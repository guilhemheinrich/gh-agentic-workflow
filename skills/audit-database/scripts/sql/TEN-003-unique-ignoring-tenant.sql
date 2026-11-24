-- id: TEN-003
-- severity: low
-- category: multi-tenancy
-- title: UNIQUE index on a tenant-scoped table that does not include the tenant column
-- fix: Decide per index - global uniqueness on purpose (keep, COMMENT it) or per-tenant uniqueness (recreate as UNIQUE (tenant_id, ...)). A global one leaks existence across tenants
-- data-probe: false
SELECT format('%I.%I %I', n.nspname, c.relname, ic.relname) AS object,
       format('%s does not include %I', pg_get_indexdef(i.indexrelid), a.attname) AS detail
FROM pg_index i
JOIN pg_class ic ON ic.oid = i.indexrelid
JOIN pg_class c ON c.oid = i.indrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped AND a.attname ~ :'tenant_col'
WHERE i.indisunique AND NOT i.indisprimary
  AND NOT a.attnum = ANY (i.indkey::int2[])
  AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
  AND c.relname !~ :'ignore_tables'
