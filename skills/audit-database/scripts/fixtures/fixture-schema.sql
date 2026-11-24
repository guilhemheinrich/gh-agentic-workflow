-- Fixture for scripts/test-audit.sh. Two schemas:
--   shop  : every defect is DELIBERATE; the comment on each line names the
--           check that must flag it.
--   clean : the same domain modelled correctly; the headline checks must stay
--           silent on it (false-positive guard).
-- No credentials here: the test script generates throwaway passwords at run time.

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS dblink;                       -- SEC-006 (flagged extension)

-- =========================================================================
-- shop: the schema an ORM-first project ends up with
-- =========================================================================
CREATE SCHEMA shop;

CREATE TABLE shop.tenants (
  id   serial PRIMARY KEY,
  name text NOT NULL
);                                                           -- AUD-001, DOC-001, CON-004

CREATE TABLE shop.customers (
  id         serial PRIMARY KEY,
  tenant_id  integer NOT NULL REFERENCES shop.tenants(id),   -- TEN-001 (no RLS), REL-009, IDX-001
  email      text,                                           -- CON-003 (never NULL, yet nullable), SEC-007
  first_name text,                                           -- SEC-007
  phone      text,                                           -- SEC-007
  password   text,                                           -- SEC-008
  role       text,                                           -- CON-001
  created_at timestamp DEFAULT now(),                        -- TYP-002
  updated_at timestamp DEFAULT now()                         -- TYP-002, AUD-002 (no trigger)
);
CREATE UNIQUE INDEX customers_email_key ON shop.customers (email);   -- TEN-003 (ignores tenant_id)
GRANT SELECT ON shop.customers TO PUBLIC;                    -- SEC-002

CREATE TABLE shop.articles (
  id         bigserial PRIMARY KEY,
  title      text NOT NULL,
  created_at timestamp DEFAULT now()                         -- TYP-002, AUD-001 (no updated_at)
);

CREATE TABLE shop.videos (
  id  bigserial PRIMARY KEY,
  url text NOT NULL
);

-- THE headline anti-pattern: which table does commentable_id point to?
CREATE TABLE shop.comments (
  id               bigserial PRIMARY KEY,
  commentable_id   bigint NOT NULL,                          -- REL-001, REL-003
  commentable_type text   NOT NULL,                          -- REL-001, REL-002
  body             text   NOT NULL
);

CREATE TABLE shop.orders (
  id             serial PRIMARY KEY,                         -- OPS-001 (sequence pushed near int4 max below)
  tenant_id      integer NOT NULL REFERENCES shop.tenants(id),
  customer_id    integer NOT NULL REFERENCES shop.customers(id),  -- IDX-001, REL-009, TEN-002
  order_number   text NOT NULL,
  status         text NOT NULL DEFAULT 'draft',              -- CON-001, CON-005
  total_amount   double precision NOT NULL,                  -- TYP-001
  customer_email text,                                       -- DUP-001 (copy of customers.email)
  payload        jsonb,                                      -- TYP-003, TYP-004 (holds product_id)
  meta           json,                                       -- TYP-003
  deleted_at     timestamptz,                                -- soft delete ...
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),         -- AUD-002
  CONSTRAINT orders_order_number_key UNIQUE (order_number)   -- CON-002 (... with a non-partial UNIQUE)
);
-- CON-002, second form: deleted_at is nullable and NULLs are distinct, so this
-- "unique" index accepts two live orders with the same number.
CREATE UNIQUE INDEX orders_number_deleted_key ON shop.orders (order_number, deleted_at);

CREATE TABLE shop.products (
  id     integer PRIMARY KEY,
  sku    text NOT NULL,
  "Name" text NOT NULL                                       -- NAM-001 (needs quoting)
);
CREATE INDEX products_sku_idx   ON shop.products (sku);      -- IDX-002, IDX-003, IDX-005
CREATE INDEX products_sku_idx2  ON shop.products (sku);      -- IDX-002 (duplicate)
CREATE INDEX products_sku_name  ON shop.products (sku, "Name");  -- makes (sku) redundant: IDX-005

CREATE TABLE shop.order_items (                              -- REL-007 (no primary key), REL-008
  order_id   integer NOT NULL,                               -- REL-004, REL-005 (no FK, one orphan)
  product_id integer NOT NULL,                               -- REL-004
  quantity   integer NOT NULL,
  unit_price real    NOT NULL                                -- TYP-001
);

CREATE TABLE shop.carriers (
  id   serial PRIMARY KEY,
  name text NOT NULL
);

CREATE TABLE shop.shipments (
  id            serial PRIMARY KEY,
  order_id      bigint NOT NULL REFERENCES shop.orders(id) ON DELETE CASCADE,  -- REL-010 (bigint -> integer)
  carrier_id    integer,
  legacy_ref_id integer,                                     -- REL-006 (points to nothing identifiable)
  shipping_fee  money                                        -- TYP-001 (locale-dependent money type)
);
CREATE INDEX shipments_order_id_idx ON shop.shipments (order_id);
ALTER TABLE shop.shipments
  ADD CONSTRAINT shipments_carrier_id_fkey FOREIGN KEY (carrier_id)
  REFERENCES shop.carriers(id) ON DELETE SET NULL NOT VALID; -- REL-011

CREATE TABLE shop.invoices (
  id        serial PRIMARY KEY,
  tenant_id integer NOT NULL REFERENCES shop.tenants(id) ON DELETE CASCADE,
  amount    numeric(12, 2) NOT NULL
);
CREATE INDEX invoices_tenant_id_idx ON shop.invoices (tenant_id);
ALTER TABLE shop.invoices ENABLE ROW LEVEL SECURITY;         -- TEN-004 (no policy, not forced)

-- TEN-005: the view runs with its owner's rights, so it reads every invoice
-- whatever policy protects the table.
CREATE VIEW shop.invoice_totals AS
  SELECT tenant_id, sum(amount) AS total FROM shop.invoices GROUP BY tenant_id;
DO $$ BEGIN  -- the safe form exists from PostgreSQL 15: TEN-005 must stay silent on it
  IF current_setting('server_version_num')::int >= 150000 THEN
    EXECUTE 'CREATE VIEW shop.invoice_totals_safe WITH (security_invoker = true) AS
             SELECT tenant_id, sum(amount) AS total FROM shop.invoices GROUP BY tenant_id';
  END IF;
END $$;

CREATE TABLE shop.refunds (
  id        serial PRIMARY KEY,
  tenant_id integer NOT NULL REFERENCES shop.tenants(id) ON DELETE CASCADE,
  amount    numeric(12, 2) NOT NULL
);
CREATE INDEX refunds_tenant_id_idx ON shop.refunds (tenant_id);
ALTER TABLE shop.refunds ENABLE ROW LEVEL SECURITY;
ALTER TABLE shop.refunds FORCE ROW LEVEL SECURITY;
CREATE POLICY refunds_tenant ON shop.refunds
  USING (tenant_id = nullif(current_setting('app.tenant_id', true), '')::integer);
CREATE POLICY refunds_debug ON shop.refunds USING (true);    -- TEN-004 (forced, has policies, yet lets every row through)

CREATE TABLE shop.churn (
  id  integer PRIMARY KEY,
  val text
) WITH (autovacuum_enabled = off);                           -- OPS-002

CREATE FUNCTION shop.customer_count() RETURNS bigint
  LANGUAGE sql SECURITY DEFINER                              -- SEC-009 (no search_path)
  AS 'SELECT count(*) FROM shop.customers';

-- IDX-002 guard: a plain index repeating a standalone UNIQUE index. Only the
-- plain one may be reported as droppable; the unique one enforces uniqueness
-- without any pg_constraint row.
CREATE UNIQUE INDEX products_name_uq ON shop.products ("Name");
CREATE INDEX products_name_ix ON shop.products ("Name");

-- CON-002, third form: a NOT NULL flag inside the unique key. Two live rows
-- are refused, but so is the second deletion of a re-created code.
CREATE TABLE shop.coupons (
  id         serial PRIMARY KEY,
  code       text NOT NULL,
  is_deleted boolean NOT NULL DEFAULT false,
  CONSTRAINT coupons_code_is_deleted_key UNIQUE (code, is_deleted)
);

-- TEN-004 guard: permissive USING (true) plus a RESTRICTIVE tenant policy is a
-- documented pattern (the restrictive policy still filters): must not be flagged.
CREATE TABLE shop.credits (
  id        serial PRIMARY KEY,
  tenant_id integer NOT NULL REFERENCES shop.tenants(id) ON DELETE CASCADE,
  amount    numeric(12, 2) NOT NULL
);
CREATE INDEX credits_tenant_id_idx ON shop.credits (tenant_id);
ALTER TABLE shop.credits ENABLE ROW LEVEL SECURITY;
ALTER TABLE shop.credits FORCE ROW LEVEL SECURITY;
CREATE POLICY credits_all ON shop.credits USING (true);
CREATE POLICY credits_tenant ON shop.credits AS RESTRICTIVE
  USING (tenant_id = nullif(current_setting('app.tenant_id', true), '')::integer);

-- ---- data ---------------------------------------------------------------
INSERT INTO shop.tenants (name) VALUES ('acme'), ('globex');

INSERT INTO shop.customers (tenant_id, email, first_name, phone, password, role)
SELECT 1 + (g % 2), 'user' || g || '@example.test', 'User ' || g, '+3300000' || g, 'not-a-real-secret', 'buyer'
FROM generate_series(1, 300) AS g;

INSERT INTO shop.articles (title) VALUES ('First article'), ('Second article');
INSERT INTO shop.videos (url) VALUES ('https://example.test/v/1');

INSERT INTO shop.comments (commentable_id, commentable_type, body) VALUES
  (1,   'Article',            'points to an existing article'),
  (2,   'Article',            'points to an existing article'),
  (999, 'Article',            'ORPHAN: article 999 does not exist'),
  (1,   'App\Models\Video',   'Laravel-style class name, existing video'),
  (42,  'Ghost',              'type names no table at all');

INSERT INTO shop.orders (tenant_id, customer_id, order_number, total_amount, customer_email, payload, meta)
SELECT 1, g, 'ORD-' || g, 19.99 * g, 'user' || g || '@example.test',
       jsonb_build_object('product_id', g, 'note', 'gift'), '{"source": "web"}'
FROM generate_series(1, 50) AS g;

INSERT INTO shop.products (id, sku, "Name") VALUES (1, 'SKU-1', 'Widget'), (2, 'SKU-2', 'Gadget');

INSERT INTO shop.order_items (order_id, product_id, quantity, unit_price) VALUES
  (1, 1, 2, 9.99),
  (2, 2, 1, 19.99),
  (7777, 1, 1, 9.99);                                        -- orphan: order 7777 does not exist

INSERT INTO shop.churn SELECT g, 'x' FROM generate_series(1, 5000) AS g;
DELETE FROM shop.churn WHERE id > 500;

SELECT setval('shop.orders_id_seq', 1900000000);             -- 88% of the int4 range

-- OPS-008: a replication slot nobody consumes (reserves WAL from now on).
SELECT pg_create_physical_replication_slot('audit_fixture_slot', true);

-- =========================================================================
-- clean: the same needs, with integrity in the database
-- =========================================================================
CREATE SCHEMA clean;

CREATE FUNCTION clean.set_updated_at() RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

-- Supertype / subtype (skills/sql-migration-guidelines/templates/polymorphic-parent-table.sql)
CREATE TABLE clean.comment_targets (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  target_kind text NOT NULL CHECK (target_kind IN ('article', 'video')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE clean.articles (
  comment_target_id bigint PRIMARY KEY REFERENCES clean.comment_targets(id) ON DELETE CASCADE,
  title             text NOT NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE clean.videos (
  comment_target_id bigint PRIMARY KEY REFERENCES clean.comment_targets(id) ON DELETE CASCADE,
  url               text NOT NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE clean.comments (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  comment_target_id bigint NOT NULL REFERENCES clean.comment_targets(id) ON DELETE CASCADE,
  body              text NOT NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX comments_comment_target_id_idx ON clean.comments (comment_target_id);

-- Exclusive arc: one nullable FK per target, exactly one set.
CREATE TABLE clean.attachments (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  article_id bigint REFERENCES clean.articles(comment_target_id) ON DELETE CASCADE,
  video_id   bigint REFERENCES clean.videos(comment_target_id) ON DELETE CASCADE,
  file_path  text NOT NULL,
  price      numeric(12, 2) NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT attachments_exactly_one_target CHECK (num_nonnulls(article_id, video_id) = 1)
);
CREATE INDEX attachments_article_id_idx ON clean.attachments (article_id);
CREATE INDEX attachments_video_id_idx ON clean.attachments (video_id);

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['comment_targets', 'articles', 'videos', 'comments', 'attachments'] LOOP
    EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON clean.%I FOR EACH ROW EXECUTE FUNCTION clean.set_updated_at()',
                   t || '_set_updated_at', t);
  END LOOP;
END $$;

COMMENT ON TABLE clean.comment_targets IS 'Supertype: anything a comment can be attached to. One row per article or video.';
COMMENT ON COLUMN clean.comment_targets.target_kind IS 'Classifier of the subtype row sharing this id: article or video.';
COMMENT ON TABLE clean.articles IS 'Editorial article; subtype of comment_targets (shared primary key).';
COMMENT ON COLUMN clean.articles.comment_target_id IS 'Primary key, and foreign key to the comment_targets parent row.';
COMMENT ON COLUMN clean.articles.title IS 'Headline shown to readers.';
COMMENT ON TABLE clean.videos IS 'Hosted video; subtype of comment_targets (shared primary key).';
COMMENT ON COLUMN clean.videos.comment_target_id IS 'Primary key, and foreign key to the comment_targets parent row.';
COMMENT ON COLUMN clean.videos.url IS 'Public playback URL.';
COMMENT ON TABLE clean.comments IS 'User-authored comment attached to exactly one comment target.';
COMMENT ON COLUMN clean.comments.comment_target_id IS 'The article or video commented on, through the supertype.';
COMMENT ON COLUMN clean.comments.body IS 'Raw comment text supplied by the user.';
COMMENT ON TABLE clean.attachments IS 'File attached to exactly one article or one video (exclusive arc).';
COMMENT ON COLUMN clean.attachments.article_id IS 'Set when the file belongs to an article; mutually exclusive with video_id.';
COMMENT ON COLUMN clean.attachments.video_id IS 'Set when the file belongs to a video; mutually exclusive with article_id.';
COMMENT ON COLUMN clean.attachments.file_path IS 'Object-storage key of the file.';
COMMENT ON COLUMN clean.attachments.price IS 'Download price in EUR, two decimals; 0 when free.';

INSERT INTO clean.comment_targets (target_kind) VALUES ('article'), ('video');
INSERT INTO clean.articles (comment_target_id, title) VALUES (1, 'First article');
INSERT INTO clean.videos (comment_target_id, url) VALUES (2, 'https://example.test/v/1');
INSERT INTO clean.comments (comment_target_id, body) VALUES (1, 'on the article'), (2, 'on the video');
INSERT INTO clean.attachments (article_id, file_path) VALUES (1, 'a/1.pdf');

-- IDX-002: two UNIQUE indexes on the same key that differ only in NULL
-- semantics are not interchangeable (one accepts two NULLs, the other refuses
-- them), so they must never be reported as identical. PostgreSQL 15+ only.
-- Kept at the end of the file so the line numbers quoted elsewhere stay put.
DO $$ BEGIN
  IF current_setting('server_version_num')::int >= 150000 THEN
    EXECUTE 'CREATE TABLE shop.labels (id int PRIMARY KEY, code text)';
    EXECUTE 'COMMENT ON TABLE shop.labels IS ''Product labels.''';
    EXECUTE 'CREATE UNIQUE INDEX labels_code_key ON shop.labels (code)';
    EXECUTE 'CREATE UNIQUE INDEX labels_code_nnd_key ON shop.labels (code) NULLS NOT DISTINCT';
  END IF;
END $$;

-- OPS-001: an integer sequence feeding a bigint column runs out at the
-- sequence's own max_value (2 147 483 647), whatever the column could hold.
CREATE TABLE shop.events (id bigint PRIMARY KEY);
COMMENT ON TABLE shop.events IS 'Application events.';
CREATE SEQUENCE shop.events_id_seq AS integer OWNED BY shop.events.id;
ALTER TABLE shop.events ALTER COLUMN id SET DEFAULT nextval('shop.events_id_seq');
SELECT setval('shop.events_id_seq', 2000000000);               -- 93% of the sequence, 0% of bigint

-- A least-privilege audit role: can read catalogs, statistics and (for the
-- data probes) table rows; can write nothing. Deliberately weaker than the role
-- SKILL.md recommends: no SELECT on sequences and no BYPASSRLS, so that ACC-001
-- must report shop.orders_id_seq and the RLS-protected shop.invoices as partial.
CREATE ROLE audit_reader LOGIN;
GRANT pg_monitor TO audit_reader;
GRANT USAGE ON SCHEMA shop, clean TO audit_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA shop, clean TO audit_reader;

ANALYZE;
