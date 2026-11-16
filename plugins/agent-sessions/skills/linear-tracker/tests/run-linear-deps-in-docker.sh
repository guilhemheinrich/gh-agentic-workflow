#!/usr/bin/env bash
# run-linear-deps-in-docker.sh — run the linear_deps tests in a throwaway container (stdlib only).
set -euo pipefail
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec docker run --rm -v "$SKILL_DIR:/skill:ro" -w /skill/tests python:3.12-alpine \
  python3 -B -m unittest -v linear_deps_test
