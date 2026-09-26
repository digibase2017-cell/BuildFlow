-- 008_triggers.sql — lifecycle and tenant integrity guards; requires 001–007.
-- Draft; no PostgreSQL/Supabase Local execution yet.
BEGIN;

-- Serialize subscription changes by company; paid periods may not overlap.
-- An older grace window may overlap a newly paid period; paid access wins.
CREATE FUNCTION app_private.guard_subscription_period()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM 1 FROM public.companies WHERE id=NEW.company_id FOR UPDATE;
  IF EXISTS (SELECT 1 FROM public.company_subscriptions s
      WHERE s.company_id=NEW.company_id AND s.id IS DISTINCT FROM NEW.id
        AND s.starts_at<NEW.expires_at AND NEW.starts_at<s.expires_at) THEN
    RAISE EXCEPTION 'Overlapping paid subscription periods' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_subscription_period BEFORE INSERT OR UPDATE ON public.company_subscriptions
  FOR EACH ROW EXECUTE FUNCTION app_private.guard_subscription_period();

CREATE FUNCTION app_private.guard_quota()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_limit integer; v_used bigint;
BEGIN
  IF TG_TABLE_NAME='users' THEN
    IF TG_OP='INSERT' THEN
      IF NOT NEW.is_active THEN RETURN NEW; END IF;
    ELSIF OLD.is_active OR NOT NEW.is_active THEN
      RETURN NEW;
    END IF;
  END IF;
  PERFORM 1 FROM public.companies WHERE id=NEW.company_id FOR UPDATE;
  IF TG_TABLE_NAME='users' THEN
    SELECT max_active_users INTO v_limit FROM public.company_subscriptions
      WHERE company_id=NEW.company_id AND now()>=starts_at AND now()<expires_at
      ORDER BY starts_at DESC,id DESC LIMIT 1;
    SELECT count(*) INTO v_used FROM public.users
      WHERE company_id=NEW.company_id AND is_active;
  ELSE
    SELECT max_projects INTO v_limit FROM public.company_subscriptions
      WHERE company_id=NEW.company_id AND now()>=starts_at AND now()<expires_at
      ORDER BY starts_at DESC,id DESC LIMIT 1;
    SELECT count(*) INTO v_used FROM public.projects WHERE company_id=NEW.company_id;
  END IF;
  IF v_limit IS NULL OR v_used>=v_limit THEN
    RAISE EXCEPTION 'Subscription quota or paid period unavailable' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_user_quota BEFORE INSERT OR UPDATE OF is_active ON public.users
  FOR EACH ROW EXECUTE FUNCTION app_private.guard_quota();
CREATE TRIGGER trg_project_quota BEFORE INSERT ON public.projects
  FOR EACH ROW EXECUTE FUNCTION app_private.guard_quota();

-- Allocate Lead/Quote numbers atomically on insert; clients cannot choose or
-- later change the tenant, identity, number, or Quote's source Lead.
CREATE FUNCTION app_private.guard_lead_quote_identity()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF TG_OP='INSERT' THEN
    IF TG_TABLE_NAME='leads' THEN
      NEW.lead_number:=app_private.next_number(NEW.company_id,'lead');
      NEW.created_by:=COALESCE(NEW.created_by,app_private.actor_id(NEW.company_id));
    ELSE
      NEW.quote_number:=app_private.next_number(NEW.company_id,'quote');
    END IF;
  ELSE
    IF (NEW.company_id,NEW.id) IS DISTINCT FROM (OLD.company_id,OLD.id) THEN
      RAISE EXCEPTION 'Record identity is immutable' USING ERRCODE='23514'; END IF;
    IF TG_TABLE_NAME='leads' THEN
      IF NEW.lead_number IS DISTINCT FROM OLD.lead_number THEN
        RAISE EXCEPTION 'Lead number is immutable' USING ERRCODE='23514'; END IF;
    ELSE
      IF (NEW.lead_id,NEW.quote_number) IS DISTINCT FROM (OLD.lead_id,OLD.quote_number) THEN
        RAISE EXCEPTION 'Quote source and number are immutable' USING ERRCODE='23514'; END IF;
    END IF;
    NEW.updated_at:=now();
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_lead_identity BEFORE INSERT OR UPDATE ON public.leads
  FOR EACH ROW EXECUTE FUNCTION app_private.guard_lead_quote_identity();
CREATE TRIGGER trg_quote_identity BEFORE INSERT OR UPDATE ON public.quotes
  FOR EACH ROW EXECUTE FUNCTION app_private.guard_lead_quote_identity();

-- Shared parent lock serializes privileged assignment writes with the public
-- assignment RPC and explicit Project creation. Closed assignments stay history.
CREATE FUNCTION app_private.guard_lead_assignment()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'Lead assignment history cannot be deleted' USING ERRCODE='23514'; END IF;
  PERFORM 1 FROM public.leads WHERE company_id=NEW.company_id AND id=NEW.lead_id FOR UPDATE;
  IF NEW.unassigned_at IS NULL AND NOT EXISTS (SELECT 1 FROM public.users
      WHERE company_id=NEW.company_id AND id=NEW.user_id AND is_active) THEN
    RAISE EXCEPTION 'Lead assignee must be active in this company' USING ERRCODE='23514'; END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_lead_assignment_guard BEFORE INSERT OR UPDATE OR DELETE ON public.lead_assignments
  FOR EACH ROW EXECUTE FUNCTION app_private.guard_lead_assignment();

-- Finalized quote versions and all nested rows become immutable. A version
-- may be cloned, but the finalized source never changes.
CREATE FUNCTION app_private.guard_quote_version()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF TG_OP='DELETE' AND OLD.status='Đã chốt' THEN
    RAISE EXCEPTION 'Finalized Quote cannot be deleted' USING ERRCODE='23514';
  ELSIF TG_OP='UPDATE' AND OLD.status='Đã chốt' THEN
    RAISE EXCEPTION 'Finalized Quote cannot be modified' USING ERRCODE='23514';
  END IF;
  IF TG_OP='DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_guard_quote_version BEFORE UPDATE OR DELETE
  ON public.quote_versions FOR EACH ROW EXECUTE FUNCTION app_private.guard_quote_version();

CREATE FUNCTION app_private.guard_quote_child()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_old uuid; v_new uuid; v_company uuid; v_status text;
BEGIN
  IF TG_OP<>'INSERT' THEN
    v_old:=OLD.version_id; v_company:=OLD.company_id;
    SELECT status INTO v_status FROM public.quote_versions
      WHERE company_id=v_company AND id=v_old FOR UPDATE;
    IF v_status='Đã chốt' THEN
      RAISE EXCEPTION 'Finalized Quote content is immutable' USING ERRCODE='23514'; END IF;
  END IF;
  IF TG_OP<>'DELETE' THEN
    v_new:=NEW.version_id; v_company:=NEW.company_id;
    SELECT status INTO v_status FROM public.quote_versions
      WHERE company_id=v_company AND id=v_new FOR UPDATE;
    IF v_status='Đã chốt' THEN
      RAISE EXCEPTION 'Finalized Quote content is immutable' USING ERRCODE='23514'; END IF;
  END IF;
  IF TG_OP='DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_guard_quote_rooms BEFORE INSERT OR UPDATE OR DELETE
  ON public.quote_rooms FOR EACH ROW EXECUTE FUNCTION app_private.guard_quote_child();
CREATE TRIGGER trg_guard_quote_groups BEFORE INSERT OR UPDATE OR DELETE
  ON public.quote_groups FOR EACH ROW EXECUTE FUNCTION app_private.guard_quote_child();
CREATE TRIGGER trg_guard_quote_items BEFORE INSERT OR UPDATE OR DELETE
  ON public.quote_items FOR EACH ROW EXECUTE FUNCTION app_private.guard_quote_child();
CREATE TRIGGER trg_guard_quote_materials BEFORE INSERT OR UPDATE OR DELETE
  ON public.quote_item_materials FOR EACH ROW EXECUTE FUNCTION app_private.guard_quote_child();

CREATE FUNCTION app_private.compute_quote_quantity()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF NEW.quantity_mode='auto' THEN
    NEW.quantity:=CASE NEW.unit
      WHEN 'cái' THEN NEW.item_count WHEN 'bộ' THEN NEW.item_count
      WHEN 'md' THEN NEW.length*NEW.item_count
      WHEN 'm²' THEN NEW.length*NEW.height*NEW.item_count
      WHEN 'm³' THEN NEW.length*NEW.width*NEW.height*NEW.item_count
      ELSE NULL END;
    IF NEW.quantity IS NULL OR NEW.quantity<=0 THEN
      RAISE EXCEPTION 'Quantity needs dimensions or manual mode' USING ERRCODE='23514'; END IF;
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_quote_item_quantity BEFORE INSERT OR UPDATE ON public.quote_items
  FOR EACH ROW EXECUTE FUNCTION app_private.compute_quote_quantity();

CREATE FUNCTION app_private.sync_design_round()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF TG_OP='DELETE' THEN RETURN OLD; END IF;
  IF TG_OP='INSERT' THEN
    UPDATE public.design_rounds SET status='Sửa xong',updated_at=now()
      WHERE company_id=NEW.company_id AND design_id=NEW.design_id
        AND status='Đang sửa' AND round_number<NEW.round_number;
  END IF;
  -- Only the latest round drives the current design phase. Older history cannot
  -- reopen or approve a newer submission.
  IF NEW.id=(SELECT id FROM public.design_rounds
      WHERE company_id=NEW.company_id AND design_id=NEW.design_id
      ORDER BY round_number DESC LIMIT 1) THEN
    UPDATE public.project_designs SET
      status=CASE NEW.status
        WHEN 'Đã gửi' THEN 'Chờ khách duyệt'
        WHEN 'Đang sửa' THEN 'Đang thiết kế'
        WHEN 'Sửa xong' THEN 'Đang thiết kế'
        WHEN 'Đã duyệt' THEN 'Đã duyệt'
        ELSE status END,
      customer_approved_date=CASE WHEN NEW.status='Đã duyệt'
        THEN COALESCE(NEW.sent_at::date,CURRENT_DATE)
        WHEN NEW.status IN ('Đã gửi','Đang sửa','Sửa xong') THEN NULL
        ELSE customer_approved_date END,
      updated_at=now()
      WHERE company_id=NEW.company_id AND id=NEW.design_id
        AND status<>'Đã hủy' AND NEW.status<>'Đã hủy';
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_design_round_sync AFTER INSERT OR UPDATE OF status
  ON public.design_rounds FOR EACH ROW EXECUTE FUNCTION app_private.sync_design_round();

CREATE FUNCTION app_private.guard_derived_status()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE v_default text;
BEGIN
  v_default:=CASE TG_TABLE_NAME
    WHEN 'project_acceptance' THEN 'Chưa nghiệm thu'
    WHEN 'project_purchasing' THEN 'Chưa đặt'
    WHEN 'project_production' THEN 'Chưa sản xuất' END;
  IF TG_OP='INSERT' AND NEW.status IS DISTINCT FROM v_default THEN
    RAISE EXCEPTION 'Derived module status must start at default' USING ERRCODE='23514';
  ELSIF TG_OP='UPDATE' AND current_user='authenticated'
    AND NEW.status IS DISTINCT FROM OLD.status THEN
    RAISE EXCEPTION 'Derived module status is system-managed' USING ERRCODE='42501';
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_guard_acceptance_status BEFORE INSERT OR UPDATE ON public.project_acceptance
  FOR EACH ROW EXECUTE FUNCTION app_private.guard_derived_status();
CREATE TRIGGER trg_guard_purchasing_status BEFORE INSERT OR UPDATE ON public.project_purchasing
  FOR EACH ROW EXECUTE FUNCTION app_private.guard_derived_status();
CREATE TRIGGER trg_guard_production_status BEFORE INSERT OR UPDATE ON public.project_production
  FOR EACH ROW EXECUTE FUNCTION app_private.guard_derived_status();

-- A number revision tracks actual deadline changes, including A -> B -> A.
CREATE FUNCTION app_private.bump_deadline_revision()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF NEW.deadline IS DISTINCT FROM OLD.deadline THEN
    NEW.deadline_revision:=OLD.deadline_revision+1;
  ELSIF NEW.deadline_revision IS DISTINCT FROM OLD.deadline_revision THEN
    RAISE EXCEPTION 'Deadline revision is system-managed' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_project_deadline_revision BEFORE UPDATE ON public.projects
  FOR EACH ROW EXECUTE FUNCTION app_private.bump_deadline_revision();
CREATE TRIGGER trg_design_deadline_revision BEFORE UPDATE ON public.project_designs
  FOR EACH ROW EXECUTE FUNCTION app_private.bump_deadline_revision();
CREATE TRIGGER trg_purchasing_deadline_revision BEFORE UPDATE ON public.project_purchasing
  FOR EACH ROW EXECUTE FUNCTION app_private.bump_deadline_revision();
CREATE TRIGGER trg_production_deadline_revision BEFORE UPDATE ON public.project_production
  FOR EACH ROW EXECUTE FUNCTION app_private.bump_deadline_revision();
CREATE TRIGGER trg_construction_deadline_revision BEFORE UPDATE ON public.project_construction
  FOR EACH ROW EXECUTE FUNCTION app_private.bump_deadline_revision();
CREATE TRIGGER trg_production_item_deadline_revision BEFORE UPDATE ON public.production_items
  FOR EACH ROW EXECUTE FUNCTION app_private.bump_deadline_revision();
CREATE TRIGGER trg_construction_item_deadline_revision BEFORE UPDATE ON public.construction_items
  FOR EACH ROW EXECUTE FUNCTION app_private.bump_deadline_revision();
CREATE FUNCTION app_private.bump_receipt_revision()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF NEW.expected_receipt_date IS DISTINCT FROM OLD.expected_receipt_date THEN
    NEW.expected_receipt_revision:=OLD.expected_receipt_revision+1;
  ELSIF NEW.expected_receipt_revision IS DISTINCT FROM OLD.expected_receipt_revision THEN
    RAISE EXCEPTION 'Receipt revision is system-managed' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_receipt_deadline_revision BEFORE UPDATE ON public.purchasing_items
  FOR EACH ROW EXECUTE FUNCTION app_private.bump_receipt_revision();

-- Assignees must be active. Module assignees must be Project members. Sales
-- department eligibility is explicit in this draft; review department codes
-- before deploying with real Partner data.
CREATE FUNCTION app_private.guard_assignee()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_project uuid; v_department text; v_active boolean;
BEGIN
  SELECT is_active,department INTO v_active,v_department FROM public.users
    WHERE company_id=NEW.company_id AND id=NEW.user_id;
  IF v_active IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Assignee must be active' USING ERRCODE='23514'; END IF;
  CASE TG_TABLE_NAME
    WHEN 'project_members' THEN RETURN NEW;
    WHEN 'project_sales' THEN
      v_project:=NEW.project_id;
      IF v_department IS DISTINCT FROM 'Sales' THEN
        RAISE EXCEPTION 'Project Sales needs Sales department' USING ERRCODE='23514'; END IF;
    WHEN 'design_users' THEN
      SELECT project_id INTO v_project FROM public.project_designs
        WHERE company_id=NEW.company_id AND id=NEW.design_id;
    WHEN 'purchasing_users' THEN
      SELECT project_id INTO v_project FROM public.project_purchasing
        WHERE company_id=NEW.company_id AND id=NEW.purchasing_id;
    WHEN 'production_users' THEN
      SELECT project_id INTO v_project FROM public.project_production
        WHERE company_id=NEW.company_id AND id=NEW.production_id;
    WHEN 'construction_users' THEN
      SELECT project_id INTO v_project FROM public.project_construction
        WHERE company_id=NEW.company_id AND id=NEW.construction_id;
    WHEN 'acceptance_users' THEN v_project:=NEW.project_id;
  END CASE;
  IF v_project IS NULL OR NOT EXISTS (SELECT 1 FROM public.project_members pm
    WHERE pm.company_id=NEW.company_id AND pm.project_id=v_project
      AND pm.user_id=NEW.user_id) THEN
    RAISE EXCEPTION 'Assignee must belong to Project' USING ERRCODE='23514'; END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_project_member BEFORE INSERT OR UPDATE ON public.project_members
  FOR EACH ROW EXECUTE FUNCTION app_private.guard_assignee();
CREATE TRIGGER trg_project_sales_assignee BEFORE INSERT OR UPDATE ON public.project_sales
  FOR EACH ROW EXECUTE FUNCTION app_private.guard_assignee();
CREATE TRIGGER trg_design_assignee BEFORE INSERT OR UPDATE ON public.design_users
  FOR EACH ROW EXECUTE FUNCTION app_private.guard_assignee();
CREATE TRIGGER trg_purchasing_assignee BEFORE INSERT OR UPDATE ON public.purchasing_users
  FOR EACH ROW EXECUTE FUNCTION app_private.guard_assignee();
CREATE TRIGGER trg_production_assignee BEFORE INSERT OR UPDATE ON public.production_users
  FOR EACH ROW EXECUTE FUNCTION app_private.guard_assignee();
CREATE TRIGGER trg_construction_assignee BEFORE INSERT OR UPDATE ON public.construction_users
  FOR EACH ROW EXECUTE FUNCTION app_private.guard_assignee();
CREATE TRIGGER trg_acceptance_assignee BEFORE INSERT OR UPDATE ON public.acceptance_users
  FOR EACH ROW EXECUTE FUNCTION app_private.guard_assignee();

CREATE FUNCTION app_private.guard_enabled_module()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_enabled boolean;
BEGIN
  IF TG_OP='UPDATE' AND
     (NEW.company_id,NEW.id,NEW.project_id) IS DISTINCT FROM
     (OLD.company_id,OLD.id,OLD.project_id) THEN
    RAISE EXCEPTION 'Module cannot move to another Project' USING ERRCODE='23514';
  END IF;
  SELECT CASE TG_TABLE_NAME
    WHEN 'project_designs' THEN p.has_design
    WHEN 'project_purchasing' THEN p.has_purchasing
    WHEN 'project_production' THEN p.has_production
    WHEN 'project_construction' THEN p.has_construction END
    INTO v_enabled FROM public.projects p
    WHERE p.company_id=NEW.company_id AND p.id=NEW.project_id;
  IF v_enabled IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Project module is disabled' USING ERRCODE='23514'; END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_enabled_design BEFORE INSERT OR UPDATE ON public.project_designs
  FOR EACH ROW EXECUTE FUNCTION app_private.guard_enabled_module();
CREATE TRIGGER trg_enabled_purchasing BEFORE INSERT OR UPDATE ON public.project_purchasing
  FOR EACH ROW EXECUTE FUNCTION app_private.guard_enabled_module();
CREATE TRIGGER trg_enabled_production BEFORE INSERT OR UPDATE ON public.project_production
  FOR EACH ROW EXECUTE FUNCTION app_private.guard_enabled_module();
CREATE TRIGGER trg_enabled_construction BEFORE INSERT OR UPDATE ON public.project_construction
  FOR EACH ROW EXECUTE FUNCTION app_private.guard_enabled_module();

-- Attribution columns on direct client writes use the actual Supabase actor.
-- leads.created_by is the deliberate business-attribution exception; its true
-- actor is still recorded in activity_logs by a separate trigger below.
CREATE FUNCTION app_private.stamp_attribution()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_field text; v_old jsonb;
BEGIN
  v_actor:=app_private.actor_id(NEW.company_id);
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Active user required' USING ERRCODE='42501'; END IF;
  v_field:=TG_ARGV[0];
  IF TG_OP='INSERT' THEN
    NEW:=pg_catalog.jsonb_populate_record(NEW,pg_catalog.jsonb_build_object(v_field,v_actor));
  ELSE
    v_old:=pg_catalog.to_jsonb(OLD);
    NEW:=pg_catalog.jsonb_populate_record(NEW,
      pg_catalog.jsonb_build_object(v_field,v_old->v_field));
    IF TG_TABLE_NAME='lead_assignments' THEN
      IF (NEW.company_id,NEW.id,NEW.lead_id,NEW.user_id,NEW.assigned_at)
        IS DISTINCT FROM (OLD.company_id,OLD.id,OLD.lead_id,OLD.user_id,OLD.assigned_at) THEN
        RAISE EXCEPTION 'Lead assignment identity is immutable' USING ERRCODE='23514';
      END IF;
      IF OLD.unassigned_at IS NOT NULL AND
        (NEW.unassigned_at,NEW.unassigned_by) IS DISTINCT FROM
        (OLD.unassigned_at,OLD.unassigned_by) THEN
        RAISE EXCEPTION 'Closed Lead assignment cannot be reopened' USING ERRCODE='23514';
      END IF;
      IF OLD.unassigned_at IS NULL AND NEW.unassigned_at IS NOT NULL THEN
        NEW.unassigned_by:=v_actor;
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_stamp_lead_assignment BEFORE INSERT OR UPDATE ON public.lead_assignments
  FOR EACH ROW EXECUTE FUNCTION app_private.stamp_attribution('assigned_by');
CREATE TRIGGER trg_stamp_project_member BEFORE INSERT OR UPDATE ON public.project_members
  FOR EACH ROW EXECUTE FUNCTION app_private.stamp_attribution('added_by');
CREATE TRIGGER trg_stamp_project_sales BEFORE INSERT OR UPDATE ON public.project_sales
  FOR EACH ROW EXECUTE FUNCTION app_private.stamp_attribution('assigned_by');
CREATE TRIGGER trg_stamp_catalog_item BEFORE INSERT OR UPDATE ON public.catalog_items
  FOR EACH ROW EXECUTE FUNCTION app_private.stamp_attribution('created_by');
CREATE TRIGGER trg_stamp_quote BEFORE INSERT OR UPDATE ON public.quotes
  FOR EACH ROW EXECUTE FUNCTION app_private.stamp_attribution('created_by');
CREATE TRIGGER trg_stamp_quote_version BEFORE INSERT OR UPDATE ON public.quote_versions
  FOR EACH ROW EXECUTE FUNCTION app_private.stamp_attribution('created_by');
CREATE TRIGGER trg_stamp_design_user BEFORE INSERT OR UPDATE ON public.design_users
  FOR EACH ROW EXECUTE FUNCTION app_private.stamp_attribution('assigned_by');
CREATE TRIGGER trg_stamp_design_round BEFORE INSERT OR UPDATE ON public.design_rounds
  FOR EACH ROW EXECUTE FUNCTION app_private.stamp_attribution('created_by');
CREATE TRIGGER trg_stamp_purchasing_user BEFORE INSERT OR UPDATE ON public.purchasing_users
  FOR EACH ROW EXECUTE FUNCTION app_private.stamp_attribution('assigned_by');
CREATE TRIGGER trg_stamp_receipt BEFORE INSERT OR UPDATE ON public.purchasing_receipts
  FOR EACH ROW EXECUTE FUNCTION app_private.stamp_attribution('created_by');
CREATE TRIGGER trg_stamp_production_user BEFORE INSERT OR UPDATE ON public.production_users
  FOR EACH ROW EXECUTE FUNCTION app_private.stamp_attribution('assigned_by');
CREATE TRIGGER trg_stamp_production_batch BEFORE INSERT OR UPDATE ON public.production_batches
  FOR EACH ROW EXECUTE FUNCTION app_private.stamp_attribution('created_by');
CREATE TRIGGER trg_stamp_construction_user BEFORE INSERT OR UPDATE ON public.construction_users
  FOR EACH ROW EXECUTE FUNCTION app_private.stamp_attribution('assigned_by');
CREATE TRIGGER trg_stamp_construction_batch BEFORE INSERT OR UPDATE ON public.construction_batches
  FOR EACH ROW EXECUTE FUNCTION app_private.stamp_attribution('created_by');
CREATE TRIGGER trg_stamp_construction_expense BEFORE INSERT OR UPDATE ON public.construction_expenses
  FOR EACH ROW EXECUTE FUNCTION app_private.stamp_attribution('created_by');
CREATE TRIGGER trg_stamp_acceptance_user BEFORE INSERT OR UPDATE ON public.acceptance_users
  FOR EACH ROW EXECUTE FUNCTION app_private.stamp_attribution('assigned_by');
CREATE TRIGGER trg_stamp_acceptance_round BEFORE INSERT OR UPDATE ON public.acceptance_rounds
  FOR EACH ROW EXECUTE FUNCTION app_private.stamp_attribution('created_by');
CREATE TRIGGER trg_stamp_payment BEFORE INSERT OR UPDATE ON public.project_payments
  FOR EACH ROW EXECUTE FUNCTION app_private.stamp_attribution('created_by');
CREATE TRIGGER trg_stamp_document BEFORE INSERT OR UPDATE ON public.documents
  FOR EACH ROW EXECUTE FUNCTION app_private.stamp_attribution('uploaded_by');

-- Latest round_number determines acceptance; Project provenance controls
-- clearing an automatically written completion date on reversal.
CREATE FUNCTION app_private.sync_acceptance(p_company uuid,p_acceptance uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_project uuid; v_round uuid; v_result text; v_date date;
  v_status text; v_previous_status text;
BEGIN
  SELECT project_id,status INTO v_project,v_previous_status FROM public.project_acceptance
    WHERE company_id=p_company AND id=p_acceptance FOR UPDATE;
  IF v_project IS NULL THEN RETURN; END IF;
  SELECT id,result,round_date INTO v_round,v_result,v_date
    FROM public.acceptance_rounds WHERE company_id=p_company AND acceptance_id=p_acceptance
    ORDER BY round_number DESC LIMIT 1;
  v_status:=CASE WHEN v_round IS NULL THEN 'Chưa nghiệm thu'
     WHEN v_result='Đạt' THEN 'Đã nghiệm thu' ELSE 'Cần khắc phục' END;
  UPDATE public.project_acceptance SET status=v_status,updated_at=now()
    WHERE company_id=p_company AND id=p_acceptance;
  IF v_result='Đạt' THEN
    UPDATE public.projects SET status='Hoàn thành',completed_date=v_date,
      completion_source_acceptance_round_id=v_round,updated_at=now()
      WHERE company_id=p_company AND id=v_project
        AND status NOT IN ('Tạm dừng','Đã hủy');
  ELSE
    UPDATE public.projects p SET status='Đang thực hiện',
      completed_date=CASE WHEN p.completion_source_acceptance_round_id IS NOT NULL
        THEN NULL ELSE p.completed_date END,
      completion_source_acceptance_round_id=NULL,updated_at=now()
      WHERE p.company_id=p_company AND p.id=v_project
        AND p.status NOT IN ('Tạm dừng','Đã hủy')
        AND (p.completion_source_acceptance_round_id IS NOT NULL
          OR v_previous_status='Đã nghiệm thu');
  END IF;
END; $$;
CREATE FUNCTION app_private.on_acceptance_round()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF TG_OP='UPDATE' AND (OLD.company_id,OLD.acceptance_id,OLD.project_id)
    IS DISTINCT FROM (NEW.company_id,NEW.acceptance_id,NEW.project_id) THEN
    RAISE EXCEPTION 'Round cannot move between Projects' USING ERRCODE='23514'; END IF;
  IF TG_OP='DELETE' THEN
    PERFORM app_private.sync_acceptance(OLD.company_id,OLD.acceptance_id);
    RETURN OLD;
  END IF;
  PERFORM app_private.sync_acceptance(NEW.company_id,NEW.acceptance_id);
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_acceptance_round_sync AFTER INSERT OR UPDATE OR DELETE
  ON public.acceptance_rounds FOR EACH ROW EXECUTE FUNCTION app_private.on_acceptance_round();

CREATE FUNCTION app_private.clear_manual_completion_provenance()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF pg_catalog.pg_trigger_depth()=1
    AND NEW.completed_date IS DISTINCT FROM OLD.completed_date
    AND NEW.completion_source_acceptance_round_id
      IS NOT DISTINCT FROM OLD.completion_source_acceptance_round_id THEN
    NEW.completion_source_acceptance_round_id:=NULL;
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_manual_completion_provenance BEFORE UPDATE OF completed_date
  ON public.projects FOR EACH ROW
  EXECUTE FUNCTION app_private.clear_manual_completion_provenance();

CREATE FUNCTION app_private.guard_project_identity()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF (NEW.company_id,NEW.id,NEW.source_lead_id)
    IS DISTINCT FROM (OLD.company_id,OLD.id,OLD.source_lead_id) THEN
    RAISE EXCEPTION 'Project source identity cannot change' USING ERRCODE='23514';
  END IF;
  IF current_user='authenticated' AND
    (NEW.is_hidden IS DISTINCT FROM OLD.is_hidden OR
     NEW.current_quote_version_id IS DISTINCT FROM OLD.current_quote_version_id OR
     NEW.completion_source_acceptance_round_id
       IS DISTINCT FROM OLD.completion_source_acceptance_round_id) THEN
    RAISE EXCEPTION 'Use guarded Project workflow' USING ERRCODE='42501';
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_guard_project_identity BEFORE UPDATE ON public.projects
  FOR EACH ROW EXECUTE FUNCTION app_private.guard_project_identity();
CREATE FUNCTION app_private.guard_project_module_flags()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF (OLD.has_design AND NOT NEW.has_design AND EXISTS
       (SELECT 1 FROM public.project_designs WHERE company_id=OLD.company_id AND project_id=OLD.id))
    OR (OLD.has_purchasing AND NOT NEW.has_purchasing AND EXISTS
       (SELECT 1 FROM public.project_purchasing WHERE company_id=OLD.company_id AND project_id=OLD.id))
    OR (OLD.has_production AND NOT NEW.has_production AND EXISTS
       (SELECT 1 FROM public.project_production WHERE company_id=OLD.company_id AND project_id=OLD.id))
    OR (OLD.has_construction AND NOT NEW.has_construction AND EXISTS
       (SELECT 1 FROM public.project_construction WHERE company_id=OLD.company_id AND project_id=OLD.id)) THEN
    RAISE EXCEPTION 'Cannot disable a populated Project module' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_guard_project_module_flags BEFORE UPDATE OF
  has_design,has_purchasing,has_production,has_construction ON public.projects
  FOR EACH ROW EXECUTE FUNCTION app_private.guard_project_module_flags();

-- Batch corrections restore the saved phase, never guess "in transit" or
-- "in progress". Lock item before aggregate to serialize concurrent batches.
CREATE FUNCTION app_private.reconcile_batch(p_kind text,p_company uuid,p_item uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_required numeric; v_status text; v_before text; v_sum numeric;
BEGIN
  IF p_kind='purchasing' THEN
    SELECT required_quantity,status,pre_received_status INTO v_required,v_status,v_before
      FROM public.purchasing_items WHERE company_id=p_company AND id=p_item FOR UPDATE;
    IF NOT FOUND THEN RETURN; END IF;
    SELECT COALESCE(sum(quantity),0) INTO v_sum FROM public.purchasing_receipts
      WHERE company_id=p_company AND purchasing_item_id=p_item;
    IF v_sum<v_required AND v_status='Đã nhận' AND v_before IS NULL THEN
      RAISE EXCEPTION 'Previous purchasing phase is missing' USING ERRCODE='23514'; END IF;
    UPDATE public.purchasing_items SET
      status=CASE WHEN v_sum>=v_required THEN 'Đã nhận'
         WHEN v_status='Đã nhận' THEN v_before ELSE v_status END,
      pre_received_status=CASE WHEN v_sum>=v_required THEN
        CASE WHEN v_status='Đã nhận' THEN v_before ELSE v_status END ELSE NULL END,
      updated_at=now() WHERE company_id=p_company AND id=p_item;
  ELSIF p_kind='production' THEN
    SELECT required_quantity,status,pre_completed_status INTO v_required,v_status,v_before
      FROM public.production_items WHERE company_id=p_company AND id=p_item FOR UPDATE;
    IF NOT FOUND THEN RETURN; END IF;
    SELECT COALESCE(sum(quantity),0) INTO v_sum FROM public.production_batches
      WHERE company_id=p_company AND production_item_id=p_item;
    IF v_sum<v_required AND v_status='Hoàn thành' AND v_before IS NULL THEN
      RAISE EXCEPTION 'Previous production phase is missing' USING ERRCODE='23514'; END IF;
    UPDATE public.production_items SET
      status=CASE WHEN v_sum>=v_required THEN 'Hoàn thành'
        WHEN v_status='Hoàn thành' THEN v_before ELSE v_status END,
      pre_completed_status=CASE WHEN v_sum>=v_required THEN
        CASE WHEN v_status='Hoàn thành' THEN v_before ELSE v_status END ELSE NULL END,
      updated_at=now() WHERE company_id=p_company AND id=p_item;
  ELSIF p_kind='construction' THEN
    SELECT required_quantity,status,pre_completed_status INTO v_required,v_status,v_before
      FROM public.construction_items WHERE company_id=p_company AND id=p_item FOR UPDATE;
    IF NOT FOUND THEN RETURN; END IF;
    SELECT COALESCE(sum(quantity),0) INTO v_sum FROM public.construction_batches
      WHERE company_id=p_company AND construction_item_id=p_item;
    IF v_sum<v_required AND v_status='Hoàn thành' AND v_before IS NULL THEN
      RAISE EXCEPTION 'Previous construction phase is missing' USING ERRCODE='23514'; END IF;
    UPDATE public.construction_items SET
      status=CASE WHEN v_sum>=v_required THEN 'Hoàn thành'
        WHEN v_status='Hoàn thành' THEN v_before ELSE v_status END,
      pre_completed_status=CASE WHEN v_sum>=v_required THEN
        CASE WHEN v_status='Hoàn thành' THEN v_before ELSE v_status END ELSE NULL END,
      updated_at=now() WHERE company_id=p_company AND id=p_item;
  ELSE RAISE EXCEPTION 'Unknown batch kind' USING ERRCODE='22023'; END IF;
END; $$;
CREATE FUNCTION app_private.on_batch()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_kind text; v_old uuid; v_new uuid;
BEGIN
  v_kind:=TG_ARGV[0];
  IF TG_OP<>'INSERT' THEN
    v_old:=((to_jsonb(OLD)->>CASE v_kind
      WHEN 'purchasing' THEN 'purchasing_item_id'
      WHEN 'production' THEN 'production_item_id'
      ELSE 'construction_item_id' END))::uuid;
  END IF;
  IF TG_OP<>'DELETE' THEN
    v_new:=((to_jsonb(NEW)->>CASE v_kind
      WHEN 'purchasing' THEN 'purchasing_item_id'
      WHEN 'production' THEN 'production_item_id'
      ELSE 'construction_item_id' END))::uuid;
  END IF;
  IF v_old IS NOT NULL THEN PERFORM app_private.reconcile_batch(v_kind,OLD.company_id,v_old); END IF;
  IF v_new IS NOT NULL AND (TG_OP='INSERT' OR v_new IS DISTINCT FROM v_old) THEN
    PERFORM app_private.reconcile_batch(v_kind,NEW.company_id,v_new);
  ELSIF v_new IS NOT NULL AND TG_OP='UPDATE' THEN
    PERFORM app_private.reconcile_batch(v_kind,NEW.company_id,v_new);
  END IF;
  IF TG_OP='DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_purchasing_receipt AFTER INSERT OR UPDATE OR DELETE ON public.purchasing_receipts
  FOR EACH ROW EXECUTE FUNCTION app_private.on_batch('purchasing');
CREATE TRIGGER trg_production_batch AFTER INSERT OR UPDATE OR DELETE ON public.production_batches
  FOR EACH ROW EXECUTE FUNCTION app_private.on_batch('production');
CREATE TRIGGER trg_construction_batch AFTER INSERT OR UPDATE OR DELETE ON public.construction_batches
  FOR EACH ROW EXECUTE FUNCTION app_private.on_batch('construction');

CREATE FUNCTION app_private.on_required_quantity_change()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.required_quantity IS DISTINCT FROM OLD.required_quantity THEN
    PERFORM app_private.reconcile_batch(TG_ARGV[0],NEW.company_id,NEW.id);
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_purchasing_required_change AFTER UPDATE OF required_quantity
  ON public.purchasing_items FOR EACH ROW
  EXECUTE FUNCTION app_private.on_required_quantity_change('purchasing');
CREATE TRIGGER trg_production_required_change AFTER UPDATE OF required_quantity
  ON public.production_items FOR EACH ROW
  EXECUTE FUNCTION app_private.on_required_quantity_change('production');
CREATE TRIGGER trg_construction_required_change AFTER UPDATE OF required_quantity
  ON public.construction_items FOR EACH ROW
  EXECUTE FUNCTION app_private.on_required_quantity_change('construction');

-- Aggregate status of Purchasing and Production follows their items.
CREATE FUNCTION app_private.sync_module_items(p_kind text,p_company uuid,p_module uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_total bigint; v_done bigint; v_new bigint; v_status text;
BEGIN
  IF p_kind='purchasing' THEN
    PERFORM 1 FROM public.project_purchasing WHERE company_id=p_company AND id=p_module FOR UPDATE;
    SELECT count(*),count(*) FILTER(WHERE status='Đã nhận'),
      count(*) FILTER(WHERE status='Chưa đặt') INTO v_total,v_done,v_new
      FROM public.purchasing_items WHERE company_id=p_company AND purchasing_id=p_module;
    v_status:=CASE WHEN v_total=0 OR v_total=v_new THEN 'Chưa đặt'
      WHEN v_total=v_done THEN 'Đã xong' ELSE 'Đang mua' END;
    UPDATE public.project_purchasing SET status=v_status,updated_at=now()
      WHERE company_id=p_company AND id=p_module;
  ELSIF p_kind='production' THEN
    PERFORM 1 FROM public.project_production WHERE company_id=p_company AND id=p_module FOR UPDATE;
    SELECT count(*),count(*) FILTER(WHERE status='Hoàn thành'),
      count(*) FILTER(WHERE status='Chưa sản xuất') INTO v_total,v_done,v_new
      FROM public.production_items WHERE company_id=p_company AND production_id=p_module;
    v_status:=CASE WHEN v_total=0 OR v_total=v_new THEN 'Chưa sản xuất'
      WHEN v_total=v_done THEN 'Đã xong' ELSE 'Đang sản xuất' END;
    UPDATE public.project_production SET status=v_status,updated_at=now()
      WHERE company_id=p_company AND id=p_module;
  END IF;
END; $$;
CREATE FUNCTION app_private.on_module_item()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_kind text:=TG_ARGV[0]; v_old uuid; v_new uuid;
BEGIN
  IF TG_OP<>'INSERT' THEN
    v_old:=((to_jsonb(OLD)->>CASE WHEN v_kind='purchasing'
      THEN 'purchasing_id' ELSE 'production_id' END))::uuid;
  END IF;
  IF TG_OP<>'DELETE' THEN
    v_new:=((to_jsonb(NEW)->>CASE WHEN v_kind='purchasing'
      THEN 'purchasing_id' ELSE 'production_id' END))::uuid;
  END IF;
  IF v_old IS NOT NULL THEN PERFORM app_private.sync_module_items(v_kind,OLD.company_id,v_old); END IF;
  IF v_new IS NOT NULL AND (TG_OP='INSERT' OR v_new IS DISTINCT FROM v_old) THEN
    PERFORM app_private.sync_module_items(v_kind,NEW.company_id,v_new);
  ELSIF v_new IS NOT NULL AND TG_OP='UPDATE' THEN
    PERFORM app_private.sync_module_items(v_kind,NEW.company_id,v_new);
  END IF;
  IF TG_OP='DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_purchasing_item_status AFTER INSERT OR UPDATE OF status,required_quantity OR DELETE
  ON public.purchasing_items FOR EACH ROW EXECUTE FUNCTION app_private.on_module_item('purchasing');
CREATE TRIGGER trg_production_item_status AFTER INSERT OR UPDATE OF status,required_quantity OR DELETE
  ON public.production_items FOR EACH ROW EXECUTE FUNCTION app_private.on_module_item('production');

-- The audit table itself is append-only; writes below store only a known-safe
-- status pair, never a whole row that may include secrets or signed links.
CREATE FUNCTION app_private.guard_activity_log()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  RAISE EXCEPTION 'Activity log is append-only' USING ERRCODE='23514';
END; $$;
CREATE TRIGGER trg_activity_log_append_only BEFORE UPDATE OR DELETE
  ON public.activity_logs FOR EACH ROW EXECUTE FUNCTION app_private.guard_activity_log();
CREATE FUNCTION app_private.audit_status()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    INSERT INTO public.activity_logs(company_id,actor_user_id,action,entity_type,
      entity_id,project_id,old_data,new_data)
    VALUES(NEW.company_id,app_private.actor_id(NEW.company_id),'status.changed',
      TG_TABLE_NAME,NEW.id,CASE WHEN TG_TABLE_NAME='projects' THEN NEW.id ELSE NULL END,
      jsonb_build_object('status',OLD.status),jsonb_build_object('status',NEW.status));
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_audit_lead_status AFTER UPDATE OF status ON public.leads
  FOR EACH ROW EXECUTE FUNCTION app_private.audit_status();
CREATE TRIGGER trg_audit_project_status AFTER UPDATE OF status ON public.projects
  FOR EACH ROW EXECUTE FUNCTION app_private.audit_status();
CREATE TRIGGER trg_audit_quote_status AFTER UPDATE OF status ON public.quote_versions
  FOR EACH ROW EXECUTE FUNCTION app_private.audit_status();
CREATE FUNCTION app_private.audit_lead_creation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  INSERT INTO public.activity_logs(company_id,actor_user_id,action,entity_type,entity_id)
    VALUES(NEW.company_id,app_private.actor_id(NEW.company_id),'lead.created','leads',NEW.id);
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_audit_lead_create AFTER INSERT ON public.leads
  FOR EACH ROW EXECUTE FUNCTION app_private.audit_lead_creation();

-- Called by a trusted scheduled worker. Validate actual revision and due date
-- before inserting the event; the unique index in 005 deduplicates retries.
-- Recipient selection uses CURRENT Project Sales, eligible module assignees,
-- Supervisor Project members and active Owner/Admin users.
CREATE FUNCTION app_private.dispatch_overdue(p_company uuid,p_entity_type text,
  p_entity uuid,p_revision integer,p_title text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_project uuid; v_module uuid; v_due date; v_actual integer;
  v_status text; v_timezone text; v_event uuid;
BEGIN
  SELECT timezone INTO v_timezone FROM public.companies
    WHERE id=p_company AND status='active';
  IF v_timezone IS NULL OR app_private.subscription_access(p_company)<>'write'
    THEN RETURN NULL; END IF;
  CASE p_entity_type
    WHEN 'projects' THEN
      SELECT id,id,deadline,deadline_revision,status
        INTO v_project,v_module,v_due,v_actual,v_status FROM public.projects
        WHERE company_id=p_company AND id=p_entity;
    WHEN 'project_designs' THEN
      SELECT project_id,id,deadline,deadline_revision,status
        INTO v_project,v_module,v_due,v_actual,v_status FROM public.project_designs
        WHERE company_id=p_company AND id=p_entity;
    WHEN 'project_purchasing' THEN
      SELECT project_id,id,deadline,deadline_revision,status
        INTO v_project,v_module,v_due,v_actual,v_status FROM public.project_purchasing
        WHERE company_id=p_company AND id=p_entity;
    WHEN 'project_production' THEN
      SELECT project_id,id,deadline,deadline_revision,status
        INTO v_project,v_module,v_due,v_actual,v_status FROM public.project_production
        WHERE company_id=p_company AND id=p_entity;
    WHEN 'project_construction' THEN
      SELECT project_id,id,deadline,deadline_revision,status
        INTO v_project,v_module,v_due,v_actual,v_status FROM public.project_construction
        WHERE company_id=p_company AND id=p_entity;
    WHEN 'purchasing_items' THEN
      SELECT project_id,purchasing_id,expected_receipt_date,expected_receipt_revision,status
        INTO v_project,v_module,v_due,v_actual,v_status FROM public.purchasing_items
        WHERE company_id=p_company AND id=p_entity;
    WHEN 'production_items' THEN
      SELECT project_id,production_id,deadline,deadline_revision,status
        INTO v_project,v_module,v_due,v_actual,v_status FROM public.production_items
        WHERE company_id=p_company AND id=p_entity;
    WHEN 'construction_items' THEN
      SELECT project_id,construction_id,deadline,deadline_revision,status
        INTO v_project,v_module,v_due,v_actual,v_status FROM public.construction_items
        WHERE company_id=p_company AND id=p_entity;
    ELSE RAISE EXCEPTION 'Unsupported overdue entity' USING ERRCODE='22023';
  END CASE;
  IF v_project IS NULL OR v_due IS NULL OR v_due >= (now() AT TIME ZONE v_timezone)::date
    OR v_actual IS DISTINCT FROM p_revision
    OR v_status IN ('Hoàn thành','Đã xong','Đã nhận','Đã duyệt','Đã hủy') THEN
    RETURN NULL;
  END IF;
  IF p_title IS NULL OR length(btrim(p_title))=0 THEN
    RAISE EXCEPTION 'Title required' USING ERRCODE='22023'; END IF;
  INSERT INTO public.notification_events(company_id,event_type,entity_type,entity_id,
    project_id,deadline_revision)
    VALUES(p_company,'overdue',p_entity_type,p_entity,v_project,p_revision)
    ON CONFLICT (company_id,event_type,entity_type,entity_id,deadline_revision)
      WHERE deadline_revision IS NOT NULL DO NOTHING
    RETURNING id INTO v_event;
  IF v_event IS NULL THEN RETURN NULL; END IF;
  INSERT INTO public.notifications(company_id,event_id,recipient_user_id,title)
    SELECT p_company,v_event,x.user_id,p_title FROM (
      SELECT ps.user_id FROM public.project_sales ps
        WHERE ps.company_id=p_company AND ps.project_id=v_project
      UNION
      SELECT pm.user_id FROM public.project_members pm
        JOIN public.users u ON (u.company_id,u.id)=(pm.company_id,pm.user_id)
        JOIN public.roles r ON (r.company_id,r.id)=(u.company_id,u.role_id)
        WHERE pm.company_id=p_company AND pm.project_id=v_project
          AND r.code='supervisor'
      UNION
      SELECT u.id FROM public.users u JOIN public.roles r
        ON (r.company_id,r.id)=(u.company_id,u.role_id)
        WHERE u.company_id=p_company AND r.code IN ('owner','admin')
      UNION
      SELECT p.main_responsible_user_id FROM public.projects p
        WHERE p.company_id=p_company AND p.id=v_project AND p_entity_type='projects'
          AND p.main_responsible_user_id IS NOT NULL
      UNION
      SELECT du.user_id FROM public.design_users du
        WHERE p_entity_type='project_designs' AND du.company_id=p_company
          AND du.design_id=v_module
      UNION
      SELECT pu.user_id FROM public.purchasing_users pu
        WHERE p_entity_type IN ('project_purchasing','purchasing_items')
          AND pu.company_id=p_company AND pu.purchasing_id=v_module
      UNION
      SELECT pu.user_id FROM public.production_users pu
        WHERE p_entity_type IN ('project_production','production_items')
          AND pu.company_id=p_company AND pu.production_id=v_module
      UNION
      SELECT cu.user_id FROM public.construction_users cu
        WHERE p_entity_type IN ('project_construction','construction_items')
          AND cu.company_id=p_company AND cu.construction_id=v_module
    ) AS x JOIN public.users u ON (u.company_id,u.id)=(p_company,x.user_id)
    WHERE u.is_active AND (NOT EXISTS (SELECT 1 FROM public.projects p
      WHERE p.company_id=p_company AND p.id=v_project AND p.is_hidden)
      OR EXISTS (SELECT 1 FROM public.roles r WHERE r.company_id=u.company_id
        AND r.id=u.role_id AND r.code IN ('owner','admin')));
  RETURN v_event;
END; $$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app_private FROM PUBLIC,anon,authenticated;
COMMIT;
