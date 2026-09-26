-- Regression coverage for clone identity, alternative pricing and immutability.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = public, extensions;
SELECT no_plan();

INSERT INTO public.companies(id,name) VALUES ('11000000-0000-0000-0000-000000000001','Quote regression');
INSERT INTO public.company_subscriptions(company_id,plan_id,starts_at,expires_at,grace_ends_at,
  price_paid_vnd,max_active_users,max_projects,r2_storage_bytes)
SELECT '11000000-0000-0000-0000-000000000001',id,now()-interval '1 day',now()+interval '1 year',now()+interval '1 year 7 days',
  annual_price_vnd,max_active_users,max_projects,r2_storage_bytes FROM public.subscription_plans WHERE code='starter';
INSERT INTO auth.users(id,email) VALUES ('31000000-0000-0000-0000-000000000001','quote-regression@example.test');
INSERT INTO public.users(id,company_id,auth_user_id,role_id,full_name,email)
SELECT '21000000-0000-0000-0000-000000000001',company_id,'31000000-0000-0000-0000-000000000001',id,'Quote Admin','quote-regression@example.test'
FROM public.roles WHERE company_id='11000000-0000-0000-0000-000000000001' AND code='admin';

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub='31000000-0000-0000-0000-000000000001';
INSERT INTO public.leads(id,company_id,customer_name) VALUES ('41000000-0000-0000-0000-000000000001','11000000-0000-0000-0000-000000000001','Clone customer');
INSERT INTO public.quotes(id,company_id,lead_id,title) VALUES ('51000000-0000-0000-0000-000000000001','11000000-0000-0000-0000-000000000001','41000000-0000-0000-0000-000000000001','Clone quote');
INSERT INTO public.quote_versions(id,company_id,quote_id,version_number) VALUES ('61000000-0000-0000-0000-000000000001','11000000-0000-0000-0000-000000000001','51000000-0000-0000-0000-000000000001',1);
INSERT INTO public.quote_rooms(id,company_id,version_id,name) VALUES ('71000000-0000-0000-0000-000000000001','11000000-0000-0000-0000-000000000001','61000000-0000-0000-0000-000000000001','Kitchen');
INSERT INTO public.quote_groups(id,company_id,version_id,room_id,name) VALUES ('81000000-0000-0000-0000-000000000001','11000000-0000-0000-0000-000000000001','61000000-0000-0000-0000-000000000001','71000000-0000-0000-0000-000000000001','Cabinets');
INSERT INTO public.quote_items(id,company_id,version_id,group_id,name,unit,length,item_count)
VALUES ('91000000-0000-0000-0000-000000000001','11000000-0000-0000-0000-000000000001','61000000-0000-0000-0000-000000000001','81000000-0000-0000-0000-000000000001','Cabinet','md',1.5,1);
INSERT INTO public.quote_item_materials(id,company_id,version_id,item_id,material_name,selling_price,is_selected) VALUES
('a1000000-0000-0000-0000-000000000001','11000000-0000-0000-0000-000000000001','61000000-0000-0000-0000-000000000001','91000000-0000-0000-0000-000000000001','Option A',101,true),
('a1000000-0000-0000-0000-000000000002','11000000-0000-0000-0000-000000000001','61000000-0000-0000-0000-000000000001','91000000-0000-0000-0000-000000000001','Option B',200,true);
SELECT is((SELECT quantity FROM public.quote_items WHERE id='91000000-0000-0000-0000-000000000001'),1.5::numeric,'Linear quantity uses length times count');
SELECT lives_ok($test$SELECT public.finalize_quote_version('11000000-0000-0000-0000-000000000001','61000000-0000-0000-0000-000000000001')$test$,'Unresolved material alternatives can be finalized');
SELECT ok((SELECT total_amount IS NULL FROM public.quote_versions WHERE id='61000000-0000-0000-0000-000000000001'),'Unresolved total remains NULL');
SELECT throws_ok($test$UPDATE public.quote_item_materials SET selling_price=999 WHERE id='a1000000-0000-0000-0000-000000000001'$test$,'23514',NULL,'Finalized material price is immutable');
SELECT throws_ok($test$INSERT INTO public.quote_rooms(company_id,version_id,name) VALUES ('11000000-0000-0000-0000-000000000001','61000000-0000-0000-0000-000000000001','Forbidden room')$test$,'23514',NULL,'Cannot add a room to finalized version');
SELECT lives_ok($test$SELECT public.clone_quote_version('11000000-0000-0000-0000-000000000001','61000000-0000-0000-0000-000000000001')$test$,'Clone finalized unresolved version');
SELECT is((SELECT count(*) FROM public.quote_items WHERE company_id='11000000-0000-0000-0000-000000000001'),2::bigint,'Clone creates another item');
SELECT is((SELECT count(DISTINCT lineage_id) FROM public.quote_items WHERE company_id='11000000-0000-0000-0000-000000000001'),1::bigint,'Clone preserves item lineage');

UPDATE public.quote_items i SET finalized_material_id=m.id FROM public.quote_item_materials m, public.quote_versions v
WHERE i.version_id=v.id AND v.quote_id='51000000-0000-0000-0000-000000000001' AND v.version_number=2
  AND m.item_id=i.id AND m.material_name='Option A';
SELECT lives_ok($test$SELECT public.finalize_quote_version('11000000-0000-0000-0000-000000000001',(SELECT id FROM public.quote_versions WHERE quote_id='51000000-0000-0000-0000-000000000001' AND version_number=2))$test$,'Finalize chosen material');
SELECT is((SELECT total_amount FROM public.quote_versions WHERE quote_id='51000000-0000-0000-0000-000000000001' AND version_number=2),152::numeric,'Half-up rounding uses only the finalized alternative');
SELECT lives_ok($test$SELECT public.clone_quote_version('11000000-0000-0000-0000-000000000001',(SELECT id FROM public.quote_versions WHERE quote_id='51000000-0000-0000-0000-000000000001' AND version_number=2))$test$,'Clone version with finalized material pointer');
SELECT ok((SELECT i.finalized_material_id=m.id AND m.item_id=i.id AND m.version_id=i.version_id AND m.material_name='Option A'
  FROM public.quote_items i JOIN public.quote_versions v ON v.id=i.version_id
  JOIN public.quote_item_materials m ON m.id=i.finalized_material_id
  WHERE v.quote_id='51000000-0000-0000-0000-000000000001' AND v.version_number=3),'Clone remaps chosen material to its new item and version');
SELECT is((SELECT count(DISTINCT finalized_material_id) FROM public.quote_items WHERE company_id='11000000-0000-0000-0000-000000000001'),2::bigint,'Chosen material IDs differ between source and clone');
SELECT lives_ok($test$SET CONSTRAINTS ALL IMMEDIATE$test$,'Clone foreign keys validate');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
