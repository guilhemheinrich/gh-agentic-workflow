-- id: OPS-002
-- severity: medium
-- category: operations
-- title: Table bloat indicators (high dead-tuple ratio, or autovacuum disabled)
-- fix: Find what blocks vacuum (OPS-003 long transactions, replication slots), tune per-table autovacuum thresholds; re-enable autovacuum. Estimate only - confirm with pgstattuple before any rewrite
-- data-probe: false
SELECT format('%I.%I', n.nspname, c.relname) AS object,
       concat_ws('; ',
         CASE WHEN s.n_dead_tup >= :dead_min AND s.n_dead_tup >= 0.2 * (s.n_live_tup + s.n_dead_tup)
              THEN format('%s dead / %s live tuples (%s%% dead), last autovacuum %s', s.n_dead_tup, s.n_live_tup,
                          round(100.0 * s.n_dead_tup / greatest(s.n_live_tup + s.n_dead_tup, 1)),
                          coalesce(s.last_autovacuum::date::text, 'never')) END,
         CASE WHEN c.reloptions::text ~ 'autovacuum_enabled=(off|false)'
              THEN 'autovacuum disabled on this table (reloptions)' END) AS detail
FROM pg_stat_user_tables s
JOIN pg_class c ON c.oid = s.relid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE ((s.n_dead_tup >= :dead_min AND s.n_dead_tup >= 0.2 * (s.n_live_tup + s.n_dead_tup))
       OR c.reloptions::text ~ 'autovacuum_enabled=(off|false)')
  AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
  AND c.relname !~ :'ignore_tables'
