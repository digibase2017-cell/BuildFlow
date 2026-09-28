-- 009_rls.sql — tenant-scoped read/write policies and guarded RPC surface.
-- Requires 001–008. Not compiled or tested against Supabase/PostgreSQL.
-- Protected administration/history and Project creation stay RPC-only.
BEGIN;

-- Every user-visible row is checked for active identity, paid/grace access,
-- effective permission and record scope. Runs with a privileged DB owner;
-- the caller cannot change the immutable Auth UID used by actor_id().
CREATE FUNCTION public.can_access_row(p_company uuid,p_table text,p_row jsonb,p_action text)
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
CREATE FUNCTION public.can_read_row(p_company uuid,p_table text,p_row jsonb)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT public.can_access_row(p_company,p_table,p_row,'view');
$$;
REVOKE ALL ON FUNCTION public.can_access_row(uuid,text,jsonb,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.can_access_row(uuid,text,jsonb,text) TO authenticated;
REVOKE ALL ON FUNCTION public.can_read_row(uuid,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.can_read_row(uuid,text,jsonb) TO authenticated;

-- RLS is switched on everywhere, including tables with no client grants.
DO $block$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'companies','permissions','roles','users','role_permissions','user_permissions',
    'subscription_plans','company_subscriptions','company_counters','company_settings',
    'leads','lead_assignments','projects','project_members',
    'project_sales','project_financials','catalog_items','catalog_item_materials',
    'quotes','quote_versions','quote_rooms','quote_groups','quote_items',
    'quote_item_materials','project_designs','design_users','design_rounds',
    'project_purchasing','purchasing_users','purchasing_items','purchasing_receipts',
    'project_production','production_users','production_items','production_batches',
    'project_construction','construction_users','construction_items',
    'construction_batches','construction_expense_categories','construction_expenses',
    'project_acceptance','acceptance_users','acceptance_rounds',
    'project_payments','documents','notification_events','notifications',
    'activity_logs','project_quote_history','project_applied_quote_versions'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('REVOKE ALL ON public.%I FROM anon,authenticated',t);
  END LOOP;
END $block$;

-- Only whitelisted business tables receive SELECT, each with its own
-- permission code and an additional Project/Lead row-scope decision.
DO $block$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'leads','lead_assignments','projects','project_members',
    'project_sales','project_financials','catalog_items','catalog_item_materials',
    'quotes','quote_versions','quote_rooms','quote_groups','quote_items',
    'quote_item_materials','project_designs','design_users','design_rounds',
    'project_purchasing','purchasing_users','purchasing_items','purchasing_receipts',
    'project_production','production_users','production_items','production_batches',
    'project_construction','construction_users','construction_items',
    'construction_batches','construction_expense_categories','construction_expenses',
    'project_acceptance','acceptance_users','acceptance_rounds',
    'project_payments','documents','activity_logs','project_quote_history',
    'project_applied_quote_versions'] LOOP
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated',t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING '
      || '(public.can_read_row(company_id,%L,to_jsonb(%I)))',
      'read_'||t,t,t,t);
  END LOOP;
END $block$;

-- Ordinary writes follow the action-specific Permission and the same row
-- scope. Tables with no delete Permission receive no DELETE grant. Protected
-- records (Lead assignments, users, roles, history, registry, audit and inbox) are excluded.
DO $block$
DECLARE t text; a text; v_actions text[];
BEGIN
  FOR t,v_actions IN SELECT x.table_name,x.actions FROM (VALUES
    ('leads',ARRAY['create','edit','delete']),
    ('projects',ARRAY['edit']),
    ('project_members',ARRAY['create','edit','delete']),
    ('project_sales',ARRAY['create','edit','delete']),
    ('project_financials',ARRAY['create','edit']),
    ('catalog_items',ARRAY['create','edit','delete']),
    ('catalog_item_materials',ARRAY['create','edit','delete']),
    ('quotes',ARRAY['create','edit','delete']),
    ('quote_versions',ARRAY['create','edit']),
    ('quote_rooms',ARRAY['create','edit','delete']),
    ('quote_groups',ARRAY['create','edit','delete']),
    ('quote_items',ARRAY['create','edit','delete']),
    ('quote_item_materials',ARRAY['create','edit','delete']),
    ('project_designs',ARRAY['create','edit']),
    ('design_users',ARRAY['create','edit','delete']),
    ('design_rounds',ARRAY['create','edit','delete']),
    ('project_purchasing',ARRAY['create','edit']),
    ('purchasing_users',ARRAY['create','edit','delete']),
    ('purchasing_items',ARRAY['create','edit','delete']),
    ('purchasing_receipts',ARRAY['create','edit','delete']),
    ('project_production',ARRAY['create','edit']),
    ('production_users',ARRAY['create','edit','delete']),
    ('production_items',ARRAY['create','edit','delete']),
    ('production_batches',ARRAY['create','edit','delete']),
    ('project_construction',ARRAY['create','edit']),
    ('construction_users',ARRAY['create','edit','delete']),
    ('construction_items',ARRAY['create','edit','delete']),
    ('construction_batches',ARRAY['create','edit','delete']),
    ('construction_expense_categories',ARRAY['create','edit']),
    ('construction_expenses',ARRAY['create','edit','delete']),
    ('project_acceptance',ARRAY['create','edit']),
    ('acceptance_users',ARRAY['create','edit']),
    ('acceptance_rounds',ARRAY['create','edit','delete']),
    ('project_payments',ARRAY['create','edit','delete']),
    ('documents',ARRAY['create','edit','delete'])
  ) AS x(table_name,actions) LOOP
    FOREACH a IN ARRAY v_actions LOOP
      IF a='create' THEN
        EXECUTE format('GRANT INSERT ON public.%I TO authenticated',t);
        EXECUTE format('CREATE POLICY %I ON public.%I FOR INSERT TO authenticated '
          ||'WITH CHECK (public.can_access_row(company_id,%L,to_jsonb(%I),%L))',
          'insert_'||t,t,t,t,a);
      ELSIF a='edit' THEN
        EXECUTE format('GRANT UPDATE ON public.%I TO authenticated',t);
        EXECUTE format('CREATE POLICY %I ON public.%I FOR UPDATE TO authenticated '
          ||'USING (public.can_access_row(company_id,%L,to_jsonb(%I),%L)) '
          ||'WITH CHECK (public.can_access_row(company_id,%L,to_jsonb(%I),%L))',
          'update_'||t,t,t,t,a,t,t,a);
      ELSE
        EXECUTE format('GRANT DELETE ON public.%I TO authenticated',t);
        EXECUTE format('CREATE POLICY %I ON public.%I FOR DELETE TO authenticated '
          ||'USING (public.can_access_row(company_id,%L,to_jsonb(%I),%L))',
          'delete_'||t,t,t,t,a);
      END IF;
    END LOOP;
  END LOOP;
END $block$;

-- Inbox is self-only; historical notifications remain after Sales removal.
CREATE POLICY read_own_notifications ON public.notifications FOR SELECT
  TO authenticated USING (recipient_user_id=app_private.actor_id(company_id)
    AND app_private.subscription_access(company_id)<>'locked'
    AND app_private.notification_event_visible(company_id,event_id));
GRANT SELECT ON public.notifications TO authenticated;

-- Profile/role/settings metadata uses separate protected checks. Users may
-- see their own row; user/role administration needs the respective permission.
CREATE POLICY read_users ON public.users FOR SELECT TO authenticated USING
  (app_private.subscription_access(company_id)<>'locked' AND
   (id=app_private.actor_id(company_id) OR
      app_private.can_view_permission(company_id,'user.view')));
GRANT SELECT ON public.users TO authenticated;
CREATE POLICY read_roles ON public.roles FOR SELECT TO authenticated USING
  (app_private.subscription_access(company_id)<>'locked' AND
    app_private.can_view_permission(company_id,'role.view'));
GRANT SELECT ON public.roles TO authenticated;
CREATE POLICY read_role_permissions ON public.role_permissions FOR SELECT TO authenticated USING
  (app_private.subscription_access(company_id)<>'locked' AND
    app_private.can_view_permission(company_id,'role.view'));
GRANT SELECT ON public.role_permissions TO authenticated;
CREATE POLICY read_user_permissions ON public.user_permissions FOR SELECT TO authenticated USING
  (app_private.subscription_access(company_id)<>'locked' AND
    app_private.can_view_permission(company_id,'user.view'));
GRANT SELECT ON public.user_permissions TO authenticated;
CREATE POLICY read_settings ON public.company_settings FOR SELECT TO authenticated USING
  (app_private.subscription_access(company_id)<>'locked' AND
    app_private.can_view_permission(company_id,'settings.view'));
GRANT SELECT ON public.company_settings TO authenticated;
CREATE POLICY read_company_subscriptions ON public.company_subscriptions FOR SELECT
  TO authenticated USING (app_private.subscription_access(company_id)<>'locked'
    AND app_private.can_view_permission(company_id,'settings.view'));
GRANT SELECT ON public.company_subscriptions TO authenticated;
CREATE POLICY read_permission_catalog ON public.permissions FOR SELECT TO authenticated USING
  (EXISTS (SELECT 1 FROM public.users u WHERE u.auth_user_id=auth.uid()
    AND u.is_active AND app_private.subscription_access(u.company_id)<>'locked'
    AND app_private.can_view_permission(u.company_id,'role.view')));
GRANT SELECT ON public.permissions TO authenticated;
CREATE POLICY read_plan_catalog ON public.subscription_plans FOR SELECT TO authenticated USING
  (EXISTS (SELECT 1 FROM public.users u WHERE u.auth_user_id=auth.uid()
    AND u.is_active AND app_private.subscription_access(u.company_id)<>'locked'));
GRANT SELECT ON public.subscription_plans TO authenticated;
CREATE POLICY read_company ON public.companies FOR SELECT TO authenticated USING
  (app_private.actor_id(id) IS NOT NULL AND
    app_private.subscription_access(id)<>'locked');
GRANT SELECT ON public.companies TO authenticated;

-- Protected role/user overrides, Quote history, registry, activity logs and
-- notification events are only changed by privileged code with explicit checks.
GRANT EXECUTE ON FUNCTION public.set_user_permission(uuid,uuid,text,text),
 public.set_project_hidden(uuid,uuid,boolean),
 public.set_role_permission(uuid,uuid,text,boolean),public.assign_user_role(uuid,uuid,uuid),
 public.create_custom_role(uuid,text,text),
 public.set_lead_assignees(uuid,uuid,uuid[]),
 public.list_lead_assignee_candidates(uuid,uuid),
 public.create_project_from_lead(uuid,uuid,text,text,boolean,boolean,boolean,boolean),
 public.apply_quote_version(uuid,uuid,uuid,text),
 public.set_project_financials(uuid,uuid,numeric,numeric),
 public.clone_quote_version(uuid,uuid),public.finalize_quote_version(uuid,uuid),
 public.set_notification_read(uuid,uuid,boolean),
 public.mark_all_notifications_read(uuid) TO authenticated;
GRANT USAGE ON SCHEMA app_private TO authenticated;
GRANT EXECUTE ON FUNCTION app_private.actor_id(uuid),
 app_private.subscription_access(uuid),app_private.has_permission(uuid,text),
 app_private.can_view_permission(uuid,text),
 app_private.notification_event_visible(uuid,uuid)
 TO authenticated;
COMMIT;
