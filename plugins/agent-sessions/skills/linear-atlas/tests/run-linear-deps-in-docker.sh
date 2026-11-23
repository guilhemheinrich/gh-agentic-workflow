#!/usr/bin/env bash
# run-linear-deps-in-docker.sh — run the linear_deps tests in a throwaway container (stdlib only).
set -euo pipefail
SKILLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec docker run --rm -v "$SKILLS_DIR:/skills:ro" -w /skills/linear-atlas/tests python:3.12-alpine \
  python3 -B -m unittest -v linear_deps_test linear_serve_test linear_store_test lw_mcp_test
