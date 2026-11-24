-- id: SEC-003
-- severity: medium
-- category: security
-- title: Tables owned by a role that can log in
-- fix: Own tables with a NOLOGIN role used only by migrations; the runtime role gets SELECT/INSERT/UPDATE/DELETE grants and cannot ALTER, DROP or TRUNCATE
-- data-probe: false
SELECT format('schema %I, owner %I', n.nspname, r.rolname) AS object,
       format('%s tables owned by login role %I%s: if the application connects as it, an injection can DROP/ALTER, and RLS does not apply unless FORCEd',
              count(*), r.rolname, CASE WHEN r.rolsuper THEN ' (superuser)' ELSE '' END) AS detail
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_roles r ON r.oid = c.relowner
WHERE c.relkind IN ('r', 'p') AND r.rolcanlogin
  AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
  AND c.relname !~ :'ignore_tables'
GROUP BY n.nspname, r.rolname, r.rolsuper
