BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions;
SELECT no_plan();

INSERT INTO public.companies(id,name) VALUES
 ('19000000-0000-0000-0000-000000000001','Lead detail A'),
 ('19000000-0000-0000-0000-000000000002','Lead detail B');
INSERT INTO public.company_subscriptions(company_id,plan_id,starts_at,expires_at,grace_ends_at,
 price_paid_vnd,max_active_users,max_projects,r2_storage_bytes)
SELECT c.id,p.id,now()-interval '1 day',now()+interval '1 year',now()+interval '1 year 7 days',
 p.annual_price_vnd,p.max_active_users,p.max_projects,p.r2_storage_bytes
FROM public.companies c CROSS JOIN public.subscription_plans p
WHERE c.id IN ('19000000-0000-0000-0000-000000000001','19000000-0000-0000-0000-000000000002') AND p.code='starter';
INSERT INTO auth.users(id,email) VALUES
 ('39000000-0000-0000-0000-000000000001','detail-owner@example.test'),
 ('39000000-0000-0000-0000-000000000002','detail-sale-a@example.test'),
 ('39000000-0000-0000-0000-000000000003','detail-sale-b@example.test'),
 ('39000000-0000-0000-0000-000000000004','detail-marketing@example.test'),
 ('39000000-0000-0000-0000-000000000005','detail-owner-b@example.test');
INSERT INTO public.users(id,company_id,auth_user_id,role_id,full_name,email,department)
SELECT x.user_id,x.company_id,x.auth_id,r.id,x.name,x.email,x.department
FROM (VALUES
 ('29000000-0000-0000-0000-000000000001'::uuid,'19000000-0000-0000-0000-000000000001'::uuid,'39000000-0000-0000-0000-000000000001'::uuid,'owner','Owner A','detail-owner@example.test','Sales'),
 ('29000000-0000-0000-0000-000000000002'::uuid,'19000000-0000-0000-0000-000000000001'::uuid,'39000000-0000-0000-0000-000000000002'::uuid,'sales','Sale A','detail-sale-a@example.test','Sales'),
 ('29000000-0000-0000-0000-000000000003'::uuid,'19000000-0000-0000-0000-000000000001'::uuid,'39000000-0000-0000-0000-000000000003'::uuid,'sales','Sale B','detail-sale-b@example.test','Sales'),
 ('29000000-0000-0000-0000-000000000004'::uuid,'19000000-0000-0000-0000-000000000001'::uuid,'39000000-0000-0000-0000-000000000004'::uuid,'marketing','Marketing','detail-marketing@example.test','Marketing'),
 ('29000000-0000-0000-0000-000000000005'::uuid,'19000000-0000-0000-0000-000000000002'::uuid,'39000000-0000-0000-0000-000000000005'::uuid,'owner','Owner B','detail-owner-b@example.test','Sales')
) x(user_id,company_id,auth_id,role_code,name,email,department)
JOIN public.roles r ON r.company_id=x.company_id AND r.code=x.role_code;

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='39000000-0000-0000-0000-000000000001';
INSERT INTO public.leads(id,company_id,customer_name) VALUES
 ('49000000-0000-0000-0000-000000000001','19000000-0000-0000-0000-000000000001','Khách A');
SELECT lives_ok($sql$SELECT public.set_lead_assignees(
 '19000000-0000-0000-0000-000000000001','49000000-0000-0000-0000-000000000001',
 ARRAY['29000000-0000-0000-0000-000000000002']::uuid[])$sql$,'Owner assigns an active Sale');

SET LOCAL request.jwt.claim.sub='39000000-0000-0000-0000-000000000002';
SELECT lives_ok($sql$INSERT INTO public.lead_care_activities
 (id,company_id,lead_id,content,created_by,created_at) VALUES
 ('59000000-0000-0000-0000-000000000001','19000000-0000-0000-0000-000000000001',
 '49000000-0000-0000-0000-000000000001','  Đã gọi khách\nHẹn gặp  ',
 '29000000-0000-0000-0000-000000000001','2000-01-01')$sql$,
 'Assigned Sale with lead.edit creates care despite spoofed attribution');
SELECT is((SELECT created_by FROM public.lead_care_activities WHERE id='59000000-0000-0000-0000-000000000001'),
 '29000000-0000-0000-0000-000000000002'::uuid,'Care creator is the JWT actor');
SELECT ok((SELECT created_at>now()-interval '1 minute' FROM public.lead_care_activities
 WHERE id='59000000-0000-0000-0000-000000000001'),'Care time is set by database');
SELECT is((SELECT content FROM public.lead_care_activities WHERE id='59000000-0000-0000-0000-000000000001'),
 'Đã gọi khách\nHẹn gặp','Care trims only outer whitespace');
SELECT throws_ok($sql$INSERT INTO public.lead_care_activities(company_id,lead_id,content) VALUES
 ('19000000-0000-0000-0000-000000000001','49000000-0000-0000-0000-000000000001','   ')$sql$,
 '23514',NULL,'Whitespace-only care is rejected');
SELECT throws_ok($sql$UPDATE public.lead_care_activities SET content='Changed' WHERE id='59000000-0000-0000-0000-000000000001'$sql$,
 '42501',NULL,'Care UPDATE is not granted');
SELECT is((SELECT count(*) FROM public.lead_care_activities WHERE lead_id='49000000-0000-0000-0000-000000000001'),
 1::bigint,'Assigned Sale reads care');
SELECT is(public.get_lead_creator_name('19000000-0000-0000-0000-000000000001',
 '49000000-0000-0000-0000-000000000001'),'Owner A',
 'Assigned Sale reads creator name without user.view');

SET LOCAL request.jwt.claim.sub='39000000-0000-0000-0000-000000000003';
SELECT is((SELECT count(*) FROM public.lead_care_activities WHERE lead_id='49000000-0000-0000-0000-000000000001'),
 0::bigint,'Unassigned Sale cannot read care');
SELECT throws_ok($sql$INSERT INTO public.lead_care_activities(company_id,lead_id,content) VALUES
 ('19000000-0000-0000-0000-000000000001','49000000-0000-0000-0000-000000000001','No access')$sql$,
 '42501',NULL,'Lead edit without Lead visibility cannot create care');
RESET ROLE;
INSERT INTO public.user_permissions(company_id,user_id,permission_id,effect,granted_by)
SELECT '19000000-0000-0000-0000-000000000001','29000000-0000-0000-0000-000000000003',id,'allow',
 '29000000-0000-0000-0000-000000000001' FROM public.permissions WHERE code IN ('lead.view.all','lead.assign');
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='39000000-0000-0000-0000-000000000003';
SELECT is((SELECT count(*) FROM public.lead_care_activities WHERE lead_id='49000000-0000-0000-0000-000000000001'),
 1::bigint,'lead.view.all reads assigned Lead care');
SELECT is((SELECT count(*) FROM public.lead_assignments WHERE lead_id='49000000-0000-0000-0000-000000000001'),
 1::bigint,'lead.view.all reads assignment rows');
SELECT throws_ok($sql$INSERT INTO public.lead_care_activities(company_id,lead_id,content) VALUES
 ('19000000-0000-0000-0000-000000000001','49000000-0000-0000-0000-000000000001','View all only')$sql$,
 '42501',NULL,'view-all and lead.edit without write scope cannot create care');
SELECT lives_ok($sql$SELECT public.set_lead_assignees(
 '19000000-0000-0000-0000-000000000001','49000000-0000-0000-0000-000000000001',
 ARRAY['29000000-0000-0000-0000-000000000002','29000000-0000-0000-0000-000000000003']::uuid[])$sql$,
 'view-all plus lead.assign may add another Sale');
SELECT is((SELECT count(*) FROM public.get_lead_history(
 '19000000-0000-0000-0000-000000000001','49000000-0000-0000-0000-000000000001')
 WHERE action_code='lead.assignee_added'),2::bigint,'Assignment History has one event per added Sale');
SELECT is((SELECT count(*) FROM public.activity_logs WHERE entity_id='49000000-0000-0000-0000-000000000001'),
 0::bigint,'General activity_logs SELECT remains hidden from Sale');
WITH removed AS (DELETE FROM public.lead_care_activities WHERE id='59000000-0000-0000-0000-000000000001' RETURNING id)
SELECT is((SELECT count(*) FROM removed),0::bigint,'Another Sale cannot delete creator activity');

SET LOCAL request.jwt.claim.sub='39000000-0000-0000-0000-000000000002';
WITH removed AS (DELETE FROM public.lead_care_activities WHERE id='59000000-0000-0000-0000-000000000001' RETURNING id)
SELECT is((SELECT count(*) FROM removed),1::bigint,'Creator deletes own care during Vietnam day');
INSERT INTO public.lead_care_activities(id,company_id,lead_id,content)
VALUES('59000000-0000-0000-0000-000000000002','19000000-0000-0000-0000-000000000001',
 '49000000-0000-0000-0000-000000000001','Old activity');
RESET ROLE;
UPDATE public.lead_care_activities SET created_at=clock_timestamp()-interval '1 day'
 WHERE id='59000000-0000-0000-0000-000000000002';
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='39000000-0000-0000-0000-000000000002';
WITH removed AS (DELETE FROM public.lead_care_activities WHERE id='59000000-0000-0000-0000-000000000002' RETURNING id)
SELECT is((SELECT count(*) FROM removed),0::bigint,'Creator cannot delete care from prior Vietnam day');
SELECT ok(app_private.care_same_vietnam_day('2026-09-28 16:59:59+00','2026-09-28 16:59:59+00'),
 'At 23:59:59 Vietnam time deletion is within the day');
SELECT ok(NOT app_private.care_same_vietnam_day('2026-09-28 16:59:59+00','2026-09-28 17:00:00+00'),
 'At 00:00:00 Vietnam time deletion is outside the day');

SET LOCAL request.jwt.claim.sub='39000000-0000-0000-0000-000000000005';
SELECT is((SELECT count(*) FROM public.lead_care_activities WHERE lead_id='49000000-0000-0000-0000-000000000001'),
 0::bigint,'Other tenant cannot read Lead care');
SELECT throws_ok($sql$INSERT INTO public.lead_care_activities(company_id,lead_id,content) VALUES
 ('19000000-0000-0000-0000-000000000001','49000000-0000-0000-0000-000000000001','Cross company')$sql$,
 '42501',NULL,'Other tenant cannot create Lead care');

SET LOCAL request.jwt.claim.sub='39000000-0000-0000-0000-000000000001';
SELECT throws_ok($sql$SELECT public.set_lead_assignees(
 '19000000-0000-0000-0000-000000000001','49000000-0000-0000-0000-000000000001',
 ARRAY['29000000-0000-0000-0000-000000000004']::uuid[])$sql$,
 '23514',NULL,'RPC rejects Marketing department');
SELECT throws_ok($sql$INSERT INTO public.lead_assignments(company_id,lead_id,user_id,assigned_by) VALUES
 ('19000000-0000-0000-0000-000000000001','49000000-0000-0000-0000-000000000001',
 '29000000-0000-0000-0000-000000000004','29000000-0000-0000-0000-000000000001')$sql$,
 '42501',NULL,'Client cannot directly INSERT assignment');
RESET ROLE;
SELECT throws_ok($sql$INSERT INTO public.lead_assignments(company_id,lead_id,user_id,assigned_by) VALUES
 ('19000000-0000-0000-0000-000000000001','49000000-0000-0000-0000-000000000001',
 '29000000-0000-0000-0000-000000000004','29000000-0000-0000-0000-000000000001')$sql$,
 '23514',NULL,'Trigger rejects privileged non-Sales assignment');
SELECT throws_ok($sql$UPDATE public.users SET department='Marketing'
 WHERE id='29000000-0000-0000-0000-000000000002'$sql$,
 '23514',NULL,'Cannot move assigned Sale out of Sales department');

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='39000000-0000-0000-0000-000000000001';
SELECT public.add_lead_option('19000000-0000-0000-0000-000000000001','source','Facebook');
SELECT public.add_lead_option('19000000-0000-0000-0000-000000000001','failure_reason','Giá cao');
SELECT public.add_province_option('19000000-0000-0000-0000-000000000001','Hà Nội');
UPDATE public.leads SET customer_name='Khách B',phone='0912',email='a@example.test',zalo='Zalo A',
 address='123 phố',province='Hà Nội',source='Facebook',source_2='Chiến dịch',source_3='ID 12',
 execution_types=ARRAY['Thiết kế'],building_type='Nhà đất',budget=1000000,
 customer_requirements='Thiết kế nhà',notes='Ưu tiên',status='Thất bại',failure_reason='Giá cao'
WHERE id='49000000-0000-0000-0000-000000000001';
SELECT is((SELECT count(*) FROM public.get_lead_history(
 '19000000-0000-0000-0000-000000000001','49000000-0000-0000-0000-000000000001')
 WHERE action_code IN ('lead.customer_name_changed','lead.contact_changed','lead.address_changed',
 'lead.source_changed','lead.type_changed','lead.budget_changed',
 'lead.requirements_changed','lead.status_changed','lead.failure_reason_changed')),
 9::bigint,'One Lead update creates exactly nine field-group events');
SELECT is((SELECT new_value->>'phone' FROM public.get_lead_history(
 '19000000-0000-0000-0000-000000000001','49000000-0000-0000-0000-000000000001')
 WHERE action_code='lead.contact_changed'),'0912','History includes changed new phone');
SELECT ok((SELECT old_value ? 'phone' AND NOT old_value ? 'address' FROM public.get_lead_history(
 '19000000-0000-0000-0000-000000000001','49000000-0000-0000-0000-000000000001')
 WHERE action_code='lead.contact_changed'),'Contact history excludes other groups');
SELECT is((SELECT count(*) FROM public.get_lead_history(
 '19000000-0000-0000-0000-000000000001','49000000-0000-0000-0000-000000000001')
 WHERE action_code='lead.status_changed'),1::bigint,'Status audit is not duplicated');
SELECT is((SELECT actor_name FROM public.get_lead_history(
 '19000000-0000-0000-0000-000000000001','49000000-0000-0000-0000-000000000001')
 WHERE action_code='lead.customer_name_changed'),'Owner A','History captures actor name');
RESET ROLE;
UPDATE public.users SET full_name='Renamed Owner' WHERE id='29000000-0000-0000-0000-000000000001';
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='39000000-0000-0000-0000-000000000001';
SELECT is((SELECT actor_name FROM public.get_lead_history(
 '19000000-0000-0000-0000-000000000001','49000000-0000-0000-0000-000000000001')
 WHERE action_code='lead.customer_name_changed'),'Owner A','Actor snapshot survives user rename');
SELECT lives_ok($sql$UPDATE public.leads SET customer_name=customer_name
 WHERE id='49000000-0000-0000-0000-000000000001'$sql$,'No-op Lead update succeeds');
SELECT is((SELECT count(*) FROM public.get_lead_history(
 '19000000-0000-0000-0000-000000000001','49000000-0000-0000-0000-000000000001')
 WHERE action_code='lead.customer_name_changed'),1::bigint,'No-op does not add History');
SELECT throws_ok($sql$UPDATE public.leads SET customer_name=' '
 WHERE id='49000000-0000-0000-0000-000000000001'$sql$,
 '23514',NULL,'Invalid Lead update rolls back');
SELECT is((SELECT count(*) FROM public.get_lead_history(
 '19000000-0000-0000-0000-000000000001','49000000-0000-0000-0000-000000000001')
 WHERE action_code='lead.customer_name_changed'),1::bigint,'Rolled-back update leaves no History');

INSERT INTO public.quotes(id,company_id,lead_id,title) VALUES
 ('69000000-0000-0000-0000-000000000001','19000000-0000-0000-0000-000000000001',
 '49000000-0000-0000-0000-000000000001','BG 1');
INSERT INTO public.quote_versions(id,company_id,quote_id,version_number) VALUES
 ('79000000-0000-0000-0000-000000000001','19000000-0000-0000-0000-000000000001',
 '69000000-0000-0000-0000-000000000001',1);
SELECT public.clone_quote_version('19000000-0000-0000-0000-000000000001',
 '79000000-0000-0000-0000-000000000001') AS v2 \gset
SELECT public.clone_quote_version('19000000-0000-0000-0000-000000000001',:'v2') AS v3 \gset
INSERT INTO public.quotes(id,company_id,lead_id,title) VALUES
 ('69000000-0000-0000-0000-000000000002','19000000-0000-0000-0000-000000000001',
 '49000000-0000-0000-0000-000000000001','BG 2');
INSERT INTO public.quote_versions(id,company_id,quote_id,version_number) VALUES
 ('79000000-0000-0000-0000-000000000002','19000000-0000-0000-0000-000000000001',
 '69000000-0000-0000-0000-000000000002',1);
SELECT public.clone_quote_version('19000000-0000-0000-0000-000000000001',
 '79000000-0000-0000-0000-000000000002') AS bg2v2 \gset
SELECT is((SELECT count(*) FROM public.get_lead_history(
 '19000000-0000-0000-0000-000000000001','49000000-0000-0000-0000-000000000001')
 WHERE action_code='lead.quote_created'),2::bigint,'Each Quote V1 creates a new Quote history event');
SELECT is((SELECT count(*) FROM public.get_lead_history(
 '19000000-0000-0000-0000-000000000001','49000000-0000-0000-0000-000000000001')
 WHERE action_code='lead.quote_version_created'),3::bigint,'V2/V3 and second Quote V2 create three version events');
UPDATE public.quote_versions SET status='Đã gửi' WHERE id='79000000-0000-0000-0000-000000000001';
SELECT is((SELECT count(*) FROM public.get_lead_history(
 '19000000-0000-0000-0000-000000000001','49000000-0000-0000-0000-000000000001')
 WHERE action_code LIKE 'lead.quote%'),5::bigint,'Quote status change does not enter Lead History');
SELECT ok((SELECT bool_and(action_code IN (
 'lead.customer_name_changed','lead.contact_changed','lead.address_changed','lead.source_changed',
 'lead.type_changed','lead.budget_changed','lead.requirements_changed','lead.status_changed',
 'lead.failure_reason_changed','lead.assignee_added','lead.assignee_removed',
 'lead.quote_created','lead.quote_version_created'))
 FROM public.get_lead_history('19000000-0000-0000-0000-000000000001',
 '49000000-0000-0000-0000-000000000001')),'History exposes only the 13 approved groups');
SELECT ok((SELECT bool_and((event_at,event_id)<(lag_at,lag_id)) FROM (
 SELECT event_at,event_id,lag(event_at) OVER (ORDER BY event_at DESC,event_id DESC) lag_at,
 lag(event_id) OVER (ORDER BY event_at DESC,event_id DESC) lag_id
 FROM public.get_lead_history('19000000-0000-0000-0000-000000000001',
 '49000000-0000-0000-0000-000000000001')) x WHERE lag_at IS NOT NULL),
 'History ordering uses timestamp and ID');
SELECT is((SELECT count(*) FROM public.get_lead_history(
 '19000000-0000-0000-0000-000000000001','49000000-0000-0000-0000-000000000001',2)),
 2::bigint,'History page limit is applied');

SELECT lives_ok($sql$SELECT public.create_lead_with_assignees(
 '19000000-0000-0000-0000-000000000001','49000000-0000-0000-0000-000000000002',
 '{"customer_name":"Second Lead"}'::jsonb,
 ARRAY['29000000-0000-0000-0000-000000000003']::uuid[],false)$sql$,
 'Create Lead with assignee keeps the existing RPC path');
SELECT is((SELECT count(*) FROM public.get_lead_history(
 '19000000-0000-0000-0000-000000000001','49000000-0000-0000-0000-000000000002')
 WHERE action_code='lead.assignee_added'),1::bigint,
 'Create-with-assignees aggregate is expanded into one approved History event');
SELECT is((SELECT count(*) FROM public.get_lead_history(
 '19000000-0000-0000-0000-000000000001','49000000-0000-0000-0000-000000000002')
 WHERE action_code='lead.created'),0::bigint,'Lead creation stays outside History');
SELECT is((SELECT count(*) FROM public.list_lead_assignees(
 '19000000-0000-0000-0000-000000000001','49000000-0000-0000-0000-000000000001')),
 2::bigint,'Viewer-safe assignee RPC returns current Sale names');
SELECT ok(NOT public.delete_lead_care_activity('19000000-0000-0000-0000-000000000001',
 '59000000-0000-0000-0000-000000000002'),
 'Delete RPC reports false for care from a previous day');

UPDATE public.leads SET email=NULL WHERE id='49000000-0000-0000-0000-000000000001';
SELECT ok(EXISTS (SELECT 1 FROM public.get_lead_history('19000000-0000-0000-0000-000000000001',
 '49000000-0000-0000-0000-000000000001') WHERE action_code='lead.contact_changed'
 AND old_value->>'email'='a@example.test' AND new_value->'email'='null'::jsonb),
 'History captures value to NULL precisely');
WITH first_page AS (
 SELECT * FROM public.get_lead_history('19000000-0000-0000-0000-000000000001',
 '49000000-0000-0000-0000-000000000001',2)
), cursor_row AS (
 SELECT event_at,event_id FROM first_page ORDER BY event_at,event_id LIMIT 1
), next_page AS (
 SELECT h.* FROM cursor_row c CROSS JOIN LATERAL public.get_lead_history(
 '19000000-0000-0000-0000-000000000001','49000000-0000-0000-0000-000000000001',2,
 c.event_at,c.event_id) h
)
SELECT is((SELECT count(*) FROM next_page n JOIN first_page f USING(event_id)),0::bigint,
 'History cursor page has no duplicate events');

SET LOCAL request.jwt.claim.sub='39000000-0000-0000-0000-000000000002';
INSERT INTO public.lead_care_activities(id,company_id,lead_id,content)
VALUES('59000000-0000-0000-0000-000000000003','19000000-0000-0000-0000-000000000001',
 '49000000-0000-0000-0000-000000000001','Same-day care before reassignment');
SET LOCAL request.jwt.claim.sub='39000000-0000-0000-0000-000000000001';
SELECT public.set_lead_assignees('19000000-0000-0000-0000-000000000001',
 '49000000-0000-0000-0000-000000000001',ARRAY['29000000-0000-0000-0000-000000000003']::uuid[]);
SELECT is((SELECT count(*) FROM public.get_lead_history(
 '19000000-0000-0000-0000-000000000001','49000000-0000-0000-0000-000000000001')
 WHERE action_code='lead.assignee_removed'),1::bigint,'Removing one Sale writes one removal event');
SET LOCAL request.jwt.claim.sub='39000000-0000-0000-0000-000000000002';
SELECT ok(NOT public.delete_lead_care_activity('19000000-0000-0000-0000-000000000001',
 '59000000-0000-0000-0000-000000000003'),
 'Care creator loses delete access after Lead reassignment');
SELECT throws_ok($sql$SELECT * FROM public.get_lead_history(
 '19000000-0000-0000-0000-000000000001','49000000-0000-0000-0000-000000000001')$sql$,
 '42501',NULL,'Reassigned Sale cannot read Lead History');
RESET ROLE;
SELECT lives_ok($sql$UPDATE public.users SET department='Marketing'
 WHERE id='29000000-0000-0000-0000-000000000002'$sql$,
 'Sale may change department after every open assignment is removed');
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='39000000-0000-0000-0000-000000000001';
SELECT throws_ok($sql$SELECT public.set_lead_assignees(
 '19000000-0000-0000-0000-000000000001','49000000-0000-0000-0000-000000000001',
 ARRAY['29000000-0000-0000-0000-000000000002']::uuid[])$sql$,
 '23514',NULL,'Former Sale cannot be assigned again after department change');
RESET ROLE;
INSERT INTO public.user_permissions(company_id,user_id,permission_id,effect,granted_by)
SELECT '19000000-0000-0000-0000-000000000001','29000000-0000-0000-0000-000000000003',id,
 'deny','29000000-0000-0000-0000-000000000001' FROM public.permissions WHERE code='lead.edit';
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='39000000-0000-0000-0000-000000000003';
SELECT throws_ok($sql$INSERT INTO public.lead_care_activities(company_id,lead_id,content) VALUES
 ('19000000-0000-0000-0000-000000000001','49000000-0000-0000-0000-000000000001','View but no edit')$sql$,
 '42501',NULL,'Assigned viewer with explicit lead.edit deny cannot post care');
RESET ROLE;
UPDATE public.company_subscriptions SET expires_at=now()-interval '1 hour',
 grace_ends_at=now()+interval '1 day'
WHERE company_id='19000000-0000-0000-0000-000000000001';
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='39000000-0000-0000-0000-000000000001';
SELECT is((SELECT count(*) FROM public.lead_care_activities WHERE lead_id='49000000-0000-0000-0000-000000000001'),
 2::bigint,'Care remains readable during subscription grace');
SELECT throws_ok($sql$INSERT INTO public.lead_care_activities(company_id,lead_id,content) VALUES
 ('19000000-0000-0000-0000-000000000001','49000000-0000-0000-0000-000000000001','Grace write')$sql$,
 '42501',NULL,'Subscription grace denies care writes');
SELECT ok(NOT public.delete_lead_care_activity('19000000-0000-0000-0000-000000000001',
 '59000000-0000-0000-0000-000000000003'),
 'Subscription grace denies care deletion');
RESET ROLE;
UPDATE public.company_subscriptions SET starts_at=now()-interval '3 days',
 expires_at=now()-interval '2 days',
 grace_ends_at=now()-interval '1 day'
WHERE company_id='19000000-0000-0000-0000-000000000001';
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='39000000-0000-0000-0000-000000000001';
SELECT is((SELECT count(*) FROM public.lead_care_activities WHERE lead_id='49000000-0000-0000-0000-000000000001'),
 0::bigint,'Locked subscription hides Lead care');
SELECT throws_ok($sql$SELECT * FROM public.get_lead_history(
 '19000000-0000-0000-0000-000000000001','49000000-0000-0000-0000-000000000001')$sql$,
 '42501',NULL,'Locked subscription hides Lead History');

SELECT * FROM finish();
ROLLBACK;
