-- id: TEN-002
-- severity: high
-- category: multi-tenancy
-- title: Foreign key between two tenant-scoped tables that does not carry the tenant column
-- fix: Add UNIQUE (tenant_id, id) on the parent and reference it with FOREIGN KEY (tenant_id, parent_id): the child can then only point inside its own tenant
-- data-probe: false
WITH tt AS (
  SELECT a.attrelid AS relid, a.attnum, a.attname
  FROM pg_attribute a
  WHERE a.attnum > 0 AND NOT a.attisdropped AND a.attname ~ :'tenant_col'
)
SELECT format('%I.%I %I', n.nspname, c.relname, k.conname) AS object,
       format('%s: both tables carry %I, the key does not: a row of tenant A may reference a %I row of tenant B',
              pg_get_constraintdef(k.oid), ct.attname, pc.relname) AS detail
FROM pg_constraint k
JOIN pg_class c ON c.oid = k.conrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_class pc ON pc.oid = k.confrelid
JOIN tt ct ON ct.relid = k.conrelid
JOIN tt pt ON pt.relid = k.confrelid
WHERE k.contype = 'f' AND k.conparentid = 0
  AND NOT ct.attnum = ANY (k.conkey)
  AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
  AND c.relname !~ :'ignore_tables'
