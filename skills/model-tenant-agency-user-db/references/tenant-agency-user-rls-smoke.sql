-- Smoke test for tenant-agency-user-postgres.sql.
-- Run after loading the reference schema into an empty PostgreSQL database.

CREATE ROLE app_client;
GRANT USAGE ON SCHEMA app TO app_client;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA app TO app_client;

INSERT INTO app.tenants (id, name) VALUES
  ('00000000-0000-0000-0000-000000000001', 'Tenant 1'),
  ('00000000-0000-0000-0000-000000000002', 'Tenant 2');

INSERT INTO app.agencies (id, tenant_id, name) VALUES
  ('00000000-0000-0000-0000-000000000101', '00000000-0000-0000-0000-000000000001', 'Agency 1A'),
  ('00000000-0000-0000-0000-000000000102', '00000000-0000-0000-0000-000000000001', 'Agency 1B'),
  ('00000000-0000-0000-0000-000000000201', '00000000-0000-0000-0000-000000000002', 'Agency 2A');

INSERT INTO app.users (id, tenant_id, agency_id, email, role) VALUES
  ('00000000-0000-0000-0000-000000001001', '00000000-0000-0000-0000-000000000001', NULL, 'admin@t1.test', 'admin_tenant'),
  ('00000000-0000-0000-0000-000000001002', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000101', 'agency-admin@t1.test', 'admin_agency'),
  ('00000000-0000-0000-0000-000000002001', '00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000201', 'user@t2.test', 'user');

INSERT INTO app.agency_records (tenant_id, agency_id, title, created_by_user_id) VALUES
  ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000101', 'T1 A1 record', '00000000-0000-0000-0000-000000001002'),
  ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000102', 'T1 A2 record', '00000000-0000-0000-0000-000000001002'),
  ('00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000201', 'T2 A1 record', '00000000-0000-0000-0000-000000002001');

SET ROLE app_client;
SET app.current_tenant_id = '00000000-0000-0000-0000-000000000001';
SET app.current_user_id = '00000000-0000-0000-0000-000000001001';

DO $$
DECLARE
  agencies_count integer;
  records_count integer;
BEGIN
  SELECT count(*) INTO agencies_count FROM app.agencies;
  SELECT count(*) INTO records_count FROM app.agency_records;

  IF agencies_count <> 2 THEN
    RAISE EXCEPTION 'tenant admin agency visibility expected 2, got %', agencies_count;
  END IF;

  IF records_count <> 2 THEN
    RAISE EXCEPTION 'tenant admin record visibility expected 2, got %', records_count;
  END IF;
END $$;

SET app.current_user_id = '00000000-0000-0000-0000-000000001002';

DO $$
DECLARE
  agencies_count integer;
  records_count integer;
BEGIN
  SELECT count(*) INTO agencies_count FROM app.agencies;
  SELECT count(*) INTO records_count FROM app.agency_records;

  IF agencies_count <> 1 THEN
    RAISE EXCEPTION 'agency admin agency visibility expected 1, got %', agencies_count;
  END IF;

  IF records_count <> 1 THEN
    RAISE EXCEPTION 'agency admin record visibility expected 1, got %', records_count;
  END IF;
END $$;

RESET ROLE;

SELECT 'RLS smoke assertions passed' AS result;
