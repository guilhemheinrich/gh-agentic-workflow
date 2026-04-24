---
description: >-
  A universal Docker volume pattern to reconcile hot-reload with
  container-isolated node_modules
tags:
  - docker
  - typescript
---

# Docker Hot-Reload Volume Pattern (Agnostic)

**Description:** A universal Docker volume pattern to reconcile **hot-reload** (live code editing on the host) with **container-isolated node_modules** (installed inside Docker). Ideal for Node.js monorepos where dependencies should not exist on or pollute the host machine.

---

## The Problem

In development, we face two conflicting requirements:

| Requirement | Solution | Side Effect |
|:---|:---|:---|
| Edit code on host, see changes instantly | Bind mount `./apps/<service>:/app` | Overwrites **everything** in `/app`, including the `node_modules` installed during build. |
| Keep `node_modules` from the Docker build | Volume for `/app/node_modules` | Gets hidden or deleted by the bind mount above. |

---

## The Solution: 3-Layer Volume Stack

The pattern uses three volume layers that Docker mounts **in order** before the entrypoint runs:

1.  **Layer 1 (Bind Mount):** `./apps/<service>:/app` → Host source code (no `node_modules`).
2.  **Layer 2 (Anonymous Volume):** `/app/node_modules` → Persists dependencies between restarts.
3.  **Layer 3 (Specific Bind Mounts):** `./packages/<pkg>:/app/node_modules/<scope>/<pkg>` → Local workspace packages for live editing.

### The Dependency Cache Logic
A full copy of dependencies is "baked" into the image during the build stage at `/deps/node_modules`. The **entrypoint** uses this cache to populate the anonymous volume (Layer 2) only if it is empty.

---

## Implementation Reference

### 1. Dockerfile (Multi-stage)

```dockerfile
# Stage 1 — Dependency Installation
FROM <base-image> AS deps
WORKDIR /build
COPY package.json <lock-file> ./
# Copy monorepo manifests
COPY apps/<service-name>/package.json ./apps/<service-name>/
COPY packages/shared/package.json ./packages/shared/
RUN <package-manager> install

# Stage 2 — Runtime
FROM <runtime-image>
# Keep the dependency cache
COPY --from=deps /build/node_modules /deps/node_modules
WORKDIR /app
# The entrypoint script is the orchestrator
COPY .docker/scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
CMD ["<package-manager>", "run", "dev"]
```

### 2. compose.yml

```yaml
services:
  <service-name>:
    build:
      context: .
      dockerfile: apps/<service-name>/Dockerfile
    volumes:
      - ./apps/<service-name>:/app                                 # Layer 1: Source code
      - /app/node_modules                                          # Layer 2: Anon Volume
      - ./packages/<pkg-name>:/app/node_modules/<scope>/<pkg-name> # Layer 3: Workspace PKG
```

### 3. entrypoint.sh (Generic)

This script detects if the volume is empty and intelligently copies the cache while avoiding overwriting active bind mounts from Layer 3.

```sh
#!/bin/sh
set -e

# Configuration
SERVICE_NAME="<service-name>"
SCOPE_NAME="@<your-org-scope>" # Leave empty if no scope is used

if [ ! -d "/app/node_modules/.bin" ]; then
  echo "==> [$SERVICE_NAME] Populating node_modules from build cache..."
  mkdir -p /app/node_modules

  # 1. Copy root packages (excluding the scope directory)
  for item in /deps/node_modules/* /deps/node_modules/.*; do
    name=$(basename "$item")
    [ "$name" = "." ] || [ "$name" = ".." ] || [ "$name" = "$SCOPE_NAME" ] && continue
    cp -a "$item" /app/node_modules/
  done

  # 2. Selective scope copy (prevents overwriting Layer 3 bind mounts)
  if [ -n "$SCOPE_NAME" ] && [ -d "/deps/node_modules/$SCOPE_NAME" ]; then
    mkdir -p "/app/node_modules/$SCOPE_NAME"
    for pkg in /deps/node_modules/$SCOPE_NAME/*; do
      pkg_name=$(basename "$pkg")
      target="/app/node_modules/$SCOPE_NAME/$pkg_name"
      
      # Check if directory exists and is NOT empty (meaning Docker already mounted it)
      if [ -d "$target" ] && [ -n "$(ls -A "$target")" ]; then
        echo "==> [$SERVICE_NAME] Skipping $SCOPE_NAME/$pkg_name (active bind mount)"
        continue
      fi
      cp -a "$pkg" "$target"
    done
  fi
fi

echo "==> [$SERVICE_NAME] Starting service..."
exec "$@"
```

---

## Common Pitfalls & Fixes

* **"File exists" error at startup:** Usually happens if you use a global `cp -a`. The entrypoint loop above fixes this by checking if the target directory is already occupied by a mount.
* **Stale dependencies:** Since anonymous volumes persist, adding a new package to `package.json` won't trigger a re-copy. 
    * **Fix:** Run `docker compose down -v` to wipe the volumes and force a fresh sync.
* **Module Not Found:** Ensure the workspace package is correctly referenced in both the `Dockerfile` (for the build cache) and the `compose.yml` (for the runtime mount).

---

## Skills connexes

| Skill | Quand la consulter |
|:---|:---|
| [dockerfile-dev-prod](../dockerfile-dev-prod/SKILL.md) | Pattern multi-stage `development` / `production` avec `make lock` — à combiner avec ce pattern pour le Dockerfile |
| [docker-compose-orchestration](../docker-compose-orchestration/SKILL.md) | Orchestration complète multi-services, réseaux, health checks |
| [docker-containerization](../docker-containerization/SKILL.md) | Bonnes pratiques générales : sécurité, `.dockerignore`, images minimales |
| [npm-private-registry](../npm-private-registry/SKILL.md) | Intégrer un registre npm privé dans le build Docker (`.npmrc`, `NPM_TOKEN`) |
