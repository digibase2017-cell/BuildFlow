-- 012_lead_view_all.sql — upgrade existing local databases to independent Lead visibility.

BEGIN;

ALTER TABLE public.permissions DROP CONSTRAINT permissions_code_check;
ALTER TABLE public.permissions ADD CONSTRAINT permissions_code_check
  CHECK (code ~ '^[a-z_]+\.[a-z_]+(\.[a-z_]+)?$');

INSERT INTO public.permissions(code,description) VALUES ('lead.view.all','lead.view.all') ON CONFLICT(code) DO NOTHING;

CREATE OR REPLACE FUNCTION app_private.lead_assignment_scope(p_company uuid,p_lead uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT app_private.actor_id(p_company) IS NOT NULL
    AND (app_private.is_manager(p_company)
      OR EXISTS (SELECT 1 FROM public.lead_assignments a
        WHERE a.company_id=p_company AND a.lead_id=p_lead
          AND a.unassigned_at IS NULL AND a.user_id=app_private.actor_id(p_company)));
$$;

CREATE OR REPLACE FUNCTION app_private.can_view_lead(p_company uuid,p_lead uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT app_private.actor_id(p_company) IS NOT NULL
    AND (app_private.is_manager(p_company)
      OR app_private.has_permission(p_company,'lead.view.all')
      OR (app_private.has_permission(p_company,'lead.view')
        AND app_private.lead_assignment_scope(p_company,p_lead)));
$$;

CREATE OR REPLACE FUNCTION public.can_access_row(p_company uuid,p_table text,p_row jsonb,p_action text)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_code text; v_project uuid; v_lead uuid; v_parent uuid;
BEGIN
  IF p_row->>'company_id' IS DISTINCT FROM p_company::text
     OR app_private.actor_id(p_company) IS NULL
     OR app_private.subscription_access(p_company)='locked' THEN RETURN false; END IF;

  v_code:=CASE
    WHEN p_table IN ('leads','lead_assignments') THEN 'lead.view'
    WHEN p_table IN ('quotes','quote_versions','quote_rooms','quote_groups',
       'quote_items','quote_item_materials') THEN 'quote.view'
    WHEN p_table IN ('projects','project_members','project_sales',
       'project_quote_history','project_applied_quote_versions') THEN 'project.view'
    WHEN p_table='project_financials' THEN 'financial.view'
    WHEN p_table IN ('catalog_items','catalog_item_materials') THEN 'catalog.view'
    WHEN p_table IN ('project_designs','design_users','design_rounds') THEN 'design.view'
    WHEN p_table IN ('project_purchasing','purchasing_users','purchasing_items',
       'purchasing_receipts') THEN 'purchasing.view'
    WHEN p_table IN ('project_production','production_users','production_items',
       'production_batches') THEN 'production.view'
    WHEN p_table IN ('project_construction','construction_users','construction_items',
       'construction_batches','construction_expense_categories','construction_expenses')
       THEN 'construction.view'
    WHEN p_table IN ('project_acceptance','acceptance_users','acceptance_rounds')
       THEN 'acceptance.view'
    WHEN p_table='project_payments' THEN 'payment.view'
    WHEN p_table='documents' THEN 'document.view'
    WHEN p_table='activity_logs' THEN 'activity_log.view'
    ELSE NULL END;
  IF v_code IS NULL OR p_action NOT IN ('view','create','edit','delete') THEN
    RETURN false; END IF;
  IF p_action<>'view' THEN
    IF app_private.subscription_access(p_company)<>'write' THEN RETURN false; END IF;
    IF p_table='lead_assignments' THEN v_code:='lead.assign';
    ELSIF p_table IN ('project_members','project_sales') THEN
      v_code:='project.manage_members';
    ELSIF p_table='acceptance_users' THEN v_code:='acceptance.assign';
    ELSIF p_table='project_financials' THEN v_code:='financial.edit';
    ELSE v_code:=split_part(v_code,'.',1)||'.'||p_action; END IF;
    IF p_action='delete' AND p_table IN
      ('quote_rooms','quote_groups','quote_items','quote_item_materials',
       'design_users','design_rounds','purchasing_users','purchasing_items',
       'purchasing_receipts','production_users','production_items',
       'production_batches','construction_users','construction_items',
       'construction_batches','construction_expenses','acceptance_rounds') THEN
      v_code:=split_part(v_code,'.',1)||'.edit';
    END IF;
    IF p_table='quote_versions' AND p_row->>'status'='Đã chốt' THEN
      RETURN false; END IF;
  END IF;
  -- Owner/Admin always see business rows within their active company and
  -- subscription. This read exception never grants writes or protected actions.
  IF p_action='view' AND app_private.is_manager(p_company) THEN RETURN true; END IF;
  IF p_table='leads' AND p_action='view' THEN
    RETURN app_private.can_view_lead(p_company,(p_row->>'id')::uuid);
  END IF;
  IF NOT app_private.has_permission(p_company,v_code) THEN RETURN false; END IF;

  IF p_table IN ('catalog_items','catalog_item_materials',
      'construction_expense_categories') THEN RETURN true; END IF;
  IF p_table='leads' THEN
    IF p_action='create' THEN RETURN true; END IF;
    -- RLS already supplies the actual row; do not re-query leads with a STABLE
    -- snapshot that predates the inserted tuple during INSERT RETURNING.
    RETURN app_private.lead_assignment_scope(p_company,(p_row->>'id')::uuid);
  END IF;
  IF p_table IN ('lead_assignments','quotes') THEN
    RETURN app_private.can_lead(p_company,(p_row->>'lead_id')::uuid); END IF;
  IF p_table IN ('quote_versions') THEN
    v_parent:=(p_row->>'quote_id')::uuid;
  ELSIF p_table IN ('quote_rooms','quote_groups','quote_items','quote_item_materials') THEN
    SELECT quote_id INTO v_parent FROM public.quote_versions WHERE company_id=p_company
      AND id=(p_row->>'version_id')::uuid;
  END IF;
  IF v_parent IS NOT NULL THEN
    SELECT lead_id INTO v_lead FROM public.quotes WHERE company_id=p_company AND id=v_parent;
    RETURN app_private.can_lead(p_company,v_lead);
  END IF;

  IF p_table='projects' THEN v_project:=(p_row->>'id')::uuid;
  ELSIF p_table IN ('project_members','project_sales','project_financials',
      'project_quote_history','project_applied_quote_versions',
      'project_designs','project_purchasing','project_production',
      'project_construction','project_acceptance','project_payments',
      'acceptance_users','acceptance_rounds','purchasing_items',
      'production_items','construction_items') THEN
    v_project:=(p_row->>'project_id')::uuid;
  ELSIF p_table IN ('design_users','design_rounds') THEN
    SELECT project_id INTO v_project FROM public.project_designs
      WHERE company_id=p_company AND id=COALESCE((p_row->>'design_id')::uuid,
        (p_row->>'id')::uuid);
  ELSIF p_table='purchasing_users' THEN
    SELECT project_id INTO v_project FROM public.project_purchasing
      WHERE company_id=p_company AND id=(p_row->>'purchasing_id')::uuid;
  ELSIF p_table='production_users' THEN
    SELECT project_id INTO v_project FROM public.project_production
      WHERE company_id=p_company AND id=(p_row->>'production_id')::uuid;
  ELSIF p_table='construction_users' THEN
    SELECT project_id INTO v_project FROM public.project_construction
      WHERE company_id=p_company AND id=(p_row->>'construction_id')::uuid;
  ELSIF p_table='purchasing_receipts' THEN
    SELECT project_id INTO v_project FROM public.purchasing_items
      WHERE company_id=p_company AND id=(p_row->>'purchasing_item_id')::uuid;
  ELSIF p_table='production_batches' THEN
    SELECT project_id INTO v_project FROM public.production_items
      WHERE company_id=p_company AND id=(p_row->>'production_item_id')::uuid;
  ELSIF p_table='construction_batches' THEN
    SELECT project_id INTO v_project FROM public.construction_items
      WHERE company_id=p_company AND id=(p_row->>'construction_item_id')::uuid;
  ELSIF p_table='construction_expenses' THEN
    SELECT project_id INTO v_project FROM public.construction_items
      WHERE company_id=p_company AND id=(p_row->>'construction_item_id')::uuid;
  ELSIF p_table='documents' THEN
    IF p_row->>'project_id' IS NOT NULL THEN
      v_project:=(p_row->>'project_id')::uuid;
    ELSIF p_row->>'lead_id' IS NOT NULL THEN
      RETURN app_private.can_lead(p_company,(p_row->>'lead_id')::uuid);
    ELSE
      SELECT lead_id INTO v_lead FROM public.quotes
        WHERE company_id=p_company AND id=(p_row->>'quote_id')::uuid;
      RETURN app_private.can_lead(p_company,v_lead);
    END IF;
  ELSIF p_table='activity_logs' THEN
    IF p_row->>'project_id' IS NULL THEN RETURN app_private.is_manager(p_company); END IF;
    v_project:=(p_row->>'project_id')::uuid;
  END IF;
  RETURN v_project IS NOT NULL AND app_private.can_project(p_company,v_project);
END; $$;

CREATE OR REPLACE FUNCTION app_private.default_role_permission_codes(p_role text)
RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT codes FROM (VALUES
    ('owner',ARRAY['lead.view','lead.view.all','lead.create','lead.edit','lead.delete','lead.assign','quote.view','quote.create','quote.edit','quote.delete','quote.finalize','quote.export','project.view','project.create','project.edit','project.manage_members','catalog.view','catalog.create','catalog.edit','catalog.delete','design.view','design.create','design.edit','purchasing.view','purchasing.create','purchasing.edit','production.view','production.create','production.edit','construction.view','construction.create','construction.edit','acceptance.view','acceptance.create','acceptance.edit','acceptance.assign','payment.view','payment.create','payment.edit','payment.delete','financial.view','financial.edit','document.view','document.create','document.edit','document.delete','activity_log.view','user.view','user.create','user.edit','role.view','role.create','role.edit','settings.view','settings.edit','report.view','report.export']::text[]),
    ('admin',ARRAY['lead.view','lead.view.all','lead.create','lead.edit','lead.delete','lead.assign','quote.view','quote.create','quote.edit','quote.delete','quote.finalize','quote.export','project.view','project.create','project.edit','project.manage_members','catalog.view','catalog.create','catalog.edit','catalog.delete','design.view','design.create','design.edit','purchasing.view','purchasing.create','purchasing.edit','production.view','production.create','production.edit','construction.view','construction.create','construction.edit','acceptance.view','acceptance.create','acceptance.edit','acceptance.assign','payment.view','payment.create','payment.edit','payment.delete','financial.view','financial.edit','document.view','document.create','document.edit','document.delete','activity_log.view','user.view','user.create','user.edit','role.view','role.create','role.edit','settings.view','settings.edit','report.view','report.export']::text[]),
    ('marketing',ARRAY['lead.view','lead.create','lead.edit']::text[]),
    ('sales',ARRAY['lead.view','lead.create','lead.edit','quote.view','quote.create','quote.edit','quote.finalize','quote.export','project.view','project.create','catalog.view','catalog.create','catalog.edit','design.view','purchasing.view','production.view','construction.view','acceptance.view','payment.view','document.view','document.create','document.edit']::text[]),
    ('project_manager',ARRAY['lead.view','quote.view','quote.export','project.view','project.create','project.edit','project.manage_members','catalog.view','design.view','design.create','design.edit','purchasing.view','purchasing.create','purchasing.edit','production.view','production.create','production.edit','construction.view','construction.create','construction.edit','acceptance.view','acceptance.assign','payment.view','financial.view','document.view','document.create','document.edit','activity_log.view','user.view','report.view','report.export']::text[]),
    ('designer',ARRAY['project.view','quote.view','catalog.view','design.view','design.create','design.edit','document.view','document.create','document.edit']::text[]),
    ('purchasing',ARRAY['project.view','quote.view','catalog.view','purchasing.view','purchasing.create','purchasing.edit','document.view','document.create','document.edit']::text[]),
    ('production',ARRAY['project.view','quote.view','catalog.view','production.view','production.create','production.edit','document.view','document.create','document.edit']::text[]),
    ('construction',ARRAY['project.view','quote.view','construction.view','construction.create','construction.edit','document.view','document.create','document.edit']::text[]),
    ('supervisor',ARRAY['project.view','quote.view','design.view','purchasing.view','production.view','construction.view','construction.create','construction.edit','acceptance.view','acceptance.create','acceptance.edit','acceptance.assign','document.view','document.create','document.edit']::text[]),
    ('accountant',ARRAY['project.view','quote.view','quote.export','purchasing.view','production.view','construction.view','acceptance.view','payment.view','payment.create','payment.edit','financial.view','financial.edit','document.view','document.create','document.edit','activity_log.view','report.view','report.export']::text[])
  ) AS defaults(role_code,codes) WHERE role_code=p_role;
$$;

INSERT INTO public.role_permissions(company_id,role_id,permission_id,granted_by) SELECT r.company_id,r.id,p.id,NULL FROM public.roles r CROSS JOIN public.permissions p WHERE r.code IN ('owner','admin') AND p.code='lead.view.all' ON CONFLICT(company_id,role_id,permission_id) DO NOTHING;

COMMIT;
