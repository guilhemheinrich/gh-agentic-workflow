-- id: CON-004
-- severity: low
-- category: constraints
-- title: Table whose only uniqueness is a generated surrogate key (no natural key)
-- fix: Ask what makes two rows "the same" for the business and declare it UNIQUE; otherwise duplicates are prevented only by application code
-- data-probe: false
SELECT format('%I.%I', n.nspname, c.relname) AS object,
       format('only unique index is the primary key on generated column %I', a.attname) AS detail
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_index p ON p.indrelid = c.oid AND p.indisprimary AND p.indnkeyatts = 1
JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = p.indkey[0]
WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition
  AND (a.attidentity <> '' OR EXISTS (SELECT 1 FROM pg_attrdef d WHERE d.adrelid = c.oid AND d.adnum = a.attnum))
  AND NOT EXISTS (SELECT 1 FROM pg_index u WHERE u.indrelid = c.oid AND u.indisunique AND NOT u.indisprimary)
  -- a subtype sharing its parent's key is unique by construction
  AND NOT EXISTS (SELECT 1 FROM pg_constraint k
                  WHERE k.conrelid = c.oid AND k.contype = 'f' AND k.conkey = ARRAY[a.attnum])
  AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
  AND c.relname !~ :'ignore_tables'
