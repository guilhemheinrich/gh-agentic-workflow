-- id: AUD-001
-- severity: low
-- category: conventions
-- title: Table without created_at / updated_at
-- fix: ADD COLUMN created_at timestamptz NOT NULL DEFAULT now(), updated_at likewise (skills/sql-migration-guidelines rule: every table, join tables included)
-- data-probe: false
SELECT format('%I.%I', n.nspname, c.relname) AS object,
       format('missing: %s', concat_ws(', ',
              CASE WHEN NOT x.has_created THEN 'creation timestamp' END,
              CASE WHEN NOT x.has_updated THEN 'update timestamp' END)) AS detail
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
CROSS JOIN LATERAL (
  SELECT coalesce(bool_or(a.attname ~* '^(created_?(at|on)|inserted_?at|creation_?date|date_?created|created)$'), false) AS has_created,
         coalesce(bool_or(a.attname ~* '^(updated_?(at|on)|modified_?(at|on)|last_?modified(_?at)?|date_?updated|updated)$'), false) AS has_updated
  FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped) x
WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition
  AND NOT (x.has_created AND x.has_updated)
  AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
  AND c.relname !~ :'ignore_tables'
