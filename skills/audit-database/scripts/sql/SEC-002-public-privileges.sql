-- id: SEC-002
-- severity: high
-- category: security
-- title: Privileges granted to PUBLIC (every present and future role)
-- fix: REVOKE ... FROM PUBLIC and grant to named roles; on PostgreSQL < 15 also REVOKE CREATE ON SCHEMA public FROM PUBLIC
-- data-probe: false
SELECT format('schema %I', n.nspname) AS object,
       'PUBLIC may CREATE objects in this schema (search_path hijacking: any role can shadow a table or function)' AS detail
FROM pg_namespace n
WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
  AND has_schema_privilege('public', n.oid, 'CREATE')
UNION ALL
SELECT format('%I.%I', n.nspname, c.relname),
       format('PUBLIC holds %s', string_agg(x.privilege_type, ', ' ORDER BY x.privilege_type))
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
CROSS JOIN LATERAL aclexplode(c.relacl) x
WHERE c.relkind IN ('r', 'p', 'v', 'm') AND x.grantee = 0
  AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
  AND c.relname !~ :'ignore_tables'
GROUP BY n.nspname, c.relname
