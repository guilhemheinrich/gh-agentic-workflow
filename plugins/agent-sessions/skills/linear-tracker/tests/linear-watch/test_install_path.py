"""Installer for `lw` on PATH: scripts/install-lw-path.sh, in a sandbox HOME.

Run in Docker: bash skills/linear-tracker/tests/linear-watch/run-in-docker.sh test_install_path
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SKILL = Path(__file__).resolve().parents[2]
INSTALLER = SKILL / "scripts" / "install-lw-path.sh"
LW = SKILL / "scripts" / "lw"
SH = shutil.which("sh") or "/bin/sh"


class InstallPathTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.home = Path(self._tmp.name)
        (self.home / ".zshrc").write_text("export FOO=1\n")
        (self.home / ".bashrc").write_text("export BAR=1\n")
        (self.home / ".config/fish/conf.d").mkdir(parents=True)

    def run_installer(self, *args, check=True, checkout_ok=True):
        env = {"PATH": os.environ["PATH"], "HOME": str(self.home)}
        if checkout_ok:
            env["LW_ALLOW_CHECKOUT"] = "1"
        p = subprocess.run([SH, str(INSTALLER), *args], env=env, capture_output=True, text=True)
        if check:
            self.assertEqual(p.returncode, 0, p.stderr)
        return p

    def count(self, name: str) -> int:
        return (self.home / name).read_text().count("# >>> lw >>>")

    def test_install_twice_is_idempotent(self):
        self.run_installer()
        self.run_installer()
        link = self.home / ".local/bin/lw"
        self.assertTrue(link.is_symlink())
        self.assertEqual(Path(os.readlink(link)), LW)
        for rc in (".zshrc", ".bashrc"):
            self.assertEqual(self.count(rc), 1, rc)
            self.assertEqual((self.home / rc).read_text().count("# <<< lw <<<"), 1)
        self.assertIn("export FOO=1", (self.home / ".zshrc").read_text())
        fish = self.home / ".config/fish/conf.d/lw-path.fish"
        self.assertIn('fish_add_path -g "$HOME/.local/bin"', fish.read_text())

    def test_uninstall_leaves_nothing(self):
        self.run_installer()
        self.run_installer("--uninstall")
        self.assertFalse((self.home / ".local/bin/lw").exists())
        self.assertFalse((self.home / ".local/bin/lw").is_symlink())
        self.assertFalse((self.home / ".config/fish/conf.d/lw-path.fish").exists())
        for rc, line in ((".zshrc", "export FOO=1\n"), (".bashrc", "export BAR=1\n")):
            text = (self.home / rc).read_text()
            self.assertNotIn(">>> lw", text)
            self.assertIn(line.strip(), text)

    def test_existing_foreign_guard_is_reused_not_duplicated(self):
        guard = '# >>> conso >>>\nexport PATH="$HOME/.local/bin:$PATH"\n# <<< conso <<<\n'
        (self.home / ".zshrc").write_text(guard)
        (self.home / ".config/fish/conf.d/conso.fish").write_text(
            'fish_add_path -g "$HOME/.local/bin"\n')
        self.run_installer()
        self.run_installer()
        self.assertEqual(self.count(".zshrc"), 0)
        self.assertEqual((self.home / ".zshrc").read_text(), guard)
        self.assertEqual(self.count(".bashrc"), 1)
        self.assertFalse((self.home / ".config/fish/conf.d/lw-path.fish").exists())
        self.run_installer("--uninstall")
        self.assertEqual((self.home / ".zshrc").read_text(), guard)  # foreign guard survives
        self.assertTrue((self.home / ".config/fish/conf.d/conso.fish").exists())

    def test_refuses_to_overwrite_a_regular_file(self):
        (self.home / ".local/bin").mkdir(parents=True)
        (self.home / ".local/bin/lw").write_text("mine\n")
        p = self.run_installer(check=False)
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual((self.home / ".local/bin/lw").read_text(), "mine\n")

    def test_refuses_from_a_checkout(self):
        p = self.run_installer(check=False, checkout_ok=False)
        # the skill is mounted from a checkout or an install: only assert when it is a checkout
        in_checkout = any((d / ".git").exists() for d in INSTALLER.parents) or "/worktrees/" in str(INSTALLER)
        if in_checkout:
            self.assertNotEqual(p.returncode, 0)
            self.assertFalse((self.home / ".local/bin/lw").exists())


if __name__ == "__main__":
    unittest.main()
