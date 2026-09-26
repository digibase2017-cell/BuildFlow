import { randomUUID } from 'node:crypto';

// All business actions use real HTTP JWTs. Privileged writes create/clean fixtures only.
export async function testPermissionActions({ db, owner, company, foreign, http, check, actors, project, modules, lead }) {
  const admin = actors.find(u => u.code === 'admin');
  const boss = actors.find(u => u.code === 'owner');
  const designer = actors.find(u => u.code === 'designer');
  await owner.query("SELECT public.set_user_permission($1,$2,'design.edit',NULL)", [company, designer.id]);
  await owner.query("SELECT public.set_user_permission($1,$2,'financial.edit',NULL)", [company, designer.id]);
  await owner.query('SELECT public.set_lead_assignees($1,$2,$3)', [company, lead, actors.map(u => u.id)]);
  async function fixtureUser() {
    const id = randomUUID(), auth = randomUUID();
    await db.query('INSERT INTO auth.users(id,email) VALUES ($1,$2)', [auth, `${auth}@example.test`]);
    await db.query(`INSERT INTO public.users(id,company_id,auth_user_id,role_id,full_name,email,department)
      SELECT $1,$2,$3,id,'Assignment target',$4,'Sales' FROM public.roles WHERE company_id=$2 AND code='sales'`, [id, company, auth, `${auth}@example.test`]);
    return id;
  }
  const target = await fixtureUser(), replacement = await fixtureUser();
  const rowCount = async (table, id) => (await db.query(`SELECT count(*)::int AS n FROM public.${table} WHERE id=$1`, [id])).rows[0].n;
  const rpc = (user, name, body) => http(`/rest/v1/rpc/${name}`, { token: user.token, method: 'POST', body });
  async function make(table, fields) {
    const id = randomUUID();
    const keys = ['id', 'company_id', ...Object.keys(fields)];
    await owner.query(`INSERT INTO public.${table}(${keys.join(',')}) VALUES (${keys.map((_, i) => `$${i + 1}`).join(',')})`, [id, company, ...Object.values(fields)]);
    return id;
  }
  for (const [index, user] of actors.entries()) {
    const deletes = [
      ['lead.delete', 'leads', { customer_name: 'Delete fixture' }],
      ['quote.delete', 'quotes', { lead_id: lead, title: 'Delete fixture' }],
      ['catalog.delete', 'catalog_items', { item_code: randomUUID(), name: 'Unused catalog', unit: 'cái' }],
      ['payment.delete', 'project_payments', { project_id: project, transfer_at: '2026-09-24T00:00:00Z', amount: 10 }],
      ['document.delete', 'documents', { project_id: project, name: 'Delete fixture', storage_kind: 'external_link', external_url: 'https://example.test/fixture' }],
      ['design.edit', 'design_rounds', { design_id: modules.designs, round_number: 100 + index }],
      ['acceptance.edit', 'acceptance_rounds', { project_id: project, acceptance_id: modules.acceptance, round_number: 100 + index, round_date: '2026-09-24', result: 'Cần khắc phục' }],
      ...['purchasing', 'production', 'construction'].map(kind => [`${kind}.edit`, `${kind}_items`,
        { project_id: project, [`${kind}_id`]: modules[kind], name: 'Delete fixture', unit: 'cái', required_quantity: 1 }]),
    ];
    for (const [permission, table, fields] of deletes) {
      const id = await make(table, fields);
      const allowed = user.expected.has(permission);
      const r = await http(`/rest/v1/${table}?id=eq.${id}`, { token: user.token, method: 'DELETE', prefer: 'return=representation' });
      check(r.status === 200 && r.body.length === (allowed ? 1 : 0) && await rowCount(table, id) === (allowed ? 0 : 1),
        `${user.code}: DELETE ${table} via ${permission} ${allowed ? 'allowed' : 'denied'}`);
    }
    const canManage = user.expected.has('project.manage_members');
    let id = randomUUID();
    let r = await http('/rest/v1/project_members', { token: user.token, method: 'POST', prefer: 'return=representation',
      body: { id, company_id: company, project_id: project, user_id: target } });
    check(r.status === (canManage ? 201 : 403) && await rowCount('project_members', id) === (canManage ? 1 : 0), `${user.code}: add Project member matches manage_members`);
    if (!canManage) id = await make('project_members', { project_id: project, user_id: target });
    r = await http(`/rest/v1/project_members?id=eq.${id}`, { token: user.token, method: 'DELETE', prefer: 'return=representation' });
    check(r.status === 200 && r.body.length === (canManage ? 1 : 0) && await rowCount('project_members', id) === (canManage ? 0 : 1), `${user.code}: remove Project member matches manage_members`);
    if (canManage) await make('project_members', { project_id: project, user_id: target });

    id = randomUUID();
    r = await http('/rest/v1/project_sales', { token: user.token, method: 'POST', prefer: 'return=representation',
      body: { id, company_id: company, project_id: project, user_id: target } });
    check(r.status === (canManage ? 201 : 403) && await rowCount('project_sales', id) === (canManage ? 1 : 0), `${user.code}: add Project Sales matches manage_members`);
    if (!canManage) id = await make('project_sales', { project_id: project, user_id: target });
    r = await http(`/rest/v1/project_sales?id=eq.${id}`, { token: user.token, method: 'DELETE', prefer: 'return=representation' });
    check(r.status === 200 && r.body.length === (canManage ? 1 : 0) && await rowCount('project_sales', id) === (canManage ? 0 : 1), `${user.code}: remove Project Sales matches manage_members`);
    await owner.query('DELETE FROM public.project_sales WHERE project_id=$1 AND user_id=$2', [project, target]);
    await make('project_members', { project_id: project, user_id: replacement });

    const canAssign = user.expected.has('acceptance.assign');
    id = randomUUID();
    r = await http('/rest/v1/acceptance_users', { token: user.token, method: 'POST', prefer: 'return=representation',
      body: { id, company_id: company, project_id: project, acceptance_id: modules.acceptance, user_id: target } });
    check(r.status === (canAssign ? 201 : 403) && await rowCount('acceptance_users', id) === (canAssign ? 1 : 0), `${user.code}: acceptance assignment matches permission`);
    if (!canAssign) id = await make('acceptance_users', { project_id: project, acceptance_id: modules.acceptance, user_id: target });
    r = await http(`/rest/v1/acceptance_users?id=eq.${id}`, { token: user.token, method: 'PATCH', prefer: 'return=representation', body: { user_id: replacement } });
    check(r.status === 200 && r.body.length === (canAssign ? 1 : 0) &&
      (await db.query('SELECT user_id FROM public.acceptance_users WHERE id=$1', [id])).rows[0].user_id === (canAssign ? replacement : target),
      `${user.code}: reassign acceptance matches permission`);
    // No client DELETE surface exists for acceptance_users; fixture cleanup is privileged.
    await db.query('DELETE FROM public.acceptance_users WHERE id=$1', [id]);
    await owner.query('DELETE FROM public.project_members WHERE project_id=$1 AND user_id=ANY($2::uuid[])', [project, [target, replacement]]);

    const canAssignLead = user.expected.has('lead.assign');
    r = await rpc(user, 'set_lead_assignees', { p_company: company, p_lead: lead, p_users: [...actors.map(u => u.id), target] });
    check(r.status === (canAssignLead ? 204 : 403) &&
      (await db.query('SELECT count(*)::int AS n FROM public.lead_assignments WHERE lead_id=$1 AND user_id=$2 AND unassigned_at IS NULL', [lead, target])).rows[0].n === (canAssignLead ? 1 : 0),
      `${user.code}: Lead assignment RPC matches default permission`);
    await owner.query('SELECT public.set_lead_assignees($1,$2,$3)', [company, lead, actors.map(u => u.id)]);
  }

  const supervisor = actors.find(u => u.code === 'supervisor');
  let r = await http('/rest/v1/acceptance_users', { token: supervisor.token, method: 'POST',
    body: { company_id: company, project_id: project, acceptance_id: modules.acceptance, user_id: target } });
  check(r.status === 400 && r.body.code === '23514', 'acceptance.assign cannot add a non-member');
  r = await http('/rest/v1/project_members', { token: supervisor.token, method: 'POST', body: { company_id: company, project_id: project, user_id: target } });
  check(r.status === 403, 'Supervisor cannot use acceptance.assign to create Project membership');
  r = await http('/rest/v1/project_members', { token: admin.token, method: 'POST', body: { company_id: company, project_id: project, user_id: foreign.id } });
  check(r.status === 400 && r.body.code === '23514', 'Project membership rejects a foreign-tenant user');
  await db.query('UPDATE public.users SET is_active=false WHERE id=$1', [target]);
  r = await http('/rest/v1/project_members', { token: admin.token, method: 'POST', body: { company_id: company, project_id: project, user_id: target } });
  check(r.status === 400 && r.body.code === '23514', 'Project membership rejects an inactive user');
  await db.query('UPDATE public.users SET is_active=true WHERE id=$1', [target]);
  await make('project_members', { project_id: project, user_id: target });
  const assignment = await make('acceptance_users', { project_id: project, acceptance_id: modules.acceptance, user_id: target });
  const membership = (await db.query('SELECT id FROM public.project_members WHERE project_id=$1 AND user_id=$2', [project, target])).rows[0].id;
  r = await http(`/rest/v1/project_members?id=eq.${membership}`, { token: admin.token, method: 'DELETE', prefer: 'return=representation' });
  check(r.status === 409 && r.body.code === '23503' && await rowCount('project_members', membership) === 1,
    'Deferred FK prevents removing a member who is still assigned to acceptance');
  await db.query('DELETE FROM public.acceptance_users WHERE id=$1', [assignment]);

  const roles = Object.fromEntries((await db.query('SELECT code,id FROM public.roles WHERE company_id=$1', [company])).rows.map(r => [r.code, r.id]));
  r = await rpc(admin, 'assign_user_role', { p_company: company, p_user: target, p_role: roles.admin });
  check(r.status === 403, 'Admin cannot promote another user to Admin');
  r = await rpc(boss, 'assign_user_role', { p_company: company, p_user: target, p_role: roles.admin });
  check(r.status === 204, 'Owner can promote a user to Admin');
  r = await rpc(admin, 'assign_user_role', { p_company: company, p_user: target, p_role: roles.sales });
  check(r.status === 403, 'Admin cannot demote another Admin');
  r = await rpc(boss, 'assign_user_role', { p_company: company, p_user: target, p_role: roles.sales });
  check(r.status === 204, 'Owner can restore a regular Role');
  r = await http(`/rest/v1/users?id=eq.${boss.id}`, { token: admin.token, method: 'PATCH', body: { is_active: false } });
  check(r.status === 403 && (await db.query('SELECT is_active FROM public.users WHERE id=$1', [boss.id])).rows[0].is_active,
    'Direct HTTP user update cannot bypass Owner protection');
  r = await rpc(admin, 'set_role_permission', { p_company: company, p_role: roles.owner, p_code: 'lead.delete', p_grant: false });
  check(r.status === 403, 'Admin cannot change Owner role permissions');
  // Ordinary permission grants never confer protected role-administration authority.
  await owner.query("SELECT public.set_user_permission($1,$2,'role.edit','allow')", [company, designer.id]);
  await owner.query("SELECT public.set_user_permission($1,$2,'user.edit','allow')", [company, designer.id]);
  r = await rpc(designer, 'assign_user_role', { p_company: company, p_user: target, p_role: roles.admin });
  check(r.status === 403 && (await db.query('SELECT role_id FROM public.users WHERE id=$1', [target])).rows[0].role_id === roles.sales,
    'User/role permission overrides cannot manufacture protected Admin authority');
}
