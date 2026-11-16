---
name: git-activity-report
description: Generate sourced Markdown activity reports from Git branch history. Use when Codex needs to scan commits and pull requests or merge requests for a target branch over a configurable lookback period using git, Docker, optional provider CLIs such as gh, glab, or Bitbucket tools, and optional MCP provider tools, then produce a digestible report with href links back to the relevant commits and PRs/MRs.
---

# Git Activity Report

## Workflow

1. Collect deterministic source data before writing the report:

```bash
python3 skills/git-activity-report/scripts/collect_git_activity.py \
  --branch main \
  --since-days 14 \
  --output /tmp/git-activity.json
```

Or run the bundled minimal Docker image from the repository root:

```bash
docker build -f skills/git-activity-report/Dockerfile -t git-activity-report skills/git-activity-report
docker run --rm -v "$PWD:/repo" -w /repo git-activity-report \
  --branch main \
  --since-days 14 \
  --include-prs never
```

When a GitHub, GitLab, or Bitbucket MCP is available, use it to fetch PR/MR metadata, normalize the tool result into JSON, then pass that file to the collector:

```bash
python3 skills/git-activity-report/scripts/collect_git_activity.py \
  --branch main \
  --since-days 14 \
  --include-prs never \
  --pull-requests-json /tmp/provider-prs.json \
  --output /tmp/git-activity.json
```

2. Adjust parameters as needed:

- Use `--branch <branch-or-ref>` to target a local branch, remote branch, tag, or commit ref.
- Use `--since-days <n>` for a relative lookback window, or `--since YYYY-MM-DD` for an absolute start.
- Use `--include-prs never` when only local Git history is wanted.
- Use `--provider github|gitlab|bitbucket|none` only when auto-detection is wrong.
- Use `--remote <name>` when commit hrefs must be built from a non-`origin` remote.
- Use `--pull-requests-json <path>` to merge PR/MR metadata already collected from an MCP, API, or CLI export. The file may contain either a list or an object with `pull_requests`, `pullRequests`, `merge_requests`, `mergeRequests`, `items`, `values`, `nodes`, or `edges[].node`.
- Use the Docker path when the host does not have a suitable Python runtime. The image uses the minimal compatible runtime, `python:3.10-alpine`, and includes only `git`; provider CLIs are intentionally not installed.

3. Read the JSON output and write the Markdown report from those facts only. Treat `collection.warnings` as caveats to mention briefly when PR/MR enrichment was unavailable.

## Report Rules

- Produce Markdown by default.
- Start with a short title naming the branch and period.
- Include a 3-6 bullet executive summary for non-technical readers.
- Group detailed changes by practical themes such as delivery, fixes, infrastructure, tests, documentation, and cleanup.
- Attach source links directly to claims using Markdown hrefs, for example `[abc1234](https://...)` or `[PR #42](https://...)`.
- Prefer PR/MR titles when they summarize a change better than individual commit summaries.
- Keep orphan commits visible when no PR/MR is attached.
- Avoid inventing business impact that is not supported by commit or PR/MR summaries.
- Add a compact appendix listing raw commits and PRs/MRs when the report is long or when traceability matters.

## Source Handling

Use these JSON fields first:

- `commits[].summary`, `commits[].url`, and `commits[].short_sha` for commit-backed facts.
- `pull_requests[].title`, `pull_requests[].url`, and `pull_requests[].number` for PR/MR-backed facts.
- `commits[].pull_request_numbers` to connect commits to PRs/MRs when provider data was available.
- `collection.warnings` to explain missing provider enrichment without blocking the report.

When URLs are missing, still cite the short SHA or PR/MR number in monospace and state that no remote href could be derived.

## MCP Provider Data

Prefer MCP tools over provider CLIs when they are already connected and authenticated. Keep the Git collection script as the deterministic merge step:

1. Use the MCP to query merged or recently updated PRs/MRs for the target repository, branch, and period.
2. Save or construct a JSON payload using provider-native field names or the normalized fields below.
3. Run `collect_git_activity.py` with `--pull-requests-json`.
4. Write the report only after the script has merged commits and PR/MR metadata.

Preferred normalized item shape:

```json
{
  "provider": "github",
  "number": 42,
  "title": "Add activity report collector",
  "url": "https://github.com/org/repo/pull/42",
  "state": "MERGED",
  "author": "octocat",
  "base_branch": "main",
  "head_branch": "feature/activity-report",
  "merged_at": "2026-07-09T10:00:00Z",
  "updated_at": "2026-07-09T10:05:00Z",
  "merge_commit_sha": "abc123...",
  "commit_shas": ["abc123..."]
}
```

Provider-native shapes from GitHub, GitLab, and Bitbucket are acceptable when they expose equivalent fields such as `id`, `iid`, `web_url`, `html_url`, `baseRefName`, `target_branch`, `destination`, `mergedAt`, `merged_on`, `mergeCommit`, or `commits`.

## Output Shape

Use this structure unless the user asks for another one:

```markdown
# Activity Report: <branch> (<start> to <end>)

## Summary
- ...

## Highlights
### <Theme>
- ... [commit](...) / [PR #...](...)

## Pull Requests / Merge Requests
- ...

## Follow-ups
- ...

## Sources
- ...
```
