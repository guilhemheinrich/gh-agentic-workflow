-- id: NAM-001
-- severity: low
-- category: conventions
-- title: Naming inconsistency (identifiers needing quotes, mixed singular/plural table names)
-- fix: Pick one convention (snake_case, one grammatical number) and rename the minority; in the ORM, map explicitly instead of letting it generate quoted camelCase
-- data-probe: false
WITH t AS (
  SELECT c.oid, n.nspname, c.relname, c.relname ~ 's$' AS plural,
         count(*) OVER (PARTITION BY n.nspname) AS total,
         count(*) FILTER (WHERE c.relname ~ 's$') OVER (PARTITION BY n.nspname) AS plurals
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition
    AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
    AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
    AND c.relname !~ :'ignore_tables'
)
SELECT format('%I.%I', nspname, relname) AS object,
       'table name must be double-quoted in every query (upper case or special characters)' AS detail
FROM t WHERE relname !~ '^[a-z_][a-z0-9_]*$'
UNION ALL
SELECT format('%I.%I.%I', t.nspname, t.relname, a.attname),
       'column name must be double-quoted in every query (upper case or special characters)'
FROM t JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum > 0 AND NOT a.attisdropped
WHERE a.attname !~ '^[a-z_][a-z0-9_]*$'
UNION ALL
SELECT format('%I.%I', nspname, relname),
       format('%s name in a schema where %s of %s tables are %s',
              CASE WHEN plural THEN 'plural' ELSE 'singular' END,
              CASE WHEN plural THEN total - plurals ELSE plurals END, total,
              CASE WHEN plural THEN 'singular' ELSE 'plural' END)
FROM t
WHERE total >= 5
  AND ((plural AND plurals::numeric / total <= 0.34) OR (NOT plural AND (total - plurals)::numeric / total <= 0.34))
