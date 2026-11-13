"""LW-3 — poll cycle: `lw daemon once` turns Linear changes into event rows.

Every call goes to the fake CLI in tests/bin/linear, which replays the real
payloads of LW-0 (2026-11-12, project 5842ed0c2bcd) cycle by cycle: the test
moves lw's clock and Linear's present (FAKE_LINEAR_NOW) together.
Run in Docker: bash skills/linear-tracker/tests/linear-watch/run-in-docker.sh test_cycle
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import shutil
import sqlite3
import tempfile
import time
import unittest
from datetime import datetime, timezone
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
from pathlib import Path
from unittest import mock

TESTS = Path(__file__).resolve().parent
LW_PATH = TESTS.parents[1] / "scripts" / "lw"
FAKE_LINEAR = TESTS / "bin" / "linear"
FIXTURES = TESTS / "fixtures" / "linear-real"


def load_lw():
    loader = SourceFileLoader("lw_cycle", str(LW_PATH))
    spec = spec_from_loader("lw_cycle", loader)
    module = module_from_spec(spec)
    loader.exec_module(module)
    return module


lw = load_lw()

# A made-up key in the real key's shape; only the fake ever accepts it.
TEST_KEY = "lin_api_TESTkey0123456789abcdefghijklmnopqrstuv"
PROJECT = "5842ed0c2bcd"
PROJECT_URL = "https://linear.app/septeo-proptech/project/redacted-name-5842ed0c2bcd/overview"
DAY = "2026-11-12"

# the newest comment of the fixture: TT-2537, Person A, 15:46:49.980Z
NEWEST_COMMENT = "c9dceae3-9888-4aa9-a5b2-2e812e96c9c3"
NEWEST_LINE = (
    "Linear · TT-2537 comment by Person A (15:46) · "
    "https://linear.app/septeo-proptech/issue/TT-2537"
)
# TT-207 is Todo (unstarted) in the fixture, updated 15:48:31.600Z
# a state move line ends with the project's graph path (LW-11); HOME is a temp dir here
TT207_LINE = ("Linear · TT-207 Blocked → Todo · https://linear.app/septeo-proptech/issue/TT-207"
              " · graph ~/linear-graphs/redacted-name.svg")


def at(hhmmss: str) -> datetime:
    return datetime.fromisoformat(f"{DAY}T{hhmmss}+00:00")


class CycleCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.state_dir = self.tmp / "state"
        self.log = self.tmp / "calls.jsonl"
        env = {
            "LW_LINEAR_BIN": str(FAKE_LINEAR),
            "LINEAR_API_KEY": TEST_KEY,
            "FAKE_LINEAR_LOG": str(self.log),
            "HOME": str(self.tmp / "home"),
            "TZ": "UTC",
        }
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)
        for var in ("FAKE_LINEAR_MODE", "FAKE_LINEAR_FIXTURE", "FAKE_LINEAR_FIXTURE_DIR",
                    "FAKE_LINEAR_FAIL_OPS", "FAKE_LINEAR_NOW", "LW_STATE_DIR"):
            os.environ.pop(var, None)
        time.tzset()
        self.addCleanup(time.tzset)
        lw.reset_linear_bin()

    def tearDown(self):
        self._tmp.cleanup()

    # ── helpers ───────────────────────────────────────────────────────────────
    @contextlib.contextmanager
    def clock(self, hhmmss: str):
        """lw's clock and Linear's present, both at DAY hhmmss UTC."""
        t = at(hhmmss)
        with mock.patch.object(lw, "now", return_value=t), \
                mock.patch.dict(os.environ, {"FAKE_LINEAR_NOW": t.strftime("%Y-%m-%dT%H:%M:%SZ")}):
            yield

    def run_lw(self, hhmmss: str, *args: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with self.clock(hhmmss), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = lw.main(["--state-dir", str(self.state_dir), *args])
        return code, out.getvalue(), err.getvalue()

    def ok(self, hhmmss: str, *args: str) -> str:
        code, out, err = self.run_lw(hhmmss, *args)
        self.assertEqual(code, 0, f"lw {' '.join(args)} failed: {out}{err}")
        return out

    def cycle(self, hhmmss: str) -> str:
        return self.ok(hhmmss, "daemon", "once")

    def subscribe(self, hhmmss: str, session: str, *target: str) -> None:
        self.ok(hhmmss, "subscribe", "--session", session, *target)

    def db(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.state_dir / "lw.sqlite")
        conn.row_factory = sqlite3.Row
        self.addCleanup(conn.close)
        return conn

    def lines(self, session: str = "s1") -> list[str]:
        return [r["text"] for r in self.db().execute(
            "SELECT text FROM events WHERE session = ? ORDER BY ts, id", (session,))]

    def cursor(self, kind: str, target: str) -> str | None:
        row = self.db().execute(
            "SELECT last_seen FROM cursors WHERE kind = ? AND target = ?", (kind, target)).fetchone()
        return row["last_seen"] if row else None

    def calls(self) -> list[dict]:
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def edited_fixtures(self, identifier: str, *, name: str, type_: str, updated: str) -> Path:
        """A copy of the real fixtures where one issue sits in another state."""
        target = self.tmp / f"fixtures-{len(list(self.tmp.glob('fixtures-*')))}"
        shutil.copytree(FIXTURES, target)
        path = target / "issues-updated-since.json"
        body = json.loads(path.read_text())
        for node in body["data"]["issues"]["nodes"]:
            if node["identifier"] == identifier:
                node["state"].update(name=name, type=type_)
                node["updatedAt"] = updated
        path.write_text(json.dumps(body))
        return target

    def baseline_tt207_blocked(self) -> None:
        """Subscribe s1 to the project at 15:20 and see TT-207 as Blocked."""
        self.subscribe("15:20:00", "s1", "--project", PROJECT_URL)
        blocked = self.edited_fixtures("TT-207", name="Blocked", type_="started",
                                       updated="2026-11-12T15:10:00.000Z")
        with mock.patch.dict(os.environ, {"FAKE_LINEAR_FIXTURE_DIR": str(blocked)}):
            self.cycle("15:20:00")
        self.assertEqual(self.lines(), [])


class ProjectCommentsTest(CycleCase):
    def test_first_cycle_is_a_silent_baseline(self):
        self.subscribe("15:40:00", "s1", "--project", PROJECT_URL)
        self.cycle("15:40:00")
        self.assertEqual(self.lines(), [])
        self.assertEqual(self.cursor("project", PROJECT), f"{DAY}T15:40:00Z")
        states = dict(self.db().execute("SELECT identifier, state FROM issue_states").fetchall())
        self.assertEqual(states.get("TT-2445"), "Backlog")  # updated 15:32, open: in the baseline

    def test_new_foreign_comment_gives_one_line(self):
        self.subscribe("15:40:00", "s1", "--project", PROJECT_URL)
        self.cycle("15:40:00")
        out = self.cycle("15:50:00")
        self.assertEqual(self.lines(), [NEWEST_LINE])
        self.assertIn("1 line", out)

    def test_same_comment_next_cycle_gives_nothing(self):
        self.subscribe("15:40:00", "s1", "--project", PROJECT_URL)
        self.cycle("15:40:00")
        self.cycle("15:47:30")
        self.assertEqual(self.lines(), [NEWEST_LINE])
        # the next bound is 15:45:30 (cursor − 120 s): the 15:46:49 comment is
        # fetched again and must not give a second row
        self.cycle("15:52:00")
        self.assertEqual(self.lines(), [NEWEST_LINE])
        comment_calls = [c for c in self.calls() if "CommentsSince" in c["stdin"]]
        self.assertEqual(json.loads(comment_calls[-1]["argv"][2])["since"], f"{DAY}T15:45:30Z")

    def test_own_comment_gives_nothing(self):
        self.subscribe("15:40:00", "s1", "--project", PROJECT_URL)
        self.cycle("15:40:00")
        self.ok("15:46:50", "own-write", "--comment", NEWEST_COMMENT)
        self.cycle("15:50:00")
        self.assertEqual(self.lines(), [])

    def test_since_delivers_older_comments_once(self):
        self.ok("15:40:00", "subscribe", "--session", "s1", "--project", PROJECT, "--since", "3d")
        self.cycle("15:40:00")
        first = self.lines()
        # all 31 comments of the day but the 15:46 one, which Linear has not seen yet
        self.assertEqual(len(first), 30)
        self.assertIn("Linear · TT-1068 comment by Person B (08:44) · "
                      "https://linear.app/septeo-proptech/issue/TT-1068", first)
        self.cycle("15:45:00")
        self.assertEqual(self.lines(), first)
        self.cycle("15:50:00")
        self.assertEqual(self.lines(), first + [NEWEST_LINE])

    def test_since_on_a_target_already_watched_backfills_the_newcomer_only(self):
        self.subscribe("15:20:00", "s1", "--project", PROJECT_URL)
        self.cycle("15:20:00")
        self.ok("15:30:00", "subscribe", "--session", "s2", "--project", PROJECT, "--since", "1d")
        self.cycle("15:30:00")
        # s1 only hears what came after its own subscription (15:26:11);
        # s2 gets the day's 30 comments Linear knows at 15:30
        self.assertEqual(len(self.lines("s1")), 1)
        self.assertEqual(len(self.lines("s2")), 30)
        self.cycle("15:35:00")
        self.assertEqual(len(self.lines("s1")), 1)
        self.assertEqual(len(self.lines("s2")), 30)

    def test_comment_older_than_the_subscription_is_not_delivered(self):
        # s1 watches since 15:20, s2 subscribes at 15:46:00 without --since,
        # a minute before the 15:46:49 comment: only that comment reaches s2
        self.subscribe("15:20:00", "s1", "--project", PROJECT_URL)
        self.cycle("15:20:00")
        self.subscribe("15:46:00", "s2", "--project", PROJECT_URL)
        self.cycle("15:50:00")
        self.assertEqual(len(self.lines("s1")), 2)  # 15:26:11 and 15:46:49
        self.assertEqual(self.lines("s2"), [NEWEST_LINE])

    def test_closed_subscription_gets_nothing(self):
        self.subscribe("15:40:00", "s1", "--project", PROJECT_URL)
        self.cycle("15:40:00")
        self.ok("15:41:00", "unsubscribe", "--session", "s1", "--all")
        self.cycle("15:50:00")
        self.assertEqual(self.lines(), [])

    def test_every_open_subscription_gets_the_line(self):
        self.subscribe("15:40:00", "s1", "--project", PROJECT_URL)
        self.subscribe("15:40:00", "s2", "--project", PROJECT)
        self.cycle("15:40:00")
        self.cycle("15:50:00")
        self.assertEqual(self.lines("s1"), [NEWEST_LINE])
        self.assertEqual(self.lines("s2"), [NEWEST_LINE])


class StateTransitionTest(CycleCase):
    def test_blocked_to_todo_gives_one_line(self):
        self.baseline_tt207_blocked()
        self.cycle("15:50:00")
        state_lines = [line for line in self.lines() if "→" in line]
        self.assertEqual(state_lines, [TT207_LINE])
        row = self.db().execute(
            "SELECT state, state_type FROM issue_states WHERE identifier = 'TT-207'").fetchone()
        self.assertEqual(tuple(row), ("Todo", "unstarted"))
        self.cycle("15:52:00")  # seen again in the overlap: no second line
        self.assertEqual([line for line in self.lines() if "→" in line], [TT207_LINE])

    def test_own_state_move_gives_nothing(self):
        self.baseline_tt207_blocked()
        self.ok("15:48:32", "own-write", "--issue", "TT-207", "--state", "Todo")
        self.cycle("15:50:00")
        self.assertEqual([line for line in self.lines() if "→" in line], [])

    def test_stale_own_state_row_does_not_hide_a_later_move(self):
        # the agent moved TT-207 to Todo at 15:00, someone moved it to Blocked
        # at 15:10 (seen by the baseline), then a human moved it back to Todo
        self.ok("15:00:00", "own-write", "--issue", "TT-207", "--state", "Todo")
        self.baseline_tt207_blocked()
        self.cycle("15:50:00")
        self.assertEqual([line for line in self.lines() if "→" in line], [TT207_LINE])

    def test_an_issue_unknown_until_now_is_recorded_silently(self):
        self.subscribe("15:40:00", "s1", "--project", PROJECT_URL)
        self.cycle("15:40:00")
        self.cycle("15:50:00")
        self.assertEqual([line for line in self.lines() if "→" in line], [])
        # TT-2549 (updated 15:49:23) was not in the 15:40 baseline
        known = self.db().execute(
            "SELECT state FROM issue_states WHERE identifier = 'TT-2549'").fetchone()
        self.assertEqual(known["state"], "Backlog")

    def test_project_and_issue_subscribers_both_get_the_transition(self):
        self.subscribe("15:20:00", "s2", "--issue", "TT-207")
        self.baseline_tt207_blocked()
        self.cycle("15:50:00")
        self.assertEqual([line for line in self.lines("s1") if "→" in line], [TT207_LINE])
        self.assertEqual(self.lines("s2"), [TT207_LINE])


class IssueSubscriptionTest(CycleCase):
    def test_issue_comment_gives_one_line(self):
        self.subscribe("15:40:00", "s1", "--issue", "TT-2537")
        self.cycle("15:40:00")
        self.assertEqual(self.lines(), [])
        self.cycle("15:50:00")
        self.assertEqual(self.lines(), [NEWEST_LINE])
        self.assertEqual(self.cursor("issue", "TT-2537"), f"{DAY}T15:50:00Z")

    def test_issue_subscriptions_share_one_query(self):
        self.subscribe("15:40:00", "s1", "--issue", "TT-2537")
        self.subscribe("15:40:00", "s1", "--issue", "TT-2519")
        self.subscribe("15:40:00", "s2", "--issue", "TT-207")
        self.cycle("15:40:00")
        watched = [c for c in self.calls() if "WatchedIssues" in c["stdin"]]
        self.assertEqual(len(watched), 1)
        self.assertEqual(sorted(json.loads(watched[0]["argv"][2])["ids"]),
                         ["TT-207", "TT-2519", "TT-2537"])

    def test_since_on_an_issue_delivers_its_older_comments_once(self):
        self.ok("15:40:00", "subscribe", "--session", "s1", "--issue", "TT-2519", "--since", "1d")
        self.cycle("15:40:00")
        self.assertEqual(self.lines(), [
            "Linear · TT-2519 comment by Person A (13:09) · https://linear.app/septeo-proptech/issue/TT-2519",
            "Linear · TT-2519 comment by Person A (13:19) · https://linear.app/septeo-proptech/issue/TT-2519",
            "Linear · TT-2519 comment by Person A (14:25) · https://linear.app/septeo-proptech/issue/TT-2519",
        ])
        self.cycle("15:45:00")
        self.assertEqual(len(self.lines()), 3)

    def test_issue_state_transition(self):
        self.subscribe("15:20:00", "s1", "--issue", "TT-207")
        blocked = self.edited_fixtures("TT-207", name="Blocked", type_="started",
                                       updated="2026-11-12T15:10:00.000Z")
        with mock.patch.dict(os.environ, {"FAKE_LINEAR_FIXTURE_DIR": str(blocked)}):
            self.cycle("15:20:00")
        self.cycle("15:50:00")
        self.assertEqual(self.lines(), [TT207_LINE])


    def test_an_older_observation_never_moves_the_state_back(self):
        self.subscribe("15:50:00", "s1", "--issue", "TT-207")
        self.cycle("15:50:00")  # TT-207 known as Todo, updated 15:48:31
        stale = self.edited_fixtures("TT-207", name="Blocked", type_="started",
                                     updated="2026-11-12T15:10:00.000Z")
        with mock.patch.dict(os.environ, {"FAKE_LINEAR_FIXTURE_DIR": str(stale)}):
            self.cycle("15:55:00")
        self.assertEqual(self.lines(), [])
        state = self.db().execute("SELECT state FROM issue_states WHERE identifier = 'TT-207'").fetchone()
        self.assertEqual(state["state"], "Todo")


class FailureTest(CycleCase):
    def test_transport_error_keeps_the_cursor(self):
        self.subscribe("15:40:00", "s1", "--project", PROJECT_URL)
        self.cycle("15:40:00")
        with mock.patch.dict(os.environ, {"FAKE_LINEAR_MODE": "unreachable"}):
            code, out, err = self.run_lw("15:50:00", "daemon", "once")
        self.assertEqual(code, 1)
        self.assertIn("Connection refused", err)
        self.assertEqual(self.cursor("project", PROJECT), f"{DAY}T15:40:00Z")
        self.assertEqual(self.lines(), [])
        status = lw.read_transport_status(self.state_dir)
        self.assertEqual(status["last_error"]["code"], lw.T_OTHER)
        # late, never lost: the next good cycle delivers the missed comment
        self.cycle("15:55:00")
        self.assertEqual(self.lines(), [NEWEST_LINE])
        self.assertEqual(self.cursor("project", PROJECT), f"{DAY}T15:55:00Z")

    def test_one_failed_query_writes_nothing_for_its_target(self):
        self.baseline_tt207_blocked()
        with mock.patch.dict(os.environ, {"FAKE_LINEAR_FAIL_OPS": "IssuesUpdatedSince"}):
            code, _, _ = self.run_lw("15:50:00", "daemon", "once")
        self.assertEqual(code, 1)
        self.assertEqual(self.lines(), [])  # the comments query succeeded, but nothing lands
        self.assertEqual(self.cursor("project", PROJECT), f"{DAY}T15:20:00Z")
        state = self.db().execute("SELECT state FROM issue_states WHERE identifier = 'TT-207'").fetchone()
        self.assertEqual(state["state"], "Blocked")
        self.cycle("15:55:00")
        self.assertIn(TT207_LINE, self.lines())
        self.assertIn(NEWEST_LINE, self.lines())

    def test_first_sight_failure_leaves_no_cursor(self):
        self.subscribe("15:40:00", "s1", "--issue", "TT-2537")
        with mock.patch.dict(os.environ, {"FAKE_LINEAR_MODE": "unauthenticated"}):
            code, _, err = self.run_lw("15:40:00", "daemon", "once")
        self.assertEqual(code, 1)
        self.assertIn("code 10", err)
        self.assertIsNone(self.cursor("issue", "TT-2537"))

    def test_a_failed_project_does_not_block_another_target(self):
        self.subscribe("15:40:00", "s1", "--project", PROJECT_URL)
        self.subscribe("15:40:00", "s2", "--issue", "TT-2537")
        self.cycle("15:40:00")
        with mock.patch.dict(os.environ, {"FAKE_LINEAR_FAIL_OPS": "CommentsSince"}):
            code, _, _ = self.run_lw("15:50:00", "daemon", "once")
        self.assertEqual(code, 1)
        self.assertEqual(self.lines("s2"), [NEWEST_LINE])
        # the issue path saw the comment of the project: s1 hears it too
        self.assertEqual(self.lines("s1"), [NEWEST_LINE])
        self.assertEqual(self.cursor("project", PROJECT), f"{DAY}T15:40:00Z")


class HygieneTest(CycleCase):
    def test_nothing_watched_calls_nothing(self):
        out = self.cycle("15:40:00")
        self.assertEqual(self.calls(), [])
        self.assertIn("nothing watched", out)

    def test_no_query_asks_for_a_body_and_no_key_on_argv(self):
        self.subscribe("15:40:00", "s1", "--project", PROJECT_URL)
        self.subscribe("15:40:00", "s1", "--issue", "TT-2537")
        self.cycle("15:40:00")
        self.cycle("15:50:00")
        calls = self.calls()
        operations = {lw._operation_name(c["stdin"]) for c in calls}
        self.assertEqual(operations, {"CommentsSince", "IssuesUpdatedSince",
                                      "ProjectIssueStates", "WatchedIssues"})
        for call in calls:
            self.assertNotIn("body", call["stdin"])
            self.assertNotIn(TEST_KEY, json.dumps(call["argv"]))
        for line in self.lines():
            self.assertTrue(line.startswith("Linear · "), line)

    def test_pagination_follows_end_cursor(self):
        # issues-updated-since.json is a real first page (hasNextPage: true)
        self.subscribe("15:40:00", "s1", "--project", PROJECT_URL)
        self.cycle("15:40:00")
        self.cycle("15:50:00")
        pages = [json.loads(c["argv"][2]) for c in self.calls() if "IssuesUpdatedSince" in c["stdin"]]
        self.assertEqual([p.get("after") for p in pages],
                         [None, "fe8e634d-afce-4a18-98b5-a9e1f09429d6"])

    def test_wake_line_neutralizes_third_party_text(self):
        self.assertEqual(lw.clean_text("Jane\n\x1b[31mDoe\t  "), "Jane [31mDoe")
        self.assertEqual(lw.issue_link("TT-2287", "https://linear.app/ws/issue/TT-2287/some-title"),
                         "https://linear.app/ws/issue/TT-2287")
        self.assertEqual(lw.issue_link("TT-2287", "javascript:alert(1)"), "")


class DoneStateTypesTest(unittest.TestCase):
    """The poll's GraphQL list and the expiry's tuple are two constants, not one name."""

    def test_baseline_query_excludes_finished_issues(self):
        self.assertIn('nin: ["completed", "canceled"]', lw.PROJECT_BASELINE_QUERY)

    def test_expiry_keeps_its_tuple(self):
        self.assertEqual(lw.DONE_STATE_TYPES, ("completed", "canceled"))
        self.assertEqual(lw.DONE_STATE_TYPES_GRAPHQL, '["completed", "canceled"]')


if __name__ == "__main__":
    unittest.main()
