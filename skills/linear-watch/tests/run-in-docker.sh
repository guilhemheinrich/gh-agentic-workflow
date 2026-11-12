#!/usr/bin/env bash
# run-in-docker.sh — run the lw unit tests in a throwaway python:3.12-slim
# container. The skill is mounted read-only; tests write only to temp dirs.
#
#   bash tests/run-in-docker.sh                 # every tests/test_*.py
#   bash tests/run-in-docker.sh test_store      # one module
set -euo pipefail
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "$#" -gt 0 ]; then
  args=(-m unittest -v "$@")
else
  args=(-m unittest discover -s tests -v)
fi
exec docker run --rm \
  -v "$SKILL_DIR:/skill:ro" -w /skill \
  -e PYTHONDONTWRITEBYTECODE=1 -e PYTHONPATH=/skill/tests \
  python:3.12-slim python "${args[@]}"
