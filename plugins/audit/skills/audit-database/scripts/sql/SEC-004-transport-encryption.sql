-- id: SEC-004
-- severity: high
-- category: security
-- title: Unencrypted client connections or weak password hashing
-- fix: ssl = on with hostssl-only pg_hba rules (SEC-005), sslmode=verify-full on clients, password_encryption = scram-sha-256 then reset the passwords
-- data-probe: false
SELECT 'setting ssl' AS object, 'ssl = off: credentials and data cross the network in clear text' AS detail
WHERE current_setting('ssl') = 'off'
UNION ALL
SELECT 'setting password_encryption', 'password_encryption = md5: new passwords are stored as replayable MD5 hashes'
WHERE current_setting('password_encryption') = 'md5'
UNION ALL
SELECT 'pg_stat_ssl', format('%s of %s remote sessions visible to this role are not encrypted', x.plain, x.total)
FROM (SELECT count(*) FILTER (WHERE NOT s.ssl) AS plain, count(*) AS total
      FROM pg_stat_ssl s JOIN pg_stat_activity a USING (pid)
      WHERE a.client_addr IS NOT NULL AND a.pid <> pg_backend_pid()) x
WHERE x.plain > 0
