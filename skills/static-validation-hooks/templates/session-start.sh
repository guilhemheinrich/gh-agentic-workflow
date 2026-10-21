#!/bin/bash
# .claude/hooks/session-start.sh
#
# SessionStart hook — Claude Code cloud sessions only. A cloud session starts
# from a fresh clone: no node_modules, no virtualenv, usually no running
# compose stack. A routing table that runs linters on the host then has
# nothing to run, and warns "not installed" once before falling silent for the
# whole session. This installs the dependencies before the session begins.
#
# Local sessions are left alone: their dependencies are the developer's.
#
# Keep only the block matching the stack, then add whatever the linters or the
# tests need built first (workspace packages consumed through their `dist`,
# generated clients). Mirror the CI install step — it is the one already proven
# to work from a clean checkout.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"

# Every install writes to stderr: the hook's stdout is a protocol channel, and
# a stray line there can be read as hook output.
#
# Prefer a plain install over a frozen/clean one (`npm ci`, `--frozen-lockfile`):
# the container state is cached after this hook completes, and a plain install
# reuses what is already there on the next start.
if [ -f pnpm-lock.yaml ]; then
  pnpm install --prefer-offline >&2
elif [ -f package-lock.json ]; then
  npm install --no-audit --no-fund >&2
elif [ -f yarn.lock ]; then
  yarn install >&2
elif [ -f uv.lock ]; then
  uv sync >&2
elif [ -f poetry.lock ]; then
  poetry install --no-interaction >&2
elif [ -f requirements.txt ]; then
  pip install -r requirements.txt >&2
elif [ -f go.mod ]; then
  go mod download >&2
fi

# Project-specific build steps go here, e.g. for a pnpm monorepo whose tests
# import workspace packages through their `dist`:
#   pnpm -r --filter "./packages/**" build >&2

# The runner switches to host mode here on its own (VALIDATE_EXEC=auto reads
# CLAUDE_CODE_REMOTE): there is no Docker in a cloud session. Activate the
# versioned pre-commit replay (templates/pre-commit.sh) too, so files written
# through the Bash tool are validated at commit time.
if [ -d .githooks ]; then
  git config core.hooksPath .githooks
fi
