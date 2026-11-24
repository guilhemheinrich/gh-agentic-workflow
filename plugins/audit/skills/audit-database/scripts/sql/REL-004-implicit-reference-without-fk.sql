-- id: REL-004
-- severity: high
-- category: relational-integrity
-- title: Column named like a reference to an existing table, without a FOREIGN KEY
-- fix: Clean orphans (REL-005), then ADD CONSTRAINT ... FOREIGN KEY ... NOT VALID followed by VALIDATE CONSTRAINT, with an explicit ON DELETE
-- data-probe: false
WITH tabs AS (
  SELECT n.nspname, c.relname,
         regexp_replace(regexp_replace(regexp_replace(lower(c.relname), '[^a-z0-9]', '', 'g'),
                        'ies$', 'y'), '(?<=[^s])s$|(?<=(ss|x|ch|sh))es$', '') AS nrm
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind IN ('r', 'p') AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
), cand AS (
  SELECT n.nspname, c.relname, a.attname, format_type(a.atttypid, a.atttypmod) AS typ,
         regexp_replace(regexp_replace(regexp_replace(
           lower(regexp_replace(a.attname, '(_id|Id|ID|_uuid)$', '')), '[^a-z0-9]', '', 'g'),
           'ies$', 'y'), '(?<=[^s])s$|(?<=(ss|x|ch|sh))es$', '') AS nrm
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
    -- polymorphic ids are reported by REL-001
    AND NOT EXISTS (SELECT 1 FROM pg_attribute s
                    WHERE s.attrelid = c.oid AND s.attnum > 0 AND NOT s.attisdropped
                      AND s.attname ~ '.(_type|Type|_kind|Kind|_class|_model|_table|_entity)$'
                      AND lower(regexp_replace(s.attname, '(_type|Type|_kind|Kind|_class|_model|_table|_entity)$', ''))
                          = lower(regexp_replace(a.attname, '(_id|Id|ID|_uuid)$', '')))
)
SELECT format('%I.%I.%I', cand.nspname, cand.relname, cand.attname) AS object,
       format('%s, no FOREIGN KEY; the name designates table %I.%I', cand.typ, t.nspname, t.relname) AS detail
FROM cand
JOIN tabs t ON t.nrm = cand.nrm AND t.nspname = cand.nspname
