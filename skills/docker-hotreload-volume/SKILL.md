---
name: docker-hotreload-volume
description: >-
  Docker volume pattern that reconciles hot reload (bind-mounted source) with a
  container-isolated node_modules in Node.js monorepos. Use when a bind mount
  hides node_modules, workspace packages must be live-edited in a container, or
  startup fails with "File exists" / "Module not found" after adding a package.
tags:
  - docker
  - typescript
---

# Docker hot-reload volume pattern

Edit code on the host with live reload while `node_modules` stays installed inside Docker. A bind mount of `./apps/<service>:/app` hides the `node_modules` installed at build, so the dependencies are rebuilt into a volume at startup.

## 3-layer volume stack

Docker mounts these in order, before the entrypoint runs:

1. **Bind mount** `./apps/<service>:/app`: host source, no `node_modules`.
2. **Anonymous volume** `/app/node_modules`: persists dependencies across restarts.
3. **Specific bind mounts** `./packages/<pkg>:/app/node_modules/<scope>/<pkg>`: workspace packages, live-editable.

The image bakes a full copy of dependencies at `/deps/node_modules`. The entrypoint copies it into the volume (layer 2) **only if empty**, and skips scope packages that are already bind-mounted (non-empty directories).

## Files

- `templates/Dockerfile.snippet`: deps stage + runtime stage keeping the cache at `/deps/node_modules`.
- `templates/compose.snippet.yml`: the three volume layers.
- `templates/entrypoint.sh`: conditional populate, then `exec "$@"`. Set `SERVICE_NAME` and `SCOPE_NAME`.

## Pitfalls

- **"File exists" at startup**: a global `cp -a` collides with layer-3 mounts; the per-package loop in the entrypoint avoids it.
- **Stale dependencies**: the anonymous volume persists, so a new package in `package.json` is not copied. Run `docker compose down -v` to wipe volumes and resync.
- **Module not found**: the workspace package must be referenced in both the Dockerfile (manifest copy, for the cache) and compose (runtime mount).

## Related

- `dockerfile`: dev/prod stages and lockfile generation.
- `npm-private-registry`: private scopes at install time.
