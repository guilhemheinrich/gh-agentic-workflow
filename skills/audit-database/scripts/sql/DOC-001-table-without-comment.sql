-- id: DOC-001
-- severity: low
-- category: readability
-- title: Table without COMMENT
-- fix: COMMENT ON TABLE ... IS '<business meaning, lifecycle, owner>' (template: skills/sql-migration-guidelines/templates/comments.sql)
-- data-probe: false
SELECT format('%I.%I', n.nspname, c.relname) AS object,
       'no table comment: a reader of the database alone cannot tell what a row represents' AS detail
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition
  AND obj_description(c.oid, 'pg_class') IS NULL
  AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
  AND c.relname !~ :'ignore_tables'
