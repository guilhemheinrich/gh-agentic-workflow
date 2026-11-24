-- id: TEN-005
-- severity: high
-- category: multi-tenancy
-- title: View over a row-level-secured table that runs with its owner's rights (security_invoker off)
-- fix: PostgreSQL 15+: ALTER VIEW ... SET (security_invoker = true). Before 15: own the view with a role that is itself subject to the policies, or filter on the tenant inside the view
-- data-probe: false
SELECT DISTINCT format('%I.%I', vn.nspname, v.relname) AS object,
       format('view owned by %I reads %I.%I, which has row level security, with the owner''s rights: callers are filtered by the policies that apply to %I, not to themselves',
              pg_get_userbyid(v.relowner), tn.nspname, t.relname, pg_get_userbyid(v.relowner)) AS detail
FROM pg_rewrite r
JOIN pg_class v ON v.oid = r.ev_class AND v.relkind = 'v'
JOIN pg_namespace vn ON vn.oid = v.relnamespace
JOIN pg_depend d ON d.classid = 'pg_rewrite'::regclass AND d.objid = r.oid
                AND d.refclassid = 'pg_class'::regclass AND d.refobjid <> v.oid
JOIN pg_class t ON t.oid = d.refobjid AND t.relkind IN ('r', 'p') AND t.relrowsecurity
JOIN pg_namespace tn ON tn.oid = t.relnamespace
WHERE NOT EXISTS (SELECT 1 FROM unnest(coalesce(v.reloptions, '{}'::text[])) AS o
                  WHERE o ~* '^security_invoker=(true|on|yes|1)$')
  AND vn.nspname !~ '^pg_' AND vn.nspname <> 'information_schema'
  AND (:'schemas' = '' OR vn.nspname = ANY (string_to_array(:'schemas', ',')))
