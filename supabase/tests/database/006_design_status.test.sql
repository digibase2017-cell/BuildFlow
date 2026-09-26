-- Current design phase follows the latest submitted round; Project status is separate.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = public, extensions;
SELECT no_plan();

INSERT INTO public.companies(id,name)
  VALUES ('16000000-0000-0000-0000-000000000001','Design status regression');
INSERT INTO public.company_subscriptions(company_id,plan_id,starts_at,expires_at,grace_ends_at,
  price_paid_vnd,max_active_users,max_projects,r2_storage_bytes)
SELECT '16000000-0000-0000-0000-000000000001',id,now()-interval '1 day',
  now()+interval '1 year',now()+interval '1 year 7 days',annual_price_vnd,
  max_active_users,max_projects,r2_storage_bytes
FROM public.subscription_plans WHERE code='starter';
INSERT INTO auth.users(id,email)
  VALUES ('36000000-0000-0000-0000-000000000001','design-status@example.test');
INSERT INTO public.users(id,company_id,auth_user_id,role_id,full_name,email)
SELECT '26000000-0000-0000-0000-000000000001',company_id,
  '36000000-0000-0000-0000-000000000001',id,'Design Admin','design-status@example.test'
FROM public.roles WHERE company_id='16000000-0000-0000-0000-000000000001' AND code='admin';

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='36000000-0000-0000-0000-000000000001';
INSERT INTO public.leads(id,company_id,customer_name,status)
  VALUES ('46000000-0000-0000-0000-000000000001',
    '16000000-0000-0000-0000-000000000001','Design customer','Thành công');
SELECT public.create_project_from_lead('16000000-0000-0000-0000-000000000001',
  '46000000-0000-0000-0000-000000000001','Design project',NULL,true) AS project_id \gset
INSERT INTO public.project_designs(company_id,project_id)
  VALUES ('16000000-0000-0000-0000-000000000001',:'project_id') RETURNING id AS design_id \gset
SELECT is((SELECT status FROM public.project_designs WHERE id=:'design_id'),
  'Chưa bắt đầu','New design starts at Chưa bắt đầu');
SELECT is((SELECT status FROM public.projects WHERE id=:'project_id'),
  'Chưa bắt đầu','Project retains its own status');

INSERT INTO public.design_rounds(company_id,design_id,round_number)
  VALUES ('16000000-0000-0000-0000-000000000001',:'design_id',1) RETURNING id AS round1 \gset
SELECT is((SELECT status FROM public.project_designs WHERE id=:'design_id'),
  'Chờ khách duyệt','Sending latest round waits for customer');
UPDATE public.design_rounds SET status='Đang sửa' WHERE id=:'round1';
SELECT is((SELECT status FROM public.project_designs WHERE id=:'design_id'),
  'Đang thiết kế','Customer change request resumes design');
UPDATE public.design_rounds SET status='Sửa xong' WHERE id=:'round1';
SELECT is((SELECT status FROM public.project_designs WHERE id=:'design_id'),
  'Đang thiết kế','Finishing revisions does not imply sending them');
UPDATE public.design_rounds SET status='Đang sửa' WHERE id=:'round1';
INSERT INTO public.design_rounds(company_id,design_id,round_number)
  VALUES ('16000000-0000-0000-0000-000000000001',:'design_id',2) RETURNING id AS round2 \gset
SELECT is((SELECT status FROM public.design_rounds WHERE id=:'round1'),
  'Sửa xong','New round closes earlier in-progress revision');
SELECT is((SELECT status FROM public.project_designs WHERE id=:'design_id'),
  'Chờ khách duyệt','Sending next round waits for customer again');
UPDATE public.design_rounds SET status='Đã duyệt' WHERE id=:'round1';
SELECT is((SELECT status FROM public.project_designs WHERE id=:'design_id'),
  'Chờ khách duyệt','Old round approval cannot override latest round');
UPDATE public.design_rounds SET status='Đang sửa' WHERE id=:'round2';
SELECT is((SELECT status FROM public.project_designs WHERE id=:'design_id'),
  'Đang thiết kế','Second change request resumes design');
UPDATE public.design_rounds SET status='Đã duyệt' WHERE id=:'round2';
SELECT is((SELECT status FROM public.project_designs WHERE id=:'design_id'),
  'Đã duyệt','Latest round approval completes design');
SELECT ok((SELECT customer_approved_date IS NOT NULL FROM public.project_designs
  WHERE id=:'design_id'),'Latest approval records date');
INSERT INTO public.design_rounds(company_id,design_id,round_number)
  VALUES ('16000000-0000-0000-0000-000000000001',:'design_id',3) RETURNING id AS round3 \gset
SELECT is((SELECT status FROM public.project_designs WHERE id=:'design_id'),
  'Chờ khách duyệt','New submission reopens approved design');
SELECT ok((SELECT customer_approved_date IS NULL FROM public.project_designs
  WHERE id=:'design_id'),'New submission clears current approval date');
SELECT is((SELECT status FROM public.projects WHERE id=:'project_id'),
  'Chưa bắt đầu','Design lifecycle does not change Project status');
UPDATE public.design_rounds SET status='Đã hủy' WHERE id=:'round3';
SELECT is((SELECT status FROM public.design_rounds WHERE id=:'round3'),
  'Đã hủy','A submission can be cancelled');
SELECT is((SELECT status FROM public.project_designs WHERE id=:'design_id'),
  'Chờ khách duyệt','Cancelling one submission does not cancel the whole design');
UPDATE public.project_designs SET status='Đã hủy' WHERE id=:'design_id';
SELECT is((SELECT status FROM public.project_designs WHERE id=:'design_id'),
  'Đã hủy','Authorized user explicitly cancels the whole design');
UPDATE public.design_rounds SET status='Đã gửi' WHERE id=:'round3';
SELECT is((SELECT status FROM public.project_designs WHERE id=:'design_id'),
  'Đã hủy','Round status cannot silently reopen a cancelled design');
SELECT is((SELECT status FROM public.projects WHERE id=:'project_id'),
  'Chưa bắt đầu','Cancelling design does not cancel Project');

SET CONSTRAINTS ALL IMMEDIATE;
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
