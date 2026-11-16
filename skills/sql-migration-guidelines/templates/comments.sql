-- Describe business meaning, lifecycle, invariants, units, privacy.
-- Do not restate the obvious ("primary key").
COMMENT ON TABLE comments IS
  'User-authored comments attached to one commentable target.';
COMMENT ON COLUMN comments.comment_target_id IS
  'Foreign key to the common comment_targets parent table.';
COMMENT ON COLUMN comments.body IS
  'Raw comment body supplied by the user.';
