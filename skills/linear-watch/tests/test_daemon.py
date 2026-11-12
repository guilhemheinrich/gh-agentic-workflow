"""LW-7 — `lw daemon run|start|stop|alive`, the daemon under launchd.

The loop is driven with `--cycles N` and a tiny LW_POLL_SECONDS; every Linear
call goes to the fake CLI in tests/bin/linear. `launchctl` is a stub written
into a temp dir put first on PATH: it records its argv and never touches
launchd. The re-exec is observed by patching os.execv.
Run in Docker: bash skills/linear-watch/tests/run-in-docker.sh test_daemon
"""

from __future__ import annotations

import contextlib
import io
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import timedelta
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
from pathlib import Path
from unittest import mock

TESTS = Path(__file__).resolve().parent
LW_PATH = TESTS.parent / "scripts" / "lw"
FAKE_LINEAR = TESTS / "bin" / "linear"


def load_lw():
    loader = SourceFileLoader("lw_daemon", str(LW_PATH))
    spec = spec_from_loader("lw_daemon", loader)
    module = module_from_spec(spec)
    loader.exec_module(module)
    return module


lw = load_lw()

# A made-up key in the real key's shape; only the fake ever accepts it.
TEST_KEY = "lin_api_TESTkey0123456789abcdefghijklmnopqrstuv"
PROJECT = "5842ed0c2bcd"

LAUNCHCTL_STUB = """#!/bin/sh
# records one JSON-ish line per call; exits $LAUNCHCTL_STUB_RC for bootstrap
printf '%s\\n' "$*" >>"$LAUNCHCTL_LOG"
case "$1" in
  bootstrap) exit "${LAUNCHCTL_STUB_RC:-0}" ;;
  bootout) exit "${LAUNCHCTL_BOOTOUT_RC:-0}" ;;
esac
exit 0
"""


class Exec(Exception):
    """Raised by the patched os.execv to stop the loop where it would re-exec."""


class DaemonCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.state = self.tmp / "state"
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.launchctl_log = self.tmp / "launchctl.log"
        stub = self.bin / "launchctl"
        stub.write_text(LAUNCHCTL_STUB)
        stub.chmod(0o755)
        env = {
            "HOME": str(self.home),
            "LW_STATE_DIR": str(self.state),
            "LW_LINEAR_BIN": str(FAKE_LINEAR),
            "LINEAR_API_KEY": TEST_KEY,
            "FAKE_LINEAR_KEY": TEST_KEY,
            "LW_POLL_SECONDS": "0.01",
            "LW_DESKTOP_DIR": str(self.tmp / "no-desktop"),
            "LAUNCHCTL_LOG": str(self.launchctl_log),
            "PATH": f"{self.bin}{os.pathsep}{os.environ.get('PATH', '')}",
        }
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)
        for var in ("FAKE_LINEAR_MODE", "FAKE_LINEAR_FIXTURE", "FAKE_LINEAR_FAIL_OPS",
                    "LW_TTL_DAYS", "LW_ALLOW_CHECKOUT", "LAUNCHCTL_STUB_RC"):
            os.environ.pop(var, None)
        lw.reset_linear_bin()
        self.addCleanup(lw.reset_linear_bin)
        # An installed copy: a path with no .git above it and no /worktrees/.
        self.installed = self.tmp / "installed" / "skills" / "linear-watch" / "scripts" / "lw"
        self.installed.parent.mkdir(parents=True)
        self.installed.write_text("# stand-in for the installed lw\n")
        patcher = mock.patch.object(lw, "LW_SCRIPT", str(self.installed))
        patcher.start()
        self.addCleanup(patcher.stop)

    def lw(self, *argv: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = lw.main(list(argv))
        return code, out.getvalue(), err.getvalue()

    def log_lines(self) -> list[str]:
        path = self.state / lw.DAEMON_LOG
        return path.read_text().splitlines() if path.exists() else []

    def cycle_lines(self) -> list[str]:
        return [line for line in self.log_lines() if " cycle " in f" {line} "]

    def launchctl_calls(self) -> list[str]:
        if not self.launchctl_log.exists():
            return []
        return self.launchctl_log.read_text().splitlines()

    def beat(self, age: float):
        self.state.mkdir(parents=True, exist_ok=True)
        path = self.state / lw.HEARTBEAT_FILE
        path.touch()
        t = time.time() - age
        os.utime(path, (t, t))

    def subscribe(self, *argv: str):
        code, _, err = self.lw("subscribe", *argv)
        self.assertEqual(code, 0, err)


class HeartbeatTest(DaemonCase):
    def test_run_writes_the_heartbeat_doctor_reads(self):
        code, _, err = self.lw("daemon", "run", "--cycles", "1")
        self.assertEqual(code, 0, err)
        age = lw.heartbeat_age(self.state)
        self.assertIsNotNone(age)
        self.assertLess(age, 5)
        os.environ["LW_POLL_SECONDS"] = "300"  # doctor's limit, not the test cadence
        conn = lw.connect(self.state)
        self.addCleanup(conn.close)
        beat = [c for c in lw.doctor_checks(conn, self.state) if "heartbeat" in c[1]]
        self.assertEqual(beat[0][0], "ok", beat)

    def test_the_heartbeat_is_refreshed_each_cycle(self):
        self.beat(age=3600)
        code, _, err = self.lw("daemon", "run", "--cycles", "1")
        self.assertEqual(code, 0, err)
        self.assertLess(lw.heartbeat_age(self.state), 5)

    def test_a_failing_cycle_still_beats(self):
        self.beat(age=3600)
        with mock.patch.object(lw, "run_cycle", side_effect=RuntimeError("boom")):
            code, _, err = self.lw("daemon", "run", "--cycles", "1")
        self.assertEqual(code, 0, err)
        self.assertLess(lw.heartbeat_age(self.state), 5)


class AliveTest(DaemonCase):
    def test_a_fresh_heartbeat_is_alive(self):
        self.beat(age=0)
        code, out, _ = self.lw("daemon", "alive")
        self.assertEqual(code, 0)
        self.assertIn("alive", out)

    def test_a_heartbeat_older_than_three_intervals_is_dead(self):
        os.environ["LW_POLL_SECONDS"] = "100"
        self.beat(age=250)
        self.assertEqual(self.lw("daemon", "alive")[0], 0)
        self.beat(age=310)
        code, out, _ = self.lw("daemon", "alive")
        self.assertEqual(code, 1)
        self.assertIn("not alive", out)

    def test_no_heartbeat_is_dead(self):
        code, out, _ = self.lw("daemon", "alive")
        self.assertEqual(code, 1)
        self.assertIn("never", out)


class CycleOrderTest(DaemonCase):
    def test_expiry_runs_before_the_poll(self):
        calls: list[str] = []
        real_expire, real_cycle = lw.expire_subscriptions, lw.run_cycle

        def expire(*a, **k):
            calls.append("expire")
            return real_expire(*a, **k)

        def cycle(*a, **k):
            calls.append("poll")
            return real_cycle(*a, **k)

        with mock.patch.object(lw, "expire_subscriptions", side_effect=expire), \
                mock.patch.object(lw, "run_cycle", side_effect=cycle):
            code, _, err = self.lw("daemon", "run", "--cycles", "2")
        self.assertEqual(code, 0, err)
        self.assertEqual(calls, ["expire", "poll", "expire", "poll"])

    def test_an_expired_subscription_is_not_polled(self):
        # ttl: renewed long ago -> closed by expiry, so the poll watches nothing
        self.subscribe("--session", "s-old", "--project", PROJECT)
        conn = lw.connect(self.state)
        self.addCleanup(conn.close)
        old = lw.fmt(lw.now() - timedelta(days=30))
        conn.execute("UPDATE subscriptions SET renewed_at = ?", (old,))
        os.environ["LW_LINEAR_BIN"] = str(self.tmp / "no-such-linear")  # a call would fail
        code, _, err = self.lw("daemon", "run", "--cycles", "1")
        self.assertEqual(code, 0, err)
        row = conn.execute("SELECT close_reason FROM subscriptions").fetchone()
        self.assertEqual(row["close_reason"], "ttl")
        [line] = self.cycle_lines()
        self.assertIn("expired 1", line)
        self.assertIn("nothing watched", line)
        self.assertNotIn("failed", line)


class LoopSurvivesTest(DaemonCase):
    def test_a_raising_cycle_does_not_kill_the_loop(self):
        outcomes = [RuntimeError("boom"), lw.CycleResult()]
        with mock.patch.object(lw, "run_cycle", side_effect=outcomes) as cycle:
            code, _, err = self.lw("daemon", "run", "--cycles", "2")
        self.assertEqual(code, 0, err)
        self.assertEqual(cycle.call_count, 2)
        first, second = self.cycle_lines()
        self.assertIn("cycle failed", first)
        self.assertIn("RuntimeError: boom", first)
        self.assertNotIn("failed", second)

    def test_a_bad_ttl_fails_the_cycle_not_the_loop(self):
        os.environ["LW_TTL_DAYS"] = "nope"
        code, _, err = self.lw("daemon", "run", "--cycles", "2")
        self.assertEqual(code, 0, err)
        lines = self.cycle_lines()
        self.assertEqual(len(lines), 2)
        self.assertTrue(all("cycle failed" in line and "LW_TTL_DAYS" in line for line in lines), lines)

    def test_a_transport_error_is_logged_and_the_loop_goes_on(self):
        self.subscribe("--session", "s1", "--project", PROJECT)
        os.environ["FAKE_LINEAR_MODE"] = "unreachable"
        code, _, err = self.lw("daemon", "run", "--cycles", "2")
        self.assertEqual(code, 0, err)
        lines = self.cycle_lines()
        self.assertEqual(len(lines), 2)
        for line in lines:
            self.assertIn("1 failed query(ies)", line)
            self.assertIn("CommentsSince", line)

    def test_one_log_line_per_cycle_and_no_secret(self):
        self.subscribe("--session", "s1", "--project", PROJECT)
        os.environ["FAKE_LINEAR_MODE"] = "unauthenticated"
        code, _, err = self.lw("daemon", "run", "--cycles", "3")
        self.assertEqual(code, 0, err)
        self.assertEqual(len(self.cycle_lines()), 3)
        log = (self.state / lw.DAEMON_LOG).read_text()
        self.assertNotIn(TEST_KEY, log)
        self.assertRegex(self.cycle_lines()[0], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ cycle ")

    def test_a_bad_poll_interval_refuses_to_start(self):
        os.environ["LW_POLL_SECONDS"] = "0"
        code, _, err = self.lw("daemon", "run", "--cycles", "1")
        self.assertEqual(code, 2)
        self.assertIn("LW_POLL_SECONDS", err)
        self.assertEqual(self.cycle_lines(), [])


class ReexecTest(DaemonCase):
    def touch_script_later(self, *_a, **_k):
        t = time.time() + 5
        os.utime(self.installed, (t, t))
        return lw.CycleResult()

    def test_a_newer_script_re_execs_after_the_cycle(self):
        with mock.patch.object(lw, "run_cycle", side_effect=self.touch_script_later), \
                mock.patch.object(lw.os, "execv", side_effect=Exec) as execv:
            with self.assertRaises(Exec):
                self.lw("daemon", "run", "--cycles", "3")
        self.assertEqual(len(self.cycle_lines()), 1)  # exec'd before the second cycle
        path, argv = execv.call_args.args
        self.assertEqual(path, sys.executable)
        self.assertEqual(argv, [sys.executable, str(self.installed), "daemon", "run",
                                "--state-dir", str(self.state)])
        self.assertTrue(any("re-exec" in line for line in self.log_lines()))

    def test_an_unchanged_script_does_not_re_exec(self):
        with mock.patch.object(lw.os, "execv", side_effect=Exec) as execv:
            code, _, err = self.lw("daemon", "run", "--cycles", "3")
        self.assertEqual(code, 0, err)
        execv.assert_not_called()
        self.assertEqual(len(self.cycle_lines()), 3)

    def test_the_re_execed_process_rewrites_the_marker_and_does_not_loop(self):
        # the script changed before this run started: it is the new code
        t = time.time() - 60
        os.utime(self.installed, (t, t))
        self.state.mkdir(parents=True)
        (self.state / lw.DAEMON_STARTED).write_text("0\n")
        os.utime(self.state / lw.DAEMON_STARTED, (t - 60, t - 60))
        with mock.patch.object(lw.os, "execv", side_effect=Exec) as execv:
            code, _, err = self.lw("daemon", "run", "--cycles", "2")
        self.assertEqual(code, 0, err)
        execv.assert_not_called()

    def test_an_older_copy_with_a_different_mtime_also_re_execs(self):
        # `cp -p` of an older checkout keeps an mtime older than the marker
        def roll_back(*_a, **_k):
            t = time.time() - 3600
            os.utime(self.installed, (t, t))
            return lw.CycleResult()

        with mock.patch.object(lw, "run_cycle", side_effect=roll_back), \
                mock.patch.object(lw.os, "execv", side_effect=Exec):
            with self.assertRaises(Exec):
                self.lw("daemon", "run", "--cycles", "3")


class StartTest(DaemonCase):
    def plist_path(self) -> Path:
        return self.home / "Library" / "LaunchAgents" / f"{lw.LAUNCHD_LABEL}.plist"

    def test_start_installs_and_loads_the_plist(self):
        code, out, err = self.lw("daemon", "start")
        self.assertEqual(code, 0, err)
        self.assertIn("daemon started", out)
        text = self.plist_path().read_text()
        self.assertIsNone(re.search(r"@[A-Z_]+@", text), "placeholder left")
        plist = plistlib.loads(text.encode())
        self.assertEqual(plist["Label"], "com.linear-watch.daemon")
        self.assertEqual(plist["ProgramArguments"],
                         [sys.executable, str(self.installed), "daemon", "run"])
        env = plist["EnvironmentVariables"]
        self.assertEqual(env["LW_LINEAR_BIN"], str(FAKE_LINEAR))
        self.assertEqual(env["LW_STATE_DIR"], str(self.state))
        self.assertEqual(env["HOME"], str(self.home))
        self.assertIn("/opt/homebrew/bin", env["PATH"])
        self.assertTrue(plist["RunAtLoad"])
        self.assertTrue(plist["KeepAlive"])
        self.assertEqual(plist["StandardErrorPath"], str(self.state / "daemon.out"))
        uid = os.getuid()
        self.assertEqual(self.launchctl_calls(), [
            f"bootout gui/{uid}/com.linear-watch.daemon",
            f"bootstrap gui/{uid} {self.plist_path()}",
        ])

    def test_no_secret_in_the_plist_nor_in_launchctl_argv(self):
        self.assertEqual(self.lw("daemon", "start")[0], 0)
        self.assertNotIn(TEST_KEY, self.plist_path().read_text())
        self.assertNotIn("LINEAR_API_KEY", self.plist_path().read_text())
        self.assertNotIn(TEST_KEY, self.launchctl_log.read_text())

    def test_paths_are_xml_escaped(self):
        odd = self.tmp / "state & <co>"
        os.environ["LW_STATE_DIR"] = str(odd)
        self.assertEqual(self.lw("daemon", "start")[0], 0)
        plist = plistlib.loads(self.plist_path().read_bytes())
        self.assertEqual(plist["EnvironmentVariables"]["LW_STATE_DIR"], str(odd))

    def test_a_failed_bootstrap_exits_1(self):
        os.environ["LAUNCHCTL_STUB_RC"] = "5"
        code, _, err = self.lw("daemon", "start")
        self.assertEqual(code, 1)
        self.assertIn("launchctl bootstrap failed", err)

    def test_start_without_launchctl_says_how_to_run_it(self):
        (self.bin / "launchctl").unlink()
        os.environ["PATH"] = str(self.bin)
        code, _, err = self.lw("daemon", "start")
        self.assertEqual(code, 2)
        self.assertIn("lw daemon run", err)
        self.assertFalse(self.plist_path().exists())

    def test_start_refuses_without_a_linear_binary(self):
        os.environ["LW_LINEAR_BIN"] = str(self.tmp / "no-such-linear")
        code, _, err = self.lw("daemon", "start")
        self.assertEqual(code, 2)
        self.assertIn("linear binary", err)
        self.assertEqual(self.launchctl_calls(), [])

    def test_start_records_an_absolute_linear_path(self):
        rel = os.path.relpath(FAKE_LINEAR)
        os.environ["LW_LINEAR_BIN"] = rel
        self.assertEqual(self.lw("daemon", "start")[0], 0)
        plist = plistlib.loads(self.plist_path().read_bytes())
        self.assertEqual(plist["EnvironmentVariables"]["LW_LINEAR_BIN"], os.path.abspath(rel))

    def test_stop_unloads_and_removes_the_plist(self):
        self.assertEqual(self.lw("daemon", "start")[0], 0)
        code, out, err = self.lw("daemon", "stop")
        self.assertEqual(code, 0, err)
        self.assertIn("daemon stopped", out)
        self.assertFalse(self.plist_path().exists())
        self.assertEqual(self.launchctl_calls()[-1], f"bootout gui/{os.getuid()}/com.linear-watch.daemon")

    def test_stop_when_not_loaded(self):
        os.environ["LAUNCHCTL_BOOTOUT_RC"] = "3"
        code, out, _ = self.lw("daemon", "stop")
        self.assertEqual(code, 0)
        self.assertIn("not loaded", out)


class CheckoutRefusalTest(DaemonCase):
    def point_script_at(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("# lw\n")
        patcher = mock.patch.object(lw, "LW_SCRIPT", str(path))
        patcher.start()
        self.addCleanup(patcher.stop)

    def assert_refused(self):
        code, _, err = self.lw("daemon", "start")
        self.assertEqual(code, 2)
        self.assertIn("refusing", err)
        self.assertIn("installed copy", err)
        self.assertEqual(self.launchctl_calls(), [])
        self.assertFalse((self.home / "Library" / "LaunchAgents").exists())

    def test_refuses_from_a_git_checkout(self):
        repo = self.tmp / "repo"
        (repo / ".git").mkdir(parents=True)
        self.point_script_at(repo / "skills" / "linear-watch" / "scripts" / "lw")
        self.assert_refused()

    def test_refuses_from_a_linked_worktree(self):
        wt = self.tmp / "wt"
        wt.mkdir()
        (wt / ".git").write_text("gitdir: /somewhere/.git/worktrees/wt\n")
        self.point_script_at(wt / "skills" / "linear-watch" / "scripts" / "lw")
        self.assert_refused()

    def test_refuses_from_a_worktrees_path(self):
        self.point_script_at(self.tmp / "repo" / ".claude" / "worktrees" / "x" / "scripts" / "lw")
        self.assert_refused()

    def test_allow_checkout_overrides(self):
        repo = self.tmp / "repo"
        (repo / ".git").mkdir(parents=True)
        self.point_script_at(repo / "skills" / "linear-watch" / "scripts" / "lw")
        os.environ["LW_ALLOW_CHECKOUT"] = "1"
        code, _, err = self.lw("daemon", "start")
        self.assertEqual(code, 0, err)

    def test_the_refusal_names_no_install_location(self):
        repo = self.tmp / "repo"
        (repo / ".git").mkdir(parents=True)
        self.point_script_at(repo / "scripts" / "lw")
        _, _, err = self.lw("daemon", "start")
        self.assertNotIn(".agents", err)
        self.assertIn(str(repo / "scripts" / "lw"), err)

    def test_the_installed_copy_is_accepted(self):
        self.assertFalse(lw.in_checkout(str(self.installed)))
        self.assertEqual(self.lw("daemon", "start")[0], 0)


class ScriptPathTest(unittest.TestCase):
    def test_paths_follow_the_script_through_a_symlink(self):
        with tempfile.TemporaryDirectory() as tmp:
            link = Path(tmp) / "bin" / "lw"
            link.parent.mkdir()
            link.symlink_to(LW_PATH)
            loader = SourceFileLoader("lw_link", str(link))
            module = module_from_spec(spec_from_loader("lw_link", loader))
            loader.exec_module(module)
        self.assertEqual(module.LW_SCRIPT, os.path.realpath(LW_PATH))
        self.assertEqual(module.DAEMON_TEMPLATE,
                         Path(os.path.realpath(LW_PATH)).parent.parent / "templates"
                         / "com.linear-watch.daemon.plist")
        self.assertNotIn("linear-watch/scripts", Path(LW_PATH).read_text().split(
            "# ── daemon (LW-7)", 1)[1].split("# ── end of daemon (LW-7)", 1)[0])


class TemplateTest(unittest.TestCase):
    def test_the_template_is_a_plist_with_placeholders(self):
        path = TESTS.parent / "templates" / "com.linear-watch.daemon.plist"
        text = path.read_text()
        for placeholder in ("@PYTHON@", "@LW@", "@STATE@", "@HOME@", "@LINEAR_BIN@"):
            self.assertIn(placeholder, text)
        self.assertNotIn("LINEAR_API_KEY", text)
        plistlib.loads(text.encode())  # well-formed before substitution


class RunCommandTest(DaemonCase):
    def test_lw_daemon_run_as_a_process(self):
        # the real entry point, once, end to end
        env = dict(os.environ)
        proc = subprocess.run(
            [sys.executable, str(LW_PATH), "daemon", "run", "--cycles", "1"],
            capture_output=True, text=True, env=env, timeout=60,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(len(self.cycle_lines()), 1)
        self.assertTrue(any("daemon started" in line for line in self.log_lines()))
        self.assertIsNotNone(lw.heartbeat_age(self.state))


if __name__ == "__main__":
    unittest.main()
