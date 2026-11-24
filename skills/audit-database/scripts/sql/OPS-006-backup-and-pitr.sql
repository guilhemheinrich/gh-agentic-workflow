-- id: OPS-006
-- severity: high
-- category: operations
-- title: No evidence of WAL archiving / point-in-time recovery from this server
-- fix: Ask for external evidence - backup tool config, date of the last successful RESTORE test. On managed services (RDS, Cloud SQL, Azure) PITR is configured outside these settings: verify in the provider console
-- data-probe: false
WITH s AS (
  SELECT max(setting) FILTER (WHERE name = 'wal_level') AS wal_level,
         max(setting) FILTER (WHERE name = 'archive_mode') AS archive_mode,
         max(setting) FILTER (WHERE name = 'archive_command') AS archive_command,
         max(setting) FILTER (WHERE name = 'archive_library') AS archive_library
  FROM pg_settings
)
SELECT 'setting wal_level' AS object,
       'wal_level = minimal: neither WAL archiving nor replication is possible' AS detail
FROM s WHERE wal_level = 'minimal'
UNION ALL
SELECT 'setting archive_mode', 'archive_mode = off: this server does not archive WAL, so it cannot be restored to a point in time from its own archives'
FROM s WHERE archive_mode = 'off'
UNION ALL
SELECT 'setting archive_command', 'archive_mode is on but no archive_command / archive_library is visible (empty, or hidden from this role)'
FROM s WHERE archive_mode <> 'off' AND coalesce(archive_command, '') IN ('', '(disabled)') AND coalesce(archive_library, '') = ''
UNION ALL
SELECT 'pg_stat_archiver', format('%s failed archive attempts, last failure %s, last success %s', a.failed_count,
                                  a.last_failed_time, coalesce(a.last_archived_time::text, 'never'))
FROM pg_stat_archiver a
WHERE a.failed_count > 0 AND (a.last_archived_time IS NULL OR a.last_failed_time > a.last_archived_time)
UNION ALL
SELECT 'pg_stat_replication', 'archiving is off and no standby or WAL receiver is connected (or this role cannot see them): no second copy of the WAL is visible. A standby is not a backup either way'
FROM s WHERE archive_mode = 'off' AND NOT pg_is_in_recovery() AND NOT EXISTS (SELECT 1 FROM pg_stat_replication)
