-- id: CON-002
-- severity: high
-- category: constraints
-- title: Soft-deleted table whose UNIQUE index counts deleted rows, or stops protecting live ones
-- fix: Replace it with a partial unique index: CREATE UNIQUE INDEX CONCURRENTLY ... ON t (col) WHERE deleted_at IS NULL
-- data-probe: false
SELECT format('%I.%I %I', n.nspname, c.relname, ic.relname) AS object,
       CASE WHEN sd.attnum = ANY (i.indkey::int2[]) AND sd.is_flag
            THEN format('%s contains the flag %I: at most one deleted row per key can exist, so deleting a re-created row fails with a unique violation',
                        pg_get_indexdef(i.indexrelid), sd.attname)
            WHEN sd.attnum = ANY (i.indkey::int2[])
            THEN format('%s contains nullable %I: NULLs are distinct in a unique index, so two live rows with the same key are both accepted',
                        pg_get_indexdef(i.indexrelid), sd.attname)
            ELSE format('%s is not partial although the table is soft-deleted through %I: a deleted row blocks re-creation, or the application "fixes" it by mangling the value',
                        pg_get_indexdef(i.indexrelid), sd.attname) END AS detail
FROM pg_index i
JOIN pg_class ic ON ic.oid = i.indexrelid
JOIN pg_class c ON c.oid = i.indrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN LATERAL (SELECT a.attname, a.attnum, a.attnotnull, a.atttypid = 'bool'::regtype AS is_flag FROM pg_attribute a
              WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
                AND a.attname ~* '^(deleted_?at|deleted_?on|is_?deleted|deleted|archived_?at|removed_?at|discarded_?at)$'
              LIMIT 1) sd ON true
WHERE i.indisunique AND NOT i.indisprimary AND i.indpred IS NULL
  AND (NOT sd.attnum = ANY (i.indkey::int2[])
       -- indnullsnotdistinct exists from PostgreSQL 15: read it through jsonb so that older servers still parse the query
       OR (NOT sd.attnotnull AND NOT coalesce((to_jsonb(i) ->> 'indnullsnotdistinct')::boolean, false))
       OR sd.is_flag)
  AND n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND (:'schemas' = '' OR n.nspname = ANY (string_to_array(:'schemas', ',')))
  AND c.relname !~ :'ignore_tables'
