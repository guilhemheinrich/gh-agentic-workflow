#!/usr/bin/env bash
# fixtures.sh — GitHub REST fixtures for the prw tests. Source after lib.sh.

FX="$WORK/fixtures"
FX_REPO="octo-org/cockpit"
FX_KEY="github:octo-org/cockpit"
export GITHUB_WATCH_TOKEN="gh-SECRET-456"
export GITHUB_API_BASE="http://fake.test"
FX_PR=42
FX_HEAD="aaa111aaa111aaa111aaa111aaa111aaa111aaaa"
FX_MERGE="mrg111mrg111mrg111mrg111mrg111mrg111mrg1"
mkdir -p "$FX"

# fx_put TAIL JSON [CODE] — the body served for the URL tail TAIL.
fx_put() {
  local key; key="$(fixture_key "$1")"
  printf '%s' "$2" >"$FX/$key.json"
  if [ -n "${3:-}" ]; then printf '%s' "$3" >"$FX/$key.code"; else rm -f "$FX/$key.code"; fi
}

# fx_list TAIL JSON_ARRAY — a list endpoint with one page (fewer than 100).
fx_list() { fx_put "$1?per_page=100&page=1" "$2"; }

# fx_pr_open — an open PR with a passing check, a running check, one approval,
# one change request, one review comment and one conversation comment.
fx_pr_open() {
  fx_put "repos/$FX_REPO/pulls/$FX_PR" "$(printf '%s' '{
    "number": 42, "state": "open", "merged": false, "title": "Cockpit cascade filters",
    "html_url": "https://github.com/octo-org/cockpit/pull/42",
    "head": {"sha": "'"$FX_HEAD"'", "ref": "feat/cascade"},
    "base": {"sha": "bbb222bbb222bbb222bbb222bbb222bbb222bbbb", "ref": "staging"},
    "merge_commit_sha": null, "mergeable": true, "mergeable_state": "clean"}')"
  fx_list "repos/$FX_REPO/commits/$FX_HEAD/check-runs" '{"check_runs": [
    {"name": "build", "status": "completed", "conclusion": "success",
     "completed_at": "2026-11-02T10:00:00Z", "html_url": "https://github.com/octo-org/cockpit/runs/1"},
    {"name": "lint", "status": "in_progress", "conclusion": null,
     "started_at": "2026-11-02T10:01:00Z", "html_url": "https://github.com/octo-org/cockpit/runs/2"}]}'
  fx_list "repos/$FX_REPO/commits/$FX_HEAD/statuses" '[
    {"context": "sonar", "state": "success", "updated_at": "2026-11-02T10:02:00Z", "target_url": "https://sonar.example.test/42"}]'
  fx_list "repos/$FX_REPO/pulls/$FX_PR/reviews" '[
    {"id": 1, "state": "APPROVED", "user": {"login": "alice"}},
    {"id": 2, "state": "COMMENTED", "user": {"login": "carol"}},
    {"id": 3, "state": "CHANGES_REQUESTED", "user": {"login": "bob"}}]'
  fx_list "repos/$FX_REPO/pulls/$FX_PR/comments" '[
    {"id": 9001, "body": "SECRET BODY TEXT", "path": "src/a.ts", "line": 12, "user": {"login": "alice"}}]'
  fx_list "repos/$FX_REPO/issues/$FX_PR/comments" '[
    {"id": 9002, "body": "another secret", "user": {"login": "carol"}}]'
}
