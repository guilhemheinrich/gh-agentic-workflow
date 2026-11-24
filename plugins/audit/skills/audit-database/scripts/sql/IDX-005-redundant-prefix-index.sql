-- id: IDX-005
-- severity: low
-- category: indexes
-- title: Index made redundant by a wider index starting with the same columns
-- fix: Drop the narrower one unless it is markedly smaller and serves a hot query; (a) is covered by (a, b)
-- data-probe: false
SELECT format('%I.%I', n.nspname, ac.relname) AS object,
       format('columns (%s) are a prefix of index %I on %I',
              (SELECT string_agg(att.attname, ', ' ORDER BY u.ord)
               FROM unnest(a.indkey::int2[]) WITH ORDINALITY AS u(att, ord)
               JOIN pg_attribute att ON att.attrelid = a.indrelid AND att.attnum = u.att),
              bc.relname, c.relname) AS detail
FROM pg_index a
JOIN pg_class ac ON ac.oid = a.indexrelid
JOIN pg_class c ON c.oid = a.indrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_index b ON b.indrelid = a.indrelid AND b.indexrelid <> a.indexrelid
JOIN pg_class bc ON bc.oid = b.indexrelid AND bc.relam = ac.relam
WHERE NOT a.indisunique AND a.indisvalid AND b.indisvalid
  AND a.indpred IS NULL AND b.indpred IS NULL AND a.indexprs IS NULL AND b.indexprs IS NULL
  AND b.indkey::text LIKE a.indkey::text || ' %'
  AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
  AND c.relname !~ :'ignore_tables'
