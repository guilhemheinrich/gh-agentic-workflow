-- id: IDX-001
-- severity: medium
-- category: indexes
-- title: Foreign key without a supporting index on the referencing columns
-- fix: CREATE INDEX CONCURRENTLY ON child (fk_cols). PostgreSQL indexes the referenced side only; without this, parent DELETE/UPDATE scans the child and joins are sequential
-- data-probe: false
SELECT format('%I.%I %I', n.nspname, c.relname, k.conname) AS object,
       format('%s: no valid non-partial index starts with (%s); child table ~%s rows',
              pg_get_constraintdef(k.oid),
              (SELECT string_agg(a.attname, ', ' ORDER BY u.ord)
               FROM unnest(k.conkey) WITH ORDINALITY AS u(att, ord)
               JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = u.att),
              greatest(c.reltuples, 0)::bigint) AS detail
FROM pg_constraint k
JOIN pg_class c ON c.oid = k.conrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE k.contype = 'f' AND k.conparentid = 0
  AND NOT EXISTS (
    SELECT 1 FROM pg_index i
    WHERE i.indrelid = k.conrelid AND i.indisvalid AND i.indpred IS NULL
      AND ((i.indnkeyatts >= cardinality(k.conkey)
            AND (i.indkey::int2[])[0:cardinality(k.conkey) - 1] @> k.conkey::int2[]
            AND k.conkey::int2[] @> (i.indkey::int2[])[0:cardinality(k.conkey) - 1])
           -- a unique index on a subset of the FK columns already yields at most one row
           OR (i.indisunique AND i.indexprs IS NULL
               AND k.conkey::int2[] @> (i.indkey::int2[])[0:i.indnkeyatts - 1])))
  AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
  AND c.relname !~ :'ignore_tables'
