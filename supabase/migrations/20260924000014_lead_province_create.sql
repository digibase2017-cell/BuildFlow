-- Company-shared province options, a per-user default, and atomic Lead creation.
BEGIN;

ALTER TABLE public.lead_options DROP CONSTRAINT lead_options_kind_check;
ALTER TABLE public.lead_options ADD CONSTRAINT lead_options_kind_check
  CHECK (kind IN ('source','execution_type','building_type','failure_reason','province'));

CREATE POLICY read_province_options ON public.lead_options FOR SELECT TO authenticated USING (
  kind='province' AND app_private.actor_id(company_id) IS NOT NULL
  AND app_private.subscription_access(company_id)<>'locked'
  AND (app_private.has_permission(company_id,'lead.create')
    OR app_private.has_permission(company_id,'lead.edit')
    OR app_private.can_view_permission(company_id,'lead.view'))
);

ALTER TABLE public.leads ADD COLUMN province text;
CREATE FUNCTION app_private.guard_lead_province()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_label text;
BEGIN
  IF NEW.province IS NOT NULL THEN
    SELECT o.label INTO v_label FROM public.lead_options o
      WHERE o.company_id=NEW.company_id AND o.kind='province'
        AND o.label_key=lower(btrim(NEW.province)) AND o.is_active;
    IF v_label IS NULL THEN RAISE EXCEPTION 'Province option is unavailable' USING ERRCODE='23514'; END IF;
    NEW.province:=v_label;
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_guard_lead_province BEFORE INSERT OR UPDATE OF province ON public.leads
  FOR EACH ROW EXECUTE FUNCTION app_private.guard_lead_province();

CREATE TABLE public.user_preferences (
  company_id uuid NOT NULL,
  user_id uuid NOT NULL,
  default_province text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(company_id,user_id),
  CONSTRAINT fk_user_preferences_user FOREIGN KEY(company_id,user_id)
    REFERENCES public.users(company_id,id) ON DELETE RESTRICT
);
ALTER TABLE public.user_preferences ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.user_preferences FROM PUBLIC,anon,authenticated;
CREATE POLICY read_own_preferences ON public.user_preferences FOR SELECT TO authenticated USING (
  user_id=app_private.actor_id(company_id)
  AND app_private.subscription_access(company_id)<>'locked');
GRANT SELECT ON public.user_preferences TO authenticated;

CREATE FUNCTION public.add_province_option(p_company uuid,p_label text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_actor uuid; v_id uuid;
BEGIN
  v_actor:=app_private.actor_id(p_company);
  IF v_actor IS NULL OR app_private.subscription_access(p_company)<>'write'
    OR NOT (app_private.has_permission(p_company,'lead.create')
      OR app_private.has_permission(p_company,'lead.edit')) THEN
    RAISE EXCEPTION 'Action not permitted' USING ERRCODE='42501'; END IF;
  IF p_label IS NULL OR length(btrim(p_label)) NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION 'Invalid province' USING ERRCODE='22023'; END IF;
  INSERT INTO public.lead_options(company_id,kind,label,created_by)
    VALUES(p_company,'province',btrim(p_label),v_actor)
    ON CONFLICT(company_id,kind,label_key) DO UPDATE SET
      is_active=true,updated_at=now()
    RETURNING id INTO v_id;
  RETURN v_id;
END; $$;

CREATE FUNCTION public.list_sale_candidates(p_company uuid)
RETURNS TABLE(user_id uuid,full_name text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
  IF app_private.actor_id(p_company) IS NULL
    OR app_private.subscription_access(p_company)='locked'
    OR NOT app_private.has_permission(p_company,'lead.assign') THEN
    RAISE EXCEPTION 'Action not permitted' USING ERRCODE='42501'; END IF;
  RETURN QUERY SELECT u.id,u.full_name FROM public.users u
    WHERE u.company_id=p_company AND u.is_active AND u.department='Sales'
    ORDER BY u.full_name,u.id;
END; $$;

CREATE FUNCTION public.create_lead_with_assignees(
  p_company uuid,p_lead uuid,p_data jsonb,p_users uuid[] DEFAULT '{}'::uuid[],
  p_make_default boolean DEFAULT false)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_actor uuid; v_lead uuid; v_users uuid[]; v_province text;
BEGIN
  v_actor:=app_private.assert_action(p_company,'lead.create');
  IF p_data IS NULL OR jsonb_typeof(p_data)<>'object'
    OR length(btrim(coalesce(p_data->>'customer_name','')))=0
    OR p_users IS NULL OR array_position(p_users,NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'Invalid Lead input' USING ERRCODE='22023'; END IF;
  SELECT coalesce(array_agg(DISTINCT x ORDER BY x),'{}'::uuid[]) INTO v_users
    FROM unnest(p_users) AS ids(x);
  IF cardinality(v_users)>0 THEN
    IF NOT app_private.has_permission(p_company,'lead.assign') THEN
      RAISE EXCEPTION 'Lead assignment denied' USING ERRCODE='42501'; END IF;
    PERFORM 1 FROM public.users u WHERE u.company_id=p_company AND u.id=ANY(v_users)
      ORDER BY u.id FOR SHARE;
    IF EXISTS (SELECT 1 FROM unnest(v_users) AS ids(x) WHERE NOT EXISTS
      (SELECT 1 FROM public.users u WHERE u.company_id=p_company AND u.id=x
        AND u.is_active AND u.department='Sales')) THEN
      RAISE EXCEPTION 'Assignee must be an active Sale in this company' USING ERRCODE='23514'; END IF;
  END IF;
  v_lead:=coalesce(p_lead,gen_random_uuid());
  INSERT INTO public.leads(id,company_id,customer_name,phone,email,zalo,address,
    source,source_2,source_3,building_type,execution_types,budget,
    customer_requirements,notes,province,created_by)
  VALUES(v_lead,p_company,btrim(p_data->>'customer_name'),nullif(btrim(p_data->>'phone'),''),
    nullif(btrim(p_data->>'email'),''),nullif(btrim(p_data->>'zalo'),''),
    nullif(btrim(p_data->>'address'),''),nullif(p_data->>'source',''),
    nullif(btrim(p_data->>'source_2'),''),nullif(btrim(p_data->>'source_3'),''),
    nullif(p_data->>'building_type',''),
    ARRAY(SELECT jsonb_array_elements_text(coalesce(p_data->'execution_types','[]'::jsonb))),
    nullif(p_data->>'budget','')::numeric,
    nullif(btrim(p_data->>'customer_requirements'),''),
    nullif(btrim(p_data->>'notes'),''),nullif(p_data->>'province',''),v_actor)
  RETURNING province INTO v_province;
  IF cardinality(v_users)>0 THEN
    INSERT INTO public.lead_assignments(company_id,lead_id,user_id,assigned_by)
      SELECT p_company,v_lead,x,v_actor FROM unnest(v_users) AS ids(x);
    INSERT INTO public.activity_logs(company_id,actor_user_id,action,entity_type,entity_id,old_data,new_data)
      VALUES(p_company,v_actor,'lead.assignees_changed','leads',v_lead,
        jsonb_build_object('user_ids','[]'::jsonb),jsonb_build_object('user_ids',v_users));
  END IF;
  IF p_make_default THEN
    IF v_province IS NULL THEN RAISE EXCEPTION 'A province is required for default' USING ERRCODE='22023'; END IF;
    INSERT INTO public.user_preferences(company_id,user_id,default_province)
      VALUES(p_company,v_actor,v_province)
      ON CONFLICT(company_id,user_id) DO UPDATE SET
        default_province=excluded.default_province,updated_at=now();
  END IF;
  RETURN v_lead;
END; $$;

REVOKE ALL ON FUNCTION public.add_province_option(uuid,text),
  public.list_sale_candidates(uuid),
  public.create_lead_with_assignees(uuid,uuid,jsonb,uuid[],boolean)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.add_province_option(uuid,text),
  public.list_sale_candidates(uuid),
  public.create_lead_with_assignees(uuid,uuid,jsonb,uuid[],boolean)
  TO authenticated;
COMMIT;
