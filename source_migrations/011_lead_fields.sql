-- 011_lead_fields.sql. Additive update; 001-010 remain byte-identical.
BEGIN;

CREATE TABLE public.lead_options (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  kind text NOT NULL CHECK (kind IN ('source','execution_type','building_type','failure_reason')),
  label text NOT NULL CHECK (length(btrim(label)) BETWEEN 1 AND 200 AND label=btrim(label)),
  label_key text GENERATED ALWAYS AS (lower(btrim(label))) STORED,
  is_active boolean NOT NULL DEFAULT true,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_lead_option_label UNIQUE(company_id,kind,label_key),
  CONSTRAINT uq_lead_option_identity UNIQUE(company_id,id),
  CONSTRAINT fk_lead_option_creator FOREIGN KEY(company_id,created_by)
    REFERENCES public.users(company_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_lead_options_lookup ON public.lead_options(company_id,kind,is_active,label);
ALTER TABLE public.lead_options ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lead_options FROM PUBLIC,anon,authenticated;
CREATE POLICY read_lead_options ON public.lead_options FOR SELECT TO authenticated USING (
  app_private.actor_id(company_id) IS NOT NULL
  AND app_private.subscription_access(company_id)<>'locked'
  AND ((kind IN ('source','failure_reason') AND
      (app_private.can_view_permission(company_id,'lead.view')
        OR app_private.has_permission(company_id,'lead.create')
        OR app_private.has_permission(company_id,'lead.edit')))
    OR (kind IN ('execution_type','building_type') AND
      (app_private.can_view_permission(company_id,'lead.view')
        OR app_private.has_permission(company_id,'lead.create')
        OR app_private.has_permission(company_id,'lead.edit')
        OR app_private.can_view_permission(company_id,'project.view')
        OR app_private.has_permission(company_id,'project.edit'))))
);
GRANT SELECT ON public.lead_options TO authenticated;
-- Only guarded RPCs may add/archive options; no client UPDATE/DELETE grant.

CREATE FUNCTION app_private.seed_lead_options(p_company uuid)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
  INSERT INTO public.lead_options(company_id,kind,label)
    SELECT p_company,x.kind,x.label FROM (VALUES
      ('execution_type','Xây dựng'),('execution_type','Thiết kế'),('execution_type','Thi công'),
      ('building_type','Nhà đất'),('building_type','Chung cư'),
      ('building_type','Nhà hàng'),('building_type','Khách sạn')
    ) x(kind,label)
    ON CONFLICT(company_id,kind,label_key) DO NOTHING;
$$;
REVOKE ALL ON FUNCTION app_private.seed_lead_options(uuid) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION app_private.seed_lead_options_on_company()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  PERFORM app_private.seed_lead_options(NEW.id);
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_seed_lead_options AFTER INSERT ON public.companies
  FOR EACH ROW EXECUTE FUNCTION app_private.seed_lead_options_on_company();
DO $$ DECLARE c record; BEGIN
  FOR c IN SELECT id FROM public.companies LOOP
    PERFORM app_private.seed_lead_options(c.id);
  END LOOP;
END $$;

ALTER TABLE public.leads
  ADD COLUMN source_2 text,
  ADD COLUMN source_3 text,
  ADD COLUMN execution_types text[] NOT NULL DEFAULT '{}'::text[],
  ADD COLUMN building_type text,
  ADD COLUMN budget numeric(18,0) CHECK(budget IS NULL OR budget>=0),
  ADD COLUMN failure_reason text,
  ADD CONSTRAINT chk_lead_failed_reason CHECK
    (status<>'Thất bại' OR length(btrim(coalesce(failure_reason,'')))>0);
ALTER TABLE public.projects
  ADD COLUMN execution_types text[] NOT NULL DEFAULT '{}'::text[],
  ADD COLUMN building_type text;
COMMENT ON COLUMN public.project_financials.budget IS 'User-entered Project budget (VND).';

CREATE FUNCTION app_private.option_active(p_company uuid,p_kind text,p_label text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
  SELECT EXISTS(SELECT 1 FROM public.lead_options o
    WHERE o.company_id=p_company AND o.kind=p_kind
      AND o.label_key=lower(btrim(p_label)) AND o.is_active);
$$;
REVOKE ALL ON FUNCTION app_private.option_active(uuid,text,text) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION app_private.assert_option(p_company uuid,p_kind text,p_label text)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
  IF p_label IS NOT NULL AND NOT app_private.option_active(p_company,p_kind,p_label) THEN
    RAISE EXCEPTION 'Option is unavailable' USING ERRCODE='23514';
  END IF;
END; $$;
REVOKE ALL ON FUNCTION app_private.assert_option(uuid,text,text) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION app_private.guard_lead_fields()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_label text;
BEGIN
  IF TG_OP='INSERT' OR NEW.source IS DISTINCT FROM OLD.source THEN
    PERFORM app_private.assert_option(NEW.company_id,'source',NEW.source);
  END IF;
  IF TG_OP='INSERT' OR NEW.building_type IS DISTINCT FROM OLD.building_type THEN
    PERFORM app_private.assert_option(NEW.company_id,'building_type',NEW.building_type);
  END IF;
  IF TG_OP='INSERT' OR NEW.failure_reason IS DISTINCT FROM OLD.failure_reason THEN
    PERFORM app_private.assert_option(NEW.company_id,'failure_reason',NEW.failure_reason);
  END IF;
  IF TG_OP='INSERT' OR NEW.execution_types IS DISTINCT FROM OLD.execution_types THEN
    IF array_position(NEW.execution_types,NULL) IS NOT NULL OR
      (SELECT count(*) FROM unnest(NEW.execution_types) x) <>
      (SELECT count(DISTINCT lower(btrim(x))) FROM unnest(NEW.execution_types) x) THEN
      RAISE EXCEPTION 'Duplicate or null execution type' USING ERRCODE='23514';
    END IF;
    FOREACH v_label IN ARRAY NEW.execution_types LOOP
      PERFORM app_private.assert_option(NEW.company_id,'execution_type',v_label);
    END LOOP;
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_guard_lead_fields BEFORE INSERT OR UPDATE OF
  source,building_type,failure_reason,execution_types ON public.leads
  FOR EACH ROW EXECUTE FUNCTION app_private.guard_lead_fields();

CREATE FUNCTION app_private.copy_project_lead_fields()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  SELECT l.execution_types,l.building_type INTO NEW.execution_types,NEW.building_type
    FROM public.leads l WHERE l.company_id=NEW.company_id AND l.id=NEW.source_lead_id;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_copy_project_lead_fields BEFORE INSERT ON public.projects
  FOR EACH ROW EXECUTE FUNCTION app_private.copy_project_lead_fields();
CREATE FUNCTION app_private.guard_project_lead_fields()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_label text;
BEGIN
  IF NEW.building_type IS DISTINCT FROM OLD.building_type THEN
    PERFORM app_private.assert_option(NEW.company_id,'building_type',NEW.building_type);
  END IF;
  IF NEW.execution_types IS DISTINCT FROM OLD.execution_types THEN
    IF array_position(NEW.execution_types,NULL) IS NOT NULL OR
      (SELECT count(*) FROM unnest(NEW.execution_types) x) <>
      (SELECT count(DISTINCT lower(btrim(x))) FROM unnest(NEW.execution_types) x) THEN
      RAISE EXCEPTION 'Duplicate or null execution type' USING ERRCODE='23514';
    END IF;
    FOREACH v_label IN ARRAY NEW.execution_types LOOP
      PERFORM app_private.assert_option(NEW.company_id,'execution_type',v_label);
    END LOOP;
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_guard_project_lead_fields BEFORE UPDATE OF
  building_type,execution_types ON public.projects
  FOR EACH ROW EXECUTE FUNCTION app_private.guard_project_lead_fields();

CREATE FUNCTION public.add_lead_option(p_company uuid,p_kind text,p_label text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_actor uuid; v_id uuid;
BEGIN
  v_actor:=app_private.actor_id(p_company);
  IF v_actor IS NULL OR app_private.subscription_access(p_company)<>'write' OR
    NOT (app_private.has_permission(p_company,'lead.create') OR
         app_private.has_permission(p_company,'lead.edit') OR
         (p_kind IN ('execution_type','building_type') AND
          app_private.has_permission(p_company,'project.edit'))) THEN
    RAISE EXCEPTION 'Action not permitted' USING ERRCODE='42501';
  END IF;
  IF p_kind NOT IN ('source','execution_type','building_type','failure_reason') OR
    p_label IS NULL OR length(btrim(p_label)) NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION 'Invalid option' USING ERRCODE='22023';
  END IF;
  INSERT INTO public.lead_options(company_id,kind,label,created_by)
    VALUES(p_company,p_kind,btrim(p_label),v_actor)
    ON CONFLICT(company_id,kind,label_key) DO UPDATE SET
      is_active=true,updated_at=now()
    RETURNING id INTO v_id;
  RETURN v_id;
END; $$;
CREATE FUNCTION public.archive_lead_option(p_company uuid,p_option uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_actor uuid; v_kind text;
BEGIN
  v_actor:=app_private.actor_id(p_company);
  SELECT kind INTO v_kind FROM public.lead_options
    WHERE company_id=p_company AND id=p_option FOR UPDATE;
  IF v_actor IS NULL OR v_kind IS NULL OR app_private.subscription_access(p_company)<>'write' OR
    NOT (app_private.has_permission(p_company,'lead.create') OR
         app_private.has_permission(p_company,'lead.edit') OR
         (v_kind IN ('execution_type','building_type') AND
          app_private.has_permission(p_company,'project.edit'))) THEN
    RAISE EXCEPTION 'Action not permitted' USING ERRCODE='42501';
  END IF;
  UPDATE public.lead_options SET is_active=false,updated_at=now()
    WHERE company_id=p_company AND id=p_option;
END; $$;
CREATE FUNCTION public.my_capabilities(p_company uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_role text; v_codes text[];
BEGIN
  IF app_private.actor_id(p_company) IS NULL OR app_private.subscription_access(p_company)='locked' THEN
    RAISE EXCEPTION 'Account unavailable' USING ERRCODE='42501';
  END IF;
  SELECT r.code INTO v_role FROM public.users u JOIN public.roles r
    ON (r.company_id,r.id)=(u.company_id,u.role_id)
    WHERE u.company_id=p_company AND u.id=app_private.actor_id(p_company);
  SELECT array_agg(p.code ORDER BY p.code) INTO v_codes FROM public.permissions p
    WHERE app_private.has_permission(p_company,p.code);
  RETURN jsonb_build_object('role',v_role,'permissions',coalesce(v_codes,'{}'::text[]),
    'can_write',app_private.subscription_access(p_company)='write');
END; $$;
CREATE FUNCTION public.lead_project_budgets(p_company uuid,p_lead uuid)
RETURNS TABLE(project_id uuid,project_number bigint,budget numeric,can_edit boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
  IF app_private.actor_id(p_company) IS NULL
    OR app_private.subscription_access(p_company)='locked'
    OR NOT app_private.can_view_permission(p_company,'lead.view')
    OR NOT app_private.can_lead(p_company,p_lead) THEN
    RAISE EXCEPTION 'Lead access denied' USING ERRCODE='42501'; END IF;
  RETURN QUERY SELECT p.id,p.project_number,f.budget,
    app_private.subscription_access(p_company)='write'
      AND app_private.has_permission(p_company,'lead.edit')
    FROM public.projects p LEFT JOIN public.project_financials f
      ON (f.company_id,f.project_id)=(p.company_id,p.id)
    WHERE p.company_id=p_company AND p.source_lead_id=p_lead
      AND app_private.project_is_visible(p_company,p.id)
    ORDER BY p.project_number;
END; $$;
CREATE FUNCTION public.set_project_budget(p_company uuid,p_project uuid,p_budget numeric)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_actor uuid; v_lead uuid;
BEGIN
  v_actor:=app_private.actor_id(p_company);
  IF v_actor IS NULL OR app_private.subscription_access(p_company)<>'write'
    OR (p_budget IS NOT NULL AND (p_budget<0 OR p_budget<>trunc(p_budget))) THEN
    RAISE EXCEPTION 'Budget action denied or invalid' USING ERRCODE='42501'; END IF;
  SELECT source_lead_id INTO v_lead FROM public.projects
    WHERE company_id=p_company AND id=p_project FOR UPDATE;
  IF v_lead IS NULL OR NOT app_private.project_is_visible(p_company,p_project)
    OR NOT ((app_private.has_permission(p_company,'financial.edit')
        AND app_private.can_project(p_company,p_project))
      OR (app_private.has_permission(p_company,'lead.edit')
        AND app_private.can_lead(p_company,v_lead))) THEN
    RAISE EXCEPTION 'Project budget access denied' USING ERRCODE='42501'; END IF;
  INSERT INTO public.project_financials(company_id,project_id,budget,updated_by)
    VALUES(p_company,p_project,p_budget,v_actor)
    ON CONFLICT(company_id,project_id) DO UPDATE SET
      budget=excluded.budget,updated_by=excluded.updated_by,updated_at=now();
END; $$;
GRANT EXECUTE ON FUNCTION public.add_lead_option(uuid,text,text),
  public.archive_lead_option(uuid,uuid),public.my_capabilities(uuid),
  public.lead_project_budgets(uuid,uuid),
  public.set_project_budget(uuid,uuid,numeric) TO authenticated;
COMMIT;

