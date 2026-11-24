-- id: CON-005
-- severity: low
-- category: constraints
-- title: Status column with no state-machine guard in the database
-- fix: Guard transitions where it matters (BEFORE UPDATE trigger, or a transitions table referenced by FK); at minimum CHECK cross-column invariants such as (status = 'paid') = (paid_at IS NOT NULL)
-- data-probe: false
SELECT format('%I.%I.%I', n.nspname, c.relname, a.attname) AS object,
       format('%s; no UPDATE trigger on the table and no CHECK tying %I to another column: any transition is accepted',
              format_type(a.atttypid, a.atttypmod), a.attname) AS detail
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition
  AND a.attnum > 0 AND NOT a.attisdropped
  AND a.attname ~* '^(.*_)?(status|state|stage|phase)$'
  AND NOT EXISTS (SELECT 1 FROM pg_trigger t
                  WHERE t.tgrelid = c.oid AND NOT t.tgisinternal AND (t.tgtype & 16) <> 0)
  AND NOT EXISTS (SELECT 1 FROM pg_constraint k
                  WHERE k.conrelid = c.oid AND k.contype = 'c'
                    AND a.attnum = ANY (k.conkey) AND cardinality(k.conkey) > 1)
  AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
  AND c.relname !~ :'ignore_tables'
