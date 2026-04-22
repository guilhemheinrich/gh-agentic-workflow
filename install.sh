#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

TARGETS=("$HOME/.cursor" "$HOME/.pi")

RESOURCES=(skills rules hooks agents commands)

for target in "${TARGETS[@]}"; do
  for res in "${RESOURCES[@]}"; do
    src="$REPO_DIR/$res"
    [ -d "$src" ] || continue
    mkdir -p "$target/$res"
    cp -Rf "$src"/* "$target/$res"/
    echo "  $res -> $target/$res"
  done
  echo ""
done

echo "Done."
