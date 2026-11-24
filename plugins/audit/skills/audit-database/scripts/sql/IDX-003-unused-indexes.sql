-- id: IDX-003
-- severity: low
-- category: indexes
-- title: Index never scanned since statistics were last reset
-- fix: Confirm on every replica and over a full business cycle (month end), then DROP INDEX CONCURRENTLY. Never drop on idx_scan = 0 alone
-- data-probe: false
SELECT format('%I.%I', s.schemaname, s.indexrelname) AS object,
       format('0 scans since %s; %s; on %I (%s writes since then)',
              coalesce((SELECT d.stats_reset::date::text FROM pg_stat_database d WHERE d.datname = current_database()),
                       'the last statistics reset (date unknown)'),
              pg_size_pretty(pg_relation_size(s.indexrelid)), s.relname,
              coalesce(t.n_tup_ins + t.n_tup_upd + t.n_tup_del, 0)) AS detail
FROM pg_stat_user_indexes s
JOIN pg_index i ON i.indexrelid = s.indexrelid
JOIN pg_class c ON c.oid = s.relid
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_stat_user_tables t ON t.relid = s.relid
WHERE s.idx_scan = 0 AND NOT i.indisunique AND NOT i.indisprimary
  AND NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conindid = i.indexrelid)
  AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
  AND c.relname !~ :'ignore_tables'
