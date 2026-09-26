BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions;
SELECT no_plan();
INSERT INTO public.companies(id,name) VALUES
 ('16000000-0000-0000-0000-000000000001','Lead fields A'),
 ('16000000-0000-0000-0000-000000000002','Lead fields B');
INSERT INTO public.company_subscriptions(company_id,plan_id,starts_at,expires_at,grace_ends_at,price_paid_vnd,max_active_users,max_projects,r2_storage_bytes)
SELECT c.id,p.id,now()-interval '1 day',now()+interval '1 year',now()+interval '1 year 7 days',p.annual_price_vnd,p.max_active_users,p.max_projects,p.r2_storage_bytes
FROM public.companies c CROSS JOIN public.subscription_plans p WHERE c.id IN
 ('16000000-0000-0000-0000-000000000001','16000000-0000-0000-0000-000000000002') AND p.code='starter';
INSERT INTO auth.users(id,email) VALUES
 ('36000000-0000-0000-0000-000000000001','lead-fields-admin@example.test'),
 ('36000000-0000-0000-0000-000000000002','lead-fields-sales@example.test'),
 ('36000000-0000-0000-0000-000000000003','lead-fields-other@example.test'),
 ('36000000-0000-0000-0000-000000000004','lead-fields-designer@example.test'),
 ('36000000-0000-0000-0000-000000000005','lead-fields-marketing@example.test');
INSERT INTO public.users(id,company_id,auth_user_id,role_id,full_name,email)
SELECT x.user_id,x.company_id,x.auth_id,r.id,x.name,x.email FROM (VALUES
 ('26000000-0000-0000-0000-000000000001'::uuid,'16000000-0000-0000-0000-000000000001'::uuid,'36000000-0000-0000-0000-000000000001'::uuid,'admin','Admin A','lead-fields-admin@example.test'),
 ('26000000-0000-0000-0000-000000000002'::uuid,'16000000-0000-0000-0000-000000000001'::uuid,'36000000-0000-0000-0000-000000000002'::uuid,'sales','Sales A','lead-fields-sales@example.test'),
 ('26000000-0000-0000-0000-000000000003'::uuid,'16000000-0000-0000-0000-000000000002'::uuid,'36000000-0000-0000-0000-000000000003'::uuid,'admin','Admin B','lead-fields-other@example.test'),
 ('26000000-0000-0000-0000-000000000004'::uuid,'16000000-0000-0000-0000-000000000001'::uuid,'36000000-0000-0000-0000-000000000004'::uuid,'designer','Designer A','lead-fields-designer@example.test'),
 ('26000000-0000-0000-0000-000000000005'::uuid,'16000000-0000-0000-0000-000000000001'::uuid,'36000000-0000-0000-0000-000000000005'::uuid,'marketing','Marketing A','lead-fields-marketing@example.test')
) x(user_id,company_id,auth_id,role_code,name,email)
JOIN public.roles r ON r.company_id=x.company_id AND r.code=x.role_code;
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='36000000-0000-0000-0000-000000000001';
SELECT ok((public.my_capabilities('16000000-0000-0000-0000-000000000001')->'permissions') ? 'lead.create','Self capability RPC includes effective Lead permission');
SELECT throws_ok($sql$SELECT public.my_capabilities('16000000-0000-0000-0000-000000000002')$sql$,'42501',NULL,'Self capability RPC rejects other tenant');
SELECT is((SELECT count(*) FROM public.lead_options WHERE company_id='16000000-0000-0000-0000-000000000001' AND is_active),7::bigint,'Company receives seven initial work/building options');
SELECT ok(NOT has_table_privilege('authenticated','public.lead_options','DELETE'),'No client hard delete of options');
SELECT public.add_lead_option('16000000-0000-0000-0000-000000000001','source','Facebook');
SELECT public.add_lead_option('16000000-0000-0000-0000-000000000001','failure_reason','Giá không phù hợp');
SELECT throws_ok($sql$INSERT INTO public.leads(company_id,customer_name,status) VALUES('16000000-0000-0000-0000-000000000001','No reason','Thất bại')$sql$,'23514',NULL,'Failed Lead requires reason');
INSERT INTO public.leads(id,company_id,customer_name,source,source_2,source_3,execution_types,building_type,budget,status,failure_reason)
VALUES('46000000-0000-0000-0000-000000000001','16000000-0000-0000-0000-000000000001','Client A','Facebook','Ad campaign 1','ad-123',ARRAY['Thiết kế'],'Nhà hàng',100000000,'Thất bại','Giá không phù hợp');
SELECT is((SELECT source_3 FROM public.leads WHERE id='46000000-0000-0000-0000-000000000001'),'ad-123','Lead stores detailed source ID');
SELECT is((SELECT budget FROM public.leads WHERE id='46000000-0000-0000-0000-000000000001'),100000000::numeric,'Lead budget is manually stored');
SELECT is((SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='leads' AND column_name IN ('estimated_budget','actual_budget')),0::bigint,'Lead has no estimated or actual budget columns');
SELECT throws_ok($sql$UPDATE public.leads SET execution_types=ARRAY['Thiết kế','Thiết kế'] WHERE id='46000000-0000-0000-0000-000000000001'$sql$,'23514',NULL,'Duplicate execution types rejected');
SELECT throws_ok($sql$UPDATE public.leads SET building_type='Biệt thự' WHERE id='46000000-0000-0000-0000-000000000001'$sql$,'23514',NULL,'Unapproved option rejected');
SELECT throws_ok($sql$SELECT public.add_lead_option('16000000-0000-0000-0000-000000000002','failure_reason','Injected')$sql$,'42501',NULL,'Cannot add option in other tenant');
SELECT public.archive_lead_option('16000000-0000-0000-0000-000000000001',
 (SELECT id FROM public.lead_options WHERE company_id='16000000-0000-0000-0000-000000000001' AND kind='failure_reason' AND label='Giá không phù hợp'));
SELECT is((SELECT failure_reason FROM public.leads WHERE id='46000000-0000-0000-0000-000000000001'),'Giá không phù hợp','Archived reason remains on old Lead');
UPDATE public.leads SET notes='Updated after archive' WHERE id='46000000-0000-0000-0000-000000000001';
SELECT throws_ok($sql$INSERT INTO public.leads(company_id,customer_name,status,failure_reason) VALUES('16000000-0000-0000-0000-000000000001','New after archive','Thất bại','Giá không phù hợp')$sql$,'23514',NULL,'Archived reason unavailable to new Lead');
UPDATE public.leads SET status='Thành công' WHERE id='46000000-0000-0000-0000-000000000001';
SELECT public.create_project_from_lead('16000000-0000-0000-0000-000000000001','46000000-0000-0000-0000-000000000001','Project A') AS project_id \gset
SELECT is((SELECT building_type FROM public.projects WHERE id=:'project_id'),'Nhà hàng','Project inherits building type');
SELECT is((SELECT execution_types FROM public.projects WHERE id=:'project_id'),ARRAY['Thiết kế']::text[],'Project inherits multi-select work type');
UPDATE public.leads SET execution_types=ARRAY['Thi công'] WHERE id='46000000-0000-0000-0000-000000000001';
SELECT is((SELECT execution_types FROM public.projects WHERE id=:'project_id'),ARRAY['Thiết kế']::text[],'Project selection remains independent of Lead');
SELECT public.set_project_budget('16000000-0000-0000-0000-000000000001',:'project_id',90000000);
SELECT is((SELECT budget FROM public.project_financials WHERE project_id=:'project_id'),90000000::numeric,'Project budget stored independently');
SELECT is((SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='project_financials' AND column_name='actual_budget'),0::bigint,'Project has no actual budget column');
SET LOCAL request.jwt.claim.sub='36000000-0000-0000-0000-000000000002';
SELECT ok((public.my_capabilities('16000000-0000-0000-0000-000000000001')->'permissions') ? 'project.create','Sales retains default Project create permission');
SELECT is((SELECT count(*) FROM public.lead_options WHERE company_id='16000000-0000-0000-0000-000000000002'),0::bigint,'Sales cannot read options from another tenant');
SELECT public.set_project_budget('16000000-0000-0000-0000-000000000001',:'project_id',75000000);
SELECT is((SELECT budget FROM public.lead_project_budgets('16000000-0000-0000-0000-000000000001','46000000-0000-0000-0000-000000000001') WHERE project_id=:'project_id'),75000000::numeric,'Sales may edit and read linked Project budget without financial.view');
SELECT throws_ok(format('SELECT public.set_project_budget(%L,%L,%s)','16000000-0000-0000-0000-000000000002',:'project_id',1),'42501',NULL,'Sales cannot change another tenant Project budget');
SET LOCAL request.jwt.claim.sub='36000000-0000-0000-0000-000000000005';
SELECT ok(NOT ((public.my_capabilities('16000000-0000-0000-0000-000000000001')->'permissions') ? 'financial.view'),'Marketing still lacks financial.view');
SELECT public.set_project_budget('16000000-0000-0000-0000-000000000001',:'project_id',70000000);
SELECT is((SELECT budget FROM public.lead_project_budgets('16000000-0000-0000-0000-000000000001','46000000-0000-0000-0000-000000000001') WHERE project_id=:'project_id'),70000000::numeric,'Marketing may enter linked Project budget from Lead scope');
SELECT is((SELECT count(*) FROM public.project_financials WHERE project_id=:'project_id'),0::bigint,'Marketing still cannot select full financial row');
SET LOCAL request.jwt.claim.sub='36000000-0000-0000-0000-000000000004';
SELECT is((SELECT count(*) FROM public.lead_options WHERE kind='failure_reason'),0::bigint,'Project-only Designer cannot read Lead failure reasons');
SELECT is((SELECT count(*) FROM public.lead_options WHERE kind='building_type'),4::bigint,'Project-only Designer can read building options');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
