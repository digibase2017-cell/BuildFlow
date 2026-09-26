// Disposable local integration suite. This command resets this project's DB
// before AND after execution; it never accepts a remote URL or linked project.
import assert from 'node:assert/strict';
import { randomUUID, randomBytes } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import pg from 'pg';
import { testQuoteSources } from './test-quote-sources.mjs';
import { testRoleMatrix } from './test-role-matrix.mjs';
import { testPermissionActions } from './test-permission-actions.mjs';
import { testModuleConcurrency } from './test-module-concurrency.mjs';
import { testHiddenProjects } from './test-hidden-projects.mjs';

const exec = promisify(execFile);
const root = fileURLToPath(new URL('../', import.meta.url));
assert(process.argv.includes('--reset-local'), 'Explicit --reset-local is required');
assert(process.env.npm_execpath, 'Run through npm run test:integration');
const config = await readFile(new URL('../supabase/config.toml', import.meta.url), 'utf8');
assert(/^project_id = "project_saas_local"$/m.test(config), 'Unexpected local project');
async function npm(script) {
  const { stdout } = await exec(process.execPath, [process.env.npm_execpath, 'run', script, '--silent'],
    { cwd: root, timeout: 180000, maxBuffer: 4 * 1024 * 1024, windowsHide: true });
  return stdout;
}
const status = JSON.parse(await npm('local:status'));
const dbURL = new URL(status.DB_URL);
assert.equal(dbURL.hostname, '127.0.0.1');
assert.equal(dbURL.port, '54322');
assert.equal(dbURL.pathname, '/postgres');
assert.equal(status.API_URL, 'http://127.0.0.1:54321');
const clients = new Set();
let checks = 0;
function check(value, name) { assert(value, name); console.log(`OK ${++checks}: ${name}`); }
async function connect(subject) {
  const client = new pg.Client({ connectionString: status.DB_URL, statement_timeout: 10000,
    application_name: 'project_saas_local_integration', connectionTimeoutMillis: 5000 });
  await client.connect(); clients.add(client);
  if (subject) {
    await client.query('SET ROLE authenticated');
    await client.query("SELECT set_config('request.jwt.claim.sub',$1,false)", [subject]);
  }
  return client;
}
async function close(client) { clients.delete(client); await client.end(); }
async function http(path, { token, method = 'GET', body, prefer } = {}) {
  const response = await fetch(`${status.API_URL}${path}`, { method,
    headers: { apikey: status.ANON_KEY, ...(token ? { Authorization: `Bearer ${token}` } : {}),
      'Content-Type': 'application/json', ...(prefer ? { Prefer: prefer } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(10000) });
  const text = await response.text();
  return { status: response.status, body: text ? JSON.parse(text) : null };
}
async function identity(label) {
  const email = `${label}-${randomUUID()}@example.test`;
  const password = randomBytes(24).toString('base64url');
  const signup = await http('/auth/v1/signup', { method: 'POST', body: { email, password } });
  assert.equal(signup.status, 200, 'Local Auth signup failed');
  const login = await http('/auth/v1/token?grant_type=password', { method: 'POST', body: { email, password } });
  check(login.status === 200 && login.body.access_token && login.body.user.id,
    `${label}: real Auth password login succeeds`);
  return { subject: login.body.user.id, token: login.body.access_token, refresh: login.body.refresh_token, id: randomUUID() };
}
// First transaction already holds its locks before the second query starts.
// Verify an actual PostgreSQL blocking relationship, not a timing assumption.
async function race(observer, subject1, first, subject2, second) {
  const a = await connect(subject1), b = await connect(subject2);
  let pending;
  try {
    await a.query('BEGIN');
    const firstResult = await first(a);
    pending = second(b).then(result => ({ result }), error => ({ error }));
    let blocked = false;
    const deadline = Date.now() + 5000;
    while (Date.now() < deadline) {
      const { rows } = await observer.query('SELECT $1::int = ANY(pg_blocking_pids($2)) AS blocked', [a.processID, b.processID]);
      if (rows[0].blocked) { blocked = true; break; }
      await new Promise(resolve => setTimeout(resolve, 25));
    }
    assert(blocked, 'Contending session never blocked on the first transaction');
    await a.query('COMMIT');
    return { first: firstResult, second: await pending };
  } finally {
    await a.query('ROLLBACK').catch(() => {});
    if (pending) await pending;
    await close(a); await close(b);
  }
}

let resetStarted = false;
try {
  console.log('Resetting disposable project_saas_local before integration tests...');
  resetStarted = true;
  await npm('db:reset');
  const db = await connect();
  const admin = await identity('admin'), sales = await identity('sales'), foreign = await identity('foreign');
  const company = randomUUID(), other = randomUUID();
  await db.query('INSERT INTO public.companies(id,name) VALUES ($1,$2),($3,$4)', [company, 'Integration A', other, 'Integration B']);
  await db.query(`INSERT INTO public.company_subscriptions(company_id,plan_id,starts_at,expires_at,grace_ends_at,
    price_paid_vnd,max_active_users,max_projects,r2_storage_bytes)
    SELECT c.id,p.id,now()-interval '1 day',now()+interval '1 year',now()+interval '1 year 7 days',
      p.annual_price_vnd,p.max_active_users,p.max_projects,p.r2_storage_bytes
    FROM public.companies c CROSS JOIN public.subscription_plans p WHERE c.id=ANY($1::uuid[]) AND p.code='starter'`, [[company, other]]);
  for (const [user, tenant, role] of [[admin, company, 'admin'], [sales, company, 'sales'], [foreign, other, 'sales']]) {
    await db.query(`INSERT INTO public.users(id,company_id,auth_user_id,role_id,full_name,email,department)
      SELECT $1,$2,$3,id,$4,$5,'Sales' FROM public.roles WHERE company_id=$2 AND code=$6`,
      [user.id, tenant, user.subject, role, `${user.id}@example.test`, role]);
  }
  const owner = await connect(admin.subject);
  const lead = randomUUID();
  let r = await http('/rest/v1/leads', { token: admin.token, method: 'POST', prefer: 'return=representation',
    body: { id: lead, company_id: company, customer_name: 'HTTP customer' } });
  check(r.status === 201 && r.body[0].created_by === admin.id, 'HTTP Lead create assigns the authenticated actor');
  r = await http(`/rest/v1/leads?id=eq.${lead}&select=id`, { token: sales.token });
  check(r.status === 200 && r.body.length === 1, 'HTTP Sales sees unassigned Lead');
  r = await http(`/rest/v1/leads?id=eq.${lead}&select=id`, { token: foreign.token });
  check(r.status === 200 && r.body.length === 0, 'HTTP tenant isolation hides foreign Lead');
  r = await http('/rest/v1/leads', { token: foreign.token, method: 'POST', body: { company_id: company, customer_name: 'Forbidden' } });
  check(r.status === 403, 'HTTP cross-tenant create rejected');
  r = await http('/rest/v1/leads?select=id');
  check(r.status === 401 || r.status === 403, 'HTTP anonymous business access rejected');
  r = await http('/rest/v1/leads?select=id', { token: 'invalid.jwt.token' });
  check(r.status === 401, 'HTTP invalid JWT rejected');
  r = await http('/rest/v1/rpc/set_lead_assignees', { token: admin.token, method: 'POST',
    body: { p_company: company, p_lead: lead, p_users: [admin.id] } });
  check(r.status === 204, 'HTTP assignment RPC succeeds');
  r = await http(`/rest/v1/leads?id=eq.${lead}&select=id`, { token: sales.token });
  check(r.status === 200 && r.body.length === 0, 'HTTP assignment immediately removes non-assignee scope');
  r = await http(`/rest/v1/leads?id=eq.${lead}`, { token: sales.token, method: 'PATCH', prefer: 'return=representation', body: { notes: 'forbidden' } });
  check(r.status === 200 && r.body.length === 0, 'HTTP hidden Lead update changes no rows');
  check((await db.query('SELECT notes FROM public.leads WHERE id=$1', [lead])).rows[0].notes === null, 'Privileged verification confirms hidden update did not write');
  r = await http('/auth/v1/token?grant_type=refresh_token', { method: 'POST', body: { refresh_token: sales.refresh } });
  check(r.status === 200 && r.body.access_token, 'HTTP refresh token grants a new session');
  sales.token = r.body.access_token;
  await db.query('UPDATE public.users SET is_active=false WHERE id=$1', [sales.id]);
  r = await http('/rest/v1/leads?select=id', { token: sales.token });
  check(r.status === 200 && r.body.length === 0, 'Existing Auth token cannot bypass inactive application user');
  await db.query('UPDATE public.users SET is_active=true WHERE id=$1', [sales.id]);

  await owner.query("SELECT public.set_user_permission($1,$2,'lead.assign','allow')", [company, sales.id]);
  await owner.query('SELECT public.set_lead_assignees($1,$2,$3)', [company, lead, []]);
  let outcome = await race(db, admin.subject,
    c => c.query('SELECT public.set_lead_assignees($1,$2,$3)', [company, lead, [admin.id]]), sales.subject,
    c => c.query('SELECT public.set_lead_assignees($1,$2,$3)', [company, lead, [sales.id]]));
  check(outcome.second.error?.code === '42501', 'Concurrent assignment rechecks scope after waiting for Lead lock');
  check((await db.query('SELECT user_id FROM public.lead_assignments WHERE lead_id=$1 AND unassigned_at IS NULL', [lead])).rows.map(x => x.user_id).join() === admin.id,
    'Rejected concurrent assignment preserves winning assignee');

  // Parallel independent transactions allocate company Lead numbers atomically.
  const numberingClients = await Promise.all(Array.from({ length: 8 }, () => connect(admin.subject)));
  const numbered = await Promise.allSettled(numberingClients.map(c => c.query(
    'INSERT INTO public.leads(company_id,customer_name) VALUES ($1,$2) RETURNING lead_number', [company, 'Parallel lead'])));
  await Promise.all(numberingClients.map(close));
  check(numbered.every(x => x.status === 'fulfilled'), 'Eight concurrent Lead creates all commit');
  check(new Set(numbered.map(x => x.value.rows[0].lead_number)).size === 8, 'Concurrent Lead numbers never collide');

  await owner.query("UPDATE public.leads SET status='Thành công' WHERE id=$1", [lead]);
  await db.query('UPDATE public.company_subscriptions SET max_projects=1 WHERE company_id=$1', [company]);
  outcome = await race(db, admin.subject,
    c => c.query("SELECT public.create_project_from_lead($1,$2,'Quota winner',NULL,false,true,true,true) AS id", [company, lead]), admin.subject,
    c => c.query("SELECT public.create_project_from_lead($1,$2,'Quota contender')", [company, lead]));
  check(outcome.second.error?.code === '23514', 'Concurrent Project creation cannot exceed the last quota slot');
  check((await db.query('SELECT count(*)::int AS n FROM public.projects WHERE company_id=$1', [company])).rows[0].n === 1, 'Only one Project exists after quota race');
  const project = outcome.first.rows[0].id;
  await db.query('UPDATE public.company_subscriptions SET max_projects=10 WHERE company_id=$1', [company]);
  outcome = await race(db, admin.subject,
    c => c.query("UPDATE public.leads SET status='Đàm phán' WHERE id=$1", [lead]), admin.subject,
    c => c.query("SELECT public.create_project_from_lead($1,$2,'Stale status')", [company, lead]));
  check(outcome.second.error?.code === '23514', 'Project creation rechecks successful Lead status after concurrent reversal');

  for (const [kind, batch, date, done] of [
    ['purchasing', 'purchasing_receipts', 'receipt_date', 'Đã nhận'],
    ['production', 'production_batches', 'completed_date', 'Hoàn thành'],
    ['construction', 'construction_batches', 'completed_date', 'Hoàn thành']]) {
    const module = (await owner.query(`INSERT INTO public.project_${kind}(company_id,project_id) VALUES ($1,$2) RETURNING id`, [company, project])).rows[0].id;
    const item = (await owner.query(`INSERT INTO public.${kind}_items(company_id,project_id,${kind}_id,name,unit,required_quantity)
      VALUES ($1,$2,$3,'Concurrent item','cái',10) RETURNING id`, [company, project, module])).rows[0].id;
    const insert = (c, quantity) => c.query(`INSERT INTO public.${batch}(company_id,${kind}_item_id,${date},quantity)
      VALUES ($1,$2,current_date,$3)`, [company, item, quantity]);
    outcome = await race(db, admin.subject, c => insert(c, 6), admin.subject, c => insert(c, 4));
    if (outcome.second.error) throw outcome.second.error;
    check((await owner.query(`SELECT status FROM public.${kind}_items WHERE id=$1`, [item])).rows[0].status === done,
      `${kind}: concurrent quantities reconcile to completed status`);
    check((await owner.query(`SELECT sum(quantity)::int AS n FROM public.${batch} WHERE ${kind}_item_id=$1`, [item])).rows[0].n === 10,
      `${kind}: both concurrent quantities are retained`);
  }

  const quote = (await owner.query("INSERT INTO public.quotes(company_id,lead_id,title) VALUES ($1,$2,'Concurrent quote') RETURNING id", [company, lead])).rows[0].id;
  const version = (await owner.query('INSERT INTO public.quote_versions(company_id,quote_id,version_number) VALUES ($1,$2,1) RETURNING id', [company, quote])).rows[0].id;
  const room = (await owner.query("INSERT INTO public.quote_rooms(company_id,version_id,name) VALUES ($1,$2,'Room') RETURNING id", [company, version])).rows[0].id;
  outcome = await race(db, admin.subject,
    c => c.query('SELECT public.finalize_quote_version($1,$2)', [company, version]), admin.subject,
    c => c.query("UPDATE public.quote_rooms SET name='Stale edit' WHERE id=$1", [room]));
  check(outcome.second.error?.code === '23514', 'Concurrent Quote child edit cannot pass a committed finalization');
  outcome = await race(db, admin.subject,
    c => c.query('SELECT public.clone_quote_version($1,$2)', [company, version]), admin.subject,
    c => c.query('SELECT public.clone_quote_version($1,$2)', [company, version]));
  if (outcome.second.error) throw outcome.second.error;
  check((await owner.query('SELECT version_number FROM public.quote_versions WHERE quote_id=$1 ORDER BY version_number', [quote])).rows.map(x => x.version_number).join() === '1,2,3',
    'Concurrent clones allocate V2 and V3 without collisions');
  const foreignClient = await connect(foreign.subject);
  await testQuoteSources({ owner, foreignClient, company, other, check });
  const roleContext = await testRoleMatrix({ db, owner, company, admin, sales, identity, http, check });
  await testPermissionActions({ db, owner, company, foreign, http, check, ...roleContext });
  await testModuleConcurrency({ db, owner, company, admin, race, check });
  await testHiddenProjects({ db, owner, company, other, foreign, admin, sales, http, check, race, ...roleContext });
  console.log(`PASS: ${checks} HTTP/concurrency/source/role checks`);
} catch (error) {
  // Never print HTTP credentials, JWTs, connection URLs or command stdout.
  console.error(`FAIL: ${error.code ?? error.name}: ${error.message}`);
  process.exitCode = 1;
} finally {
  await Promise.allSettled([...clients].map(close));
  if (resetStarted) {
    try {
      await npm('db:reset');
      console.log('Cleanup: disposable local database reset; Auth and business fixtures removed.');
    } catch {
      console.error('Cleanup reset FAILED. Run npm run db:reset locally before continuing.');
      process.exitCode = 1;
    }
  }
}
