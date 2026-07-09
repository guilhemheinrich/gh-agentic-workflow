#!/usr/bin/env python3
"""Collect Git commits and optional PR/MR metadata for activity reports."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


ISO_Z = "%Y-%m-%dT%H:%M:%SZ"


@dataclass(frozen=True)
class RemoteInfo:
    name: str
    raw_url: str
    web_url: str | None
    provider: str | None


def run(args: list[str], cwd: Path, *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        cwd=str(cwd),
        check=check,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def git(args: list[str], cwd: Path, *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return run(["git", *args], cwd, check=check)


def parse_utc(value: str) -> dt.datetime:
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    parsed = dt.datetime.fromisoformat(value)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.astimezone(dt.timezone.utc)


def format_utc(value: dt.datetime) -> str:
    return value.astimezone(dt.timezone.utc).strftime(ISO_Z)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Collect commits and optional PR/MR metadata for a branch activity report.",
    )
    parser.add_argument("--repo", default=".", help="Git repository path. Defaults to current directory.")
    parser.add_argument("--branch", help="Branch, ref, tag, or commit to scan. Defaults to current branch.")
    parser.add_argument("--since-days", type=int, default=14, help="Lookback duration in days. Defaults to 14.")
    parser.add_argument("--since", help="Absolute start date/time, for example 2026-07-01 or 2026-07-01T00:00:00Z.")
    parser.add_argument("--until", help="Absolute end date/time. Defaults to now in UTC.")
    parser.add_argument("--now", help="Freeze the current time for deterministic tests.")
    parser.add_argument("--remote", default="origin", help="Remote used to derive web hrefs. Defaults to origin.")
    parser.add_argument(
        "--include-prs",
        choices=["auto", "always", "never"],
        default="auto",
        help="Collect PR/MR metadata with provider CLIs. Defaults to auto.",
    )
    parser.add_argument(
        "--provider",
        choices=["auto", "github", "gitlab", "bitbucket", "none"],
        default="auto",
        help="Override provider detection from the remote URL.",
    )
    parser.add_argument(
        "--pull-requests-json",
        action="append",
        default=[],
        help=(
            "Read PR/MR metadata from a JSON file, for example data exported from "
            "a GitHub, GitLab, or Bitbucket MCP tool. May be passed multiple times."
        ),
    )
    parser.add_argument("--limit-prs", type=int, default=200, help="Maximum provider PR/MR records to request.")
    parser.add_argument("--output", help="Write JSON to this path instead of stdout.")
    return parser.parse_args()


def current_branch(repo: Path) -> str:
    result = git(["branch", "--show-current"], repo)
    branch = result.stdout.strip()
    if branch:
        return branch
    return git(["rev-parse", "HEAD"], repo).stdout.strip()


def resolve_ref(repo: Path, ref: str) -> str:
    result = git(["rev-parse", "--verify", f"{ref}^{{commit}}"], repo, check=False)
    if result.returncode != 0:
        raise SystemExit(f"Ref not found: {ref}\n{result.stderr.strip()}")
    return result.stdout.strip()


def remote_url(repo: Path, remote: str) -> str:
    result = git(["remote", "get-url", remote], repo, check=False)
    return result.stdout.strip() if result.returncode == 0 else ""


def normalize_remote_url(raw_url: str) -> tuple[str | None, str | None]:
    if not raw_url:
        return None, None

    url = raw_url.strip()
    scp_match = re.match(r"^(?:[^@]+@)?([^:]+):(.+)$", url)
    if scp_match and "://" not in url:
        host = scp_match.group(1)
        path = scp_match.group(2)
        web_url = f"https://{host}/{path}"
    else:
        parsed = urlparse(url)
        if parsed.scheme in {"http", "https", "ssh", "git"} and parsed.netloc:
            host = parsed.netloc.split("@")[-1]
            web_url = f"https://{host}{parsed.path}"
        else:
            return None, None

    web_url = re.sub(r"\.git$", "", web_url.rstrip("/"))
    host = urlparse(web_url).netloc.lower()
    provider = None
    if "github" in host:
        provider = "github"
    elif "gitlab" in host:
        provider = "gitlab"
    elif "bitbucket" in host:
        provider = "bitbucket"
    return web_url, provider


def build_commit_url(remote: RemoteInfo, sha: str) -> str | None:
    if not remote.web_url:
        return None
    if remote.provider == "bitbucket":
        return f"{remote.web_url}/commits/{sha}"
    return f"{remote.web_url}/commit/{sha}"


def display_branch(ref: str, remote: str) -> str:
    for prefix in ("refs/heads/", "heads/"):
        if ref.startswith(prefix):
            return ref[len(prefix) :]
    remote_prefix = f"{remote}/"
    if ref.startswith(remote_prefix):
        return ref[len(remote_prefix) :]
    return ref


def collect_commits(repo: Path, ref: str, since: dt.datetime, until: dt.datetime, remote: RemoteInfo) -> list[dict[str, Any]]:
    pretty = "%H%x1f%h%x1f%aI%x1f%an%x1f%s%x1f%D"
    result = git(
        [
            "log",
            ref,
            f"--since={format_utc(since)}",
            f"--until={format_utc(until)}",
            "--date=iso-strict",
            f"--pretty=format:{pretty}",
        ],
        repo,
    )
    commits: list[dict[str, Any]] = []
    for line in result.stdout.splitlines():
        parts = line.split("\x1f")
        if len(parts) != 6:
            continue
        sha, short_sha, authored_at, author, summary, refs = parts
        commits.append(
            {
                "sha": sha,
                "short_sha": short_sha,
                "authored_at": authored_at,
                "author": author,
                "summary": summary,
                "refs": refs,
                "url": build_commit_url(remote, sha),
                "pull_request_numbers": [],
            }
        )
    return commits


def date_in_window(value: str | None, since: dt.datetime, until: dt.datetime) -> bool:
    if not value:
        return True
    try:
        parsed = parse_utc(value)
    except ValueError:
        return True
    return since <= parsed <= until


def command_exists(name: str) -> bool:
    return shutil.which(name) is not None


def load_json_command(command: list[str], repo: Path, warnings: list[str]) -> Any | None:
    result = run(command, repo, check=False)
    if result.returncode != 0:
        warnings.append(f"{command[0]} failed: {result.stderr.strip() or result.stdout.strip()}")
        return None
    try:
        return json.loads(result.stdout or "[]")
    except json.JSONDecodeError as exc:
        warnings.append(f"{command[0]} returned non-JSON output: {exc}")
        return None


def compact_author(value: Any) -> str | None:
    if isinstance(value, dict):
        return value.get("login") or value.get("username") or value.get("name")
    if isinstance(value, str):
        return value
    return None


def first_value(item: dict[str, Any], *keys: str) -> Any:
    for key in keys:
        value = item.get(key)
        if value not in (None, ""):
            return value
    return None


def nested_value(item: dict[str, Any], *path: str) -> Any:
    current: Any = item
    for part in path:
        if not isinstance(current, dict):
            return None
        current = current.get(part)
    return current


def extract_branch_name(value: Any) -> str | None:
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        return first_value(value, "name", "ref", "branch", "displayId")
    return None


def extract_url(item: dict[str, Any]) -> str | None:
    url = first_value(item, "url", "web_url", "webUrl", "html_url", "htmlUrl", "href")
    if url:
        return str(url)
    links = item.get("links")
    if isinstance(links, dict):
        html = links.get("html")
        if isinstance(html, dict) and html.get("href"):
            return str(html["href"])
        if isinstance(html, str):
            return html
        self_link = links.get("self")
        if isinstance(self_link, dict) and self_link.get("href"):
            return str(self_link["href"])
    return None


def extract_commit_shas(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []
    shas: list[str] = []
    for entry in value:
        sha = None
        if isinstance(entry, str):
            sha = entry
        elif isinstance(entry, dict):
            sha = first_value(entry, "sha", "oid", "hash", "id")
            if sha is None:
                sha = nested_value(entry, "commit", "oid") or nested_value(entry, "commit", "sha")
        if sha:
            shas.append(str(sha))
    return shas


def normalize_provider_item(
    item: dict[str, Any],
    default_provider: str | None,
    since: dt.datetime,
    until: dt.datetime,
) -> dict[str, Any] | None:
    merged_at = first_value(item, "merged_at", "mergedAt", "merged_on", "mergedOn", "closed_at", "closedAt")
    updated_at = first_value(item, "updated_at", "updatedAt", "updated_on", "updatedOn")
    created_at = first_value(item, "created_at", "createdAt", "created_on", "createdOn")
    if not date_in_window(str(merged_at or updated_at or created_at) if merged_at or updated_at or created_at else None, since, until):
        return None

    number = first_value(item, "number", "id", "iid")
    merge_commit = first_value(item, "merge_commit_sha", "mergeCommitSha")
    if merge_commit is None:
        merge_commit = nested_value(item, "mergeCommit", "oid") or nested_value(item, "merge_commit", "sha")

    base = first_value(item, "base_branch", "baseBranch", "baseRefName", "target_branch", "targetBranch")
    if base is None:
        base = extract_branch_name(first_value(item, "base", "destination", "toRef"))
    head = first_value(item, "head_branch", "headBranch", "headRefName", "source_branch", "sourceBranch")
    if head is None:
        head = extract_branch_name(first_value(item, "head", "source", "fromRef"))

    commit_shas = extract_commit_shas(first_value(item, "commit_shas", "commitShas", "commits"))

    return {
        "provider": first_value(item, "provider", "source") or default_provider,
        "number": number,
        "title": first_value(item, "title", "summary"),
        "url": extract_url(item),
        "state": first_value(item, "state", "status"),
        "author": compact_author(first_value(item, "author", "user", "created_by", "createdBy")),
        "base_branch": base,
        "head_branch": head,
        "merged_at": merged_at,
        "updated_at": updated_at,
        "merge_commit_sha": merge_commit,
        "commit_shas": commit_shas,
    }


def extract_provider_items(data: Any) -> list[dict[str, Any]]:
    if isinstance(data, list):
        return [item for item in data if isinstance(item, dict)]
    if not isinstance(data, dict):
        return []
    for key in ("pull_requests", "pullRequests", "merge_requests", "mergeRequests", "items", "values", "nodes"):
        value = data.get(key)
        if isinstance(value, list):
            return [item for item in value if isinstance(item, dict)]
    edges = data.get("edges")
    if isinstance(edges, list):
        return [edge["node"] for edge in edges if isinstance(edge, dict) and isinstance(edge.get("node"), dict)]
    return []


def collect_json_prs(
    paths: list[str],
    default_provider: str | None,
    since: dt.datetime,
    until: dt.datetime,
    warnings: list[str],
) -> list[dict[str, Any]]:
    prs: list[dict[str, Any]] = []
    for raw_path in paths:
        path = Path(raw_path)
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except OSError as exc:
            warnings.append(f"Could not read PR/MR JSON file {raw_path}: {exc}")
            continue
        except json.JSONDecodeError as exc:
            warnings.append(f"Could not parse PR/MR JSON file {raw_path}: {exc}")
            continue
        items = extract_provider_items(data)
        if not items:
            warnings.append(f"PR/MR JSON file {raw_path} did not contain a supported item list.")
            continue
        for item in items:
            normalized = normalize_provider_item(item, default_provider, since, until)
            if normalized is not None:
                prs.append(normalized)
    return prs


def dedupe_prs(prs: list[dict[str, Any]]) -> list[dict[str, Any]]:
    seen: set[tuple[Any, Any]] = set()
    deduped: list[dict[str, Any]] = []
    for pr in prs:
        key = (
            pr.get("provider") or pr.get("url") or pr.get("merge_commit_sha"),
            pr.get("number") or pr.get("url") or pr.get("merge_commit_sha") or pr.get("title"),
        )
        if key in seen:
            continue
        seen.add(key)
        deduped.append(pr)
    return deduped


def collect_github_prs(
    repo: Path,
    branch: str,
    since: dt.datetime,
    until: dt.datetime,
    limit: int,
    warnings: list[str],
) -> list[dict[str, Any]]:
    if not command_exists("gh"):
        warnings.append("gh is not installed; GitHub PR enrichment skipped.")
        return []
    fields = "number,title,url,state,author,baseRefName,headRefName,mergedAt,updatedAt,mergeCommit,commits"
    query = f"merged:>={since.date().isoformat()} base:{branch}"
    data = load_json_command(
        ["gh", "pr", "list", "--state", "all", "--base", branch, "--search", query, "--limit", str(limit), "--json", fields],
        repo,
        warnings,
    )
    if not isinstance(data, list):
        return []
    prs: list[dict[str, Any]] = []
    for item in data:
        merged_at = item.get("mergedAt")
        updated_at = item.get("updatedAt")
        if not date_in_window(merged_at or updated_at, since, until):
            continue
        commit_shas = []
        for commit in item.get("commits") or []:
            oid = commit.get("oid") if isinstance(commit, dict) else None
            if oid:
                commit_shas.append(oid)
        merge_commit = item.get("mergeCommit") or {}
        merge_sha = merge_commit.get("oid") if isinstance(merge_commit, dict) else None
        prs.append(
            {
                "provider": "github",
                "number": item.get("number"),
                "title": item.get("title"),
                "url": item.get("url"),
                "state": item.get("state"),
                "author": compact_author(item.get("author")),
                "base_branch": item.get("baseRefName"),
                "head_branch": item.get("headRefName"),
                "merged_at": merged_at,
                "updated_at": updated_at,
                "merge_commit_sha": merge_sha,
                "commit_shas": commit_shas,
            }
        )
    return prs


def collect_gitlab_mrs(
    repo: Path,
    branch: str,
    since: dt.datetime,
    until: dt.datetime,
    limit: int,
    warnings: list[str],
) -> list[dict[str, Any]]:
    if not command_exists("glab"):
        warnings.append("glab is not installed; GitLab MR enrichment skipped.")
        return []
    data = load_json_command(
        ["glab", "mr", "list", "--state", "merged", "--target-branch", branch, "--per-page", str(limit), "--output", "json"],
        repo,
        warnings,
    )
    if not isinstance(data, list):
        return []
    mrs: list[dict[str, Any]] = []
    for item in data:
        merged_at = item.get("merged_at") or item.get("mergedAt")
        updated_at = item.get("updated_at") or item.get("updatedAt")
        if not date_in_window(merged_at or updated_at, since, until):
            continue
        number = item.get("iid") or item.get("id")
        mrs.append(
            {
                "provider": "gitlab",
                "number": number,
                "title": item.get("title"),
                "url": item.get("web_url") or item.get("url"),
                "state": item.get("state"),
                "author": compact_author(item.get("author")),
                "base_branch": item.get("target_branch") or item.get("targetBranch"),
                "head_branch": item.get("source_branch") or item.get("sourceBranch"),
                "merged_at": merged_at,
                "updated_at": updated_at,
                "merge_commit_sha": item.get("merge_commit_sha") or item.get("mergeCommitSha"),
                "commit_shas": [],
            }
        )
    return mrs


def collect_bitbucket_prs(
    repo: Path,
    branch: str,
    since: dt.datetime,
    until: dt.datetime,
    limit: int,
    warnings: list[str],
) -> list[dict[str, Any]]:
    cli = "bb" if command_exists("bb") else "bitbucket" if command_exists("bitbucket") else None
    if cli is None:
        warnings.append("No Bitbucket CLI named bb or bitbucket was found; Bitbucket PR enrichment skipped.")
        return []
    candidate_commands = [
        [cli, "pr", "list", "--state", "MERGED", "--destination", branch, "--limit", str(limit), "--format", "json"],
        [cli, "pull-request", "list", "--state", "MERGED", "--destination", branch, "--limit", str(limit), "--format", "json"],
    ]
    data = None
    local_warnings: list[str] = []
    for command in candidate_commands:
        data = load_json_command(command, repo, local_warnings)
        if isinstance(data, list):
            break
    if not isinstance(data, list):
        warnings.extend(local_warnings[-1:] or [f"{cli} did not return a supported PR list shape."])
        return []
    prs: list[dict[str, Any]] = []
    for item in data:
        merged_at = item.get("merged_on") or item.get("mergedAt") or item.get("updated_on")
        updated_at = item.get("updated_on") or item.get("updatedAt")
        if not date_in_window(merged_at or updated_at, since, until):
            continue
        links = item.get("links") if isinstance(item.get("links"), dict) else {}
        html = links.get("html") if isinstance(links.get("html"), dict) else {}
        prs.append(
            {
                "provider": "bitbucket",
                "number": item.get("id") or item.get("number"),
                "title": item.get("title"),
                "url": item.get("url") or html.get("href"),
                "state": item.get("state"),
                "author": compact_author(item.get("author")),
                "base_branch": branch,
                "head_branch": None,
                "merged_at": merged_at,
                "updated_at": updated_at,
                "merge_commit_sha": None,
                "commit_shas": [],
            }
        )
    return prs


def attach_prs_to_commits(commits: list[dict[str, Any]], prs: list[dict[str, Any]]) -> None:
    by_sha = {commit["sha"]: commit for commit in commits}
    for pr in prs:
        number = pr.get("number")
        for sha in pr.get("commit_shas") or []:
            commit = by_sha.get(sha)
            if commit is not None and number is not None and number not in commit["pull_request_numbers"]:
                commit["pull_request_numbers"].append(number)
        merge_sha = pr.get("merge_commit_sha")
        commit = by_sha.get(merge_sha)
        if commit is not None and number is not None and number not in commit["pull_request_numbers"]:
            commit["pull_request_numbers"].append(number)


def main() -> int:
    args = parse_args()
    repo = Path(args.repo).resolve()
    if not repo.exists():
        raise SystemExit(f"Repository path does not exist: {repo}")

    git(["rev-parse", "--git-dir"], repo)
    branch = args.branch or current_branch(repo)
    resolve_ref(repo, branch)

    now = parse_utc(args.now) if args.now else dt.datetime.now(dt.timezone.utc)
    until = parse_utc(args.until) if args.until else now
    if args.since:
        since = parse_utc(args.since)
    else:
        if args.since_days < 0:
            raise SystemExit("--since-days must be greater than or equal to 0.")
        since = until - dt.timedelta(days=args.since_days)

    raw_remote_url = remote_url(repo, args.remote)
    web_url, detected_provider = normalize_remote_url(raw_remote_url)
    provider = detected_provider if args.provider == "auto" else None if args.provider == "none" else args.provider
    remote = RemoteInfo(name=args.remote, raw_url=raw_remote_url, web_url=web_url, provider=provider)
    branch_for_provider = display_branch(branch, args.remote)

    warnings: list[str] = []
    commits = collect_commits(repo, branch, since, until, remote)
    pull_requests: list[dict[str, Any]] = []
    include_prs = args.include_prs != "never" and provider is not None
    if args.include_prs == "always" and provider is None:
        warnings.append("PR/MR enrichment requested but no provider could be detected or selected.")
    if include_prs:
        if provider == "github":
            pull_requests = collect_github_prs(repo, branch_for_provider, since, until, args.limit_prs, warnings)
        elif provider == "gitlab":
            pull_requests = collect_gitlab_mrs(repo, branch_for_provider, since, until, args.limit_prs, warnings)
        elif provider == "bitbucket":
            pull_requests = collect_bitbucket_prs(repo, branch_for_provider, since, until, args.limit_prs, warnings)
    json_pull_requests = collect_json_prs(args.pull_requests_json, provider, since, until, warnings)
    pull_requests = dedupe_prs([*pull_requests, *json_pull_requests])

    attach_prs_to_commits(commits, pull_requests)

    output = {
        "generated_at": format_utc(now),
        "repo": str(repo),
        "branch": branch,
        "provider_branch": branch_for_provider,
        "since": format_utc(since),
        "until": format_utc(until),
        "remote": {
            "name": remote.name,
            "url": remote.raw_url,
            "web_url": remote.web_url,
            "provider": remote.provider,
        },
        "collection": {
            "include_prs": args.include_prs,
            "pull_requests_json": args.pull_requests_json,
            "warnings": warnings,
            "commit_count": len(commits),
            "pull_request_count": len(pull_requests),
        },
        "commits": commits,
        "pull_requests": pull_requests,
    }

    serialized = json.dumps(output, indent=2, sort_keys=True) + "\n"
    if args.output:
        Path(args.output).write_text(serialized, encoding="utf-8")
    else:
        sys.stdout.write(serialized)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
