-- One reusable trigger function per schema.
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Attach it to every table that has updated_at (repeat per table).
CREATE TRIGGER comments_set_updated_at
BEFORE UPDATE ON comments
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();
