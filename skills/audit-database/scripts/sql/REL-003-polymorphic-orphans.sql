-- id: REL-003
-- severity: critical
-- category: relational-integrity
-- title: Orphan rows behind a polymorphic pair (id pointing at no row, or type naming no table)
-- fix: Decide per row (re-attach, quarantine, delete) before VALIDATE-ing the new foreign keys. Sampled counts are a lower bound; a type value that names no table is an unknown mapping until the code (morph map, alias) resolves it
-- data-probe: true
WITH cols AS (
  SELECT n.nspname, c.relname, c.oid AS relid, a.attname, a.attnum
  FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition
    AND a.attnum > 0 AND NOT a.attisdropped
    AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
    AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
    AND c.relname !~ :'ignore_tables'
), pairs AS (
  SELECT i.nspname, i.relname, i.attname AS id_col, t.attname AS type_col
  FROM cols i
  JOIN cols t ON t.relid = i.relid AND t.attnum <> i.attnum
  WHERE i.attname ~ '.(_id|Id|ID|_uuid|_key|_ref|_pk)$'
    AND t.attname ~ '.(_type|Type|_kind|Kind|_class|_model|_table|_entity)$'
    AND lower(regexp_replace(i.attname, '(_id|Id|ID|_uuid|_key|_ref|_pk)$', ''))
        = lower(regexp_replace(t.attname, '(_type|Type|_kind|Kind|_class|_model|_table|_entity)$', ''))
    AND NOT EXISTS (SELECT 1 FROM pg_constraint k
                    WHERE k.conrelid = i.relid AND k.contype = 'f' AND i.attnum = ANY (k.conkey))
), vals AS (
  SELECT p.*, v::text AS val
  FROM pairs p,
  LATERAL unnest(xpath('/table/row/v/text()', query_to_xml(format(
    'SELECT DISTINCT %I::text AS v FROM (SELECT %I FROM %I.%I WHERE %I IS NOT NULL LIMIT %s) s LIMIT 30',
    type_col, type_col, nspname, relname, type_col, :probe_rows), false, false, ''))) AS v
), tabs AS (
  SELECT n.nspname, c.relname,
         regexp_replace(regexp_replace(regexp_replace(lower(c.relname), '[^a-z0-9]', '', 'g'),
                        'ies$', 'y'), '(?<=[^s])s$|(?<=(ss|x|ch|sh))es$', '') AS nrm,
         (SELECT a.attname FROM pg_index pi
          JOIN pg_attribute a ON a.attrelid = pi.indrelid AND a.attnum = pi.indkey[0]
          WHERE pi.indrelid = c.oid AND pi.indisprimary AND pi.indnkeyatts = 1) AS pk
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind IN ('r', 'p') AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
), res AS (
  SELECT v.*, t.nspname AS tns, t.relname AS trel, t.pk
  FROM vals v
  -- same-schema table first; another schema only when the value matches nothing here
  LEFT JOIN LATERAL (
    SELECT t0.nspname, t0.relname, t0.pk FROM tabs t0
    WHERE t0.pk IS NOT NULL
      AND t0.nrm = regexp_replace(regexp_replace(regexp_replace(
                     lower(regexp_replace(v.val, '^.*(\\|::|\.|/)', '')), '[^a-z0-9]', '', 'g'),
                     'ies$', 'y'), '(?<=[^s])s$|(?<=(ss|x|ch|sh))es$', '')
    ORDER BY (t0.nspname = v.nspname) DESC, t0.nspname
    LIMIT 1) t ON true
), probe AS (
  SELECT r.*, CASE WHEN r.trel IS NOT NULL THEN query_to_xml(format(
    'SELECT count(*) AS n, count(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM %I.%I t WHERE t.%I::text = s.v)) AS o '
    'FROM (SELECT %I::text AS v FROM %I.%I WHERE %I = %L AND %I IS NOT NULL LIMIT %s) s',
    r.tns, r.trel, r.pk, r.id_col, r.nspname, r.relname, r.type_col, r.val, r.id_col, :probe_rows),
    false, false, '') END AS x
  FROM res r
)
SELECT format('%I.%I (%I where %I = %L)', nspname, relname, id_col, type_col, val) AS object,
       CASE WHEN trel IS NULL
            THEN 'type value names no table with a single-column primary key: unknown mapping. Resolve it from the code (morph map, alias, composite key) before calling these rows unreachable'
            ELSE format('%s of %s sampled rows are orphans: no row in %I.%I with %I = %I',
                        (xpath('/table/row/o/text()', x))[1]::text, (xpath('/table/row/n/text()', x))[1]::text,
                        tns, trel, pk, id_col) END AS detail
FROM probe
WHERE trel IS NULL OR (xpath('/table/row/o/text()', x))[1]::text::bigint > 0
