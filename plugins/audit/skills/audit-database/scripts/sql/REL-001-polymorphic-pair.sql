-- id: REL-001
-- severity: high
-- category: relational-integrity
-- title: Polymorphic association by convention (type + id pair without a foreign key)
-- fix: Replace the pair with real foreign keys (supertype table, exclusive arc or one join table per target). See references/polymorphic-associations.md
-- data-probe: false
WITH cols AS (
  SELECT n.nspname, c.relname, c.oid AS relid, a.attname, a.attnum, a.atttypid,
         format_type(a.atttypid, a.atttypmod) AS typ
  FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition
    AND a.attnum > 0 AND NOT a.attisdropped
    AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
    AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
    AND c.relname !~ :'ignore_tables'
), fk AS (
  SELECT k.conrelid, u.attnum, k.confrelid
  FROM pg_constraint k, LATERAL unnest(k.conkey) AS u(attnum)
  WHERE k.contype = 'f'
)
-- Branch 1: <prefix>_id next to <prefix>_type (Rails, Laravel, TypeORM, hand-rolled).
SELECT format('%I.%I (%I, %I)', i.nspname, i.relname, i.attname, t.attname) AS object,
       format('%s %s has no FOREIGN KEY: the table it points to is chosen per row by %s %s (%s)',
              i.attname, i.typ, t.attname, t.typ,
              CASE WHEN EXISTS (SELECT 1 FROM pg_constraint k
                                WHERE k.conrelid = t.relid AND k.contype = 'c' AND t.attnum = ANY (k.conkey))
                        OR EXISTS (SELECT 1 FROM pg_type y WHERE y.oid = t.atttypid AND y.typtype = 'e')
                   THEN 'discriminator values constrained' ELSE 'discriminator values unconstrained' END) AS detail
FROM cols i
JOIN cols t ON t.relid = i.relid AND t.attnum <> i.attnum
WHERE i.attname ~ '.(_id|Id|ID|_uuid|_key|_ref|_pk)$'
  AND t.attname ~ '.(_type|Type|_kind|Kind|_class|_model|_table|_entity)$'
  AND lower(regexp_replace(i.attname, '(_id|Id|ID|_uuid|_key|_ref|_pk)$', ''))
      = lower(regexp_replace(t.attname, '(_type|Type|_kind|Kind|_class|_model|_table|_entity)$', ''))
  AND NOT EXISTS (SELECT 1 FROM fk WHERE fk.conrelid = i.relid AND fk.attnum = i.attnum)
UNION ALL
-- Branch 2: Django contenttypes (content_type_id is a real FK, object_id is not).
SELECT format('%I.%I (%I, %I)', i.nspname, i.relname, i.attname, t.attname),
       format('%s %s has no FOREIGN KEY: Django GenericForeignKey, target table resolved through %s',
              i.attname, i.typ, (SELECT fc.relname FROM pg_class fc WHERE fc.oid = f.confrelid))
FROM cols i
JOIN cols t ON t.relid = i.relid AND t.attname ~ '^content_?type(_id|Id)?$'
JOIN fk f ON f.conrelid = t.relid AND f.attnum = t.attnum
WHERE i.attname ~ '^object_?(id|Id|pk)$'
  AND NOT EXISTS (SELECT 1 FROM fk WHERE fk.conrelid = i.relid AND fk.attnum = i.attnum)
