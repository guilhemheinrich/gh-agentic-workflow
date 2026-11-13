"""LW-11 — the dependency graph is rebuilt on every state change.

`lw graph` runs the renderer (linear_deps.py) with the host Python and replaces
one `<slug>.svg` + `<slug>.json` pair per project. The renderer is a fake
(tests/bin/linear_deps_fake.py, selected by LW_GRAPH_RENDERER); Linear is the
fake CLI of tests/bin/linear. Nothing writes to the real ~/linear-graphs: HOME
and LW_GRAPH_DIR point into a temp dir.
Run in Docker: bash skills/linear-tracker/tests/linear-watch/run-in-docker.sh test_graph
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from datetime import datetime
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
from pathlib import Path
from unittest import mock

TESTS = Path(__file__).resolve().parent
SKILL = TESTS.parents[1]
LW_PATH = SKILL / "scripts" / "lw"
HOOK = SKILL / "adapters" / "claude" / "own-writes-hook.sh"
FAKE_LINEAR = TESTS / "bin" / "linear"
FAKE_DEPS = TESTS / "bin" / "linear_deps_fake.py"
FIXTURES = TESTS / "fixtures" / "linear-real"
MCP_FIXTURES = TESTS / "fixtures" / "mcp-responses"
BASH = shutil.which("bash") or "/bin/bash"


def load_lw():
    loader = SourceFileLoader("lw_graph", str(LW_PATH))
    spec = spec_from_loader("lw_graph", loader)
    module = module_from_spec(spec)
    loader.exec_module(module)
    return module


lw = load_lw()

TEST_KEY = "lin_api_TESTkey0123456789abcdefghijklmnopqrstuv"
PROJECT = "5842ed0c2bcd"
PROJECT_URL = f"https://linear.app/septeo-proptech/project/redacted-name-{PROJECT}"
SLUG = "redacted-name"
DAY = "2026-11-12"
TT207_LINE = "Linear · TT-207 Blocked → Todo · https://linear.app/septeo-proptech/issue/TT-207"


def at(hhmmss: str) -> datetime:
    return datetime.fromisoformat(f"{DAY}T{hhmmss}+00:00")


class SlugTest(unittest.TestCase):
    def test_slug_is_the_name_part_without_the_slug_id(self):
        self.assertEqual(
            lw.graph_slug("https://linear.app/septeo-proptech/project/"
                          "broker-pa-run-evolutions-courant-5842ed0c2bcd"),
            "broker-pa-run-evolutions-courant")

    def test_trailing_page_and_query_are_ignored(self):
        self.assertEqual(lw.graph_slug(PROJECT_URL + "/overview?x=1"), SLUG)

    def test_a_name_with_hyphens_and_digits_keeps_them(self):
        self.assertEqual(
            lw.graph_slug("https://linear.app/w/project/calendar-notifications-seule-and-iam-agence-0123456789ab"),
            "calendar-notifications-seule-and-iam-agence")

    def test_a_slug_id_alone_has_no_name(self):
        with self.assertRaises(lw.LwError):
            lw.graph_slug(f"https://linear.app/w/project/{PROJECT}")

    def test_an_unsafe_name_never_leaves_the_folder(self):
        slug = lw.graph_slug("https://linear.app/w/project/..%2F..%2Fetc-0123456789ab")
        self.assertNotIn("/", slug)
        self.assertFalse(slug.startswith("."))

    def test_not_a_project_url(self):
        with self.assertRaises(lw.LwError):
            lw.graph_slug("https://example.com/whatever")


class GraphCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.state = self.tmp / "state"
        self.graphs = self.tmp / "graphs"
        self.deps_log = self.tmp / "deps.jsonl"
        self.linear_log = self.tmp / "linear.jsonl"
        env = {
            "HOME": str(self.home),
            "TZ": "UTC",
            "LW_STATE_DIR": str(self.state),
            "LW_GRAPH_DIR": str(self.graphs),
            "LW_GRAPH_RENDERER": str(FAKE_DEPS),
            "LW_LINEAR_BIN": str(FAKE_LINEAR),
            "LINEAR_API_KEY": TEST_KEY,
            "FAKE_DEPS_LOG": str(self.deps_log),
            "FAKE_LINEAR_LOG": str(self.linear_log),
        }
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)
        for var in ("LW_GRAPH", "FAKE_DEPS_FAIL", "FAKE_DEPS_LEAK_KEY", "FAKE_DEPS_WAIT_FILE",
                    "FAKE_DEPS_STARTED", "FAKE_DEPS_DELAY", "FAKE_LINEAR_MODE",
                    "FAKE_LINEAR_FIXTURE", "FAKE_LINEAR_FIXTURE_DIR", "FAKE_LINEAR_NOW"):
            os.environ.pop(var, None)
        time.tzset()
        self.addCleanup(time.tzset)
        lw.reset_linear_bin()
        self.addCleanup(lw.reset_linear_bin)

    # ── helpers ───────────────────────────────────────────────────────────────
    def run_lw(self, *args: str, clock: str | None = None) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.ExitStack() as stack:
            stack.enter_context(contextlib.redirect_stdout(out))
            stack.enter_context(contextlib.redirect_stderr(err))
            if clock:
                stack.enter_context(mock.patch.object(lw, "now", return_value=at(clock)))
                stack.enter_context(mock.patch.dict(
                    os.environ, {"FAKE_LINEAR_NOW": at(clock).strftime("%Y-%m-%dT%H:%M:%SZ")}))
            code = lw.main(["--state-dir", str(self.state), *args])
        return code, out.getvalue(), err.getvalue()

    def ok(self, *args: str, clock: str | None = None) -> str:
        code, out, err = self.run_lw(*args, clock=clock)
        self.assertEqual(code, 0, f"lw {' '.join(args)} failed: {out}{err}")
        return out

    def deps_calls(self) -> list[dict]:
        if not self.deps_log.exists():
            return []
        return [json.loads(line) for line in self.deps_log.read_text().splitlines()]

    def linear_ops(self) -> list[str]:
        if not self.linear_log.exists():
            return []
        ops = []
        for line in self.linear_log.read_text().splitlines():
            doc = json.loads(line)["stdin"].split()
            ops.append(doc[1].split("(")[0] if len(doc) > 1 else "")
        return ops

    def graph_files(self) -> list[str]:
        return sorted(p.name for p in self.graphs.iterdir()) if self.graphs.exists() else []

    def daemon_log(self) -> str:
        path = self.state / "daemon.log"
        return path.read_text() if path.exists() else ""

    def db(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.state / "lw.sqlite")
        conn.row_factory = sqlite3.Row
        self.addCleanup(conn.close)
        return conn


class GraphCommandTest(GraphCase):
    def test_project_url_writes_the_pair_named_after_the_project(self):
        out = self.ok("graph", "--project", PROJECT_URL)
        self.assertEqual(self.graph_files(), [f"{SLUG}.json", f"{SLUG}.svg"])
        self.assertIn(PROJECT_URL, (self.graphs / f"{SLUG}.svg").read_text())
        self.assertEqual(json.loads((self.graphs / f"{SLUG}.json").read_text())["project"], PROJECT_URL)
        self.assertIn(SLUG, out)
        self.assertEqual(self.linear_ops(), [])  # a full URL needs no API call

    def test_renderer_gets_the_url_and_temp_files_in_the_graph_folder(self):
        self.ok("graph", "--project", PROJECT_URL)
        (call,) = self.deps_calls()
        argv = call["argv"]
        self.assertEqual(argv[0], PROJECT_URL)
        svg, js = argv[argv.index("-o") + 1], argv[argv.index("--json-out") + 1]
        # same folder as the final files, so os.replace is atomic; never the final name
        for tmp, final in ((svg, f"{SLUG}.svg"), (js, f"{SLUG}.json")):
            self.assertEqual(Path(tmp).parent, self.graphs)
            self.assertNotEqual(Path(tmp).name, final)
        self.assertEqual(self.graph_files(), [f"{SLUG}.json", f"{SLUG}.svg"])  # no leftover temp

    def test_renderer_runs_with_the_host_python(self):
        with mock.patch.object(lw.subprocess, "run", wraps=subprocess.run) as run:
            self.ok("graph", "--project", PROJECT_URL)
        cmd = [c.args[0] for c in run.call_args_list if str(FAKE_DEPS) in c.args[0]]
        self.assertEqual(cmd[0][0], sys.executable)

    def test_key_reaches_the_renderer_by_environment_never_by_argv(self):
        self.ok("graph", "--project", PROJECT_URL)
        (call,) = self.deps_calls()
        self.assertTrue(call["key_received"])
        self.assertNotIn(TEST_KEY, json.dumps(call["argv"]))

    def test_key_is_read_from_the_linear_env_file_when_the_environment_has_none(self):
        os.environ.pop("LINEAR_API_KEY")
        env_file = self.home / ".config" / "linear" / "env"
        env_file.parent.mkdir(parents=True)
        env_file.write_text(f"LINEAR_API_KEY={TEST_KEY}\n")
        self.ok("graph", "--project", PROJECT_URL)
        self.assertTrue(self.deps_calls()[0]["key_received"])

    def test_default_folder_is_linear_graphs_in_home(self):
        os.environ.pop("LW_GRAPH_DIR")
        self.ok("graph", "--project", PROJECT_URL)
        self.assertTrue((self.home / "linear-graphs" / f"{SLUG}.svg").exists())

    def test_a_slug_id_is_resolved_to_the_project_url_through_the_api(self):
        self.ok("graph", "--project", PROJECT)
        self.assertEqual(self.linear_ops(), ["GraphProject"])
        self.assertTrue((self.graphs / f"{SLUG}.svg").exists())

    def test_an_issue_is_resolved_to_its_project_through_the_api(self):
        self.ok("graph", "--issue", "TT-207")
        self.assertEqual(self.linear_ops(), ["GraphIssueProject"])
        self.assertEqual(self.deps_calls()[0]["argv"][0], PROJECT_URL)
        self.assertTrue((self.graphs / f"{SLUG}.svg").exists())

    def test_an_unknown_issue_or_one_without_project_is_a_usage_error(self):
        for ident in ("TT-9999", "TT-9998"):
            code, _, err = self.run_lw("graph", "--issue", ident)
            self.assertEqual(code, 2, ident)
            self.assertIn(ident, err)
        self.assertEqual(self.graph_files(), [])

    def test_a_second_run_overwrites_in_place(self):
        self.ok("graph", "--project", PROJECT_URL)
        self.ok("graph", "--project", PROJECT_URL)
        self.assertEqual(self.graph_files(), [f"{SLUG}.json", f"{SLUG}.svg"])
        self.assertIn("#2", (self.graphs / f"{SLUG}.svg").read_text())

    def test_project_or_issue_is_required(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            lw.main(["--state-dir", str(self.state), "graph"])


class AtomicReplaceTest(GraphCase):
    def seed_old(self) -> None:
        self.graphs.mkdir()
        (self.graphs / f"{SLUG}.svg").write_text("OLD SVG")
        (self.graphs / f"{SLUG}.json").write_text("OLD JSON")

    def test_failed_renderer_leaves_the_previous_files_untouched(self):
        self.seed_old()
        os.environ["FAKE_DEPS_FAIL"] = "1"
        code, _, err = self.run_lw("graph", "--project", PROJECT_URL)
        self.assertEqual(code, 1)
        self.assertIn("HTTP 500", err)
        self.assertEqual((self.graphs / f"{SLUG}.svg").read_text(), "OLD SVG")
        self.assertEqual((self.graphs / f"{SLUG}.json").read_text(), "OLD JSON")
        self.assertEqual(self.graph_files(), [f"{SLUG}.json", f"{SLUG}.svg"])  # temp files removed

    def test_a_failed_first_build_leaves_nothing(self):
        os.environ["FAKE_DEPS_FAIL"] = "1"
        self.assertEqual(self.run_lw("graph", "--project", PROJECT_URL)[0], 1)
        self.assertEqual(self.graph_files(), [])

    def test_a_reader_never_sees_a_half_file(self):
        self.seed_old()
        os.environ["FAKE_DEPS_DELAY"] = "0.5"
        seen: list[str] = []
        stop = threading.Event()

        def read():
            while not stop.is_set():
                seen.append((self.graphs / f"{SLUG}.svg").read_text())

        reader = threading.Thread(target=read)
        reader.start()
        try:
            self.ok("graph", "--project", PROJECT_URL)
        finally:
            stop.set()
            reader.join()
        self.assertTrue(seen)
        for text in seen:
            self.assertTrue(text == "OLD SVG" or text.endswith("</svg>\n"), text)

    def test_the_key_is_scrubbed_from_what_is_recorded(self):
        os.environ["FAKE_DEPS_LEAK_KEY"] = "1"
        code, out, err = self.run_lw("graph", "--project", PROJECT_URL)
        self.assertEqual(code, 1)
        everything = out + err + self.daemon_log() + "".join(
            p.read_text() for p in self.state.glob("graph-*.json"))
        self.assertNotIn(TEST_KEY, everything)
        self.assertIn("<key>", everything)

    def test_missing_credential_fails_without_running_the_renderer(self):
        os.environ.pop("LINEAR_API_KEY")
        code, _, err = self.run_lw("graph", "--project", PROJECT_URL)
        self.assertEqual(code, 1)
        self.assertIn("LINEAR_API_KEY", err)
        self.assertEqual(self.deps_calls(), [])


class CoalescingTest(GraphCase):
    def test_a_request_during_a_rebuild_is_coalesced_into_one_more_run(self):
        gate, started = self.tmp / "gate", self.tmp / "started"
        os.environ["FAKE_DEPS_WAIT_FILE"] = str(gate)
        os.environ["FAKE_DEPS_STARTED"] = str(started)
        first: list = []
        worker = threading.Thread(
            target=lambda: first.append(lw.rebuild_graph(self.state, PROJECT, PROJECT_URL)))
        worker.start()
        try:
            deadline = time.monotonic() + 10
            while not started.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(started.exists(), "the first renderer never started")
            late = [lw.rebuild_graph(self.state, PROJECT, PROJECT_URL) for _ in range(3)]
        finally:
            gate.write_text("go\n")
            worker.join(timeout=30)
        self.assertEqual([o.status for o in late], ["coalesced"] * 3)
        self.assertEqual(first[0].status, "rebuilt")
        # three requests while one ran: one extra run, not three
        self.assertEqual(len(self.deps_calls()), 2)

    def test_another_project_is_not_blocked(self):
        gate, started = self.tmp / "gate", self.tmp / "started"
        os.environ["FAKE_DEPS_WAIT_FILE"] = str(gate)
        os.environ["FAKE_DEPS_STARTED"] = str(started)
        worker = threading.Thread(target=lambda: lw.rebuild_graph(self.state, PROJECT, PROJECT_URL))
        worker.start()
        try:
            deadline = time.monotonic() + 10
            while not started.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            gate.write_text("go\n")  # the second project's renderer must not wait on the first's lock
            other = lw.rebuild_graph(self.state, "0123456789ab",
                                     "https://linear.app/septeo-proptech/project/other-0123456789ab")
        finally:
            gate.write_text("go\n")
            worker.join(timeout=30)
        self.assertEqual(other.status, "rebuilt")

    def test_sequential_requests_each_rebuild(self):
        for _ in range(2):
            self.assertEqual(lw.rebuild_graph(self.state, PROJECT, PROJECT_URL).status, "rebuilt")
        self.assertEqual(len(self.deps_calls()), 2)


class NoCreateTest(GraphCase):
    """The hook path (--no-create): rebuild what exists or what is watched, never a new file."""

    def test_unwatched_project_without_a_file_is_skipped(self):
        out = self.ok("graph", "--issue", "TT-207", "--no-create")
        self.assertIn("skipped", out)
        self.assertEqual(self.graph_files(), [])
        self.assertEqual(self.deps_calls(), [])

    def test_an_existing_file_is_rebuilt(self):
        self.graphs.mkdir()
        (self.graphs / f"{SLUG}.svg").write_text("OLD")
        self.ok("graph", "--issue", "TT-207", "--no-create")
        self.assertIn("#1", (self.graphs / f"{SLUG}.svg").read_text())
        self.assertEqual(self.graph_files(), [f"{SLUG}.json", f"{SLUG}.svg"])

    def test_a_watched_project_is_rebuilt_even_without_a_file(self):
        self.ok("subscribe", "--session", "s1", "--project", PROJECT_URL)
        self.ok("graph", "--issue", "TT-207", "--no-create")
        self.assertTrue((self.graphs / f"{SLUG}.svg").exists())

    def test_a_closed_subscription_does_not_count_as_watched(self):
        self.ok("subscribe", "--session", "s1", "--project", PROJECT_URL)
        self.ok("unsubscribe", "--session", "s1", "--all")
        self.ok("graph", "--issue", "TT-207", "--no-create")
        self.assertEqual(self.graph_files(), [])

    def test_the_function_refuses_too(self):
        outcome = lw.rebuild_graph(self.state, PROJECT, PROJECT_URL, create=False)
        self.assertEqual(outcome.status, "skipped")
        self.assertEqual(self.graph_files(), [])

    def test_manual_run_without_the_flag_creates_the_file(self):
        self.ok("graph", "--issue", "TT-207")
        self.assertTrue((self.graphs / f"{SLUG}.svg").exists())


class OwnWritesHookTest(GraphCase):
    """own-write --hook starts `lw graph --issue <id> --no-create` detached after a state move."""

    def hook_payload(self, name: str) -> str:
        return (MCP_FIXTURES / name).read_text()

    def run_hook_in_process(self, name: str) -> mock.MagicMock:
        popen = mock.MagicMock()
        with mock.patch.object(lw.subprocess, "Popen", popen), \
                mock.patch.object(sys, "stdin", io.StringIO(self.hook_payload(name))):
            self.assertEqual(lw.main(["--state-dir", str(self.state), "own-write", "--hook"]), 0)
        return popen

    def test_a_state_move_starts_a_detached_no_create_rebuild(self):
        popen = self.run_hook_in_process("save-issue-state.json")
        popen.assert_called_once()
        argv = popen.call_args.args[0]
        self.assertEqual(argv[0], sys.executable)
        self.assertEqual(argv[1], lw.LW_SCRIPT)
        self.assertEqual(argv[2:6], ["graph", "--issue", "TT-2117", "--no-create"])
        self.assertIn(str(self.state), argv)
        kwargs = popen.call_args.kwargs
        self.assertTrue(kwargs["start_new_session"])
        for stream in ("stdin", "stdout", "stderr"):
            self.assertEqual(kwargs[stream], subprocess.DEVNULL)
        self.assertNotIn(TEST_KEY, json.dumps(argv))

    def test_the_move_is_still_recorded(self):
        self.run_hook_in_process("save-issue-state.json")
        row = self.db().execute("SELECT value FROM own_writes WHERE ref = 'TT-2117'").fetchone()
        self.assertEqual(row["value"], "In Review")

    def test_a_comment_starts_nothing(self):
        self.run_hook_in_process("save-comment-created.json").assert_not_called()

    def test_a_save_issue_without_state_starts_nothing(self):
        self.run_hook_in_process("save-issue-no-state.json").assert_not_called()

    def test_a_failed_call_starts_nothing(self):
        self.run_hook_in_process("save-issue-error.json").assert_not_called()

    def test_lw_graph_0_starts_nothing(self):
        os.environ["LW_GRAPH"] = "0"
        self.run_hook_in_process("save-issue-state.json").assert_not_called()

    def test_a_spawn_failure_never_fails_the_hook(self):
        with mock.patch.object(lw.subprocess, "Popen", side_effect=OSError("no fork")), \
                mock.patch.object(sys, "stdin", io.StringIO(self.hook_payload("save-issue-state.json"))):
            self.assertEqual(lw.main(["--state-dir", str(self.state), "own-write", "--hook"]), 0)
        row = self.db().execute("SELECT value FROM own_writes WHERE ref = 'TT-2117'").fetchone()
        self.assertEqual(row["value"], "In Review")

    def run_shell_hook(self, name: str) -> tuple[subprocess.CompletedProcess, float]:
        env = dict(os.environ, PATH=os.environ.get("PATH", "/usr/bin:/bin"))
        started = time.monotonic()
        done = subprocess.run([BASH, str(HOOK)], input=self.hook_payload(name), capture_output=True,
                              text=True, env=env, timeout=30)
        return done, time.monotonic() - started

    def wait_for(self, predicate, seconds: float = 20.0) -> bool:
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if predicate():
                return True
            time.sleep(0.05)
        return False

    def test_shell_hook_returns_at_once_and_the_graph_follows(self):
        self.graphs.mkdir()
        (self.graphs / f"{SLUG}.svg").write_text("OLD")
        os.environ["FAKE_DEPS_DELAY"] = "2"
        done, elapsed = self.run_shell_hook("save-issue-state.json")
        self.assertEqual((done.returncode, done.stdout, done.stderr), (0, "", ""))
        self.assertEqual((self.graphs / f"{SLUG}.svg").read_text(), "OLD")  # not rebuilt yet
        self.assertLess(elapsed, 2.0)
        self.assertTrue(self.wait_for(lambda: "fake graph" in (self.graphs / f"{SLUG}.svg").read_text()))

    def test_shell_hook_never_creates_a_new_file(self):
        done, _ = self.run_shell_hook("save-issue-state.json")
        self.assertEqual(done.returncode, 0)
        # the detached child resolves the project and decides to skip; wait for its log line
        self.assertTrue(self.wait_for(lambda: "skipped" in self.daemon_log()), self.daemon_log())
        self.assertEqual(self.graph_files(), [])
        self.assertEqual(self.deps_calls(), [])


class CycleCase(GraphCase):
    """Real fixtures of LW-0: TT-207 goes Blocked → Todo at 15:48:31 (project 5842ed0c2bcd)."""

    def edited_fixtures(self, identifier: str, *, name: str, type_: str, updated: str) -> Path:
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

    def daemon_cycle(self, hhmmss: str) -> str:
        with mock.patch.object(lw, "now", return_value=at(hhmmss)), \
                mock.patch.dict(os.environ, {"FAKE_LINEAR_NOW": at(hhmmss).strftime("%Y-%m-%dT%H:%M:%SZ")}):
            return lw.daemon_cycle(self.state, self.tmp / "no-desktop")

    def baseline_tt207_blocked(self, *sessions: str) -> None:
        for session in sessions or ("s1",):
            self.ok("subscribe", "--session", session, "--project", PROJECT_URL, clock="15:20:00")
        blocked = self.edited_fixtures("TT-207", name="Blocked", type_="started",
                                       updated="2026-11-12T15:10:00.000Z")
        with mock.patch.dict(os.environ, {"FAKE_LINEAR_FIXTURE_DIR": str(blocked)}):
            self.daemon_cycle("15:20:00")

    def all_lines(self, session: str = "s1") -> list[str]:
        return [r["text"] for r in self.db().execute(
            "SELECT text FROM events WHERE session = ? ORDER BY ts, id", (session,))]

    def lines(self, session: str = "s1") -> list[str]:
        """The state-move lines only (the fixture day also holds many comments)."""
        return [line for line in self.all_lines(session) if "→" in line]


class DaemonRebuildTest(CycleCase):
    def test_a_transition_rebuilds_the_project_graph(self):
        self.baseline_tt207_blocked()
        self.assertEqual(self.deps_calls(), [])  # the baseline observes no transition
        self.daemon_cycle("15:50:00")
        (call,) = self.deps_calls()
        self.assertEqual(call["argv"][0], PROJECT_URL)
        self.assertIn("#1", (self.graphs / f"{SLUG}.svg").read_text())
        self.assertEqual(self.linear_ops().count("GraphProject"), 0)  # the cycle already knew the url

    def test_the_next_cycle_without_a_new_transition_rebuilds_nothing(self):
        self.baseline_tt207_blocked()
        self.daemon_cycle("15:50:00")
        self.daemon_cycle("15:55:00")  # TT-207 seen again in the overlap: no transition
        self.assertEqual(len(self.deps_calls()), 1)

    def test_an_own_transition_rebuilds_but_does_not_wake(self):
        self.baseline_tt207_blocked()
        self.ok("own-write", "--issue", "TT-207", "--state", "Todo", clock="15:48:32")
        self.daemon_cycle("15:50:00")
        self.assertEqual(self.lines(), [])
        self.assertEqual(len(self.deps_calls()), 1)
        self.assertTrue((self.graphs / f"{SLUG}.svg").exists())

    def test_one_rebuild_per_project_however_many_subscribers(self):
        self.baseline_tt207_blocked("s1", "s2")
        self.ok("subscribe", "--session", "s3", "--issue", "TT-207", clock="15:20:00")
        self.daemon_cycle("15:50:00")
        self.assertEqual(len(self.deps_calls()), 1)

    def test_graph_after_cycle_rebuilds_once_per_project_with_several_transitions(self):
        result = lw.CycleResult()
        other = "0123456789ab"
        other_url = "https://linear.app/septeo-proptech/project/other-0123456789ab"
        for ident in ("TT-1", "TT-2", "TT-3"):
            result.add_transition(PROJECT, PROJECT_URL, ident)
        result.add_transition(other, other_url, "TT-4")
        lw.graph_after_cycle(self.state, result)
        urls = sorted(call["argv"][0] for call in self.deps_calls())
        self.assertEqual(urls, sorted([PROJECT_URL, other_url]))

    def test_a_transition_without_a_known_url_is_resolved_through_the_api(self):
        result = lw.CycleResult()
        result.add_transition(PROJECT, None, "TT-207")
        lw.graph_after_cycle(self.state, result)
        self.assertEqual(self.linear_ops(), ["GraphProject"])
        self.assertEqual(self.deps_calls()[0]["argv"][0], PROJECT_URL)

    def test_an_issue_with_no_project_rebuilds_nothing(self):
        result = lw.CycleResult()
        result.add_transition(None, None, "TT-1")
        lw.graph_after_cycle(self.state, result)
        self.assertEqual(self.deps_calls(), [])

    def test_lw_graph_0_disables_the_daemon_rebuild(self):
        os.environ["LW_GRAPH"] = "0"
        self.baseline_tt207_blocked()
        self.daemon_cycle("15:50:00")
        self.assertEqual(self.deps_calls(), [])
        self.assertEqual(self.graph_files(), [])

    def test_a_failed_rebuild_never_fails_the_cycle_and_keeps_the_old_files(self):
        self.graphs.mkdir()
        (self.graphs / f"{SLUG}.svg").write_text("OLD")
        self.baseline_tt207_blocked()
        os.environ["FAKE_DEPS_FAIL"] = "1"
        text = self.daemon_cycle("15:50:00")
        self.assertNotIn("cycle failed", text)
        self.assertEqual((self.graphs / f"{SLUG}.svg").read_text(), "OLD")
        self.assertEqual(self.lines()[0].split(" · graph ")[0], TT207_LINE)

    def test_each_rebuild_is_logged_with_project_duration_and_result(self):
        self.baseline_tt207_blocked()
        self.daemon_cycle("15:50:00")
        entries = [line for line in self.daemon_log().splitlines() if "graph " in line]
        self.assertEqual(len(entries), 1, self.daemon_log())
        self.assertRegex(entries[0], rf"graph {SLUG} rebuilt in \d+(\.\d+)?s")
        os.environ["FAKE_DEPS_FAIL"] = "1"
        lw.rebuild_graph(self.state, PROJECT, PROJECT_URL)
        failed = [line for line in self.daemon_log().splitlines() if f"graph {SLUG} failed" in line]
        self.assertEqual(len(failed), 1, self.daemon_log())
        self.assertIn("HTTP 500", failed[0])


class WakeLineTest(CycleCase):
    def test_a_state_transition_line_ends_with_the_graph_path(self):
        self.baseline_tt207_blocked()
        self.daemon_cycle("15:50:00")
        self.assertEqual(self.lines(), [f"{TT207_LINE} · graph {self.graphs}/{SLUG}.svg"])

    def test_the_path_is_shown_with_a_tilde_under_home(self):
        os.environ.pop("LW_GRAPH_DIR")
        self.baseline_tt207_blocked()
        self.daemon_cycle("15:50:00")
        self.assertEqual(self.lines(), [f"{TT207_LINE} · graph ~/linear-graphs/{SLUG}.svg"])

    def test_the_line_names_the_path_even_for_an_issue_subscriber(self):
        self.ok("subscribe", "--session", "s2", "--issue", "TT-207", clock="15:20:00")
        self.baseline_tt207_blocked()
        self.daemon_cycle("15:50:00")
        (line,) = self.lines("s2")
        self.assertTrue(line.endswith(f" · graph {self.graphs}/{SLUG}.svg"), line)

    def test_lw_graph_0_drops_the_suffix(self):
        os.environ["LW_GRAPH"] = "0"
        self.baseline_tt207_blocked()
        self.daemon_cycle("15:50:00")
        self.assertEqual(self.lines(), [TT207_LINE])

    def test_a_comment_line_has_no_graph_suffix(self):
        self.ok("subscribe", "--session", "s1", "--project", PROJECT_URL, clock="15:40:00")
        self.daemon_cycle("15:40:00")
        self.daemon_cycle("15:50:00")
        comment_lines = [line for line in self.all_lines() if "comment by" in line]
        self.assertTrue(comment_lines)
        for line in comment_lines:
            self.assertNotIn(" · graph ", line)


class DoctorTest(GraphCase):
    def doctor(self) -> str:
        _, out, _ = self.run_lw("doctor")
        return out

    def test_no_rebuild_no_graph_line(self):
        self.assertNotIn("graph", self.doctor())

    def test_a_failed_rebuild_shows_up_and_a_later_success_clears_it(self):
        os.environ["FAKE_DEPS_FAIL"] = "1"
        self.assertEqual(self.run_lw("graph", "--project", PROJECT_URL)[0], 1)
        out = self.doctor()
        line = next(l for l in out.splitlines() if "graph" in l)
        self.assertTrue(line.startswith("warn "), line)
        self.assertIn(SLUG, line)
        self.assertIn("HTTP 500", line)
        os.environ.pop("FAKE_DEPS_FAIL")
        self.ok("graph", "--project", PROJECT_URL)
        line = next(l for l in self.doctor().splitlines() if "graph" in l)
        self.assertTrue(line.startswith("ok "), line)

    def test_a_graph_failure_is_not_fatal_to_the_doctor(self):
        os.environ["FAKE_DEPS_FAIL"] = "1"
        self.run_lw("graph", "--project", PROJECT_URL)
        # doctor's other checks fail here (no heartbeat), so compare with and without the failure
        before = self.run_lw("doctor", "--quiet")[0]
        (self.state / f"graph-{SLUG}.json").unlink()
        self.assertEqual(self.run_lw("doctor", "--quiet")[0], before)


if __name__ == "__main__":
    unittest.main()
