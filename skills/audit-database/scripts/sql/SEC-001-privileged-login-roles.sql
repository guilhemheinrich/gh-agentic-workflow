-- id: SEC-001
-- severity: medium
-- category: security
-- title: Login role with elevated attributes (inventory - expect only the DBA role here)
-- fix: The application must connect as a role with none of these; split owner (migrations) / writer (app) / reader (BI) roles
-- data-probe: false
SELECT format('role %I', r.rolname) AS object,
       format('can log in with: %s%s', concat_ws(', ',
              CASE WHEN r.rolsuper THEN 'SUPERUSER' END,
              CASE WHEN r.rolbypassrls THEN 'BYPASSRLS' END,
              CASE WHEN r.rolcreaterole THEN 'CREATEROLE' END,
              CASE WHEN r.rolcreatedb THEN 'CREATEDB' END,
              CASE WHEN r.rolreplication THEN 'REPLICATION' END,
              (SELECT 'member of ' || string_agg(g.rolname, ', ')
               FROM pg_auth_members m JOIN pg_roles g ON g.oid = m.roleid
               WHERE m.member = r.oid
                 AND g.rolname IN ('pg_write_server_files', 'pg_read_server_files', 'pg_execute_server_program', 'pg_write_all_data'))),
              CASE WHEN r.rolvaliduntil IS NULL THEN '; password never expires' ELSE '' END) AS detail
FROM pg_roles r
WHERE r.rolcanlogin AND r.rolname !~ '^pg_'
  AND (r.rolsuper OR r.rolbypassrls OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication
       OR EXISTS (SELECT 1 FROM pg_auth_members m JOIN pg_roles g ON g.oid = m.roleid
                  WHERE m.member = r.oid
                    AND g.rolname IN ('pg_write_server_files', 'pg_read_server_files', 'pg_execute_server_program', 'pg_write_all_data')))
