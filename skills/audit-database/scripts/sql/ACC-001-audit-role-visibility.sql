-- id: ACC-001
-- severity: info
-- category: audit-access
-- title: Objects the audit role cannot fully read (results on them are partial, not clean)
-- fix: Not a defect of the database: declare these objects as blind spots, or ask the DBA to run the audit with a role that can read them (SELECT on tables and sequences; BYPASSRLS only with the data owner's approval)
-- data-probe: false
SELECT format('%I.%I', n.nspname, c.relname) AS object,
       CASE WHEN c.relkind = 'S'
            THEN 'sequence not readable by the audit role: OPS-001 cannot see its last_value and stays silent'
            WHEN NOT has_schema_privilege(n.oid, 'USAGE') OR NOT has_table_privilege(c.oid, 'SELECT')
            THEN 'no SELECT privilege: data probes fail on it and pg_stats hides it (CON-001 estimate, CON-003, REL-002, REL-003, REL-005, TYP-004)'
            ELSE 'row level security applies to the audit role: data probes see only the rows its policies allow (possibly none), so orphan counts can be wrong in both directions, and pg_stats hides the table (CON-003)'
       END AS detail
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE ((c.relkind IN ('r', 'p') AND NOT c.relispartition
        AND (NOT has_schema_privilege(n.oid, 'USAGE') OR NOT has_table_privilege(c.oid, 'SELECT') OR row_security_active(c.oid)))
       OR (c.relkind = 'S' AND NOT has_sequence_privilege(c.oid, 'SELECT,USAGE')))
  AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
  AND c.relname !~ :'ignore_tables'
