-- id: CON-001
-- severity: medium
-- category: constraints
-- title: Enumeration stored as free text (status/type/role column with no CHECK, enum type or lookup FK)
-- fix: Add CHECK (col IN (...)), a native enum or a lookup table with a foreign key; the list of legal values must be readable from the schema
-- data-probe: false
SELECT format('%I.%I.%I', n.nspname, c.relname, a.attname) AS object,
       format('%s with no CHECK and no FOREIGN KEY%s', format_type(a.atttypid, a.atttypmod),
              coalesce((SELECT format('; planner statistics: %s distinct values',
                                      CASE WHEN s.n_distinct >= 0 THEN s.n_distinct::bigint::text
                                           ELSE round((-s.n_distinct * greatest(c.reltuples, 0))::numeric)::text END)
                        FROM pg_stats s
                        WHERE s.schemaname = n.nspname AND s.tablename = c.relname AND s.attname = a.attname), '')) AS detail
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition
  AND a.attnum > 0 AND NOT a.attisdropped
  AND a.atttypid IN ('text'::regtype, 'varchar'::regtype, 'bpchar'::regtype)
  AND a.attname ~* '^(.*_)?(status|state|type|kind|role|category|level|mode|priority|stage|phase|visibility|gender|currency|locale)$'
  AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
  AND c.relname !~ :'ignore_tables'
  AND NOT EXISTS (SELECT 1 FROM pg_constraint k
                  WHERE k.conrelid = c.oid AND k.contype IN ('c', 'f') AND a.attnum = ANY (k.conkey))
