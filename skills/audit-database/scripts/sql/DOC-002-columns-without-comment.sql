-- id: DOC-002
-- severity: low
-- category: readability
-- title: Columns without COMMENT (per table)
-- fix: Comment at least the columns whose meaning, unit or allowed values are not obvious from the name (status codes, amounts, flags, JSON shapes)
-- data-probe: false
SELECT format('%I.%I', n.nspname, c.relname) AS object,
       format('%s of %s columns have no comment', count(*) FILTER (WHERE col_description(c.oid, a.attnum) IS NULL), count(*)) AS detail
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition
  AND a.attnum > 0 AND NOT a.attisdropped
  AND a.attname !~* '^(id|created_?at|updated_?at|deleted_?at)$'
  AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
  AND c.relname !~ :'ignore_tables'
GROUP BY n.nspname, c.relname, c.oid
HAVING count(*) FILTER (WHERE col_description(c.oid, a.attnum) IS NULL) > 0
