-- id: AUD-002
-- severity: medium
-- category: orm-leakage
-- title: updated_at maintained by nobody in the database (no BEFORE UPDATE trigger)
-- fix: Install the trigger from skills/sql-migration-guidelines/templates/updated-at-trigger.sql; today any UPDATE not going through the ORM leaves a stale timestamp
-- data-probe: false
SELECT format('%I.%I.%I', n.nspname, c.relname, a.attname) AS object,
       'no BEFORE UPDATE trigger on the table: the value is correct only for writes made through the ORM' AS detail
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition
  AND a.attnum > 0 AND NOT a.attisdropped
  AND a.attname ~* '^(updated_?(at|on)|modified_?(at|on)|last_?modified(_?at)?|date_?updated)$'
  AND NOT EXISTS (SELECT 1 FROM pg_trigger t
                  WHERE t.tgrelid = c.oid AND NOT t.tgisinternal
                    AND (t.tgtype & 2) <> 0 AND (t.tgtype & 16) <> 0)
  AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
  AND c.relname !~ :'ignore_tables'
