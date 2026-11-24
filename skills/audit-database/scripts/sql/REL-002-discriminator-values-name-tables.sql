-- id: REL-002
-- severity: high
-- category: relational-integrity
-- title: Text column whose values are table or model names
-- fix: A value naming a table is a foreign key decided at runtime. Model the choice with real foreign keys (references/polymorphic-associations.md)
-- data-probe: true
WITH cand AS (
  SELECT c.oid AS relid, n.nspname, c.relname, a.attname
  FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition
    AND a.attnum > 0 AND NOT a.attisdropped
    AND a.atttypid IN ('text'::regtype, 'varchar'::regtype, 'bpchar'::regtype)
    AND a.attname ~* '(type|kind|class|model|table|entity|resource|subject|target)(_?name)?$'
    AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
    AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
    AND c.relname !~ :'ignore_tables'
    -- a column that is part of a foreign key is already checked by the database
    AND NOT EXISTS (SELECT 1 FROM pg_constraint k
                    WHERE k.conrelid = c.oid AND k.contype = 'f' AND a.attnum = ANY (k.conkey))
), vals AS (
  SELECT cand.*, v::text AS val
  FROM cand,
  LATERAL unnest(xpath('/table/row/v/text()', query_to_xml(format(
    'SELECT DISTINCT %I::text AS v FROM (SELECT %I FROM %I.%I WHERE %I IS NOT NULL LIMIT %s) s LIMIT 30',
    attname, attname, nspname, relname, attname, :probe_rows), false, false, ''))) AS v
), tabs AS (
  SELECT c.oid AS relid, n.nspname, c.relname,
         regexp_replace(regexp_replace(regexp_replace(lower(c.relname), '[^a-z0-9]', '', 'g'),
                        'ies$', 'y'), '(?<=[^s])s$|(?<=(ss|x|ch|sh))es$', '') AS nrm
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind IN ('r', 'p') AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
), m AS (
  SELECT v.*, t.relname AS target,
         -- A supertype table legitimately carries a classifier naming its
         -- subtypes: the named table then has a foreign key back to this one.
         -- A value naming the row's own table (single-table inheritance) is not a reference either.
         (t.relid = v.relid
          OR EXISTS (SELECT 1 FROM pg_constraint k
                     WHERE k.contype = 'f' AND k.conrelid = t.relid AND k.confrelid = v.relid)) AS refs_back
  FROM vals v
  LEFT JOIN LATERAL (
    SELECT t0.relid, t0.relname FROM tabs t0
    WHERE t0.nrm = regexp_replace(regexp_replace(regexp_replace(
                     lower(regexp_replace(v.val, '^.*(\\|::|\.|/)', '')), '[^a-z0-9]', '', 'g'),
                     'ies$', 'y'), '(?<=[^s])s$|(?<=(ss|x|ch|sh))es$', '')
    ORDER BY (t0.relid = v.relid) DESC, (t0.nspname = v.nspname) DESC, t0.nspname
    LIMIT 1) t ON true
)
SELECT format('%I.%I.%I', nspname, relname, attname) AS object,
       format('%s of %s sampled distinct values name a table: %s',
              count(target) FILTER (WHERE NOT refs_back), count(*),
              string_agg(val || ' -> ' || target, ', ' ORDER BY val) FILTER (WHERE target IS NOT NULL AND NOT refs_back)) AS detail
FROM m
GROUP BY nspname, relname, attname
HAVING count(target) FILTER (WHERE NOT refs_back) > 0
