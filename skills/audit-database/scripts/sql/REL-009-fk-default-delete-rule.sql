-- id: REL-009
-- severity: low
-- category: relational-integrity
-- title: Foreign key with ON DELETE NO ACTION (the default nobody chose)
-- fix: State the lifecycle on purpose (RESTRICT, CASCADE or SET NULL). If the ORM model declares a cascade the database does not, that cascade is ORM-only (ORM-003)
-- data-probe: false
SELECT format('%I.%I %I', n.nspname, c.relname, k.conname) AS object,
       format('%s: ON DELETE NO ACTION', pg_get_constraintdef(k.oid)) AS detail
FROM pg_constraint k
JOIN pg_class c ON c.oid = k.conrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE k.contype = 'f' AND k.confdeltype = 'a' AND k.conparentid = 0
  AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
  AND c.relname !~ :'ignore_tables'
