-- id: SEC-009
-- severity: medium
-- category: security
-- title: SECURITY DEFINER function without a pinned search_path
-- fix: ALTER FUNCTION ... SET search_path = <schema>, pg_temp; otherwise a caller can shadow a table or operator and run code as the function owner
-- data-probe: false
SELECT format('%I.%I(%s)', n.nspname, p.proname, pg_get_function_identity_arguments(p.oid)) AS object,
       format('SECURITY DEFINER owned by %I, no search_path in proconfig', pg_get_userbyid(p.proowner)) AS detail
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE p.prosecdef
  AND NOT EXISTS (SELECT 1 FROM unnest(coalesce(p.proconfig, '{}'::text[])) AS cfg WHERE cfg LIKE 'search_path=%')
  AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
  AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
