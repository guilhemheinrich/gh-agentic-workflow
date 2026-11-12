"""LW-8 — Claude adapter: the SessionStart hook and `lw setup|uninstall --claude`.

Run in Docker: bash skills/linear-watch/tests/run-in-docker.sh test_claude_adapter

Every subprocess gets a temporary HOME, so ~/.claude/settings.json is always a
temp file. `lw daemon alive|start` (LW-7) are stubbed by a wrapper that logs
the call, prints noise on both streams and exits with the configured code;
every other command goes to the real scripts/lw.
"""

from __future__ import annotations

import json
import os
import shutil
import sqlite3
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

SKILL = Path(__file__).resolve().parent.parent
LW_PATH = SKILL / "scripts" / "lw"
ADAPTER = SKILL / "adapters" / "claude"
HOOK = ADAPTER / "session-start-hook.sh"
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "session-start"
BASH = shutil.which("bash") or "/bin/bash"
PYTHON = shutil.which("python3") or "python3"

SESSION = "3c2598fd-729b-4084-a255-3d867c98d822"  # the recorded payloads' id
OTHER = "00000000-0000-4000-8000-000000000099"
PROJECT = "5842ed0c2bcd"
OWN_WRITES_MATCHER = "mcp__.*__(save_comment|save_issue)"

STUB = textwrap.dedent(
    """\
    #!/usr/bin/env python3
    # stands in for lw: logs `daemon alive|start`, forwards the rest to the real lw
    import os, runpy, sys
    if sys.argv[1:2] == ["daemon"] and sys.argv[2:3] in (["alive"], ["start"]):
        action = sys.argv[2]
        with open(os.environ["LW_STUB_LOG"], "a") as fh:
            fh.write(action + "\\n")
        print("noise from daemon " + action)
        print("noise on stderr", file=sys.stderr)
        sys.exit(int(os.environ.get("LW_STUB_" + action.upper(), "0")))
    real = os.environ["LW_STUB_REAL"]
    sys.argv[0] = real
    runpy.run_path(real, run_name="__main__")
    """
)


class AdapterCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.state_dir = self.tmp / "state"
        self.stub = self.tmp / "lw-stub"
        self.stub.write_text(STUB)
        self.stub.chmod(0o755)
        self.log = self.tmp / "daemon.log"

    def tearDown(self):
        self._tmp.cleanup()

    def env(self, **extra) -> dict:
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": str(self.home),
            "LW_STATE_DIR": str(self.state_dir),
            "LW_STUB_LOG": str(self.log),
            "LW_STUB_REAL": str(LW_PATH),
            "LW_BIN": str(self.stub),
            "PYTHONDONTWRITEBYTECODE": "1",
        }
        env.update(extra)
        return {k: v for k, v in env.items() if v is not None}

    def lw(self, *args, stdin: str = "", **env) -> subprocess.CompletedProcess:
        return subprocess.run(
            [PYTHON, str(LW_PATH), *args], input=stdin, capture_output=True, text=True,
            env=self.env(**env), timeout=60,
        )

    def daemon_calls(self) -> list[str]:
        return self.log.read_text().split() if self.log.exists() else []

    def db(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.state_dir / "lw.sqlite")
        conn.row_factory = sqlite3.Row
        return conn


# ── SessionStart hook ─────────────────────────────────────────────────────────
class SessionStartHookTest(AdapterCase):
    def payload(self, name: str) -> str:
        return (FIXTURES / name).read_text()

    def hook(self, stdin: str, hook: Path = HOOK, **env) -> subprocess.CompletedProcess:
        return subprocess.run(
            [BASH, str(hook)], input=stdin, capture_output=True, text=True,
            env=self.env(**env), timeout=60,
        )

    def subscribe(self, session: str, *target: str) -> None:
        done = self.lw("subscribe", "--session", session, *target)
        self.assertEqual(done.returncode, 0, done.stderr)

    def age_renewals(self) -> None:
        with self.db() as conn:
            conn.execute("UPDATE subscriptions SET renewed_at = '2026-01-01T00:00:00Z'")

    def context(self, done: subprocess.CompletedProcess) -> str:
        self.assertEqual(done.returncode, 0, done.stderr)
        answer = json.loads(done.stdout)  # exactly one JSON document
        self.assertEqual(answer["hookSpecificOutput"]["hookEventName"], "SessionStart")
        return answer["hookSpecificOutput"]["additionalContext"]

    def test_fixtures_are_the_recorded_payloads(self):
        startup = json.loads(self.payload("startup.json"))
        resume = json.loads(self.payload("resume.json"))
        self.assertEqual((startup["source"], resume["source"]), ("startup", "resume"))
        self.assertEqual(startup["session_id"], resume["session_id"])  # resume keeps the id

    def test_startup_with_subscriptions_asks_to_arm_the_wait(self):
        self.subscribe(SESSION, "--project", PROJECT)
        self.subscribe(SESSION, "--issue", "TT-2287")
        context = self.context(self.hook(self.payload("startup.json")))
        self.assertIn(SESSION, context)
        self.assertIn(f"{LW_PATH} wait --session {SESSION}", context)
        self.assertIn("run_in_background", context)
        self.assertIn(f"project {PROJECT}", context)
        self.assertIn("issue TT-2287", context)
        self.assertIn("untrusted", context)
        self.assertNotIn("python3", context)  # the script is run by its path
        self.assertEqual(self.daemon_calls(), ["alive"])

    def test_resume_renews_the_session_subscriptions_only(self):
        self.subscribe(SESSION, "--project", PROJECT)
        self.subscribe(OTHER, "--project", PROJECT)
        self.age_renewals()
        context = self.context(self.hook(self.payload("resume.json")))
        self.assertIn(f"wait --session {SESSION}", context)
        with self.db() as conn:
            renewed = dict(conn.execute("SELECT session, renewed_at FROM subscriptions").fetchall())
        self.assertNotEqual(renewed[SESSION], "2026-01-01T00:00:00Z")
        self.assertEqual(renewed[OTHER], "2026-01-01T00:00:00Z")

    def test_without_subscription_gives_the_id_and_the_subscribe_command(self):
        self.subscribe(OTHER, "--project", PROJECT)
        self.subscribe(SESSION, "--issue", "TT-1")
        self.assertEqual(self.lw("unsubscribe", "--session", SESSION, "--all").returncode, 0)
        context = self.context(self.hook(self.payload("startup.json")))
        self.assertEqual(len(context.splitlines()), 1)
        self.assertIn(SESSION, context)
        self.assertIn(f"{LW_PATH} subscribe --session {SESSION}", context)
        self.assertNotIn("watches", context)

    def test_dead_daemon_is_started_and_its_noise_never_reaches_stdout(self):
        self.subscribe(SESSION, "--project", PROJECT)
        done = self.hook(self.payload("startup.json"), LW_STUB_ALIVE="1")
        self.context(done)
        self.assertEqual(self.daemon_calls(), ["alive", "start"])
        self.assertNotIn("noise", done.stdout + done.stderr)

    def test_failed_daemon_start_still_answers(self):
        self.subscribe(SESSION, "--project", PROJECT)
        done = self.hook(self.payload("startup.json"), LW_STUB_ALIVE="1", LW_STUB_START="1")
        self.assertIn("wait --session", self.context(done))

    def test_lw_hooks_0_disables_it(self):
        self.subscribe(SESSION, "--project", PROJECT)
        done = self.hook(self.payload("startup.json"), LW_HOOKS="0")
        self.assertEqual((done.returncode, done.stdout, done.stderr), (0, "", ""))
        self.assertEqual(self.daemon_calls(), [])

    def test_bad_payloads_are_silent(self):
        for stdin in ("", "not json", "[]", '{"session_id": 42}', '{"source": "startup"}',
                      '{"session_id": ""}'):
            with self.subTest(stdin=stdin):
                done = self.hook(stdin)
                self.assertEqual((done.returncode, done.stdout, done.stderr), (0, "", ""))
        self.assertEqual(self.daemon_calls(), [])

    def test_missing_lw_is_silent(self):
        done = self.hook(self.payload("startup.json"), LW_BIN=str(self.tmp / "nope"))
        self.assertEqual((done.returncode, done.stdout, done.stderr), (0, "", ""))

    def test_broken_store_is_silent(self):
        blocker = self.tmp / "a-file"
        blocker.write_text("")
        done = self.hook(self.payload("startup.json"), LW_STATE_DIR=str(blocker / "state"))
        self.assertEqual((done.returncode, done.stdout, done.stderr), (0, "", ""))

    def test_hook_finds_lw_next_to_itself(self):
        copy = self.tmp / "skill"
        shutil.copytree(SKILL / "scripts", copy / "scripts")
        shutil.copytree(ADAPTER, copy / "adapters" / "claude")
        self.subscribe(SESSION, "--project", PROJECT)
        # no LW_BIN: the copy's own scripts/lw answers (LW-7's daemon commands
        # may be missing there: the daemon step fails silently)
        done = self.hook(self.payload("startup.json"), copy / "adapters" / "claude" / HOOK.name,
                         LW_BIN=None)
        self.assertIn(f"{copy / 'scripts' / 'lw'} wait --session {SESSION}", self.context(done))

    def test_session_start_command_quotes_odd_ids(self):
        odd = "x'; rm -rf /"
        done = self.lw("session-start", "--session", odd)
        context = json.loads(done.stdout)["hookSpecificOutput"]["additionalContext"]
        self.assertIn("--session 'x'\"'\"'; rm -rf /'", context)


# ── setup / uninstall --claude ────────────────────────────────────────────────
EXISTING = {
    "permissions": {"allow": ["Bash(git status)"]},
    "hooks": {
        "SessionStart": [
            {"matcher": "startup|resume",
             "hooks": [{"type": "command", "command": "bash ~/.agents/hooks/pr-watch-session-start.sh"}]},
        ],
        "PostToolUse": [
            {"matcher": "Bash", "hooks": [{"type": "command", "command": "bash ~/.agents/hooks/pr-watch-push.sh"}]},
        ],
    },
    "model": "opus",
}


class SetupTest(AdapterCase):
    @property
    def settings(self) -> Path:
        return self.home / ".claude" / "settings.json"

    def write_settings(self, data) -> bytes:
        self.settings.parent.mkdir(parents=True, exist_ok=True)
        raw = (json.dumps(data, indent=4) if not isinstance(data, str) else data).encode()
        self.settings.write_bytes(raw)
        return raw

    def setup_claude(self, answer: str, lw: Path = LW_PATH, **env) -> subprocess.CompletedProcess:
        env.setdefault("LW_ALLOW_CHECKOUT", "1")
        return subprocess.run(
            [PYTHON, str(lw), "setup", "--claude"], input=answer, capture_output=True, text=True,
            env=self.env(**env), timeout=60,
        )

    def uninstall_claude(self, answer: str) -> subprocess.CompletedProcess:
        return self.lw("uninstall", "--claude", stdin=answer)

    def lw_entries(self, settings: dict) -> list[tuple[str, str, str]]:
        return sorted(
            (event, entry.get("matcher", ""), hook["command"])
            for event, entries in settings.get("hooks", {}).items()
            for entry in entries
            for hook in entry["hooks"]
            if "/linear-watch/adapters/claude/" in hook["command"]
        )

    def test_yes_on_a_fresh_home_registers_both_hooks(self):
        done = self.setup_claude("y\n")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("+", done.stdout)  # the diff was shown
        self.assertIn(OWN_WRITES_MATCHER, done.stdout)
        data = json.loads(self.settings.read_text())
        self.assertEqual(self.lw_entries(data), [
            ("PostToolUse", OWN_WRITES_MATCHER, f"bash {ADAPTER / 'own-writes-hook.sh'}"),
            ("SessionStart", "startup|resume", f"bash {ADAPTER / 'session-start-hook.sh'}"),
        ])
        for _, _, command in self.lw_entries(data):
            self.assertTrue(Path(command.split(" ", 1)[1]).is_file(), command)

    def test_existing_settings_are_kept(self):
        self.write_settings(EXISTING)
        self.assertEqual(self.setup_claude("yes\n").returncode, 0)
        data = json.loads(self.settings.read_text())
        self.assertEqual(data["permissions"], EXISTING["permissions"])
        self.assertEqual(data["model"], "opus")
        self.assertEqual(data["hooks"]["SessionStart"][0], EXISTING["hooks"]["SessionStart"][0])
        self.assertEqual(data["hooks"]["PostToolUse"][0], EXISTING["hooks"]["PostToolUse"][0])
        self.assertEqual(len(self.lw_entries(data)), 2)

    def test_no_or_eof_leaves_the_file_byte_identical(self):
        raw = self.write_settings(EXISTING)
        for answer in ("n\n", "", "\n", "maybe\n"):
            with self.subTest(answer=answer):
                done = self.setup_claude(answer)
                self.assertEqual(done.returncode, 0, done.stderr)
                self.assertIn("not applied", done.stdout)
                self.assertEqual(self.settings.read_bytes(), raw)

    def test_no_on_a_fresh_home_creates_nothing(self):
        self.setup_claude("n\n")
        self.assertFalse(self.settings.exists())

    def test_setup_twice_changes_nothing(self):
        self.write_settings(EXISTING)
        self.setup_claude("y\n")
        raw = self.settings.read_bytes()
        done = self.setup_claude("y\n")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("already", done.stdout)
        self.assertEqual(self.settings.read_bytes(), raw)

    def test_an_entry_from_another_installed_copy_is_replaced(self):
        stale = json.loads(json.dumps(EXISTING))
        stale["hooks"]["SessionStart"].append({"matcher": "startup|resume", "hooks": [
            {"type": "command", "command": "bash /old/.claude/skills/linear-watch/adapters/claude/session-start-hook.sh"}]})
        self.write_settings(stale)
        self.setup_claude("y\n")
        data = json.loads(self.settings.read_text())
        commands = [c for _, _, c in self.lw_entries(data)]
        self.assertEqual(len(commands), 2)
        self.assertFalse(any("/old/" in c for c in commands))

    def test_invalid_settings_are_refused_untouched(self):
        for text in ("{not json", "[1, 2]", '{"hooks": []}', '{"hooks": {"SessionStart": {}}}'):
            with self.subTest(text=text):
                raw = self.write_settings(text)
                done = self.setup_claude("y\n")
                self.assertEqual(done.returncode, 2)
                self.assertIn("lw:", done.stderr)
                self.assertEqual(self.settings.read_bytes(), raw)

    def test_refuses_to_run_from_a_checkout(self):
        for marker in (".git", "worktrees"):
            with self.subTest(marker=marker):
                root = self.tmp / marker / "repo" if marker == "worktrees" else self.tmp / "repo"
                if marker == ".git":
                    (root / ".git").mkdir(parents=True)
                copy = root / "skills" / "linear-watch"
                shutil.copytree(SKILL / "scripts", copy / "scripts")
                shutil.copytree(ADAPTER, copy / "adapters" / "claude")
                done = self.setup_claude("y\n", copy / "scripts" / "lw", LW_ALLOW_CHECKOUT=None)
                self.assertEqual(done.returncode, 2)
                self.assertIn("checkout", done.stderr)
                self.assertFalse(self.settings.exists())
                shutil.rmtree(root)

    def test_an_installed_copy_is_accepted(self):
        copy = self.home / ".agents" / "skills" / "linear-watch"
        shutil.copytree(SKILL / "scripts", copy / "scripts")
        shutil.copytree(ADAPTER, copy / "adapters" / "claude")
        done = self.setup_claude("y\n", copy / "scripts" / "lw", LW_ALLOW_CHECKOUT=None)
        self.assertEqual(done.returncode, 0, done.stderr)
        commands = [c for _, _, c in self.lw_entries(json.loads(self.settings.read_text()))]
        self.assertTrue(all(str(copy) in c for c in commands), commands)

    def test_setup_needs_claude(self):
        self.assertNotEqual(self.lw("setup").returncode, 0)
        self.assertNotEqual(self.lw("uninstall").returncode, 0)

    def test_registered_session_start_command_runs_end_to_end(self):
        self.setup_claude("y\n")
        self.lw("subscribe", "--session", SESSION, "--project", PROJECT)
        data = json.loads(self.settings.read_text())
        command = next(c for e, _, c in self.lw_entries(data) if e == "SessionStart")
        done = subprocess.run(
            [BASH, "-c", command], input=(FIXTURES / "startup.json").read_text(),
            capture_output=True, text=True, env=self.env(), timeout=60,
        )
        self.assertEqual(done.returncode, 0, done.stderr)
        context = json.loads(done.stdout)["hookSpecificOutput"]["additionalContext"]
        self.assertIn(f"wait --session {SESSION}", context)

    def test_uninstall_restores_the_original_settings(self):
        self.write_settings(EXISTING)
        self.setup_claude("y\n")
        done = self.uninstall_claude("y\n")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("-", done.stdout)
        self.assertEqual(json.loads(self.settings.read_text()), EXISTING)

    def test_uninstall_on_a_lw_only_file_leaves_no_empty_hooks(self):
        self.write_settings({"model": "opus"})
        self.setup_claude("y\n")
        self.uninstall_claude("y\n")
        self.assertEqual(json.loads(self.settings.read_text()), {"model": "opus"})

    def test_uninstall_no_leaves_the_file_byte_identical(self):
        self.write_settings(EXISTING)
        self.setup_claude("y\n")
        raw = self.settings.read_bytes()
        done = self.uninstall_claude("n\n")
        self.assertIn("not applied", done.stdout)
        self.assertEqual(self.settings.read_bytes(), raw)

    def test_uninstall_with_nothing_installed(self):
        raw = self.write_settings(EXISTING)
        done = self.uninstall_claude("y\n")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("nothing", done.stdout)
        self.assertEqual(self.settings.read_bytes(), raw)
        self.assertEqual(self.uninstall_claude("y\n").returncode, 0)  # twice is fine

    def test_uninstall_keeps_foreign_hooks_sharing_an_entry(self):
        mixed = {"hooks": {"PostToolUse": [{"matcher": OWN_WRITES_MATCHER, "hooks": [
            {"type": "command", "command": "bash /x/linear-watch/adapters/claude/own-writes-hook.sh"},
            {"type": "command", "command": "bash ~/mine.sh"},
        ]}]}}
        self.write_settings(mixed)
        self.uninstall_claude("y\n")
        data = json.loads(self.settings.read_text())
        self.assertEqual(data["hooks"]["PostToolUse"][0]["hooks"],
                         [{"type": "command", "command": "bash ~/mine.sh"}])


if __name__ == "__main__":
    unittest.main()
