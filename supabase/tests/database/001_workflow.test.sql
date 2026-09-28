-- Run with Supabase Local. Fixtures roll back at the end.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SET LOCAL search_path = public, extensions;

SELECT no_plan();

SELECT ok(to_regclass('public.sales') IS NULL AND to_regclass('public.sale_users') IS NULL,'No separate Sale tables');

SELECT is((SELECT count(*) FROM public.permissions WHERE true),57::bigint,'57 permission codes');

INSERT INTO public.companies(id,name) VALUES ('10000000-0000-0000-0000-000000000001','Test A'),('10000000-0000-0000-0000-000000000002','Test B');

INSERT INTO public.company_subscriptions(company_id,plan_id,starts_at,expires_at,grace_ends_at,
price_paid_vnd,max_active_users,max_projects,r2_storage_bytes)
SELECT c.id,p.id,now()-interval '1 day',now()+interval '1 year',now()+interval '1 year 7 days',
p.annual_price_vnd,p.max_active_users,p.max_projects,p.r2_storage_bytes
FROM public.companies c CROSS JOIN public.subscription_plans p
WHERE c.id IN ('10000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002') AND p.code='starter';

INSERT INTO auth.users(id,email) VALUES ('30000000-0000-0000-0000-000000000001','fixture1@example.test');

INSERT INTO public.users(id,company_id,auth_user_id,role_id,full_name,email,department) SELECT '20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001',id,'Fixture 1','fixture1@example.test','Sales' FROM public.roles WHERE company_id='10000000-0000-0000-0000-000000000001' AND code='marketing';

INSERT INTO auth.users(id,email) VALUES ('30000000-0000-0000-0000-000000000002','fixture2@example.test');

INSERT INTO public.users(id,company_id,auth_user_id,role_id,full_name,email,department) SELECT '20000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000002',id,'Fixture 2','fixture2@example.test','Sales' FROM public.roles WHERE company_id='10000000-0000-0000-0000-000000000001' AND code='sales';

INSERT INTO auth.users(id,email) VALUES ('30000000-0000-0000-0000-000000000003','fixture3@example.test');

INSERT INTO public.users(id,company_id,auth_user_id,role_id,full_name,email,department) SELECT '20000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000003',id,'Fixture 3','fixture3@example.test','Sales' FROM public.roles WHERE company_id='10000000-0000-0000-0000-000000000001' AND code='sales';

INSERT INTO auth.users(id,email) VALUES ('30000000-0000-0000-0000-000000000004','fixture4@example.test');

INSERT INTO public.users(id,company_id,auth_user_id,role_id,full_name,email,department) SELECT '20000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000004',id,'Fixture 4','fixture4@example.test','Sales' FROM public.roles WHERE company_id='10000000-0000-0000-0000-000000000001' AND code='sales';

INSERT INTO auth.users(id,email) VALUES ('30000000-0000-0000-0000-000000000005','fixture5@example.test');

INSERT INTO public.users(id,company_id,auth_user_id,role_id,full_name,email,department) SELECT '20000000-0000-0000-0000-000000000005','10000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000005',id,'Fixture 5','fixture5@example.test','Sales' FROM public.roles WHERE company_id='10000000-0000-0000-0000-000000000001' AND code='admin';

INSERT INTO auth.users(id,email) VALUES ('30000000-0000-0000-0000-000000000006','fixture6@example.test');

INSERT INTO public.users(id,company_id,auth_user_id,role_id,full_name,email,department) SELECT '20000000-0000-0000-0000-000000000006','10000000-0000-0000-0000-000000000002','30000000-0000-0000-0000-000000000006',id,'Fixture 6','fixture6@example.test','Sales' FROM public.roles WHERE company_id='10000000-0000-0000-0000-000000000002' AND code='sales';

INSERT INTO auth.users(id,email) VALUES ('30000000-0000-0000-0000-000000000007','fixture7@example.test');

INSERT INTO public.users(id,company_id,auth_user_id,role_id,full_name,email,department) SELECT '20000000-0000-0000-0000-000000000007','10000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000007',id,'Fixture 7','fixture7@example.test','Sales' FROM public.roles WHERE company_id='10000000-0000-0000-0000-000000000001' AND code='owner';

SELECT is((SELECT count(*) FROM public.roles WHERE company_id='10000000-0000-0000-0000-000000000001'),11::bigint,'11 company roles');

SELECT is((SELECT count(*) FROM public.user_permissions WHERE company_id='10000000-0000-0000-0000-000000000001'),0::bigint,'No default user overrides');

SELECT ok(NOT has_table_privilege('authenticated','public.lead_assignments','INSERT'),'Assignment table is RPC-only');

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '30000000-0000-0000-0000-000000000001';

SELECT lives_ok($test$INSERT INTO public.leads(id,company_id,customer_name) VALUES ('40000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','Customer A')$test$,'Marketing creates Lead with server number and attribution');

SELECT is((SELECT count(*) FROM public.leads WHERE id='40000000-0000-0000-0000-000000000001'),0::bigint,'Marketing cannot see unassigned Lead');

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '30000000-0000-0000-0000-000000000002';

SELECT is((SELECT count(*) FROM public.leads WHERE id='40000000-0000-0000-0000-000000000001'),0::bigint,'Sales cannot see unassigned Lead');

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '30000000-0000-0000-0000-000000000006';

SELECT lives_ok($test$INSERT INTO public.leads(id,company_id,customer_name) VALUES ('40000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000002','Customer B')$test$,'Second tenant can create its own Lead');

SELECT is((SELECT count(*) FROM public.leads WHERE id='40000000-0000-0000-0000-000000000001'),0::bigint,'Other tenant cannot see Lead A');

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '30000000-0000-0000-0000-000000000005';

SELECT lives_ok($test$SELECT public.set_user_permission('10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000004','lead.assign','allow')$test$,'Admin grants assignment to team leader');
SELECT lives_ok($test$SELECT public.set_lead_assignees('10000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001',ARRAY['20000000-0000-0000-0000-000000000004']::uuid[])$test$,'Admin assigns initial team leader');

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '30000000-0000-0000-0000-000000000004';

SELECT is((SELECT count(*) FROM public.users WHERE company_id='10000000-0000-0000-0000-000000000001'),1::bigint,'Lead assign does not grant full user directory');

SELECT is((SELECT count(*) FROM public.list_lead_assignee_candidates('10000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001')),6::bigint,'Picker includes only active users of tenant A');

SELECT lives_ok($test$SELECT public.set_lead_assignees('10000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001',ARRAY['20000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000003','20000000-0000-0000-0000-000000000004']::uuid[])$test$,'Assign two Sales and team leader atomically');

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '30000000-0000-0000-0000-000000000001';

SELECT is((SELECT count(*) FROM public.leads WHERE id='40000000-0000-0000-0000-000000000001'),0::bigint,'Creator loses access after assignment');

WITH changed AS (UPDATE public.leads SET notes='forbidden' WHERE id='40000000-0000-0000-0000-000000000001' RETURNING id)
SELECT is((SELECT count(*) FROM changed),0::bigint,'Unassigned creator cannot edit');

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '30000000-0000-0000-0000-000000000002';

SELECT is((SELECT count(*) FROM public.leads WHERE id='40000000-0000-0000-0000-000000000001'),1::bigint,'Assigned Sales can view');

SELECT lives_ok($test$UPDATE public.leads SET customer_requirements='Kitchen' WHERE id='40000000-0000-0000-0000-000000000001'$test$,'Assigned Sales updates requirements on Lead');

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '30000000-0000-0000-0000-000000000003';

SELECT is((SELECT customer_requirements FROM public.leads WHERE id='40000000-0000-0000-0000-000000000001'),'Kitchen','Peer sees same Lead information');

SELECT throws_ok($test$SELECT public.set_lead_assignees('10000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001',ARRAY['20000000-0000-0000-0000-000000000003']::uuid[])$test$,'42501',NULL,'Sales cannot assign without permission');

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '30000000-0000-0000-0000-000000000004';

SELECT throws_ok($test$SELECT public.set_lead_assignees('10000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001',ARRAY['20000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000006']::uuid[])$test$,'23514',NULL,'Foreign-tenant assignee rejected');

SELECT is((SELECT count(*) FROM public.lead_assignments WHERE lead_id='40000000-0000-0000-0000-000000000001' AND unassigned_at IS NULL),3::bigint,'Failed assignment leaves prior set intact');

SELECT lives_ok($test$SELECT public.set_lead_assignees('10000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001',ARRAY['20000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000003']::uuid[])$test$,'Team leader may remove self');

SELECT is((SELECT count(*) FROM public.leads WHERE id='40000000-0000-0000-0000-000000000001'),0::bigint,'Team leader immediately loses Lead scope');

SELECT throws_ok($test$SELECT public.set_lead_assignees('10000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001',ARRAY['20000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000003','20000000-0000-0000-0000-000000000004']::uuid[])$test$,'42501',NULL,'Lead assign alone cannot reclaim hidden Lead');

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '30000000-0000-0000-0000-000000000005';

SELECT is((SELECT count(*) FROM public.leads WHERE id='40000000-0000-0000-0000-000000000001'),1::bigint,'Admin sees assigned Lead without membership');

SELECT lives_ok($test$SELECT public.set_lead_assignees('10000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001',ARRAY[]::uuid[])$test$,'Admin clears all assignments');

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '30000000-0000-0000-0000-000000000001';

SELECT is((SELECT count(*) FROM public.leads WHERE id='40000000-0000-0000-0000-000000000001'),0::bigint,'Removing all assignees keeps Lead hidden without lead.view.all');

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '30000000-0000-0000-0000-000000000005';

SELECT lives_ok($test$SELECT public.set_lead_assignees('10000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001',ARRAY['20000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000004']::uuid[])$test$,'Admin assigns Sales and leader');

SELECT lives_ok($test$SELECT public.set_user_permission('10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000002','lead.view','deny')$test$,'Admin denies Sales view');

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '30000000-0000-0000-0000-000000000002';

SELECT is((SELECT count(*) FROM public.leads WHERE id='40000000-0000-0000-0000-000000000001'),0::bigint,'User deny wins over Role and assignment');

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '30000000-0000-0000-0000-000000000005';

SELECT lives_ok($test$SELECT public.set_user_permission('10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000002','lead.view','allow')$test$,'Admin replaces deny with allow');

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '30000000-0000-0000-0000-000000000002';

SELECT is((SELECT count(*) FROM public.leads WHERE id='40000000-0000-0000-0000-000000000001'),1::bigint,'User allow restores view within scope');

SELECT throws_ok($test$SELECT public.create_project_from_lead('10000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001','Too early')$test$,'23514',NULL,'Lead must succeed before creating Project');

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '30000000-0000-0000-0000-000000000005';

SELECT lives_ok($test$UPDATE public.leads SET status='Thành công' WHERE id='40000000-0000-0000-0000-000000000001'$test$,'Lead can become successful');

SELECT is((SELECT count(*) FROM public.projects WHERE company_id='10000000-0000-0000-0000-000000000001'),0::bigint,'Success does not automatically create Project');

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '30000000-0000-0000-0000-000000000003';

SELECT throws_ok($test$SELECT public.create_project_from_lead('10000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001','Forbidden')$test$,'42501',NULL,'Project creation cannot bypass Lead scope');

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '30000000-0000-0000-0000-000000000005';

SELECT lives_ok($test$SELECT public.create_project_from_lead('10000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001','Project A')$test$,'Explicit Project creation from Lead');

SELECT is((SELECT count(*) FROM public.project_sales WHERE company_id='10000000-0000-0000-0000-000000000001'),2::bigint,'Project Sales snapshots eligible Lead assignees');

SELECT lives_ok($test$SELECT public.set_lead_assignees('10000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001',ARRAY[]::uuid[])$test$,'Lead assignment can change after Project creation');

SELECT is((SELECT count(*) FROM public.project_sales WHERE company_id='10000000-0000-0000-0000-000000000001'),2::bigint,'Project Sales does not follow later Lead changes');

SELECT lives_ok($test$INSERT INTO public.quotes(id,company_id,lead_id,title,created_by) VALUES ('50000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001','Quote A','20000000-0000-0000-0000-000000000005')$test$,'Quote belongs directly to Lead');

SELECT lives_ok($test$INSERT INTO public.quote_versions(id,company_id,quote_id,version_number,created_by) VALUES ('60000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000001',1,'20000000-0000-0000-0000-000000000005')$test$,'Create Quote V1');

SELECT lives_ok($test$SELECT public.finalize_quote_version('10000000-0000-0000-0000-000000000001','60000000-0000-0000-0000-000000000001')$test$,'Finalize Quote V1');

SELECT lives_ok($test$INSERT INTO public.quote_versions(id,company_id,quote_id,version_number,created_by) VALUES ('60000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000001',2,'20000000-0000-0000-0000-000000000005')$test$,'Create Quote V2');

SELECT lives_ok($test$SELECT public.finalize_quote_version('10000000-0000-0000-0000-000000000001','60000000-0000-0000-0000-000000000002')$test$,'Finalize Quote V2');

SELECT lives_ok($test$SELECT public.apply_quote_version('10000000-0000-0000-0000-000000000001',(SELECT id FROM public.projects WHERE company_id='10000000-0000-0000-0000-000000000001' AND name='Project A'),'60000000-0000-0000-0000-000000000001')$test$,'Apply V1');

SELECT lives_ok($test$SELECT public.apply_quote_version('10000000-0000-0000-0000-000000000001',(SELECT id FROM public.projects WHERE company_id='10000000-0000-0000-0000-000000000001' AND name='Project A'),'60000000-0000-0000-0000-000000000002')$test$,'Apply V2');

SELECT lives_ok($test$SELECT public.apply_quote_version('10000000-0000-0000-0000-000000000001',(SELECT id FROM public.projects WHERE company_id='10000000-0000-0000-0000-000000000001' AND name='Project A'),'60000000-0000-0000-0000-000000000001')$test$,'Apply V1');

SELECT is((SELECT count(*) FROM public.project_quote_history WHERE company_id='10000000-0000-0000-0000-000000000001'),3::bigint,'V1 V2 V1 retains three applications');

SELECT is((SELECT count(*) FROM public.project_quote_history WHERE company_id='10000000-0000-0000-0000-000000000001' AND replaced_at IS NULL),1::bigint,'Exactly one active application');

SELECT is((SELECT count(*) FROM public.project_applied_quote_versions WHERE company_id='10000000-0000-0000-0000-000000000001'),2::bigint,'Registry retains both ever-applied versions');

SELECT is((SELECT current_quote_version_id FROM public.projects WHERE id=(SELECT id FROM public.projects WHERE company_id='10000000-0000-0000-0000-000000000001' AND name='Project A')),'60000000-0000-0000-0000-000000000001'::uuid,'Current version returns to V1');

SELECT lives_ok($test$SET CONSTRAINTS ALL IMMEDIATE$test$,'Deferred cross-table constraints agree after reapplication');

SET CONSTRAINTS ALL DEFERRED;

SELECT lives_ok($test$INSERT INTO public.acceptance_rounds(id,company_id,acceptance_id,project_id,round_number,round_date,result,created_by) SELECT '70000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',id,project_id,1,current_date,'Đạt','20000000-0000-0000-0000-000000000005' FROM public.project_acceptance WHERE project_id=(SELECT id FROM public.projects WHERE company_id='10000000-0000-0000-0000-000000000001' AND name='Project A')$test$,'Pass acceptance on same Project');

SELECT is((SELECT status FROM public.projects WHERE id=(SELECT id FROM public.projects WHERE company_id='10000000-0000-0000-0000-000000000001' AND name='Project A')),'Hoàn thành','Acceptance completes Project');

SELECT lives_ok($test$UPDATE public.acceptance_rounds SET result='Cần khắc phục' WHERE id='70000000-0000-0000-0000-000000000001'$test$,'Reverse latest acceptance result');

SELECT is((SELECT status FROM public.projects WHERE id=(SELECT id FROM public.projects WHERE company_id='10000000-0000-0000-0000-000000000001' AND name='Project A')),'Đang thực hiện','Reversal reopens Project');

SELECT ok((SELECT completed_date IS NULL FROM public.projects WHERE id=(SELECT id FROM public.projects WHERE company_id='10000000-0000-0000-0000-000000000001' AND name='Project A')),'Auto completion date cleared on reversal');

RESET ROLE;

SELECT throws_ok($test$INSERT INTO public.quotes(company_id,lead_id,title,created_by) VALUES ('10000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000002','Foreign Lead','20000000-0000-0000-0000-000000000005')$test$,'23503',NULL,'FK rejects foreign-tenant Lead even under privileged writer');

DELETE FROM public.role_permissions WHERE company_id='10000000-0000-0000-0000-000000000001' AND role_id=(SELECT id FROM public.roles WHERE company_id='10000000-0000-0000-0000-000000000001' AND code='sales') AND permission_id=(SELECT id FROM public.permissions WHERE code='catalog.edit');

SELECT lives_ok($test$SELECT app_private.seed_company_defaults('10000000-0000-0000-0000-000000000001')$test$,'Reseeding existing company is safe');

SELECT is((SELECT count(*) FROM public.role_permissions WHERE company_id='10000000-0000-0000-0000-000000000001' AND role_id=(SELECT id FROM public.roles WHERE company_id='10000000-0000-0000-0000-000000000001' AND code='sales') AND permission_id=(SELECT id FROM public.permissions WHERE code='catalog.edit')),0::bigint,'Reseeding does not restore revoked permission');

SELECT lives_ok($test$SET CONSTRAINTS ALL IMMEDIATE$test$,'All final deferred constraints pass');

-- Edge cases run as authenticated; only fixture activation uses postgres.
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='30000000-0000-0000-0000-000000000005';
SELECT throws_ok($test$SELECT public.set_lead_assignees('10000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001',NULL)$test$,'22023',NULL,'NULL assignment list rejected');
SELECT throws_ok($test$SELECT public.set_lead_assignees('10000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001',ARRAY[NULL]::uuid[])$test$,'22023',NULL,'NULL assignee rejected');
SELECT lives_ok($test$SELECT public.set_lead_assignees('10000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001',ARRAY['20000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000002']::uuid[])$test$,'Duplicate assignee IDs accepted as a set');
SELECT is((SELECT count(*) FROM public.lead_assignments WHERE lead_id='40000000-0000-0000-0000-000000000001' AND unassigned_at IS NULL),1::bigint,'Duplicate IDs create only one open assignment');
SELECT throws_ok($test$SELECT public.assign_user_role('10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000002',(SELECT id FROM public.roles WHERE company_id='10000000-0000-0000-0000-000000000001' AND code='admin'))$test$,'42501',NULL,'Admin cannot promote a regular user to Admin');
SELECT throws_ok($test$SELECT public.set_user_permission('10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000007','lead.edit','deny')$test$,'42501',NULL,'Admin cannot override Owner permissions');
RESET ROLE;
UPDATE public.users SET is_active=false WHERE id='20000000-0000-0000-0000-000000000003';
SET LOCAL ROLE authenticated;
SELECT throws_ok($test$SELECT public.set_lead_assignees('10000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001',ARRAY['20000000-0000-0000-0000-000000000003']::uuid[])$test$,'23514',NULL,'Inactive assignee rejected');
SELECT is((SELECT count(*) FROM public.lead_assignments WHERE lead_id='40000000-0000-0000-0000-000000000001' AND unassigned_at IS NULL AND user_id='20000000-0000-0000-0000-000000000002'),1::bigint,'Rejected inactive assignee preserves existing assignment');
SET LOCAL request.jwt.claim.sub='30000000-0000-0000-0000-000000000003';
SELECT is((SELECT count(*) FROM public.leads WHERE company_id='10000000-0000-0000-0000-000000000001'),0::bigint,'Inactive user cannot read business data');
SELECT throws_ok($test$INSERT INTO public.leads(company_id,customer_name) VALUES ('10000000-0000-0000-0000-000000000001','Inactive writer')$test$,'42501',NULL,'Inactive user cannot create a Lead');
RESET ROLE;

-- Grace and lockout still apply to administrators.
UPDATE public.company_subscriptions SET expires_at=now()-interval '1 hour',
  grace_ends_at=now()+interval '7 days' WHERE company_id='10000000-0000-0000-0000-000000000001';
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='30000000-0000-0000-0000-000000000005';
SELECT is((SELECT count(*) FROM public.leads WHERE id='40000000-0000-0000-0000-000000000001'),1::bigint,'Admin may read during grace');
SELECT throws_ok($test$SELECT public.set_lead_assignees('10000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001','{}'::uuid[])$test$,'42501',NULL,'Grace blocks writes even for Admin');
RESET ROLE;
UPDATE public.company_subscriptions SET grace_ends_at=now()-interval '1 minute'
  WHERE company_id='10000000-0000-0000-0000-000000000001';
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*) FROM public.leads WHERE company_id='10000000-0000-0000-0000-000000000001'),0::bigint,'Expired grace locks Admin business reads');
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
