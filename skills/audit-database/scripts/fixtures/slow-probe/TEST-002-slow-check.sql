-- id: TEST-002
-- severity: info
-- category: self-test
-- title: A slow check, so the self-test can inspect the audit container's process list while psql runs
-- fix: none (used only by scripts/test-audit.sh)
-- data-probe: false
SELECT pg_sleep(8)::text AS object,
       'slept' AS detail
