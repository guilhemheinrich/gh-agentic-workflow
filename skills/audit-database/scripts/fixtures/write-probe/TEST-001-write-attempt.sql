-- id: TEST-001
-- severity: info
-- category: self-test
-- title: A check that tries to write must be refused by the read-only session
-- fix: none (used only by scripts/test-audit.sh)
-- data-probe: false
SELECT nextval('shop.orders_id_seq')::text AS object,
       'this row must never be produced' AS detail
