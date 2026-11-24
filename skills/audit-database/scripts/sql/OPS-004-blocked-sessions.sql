-- id: OPS-004
-- severity: medium
-- category: operations
-- title: Session blocked by another session's lock at audit time
-- fix: A snapshot, not a trend - if it reproduces, look for DDL without lock_timeout (MIG-001) or transactions holding row locks across slow work
-- data-probe: false
SELECT format('pid %s (%s)', a.pid, coalesce(nullif(a.application_name, ''), 'no application_name')) AS object,
       format('waiting on %s for %s, blocked by pid(s) %s', coalesce(a.wait_event_type || ':' || a.wait_event, 'a lock'),
              date_trunc('second', now() - a.state_change), array_to_string(pg_blocking_pids(a.pid), ', ')) AS detail
FROM pg_stat_activity a
WHERE cardinality(pg_blocking_pids(a.pid)) > 0 AND a.datname = current_database()
