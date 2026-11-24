-- id: TYP-004
-- severity: high
-- category: types
-- title: JSON document carrying keys that look like foreign keys
-- fix: Promote the key to a real column with a FOREIGN KEY (or a child table for arrays); keep in JSON only what no other row depends on
-- data-probe: true
WITH cand AS (
  SELECT n.nspname, c.relname, a.attname
  FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition
    AND a.attnum > 0 AND NOT a.attisdropped
    AND a.atttypid IN ('json'::regtype, 'jsonb'::regtype)
    AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
    AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
    AND c.relname !~ :'ignore_tables'
), probe AS (
  SELECT cand.*, xpath('/table/row/v/text()', query_to_xml(format(
    'SELECT k || '' ('' || count(*) || '')'' AS v '
    'FROM (SELECT %I::jsonb AS j FROM %I.%I WHERE %I IS NOT NULL LIMIT 1000) s, '
    'LATERAL jsonb_object_keys(CASE WHEN jsonb_typeof(s.j) = ''object'' THEN s.j ELSE ''{}''::jsonb END) AS k '
    'WHERE k ~ %L GROUP BY k ORDER BY count(*) DESC LIMIT 10',
    attname, nspname, relname, attname, '.(_id|Id|ID|_ids|Ids|_uuid)$'), false, false, '')) AS ks
  FROM cand
)
SELECT format('%I.%I.%I', nspname, relname, attname) AS object,
       format('top-level keys shaped like references, with occurrences in a 1000-row sample: %s',
              array_to_string(ks::text[], ', ')) AS detail
FROM probe
WHERE cardinality(ks) > 0
