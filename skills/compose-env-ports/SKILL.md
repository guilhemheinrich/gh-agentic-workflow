---
name: compose-env-ports
description: >-
  Detect and resolve local Docker Compose host-port collisions by reading compose.yml,
  compose.yaml, docker-compose.yml, or docker-compose.yaml, extracting .env-backed
  published-port variables, checking Docker Engine and local listener ports, and
  generating deterministic free port assignments. Use when adjusting .env files for
  Compose stacks, avoiding default port conflicts, converting published ports to
  ${VAR:-default} patterns, or preparing docker compose up on a workstation with many
  active stacks.
---

# Compose Env Ports

## Overview

Use this skill to make local Docker Compose host ports explicit, `.env`-controlled, and collision-free. Prefer the bundled script for deterministic detection and candidate generation; fall back to the manual workflow only when required tools are unavailable.

## Default Workflow

1. Locate the compose file in this order unless the user gives a path: `compose.yml`, `compose.yaml`, `docker-compose.yml`, `docker-compose.yaml`.
2. Run the bundled script in dry-run mode from the target project root:

   ```bash
   bash skills/compose-env-ports/scripts/compose-env-ports.sh --root . --dry-run
   ```

   If the skill is installed outside the repository, use the absolute path to `scripts/compose-env-ports.sh`.
3. Review the proposed assignments. The script is dry-run by default and never edits `.env` unless `--apply` is passed.
4. Apply the assignments when they are appropriate:

   ```bash
   bash skills/compose-env-ports/scripts/compose-env-ports.sh --root . --apply
   ```

5. If literal published host ports are reported, convert them to `.env`-backed defaults before rerunning:

   ```yaml
   ports:
     - "${WEB_PORT:-3000}:3000"
   ```

## Script Behavior

The script extracts only published host ports:

- Short syntax: `"${WEB_PORT:-3000}:3000"` and `"127.0.0.1:${WEB_PORT:-3000}:3000"`.
- Long syntax: `published: "${WEB_PORT:-3000}"`.
- Ignored values: container target ports, host IP variables, and variables without a numeric default unless the variable name contains `PORT`.

The script checks occupied ports through Docker Engine when available, then local TCP listeners through `lsof`, `ss`, or `netstat`. Candidate ports are deterministic: keep the existing `.env` value when it is valid and free; otherwise scan upward from the current/default value and stay inside the non-reserved range.

Useful options:

- `--compose <file>`: use a specific compose file.
- `--env <file>`: use a specific env file, default `.env`.
- `--start <port>` and `--end <port>`: override the candidate range.
- `--reserve <ports>`: exclude extra ports or ranges, for example `--reserve 3000,5000-5010`.
- `--apply`: update or create `.env`.

## Fallback Workflow

Use this deterministic manual procedure only if the script or required shell tools cannot run:

1. Inspect the compose `ports:` blocks and identify host-side published ports. Prefer variables shaped as `${SERVICE_PORT:-default}`.
2. List active Docker published ports with `docker ps --format '{{.Ports}}'`.
3. List local TCP listeners with the first available command: `lsof -nP -iTCP -sTCP:LISTEN`, `ss -H -ltn`, or `netstat -an`.
4. Avoid privileged ports below `1024`, avoid the OS ephemeral range, and avoid any extra reserved range provided by the user.
5. For each port variable, keep the `.env` value if it is numeric, in range, not already allocated, and not occupied. Otherwise scan upward from the current/default value until a free port is found.
6. Update `.env` with one `KEY=value` assignment per port variable. Do not modify unrelated `.env` keys.

When a compose file uses literal host ports, ask whether to convert them to `.env` variables or make the smallest obvious conversion using service-oriented names such as `WEB_PORT`, `API_PORT`, `POSTGRES_PORT`, and `REDIS_PORT`.
