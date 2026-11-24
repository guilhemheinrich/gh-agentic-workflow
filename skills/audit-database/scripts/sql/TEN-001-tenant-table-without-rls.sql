-- id: TEN-001
-- severity: medium
-- category: multi-tenancy
-- title: Tenant-scoped table without row level security
-- fix: ENABLE + FORCE ROW LEVEL SECURITY with a policy on the tenant column . If isolation is deliberately app-side, record that decision
-- data-probe: false
SELECT format('%I.%I', n.nspname, c.relname) AS object,
       format('has %I but relrowsecurity = false: one forgotten WHERE in application code exposes every tenant', a.attname) AS detail
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition
  AND a.attnum > 0 AND NOT a.attisdropped
  AND a.attname ~ :'tenant_col' AND NOT c.relrowsecurity
  AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
  AND c.relname !~ :'ignore_tables'
