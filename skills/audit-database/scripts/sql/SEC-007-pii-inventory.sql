-- id: SEC-007
-- severity: info
-- category: security
-- title: Columns likely to hold personal data (inventory by name - the starting point of a GDPR register)
-- fix: For each - confirm, COMMENT the column as personal data, check retention/erasure, restrict SELECT by column grants or views for BI roles
-- data-probe: false
SELECT format('%I.%I.%I', n.nspname, c.relname, a.attname) AS object,
       format('%s; class: %s', format_type(a.atttypid, a.atttypmod),
              CASE WHEN a.attname ~* '(e_?mail|phone|mobile|telephone|fax)' THEN 'contact'
                   WHEN a.attname ~* '(first_?name|last_?name|full_?name|surname|nom|prenom|maiden)' THEN 'identity'
                   WHEN a.attname ~* '(birth|dob|naissance|gender|sex|nationality)' THEN 'identity (sensitive)'
                   WHEN a.attname ~* '(ssn|social_?security|national_?id|passport|nir|tax_?id|siren|siret|driver)' THEN 'government identifier'
                   WHEN a.attname ~* '(iban|bic|card_?number|pan|cvv|account_?number)' THEN 'financial'
                   WHEN a.attname ~* '(address|street|zip|postal|city|latitude|longitude|geo)' THEN 'location'
                   WHEN a.attname ~* '(ip_?addr|user_?agent|device_?id)' THEN 'online identifier'
                   ELSE 'health / other special category' END) AS detail
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition
  AND a.attnum > 0 AND NOT a.attisdropped
  AND a.attname ~* '(e_?mail|phone|mobile|telephone|fax|first_?name|last_?name|full_?name|surname|prenom|maiden|birth|dob|naissance|gender|nationality|ssn|social_?security|national_?id|passport|tax_?id|siret|iban|card_?number|cvv|account_?number|address|street|zip_?code|postal|latitude|longitude|ip_?addr|user_?agent|device_?id|diagnos|medical|health|religion|ethnic)'
  AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
  AND c.relname !~ :'ignore_tables'
