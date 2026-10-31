#!/usr/bin/env bash
# fixtures.sh — builders for fake Bitbucket API responses. Source after lib.sh.
#
# Every builder writes into $FX (the directory served by the fake curl) under
# the key the fake curl derives from the URL.

FX_REPO="septeo-immobilier/modelo-bill-e"
FX_PR=229

fx_put() { # URL_TAIL JSON [CODE]
  local k; k="$(fixture_key "$1")"
  printf '%s' "$2" >"$FX/$k.json"
  if [ -n "${3:-}" ]; then printf '%s' "$3" >"$FX/$k.code"; else rm -f "$FX/$k.code"; fi
}

# fx_pr STATE HEAD DEST PARTICIPANTS_JSON_ARRAY
fx_pr() {
  fx_put "repositories/$FX_REPO/pullrequests/$FX_PR" "$(jq -n \
    --arg s "$1" --arg h "$2" --arg d "$3" --argjson p "${4:-[]}" '{
      id: 229, title: "Cockpit cascade filters", state: $s,
      source: {branch: {name: "feat/cascade"}, commit: {hash: $h}},
      destination: {branch: {name: "staging"}, commit: {hash: $d}},
      links: {html: {href: "https://bitbucket.org/septeo-immobilier/modelo-bill-e/pull-requests/229"}},
      participants: $p}')"
}

# fx_participant ACCOUNT NAME APPROVED STATE
fx_participant() {
  jq -n --arg a "$1" --arg n "$2" --argjson ap "$3" --arg st "$4" \
    '{user: {account_id: $a, display_name: $n}, approved: $ap, state: (if $st == "" then null else $st end)}'
}

# fx_statuses HEAD STATUS_JSON_ARRAY   items: {key,name,state}
fx_statuses() {
  fx_put "repositories/$FX_REPO/commit/$1/statuses?pagelen=100" "$(jq -n --argjson v "$2" '{values: $v}')"
}

# fx_comments PAGE_JSON_ARRAY [NEXT_PAGE_NUMBER] [PAGE_NUMBER]
fx_comments() {
  local tail="repositories/$FX_REPO/pullrequests/$FX_PR/comments?pagelen=100"
  [ -n "${3:-}" ] && tail="$tail&page=$3"
  if [ -n "${2:-}" ]; then
    fx_put "$tail" "$(jq -n --argjson v "$1" --arg n "$BBW_API_BASE/repositories/$FX_REPO/pullrequests/$FX_PR/comments?pagelen=100&page=$2" '{values: $v, next: $n}')"
  else
    fx_put "$tail" "$(jq -n --argjson v "$1" '{values: $v}')"
  fi
}

# fx_comment ID AUTHOR [PATH LINE] [DELETED]
fx_comment() {
  jq -n --argjson id "$1" --arg a "$2" --arg p "${3:-}" --arg l "${4:-}" --argjson del "${5:-false}" \
    '{id: $id, user: {display_name: $a}, deleted: $del} + (if $p == "" then {} else {inline: {path: $p, to: ($l | tonumber)}} end)'
}

# fx_diffstat CONFLICT(true|false)
fx_diffstat() {
  local st=modified
  [ "$1" = true ] && st="merge conflict"
  fx_put "repositories/$FX_REPO/pullrequests/$FX_PR/diffstat?pagelen=500" "$(jq -n --arg s "$st" '{values: [{status: $s}]}')"
}

# fx_default — an open PR with one running pipeline, no comment, no review.
fx_default() {
  fx_pr OPEN abc123 def456 '[]'
  fx_statuses abc123 '[{"key":"pr-analysis","name":"PR analysis","state":"INPROGRESS"}]'
  fx_comments '[]'
  fx_diffstat false
}
