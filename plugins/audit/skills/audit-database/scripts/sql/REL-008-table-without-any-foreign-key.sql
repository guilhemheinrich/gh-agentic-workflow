-- id: REL-008
-- severity: medium
-- category: relational-integrity
-- title: Isolated table (no foreign key in or out)
-- fix: Confirm it is genuinely standalone (settings, lookup). If it has *_id columns (REL-004/REL-006) its relations live only in application code
-- data-probe: false
SELECT format('%I.%I', n.nspname, c.relname) AS object,
       format('no incoming or outgoing foreign key; %s id-like column(s)',
              (SELECT count(*) FROM pg_attribute a
               WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
                 AND a.attname ~ '.(_id|Id|ID|_uuid)$')) AS detail
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition
  AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
  AND c.relname !~ :'ignore_tables'
  AND NOT EXISTS (SELECT 1 FROM pg_constraint k
                  WHERE k.contype = 'f' AND (k.conrelid = c.oid OR k.confrelid = c.oid))
