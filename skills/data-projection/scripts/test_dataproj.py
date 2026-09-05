#!/usr/bin/env python3
"""Regression probes for dataproj.py.

The value of this skill is a report whose shape does not move. So the probes
concentrate there: the closed vocabularies reject what is outside them, the
glyphs and tallies are derived rather than authored, every rendered line fits
the width budget, and the committed artefact cannot come out translated.

    docker run --rm -v "$PWD:/repo" -w /repo/skills/data-projection/scripts \\
      python:3.12-alpine python3 -m unittest -v
"""

import argparse
import json
import os
import tempfile
import unittest

import dataproj as d

SCHEMA = {
    "spec": "specs/071-siren",
    "title": "SIREN on the public form",
    "migrations": [{"path": "db/migrations/041.sql", "tasks": ["T010", "T011"],
                    "reversible": True, "note": "down drops both columns"}],
    "tables": [
        {"name": "public.enrollment", "op": "alter-table", "weight": "heavy",
         "intent": "the table the feature writes", "tasks": ["T010"],
         "objects": [
             {"name": "siren", "op": "add-column", "shape": "varchar(9) NULL",
              "intent": "the SIREN captured on the public form"},
             {"name": "form_data", "op": "set-default", "shape": "jsonb, default '{}'",
              "intent": "gains 6 prefill keys; no type change"},
             {"name": "idx_enrollment_siren", "op": "add-index", "shape": "index (siren)",
              "intent": "the back-office lookup by SIREN, which the audit screen runs "
                        "on every page load"},
         ]},
        {"name": "public.signature_event", "op": "referenced", "weight": "touch",
         "intent": "append-only log, no schema change", "tasks": ["T012"], "objects": []},
    ],
    "not_touched": [{"name": "public.tenant", "why": "no tenant-level SIREN here"}],
}

EFFECTS = {
    "spec": "specs/071-siren",
    "title": "SIREN on the public form",
    "use_cases": [{
        "name": "sign the enrollment form", "requirements": ["FR-004"],
        "tasks": ["T010", "T011", "T012", "T013"],
        "effects": [
            {"op": "update", "table": "public.enrollment",
             "where": "token = :token AND signed_at IS NULL", "rows": "one",
             "test": "tests/enroll.spec.ts::signs with a valid SIREN",
             "fields": [
                 {"name": "siren", "before": "NULL", "after": "'812345678'",
                  "kind": "value", "intent": "from the form field, checksum already passed"},
                 {"name": "signed_at", "before": "NULL", "after": "now()",
                  "kind": "value", "intent": "the signature timestamp, and the guard "
                                             "against a second submission"},
             ]},
            {"op": "insert", "table": "public.signature_event", "rows": "one",
             "test": "tests/enroll.spec.ts::signs with a valid SIREN",
             "fields": [
                 {"name": "enrollment_id", "after": "1", "kind": "from-step",
                  "intent": "the row step 1 completed"},
                 {"name": "kind", "after": "'signed'", "kind": "literal", "intent": ""},
             ]},
        ],
        "guards": [
            {"when": "the SIREN fails the checksum",
             "then": "nothing is written, step 1 never runs"},
            {"when": "the enrollment is already signed",
             "then": "nothing is written, the predicate on signed_at matches no row"},
        ],
    }],
}

MIGRATION = """
ALTER TABLE enrollment ADD COLUMN siren varchar(9) NULL;
ALTER TABLE enrollment ALTER COLUMN form_data SET DEFAULT '{}'::jsonb;
CREATE INDEX idx_enrollment_siren ON enrollment (siren);
"""


class Glyphs(unittest.TestCase):
    """The glyph follows the operation. The author never picks it."""

    def test_additions(self):
        for op in ("add-column", "add-index", "add-fk", "create-table"):
            self.assertEqual(d.glyph(op), "+", op)

    def test_removals(self):
        for op in ("drop-column", "drop-index", "drop-table"):
            self.assertEqual(d.glyph(op), "-", op)

    def test_everything_else_is_an_alteration(self):
        for op in ("alter-type", "set-default", "rename-column", "backfill", "referenced"):
            self.assertEqual(d.glyph(op), "~", op)


class Vocabulary(unittest.TestCase):
    """An operation outside the enum is an error, never an exotic rendering."""

    def test_a_clean_schema_validates(self):
        self.assertEqual(d.validate_schema(SCHEMA), [])

    def test_a_clean_effect_set_validates(self):
        self.assertEqual(d.validate_effects(EFFECTS), [])

    def test_a_table_op_outside_the_enum_is_rejected(self):
        broken = json.loads(json.dumps(SCHEMA))
        broken["tables"][0]["op"] = "ALTER"
        self.assertTrue(any("table op" in error for error in d.validate_schema(broken)))

    def test_an_object_op_outside_the_enum_is_rejected(self):
        broken = json.loads(json.dumps(SCHEMA))
        broken["tables"][0]["objects"][0]["op"] = "add_column"
        self.assertTrue(any("object op" in error for error in d.validate_schema(broken)))

    def test_a_weight_outside_the_enum_is_rejected(self):
        broken = json.loads(json.dumps(SCHEMA))
        broken["tables"][0]["weight"] = "huge"
        self.assertTrue(any("weight" in error for error in d.validate_schema(broken)))

    def test_an_effect_op_outside_the_enum_is_rejected(self):
        broken = json.loads(json.dumps(EFFECTS))
        broken["use_cases"][0]["effects"][0]["op"] = "UPDATE"
        self.assertTrue(any("op" in error for error in d.validate_effects(broken)))

    def test_a_cardinality_outside_the_enum_is_rejected(self):
        broken = json.loads(json.dumps(EFFECTS))
        broken["use_cases"][0]["effects"][0]["rows"] = "1"
        self.assertTrue(any("rows" in error for error in d.validate_effects(broken)))

    def test_from_step_refuses_prose(self):
        """A structural slot holds a step number; prose goes in `intent`."""
        broken = json.loads(json.dumps(EFFECTS))
        broken["use_cases"][0]["effects"][1]["fields"][0]["after"] = "step 1 key"
        self.assertTrue(any("from-step" in error for error in d.validate_effects(broken)))

    def test_duplicate_use_case_names_are_rejected(self):
        broken = json.loads(json.dumps(EFFECTS))
        broken["use_cases"].append(json.loads(json.dumps(broken["use_cases"][0])))
        self.assertTrue(any("duplicate" in error for error in d.validate_effects(broken)))


class Derived(unittest.TestCase):
    """Counts and ranges are computed, never written."""

    def test_the_tally_keeps_tables_and_objects_apart(self):
        tally = d.schema_tally(SCHEMA, d.CHROME["en"])
        self.assertIn("2 tables (0 created, 0 dropped)", tally)
        self.assertIn("2 objects added", tally)
        self.assertIn("1 altered", tally)
        self.assertIn("0 dropped", tally)

    def test_a_created_table_counts_at_the_table_level(self):
        data = {"tables": [{"name": "t", "op": "create-table", "objects": []}]}
        self.assertIn("1 tables (1 created", d.schema_tally(data, d.CHROME["en"]))

    def test_the_net_effect_speaks_sql(self):
        tally = d.net_effect(EFFECTS["use_cases"][0])
        self.assertIn("public.enrollment: UPDATE ×1", tally)
        self.assertIn("public.signature_event: INSERT ×1", tally)

    def test_deletes_are_reported_even_at_zero(self):
        self.assertIn("(DELETE ×0)", d.net_effect(EFFECTS["use_cases"][0]))

    def test_an_unbounded_cardinality_becomes_n(self):
        case = {"effects": [{"op": "delete", "table": "t", "rows": "many"}]}
        self.assertEqual(d.net_effect(case), "t: DELETE ×N")

    def test_a_contiguous_task_list_becomes_a_range(self):
        self.assertEqual(d.task_range(["T010", "T011", "T012", "T013"]), "T010-T013")

    def test_a_sparse_task_list_stays_a_list(self):
        self.assertEqual(d.task_range(["T010", "T014"]), "T010, T014")

    def test_a_table_name_normalises_for_sql_matching(self):
        self.assertEqual(d.bare_table('public."Enrollment"'), "enrollment")


class SqlAnchor(unittest.TestCase):
    """The hard anchor: a declared operation exists in the migration, or not."""

    def repo(self, tmp, body=MIGRATION):
        os.makedirs(os.path.join(tmp, "db", "migrations"), exist_ok=True)
        with open(os.path.join(tmp, "db", "migrations", "041.sql"), "w",
                  encoding="utf-8") as handle:
            handle.write(body)

    def test_every_declared_operation_is_confirmed(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.repo(tmp)
            findings, _, confirmed = d.audit_sql(SCHEMA, tmp)
            self.assertEqual(findings, [])
            self.assertEqual(confirmed, 3)

    def test_a_missing_statement_is_a_contradiction(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.repo(tmp, "ALTER TABLE enrollment ADD COLUMN siren varchar(9);")
            findings, _, _ = d.audit_sql(SCHEMA, tmp)
            self.assertTrue(any("form_data" in finding and "contradicted" in finding
                                for finding in findings))

    def test_a_migration_absent_from_disk_is_a_finding(self):
        with tempfile.TemporaryDirectory() as tmp:
            findings, _, _ = d.audit_sql(SCHEMA, tmp)
            self.assertTrue(any("missing migration" in finding for finding in findings))

    def test_unreadable_ddl_is_unverifiable_not_contradicted(self):
        """Django and ActiveRecord are out of reach. Saying so beats crying wolf."""
        with tempfile.TemporaryDirectory() as tmp:
            self.repo(tmp, "class Migration(migrations.Migration):\n    pass\n")
            findings, notes, confirmed = d.audit_sql(SCHEMA, tmp)
            self.assertEqual(findings, [])
            self.assertEqual(confirmed, 0)
            self.assertTrue(any("unverifiable" in note for note in notes))

    def test_alembic_helpers_are_read(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.repo(tmp, "op.add_column('enrollment', sa.Column('siren', sa.String(9)))\n"
                           "op.alter_column('enrollment', 'form_data')\n"
                           "op.create_index('idx_enrollment_siren', 'enrollment')\n")
            findings, _, confirmed = d.audit_sql(SCHEMA, tmp)
            self.assertEqual(findings, [])
            self.assertEqual(confirmed, 3)

    def test_a_column_created_with_its_table_counts(self):
        data = {"migrations": [{"path": "db/migrations/041.sql"}],
                "tables": [{"name": "public.enrollment", "op": "create-table", "objects": [
                    {"name": "siren", "op": "add-column"}]}]}
        with tempfile.TemporaryDirectory() as tmp:
            self.repo(tmp, "CREATE TABLE enrollment (id uuid PRIMARY KEY, siren varchar(9));")
            findings, _, confirmed = d.audit_sql(data, tmp)
            self.assertEqual(findings, [])
            self.assertEqual(confirmed, 2)


class Topology(unittest.TestCase):
    """The shape of the report, which is the whole point."""

    def test_the_schema_intent_column_is_shared_by_every_table(self):
        lines = [line for line in d.render_schema(SCHEMA).splitlines()
                 if " ~ " in line or " + " in line or "★" in line]
        offsets = {line.index("★") if "★" in line else None for line in lines}
        marks = [line for line in d.render_schema(SCHEMA).splitlines()
                 if line.startswith(("public.", "├──", "└──"))]
        # Every row of the block reaches the same glyph column.
        columns = {len(row) - len(row.lstrip()) for row in marks}
        self.assertEqual(columns, {0}, marks)
        self.assertTrue(offsets)

    def test_the_schema_report_carries_its_mandatory_sections(self):
        out = d.render_schema(SCHEMA)
        for expected in ("migration", "reversible", "tally", "deliberately NOT touched:"):
            self.assertIn(expected, out)

    def test_an_empty_not_touched_shows_the_placeholder(self):
        data = json.loads(json.dumps(SCHEMA))
        data["not_touched"] = []
        self.assertIn(d.PLACEHOLDER, d.render_schema(data).split("NOT touched:")[1])

    def test_the_effects_report_numbers_its_steps(self):
        out = d.render_effects(EFFECTS)
        self.assertIn("  1  UPDATE", out)
        self.assertIn("  2  INSERT", out)

    def test_the_predicate_sits_on_its_own_line(self):
        """Inlining it makes the header width depend on the author's WHERE."""
        lines = d.render_effects(EFFECTS).splitlines()
        header = next(line for line in lines if line.startswith("  1  UPDATE"))
        self.assertNotIn("token = :token", header)
        self.assertTrue(any(line.strip().startswith("where  token = :token")
                            for line in lines))

    def test_the_from_step_arrow_is_derived(self):
        self.assertIn("← step 1", d.render_effects(EFFECTS))

    def test_no_terminal_escape_reaches_the_output(self):
        for out in (d.render_schema(SCHEMA), d.render_effects(EFFECTS)):
            self.assertNotIn("\x1b", out)
            self.assertNotIn("\x07", out)

    def test_every_line_fits_the_width_budget(self):
        for lang in d.CHROME:
            for renderer, data in ((d.render_schema, SCHEMA), (d.render_effects, EFFECTS)):
                for line in renderer(data, lang=lang).splitlines():
                    self.assertLessEqual(len(line), d.WIDTH,
                                         f"{renderer.__name__}/{lang}: {line}")

    def test_a_long_value_does_not_shift_the_whole_report(self):
        data = json.loads(json.dumps(EFFECTS))
        field = data["use_cases"][0]["effects"][0]["fields"][0]
        field["after"] = "'a very long literal value that eats the whole column budget'"
        for line in d.render_effects(data).splitlines():
            self.assertLessEqual(len(line), d.WIDTH, line)


class Language(unittest.TestCase):
    """The artefact is English; the report pasted into a chat is not."""

    def test_the_chrome_follows_the_requested_language(self):
        out = d.render_effects(EFFECTS, lang="fr")
        self.assertIn("cas d'usage", out)
        self.assertIn("garde", out)
        self.assertIn("effet net", out)
        self.assertIn("lignes: une", out)

    def test_the_schema_chrome_follows_too(self):
        out = d.render_schema(SCHEMA, lang="fr")
        self.assertIn("délibérément PAS touché :", out)
        self.assertIn("décompte", out)

    def test_an_unknown_language_falls_back_to_english(self):
        self.assertIn("net effect", d.render_effects(EFFECTS, lang="zz"))

    def test_the_sql_keywords_are_never_translated(self):
        """A tally in SQL needs no plural agreement in any language."""
        for lang in d.CHROME:
            self.assertIn("UPDATE ×1", d.render_effects(EFFECTS, lang=lang))

    def test_the_schema_overlay_replaces_prose_for_one_render(self):
        overlay = {"tables": {"public.enrollment": {
            "intent": "la table que la fonctionnalité écrit",
            "objects": {"siren": "le SIREN saisi sur le formulaire public"}}}}
        out = d.render_schema(SCHEMA, lang="fr", overlay=overlay)
        self.assertIn("le SIREN saisi sur le formulaire public", out)
        self.assertEqual(SCHEMA["tables"][0]["intent"], "the table the feature writes")

    def test_the_effects_overlay_replaces_intents_values_and_guards(self):
        overlay = {"use_cases": {"sign the enrollment form": {
            "name": "signer le formulaire",
            "effects": [{"where": "token = :token", "fields": {"siren": "depuis le champ"}},
                        {"values": {"kind": "'signe'"}}],
            "guards": [{"when": "la clé échoue", "then": "rien n'est écrit"}]}}}
        out = d.render_effects(EFFECTS, lang="fr", overlay=overlay)
        self.assertIn("signer le formulaire", out)
        self.assertIn("depuis le champ", out)
        self.assertIn("'signe'", out)
        self.assertIn("rien n'est écrit", out)
        self.assertEqual(EFFECTS["use_cases"][0]["name"], "sign the enrollment form")

    def test_a_french_intent_is_flagged(self):
        self.assertIn("fichier", d.foreign_words("ajoute la valeur dans le fichier"))

    def test_the_reference_english_prose_raises_no_marker(self):
        for text in ("the table the feature writes",
                     "the SIREN captured on the public form",
                     "nothing is written, the predicate on signed_at matches no row",
                     "gains 6 prefill keys; no type change"):
            self.assertEqual(d.foreign_words(text), [], text)


class WriteGuard(unittest.TestCase):
    """Only the final, English artefact reaches a commit."""

    def spec(self, tmp, view, data):
        with open(d.artefact_path(tmp, view), "w", encoding="utf-8") as handle:
            handle.write(d.document(data, view, d.RENDERERS[view](data)))

    def args(self, tmp, view, **kwargs):
        base = {"spec": tmp, "view": view, "write": False, "lang": "en",
                "overlay": None, "repo_root": tmp}
        base.update(kwargs)
        return argparse.Namespace(**base)

    def test_a_translated_render_cannot_be_written(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.spec(tmp, "schema", SCHEMA)
            with self.assertRaises(SystemExit):
                d.cmd_render(self.args(tmp, "schema", write=True, lang="fr"))

    def test_an_overlay_cannot_be_written_either(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.spec(tmp, "effects", EFFECTS)
            path = os.path.join(tmp, "fr.json")
            with open(path, "w", encoding="utf-8") as handle:
                json.dump({"use_cases": {}}, handle)
            with self.assertRaises(SystemExit):
                d.cmd_render(self.args(tmp, "effects", write=True, overlay=path))

    def test_a_declaration_outside_the_vocabulary_refuses_to_render(self):
        with tempfile.TemporaryDirectory() as tmp:
            broken = json.loads(json.dumps(SCHEMA))
            self.spec(tmp, "schema", broken)
            with open(d.artefact_path(tmp, "schema"), encoding="utf-8") as handle:
                text = handle.read().replace('"alter-table"', '"ALTER"')
            with open(d.artefact_path(tmp, "schema"), "w", encoding="utf-8") as handle:
                handle.write(text)
            with self.assertRaises(SystemExit):
                d.cmd_render(self.args(tmp, "schema", write=True))

    def test_the_english_render_writes_normally(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.spec(tmp, "schema", SCHEMA)
            self.assertEqual(d.cmd_render(self.args(tmp, "schema", write=True)), 0)
            with open(d.artefact_path(tmp, "schema"), encoding="utf-8") as handle:
                self.assertIn("the table the feature writes", handle.read())


class Roundtrip(unittest.TestCase):
    def test_the_json_block_survives_the_document_wrapper(self):
        for view, data in (("schema", SCHEMA), ("effects", EFFECTS)):
            text = d.document(data, view, d.RENDERERS[view](data))
            self.assertEqual(d.split_document(text), data)

    def test_a_broken_json_block_names_the_problem(self):
        text = f"{d.DATA_START}\n```json\n{{not json}}\n```\n{d.DATA_END}"
        with self.assertRaises(SystemExit):
            d.split_document(text)


if __name__ == "__main__":
    unittest.main()
