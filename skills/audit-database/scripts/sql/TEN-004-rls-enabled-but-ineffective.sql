-- id: TEN-004
-- severity: high
-- category: multi-tenancy
-- title: Row level security enabled but not protecting (no policy, owner exempt, or a policy that lets every row through)
-- fix: Write the missing tenant policy; drop or narrow the USING (true) policy, or add a RESTRICTIVE tenant policy; FORCE ROW LEVEL SECURITY when the application connects as the table owner. Then prove it with seeded rows of two tenants, as the application role, on a copy
-- data-probe: false
SELECT format('%I.%I', n.nspname, c.relname) AS object,
       concat_ws('; ',
         CASE WHEN NOT EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid = c.oid)
              THEN 'RLS enabled with zero policies: default deny for every role subject to RLS (an availability problem, not a leak); the owner and BYPASSRLS roles still read everything' END,
         CASE WHEN NOT c.relforcerowsecurity
              THEN format('not FORCEd: owner %I is exempt from every policy (a leak only if the application connects as that role)', pg_get_userbyid(c.relowner)) END,
         (SELECT format('permissive policy %s has USING (true) and the table has no RESTRICTIVE policy: every row passes, the other permissive policies are redundant', string_agg(quote_ident(p.polname), ', ' ORDER BY p.polname))
          FROM pg_policy p
          WHERE p.polrelid = c.oid AND p.polpermissive AND pg_get_expr(p.polqual, p.polrelid) = 'true'
            AND NOT EXISTS (SELECT 1 FROM pg_policy r WHERE r.polrelid = c.oid AND NOT r.polpermissive))) AS detail
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p') AND c.relrowsecurity
  AND (NOT c.relforcerowsecurity
       OR NOT EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid = c.oid)
       OR (EXISTS (SELECT 1 FROM pg_policy p
                   WHERE p.polrelid = c.oid AND p.polpermissive AND pg_get_expr(p.polqual, p.polrelid) = 'true')
           -- permissive USING (true) plus a RESTRICTIVE policy is a documented pattern: the restrictive one still filters
           AND NOT EXISTS (SELECT 1 FROM pg_policy r WHERE r.polrelid = c.oid AND NOT r.polpermissive)))
  AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
  AND c.relname !~ :'ignore_tables'
