import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

export async function testHiddenProjects({ db, owner, company, other, foreign, admin, sales, http, check, race, actors, project, modules, lead }) {
  const boss = actors.find(u => u.code === 'owner');
  const designer = actors.find(u => u.code === 'designer');
  const accountant = actors.find(u => u.code === 'accountant');
  const rpc = (user, hidden, tenant = company, id = project) => http('/rest/v1/rpc/set_project_hidden', {
    token: user.token, method: 'POST', body: { p_company: tenant, p_project: id, p_hidden: hidden } });
  const flag = async () => (await db.query('SELECT is_hidden FROM public.projects WHERE id=$1', [project])).rows[0].is_hidden;
  const make = async (table, fields) => {
    const id = randomUUID(), keys = ['id', 'company_id', ...Object.keys(fields)];
    await owner.query(`INSERT INTO public.${table}(${keys.join(',')}) VALUES (${keys.map((_, i) => `$${i + 1}`).join(',')})`, [id, company, ...Object.values(fields)]);
    return id;
  };
  check((await db.query("SELECT count(*)::int AS n FROM public.permissions WHERE code IN ('project.delete','project.hide','project.unhide')")).rows[0].n === 0,
    'No grantable Project delete/hide/unhide permissions');
  let r = await rpc(admin, null);
  check(r.status === 400 && r.body.code === '22023', 'Hide requires explicit boolean');
  r = await rpc(admin, true, other);
  check(r.status === 403 && !await flag(), 'Admin cannot hide across tenant boundary');
  r = await rpc(foreign, true);
  check(r.status === 403 && !await flag(), 'Foreign user cannot hide another tenant Project');
  for (const user of actors) {
    r = await http(`/rest/v1/projects?id=eq.${project}`, { token: user.token, method: 'PATCH', prefer: 'return=representation', body: { is_hidden: true } });
    check((r.status === 403 || (r.status === 200 && r.body.length === 0)) && !await flag(), `${user.code}: direct PATCH cannot change hidden flag`);
    r = await http(`/rest/v1/projects?id=eq.${project}`, { token: user.token, method: 'DELETE' });
    check(r.status === 403 && !await flag(), `${user.code}: Project deletion is unavailable`);
    const manager = ['owner', 'admin'].includes(user.code);
    r = await rpc(user, true);
    check(r.status === (manager ? 204 : 403) && await flag() === manager, `${user.code}: hide is protected by Owner/Admin role`);
    r = await rpc(user, false);
    check(r.status === (manager ? 204 : 403) && !await flag(), `${user.code}: unhide is protected by Owner/Admin role`);
  }
  await owner.query("SELECT public.set_user_permission($1,$2,'project.edit','allow')", [company, designer.id]);
  r = await rpc(designer, true);
  check(r.status === 403 && !await flag(), 'Ordinary permission overrides cannot grant hide authority');

  // Build actual data in both direct and nested Project tables; empty fixtures
  // must never create false-positive visibility tests.
  const targets = [
    ['projects', `id=eq.${project}`],
    ...['project_members', 'project_sales', 'project_financials', 'project_designs', 'project_purchasing',
      'project_production', 'project_construction', 'project_acceptance', 'acceptance_rounds', 'project_payments',
      'documents', 'activity_logs'].map(t => [t, `project_id=eq.${project}`]),
  ];
  await make('design_users', { design_id: modules.designs, user_id: designer.id });
  await make('design_rounds', { design_id: modules.designs, round_number: 901 });
  targets.push(['design_users', `design_id=eq.${modules.designs}`], ['design_rounds', `design_id=eq.${modules.designs}`]);
  await make('acceptance_users', { project_id: project, acceptance_id: modules.acceptance, user_id: sales.id });
  targets.push(['acceptance_users', `project_id=eq.${project}`]);
  for (const [kind, batch, date] of [['purchasing', 'purchasing_receipts', 'receipt_date'],
    ['production', 'production_batches', 'completed_date'], ['construction', 'construction_batches', 'completed_date']]) {
    await make(`${kind}_users`, { [`${kind}_id`]: modules[kind], user_id: sales.id });
    const item = await make(`${kind}_items`, { project_id: project, [`${kind}_id`]: modules[kind], name: 'Hidden snapshot', unit: 'cái', required_quantity: 10 });
    await make(batch, { [`${kind}_item_id`]: item, [date]: '2026-09-24', quantity: 1 });
    targets.push([`${kind}_users`, `${kind}_id=eq.${modules[kind]}`], [`${kind}_items`, `id=eq.${item}`], [batch, `${kind}_item_id=eq.${item}`]);
    if (kind === 'construction') {
      const category = (await db.query('SELECT id FROM public.construction_expense_categories WHERE company_id=$1 LIMIT 1', [company])).rows[0].id;
      await make('construction_expenses', { construction_item_id: item, category_id: category, expense_date: '2026-09-24', amount: 100 });
      targets.push(['construction_expenses', `construction_item_id=eq.${item}`]);
    }
  }
  const quote = await make('quotes', { lead_id: lead, title: 'Independent source Quote' });
  const version = await make('quote_versions', { quote_id: quote, version_number: 1 });
  await owner.query('SELECT public.finalize_quote_version($1,$2)', [company, version]);
  await owner.query('SELECT public.apply_quote_version($1,$2,$3)', [company, project, version]);
  targets.push(['project_quote_history', `project_id=eq.${project}`], ['project_applied_quote_versions', `project_id=eq.${project}`]);
  const event = randomUUID();
  await db.query("INSERT INTO public.notification_events(id,company_id,event_type,entity_type,entity_id,project_id) VALUES ($1,$2,'test','projects',$3,$3)", [event, company, project]);
  for (const user of actors) await db.query('INSERT INTO public.notifications(company_id,event_id,recipient_user_id,title) VALUES ($1,$2,$3,$4)', [company, event, user.id, 'Project notification']);
  const generalEvent = randomUUID();
  await db.query("INSERT INTO public.notification_events(id,company_id,event_type,entity_type,entity_id) VALUES ($1,$2,'test','company',$2)", [generalEvent, company]);
  await db.query("INSERT INTO public.notifications(company_id,event_id,recipient_user_id,title) VALUES ($1,$2,$3,'General notification')", [company, generalEvent, sales.id]);
  const before = (await db.query(`SELECT p.status,p.current_quote_version_id,p.progress_percent,f.contract_value,
    (SELECT count(*) FROM public.project_members WHERE project_id=p.id) AS members
    FROM public.projects p JOIN public.project_financials f ON f.project_id=p.id WHERE p.id=$1`, [project])).rows[0];
  for (const [table, filter] of targets) {
    r = await http(`/rest/v1/${table}?${filter}`, { token: admin.token });
    assert(r.status === 200 && r.body.length > 0, `Missing positive fixture for ${table}`);
  }
  const oldAudit = Number((await db.query("SELECT count(*) AS n FROM public.activity_logs WHERE project_id=$1 AND action='project.hidden'", [project])).rows[0].n);
  await owner.query('SELECT public.set_project_hidden($1,$2,true)', [company, project]);
  await owner.query('SELECT public.set_project_hidden($1,$2,true)', [company, project]);
  const audit = (await db.query("SELECT actor_user_id,old_data,new_data FROM public.activity_logs WHERE project_id=$1 AND action='project.hidden' ORDER BY created_at DESC", [project])).rows;
  check(audit.length === oldAudit + 1 && audit[0].actor_user_id === admin.id && audit[0].old_data.is_hidden === false && audit[0].new_data.is_hidden === true,
    'Hide audit records the real actor and transition; repeated hide is a no-op');
  for (const user of actors) {
    const manager = ['owner', 'admin'].includes(user.code);
    for (const [table, filter] of targets) {
      r = await http(`/rest/v1/${table}?${filter}`, { token: user.token });
      check(r.status === 200 && (manager ? r.body.length > 0 : r.body.length === 0), `${user.code}: hidden ${table} ${manager ? 'visible' : 'blocked'}`);
    }
    r = await http(`/rest/v1/notifications?event_id=eq.${event}`, { token: user.token });
    check(r.status === 200 && r.body.length === (manager ? 1 : 0), `${user.code}: hidden Project notification respects visibility and self-only inbox`);
  }
  r = await http(`/rest/v1/leads?id=eq.${lead}`, { token: sales.token });
  check(r.status === 200 && r.body.length === 1, 'Hiding Project does not hide its independent source Lead');
  r = await http(`/rest/v1/quotes?id=eq.${quote}`, { token: sales.token });
  check(r.status === 200 && r.body.length === 1, 'Hiding Project does not hide its independent source Quote');
  r = await http(`/rest/v1/project_designs?id=eq.${modules.designs}`, { token: designer.token, method: 'PATCH', prefer: 'return=representation', body: { notes: 'Hidden write' } });
  check(r.status === 200 && r.body.length === 0, 'Hidden module cannot be edited by an ordinary member');
  r = await http('/rest/v1/rpc/set_project_financials', { token: accountant.token, method: 'POST', body: { p_company: company, p_project: project, p_budget: 1, p_contract_value: 1 } });
  check(r.status === 403, 'Guarded financial RPC cannot write a hidden Project for ordinary user');
  r = await http('/rest/v1/rpc/mark_all_notifications_read', { token: sales.token, method: 'POST', body: { p_company: company } });
  check(r.status === 200 && r.body === 1, 'Mark-all-read skips hidden notifications but handles general inbox');
  const notification = (await db.query('SELECT id FROM public.notifications WHERE event_id=$1 AND recipient_user_id=$2', [event, sales.id])).rows[0].id;
  await http('/rest/v1/rpc/set_notification_read', { token: sales.token, method: 'POST', body: { p_company: company, p_notification: notification, p_read: true } });
  check(!(await db.query('SELECT is_read FROM public.notifications WHERE id=$1', [notification])).rows[0].is_read, 'Single notification RPC cannot mutate hidden Project notification');
  await owner.query("UPDATE public.projects SET deadline=current_date-1 WHERE id=$1", [project]);
  const revision = (await db.query('SELECT deadline_revision FROM public.projects WHERE id=$1', [project])).rows[0].deadline_revision;
  const dispatched = (await db.query("SELECT app_private.dispatch_overdue($1,'projects',$2,$3,'Hidden deadline') AS id", [company, project, revision])).rows[0].id;
  const recipients = (await db.query('SELECT recipient_user_id FROM public.notifications WHERE event_id=$1 ORDER BY recipient_user_id', [dispatched])).rows.map(x => x.recipient_user_id).sort();
  check(JSON.stringify(recipients) === JSON.stringify([admin.id, boss.id].sort()), 'Hidden Project overdue notifications go only to active Owner/Admin');
  const count = (await db.query('SELECT count(*)::int AS n FROM public.projects WHERE company_id=$1', [company])).rows[0].n;
  await db.query('UPDATE public.company_subscriptions SET max_projects=$2 WHERE company_id=$1', [company, count]);
  r = await http('/rest/v1/rpc/create_project_from_lead', { token: admin.token, method: 'POST', body: { p_company: company, p_lead: lead, p_name: 'Quota bypass' } });
  check(r.status === 400 && r.body.code === '23514', 'Hidden Project still consumes the final quota slot via HTTP');
  await db.query('UPDATE public.company_subscriptions SET max_projects=10 WHERE company_id=$1', [company]);

  await db.query("UPDATE public.company_subscriptions SET expires_at=now()-interval '1 hour',grace_ends_at=now()+interval '1 day' WHERE company_id=$1", [company]);
  r = await rpc(admin, false);
  check(r.status === 403 && await flag(), 'Read-only grace blocks unhide even for Admin');
  r = await http(`/rest/v1/projects?id=eq.${project}`, { token: admin.token });
  check(r.status === 200 && r.body.length === 1, 'Admin can read hidden Project during grace');
  await db.query("UPDATE public.company_subscriptions SET grace_ends_at=now()-interval '1 minute' WHERE company_id=$1", [company]);
  r = await http(`/rest/v1/projects?id=eq.${project}`, { token: boss.token });
  check(r.status === 200 && r.body.length === 0, 'Expired grace blocks Owner hidden Project reads');
  await db.query("UPDATE public.company_subscriptions SET expires_at=now()+interval '1 year',grace_ends_at=now()+interval '1 year 7 days' WHERE company_id=$1", [company]);
  const assigned = [];
  for (const row of (await db.query('SELECT DISTINCT lead_id FROM public.lead_assignments WHERE company_id=$1 AND user_id=$2 AND unassigned_at IS NULL', [company, admin.id])).rows) {
    const users = (await db.query('SELECT user_id FROM public.lead_assignments WHERE company_id=$1 AND lead_id=$2 AND unassigned_at IS NULL', [company, row.lead_id])).rows.map(item => item.user_id);
    assigned.push({ lead: row.lead_id, users });
    await owner.query('SELECT public.set_lead_assignees($1,$2,$3)', [company, row.lead_id, users.filter(id => id !== admin.id)]);
  }
  await db.query('UPDATE public.users SET is_active=false WHERE id=$1', [admin.id]);
  r = await rpc(admin, false);
  check(r.status === 403 && await flag(), 'Inactive Admin cannot unhide');
  await db.query('UPDATE public.users SET is_active=true WHERE id=$1', [admin.id]);
  for (const row of assigned) await owner.query('SELECT public.set_lead_assignees($1,$2,$3)', [company, row.lead, row.users]);
  // Protected hide/unhide is independent from ordinary project.edit overrides.
  r = await http('/rest/v1/rpc/set_user_permission', { token: boss.token, method: 'POST', body: { p_company: company, p_user: admin.id, p_code: 'project.edit', p_effect: 'deny' } });
  assert.equal(r.status, 204);
  r = await rpc(admin, false);
  check(r.status === 204 && !await flag(), 'Admin can unhide despite denied ordinary project.edit');
  await http('/rest/v1/rpc/set_user_permission', { token: boss.token, method: 'POST', body: { p_company: company, p_user: admin.id, p_code: 'project.edit', p_effect: null } });
  r = await http(`/rest/v1/projects?id=eq.${project}`, { token: sales.token });
  check(r.status === 200 && r.body.length === 1, 'Unhide restores existing member access');
  r = await http(`/rest/v1/notifications?event_id=eq.${event}`, { token: sales.token });
  check(r.status === 200 && r.body.length === 1, 'Unhide restores preserved historical notification');
  const after = (await db.query(`SELECT p.status,p.current_quote_version_id,p.progress_percent,f.contract_value,
    (SELECT count(*) FROM public.project_members WHERE project_id=p.id) AS members
    FROM public.projects p JOIN public.project_financials f ON f.project_id=p.id WHERE p.id=$1`, [project])).rows[0];
  check(JSON.stringify(before) === JSON.stringify(after), 'Hide/unhide preserves business state, Quote, contract and membership');
  const result = await race(db, admin.subject,
    c => c.query('SELECT public.set_project_hidden($1,$2,true)', [company, project]), accountant.subject,
    c => c.query('SELECT public.set_project_financials($1,$2,1,1)', [company, project]));
  check(result.second.error?.code === '42501', 'Financial RPC rechecks scope after waiting for concurrent hide');
  await owner.query('SELECT public.set_project_hidden($1,$2,false)', [company, project]);
}
