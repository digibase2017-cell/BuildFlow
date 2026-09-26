-- Regression coverage for receipt/batch corrections and acceptance lifecycle.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = public, extensions;
SELECT no_plan();

INSERT INTO public.companies(id,name) VALUES ('12000000-0000-0000-0000-000000000001','Module regression');
INSERT INTO public.company_subscriptions(company_id,plan_id,starts_at,expires_at,grace_ends_at,
  price_paid_vnd,max_active_users,max_projects,r2_storage_bytes)
SELECT '12000000-0000-0000-0000-000000000001',id,now()-interval '1 day',now()+interval '1 year',now()+interval '1 year 7 days',
  annual_price_vnd,max_active_users,max_projects,r2_storage_bytes FROM public.subscription_plans WHERE code='starter';
INSERT INTO auth.users(id,email) VALUES ('32000000-0000-0000-0000-000000000001','module-regression@example.test');
INSERT INTO public.users(id,company_id,auth_user_id,role_id,full_name,email)
SELECT '22000000-0000-0000-0000-000000000001',company_id,'32000000-0000-0000-0000-000000000001',id,'Module Admin','module-regression@example.test'
FROM public.roles WHERE company_id='12000000-0000-0000-0000-000000000001' AND code='admin';

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='32000000-0000-0000-0000-000000000001';
INSERT INTO public.leads(id,company_id,customer_name) VALUES ('42000000-0000-0000-0000-000000000001','12000000-0000-0000-0000-000000000001','Module customer');

UPDATE public.leads SET status='Thành công' WHERE company_id='12000000-0000-0000-0000-000000000001';
SELECT public.create_project_from_lead('12000000-0000-0000-0000-000000000001','42000000-0000-0000-0000-000000000001','Module project',NULL,false,true,true,true) AS project_id \gset
UPDATE public.projects SET progress_percent=37 WHERE id=:'project_id';

-- purchasing: quantity corrections must recover the actual earlier phase.
INSERT INTO public.project_purchasing(company_id,project_id) VALUES ('12000000-0000-0000-0000-000000000001',:'project_id') RETURNING id AS module_id \gset
INSERT INTO public.purchasing_items(company_id,project_id,purchasing_id,name,unit,required_quantity,status)
VALUES ('12000000-0000-0000-0000-000000000001',:'project_id',:'module_id','Test item','cái',10,'Đã đặt') RETURNING id AS item_id \gset
INSERT INTO public.purchasing_receipts(company_id,purchasing_item_id,receipt_date,quantity) VALUES ('12000000-0000-0000-0000-000000000001',:'item_id',current_date,10) RETURNING id AS batch_id \gset
SELECT is((SELECT status FROM public.purchasing_items WHERE id=:'item_id'),'Đã nhận','purchasing: exact threshold completes item');
SELECT is((SELECT pre_received_status FROM public.purchasing_items WHERE id=:'item_id'),'Đã đặt','purchasing: saves earlier phase');
SELECT is((SELECT status FROM public.project_purchasing WHERE id=:'module_id'),'Đã xong','purchasing: module completes with its item');
UPDATE public.purchasing_receipts SET quantity=4 WHERE id=:'batch_id';
SELECT is((SELECT status FROM public.purchasing_items WHERE id=:'item_id'),'Đã đặt','purchasing: correction restores earlier phase');
SELECT ok((SELECT pre_received_status IS NULL FROM public.purchasing_items WHERE id=:'item_id'),'purchasing: clears automatic completion provenance');
INSERT INTO public.purchasing_receipts(company_id,purchasing_item_id,receipt_date,quantity) VALUES ('12000000-0000-0000-0000-000000000001',:'item_id',current_date,7) RETURNING id AS replacement_id \gset
SELECT is((SELECT status FROM public.purchasing_items WHERE id=:'item_id'),'Đã nhận','purchasing: replacement exceeding threshold completes');
SELECT is((SELECT required_quantity FROM public.purchasing_items WHERE id=:'item_id'),10::numeric,'purchasing: replacement does not increase requirement');
DELETE FROM public.purchasing_receipts WHERE id=:'replacement_id';
SELECT is((SELECT status FROM public.purchasing_items WHERE id=:'item_id'),'Đã đặt','purchasing: deletion restores earlier phase');
UPDATE public.purchasing_items SET required_quantity=4 WHERE id=:'item_id';
SELECT is((SELECT status FROM public.purchasing_items WHERE id=:'item_id'),'Đã nhận','purchasing: reduced requirement reconciles existing quantities');
UPDATE public.purchasing_items SET required_quantity=10 WHERE id=:'item_id';
SELECT is((SELECT status FROM public.purchasing_items WHERE id=:'item_id'),'Đã đặt','purchasing: increased requirement restores earlier phase');

-- production: quantity corrections must recover the actual earlier phase.
INSERT INTO public.project_production(company_id,project_id) VALUES ('12000000-0000-0000-0000-000000000001',:'project_id') RETURNING id AS module_id \gset
INSERT INTO public.production_items(company_id,project_id,production_id,name,unit,required_quantity,status)
VALUES ('12000000-0000-0000-0000-000000000001',:'project_id',:'module_id','Test item','cái',10,'Đang sản xuất') RETURNING id AS item_id \gset
INSERT INTO public.production_batches(company_id,production_item_id,completed_date,quantity) VALUES ('12000000-0000-0000-0000-000000000001',:'item_id',current_date,10) RETURNING id AS batch_id \gset
SELECT is((SELECT status FROM public.production_items WHERE id=:'item_id'),'Hoàn thành','production: exact threshold completes item');
SELECT is((SELECT pre_completed_status FROM public.production_items WHERE id=:'item_id'),'Đang sản xuất','production: saves earlier phase');
SELECT is((SELECT status FROM public.project_production WHERE id=:'module_id'),'Đã xong','production: module completes with its item');
UPDATE public.production_batches SET quantity=4 WHERE id=:'batch_id';
SELECT is((SELECT status FROM public.production_items WHERE id=:'item_id'),'Đang sản xuất','production: correction restores earlier phase');
SELECT ok((SELECT pre_completed_status IS NULL FROM public.production_items WHERE id=:'item_id'),'production: clears automatic completion provenance');
INSERT INTO public.production_batches(company_id,production_item_id,completed_date,quantity) VALUES ('12000000-0000-0000-0000-000000000001',:'item_id',current_date,7) RETURNING id AS replacement_id \gset
SELECT is((SELECT status FROM public.production_items WHERE id=:'item_id'),'Hoàn thành','production: replacement exceeding threshold completes');
SELECT is((SELECT required_quantity FROM public.production_items WHERE id=:'item_id'),10::numeric,'production: replacement does not increase requirement');
DELETE FROM public.production_batches WHERE id=:'replacement_id';
SELECT is((SELECT status FROM public.production_items WHERE id=:'item_id'),'Đang sản xuất','production: deletion restores earlier phase');
UPDATE public.production_items SET required_quantity=4 WHERE id=:'item_id';
SELECT is((SELECT status FROM public.production_items WHERE id=:'item_id'),'Hoàn thành','production: reduced requirement reconciles existing quantities');
UPDATE public.production_items SET required_quantity=10 WHERE id=:'item_id';
SELECT is((SELECT status FROM public.production_items WHERE id=:'item_id'),'Đang sản xuất','production: increased requirement restores earlier phase');

-- construction: quantity corrections must recover the actual earlier phase.
INSERT INTO public.project_construction(company_id,project_id) VALUES ('12000000-0000-0000-0000-000000000001',:'project_id') RETURNING id AS module_id \gset
INSERT INTO public.construction_items(company_id,project_id,construction_id,name,unit,required_quantity,status)
VALUES ('12000000-0000-0000-0000-000000000001',:'project_id',:'module_id','Test item','cái',10,'Đang thi công') RETURNING id AS item_id \gset
INSERT INTO public.construction_batches(company_id,construction_item_id,completed_date,quantity) VALUES ('12000000-0000-0000-0000-000000000001',:'item_id',current_date,10) RETURNING id AS batch_id \gset
SELECT is((SELECT status FROM public.construction_items WHERE id=:'item_id'),'Hoàn thành','construction: exact threshold completes item');
SELECT is((SELECT pre_completed_status FROM public.construction_items WHERE id=:'item_id'),'Đang thi công','construction: saves earlier phase');

UPDATE public.construction_batches SET quantity=4 WHERE id=:'batch_id';
SELECT is((SELECT status FROM public.construction_items WHERE id=:'item_id'),'Đang thi công','construction: correction restores earlier phase');
SELECT ok((SELECT pre_completed_status IS NULL FROM public.construction_items WHERE id=:'item_id'),'construction: clears automatic completion provenance');
INSERT INTO public.construction_batches(company_id,construction_item_id,completed_date,quantity) VALUES ('12000000-0000-0000-0000-000000000001',:'item_id',current_date,7) RETURNING id AS replacement_id \gset
SELECT is((SELECT status FROM public.construction_items WHERE id=:'item_id'),'Hoàn thành','construction: replacement exceeding threshold completes');
SELECT is((SELECT required_quantity FROM public.construction_items WHERE id=:'item_id'),10::numeric,'construction: replacement does not increase requirement');
DELETE FROM public.construction_batches WHERE id=:'replacement_id';
SELECT is((SELECT status FROM public.construction_items WHERE id=:'item_id'),'Đang thi công','construction: deletion restores earlier phase');
UPDATE public.construction_items SET required_quantity=4 WHERE id=:'item_id';
SELECT is((SELECT status FROM public.construction_items WHERE id=:'item_id'),'Hoàn thành','construction: reduced requirement reconciles existing quantities');
UPDATE public.construction_items SET required_quantity=10 WHERE id=:'item_id';
SELECT is((SELECT status FROM public.construction_items WHERE id=:'item_id'),'Đang thi công','construction: increased requirement restores earlier phase');

SELECT id AS acceptance_id FROM public.project_acceptance WHERE project_id=:'project_id' \gset
INSERT INTO public.acceptance_rounds(company_id,acceptance_id,project_id,round_number,round_date,result)
VALUES ('12000000-0000-0000-0000-000000000001',:'acceptance_id',:'project_id',1,current_date,'Đạt') RETURNING id AS round1 \gset
SELECT is((SELECT status FROM public.projects WHERE id=:'project_id'),'Hoàn thành','Acceptance completes project');
SELECT is((SELECT progress_percent FROM public.projects WHERE id=:'project_id'),37::numeric,'Acceptance preserves manual progress');
SELECT is((SELECT status FROM public.project_production WHERE project_id=:'project_id'),'Đang sản xuất','Acceptance does not force production completion');
UPDATE public.projects SET completed_date=current_date-3 WHERE id=:'project_id';
SELECT ok((SELECT completion_source_acceptance_round_id IS NULL FROM public.projects WHERE id=:'project_id'),'Manual date clears automatic provenance');
UPDATE public.acceptance_rounds SET result='Cần khắc phục' WHERE id=:'round1';
SELECT is((SELECT completed_date FROM public.projects WHERE id=:'project_id'),current_date-3,'Reversal preserves manual completion date');
SELECT is((SELECT status FROM public.projects WHERE id=:'project_id'),'Đang thực hiện','Reversal reopens manually dated project');
UPDATE public.projects SET status='Tạm dừng' WHERE id=:'project_id';
UPDATE public.acceptance_rounds SET result='Đạt' WHERE id=:'round1';
SELECT is((SELECT status FROM public.projects WHERE id=:'project_id'),'Tạm dừng','Passing round does not override paused project');
SELECT is((SELECT completed_date FROM public.projects WHERE id=:'project_id'),current_date-3,'Paused project retains its date');
UPDATE public.projects SET status='Đã hủy' WHERE id=:'project_id';
UPDATE public.acceptance_rounds SET result='Cần khắc phục' WHERE id=:'round1';
SELECT is((SELECT status FROM public.projects WHERE id=:'project_id'),'Đã hủy','Reversal does not override cancelled project');
UPDATE public.acceptance_rounds SET result='Đạt' WHERE id=:'round1';
SELECT is((SELECT status FROM public.projects WHERE id=:'project_id'),'Đã hủy','Passing round does not override cancelled project');
UPDATE public.projects SET status='Đang thực hiện' WHERE id=:'project_id';
INSERT INTO public.acceptance_rounds(company_id,acceptance_id,project_id,round_number,round_date,result)
VALUES ('12000000-0000-0000-0000-000000000001',:'acceptance_id',:'project_id',2,current_date+1,'Cần khắc phục') RETURNING id AS round2 \gset
UPDATE public.acceptance_rounds SET notes='Old round edited' WHERE id=:'round1';
SELECT is((SELECT status FROM public.project_acceptance WHERE id=:'acceptance_id'),'Cần khắc phục','Editing old round does not supersede latest result');
DELETE FROM public.acceptance_rounds WHERE id=:'round2';
SELECT is((SELECT status FROM public.projects WHERE id=:'project_id'),'Hoàn thành','Deleting latest round falls back to earlier passing result');
DELETE FROM public.acceptance_rounds WHERE id=:'round1';
SELECT is((SELECT status FROM public.project_acceptance WHERE id=:'acceptance_id'),'Chưa nghiệm thu','Deleting all rounds resets acceptance');
SELECT ok((SELECT completed_date IS NULL AND completion_source_acceptance_round_id IS NULL FROM public.projects WHERE id=:'project_id'),'Deleting completion round clears its automatic date and reference');
SET CONSTRAINTS ALL IMMEDIATE;
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
