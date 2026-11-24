-- id: SEC-008
-- severity: medium
-- category: security
-- title: Column named like a credential stored in a plain text type
-- fix: Verify in code that passwords are hashed (argon2/bcrypt) and tokens/API keys are hashed or encrypted at rest; rename the column to say so (password_hash, token_digest)
-- data-probe: false
SELECT format('%I.%I.%I', n.nspname, c.relname, a.attname) AS object,
       format('%s: the name does not say hash/digest/encrypted; content not read by this audit', format_type(a.atttypid, a.atttypmod)) AS detail
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition
  AND a.attnum > 0 AND NOT a.attisdropped
  AND a.atttypid IN ('text'::regtype, 'varchar'::regtype, 'bpchar'::regtype)
  AND a.attname ~* '(password|passwd|pwd|secret|api_?key|access_?token|refresh_?token|private_?key|credential)'
  AND a.attname !~* '(hash|digest|encrypted|cipher|salt|_at$|expires|reset_sent)'
  AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
  AND c.relname !~ :'ignore_tables'
