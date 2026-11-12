"""LW-5 — expiry: expire_subscriptions() and `lw expire`.

Built against hand-written rows and the fake desktop folder in
tests/fixtures/desktop-sessions/ (the poll cycle, LW-3, is not needed).
Run in Docker: bash skills/linear-tracker/tests/linear-watch/run-in-docker.sh test_expiry
"""

from __future__ import annotations

import contextlib
import io
import os
import shutil
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
from pathlib import Path
from unittest import mock

TESTS = Path(__file__).resolve().parent
LW_PATH = TESTS.parents[1] / "scripts" / "lw"
DESKTOP = TESTS / "fixtures" / "desktop-sessions"


def load_lw():
    loader = SourceFileLoader("lw_expiry", str(LW_PATH))
    spec = spec_from_loader("lw_expiry", loader)
    module = module_from_spec(spec)
    loader.exec_module(module)
    return module


lw = load_lw()

NOW = datetime(2026, 11, 12, 12, 0, 0, tzinfo=timezone.utc)
ARCHIVED = "aaaaaaaa-0000-4000-8000-000000000001"
ARCHIVED_PRIOR = "bbbbbbbb-0000-4000-8000-000000000001"
LIVE = "cccccccc-0000-4000-8000-000000000001"
ARCHIVED_BUT_FORKED = "dddddddd-0000-4000-8000-000000000001"
OUTSIDE_GLOB = "ffffffff-0000-4000-8000-000000000001"
GONE = "99999999-0000-4000-8000-000000000001"
PROJECT = "5842ed0c2bcd"


def ts(delta: timedelta = timedelta(0)) -> str:
    return lw.fmt(NOW - delta)


class ExpiryCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        self.state = self.tmp / "state"
        self.conn = lw.connect(self.state)
        self.addCleanup(self.conn.close)
        patcher = mock.patch.dict(os.environ, {"LW_STATE_DIR": str(self.state)})
        patcher.start()
        self.addCleanup(patcher.stop)
        os.environ.pop("LW_TTL_DAYS", None)

    # ── helpers ──
    def add_sub(self, session, kind="project", target=PROJECT, harness="claude-code",
                renewed=timedelta(hours=1), closed=None):
        cur = self.conn.execute(
            "INSERT INTO subscriptions"
            " (session, harness, kind, target, since, created_at, renewed_at, closed_at, close_reason)"
            " VALUES (?, ?, ?, ?, NULL, ?, ?, ?, ?)",
            (session, harness, kind, target, ts(renewed), ts(renewed),
             ts(closed) if closed else None, "unsubscribed" if closed else None),
        )
        return cur.lastrowid

    def row(self, sub_id):
        return self.conn.execute(
            "SELECT closed_at, close_reason FROM subscriptions WHERE id = ?", (sub_id,)
        ).fetchone()

    def reason(self, sub_id):
        return self.row(sub_id)["close_reason"]

    def expire(self, desktop=DESKTOP):
        return lw.expire_subscriptions(self.conn, NOW, desktop)

    def set_issue_state(self, ident, state_type):
        self.conn.execute(
            "INSERT OR REPLACE INTO issue_states (identifier, state, state_type, updated_at)"
            " VALUES (?, ?, ?, ?)", (ident, state_type.title(), state_type, ts()),
        )

    def add_event(self, session, event_id, delivered=None, at=timedelta(0)):
        self.conn.execute(
            "INSERT INTO events (id, session, ts, text, delivered_at) VALUES (?, ?, ?, ?, ?)",
            (event_id, session, ts(at), f"Linear · {event_id}",
             ts(delivered) if delivered is not None else None),
        )


class CloseReasons(ExpiryCase):
    def test_archived_by_cli_session_id(self):
        sub = self.add_sub(ARCHIVED)
        result = self.expire()
        self.assertEqual(self.reason(sub), "archived")
        self.assertEqual(self.row(sub)["closed_at"], ts())
        self.assertEqual(result["closed"], [
            {"session": ARCHIVED, "kind": "project", "target": PROJECT, "reason": "archived"}
        ])

    def test_archived_by_prior_cli_session_id(self):
        sub = self.add_sub(ARCHIVED_PRIOR)
        self.expire()
        self.assertEqual(self.reason(sub), "archived")

    def test_session_gone(self):
        sub = self.add_sub(GONE)
        self.expire()
        self.assertEqual(self.reason(sub), "session-gone")

    def test_ttl(self):
        sub = self.add_sub(LIVE, renewed=timedelta(days=7, seconds=1))
        self.expire()
        self.assertEqual(self.reason(sub), "ttl")

    def test_issue_done(self):
        for state_type in ("completed", "canceled"):
            with self.subTest(state_type=state_type):
                ident = f"TT-{len(state_type)}"
                sub = self.add_sub(LIVE, kind="issue", target=ident)
                self.set_issue_state(ident, state_type)
                self.expire()
                self.assertEqual(self.reason(sub), "issue-done")

    def test_project_done(self):
        for i, state_type in enumerate(("completed", "canceled")):
            with self.subTest(state_type=state_type):
                slug = f"{i:012x}"
                sub = self.add_sub(LIVE, target=slug)
                lw.record_project_state(self.conn, slug, state_type, ts())
                self.expire()
                self.assertEqual(self.reason(sub), "project-done")


class StaysOpen(ExpiryCase):
    def assert_open(self, sub):
        self.assertIsNone(self.row(sub)["closed_at"])

    def test_live_session(self):
        sub = self.add_sub(LIVE)
        result = self.expire()
        self.assert_open(sub)
        self.assertEqual(result["closed"], [])

    def test_archived_file_whose_id_lives_on_in_a_live_file(self):
        sub = self.add_sub(ARCHIVED_BUT_FORKED)
        self.expire()
        self.assert_open(sub)

    def test_file_outside_the_glob_does_not_count(self):
        sub = self.add_sub(OUTSIDE_GLOB)
        self.expire()
        self.assertEqual(self.reason(sub), "session-gone")

    def test_no_desktop_folder_skips_desktop_checks(self):
        sub = self.add_sub(GONE)
        self.expire(desktop=self.tmp / "no-such-folder")
        self.assert_open(sub)

    def test_empty_desktop_folder_skips_session_gone(self):
        empty = self.tmp / "empty"
        (empty / "a" / "b").mkdir(parents=True)
        sub = self.add_sub(GONE)
        self.expire(desktop=empty)
        self.assert_open(sub)

    def test_unreadable_file_skips_session_gone_but_not_archived(self):
        desktop = self.tmp / "desktop"
        shutil.copytree(DESKTOP, desktop)
        (desktop / "workspace-a" / "account-2" / "local_half-written.json").write_text('{"cliSess')
        gone = self.add_sub(GONE)
        archived = self.add_sub(ARCHIVED)
        self.expire(desktop=desktop)
        self.assert_open(gone)
        self.assertEqual(self.reason(archived), "archived")

    def test_other_harness_ignores_desktop_files(self):
        gone = self.add_sub(GONE, harness="codex")
        archived = self.add_sub(ARCHIVED, harness="codex")
        self.expire()
        self.assert_open(gone)
        self.assert_open(archived)

    def test_ttl_boundary(self):
        sub = self.add_sub(LIVE, renewed=timedelta(days=6, hours=23))
        self.expire()
        self.assert_open(sub)

    def test_ttl_days_from_environment(self):
        with mock.patch.dict(os.environ, {"LW_TTL_DAYS": "2"}):
            stale = self.add_sub(LIVE, renewed=timedelta(days=3))
            fresh = self.add_sub(LIVE, kind="issue", target="TT-1", renewed=timedelta(days=1))
            self.expire()
        self.assertEqual(self.reason(stale), "ttl")
        self.assert_open(fresh)

    def test_bad_ttl_days_is_an_error(self):
        for raw in ("0", "-1", "soon"):
            with self.subTest(raw=raw), mock.patch.dict(os.environ, {"LW_TTL_DAYS": raw}):
                with self.assertRaises(lw.LwError):
                    self.expire()

    def test_unfinished_issue_and_project(self):
        issue = self.add_sub(LIVE, kind="issue", target="TT-7")
        self.set_issue_state("TT-7", "started")
        project = self.add_sub(LIVE)
        lw.record_project_state(self.conn, PROJECT, "started", ts())
        self.expire()
        self.assert_open(issue)
        self.assert_open(project)

    def test_issue_state_does_not_close_a_project_subscription(self):
        sub = self.add_sub(LIVE, kind="project", target=PROJECT)
        self.set_issue_state(PROJECT.upper(), "completed")
        self.expire()
        self.assert_open(sub)

    def test_closed_rows_are_left_alone(self):
        sub = self.add_sub(ARCHIVED, closed=timedelta(days=1))
        self.expire()
        self.assertEqual(self.reason(sub), "unsubscribed")
        self.assertEqual(self.row(sub)["closed_at"], ts(timedelta(days=1)))


class Precedence(ExpiryCase):
    def test_archived_wins_over_everything(self):
        self.set_issue_state("TT-9", "completed")
        sub = self.add_sub(ARCHIVED, kind="issue", target="TT-9", renewed=timedelta(days=30))
        self.expire()
        self.assertEqual(self.reason(sub), "archived")

    def test_session_gone_wins_over_target_done_and_ttl(self):
        self.set_issue_state("TT-9", "completed")
        sub = self.add_sub(GONE, kind="issue", target="TT-9", renewed=timedelta(days=30))
        self.expire()
        self.assertEqual(self.reason(sub), "session-gone")

    def test_target_done_wins_over_ttl(self):
        self.set_issue_state("TT-9", "canceled")
        sub = self.add_sub(LIVE, kind="issue", target="TT-9", renewed=timedelta(days=30))
        self.expire()
        self.assertEqual(self.reason(sub), "issue-done")


class Purge(ExpiryCase):
    def test_purges_only_delivered_events_older_than_seven_days(self):
        self.add_event(LIVE, "comment:old-delivered", delivered=timedelta(days=7, seconds=1),
                       at=timedelta(days=8))
        self.add_event(LIVE, "comment:recent-delivered", delivered=timedelta(days=6),
                       at=timedelta(days=6))
        self.add_event(LIVE, "comment:old-pending", at=timedelta(days=30))
        result = self.expire()
        ids = {r["id"] for r in self.conn.execute("SELECT id FROM events")}
        self.assertEqual(ids, {"comment:recent-delivered", "comment:old-pending"})
        self.assertEqual(result["purged"], 1)

    def test_closing_an_issue_keeps_its_pending_line_deliverable(self):
        self.set_issue_state("TT-2290", "completed")
        self.add_sub(LIVE, kind="issue", target="TT-2290")
        self.add_event(LIVE, "state:TT-2290:completed")
        self.expire()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = lw.wait_once(self.conn, LIVE)
        self.assertEqual(code, lw.WAIT_EXIT_LINES)
        self.assertIn("Linear · state:TT-2290:completed", out.getvalue())


class ExpireCommand(ExpiryCase):
    def run_lw(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = lw.main(["expire", "--state-dir", str(self.state), *argv])
        return code, out.getvalue(), err.getvalue()

    def test_prints_one_line_per_closure_and_the_purge(self):
        self.add_sub(ARCHIVED)
        self.add_sub(GONE, kind="issue", target="TT-5")
        self.add_event(LIVE, "comment:old", delivered=timedelta(days=8))
        code, out, err = self.run_lw("--desktop-dir", str(DESKTOP))
        self.assertEqual(code, 0, err)
        lines = out.splitlines()
        self.assertIn(f"closed {ARCHIVED} project {PROJECT}: archived", lines)
        self.assertIn(f"closed {GONE} issue TT-5: session-gone", lines)
        self.assertIn("purged 1 delivered event(s) older than 7 days", lines)

    def test_desktop_dir_from_environment(self):
        self.add_sub(GONE)
        with mock.patch.dict(os.environ, {"LW_DESKTOP_DIR": str(DESKTOP)}):
            code, out, _ = self.run_lw()
        self.assertEqual(code, 0)
        self.assertIn(f"closed {GONE} project {PROJECT}: session-gone", out)

    def test_nothing_to_do(self):
        self.add_sub(LIVE)
        code, out, _ = self.run_lw("--desktop-dir", str(DESKTOP))
        self.assertEqual((code, out.strip()), (0, "nothing expired"))

    def test_desktop_file_content_never_reaches_output(self):
        for session in (ARCHIVED, ARCHIVED_PRIOR, LIVE, ARCHIVED_BUT_FORKED, GONE):
            self.add_sub(session)
        desktop = self.tmp / "desktop"
        shutil.copytree(DESKTOP, desktop)
        (desktop / "workspace-a" / "account-2" / "local_DECOY-broken.json").write_text("{DECOY")
        code, out, err = self.run_lw("--desktop-dir", str(desktop))
        self.assertEqual(code, 0, err)
        self.assertNotIn("DECOY", out + err)

    def test_bad_ttl_exits_2_with_a_message(self):
        with mock.patch.dict(os.environ, {"LW_TTL_DAYS": "soon"}):
            code, _, err = self.run_lw("--desktop-dir", str(DESKTOP))
        self.assertEqual(code, 2)
        self.assertIn("LW_TTL_DAYS", err)


if __name__ == "__main__":
    unittest.main()
