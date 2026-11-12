"""LW-2 — transport: linear_api() over the `linear api` CLI.

Every call goes to the fake CLI in tests/bin/linear, which replays the LW-0
fixtures and exit codes. Run in Docker: bash skills/linear-watch/tests/run-in-docker.sh
"""

from __future__ import annotations

import json
import os
import stat
import tempfile
import unittest
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
from pathlib import Path
from unittest import mock

TESTS = Path(__file__).resolve().parent
LW_PATH = TESTS.parent / "scripts" / "lw"
FAKE_LINEAR = TESTS / "bin" / "linear"
FIXTURES = TESTS / "fixtures" / "linear-real"


def load_lw():
    loader = SourceFileLoader("lw_transport", str(LW_PATH))
    spec = spec_from_loader("lw_transport", loader)
    module = module_from_spec(spec)
    loader.exec_module(module)
    return module


lw = load_lw()

# A made-up key in the real key's shape; only the fake ever accepts it.
TEST_KEY = "lin_api_TESTkey0123456789abcdefghijklmnopqrstuv"
COMMENTS_QUERY = (
    "query CommentsSince($since: DateTimeOrDuration!, $p: String!) {"
    " comments(first: 250, filter: {createdAt: {gt: $since},"
    " issue: {project: {slugId: {eq: $p}}}}) {"
    " nodes { id createdAt } pageInfo { hasNextPage endCursor } } }"
)
COMMENTS_VARS = {"since": "2026-11-12T08:00:00Z", "p": "5842ed0c2bcd"}

FAILURE_MODES = {
    # mode -> expected lw code
    "unauthenticated": 10,
    "rate-limited": 12,
    "rate-limited-text": 12,
    "not-found": 13,
    "unknown-field": 13,
    "bad-variable": 13,
    "unreachable": 13,
    "garbage": 13,
    "paginated-array": 13,
}


class TransportCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="lw-transport-"))
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.state = self.tmp / "state"
        self.log = self.tmp / "fake-linear.log"
        env = {
            "HOME": str(self.home),
            "LW_STATE_DIR": str(self.state),
            "LW_LINEAR_BIN": str(FAKE_LINEAR),
            "LINEAR_API_KEY": TEST_KEY,
            "FAKE_LINEAR_KEY": TEST_KEY,
            "FAKE_LINEAR_LOG": str(self.log),
        }
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)
        for var in ("FAKE_LINEAR_MODE", "FAKE_LINEAR_FIXTURE", "LW_LINEAR_TIMEOUT"):
            os.environ.pop(var, None)
        lw.reset_linear_bin()
        self.addCleanup(lw.reset_linear_bin)

    def calls(self) -> list[dict]:
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def fail_with(self, mode: str, **kwargs) -> "lw.TransportError":
        os.environ["FAKE_LINEAR_MODE"] = mode
        with self.assertRaises(lw.TransportError) as ctx:
            lw.linear_api(COMMENTS_QUERY, COMMENTS_VARS, **kwargs)
        return ctx.exception

    def write_env_file(self, content: str) -> Path:
        path = self.home / ".config" / "linear" / "env"
        path.parent.mkdir(parents=True)
        path.write_text(content)
        return path


class FakeBinaryTest(TransportCase):
    def test_fake_is_executable(self):
        self.assertTrue(FAKE_LINEAR.stat().st_mode & stat.S_IXUSR)


class CodeOkTest(TransportCase):
    def test_success_returns_the_parsed_body(self):
        data = lw.linear_api(COMMENTS_QUERY, COMMENTS_VARS)
        expected = json.loads((FIXTURES / "comments-since.json").read_text())
        self.assertEqual(data, expected)
        self.assertEqual(len(data["data"]["comments"]["nodes"]), 31)

    def test_query_on_stdin_and_variables_as_json(self):
        lw.linear_api(COMMENTS_QUERY, COMMENTS_VARS)
        (call,) = self.calls()
        self.assertEqual(call["stdin"], COMMENTS_QUERY)
        self.assertEqual(call["argv"][:2], ["api", "--variables-json"])
        self.assertEqual(json.loads(call["argv"][2]), COMMENTS_VARS)
        self.assertEqual(len(call["argv"]), 3, "no query and no other flag on argv")
        self.assertEqual(call["ignore_env_file"], "1")
        self.assertEqual(call["cwd"], "/")

    def test_all_digit_slug_id_stays_a_string(self):
        # LW-0: `--variable p=123456789012` would send a number
        lw.linear_api(COMMENTS_QUERY, {"since": "2026-11-12T08:00:00Z", "p": "123456789012"})
        (call,) = self.calls()
        self.assertEqual(json.loads(call["argv"][2])["p"], "123456789012")

    def test_no_variables_sends_an_empty_object(self):
        os.environ["FAKE_LINEAR_FIXTURE"] = "project-completed.json"
        lw.linear_api("{ organization { urlKey } }")
        (call,) = self.calls()
        self.assertEqual(json.loads(call["argv"][2]), {})

    def test_success_is_recorded_for_doctor(self):
        lw.linear_api(COMMENTS_QUERY, COMMENTS_VARS)
        status = lw.read_transport_status(self.state)
        self.assertIn("last_ok", status)
        self.assertNotIn("last_error", status)


class CredentialTest(TransportCase):
    def test_rejected_key_is_10(self):
        os.environ["LINEAR_API_KEY"] = "lin_api_bogus"
        with self.assertRaises(lw.TransportError) as ctx:
            lw.linear_api(COMMENTS_QUERY, COMMENTS_VARS)
        exc = ctx.exception
        self.assertEqual(exc.code, lw.T_CREDENTIAL)
        self.assertEqual(exc.code, 10)
        self.assertIn("Authentication required", exc.message)

    def test_unauthenticated_body_is_10(self):
        self.assertEqual(self.fail_with("unauthenticated").code, 10)

    def test_no_key_anywhere_is_10_without_calling_linear(self):
        del os.environ["LINEAR_API_KEY"]
        exc = self.fail_with("ok")
        self.assertEqual(exc.code, 10)
        self.assertIn("LINEAR_API_KEY", exc.message)
        self.assertEqual(self.calls(), [])

    def test_key_loaded_from_the_linear_env_file(self):
        del os.environ["LINEAR_API_KEY"]
        self.write_env_file(f'# written by hand\nexport LINEAR_API_KEY="{TEST_KEY}"\n')
        lw.linear_api(COMMENTS_QUERY, COMMENTS_VARS)
        (call,) = self.calls()
        self.assertTrue(call["key_received"])
        self.assertNotIn("LINEAR_API_KEY", os.environ, "the key stays out of os.environ")

    def test_env_file_without_export_and_single_quotes(self):
        os.environ["LINEAR_API_KEY"] = ""  # empty counts as unset (LW-0, case D)
        self.write_env_file(f"LINEAR_API_KEY='{TEST_KEY}'\n")
        lw.linear_api(COMMENTS_QUERY, COMMENTS_VARS)
        self.assertTrue(self.calls()[0]["key_received"])

    def test_environment_key_wins_over_the_env_file(self):
        self.write_env_file("export LINEAR_API_KEY=lin_api_stale\n")
        lw.linear_api(COMMENTS_QUERY, COMMENTS_VARS)  # the fake accepts TEST_KEY only


class RateLimitTest(TransportCase):
    def test_ratelimited_body_is_12(self):
        exc = self.fail_with("rate-limited")
        self.assertEqual(exc.code, lw.T_RATE_LIMITED)
        self.assertEqual(exc.code, 12)

    def test_rate_limit_text_on_exit_5_is_12(self):
        self.assertEqual(self.fail_with("rate-limited-text").code, 12)


class OtherFailureTest(TransportCase):
    def test_every_other_failure_is_13(self):
        for mode in ("not-found", "unknown-field", "bad-variable", "unreachable",
                     "garbage", "paginated-array"):
            with self.subTest(mode=mode):
                exc = self.fail_with(mode)
                self.assertEqual(exc.code, lw.T_OTHER)
                self.assertEqual(exc.code, 13)
                self.assertTrue(exc.message)

    def test_rate_limit_words_outside_messages_do_not_count(self):
        # a validation error at column 429, on a field named like a rate limit
        body = json.loads((FIXTURES / "errors-unknown-field.json").read_text())
        body["errors"][0]["locations"][0]["column"] = 429
        body["errors"][0]["extensions"]["hint"] = "rateLimitStatus"
        code, _ = lw._classify(1, "", json.dumps(body))
        self.assertEqual(code, 13)

    def test_exit_0_with_null_data_is_13(self):
        self.assertEqual(lw._classify(0, '{"data": null}', "")[0], 13)

    def test_body_message_is_kept(self):
        exc = self.fail_with("not-found")
        self.assertEqual(exc.message, "Entity not found: Issue")
        exc = self.fail_with("unreachable")
        self.assertIn("Connection refused", exc.message)
        self.assertNotIn("✗", exc.message)

    def test_missing_binary_is_13(self):
        os.environ["LW_LINEAR_BIN"] = str(self.tmp / "no-such-linear")
        exc = self.fail_with("ok")
        self.assertEqual(exc.code, 13)
        self.assertIn("no-such-linear", exc.message)

    def test_timeout_is_13(self):
        exc = self.fail_with("hang", timeout=0.5)
        self.assertEqual(exc.code, 13)
        self.assertIn("timed out", exc.message)


class LastErrorTest(TransportCase):
    def test_last_error_kept_with_code_message_and_query_name(self):
        exc = self.fail_with("rate-limited")
        self.assertEqual(exc.query, "CommentsSince")
        status = lw.read_transport_status(self.state)
        err = status["last_error"]
        self.assertEqual(err["code"], 12)
        self.assertEqual(err["query"], "CommentsSince")
        self.assertEqual(err["message"], "Rate limit exceeded")
        self.assertIn("at", err)
        mode = (self.state / lw.TRANSPORT_FILE).stat().st_mode & 0o777
        self.assertEqual(mode, 0o600)

    def test_anonymous_query_name(self):
        os.environ["FAKE_LINEAR_MODE"] = "unknown-field"
        with self.assertRaises(lw.TransportError) as ctx:
            lw.linear_api("{ organization { urlKey nopeField } }")
        self.assertEqual(ctx.exception.query, "anonymous")

    def test_a_later_success_keeps_the_error_and_adds_last_ok(self):
        self.fail_with("unreachable")
        os.environ["FAKE_LINEAR_MODE"] = "ok"
        lw.linear_api(COMMENTS_QUERY, COMMENTS_VARS)
        status = lw.read_transport_status(self.state)
        self.assertEqual(status["last_error"]["code"], 13)
        self.assertGreaterEqual(status["last_ok"], status["last_error"]["at"])

    def test_explicit_state_dir(self):
        other = self.tmp / "other"
        self.fail_with("not-found", state_dir=other)
        self.assertEqual(lw.read_transport_status(other)["last_error"]["code"], 13)
        self.assertEqual(lw.read_transport_status(self.state), {})


class KeyNeverExposedTest(TransportCase):
    def test_key_never_on_argv_stdin_error_or_file(self):
        seen_errors = []
        lw.linear_api(COMMENTS_QUERY, COMMENTS_VARS)
        for mode in FAILURE_MODES:
            seen_errors.append(self.fail_with(mode))
        # the key read from the env file is guarded the same way
        os.environ["FAKE_LINEAR_MODE"] = "ok"
        del os.environ["LINEAR_API_KEY"]
        self.write_env_file(f"export LINEAR_API_KEY={TEST_KEY}\n")
        lw.linear_api(COMMENTS_QUERY, COMMENTS_VARS)

        calls = self.calls()
        self.assertEqual(len(calls), len(FAILURE_MODES) + 2)
        for call in calls:
            self.assertTrue(call["key_received"])
            for arg in call["argv"]:
                self.assertNotIn(TEST_KEY, arg)
            self.assertNotIn(TEST_KEY, call["stdin"])
        for exc in seen_errors:
            self.assertNotIn(TEST_KEY, str(exc))
            self.assertNotIn(TEST_KEY, exc.message)
        for path in self.state.rglob("*"):
            if path.is_file():
                self.assertNotIn(TEST_KEY, path.read_text())

    def test_key_echoed_by_linear_is_redacted(self):
        # a CLI that echoes the key in an error must not carry it further
        fake = self.tmp / "echo-linear"
        fake.write_text(
            "#!/bin/sh\ncat >/dev/null\n"
            'echo "invalid key $LINEAR_API_KEY" >&2\nexit 1\n'
        )
        fake.chmod(0o755)
        os.environ["LW_LINEAR_BIN"] = str(fake)
        exc = self.fail_with("ok")
        self.assertNotIn(TEST_KEY, exc.message)
        self.assertIn("<key>", exc.message)
        self.assertNotIn(TEST_KEY, (self.state / lw.TRANSPORT_FILE).read_text())


class BinaryResolutionTest(TransportCase):
    def test_lw_linear_bin_wins(self):
        self.assertEqual(lw.linear_bin(), str(FAKE_LINEAR))

    def test_default_path_when_it_exists(self):
        del os.environ["LW_LINEAR_BIN"]
        with mock.patch.object(lw, "LINEAR_DEFAULT_BIN", str(FAKE_LINEAR)):
            lw.reset_linear_bin()
            self.assertEqual(lw.linear_bin(), str(FAKE_LINEAR))

    def test_falls_back_to_path_and_keeps_the_symlink(self):
        del os.environ["LW_LINEAR_BIN"]
        bindir = self.tmp / "bin"
        bindir.mkdir()
        (bindir / "linear").symlink_to(FAKE_LINEAR)
        with mock.patch.object(lw, "LINEAR_DEFAULT_BIN", str(self.tmp / "absent")), \
                mock.patch.dict(os.environ, {"PATH": f"{bindir}:{os.environ['PATH']}"}):
            lw.reset_linear_bin()
            self.assertEqual(lw.linear_bin(), str(bindir / "linear"))
            lw.linear_api(COMMENTS_QUERY, COMMENTS_VARS)

    def test_resolved_once(self):
        del os.environ["LW_LINEAR_BIN"]
        with mock.patch.object(lw, "LINEAR_DEFAULT_BIN", str(FAKE_LINEAR)):
            lw.reset_linear_bin()
            first = lw.linear_bin()
        # the default moved away, the cached path stays
        self.assertEqual(lw.linear_bin(), first)


if __name__ == "__main__":
    unittest.main()
