#!/usr/bin/env python3
"""Tests for the session-meta CLI.

Run from this directory, inside a container:

    docker run --rm -v "$PWD:/repo" -w /repo/skills/session-meta/scripts \
      python:3.12-alpine python3 -m unittest -v

Standard library only, to match the script under test.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import tempfile
import threading
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location("session_meta", Path(__file__).with_name("session-meta.py"))
sm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sm)


class SessionMetaTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = str(Path(self.tmp.name) / "nested" / "meta.sqlite")

    def tearDown(self):
        self.tmp.cleanup()

    def run_cli(self, *args, harness="claude-code"):
        cmd, rest = args[0], list(args[1:])
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = sm.main([cmd, "--db", self.db, "--harness", harness, *rest])
        self.assertEqual(rc, 0)
        return json.loads(out.getvalue())

    def test_unknown_session_is_an_empty_document(self):
        self.assertEqual(self.run_cli("get", "nope"), {})

    def test_keys_are_open_and_values_are_json(self):
        self.run_cli("set", "s", "subject", "Métadonnées de session")
        self.run_cli("set", "s", "linear_issue", '{"id": "TT-1843", "url": "https://linear.app/x"}', "--json")
        doc = self.run_cli("get", "s")
        self.assertEqual(doc["subject"], "Métadonnées de session")
        self.assertEqual(doc["linear_issue"]["id"], "TT-1843")
        self.assertEqual(self.run_cli("get", "s", "--key", "subject"), "Métadonnées de session")

    def test_plain_value_is_kept_as_a_string(self):
        # "42" without --json must not silently become a number.
        self.run_cli("set", "s", "pr", "42")
        self.assertEqual(self.run_cli("get", "s", "--key", "pr"), "42")

    def test_harness_partitions_the_same_session_id(self):
        self.run_cli("set", "s", "subject", "claude side")
        self.run_cli("set", "s", "subject", "cursor side", harness="cursor")
        self.assertEqual(self.run_cli("get", "s", "--key", "subject"), "claude side")
        self.assertEqual(self.run_cli("get", "s", "--key", "subject", harness="cursor"), "cursor side")

    def test_unset_removes_one_key(self):
        self.run_cli("set", "s", "a", "1")
        self.run_cli("set", "s", "b", "2")
        self.run_cli("unset", "s", "a")
        self.assertEqual(self.run_cli("get", "s"), {"b": "2"})

    def test_incr_counts_from_zero(self):
        self.run_cli("incr", "s", "turns")
        self.assertEqual(self.run_cli("incr", "s", "turns"), 2)

    def test_concurrent_appends_all_survive(self):
        # Two hooks firing at once must not lose an event (read-modify-write).
        # redirect_stdout is process-wide, not per thread: silence emit instead.
        def worker(n):
            sm.main(["append", "--db", self.db, "--harness", "claude-code", "s", "events", json.dumps({"n": n}), "--json"])

        sm.connect(Path(self.db)).close()
        real_emit, sm.emit = sm.emit, lambda obj: None
        try:
            threads = [threading.Thread(target=worker, args=(i,)) for i in range(10)]
            for t in threads:
                t.start()
            for t in threads:
                t.join()
        finally:
            sm.emit = real_emit
        events = self.run_cli("get", "s", "--key", "events")
        self.assertEqual(sorted(e["n"] for e in events), list(range(10)))

    def test_find_by_key_and_value(self):
        self.run_cli("set", "a", "scope", "focused")
        self.run_cli("set", "b", "scope", "generalist")
        self.run_cli("set", "c", "scope", "focused", harness="cursor")
        hits = self.run_cli("find", "--key", "scope", "--value", "focused")
        self.assertEqual([h["session_id"] for h in hits], ["a"])
        hits = self.run_cli("find", "--key", "scope", "--value", "focused", "--all-harnesses")
        self.assertEqual(sorted(h["session_id"] for h in hits), ["a", "c"])

    def test_sessions_lists_ids_with_key_counts(self):
        self.run_cli("set", "a", "x", "1")
        self.run_cli("set", "a", "y", "1")
        self.assertEqual([(s["session_id"], s["keys"]) for s in self.run_cli("sessions")], [("a", 2)])


if __name__ == "__main__":
    unittest.main()
