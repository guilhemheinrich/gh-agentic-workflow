-- id: SEC-005
-- severity: high
-- category: security
-- title: Weak pg_hba.conf rule (no authentication, clear-text or MD5 password, TLS not required from any address)
-- fix: Use scram-sha-256 over hostssl, restrict address ranges, keep trust/peer for local maintenance sockets only. Needs superuser or a GRANT on pg_hba_file_rules to be audited
-- data-probe: false
SELECT format('pg_hba.conf line %s', h.line_number) AS object,
       format('%s database=%s user=%s address=%s method=%s -> %s', h.type,
              array_to_string(h.database, ','), array_to_string(h.user_name, ','),
              coalesce(h.address, '-'), h.auth_method,
              concat_ws(', ',
                CASE h.auth_method WHEN 'trust' THEN 'no authentication at all'
                                   WHEN 'password' THEN 'password sent in clear text'
                                   WHEN 'md5' THEN 'MD5 challenge (replayable hash)'
                                   WHEN 'ident' THEN 'trusts the client machine' END,
                CASE WHEN h.type IN ('host', 'hostnossl') AND coalesce(h.address, '') NOT IN ('127.0.0.1', '::1', 'localhost', 'samehost')
                     THEN 'TLS not required' END,
                CASE WHEN h.address IN ('all', '0.0.0.0', '::') OR h.netmask IN ('0.0.0.0', '::')
                     THEN 'open to every address' END)) AS detail
FROM pg_hba_file_rules h
WHERE h.error IS NULL
  AND (h.auth_method IN ('trust', 'password', 'md5', 'ident')
       OR (h.type IN ('host', 'hostnossl') AND coalesce(h.address, '') NOT IN ('127.0.0.1', '::1', 'localhost', 'samehost')))
