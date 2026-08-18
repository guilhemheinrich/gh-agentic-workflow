#!/usr/bin/env python3
"""Build a deterministic Notion sync action plan for SpecKit specs."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


INDEXED_DIR_RE = re.compile(r"^(?P<index>\d{3})-(?P<slug>.+)$")
DEFAULT_DATABASE_NAME = "Specs"
DEFAULT_NOTION_ROOT = "sentinel-sync"
DEFAULT_BLOCK_CHARS = 1800
DEFAULT_PAGE_ICON = "\U0001F4C4"
DEFAULT_PROJECT_ICON = "\U0001F4C1"
DEFAULT_SORT_DIRECTION = "descending"


@dataclass(frozen=True)
class SpecEntry:
    family: str
    state: str
    index: int
    slug: str
    source_path: str
    spec_path: str | None
    review_path: str | None
    content_hash: str


def run_git(repo: Path, args: list[str]) -> str | None:
    try:
        result = subprocess.run(
            ["git", *args],
            cwd=repo,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except (FileNotFoundError, subprocess.CalledProcessError):
        return None
    value = result.stdout.strip()
    return value or None


def git_root(start: Path) -> Path:
    resolved = start.resolve()
    root = run_git(resolved, ["rev-parse", "--show-toplevel"])
    return Path(root).resolve() if root else resolved


def repo_name(repo: Path, override: str | None) -> str:
    if override:
        return override

    origin = run_git(repo, ["config", "--get", "remote.origin.url"])
    if origin:
        candidate = origin.rstrip("/").rsplit("/", 1)[-1]
        if ":" in candidate:
            candidate = candidate.rsplit(":", 1)[-1]
        if candidate.endswith(".git"):
            candidate = candidate[:-4]
        if candidate:
            return candidate

    return repo.name


def rel(path: Path, root: Path) -> str:
    return path.resolve().relative_to(root.resolve()).as_posix()


def is_archive_part(part: str) -> bool:
    return part.lower().startswith("archive")


def state_for(path: Path, root: Path) -> str:
    parts = path.resolve().relative_to(root.resolve()).parts
    return "archived" if any(is_archive_part(part) for part in parts) else "active"


def family_for(path: Path) -> str:
    return "FIX" if path.parent.name == "fixes" else "SPEC"


def discover_roots(repo: Path) -> list[Path]:
    roots: list[Path] = []

    for candidate in [repo / "specs", repo / "fixes", repo / "specs" / "fixes"]:
        if candidate.is_dir():
            roots.append(candidate)

    specs_dir = repo / "specs"
    if specs_dir.is_dir():
        for child in sorted(specs_dir.iterdir(), key=lambda p: p.name):
            if child.is_dir() and is_archive_part(child.name):
                roots.append(child)
                fixes = child / "fixes"
                if fixes.is_dir():
                    roots.append(fixes)

    deduped: list[Path] = []
    seen: set[Path] = set()
    for root in roots:
        resolved = root.resolve()
        if resolved not in seen:
            seen.add(resolved)
            deduped.append(root)
    return deduped


def indexed_children(root: Path) -> list[Path]:
    if not root.is_dir():
        return []
    children: list[Path] = []
    for child in root.iterdir():
        if child.is_dir() and INDEXED_DIR_RE.match(child.name):
            children.append(child)
    return sorted(children, key=lambda p: p.name)


def file_text(path: Path | None) -> str:
    if not path or not path.is_file():
        return ""
    return path.read_text(encoding="utf-8", errors="replace")


def content_hash_for(paths: list[Path | None]) -> str:
    digest = hashlib.sha256()
    for path in paths:
        if not path or not path.is_file():
            continue
        digest.update(path.name.encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def discover_entries(repo: Path) -> list[SpecEntry]:
    entries: list[SpecEntry] = []
    seen: set[str] = set()

    for root in discover_roots(repo):
        for folder in indexed_children(root):
            source_path = rel(folder, repo)
            if source_path in seen:
                continue
            seen.add(source_path)

            match = INDEXED_DIR_RE.match(folder.name)
            if not match:
                continue

            spec_path = folder / "spec.md"
            review_path = folder / "review.md"
            entries.append(
                SpecEntry(
                    family=family_for(folder),
                    state=state_for(folder, repo),
                    index=int(match.group("index")),
                    slug=match.group("slug"),
                    source_path=source_path,
                    spec_path=rel(spec_path, repo) if spec_path.is_file() else None,
                    review_path=rel(review_path, repo) if review_path.is_file() else None,
                    content_hash=content_hash_for([spec_path, review_path]),
                )
            )

    return sorted(
        entries,
        key=lambda item: (item.family, item.state, item.index, item.source_path),
    )


def entry_name(entry: SpecEntry) -> str:
    return f"{entry.index:03d} - {entry.slug}"


def sort_entries(entries: list[SpecEntry], direction: str) -> list[SpecEntry]:
    reverse = direction == "descending"
    return sorted(entries, key=lambda entry: (entry_name(entry), entry.source_path), reverse=reverse)


def notion_emoji_icon(icon: str) -> dict[str, str]:
    return {"type": "emoji", "emoji": icon}


def split_chunks(text: str, max_chars: int) -> list[str]:
    if not text:
        return []
    chunks: list[str] = []
    remaining = text
    while len(remaining) > max_chars:
        split_at = remaining.rfind("\n", 0, max_chars)
        if split_at < max_chars // 2:
            split_at = max_chars
        chunks.append(remaining[:split_at].rstrip("\n"))
        remaining = remaining[split_at:].lstrip("\n")
    if remaining:
        chunks.append(remaining.rstrip("\n"))
    return chunks


def fence_for(text: str) -> str:
    longest = 0
    for match in re.finditer(r"`+", text):
        longest = max(longest, len(match.group(0)))
    return "`" * max(3, longest + 1)


def fenced_markdown(text: str, language: str) -> str:
    fence = fence_for(text)
    return f"{fence}{language}\n{text}\n{fence}"


def file_blocks(title: str, source_path: str | None, text: str, max_chars: int) -> list[dict[str, Any]]:
    if source_path is None:
        return []

    blocks: list[dict[str, Any]] = [
        {"type": "heading_2", "text": title},
        {"type": "paragraph", "text": f"Source: {source_path}"},
    ]
    for index, chunk in enumerate(split_chunks(text, max_chars), start=1):
        caption = f"{title} chunk {index}" if len(text) > max_chars else title
        blocks.append(
            {
                "type": "code",
                "language": "markdown",
                "caption": caption,
                "fence": fence_for(chunk),
                "markdown": fenced_markdown(chunk, "markdown"),
                "text": chunk,
            }
        )
    return blocks


def markdown_file_blocks(title: str, source_path: str, text: str, max_chars: int) -> list[dict[str, Any]]:
    return file_blocks(title, source_path, text, max_chars)


def find_project_readme(repo: Path, readme_path: str | None) -> Path | None:
    if readme_path:
        candidate = (repo / readme_path).resolve()
        try:
            candidate.relative_to(repo.resolve())
        except ValueError:
            return None
        return candidate if candidate.is_file() else None

    for name in ["README.md", "readme.md", "Readme.md"]:
        candidate = repo / name
        if candidate.is_file():
            return candidate
    return None


def project_page_children(repo: Path, project_name: str, readme_path: Path | None, max_chars: int) -> list[dict[str, Any]]:
    children: list[dict[str, Any]] = [
        {"type": "heading_1", "text": "Project"},
        {"type": "paragraph", "text": f"Repository: {project_name}"},
    ]
    if not readme_path:
        children.append({"type": "paragraph", "text": "No root README.md found at sync time."})
        return children

    readme_rel = rel(readme_path, repo)
    readme_text = file_text(readme_path)
    children.extend(markdown_file_blocks("README.md", readme_rel, readme_text, max_chars))
    return children


def project_page_markdown(repo: Path, project_name: str, readme_path: Path | None) -> str:
    lines = ["# Project", "", f"Repository: {project_name}", ""]
    if not readme_path:
        lines.append("No root README.md found at sync time.")
        return "\n".join(lines)

    readme_rel = rel(readme_path, repo)
    lines.extend([f"## {readme_rel}", "", file_text(readme_path).rstrip("\n")])
    return "\n".join(lines).rstrip("\n")


def markdown_chunks(text: str, max_chars: int) -> list[dict[str, str]]:
    chunks: list[dict[str, str]] = []
    for index, chunk in enumerate(split_chunks(text, max_chars), start=1):
        chunks.append(
            {
                "caption": f"project markdown chunk {index}",
                "text": chunk,
                "fence": fence_for(chunk),
                "fallback_code_markdown": fenced_markdown(chunk, "markdown"),
            }
        )
    return chunks


def page_children(entry: SpecEntry, repo: Path, max_chars: int) -> list[dict[str, Any]]:
    spec_text = file_text(repo / entry.spec_path) if entry.spec_path else ""
    review_text = file_text(repo / entry.review_path) if entry.review_path else ""

    children: list[dict[str, Any]] = [
        {"type": "heading_1", "text": f"{entry.family} {entry.index:03d} - {entry.slug}"},
        {"type": "paragraph", "text": f"Source path: {entry.source_path}"},
        {"type": "paragraph", "text": f"State: {entry.state}; hash: {entry.content_hash}"},
    ]
    children.extend(file_blocks("spec.md", entry.spec_path, spec_text, max_chars))
    children.extend(file_blocks("review.md", entry.review_path, review_text, max_chars))
    return children


def plan(
    repo: Path,
    notion_root: str,
    name_override: str | None,
    database_name: str,
    max_chars: int,
    page_icon: str,
    project_icon: str,
    readme_path: str | None,
    sort_direction: str,
) -> dict[str, Any]:
    repo = git_root(repo)
    name = repo_name(repo, name_override)
    path_segments = [segment for segment in notion_root.strip("/").split("/") if segment] + [name]
    entries = discover_entries(repo)
    display_entries = sort_entries(entries, sort_direction)
    project_readme = find_project_readme(repo, readme_path)

    head = run_git(repo, ["rev-parse", "HEAD"])
    origin = run_git(repo, ["config", "--get", "remote.origin.url"])
    project_markdown = project_page_markdown(repo, name, project_readme)

    actions: list[dict[str, Any]] = [
        {
            "action": "ensure_path",
            "path": path_segments,
            "icon": notion_emoji_icon(project_icon),
            "markdown": project_markdown,
            "markdown_chunks": markdown_chunks(project_markdown, max_chars),
            "children": project_page_children(repo, name, project_readme, max_chars),
            "content_source": rel(project_readme, repo) if project_readme else None,
        },
        {
            "action": "ensure_database",
            "parent_path": path_segments,
            "database_name": database_name,
            "unique_property": "Source path",
            "default_sort": {
                "property": "Name",
                "direction": sort_direction,
            },
            "properties": {
                "Name": "title",
                "Family": "select",
                "State": "select",
                "Index": "number",
                "Slug": "rich_text",
                "Source path": "rich_text",
                "Spec hash": "rich_text",
                "Has review": "checkbox",
                "Has spec": "checkbox",
            },
        },
    ]

    for entry in display_entries:
        actions.append(
            {
                "action": "upsert_page",
                "database_name": database_name,
                "icon": notion_emoji_icon(page_icon),
                "stable_key_property": "Source path",
                "stable_key": entry.source_path,
                "properties": {
                    "Name": entry_name(entry),
                    "Family": entry.family,
                    "State": entry.state,
                    "Index": entry.index,
                    "Slug": entry.slug,
                    "Source path": entry.source_path,
                    "Spec hash": entry.content_hash,
                    "Has review": entry.review_path is not None,
                    "Has spec": entry.spec_path is not None,
                },
                "children": page_children(entry, repo, max_chars),
            }
        )

    return {
        "schema_version": 1,
        "repo": {
            "name": name,
            "root": str(repo),
            "origin": origin,
            "head": head,
        },
        "notion": {
            "path": "/".join(path_segments),
            "path_segments": path_segments,
            "database_name": database_name,
            "page_icon": notion_emoji_icon(page_icon),
            "project_icon": notion_emoji_icon(project_icon),
            "project_readme": rel(project_readme, repo) if project_readme else None,
            "sort": {
                "property": "Name",
                "direction": sort_direction,
            },
        },
        "summary": {
            "total": len(entries),
            "specs": sum(1 for entry in entries if entry.family == "SPEC"),
            "fixes": sum(1 for entry in entries if entry.family == "FIX"),
            "active": sum(1 for entry in entries if entry.state == "active"),
            "archived": sum(1 for entry in entries if entry.state == "archived"),
        },
        "entries": [entry.__dict__ for entry in display_entries],
        "actions": actions,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=".", help="Repository path. Default: current directory.")
    parser.add_argument("--notion-root", default=os.environ.get("NOTION_SPEC_SYNC_ROOT", DEFAULT_NOTION_ROOT))
    parser.add_argument("--repo-name", default=None, help="Override the Git-derived repo name.")
    parser.add_argument("--database-name", default=DEFAULT_DATABASE_NAME)
    parser.add_argument("--max-block-chars", type=int, default=DEFAULT_BLOCK_CHARS)
    parser.add_argument("--page-icon", default=os.environ.get("NOTION_SPEC_SYNC_PAGE_ICON", DEFAULT_PAGE_ICON))
    parser.add_argument(
        "--project-icon",
        default=os.environ.get("NOTION_SPEC_SYNC_PROJECT_ICON", DEFAULT_PROJECT_ICON),
        help="Emoji icon applied to the repo project page. Default: folder.",
    )
    parser.add_argument(
        "--readme-path",
        default=os.environ.get("NOTION_SPEC_SYNC_README_PATH"),
        help="Repo-relative README path to sync on the project page. Default: root README.md/readme.md.",
    )
    parser.add_argument(
        "--sort-direction",
        choices=["ascending", "descending"],
        default=DEFAULT_SORT_DIRECTION,
        help="Sort cards by Name in this direction. Default: descending.",
    )
    parser.add_argument("--output", default="-", help="Output JSON path, or '-' for stdout.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.max_block_chars < 200:
        print("--max-block-chars must be at least 200", file=sys.stderr)
        return 2

    result = plan(
        repo=Path(args.repo),
        notion_root=args.notion_root,
        name_override=args.repo_name,
        database_name=args.database_name,
        max_chars=args.max_block_chars,
        page_icon=args.page_icon,
        project_icon=args.project_icon,
        readme_path=args.readme_path,
        sort_direction=args.sort_direction,
    )
    output = json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True)

    if args.output == "-":
        print(output)
    else:
        Path(args.output).write_text(output + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
