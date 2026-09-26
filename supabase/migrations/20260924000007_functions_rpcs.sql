-- 007_functions_rpcs.sql — privileged helpers and guarded workflow RPCs.
-- Requires 001–006. NOT YET RUN against Supabase/PostgreSQL.
BEGIN;

CREATE FUNCTION app_private.actor_id(p_company uuid)
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT u.id FROM public.users u JOIN public.companies c ON c.id=u.company_id
  WHERE u.company_id=p_company AND u.auth_user_id=auth.uid()
    AND u.is_active AND c.status='active';
$$;
CREATE FUNCTION app_private.is_manager(p_company uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (SELECT 1 FROM public.users u JOIN public.roles r
    ON (r.company_id,r.id)=(u.company_id,u.role_id)
    WHERE u.id=app_private.actor_id(p_company) AND r.code IN ('owner','admin'));
$$;
CREATE FUNCTION app_private.is_owner(p_company uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (SELECT 1 FROM public.users u JOIN public.roles r
    ON (r.company_id,r.id)=(u.company_id,u.role_id)
    WHERE u.id=app_private.actor_id(p_company) AND r.code='owner');
$$;
CREATE FUNCTION app_private.has_permission(p_company uuid,p_code text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT COALESCE((SELECT CASE WHEN up.effect='deny' THEN false ELSE true END
    FROM public.user_permissions up JOIN public.permissions p ON p.id=up.permission_id
    WHERE up.company_id=p_company AND up.user_id=app_private.actor_id(p_company)
      AND p.code=p_code),
    EXISTS (SELECT 1 FROM public.users u JOIN public.role_permissions rp
      ON (rp.company_id,rp.role_id)=(u.company_id,u.role_id)
      JOIN public.permissions p ON p.id=rp.permission_id
      WHERE u.id=app_private.actor_id(p_company) AND p.code=p_code))
    AND app_private.actor_id(p_company) IS NOT NULL;
$$;
-- Read-only Owner/Admin exception; write checks continue to use has_permission.
CREATE FUNCTION app_private.can_view_permission(p_company uuid,p_code text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT app_private.actor_id(p_company) IS NOT NULL
    AND (app_private.is_manager(p_company) OR app_private.has_permission(p_company,p_code));
$$;
-- Paid period takes precedence over an older subscription's grace period.
CREATE FUNCTION app_private.subscription_access(p_company uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE
    WHEN EXISTS (SELECT 1 FROM public.company_subscriptions s
      WHERE s.company_id=p_company AND now()>=s.starts_at AND now()<s.expires_at)
      THEN 'write'
    WHEN EXISTS (SELECT 1 FROM public.company_subscriptions s
      WHERE s.company_id=p_company AND now()>=s.expires_at AND now()<s.grace_ends_at)
      THEN 'read_export'
    ELSE 'locked' END;
$$;
CREATE FUNCTION app_private.project_is_visible(p_company uuid,p_project uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT app_private.actor_id(p_company) IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.projects p WHERE p.company_id=p_company AND p.id=p_project
      AND (NOT p.is_hidden OR app_private.is_manager(p_company)));
$$;
CREATE FUNCTION app_private.notification_event_visible(p_company uuid,p_event uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (SELECT 1 FROM public.notification_events e
    JOIN public.notifications n ON (n.company_id,n.event_id)=(e.company_id,e.id)
    WHERE e.company_id=p_company AND e.id=p_event
      AND n.recipient_user_id=app_private.actor_id(p_company)
      AND (e.project_id IS NULL OR app_private.project_is_visible(p_company,e.project_id)));
$$;
CREATE FUNCTION app_private.can_project(p_company uuid,p_project uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT app_private.project_is_visible(p_company,p_project) AND
    (app_private.is_manager(p_company) OR EXISTS
      (SELECT 1 FROM public.project_members m WHERE m.company_id=p_company
        AND m.project_id=p_project AND m.user_id=app_private.actor_id(p_company)));
$$;
-- Assignment scope for an actual Lead row supplied by RLS, including the NEW
-- row of INSERT RETURNING. A STABLE lookup of leads cannot see that NEW row yet.
-- Action permission and subscription are checked separately by the caller.
CREATE FUNCTION app_private.lead_assignment_scope(p_company uuid,p_lead uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT app_private.actor_id(p_company) IS NOT NULL
    AND (app_private.is_manager(p_company)
      OR NOT EXISTS (SELECT 1 FROM public.lead_assignments a
        WHERE a.company_id=p_company AND a.lead_id=p_lead AND a.unassigned_at IS NULL)
      OR EXISTS (SELECT 1 FROM public.lead_assignments a
        WHERE a.company_id=p_company AND a.lead_id=p_lead
          AND a.unassigned_at IS NULL AND a.user_id=app_private.actor_id(p_company)));
$$;
-- RPC/related-row callers must additionally prove the referenced Lead exists.
-- Project membership and created_by never confer access to an assigned Lead.
CREATE FUNCTION app_private.can_lead(p_company uuid,p_lead uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (SELECT 1 FROM public.leads l WHERE l.company_id=p_company AND l.id=p_lead)
    AND app_private.lead_assignment_scope(p_company,p_lead);
$$;
CREATE FUNCTION app_private.assert_action(p_company uuid,p_code text,p_project uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid;
BEGIN
  v_actor:=app_private.actor_id(p_company);
  IF v_actor IS NULL OR NOT app_private.has_permission(p_company,p_code)
    OR app_private.subscription_access(p_company)<>'write'
    OR (p_project IS NOT NULL AND NOT app_private.can_project(p_company,p_project)) THEN
    RAISE EXCEPTION 'Action not permitted' USING ERRCODE='42501';
  END IF;
  IF p_project IS NOT NULL THEN
    -- Serialize guarded Project RPCs against hide/unhide, then recheck scope.
    PERFORM 1 FROM public.projects WHERE company_id=p_company AND id=p_project FOR UPDATE;
    IF NOT app_private.can_project(p_company,p_project) THEN
      RAISE EXCEPTION 'Project access denied' USING ERRCODE='42501'; END IF;
  END IF;
  RETURN v_actor;
END; $$;
CREATE FUNCTION app_private.next_number(p_company uuid,p_type text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_number bigint;
BEGIN
  INSERT INTO public.company_counters(company_id,counter_type,last_value)
    VALUES(p_company,p_type,1)
    ON CONFLICT(company_id,counter_type) DO UPDATE
      SET last_value=public.company_counters.last_value+1
    RETURNING last_value INTO v_number;
  RETURN v_number;
END; $$;

-- Special administration is checked by protected role code, never by a
-- grantable ordinary permission. NULL effect removes the override.
CREATE FUNCTION public.set_project_hidden(p_company uuid,p_project uuid,p_hidden boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_before boolean;
BEGIN
  v_actor:=app_private.actor_id(p_company);
  IF v_actor IS NULL OR NOT app_private.is_manager(p_company)
    OR app_private.subscription_access(p_company)<>'write' THEN
    RAISE EXCEPTION 'Owner/Admin required' USING ERRCODE='42501'; END IF;
  IF p_hidden IS NULL THEN RAISE EXCEPTION 'Explicit hidden state required' USING ERRCODE='22023'; END IF;
  SELECT is_hidden INTO v_before FROM public.projects
    WHERE company_id=p_company AND id=p_project FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Project access denied' USING ERRCODE='42501'; END IF;
  IF v_before=p_hidden THEN RETURN; END IF;
  UPDATE public.projects SET is_hidden=p_hidden,updated_at=now()
    WHERE company_id=p_company AND id=p_project;
  INSERT INTO public.activity_logs(company_id,actor_user_id,action,entity_type,entity_id,
    project_id,old_data,new_data)
    VALUES(p_company,v_actor,CASE WHEN p_hidden THEN 'project.hidden' ELSE 'project.unhidden' END,
      'projects',p_project,p_project,jsonb_build_object('is_hidden',v_before),jsonb_build_object('is_hidden',p_hidden));
END; $$;
CREATE FUNCTION public.set_user_permission(p_company uuid,p_user uuid,p_code text,p_effect text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_target_role text; v_permission uuid;
BEGIN
  v_actor:=app_private.actor_id(p_company);
  IF v_actor IS NULL OR NOT app_private.is_manager(p_company)
      OR app_private.subscription_access(p_company)<>'write' THEN
    RAISE EXCEPTION 'Action not permitted' USING ERRCODE='42501'; END IF;
  SELECT r.code INTO v_target_role FROM public.users u JOIN public.roles r
    ON (r.company_id,r.id)=(u.company_id,u.role_id)
    WHERE u.company_id=p_company AND u.id=p_user FOR UPDATE OF u;
  IF NOT FOUND OR (NOT app_private.is_owner(p_company)
     AND v_target_role IN ('owner','admin')) THEN
    RAISE EXCEPTION 'Protected user' USING ERRCODE='42501'; END IF;
  SELECT id INTO v_permission FROM public.permissions WHERE code=p_code;
  IF v_permission IS NULL OR (p_effect IS NOT NULL AND p_effect NOT IN ('allow','deny')) THEN
    RAISE EXCEPTION 'Invalid permission override' USING ERRCODE='22023'; END IF;
  IF p_effect IS NULL THEN
    DELETE FROM public.user_permissions WHERE company_id=p_company
      AND user_id=p_user AND permission_id=v_permission;
  ELSE
    INSERT INTO public.user_permissions(company_id,user_id,permission_id,effect,granted_by)
      VALUES(p_company,p_user,v_permission,p_effect,v_actor)
      ON CONFLICT(company_id,user_id,permission_id) DO UPDATE
      SET effect=EXCLUDED.effect,granted_by=EXCLUDED.granted_by,updated_at=now();
  END IF;
END; $$;
CREATE FUNCTION public.set_role_permission(p_company uuid,p_role uuid,p_code text,p_grant boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_role_code text; v_permission uuid;
BEGIN
  v_actor:=app_private.actor_id(p_company);
  IF v_actor IS NULL OR NOT app_private.is_manager(p_company)
      OR app_private.subscription_access(p_company)<>'write' THEN
    RAISE EXCEPTION 'Action not permitted' USING ERRCODE='42501'; END IF;
  SELECT code INTO v_role_code FROM public.roles WHERE company_id=p_company AND id=p_role FOR UPDATE;
  IF NOT FOUND OR (v_role_code IN ('owner','admin') AND NOT app_private.is_owner(p_company)) THEN
    RAISE EXCEPTION 'Protected role' USING ERRCODE='42501'; END IF;
  SELECT id INTO v_permission FROM public.permissions WHERE code=p_code;
  IF v_permission IS NULL OR p_grant IS NULL THEN
    RAISE EXCEPTION 'Invalid permission' USING ERRCODE='22023'; END IF;
  IF p_grant THEN
    INSERT INTO public.role_permissions(company_id,role_id,permission_id,granted_by)
      VALUES(p_company,p_role,v_permission,v_actor)
      ON CONFLICT DO NOTHING;
  ELSE
    DELETE FROM public.role_permissions WHERE company_id=p_company
      AND role_id=p_role AND permission_id=v_permission;
  END IF;
END; $$;
CREATE FUNCTION public.assign_user_role(p_company uuid,p_user uuid,p_role uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_target text; v_new text;
BEGIN
  IF NOT app_private.is_manager(p_company)
    OR app_private.subscription_access(p_company)<>'write' THEN
    RAISE EXCEPTION 'Action not permitted' USING ERRCODE='42501'; END IF;
  SELECT r.code INTO v_target FROM public.users u JOIN public.roles r
    ON (r.company_id,r.id)=(u.company_id,u.role_id)
    WHERE u.company_id=p_company AND u.id=p_user FOR UPDATE OF u;
  SELECT code INTO v_new FROM public.roles WHERE company_id=p_company AND id=p_role;
  IF v_target IS NULL OR v_new IS NULL OR
     (NOT app_private.is_owner(p_company) AND
       (v_target IN ('owner','admin') OR v_new IN ('owner','admin'))) THEN
    RAISE EXCEPTION 'Protected role assignment' USING ERRCODE='42501'; END IF;
  UPDATE public.users SET role_id=p_role,updated_at=now()
    WHERE company_id=p_company AND id=p_user;
END; $$;
CREATE FUNCTION public.create_custom_role(p_company uuid,p_code text,p_name text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_role uuid;
BEGIN
  IF NOT app_private.is_manager(p_company)
    OR app_private.subscription_access(p_company)<>'write' THEN
    RAISE EXCEPTION 'Action not permitted' USING ERRCODE='42501'; END IF;
  IF p_code IS NULL OR p_code IN ('owner','admin') THEN
    RAISE EXCEPTION 'Protected role code' USING ERRCODE='42501'; END IF;
  INSERT INTO public.roles(company_id,code,name,is_system_default,is_protected)
    VALUES(p_company,p_code,p_name,false,false) RETURNING id INTO v_role;
  RETURN v_role;
END; $$;

-- Minimal picker for a permitted Lead assignment operation. lead.assign does
-- not grant user.view or expose email/Auth/Role data from the users table.
CREATE FUNCTION public.list_lead_assignee_candidates(p_company uuid,p_lead uuid)
RETURNS TABLE(user_id uuid,full_name text) LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF app_private.actor_id(p_company) IS NULL
    OR app_private.subscription_access(p_company)='locked'
    OR NOT app_private.has_permission(p_company,'lead.assign')
    OR NOT app_private.can_view_permission(p_company,'lead.view')
    OR NOT app_private.can_lead(p_company,p_lead) THEN
    RAISE EXCEPTION 'Lead access denied' USING ERRCODE='42501'; END IF;
  RETURN QUERY SELECT u.id,u.full_name FROM public.users u
    WHERE u.company_id=p_company AND u.is_active ORDER BY u.full_name,u.id;
END; $$;

-- Replace the current assignment set atomically; retain ended history.
-- Scope is checked under the Lead lock BEFORE the set changes. A team leader
-- includes their own id in p_users to keep access. An empty array unassigns all.
CREATE FUNCTION public.set_lead_assignees(p_company uuid,p_lead uuid,p_users uuid[])
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_before uuid[]; v_after uuid[]; v_at timestamptz;
BEGIN
  v_actor:=app_private.assert_action(p_company,'lead.assign');
  PERFORM 1 FROM public.leads WHERE company_id=p_company AND id=p_lead FOR UPDATE;
  IF NOT FOUND OR NOT app_private.can_lead(p_company,p_lead)
    OR (NOT app_private.is_manager(p_company)
      AND NOT app_private.has_permission(p_company,'lead.view')) THEN
    RAISE EXCEPTION 'Lead access denied' USING ERRCODE='42501'; END IF;
  IF p_users IS NULL OR array_position(p_users,NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'An explicit array of User IDs is required' USING ERRCODE='22023'; END IF;
  SELECT COALESCE(array_agg(DISTINCT x ORDER BY x),'{}'::uuid[]) INTO v_after
    FROM unnest(p_users) AS ids(x);
  -- Lock target users while validating active status, in deterministic order.
  PERFORM 1 FROM public.users WHERE company_id=p_company AND id=ANY(v_after)
    ORDER BY id FOR SHARE;
  IF EXISTS (SELECT 1 FROM unnest(v_after) AS ids(x) WHERE NOT EXISTS
    (SELECT 1 FROM public.users u WHERE u.company_id=p_company AND u.id=x AND u.is_active)) THEN
    RAISE EXCEPTION 'Assignee must be active and in this company' USING ERRCODE='23514'; END IF;
  SELECT COALESCE(array_agg(user_id ORDER BY user_id),'{}'::uuid[]) INTO v_before
    FROM public.lead_assignments WHERE company_id=p_company AND lead_id=p_lead
      AND unassigned_at IS NULL;
  IF v_before=v_after THEN RETURN; END IF;
  v_at:=clock_timestamp();
  UPDATE public.lead_assignments SET unassigned_at=GREATEST(v_at,assigned_at),unassigned_by=v_actor
    WHERE company_id=p_company AND lead_id=p_lead AND unassigned_at IS NULL
      AND NOT (user_id=ANY(v_after));
  INSERT INTO public.lead_assignments(company_id,lead_id,user_id,assigned_at,assigned_by)
    SELECT p_company,p_lead,x,v_at,v_actor FROM unnest(v_after) AS ids(x)
    WHERE NOT EXISTS (SELECT 1 FROM public.lead_assignments a
      WHERE a.company_id=p_company AND a.lead_id=p_lead AND a.user_id=x
        AND a.unassigned_at IS NULL);
  INSERT INTO public.activity_logs(company_id,actor_user_id,action,entity_type,entity_id,old_data,new_data)
    VALUES(p_company,v_actor,'lead.assignees_changed','leads',p_lead,
      jsonb_build_object('user_ids',v_before),jsonb_build_object('user_ids',v_after));
END; $$;

-- Single statement/transaction RPC: the Company row serializes quota checks;
-- Lead row locks the success precondition, preventing a concurrent reversal.
CREATE FUNCTION public.create_project_from_lead(
  p_company uuid,p_lead uuid,p_name text,p_project_address text DEFAULT NULL,
  p_has_design boolean DEFAULT false,p_has_purchasing boolean DEFAULT false,
  p_has_production boolean DEFAULT false,p_has_construction boolean DEFAULT false)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_lead uuid; v_status text; v_project uuid;
  v_limit integer; v_count bigint;
BEGIN
  v_actor:=app_private.assert_action(p_company,'project.create');
  PERFORM 1 FROM public.companies WHERE id=p_company FOR UPDATE;
  SELECT s.max_projects INTO v_limit FROM public.company_subscriptions s
    WHERE s.company_id=p_company AND now()>=s.starts_at AND now()<s.expires_at
    ORDER BY s.starts_at DESC,s.id DESC LIMIT 1;
  IF v_limit IS NULL THEN RAISE EXCEPTION 'No paid subscription' USING ERRCODE='42501'; END IF;
  SELECT count(*) INTO v_count FROM public.projects WHERE company_id=p_company;
  IF v_count>=v_limit THEN RAISE EXCEPTION 'Project quota reached' USING ERRCODE='23514'; END IF;
  SELECT id,status INTO v_lead,v_status FROM public.leads
    WHERE company_id=p_company AND id=p_lead FOR UPDATE;
  IF NOT app_private.can_lead(p_company,p_lead)
     OR (NOT app_private.is_manager(p_company)
       AND NOT app_private.has_permission(p_company,'lead.view')) THEN
    RAISE EXCEPTION 'Lead access denied' USING ERRCODE='42501'; END IF;
  IF v_status IS DISTINCT FROM 'Thành công' THEN
    RAISE EXCEPTION 'Lead must be successful' USING ERRCODE='23514'; END IF;
  INSERT INTO public.projects(company_id,project_number,name,project_address,
    source_lead_id,has_design,has_purchasing,has_production,
    has_construction,created_by)
    VALUES(p_company,app_private.next_number(p_company,'project'),p_name,
    p_project_address,v_lead,p_has_design,p_has_purchasing,
    p_has_production,p_has_construction,v_actor) RETURNING id INTO v_project;
  INSERT INTO public.project_members(company_id,project_id,user_id,added_by)
    SELECT p_company,v_project,su.user_id,v_actor FROM public.lead_assignments su
      JOIN public.users u ON (u.company_id,u.id)=(su.company_id,su.user_id)
      WHERE su.company_id=p_company AND su.lead_id=p_lead AND su.unassigned_at IS NULL
        AND u.is_active AND u.department='Sales'
    ON CONFLICT(company_id,project_id,user_id) DO NOTHING;
  INSERT INTO public.project_members(company_id,project_id,user_id,added_by)
    VALUES(p_company,v_project,v_actor,v_actor)
    ON CONFLICT(company_id,project_id,user_id) DO NOTHING;
  INSERT INTO public.project_sales(company_id,project_id,user_id,assigned_by)
    SELECT p_company,v_project,su.user_id,v_actor FROM public.lead_assignments su
      JOIN public.users u ON (u.company_id,u.id)=(su.company_id,su.user_id)
      WHERE su.company_id=p_company AND su.lead_id=p_lead AND su.unassigned_at IS NULL
        AND u.is_active AND u.department='Sales';
  INSERT INTO public.project_financials(company_id,project_id) VALUES(p_company,v_project);
  INSERT INTO public.project_acceptance(company_id,project_id) VALUES(p_company,v_project);
  RETURN v_project;
END; $$;

CREATE FUNCTION public.apply_quote_version(p_company uuid,p_project uuid,p_version uuid,p_notes text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_project public.projects%ROWTYPE; v_quote uuid;
  v_lead uuid; v_status text; v_at timestamptz;
  v_history uuid;
BEGIN
  v_actor:=app_private.assert_action(p_company,'project.edit',p_project);
  SELECT * INTO v_project FROM public.projects
    WHERE company_id=p_company AND id=p_project FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Project not found' USING ERRCODE='P0002'; END IF;
  SELECT q.id,q.lead_id,v.status INTO v_quote,v_lead,v_status
    FROM public.quote_versions v JOIN public.quotes q
      ON (q.company_id,q.id)=(v.company_id,v.quote_id)
    WHERE v.company_id=p_company AND v.id=p_version FOR SHARE OF v,q;
  IF v_status IS DISTINCT FROM 'Đã chốt' OR v_lead<>v_project.source_lead_id THEN
    RAISE EXCEPTION 'Version is not a finalized Quote for this Project'
      USING ERRCODE='23514'; END IF;
  v_at:=clock_timestamp();
  UPDATE public.project_quote_history SET replaced_at=GREATEST(v_at,applied_at),
    replaced_by=v_actor WHERE company_id=p_company AND project_id=p_project
      AND replaced_at IS NULL;
  INSERT INTO public.project_quote_history(company_id,project_id,quote_version_id,
    quote_id,source_lead_id,applied_at,applied_by,notes)
    VALUES(p_company,p_project,p_version,v_quote,v_lead,v_at,v_actor,p_notes)
    RETURNING id INTO v_history;
  INSERT INTO public.project_applied_quote_versions(company_id,project_id,
    quote_version_id,first_history_id)
    VALUES(p_company,p_project,p_version,v_history)
    ON CONFLICT(company_id,project_id,quote_version_id) DO NOTHING;
  UPDATE public.projects SET current_quote_version_id=p_version,updated_at=now()
    WHERE company_id=p_company AND id=p_project;
  RETURN v_history;
END; $$;

-- financial.edit is independent of financial.view. This RPC can change the
-- two fields without relying on SELECT visibility of project_financials.
CREATE FUNCTION public.set_project_financials(p_company uuid,p_project uuid,
  p_budget numeric,p_contract_value numeric)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid;
BEGIN
  v_actor:=app_private.assert_action(p_company,'financial.edit',p_project);
  INSERT INTO public.project_financials(company_id,project_id,budget,
    contract_value,updated_by)
    VALUES(p_company,p_project,p_budget,p_contract_value,v_actor)
    ON CONFLICT(company_id,project_id) DO UPDATE SET
      budget=EXCLUDED.budget,contract_value=EXCLUDED.contract_value,
      updated_by=EXCLUDED.updated_by,updated_at=now();
END; $$;

-- Clone the entire hierarchy with fresh IDs. The item lineage persists, while
-- finalized material points at the corresponding *new* material row.
CREATE FUNCTION public.clone_quote_version(p_company uuid,p_source uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_source public.quote_versions%ROWTYPE;
  v_new uuid; v_room uuid; v_group uuid; v_item uuid; v_material uuid;
  v_final uuid; v_number integer; r record; g record; i record; m record;
BEGIN
  v_actor:=app_private.assert_action(p_company,'quote.create');
  SELECT * INTO v_source FROM public.quote_versions
    WHERE company_id=p_company AND id=p_source FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Source version missing' USING ERRCODE='P0002'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.quotes q WHERE q.company_id=p_company
    AND q.id=v_source.quote_id AND app_private.can_lead(p_company,q.lead_id)) THEN
    RAISE EXCEPTION 'Quote outside access scope' USING ERRCODE='42501'; END IF;
  PERFORM 1 FROM public.quotes WHERE company_id=p_company
    AND id=v_source.quote_id FOR UPDATE;
  SELECT COALESCE(max(version_number),0)+1 INTO v_number FROM public.quote_versions
    WHERE company_id=p_company AND quote_id=v_source.quote_id;
  INSERT INTO public.quote_versions(company_id,quote_id,version_number,status,title,
    notes,vat_text,created_from_version_id,created_by)
    VALUES(p_company,v_source.quote_id,v_number,'Nháp',v_source.title,
      v_source.notes,v_source.vat_text,p_source,v_actor) RETURNING id INTO v_new;
  FOR r IN SELECT * FROM public.quote_rooms WHERE company_id=p_company
       AND version_id=p_source ORDER BY sort_order,id LOOP
    INSERT INTO public.quote_rooms(company_id,version_id,name,sort_order,notes)
      VALUES(p_company,v_new,r.name,r.sort_order,r.notes) RETURNING id INTO v_room;
    FOR g IN SELECT * FROM public.quote_groups WHERE company_id=p_company
       AND room_id=r.id ORDER BY sort_order,id LOOP
      INSERT INTO public.quote_groups(company_id,version_id,room_id,name,sort_order,notes)
        VALUES(p_company,v_new,v_room,g.name,g.sort_order,g.notes) RETURNING id INTO v_group;
      FOR i IN SELECT * FROM public.quote_items WHERE company_id=p_company
         AND group_id=g.id ORDER BY sort_order,id LOOP
        INSERT INTO public.quote_items(company_id,version_id,group_id,lineage_id,
          source_catalog_item_id,name,specifications,length,width,height,depth,unit,
          item_count,quantity_mode,quantity,coefficient,coefficient_note,
          discount_amount,extra_amount,is_included,sort_order,notes)
        VALUES(p_company,v_new,v_group,i.lineage_id,i.source_catalog_item_id,
          i.name,i.specifications,i.length,i.width,i.height,i.depth,i.unit,
          i.item_count,i.quantity_mode,i.quantity,i.coefficient,i.coefficient_note,
          i.discount_amount,i.extra_amount,i.is_included,i.sort_order,i.notes)
        RETURNING id INTO v_item;
        v_final:=NULL;
        FOR m IN SELECT * FROM public.quote_item_materials WHERE company_id=p_company
          AND item_id=i.id ORDER BY sort_order,id LOOP
          INSERT INTO public.quote_item_materials(company_id,version_id,item_id,
            source_catalog_material_id,material_name,base_price,selling_price,
            is_selected,sort_order,notes)
          VALUES(p_company,v_new,v_item,m.source_catalog_material_id,m.material_name,
            m.base_price,m.selling_price,m.is_selected,m.sort_order,m.notes)
          RETURNING id INTO v_material;
          IF m.id=i.finalized_material_id THEN v_final:=v_material; END IF;
        END LOOP;
        IF v_final IS NOT NULL THEN
          UPDATE public.quote_items SET finalized_material_id=v_final WHERE id=v_item;
        END IF;
      END LOOP;
    END LOOP;
  END LOOP;
  RETURN v_new;
END; $$;

-- Unresolved or unpriced alternatives keep the official total NULL. Each
-- material row is an alternative, never another additive component.
CREATE FUNCTION public.finalize_quote_version(p_company uuid,p_version uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_quote uuid; v_lead uuid; v_status text;
  v_unresolved bigint; v_item_count bigint; v_total numeric(18,0);
BEGIN
  v_actor:=app_private.assert_action(p_company,'quote.finalize');
  SELECT quote_id,status INTO v_quote,v_status FROM public.quote_versions
    WHERE company_id=p_company AND id=p_version FOR UPDATE;
  IF v_quote IS NULL OR v_status NOT IN ('Nháp','Đã gửi') THEN
    RAISE EXCEPTION 'Version cannot be finalized' USING ERRCODE='23514'; END IF;
  SELECT lead_id INTO v_lead FROM public.quotes WHERE company_id=p_company AND id=v_quote;
  IF NOT app_private.can_lead(p_company,v_lead) THEN
    RAISE EXCEPTION 'Quote outside access scope' USING ERRCODE='42501'; END IF;
  SELECT count(*),count(*) FILTER (WHERE i.finalized_material_id IS NULL
      OR m.selling_price IS NULL),
    COALESCE(sum(round(i.quantity*i.coefficient*m.selling_price,0)
      +i.extra_amount-i.discount_amount),0)
    INTO v_item_count,v_unresolved,v_total FROM public.quote_items i
      LEFT JOIN public.quote_item_materials m ON
       (m.company_id,m.item_id,m.id)=(i.company_id,i.id,i.finalized_material_id)
    WHERE i.company_id=p_company AND i.version_id=p_version AND i.is_included;
  IF v_item_count=0 OR v_unresolved>0 THEN v_total:=NULL; END IF;
  IF v_total IS NOT NULL AND v_total<0 THEN
    RAISE EXCEPTION 'Negative Quote total' USING ERRCODE='23514'; END IF;
  UPDATE public.quote_versions SET status='Đã chốt',total_amount=v_total,
    finalized_at=now(),finalized_by=v_actor,updated_at=now()
    WHERE company_id=p_company AND id=p_version;
END; $$;

-- Read/unread changes are confined to the caller's own inbox.
CREATE FUNCTION public.set_notification_read(p_company uuid,p_notification uuid,p_read boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid;
BEGIN
  v_actor:=app_private.actor_id(p_company);
  IF v_actor IS NULL OR app_private.subscription_access(p_company)<>'write'
     OR p_read IS NULL THEN RAISE EXCEPTION 'Action not permitted' USING ERRCODE='42501'; END IF;
  UPDATE public.notifications SET is_read=p_read,
    read_at=CASE WHEN p_read THEN now() ELSE NULL END
    WHERE company_id=p_company AND id=p_notification AND recipient_user_id=v_actor
      AND app_private.notification_event_visible(p_company,event_id);
END; $$;
CREATE FUNCTION public.mark_all_notifications_read(p_company uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_actor uuid; v_count integer;
BEGIN
  v_actor:=app_private.actor_id(p_company);
  IF v_actor IS NULL OR app_private.subscription_access(p_company)<>'write'
    THEN RAISE EXCEPTION 'Action not permitted' USING ERRCODE='42501'; END IF;
  UPDATE public.notifications SET is_read=true,read_at=now()
    WHERE company_id=p_company AND recipient_user_id=v_actor AND NOT is_read
      AND app_private.notification_event_visible(p_company,event_id);
  GET DIAGNOSTICS v_count=ROW_COUNT;
  RETURN v_count;
END; $$;

-- No implicit PUBLIC execution. 009 explicitly grants safe entry points.
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app_private FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.set_user_permission(uuid,uuid,text,text),
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
 public.mark_all_notifications_read(uuid) FROM PUBLIC,anon,authenticated;
COMMIT;
