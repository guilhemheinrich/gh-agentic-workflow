"""LW-1 — store, schema migration and subscriptions.

Run in Docker: bash skills/linear-watch/tests/run-in-docker.sh
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
from pathlib import Path

LW_PATH = Path(__file__).resolve().parent.parent / "scripts" / "lw"


def load_lw():
    loader = SourceFileLoader("lw", str(LW_PATH))
    spec = spec_from_loader("lw", loader)
    module = module_from_spec(spec)
    loader.exec_module(module)
    return module


lw = load_lw()

SLUG_ID = "5842ed0c2bcd"
FULL_SLUG = "broker-pa-run-and-evolutions-courant-5842ed0c2bcd"
PROJECT_URL = (
    "https://linear.app/septeo-proptech/project/"
    "broker-pa-run-and-evolutions-courant-5842ed0c2bcd/overview"
)
ISSUE_URL = "https://linear.app/septeo-proptech/issue/TT-2287/some-title"
TABLES = {"subscriptions", "cursors", "issue_states", "own_writes", "events"}


def parse_ts(value: str) -> datetime:
    return datetime.strptime(value, lw.TS_FORMAT)


class StoreTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state_dir = Path(self._tmp.name) / "state"
        self.db = self.state_dir / "lw.sqlite"

    def tearDown(self):
        self._tmp.cleanup()

    def run_lw(self, *args: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = lw.main(["--state-dir", str(self.state_dir), *args])
        return code, out.getvalue(), err.getvalue()

    def ok(self, *args: str) -> str:
        code, out, err = self.run_lw(*args)
        self.assertEqual(code, 0, f"lw {' '.join(args)} failed: {err}")
        return out

    def rows(self, sql: str, params=()) -> list[sqlite3.Row]:
        conn = sqlite3.connect(self.db)
        conn.row_factory = sqlite3.Row
        try:
            return conn.execute(sql, params).fetchall()
        finally:
            conn.close()

    def open_subscriptions(self, session: str = "s1") -> list[sqlite3.Row]:
        return self.rows(
            "SELECT * FROM subscriptions WHERE session = ? AND closed_at IS NULL",
            (session,),
        )


class TestMigration(StoreTestCase):
    def test_migration_from_an_empty_file(self):
        self.state_dir.mkdir(parents=True)
        self.db.write_bytes(b"")
        self.ok("list")
        version = self.rows("PRAGMA user_version")[0][0]
        self.assertEqual(version, lw.SCHEMA_VERSION)
        names = {r[0] for r in self.rows("SELECT name FROM sqlite_master WHERE type = 'table'")}
        self.assertTrue(TABLES <= names, names)

    def test_second_open_is_a_no_op(self):
        self.ok("subscribe", "--session", "s1", "--issue", "TT-1")
        self.ok("list")
        self.assertEqual(self.rows("PRAGMA user_version")[0][0], lw.SCHEMA_VERSION)
        self.assertEqual(len(self.open_subscriptions()), 1)

    def test_missing_state_dir_is_created(self):
        self.assertFalse(self.state_dir.exists())
        self.ok("list")
        self.assertTrue(self.db.exists())

    def test_newer_schema_is_refused(self):
        self.state_dir.mkdir(parents=True)
        conn = sqlite3.connect(self.db)
        conn.execute(f"PRAGMA user_version = {lw.SCHEMA_VERSION + 1}")
        conn.close()
        code, _, err = self.run_lw("list")
        self.assertEqual(code, 2)
        self.assertIn("newer", err)

    def test_events_dedupe_per_session(self):
        self.ok("list")
        conn = sqlite3.connect(self.db)
        insert = "INSERT OR IGNORE INTO events (id, session, ts, text) VALUES (?, ?, ?, ?)"
        conn.execute(insert, ("comment:c1", "s1", "t", "line"))
        conn.execute(insert, ("comment:c1", "s1", "t", "line"))
        conn.execute(insert, ("comment:c1", "s2", "t", "line"))
        conn.commit()
        conn.close()
        self.assertEqual(self.rows("SELECT COUNT(*) FROM events")[0][0], 2)


class TestSubscribe(StoreTestCase):
    def test_subscribe_twice_gives_one_row(self):
        self.ok("subscribe", "--session", "s1", "--project", SLUG_ID)
        self.ok("subscribe", "--session", "s1", "--project", SLUG_ID)
        rows = self.open_subscriptions()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["kind"], "project")
        self.assertEqual(rows[0]["target"], SLUG_ID)
        self.assertEqual(rows[0]["harness"], "claude-code")

    def test_resubscribe_renews(self):
        self.ok("subscribe", "--session", "s1", "--issue", "TT-1")
        conn = sqlite3.connect(self.db)
        conn.execute("UPDATE subscriptions SET renewed_at = '2000-01-01T00:00:00Z'")
        conn.commit()
        conn.close()
        self.ok("subscribe", "--session", "s1", "--issue", "TT-1")
        self.assertNotEqual(self.open_subscriptions()[0]["renewed_at"], "2000-01-01T00:00:00Z")

    def test_project_url_and_slug_give_the_same_target(self):
        for form in (SLUG_ID, FULL_SLUG, PROJECT_URL, PROJECT_URL.replace("/overview", "")):
            with self.subTest(form=form):
                self.assertEqual(lw.normalize_project(form), SLUG_ID)
        self.ok("subscribe", "--session", "s1", "--project", FULL_SLUG)
        self.ok("subscribe", "--session", "s1", "--project", PROJECT_URL)
        self.ok("subscribe", "--session", "s1", "--project", SLUG_ID)
        self.assertEqual(len(self.open_subscriptions()), 1)

    def test_project_without_slug_id_is_refused(self):
        code, _, err = self.run_lw("subscribe", "--session", "s1", "--project", "my-project")
        self.assertEqual(code, 2)
        self.assertIn("slugId", err)
        self.assertFalse(self.db.exists() and self.open_subscriptions())

    def test_issue_identifier_is_normalized(self):
        for form in ("TT-2287", "tt-2287", ISSUE_URL):
            with self.subTest(form=form):
                self.assertEqual(lw.normalize_issue(form), "TT-2287")
        code, _, _ = self.run_lw("subscribe", "--session", "s1", "--issue", "not an issue")
        self.assertEqual(code, 2)

    def test_since_30d_is_capped_to_7d(self):
        self.ok("subscribe", "--session", "s1", "--issue", "TT-1", "--since", "30d")
        row = self.open_subscriptions()[0]
        delta = parse_ts(row["created_at"]) - parse_ts(row["since"])
        self.assertEqual(delta, timedelta(days=7))

    def test_since_3d_is_kept(self):
        self.ok("subscribe", "--session", "s1", "--issue", "TT-1", "--since", "3d")
        row = self.open_subscriptions()[0]
        delta = parse_ts(row["created_at"]) - parse_ts(row["since"])
        self.assertEqual(delta, timedelta(days=3))

    def test_no_since_means_baseline(self):
        self.ok("subscribe", "--session", "s1", "--issue", "TT-1")
        self.assertIsNone(self.open_subscriptions()[0]["since"])

    def test_since_units(self):
        self.assertEqual(lw.parse_duration("90m"), timedelta(minutes=90))
        self.assertEqual(lw.parse_duration("12h"), timedelta(hours=12))
        self.assertEqual(lw.parse_duration("2w"), timedelta(days=7))
        for bad in ("", "3", "d", "-1d", "3y"):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                lw.parse_duration(bad)

    def test_resubscribe_keeps_the_earliest_since(self):
        self.ok("subscribe", "--session", "s1", "--issue", "TT-1", "--since", "1d")
        self.ok("subscribe", "--session", "s1", "--issue", "TT-1", "--since", "3d")
        self.ok("subscribe", "--session", "s1", "--issue", "TT-1", "--since", "2h")
        row = self.open_subscriptions()[0]
        delta = parse_ts(row["created_at"]) - parse_ts(row["since"])
        self.assertGreaterEqual(delta, timedelta(days=3) - timedelta(seconds=5))

    def test_project_and_issue_are_exclusive(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            lw.main(["--state-dir", str(self.state_dir), "subscribe", "--session", "s1",
                     "--project", SLUG_ID, "--issue", "TT-1"])

    def test_harness_flag(self):
        self.ok("subscribe", "--session", "s1", "--issue", "TT-1", "--harness", "cursor")
        self.assertEqual(self.open_subscriptions()[0]["harness"], "cursor")


class TestUnsubscribe(StoreTestCase):
    def setUp(self):
        super().setUp()
        self.ok("subscribe", "--session", "s1", "--project", SLUG_ID)
        self.ok("subscribe", "--session", "s1", "--issue", "TT-1")
        self.ok("subscribe", "--session", "s1", "--issue", "TT-2")
        self.ok("subscribe", "--session", "s2", "--issue", "TT-1")

    def test_unsubscribe_all_closes_every_row_with_reason_unsubscribed(self):
        self.ok("unsubscribe", "--session", "s1", "--all")
        self.assertEqual(self.open_subscriptions("s1"), [])
        closed = self.rows("SELECT * FROM subscriptions WHERE session = 's1'")
        self.assertEqual(len(closed), 3)
        for row in closed:
            self.assertEqual(row["close_reason"], "unsubscribed")
            self.assertIsNotNone(row["closed_at"])
        self.assertEqual(len(self.open_subscriptions("s2")), 1)

    def test_unsubscribe_one_issue(self):
        self.ok("unsubscribe", "--session", "s1", "--issue", "tt-1")
        targets = {r["target"] for r in self.open_subscriptions("s1")}
        self.assertEqual(targets, {SLUG_ID, "TT-2"})

    def test_unsubscribe_project_by_url(self):
        self.ok("unsubscribe", "--session", "s1", "--project", PROJECT_URL)
        targets = {r["target"] for r in self.open_subscriptions("s1")}
        self.assertEqual(targets, {"TT-1", "TT-2"})

    def test_resubscribe_after_unsubscribe_opens_a_new_row(self):
        self.ok("unsubscribe", "--session", "s1", "--issue", "TT-1")
        self.ok("subscribe", "--session", "s1", "--issue", "TT-1")
        rows = self.rows("SELECT * FROM subscriptions WHERE session = 's1' AND target = 'TT-1'")
        self.assertEqual(len(rows), 2)
        self.assertEqual(sum(r["closed_at"] is None for r in rows), 1)

    def test_unsubscribe_nothing_matches_is_not_an_error(self):
        out = self.ok("unsubscribe", "--session", "nobody", "--all")
        self.assertIn("0", out)


class TestList(StoreTestCase):
    def setUp(self):
        super().setUp()
        self.ok("subscribe", "--session", "s1", "--project", SLUG_ID, "--since", "3d")
        self.ok("subscribe", "--session", "s2", "--issue", "TT-1")
        self.ok("subscribe", "--session", "s2", "--issue", "TT-2")
        self.ok("unsubscribe", "--session", "s2", "--issue", "TT-2")

    def test_list_json_shows_open_subscriptions(self):
        data = json.loads(self.ok("list", "--json"))
        self.assertEqual({(d["session"], d["target"]) for d in data},
                         {("s1", SLUG_ID), ("s2", "TT-1")})
        self.assertEqual(
            set(data[0]),
            {"session", "harness", "kind", "target", "since", "created_at",
             "renewed_at", "closed_at", "close_reason"},
        )

    def test_list_filters_by_session(self):
        data = json.loads(self.ok("list", "--session", "s2", "--json"))
        self.assertEqual([d["target"] for d in data], ["TT-1"])

    def test_list_closed(self):
        data = json.loads(self.ok("list", "--session", "s2", "--closed", "--json"))
        self.assertEqual({d["target"] for d in data}, {"TT-1", "TT-2"})

    def test_list_text(self):
        out = self.ok("list")
        self.assertIn(SLUG_ID, out)
        self.assertIn("TT-1", out)
        self.assertNotIn("TT-2", out)

    def test_list_empty_text(self):
        out = self.ok("list", "--session", "nobody")
        self.assertIn("no subscription", out)


class TestCli(StoreTestCase):
    def test_executable_with_env_state_dir(self):
        env = {**os.environ, "LW_STATE_DIR": str(self.state_dir)}
        run = subprocess.run(
            [sys.executable, str(LW_PATH), "subscribe", "--session", "s1", "--issue", "TT-9"],
            env=env, capture_output=True, text=True, check=False,
        )
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(len(self.open_subscriptions()), 1)

    def test_state_dir_flag_after_subcommand(self):
        with contextlib.redirect_stdout(io.StringIO()):
            code = lw.main(["list", "--state-dir", str(self.state_dir)])
        self.assertEqual(code, 0)
        self.assertTrue(self.db.exists())


if __name__ == "__main__":
    unittest.main()
