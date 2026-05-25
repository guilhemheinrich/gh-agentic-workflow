#!/usr/bin/env bash
# Standalone copy of scripts/lint-route.sh's routing arrays.
# Used by tests under tests/hooks/lint_route.bats.
# Keep in sync with the canonical script — verified by a test in lint_route.bats.

LINT_ROUTES=(
  ".ts:lint-ts"  ".tsx:lint-ts"
  ".js:lint-js"  ".jsx:lint-js"
  ".json:lint-json"
  ".yml:lint-yaml" ".yaml:lint-yaml"
  ".md:lint-md"    ".mdc:lint-md"
  ".sh:lint-sh"    ".bash:lint-sh"
  ".py:lint-py"
  ".go:lint-go"
  ".rs:lint-rs"
)

LINT_IGNORED=(
  ".png" ".jpg" ".jpeg" ".gif" ".webp" ".svg" ".ico"
  ".woff" ".woff2" ".ttf" ".eot"
  ".lock" ".lockb"
  ".pdf" ".zip" ".tar" ".tgz" ".gz"
  ".env" ".envrc"
)

LINT_EXCLUDED_PATHS=(
  "node_modules/" "dist/" "build/" ".next/" ".nuxt/"
  ".git/" ".cache/" "coverage/" "vendor/" ".venv/"
)
