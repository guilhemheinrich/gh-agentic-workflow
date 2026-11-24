-- id: OPS-008
-- severity: high
-- category: operations
-- title: Replication slot inactive or losing its WAL
-- fix: If the consumer is gone, the DBA drops the slot (pg_drop_replication_slot); otherwise repair the consumer. Set max_slot_wal_keep_size so that an abandoned slot cannot fill the disk
-- data-probe: false
SELECT format('replication slot %I', s.slot_name) AS object,
       format('%s slot, active = %s, wal_status = %s, retains %s of WAL: a slot nobody reads keeps WAL until the disk is full and holds back VACUUM',
              s.slot_type, s.active, coalesce(s.wal_status, 'unknown'),
              coalesce(pg_size_pretty(pg_wal_lsn_diff(
                CASE WHEN pg_is_in_recovery() THEN pg_last_wal_replay_lsn() ELSE pg_current_wal_lsn() END,
                s.restart_lsn)), 'an unknown amount')) AS detail
FROM pg_replication_slots s
WHERE NOT s.temporary
  AND (NOT s.active OR s.wal_status IN ('unreserved', 'lost'))
