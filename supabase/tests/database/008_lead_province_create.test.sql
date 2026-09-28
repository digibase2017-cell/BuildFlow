BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = public, extensions;
SELECT no_plan();

INSERT INTO public.companies(id,name) VALUES ('18000000-0000-0000-0000-000000000001','Province test company');
INSERT INTO public.company_subscriptions(company_id,plan_id,starts_at,expires_at,grace_ends_at,
  price_paid_vnd,max_active_users,max_projects,r2_storage_bytes)
SELECT '18000000-0000-0000-0000-000000000001',id,now()-interval '1 day',now()+interval '1 year',now()+interval '1 year 7 days',
  annual_price_vnd,max_active_users,max_projects,r2_storage_bytes FROM public.subscription_plans WHERE code='starter';
INSERT INTO auth.users(id,email) VALUES
  ('38000000-0000-0000-0000-000000000001','province-marketing@example.test'),
  ('38000000-0000-0000-0000-000000000002','province-sales@example.test'),
  ('38000000-0000-0000-0000-000000000003','province-other@example.test');
INSERT INTO public.users(id,company_id,auth_user_id,role_id,full_name,email,department)
SELECT v.id,'18000000-0000-0000-0000-000000000001',v.auth_id,r.id,v.name,v.email,v.department
FROM (VALUES
  ('28000000-0000-0000-0000-000000000001'::uuid,'38000000-0000-0000-0000-000000000001'::uuid,'Marketing','province-marketing@example.test','Marketing','marketing'),
  ('28000000-0000-0000-0000-000000000002'::uuid,'38000000-0000-0000-0000-000000000002'::uuid,'Sale','province-sales@example.test','Sales','sales'),
  ('28000000-0000-0000-0000-000000000003'::uuid,'38000000-0000-0000-0000-000000000003'::uuid,'Office','province-other@example.test','Office','sales')
) v(id,auth_id,name,email,department,role_code)
JOIN public.roles r ON r.company_id='18000000-0000-0000-0000-000000000001' AND r.code=v.role_code;
INSERT INTO public.user_permissions(company_id,user_id,permission_id,effect,granted_by)
SELECT '18000000-0000-0000-0000-000000000001','28000000-0000-0000-0000-000000000001',id,'allow','28000000-0000-0000-0000-000000000001'
FROM public.permissions WHERE code='lead.assign';

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='38000000-0000-0000-0000-000000000001';
SELECT lives_ok($test$SELECT public.add_province_option('18000000-0000-0000-0000-000000000001','Hà Nội')$test$,
  'Marketing creator can add a company province option');
SELECT is((SELECT count(*) FROM public.lead_options WHERE company_id='18000000-0000-0000-0000-000000000001' AND kind='province' AND label='Hà Nội'),1::bigint,
  'Creator can read the shared province option under RLS');
SELECT is((SELECT count(*) FROM public.list_sale_candidates('18000000-0000-0000-0000-000000000001')),1::bigint,
  'Candidate RPC exposes only the active Sales department');
SELECT lives_ok($test$SELECT public.create_lead_with_assignees(
  '18000000-0000-0000-0000-000000000001','48000000-0000-0000-0000-000000000001',
  '{"customer_name":"Lead Hà Nội","province":"Hà Nội","execution_types":[]}'::jsonb,
  ARRAY['28000000-0000-0000-0000-000000000002']::uuid[],true)$test$,
  'Marketing with lead.assign atomically creates and assigns an unassigned Lead');
SELECT is((SELECT default_province FROM public.user_preferences WHERE company_id='18000000-0000-0000-0000-000000000001'),
  'Hà Nội','Creator reads their own saved default province');
SELECT throws_ok($test$SELECT public.create_lead_with_assignees(
  '18000000-0000-0000-0000-000000000001','48000000-0000-0000-0000-000000000002',
  '{"customer_name":"Invalid assignee"}'::jsonb,
  ARRAY['28000000-0000-0000-0000-000000000003']::uuid[],false)$test$,
  '23514',NULL,'Non-Sales assignee is rejected');
RESET ROLE;
SELECT is((SELECT count(*) FROM public.leads WHERE id='48000000-0000-0000-0000-000000000002'),0::bigint,
  'Rejected assignment rolls back Lead creation');
SELECT is((SELECT province FROM public.leads WHERE id='48000000-0000-0000-0000-000000000001'),'Hà Nội',
  'Province persists on the Lead');
SELECT is((SELECT status FROM public.leads WHERE id='48000000-0000-0000-0000-000000000001'),'Mới',
  'New Lead keeps database default Mới');
SELECT is((SELECT count(*) FROM public.lead_assignments WHERE lead_id='48000000-0000-0000-0000-000000000001' AND unassigned_at IS NULL),1::bigint,
  'Exactly one Sale was assigned');
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='38000000-0000-0000-0000-000000000002';
SELECT is((SELECT count(*) FROM public.lead_options WHERE company_id='18000000-0000-0000-0000-000000000001' AND kind='province'),1::bigint,
  'Another employee in the company sees the shared province catalog');
SELECT is((SELECT count(*) FROM public.user_preferences WHERE company_id='18000000-0000-0000-0000-000000000001'),0::bigint,
  'Another user cannot read Marketing default preference');
RESET ROLE;
UPDATE public.user_permissions SET effect='deny' WHERE user_id='28000000-0000-0000-0000-000000000001'
  AND permission_id=(SELECT id FROM public.permissions WHERE code='lead.assign');
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='38000000-0000-0000-0000-000000000001';
SELECT throws_ok($test$SELECT public.create_lead_with_assignees(
  '18000000-0000-0000-0000-000000000001','48000000-0000-0000-0000-000000000003',
  '{"customer_name":"No assign permission"}'::jsonb,
  ARRAY['28000000-0000-0000-0000-000000000002']::uuid[],false)$test$,
  '42501',NULL,'Personal deny lead.assign prevents selection');
SELECT lives_ok($test$SELECT public.create_lead_with_assignees(
  '18000000-0000-0000-0000-000000000001','48000000-0000-0000-0000-000000000004',
  '{"customer_name":"No assignee"}'::jsonb,'{}'::uuid[],false)$test$,
  'Creator can still make a Lead without assignees');
SELECT lives_ok($test$SELECT public.archive_lead_option(
  '18000000-0000-0000-0000-000000000001',
  (SELECT id FROM public.lead_options WHERE kind='province' AND label='Hà Nội'))$test$,
  'Creator can remove a province from available options without deleting its row');
SELECT is((SELECT count(*) FROM public.lead_options WHERE kind='province' AND label='Hà Nội' AND is_active),0::bigint,
  'Archived province is no longer available for selection');
RESET ROLE;
SELECT is((SELECT province FROM public.leads WHERE id='48000000-0000-0000-0000-000000000001'),'Hà Nội',
  'Archiving province preserves the existing Lead value');
SELECT * FROM finish();
ROLLBACK;
