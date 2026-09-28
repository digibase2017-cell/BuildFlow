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
INSERT INTO public.users(id,company_id,auth_user_id,role_id,full_name,email,department)
SELECT '24000000-0000-0000-0000-000000000001',company_id,'34000000-0000-0000-0000-000000000001',id,'Quote Admin','lead-returning@example.test','Sales'
FROM public.roles WHERE company_id='14000000-0000-0000-0000-000000000001' AND code='sales';

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='34000000-0000-0000-0000-000000000001';

SELECT lives_ok($test$INSERT INTO public.leads(company_id,customer_name) VALUES ('14000000-0000-0000-0000-000000000001','Minimal insert')$test$,'Sales can create Lead without RETURNING');
RESET ROLE;
SELECT is((SELECT status FROM public.leads WHERE company_id='14000000-0000-0000-0000-000000000001' AND customer_name='Minimal insert'),'Mới','Lead defaults to the approved Mới status');
SET LOCAL ROLE authenticated;
SELECT throws_ok($test$INSERT INTO public.leads(company_id,customer_name,status) VALUES ('14000000-0000-0000-0000-000000000001','Legacy status','Đã liên hệ')$test$,'23514',NULL,'Legacy Sale status is rejected');
SELECT throws_ok($test$INSERT INTO public.leads(company_id,customer_name) VALUES ('14000000-0000-0000-0000-000000000001','Representation insert') RETURNING id$test$,'42501',NULL,'Unassigned Lead is not returned without lead.view.all');
SELECT is((SELECT count(*) FROM public.leads WHERE company_id='14000000-0000-0000-0000-000000000001'),0::bigint,'Unassigned Leads are hidden');
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
INSERT INTO public.user_permissions(company_id,user_id,permission_id,effect,granted_by)
SELECT '14000000-0000-0000-0000-000000000001','24000000-0000-0000-0000-000000000001',id,'allow','24000000-0000-0000-0000-000000000001'
FROM public.permissions WHERE code='lead.view.all';
INSERT INTO public.user_permissions(company_id,user_id,permission_id,effect,granted_by)
SELECT '14000000-0000-0000-0000-000000000001','24000000-0000-0000-0000-000000000001',id,'deny','24000000-0000-0000-0000-000000000001'
FROM public.permissions WHERE code='lead.edit';
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*) FROM public.leads WHERE company_id='14000000-0000-0000-0000-000000000001'),2::bigint,'lead.view.all sees unassigned Leads even when lead.view is denied');
WITH changed AS (UPDATE public.leads SET notes='forbidden' WHERE company_id='14000000-0000-0000-0000-000000000001' RETURNING id)
SELECT is((SELECT count(*) FROM changed),0::bigint,'lead.view.all alone cannot edit Leads');
SELECT lives_ok($test$INSERT INTO public.leads(company_id,customer_name) VALUES ('14000000-0000-0000-0000-000000000001','Visible via all') RETURNING id$test$,'lead.view.all permits INSERT RETURNING for a separately authorized creator');
RESET ROLE;
UPDATE public.user_permissions SET effect='deny' WHERE user_id='24000000-0000-0000-0000-000000000001'
 AND permission_id=(SELECT id FROM public.permissions WHERE code='lead.view.all');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*) FROM public.leads WHERE company_id='14000000-0000-0000-0000-000000000001'),0::bigint,'Denying both view permissions hides all Leads');
RESET ROLE;
UPDATE public.user_permissions SET effect='allow' WHERE user_id='24000000-0000-0000-0000-000000000001'
 AND permission_id=(SELECT id FROM public.permissions WHERE code='lead.view');
INSERT INTO public.lead_assignments(company_id,lead_id,user_id,assigned_by)
SELECT company_id,id,'24000000-0000-0000-0000-000000000001','24000000-0000-0000-0000-000000000001' FROM public.leads
WHERE company_id='14000000-0000-0000-0000-000000000001' AND customer_name='Minimal insert';
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*) FROM public.leads WHERE company_id='14000000-0000-0000-0000-000000000001'),1::bigint,'lead.view sees only the assigned Lead when lead.view.all is denied');
RESET ROLE;
INSERT INTO public.role_permissions(company_id,role_id,permission_id)
SELECT r.company_id,r.id,p.id FROM public.roles r CROSS JOIN public.permissions p
WHERE r.company_id='14000000-0000-0000-0000-000000000001' AND r.code='sales' AND p.code='lead.view.all';
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*) FROM public.leads WHERE company_id='14000000-0000-0000-0000-000000000001'),1::bigint,'User deny overrides Role grant of lead.view.all');
RESET ROLE;
DELETE FROM public.user_permissions WHERE user_id='24000000-0000-0000-0000-000000000001'
 AND permission_id=(SELECT id FROM public.permissions WHERE code='lead.view.all');
SET LOCAL ROLE authenticated;
SELECT is((SELECT count(*) FROM public.leads WHERE company_id='14000000-0000-0000-0000-000000000001'),3::bigint,'Role grant of lead.view.all reveals assigned and unassigned Leads');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
