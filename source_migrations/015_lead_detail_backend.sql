-- Lead care, scoped Lead history and Sales-only assignments. Upgrade after 014.
BEGIN;

-- Refuse to silently rewrite existing business assignments.
DO $block$
DECLARE v_invalid bigint;
BEGIN
  SELECT count(*) INTO v_invalid FROM public.lead_assignments a
    JOIN public.users u ON (u.company_id,u.id)=(a.company_id,a.user_id)
    WHERE a.unassigned_at IS NULL
      AND (NOT u.is_active OR u.department IS DISTINCT FROM 'Sales');
  IF v_invalid>0 THEN
    RAISE EXCEPTION '% open Lead assignments have inactive or non-Sales users; resolve them before migration 015',v_invalid
      USING ERRCODE='23514';
  END IF;
END $block$;

CREATE TABLE public.lead_care_activities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  lead_id uuid NOT NULL,
  content text NOT NULL CHECK (length(btrim(content))>0),
  created_by uuid NOT NULL,
  creator_name_snapshot text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT uq_lead_care_company_id UNIQUE(company_id,id),
  CONSTRAINT fk_lead_care_lead FOREIGN KEY(company_id,lead_id)
    REFERENCES public.leads(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT fk_lead_care_creator FOREIGN KEY(company_id,created_by)
    REFERENCES public.users(company_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_lead_care_recent ON public.lead_care_activities
  (company_id,lead_id,created_at DESC,id DESC);
ALTER TABLE public.lead_care_activities ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lead_care_activities FROM PUBLIC,anon,authenticated;

CREATE FUNCTION app_private.care_same_vietnam_day(p_created timestamptz,p_checked timestamptz)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path='' AS $$
  SELECT (p_created AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
       = (p_checked AT TIME ZONE 'Asia/Ho_Chi_Minh')::date;
$$;
REVOKE ALL ON FUNCTION app_private.care_same_vietnam_day(timestamptz,timestamptz)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION app_private.care_same_vietnam_day(timestamptz,timestamptz)
  TO authenticated;

CREATE FUNCTION app_private.stamp_lead_care()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_actor uuid;
BEGIN
  v_actor:=app_private.actor_id(NEW.company_id);
  IF v_actor IS NULL THEN RAISE EXCEPTION 'Active user required' USING ERRCODE='42501'; END IF;
  NEW.created_by:=v_actor;
  SELECT full_name INTO NEW.creator_name_snapshot FROM public.users
    WHERE company_id=NEW.company_id AND id=v_actor;
  NEW.created_at:=clock_timestamp();
  NEW.content:=btrim(NEW.content);
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_stamp_lead_care BEFORE INSERT ON public.lead_care_activities
  FOR EACH ROW EXECUTE FUNCTION app_private.stamp_lead_care();

CREATE FUNCTION app_private.guard_lead_care_delete()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  IF app_private.actor_id(OLD.company_id) IS DISTINCT FROM OLD.created_by
    OR app_private.subscription_access(OLD.company_id)<>'write'
    OR NOT app_private.can_view_lead(OLD.company_id,OLD.lead_id)
    OR NOT app_private.care_same_vietnam_day(OLD.created_at,clock_timestamp()) THEN
    RAISE EXCEPTION 'Care activity cannot be deleted' USING ERRCODE='42501';
  END IF;
  RETURN OLD;
END; $$;
CREATE TRIGGER trg_guard_lead_care_delete BEFORE DELETE ON public.lead_care_activities
  FOR EACH ROW EXECUTE FUNCTION app_private.guard_lead_care_delete();

CREATE POLICY read_lead_care ON public.lead_care_activities FOR SELECT TO authenticated USING (
  app_private.subscription_access(company_id)<>'locked'
  AND app_private.can_view_lead(company_id,lead_id));
CREATE POLICY insert_lead_care ON public.lead_care_activities FOR INSERT TO authenticated WITH CHECK (
  created_by=app_private.actor_id(company_id)
  AND app_private.can_view_lead(company_id,lead_id)
  AND EXISTS (SELECT 1 FROM public.leads l WHERE l.company_id=lead_care_activities.company_id
    AND l.id=lead_care_activities.lead_id)
  AND public.can_access_row(company_id,'leads',
    jsonb_build_object('company_id',company_id,'id',lead_id),'edit'));
CREATE POLICY delete_lead_care ON public.lead_care_activities FOR DELETE TO authenticated USING (
  created_by=app_private.actor_id(company_id)
  AND app_private.subscription_access(company_id)='write'
  AND app_private.can_view_lead(company_id,lead_id)
  AND app_private.care_same_vietnam_day(created_at,clock_timestamp()));
GRANT SELECT,INSERT,DELETE ON public.lead_care_activities TO authenticated;
-- RLS expressions run as the authenticated role and need EXECUTE on this
-- boolean scope helper; it reveals no Lead fields.
GRANT EXECUTE ON FUNCTION app_private.can_view_lead(uuid,uuid) TO authenticated;

CREATE FUNCTION public.delete_lead_care_activity(p_company uuid,p_activity uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE v_deleted uuid;
BEGIN
  DELETE FROM public.lead_care_activities
    WHERE company_id=p_company AND id=p_activity RETURNING id INTO v_deleted;
  RETURN v_deleted IS NOT NULL;
END; $$;
REVOKE ALL ON FUNCTION public.delete_lead_care_activity(uuid,uuid)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.delete_lead_care_activity(uuid,uuid)
  TO authenticated;
-- RLS expressions run as the authenticated role and need EXECUTE on this
-- boolean scope helper; it reveals no Lead fields.
GRANT EXECUTE ON FUNCTION app_private.can_view_lead(uuid,uuid) TO authenticated;

-- Audit remains append-only and inaccessible as a general Lead feed to Sales.
ALTER TABLE public.activity_logs ADD COLUMN actor_name_snapshot text;
CREATE INDEX idx_activity_logs_lead_history ON public.activity_logs
  (company_id,entity_type,entity_id,created_at DESC,id DESC);

-- The generic status trigger still serves Project and Quote; Lead uses the
-- grouped trigger below so each status change creates exactly one Lead event.
DROP TRIGGER trg_audit_lead_status ON public.leads;
CREATE FUNCTION app_private.audit_lead_update()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_old jsonb; v_new jsonb; v_before jsonb; v_after jsonb;
  v_actor uuid; v_actor_name text; g record;
BEGIN
  v_old:=to_jsonb(OLD); v_new:=to_jsonb(NEW);
  v_actor:=app_private.actor_id(NEW.company_id);
  SELECT full_name INTO v_actor_name FROM public.users
    WHERE company_id=NEW.company_id AND id=v_actor;
  FOR g IN SELECT * FROM (VALUES
    ('lead.customer_name_changed',ARRAY['customer_name']),
    ('lead.contact_changed',ARRAY['phone','email','zalo']),
    ('lead.address_changed',ARRAY['address','province']),
    ('lead.source_changed',ARRAY['source','source_2','source_3']),
    ('lead.type_changed',ARRAY['execution_types','building_type']),
    ('lead.budget_changed',ARRAY['budget']),
    ('lead.requirements_changed',ARRAY['customer_requirements','notes']),
    ('lead.status_changed',ARRAY['status']),
    ('lead.failure_reason_changed',ARRAY['failure_reason'])
  ) AS x(action_code,field_names) LOOP
    SELECT coalesce(jsonb_object_agg(k,v_old->k),'{}'::jsonb),
      coalesce(jsonb_object_agg(k,v_new->k),'{}'::jsonb)
      INTO v_before,v_after FROM unnest(g.field_names) AS fields(k)
      WHERE (v_old->k) IS DISTINCT FROM (v_new->k);
    IF v_before<>'{}'::jsonb THEN
      INSERT INTO public.activity_logs(company_id,actor_user_id,actor_name_snapshot,
        action,entity_type,entity_id,old_data,new_data)
      VALUES(NEW.company_id,v_actor,v_actor_name,g.action_code,'leads',NEW.id,v_before,v_after);
    END IF;
  END LOOP;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_audit_lead_update AFTER UPDATE ON public.leads
  FOR EACH ROW EXECUTE FUNCTION app_private.audit_lead_update();

-- V1 of every independent Quote is a new Quote event; V2+ is a version event.
CREATE FUNCTION app_private.audit_lead_quote_version()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_lead uuid; v_number bigint; v_actor uuid; v_actor_name text;
BEGIN
  SELECT q.lead_id,q.quote_number INTO v_lead,v_number FROM public.quotes q
    WHERE q.company_id=NEW.company_id AND q.id=NEW.quote_id;
  v_actor:=app_private.actor_id(NEW.company_id);
  SELECT full_name INTO v_actor_name FROM public.users
    WHERE company_id=NEW.company_id AND id=v_actor;
  INSERT INTO public.activity_logs(company_id,actor_user_id,actor_name_snapshot,
    action,entity_type,entity_id,new_data)
  VALUES(NEW.company_id,v_actor,v_actor_name,
    CASE WHEN NEW.version_number=1 THEN 'lead.quote_created'
      ELSE 'lead.quote_version_created' END,'leads',v_lead,
    jsonb_build_object('quote_id',NEW.quote_id,'quote_number',v_number,
      'version_id',NEW.id,'version_number',NEW.version_number));
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_audit_lead_quote_version AFTER INSERT ON public.quote_versions
  FOR EACH ROW EXECUTE FUNCTION app_private.audit_lead_quote_version();

-- Existing aggregate assignment logs remain intact. Normalize their delta
-- into displayable per-user events without changing any assignment history.
INSERT INTO public.activity_logs(company_id,actor_user_id,actor_name_snapshot,
  action,entity_type,entity_id,new_data,created_at)
SELECT l.company_id,l.actor_user_id,actor.full_name,'lead.assignee_added',
  'leads',l.entity_id,
  jsonb_build_object('user_id',x.user_id,'user_name',target.full_name),l.created_at
FROM public.activity_logs l
CROSS JOIN LATERAL jsonb_array_elements_text(coalesce(l.new_data->'user_ids','[]'::jsonb)) AS x(user_id)
LEFT JOIN public.users actor ON (actor.company_id,actor.id)=(l.company_id,l.actor_user_id)
LEFT JOIN public.users target ON (target.company_id,target.id)=(l.company_id,x.user_id::uuid)
WHERE l.entity_type='leads' AND l.action='lead.assignees_changed'
  AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(coalesce(l.old_data->'user_ids','[]'::jsonb)) old_id
    WHERE old_id=x.user_id);
INSERT INTO public.activity_logs(company_id,actor_user_id,actor_name_snapshot,
  action,entity_type,entity_id,old_data,created_at)
SELECT l.company_id,l.actor_user_id,actor.full_name,'lead.assignee_removed',
  'leads',l.entity_id,
  jsonb_build_object('user_id',x.user_id,'user_name',target.full_name),l.created_at
FROM public.activity_logs l
CROSS JOIN LATERAL jsonb_array_elements_text(coalesce(l.old_data->'user_ids','[]'::jsonb)) AS x(user_id)
LEFT JOIN public.users actor ON (actor.company_id,actor.id)=(l.company_id,l.actor_user_id)
LEFT JOIN public.users target ON (target.company_id,target.id)=(l.company_id,x.user_id::uuid)
WHERE l.entity_type='leads' AND l.action='lead.assignees_changed'
  AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(coalesce(l.new_data->'user_ids','[]'::jsonb)) new_id
    WHERE new_id=x.user_id);

-- The existing create_lead_with_assignees RPC still emits the aggregate event.
-- Expand future aggregate events as they arrive, preserving that RPC unchanged.
CREATE FUNCTION app_private.expand_lead_assignment_log()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_actor_name text; v_user record;
BEGIN
  IF NEW.action<>'lead.assignees_changed' OR NEW.entity_type<>'leads' THEN RETURN NEW; END IF;
  SELECT full_name INTO v_actor_name FROM public.users
    WHERE company_id=NEW.company_id AND id=NEW.actor_user_id;
  FOR v_user IN SELECT u.id,u.full_name FROM public.users u
    WHERE u.company_id=NEW.company_id
      AND u.id IN (SELECT x::uuid FROM jsonb_array_elements_text(coalesce(NEW.new_data->'user_ids','[]'::jsonb)) x)
      AND u.id NOT IN (SELECT x::uuid FROM jsonb_array_elements_text(coalesce(NEW.old_data->'user_ids','[]'::jsonb)) x) LOOP
    INSERT INTO public.activity_logs(company_id,actor_user_id,actor_name_snapshot,
      action,entity_type,entity_id,new_data,created_at)
    VALUES(NEW.company_id,NEW.actor_user_id,v_actor_name,'lead.assignee_added','leads',NEW.entity_id,
      jsonb_build_object('user_id',v_user.id,'user_name',v_user.full_name),NEW.created_at);
  END LOOP;
  FOR v_user IN SELECT u.id,u.full_name FROM public.users u
    WHERE u.company_id=NEW.company_id
      AND u.id IN (SELECT x::uuid FROM jsonb_array_elements_text(coalesce(NEW.old_data->'user_ids','[]'::jsonb)) x)
      AND u.id NOT IN (SELECT x::uuid FROM jsonb_array_elements_text(coalesce(NEW.new_data->'user_ids','[]'::jsonb)) x) LOOP
    INSERT INTO public.activity_logs(company_id,actor_user_id,actor_name_snapshot,
      action,entity_type,entity_id,old_data,created_at)
    VALUES(NEW.company_id,NEW.actor_user_id,v_actor_name,'lead.assignee_removed','leads',NEW.entity_id,
      jsonb_build_object('user_id',v_user.id,'user_name',v_user.full_name),NEW.created_at);
  END LOOP;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_expand_lead_assignment_log AFTER INSERT ON public.activity_logs
  FOR EACH ROW EXECUTE FUNCTION app_private.expand_lead_assignment_log();

CREATE OR REPLACE FUNCTION public.set_lead_assignees(p_company uuid,p_lead uuid,p_users uuid[])
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_actor uuid; v_actor_name text; v_before uuid[]; v_after uuid[];
  v_at timestamptz; v_user record;
BEGIN
  v_actor:=app_private.assert_action(p_company,'lead.assign');
  PERFORM 1 FROM public.leads WHERE company_id=p_company AND id=p_lead FOR UPDATE;
  IF NOT FOUND OR NOT app_private.can_view_lead(p_company,p_lead) THEN
    RAISE EXCEPTION 'Lead access denied' USING ERRCODE='42501'; END IF;
  IF p_users IS NULL OR array_position(p_users,NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'An explicit array of User IDs is required' USING ERRCODE='22023'; END IF;
  SELECT coalesce(array_agg(DISTINCT x ORDER BY x),'{}'::uuid[]) INTO v_after
    FROM unnest(p_users) AS ids(x);
  PERFORM 1 FROM public.users WHERE company_id=p_company AND id=ANY(v_after)
    ORDER BY id FOR SHARE;
  IF EXISTS (SELECT 1 FROM unnest(v_after) AS ids(x) WHERE NOT EXISTS
    (SELECT 1 FROM public.users u WHERE u.company_id=p_company AND u.id=x
      AND u.is_active AND u.department='Sales')) THEN
    RAISE EXCEPTION 'Assignee must be an active Sale in this company' USING ERRCODE='23514'; END IF;
  SELECT coalesce(array_agg(user_id ORDER BY user_id),'{}'::uuid[]) INTO v_before
    FROM public.lead_assignments WHERE company_id=p_company AND lead_id=p_lead
      AND unassigned_at IS NULL;
  IF v_before=v_after THEN RETURN; END IF;
  SELECT full_name INTO v_actor_name FROM public.users
    WHERE company_id=p_company AND id=v_actor;
  v_at:=clock_timestamp();
  UPDATE public.lead_assignments SET unassigned_at=GREATEST(v_at,assigned_at),unassigned_by=v_actor
    WHERE company_id=p_company AND lead_id=p_lead AND unassigned_at IS NULL
      AND NOT (user_id=ANY(v_after));
  INSERT INTO public.lead_assignments(company_id,lead_id,user_id,assigned_at,assigned_by)
    SELECT p_company,p_lead,x,v_at,v_actor FROM unnest(v_after) AS ids(x)
    WHERE NOT EXISTS (SELECT 1 FROM public.lead_assignments a
      WHERE a.company_id=p_company AND a.lead_id=p_lead AND a.user_id=x
        AND a.unassigned_at IS NULL);
  FOR v_user IN SELECT u.id,u.full_name FROM public.users u
    WHERE u.company_id=p_company AND u.id=ANY(v_before) AND NOT (u.id=ANY(v_after)) LOOP
    INSERT INTO public.activity_logs(company_id,actor_user_id,actor_name_snapshot,
      action,entity_type,entity_id,old_data)
    VALUES(p_company,v_actor,v_actor_name,'lead.assignee_removed','leads',p_lead,
      jsonb_build_object('user_id',v_user.id,'user_name',v_user.full_name));
  END LOOP;
  FOR v_user IN SELECT u.id,u.full_name FROM public.users u
    WHERE u.company_id=p_company AND u.id=ANY(v_after) AND NOT (u.id=ANY(v_before)) LOOP
    INSERT INTO public.activity_logs(company_id,actor_user_id,actor_name_snapshot,
      action,entity_type,entity_id,new_data)
    VALUES(p_company,v_actor,v_actor_name,'lead.assignee_added','leads',p_lead,
      jsonb_build_object('user_id',v_user.id,'user_name',v_user.full_name));
  END LOOP;
END; $$;

CREATE OR REPLACE FUNCTION app_private.guard_lead_assignment()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'Lead assignment history cannot be deleted' USING ERRCODE='23514'; END IF;
  PERFORM 1 FROM public.leads WHERE company_id=NEW.company_id AND id=NEW.lead_id FOR UPDATE;
  IF NEW.unassigned_at IS NULL THEN
    PERFORM 1 FROM public.users WHERE company_id=NEW.company_id AND id=NEW.user_id
      AND is_active AND department='Sales' FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Lead assignee must be an active Sale in this company' USING ERRCODE='23514';
    END IF;
  END IF;
  RETURN NEW;
END; $$;

CREATE FUNCTION app_private.guard_open_lead_assignments_on_user()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  IF (NEW.department IS DISTINCT FROM 'Sales' OR NOT NEW.is_active)
    AND (OLD.department IS DISTINCT FROM NEW.department OR OLD.is_active IS DISTINCT FROM NEW.is_active)
    AND EXISTS (SELECT 1 FROM public.lead_assignments a
      WHERE a.company_id=OLD.company_id AND a.user_id=OLD.id AND a.unassigned_at IS NULL) THEN
    RAISE EXCEPTION 'Remove open Lead assignments before changing this Sale department or active state'
      USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER trg_guard_open_lead_assignments_on_user
  BEFORE UPDATE OF department,is_active ON public.users
  FOR EACH ROW EXECUTE FUNCTION app_private.guard_open_lead_assignments_on_user();

DROP POLICY read_lead_assignments ON public.lead_assignments;
CREATE POLICY read_lead_assignments ON public.lead_assignments FOR SELECT TO authenticated USING (
  app_private.subscription_access(company_id)<>'locked'
  AND app_private.can_view_lead(company_id,lead_id));

CREATE FUNCTION public.list_lead_assignees(p_company uuid,p_lead uuid)
RETURNS TABLE(user_id uuid,full_name text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
  IF app_private.actor_id(p_company) IS NULL
    OR app_private.subscription_access(p_company)='locked'
    OR NOT EXISTS(SELECT 1 FROM public.leads l WHERE l.company_id=p_company AND l.id=p_lead)
    OR NOT app_private.can_view_lead(p_company,p_lead) THEN
    RAISE EXCEPTION 'Lead assignee access denied' USING ERRCODE='42501'; END IF;
  RETURN QUERY SELECT u.id,u.full_name FROM public.lead_assignments a
    JOIN public.users u ON (u.company_id,u.id)=(a.company_id,a.user_id)
    WHERE a.company_id=p_company AND a.lead_id=p_lead AND a.unassigned_at IS NULL
    ORDER BY a.assigned_at,u.id;
END; $$;
REVOKE ALL ON FUNCTION public.list_lead_assignees(uuid,uuid)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.list_lead_assignees(uuid,uuid) TO authenticated;

CREATE FUNCTION public.get_lead_creator_name(p_company uuid,p_lead uuid)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_name text;
BEGIN
  IF app_private.actor_id(p_company) IS NULL
    OR app_private.subscription_access(p_company)='locked'
    OR NOT EXISTS(SELECT 1 FROM public.leads l WHERE l.company_id=p_company AND l.id=p_lead)
    OR NOT app_private.can_view_lead(p_company,p_lead) THEN
    RAISE EXCEPTION 'Lead creator access denied' USING ERRCODE='42501'; END IF;
  SELECT u.full_name INTO v_name FROM public.leads l
    JOIN public.users u ON (u.company_id,u.id)=(l.company_id,l.created_by)
    WHERE l.company_id=p_company AND l.id=p_lead;
  RETURN v_name;
END; $$;
REVOKE ALL ON FUNCTION public.get_lead_creator_name(uuid,uuid)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.get_lead_creator_name(uuid,uuid) TO authenticated;

CREATE FUNCTION public.get_lead_history(p_company uuid,p_lead uuid,p_limit integer DEFAULT 50,
  p_before_at timestamptz DEFAULT NULL,p_before_id uuid DEFAULT NULL)
RETURNS TABLE(event_id uuid,event_at timestamptz,actor_name text,action_code text,
  message text,old_value jsonb,new_value jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100
    OR (p_before_at IS NULL)<>(p_before_id IS NULL) THEN
    RAISE EXCEPTION 'Invalid Lead history cursor or limit' USING ERRCODE='22023'; END IF;
  IF app_private.actor_id(p_company) IS NULL
    OR app_private.subscription_access(p_company)='locked'
    OR NOT EXISTS(SELECT 1 FROM public.leads l WHERE l.company_id=p_company AND l.id=p_lead)
    OR NOT app_private.can_view_lead(p_company,p_lead) THEN
    RAISE EXCEPTION 'Lead history access denied' USING ERRCODE='42501'; END IF;
  RETURN QUERY SELECT log.id,log.created_at,
    coalesce(log.actor_name_snapshot,u.full_name,'Hệ thống'),
    CASE WHEN log.action='status.changed' THEN 'lead.status_changed' ELSE log.action END,
    CASE log.action
      WHEN 'lead.customer_name_changed' THEN 'Thay đổi tên khách hàng'
      WHEN 'lead.contact_changed' THEN 'Thay đổi thông tin liên hệ'
      WHEN 'lead.address_changed' THEN 'Thay đổi địa chỉ khách hàng'
      WHEN 'lead.source_changed' THEN 'Thay đổi nguồn Lead'
      WHEN 'lead.type_changed' THEN 'Thay đổi loại thực hiện/công trình'
      WHEN 'lead.budget_changed' THEN 'Thay đổi ngân sách'
      WHEN 'lead.requirements_changed' THEN 'Thay đổi nhu cầu/ghi chú'
      WHEN 'lead.status_changed' THEN 'Thay đổi trạng thái Sale'
      WHEN 'status.changed' THEN 'Thay đổi trạng thái Sale'
      WHEN 'lead.failure_reason_changed' THEN 'Thay đổi lý do thất bại'
      WHEN 'lead.assignee_added' THEN 'Thêm người phụ trách: '||coalesce(log.new_data->>'user_name','Nhân viên')
      WHEN 'lead.assignee_removed' THEN 'Gỡ người phụ trách: '||coalesce(log.old_data->>'user_name','Nhân viên')
      WHEN 'lead.quote_created' THEN 'Tạo báo giá: BG-'||lpad(log.new_data->>'quote_number',3,'0')
      WHEN 'lead.quote_version_created' THEN 'Tạo phiên bản báo giá mới: BG-'||lpad(log.new_data->>'quote_number',3,'0')||' · V'||(log.new_data->>'version_number')
    END,
    log.old_data,log.new_data
  FROM public.activity_logs log
  LEFT JOIN public.users u ON (u.company_id,u.id)=(log.company_id,log.actor_user_id)
  WHERE log.company_id=p_company AND log.entity_type='leads' AND log.entity_id=p_lead
    AND log.action IN (
      'lead.customer_name_changed','lead.contact_changed','lead.address_changed',
      'lead.source_changed','lead.type_changed','lead.budget_changed',
      'lead.requirements_changed','lead.status_changed','status.changed',
      'lead.failure_reason_changed','lead.assignee_added','lead.assignee_removed',
      'lead.quote_created','lead.quote_version_created')
    AND (p_before_at IS NULL OR (log.created_at,log.id)<(p_before_at,p_before_id))
  ORDER BY log.created_at DESC,log.id DESC LIMIT p_limit;
END; $$;
REVOKE ALL ON FUNCTION public.get_lead_history(uuid,uuid,integer,timestamptz,uuid)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.get_lead_history(uuid,uuid,integer,timestamptz,uuid)
  TO authenticated;

COMMIT;
