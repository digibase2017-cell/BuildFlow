-- 003_catalog_quotes.sql — draft, clean-install migration.
-- Requires 001_foundation.sql and 002_leads_sales_projects.sql.
-- Run with a privileged migration role. Not yet executed against PostgreSQL.
-- Cross-table lifecycle constraints, clone/finalize RPCs, immutability, RLS,
-- and project quote-application history are implemented in 006–010.
BEGIN;

-- Tenant-owned template library. Historical copies in quotes/modules never sync.
CREATE TABLE public.catalog_items (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    item_code text NOT NULL CHECK (length(btrim(item_code)) > 0),
    name text NOT NULL CHECK (length(btrim(name)) > 0),
    category text,
    specifications text,
    length numeric(14,4) CHECK (length IS NULL OR length > 0),
    width numeric(14,4) CHECK (width IS NULL OR width > 0),
    height numeric(14,4) CHECK (height IS NULL OR height > 0),
    depth numeric(14,4) CHECK (depth IS NULL OR depth > 0),
    unit text NOT NULL CHECK (length(btrim(unit)) > 0),
    coefficient numeric(14,4) NOT NULL DEFAULT 1 CHECK (coefficient > 0),
    coefficient_note text,
    notes text,
    is_hidden boolean NOT NULL DEFAULT false,
    created_by uuid NOT NULL,
    updated_by uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_catalog_items_company_id UNIQUE (company_id,id),
    CONSTRAINT uq_catalog_items_company_code UNIQUE (company_id,item_code),
    CONSTRAINT fk_catalog_items_creator FOREIGN KEY (company_id,created_by)
        REFERENCES public.users(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_catalog_items_editor FOREIGN KEY (company_id,updated_by)
        REFERENCES public.users(company_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_catalog_items_visible_name
    ON public.catalog_items(company_id,name) WHERE NOT is_hidden;
CREATE INDEX idx_catalog_items_visible_category
    ON public.catalog_items(company_id,category) WHERE NOT is_hidden;

CREATE TABLE public.catalog_item_materials (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL,
    catalog_item_id uuid NOT NULL,
    material_name text NOT NULL CHECK (length(btrim(material_name)) > 0),
    base_price numeric(18,0) CHECK (base_price IS NULL OR base_price >= 0),
    selling_price numeric(18,0) CHECK (selling_price IS NULL OR selling_price >= 0),
    sort_order integer NOT NULL DEFAULT 0,
    is_hidden boolean NOT NULL DEFAULT false,
    notes text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_catalog_materials_company_id UNIQUE (company_id,id),
    CONSTRAINT uq_catalog_materials_item_identity UNIQUE (company_id,catalog_item_id,id),
    CONSTRAINT fk_catalog_materials_item FOREIGN KEY (company_id,catalog_item_id)
        REFERENCES public.catalog_items(company_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_catalog_materials_item_order
    ON public.catalog_item_materials(company_id,catalog_item_id,sort_order);

-- One Lead can own many separate quote documents; no duplicated customer fields.
CREATE TABLE public.quotes (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL,
    quote_number bigint NOT NULL CHECK (quote_number > 0),
    lead_id uuid NOT NULL,
    title text NOT NULL CHECK (length(btrim(title)) > 0),
    notes text,
    created_by uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_quotes_company_id UNIQUE (company_id,id),
    CONSTRAINT uq_quotes_company_number UNIQUE (company_id,quote_number),
    -- Needed to prove a version's quote belongs to the Project's Lead in 006.
    CONSTRAINT uq_quotes_lead_identity UNIQUE (company_id,id,lead_id),
    CONSTRAINT fk_quotes_lead FOREIGN KEY (company_id,lead_id)
        REFERENCES public.leads(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_quotes_creator FOREIGN KEY (company_id,created_by)
        REFERENCES public.users(company_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_quotes_lead ON public.quotes(company_id,lead_id);

-- Sequential version_number is allocated under SELECT ... FOR UPDATE on quotes.
-- Multiple finalized versions of one quote are allowed.
CREATE TABLE public.quote_versions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL,
    quote_id uuid NOT NULL,
    version_number integer NOT NULL CHECK (version_number > 0),
    status text NOT NULL DEFAULT 'Nháp'
        CHECK (status IN ('Nháp','Đã gửi','Đã chốt','Đã hủy')),
    title text,
    notes text,
    vat_text text,
    -- NULL means unresolved/unpriced material options: display TẠM TÍNH.
    total_amount numeric(18,0) CHECK (total_amount IS NULL OR total_amount >= 0),
    sent_at timestamptz,
    finalized_at timestamptz,
    finalized_by uuid,
    created_from_version_id uuid,
    created_by uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_quote_versions_company_id UNIQUE (company_id,id),
    CONSTRAINT uq_quote_versions_number UNIQUE (company_id,quote_id,version_number),
    CONSTRAINT uq_quote_versions_quote_identity UNIQUE (company_id,id,quote_id),
    -- 006 references the literal finalized state from applied history.
    CONSTRAINT uq_quote_versions_status_identity UNIQUE (company_id,id,status),
    CONSTRAINT fk_quote_versions_quote FOREIGN KEY (company_id,quote_id)
        REFERENCES public.quotes(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_quote_versions_parent FOREIGN KEY (company_id,created_from_version_id,quote_id)
        REFERENCES public.quote_versions(company_id,id,quote_id) ON DELETE RESTRICT,
    CONSTRAINT fk_quote_versions_creator FOREIGN KEY (company_id,created_by)
        REFERENCES public.users(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_quote_versions_finalizer FOREIGN KEY (company_id,finalized_by)
        REFERENCES public.users(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT chk_quote_versions_finalizer CHECK (
        (status = 'Đã chốt' AND finalized_at IS NOT NULL AND finalized_by IS NOT NULL)
        OR (status <> 'Đã chốt' AND finalized_at IS NULL AND finalized_by IS NULL)
    )
);
CREATE INDEX idx_quote_versions_quote_latest
    ON public.quote_versions(company_id,quote_id,version_number DESC);

CREATE TABLE public.quote_rooms (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL,
    version_id uuid NOT NULL,
    name text NOT NULL CHECK (length(btrim(name)) > 0),
    sort_order integer NOT NULL DEFAULT 0,
    notes text,
    CONSTRAINT uq_quote_rooms_company_id UNIQUE (company_id,id),
    CONSTRAINT uq_quote_rooms_version_identity UNIQUE (company_id,id,version_id),
    CONSTRAINT fk_quote_rooms_version FOREIGN KEY (company_id,version_id)
        REFERENCES public.quote_versions(company_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_quote_rooms_version_order
    ON public.quote_rooms(company_id,version_id,sort_order);

CREATE TABLE public.quote_groups (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL,
    version_id uuid NOT NULL,
    room_id uuid NOT NULL,
    name text NOT NULL CHECK (length(btrim(name)) > 0),
    sort_order integer NOT NULL DEFAULT 0,
    notes text,
    CONSTRAINT uq_quote_groups_company_id UNIQUE (company_id,id),
    CONSTRAINT uq_quote_groups_version_identity UNIQUE (company_id,id,version_id),
    CONSTRAINT fk_quote_groups_room_version FOREIGN KEY (company_id,room_id,version_id)
        REFERENCES public.quote_rooms(company_id,id,version_id) ON DELETE RESTRICT
);
CREATE INDEX idx_quote_groups_room_order
    ON public.quote_groups(company_id,room_id,sort_order);

-- Each cloned version gets new row IDs but retains lineage_id for comparison.
-- The calculated quantity is stored as a snapshot and updated only while editable.
CREATE TABLE public.quote_items (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL,
    version_id uuid NOT NULL,
    group_id uuid NOT NULL,
    lineage_id uuid NOT NULL DEFAULT gen_random_uuid(),
    source_catalog_item_id uuid,
    name text NOT NULL CHECK (length(btrim(name)) > 0),
    specifications text,
    length numeric(14,4) CHECK (length IS NULL OR length > 0),
    width numeric(14,4) CHECK (width IS NULL OR width > 0),
    height numeric(14,4) CHECK (height IS NULL OR height > 0),
    depth numeric(14,4) CHECK (depth IS NULL OR depth > 0),
    unit text NOT NULL CHECK (length(btrim(unit)) > 0),
    item_count numeric(14,4) NOT NULL DEFAULT 1 CHECK (item_count > 0),
    quantity_mode text NOT NULL DEFAULT 'auto'
        CHECK (quantity_mode IN ('auto','manual')),
    quantity numeric(18,4) NOT NULL CHECK (quantity > 0),
    coefficient numeric(14,4) NOT NULL DEFAULT 1 CHECK (coefficient > 0),
    coefficient_note text,
    discount_amount numeric(18,0) NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
    extra_amount numeric(18,0) NOT NULL DEFAULT 0 CHECK (extra_amount >= 0),
    finalized_material_id uuid,
    is_included boolean NOT NULL DEFAULT true,
    sort_order integer NOT NULL DEFAULT 0,
    notes text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_quote_items_company_id UNIQUE (company_id,id),
    CONSTRAINT uq_quote_items_version_identity UNIQUE (company_id,id,version_id),
    CONSTRAINT uq_quote_items_lineage_per_version UNIQUE (company_id,version_id,lineage_id),
    CONSTRAINT fk_quote_items_group_version FOREIGN KEY (company_id,group_id,version_id)
        REFERENCES public.quote_groups(company_id,id,version_id) ON DELETE RESTRICT,
    CONSTRAINT fk_quote_items_catalog_source FOREIGN KEY (company_id,source_catalog_item_id)
        REFERENCES public.catalog_items(company_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_quote_items_group_order
    ON public.quote_items(company_id,group_id,sort_order);
CREATE INDEX idx_quote_items_lineage
    ON public.quote_items(company_id,lineage_id);
CREATE INDEX idx_quote_items_catalog_source
    ON public.quote_items(company_id,source_catalog_item_id)
    WHERE source_catalog_item_id IS NOT NULL;

-- is_selected may be true for several alternatives being compared.
-- Exactly one optional definitive option lives on quote_items.finalized_material_id.
CREATE TABLE public.quote_item_materials (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL,
    version_id uuid NOT NULL,
    item_id uuid NOT NULL,
    source_catalog_material_id uuid,
    material_name text NOT NULL CHECK (length(btrim(material_name)) > 0),
    base_price numeric(18,0) CHECK (base_price IS NULL OR base_price >= 0),
    selling_price numeric(18,0) CHECK (selling_price IS NULL OR selling_price >= 0),
    is_selected boolean NOT NULL DEFAULT false,
    sort_order integer NOT NULL DEFAULT 0,
    notes text,
    CONSTRAINT uq_quote_materials_company_id UNIQUE (company_id,id),
    CONSTRAINT uq_quote_materials_item_identity UNIQUE (company_id,item_id,id),
    CONSTRAINT fk_quote_materials_item_version FOREIGN KEY (company_id,item_id,version_id)
        REFERENCES public.quote_items(company_id,id,version_id) ON DELETE RESTRICT,
    CONSTRAINT fk_quote_materials_catalog_source FOREIGN KEY (company_id,source_catalog_material_id)
        REFERENCES public.catalog_item_materials(company_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_quote_materials_item_order
    ON public.quote_item_materials(company_id,item_id,sort_order);

-- 006: add DEFERRABLE composite FK from quote_items
--      (company_id,id,finalized_material_id) to quote_item_materials
--      (company_id,item_id,id); validate selected catalog-material belongs to
--      quote_items.source_catalog_item_id where both are present.
-- 007/008: finalize/cloning RPC, half-up currency calculation, snapshot locks.
-- 009: per-table tenant RLS; revoke direct client writes to protected versions.
REVOKE ALL ON public.catalog_items, public.catalog_item_materials,
    public.quotes, public.quote_versions, public.quote_rooms, public.quote_groups,
    public.quote_items, public.quote_item_materials FROM anon, authenticated;
COMMIT;
