-- 001_foundation.sql — clean-install schema for Supabase PostgreSQL.
-- Assumes gen_random_uuid() and Supabase auth.users are available.
-- Apply using a privileged migration role, not authenticated/anon.
BEGIN;

CREATE SCHEMA IF NOT EXISTS app_private;
REVOKE ALL ON SCHEMA app_private FROM PUBLIC, anon, authenticated;

CREATE TABLE public.companies (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL CHECK (length(btrim(name)) > 0),
    status text NOT NULL DEFAULT 'active'
      CHECK (status IN ('active', 'suspended')),
    timezone text NOT NULL DEFAULT 'Asia/Ho_Chi_Minh',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.permissions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code text NOT NULL UNIQUE CHECK (code ~ '^[a-z_]+\.[a-z_]+$'),
    description text NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.roles (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    code text NOT NULL CHECK (code ~ '^[a-z][a-z0-9_]*$'),
    name text NOT NULL CHECK (length(btrim(name)) > 0),
    is_system_default boolean NOT NULL DEFAULT false,
    is_protected boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_roles_company_id UNIQUE (company_id, id),
    CONSTRAINT uq_roles_company_code UNIQUE (company_id, code),
    CONSTRAINT chk_roles_protected_code CHECK (
      (code IN ('owner','admin') AND is_system_default AND is_protected)
      OR (code NOT IN ('owner','admin') AND NOT is_protected)
    )
);

CREATE TABLE public.users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    auth_user_id uuid NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE RESTRICT,
    role_id uuid NOT NULL,
    full_name text NOT NULL CHECK (length(btrim(full_name)) > 0),
    email text NOT NULL,
    department text,
    is_active boolean NOT NULL DEFAULT true,
    notification_sound_enabled boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_users_company_id UNIQUE (company_id, id),
    CONSTRAINT fk_users_role_same_company FOREIGN KEY (company_id,role_id)
      REFERENCES public.roles(company_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_users_company_role ON public.users(company_id,role_id);
CREATE INDEX idx_users_company_active ON public.users(company_id,id) WHERE is_active;

CREATE TABLE public.role_permissions (
    company_id uuid NOT NULL,
    role_id uuid NOT NULL,
    permission_id uuid NOT NULL REFERENCES public.permissions(id) ON DELETE RESTRICT,
    granted_by uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (company_id,role_id,permission_id),
    CONSTRAINT fk_role_permissions_role FOREIGN KEY (company_id,role_id)
      REFERENCES public.roles(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_role_permissions_actor FOREIGN KEY (company_id,granted_by)
      REFERENCES public.users(company_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_role_permissions_permission ON public.role_permissions(permission_id);

-- A user override exists only for an exception: allow / deny.
-- No row = inherit from assigned role. Protected owner/admin operations
-- are NOT ordinary permission codes and must be guarded in RPCs/triggers.
CREATE TABLE public.user_permissions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL,
    user_id uuid NOT NULL,
    permission_id uuid NOT NULL REFERENCES public.permissions(id) ON DELETE RESTRICT,
    effect text NOT NULL CHECK (effect IN ('allow','deny')),
    granted_by uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_user_permission UNIQUE (company_id,user_id,permission_id),
    CONSTRAINT fk_user_permissions_user FOREIGN KEY (company_id,user_id)
      REFERENCES public.users(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_user_permissions_actor FOREIGN KEY (company_id,granted_by)
      REFERENCES public.users(company_id,id) ON DELETE RESTRICT
);
CREATE INDEX idx_user_permissions_user ON public.user_permissions(company_id,user_id);

-- Platform catalog. Every company subscription stores its contracted snapshot.
CREATE TABLE public.subscription_plans (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code text NOT NULL UNIQUE CHECK (code IN ('starter','business','enterprise')),
    name text NOT NULL,
    annual_price_vnd bigint NOT NULL CHECK (annual_price_vnd >= 0),
    max_active_users integer NOT NULL CHECK (max_active_users > 0),
    max_projects integer NOT NULL CHECK (max_projects > 0),
    r2_storage_bytes bigint NOT NULL CHECK (r2_storage_bytes > 0),
    grace_period interval NOT NULL CHECK (grace_period > interval '0 seconds'),
    free_onedrive_gb integer NOT NULL DEFAULT 0 CHECK (free_onedrive_gb >= 0),
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.company_subscriptions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    plan_id uuid NOT NULL REFERENCES public.subscription_plans(id) ON DELETE RESTRICT,
    starts_at timestamptz NOT NULL,
    expires_at timestamptz NOT NULL,
    grace_ends_at timestamptz NOT NULL,
    price_paid_vnd bigint NOT NULL CHECK (price_paid_vnd >= 0),
    max_active_users integer NOT NULL CHECK (max_active_users > 0),
    max_projects integer NOT NULL CHECK (max_projects > 0),
    r2_storage_bytes bigint NOT NULL CHECK (r2_storage_bytes > 0),
    free_onedrive_gb integer NOT NULL DEFAULT 0 CHECK (free_onedrive_gb >= 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_company_subscription_identity UNIQUE (company_id,id),
    CONSTRAINT chk_subscription_period CHECK (
      starts_at < expires_at AND expires_at <= grace_ends_at
    )
);
CREATE INDEX idx_company_subscription_period ON public.company_subscriptions(company_id,starts_at DESC,expires_at DESC);
-- Active-period overlap must be rejected by subscription-management RPC
-- or an exclusion constraint in 006 if btree_gist is enabled.

CREATE TABLE public.company_counters (
    company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    counter_type text NOT NULL CHECK (counter_type IN ('lead','project','quote')),
    last_value bigint NOT NULL DEFAULT 0 CHECK (last_value >= 0),
    PRIMARY KEY (company_id,counter_type)
);

CREATE TABLE public.company_settings (
    company_id uuid PRIMARY KEY REFERENCES public.companies(id) ON DELETE RESTRICT,
    tier_s_max_vnd bigint CHECK (tier_s_max_vnd IS NULL OR tier_s_max_vnd >= 0),
    tier_m_max_vnd bigint CHECK (tier_m_max_vnd IS NULL OR tier_m_max_vnd >= 0),
    tier_l_max_vnd bigint CHECK (tier_l_max_vnd IS NULL OR tier_l_max_vnd >= 0),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT chk_company_tier_order CHECK (
      (tier_s_max_vnd IS NULL OR tier_m_max_vnd IS NULL OR tier_s_max_vnd < tier_m_max_vnd)
      AND (tier_m_max_vnd IS NULL OR tier_l_max_vnd IS NULL OR tier_m_max_vnd < tier_l_max_vnd)
    )
);

-- Deny direct client access until explicit RLS/GRANTs in 009.
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon, authenticated;
COMMIT;
