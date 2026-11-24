-- id: OPS-005
-- severity: low
-- category: orm-leakage
-- title: Point lookup executed a very large number of times (N+1 query hint)
-- fix: Find the loop in the ORM code (lazy-loaded association) and replace it with a join or an IN/ANY batch (includes / select_related / with / relations)
-- data-probe: false
-- requires-extension: pg_stat_statements
SELECT left(regexp_replace(s.query, '\s+', ' ', 'g'), 160) AS object,
       format('%s calls, %s rows per call, mean %s ms, total %s s',
              s.calls, round(s.rows::numeric / s.calls, 2), round(s.mean_exec_time::numeric, 3),
              round((s.total_exec_time / 1000)::numeric, 1)) AS detail
FROM pg_stat_statements s
JOIN pg_database d ON d.oid = s.dbid AND d.datname = current_database()
WHERE s.calls >= :n1_min_calls
  AND s.rows::numeric / s.calls <= 1.5
  AND s.query ~* '^\s*select\M'
  AND s.query ~* '\mwhere\M[^;]*=\s*\$\d+'
  AND s.query !~* '\m(join|pg_catalog|information_schema)\M'
ORDER BY s.calls DESC
LIMIT 25
