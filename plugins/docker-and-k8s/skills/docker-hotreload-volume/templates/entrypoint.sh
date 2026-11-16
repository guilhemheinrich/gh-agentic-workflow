#!/bin/sh
# Populate the anonymous node_modules volume from the image cache (/deps)
# without overwriting active workspace bind mounts (layer 3).
set -e

SERVICE_NAME="<service-name>"
SCOPE_NAME="@<your-org-scope>" # leave empty if no scope is used

if [ ! -d "/app/node_modules/.bin" ]; then
  echo "==> [$SERVICE_NAME] Populating node_modules from build cache..."
  mkdir -p /app/node_modules

  # 1. Root packages, excluding the scope directory
  for item in /deps/node_modules/* /deps/node_modules/.*; do
    name=$(basename "$item")
    if [ "$name" = "." ] || [ "$name" = ".." ] || [ "$name" = "$SCOPE_NAME" ]; then
      continue
    fi
    cp -a "$item" /app/node_modules/
  done

  # 2. Scope packages, skipping non-empty targets (already bind-mounted)
  if [ -n "$SCOPE_NAME" ] && [ -d "/deps/node_modules/$SCOPE_NAME" ]; then
    mkdir -p "/app/node_modules/$SCOPE_NAME"
    for pkg in /deps/node_modules/$SCOPE_NAME/*; do
      pkg_name=$(basename "$pkg")
      target="/app/node_modules/$SCOPE_NAME/$pkg_name"
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
