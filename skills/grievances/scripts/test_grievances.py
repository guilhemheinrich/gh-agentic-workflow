#!/usr/bin/env python3
"""Tests for the grievances ledger CLI.

Run from this directory, inside the container the skill documents:

    docker run --rm -v "$PWD:/repo" -w /repo/skills/grievances/scripts \
      python:3.12-alpine python3 -m unittest -v

Standard library only, to match the script under test. Several cases exist
because an adversarial review broke an earlier design; each of those names the
finding it pins, so a later refactor cannot quietly undo the fix.
"""

from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

import grievances as g

# ── Fixtures ───────────────────────────────────────────────────────────────

LEGACY_ID = "GRV-0001"
SLUG_ID = "GRV-worker-hosted-api-scale"


def block(gid: str, short: str = "a finding", **meta: object) -> str:
    """One detail block, as the tool writes it."""
    header = {"id": gid, "short": short, "severity": "high", "date": "2026-07-30",
              "status": "open", "occurrences": 1}
    header.update(meta)
    return (
        f"<!-- grievance:{gid} {json.dumps(header, ensure_ascii=False, sort_keys=True)} -->\n"
        f'<a id="{gid.lower()}"></a>\n'
        f"### {gid} · high · 2026-07-30 — {short}\n\n"
        f"<!-- grievance:{gid}:prose -->\n\n"
        f"**Finding.** prose owned by the author.\n"
        f"<!-- /grievance:{gid} -->\n"
    )


def ledger_text(*blocks: str, extra: str = "") -> str:
    """A whole ledger file wrapping the given detail blocks."""
    return (
        "# Grievances\n\n"
        f"{g.OPEN_START}\n{g.RESOLVED_START}\n{g.RESOLVED_END}\n{g.OPEN_END}\n\n"
        "# Details\n\n" + "".join(blocks) + extra + f"\n{g.DETAILS_END}\n"
    )


@contextlib.contextmanager
def quiet():
    """Swallow the CLI's own stdout; the suite reports its own results."""
    with contextlib.redirect_stdout(io.StringIO()):
        yield


def written(text: str) -> Path:
    """Write `text` to a throwaway ledger and return its path."""
    tmp = Path(tempfile.mkdtemp()) / "GRIEVANCES.md"
    tmp.write_text(text, encoding="utf-8")
    return tmp


# ── Identifier shape ───────────────────────────────────────────────────────


class TestIdentifierShape(unittest.TestCase):
    """T002, T003: the two forms, their bounds, and their disjointness."""

    LEGACY_OK = ["GRV-0001", "GRV-0042", "GRV-9999"]
    SLUG_OK = [
        "GRV-db-naming",
        "GRV-worker-hosted-api-scale",
        "GRV-worker-queue-retry-bug-alpha",   # 5 segments
        "GRV-release-pipeline-npm-token-9c23",  # with a discriminator
        "GRV-2fa-bypass-trap-npm-token",
    ]
    NEITHER = [
        "GRV-worker",          # 1 segment
        "GRV-Worker-Api",      # uppercase
        "GRV-a-b-c-d-e-f",     # 6 segments
        "GRV-worker_api",      # underscore
        "GRV-",                # empty
        "grv-worker-api",      # lowercase prefix
    ]

    def test_legacy_form(self):
        for ident in self.LEGACY_OK:
            self.assertTrue(g.LEGACY_ID_RE.match(ident), ident)
        for ident in self.SLUG_OK + self.NEITHER:
            self.assertFalse(g.LEGACY_ID_RE.match(ident), ident)

    def test_slug_form(self):
        for ident in self.SLUG_OK:
            self.assertTrue(g.SLUG_ID_RE.match(ident), ident)
        for ident in self.LEGACY_OK + self.NEITHER:
            self.assertFalse(g.SLUG_ID_RE.match(ident), ident)

    def test_forms_are_disjoint(self):
        """One union pattern can read a mixed ledger only if nothing matches both."""
        both = [
            ident
            for ident in self.LEGACY_OK + self.SLUG_OK + self.NEITHER
            if g.LEGACY_ID_RE.match(ident) and g.SLUG_ID_RE.match(ident)
        ]
        self.assertEqual(both, [])

    def test_validators_are_anchored(self):
        """Review finding 10: an unanchored validator accepts a padded identifier."""
        for ident in ["GRV-0001x", "GRV-worker-api!!", "xGRV-worker-api"]:
            with self.assertRaises(g.UserError, msg=ident):
                g.check_id(ident)

    def test_ceiling_is_separate_from_the_pattern(self):
        """T003, review finding 3: the pattern carries no length bound."""
        overlong = "GRV-" + "-".join(["aaaaaaaa"] * 5)
        self.assertGreater(len(overlong), g.ID_MAX_LEN)
        self.assertTrue(g.SLUG_ID_RE.match(overlong), "pattern alone accepts it")
        with self.assertRaises(g.UserError):
            g.check_id(overlong)

    def test_legacy_form_is_never_minted(self):
        g.check_id("GRV-0099")
        with self.assertRaises(g.UserError):
            g.check_new_id("GRV-0099")


class TestBlockPattern(unittest.TestCase):
    """T004: BLOCK_RE keeps its group numbering and its backreference."""

    def test_groups_over_a_mixed_ledger(self):
        text = ledger_text(block(LEGACY_ID, "legacy entry"),
                           block("GRV-worker-queue-retry-bug-alpha", "slug entry"))
        found = [(m.group(1), m.group(2), m.group(3)) for m in g.BLOCK_RE.finditer(text)]
        self.assertEqual([f[0] for f in found],
                         [LEGACY_ID, "GRV-worker-queue-retry-bug-alpha"])
        for gid, raw_meta, body in found:
            self.assertEqual(json.loads(raw_meta)["id"], gid, "group 2 is the JSON")
            self.assertIn("prose owned by the author", body, "group 3 is the body")

    def test_backreference_rejects_a_mismatched_pair(self):
        text = ('<!-- grievance:GRV-a-b {"id": "GRV-a-b"} -->\nbody\n'
                "<!-- /grievance:GRV-c-d -->\n")
        self.assertEqual(g.BLOCK_RE.findall(text), [])


# ── Word selection and derivation ──────────────────────────────────────────


class TestSignificantWords(unittest.TestCase):
    """T006: the acronym exception, accent folding, the stop-word set."""

    def test_acronym_test_reads_the_pre_fold_token(self):
        """Review finding 7: folding first makes the acronym test impossible."""
        self.assertEqual(g.significant_words("DB naming"), ["db", "naming"])
        self.assertEqual(g.significant_words("db naming"), ["naming"])

    def test_accents_fold(self):
        self.assertEqual(g.significant_words("requête trop lente"),
                         ["requete", "trop", "lente"])

    def test_stop_words_include_the_extension(self):
        """Review finding 8: without `not`, the documented example changes."""
        for word in ["with", "will", "not", "the", "its"]:
            self.assertIn(word, g.STOP_WORDS, word)
        self.assertEqual(len(g.STOP_WORDS), 54)

    def test_documented_selection(self):
        self.assertEqual(
            g.significant_words("worker co-hosted with the API will not scale"),
            ["worker", "hosted", "api", "scale"],
        )


class TestDeriveId(unittest.TestCase):
    """T007, T008, T009: the derivation contract."""

    DOCUMENTED = {
        "worker co-hosted with the API will not scale": "GRV-worker-hosted-api-scale",
        "DB naming": "GRV-db-naming",
        "DB naming diverges from the code aliases": "GRV-db-naming-diverges-code-aliases",
        "2FA bypass trap on the npm token": "GRV-2fa-bypass-trap-npm-token",
        "requête trop lente": "GRV-requete-trop-lente",
    }

    def test_documented_examples(self):
        for short, want in self.DOCUMENTED.items():
            self.assertEqual(g.derive_id(short), want, short)

    def test_every_result_is_valid_and_within_the_ceiling(self):
        for short in self.DOCUMENTED:
            ident = g.derive_id(short)
            g.check_new_id(ident)
            self.assertLessEqual(len(ident), g.ID_MAX_LEN, ident)

    def test_deterministic(self):
        short = "the asset registry description drifts from the skill frontmatter title"
        self.assertEqual(len({g.derive_id(short) for _ in range(5)}), 1)

    def test_distinct_descriptions_never_collide(self):
        """T008 — the review's blocker. The third pair is the load-bearing one:
        it collides under ANY design without a discriminator, because the ceiling
        truncates it regardless of the segment count."""
        pairs = [
            ("worker queue retry bug alpha", "worker queue retry bug omega"),
            ("release pipeline npm token expires after ninety days",
             "release pipeline npm token bypasses two factor auth"),
            ("the asset registry description drifts from the skill frontmatter title",
             "the asset registry description drifts from the schema enum values"),
            ("make integration hardcodes its domain list",
             "make integration hardcodes its domain map"),
        ]
        for first, second in pairs:
            self.assertNotEqual(g.derive_id(first), g.derive_id(second),
                                f"{first!r} vs {second!r}")

    def test_discriminator_is_conditional(self):
        complete = g.derive_id("DB naming")
        truncated = g.derive_id("release pipeline npm token expires after ninety days")
        self.assertEqual(complete, "GRV-db-naming")
        self.assertEqual(len(truncated.rsplit("-", 1)[1]), g.ID_DISCRIMINATOR_LEN)
        self.assertNotEqual(len(complete.split("-")), len(truncated.split("-")))

    def test_identical_descriptions_collide_on_purpose(self):
        """The duplicate signal the specification asks for."""
        short = "worker co-hosted with the API will not scale"
        self.assertEqual(g.derive_id(short), g.derive_id(short))

    def test_whitespace_and_stop_word_noise_do_not_change_the_result(self):
        base = g.derive_id("release pipeline npm token expires after ninety days")
        noisy = g.derive_id("the  release pipeline npm token expires after ninety days")
        self.assertEqual(base, noisy)

    def test_refusals(self):
        for short in ["slow", "a", "the the the", "db naming"]:
            with self.assertRaises(g.UserError, msg=short):
                g.derive_id(short)

    def test_two_long_words_are_refused_not_truncated_illegally(self):
        """Review finding 12: never emit an over-long identifier."""
        for short in ["internationalization misconfiguration",
                      "supercalifragilisticexpialidocious antidisestablishmentarianism"]:
            with self.assertRaises(g.UserError, msg=short):
                g.derive_id(short)

    def test_derivation_does_not_know_about_the_ledger(self):
        """Review finding 6: uniqueness is the caller's, so a supplied --id
        cannot skip it. derive_id must take no ledger argument."""
        import inspect
        self.assertEqual(list(inspect.signature(g.derive_id).parameters), ["short"])


# ── Conflict markers ───────────────────────────────────────────────────────


class TestConflictMarkers(unittest.TestCase):
    """T030, T031."""

    def test_angle_bracket_markers_are_found(self):
        found = g.find_conflict_markers("a\n<<<<<<< HEAD\nb\n=======\nc\n>>>>>>> other\n")
        self.assertEqual(found, ["<<<<<<< HEAD", ">>>>>>> other"])

    def test_a_bare_separator_is_not_a_conflict_marker(self):
        """Guard test, not a fail-first test: `=======` is legal markdown and
        appears in author-owned prose. It must pass before AND after the
        detector exists. Review finding 9 corrected an earlier claim otherwise."""
        self.assertEqual(g.find_conflict_markers("Heading\n=======\nbody\n"), [])
        self.assertEqual(g.find_conflict_markers("a\n---\n=======\n"), [])

    def test_loading_a_conflicted_ledger_names_the_conflict(self):
        path = written(ledger_text(block(SLUG_ID)) + "<<<<<<< HEAD\n")
        with self.assertRaises(g.UserError) as caught:
            g.Ledger.load(path)
        self.assertIn("conflict", str(caught.exception))

    def test_a_ledger_with_a_bare_separator_in_prose_loads(self):
        path = written(ledger_text(block(SLUG_ID)) + "Some section\n=======\ntext\n")
        self.assertEqual(len(g.Ledger.load(path).grievances), 1)


# ── Ledger integrity on the read path ──────────────────────────────────────


class TestLedgerIntegrity(unittest.TestCase):
    """T032, T033, T034: the three ways a ledger used to lie or brick."""

    def test_an_unusable_marker_is_reported_not_skipped(self):
        """T032, review finding 2. Before the fix these entries vanished from
        the model and the tables while their text stayed in the file."""
        path = written(ledger_text(block(LEGACY_ID), block("GRV-worker"),
                                   block("GRV-Worker-Api")))
        with self.assertRaises(g.UserError) as caught:
            g.Ledger.load(path)
        message = str(caught.exception)
        self.assertIn("GRV-worker", message)
        self.assertIn("unusable id", message)

    def test_an_overlong_stored_identifier_is_rejected(self):
        """T033, review finding 3: the ceiling must hold on the read path."""
        overlong = "GRV-" + "-".join(["aaaaaaaa"] * 5)
        path = written(ledger_text(block(overlong)))
        with self.assertRaises(g.UserError) as caught:
            g.Ledger.load(path)
        self.assertIn(str(g.ID_MAX_LEN), str(caught.exception))

    def test_a_duplicate_identifier_names_the_recovery(self):
        """T034: the failure is correct, but it has to be actionable."""
        path = written(ledger_text(block(SLUG_ID, "one"), block(SLUG_ID, "two")))
        with self.assertRaises(g.UserError) as caught:
            g.Ledger.load(path)
        message = str(caught.exception)
        self.assertIn("appears twice", message)
        self.assertIn("bump", message)

    def test_a_clean_mixed_ledger_loads(self):
        path = written(ledger_text(block(LEGACY_ID, "legacy"), block(SLUG_ID, "slug")))
        ledger = g.Ledger.load(path)
        self.assertEqual([x.id for x in ledger.grievances], [LEGACY_ID, SLUG_ID])


# ── Legacy coexistence ─────────────────────────────────────────────────────


class TestLegacyCoexistence(unittest.TestCase):
    """T024 to T028: no existing identifier may change value."""

    def test_a_legacy_only_ledger_round_trips_unchanged(self):
        path = written(ledger_text(block(LEGACY_ID)))
        before = g.Ledger.load(path)
        rendered = before.render()
        path.write_text(rendered, encoding="utf-8")
        after = g.Ledger.load(path)
        self.assertEqual([x.id for x in after.grievances], [LEGACY_ID])

    def test_both_forms_render_in_the_table_with_a_live_anchor(self):
        path = written(ledger_text(block(LEGACY_ID, "legacy one"),
                                   block(SLUG_ID, "slug one")))
        rendered = g.Ledger.load(path).render()
        for gid in (LEGACY_ID, SLUG_ID):
            self.assertIn(f"[{gid}](#{gid.lower()})", rendered, gid)
            self.assertIn(f'<a id="{gid.lower()}"></a>', rendered, gid)

    def test_regeneration_is_idempotent(self):
        path = written(ledger_text(block(LEGACY_ID), block(SLUG_ID)))
        once = g.Ledger.load(path).render()
        path.write_text(once, encoding="utf-8")
        twice = g.Ledger.load(path).render()
        self.assertEqual(once, twice)

    def test_ordering_never_depends_on_identifiers_being_numeric(self):
        older = block(SLUG_ID, "older", date="2026-01-01")
        newer = block(LEGACY_ID, "newer", date="2026-09-09")
        path = written(ledger_text(newer, older))
        rendered = g.Ledger.load(path).render()
        self.assertLess(rendered.index(f"[{SLUG_ID}]"), rendered.index(f"[{LEGACY_ID}]"))

    def test_taken_ids_survives_a_slug(self):
        """The old next_id() raised ValueError here; T022 removed it."""
        path = written(ledger_text(block(LEGACY_ID), block(SLUG_ID)))
        self.assertEqual(g.Ledger.load(path).taken_ids(), {LEGACY_ID, SLUG_ID})

    def test_next_id_is_gone(self):
        self.assertFalse(hasattr(g.Ledger, "next_id"))


# ── Merge behaviour ────────────────────────────────────────────────────────


class TestSiblingBranches(unittest.TestCase):
    """T013 to T016: the defect this whole change removes."""

    START = ledger_text(block(LEGACY_ID, "pre-existing"))

    def _declare(self, short: str) -> str:
        """Derive against a fresh copy of the same starting ledger, as a branch would."""
        ledger = g.Ledger.load(written(self.START))
        ident = g.derive_id(short)
        self.assertNotIn(ident, ledger.taken_ids())
        return ident

    def test_two_branches_two_findings_two_identifiers(self):
        first = self._declare("worker co-hosted with the API will not scale")
        second = self._declare("DB naming diverges from the code aliases")
        self.assertNotEqual(first, second)

    def test_two_branches_sharing_their_opening_words(self):
        """T014 — the exact trigger the review used to break the first design."""
        first = self._declare("release pipeline npm token expires after ninety days")
        second = self._declare("release pipeline npm token bypasses two factor auth")
        self.assertNotEqual(first, second)

    def test_the_merged_ledger_loads_and_holds_both(self):
        """T015: what used to fail is that load() refused the merged file."""
        first = self._declare("worker co-hosted with the API will not scale")
        second = self._declare("DB naming diverges from the code aliases")
        merged = written(ledger_text(block(LEGACY_ID, "pre-existing"),
                                     block(first, "one"), block(second, "two")))
        ledger = g.Ledger.load(merged)
        self.assertEqual(sorted(ledger.taken_ids()), sorted([LEGACY_ID, first, second]))

    def test_identifiers_do_not_derive_from_the_entry_count(self):
        empty = g.Ledger.load(written(ledger_text()))
        full = g.Ledger.load(written(self.START))
        short = "worker co-hosted with the API will not scale"
        self.assertEqual(g.derive_id(short), g.derive_id(short))
        self.assertNotEqual(len(empty.taken_ids()), len(full.taken_ids()))


class TestKeepBothResolution(unittest.TestCase):
    """T035: a hand-resolved merge normalizes in one regeneration."""

    def test_stale_generated_content_is_rebuilt_without_losing_an_entry(self):
        stale_table = ("| ID | Date | Severity | Seen | Short description |\n"
                       "|---|---|---|---|---|\n"
                       "| [GRV-0001](#grv-0001) | 2026-07-30 | high | ×1 | stale row |\n"
                       "| [GRV-0001](#grv-0001) | 2026-07-30 | high | ×1 | duplicated row |\n")
        text = (
            "# Grievances\n\n"
            f"{g.OPEN_START}\n{stale_table}{g.RESOLVED_START}\n{g.RESOLVED_END}\n{g.OPEN_END}\n\n"
            "# Details\n\n"
            + block(LEGACY_ID, "legacy entry") + block(SLUG_ID, "slug entry")
            + f"\n{g.DETAILS_END}\n"
        )
        path = written(text)
        rendered = g.Ledger.load(path).render()
        self.assertEqual(rendered.count("stale row"), 0)
        self.assertEqual(rendered.count(f"[{LEGACY_ID}](#{LEGACY_ID.lower()})"), 1)
        self.assertEqual(rendered.count(f"[{SLUG_ID}](#{SLUG_ID.lower()})"), 1)
        path.write_text(rendered, encoding="utf-8")
        self.assertEqual(g.Ledger.load(path).render(), rendered, "second pass is a no-op")


# ── Author-owned prose ─────────────────────────────────────────────────────


class TestProseIsPreserved(unittest.TestCase):
    """The ownership contract this change must not disturb."""

    def test_prose_survives_a_regeneration_verbatim(self):
        marker = f"<!-- grievance:{SLUG_ID}:prose -->"
        prose = "**Finding.** a table:\n\n| a | b |\n|---|---|\n| 1 | 2 |\n"
        text = ledger_text(
            f"<!-- grievance:{SLUG_ID} "
            f'{{"date": "2026-07-30", "id": "{SLUG_ID}", "occurrences": 1, '
            f'"severity": "high", "short": "x", "status": "open"}} -->\n'
            f'<a id="{SLUG_ID.lower()}"></a>\n### {SLUG_ID}\n\n{marker}\n\n{prose}'
            f"<!-- /grievance:{SLUG_ID} -->\n"
        )
        rendered = g.Ledger.load(written(text)).render()
        self.assertIn(prose.strip(), rendered)


if __name__ == "__main__":
    unittest.main()


# ── The add command, end to end in-process ─────────────────────────────────


class AddCase(unittest.TestCase):
    """Base for T017 to T019: drive cmd_add through a real Namespace."""

    def setUp(self):
        self.path = written(ledger_text())

    def add(self, short: str, **overrides: object):
        """Run cmd_add and return its exit code, or let UserError escape."""
        import argparse
        fields = dict(
            file=str(self.path), repo=None, short=short, severity="high", date=None,
            locus=None, source=None, tag=None, finding=None, impact="it costs us",
            why_tests_miss=None, fix=None, effort=None, body_file=None,
            allow_no_impact=False, force=False, id=None, dry_run=False, json=True,
        )
        fields.update(overrides)
        with quiet():
            return g.cmd_add(argparse.Namespace(**fields))

    def ids(self) -> set[str]:
        return g.Ledger.load(self.path).taken_ids()


class TestAddDerivedIdentifier(AddCase):
    """T013 at the command level."""

    def test_a_declaration_mints_a_descriptive_identifier(self):
        self.add("worker co-hosted with the API will not scale")
        self.assertEqual(self.ids(), {"GRV-worker-hosted-api-scale"})

    def test_two_declarations_two_identifiers(self):
        self.add("worker co-hosted with the API will not scale")
        self.add("DB naming diverges from the code aliases")
        self.assertEqual(len(self.ids()), 2)

    def test_a_thin_description_is_refused_before_anything_is_written(self):
        with self.assertRaises(g.UserError):
            self.add("slow")
        self.assertEqual(self.ids(), set())


class TestAddSuppliedIdentifier(AddCase):
    """T017, T018."""

    def test_a_supplied_identifier_need_not_reuse_words_from_short(self):
        """FR-004a: the escape hatch is exempt from word overlap."""
        self.add("database naming mismatch", id="GRV-registry-drift")
        self.assertEqual(self.ids(), {"GRV-registry-drift"})

    def test_a_malformed_supplied_identifier_is_refused(self):
        for bad in ["GRV-Worker-API", "GRV-worker", "GRV-" + "-".join(["aaaaaaaa"] * 5)]:
            with self.subTest(bad=bad), self.assertRaises(g.UserError):
                self.add("a distinct finding here", id=bad)
        self.assertEqual(self.ids(), set())

    def test_the_legacy_form_cannot_be_supplied(self):
        with self.assertRaises(g.UserError):
            self.add("a distinct finding here", id="GRV-0099")

    def test_a_supplied_duplicate_is_refused(self):
        """T018, review finding 6: this path bypassed the check entirely."""
        self.add("first finding here", id="GRV-registry-drift")
        with self.assertRaises(g.UserError) as caught:
            self.add("second and different finding", id="GRV-registry-drift")
        self.assertIn("already used", str(caught.exception))
        self.assertEqual(len(self.ids()), 1)


class TestAddForce(AddCase):
    """T019, review finding 5: --force cannot work alone any more."""

    SHORT = "worker co-hosted with the API will not scale"

    def test_a_duplicate_description_is_refused_and_points_at_bump(self):
        self.add(self.SHORT)
        with self.assertRaises(g.UserError) as caught:
            self.add(self.SHORT)
        self.assertIn("bump", str(caught.exception))

    def test_force_alone_is_refused_and_says_it_needs_id(self):
        self.add(self.SHORT)
        with self.assertRaises(g.UserError) as caught:
            self.add(self.SHORT, force=True)
        self.assertIn("--id", str(caught.exception))
        self.assertEqual(len(self.ids()), 1)

    def test_force_with_an_explicit_identifier_succeeds(self):
        self.add(self.SHORT)
        self.add(self.SHORT, force=True, id="GRV-worker-second-case")
        self.assertEqual(len(self.ids()), 2)


class TestAddIntoALegacyLedger(AddCase):
    """T028: nothing is renumbered."""

    def setUp(self):
        self.path = written(ledger_text(block(LEGACY_ID, "pre-existing")))

    def test_a_new_entry_does_not_touch_the_legacy_one(self):
        self.add("worker co-hosted with the API will not scale")
        self.assertEqual(self.ids(), {LEGACY_ID, "GRV-worker-hosted-api-scale"})


# ── Audit and migrate never rename ─────────────────────────────────────────


class TestAuditAndMigrate(unittest.TestCase):
    """T027, T036."""

    def _repo(self, ledger: str) -> Path:
        root = Path(tempfile.mkdtemp())
        (root / "specs").mkdir()
        (root / "specs" / g.LEDGER_BASENAME).write_text(ledger, encoding="utf-8")
        (root / "specs" / "CLAUDE.md").write_text(
            f"reads {g.LEDGER_BASENAME}\n", encoding="utf-8")
        (root / "CLAUDE.md").write_text(
            f"see specs/{g.LEDGER_BASENAME}\n", encoding="utf-8")
        return root

    def test_audit_leaves_every_identifier_untouched(self):
        text = ledger_text(block(LEGACY_ID), block(SLUG_ID))
        root = self._repo(text)
        problems, _ = g.audit_repo(root, strict=False)
        self.assertEqual(problems, 0)
        self.assertEqual(
            (root / "specs" / g.LEDGER_BASENAME).read_text(encoding="utf-8"), text)

    def test_audit_reports_each_load_failure_instead_of_raising(self):
        """T036: audit_repo wraps load, so the new refusals surface as problems."""
        overlong = "GRV-" + "-".join(["aaaaaaaa"] * 5)
        corruptions = {
            "conflict": ledger_text(block(SLUG_ID)) + "<<<<<<< HEAD\n",
            "unusable id": ledger_text(block("GRV-worker")),
            "over the ceiling": ledger_text(block(overlong)),
            "duplicate": ledger_text(block(SLUG_ID, "a"), block(SLUG_ID, "b")),
        }
        for label, text in corruptions.items():
            with self.subTest(label=label):
                problems, lines = g.audit_repo(self._repo(text), strict=False)
                self.assertGreater(problems, 0)
                self.assertTrue(any(g.LEDGER_BASENAME in line for line in lines))

    def test_migrate_imports_legacy_prose_without_minting_an_identifier(self):
        import argparse
        root = Path(tempfile.mkdtemp())
        (root / "specs").mkdir()
        legacy = root / "specs" / g.LEGACY_BASENAMES[0]
        legacy.write_text("# Doleances\n\n- an old note about GRV-0001\n", encoding="utf-8")
        target = root / "specs" / g.LEDGER_BASENAME
        with quiet():
            g.cmd_migrate(argparse.Namespace(
                file=str(target), repo=None, source=str(legacy),
                keep_legacy=True, dry_run=False, json=False,
            ))
        migrated = target.read_text(encoding="utf-8")
        self.assertIn("an old note about GRV-0001", migrated, "prose kept verbatim")
        self.assertEqual(g.Ledger.load(target).taken_ids(), set(), "nothing minted")
