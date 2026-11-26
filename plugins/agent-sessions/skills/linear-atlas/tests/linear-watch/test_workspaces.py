"""One credential per Linear workspace (issue 57): key selection, subscribe, poll, errors, doctor.

Every Linear call goes to the fake CLI in tests/bin/linear; FAKE_LINEAR_KEYS maps
each test key to a workspace so a call made with the wrong key is visible.
Run in Docker: bash skills/linear-atlas/tests/linear-watch/run-in-docker.sh test_workspaces
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import sqlite3
import sys
import unittest
from pathlib import Path

import test_cycle
from test_cycle import CycleCase, PROJECT, PROJECT_URL, NEWEST_LINE, lw

sys.path.insert(0, str(Path(test_cycle.LW_PATH).resolve().parent))
import linear_creds  # noqa: E402

# Made-up keys in the real key's shape; only the fake accepts them.
KEY_ACME = "lin_api_ACMEkey0123456789abcdefghijklmnopqrstuv"
KEY_OTHER = "lin_api_OTHERkey0123456789abcdefghijklmnopqrstu"
KEY_DEFAULT = "lin_api_DEFAULTkey0123456789abcdefghijklmnopqr"
OTHER_PROJECT = "0123456789ab"
OTHER_URL = "https://linear.app/other/project/side-project-0123456789ab/overview"


class WorkspaceCase(CycleCase):
    def setUp(self):
        super().setUp()
        self.home = self.tmp / "home"
        self.config = self.home / ".config" / "linear"
        self.config.mkdir(parents=True)
        os.environ.pop("LINEAR_API_KEY", None)
        os.environ["FAKE_LINEAR_KEYS"] = f"{KEY_ACME}=acme,{KEY_OTHER}=other,{KEY_DEFAULT}=acme"
        os.environ["FAKE_LINEAR_PROJECT_ORGS"] = f"{PROJECT}=acme,{OTHER_PROJECT}=other"
        self.addCleanup(lambda: [os.environ.pop(v, None)
                                 for v in ("FAKE_LINEAR_KEYS", "FAKE_LINEAR_PROJECT_ORGS")])

    def write_key(self, name: str, key: str) -> None:
        (self.config / name).write_text(f"LINEAR_API_KEY={key}\n")

    def two_workspaces(self) -> None:
        self.write_key("acme.env", KEY_ACME)
        self.write_key("other.env", KEY_OTHER)

    def doctor(self, *argv: str) -> tuple[int, str]:
        self.state_dir.mkdir(parents=True, exist_ok=True)
        (self.state_dir / lw.HEARTBEAT_FILE).touch()
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = lw.main(["doctor", "--state-dir", str(self.state_dir), *argv])
        text = out.getvalue() + err.getvalue()
        for key in (KEY_ACME, KEY_OTHER, KEY_DEFAULT):
            self.assertNotIn(key, text)
        return code, out.getvalue()

    def line(self, out: str, word: str) -> str:
        found = [l for l in out.splitlines() if word in l]
        self.assertTrue(found, f"no line with {word!r} in:\n{out}")
        return found[0]


class KeySelectionTest(WorkspaceCase):
    def test_workspace_file_beats_environment_and_default(self):
        self.write_key("acme.env", KEY_ACME)
        self.write_key("env", KEY_DEFAULT)
        os.environ["LINEAR_API_KEY"] = KEY_OTHER
        self.assertEqual(linear_creds.resolve("acme"), (KEY_ACME, "file"))

    def test_without_a_workspace_file_the_environment_then_the_default_serve(self):
        self.write_key("env", KEY_DEFAULT)
        self.assertEqual(linear_creds.resolve("acme"), (KEY_DEFAULT, "default file"))
        os.environ["LINEAR_API_KEY"] = KEY_OTHER
        self.assertEqual(linear_creds.resolve("acme"), (KEY_OTHER, "environment"))
        self.assertEqual(linear_creds.resolve(None), (KEY_OTHER, "environment"))

    def test_no_workspace_ignores_workspace_files(self):
        self.write_key("acme.env", KEY_ACME)
        self.assertEqual(linear_creds.resolve(None), (None, ""))

    def test_files_are_parsed_with_export_and_quotes(self):
        (self.config / "acme.env").write_text(f'# note\nexport LINEAR_API_KEY="{KEY_ACME}"\n')
        self.assertEqual(linear_creds.load_key("acme"), KEY_ACME)

    def test_missing_message_names_the_file_and_no_key(self):
        message = linear_creds.missing_message("acme")
        self.assertIn("~/.config/linear/acme.env", message)
        self.assertIn("workspace 'acme'", message)

    def test_workspace_from_url_and_normalization(self):
        self.assertEqual(linear_creds.workspace_from_url(PROJECT_URL), "acme")
        self.assertEqual(linear_creds.workspace_from_url("https://linear.app/Other/issue/TT-1"), "other")
        self.assertIsNone(linear_creds.workspace_from_url("5842ed0c2bcd"))
        self.assertIsNone(linear_creds.workspace_from_url("https://example.com/acme/project/x"))
        with self.assertRaises(ValueError):
            linear_creds.normalize_workspace("../etc")
        with self.assertRaises(ValueError):
            linear_creds.normalize_workspace("env")

    def test_configured_workspaces_lists_workspace_files_only(self):
        self.write_key("acme.env", KEY_ACME)
        self.write_key("other.env", KEY_OTHER)
        self.write_key("env", KEY_DEFAULT)
        (self.config / "notes.txt").write_text("x")
        self.assertEqual(linear_creds.configured_workspaces(), ["acme", "other"])

    def test_linear_api_uses_the_key_of_its_workspace(self):
        self.two_workspaces()
        body = lw.linear_api("query Workspace { organization { urlKey } }", state_dir=self.state_dir,
                             workspace="other")
        self.assertEqual(body["data"]["organization"]["urlKey"], "other")
        self.assertEqual([c["org"] for c in self.calls()], ["other"])


class SubscribeTest(WorkspaceCase):
    def rows(self) -> list[sqlite3.Row]:
        return self.db().execute("SELECT session, target, workspace FROM subscriptions ORDER BY id").fetchall()

    def test_workspace_comes_from_the_url(self):
        self.two_workspaces()
        out = self.ok("15:40:00", "subscribe", "--session", "s1", "--project", OTHER_URL)
        self.assertIn("workspace other", out)
        self.assertEqual([tuple(r) for r in self.rows()], [("s1", OTHER_PROJECT, "other")])

    def test_workspace_flag_for_a_bare_slug_id(self):
        self.two_workspaces()
        self.ok("15:40:00", "subscribe", "--session", "s1", "--project", OTHER_PROJECT, "--workspace", "other")
        self.assertEqual([tuple(r) for r in self.rows()], [("s1", OTHER_PROJECT, "other")])

    def test_a_flag_contradicting_the_url_is_refused(self):
        self.two_workspaces()
        code, _, err = self.run_lw("15:40:00", "subscribe", "--session", "s1", "--project", OTHER_URL,
                                   "--workspace", "acme")
        self.assertEqual(code, 2)
        self.assertIn("contradicts", err)
        self.assertEqual(self.rows(), [])

    def test_no_key_for_the_workspace_fails_naming_the_file(self):
        self.write_key("acme.env", KEY_ACME)
        code, _, err = self.run_lw("15:40:00", "subscribe", "--session", "s1", "--project", OTHER_URL)
        self.assertEqual(code, 2)
        self.assertIn("~/.config/linear/other.env", err)
        self.assertEqual(self.rows(), [])

    def test_the_old_single_file_setup_keeps_working(self):
        self.write_key("env", KEY_DEFAULT)
        self.ok("15:40:00", "subscribe", "--session", "s1", "--project", PROJECT_URL)
        self.ok("15:40:00", "subscribe", "--session", "s2", "--project", PROJECT)
        self.assertEqual([tuple(r) for r in self.rows()],
                         [("s1", PROJECT, "acme"), ("s2", PROJECT, None)])
        self.cycle("15:40:00")
        self.cycle("15:47:30")
        self.assertEqual(self.lines("s1"), [NEWEST_LINE])
        self.assertEqual(self.lines("s2"), [NEWEST_LINE])

    def test_a_bare_slug_needs_no_key_at_subscribe_time(self):
        self.ok("15:40:00", "subscribe", "--session", "s1", "--project", PROJECT)

    def test_list_reports_the_workspace_and_filters_on_it(self):
        self.two_workspaces()
        self.ok("15:40:00", "subscribe", "--session", "s1", "--project", PROJECT_URL)
        self.ok("15:40:00", "subscribe", "--session", "s2", "--project", OTHER_URL)
        everything = json.loads(self.ok("15:40:00", "list", "--json"))
        self.assertEqual({r["session"]: r["workspace"] for r in everything}, {"s1": "acme", "s2": "other"})
        only = json.loads(self.ok("15:40:00", "list", "--json", "--workspace", "other"))
        self.assertEqual([r["session"] for r in only], ["s2"])
        self.assertIn("[other]", self.ok("15:40:00", "list", "--session", "s2"))

    def test_a_store_of_the_previous_schema_is_migrated_in_place(self):
        self.state_dir.mkdir(parents=True)
        conn = sqlite3.connect(self.state_dir / "lw.sqlite")
        conn.executescript(lw.MIGRATIONS[0])
        conn.execute("PRAGMA user_version = 1")
        conn.execute("INSERT INTO subscriptions (session, harness, kind, target, created_at, renewed_at)"
                     " VALUES ('old', 'claude-code', 'project', ?, '2026-11-12T08:00:00Z', '2026-11-12T08:00:00Z')",
                     (PROJECT,))
        conn.commit()
        conn.close()
        self.write_key("env", KEY_DEFAULT)
        listed = json.loads(self.ok("15:40:00", "list", "--json"))
        self.assertEqual([(r["session"], r["workspace"]) for r in listed], [("old", None)])
        self.assertEqual(self.db().execute("PRAGMA user_version").fetchone()[0], len(lw.MIGRATIONS))
        self.cycle("15:47:30")  # the old row polls with the default key


class PollTest(WorkspaceCase):
    def test_wait_wakes_for_both_workspaces_each_poll_with_its_own_key(self):
        self.two_workspaces()
        self.subscribe("15:40:00", "s1", "--project", PROJECT_URL)
        self.subscribe("15:40:00", "s2", "--project", OTHER_URL)
        self.cycle("15:40:00")
        self.cycle("15:47:30")
        self.assertEqual(self.lines("s1"), [NEWEST_LINE])
        self.assertEqual(self.lines("s2"), [NEWEST_LINE])
        polled = {json.loads(c["argv"][2])["p"]: c["org"] for c in self.calls()
                  if "CommentsSince" in c["stdin"]}
        self.assertEqual(polled, {PROJECT: "acme", OTHER_PROJECT: "other"})
        for call in self.calls():  # no call ever crossed workspaces
            variables = json.loads(call["argv"][2])
            owner = {PROJECT: "acme", OTHER_PROJECT: "other"}.get(variables.get("p"))
            self.assertTrue(owner is None or owner == call["org"], call)
        code, out, err = self.run_lw("15:47:30", "wait", "--session", "s2", "--timeout", "0")
        self.assertEqual((code, NEWEST_LINE in out), (0, True), out + err)

    def test_issue_subscriptions_are_polled_per_workspace(self):
        self.two_workspaces()
        self.subscribe("15:40:00", "s1", "--issue", "https://linear.app/acme/issue/TT-2537")
        self.subscribe("15:40:00", "s2", "--issue", "https://linear.app/other/issue/TT-2519")
        self.cycle("15:40:00")
        orgs = {}
        for call in self.calls():
            if "WatchedIssues" in call["stdin"]:
                orgs[tuple(json.loads(call["argv"][2])["ids"])] = call["org"]
        self.assertEqual(orgs, {("TT-2537",): "acme", ("TT-2519",): "other"})

    def test_one_workspace_failing_does_not_silence_the_other(self):
        self.write_key("acme.env", KEY_ACME)  # other.env is missing: that poll has no key
        self.db_subscribe_without_check("s2", OTHER_PROJECT, "other")
        self.subscribe("15:40:00", "s1", "--project", PROJECT_URL)
        self.cycle_allow_errors("15:40:00")
        code, _, err = self.run_lw("15:47:30", "daemon", "once")
        self.assertEqual(code, 1)
        self.assertIn("~/.config/linear/other.env", err)
        self.assertEqual(self.lines("s1"), [NEWEST_LINE])

    def db_subscribe_without_check(self, session: str, target: str, workspace: str) -> None:
        self.state_dir.mkdir(parents=True, exist_ok=True)
        conn = lw.connect(self.state_dir)
        conn.execute("INSERT INTO subscriptions (session, harness, kind, target, created_at, renewed_at,"
                     " workspace) VALUES (?, 'claude-code', 'project', ?, '2026-11-12T08:00:00Z',"
                     " '2026-11-12T08:00:00Z', ?)", (session, target, workspace))
        conn.close()

    def cycle_allow_errors(self, hhmmss: str) -> None:
        self.run_lw(hhmmss, "daemon", "once")


class WrongWorkspaceTest(WorkspaceCase):
    def test_not_found_with_another_workspaces_key_says_so(self):
        self.write_key("env", KEY_DEFAULT)  # a key of workspace acme, used for the "other" project
        with self.assertRaises(lw.TransportError) as ctx:
            lw.linear_api(
                "query CommentsSince($since: DateTimeOrDuration!, $p: String!) { comments { nodes { id } } }",
                {"since": "2026-11-12T08:00:00Z", "p": OTHER_PROJECT}, state_dir=self.state_dir,
                workspace="other")
        message = ctx.exception.message
        self.assertIn("belongs to workspace 'acme'", message)
        self.assertIn("~/.config/linear/other.env", message)
        self.assertNotIn(KEY_DEFAULT, message)
        self.assertNotIn("Entity not found", message)

    def test_not_found_with_the_right_key_keeps_linears_message(self):
        self.two_workspaces()
        os.environ["FAKE_LINEAR_PROJECT_ORGS"] = f"{PROJECT}=somewhere-else"
        with self.assertRaises(lw.TransportError) as ctx:
            lw.linear_api(
                "query CommentsSince($since: DateTimeOrDuration!, $p: String!) { comments { nodes { id } } }",
                {"since": "2026-11-12T08:00:00Z", "p": PROJECT}, state_dir=self.state_dir, workspace="acme")
        self.assertIn("not found", ctx.exception.message.lower())
        self.assertNotIn("belongs to workspace", ctx.exception.message)

    def test_the_poll_reports_the_wrong_workspace_on_stderr(self):
        self.write_key("env", KEY_DEFAULT)
        self.ok("15:40:00", "subscribe", "--session", "s2", "--project", OTHER_URL)
        code, _, err = self.run_lw("15:40:00", "daemon", "once")
        self.assertEqual(code, 1)
        self.assertIn("belongs to workspace 'acme'", err)
        self.assertNotIn(KEY_DEFAULT, err)


class DoctorTest(WorkspaceCase):
    def test_one_line_per_configured_workspace(self):
        self.two_workspaces()
        self.subscribe("15:40:00", "s1", "--project", PROJECT_URL)
        self.subscribe("15:40:00", "s2", "--project", OTHER_URL)
        self.subscribe("15:40:00", "s3", "--issue", "https://linear.app/other/issue/TT-2519")
        self.cycle("15:40:00")
        code, out = self.doctor()
        self.assertEqual(code, 0, out)
        acme, other = self.line(out, "workspace acme"), self.line(out, "workspace other")
        self.assertTrue(acme.startswith("ok"), acme)
        self.assertIn("credential present (~/.config/linear/acme.env)", acme)
        self.assertIn("accepted", acme)
        self.assertIn("1 subscription(s)", acme)
        self.assertIn("2 subscription(s)", other)

    def test_a_missing_credential_fails_and_names_the_file(self):
        self.write_key("acme.env", KEY_ACME)
        self.db_subscribe("s2", OTHER_PROJECT, "other")
        code, out = self.doctor()
        self.assertEqual(code, 1)
        line = self.line(out, "workspace other")
        self.assertTrue(line.startswith("FAIL"), line)
        self.assertIn("~/.config/linear/other.env", line)
        self.assertIn("1 subscription(s)", line)

    def test_a_rejected_credential_fails_for_that_workspace_only(self):
        self.two_workspaces()
        os.environ["FAKE_LINEAR_KEYS"] = f"{KEY_ACME}=acme"  # the other key is now refused
        self.subscribe("15:40:00", "s1", "--project", PROJECT_URL)
        self.subscribe("15:40:00", "s2", "--project", OTHER_URL)
        self.run_lw("15:40:00", "daemon", "once")
        code, out = self.doctor()
        self.assertEqual(code, 1)
        self.assertTrue(self.line(out, "workspace acme").startswith("ok"), out)
        other = self.line(out, "workspace other")
        self.assertTrue(other.startswith("FAIL"), other)
        self.assertIn("rejected", other)
        self.assertNotIn(KEY_OTHER, other)

    def test_the_default_credential_is_optional_when_every_subscription_names_a_workspace(self):
        self.two_workspaces()
        self.subscribe("15:40:00", "s1", "--project", PROJECT_URL)
        code, out = self.doctor()
        self.assertEqual(code, 0, out)
        self.assertNotIn("credential missing: no LINEAR_API_KEY", out)

    def test_workspace_flag_restricts_the_report(self):
        self.two_workspaces()
        _, out = self.doctor("--workspace", "other")
        self.assertIn("workspace other", out)
        self.assertNotIn("workspace acme", out)

    def test_the_default_line_still_reports_the_single_file_setup(self):
        self.write_key("env", KEY_DEFAULT)
        code, out = self.doctor()
        self.assertEqual(code, 0, out)
        self.assertIn("credential present (~/.config/linear/env)", out)

    def db_subscribe(self, session: str, target: str, workspace: str) -> None:
        self.state_dir.mkdir(parents=True, exist_ok=True)
        conn = lw.connect(self.state_dir)
        conn.execute("INSERT INTO subscriptions (session, harness, kind, target, created_at, renewed_at,"
                     " workspace) VALUES (?, 'claude-code', 'project', ?, '2026-11-12T08:00:00Z',"
                     " '2026-11-12T08:00:00Z', ?)", (session, target, workspace))
        conn.close()


class NoSecretTest(WorkspaceCase):
    def test_a_key_never_reaches_argv(self):
        self.two_workspaces()
        self.subscribe("15:40:00", "s1", "--project", PROJECT_URL)
        self.cycle("15:40:00")
        text = (self.log).read_text()
        for key in (KEY_ACME, KEY_OTHER):
            self.assertNotIn(key, text)

    def test_one_workspaces_failure_never_prints_another_workspaces_key(self):
        self.two_workspaces()
        os.environ["FAKE_LINEAR_KEYS"] = f"{KEY_ACME}=acme"
        with self.assertRaises(lw.TransportError) as ctx:
            lw.linear_api("query Workspace { organization { urlKey } }", state_dir=self.state_dir,
                          workspace="other")
        self.assertNotIn(KEY_OTHER, str(ctx.exception))
        self.assertNotIn(KEY_ACME, str(ctx.exception))
        status = (self.state_dir / lw.TRANSPORT_FILE).read_text()
        self.assertNotIn(KEY_OTHER, status)
        self.assertNotIn(KEY_ACME, status)
        self.assertEqual(lw.read_transport_status(self.state_dir, "other")["last_error"]["code"], lw.T_CREDENTIAL)
        self.assertEqual(lw.read_transport_status(self.state_dir, "acme"), {})


if __name__ == "__main__":
    unittest.main()
