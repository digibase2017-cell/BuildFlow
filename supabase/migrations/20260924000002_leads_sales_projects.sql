-- 002_leads_sales_projects.sql
-- Clean-install migration; requires 001_foundation.sql.
-- Quote-version relationships are completed in 006 after 003 creates quotes.
-- Apply using a privileged migration role, NOT anon/authenticated.
BEGIN;

-- Customer/contact details live exclusively on leads. No customers table.
CREATE TABLE public.leads (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    lead_number bigint NOT NULL CHECK (lead_number > 0),
    customer_name text NOT NULL CHECK (length(btrim(customer_name)) > 0),
    phone text,
    email text,
    zalo text,
    address text,
    source text,
    status text NOT NULL DEFAULT 'Mới tiếp nhận' CHECK (status IN (
        'Mới tiếp nhận','Đã liên hệ','Đã gửi báo giá',
        'Đàm phán','Thành công','Thất bại'
    )),
    customer_requirements text,
    notes text,
    -- Business attribution can be reassigned; real actor lives in activity_logs.
    created_by uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_leads_company_id UNIQUE (company_id, id),
    CONSTRAINT uq_leads_number UNIQUE (company_id, lead_number),
    CONSTRAINT fk_leads_creator FOREIGN KEY (company_id, created_by)
        REFERENCES public.users(company_id, id) ON DELETE RESTRICT
);
CREATE INDEX idx_leads_company_name ON public.leads(company_id, customer_name);
CREATE INDEX idx_leads_company_created ON public.leads(company_id, created_at DESC);
CREATE INDEX idx_leads_company_status ON public.leads(company_id, status);

-- Assignment history: one open assignment per lead/user, multiple historical terms.
CREATE TABLE public.lead_assignments (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL,
    lead_id uuid NOT NULL,
    user_id uuid NOT NULL,
    assigned_at timestamptz NOT NULL DEFAULT now(),
    assigned_by uuid NOT NULL,
    unassigned_at timestamptz,
    unassigned_by uuid,
    CONSTRAINT uq_lead_assignments_company_id UNIQUE (company_id, id),
    CONSTRAINT fk_lead_assignments_lead FOREIGN KEY (company_id, lead_id)
        REFERENCES public.leads(company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_lead_assignments_user FOREIGN KEY (company_id, user_id)
        REFERENCES public.users(company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_lead_assignments_assigned_by FOREIGN KEY (company_id, assigned_by)
        REFERENCES public.users(company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_lead_assignments_unassigned_by FOREIGN KEY (company_id, unassigned_by)
        REFERENCES public.users(company_id, id) ON DELETE RESTRICT,
    CONSTRAINT chk_lead_assignment_end CHECK (
        (unassigned_at IS NULL AND unassigned_by IS NULL)
        OR (unassigned_at IS NOT NULL AND unassigned_by IS NOT NULL
            AND unassigned_at >= assigned_at)
    )
);
CREATE UNIQUE INDEX uq_lead_assignments_open
    ON public.lead_assignments(company_id, lead_id, user_id)
    WHERE unassigned_at IS NULL;
CREATE INDEX idx_lead_assignments_user_open
    ON public.lead_assignments(company_id, user_id, lead_id)
    WHERE unassigned_at IS NULL;

CREATE TABLE public.projects (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    project_number bigint NOT NULL CHECK (project_number > 0),
    name text NOT NULL CHECK (length(btrim(name)) > 0),
    project_address text,  -- Worksite, separate from leads.address.
    -- Hide/unhide is a protected Owner/Admin action, not deletion or a quota exemption.
    is_hidden boolean NOT NULL DEFAULT false,
    source_lead_id uuid NOT NULL,
    -- Added as a real FK to quote_versions in 006 (after 003).
    current_quote_version_id uuid,
    has_design boolean NOT NULL DEFAULT false,
    has_purchasing boolean NOT NULL DEFAULT false,
    has_production boolean NOT NULL DEFAULT false,
    has_construction boolean NOT NULL DEFAULT false,
    status text NOT NULL DEFAULT 'Chưa bắt đầu' CHECK (status IN (
        'Chưa bắt đầu', 'Đang thực hiện', 'Tạm dừng', 'Hoàn thành', 'Đã hủy'
    )),
    progress_percent numeric(5,2) NOT NULL DEFAULT 0
        CHECK (progress_percent BETWEEN 0 AND 100),
    start_date date,
    deadline date,
    deadline_revision integer NOT NULL DEFAULT 1 CHECK (deadline_revision > 0),
    completed_date date,
    -- FK to acceptance_rounds is added in 006 (after 005).
    completion_source_acceptance_round_id uuid,
    main_responsible_user_id uuid,
    project_tier text CHECK (project_tier IS NULL OR project_tier IN ('S','M','L','VIP')),
    folder_url text,
    notes text,
    created_by uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_projects_company_id UNIQUE (company_id, id),
    -- 006 ties each Quote application to this Project's source Lead.
    CONSTRAINT uq_projects_source_identity UNIQUE
      (company_id,id,source_lead_id),
    CONSTRAINT uq_projects_number UNIQUE (company_id, project_number),
    CONSTRAINT fk_projects_source_lead FOREIGN KEY (company_id, source_lead_id)
        REFERENCES public.leads(company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_projects_main_responsible FOREIGN KEY (company_id, main_responsible_user_id)
        REFERENCES public.users(company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_projects_creator FOREIGN KEY (company_id, created_by)
        REFERENCES public.users(company_id, id) ON DELETE RESTRICT,
    CONSTRAINT chk_projects_dates CHECK (
        start_date IS NULL OR deadline IS NULL OR deadline >= start_date
    )
);
-- No UNIQUE on source_lead_id: one Lead may create many Projects.
CREATE INDEX idx_projects_company_lead ON public.projects(company_id, source_lead_id);
CREATE INDEX idx_projects_company_status ON public.projects(company_id, status);
CREATE INDEX idx_projects_company_deadline ON public.projects(company_id, deadline)
    WHERE deadline IS NOT NULL;
CREATE INDEX idx_projects_company_responsible ON public.projects(company_id, main_responsible_user_id);

CREATE TABLE public.project_members (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL,
    project_id uuid NOT NULL,
    user_id uuid NOT NULL,
    added_at timestamptz NOT NULL DEFAULT now(),
    added_by uuid NOT NULL,
    CONSTRAINT uq_project_members_company_id UNIQUE (company_id, id),
    CONSTRAINT uq_project_members_membership UNIQUE (company_id, project_id, user_id),
    CONSTRAINT fk_project_members_project FOREIGN KEY (company_id, project_id)
        REFERENCES public.projects(company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_project_members_user FOREIGN KEY (company_id, user_id)
        REFERENCES public.users(company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_project_members_actor FOREIGN KEY (company_id, added_by)
        REFERENCES public.users(company_id, id) ON DELETE RESTRICT
);
CREATE INDEX idx_project_members_user ON public.project_members(company_id, user_id, project_id);

-- Snapshot of eligible active Sales from open lead_assignments on explicit Project creation; later maintained independently.
CREATE TABLE public.project_sales (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL,
    project_id uuid NOT NULL,
    user_id uuid NOT NULL,
    assigned_at timestamptz NOT NULL DEFAULT now(),
    assigned_by uuid NOT NULL,
    CONSTRAINT uq_project_sales_company_id UNIQUE (company_id, id),
    CONSTRAINT uq_project_sales_membership UNIQUE (company_id, project_id, user_id),
    -- A project salesperson must also be a current project member.
    CONSTRAINT fk_project_sales_membership FOREIGN KEY (company_id, project_id, user_id)
        REFERENCES public.project_members(company_id, project_id, user_id)
        DEFERRABLE INITIALLY DEFERRED,
    CONSTRAINT fk_project_sales_actor FOREIGN KEY (company_id, assigned_by)
        REFERENCES public.users(company_id, id) ON DELETE RESTRICT
);
CREATE INDEX idx_project_sales_user ON public.project_sales(company_id, user_id, project_id);

-- Intentionally separate: project.view must not imply financial.view.
CREATE TABLE public.project_financials (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL,
    project_id uuid NOT NULL,
    budget numeric(18,0) CHECK (budget IS NULL OR budget >= 0),
    contract_value numeric(18,0) CHECK (contract_value IS NULL OR contract_value >= 0),
    notes text,
    updated_by uuid,
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_project_financials_company_id UNIQUE (company_id, id),
    CONSTRAINT uq_project_financials_project UNIQUE (company_id, project_id),
    CONSTRAINT fk_project_financials_project FOREIGN KEY (company_id, project_id)
        REFERENCES public.projects(company_id, id) ON DELETE RESTRICT,
    CONSTRAINT fk_project_financials_editor FOREIGN KEY (company_id, updated_by)
        REFERENCES public.users(company_id, id) ON DELETE RESTRICT
);

-- Intentionally deferred to later migrations:
-- * 003: quotes/quote_versions and finalized immutable Quote snapshots.
-- * 006: project_quote_history + current_quote_version FK and consistency check;
--        acceptance completion-round FK; cross-project quote-source checks.
-- * 007/008: counters; explicit Project creation requires Lead success;
--        copy eligible active Lead assignees to project_members + project_sales atomically;
--        status-change notification and audit; active/department membership checks.
-- * 009: RLS and grant strategy including user-level allow/deny.
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon, authenticated;
COMMIT;
