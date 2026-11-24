-- id: REL-007
-- severity: high
-- category: relational-integrity
-- title: Table without a PRIMARY KEY
-- fix: Add a primary key (natural or surrogate). Without one, rows cannot be referenced, logical replication cannot UPDATE/DELETE, duplicates are legal
-- data-probe: false
SELECT format('%I.%I', n.nspname, c.relname) AS object,
       format('no primary key (~%s rows)', greatest(c.reltuples, 0)::bigint) AS detail
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition
  AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
  AND c.relname !~ :'ignore_tables'
  AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid AND i.indisprimary)
