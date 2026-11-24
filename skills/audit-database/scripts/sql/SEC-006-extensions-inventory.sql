-- id: SEC-006
-- severity: info
-- category: security
-- title: Installed extensions (inventory, with the ones that reach outside the database flagged)
-- fix: Remove what is unused; for flagged extensions verify who may call them (dblink/postgres_fdw can exfiltrate, untrusted languages run OS code)
-- data-probe: false
SELECT format('extension %I', e.extname) AS object,
       format('version %s in schema %I%s', e.extversion, n.nspname,
              CASE WHEN e.extname IN ('dblink', 'postgres_fdw', 'file_fdw', 'plpython3u', 'plpythonu', 'plperlu', 'pltclu',
                                      'adminpack', 'pg_execute', 'http', 'pgsql-http', 'aws_lambda', 'aws_s3')
                   THEN ' -- REVIEW: reaches the network, the filesystem or the OS' ELSE '' END) AS detail
FROM pg_extension e
JOIN pg_namespace n ON n.oid = e.extnamespace
WHERE e.extname <> 'plpgsql'
