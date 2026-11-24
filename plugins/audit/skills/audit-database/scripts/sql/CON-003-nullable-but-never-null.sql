-- id: CON-003
-- severity: low
-- category: constraints
-- title: Nullable column with no NULL seen by ANALYZE (NOT NULL possibly enforced only by the application)
-- fix: If the domain requires the value, add NOT NULL through a validated CHECK (col IS NOT NULL) first to avoid a long ACCESS EXCLUSIVE scan
-- data-probe: false
SELECT format('%I.%I.%I', n.nspname, c.relname, a.attname) AS object,
       format('nullable, but planner statistics show 0 NULL over ~%s rows', c.reltuples::bigint) AS detail
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_stats s ON s.schemaname = n.nspname AND s.tablename = c.relname AND s.attname = a.attname
WHERE c.relkind = 'r' AND a.attnum > 0 AND NOT a.attisdropped AND NOT a.attnotnull
  AND s.null_frac = 0 AND c.reltuples >= :min_rows
  AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
  AND c.relname !~ :'ignore_tables'
