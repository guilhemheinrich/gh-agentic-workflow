-- Polymorphic relation modelled with a supertype table and real foreign keys.
-- Anti-pattern (never): commentable_type varchar + commentable_id varchar.
CREATE TABLE comment_targets (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  target_kind text NOT NULL CHECK (target_kind IN ('article', 'video')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE articles (
  comment_target_id bigint PRIMARY KEY
    REFERENCES comment_targets(id) ON DELETE CASCADE,
  title text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE videos (
  comment_target_id bigint PRIMARY KEY
    REFERENCES comment_targets(id) ON DELETE CASCADE,
  url text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE comments (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  comment_target_id bigint NOT NULL
    REFERENCES comment_targets(id) ON DELETE CASCADE,
  body text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- PostgreSQL does not index referencing columns automatically.
CREATE INDEX comments_comment_target_id_idx ON comments(comment_target_id);
