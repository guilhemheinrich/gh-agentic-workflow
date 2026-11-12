#!/usr/bin/env bash
# run-in-docker.sh — run the lw (Linear watcher) unit tests in a throwaway
# python:3.12-slim container. The linear-tracker skill is mounted read-only;
# tests write only to temp dirs.
#
#   bash tests/linear-watch/run-in-docker.sh                 # every tests/linear-watch/test_*.py
#   bash tests/linear-watch/run-in-docker.sh test_store      # one module
set -euo pipefail
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [ "$#" -gt 0 ]; then
  args=(-m unittest -v "$@")
else
  args=(-m unittest discover -s tests/linear-watch -v)
fi
exec docker run --rm \
  -v "$SKILL_DIR:/skill:ro" -w /skill \
  -e PYTHONDONTWRITEBYTECODE=1 -e PYTHONPATH=/skill/tests/linear-watch \
  python:3.12-slim python "${args[@]}"
