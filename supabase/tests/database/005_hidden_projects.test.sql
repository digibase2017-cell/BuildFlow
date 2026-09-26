-- Hidden Projects are protected, reversible and still consume quota.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = public, extensions;
SELECT no_plan();

INSERT INTO public.companies(id,name) VALUES ('15000000-0000-0000-0000-000000000001','Quote regression');
INSERT INTO public.company_subscriptions(company_id,plan_id,starts_at,expires_at,grace_ends_at,
  price_paid_vnd,max_active_users,max_projects,r2_storage_bytes)
SELECT '15000000-0000-0000-0000-000000000001',id,now()-interval '1 day',now()+interval '1 year',now()+interval '1 year 7 days',
  annual_price_vnd,max_active_users,max_projects,r2_storage_bytes FROM public.subscription_plans WHERE code='starter';
INSERT INTO auth.users(id,email) VALUES ('35000000-0000-0000-0000-000000000001','hidden-project@example.test');
INSERT INTO public.users(id,company_id,auth_user_id,role_id,full_name,email)
SELECT '25000000-0000-0000-0000-000000000001',company_id,'35000000-0000-0000-0000-000000000001',id,'Quote Admin','hidden-project@example.test'
FROM public.roles WHERE company_id='15000000-0000-0000-0000-000000000001' AND code='admin';


INSERT INTO auth.users(id,email) VALUES ('35000000-0000-0000-0000-000000000002','hidden-member@example.test');
INSERT INTO public.users(id,company_id,auth_user_id,role_id,full_name,email)
SELECT '25000000-0000-0000-0000-000000000002',company_id,'35000000-0000-0000-0000-000000000002',id,'Member','hidden-member@example.test'
FROM public.roles WHERE company_id='15000000-0000-0000-0000-000000000001' AND code='project_manager';
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='35000000-0000-0000-0000-000000000001';
INSERT INTO public.leads(id,company_id,customer_name,status) VALUES ('45000000-0000-0000-0000-000000000001','15000000-0000-0000-0000-000000000001','Hidden source','Thành công');
SELECT public.create_project_from_lead('15000000-0000-0000-0000-000000000001','45000000-0000-0000-0000-000000000001','Hidden regression') AS project_id \gset
INSERT INTO public.project_members(company_id,project_id,user_id) VALUES ('15000000-0000-0000-0000-000000000001',:'project_id','25000000-0000-0000-0000-000000000002');
SELECT ok(NOT (SELECT is_hidden FROM public.projects WHERE id=:'project_id'),'New Project is visible by default');
SELECT is((SELECT count(*) FROM public.permissions WHERE code='project.delete'),0::bigint,'No project.delete permission');
SELECT ok(NOT has_table_privilege('authenticated','public.projects','DELETE'),'No direct client Project deletion');
SELECT throws_ok($test$UPDATE public.projects SET is_hidden=true WHERE name='Hidden regression'$test$,'42501',NULL,'Admin cannot bypass guarded hide RPC with direct UPDATE');
SET LOCAL request.jwt.claim.sub='35000000-0000-0000-0000-000000000002';
SELECT is((SELECT count(*) FROM public.projects WHERE id=:'project_id'),1::bigint,'Member sees visible Project');
SELECT throws_ok(format('SELECT public.set_project_hidden(%L,%L,true)','15000000-0000-0000-0000-000000000001',:'project_id'),'42501',NULL,'Project Manager cannot hide');
SET LOCAL request.jwt.claim.sub='35000000-0000-0000-0000-000000000001';
SELECT lives_ok(format('SELECT public.set_project_hidden(%L,%L,true)','15000000-0000-0000-0000-000000000001',:'project_id'),'Admin can hide');
SELECT ok((SELECT is_hidden FROM public.projects WHERE id=:'project_id'),'Admin still sees hidden Project');
SELECT lives_ok(format('SELECT public.set_project_hidden(%L,%L,true)','15000000-0000-0000-0000-000000000001',:'project_id'),'Repeated hide is idempotent');
SELECT is((SELECT count(*) FROM public.activity_logs WHERE project_id=:'project_id' AND action='project.hidden'),1::bigint,'Hide records one audit event with no duplicate for no-op');
SET LOCAL request.jwt.claim.sub='35000000-0000-0000-0000-000000000002';
SELECT is((SELECT count(*) FROM public.projects WHERE id=:'project_id'),0::bigint,'Hidden Project disappears for member');
SELECT is((SELECT count(*) FROM public.project_members WHERE project_id=:'project_id'),0::bigint,'Hidden membership is not exposed');
SELECT is((SELECT count(*) FROM public.project_acceptance WHERE project_id=:'project_id'),0::bigint,'Hidden acceptance is not exposed');
SELECT throws_ok(format('SELECT public.set_project_hidden(%L,%L,false)','15000000-0000-0000-0000-000000000001',:'project_id'),'42501',NULL,'Member cannot unhide');
RESET ROLE;
UPDATE public.company_subscriptions SET max_projects=1 WHERE company_id='15000000-0000-0000-0000-000000000001';
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='35000000-0000-0000-0000-000000000001';
SELECT throws_ok($test$SELECT public.create_project_from_lead('15000000-0000-0000-0000-000000000001','45000000-0000-0000-0000-000000000001','Over quota')$test$,'23514',NULL,'Hidden Project still consumes quota');
SELECT lives_ok(format('SELECT public.set_project_hidden(%L,%L,false)','15000000-0000-0000-0000-000000000001',:'project_id'),'Admin can unhide');
SET LOCAL request.jwt.claim.sub='35000000-0000-0000-0000-000000000002';
SELECT is((SELECT count(*) FROM public.projects WHERE id=:'project_id'),1::bigint,'Unhide restores existing member visibility');
RESET ROLE;
SET CONSTRAINTS ALL IMMEDIATE;
SELECT * FROM finish();
ROLLBACK;
