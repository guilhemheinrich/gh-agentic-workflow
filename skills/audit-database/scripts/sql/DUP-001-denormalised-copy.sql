-- id: DUP-001
-- severity: low
-- category: orm-leakage
-- title: Column duplicating a column of the row it references (denormalised copy with no visible sync)
-- fix: Decide - snapshot at a point in time (rename it, e.g. billing_email_at_order, and COMMENT it) or live copy (drop it and join, or sync it with a trigger)
-- data-probe: false
SELECT format('%I.%I.%I', n.nspname, c.relname, ca.attname) AS object,
       format('same type as %I.%I reached through %I; no trigger on %I keeps them equal',
              pc.relname, pa.attname, k.conname, c.relname) AS detail
FROM pg_constraint k
JOIN pg_class c ON c.oid = k.conrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_class pc ON pc.oid = k.confrelid
JOIN pg_attribute fa ON fa.attrelid = k.conrelid AND fa.attnum = k.conkey[1]
JOIN pg_attribute ca ON ca.attrelid = k.conrelid AND ca.attnum > 0 AND NOT ca.attisdropped
                    AND NOT ca.attnum = ANY (k.conkey)
JOIN pg_attribute pa ON pa.attrelid = k.confrelid AND pa.attnum > 0 AND NOT pa.attisdropped
                    AND pa.atttypid = ca.atttypid AND NOT pa.attnum = ANY (k.confkey)
WHERE k.contype = 'f' AND cardinality(k.conkey) = 1
  AND ca.attname IN (regexp_replace(fa.attname, '(_id|Id|ID)$', '') || '_' || pa.attname,
                     regexp_replace(pc.relname, 's$', '') || '_' || pa.attname)
  AND NOT EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgrelid = c.oid AND NOT t.tgisinternal)
  AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
  AND c.relname !~ :'ignore_tables'
