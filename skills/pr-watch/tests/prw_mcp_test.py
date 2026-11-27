"""Tests for mcp/prw_mcp.py: the MCP surface of lw, driven over stdio against a stub `prw`.

Run: docker run --rm -v "$PWD/..:/skills:ro" -w /skills/pr-watch/tests python:3.12-alpine python3 -B -m unittest -v prw_mcp_test
"""
import importlib.util
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "..", "mcp", "prw_mcp.py")

STUB = """#!/usr/bin/env python3
import os, sys
print("ARGV " + " ".join(sys.argv[1:]))
sys.exit(int(os.environ.get("STUB_EXIT", "0")))
"""


class McpTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.stub = os.path.join(self.dir.name, "prw")
        with open(self.stub, "w") as fh:
            fh.write(STUB)
        os.chmod(self.stub, os.stat(self.stub).st_mode | stat.S_IEXEC)

    def talk(self, *messages, exit_code=0):
        env = dict(os.environ, PRW_BIN=self.stub, STUB_EXIT=str(exit_code))
        p = subprocess.run([sys.executable, SERVER], input="\n".join(json.dumps(m) for m in messages) + "\n",
                           capture_output=True, text=True, env=env, timeout=30)
        return [json.loads(x) for x in p.stdout.splitlines()]

    def call(self, name, args, exit_code=0):
        (r,) = self.talk({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                          "params": {"name": name, "arguments": args}}, exit_code=exit_code)
        res = r["result"]
        return json.loads(res["content"][0]["text"]), res["isError"]

    def test_initialize_and_list_tools(self):
        out = self.talk({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
                        {"jsonrpc": "2.0", "method": "notifications/initialized"},
                        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        self.assertEqual(len(out), 2)                       # the notification gets no answer
        self.assertEqual(out[0]["result"]["serverInfo"]["name"], "prw")
        names = {t["name"] for t in out[1]["result"]["tools"]}
        self.assertEqual(names, {"prw_subscribe", "prw_unsubscribe", "prw_ignore_comment", "prw_list", "prw_status",
                                 "prw_wait", "prw_doctor", "prw_daemon"})
        for t in out[1]["result"]["tools"]:
            self.assertEqual(t["inputSchema"]["type"], "object")

    def test_subscribe_maps_to_the_cli(self):
        out, err = self.call("prw_subscribe", {"session": "s1", "repo": "ws/repo", "pr": 12})
        self.assertFalse(err)
        self.assertEqual(out["stdout"], "ARGV subscribe ws/repo 12 --session s1")
        out, _ = self.call("prw_subscribe", {"session": "s1", "branch": "feat/x", "repo": "github:o/r"})
        self.assertEqual(out["stdout"], "ARGV subscribe --branch feat/x --repo github:o/r --session s1")
        out, _ = self.call("prw_subscribe", {"session": "s1", "commit": "abc123"})
        self.assertEqual(out["stdout"], "ARGV subscribe --commit abc123 --session s1")

    def test_subscribe_needs_a_pr_or_a_branch_or_a_commit(self):
        res = self.talk({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                         "params": {"name": "prw_subscribe", "arguments": {"session": "s1"}}})[0]["result"]
        self.assertTrue(res["isError"])
        self.assertIn("repo", res["content"][0]["text"])

    def test_wait_is_bounded_and_reports_a_wake(self):
        out, err = self.call("prw_wait", {"session": "s1", "timeout": 9999})
        self.assertFalse(err)
        self.assertEqual(out["stdout"], "ARGV wait --session s1 --timeout 55")
        self.assertEqual((out["status"], out["lines"]), ("wake", ["ARGV wait --session s1 --timeout 55"]))

    def test_wait_timeout_is_not_an_error(self):
        out, err = self.call("prw_wait", {"session": "s1"}, exit_code=2)
        self.assertFalse(err)
        self.assertEqual((out["status"], out["lines"]), ("timeout", []))

    def test_wait_with_no_subscription_is_an_error(self):
        out, err = self.call("prw_wait", {"session": "s1"}, exit_code=3)
        self.assertTrue(err)
        self.assertEqual(out["status"], "no-open-subscription")

    def test_unsubscribe_ignore_status_and_daemon(self):
        out, _ = self.call("prw_unsubscribe", {"session": "s1", "repo": "ws/repo", "pr": 3})
        self.assertEqual(out["stdout"], "ARGV unsubscribe ws/repo 3 --session s1")
        out, _ = self.call("prw_ignore_comment", {"session": "s1", "repo": "ws/repo", "pr": 3, "comment_id": "99"})
        self.assertEqual(out["stdout"], "ARGV ignore-comment ws/repo 3 99 --session s1")
        out, _ = self.call("prw_status", {"repo": "ws/repo", "pr": 3})
        self.assertEqual(out["stdout"], "ARGV status ws/repo 3")
        out, _ = self.call("prw_daemon", {"action": "alive"})
        self.assertEqual(out["stdout"], "ARGV daemon alive")
        res = self.talk({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                         "params": {"name": "prw_daemon", "arguments": {"action": "run"}}})[0]["result"]
        self.assertTrue(res["isError"])    # `run` is the foreground loop, never an MCP call

    def test_a_failing_cli_is_an_error_result(self):
        out, err = self.call("prw_doctor", {}, exit_code=1)
        self.assertTrue(err)
        self.assertEqual(out["exit_code"], 1)

    def test_unknown_method_and_tool(self):
        (r,) = self.talk({"jsonrpc": "2.0", "id": 7, "method": "nope"})
        self.assertEqual(r["error"]["code"], -32601)
        (r,) = self.talk({"jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": {"name": "nope", "arguments": {}}})
        self.assertTrue(r["result"]["isError"])


def _load_module():
    spec = importlib.util.spec_from_file_location("prw_mcp", SERVER)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _fwd(path):
    return path.replace("\\", "/")


class UnrunnableCommandTests(unittest.TestCase):
    """A command that cannot start (missing file, WinError 193) must not kill the server."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.bogus = _fwd(os.path.join(self.dir.name, "does-not-exist", "prw"))
        self.mod = _load_module()

    def test_run_tool_returns_an_error_result_for_a_missing_command(self):
        with mock.patch.dict(os.environ, {"PRW_BIN": self.bogus}):
            out, is_err = self.mod.run_tool("prw_doctor", {})
        self.assertTrue(is_err)
        self.assertIsNone(out["exit_code"])
        self.assertIn(self.bogus, out["error"])
        self.assertIn("PRW_BIN", out["error"])
        self.assertEqual(out["command"][0], self.bogus)

    def test_error_names_the_variable_as_unset_when_not_configured(self):
        env = {k: v for k, v in os.environ.items() if k != "PRW_BIN"}
        with mock.patch.dict(os.environ, env, clear=True),                 mock.patch.object(self.mod.subprocess, "run", side_effect=OSError("boom")):
            out, is_err = self.mod.run_tool("prw_doctor", {})
        self.assertTrue(is_err)
        self.assertIn("PRW_BIN=unset", out["error"])
        self.assertIn("boom", out["error"])

    def test_windows_hint_points_to_the_cmd_wrapper(self):
        with mock.patch.dict(os.environ, {"PRW_BIN": self.bogus}),                 mock.patch.object(self.mod.sys, "platform", "win32"):
            out, _ = self.mod.run_tool("prw_doctor", {})
        self.assertIn("prw.cmd", out["error"])
        self.assertIn("forward slashes", out["error"])

    def test_the_server_survives_an_unrunnable_command_over_stdio(self):
        env = dict(os.environ, PRW_BIN=self.bogus)
        req = lambda i: {"jsonrpc": "2.0", "id": i, "method": "tools/call",
                         "params": {"name": "prw_doctor", "arguments": {}}}
        p = subprocess.run([sys.executable, SERVER], input=json.dumps(req(1)) + "\n" + json.dumps(req(2)) + "\n",
                           capture_output=True, text=True, env=env, timeout=30)
        replies = [json.loads(x) for x in p.stdout.splitlines()]
        self.assertEqual([r["id"] for r in replies], [1, 2])
        for r in replies:
            self.assertTrue(r["result"]["isError"])
            body = json.loads(r["result"]["content"][0]["text"])
            self.assertIn("PRW_BIN", body["error"])


class WindowsResolutionTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.mod = _load_module()
        self.bare = _fwd(os.path.join(self.dir.name, "prw"))
        for name in ("prw", "prw.cmd"):
            with open(os.path.join(self.dir.name, name), "w") as fh:
                fh.write("x")

    def command(self, value, platform="win32"):
        with mock.patch.dict(os.environ, {"PRW_BIN": value}),                 mock.patch.object(self.mod.sys, "platform", platform):
            return self.mod.prw_command()

    def test_bare_path_resolves_to_the_cmd_sibling(self):
        self.assertEqual(self.command(self.bare), [self.bare + ".cmd"])

    def test_extra_words_are_preserved(self):
        self.assertEqual(self.command(self.bare + " extra"), [self.bare + ".cmd", "extra"])

    def test_a_path_already_ending_in_cmd_is_unchanged(self):
        self.assertEqual(self.command(self.bare + ".cmd"), [self.bare + ".cmd"])

    def test_no_cmd_sibling_leaves_the_path_unchanged(self):
        os.remove(self.bare + ".cmd")
        self.assertEqual(self.command(self.bare), [self.bare])

    def test_other_platforms_keep_the_extensionless_path(self):
        self.assertEqual(self.command(self.bare, platform="linux"), [self.bare])


if __name__ == "__main__":
    unittest.main()
