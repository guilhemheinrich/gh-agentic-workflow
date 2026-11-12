"""LW-5 — `lw doctor [--quiet]`.

Transport errors are recorded by calling the real linear_api() against the
fake CLI in tests/bin/linear, so doctor reads what LW-2 actually writes.
Run in Docker: bash skills/linear-watch/tests/run-in-docker.sh test_doctor
"""

from __future__ import annotations

import contextlib
import io
import os
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
    loader = SourceFileLoader("lw_doctor", str(LW_PATH))
    spec = spec_from_loader("lw_doctor", loader)
    module = module_from_spec(spec)
    loader.exec_module(module)
    return module


lw = load_lw()

# A made-up key in the real key's shape; only the fake ever accepts it.
TEST_KEY = "lin_api_TESTkey0123456789abcdefghijklmnopqrstuv"
QUERY = "query ProjectState($p: String!) { project(id: $p) { id state } }"


class DoctorCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.state = self.tmp / "state"
        env = {
            "HOME": str(self.home),
            "LW_STATE_DIR": str(self.state),
            "LW_LINEAR_BIN": str(FAKE_LINEAR),
            "LINEAR_API_KEY": TEST_KEY,
            "FAKE_LINEAR_KEY": TEST_KEY,
        }
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)
        for var in ("FAKE_LINEAR_MODE", "FAKE_LINEAR_FIXTURE", "LW_POLL_SECONDS"):
            os.environ.pop(var, None)
        lw.reset_linear_bin()
        self.addCleanup(lw.reset_linear_bin)
        self.beat(age=10)

    def beat(self, age: float):
        self.state.mkdir(parents=True, exist_ok=True)
        path = self.state / lw.HEARTBEAT_FILE
        path.touch()
        t = time.time() - age
        os.utime(path, (t, t))

    def call_linear(self, mode: str):
        os.environ["FAKE_LINEAR_MODE"] = mode
        try:
            lw.linear_api(QUERY, {"p": "c70b17017c41"}, state_dir=self.state)
        except lw.TransportError:
            pass
        finally:
            os.environ.pop("FAKE_LINEAR_MODE", None)

    def doctor(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = lw.main(["doctor", "--state-dir", str(self.state), *argv])
        text = out.getvalue() + err.getvalue()
        self.assertNotIn(TEST_KEY, text)
        return code, out.getvalue()

    def line(self, out: str, word: str) -> str:
        found = [l for l in out.splitlines() if word in l]
        self.assertTrue(found, f"no line with {word!r} in:\n{out}")
        return found[0]


class Healthy(DoctorCase):
    def test_all_ok(self):
        self.call_linear("ok")
        code, out = self.doctor()
        self.assertEqual(code, 0, out)
        self.assertNotIn("FAIL", out)
        self.assertTrue(self.line(out, "linear binary").startswith("ok"))
        self.assertTrue(self.line(out, "credential").startswith("ok"))
        self.assertTrue(self.line(out, "heartbeat").startswith("ok"))

    def test_quiet_prints_nothing_and_exits_0(self):
        code, out = self.doctor("--quiet")
        self.assertEqual((code, out), (0, ""))

    def test_credential_source_is_named_never_printed(self):
        del os.environ["LINEAR_API_KEY"]
        env = self.home / ".config" / "linear" / "env"
        env.parent.mkdir(parents=True)
        env.write_text(f"LINEAR_API_KEY={TEST_KEY}\n")
        code, out = self.doctor()
        self.assertEqual(code, 0, out)
        self.assertIn("~/.config/linear/env", self.line(out, "credential"))


class Heartbeat(DoctorCase):
    def test_absent_heartbeat_fails_as_not_started(self):
        (self.state / lw.HEARTBEAT_FILE).unlink()
        code, out = self.doctor()
        self.assertEqual(code, 1)
        line = self.line(out, "heartbeat")
        self.assertTrue(line.startswith("FAIL"), line)
        self.assertIn("not started", line)

    def test_stale_heartbeat_fails(self):
        self.beat(age=3 * 300 + 30)
        code, out = self.doctor()
        self.assertEqual(code, 1)
        self.assertTrue(self.line(out, "heartbeat").startswith("FAIL"))

    def test_poll_seconds_sets_the_limit(self):
        with mock.patch.dict(os.environ, {"LW_POLL_SECONDS": "5"}):
            self.beat(age=20)
            self.assertEqual(self.doctor()[0], 1)
            self.beat(age=10)
            self.assertEqual(self.doctor()[0], 0)

    def test_quiet_fail_prints_nothing_and_exits_1(self):
        self.beat(age=3600)
        self.assertEqual(self.doctor("--quiet"), (1, ""))


class Credential(DoctorCase):
    def test_no_credential_fails(self):
        del os.environ["LINEAR_API_KEY"]
        code, out = self.doctor()
        self.assertEqual(code, 1)
        self.assertTrue(self.line(out, "credential").startswith("FAIL"))

    def test_rejected_credential_fails(self):
        self.call_linear("ok")
        self.call_linear("unauthenticated")
        code, out = self.doctor()
        self.assertEqual(code, 1)
        self.assertTrue(self.line(out, "credential").startswith("FAIL"), out)
        self.assertIn("rejected", self.line(out, "credential"))

    def test_credential_recovers_after_a_later_success(self):
        self.call_linear("unauthenticated")
        time.sleep(1.1)  # transport timestamps have second precision
        self.call_linear("ok")
        code, out = self.doctor()
        self.assertEqual(code, 0, out)
        self.assertTrue(self.line(out, "credential").startswith("ok"))


class Transport(DoctorCase):
    def test_binary_missing_fails(self):
        os.environ["LW_LINEAR_BIN"] = str(self.tmp / "no-linear")
        code, out = self.doctor()
        self.assertEqual(code, 1)
        self.assertTrue(self.line(out, "linear binary").startswith("FAIL"))

    def test_no_call_yet(self):
        code, out = self.doctor()
        self.assertEqual(code, 0, out)
        self.assertIn("no Linear call recorded", out)

    def test_current_error_is_reported_verbatim(self):
        self.call_linear("unreachable")
        status = lw.read_transport_status(self.state)["last_error"]
        code, out = self.doctor()
        self.assertEqual(code, 1)
        line = self.line(out, "last Linear call")
        self.assertTrue(line.startswith("FAIL"), line)
        self.assertIn(status["message"], line)
        self.assertIn("ProjectState", line)
        self.assertIn("code 13", line)

    def test_rate_limit_is_a_warning(self):
        self.call_linear("rate-limited")
        code, out = self.doctor()
        self.assertEqual(code, 0, out)
        self.assertTrue(self.line(out, "last Linear call").startswith("warn"))

    def test_recovered_error_is_ok(self):
        self.call_linear("unreachable")
        time.sleep(1.1)
        self.call_linear("ok")
        code, out = self.doctor()
        self.assertEqual(code, 0, out)
        line = self.line(out, "last Linear call")
        self.assertTrue(line.startswith("ok"), line)
        self.assertIn("recovered", line)


class Subscriptions(DoctorCase):
    def test_open_subscriptions_per_session_with_age(self):
        conn = lw.connect(self.state)
        self.addCleanup(conn.close)
        t = lw.now()
        rows = [
            ("sess-a", "project", "5842ed0c2bcd", timedelta(days=2, hours=3), timedelta(minutes=4)),
            ("sess-a", "issue", "TT-1", timedelta(hours=5), timedelta(hours=5)),
            ("sess-b", "issue", "TT-2", timedelta(minutes=30), timedelta(minutes=30)),
        ]
        for session, kind, target, created, renewed in rows:
            conn.execute(
                "INSERT INTO subscriptions (session, harness, kind, target, created_at, renewed_at)"
                " VALUES (?, 'claude-code', ?, ?, ?, ?)",
                (session, kind, target, lw.fmt(t - created), lw.fmt(t - renewed)),
            )
        conn.execute(
            "INSERT INTO subscriptions (session, harness, kind, target, created_at, renewed_at,"
            " closed_at, close_reason) VALUES ('sess-c', 'claude-code', 'issue', 'TT-3', ?, ?, ?, 'ttl')",
            (lw.fmt(t), lw.fmt(t), lw.fmt(t)),
        )
        code, out = self.doctor()
        self.assertEqual(code, 0, out)
        a = self.line(out, "sess-a")
        self.assertIn("2 open", a)
        self.assertIn("oldest 2d 3h", a)
        self.assertIn("renewed 4m ago", a)
        self.assertIn("project 5842ed0c2bcd", a)
        self.assertIn("issue TT-1", a)
        self.assertIn("1 open", self.line(out, "sess-b"))
        self.assertNotIn("sess-c", out)

    def test_no_subscription(self):
        code, out = self.doctor()
        self.assertIn("no open subscription", out)


if __name__ == "__main__":
    unittest.main()
