-- id: OPS-001
-- severity: high
-- category: operations
-- title: Sequence past the alert threshold of its binding limit (sequence max_value or column type)
-- fix: Migrate the column (and every referencing FK column) to bigint and, when the sequence's own max binds, ALTER SEQUENCE ... AS bigint, before exhaustion; at 100 percent every INSERT fails
-- data-probe: false
SELECT format('%I.%I', s.schemaname, s.sequencename) AS object,
       format('last_value %s = %s%% of the %s limit, set by %s%s', s.last_value,
              round(100.0 * s.last_value / x.cap, 1), x.cap,
              CASE WHEN x.cap < x.col_cap THEN format('the sequence itself (AS %s, max_value %s): widening the column alone does not help', s.data_type, s.max_value)
                   ELSE 'the column type' END,
              coalesce(format(' (feeds %I.%I %s)', tc.relname, a.attname, format_type(a.atttypid, a.atttypmod)), '')) AS detail
FROM pg_sequences s
JOIN pg_namespace n ON n.nspname = s.schemaname
JOIN pg_class c ON c.relnamespace = n.oid AND c.relname = s.sequencename AND c.relkind = 'S'
LEFT JOIN pg_depend d ON d.classid = 'pg_class'::regclass AND d.objid = c.oid
                     AND d.refclassid = 'pg_class'::regclass AND d.refobjsubid > 0 AND d.deptype IN ('a', 'i')
LEFT JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
LEFT JOIN pg_class tc ON tc.oid = d.refobjid
-- The binding limit is the lesser of the sequence's own max_value and its column's type range.
CROSS JOIN LATERAL (SELECT CASE a.atttypid WHEN 'int4'::regtype THEN 2147483647
                                           WHEN 'int2'::regtype THEN 32767
                                           ELSE 9223372036854775807 END::numeric AS col_cap) cc
CROSS JOIN LATERAL (SELECT least(s.max_value::numeric, cc.col_cap) AS cap, cc.col_cap) x
WHERE s.last_value IS NOT NULL AND s.increment_by > 0
  AND 100.0 * s.last_value / x.cap >= :seq_pct
  AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
