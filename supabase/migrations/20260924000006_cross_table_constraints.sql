-- 006_cross_table_constraints.sql — clean-install draft; requires 001–005.
-- No PostgreSQL/Supabase Local execution has been performed.
-- Quoted-version lifecycle locks, authorized atomic apply/clone RPCs,
-- source immutability, status synchronization and RLS follow in 007–009.
BEGIN;

-- The finalized material must belong to this exact Quote item (and company).
-- Deferrable because cloning inserts an item before its new material alternatives,
-- then remaps finalized_material_id to the newly cloned material ID.
ALTER TABLE public.quote_items
  ADD CONSTRAINT fk_quote_items_finalized_material
  FOREIGN KEY (company_id,id,finalized_material_id)
  REFERENCES public.quote_item_materials(company_id,item_id,id)
  DEFERRABLE INITIALLY DEFERRED;

-- Each application has its own row. Reapplying a past version produces another
-- history row; there is deliberately no UNIQUE(project_id,quote_version_id).
CREATE TABLE public.project_quote_history (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL,
    project_id uuid NOT NULL,
    quote_version_id uuid NOT NULL,
    quote_id uuid NOT NULL,
    source_lead_id uuid NOT NULL,
    -- Constant checked here and tied to the current quote_versions.status by FK.
    quote_version_status text NOT NULL DEFAULT 'Đã chốt'
      CHECK (quote_version_status = 'Đã chốt'),
    applied_at timestamptz NOT NULL DEFAULT now(),
    applied_by uuid NOT NULL,
    replaced_at timestamptz,
    replaced_by uuid,
    notes text,
    CONSTRAINT uq_project_quote_history_company_id UNIQUE (company_id,id),
    CONSTRAINT uq_project_quote_history_registry_identity UNIQUE
      (company_id,id,project_id,quote_version_id),
    CONSTRAINT fk_project_quote_history_project_source FOREIGN KEY
      (company_id,project_id,source_lead_id)
      REFERENCES public.projects(company_id,id,source_lead_id)
      ON DELETE RESTRICT,
    CONSTRAINT fk_project_quote_history_quote_source FOREIGN KEY
      (company_id,quote_id,source_lead_id)
      REFERENCES public.quotes(company_id,id,lead_id) ON DELETE RESTRICT,
    CONSTRAINT fk_project_quote_history_quote_version FOREIGN KEY
      (company_id,quote_version_id,quote_id)
      REFERENCES public.quote_versions(company_id,id,quote_id) ON DELETE RESTRICT,
    CONSTRAINT fk_project_quote_history_finalized_status FOREIGN KEY
      (company_id,quote_version_id,quote_version_status)
      REFERENCES public.quote_versions(company_id,id,status) ON DELETE RESTRICT,
    CONSTRAINT fk_project_quote_history_applier FOREIGN KEY (company_id,applied_by)
      REFERENCES public.users(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_project_quote_history_replacer FOREIGN KEY (company_id,replaced_by)
      REFERENCES public.users(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT chk_project_quote_history_replacement CHECK (
      (replaced_at IS NULL AND replaced_by IS NULL)
      OR (replaced_at IS NOT NULL AND replaced_by IS NOT NULL
        AND replaced_at >= applied_at)
    )
);
CREATE UNIQUE INDEX uq_project_quote_history_active
  ON public.project_quote_history(company_id,project_id)
  WHERE replaced_at IS NULL;
CREATE INDEX idx_project_quote_history_timeline
  ON public.project_quote_history(company_id,project_id,applied_at DESC,id DESC);
CREATE INDEX idx_project_quote_history_version
  ON public.project_quote_history(company_id,quote_version_id);

-- Once recorded, an application retains its identity and actor. Closing an
-- active application is the only replacement transition; it cannot be reopened.
CREATE FUNCTION app_private.guard_project_quote_history()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
      RAISE EXCEPTION 'Applied Quote history cannot be deleted'
        USING ERRCODE = '23514';
    END IF;
    IF (NEW.id,NEW.company_id,NEW.project_id,NEW.quote_version_id,
        NEW.quote_id,NEW.source_lead_id,
        NEW.quote_version_status,NEW.applied_at,NEW.applied_by)
       IS DISTINCT FROM
       (OLD.id,OLD.company_id,OLD.project_id,OLD.quote_version_id,
        OLD.quote_id,OLD.source_lead_id,
        OLD.quote_version_status,OLD.applied_at,OLD.applied_by)
       OR (OLD.replaced_at IS NOT NULL AND
           (NEW.replaced_at,NEW.replaced_by) IS DISTINCT FROM
           (OLD.replaced_at,OLD.replaced_by)) THEN
      RAISE EXCEPTION 'Applied Quote history identity cannot be changed'
        USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION app_private.guard_project_quote_history() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER trg_guard_project_quote_history
BEFORE UPDATE OR DELETE ON public.project_quote_history
FOR EACH ROW EXECUTE FUNCTION app_private.guard_project_quote_history();

-- Persistent registry proves a version has EVER been applied to this Project.
-- The first_history_id composite FK requires a real application row; no
-- UNIQUE(project_id,version_id) is placed on the history itself. This registry
-- survives V1 -> V2 -> V1 and preserves validity of snapshots copied from V1.
CREATE TABLE public.project_applied_quote_versions (
    company_id uuid NOT NULL,
    project_id uuid NOT NULL,
    quote_version_id uuid NOT NULL,
    first_history_id uuid NOT NULL,
    PRIMARY KEY (company_id,project_id,quote_version_id),
    CONSTRAINT uq_project_applied_quote_versions_history UNIQUE (company_id,first_history_id),
    CONSTRAINT fk_project_applied_quote_versions_first_history FOREIGN KEY
      (company_id,first_history_id,project_id,quote_version_id)
      REFERENCES public.project_quote_history
        (company_id,id,project_id,quote_version_id)
      ON DELETE RESTRICT
);
CREATE INDEX idx_project_applied_quote_versions_version
  ON public.project_applied_quote_versions(company_id,quote_version_id);

-- Complete the two-way proof: every history row has a registry row, and every
-- registry row points back to its first real history row. The history-to-registry
-- FK is deferred: the apply RPC inserts history first, then its registry entry.
ALTER TABLE public.project_quote_history
  ADD CONSTRAINT fk_project_quote_history_registry FOREIGN KEY
    (company_id,project_id,quote_version_id)
    REFERENCES public.project_applied_quote_versions
      (company_id,project_id,quote_version_id)
    DEFERRABLE INITIALLY DEFERRED;

-- The registry is an irreversible proof of historical application.
CREATE FUNCTION app_private.guard_applied_quote_registry()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    RAISE EXCEPTION 'Applied Quote version registry cannot be changed'
      USING ERRCODE = '23514';
END;
$$;
REVOKE ALL ON FUNCTION app_private.guard_applied_quote_registry() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER trg_guard_applied_quote_registry
BEFORE UPDATE OR DELETE ON public.project_applied_quote_versions
FOR EACH ROW EXECUTE FUNCTION app_private.guard_applied_quote_registry();

-- The current pointer must be a version applied to this exact Project.
-- The deferred state check below also requires precisely the active history
-- row to match; NULL remains valid for an external Excel Quote.
ALTER TABLE public.projects
  ADD CONSTRAINT fk_projects_current_applied_quote
  FOREIGN KEY (company_id,id,current_quote_version_id)
  REFERENCES public.project_applied_quote_versions
    (company_id,project_id,quote_version_id)
  DEFERRABLE INITIALLY DEFERRED;

-- Every copied Quote source belongs to the item's actual parent Project,
-- to the referenced Quote item/version, and to a version applied in history.
-- The 004 CHECK constraints pair NULL source_item and source_version, avoiding
-- nullable-component bypass for manual/Catalog snapshots.
ALTER TABLE public.purchasing_items
  ADD CONSTRAINT fk_purchasing_items_applied_quote FOREIGN KEY
    (company_id,project_id,source_quote_version_id)
    REFERENCES public.project_applied_quote_versions
      (company_id,project_id,quote_version_id) ON DELETE RESTRICT;
ALTER TABLE public.production_items
  ADD CONSTRAINT fk_production_items_applied_quote FOREIGN KEY
    (company_id,project_id,source_quote_version_id)
    REFERENCES public.project_applied_quote_versions
      (company_id,project_id,quote_version_id) ON DELETE RESTRICT;
ALTER TABLE public.construction_items
  ADD CONSTRAINT fk_construction_items_applied_quote FOREIGN KEY
    (company_id,project_id,source_quote_version_id)
    REFERENCES public.project_applied_quote_versions
      (company_id,project_id,quote_version_id) ON DELETE RESTRICT;

-- A completion-source round is anchored to this exact Project, not merely a
-- round with the same company. The round's acceptance parent has a matching
-- project_id composite FK defined in 005.
ALTER TABLE public.projects
  ADD CONSTRAINT fk_projects_completion_source_round
  FOREIGN KEY (company_id,id,completion_source_acceptance_round_id)
  REFERENCES public.acceptance_rounds(company_id,project_id,id)
  DEFERRABLE INITIALLY DEFERRED;

-- Check the final state at transaction end, permitting the protected apply
-- RPC to close the old row, insert a new row and update the current pointer
-- atomically in any order. Lock the parent row to serialize competing writes.
CREATE FUNCTION app_private.check_project_quote_state()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_company uuid;
    v_project uuid;
    v_current uuid;
    v_active uuid;
BEGIN
    IF TG_OP = 'DELETE' THEN
      v_company := OLD.company_id;
      IF TG_TABLE_NAME = 'projects' THEN
        v_project := OLD.id;
      ELSE
        v_project := OLD.project_id;
      END IF;
    ELSIF TG_TABLE_NAME = 'projects' THEN
      v_company := NEW.company_id;
      v_project := NEW.id;
    ELSE
      v_company := NEW.company_id;
      v_project := NEW.project_id;
    END IF;

    SELECT p.current_quote_version_id INTO v_current
    FROM public.projects AS p
    WHERE p.company_id = v_company AND p.id = v_project
    FOR UPDATE;
    IF NOT FOUND THEN
      RETURN NULL;
    END IF;

    SELECT h.quote_version_id INTO v_active
    FROM public.project_quote_history AS h
    WHERE h.company_id = v_company AND h.project_id = v_project
      AND h.replaced_at IS NULL;

    IF v_current IS DISTINCT FROM v_active THEN
      RAISE EXCEPTION 'Current Quote and active application history disagree for Project %', v_project
        USING ERRCODE = '23514';
    END IF;
    RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION app_private.check_project_quote_state() FROM PUBLIC,anon,authenticated;

CREATE CONSTRAINT TRIGGER trg_projects_quote_state
AFTER INSERT OR UPDATE
ON public.projects DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION app_private.check_project_quote_state();

CREATE CONSTRAINT TRIGGER trg_project_quote_history_state
AFTER INSERT OR UPDATE OR DELETE ON public.project_quote_history
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION app_private.check_project_quote_state();

REVOKE ALL ON public.project_quote_history,public.project_applied_quote_versions
  FROM anon,authenticated;
COMMIT;
