// Explicitly scoped to the disposable project_saas_local database. Never resets data.
import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import pg from 'pg';

assert(process.argv.includes('--local-only'), 'Run npm run app:demo -- --local-only');
const root = fileURLToPath(new URL('../', import.meta.url));
const config = await readFile(path.join(root, 'supabase/config.toml'), 'utf8');
assert(/^project_id = "project_saas_local"$/m.test(config), 'Unexpected Supabase project');
const cli = path.join(root, 'node_modules/supabase/dist/supabase.js');
const result = spawnSync(process.execPath, [cli, 'status', '--output', 'json'], {
  cwd: root, encoding: 'utf8', timeout: 20000, windowsHide: true,
});
assert.equal(result.status, 0, 'Supabase Local is not running');
const status = JSON.parse(result.stdout);
assert.equal(status.API_URL, 'http://127.0.0.1:54321');
const dbUrl = new URL(status.DB_URL);
assert.equal(dbUrl.hostname, '127.0.0.1');
assert.equal(dbUrl.port, '54322');
assert.equal(dbUrl.pathname, '/postgres');
const db = new pg.Client({ connectionString: status.DB_URL, connectionTimeoutMillis: 5000 });
await db.connect();
const createdAuth = [];
async function auth(path, body) {
  const response = await fetch(`${status.API_URL}${path}`, { method: 'POST',
    headers: { apikey: status.ANON_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify(body), signal: AbortSignal.timeout(10000) });
  const data = await response.json();
  if (!response.ok) throw new Error(`Local Auth returned ${response.status}`);
  return data;
}
const users = [
  { code: 'owner', email: `demo-owner-${randomUUID().slice(0, 8)}@example.test`, password: randomBytes(15).toString('base64url'), id: randomUUID() },
  { code: 'sales', email: `demo-sales-${randomUUID().slice(0, 8)}@example.test`, password: randomBytes(15).toString('base64url'), id: randomUUID() },
];
try {
  const existing = await db.query('SELECT count(*)::int AS n FROM public.companies');
  assert.equal(existing.rows[0].n, 0, 'Local database already has a company; demo seeding refused without changing data');
  for (const user of users) {
    const signed = await auth('/auth/v1/signup', { email: user.email, password: user.password });
    assert(signed.user?.id, 'Local signup did not create an Auth user');
    user.authId = signed.user.id; createdAuth.push(user.authId);
  }
  const company = randomUUID();
  await db.query('BEGIN');
  await db.query('INSERT INTO public.companies(id,name) VALUES ($1,$2)', [company, 'Công ty mẫu · Local']);
  await db.query(`INSERT INTO public.company_subscriptions(company_id,plan_id,starts_at,expires_at,grace_ends_at,
    price_paid_vnd,max_active_users,max_projects,r2_storage_bytes)
    SELECT $1,id,now()-interval '1 day',now()+interval '1 year',now()+interval '1 year 7 days',
      annual_price_vnd,max_active_users,max_projects,r2_storage_bytes
    FROM public.subscription_plans WHERE code='starter'`, [company]);
  for (const user of users) {
    await db.query(`INSERT INTO public.users(id,company_id,auth_user_id,role_id,full_name,email)
      SELECT $1,$2,$3,id,$4,$5 FROM public.roles WHERE company_id=$2 AND code=$6`,
    [user.id, company, user.authId, user.code === 'owner' ? 'Chủ doanh nghiệp' : 'Nhân viên Sales', user.email, user.code]);
  }
  const examples = [
    ['Căn hộ Riverside', 'Quận 2, TP. Hồ Chí Minh', 'Đang thực hiện', false],
    ['Biệt thự An Phú', 'TP. Thủ Đức', 'Chưa bắt đầu', true],
    ['Nhà phố Bình Thạnh', 'Quận Bình Thạnh', 'Tạm dừng', false],
  ];
  await db.query("SELECT set_config('request.jwt.claim.sub',$1,true)", [users[0].authId]);
  for (const [name, address, statusName, hidden] of examples) {
    const lead = randomUUID();
    await db.query(`INSERT INTO public.leads(id,company_id,customer_name,status,created_by)
      VALUES ($1,$2,$3,'Thành công',$4)`, [lead, company, `Khách hàng · ${name}`, users[0].id]);
    const project = (await db.query('SELECT public.create_project_from_lead($1,$2,$3,$4) AS id',
      [company, lead, name, address])).rows[0].id;
    await db.query('UPDATE public.projects SET status=$2,is_hidden=$3 WHERE id=$1',
      [project, statusName, hidden]);
    await db.query(`INSERT INTO public.project_members(company_id,project_id,user_id,added_by)
      VALUES ($1,$2,$3,$4)`, [company, project, users[1].id, users[0].id]);
  }
  await db.query('COMMIT');
  console.log('Demo company and three Projects created on Supabase Local only.');
  for (const user of users) console.log(`${user.code}: ${user.email} / ${user.password}`);
  console.log('Credentials are local demo credentials. Save them now; they are not written to a file.');
} catch (error) {
  await db.query('ROLLBACK').catch(() => {});
  if (createdAuth.length) await db.query('DELETE FROM auth.users WHERE id=ANY($1::uuid[])', [createdAuth]).catch(() => {});
  console.error(`Demo seed failed: ${error.message}`);
  process.exitCode = 1;
} finally { await db.end(); }
