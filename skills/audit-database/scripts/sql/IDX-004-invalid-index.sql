-- id: IDX-004
-- severity: medium
-- category: migration-safety
-- title: Invalid index (leftover of a failed CREATE INDEX CONCURRENTLY)
-- fix: DROP INDEX CONCURRENTLY it and re-run the creation; an invalid index is maintained on every write but never used by a query
-- data-probe: false
SELECT format('%I.%I', n.nspname, ic.relname) AS object,
       format('invalid index on %I: %s', c.relname, pg_get_indexdef(i.indexrelid)) AS detail
FROM pg_index i
JOIN pg_class ic ON ic.oid = i.indexrelid
JOIN pg_class c ON c.oid = i.indrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE NOT i.indisvalid
  AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
  AND c.relname !~ :'ignore_tables'
