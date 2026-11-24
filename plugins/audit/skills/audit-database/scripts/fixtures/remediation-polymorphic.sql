-- Executable companion of references/polymorphic-associations.md.
-- Applies the four remediations to the polymorphic table shop.comments
-- (commentable_id, commentable_type) of fixture-schema.sql, in a new schema
-- `fixed`, and asserts that the database now refuses what it used to accept.
-- scripts/test-audit.sh runs it, then checks that REL-001..REL-005 are silent
-- on `fixed`.
--
-- Production notes are in comments: on a live table, build indexes with
-- CREATE INDEX CONCURRENTLY and add constraints NOT VALID, then VALIDATE.

CREATE SCHEMA fixed;

-- Targets. They stand for the existing shop.articles / shop.videos tables.
CREATE TABLE fixed.articles (id bigint PRIMARY KEY, title text NOT NULL);
CREATE TABLE fixed.videos   (id bigint PRIMARY KEY, url   text NOT NULL);
INSERT INTO fixed.articles SELECT id, title FROM shop.articles;
INSERT INTO fixed.videos   SELECT id, url   FROM shop.videos;

-- The type column holds application class names. This mapping is the piece
-- of knowledge that only the ORM had; from now on it is written down.
CREATE TABLE fixed.legacy_type_map (
  legacy_type text PRIMARY KEY,
  target      text NOT NULL CHECK (target IN ('article', 'video'))
);
INSERT INTO fixed.legacy_type_map VALUES
  ('Article', 'article'), ('Video', 'video'), ('App\Models\Video', 'video');

-- =========================================================================
-- Pattern A: one foreign key column per target + exclusive-arc CHECK
-- (migrated in place: this is what you do to the real table)
-- =========================================================================
CREATE TABLE fixed.comments_arc AS SELECT * FROM shop.comments;
ALTER TABLE fixed.comments_arc ADD PRIMARY KEY (id);

-- A1. expand: nullable FK columns; the old pair stays readable meanwhile
ALTER TABLE fixed.comments_arc
  ADD COLUMN article_id bigint,
  ADD COLUMN video_id   bigint;

-- A2. backfill only the rows whose target really exists
UPDATE fixed.comments_arc c SET article_id = c.commentable_id
FROM fixed.legacy_type_map m
WHERE m.legacy_type = c.commentable_type AND m.target = 'article'
  AND EXISTS (SELECT 1 FROM fixed.articles a WHERE a.id = c.commentable_id);
UPDATE fixed.comments_arc c SET video_id = c.commentable_id
FROM fixed.legacy_type_map m
WHERE m.legacy_type = c.commentable_type AND m.target = 'video'
  AND EXISTS (SELECT 1 FROM fixed.videos v WHERE v.id = c.commentable_id);

-- A3. quarantine what could not be attached (never silently delete)
CREATE TABLE fixed.comments_quarantine AS
  SELECT c.id, to_jsonb(c) AS former_row, now() AS quarantined_at
  FROM fixed.comments_arc c WHERE num_nonnulls(c.article_id, c.video_id) = 0;
ALTER TABLE fixed.comments_quarantine ADD PRIMARY KEY (id);
DELETE FROM fixed.comments_arc WHERE num_nonnulls(article_id, video_id) = 0;

-- A4. constrain: NOT VALID first (cheap lock, new rows checked), then VALIDATE
ALTER TABLE fixed.comments_arc
  ADD CONSTRAINT comments_arc_article_id_fkey FOREIGN KEY (article_id)
    REFERENCES fixed.articles (id) ON DELETE CASCADE NOT VALID,
  ADD CONSTRAINT comments_arc_video_id_fkey FOREIGN KEY (video_id)
    REFERENCES fixed.videos (id) ON DELETE CASCADE NOT VALID,
  ADD CONSTRAINT comments_arc_exactly_one_target
    CHECK (num_nonnulls(article_id, video_id) = 1) NOT VALID;
ALTER TABLE fixed.comments_arc VALIDATE CONSTRAINT comments_arc_article_id_fkey;
ALTER TABLE fixed.comments_arc VALIDATE CONSTRAINT comments_arc_video_id_fkey;
ALTER TABLE fixed.comments_arc VALIDATE CONSTRAINT comments_arc_exactly_one_target;
CREATE INDEX comments_arc_article_id_idx ON fixed.comments_arc (article_id);  -- CONCURRENTLY in production
CREATE INDEX comments_arc_video_id_idx   ON fixed.comments_arc (video_id);

-- A5. contract: drop the pair once no reader uses it; a view keeps old
-- readers (reports, exports) working during the transition
ALTER TABLE fixed.comments_arc DROP COLUMN commentable_id, DROP COLUMN commentable_type;
CREATE VIEW fixed.comments_legacy AS
  SELECT id,
         coalesce(article_id, video_id) AS commentable_id,
         CASE WHEN article_id IS NOT NULL THEN 'Article' ELSE 'Video' END AS commentable_type,
         body
  FROM fixed.comments_arc;

-- =========================================================================
-- Pattern B: supertype table (the default of skills/sql-migration-guidelines)
-- =========================================================================
CREATE TABLE fixed.comment_targets (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  target_kind text NOT NULL CHECK (target_kind IN ('article', 'video')),
  UNIQUE (id, target_kind)            -- lets a subtype prove which kind it is
);

-- Additive variant for an existing schema: targets keep their own id and gain
-- a link to their supertype row. target_kind is pinned per table, and the
-- composite FK makes "an article whose parent says video" impossible.
ALTER TABLE fixed.articles
  ADD COLUMN comment_target_id bigint,
  ADD COLUMN target_kind text NOT NULL DEFAULT 'article' CHECK (target_kind = 'article');
ALTER TABLE fixed.videos
  ADD COLUMN comment_target_id bigint,
  ADD COLUMN target_kind text NOT NULL DEFAULT 'video' CHECK (target_kind = 'video');

-- Allocate the parent ids from the parent's own sequence, then create the
-- parent rows with exactly those ids: no temporary mapping column needed.
UPDATE fixed.articles SET comment_target_id = nextval(pg_get_serial_sequence('fixed.comment_targets', 'id'));
UPDATE fixed.videos   SET comment_target_id = nextval(pg_get_serial_sequence('fixed.comment_targets', 'id'));
INSERT INTO fixed.comment_targets (id, target_kind) OVERRIDING SYSTEM VALUE
  SELECT comment_target_id, target_kind FROM fixed.articles
  UNION ALL
  SELECT comment_target_id, target_kind FROM fixed.videos;

ALTER TABLE fixed.articles
  ALTER COLUMN comment_target_id SET NOT NULL,
  ADD CONSTRAINT articles_comment_target_key UNIQUE (comment_target_id),
  ADD CONSTRAINT articles_comment_target_fkey FOREIGN KEY (comment_target_id, target_kind)
    REFERENCES fixed.comment_targets (id, target_kind) ON DELETE CASCADE;
ALTER TABLE fixed.videos
  ALTER COLUMN comment_target_id SET NOT NULL,
  ADD CONSTRAINT videos_comment_target_key UNIQUE (comment_target_id),
  ADD CONSTRAINT videos_comment_target_fkey FOREIGN KEY (comment_target_id, target_kind)
    REFERENCES fixed.comment_targets (id, target_kind) ON DELETE CASCADE;

CREATE TABLE fixed.comments_sup (
  id                bigint PRIMARY KEY,
  comment_target_id bigint NOT NULL REFERENCES fixed.comment_targets (id) ON DELETE CASCADE,
  body              text NOT NULL
);
INSERT INTO fixed.comments_sup (id, comment_target_id, body)
SELECT c.id, coalesce(a.comment_target_id, v.comment_target_id), c.body
FROM shop.comments c
JOIN fixed.legacy_type_map m ON m.legacy_type = c.commentable_type
LEFT JOIN fixed.articles a ON m.target = 'article' AND a.id = c.commentable_id
LEFT JOIN fixed.videos   v ON m.target = 'video'   AND v.id = c.commentable_id
WHERE coalesce(a.comment_target_id, v.comment_target_id) IS NOT NULL;
CREATE INDEX comments_sup_comment_target_id_idx ON fixed.comments_sup (comment_target_id);

-- Lifecycle. The foreign keys only cascade downwards: deleting the parent row
-- removes the subtype row and the comments. Deleting an article directly would
-- leave its parent row and its comments behind, so a trigger removes the parent.
CREATE FUNCTION fixed.delete_comment_target() RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM fixed.comment_targets WHERE id = OLD.comment_target_id;
  RETURN NULL;
END $$;
CREATE TRIGGER articles_delete_comment_target AFTER DELETE ON fixed.articles
  FOR EACH ROW EXECUTE FUNCTION fixed.delete_comment_target();
CREATE TRIGGER videos_delete_comment_target AFTER DELETE ON fixed.videos
  FOR EACH ROW EXECUTE FUNCTION fixed.delete_comment_target();

-- The reverse rule: a parent row with no article and no video is a target that
-- does not exist, yet comments could attach to it. Checked at COMMIT (deferred),
-- so that parent and subtype can be inserted in the same transaction.
CREATE FUNCTION fixed.comment_target_has_subtype() RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM fixed.comment_targets WHERE id = NEW.id)
     AND NOT EXISTS (SELECT 1 FROM fixed.articles WHERE comment_target_id = NEW.id)
     AND NOT EXISTS (SELECT 1 FROM fixed.videos   WHERE comment_target_id = NEW.id) THEN
    RAISE EXCEPTION 'comment_targets % has no article and no video', NEW.id
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER comment_targets_has_subtype AFTER INSERT ON fixed.comment_targets
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fixed.comment_target_has_subtype();

-- Re-pointing a subtype at another parent would strand the old parent without
-- firing any delete trigger: the link is immutable.
CREATE FUNCTION fixed.comment_target_link_is_immutable() RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'comment_target_id cannot be reassigned' USING ERRCODE = 'integrity_constraint_violation';
END $$;
CREATE TRIGGER articles_comment_target_immutable BEFORE UPDATE OF comment_target_id ON fixed.articles
  FOR EACH ROW WHEN (OLD.comment_target_id IS DISTINCT FROM NEW.comment_target_id)
  EXECUTE FUNCTION fixed.comment_target_link_is_immutable();
CREATE TRIGGER videos_comment_target_immutable BEFORE UPDATE OF comment_target_id ON fixed.videos
  FOR EACH ROW WHEN (OLD.comment_target_id IS DISTINCT FROM NEW.comment_target_id)
  EXECUTE FUNCTION fixed.comment_target_link_is_immutable();

-- =========================================================================
-- Pattern C: one join table per target (the child table knows no target)
-- =========================================================================
CREATE TABLE fixed.comments_plain (
  id   bigint PRIMARY KEY,
  body text NOT NULL
);
CREATE TABLE fixed.article_comments (
  comment_id bigint PRIMARY KEY REFERENCES fixed.comments_plain (id) ON DELETE CASCADE,  -- PK: a comment joins at most one article
  article_id bigint NOT NULL REFERENCES fixed.articles (id) ON DELETE CASCADE
);
CREATE TABLE fixed.video_comments (
  comment_id bigint PRIMARY KEY REFERENCES fixed.comments_plain (id) ON DELETE CASCADE,
  video_id   bigint NOT NULL REFERENCES fixed.videos (id) ON DELETE CASCADE
);
CREATE INDEX article_comments_article_id_idx ON fixed.article_comments (article_id);
CREATE INDEX video_comments_video_id_idx ON fixed.video_comments (video_id);

INSERT INTO fixed.comments_plain SELECT id, body FROM fixed.comments_arc;
INSERT INTO fixed.article_comments SELECT id, article_id FROM fixed.comments_arc WHERE article_id IS NOT NULL;
INSERT INTO fixed.video_comments   SELECT id, video_id   FROM fixed.comments_arc WHERE video_id IS NOT NULL;

-- =========================================================================
-- Pattern D: one child table per target (no shared table at all)
-- =========================================================================
CREATE TABLE fixed.article_notes (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  article_id bigint NOT NULL REFERENCES fixed.articles (id) ON DELETE CASCADE,
  body       text NOT NULL
);
CREATE TABLE fixed.video_notes (
  id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  video_id bigint NOT NULL REFERENCES fixed.videos (id) ON DELETE CASCADE,
  body     text NOT NULL
);
CREATE INDEX article_notes_article_id_idx ON fixed.article_notes (article_id);
CREATE INDEX video_notes_video_id_idx ON fixed.video_notes (video_id);
INSERT INTO fixed.article_notes (article_id, body) SELECT article_id, body FROM fixed.comments_arc WHERE article_id IS NOT NULL;
INSERT INTO fixed.video_notes   (video_id, body)   SELECT video_id, body   FROM fixed.comments_arc WHERE video_id IS NOT NULL;
-- "all notes" for reporting is a view, readable by any BI tool
CREATE VIEW fixed.notes AS
  SELECT 'article' AS target, article_id AS target_id, body FROM fixed.article_notes
  UNION ALL
  SELECT 'video', video_id, body FROM fixed.video_notes;

-- The class-name mapping was migration scaffolding: once the pair is gone,
-- nothing in the database speaks the ORM's vocabulary any more.
DROP TABLE fixed.legacy_type_map;

-- =========================================================================
-- Proof: the database now refuses what the polymorphic pair accepted
-- =========================================================================
DO $$
DECLARE
  refused integer := 0;
BEGIN
  -- migration kept the 3 attachable comments and quarantined the 2 others
  IF (SELECT count(*) FROM fixed.comments_arc) <> 3 OR (SELECT count(*) FROM fixed.comments_quarantine) <> 2 THEN
    RAISE EXCEPTION 'pattern A: expected 3 migrated + 2 quarantined comments';
  END IF;
  IF (SELECT count(*) FROM fixed.comments_sup) <> 3 THEN
    RAISE EXCEPTION 'pattern B: expected 3 migrated comments';
  END IF;

  BEGIN  -- A: a comment pointing at a missing article
    INSERT INTO fixed.comments_arc (id, body, article_id) VALUES (9001, 'x', 999);
  EXCEPTION WHEN foreign_key_violation THEN refused := refused + 1; END;
  BEGIN  -- A: a comment with two targets
    INSERT INTO fixed.comments_arc (id, body, article_id, video_id) VALUES (9002, 'x', 1, 1);
  EXCEPTION WHEN check_violation THEN refused := refused + 1; END;
  BEGIN  -- A: a comment with no target
    INSERT INTO fixed.comments_arc (id, body) VALUES (9003, 'x');
  EXCEPTION WHEN check_violation THEN refused := refused + 1; END;
  BEGIN  -- B: a comment on a target that does not exist
    INSERT INTO fixed.comments_sup (id, comment_target_id, body) VALUES (9004, 999, 'x');
  EXCEPTION WHEN foreign_key_violation THEN refused := refused + 1; END;
  BEGIN  -- B: an article claiming a parent row of kind video
    INSERT INTO fixed.articles (id, title, comment_target_id)
    VALUES (9005, 'x', (SELECT comment_target_id FROM fixed.videos LIMIT 1));
  EXCEPTION WHEN foreign_key_violation THEN refused := refused + 1; END;
  BEGIN  -- C: the same comment attached to two articles
    INSERT INTO fixed.article_comments (comment_id, article_id) VALUES (1, 2);
  EXCEPTION WHEN unique_violation THEN refused := refused + 1; END;
  BEGIN  -- D: a note on a missing video
    INSERT INTO fixed.video_notes (video_id, body) VALUES (999, 'x');
  EXCEPTION WHEN foreign_key_violation THEN refused := refused + 1; END;

  BEGIN  -- B: an article with no parent row at all
    INSERT INTO fixed.articles (id, title) VALUES (9006, 'x');
  EXCEPTION WHEN not_null_violation THEN refused := refused + 1; END;

  BEGIN  -- B: a parent row with no subtype (a target that does not exist)
    INSERT INTO fixed.comment_targets (target_kind) VALUES ('article');
    SET CONSTRAINTS ALL IMMEDIATE;   -- run the deferred check now, as COMMIT would
  EXCEPTION WHEN integrity_constraint_violation THEN refused := refused + 1; END;
  SET CONSTRAINTS ALL DEFERRED;
  BEGIN  -- B: an article re-pointed at another parent row
    UPDATE fixed.articles SET comment_target_id = comment_target_id + 1000 WHERE id = 2;
  EXCEPTION WHEN integrity_constraint_violation THEN refused := refused + 1; END;

  IF refused <> 10 THEN
    RAISE EXCEPTION 'expected 10 refused writes, got %', refused;
  END IF;

  -- B, lifecycle: deleting an article directly must take its parent row and
  -- its comments with it (trigger), and must leave the video's untouched.
  DELETE FROM fixed.articles WHERE id = 1;
  IF EXISTS (SELECT 1 FROM fixed.comment_targets WHERE target_kind = 'article'
             AND id NOT IN (SELECT comment_target_id FROM fixed.articles)) THEN
    RAISE EXCEPTION 'pattern B: a parent row survived the deletion of its article';
  END IF;
  IF (SELECT count(*) FROM fixed.comments_sup) <> 2 THEN
    RAISE EXCEPTION 'pattern B: expected 2 comments left after deleting article 1, got %',
      (SELECT count(*) FROM fixed.comments_sup);
  END IF;
END $$;

GRANT USAGE ON SCHEMA fixed TO audit_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA fixed TO audit_reader;
