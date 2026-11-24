-- id: TYP-003
-- severity: low
-- category: types
-- title: JSON column (inventory of places where structure escapes the schema)
-- fix: For each one decide - opaque payload (keep, COMMENT its shape) or relational data in disguise (TYP-004: extract columns/tables). Prefer jsonb over json
-- data-probe: false
SELECT format('%I.%I.%I', n.nspname, c.relname, a.attname) AS object,
       format('%s%s%s', format_type(a.atttypid, a.atttypmod),
              CASE WHEN a.atttypid = 'json'::regtype THEN ' (text storage: no indexing, duplicate keys kept)' ELSE '' END,
              CASE WHEN EXISTS (SELECT 1 FROM pg_constraint k
                                WHERE k.conrelid = c.oid AND k.contype = 'c' AND a.attnum = ANY (k.conkey))
                   THEN '; shape constrained by a CHECK' ELSE '; no CHECK on its shape' END) AS detail
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition
  AND a.attnum > 0 AND NOT a.attisdropped
  AND a.atttypid IN ('json'::regtype, 'jsonb'::regtype)
  AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
  AND c.relname !~ :'ignore_tables'
