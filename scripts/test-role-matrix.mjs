import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';

// Expectations come from the agreed handoff, never from implementation seed SQL.
export async function testRoleMatrix({ db, owner, company, admin, sales, identity, http, check }) {
  const handoff = await readFile(new URL('../project_handoff_business_decisions.md', import.meta.url), 'utf8');
  const expand = text => [...text.matchAll(/`([a-z_]+)\.([a-z_/]+)`/g)]
    .flatMap(m => m[2].split('/').map(action => `${m[1]}.${action}`));
  // Read only catalog bullet entries, not prose explaining removed permissions.
  const all = expand(handoff.split('## 2.6.')[1].split('## 2.7.')[0]
    .split('\n').filter(line => line.startsWith('- `')).join('\n'));
  assert.equal(new Set(all).size, 56, 'Handoff permission catalog must have 56 codes');
  const codes = { Owner: 'owner', Admin: 'admin', Marketing: 'marketing', Sales: 'sales',
    'Project Manager': 'project_manager', Designer: 'designer', Purchasing: 'purchasing',
    Production: 'production', Construction: 'construction', 'Giám sát': 'supervisor', 'Kế toán': 'accountant' };
  const actors = [];
  await owner.query("SELECT public.set_user_permission($1,$2,'lead.assign',NULL)", [company, sales.id]);
  for (const [label, code] of Object.entries(codes)) {
    const line = handoff.split('\n').find(line => line.startsWith(`| ${label} |`));
    assert(line, `Missing handoff Role ${label}`);
    const expected = new Set(['owner', 'admin'].includes(code) ? all : expand(line));
    const actual = (await db.query(`SELECT p.code FROM public.role_permissions rp JOIN public.roles r ON r.id=rp.role_id
      JOIN public.permissions p ON p.id=rp.permission_id WHERE r.company_id=$1 AND r.code=$2 ORDER BY p.code`, [company, code])).rows.map(r => r.code);
    assert.deepEqual(actual, [...expected].sort(), `${code}: default permissions differ from handoff`);
    check(true, `${code}: exact default permission set matches handoff`);
    const user = code === 'admin' ? admin : code === 'sales' ? sales : await identity(code);
    if (user !== admin && user !== sales) await db.query(`INSERT INTO public.users(id,company_id,auth_user_id,role_id,full_name,email)
      SELECT $1,$2,$3,id,$4,$5 FROM public.roles WHERE company_id=$2 AND code=$4`,
      [user.id, company, user.subject, code, `${user.id}@example.test`]);
    actors.push({ ...user, code, expected });
  }
  const lead = (await owner.query("INSERT INTO public.leads(company_id,customer_name,status) VALUES ($1,'Role matrix','Thành công') RETURNING id", [company])).rows[0].id;
  await owner.query('SELECT public.set_lead_assignees($1,$2,$3)', [company, lead, actors.map(u => u.id)]);
  const project = (await owner.query("SELECT public.create_project_from_lead($1,$2,'Role matrix',NULL,true,true,true,true) AS id", [company, lead])).rows[0].id;
  for (const user of actors) await owner.query('INSERT INTO public.project_members(company_id,project_id,user_id) VALUES ($1,$2,$3) ON CONFLICT DO NOTHING', [company, project, user.id]);
  const modules = {};
  for (const kind of ['designs', 'purchasing', 'production', 'construction']) {
    modules[kind] = (await owner.query(`INSERT INTO public.project_${kind}(company_id,project_id) VALUES ($1,$2) RETURNING id`, [company, project])).rows[0].id;
  }
  modules.acceptance = (await owner.query('SELECT id FROM public.project_acceptance WHERE project_id=$1', [project])).rows[0].id;
  const quote = (await owner.query("INSERT INTO public.quotes(company_id,lead_id,title) VALUES ($1,$2,'Role matrix quote') RETURNING id", [company, lead])).rows[0].id;
  const catalog = (await owner.query("INSERT INTO public.catalog_items(company_id,item_code,name,unit) VALUES ($1,'MATRIX','Matrix catalog','cái') RETURNING id", [company])).rows[0].id;
  const payment = (await owner.query('INSERT INTO public.project_payments(company_id,project_id,transfer_at,amount) VALUES ($1,$2,now(),100) RETURNING id', [company, project])).rows[0].id;
  const document = (await owner.query("INSERT INTO public.documents(company_id,project_id,name,storage_kind,external_url) VALUES ($1,$2,'Matrix document','external_link','https://example.test/document') RETURNING id", [company, project])).rows[0].id;
  const financial = (await owner.query('SELECT id FROM public.project_financials WHERE project_id=$1', [project])).rows[0].id;
  const targets = [
    ['lead', 'leads', lead, 'notes'], ['quote', 'quotes', quote, 'notes'],
    ['project', 'projects', project, 'notes'], ['catalog', 'catalog_items', catalog, 'notes'],
    ['design', 'project_designs', modules.designs, 'notes'],
    ['purchasing', 'project_purchasing', modules.purchasing, 'notes'],
    ['production', 'project_production', modules.production, 'notes'],
    ['construction', 'project_construction', modules.construction, 'notes'],
    ['acceptance', 'project_acceptance', modules.acceptance, 'notes'],
    ['payment', 'project_payments', payment, 'amount'],
    ['financial', 'project_financials', financial, 'budget'],
    ['document', 'documents', document, 'notes'],
  ];
  for (const user of actors) {
    let n = 0;
    for (const [permission, table, id, field] of targets) {
      const path = `/rest/v1/${table}?id=eq.${id}`;
      let r = await http(`${path}&select=id`, { token: user.token });
      const canView = user.expected.has(`${permission}.view`);
      check(r.status === 200 && r.body.length === (canView ? 1 : 0), `${user.code}: HTTP ${permission}.view ${canView ? 'allowed' : 'denied'}`);
      const value = ['amount', 'budget'].includes(field) ? 1000 + actors.indexOf(user) * 100 + n++ : `${user.code}-${permission}`;
      const before = (await db.query(`SELECT ${field} FROM public.${table} WHERE id=$1`, [id])).rows[0][field];
      r = await http(path, { token: user.token, method: 'PATCH', prefer: 'return=representation', body: { [field]: value } });
      const canEdit = user.expected.has(`${permission}.edit`);
      check(r.status === 200 && r.body.length === (canEdit ? 1 : 0), `${user.code}: HTTP ${permission}.edit ${canEdit ? 'allowed' : 'denied'}`);
      const after = (await db.query(`SELECT ${field} FROM public.${table} WHERE id=$1`, [id])).rows[0][field];
      assert.equal(String(after), String(canEdit ? value : before), `${user.code}: unexpected persisted ${table} mutation`);
    }
    // Insert tests exercise WITH CHECK policies, distinct from UPDATE visibility.
    const creates = [
      ['lead', 'leads', { customer_name: 'HTTP role create' }],
      ['catalog', 'catalog_items', { item_code: randomUUID(), name: 'HTTP catalog', unit: 'cái' }],
      ['quote', 'quotes', { lead_id: lead, title: 'HTTP quote' }],
      ['purchasing', 'purchasing_items', { project_id: project, purchasing_id: modules.purchasing, name: 'HTTP item', unit: 'cái', required_quantity: 1 }],
      ['production', 'production_items', { project_id: project, production_id: modules.production, name: 'HTTP item', unit: 'cái', required_quantity: 1 }],
      ['construction', 'construction_items', { project_id: project, construction_id: modules.construction, name: 'HTTP item', unit: 'cái', required_quantity: 1 }],
      ['acceptance', 'acceptance_rounds', { project_id: project, acceptance_id: modules.acceptance, round_number: actors.indexOf(user) + 1, round_date: '2026-09-24', result: 'Cần khắc phục' }],
      ['payment', 'project_payments', { project_id: project, transfer_at: '2026-09-24T00:00:00Z', amount: 200 }],
      ['document', 'documents', { project_id: project, name: 'HTTP document', storage_kind: 'external_link', external_url: 'https://example.test/document' }],
    ];
    for (const [permission, table, fields] of creates) {
      const id = randomUUID();
      const r = await http(`/rest/v1/${table}`, { token: user.token, method: 'POST', prefer: 'return=representation', body: { id, company_id: company, ...fields } });
      const allowed = user.expected.has(`${permission}.create`);
      check(r.status === (allowed ? 201 : 403), `${user.code}: HTTP ${permission}.create ${allowed ? 'allowed' : 'denied'}`);
      assert.equal((await db.query(`SELECT count(*)::int AS n FROM public.${table} WHERE id=$1`, [id])).rows[0].n, allowed ? 1 : 0,
        `${user.code}: create returned unexpected persistence`);
    }
  }

  const designer = actors.find(u => u.code === 'designer');
  // Permission alone must not grant project or source Lead scope.
  await owner.query('DELETE FROM public.project_members WHERE project_id=$1 AND user_id=$2', [project, designer.id]);
  let r = await http(`/rest/v1/project_designs?id=eq.${modules.designs}&select=id`, { token: designer.token });
  check(r.status === 200 && r.body.length === 0, 'Designer loses module view after Project membership removal');
  await owner.query('INSERT INTO public.project_members(company_id,project_id,user_id) VALUES ($1,$2,$3)', [company, project, designer.id]);
  await owner.query('SELECT public.set_lead_assignees($1,$2,$3)', [company, lead, [admin.id]]);
  r = await http(`/rest/v1/quotes?id=eq.${quote}&select=id`, { token: designer.token });
  check(r.status === 200 && r.body.length === 0, 'Project membership does not reveal Quote outside Lead scope');
  r = await http(`/rest/v1/project_designs?id=eq.${modules.designs}&select=id`, { token: designer.token });
  check(r.status === 200 && r.body.length === 1, 'Hiding Lead does not remove independent Project module access');
  await owner.query("SELECT public.set_user_permission($1,$2,'design.edit','deny')", [company, designer.id]);
  r = await http(`/rest/v1/project_designs?id=eq.${modules.designs}`, { token: designer.token, method: 'PATCH', prefer: 'return=representation', body: { notes: 'denied override' } });
  check(r.status === 200 && r.body.length === 0, 'HTTP User deny overrides Designer role edit');
  await owner.query("SELECT public.set_user_permission($1,$2,'financial.edit','allow')", [company, designer.id]);
  r = await http('/rest/v1/rpc/set_project_financials', { token: designer.token, method: 'POST', body: { p_company: company, p_project: project, p_budget: 12345, p_contract_value: 54321 } });
  check(r.status === 204 && Number((await db.query('SELECT budget FROM public.project_financials WHERE project_id=$1', [project])).rows[0].budget) === 12345,
    'HTTP financial RPC supports explicit edit without view');
  r = await http(`/rest/v1/project_financials?project_id=eq.${project}&select=id`, { token: designer.token });
  check(r.status === 200 && r.body.length === 0, 'financial.edit override does not grant financial.view');
  return { actors, project, modules, lead };
}
