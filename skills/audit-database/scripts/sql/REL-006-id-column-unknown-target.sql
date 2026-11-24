-- id: REL-006
-- severity: medium
-- category: relational-integrity
-- title: Id-like column without a FOREIGN KEY and without an identifiable target table
-- fix: Find what the column references in the ORM models. Internal target -> add the FK; external system id -> say so in a COMMENT ON COLUMN
-- data-probe: false
WITH tabs AS (
  SELECT regexp_replace(regexp_replace(regexp_replace(lower(c.relname), '[^a-z0-9]', '', 'g'),
                        'ies$', 'y'), '(?<=[^s])s$|(?<=(ss|x|ch|sh))es$', '') AS nrm
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind IN ('r', 'p') AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
)
SELECT format('%I.%I.%I', n.nspname, c.relname, a.attname) AS object,
       format('%s, no FOREIGN KEY, no table named after it (self-reference such as parent_id, external id, or renamed target?)',
              format_type(a.atttypid, a.atttypmod)) AS detail
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition
  AND a.attnum > 0 AND NOT a.attisdropped
  AND a.attname ~ '.(_id|Id|ID|_uuid)$'
  AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
  AND c.relname !~ :'ignore_tables'
  AND NOT EXISTS (SELECT 1 FROM pg_constraint k
                  WHERE k.conrelid = c.oid AND k.contype = 'f' AND a.attnum = ANY (k.conkey))
  AND NOT EXISTS (SELECT 1 FROM pg_attribute s
                  WHERE s.attrelid = c.oid AND s.attnum > 0 AND NOT s.attisdropped
                    AND s.attname ~ '.(_type|Type|_kind|Kind|_class|_model|_table|_entity)$'
                    AND lower(regexp_replace(s.attname, '(_type|Type|_kind|Kind|_class|_model|_table|_entity)$', ''))
                        = lower(regexp_replace(a.attname, '(_id|Id|ID|_uuid)$', '')))
  AND NOT EXISTS (SELECT 1 FROM pg_attribute s
                  WHERE s.attrelid = c.oid AND s.attname ~ '^content_?type(_id|Id)?$' AND a.attname ~ '^object_?(id|Id)$')
  AND NOT EXISTS (SELECT 1 FROM tabs t
                  WHERE t.nrm = regexp_replace(regexp_replace(regexp_replace(
                          lower(regexp_replace(a.attname, '(_id|Id|ID|_uuid)$', '')), '[^a-z0-9]', '', 'g'),
                          'ies$', 'y'), '(?<=[^s])s$|(?<=(ss|x|ch|sh))es$', ''))
