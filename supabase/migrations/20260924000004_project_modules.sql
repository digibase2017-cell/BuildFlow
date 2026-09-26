-- 004_project_modules.sql — draft for a fresh Supabase PostgreSQL database.
-- Requires 001_foundation.sql, 002_leads_sales_projects.sql, 003_catalog_quotes.sql.
-- NOT YET RUN on PostgreSQL. Apply with a privileged migration role.
-- 006–009 must enforce enabled module, Project membership, snapshot source
-- provenance, quote-version finalization, protected RPCs, RLS and status triggers.
BEGIN;

-- DESIGN: one independent module record per Project; equally responsible users.
CREATE TABLE public.project_designs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL,
    project_id uuid NOT NULL,
    received_date date NOT NULL DEFAULT CURRENT_DATE,
    deadline date,
    deadline_revision integer NOT NULL DEFAULT 1 CHECK (deadline_revision > 0),
    design_type text,  -- Partner-defined, not a hard-coded enum.
    design_scope text,
    design_brief text,
    design_style text,
    status text NOT NULL DEFAULT 'Chưa bắt đầu' CHECK
      (status IN ('Chưa bắt đầu','Đang thiết kế','Chờ khách duyệt','Đã duyệt','Đã hủy')),
    current_situation text,
    customer_approved_date date,
    drawing_url text,
    notes text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_project_designs_company_id UNIQUE (company_id,id),
    CONSTRAINT uq_project_designs_project UNIQUE (company_id,project_id),
    CONSTRAINT fk_project_designs_project FOREIGN KEY (company_id,project_id)
      REFERENCES public.projects(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT chk_project_designs_dates CHECK (deadline IS NULL OR deadline >= received_date)
);
CREATE INDEX idx_project_designs_deadline ON public.project_designs(company_id,deadline)
  WHERE status <> 'Đã duyệt' AND deadline IS NOT NULL;

CREATE TABLE public.design_users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL,
    design_id uuid NOT NULL,
    user_id uuid NOT NULL,
    assigned_at timestamptz NOT NULL DEFAULT now(),
    assigned_by uuid NOT NULL,
    CONSTRAINT uq_design_users_company_id UNIQUE (company_id,id),
    CONSTRAINT uq_design_users_membership UNIQUE (company_id,design_id,user_id),
    CONSTRAINT fk_design_users_design FOREIGN KEY (company_id,design_id)
      REFERENCES public.project_designs(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_design_users_user FOREIGN KEY (company_id,user_id)
      REFERENCES public.users(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_design_users_actor FOREIGN KEY (company_id,assigned_by)
      REFERENCES public.users(company_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_design_users_user ON public.design_users(company_id,user_id);

CREATE TABLE public.design_rounds (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL,
    design_id uuid NOT NULL,
    round_number integer NOT NULL CHECK (round_number > 0),
    status text NOT NULL DEFAULT 'Đã gửi' CHECK
      (status IN ('Đã gửi','Đang sửa','Sửa xong','Đã duyệt','Đã hủy')),
    sent_at timestamptz,
    requested_changes text,
    drawing_url text,
    notes text,
    created_by uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_design_rounds_company_id UNIQUE (company_id,id),
    CONSTRAINT uq_design_rounds_number UNIQUE (company_id,design_id,round_number),
    CONSTRAINT fk_design_rounds_design FOREIGN KEY (company_id,design_id)
      REFERENCES public.project_designs(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_design_rounds_creator FOREIGN KEY (company_id,created_by)
      REFERENCES public.users(company_id,id) ON DELETE RESTRICT
);

-- PURCHASING: a copied quote/catalog row becomes an independent snapshot.
CREATE TABLE public.project_purchasing (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL,
    project_id uuid NOT NULL,
    received_date date NOT NULL DEFAULT CURRENT_DATE,
    deadline date,
    deadline_revision integer NOT NULL DEFAULT 1 CHECK (deadline_revision > 0),
    status text NOT NULL DEFAULT 'Chưa đặt' CHECK
      (status IN ('Chưa đặt','Đang mua','Đã xong')),
    notes text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_project_purchasing_company_id UNIQUE (company_id,id),
    CONSTRAINT uq_project_purchasing_item_parent UNIQUE (company_id,id,project_id),
    CONSTRAINT uq_project_purchasing_project UNIQUE (company_id,project_id),
    CONSTRAINT fk_project_purchasing_project FOREIGN KEY (company_id,project_id)
      REFERENCES public.projects(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT chk_project_purchasing_dates CHECK (deadline IS NULL OR deadline >= received_date)
);
CREATE INDEX idx_project_purchasing_deadline ON public.project_purchasing(company_id,deadline)
  WHERE status <> 'Đã xong' AND deadline IS NOT NULL;

CREATE TABLE public.purchasing_users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL,
    purchasing_id uuid NOT NULL,
    user_id uuid NOT NULL,
    assigned_at timestamptz NOT NULL DEFAULT now(),
    assigned_by uuid NOT NULL,
    CONSTRAINT uq_purchasing_users_company_id UNIQUE (company_id,id),
    CONSTRAINT uq_purchasing_users_membership UNIQUE (company_id,purchasing_id,user_id),
    CONSTRAINT fk_purchasing_users_module FOREIGN KEY (company_id,purchasing_id)
      REFERENCES public.project_purchasing(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_purchasing_users_user FOREIGN KEY (company_id,user_id)
      REFERENCES public.users(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_purchasing_users_actor FOREIGN KEY (company_id,assigned_by)
      REFERENCES public.users(company_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_purchasing_users_user ON public.purchasing_users(company_id,user_id);

CREATE TABLE public.purchasing_items (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL,
    purchasing_id uuid NOT NULL,
    project_id uuid NOT NULL,
    source_quote_item_id uuid,
    source_quote_version_id uuid,
    source_catalog_item_id uuid,
    name text NOT NULL CHECK (length(btrim(name)) > 0),
    specifications text,
    material_name text,
    unit text NOT NULL CHECK (length(btrim(unit)) > 0),
    required_quantity numeric(18,4) NOT NULL CHECK (required_quantity > 0),
    supplier_name text,
    actual_unit_price numeric(18,0) CHECK (actual_unit_price IS NULL OR actual_unit_price >= 0),
    order_date date,
    expected_receipt_date date,
    expected_receipt_revision integer NOT NULL DEFAULT 1 CHECK (expected_receipt_revision > 0),
    status text NOT NULL DEFAULT 'Chưa đặt' CHECK
      (status IN ('Chưa đặt','Đã đặt','Đang vận chuyển','Đã nhận')),
    -- Preserve phase before automatically reaching full receipt; restored if qty drops.
    pre_received_status text CHECK
      (pre_received_status IS NULL OR pre_received_status IN ('Chưa đặt','Đã đặt','Đang vận chuyển')),
    issue text,
    notes text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_purchasing_items_company_id UNIQUE (company_id,id),
    CONSTRAINT fk_purchasing_items_module FOREIGN KEY (company_id,purchasing_id,project_id)
      REFERENCES public.project_purchasing(company_id,id,project_id) ON DELETE RESTRICT,
    CONSTRAINT fk_purchasing_items_quote FOREIGN KEY
      (company_id,source_quote_item_id,source_quote_version_id)
      REFERENCES public.quote_items(company_id,id,version_id) ON DELETE RESTRICT,
    CONSTRAINT fk_purchasing_items_catalog FOREIGN KEY (company_id,source_catalog_item_id)
      REFERENCES public.catalog_items(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT chk_purchasing_items_one_direct_source CHECK
      (source_quote_item_id IS NULL OR source_catalog_item_id IS NULL),
    CONSTRAINT chk_purchasing_items_quote_source_pair CHECK
      ((source_quote_item_id IS NULL) = (source_quote_version_id IS NULL)),
    CONSTRAINT chk_purchasing_items_receipt_dates CHECK
      (order_date IS NULL OR expected_receipt_date IS NULL OR expected_receipt_date >= order_date)
);
CREATE INDEX idx_purchasing_items_module_status
  ON public.purchasing_items(company_id,purchasing_id,status);
CREATE INDEX idx_purchasing_items_quote_source ON public.purchasing_items(company_id,source_quote_item_id)
  WHERE source_quote_item_id IS NOT NULL;

CREATE TABLE public.purchasing_receipts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL,
    purchasing_item_id uuid NOT NULL,
    receipt_date date NOT NULL,
    quantity numeric(18,4) NOT NULL CHECK (quantity > 0),
    notes text,
    created_by uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_purchasing_receipts_company_id UNIQUE (company_id,id),
    CONSTRAINT fk_purchasing_receipts_item FOREIGN KEY (company_id,purchasing_item_id)
      REFERENCES public.purchasing_items(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_purchasing_receipts_creator FOREIGN KEY (company_id,created_by)
      REFERENCES public.users(company_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_purchasing_receipts_item
  ON public.purchasing_receipts(company_id,purchasing_item_id,receipt_date);

-- PRODUCTION: actual_cost is entered per item, not derived from batches.
CREATE TABLE public.project_production (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL,
    project_id uuid NOT NULL,
    received_date date NOT NULL DEFAULT CURRENT_DATE,
    deadline date,
    deadline_revision integer NOT NULL DEFAULT 1 CHECK (deadline_revision > 0),
    status text NOT NULL DEFAULT 'Chưa sản xuất' CHECK
      (status IN ('Chưa sản xuất','Đang sản xuất','Đã xong')),
    notes text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_project_production_company_id UNIQUE (company_id,id),
    CONSTRAINT uq_project_production_item_parent UNIQUE (company_id,id,project_id),
    CONSTRAINT uq_project_production_project UNIQUE (company_id,project_id),
    CONSTRAINT fk_project_production_project FOREIGN KEY (company_id,project_id)
      REFERENCES public.projects(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT chk_project_production_dates CHECK (deadline IS NULL OR deadline >= received_date)
);
CREATE INDEX idx_project_production_deadline ON public.project_production(company_id,deadline)
  WHERE status <> 'Đã xong' AND deadline IS NOT NULL;

CREATE TABLE public.production_users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL,
    production_id uuid NOT NULL,
    user_id uuid NOT NULL,
    assigned_at timestamptz NOT NULL DEFAULT now(),
    assigned_by uuid NOT NULL,
    CONSTRAINT uq_production_users_company_id UNIQUE (company_id,id),
    CONSTRAINT uq_production_users_membership UNIQUE (company_id,production_id,user_id),
    CONSTRAINT fk_production_users_module FOREIGN KEY (company_id,production_id)
      REFERENCES public.project_production(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_production_users_user FOREIGN KEY (company_id,user_id)
      REFERENCES public.users(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_production_users_actor FOREIGN KEY (company_id,assigned_by)
      REFERENCES public.users(company_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_production_users_user ON public.production_users(company_id,user_id);

CREATE TABLE public.production_items (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL,
    production_id uuid NOT NULL,
    project_id uuid NOT NULL,
    source_quote_item_id uuid,
    source_quote_version_id uuid,
    source_catalog_item_id uuid,
    room_name text,
    name text NOT NULL CHECK (length(btrim(name)) > 0),
    specifications text,
    material_name text,
    length numeric(14,4) CHECK (length IS NULL OR length > 0),
    width numeric(14,4) CHECK (width IS NULL OR width > 0),
    height numeric(14,4) CHECK (height IS NULL OR height > 0),
    depth numeric(14,4) CHECK (depth IS NULL OR depth > 0),
    unit text NOT NULL CHECK (length(btrim(unit)) > 0),
    required_quantity numeric(18,4) NOT NULL CHECK (required_quantity > 0),
    start_date date,
    deadline date,
    deadline_revision integer NOT NULL DEFAULT 1 CHECK (deadline_revision > 0),
    status text NOT NULL DEFAULT 'Chưa sản xuất' CHECK
      (status IN ('Chưa sản xuất','Đang sản xuất','Hoàn thành')),
    -- Tracks phase before the automatic completed status; no phantom in-progress.
    pre_completed_status text CHECK
      (pre_completed_status IS NULL OR pre_completed_status IN ('Chưa sản xuất','Đang sản xuất')),
    actual_cost numeric(18,0) CHECK (actual_cost IS NULL OR actual_cost >= 0),
    drawing_url text,
    issue text,
    notes text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_production_items_company_id UNIQUE (company_id,id),
    CONSTRAINT fk_production_items_module FOREIGN KEY (company_id,production_id,project_id)
      REFERENCES public.project_production(company_id,id,project_id) ON DELETE RESTRICT,
    CONSTRAINT fk_production_items_quote FOREIGN KEY
      (company_id,source_quote_item_id,source_quote_version_id)
      REFERENCES public.quote_items(company_id,id,version_id) ON DELETE RESTRICT,
    CONSTRAINT fk_production_items_catalog FOREIGN KEY (company_id,source_catalog_item_id)
      REFERENCES public.catalog_items(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT chk_production_items_one_direct_source CHECK
      (source_quote_item_id IS NULL OR source_catalog_item_id IS NULL),
    CONSTRAINT chk_production_items_quote_source_pair CHECK
      ((source_quote_item_id IS NULL) = (source_quote_version_id IS NULL)),
    CONSTRAINT chk_production_items_dates CHECK
      (start_date IS NULL OR deadline IS NULL OR deadline >= start_date)
);
CREATE INDEX idx_production_items_module_status
  ON public.production_items(company_id,production_id,status);
CREATE INDEX idx_production_items_quote_source ON public.production_items(company_id,source_quote_item_id)
  WHERE source_quote_item_id IS NOT NULL;

CREATE TABLE public.production_batches (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL,
    production_item_id uuid NOT NULL,
    completed_date date NOT NULL,
    quantity numeric(18,4) NOT NULL CHECK (quantity > 0),
    notes text,
    created_by uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_production_batches_company_id UNIQUE (company_id,id),
    CONSTRAINT fk_production_batches_item FOREIGN KEY (company_id,production_item_id)
      REFERENCES public.production_items(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_production_batches_creator FOREIGN KEY (company_id,created_by)
      REFERENCES public.users(company_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_production_batches_item
  ON public.production_batches(company_id,production_item_id,completed_date);

-- CONSTRUCTION: select from finalized/applied Quote or create manually; NOT Catalog.
CREATE TABLE public.project_construction (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL,
    project_id uuid NOT NULL,
    site_address text,  -- Initialized from projects.project_address; independent thereafter.
    received_date date NOT NULL DEFAULT CURRENT_DATE,
    deadline date,
    deadline_revision integer NOT NULL DEFAULT 1 CHECK (deadline_revision > 0),
    status text NOT NULL DEFAULT 'Chưa thi công' CHECK
      (status IN ('Chưa thi công','Đang thi công','Đã xong')),
    notes text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_project_construction_company_id UNIQUE (company_id,id),
    CONSTRAINT uq_project_construction_item_parent UNIQUE (company_id,id,project_id),
    CONSTRAINT uq_project_construction_project UNIQUE (company_id,project_id),
    CONSTRAINT fk_project_construction_project FOREIGN KEY (company_id,project_id)
      REFERENCES public.projects(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT chk_project_construction_dates CHECK (deadline IS NULL OR deadline >= received_date)
);
CREATE INDEX idx_project_construction_deadline ON public.project_construction(company_id,deadline)
  WHERE status <> 'Đã xong' AND deadline IS NOT NULL;

CREATE TABLE public.construction_users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL,
    construction_id uuid NOT NULL,
    user_id uuid NOT NULL,
    assigned_at timestamptz NOT NULL DEFAULT now(),
    assigned_by uuid NOT NULL,
    CONSTRAINT uq_construction_users_company_id UNIQUE (company_id,id),
    CONSTRAINT uq_construction_users_membership UNIQUE (company_id,construction_id,user_id),
    CONSTRAINT fk_construction_users_module FOREIGN KEY (company_id,construction_id)
      REFERENCES public.project_construction(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_construction_users_user FOREIGN KEY (company_id,user_id)
      REFERENCES public.users(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_construction_users_actor FOREIGN KEY (company_id,assigned_by)
      REFERENCES public.users(company_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_construction_users_user ON public.construction_users(company_id,user_id);

CREATE TABLE public.construction_items (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL,
    construction_id uuid NOT NULL,
    project_id uuid NOT NULL,
    source_quote_item_id uuid, -- NULL if manual; deliberately NO catalog source.
    source_quote_version_id uuid,
    room_name text,
    name text NOT NULL CHECK (length(btrim(name)) > 0),
    specifications text,
    material_name text,
    length numeric(14,4) CHECK (length IS NULL OR length > 0),
    width numeric(14,4) CHECK (width IS NULL OR width > 0),
    height numeric(14,4) CHECK (height IS NULL OR height > 0),
    depth numeric(14,4) CHECK (depth IS NULL OR depth > 0),
    unit text NOT NULL CHECK (length(btrim(unit)) > 0),
    required_quantity numeric(18,4) NOT NULL CHECK (required_quantity > 0),
    start_date date,
    deadline date,
    deadline_revision integer NOT NULL DEFAULT 1 CHECK (deadline_revision > 0),
    status text NOT NULL DEFAULT 'Chưa thi công' CHECK
      (status IN ('Chưa thi công','Đang thi công','Hoàn thành')),
    pre_completed_status text CHECK
      (pre_completed_status IS NULL OR pre_completed_status IN ('Chưa thi công','Đang thi công')),
    site_photo_url text,
    issue text,
    notes text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_construction_items_company_id UNIQUE (company_id,id),
    CONSTRAINT fk_construction_items_module FOREIGN KEY (company_id,construction_id,project_id)
      REFERENCES public.project_construction(company_id,id,project_id) ON DELETE RESTRICT,
    CONSTRAINT fk_construction_items_quote FOREIGN KEY
      (company_id,source_quote_item_id,source_quote_version_id)
      REFERENCES public.quote_items(company_id,id,version_id) ON DELETE RESTRICT,
    CONSTRAINT chk_construction_items_quote_source_pair CHECK
      ((source_quote_item_id IS NULL) = (source_quote_version_id IS NULL)),
    CONSTRAINT chk_construction_items_dates CHECK
      (start_date IS NULL OR deadline IS NULL OR deadline >= start_date)
);
CREATE INDEX idx_construction_items_module_status
  ON public.construction_items(company_id,construction_id,status);
CREATE INDEX idx_construction_items_quote_source ON public.construction_items(company_id,source_quote_item_id)
  WHERE source_quote_item_id IS NOT NULL;

CREATE TABLE public.construction_batches (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL,
    construction_item_id uuid NOT NULL,
    completed_date date NOT NULL,
    quantity numeric(18,4) NOT NULL CHECK (quantity > 0),
    notes text,
    created_by uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_construction_batches_company_id UNIQUE (company_id,id),
    CONSTRAINT fk_construction_batches_item FOREIGN KEY (company_id,construction_item_id)
      REFERENCES public.construction_items(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_construction_batches_creator FOREIGN KEY (company_id,created_by)
      REFERENCES public.users(company_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_construction_batches_item
  ON public.construction_batches(company_id,construction_item_id,completed_date);

CREATE TABLE public.construction_expense_categories (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    name text NOT NULL CHECK (length(btrim(name)) > 0),
    sort_order integer NOT NULL DEFAULT 0,
    is_hidden boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_construction_expense_categories_company_id UNIQUE (company_id,id),
    CONSTRAINT uq_construction_expense_categories_name UNIQUE (company_id,name)
);

CREATE TABLE public.construction_expenses (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL,
    construction_item_id uuid NOT NULL,
    category_id uuid NOT NULL,
    expense_date date NOT NULL,
    description text,
    amount numeric(18,0) NOT NULL CHECK (amount >= 0),
    notes text,
    created_by uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_construction_expenses_company_id UNIQUE (company_id,id),
    CONSTRAINT fk_construction_expenses_item FOREIGN KEY (company_id,construction_item_id)
      REFERENCES public.construction_items(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_construction_expenses_category FOREIGN KEY (company_id,category_id)
      REFERENCES public.construction_expense_categories(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_construction_expenses_creator FOREIGN KEY (company_id,created_by)
      REFERENCES public.users(company_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_construction_expenses_item_date
  ON public.construction_expenses(company_id,construction_item_id,expense_date);
CREATE INDEX idx_construction_expenses_category
  ON public.construction_expenses(company_id,category_id,expense_date);

-- No authenticated/anon access until RLS and guarded RPCs exist in 009.
REVOKE ALL ON public.project_designs,public.design_users,public.design_rounds,
  public.project_purchasing,public.purchasing_users,public.purchasing_items,
  public.purchasing_receipts,public.project_production,public.production_users,
  public.production_items,public.production_batches,public.project_construction,
  public.construction_users,public.construction_items,public.construction_batches,
  public.construction_expense_categories,public.construction_expenses
  FROM anon,authenticated;
COMMIT;
