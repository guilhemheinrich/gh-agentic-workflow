#!/usr/bin/env bash
# scripts/lint-route.sh
# Spec: specs/014-lint-on-edit-hook — Contract v1.0.0
# See: specs/014-lint-on-edit-hook/contracts/makefile-interface.md
#
# Dispatcher invoked by `make lint FILE=<path>`.
# Routes a file to the appropriate `make lint-<ext>` sub-target based on its
# extension. Bash 3.2-compatible (no declare -A, no bash-4-only features).
#
# Exit codes:
#   0   — File is explicitly ignored (no linter needed) or path is excluded.
#   64  — Policy gap: extension is neither routed nor explicitly ignored.
#         The agent MUST add the extension to LINT_ROUTES or LINT_IGNORED.
#   ≥1  — Delegated from make lint-<ext> (lint violations, wiring missing, etc.)
#
# Usage: scripts/lint-route.sh <file>

# No 'set -e': (( )) arithmetic returns 1 for falsy, which is not an error.
set -uo pipefail

# ── Routing table ─────────────────────────────────────────────────────────────
# Format: "ext:make-target" pairs in a plain array (Bash 3.2 compat — no declare -A)
# Edit this table to add or remove lintable extensions.
LINT_ROUTES=(
  ".ts:lint-ts"    ".tsx:lint-ts"
  ".js:lint-js"    ".jsx:lint-js"
  ".json:lint-json"
  ".yml:lint-yaml" ".yaml:lint-yaml"
  ".md:lint-md"    ".mdc:lint-md"
  ".sh:lint-sh"    ".bash:lint-sh"
  ".py:lint-py"
  ".go:lint-go"
  ".rs:lint-rs"
)

# Extensions that are explicitly out of scope — silent allow.
LINT_IGNORED=(
  ".png" ".jpg" ".jpeg" ".gif" ".webp" ".svg" ".ico"
  ".woff" ".woff2" ".ttf" ".eot"
  ".lock" ".lockb"
  ".pdf" ".zip" ".tar" ".tgz" ".gz"
  ".env" ".envrc"
  ".gitignore" ".dockerignore" ".npmignore"
)

# Path prefixes whose contents are never linted — silent allow.
LINT_EXCLUDED_PATHS=(
  "node_modules/" "dist/" "build/" ".next/" ".nuxt/"
  ".git/" ".cache/" "coverage/" "vendor/" ".venv/"
)

# ── Validate argument ─────────────────────────────────────────────────────────
if [[ $# -lt 1 || -z "${1:-}" ]]; then
  printf 'lint router: FILE argument is required.\n' >&2
  printf 'Usage: make lint FILE=path/to/file\n' >&2
  exit 64
fi

file="$1"

# ── Excluded path check ───────────────────────────────────────────────────────
for prefix in "${LINT_EXCLUDED_PATHS[@]}"; do
  case "$file" in
    "$prefix"* | "./$prefix"*)
      exit 0
      ;;
  esac
done

# ── Extension extraction ──────────────────────────────────────────────────────
filename="${file##*/}"
ext="${filename##*.}"
# No extension if the last '.' is the first character (e.g., .gitignore) or absent
if [[ "$ext" == "$filename" ]]; then
  ext=""
elif [[ "${filename:0:1}" == "." && "$filename" == ".$ext" ]]; then
  ext=""
else
  ext=".$ext"
fi

# ── Ignored extension check ───────────────────────────────────────────────────
if [[ -n "$ext" ]]; then
  for ignored in "${LINT_IGNORED[@]}"; do
    if [[ "$ext" == "$ignored" ]]; then
      exit 0
    fi
  done
fi

# ── Routed extension dispatch ─────────────────────────────────────────────────
if [[ -n "$ext" ]]; then
  for route in "${LINT_ROUTES[@]}"; do
    route_ext="${route%%:*}"
    route_target="${route#*:}"
    if [[ "$ext" == "$route_ext" ]]; then
      exec make "$route_target" FILE="$file"
    fi
  done
fi

# ── Policy gap ───────────────────────────────────────────────────────────────
if [[ -z "$ext" ]]; then
  # No conventional extension (e.g. Makefile, Dockerfile, .gitignore, .env)
  # → silent allow: no extension means no applicable lint policy.
  exit 0
else
  printf 'lint router: extension "%s" is neither routed nor ignored.\n' "$ext" >&2
  printf 'Declare it in scripts/lint-route.sh:\n' >&2
  printf '  Add to LINT_ROUTES:  "%s:lint-<target>"\n' "$ext" >&2
  printf '  Or add to LINT_IGNORED: "%s"\n' "$ext" >&2
fi
exit 64
