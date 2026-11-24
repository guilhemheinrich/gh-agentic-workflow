#!/usr/bin/env bash
# scan-secrets.sh - find committed credentials, in the working tree AND in git history.
#
# Docker-only. The secret value is never written anywhere: gitleaks runs with
# --redact, and trufflehog output is stripped of its Raw/RawV2/Redacted fields
# before it reaches disk. Reports hold rule, file, line and commit only.
#
# Exit codes: 0 = nothing found, 1 = at least one finding, 2 = scan failed.
set -euo pipefail

GITLEAKS_IMAGE="${GITLEAKS_IMAGE:-zricethezav/gitleaks:v8.30.1}"
TRUFFLEHOG_IMAGE="${TRUFFLEHOG_IMAGE:-trufflesecurity/trufflehog:3.100.1}"
JQ_IMAGE="${JQ_IMAGE:-ghcr.io/jqlang/jq:1.8.2}"

usage() {
  cat <<'EOF'
Usage: scan-secrets.sh [--out DIR] [--no-history] [--trufflehog] [--verify] [TARGET_DIR]

  TARGET_DIR     project to scan (default: current directory)
  --out DIR      where reports are written (required, or $SECURITY_AUDIT_OUT; a fresh
               directory outside the checkout: OUT=$(mktemp -d))
  --no-history   skip the git history scan
  --trufflehog   also run trufflehog (second opinion, different detectors)
  --verify       wrapper option (NOT a trufflehog flag: raw trufflehog verifies
                 by default, this wrapper passes --no-verification unless
                 --verify is given). Lets trufflehog test each candidate.
                 This SENDS the credential to the provider's API to see if it
                 is live: only with the owner's explicit authorization.

Outputs in DIR:
  secrets-worktree.json   gitleaks, files as they are on disk (ignored files included)
  secrets-history.json    gitleaks, every commit reachable from any ref
  secrets-trufflehog.json trufflehog (only with --trufflehog)
EOF
}

OUT="${SECURITY_AUDIT_OUT:-}"
HISTORY=1
TRUFFLEHOG=0
VERIFY=0
TARGET="."
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --no-history) HISTORY=0; shift ;;
    --trufflehog) TRUFFLEHOG=1; shift ;;
    --verify) VERIFY=1; TRUFFLEHOG=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) TARGET="$1"; shift ;;
  esac
done

command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 2; }
[ -d "$TARGET" ] || { echo "not a directory: $TARGET" >&2; exit 2; }
TARGET="$(cd "$TARGET" && pwd)"
. "$(dirname "$0")/out-guard.sh"
check_out_dir "$TARGET"

jq_run() { docker run --rm -i "$JQ_IMAGE" "$@"; }

# The repository is mounted at its own absolute path so that a linked git
# worktree (whose .git is a file pointing at <main>/.git/worktrees/<name>)
# still resolves. The shared git directory is mounted too when it lives
# outside TARGET.
MOUNTS=(-v "$TARGET":"$TARGET":ro)
IS_REPO=0
if command -v git >/dev/null 2>&1 && git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1; then
  IS_REPO=1
  TOP="$(git -C "$TARGET" rev-parse --show-toplevel)"
  COMMON="$(cd "$TARGET" && cd "$(git rev-parse --git-common-dir)" && pwd)"
  [ "$TOP" = "$TARGET" ] || MOUNTS+=(-v "$TOP":"$TOP":ro)
  case "$COMMON" in "$TOP"/*) ;; *) MOUNTS+=(-v "$COMMON":"$COMMON":ro) ;; esac
fi
# The container user differs from the owner of the mounted repo.
GIT_ENV=(-e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e "GIT_CONFIG_VALUE_0=*")

gitleaks() { # <subcommand> <report-name> [extra args...]
  local sub="$1" report="$2" rc=0
  shift 2
  docker run --rm "${MOUNTS[@]}" -v "$OUT":/out "${GIT_ENV[@]}" "$GITLEAKS_IMAGE" \
    "$sub" "$TARGET" --redact --no-banner --exit-code 3 \
    --report-format json --report-path "/out/$report" "$@" >"$OUT/${report%.json}.log" 2>&1 || rc=$?
  # 0 = clean, 3 = leaks (set above); anything else is a tool failure.
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
    echo "[secrets] gitleaks $sub failed (exit $rc), see $OUT/${report%.json}.log" >&2
    exit 2
  fi
}

echo "[secrets] gitleaks, working tree ($GITLEAKS_IMAGE)" >&2
gitleaks dir secrets-worktree.json
total="$(jq_run 'length' <"$OUT/secrets-worktree.json")"
jq_run -r --arg t "$TARGET/" '.[] | "worktree \(.RuleID) \(.File | ltrimstr($t)):\(.StartLine)"' <"$OUT/secrets-worktree.json"

if [ "$HISTORY" -eq 1 ]; then
  if [ "$IS_REPO" -eq 1 ]; then
    echo "[secrets] gitleaks, git history (all refs)" >&2
    if [ "$(git -C "$TARGET" rev-parse --is-shallow-repository)" = "true" ]; then
      echo "[secrets] INCOMPLETE: shallow clone, only part of the history is scanned (git fetch --unshallow)" >&2
    fi
    # Scanning a sub-directory of a repository: restrict the log to that path.
    if [ "$TOP" = "$TARGET" ]; then log_opts="--all"; else log_opts="--all -- ."; fi
    gitleaks git secrets-history.json "--log-opts=$log_opts"
    n="$(jq_run 'length' <"$OUT/secrets-history.json")"
    total=$((total + n))
    jq_run -r '.[] | "history \(.RuleID) \(.File):\(.StartLine) commit \(.Commit[0:12]) \(.Date)"' <"$OUT/secrets-history.json"
  else
    echo "[secrets] INCOMPLETE: not a git repository, history NOT scanned" >&2
  fi
fi

if [ "$TRUFFLEHOG" -eq 1 ]; then
  echo "[secrets] trufflehog ($TRUFFLEHOG_IMAGE), verification $([ "$VERIFY" -eq 1 ] && echo ON || echo off)" >&2
  th_args=(--json --no-update)
  [ "$VERIFY" -eq 1 ] || th_args+=(--no-verification)
  if [ "$IS_REPO" -eq 1 ] && [ "$HISTORY" -eq 1 ]; then
    th_cmd=(git "file://$TARGET")
  else
    th_cmd=(filesystem "$TARGET")
  fi
  docker run --rm "${MOUNTS[@]}" "${GIT_ENV[@]}" "$TRUFFLEHOG_IMAGE" "${th_cmd[@]}" "${th_args[@]}" 2>"$OUT/secrets-trufflehog.log" \
    | jq_run -s 'map(select(.DetectorName != null) | del(.Raw, .RawV2, .Redacted, .ExtraData, .StructuredData))' \
    >"$OUT/secrets-trufflehog.json"
  n="$(jq_run 'length' <"$OUT/secrets-trufflehog.json")"
  total=$((total + n))
  jq_run -r '.[] | "trufflehog \(.DetectorName) verified=\(.Verified) \(.SourceMetadata.Data | to_entries[0].value | "\(.file):\(.line)")"' <"$OUT/secrets-trufflehog.json"
fi

echo "[secrets] $total finding(s) -> $OUT/secrets-*.json (values redacted)" >&2
if [ "$total" -gt 0 ]; then
  echo "[secrets] NEXT: tell the credential owner now (file:line only); the OWNER rotates before the repo is cleaned; never paste the value anywhere" >&2
  exit 1
fi
exit 0
