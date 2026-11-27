# Watchers in Docker (Windows)

Runs the `pr-watch` daemon (`prw daemon run`, bash) and the `linear-watch`
daemon (`lw daemon run`, python) in containers.

## Why

Both daemons are plain foreground loops; `launchd` only supervises them, and
`launchd` exists on macOS only. On Windows, Docker (`restart: unless-stopped`,
a healthcheck) plays the supervisor.

## Architecture

- One image (`Dockerfile`, build context = repository root) holds bash, curl,
  jq, git, python3, tini and the `linear` CLI, plus `skills/pr-watch` and
  `skills/linear-atlas` and `skills/linear-semantics` **copied** to `/opt/watchers/` (so the "refusing: git
  checkout" guards are not involved).
- Two services, `prw` and `lw`, from `compose.yml`, both with tini as the image
  entrypoint (no compose `init: true`: a second tini would only warn).
- State lives in **named volumes** (`prw-state`, `lw-state`), never bind mounts:
  SQLite WAL and `mkdir` locks are unreliable across the Windows/Linux
  boundary.
- Credentials are bind-mounted read-only from host files. `compose.yml` holds no
  value; every path comes from the unversioned `.env` (`${VAR:?}`).
- `lw` also mounts the Claude Desktop sessions folder read-only.
- The host talks to the daemons through `docker compose exec -T` wrappers
  (`prw`, `prw.cmd`, `lw`, `lw.cmd`), so every `prw ...` / `lw ...` command
  runs inside the container against the container's state.

The `linear` CLI is installed at build time from the
[schpet/linear-cli](https://github.com/schpet/linear-cli) GitHub release
(`LINEAR_CLI_VERSION` build arg, default `v3.1.0`, Linux tarball for the build
architecture, verified against the `.sha256` file of the release). Pin another
version with `docker compose build --build-arg LINEAR_CLI_VERSION=vX.Y.Z`.

## Setup

1. `copy .env.example .env` and fill in the host paths:
   the `pr-watch` env file (tokens), the `~/.config/linear` directory
   (`LINEAR_CONFIG_DIR_HOST`, mounted read-only), and the Claude Desktop
   `claude-code-sessions` folder. Never commit `.env`.

   **Multiple Linear workspaces.** The whole `~/.config/linear` directory is
   mounted, so `lw` sees one credential file per workspace: `env` is the
   default key and `<workspace>.env` is the key of the workspace
   `linear.app/<workspace>/...`, each containing `LINEAR_API_KEY=...`. The
   lookup order is the one of `skills/linear-atlas/scripts/linear_creds.py`.
   Adding a workspace only means adding a file on the host; no compose change
   or rebuild is needed.
2. From this folder: `docker compose up -d --build`.
3. Put this folder on `PATH` (or call the wrappers by full path) to use
   `prw` / `lw` from `cmd`, PowerShell or Git Bash.

## Health and logs

- `docker compose ps` shows `healthy` once `prw daemon alive` / `lw daemon
  alive` succeed (heartbeat younger than three poll intervals).
- `prw daemon alive`, `lw daemon alive`, `lw doctor` through the wrappers.
- Daemon log lines: `docker compose logs -f prw lw`; the files
  `daemon.log` live in the volumes.
- A missing credential does not stop the loop: `prw` logs `credential missing`
  every cycle and keeps its heartbeat, so the container stays healthy. Read the
  log, not only the health status, after the first start.

## Using the wrappers from the skills

The Claude hooks are bash scripts. `adapters/claude/find-prw.sh` resolves `prw`
from `$PRW_BIN` first (it must be an existing file), and the linear-atlas
session-start hook resolves `lw` from `$LW_BIN`. The MCP servers (`lw_mcp.py`,
`prw_mcp.py`) run it with a Windows Python, which cannot execute a bash script
(`WinError 193`), so on Windows point both at the `.cmd` wrappers, with forward
slashes (the servers split the value with `shlex`, which eats backslashes):

```json
"env": {
  "LW_BIN": "D:/code/gh-agentic-workflow/scripts/watchers-docker/lw.cmd",
  "PRW_BIN": "D:/code/gh-agentic-workflow/scripts/watchers-docker/prw.cmd"
}
```

An extensionless value is upgraded to its `.cmd` sibling on Windows when that file
exists. Claude reads `env` from `settings.json` at session start: **restart the
Claude session** after editing it. A value that cannot be executed no longer kills
the MCP server: every tool (`lw_doctor`, `prw_doctor` included) answers with an
error naming the command tried and the variable. The hooks are untested with the
`.cmd` form.

The wrappers check that the script exists in the container before running it and
exit 127 with a message naming the missing path (for example
`/opt/watchers/linear-atlas/scripts/lw`) when the container is down or its image is
stale: rebuild with `docker compose -f scripts/watchers-docker/compose.yml up -d --build`.

The session-start hooks run `daemon alive || daemon start`. With the container
as supervisor, `daemon start` (launchd) must never run: it fails on Windows
(no `launchctl`), so a dead daemon is a container problem, fixed with
`docker compose up -d` / `restart`, not by the hook.

## Limitations

- `prw wait` through `docker exec -T` was checked against a synthetic
  subscription: it blocks, wakes when an event line reaches the container's
  events file, prints it and exits with the script's own code. It was not
  checked against a live PR or with a harness hook.
- Session ids come from the **host** session; the container only stores what
  `prw subscribe --session ...` / `lw` hand it. The wrapper does not forward
  host environment variables (such as a session id exported by the harness):
  pass them as explicit arguments.
- Host paths given to a wrapper (for example `--file C:\x`) are not visible
  inside the container; only the mounts above exist.
- `docker compose` must be reachable from the shell that runs the wrappers
  (Docker Desktop running).

## Alternative: WSL2

Run the skills inside a WSL2 distribution and use their own scripts there:
`prw daemon run` / `lw daemon run` under `nohup` or systemd (`systemd=true` in
`/etc/wsl.conf`). No container is needed, but the daemons stop with WSL.
