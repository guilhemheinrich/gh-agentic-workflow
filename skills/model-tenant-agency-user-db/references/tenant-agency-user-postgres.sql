-- PostgreSQL reference model for tenant / agency / user domains.
-- Assumptions:
-- - The application sets app.current_tenant_id and app.current_user_id on each
--   transaction after authenticating the request.
-- - Tenant admins are tenant-scoped and have no agency.
-- - Agency admins and simple users are scoped to exactly one agency.
-- - Billing examples intentionally use RESTRICT to preserve historical rows.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE SCHEMA IF NOT EXISTS app;

CREATE TYPE app.user_role AS ENUM (
  'admin_tenant',
  'admin_agency',
  'user'
);

CREATE TABLE app.tenants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'suspended', 'closed')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE app.agencies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL
    REFERENCES app.tenants(id) ON DELETE RESTRICT,
  name text NOT NULL,
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'closed')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, name)
);

CREATE TABLE app.users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL
    REFERENCES app.tenants(id) ON DELETE RESTRICT,
  agency_id uuid NULL,
  email text NOT NULL,
  role app.user_role NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  CONSTRAINT users_agency_same_tenant_fk
    FOREIGN KEY (tenant_id, agency_id)
    REFERENCES app.agencies(tenant_id, id)
    ON DELETE RESTRICT,
  CONSTRAINT users_role_agency_scope_ck CHECK (
    (role = 'admin_tenant' AND agency_id IS NULL)
    OR
    (role IN ('admin_agency', 'user') AND agency_id IS NOT NULL)
  ),
  UNIQUE (tenant_id, email)
);

CREATE INDEX agencies_tenant_id_idx ON app.agencies(tenant_id);
CREATE INDEX users_tenant_id_idx ON app.users(tenant_id);
CREATE INDEX users_agency_id_idx ON app.users(agency_id);

-- Generic agency-scoped business resource. This can represent mandates,
-- properties, contacts, tasks, opportunities, or other operational rows.
CREATE TABLE app.agency_records (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  agency_id uuid NOT NULL,
  title text NOT NULL,
  created_by_user_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT agency_records_agency_same_tenant_fk
    FOREIGN KEY (tenant_id, agency_id)
    REFERENCES app.agencies(tenant_id, id)
    ON DELETE RESTRICT,
  CONSTRAINT agency_records_created_by_fk
    FOREIGN KEY (tenant_id, created_by_user_id)
    REFERENCES app.users(tenant_id, id)
    ON DELETE RESTRICT
);

CREATE INDEX agency_records_tenant_agency_idx
  ON app.agency_records(tenant_id, agency_id);

-- Billing has its own retention needs. Do not cascade-delete invoice history
-- from tenant or agency by default; close/archive the tenant instead.
CREATE TABLE app.invoices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL
    REFERENCES app.tenants(id) ON DELETE RESTRICT,
  agency_id uuid NULL,
  invoice_number text NOT NULL,
  issued_at date NOT NULL,
  status text NOT NULL
    CHECK (status IN ('draft', 'issued', 'paid', 'void')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  CONSTRAINT invoices_agency_same_tenant_fk
    FOREIGN KEY (tenant_id, agency_id)
    REFERENCES app.agencies(tenant_id, id)
    ON DELETE RESTRICT,
  UNIQUE (tenant_id, invoice_number)
);

CREATE TABLE app.invoice_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL,
  invoice_id uuid NOT NULL,
  label text NOT NULL,
  amount_cents integer NOT NULL CHECK (amount_cents >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT invoice_lines_invoice_fk
    FOREIGN KEY (tenant_id, invoice_id)
    REFERENCES app.invoices(tenant_id, id)
    ON DELETE RESTRICT
);

CREATE INDEX invoices_tenant_agency_idx ON app.invoices(tenant_id, agency_id);
CREATE INDEX invoice_lines_tenant_invoice_idx
  ON app.invoice_lines(tenant_id, invoice_id);

CREATE OR REPLACE FUNCTION app.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER tenants_set_updated_at
BEFORE UPDATE ON app.tenants
FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();

CREATE TRIGGER agencies_set_updated_at
BEFORE UPDATE ON app.agencies
FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();

CREATE TRIGGER users_set_updated_at
BEFORE UPDATE ON app.users
FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();

CREATE TRIGGER agency_records_set_updated_at
BEFORE UPDATE ON app.agency_records
FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();

CREATE TRIGGER invoices_set_updated_at
BEFORE UPDATE ON app.invoices
FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();

-- Trusted session context helpers.
CREATE OR REPLACE FUNCTION app.current_tenant_id()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
  SELECT nullif(current_setting('app.current_tenant_id', true), '')::uuid
$$;

CREATE OR REPLACE FUNCTION app.current_user_id()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
  SELECT nullif(current_setting('app.current_user_id', true), '')::uuid
$$;

CREATE OR REPLACE FUNCTION app.current_user_role()
RETURNS app.user_role
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
  SELECT u.role
  FROM app.users u
  WHERE u.id = app.current_user_id()
    AND u.tenant_id = app.current_tenant_id()
    AND u.is_active
$$;

CREATE OR REPLACE FUNCTION app.current_user_agency_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
  SELECT u.agency_id
  FROM app.users u
  WHERE u.id = app.current_user_id()
    AND u.tenant_id = app.current_tenant_id()
    AND u.is_active
$$;

CREATE OR REPLACE FUNCTION app.can_access_agency(target_agency_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
  SELECT CASE
    WHEN app.current_user_role() = 'admin_tenant' THEN true
    WHEN app.current_user_role() IN ('admin_agency', 'user')
      THEN target_agency_id = app.current_user_agency_id()
    ELSE false
  END
$$;

ALTER TABLE app.tenants ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.agencies ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.agency_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.invoice_lines ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenants_isolated_by_current_tenant
ON app.tenants
FOR ALL
USING (id = app.current_tenant_id())
WITH CHECK (id = app.current_tenant_id());

CREATE POLICY agencies_visible_by_role_scope
ON app.agencies
FOR SELECT
USING (
  tenant_id = app.current_tenant_id()
  AND app.can_access_agency(id)
);

CREATE POLICY agencies_write_by_tenant_admin
ON app.agencies
FOR INSERT
WITH CHECK (
  tenant_id = app.current_tenant_id()
  AND app.current_user_role() = 'admin_tenant'
);

CREATE POLICY agencies_update_by_tenant_admin
ON app.agencies
FOR UPDATE
USING (
  tenant_id = app.current_tenant_id()
  AND app.current_user_role() = 'admin_tenant'
)
WITH CHECK (
  tenant_id = app.current_tenant_id()
  AND app.current_user_role() = 'admin_tenant'
);

CREATE POLICY users_visible_by_role_scope
ON app.users
FOR SELECT
USING (
  tenant_id = app.current_tenant_id()
  AND (
    app.current_user_role() = 'admin_tenant'
    OR agency_id = app.current_user_agency_id()
    OR id = app.current_user_id()
  )
);

CREATE POLICY users_insert_by_admins
ON app.users
FOR INSERT
WITH CHECK (
  tenant_id = app.current_tenant_id()
  AND (
    app.current_user_role() = 'admin_tenant'
    OR (
      app.current_user_role() = 'admin_agency'
      AND role = 'user'
      AND agency_id = app.current_user_agency_id()
    )
  )
);

CREATE POLICY agency_records_visible_by_role_scope
ON app.agency_records
FOR SELECT
USING (
  tenant_id = app.current_tenant_id()
  AND app.can_access_agency(agency_id)
);

CREATE POLICY agency_records_write_by_agency_scope
ON app.agency_records
FOR INSERT
WITH CHECK (
  tenant_id = app.current_tenant_id()
  AND app.can_access_agency(agency_id)
  AND created_by_user_id = app.current_user_id()
);

CREATE POLICY invoices_visible_by_tenant_or_agency_scope
ON app.invoices
FOR SELECT
USING (
  tenant_id = app.current_tenant_id()
  AND (
    app.current_user_role() = 'admin_tenant'
    OR (agency_id IS NOT NULL AND agency_id = app.current_user_agency_id())
  )
);

CREATE POLICY invoice_lines_visible_through_invoice
ON app.invoice_lines
FOR SELECT
USING (
  tenant_id = app.current_tenant_id()
  AND EXISTS (
    SELECT 1
    FROM app.invoices i
    WHERE i.id = invoice_lines.invoice_id
      AND i.tenant_id = invoice_lines.tenant_id
      AND (
        app.current_user_role() = 'admin_tenant'
        OR (i.agency_id IS NOT NULL AND i.agency_id = app.current_user_agency_id())
      )
  )
);

-- Example application-side transaction setup:
-- BEGIN;
-- SELECT set_config('app.current_tenant_id', '<tenant-uuid>', true);
-- SELECT set_config('app.current_user_id', '<user-uuid>', true);
-- SELECT * FROM app.agency_records;
-- COMMIT;

COMMENT ON TABLE app.tenants IS
  'Tenant/customer organization. Prefer close/archive over delete when historical data exists.';
COMMENT ON TABLE app.agencies IS
  'Operational agency belonging to exactly one tenant.';
COMMENT ON TABLE app.users IS
  'Human user attached to one tenant and zero or one agency depending on role.';
COMMENT ON CONSTRAINT users_role_agency_scope_ck ON app.users IS
  'Tenant admins have no agency; agency admins and simple users must have one agency.';
COMMENT ON TABLE app.invoices IS
  'Billing history retained independently from tenant or agency deletion.';
