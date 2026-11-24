#!/usr/bin/env bash
# run-probe.sh - run interaction-probe.mjs inside the official Playwright image.
#
# Nothing is installed on the host. playwright-core and axe-core are installed
# once into a named Docker volume, at versions pinned below.
#
# Usage:
#   run-probe.sh --flows <flows.json> --out <dir> [probe options...]
#   run-probe.sh --self-test [--out <dir>]
#
# Probe options are passed through (see the header of interaction-probe.mjs):
#   --base-url URL | --serve DIR (static build served inside the container)
#   --runs N --cpu RATE --viewport WxH --settle-ms N
#   --timeout-ms N --storage-state FILE --no-react-hook --no-mutations --strict
#   --authorized-target   required for any host other than the audit host
#                         (loopback, host.docker.internal): private IPs and
#                         compose services included. Pass it only when the
#                         owner approved the target, its backends AND the
#                         flows. On production: read-only flows only.
#                         The run prints every origin the page contacted.
#
# --self-test drives scripts/fixtures and asserts each deliberate defect raises
# its flag (exit 3 when an assertion fails, 2 when a step cannot run).
#
# Outputs (interaction-probe.json, dom/) can hold session data and personal
# data from the audited app: keep them out of the repo, redact before sharing.
#
# Reaching an app that runs on the host: use http://host.docker.internal:<port>
# as base URL. Reaching an app in a compose network: PROBE_NETWORK=<network>.
#
# Environment:
#   PLAYWRIGHT_IMAGE  default mcr.microsoft.com/playwright:v1.65.1-noble
#   PLAYWRIGHT_VERSION, AXE_VERSION  npm versions; PLAYWRIGHT_VERSION must match the image tag
#   PROBE_NETWORK     docker network to join (default: bridge)
set -euo pipefail

PLAYWRIGHT_VERSION="${PLAYWRIGHT_VERSION:-1.65.1}"
AXE_VERSION="${AXE_VERSION:-4.14.1}"
PLAYWRIGHT_IMAGE="${PLAYWRIGHT_IMAGE:-mcr.microsoft.com/playwright:v${PLAYWRIGHT_VERSION}-noble}"
VOLUME="audit-frontend-probe-pw${PLAYWRIGHT_VERSION}-axe${AXE_VERSION}"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

flows=""
out=""
storage=""
serve=""
self_test=0
pass=()
while [ $# -gt 0 ]; do
  case "$1" in
    --flows) flows="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --storage-state) storage="$2"; shift 2 ;;
    --serve) serve="$2"; shift 2 ;;
    --self-test) self_test=1; shift ;;
    -h|--help) sed -n '2,35p' "$0"; exit 0 ;;
    *) pass+=("$1"); shift ;;
  esac
done

if [ "$self_test" = 1 ]; then
  flows="$SKILL_DIR/scripts/fixtures/flows.example.json"
  serve="$SKILL_DIR/scripts/fixtures"
  out="${out:-./audit-frontend-out/self-test}"
fi
if [ -z "$flows" ] || [ -z "$out" ]; then
  echo "error: --flows and --out are required (or --self-test)" >&2
  exit 2
fi
[ -f "$flows" ] || { echo "error: flows file not found: $flows" >&2; exit 2; }
command -v docker >/dev/null || { echo "error: docker is required" >&2; exit 2; }

mkdir -p "$out"
flows_abs="$(cd "$(dirname "$flows")" && pwd)/$(basename "$flows")"
out_abs="$(cd "$out" && pwd)"

mounts=(
  -v "$SKILL_DIR/scripts:/skill:ro"
  -v "$(dirname "$flows_abs"):/flows:ro"
  -v "$out_abs:/out"
  -v "$VOLUME:/probe"
)
probe_args=(--flows "/flows/$(basename "$flows_abs")" --out /out)
if [ -n "$storage" ]; then
  storage_abs="$(cd "$(dirname "$storage")" && pwd)/$(basename "$storage")"
  mounts+=(-v "$storage_abs:/auth/state.json:ro")
  probe_args+=(--storage-state /auth/state.json)
fi
if [ -n "$serve" ]; then
  [ -d "$serve" ] || { echo "error: --serve directory not found: $serve" >&2; exit 2; }
  mounts+=(-v "$(cd "$serve" && pwd):/site:ro")
  probe_args+=(--serve /site)
fi
network=()
if [ -n "${PROBE_NETWORK:-}" ]; then network=(--network "$PROBE_NETWORK"); fi

# Relative goto targets without a base URL resolve against the flows directory.
docker run --rm --init --ipc=host \
  --add-host=host.docker.internal:host-gateway \
  "${network[@]+"${network[@]}"}" \
  "${mounts[@]}" \
  -w /flows \
  -e PROBE_MODULES=/probe \
  -e PLAYWRIGHT_VERSION="$PLAYWRIGHT_VERSION" -e AXE_VERSION="$AXE_VERSION" \
  "$PLAYWRIGHT_IMAGE" \
  bash -c '
    set -euo pipefail
    if [ ! -d /probe/node_modules/playwright-core ] || [ ! -d /probe/node_modules/axe-core ]; then
      cd /probe
      npm install --silent --no-audit --no-fund --no-package-lock --prefix /probe \
        "playwright-core@${PLAYWRIGHT_VERSION}" "axe-core@${AXE_VERSION}" >&2
      cd /flows
    fi
    exec node /skill/interaction-probe.mjs "$@"
  ' probe "${probe_args[@]}" "${pass[@]+"${pass[@]}"}"
