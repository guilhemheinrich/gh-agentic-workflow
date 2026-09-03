#!/usr/bin/env python3
"""Regression probes for projection.py.

Covers the parts that are easy to get wrong and impossible to eyeball: the path
filter, the single-child chain collapse, brace expansion, the guide bars
carried by a wrapped intent's continuation lines, and the two language rules —
the committed artefact is English, the rendered tree is not.

    docker run --rm -v "$PWD:/repo" -w /repo/skills/change-projection/scripts \\
      python:3.12-alpine python3 -m unittest -v
"""

import argparse
import json
import os
import tempfile
import unittest

import projection as p


class PathFilter(unittest.TestCase):
    def test_accepts_a_repository_path(self):
        self.assertTrue(p.looks_like_path("apps/web/page.tsx", "."))

    def test_accepts_a_directory(self):
        self.assertTrue(p.looks_like_path("skills/grievances/scripts/", "."))

    def test_rejects_a_token_without_a_slash(self):
        self.assertFalse(p.looks_like_path("python:3.12-alpine", "."))

    def test_rejects_a_command_fragment(self):
        self.assertFalse(p.looks_like_path("$PWD:/repo", "."))
        self.assertFalse(p.looks_like_path("-v", "."))

    def test_rejects_a_url(self):
        self.assertFalse(p.looks_like_path("https://example.org/a.md", "."))

    def test_rejects_a_slashed_token_with_no_extension(self):
        """`GRV-0001/2` and prose fragments must not become files."""
        self.assertFalse(p.looks_like_path("and/or", "."))

    def test_normalises_leading_markers(self):
        self.assertEqual(p.normalise("`./a/b.ts`".strip("`")), "a/b.ts")
        self.assertEqual(p.normalise("/specs/071/plan.md"), "specs/071/plan.md")


class TaskExtraction(unittest.TestCase):
    TASKS = "\n".join(
        [
            "- [ ] T004 Read prefill values in `apps/web/page.tsx`",
            "- [ ] T005 Also `apps/web/page.tsx`, plus `docker run --rm x`",
            "A prose line naming apps/web/invisible.tsx without backticks",
        ]
    )

    def test_maps_a_path_to_every_task_naming_it(self):
        found = p.paths_from_tasks(self.TASKS, ".")
        self.assertEqual(found["apps/web/page.tsx"], ["T004", "T005"])

    def test_ignores_a_path_outside_a_code_span(self):
        self.assertNotIn("apps/web/invisible.tsx", p.paths_from_tasks(self.TASKS, "."))


class PlanTree(unittest.TestCase):
    PLAN = "\n".join(
        [
            "## Project Structure",
            "```",
            "apps/web/",
            "├── app/",
            "│   └── page.tsx          # NEW",
            "└── src/lib/",
            "    └── helper.ts",
            "```",
        ]
    )

    def test_reconstructs_full_paths_from_the_ascii_tree(self):
        paths, parsed = p.paths_from_plan(self.PLAN, ".")
        self.assertTrue(parsed)
        self.assertIn("apps/web/app/page.tsx", paths)
        self.assertIn("apps/web/src/lib/helper.ts", paths)

    def test_reports_when_no_tree_was_parsed(self):
        _, parsed = p.paths_from_plan("no fence here", ".")
        self.assertFalse(parsed)


class Braces(unittest.TestCase):
    def test_expands_one_group(self):
        self.assertEqual(
            p.expand_braces("i18n/{fr,en}/common.json"),
            ["i18n/fr/common.json", "i18n/en/common.json"],
        )

    def test_leaves_a_plain_path_alone(self):
        self.assertEqual(p.expand_braces("a/b.ts"), ["a/b.ts"])


class Classification(unittest.TestCase):
    def test_spec_artefacts_are_bookkeeping(self):
        self.assertEqual(p.classify_role("specs/071-x/PROGRESS.md"), "bookkeeping")

    def test_lockfiles_are_bookkeeping(self):
        self.assertEqual(p.classify_role("package-lock.json"), "bookkeeping")

    def test_a_spec_file_is_a_test(self):
        self.assertEqual(p.classify_role("apps/web/tests/e2e/a.spec.ts"), "test")

    def test_a_python_probe_is_a_test(self):
        self.assertEqual(p.classify_role("scripts/test_thing.py"), "test")

    def test_anything_else_is_logic(self):
        self.assertEqual(p.classify_role("apps/web/actions.ts"), "logic")

    def test_weight_follows_the_task_count(self):
        self.assertEqual(p.suggest_weight(4), "heavy")
        self.assertEqual(p.suggest_weight(2), "added")
        self.assertEqual(p.suggest_weight(1), "touch")


class Rendering(unittest.TestCase):
    def entry(self, path, **kwargs):
        base = {"path": path, "role": "logic", "weight": "touch", "intent": "x"}
        base.update(kwargs)
        return base

    def test_collapses_a_single_child_chain_completely(self):
        """The regression that mattered: the chain must fold to its full name.

        Collapsing is post-order, so the parent has to read the child's `name`
        — already folded — and never the dict key, which is still one segment.
        """
        data = {
            "files": [
                self.entry("app/(public)/enroll/[token]/page.tsx"),
                self.entry("app/(public)/enroll/[token]/actions.ts"),
            ]
        }
        out = p.render(data)
        self.assertIn("app/(public)/enroll/[token]/", out)
        self.assertNotIn("└── enroll/", out)

    def test_a_projected_directory_keeps_its_children(self):
        """A task may edit a directory. That line is annotated *and* a parent."""
        data = {
            "files": [
                self.entry("skills/g/scripts/", intent="the whole folder"),
                self.entry("skills/g/scripts/main.py", intent="the engine"),
            ]
        }
        out = p.render(data)
        self.assertIn("the whole folder", out)
        self.assertIn("main.py", out)
        self.assertIn("the engine", out)

    def test_continuation_lines_carry_the_open_guide_bars(self):
        data = {
            "files": [
                self.entry("a/one.ts", intent="w " * 40),
                self.entry("a/two.ts", intent="short"),
            ]
        }
        lines = p.render(data).splitlines()
        # `lstrip()` is useless here: the first character is a box-drawing bar,
        # not whitespace. Strip the guide itself.
        wrapped = [line for line in lines if line.strip("│ ").startswith("w w")]
        self.assertTrue(wrapped, "the long intent never wrapped")
        self.assertTrue(
            all(line.startswith("│") for line in wrapped),
            f"a continuation line lost its guide bar: {wrapped}",
        )

    def test_bookkeeping_is_listed_apart_from_the_tree(self):
        data = {
            "files": [
                self.entry("a/one.ts"),
                self.entry("specs/071/PROGRESS.md", role="bookkeeping", intent="log"),
            ]
        }
        out = p.render(data)
        self.assertIn("bookkeeping — not part of the change:", out)
        self.assertNotIn("├── PROGRESS.md", out)

    def test_bookkeeping_does_not_shift_the_common_prefix(self):
        data = {
            "files": [
                self.entry("apps/web/one.ts"),
                self.entry("specs/071/PROGRESS.md", role="bookkeeping"),
            ]
        }
        self.assertTrue(p.render(data).startswith("apps/web/"))

    def test_a_missing_not_touched_section_is_visible(self):
        out = p.render({"files": [self.entry("a/one.ts")]})
        self.assertIn("deliberately NOT touched:", out)
        self.assertIn(p.PLACEHOLDER, out)

    def test_a_new_file_is_marked(self):
        out = p.render({"files": [self.entry("a/one.ts", new=True, intent="the probe")]})
        self.assertIn("NEW — the probe", out)

    def test_no_terminal_escape_reaches_the_output(self):
        out = p.render({"files": [self.entry("a/one.ts", weight="heavy")]})
        self.assertNotIn("\x1b", out)
        self.assertNotIn("\x07", out)


class Language(unittest.TestCase):
    """The committed artefact is English; the chat tree is not."""

    ENGLISH = [
        "6 prefill values read from form_data, falling back to the scalar columns.",
        "the heavy one. SIREN field + email field, 6 prefilled inputs, arrival lookup.",
        "the second heavy one. New refusals, writes contactEmail + siren + form_data merge.",
        "7 keys. Not optional — the locale coverage check fails both ways.",
        "two lines, only buys the fallback for a path outside this feature.",
        "the journey: prefilled form, SIREN refused, SIREN accepted.",
        "no back-office screen reads or writes siren in this change",
    ]

    def test_real_english_intents_raise_no_marker(self):
        for intent in self.ENGLISH:
            self.assertEqual(p.foreign_words(intent), [], intent)

    def test_a_french_intent_is_flagged(self):
        self.assertIn("fichier", p.foreign_words("ajoute les valeurs dans le fichier"))

    def test_an_accent_alone_is_enough(self):
        self.assertTrue(p.foreign_words("prérempli"))

    def test_the_chrome_follows_the_requested_language(self):
        data = {"files": [{"path": "a/one.ts", "intent": "x", "new": True}]}
        out = p.render(data, lang="fr")
        self.assertIn("délibérément PAS touché :", out)
        self.assertIn("NOUVEAU", out)

    def test_an_unknown_language_falls_back_to_english(self):
        out = p.render({"files": [{"path": "a/one.ts", "intent": "x"}]}, lang="zz")
        self.assertIn("deliberately NOT touched:", out)

    def test_the_overlay_replaces_the_intent_for_one_render_only(self):
        data = {"files": [{"path": "a/one.ts", "intent": "the engine"}]}
        overlay = {"files": {"a/one.ts": "le moteur"}}
        self.assertIn("le moteur", p.render(data, lang="fr", overlay=overlay))
        self.assertEqual(data["files"][0]["intent"], "the engine")

    def test_the_overlay_drops_the_english_size_hint(self):
        """Otherwise "~15 lines." lands under the translated "~15 lignes."."""
        data = {"files": [{"path": "a/one.ts", "intent": "reads it", "size_hint": "~15 lines."}]}
        out = p.render(data, lang="fr", overlay={"files": {"a/one.ts": "le lit. ~15 lignes."}})
        self.assertIn("~15 lignes.", out)
        self.assertNotIn("~15 lines.", out)

    def test_the_overlay_translates_a_not_touched_reason(self):
        data = {
            "files": [{"path": "a/one.ts", "intent": "x"}],
            "not_touched": [{"path": "b/", "why": "no screen reads it"}],
        }
        overlay = {"not_touched": {"b/": "aucun écran ne le lit"}}
        self.assertIn("aucun écran ne le lit", p.render(data, lang="fr", overlay=overlay))


class Roundtrip(unittest.TestCase):
    def test_the_json_block_survives_the_document_wrapper(self):
        data = {"title": "t", "files": [{"path": "a/b.ts", "intent": "i"}], "not_touched": []}
        text = p.document(data, p.render(data))
        self.assertEqual(p.split_document(text), data)


class WriteGuard(unittest.TestCase):
    """Only the final, English artefact reaches a commit."""

    def spec(self, tmp):
        data = {"title": "t", "files": [{"path": "a/b.ts", "intent": "reads it"}],
                "not_touched": [{"path": "c/", "why": "untouched"}]}
        with open(os.path.join(tmp, "projection.md"), "w", encoding="utf-8") as handle:
            handle.write(p.document(data, p.render(data)))
        return data

    def render_args(self, tmp, **kwargs):
        base = {"spec": tmp, "write": False, "lang": "en", "overlay": None, "repo_root": "."}
        base.update(kwargs)
        return argparse.Namespace(**base)

    def test_a_translated_render_cannot_be_written(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.spec(tmp)
            with self.assertRaises(SystemExit):
                p.cmd_render(self.render_args(tmp, write=True, lang="fr"))

    def test_an_overlay_cannot_be_written_either(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.spec(tmp)
            with open(os.path.join(tmp, "fr.json"), "w", encoding="utf-8") as handle:
                json.dump({"files": {"a/b.ts": "le lit"}}, handle)
            with self.assertRaises(SystemExit):
                p.cmd_render(self.render_args(tmp, write=True,
                                              overlay=os.path.join(tmp, "fr.json")))

    def test_the_english_render_writes_normally(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.spec(tmp)
            self.assertEqual(p.cmd_render(self.render_args(tmp, write=True)), 0)
            with open(os.path.join(tmp, "projection.md"), encoding="utf-8") as handle:
                self.assertIn("reads it", handle.read())


if __name__ == "__main__":
    unittest.main()
