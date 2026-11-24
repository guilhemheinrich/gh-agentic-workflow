-- id: TYP-002
-- severity: medium
-- category: types
-- title: timestamp without time zone
-- fix: ALTER COLUMN ... TYPE timestamptz USING col AT TIME ZONE '<zone the app wrote in>' (rewrites the table: plan it as a migration)
-- data-probe: false
SELECT format('%I.%I.%I', n.nspname, c.relname, a.attname) AS object,
       'timestamp without time zone: the instant depends on which session time zone wrote it; nothing in the schema says which' AS detail
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition
  AND a.attnum > 0 AND NOT a.attisdropped
  AND a.atttypid = 'timestamp'::regtype
  AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
  AND c.relname !~ :'ignore_tables'
