"""LW-6 — own writes: `lw own-write` and the Claude PostToolUse hook.

Run in Docker: bash skills/linear-tracker/tests/linear-watch/run-in-docker.sh test_own_writes
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import shutil
import sqlite3
import subprocess
import tempfile
import unittest
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
from pathlib import Path

SKILL = Path(__file__).resolve().parents[2]
LW_PATH = SKILL / "scripts" / "lw"
HOOK = SKILL / "adapters" / "claude" / "own-writes-hook.sh"
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "mcp-responses"
BASH = shutil.which("bash") or "/bin/bash"


def load_lw():
    loader = SourceFileLoader("lw", str(LW_PATH))
    spec = spec_from_loader("lw", loader)
    module = module_from_spec(spec)
    loader.exec_module(module)
    return module


lw = load_lw()

COMMENT_ID = "86dc623a-0000-4e62-bbc6-86761097c4b3"
EDITED_ID = "7bf7220b-0000-4c84-8782-3a44eafa139c"

# fixture -> rows (kind, ref, value) it must leave in own_writes
EXPECTED = {
    "save-comment-created.json": [("comment", COMMENT_ID, None)],
    "save-comment-edited.json": [("comment", EDITED_ID, None)],
    "save-issue-state.json": [("state", "TT-2117", "In Review")],
    "save-issue-state-again.json": [("state", "TT-2117", "Done")],
    "save-issue-created-with-state.json": [("state", "TT-2250", "In Progress")],
    "save-issue-no-state.json": [],
    "save-comment-error.json": [],
    "save-issue-error.json": [],
    "other-mcp-save-comment-named.json": [],
    "other-mcp-save-comment-generic.json": [],
    "envelope-list-teams-cli.json": [],
}


class OwnWritesCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state_dir = Path(self._tmp.name) / "state"
        self.db = self.state_dir / "lw.sqlite"

    def tearDown(self):
        self._tmp.cleanup()

    def run_lw(self, *args: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                code = lw.main(["--state-dir", str(self.state_dir), *args])
            except SystemExit as exc:  # argparse errors
                code = exc.code
        return code, out.getvalue(), err.getvalue()

    def rows(self) -> list[tuple]:
        if not self.db.exists():
            return []
        conn = sqlite3.connect(self.db)
        try:
            return conn.execute(
                "SELECT kind, ref, value FROM own_writes ORDER BY kind, ref"
            ).fetchall()
        finally:
            conn.close()

    def run_hook(self, stdin: bytes, **env_extra: str) -> subprocess.CompletedProcess:
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": self._tmp.name,
            "LW_STATE_DIR": str(self.state_dir),
            "LW_GRAPH": "0",  # LW-11 has its own tests; the hook must not spawn a rebuild here
            **env_extra,
        }
        return subprocess.run(
            [BASH, str(HOOK)], input=stdin, capture_output=True, env=env, timeout=30
        )

    def fixture(self, name: str) -> bytes:
        return (FIXTURES / name).read_bytes()


class OwnWriteCommandTest(OwnWritesCase):
    def test_comment_is_recorded(self):
        code, out, _ = self.run_lw("own-write", "--comment", COMMENT_ID)
        self.assertEqual(code, 0)
        self.assertIn(COMMENT_ID, out)
        self.assertEqual(self.rows(), [("comment", COMMENT_ID, None)])

    def test_comment_twice_is_one_row(self):
        self.run_lw("own-write", "--comment", COMMENT_ID)
        self.run_lw("own-write", "--comment", COMMENT_ID)
        self.assertEqual(self.rows(), [("comment", COMMENT_ID, None)])

    def test_state_is_recorded_with_uppercase_identifier(self):
        code, _, _ = self.run_lw("own-write", "--issue", "tt-2290", "--state", "Todo")
        self.assertEqual(code, 0)
        self.assertEqual(self.rows(), [("state", "TT-2290", "Todo")])

    def test_second_own_move_replaces_the_state(self):
        self.run_lw("own-write", "--issue", "TT-2290", "--state", "Todo")
        self.run_lw("own-write", "--issue", "TT-2290", "--state", "In Progress")
        self.assertEqual(self.rows(), [("state", "TT-2290", "In Progress")])

    def test_issue_url_is_accepted(self):
        self.run_lw(
            "own-write", "--issue",
            "https://linear.app/septeo-proptech/issue/TT-2290/some-title", "--state", "Todo",
        )
        self.assertEqual(self.rows(), [("state", "TT-2290", "Todo")])

    def test_bad_comment_id_is_refused(self):
        code, _, err = self.run_lw("own-write", "--comment", "not-a-uuid")
        self.assertEqual(code, 2)
        self.assertIn("comment id", err)
        self.assertEqual(self.rows(), [])

    def test_issue_without_state_is_refused(self):
        code, _, err = self.run_lw("own-write", "--issue", "TT-2290")
        self.assertEqual(code, 2)
        self.assertIn("--state", err)
        self.assertEqual(self.rows(), [])

    def test_empty_state_is_refused(self):
        code, _, _ = self.run_lw("own-write", "--issue", "TT-2290", "--state", "  ")
        self.assertEqual(code, 2)
        self.assertEqual(self.rows(), [])

    def test_recorded_at_is_a_timestamp(self):
        self.run_lw("own-write", "--comment", COMMENT_ID)
        conn = sqlite3.connect(self.db)
        (at,) = conn.execute("SELECT at FROM own_writes").fetchone()
        conn.close()
        self.assertRegex(at, r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")


class ParsePayloadTest(unittest.TestCase):
    """own_write_from_payload: the pure parser behind --hook."""

    def parse(self, name: str):
        return lw.own_write_from_payload(json.loads((FIXTURES / name).read_text()))

    def test_every_fixture_gives_the_expected_rows(self):
        for name, expected in EXPECTED.items():
            with self.subTest(fixture=name):
                self.assertEqual(self.parse(name), expected)

    def test_every_fixture_file_is_covered(self):
        self.assertEqual(set(EXPECTED), {p.name for p in FIXTURES.glob("*.json")})

    def test_response_as_a_dict_is_read(self):
        payload = json.loads((FIXTURES / "save-comment-created.json").read_text())
        payload["tool_response"] = json.loads(payload["tool_response"][0]["text"])
        self.assertEqual(lw.own_write_from_payload(payload), [("comment", COMMENT_ID, None)])

    def test_response_as_a_json_string_is_read(self):
        payload = json.loads((FIXTURES / "save-comment-created.json").read_text())
        payload["tool_response"] = payload["tool_response"][0]["text"]
        self.assertEqual(lw.own_write_from_payload(payload), [("comment", COMMENT_ID, None)])

    def test_cli_tool_name_is_accepted(self):
        payload = json.loads((FIXTURES / "save-issue-state.json").read_text())
        payload["tool_name"] = "mcp__claude_ai_Linear__save_issue"
        payload["mcp_server"] = {"name": "claude.ai Linear", "source": "claudeai"}
        self.assertEqual(lw.own_write_from_payload(payload), [("state", "TT-2117", "In Review")])

    def test_missing_response_gives_nothing(self):
        payload = json.loads((FIXTURES / "save-comment-created.json").read_text())
        del payload["tool_response"]
        self.assertEqual(lw.own_write_from_payload(payload), [])

    def test_failure_event_gives_nothing(self):
        payload = json.loads((FIXTURES / "save-comment-created.json").read_text())
        payload["hook_event_name"] = "PostToolUseFailure"
        self.assertEqual(lw.own_write_from_payload(payload), [])

    def test_non_mcp_tool_gives_nothing(self):
        payload = json.loads((FIXTURES / "save-comment-created.json").read_text())
        payload["tool_name"] = "save_comment"
        self.assertEqual(lw.own_write_from_payload(payload), [])

    def test_garbage_gives_nothing(self):
        for payload in (None, [], "x", 3, {"tool_name": 4}, {"tool_response": [1, None]}):
            with self.subTest(payload=payload):
                self.assertEqual(lw.own_write_from_payload(payload), [])


class HookScriptTest(OwnWritesCase):
    def assert_silent_success(self, proc: subprocess.CompletedProcess):
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout, b"")
        self.assertEqual(proc.stderr, b"")

    def test_each_fixture_writes_the_expected_rows(self):
        for name, expected in EXPECTED.items():
            with self.subTest(fixture=name):
                if self.db.exists():
                    self.db.unlink()
                proc = self.run_hook(self.fixture(name))
                self.assert_silent_success(proc)
                self.assertEqual(self.rows(), sorted(expected))

    def test_two_own_moves_leave_the_latest_state(self):
        self.run_hook(self.fixture("save-issue-state.json"))
        self.run_hook(self.fixture("save-issue-state-again.json"))
        self.assertEqual(self.rows(), [("state", "TT-2117", "Done")])

    def test_garbage_stdin_is_silent(self):
        for stdin in (b"", b"not json", b"[]", b'{"tool_name": "mcp__x__save_comment"}'):
            with self.subTest(stdin=stdin):
                self.assert_silent_success(self.run_hook(stdin))
        self.assertEqual(self.rows(), [])

    def test_unopenable_store_is_silent(self):
        blocker = Path(self._tmp.name) / "a-file"
        blocker.write_text("not a directory")
        proc = self.run_hook(
            self.fixture("save-comment-created.json"), LW_STATE_DIR=str(blocker / "state")
        )
        self.assert_silent_success(proc)

    def test_disabled_by_lw_hooks_0(self):
        proc = self.run_hook(self.fixture("save-comment-created.json"), LW_HOOKS="0")
        self.assert_silent_success(proc)
        self.assertEqual(self.rows(), [])

    def test_lw_bin_overrides_the_sibling_path(self):
        proc = self.run_hook(
            self.fixture("save-comment-created.json"), LW_BIN=str(Path(self._tmp.name) / "nope")
        )
        self.assert_silent_success(proc)
        self.assertEqual(self.rows(), [])
        proc = self.run_hook(self.fixture("save-comment-created.json"), LW_BIN=str(LW_PATH))
        self.assert_silent_success(proc)
        self.assertEqual(self.rows(), [("comment", COMMENT_ID, None)])

    def test_without_python_is_silent(self):
        proc = self.run_hook(self.fixture("save-comment-created.json"), PATH="/nonexistent")
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, b"")
        self.assertEqual(self.rows(), [])


if __name__ == "__main__":
    unittest.main()
