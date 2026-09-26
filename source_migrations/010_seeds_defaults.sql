-- 010_seeds_defaults.sql — agreed defaults only; requires 001–009.
-- Clean-install draft. NOT executed against PostgreSQL/Supabase Local.
-- Global catalog inserts preserve existing rows. Tenant defaults initialize
-- once; rerunning must not restore permissions or categories changed by users.
BEGIN;

-- Exactly the 56 ordinary permission codes in handoff section 2.6.
-- Owner-only actions are deliberately absent from this grantable catalog.
WITH permission_groups(module_name,actions) AS (
  VALUES
    ('lead','view/create/edit/delete/assign'),
    ('quote','view/create/edit/delete/finalize/export'),
    ('project','view/create/edit/manage_members'),
    ('catalog','view/create/edit/delete'),
    ('design','view/create/edit'),
    ('purchasing','view/create/edit'),
    ('production','view/create/edit'),
    ('construction','view/create/edit'),
    ('acceptance','view/create/edit/assign'),
    ('payment','view/create/edit/delete'),
    ('financial','view/edit'),
    ('document','view/create/edit/delete'),
    ('activity_log','view'),
    ('user','view/create/edit'),
    ('role','view/create/edit'),
    ('settings','view/edit'),
    ('report','view/export')
)
INSERT INTO public.permissions(code,description)
  SELECT g.module_name||'.'||a.action_name,g.module_name||'.'||a.action_name
  FROM permission_groups AS g
  CROSS JOIN LATERAL pg_catalog.unnest(pg_catalog.string_to_array(g.actions,'/'))
    AS a(action_name)
  ON CONFLICT(code) DO NOTHING;

-- Global plan catalog, NOT a purchase or subscription activation.
-- GiB uses 1024^3 bytes. Calendar intervals are not replaced by fixed day counts.
INSERT INTO public.subscription_plans(code,name,annual_price_vnd,
  max_active_users,max_projects,r2_storage_bytes,grace_period,free_onedrive_gb)
VALUES
  ('starter','Starter',6800000,20,200,
    20::bigint*1024*1024*1024,interval '7 days',0),
  ('business','Business',16800000,100,1000,
    100::bigint*1024*1024*1024,interval '1 month',1000),
  ('enterprise','Enterprise',36800000,10000,10000,
    1000::bigint*1024*1024*1024,interval '1 year',1000)
ON CONFLICT(code) DO NOTHING;

-- Private initialization receipt: prevents later re-creation of deliberately
-- removed/renamed defaults or re-granting revoked Role permissions.
CREATE TABLE IF NOT EXISTS app_private.company_default_seed_runs (
    company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    seed_key text NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY(company_id,seed_key)
);
ALTER TABLE app_private.company_default_seed_runs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON app_private.company_default_seed_runs FROM PUBLIC,anon,authenticated;

-- Exact approved matrix, isolated from per-user overrides. No ordinary Role
-- implicitly receives lead.assign. Protected management remains separate.
CREATE OR REPLACE FUNCTION app_private.default_role_permission_codes(p_role text)
RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT codes FROM (VALUES
    ('owner',ARRAY['lead.view','lead.create','lead.edit','lead.delete','lead.assign','quote.view','quote.create','quote.edit','quote.delete','quote.finalize','quote.export','project.view','project.create','project.edit','project.manage_members','catalog.view','catalog.create','catalog.edit','catalog.delete','design.view','design.create','design.edit','purchasing.view','purchasing.create','purchasing.edit','production.view','production.create','production.edit','construction.view','construction.create','construction.edit','acceptance.view','acceptance.create','acceptance.edit','acceptance.assign','payment.view','payment.create','payment.edit','payment.delete','financial.view','financial.edit','document.view','document.create','document.edit','document.delete','activity_log.view','user.view','user.create','user.edit','role.view','role.create','role.edit','settings.view','settings.edit','report.view','report.export']::text[]),
    ('admin',ARRAY['lead.view','lead.create','lead.edit','lead.delete','lead.assign','quote.view','quote.create','quote.edit','quote.delete','quote.finalize','quote.export','project.view','project.create','project.edit','project.manage_members','catalog.view','catalog.create','catalog.edit','catalog.delete','design.view','design.create','design.edit','purchasing.view','purchasing.create','purchasing.edit','production.view','production.create','production.edit','construction.view','construction.create','construction.edit','acceptance.view','acceptance.create','acceptance.edit','acceptance.assign','payment.view','payment.create','payment.edit','payment.delete','financial.view','financial.edit','document.view','document.create','document.edit','document.delete','activity_log.view','user.view','user.create','user.edit','role.view','role.create','role.edit','settings.view','settings.edit','report.view','report.export']::text[]),
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
REVOKE ALL ON FUNCTION app_private.default_role_permission_codes(text)
  FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION app_private.seed_company_defaults(p_company uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_role record;
  v_new_role uuid;
  v_existing public.roles%ROWTYPE;
  v_count integer;
BEGIN
  -- Serialize initialization and reject nonexistent companies.
  PERFORM 1 FROM public.companies WHERE id=p_company FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Company not found' USING ERRCODE='23503';
  END IF;
  IF EXISTS (SELECT 1 FROM app_private.company_default_seed_runs
    WHERE company_id=p_company AND seed_key='agreed_lead_defaults_v2') THEN
    RETURN;
  END IF;

  FOR v_role IN SELECT code,name,protected FROM (VALUES
    ('owner','Owner',true),
    ('admin','Admin',true),
    ('marketing','Marketing',false),
    ('sales','Sales',false),
    ('project_manager','Project Manager',false),
    ('designer','Designer',false),
    ('purchasing','Purchasing',false),
    ('production','Production',false),
    ('construction','Construction',false),
    ('supervisor','Giám sát',false),
    ('accountant','Kế toán',false)
  ) AS defaults(code,name,protected) LOOP
    v_new_role:=NULL;
    INSERT INTO public.roles(company_id,code,name,is_system_default,is_protected)
      VALUES(p_company,v_role.code,v_role.name,true,v_role.protected)
      ON CONFLICT(company_id,code) DO NOTHING
      RETURNING id INTO v_new_role;

    IF v_new_role IS NULL THEN
      SELECT * INTO v_existing FROM public.roles
        WHERE company_id=p_company AND code=v_role.code FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Conflicting Role was changed during initialization'
          USING ERRCODE='40001';
      END IF;
      IF NOT v_existing.is_system_default OR
        v_existing.is_protected IS DISTINCT FROM v_role.protected THEN
        RAISE EXCEPTION 'Default Role code % conflicts with an existing custom Role',v_role.code
          USING ERRCODE='23514';
      END IF;
      -- Preserve renamed default Roles and all existing Permission decisions.
    ELSE
      INSERT INTO public.role_permissions(company_id,role_id,permission_id,granted_by)
        SELECT p_company,v_new_role,p.id,NULL FROM public.permissions p
        WHERE p.code=ANY(app_private.default_role_permission_codes(v_role.code));
      GET DIAGNOSTICS v_count=ROW_COUNT;
      IF v_count IS DISTINCT FROM cardinality(app_private.default_role_permission_codes(v_role.code)) THEN
        RAISE EXCEPTION 'Approved permissions are missing for Role %',v_role.code
          USING ERRCODE='23514';
      END IF;
    END IF;
  END LOOP;

  -- user_permissions stores exceptions only and is never populated by seeds.
  INSERT INTO public.construction_expense_categories(company_id,name,sort_order,is_hidden)
    SELECT p_company,c.name,c.sort_order,false FROM (VALUES
      ('Nhân công',1),('Vật tư',2),('Vận chuyển',3),
      ('Máy móc',4),('Thuê ngoài',5),('Khác',6)
    ) AS c(name,sort_order)
    ON CONFLICT(company_id,name) DO NOTHING;

  -- Empty configurable settings, without inventing budget/tier thresholds.
  INSERT INTO public.company_settings(company_id) VALUES(p_company)
    ON CONFLICT(company_id) DO NOTHING;
  INSERT INTO app_private.company_default_seed_runs(company_id,seed_key)
    VALUES(p_company,'agreed_lead_defaults_v2');
END; $$;
REVOKE ALL ON FUNCTION app_private.seed_company_defaults(uuid)
  FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION app_private.on_company_created_seed_defaults()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM app_private.seed_company_defaults(NEW.id);
  RETURN NEW;
END; $$;
REVOKE ALL ON FUNCTION app_private.on_company_created_seed_defaults()
  FROM PUBLIC,anon,authenticated;

-- Install for future companies. Re-running 010 never creates a second trigger.
DROP TRIGGER IF EXISTS trg_company_seed_defaults ON public.companies;
CREATE TRIGGER trg_company_seed_defaults AFTER INSERT ON public.companies
  FOR EACH ROW EXECUTE FUNCTION app_private.on_company_created_seed_defaults();

-- Also initialize companies already present at migration time.
DO $seed$
DECLARE v_company uuid;
BEGIN
  FOR v_company IN SELECT id FROM public.companies ORDER BY id LOOP
    PERFORM app_private.seed_company_defaults(v_company);
  END LOOP;
END $seed$;

COMMIT;
