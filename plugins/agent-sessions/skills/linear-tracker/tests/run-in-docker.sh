#!/usr/bin/env bash
# run-in-docker.sh — run the lifecycle hook tests in a throwaway container.
# The image carries only what the hook may use in a consumer repo: bash, jq, git.
set -euo pipefail
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec docker run --rm -v "$SKILL_DIR:/skill:ro" alpine:3.20 \
  sh -c 'apk add --no-cache -q bash jq git >/dev/null && bash /skill/tests/lifecycle.test.sh'
