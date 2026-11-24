-- id: REL-005
-- severity: critical
-- category: relational-integrity
-- title: Orphan rows behind an undeclared reference (REL-004 column whose value matches no target row)
-- fix: Repair or delete the orphans, then add the foreign key so the database refuses the next one
-- data-probe: true
WITH tabs AS (
  SELECT n.nspname, c.relname,
         regexp_replace(regexp_replace(regexp_replace(lower(c.relname), '[^a-z0-9]', '', 'g'),
                        'ies$', 'y'), '(?<=[^s])s$|(?<=(ss|x|ch|sh))es$', '') AS nrm,
         (SELECT a.attname FROM pg_index pi
          JOIN pg_attribute a ON a.attrelid = pi.indrelid AND a.attnum = pi.indkey[0]
          WHERE pi.indrelid = c.oid AND pi.indisprimary AND pi.indnkeyatts = 1) AS pk
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind IN ('r', 'p') AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
), cand AS (
  SELECT n.nspname, c.relname, a.attname,
         regexp_replace(regexp_replace(regexp_replace(
           lower(regexp_replace(a.attname, '(_id|Id|ID|_uuid)$', '')), '[^a-z0-9]', '', 'g'),
           'ies$', 'y'), '(?<=[^s])s$|(?<=(ss|x|ch|sh))es$', '') AS nrm
  FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition
    AND a.attnum > 0 AND NOT a.attisdropped
    AND a.attname ~ '.(_id|Id|ID|_uuid)$'
    AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
    AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
    AND c.relname !~ :'ignore_tables'
    AND NOT EXISTS (SELECT 1 FROM pg_constraint k
                    WHERE k.conrelid = c.oid AND k.contype = 'f' AND a.attnum = ANY (k.conkey))
), probe AS (
  SELECT cand.*, t.nspname AS tns, t.relname AS trel, t.pk, query_to_xml(format(
    'SELECT count(*) AS n, count(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM %I.%I t WHERE t.%I::text = s.v)) AS o '
    'FROM (SELECT %I::text AS v FROM %I.%I WHERE %I IS NOT NULL LIMIT %s) s',
    t.nspname, t.relname, t.pk, cand.attname, cand.nspname, cand.relname, cand.attname, :probe_rows),
    false, false, '') AS x
  FROM cand
  JOIN tabs t ON t.nrm = cand.nrm AND t.nspname = cand.nspname AND t.pk IS NOT NULL
)
SELECT format('%I.%I.%I', nspname, relname, attname) AS object,
       format('%s of %s sampled non-null values match no %I.%I.%I',
              (xpath('/table/row/o/text()', x))[1]::text, (xpath('/table/row/n/text()', x))[1]::text,
              tns, trel, pk) AS detail
FROM probe
WHERE (xpath('/table/row/o/text()', x))[1]::text::bigint > 0
