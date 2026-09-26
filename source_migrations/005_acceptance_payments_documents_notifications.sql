-- 005_acceptance_payments_documents_notifications.sql — clean-install draft.
-- Requires 001–004; not yet executed against PostgreSQL/Supabase Local.
-- 006 adds the reverse Project -> acceptance-round FK. 007–009 add guarded
-- workflows, status synchronization, immutable audit, RLS and grants.
BEGIN;

-- Acceptance is Project-level and exists whether Construction is enabled or not.
CREATE TABLE public.project_acceptance (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL,
    project_id uuid NOT NULL,
    status text NOT NULL DEFAULT 'Chưa nghiệm thu' CHECK
      (status IN ('Chưa nghiệm thu','Đang nghiệm thu','Cần khắc phục','Đã nghiệm thu')),
    notes text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_project_acceptance_company_id UNIQUE (company_id,id),
    CONSTRAINT uq_project_acceptance_project UNIQUE (company_id,project_id),
    CONSTRAINT uq_project_acceptance_round_parent UNIQUE (company_id,id,project_id),
    CONSTRAINT fk_project_acceptance_project FOREIGN KEY (company_id,project_id)
      REFERENCES public.projects(company_id,id) ON DELETE RESTRICT
);

CREATE TABLE public.acceptance_users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL,
    acceptance_id uuid NOT NULL,
    project_id uuid NOT NULL,
    user_id uuid NOT NULL,
    assigned_at timestamptz NOT NULL DEFAULT now(),
    assigned_by uuid NOT NULL,
    CONSTRAINT uq_acceptance_users_company_id UNIQUE (company_id,id),
    CONSTRAINT uq_acceptance_users_membership UNIQUE (company_id,acceptance_id,user_id),
    CONSTRAINT fk_acceptance_users_acceptance FOREIGN KEY (company_id,acceptance_id,project_id)
      REFERENCES public.project_acceptance(company_id,id,project_id) ON DELETE RESTRICT,
    CONSTRAINT fk_acceptance_users_member FOREIGN KEY (company_id,project_id,user_id)
      REFERENCES public.project_members(company_id,project_id,user_id)
      DEFERRABLE INITIALLY DEFERRED,
    CONSTRAINT fk_acceptance_users_user FOREIGN KEY (company_id,user_id)
      REFERENCES public.users(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_acceptance_users_actor FOREIGN KEY (company_id,assigned_by)
      REFERENCES public.users(company_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_acceptance_users_user ON public.acceptance_users(company_id,user_id);

CREATE TABLE public.acceptance_rounds (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL,
    acceptance_id uuid NOT NULL,
    project_id uuid NOT NULL,
    round_number integer NOT NULL CHECK (round_number > 0),
    round_date date NOT NULL,
    result text NOT NULL CHECK (result IN ('Đạt','Cần khắc phục')),
    notes text,
    created_by uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_acceptance_rounds_company_id UNIQUE (company_id,id),
    CONSTRAINT uq_acceptance_rounds_project_identity UNIQUE (company_id,project_id,id),
    CONSTRAINT uq_acceptance_rounds_number UNIQUE (company_id,acceptance_id,round_number),
    CONSTRAINT fk_acceptance_rounds_acceptance FOREIGN KEY (company_id,acceptance_id,project_id)
      REFERENCES public.project_acceptance(company_id,id,project_id) ON DELETE RESTRICT,
    CONSTRAINT fk_acceptance_rounds_creator FOREIGN KEY (company_id,created_by)
      REFERENCES public.users(company_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_acceptance_rounds_latest
  ON public.acceptance_rounds(company_id,acceptance_id,round_number DESC);

-- UI row numbers come from ordering by transfer_at, created_at, id.
-- Totals and remaining balances are computed against project_financials.
CREATE TABLE public.project_payments (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL,
    project_id uuid NOT NULL,
    transfer_at timestamptz NOT NULL,
    amount numeric(18,0) NOT NULL CHECK (amount > 0),
    created_by uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_project_payments_company_id UNIQUE (company_id,id),
    CONSTRAINT fk_project_payments_project FOREIGN KEY (company_id,project_id)
      REFERENCES public.projects(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_project_payments_creator FOREIGN KEY (company_id,created_by)
      REFERENCES public.users(company_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_project_payments_display
  ON public.project_payments(company_id,project_id,transfer_at,created_at,id);

-- Documents keep metadata or partner-managed external URLs, never durable R2
-- signed URLs. Exactly one owning business record is required.
CREATE TABLE public.documents (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL,
    project_id uuid,
    lead_id uuid,
    quote_id uuid,
    name text NOT NULL CHECK (length(btrim(name)) > 0),
    storage_kind text NOT NULL CHECK (storage_kind IN ('r2','external_link')),
    object_key text,
    external_url text,
    file_size_bytes bigint CHECK (file_size_bytes IS NULL OR file_size_bytes >= 0),
    mime_type text,
    notes text,
    uploaded_by uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_documents_company_id UNIQUE (company_id,id),
    CONSTRAINT chk_documents_one_owner CHECK
      (num_nonnulls(project_id,lead_id,quote_id) = 1),
    CONSTRAINT chk_documents_location CHECK (
      (storage_kind = 'r2' AND nullif(btrim(object_key),'') IS NOT NULL
        AND external_url IS NULL)
      OR (storage_kind = 'external_link' AND nullif(btrim(external_url),'') IS NOT NULL
        AND object_key IS NULL)
    ),
    CONSTRAINT fk_documents_project FOREIGN KEY (company_id,project_id)
      REFERENCES public.projects(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_documents_lead FOREIGN KEY (company_id,lead_id)
      REFERENCES public.leads(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_documents_quote FOREIGN KEY (company_id,quote_id)
      REFERENCES public.quotes(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_documents_uploader FOREIGN KEY (company_id,uploaded_by)
      REFERENCES public.users(company_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_documents_project ON public.documents(company_id,project_id,created_at DESC)
  WHERE project_id IS NOT NULL;
CREATE INDEX idx_documents_lead ON public.documents(company_id,lead_id,created_at DESC)
  WHERE lead_id IS NOT NULL;
CREATE INDEX idx_documents_quote ON public.documents(company_id,quote_id,created_at DESC)
  WHERE quote_id IS NOT NULL;

-- One event is fanned out to recipient rows. Event identity includes the
-- deadline revision so returning from A to B to A can create a fresh alert.
CREATE TABLE public.notification_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    event_type text NOT NULL CHECK (length(btrim(event_type)) > 0),
    entity_type text NOT NULL CHECK (length(btrim(entity_type)) > 0),
    entity_id uuid NOT NULL,
    project_id uuid,
    deadline_revision integer CHECK (deadline_revision IS NULL OR deadline_revision > 0),
    occurred_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_notification_events_company_id UNIQUE (company_id,id),
    CONSTRAINT fk_notification_events_project FOREIGN KEY (company_id,project_id)
      REFERENCES public.projects(company_id,id) ON DELETE RESTRICT
);
CREATE UNIQUE INDEX uq_notification_events_overdue_revision
  ON public.notification_events(company_id,event_type,entity_type,entity_id,deadline_revision)
  WHERE deadline_revision IS NOT NULL;
CREATE INDEX idx_notification_events_project
  ON public.notification_events(company_id,project_id,occurred_at DESC);

CREATE TABLE public.notifications (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL,
    event_id uuid NOT NULL,
    recipient_user_id uuid NOT NULL,
    title text NOT NULL CHECK (length(btrim(title)) > 0),
    body text,
    is_read boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    read_at timestamptz,
    CONSTRAINT uq_notifications_company_id UNIQUE (company_id,id),
    CONSTRAINT uq_notifications_event_recipient UNIQUE (company_id,event_id,recipient_user_id),
    CONSTRAINT chk_notifications_read_time CHECK
      ((NOT is_read AND read_at IS NULL) OR (is_read AND read_at IS NOT NULL)),
    CONSTRAINT fk_notifications_event FOREIGN KEY (company_id,event_id)
      REFERENCES public.notification_events(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_notifications_recipient FOREIGN KEY (company_id,recipient_user_id)
      REFERENCES public.users(company_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_notifications_inbox
  ON public.notifications(company_id,recipient_user_id,created_at DESC,id DESC);
CREATE INDEX idx_notifications_unread
  ON public.notifications(company_id,recipient_user_id,created_at DESC)
  WHERE NOT is_read;

-- append-only enforced by 008. actor_user_id is NULL only for system actions.
-- JSON values must be sanitized by trusted logging functions (no credentials,
-- tokens, signed URLs, or password material).
CREATE TABLE public.activity_logs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    actor_user_id uuid,
    action text NOT NULL CHECK (length(btrim(action)) > 0),
    entity_type text NOT NULL CHECK (length(btrim(entity_type)) > 0),
    entity_id uuid NOT NULL,
    project_id uuid,
    old_data jsonb,
    new_data jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_activity_logs_company_id UNIQUE (company_id,id),
    CONSTRAINT fk_activity_logs_actor FOREIGN KEY (company_id,actor_user_id)
      REFERENCES public.users(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_activity_logs_project FOREIGN KEY (company_id,project_id)
      REFERENCES public.projects(company_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_activity_logs_project
  ON public.activity_logs(company_id,project_id,created_at DESC,id DESC);
CREATE INDEX idx_activity_logs_entity
  ON public.activity_logs(company_id,entity_type,entity_id,created_at DESC);

REVOKE ALL ON public.project_acceptance,public.acceptance_users,public.acceptance_rounds,
  public.project_payments,public.documents,public.notification_events,
  public.notifications,public.activity_logs FROM anon,authenticated;
COMMIT;
