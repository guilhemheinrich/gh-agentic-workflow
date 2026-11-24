-- id: REL-010
-- severity: medium
-- category: relational-integrity
-- title: Foreign key column whose type differs from the referenced key
-- fix: Align the referencing column on the referenced type (integer -> bigint ...). A mismatch forces casts in joins and overflows on the narrower side
-- data-probe: false
SELECT format('%I.%I.%I', n.nspname, c.relname, a.attname) AS object,
       format('%s references %I.%I %s (constraint %I)', format_type(a.atttypid, a.atttypmod),
              fc.relname, fa.attname, format_type(fa.atttypid, fa.atttypmod), k.conname) AS detail
FROM pg_constraint k
JOIN pg_class c ON c.oid = k.conrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_class fc ON fc.oid = k.confrelid
CROSS JOIN LATERAL unnest(k.conkey, k.confkey) AS u(att, fatt)
JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = u.att
JOIN pg_attribute fa ON fa.attrelid = k.confrelid AND fa.attnum = u.fatt
WHERE k.contype = 'f' AND k.conparentid = 0
  AND (a.atttypid <> fa.atttypid OR a.atttypmod <> fa.atttypmod)
  AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
  AND c.relname !~ :'ignore_tables'
