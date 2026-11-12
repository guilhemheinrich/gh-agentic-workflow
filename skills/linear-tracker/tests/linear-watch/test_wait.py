"""LW-4 — delivery: `lw wait`.

Built against hand-written event rows: the poll cycle (LW-3) is not needed.
Run in Docker: bash skills/linear-tracker/tests/linear-watch/run-in-docker.sh test_wait
"""

from __future__ import annotations

import contextlib
import fcntl
import io
import os
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
from pathlib import Path
from unittest import mock

LW_PATH = Path(__file__).resolve().parents[2] / "scripts" / "lw"


def load_lw():
    loader = SourceFileLoader("lw", str(LW_PATH))
    spec = spec_from_loader("lw", loader)
    module = module_from_spec(spec)
    loader.exec_module(module)
    return module


lw = load_lw()

POLL = "0.05"
OLD = "2020-01-01T00:00:00Z"
LINE_1 = "Linear · TT-2287 comment by Jane Doe (08:44) · https://linear.app/septeo-proptech/issue/TT-2287"
LINE_2 = "Linear · TT-2290 Blocked → Todo · https://linear.app/septeo-proptech/issue/TT-2290"


class WaitTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state_dir = Path(self._tmp.name) / "state"
        self.db = self.state_dir / "lw.sqlite"
        patcher = mock.patch.dict(os.environ, {"LW_WAIT_POLL": POLL})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.children: list[subprocess.Popen] = []

    def tearDown(self):
        for child in self.children:
            if child.poll() is None:
                child.kill()
            child.wait(timeout=10)
            for stream in (child.stdout, child.stderr):
                if stream:
                    stream.close()
        self._tmp.cleanup()

    # every in-process wait passes --timeout: a failing test must not hang
    def run_lw(self, *args: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = lw.main(["--state-dir", str(self.state_dir), *args])
        return code, out.getvalue(), err.getvalue()

    def ok(self, *args: str) -> str:
        code, out, err = self.run_lw(*args)
        self.assertEqual(code, 0, f"lw {' '.join(args)} failed: {err}")
        return out

    def wait(self, session: str = "s1", timeout: str = "0") -> tuple[int, str, str]:
        return self.run_lw("wait", "--session", session, "--timeout", timeout)

    def spawn_wait(self, session: str = "s1", timeout: str = "30") -> subprocess.Popen:
        env = {**os.environ, "LW_STATE_DIR": str(self.state_dir), "LW_WAIT_POLL": POLL}
        child = subprocess.Popen(
            [sys.executable, str(LW_PATH), "wait", "--session", session, "--timeout", timeout],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        self.children.append(child)
        return child

    def sql(self, statement: str, params=()) -> list[sqlite3.Row]:
        conn = sqlite3.connect(self.db, timeout=5)
        conn.row_factory = sqlite3.Row
        try:
            rows = conn.execute(statement, params).fetchall()
            conn.commit()
            return rows
        finally:
            conn.close()

    def add_event(self, event_id: str, text: str, session: str = "s1", ts: str = "2026-11-12T08:44:31Z"):
        self.sql(
            "INSERT INTO events (id, session, ts, text) VALUES (?, ?, ?, ?)",
            (event_id, session, ts, text),
        )

    def subscribe(self, session: str = "s1", issue: str = "TT-2287"):
        self.ok("subscribe", "--session", session, "--issue", issue)

    def lock_path(self, session: str = "s1") -> Path:
        return self.state_dir / "waits" / f"{session}.lock"

    def wait_until_locked(self, session: str = "s1", deadline: float = 10.0):
        """Block until a child holds the session's wait lock (no blind sleep)."""
        path, end = self.lock_path(session), time.monotonic() + deadline
        while time.monotonic() < end:
            if path.exists():
                with open(path, "a") as handle:
                    try:
                        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError:
                        return
                    fcntl.flock(handle, fcntl.LOCK_UN)
            time.sleep(0.02)
        self.fail(f"no wait took {path} within {deadline}s")


class TestDelivery(WaitTestCase):
    """Exit 0: undelivered lines are printed once, in order, then marked."""

    def test_prints_pending_lines_in_ts_order_and_exits_0(self):
        self.subscribe()
        self.add_event("state:TT-2290:1", LINE_2, ts="2026-11-12T09:00:00Z")
        self.add_event("comment:c1", LINE_1, ts="2026-11-12T08:44:31Z")
        code, out, err = self.wait()
        self.assertEqual(code, 0, err)
        lines = out.splitlines()
        self.assertEqual(lines[:2], [LINE_1, LINE_2])
        delivered = self.sql("SELECT delivered_at FROM events")
        self.assertTrue(all(r["delivered_at"] for r in delivered))

    def test_a_line_is_delivered_only_once(self):
        self.subscribe()
        self.add_event("comment:c1", LINE_1)
        self.assertEqual(self.wait()[0], 0)
        code, out, _ = self.wait()
        self.assertEqual(code, 2)
        self.assertNotIn(LINE_1, out)

    def test_other_sessions_lines_are_not_delivered(self):
        self.subscribe("s1")
        self.subscribe("s2")
        self.add_event("comment:c1", LINE_1, session="s2")
        code, out, _ = self.wait("s1")
        self.assertEqual(code, 2)
        self.assertEqual(out, "")
        undelivered = self.sql("SELECT * FROM events WHERE delivered_at IS NULL")
        self.assertEqual(len(undelivered), 1)

    def test_still_watching_line_when_subscriptions_remain(self):
        self.subscribe()
        self.add_event("comment:c1", LINE_1)
        _, out, _ = self.wait()
        last = out.splitlines()[-1]
        self.assertIn("still watching", last)
        self.assertIn("lw wait --session s1", last)
        self.assertIn("again", last)

    def test_last_lines_after_the_subscription_closed_then_exit_3(self):
        # issue-done lifecycle: the transition is delivered, then closed
        self.subscribe()
        self.add_event("state:TT-2287:1", LINE_2)
        self.ok("unsubscribe", "--session", "s1", "--all")
        code, out, _ = self.wait()
        self.assertEqual(code, 0)
        self.assertEqual(out.splitlines(), [LINE_2])
        self.assertNotIn("still watching", out)
        code, out, _ = self.wait()
        self.assertEqual(code, 3)

    def test_a_line_written_during_the_wait_wakes_it(self):
        self.subscribe()
        child = self.spawn_wait()
        self.wait_until_locked()
        self.add_event("comment:c1", LINE_1)
        out, err = child.communicate(timeout=20)
        self.assertEqual(child.returncode, 0, err)
        self.assertEqual(out.splitlines()[0], LINE_1)


class TestTimeout(WaitTestCase):
    def test_timeout_exits_2_silently(self):
        self.subscribe()
        started = time.monotonic()
        code, out, err = self.wait(timeout="0.3")
        self.assertEqual(code, 2)
        self.assertGreaterEqual(time.monotonic() - started, 0.25)
        self.assertEqual((out, err), ("", ""))

    def test_timeout_zero_polls_once(self):
        self.subscribe()
        self.assertEqual(self.wait(timeout="0")[0], 2)


class TestNothingSubscribed(WaitTestCase):
    def test_no_subscription_at_all_exits_3(self):
        code, out, _ = self.wait(timeout="5")
        self.assertEqual(code, 3)
        self.assertIn("no open subscription", out)

    def test_only_closed_subscriptions_exits_3(self):
        self.subscribe()
        self.ok("unsubscribe", "--session", "s1", "--all")
        self.assertEqual(self.wait(timeout="5")[0], 3)

    def test_unsubscribing_during_the_wait_ends_it_with_3(self):
        self.subscribe()
        child = self.spawn_wait()
        self.wait_until_locked()
        self.ok("unsubscribe", "--session", "s1", "--all")
        out, err = child.communicate(timeout=20)
        self.assertEqual(child.returncode, 3, err)
        self.assertIn("no open subscription", out)


class TestConcurrentWaits(WaitTestCase):
    def test_second_wait_for_the_same_session_exits_4(self):
        self.subscribe()  # the store exists before any child opens it
        first = self.spawn_wait()
        self.wait_until_locked()
        code, out, _ = self.wait(timeout="5")
        self.assertEqual(code, 4)
        self.assertIn("already waiting", out)
        self.assertIn(str(first.pid), out)
        # the refused wait delivered nothing: the first one still gets the line
        self.add_event("comment:c1", LINE_1)
        out, err = first.communicate(timeout=20)
        self.assertEqual(first.returncode, 0, err)
        self.assertIn(LINE_1, out)

    def test_another_session_is_not_blocked(self):
        self.subscribe("s1")
        self.subscribe("s2")
        self.spawn_wait("s1")
        self.wait_until_locked("s1")
        self.assertEqual(self.wait("s2")[0], 2)

    def test_lock_of_a_killed_wait_does_not_block(self):
        self.subscribe()
        first = self.spawn_wait()
        self.wait_until_locked()
        first.send_signal(signal.SIGKILL)
        first.wait(timeout=10)
        self.assertTrue(self.lock_path().exists())
        self.assertEqual(self.wait()[0], 2)

    def test_session_id_is_sanitized_in_the_lock_name(self):
        self.subscribe("../evil/s")
        self.assertEqual(self.wait("../evil/s")[0], 2)
        locks = list((self.state_dir / "waits").iterdir())
        self.assertEqual(len(locks), 1)
        self.assertNotIn("/", locks[0].name)
        self.assertFalse((self.state_dir.parent / "evil").exists())


class TestRenewal(WaitTestCase):
    def age_all(self):
        self.sql("UPDATE subscriptions SET renewed_at = ?", (OLD,))

    def renewed(self, session: str = "s1", closed: bool = False) -> list[str]:
        cond = "IS NOT NULL" if closed else "IS NULL"
        return [
            r["renewed_at"]
            for r in self.sql(
                f"SELECT renewed_at FROM subscriptions WHERE session = ? AND closed_at {cond}",
                (session,),
            )
        ]

    def test_wait_renews_only_the_sessions_open_subscriptions(self):
        self.subscribe("s1", "TT-1")
        self.subscribe("s1", "TT-2")
        self.ok("unsubscribe", "--session", "s1", "--issue", "TT-2")
        self.subscribe("s1", "TT-3")
        self.subscribe("s2", "TT-1")
        self.age_all()
        self.assertEqual(self.wait("s1")[0], 2)
        self.assertTrue(all(ts != OLD for ts in self.renewed("s1")), self.renewed("s1"))
        self.assertEqual(self.renewed("s1", closed=True), [OLD])
        self.assertEqual(self.renewed("s2"), [OLD])

    def test_a_running_wait_keeps_renewing(self):
        self.subscribe()
        child = self.spawn_wait()
        self.wait_until_locked()
        self.age_all()
        end = time.monotonic() + 10
        while self.renewed() == [OLD] and time.monotonic() < end:
            time.sleep(0.05)
        self.assertNotEqual(self.renewed(), [OLD])
        child.kill()

    def test_refused_wait_does_not_renew(self):
        self.subscribe()
        self.spawn_wait()
        self.wait_until_locked()
        with mock.patch.object(lw, "renew_subscriptions") as renew:
            self.assertEqual(self.wait(timeout="5")[0], 4)
        renew.assert_not_called()


class TestCli(WaitTestCase):
    def test_session_is_required(self):
        with self.assertRaises(SystemExit) as raised, contextlib.redirect_stderr(io.StringIO()):
            lw.main(["--state-dir", str(self.state_dir), "wait"])
        self.assertEqual(raised.exception.code, 2)

    def test_negative_timeout_is_refused(self):
        code, _, err = self.run_lw("wait", "--session", "s1", "--timeout", "-1")
        self.assertEqual(code, 2)
        self.assertIn("timeout", err)

    def test_bad_poll_interval_is_refused(self):
        with mock.patch.dict(os.environ, {"LW_WAIT_POLL": "soon"}):
            code, _, err = self.run_lw("wait", "--session", "s1", "--timeout", "0")
        self.assertEqual(code, 2)
        self.assertIn("LW_WAIT_POLL", err)


if __name__ == "__main__":
    unittest.main()
