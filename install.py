#!/usr/bin/env python3
"""
Install agentic resources (skills, rules, etc.) from this repo
to user-level Cursor / PI directories using symlinks (or copies on Windows).

Individual files are linked, not directories, so that the user can add
custom resources alongside the package ones without affecting the repo.
"""

from __future__ import annotations

import filecmp
import os
import platform
import shutil
from dataclasses import dataclass, field
from pathlib import Path

import click

REPO_ROOT = Path(__file__).resolve().parent

IS_WINDOWS = platform.system() == "Windows"


# ── Resource mapping ──────────────────────────────────────────────────

@dataclass
class ResourceMapping:
    """Describes a glob-based mapping from repo → user target."""
    label: str
    src_base: str
    target_base: Path


def cursor_home() -> Path:
    if IS_WINDOWS:
        return Path(os.environ.get("APPDATA", str(Path.home()))) / "Cursor"
    return Path.home() / ".cursor"


def build_mappings() -> list[ResourceMapping]:
    ch = cursor_home()
    return [
        ResourceMapping(
            label="skills (workspace)",
            src_base="skills",
            target_base=ch / "skills",
        ),
        ResourceMapping(
            label="skills (.agents)",
            src_base=".agents/skills",
            target_base=ch / "skills",
        ),
        ResourceMapping(
            label="rules",
            src_base="rules",
            target_base=ch / "rules",
        ),
    ]


# ── Plan ──────────────────────────────────────────────────────────────

@dataclass
class InstallPlan:
    to_create: list[tuple[Path, Path]] = field(default_factory=list)
    to_update: list[tuple[Path, Path]] = field(default_factory=list)
    unchanged: list[tuple[Path, Path]] = field(default_factory=list)


# ── Core logic ────────────────────────────────────────────────────────

def collect_files(src_dir: Path) -> list[Path]:
    """Recursively collect all files under src_dir, relative to it."""
    return sorted(
        p.relative_to(src_dir) for p in src_dir.rglob("*") if p.is_file()
    )


def is_our_symlink(src: Path, dst: Path) -> bool:
    """True if dst is a symlink pointing at src (same resolved path)."""
    if not dst.is_symlink():
        return False
    return dst.resolve() == src.resolve()


def same_content(src: Path, dst: Path) -> bool:
    """Check whether src and dst have identical content."""
    if is_our_symlink(src, dst):
        return True
    if dst.is_symlink():
        resolved = dst.resolve()
        if resolved.is_file():
            return filecmp.cmp(str(src), str(resolved), shallow=False)
        return False
    return filecmp.cmp(str(src), str(dst), shallow=False)


def compute_plan(mappings: list[ResourceMapping]) -> InstallPlan:
    plan = InstallPlan()
    seen_dst: dict[Path, Path] = {}

    for mapping in mappings:
        src_base = REPO_ROOT / mapping.src_base
        if not src_base.exists():
            continue

        for entry_dir in sorted(src_base.iterdir()):
            if not entry_dir.is_dir():
                if entry_dir.is_file():
                    _plan_file(
                        entry_dir,
                        mapping.target_base / entry_dir.name,
                        plan,
                        seen_dst,
                    )
                continue

            target_dir = mapping.target_base / entry_dir.name
            for rel_file in collect_files(entry_dir):
                src_file = entry_dir / rel_file
                dst_file = target_dir / rel_file
                _plan_file(src_file, dst_file, plan, seen_dst)

    return plan


def _plan_file(
    src: Path,
    dst: Path,
    plan: InstallPlan,
    seen: dict[Path, Path],
) -> None:
    """Classify a single src→dst pair, deduplicating by dst."""
    canonical_dst = dst.resolve() if dst.exists() else dst

    if canonical_dst in seen:
        _remove_from_plan(plan, dst)

    seen[canonical_dst] = src

    if not dst.exists() and not dst.is_symlink():
        plan.to_create.append((src, dst))
    elif same_content(src, dst):
        plan.unchanged.append((src, dst))
    else:
        plan.to_update.append((src, dst))


def _remove_from_plan(plan: InstallPlan, dst: Path) -> None:
    """Remove any entry targeting dst from all plan lists."""
    for lst in (plan.to_create, plan.to_update, plan.unchanged):
        lst[:] = [(s, d) for s, d in lst if d != dst]


def link_or_copy(src: Path, dst: Path) -> None:
    """Create a symlink (Unix) or copy (Windows) from src to dst."""
    dst.parent.mkdir(parents=True, exist_ok=True)

    if dst.exists() or dst.is_symlink():
        dst.unlink()

    if IS_WINDOWS:
        shutil.copy2(str(src), str(dst))
    else:
        dst.symlink_to(src)


# ── CLI ───────────────────────────────────────────────────────────────

@click.command()
@click.option(
    "--dry-run", is_flag=True, default=False,
    help="Afficher les actions sans les exécuter.",
)
@click.option(
    "--force", is_flag=True, default=False,
    help="Écraser tous les fichiers modifiés sans demander.",
)
def install(dry_run: bool, force: bool) -> None:
    """Installe les ressources agentiques dans les dossiers utilisateur Cursor."""

    mappings = build_mappings()
    plan = compute_plan(mappings)

    method = "copie" if IS_WINDOWS else "lien symbolique"
    click.echo(
        click.style(f"\n📦 Installation des ressources agentiques ({method})\n", bold=True)
    )

    click.echo(f"  Nouveaux fichiers :  {click.style(str(len(plan.to_create)), fg='green')}")
    click.echo(f"  Fichiers modifiés :  {click.style(str(len(plan.to_update)), fg='yellow')}")
    click.echo(f"  Inchangés         :  {len(plan.unchanged)}")
    click.echo()

    if not plan.to_create and not plan.to_update:
        click.echo(click.style("Tout est à jour ✓", fg="green"))
        return

    if plan.to_create:
        click.echo(click.style("── Nouveaux fichiers ──", bold=True))
        for src, dst in plan.to_create:
            rel = dst.relative_to(cursor_home())
            click.echo(f"  + {rel}")
            if not dry_run:
                link_or_copy(src, dst)

    if plan.to_update:
        click.echo()
        click.echo(click.style("── Fichiers modifiés ──", bold=True))

        overwrite_all = force
        n_modified = len(plan.to_update)

        for src, dst in plan.to_update:
            rel = dst.relative_to(cursor_home())
            click.echo(f"  ~ {click.style(str(rel), fg='yellow')}")

            if dry_run:
                continue

            if overwrite_all:
                link_or_copy(src, dst)
                continue

            choices = {
                "o": "Oui (écraser)",
                "n": "Non (garder l'existant)",
                "a": f"Oui pour tous ({n_modified} fichier(s) modifié(s))",
            }
            prompt_text = "  Écraser ? " + " / ".join(
                f"[{click.style(k, bold=True)}] {v}" for k, v in choices.items()
            )

            while True:
                answer = click.prompt(
                    prompt_text, type=str, default="n",
                ).strip().lower()
                if answer in choices:
                    break
                click.echo(
                    f"  Choix invalide. Entrez {', '.join(choices.keys())}.",
                )

            if answer == "o":
                link_or_copy(src, dst)
            elif answer == "a":
                overwrite_all = True
                link_or_copy(src, dst)

    click.echo()
    if dry_run:
        click.echo(click.style("(dry-run — aucune modification effectuée)", fg="cyan"))
    else:
        click.echo(click.style("Installation terminée ✓", fg="green"))


if __name__ == "__main__":
    install()
