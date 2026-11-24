-- id: TYP-001
-- severity: high
-- category: types
-- title: Monetary amount stored as floating point, or in the locale-dependent money type
-- fix: Use numeric(p, s) or integer minor units plus a currency column; migrate with ALTER COLUMN ... TYPE numeric(12,2) USING round(col::numeric, 2)
-- data-probe: false
SELECT format('%I.%I.%I', n.nspname, c.relname, a.attname) AS object,
       CASE WHEN a.atttypid = 'money'::regtype
            THEN 'money: exact (fixed-point), but its scale and text format follow the lc_monetary setting and it stores no currency; a dump restored under another locale changes the amounts'
            ELSE format('%s: binary floating point cannot represent 0.1; sums drift and equality tests fail',
                        format_type(a.atttypid, a.atttypmod)) END AS detail
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition
  AND a.attnum > 0 AND NOT a.attisdropped
  AND (a.atttypid = 'money'::regtype
       OR (a.atttypid IN ('float4'::regtype, 'float8'::regtype)
           AND a.attname ~* '(amount|price|total|cost|balance|fee|tax|vat|salary|discount|montant|prix|revenue|payment|credit|debit|budget)'))
  AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
  AND c.relname !~ :'ignore_tables'
