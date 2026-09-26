-- Regression: RLS visibility for INSERT RETURNING on a newly created Lead.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = public, extensions;
SELECT no_plan();

INSERT INTO public.companies(id,name) VALUES ('14000000-0000-0000-0000-000000000001','Quote regression');
INSERT INTO public.company_subscriptions(company_id,plan_id,starts_at,expires_at,grace_ends_at,
  price_paid_vnd,max_active_users,max_projects,r2_storage_bytes)
SELECT '14000000-0000-0000-0000-000000000001',id,now()-interval '1 day',now()+interval '1 year',now()+interval '1 year 7 days',
  annual_price_vnd,max_active_users,max_projects,r2_storage_bytes FROM public.subscription_plans WHERE code='starter';
INSERT INTO auth.users(id,email) VALUES ('34000000-0000-0000-0000-000000000001','lead-returning@example.test');
INSERT INTO public.users(id,company_id,auth_user_id,role_id,full_name,email)
SELECT '24000000-0000-0000-0000-000000000001',company_id,'34000000-0000-0000-0000-000000000001',id,'Quote Admin','lead-returning@example.test'
FROM public.roles WHERE company_id='14000000-0000-0000-0000-000000000001' AND code='sales';

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='34000000-0000-0000-0000-000000000001';

SELECT lives_ok($test$INSERT INTO public.leads(company_id,customer_name) VALUES ('14000000-0000-0000-0000-000000000001','Minimal insert')$test$,'Sales can create Lead without RETURNING');
SELECT lives_ok($test$INSERT INTO public.leads(company_id,customer_name) VALUES ('14000000-0000-0000-0000-000000000001','Representation insert') RETURNING id$test$,'Sales can create Lead with RETURNING');
SELECT is((SELECT count(*) FROM public.leads WHERE company_id='14000000-0000-0000-0000-000000000001'),2::bigint,'Both newly created unassigned Leads are visible');
RESET ROLE;
SELECT ok(NOT has_function_privilege('authenticated','app_private.lead_assignment_scope(uuid,uuid)','EXECUTE'),'Assignment scope helper is not a client RPC');
INSERT INTO public.user_permissions(company_id,user_id,permission_id,effect,granted_by)
SELECT '14000000-0000-0000-0000-000000000001','24000000-0000-0000-0000-000000000001',id,'deny','24000000-0000-0000-0000-000000000001'
FROM public.permissions WHERE code='lead.view';
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*) FROM public.leads WHERE company_id='14000000-0000-0000-0000-000000000001'),0::bigint,'Deny lead.view still hides existing Leads');
SELECT lives_ok($test$INSERT INTO public.leads(company_id,customer_name) VALUES ('14000000-0000-0000-0000-000000000001','Create only')$test$,'lead.create remains independent from lead.view');
SELECT throws_ok($test$INSERT INTO public.leads(company_id,customer_name) VALUES ('14000000-0000-0000-0000-000000000001','Cannot return') RETURNING id$test$,'42501',NULL,'RETURNING does not bypass deny lead.view');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
