-- id: REL-011
-- severity: medium
-- category: relational-integrity
-- title: Constraint left NOT VALID (existing rows were never checked)
-- fix: Fix the violating rows, then ALTER TABLE ... VALIDATE CONSTRAINT (takes only a SHARE UPDATE EXCLUSIVE lock)
-- data-probe: false
SELECT format('%I.%I %I', n.nspname, c.relname, k.conname) AS object,
       format('%s', pg_get_constraintdef(k.oid)) AS detail
FROM pg_constraint k
JOIN pg_class c ON c.oid = k.conrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE k.contype IN ('f', 'c') AND NOT k.convalidated
  AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
  AND c.relname !~ :'ignore_tables'
