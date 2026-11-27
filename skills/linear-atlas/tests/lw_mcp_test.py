"""Tests for mcp/lw_mcp.py: the MCP surface of lw, driven over stdio against a stub `lw`.

Run: docker run --rm -v "$PWD/..:/skills:ro" -w /skills/linear-atlas/tests python:3.12-alpine python3 -B -m unittest -v lw_mcp_test
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
SERVER = os.path.join(HERE, "..", "mcp", "lw_mcp.py")

STUB = """#!/usr/bin/env python3
import os, sys
print("ARGV " + " ".join(sys.argv[1:]))
sys.exit(int(os.environ.get("STUB_EXIT", "0")))
"""


class McpTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.stub = os.path.join(self.dir.name, "lw")
        with open(self.stub, "w") as fh:
            fh.write(STUB)
        os.chmod(self.stub, os.stat(self.stub).st_mode | stat.S_IEXEC)

    def talk(self, *messages, exit_code=0):
        env = dict(os.environ, LW_BIN=self.stub, STUB_EXIT=str(exit_code))
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
        self.assertEqual(out[0]["result"]["serverInfo"]["name"], "lw")
        names = {t["name"] for t in out[1]["result"]["tools"]}
        self.assertEqual(names, {"lw_subscribe", "lw_unsubscribe", "lw_list", "lw_wait", "lw_own_write",
                                 "lw_expire", "lw_doctor", "lw_graph"})
        for t in out[1]["result"]["tools"]:
            self.assertEqual(t["inputSchema"]["type"], "object")

    def test_subscribe_maps_to_the_cli(self):
        out, err = self.call("lw_subscribe", {"session": "s1", "project": "broker-pa", "since": "3d"})
        self.assertFalse(err)
        self.assertEqual(out["stdout"], "ARGV subscribe --session s1 --project broker-pa --since 3d")

    def test_subscribe_needs_a_target_and_a_session(self):
        out, err = self.talk({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                              "params": {"name": "lw_subscribe", "arguments": {"session": "s1"}}})[0]["result"], None
        self.assertTrue(out["isError"])
        self.assertIn("project", out["content"][0]["text"])

    def test_workspace_is_passed_to_subscribe_list_and_doctor(self):
        out, _ = self.call("lw_subscribe", {"session": "s1", "project": "0123456789ab", "workspace": "other"})
        self.assertEqual(out["stdout"], "ARGV subscribe --session s1 --project 0123456789ab --workspace other")
        out, _ = self.call("lw_list", {"workspace": "other"})
        self.assertEqual(out["stdout"], "ARGV list --json --workspace other")
        out, _ = self.call("lw_doctor", {"workspace": "other"})
        self.assertEqual(out["stdout"], "ARGV doctor --workspace other")
        out, _ = self.call("lw_doctor", {})
        self.assertEqual(out["stdout"], "ARGV doctor")

    def test_workspace_is_in_the_tool_schemas(self):
        out = self.talk({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
        tools = {t["name"]: t["inputSchema"]["properties"] for t in out[0]["result"]["tools"]}
        for name in ("lw_subscribe", "lw_list", "lw_doctor"):
            self.assertIn("workspace", tools[name])

    def test_wait_is_bounded_and_reports_a_wake(self):
        out, err = self.call("lw_wait", {"session": "s1", "timeout": 9999})
        self.assertFalse(err)
        self.assertEqual(out["stdout"], "ARGV wait --session s1 --timeout 55")
        self.assertEqual((out["status"], out["lines"]), ("wake", ["ARGV wait --session s1 --timeout 55"]))

    def test_wait_timeout_is_not_an_error(self):
        out, err = self.call("lw_wait", {"session": "s1"}, exit_code=2)
        self.assertFalse(err)
        self.assertEqual((out["status"], out["lines"]), ("timeout", []))

    def test_wait_with_no_subscription_is_an_error(self):
        out, err = self.call("lw_wait", {"session": "s1"}, exit_code=3)
        self.assertTrue(err)
        self.assertEqual(out["status"], "no-open-subscription")

    def test_unsubscribe_all_and_own_write(self):
        out, _ = self.call("lw_unsubscribe", {"session": "s1", "all": True})
        self.assertEqual(out["stdout"], "ARGV unsubscribe --session s1 --all")
        out, _ = self.call("lw_own_write", {"issue": "TT-1", "state": "Done"})
        self.assertEqual(out["stdout"], "ARGV own-write --issue TT-1 --state Done")

    def test_a_failing_cli_is_an_error_result(self):
        out, err = self.call("lw_doctor", {}, exit_code=1)
        self.assertTrue(err)
        self.assertEqual(out["exit_code"], 1)

    def test_unknown_method_and_tool(self):
        (r,) = self.talk({"jsonrpc": "2.0", "id": 7, "method": "nope"})
        self.assertEqual(r["error"]["code"], -32601)
        (r,) = self.talk({"jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": {"name": "nope", "arguments": {}}})
        self.assertTrue(r["result"]["isError"])


def _load_module():
    spec = importlib.util.spec_from_file_location("lw_mcp", SERVER)
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
        self.bogus = _fwd(os.path.join(self.dir.name, "does-not-exist", "lw"))
        self.mod = _load_module()

    def test_run_tool_returns_an_error_result_for_a_missing_command(self):
        with mock.patch.dict(os.environ, {"LW_BIN": self.bogus}):
            out, is_err = self.mod.run_tool("lw_doctor", {})
        self.assertTrue(is_err)
        self.assertIsNone(out["exit_code"])
        self.assertIn(self.bogus, out["error"])
        self.assertIn("LW_BIN", out["error"])
        self.assertEqual(out["command"][0], self.bogus)

    def test_error_names_the_variable_as_unset_when_not_configured(self):
        env = {k: v for k, v in os.environ.items() if k != "LW_BIN"}
        with mock.patch.dict(os.environ, env, clear=True),                 mock.patch.object(self.mod.subprocess, "run", side_effect=OSError("boom")):
            out, is_err = self.mod.run_tool("lw_doctor", {})
        self.assertTrue(is_err)
        self.assertIn("LW_BIN=unset", out["error"])
        self.assertIn("boom", out["error"])

    def test_windows_hint_points_to_the_cmd_wrapper(self):
        with mock.patch.dict(os.environ, {"LW_BIN": self.bogus}),                 mock.patch.object(self.mod.sys, "platform", "win32"):
            out, _ = self.mod.run_tool("lw_doctor", {})
        self.assertIn("lw.cmd", out["error"])
        self.assertIn("forward slashes", out["error"])

    def test_the_server_survives_an_unrunnable_command_over_stdio(self):
        env = dict(os.environ, LW_BIN=self.bogus)
        req = lambda i: {"jsonrpc": "2.0", "id": i, "method": "tools/call",
                         "params": {"name": "lw_doctor", "arguments": {}}}
        p = subprocess.run([sys.executable, SERVER], input=json.dumps(req(1)) + "\n" + json.dumps(req(2)) + "\n",
                           capture_output=True, text=True, env=env, timeout=30)
        replies = [json.loads(x) for x in p.stdout.splitlines()]
        self.assertEqual([r["id"] for r in replies], [1, 2])
        for r in replies:
            self.assertTrue(r["result"]["isError"])
            body = json.loads(r["result"]["content"][0]["text"])
            self.assertIn("LW_BIN", body["error"])


class WindowsResolutionTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.mod = _load_module()
        self.bare = _fwd(os.path.join(self.dir.name, "lw"))
        for name in ("lw", "lw.cmd"):
            with open(os.path.join(self.dir.name, name), "w") as fh:
                fh.write("x")

    def command(self, value, platform="win32"):
        with mock.patch.dict(os.environ, {"LW_BIN": value}),                 mock.patch.object(self.mod.sys, "platform", platform):
            return self.mod.lw_command()

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
