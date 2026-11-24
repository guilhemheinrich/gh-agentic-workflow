-- id: IDX-002
-- severity: medium
-- category: indexes
-- title: Duplicate indexes (same table, columns, operator classes, predicate)
-- fix: DROP INDEX CONCURRENTLY the index named as droppable in the detail, after checking nothing depends on it (constraint, replica identity). Never drop a UNIQUE index as the duplicate of a plain one: it is the only thing enforcing uniqueness
-- data-probe: false
WITH idx AS (
  SELECT n.nspname, c.relname, ic.relname AS idxname, i.indexrelid, i.indisunique,
         -- everything that must match for two indexes to be interchangeable for reads
         concat_ws('|', i.indrelid, ic.relam, i.indkey::text, i.indclass::text, i.indcollation::text, i.indoption::text,
                   i.indnkeyatts, coalesce(pg_get_expr(i.indexprs, i.indrelid), ''),
                   coalesce(pg_get_expr(i.indpred, i.indrelid), '')) AS shape,
         -- indnullsnotdistinct exists from PostgreSQL 15: read through jsonb so older servers still parse the query
         coalesce((to_jsonb(i) ->> 'indnullsnotdistinct')::boolean, false) AS nnd
  FROM pg_index i
  JOIN pg_class ic ON ic.oid = i.indexrelid
  JOIN pg_class c ON c.oid = i.indrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
    AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
    AND c.relname !~ :'ignore_tables'
)
-- Same shape AND same uniqueness semantics: truly identical, any one may stay.
SELECT format('%I.%I', nspname, relname) AS object,
       format('%s identical indexes: %s (total %s); keep one, preferably the one backing a constraint',
              count(*), string_agg(idxname, ', ' ORDER BY idxname),
              pg_size_pretty(sum(pg_relation_size(indexrelid)))) AS detail
FROM idx
GROUP BY nspname, relname, shape, indisunique, nnd
HAVING count(*) > 1
UNION ALL
-- A plain index with the shape of a UNIQUE one: only the plain index is redundant.
SELECT format('%I.%I', p.nspname, p.relname),
       format('plain index %s repeats UNIQUE index %s: only %s is droppable; %s enforces uniqueness and must stay',
              p.idxname, u.idxname, p.idxname, u.idxname)
FROM idx p
JOIN idx u ON u.shape = p.shape AND u.indisunique AND NOT p.indisunique
