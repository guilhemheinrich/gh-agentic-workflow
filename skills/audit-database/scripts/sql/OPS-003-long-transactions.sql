-- id: OPS-003
-- severity: medium
-- category: operations
-- title: Long-running or idle-in-transaction session, or forgotten prepared transaction
-- fix: Set idle_in_transaction_session_timeout; in the application, stop holding a transaction across HTTP calls or user think-time (see skills/philosophy-data-first: no external I/O inside a transaction)
-- data-probe: false
SELECT format('pid %s (%s)', a.pid, coalesce(nullif(a.application_name, ''), 'no application_name')) AS object,
       format('state %s, transaction open for %s, role %I', a.state,
              date_trunc('second', now() - a.xact_start), a.usename) AS detail
FROM pg_stat_activity a
WHERE a.xact_start IS NOT NULL AND a.pid <> pg_backend_pid()
  AND a.backend_type = 'client backend'
  AND a.datname = current_database()
  AND now() - a.xact_start > make_interval(secs => :long_tx_seconds)
UNION ALL
SELECT format('prepared transaction %L', p.gid),
       format('prepared %s ago by %I in database %I and never finished: it keeps its locks and holds back VACUUM until COMMIT PREPARED or ROLLBACK PREPARED',
              date_trunc('second', now() - p.prepared), p.owner, p.database)
FROM pg_prepared_xacts p
WHERE now() - p.prepared > make_interval(secs => :long_tx_seconds)
