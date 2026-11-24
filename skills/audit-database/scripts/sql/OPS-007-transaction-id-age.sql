-- id: OPS-007
-- severity: high
-- category: operations
-- title: Database approaching transaction ID or MultiXact ID wraparound
-- fix: Find what holds the xmin horizon back (long transactions, abandoned replication slots, prepared transactions) and let VACUUM FREEZE complete
-- data-probe: false
SELECT format('database %I', d.datname) AS object,
       format('age(datfrozenxid) = %s (forced shutdown near 2 000 000 000; autovacuum_freeze_max_age = %s)',
              age(d.datfrozenxid), current_setting('autovacuum_freeze_max_age')) AS detail
FROM pg_database d
WHERE d.datallowconn AND age(d.datfrozenxid) >= :xid_age_warn
UNION ALL
SELECT format('database %I', d.datname),
       format('mxid_age(datminmxid) = %s (MultiXact wraparound, same cliff near 2 000 000 000; autovacuum_multixact_freeze_max_age = %s)',
              mxid_age(d.datminmxid), current_setting('autovacuum_multixact_freeze_max_age'))
FROM pg_database d
WHERE d.datallowconn AND mxid_age(d.datminmxid) >= :xid_age_warn
