#!/usr/bin/env bash
# static-battery.sh - run the static test battery of a front-end audit in Docker.
#
# Nothing is installed on the host and the project checkout is never modified:
# it is mounted read-only and copied inside the container, where its
# dependencies are installed (lifecycle scripts disabled by default).
#
# Trust boundary: the build command, the project's lint configs and its
# lifecycle scripts are project-controlled code. Three containers keep them
# away from what they must not touch:
#   tools    installs the pinned audit tools (no project code, no credentials)
#   install  copies the project and installs its dependencies; the only stage
#            that receives NPM_TOKEN / NODE_AUTH_TOKEN
#   run      type-check, lint, build, knip: no registry credentials, no
#            network (unless --online), pinned tools mounted read-only
#   advisories  npm/pnpm/yarn audit: network, no credential, no project code
# With --allow-scripts, dependency lifecycle scripts run in the install stage
# and CAN read the token: use a read-only, short-lived token or none.
# Package-manager config is project code too: .npmrc decides which host gets
# the token, .pnpmfile.cjs and yarnPath/plugins run at install even without
# lifecycle scripts. With a token set, the battery refuses to start while such
# config exists, until you have read it and pass --trust-pm-config.
#
# Usage:
#   static-battery.sh --project <dir> --out <dir> [options]
#
# Options:
#   --package <subdir>   package to audit inside a monorepo (default: .);
#                        --project must be the directory that holds the lockfile
#   --build "<cmd>"      build command, run inside the container (e.g. "npm run build")
#   --dist <dir>         build output, relative to the package (default: dist, build, out)
#   --tsconfig <file>    tsconfig to check (default: tsconfig.app.json when
#                        tsconfig.json is solution-style, else tsconfig.json)
#   --html-dir <dir>     extra directory of HTML to validate, repeatable
#                        (e.g. the dom/ folder written by the interaction probe)
#   --only a,b / --skip a,b   tool ids: tsc eslint-project eslint-audit stylelint
#                        knip bundle npm-audit vnu osv
#   --no-install         reuse the host's node_modules instead of installing
#   --allow-scripts      let dependency lifecycle scripts run (needed by
#                        frameworks that generate types at install: Nuxt, SvelteKit)
#   --online             give the run stage network (a build that downloads
#                        fonts or data); project code can then send the checkout out
#   --trust-pm-config    with NPM_TOKEN / NODE_AUTH_TOKEN set: you read the
#                        registry, auth and code-loading lines the refusal printed
#
# Output: <out>/summary.json (one entry per tool: state, counts, top items)
# plus one raw file per tool. Exit code: 0 when the battery ran, whatever it
# found; 2 on a usage or Docker error. Findings never change the exit code:
# read summary.json.
#
# --out must be outside --project: outputs inside the checkout would modify it
# and be scanned by the next run.
#
# Environment: NODE_IMAGE, VNU_IMAGE, OSV_IMAGE override the pinned images.
# NPM_TOKEN / NODE_AUTH_TOKEN are forwarded by name, to the install stage only.
set -euo pipefail

NODE_IMAGE="${NODE_IMAGE:-node:22.23.5-bookworm-slim}"
# Nu Html Checker (W3C). Its registry has no version tags: pinned by digest.
VNU_IMAGE="${VNU_IMAGE:-ghcr.io/validator/validator@sha256:f10441aee7dcea043d2153b0a8bbce13dafeafc8a3680b69b88b83ba5b9880f5}"
OSV_IMAGE="${OSV_IMAGE:-ghcr.io/google/osv-scanner:v2.7.1}"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

project=""; out=""; package="."; build=""; dist=""; tsconfig=""; only=""; skip=""
no_install=0; allow_scripts=0; online=0; trust_pm=0
html_dirs=()
while [ $# -gt 0 ]; do
  case "$1" in
    --project) project="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --package) package="$2"; shift 2 ;;
    --build) build="$2"; shift 2 ;;
    --dist) dist="$2"; shift 2 ;;
    --tsconfig) tsconfig="$2"; shift 2 ;;
    --html-dir) html_dirs+=("$2"); shift 2 ;;
    --only) only="$2"; shift 2 ;;
    --skip) skip="$2"; shift 2 ;;
    --no-install) no_install=1; shift ;;
    --allow-scripts) allow_scripts=1; shift ;;
    --online) online=1; shift ;;
    --trust-pm-config) trust_pm=1; shift ;;
    -h|--help) sed -n '2,57p' "$0"; exit 0 ;;
    *) echo "error: unknown option $1" >&2; exit 2 ;;
  esac
done
if [ -z "$project" ] || [ -z "$out" ]; then
  echo "error: --project and --out are required" >&2
  exit 2
fi
[ -d "$project" ] || { echo "error: project directory not found: $project" >&2; exit 2; }
command -v docker >/dev/null || { echo "error: docker is required" >&2; exit 2; }

mkdir -p "$out"
project_abs="$(cd "$project" && pwd)"
out_abs="$(cd "$out" && pwd)"
case "$out_abs/" in
  "$project_abs"/*) rmdir "$out_abs" 2>/dev/null; echo "error: --out must be outside --project (use e.g. ../audit-$(basename "$project_abs")/static)" >&2; exit 2 ;;
esac

want() {
  if [ -n "$only" ] && [[ ",$only," != *",$1,"* ]]; then return 1; fi
  if [[ ",$skip," == *",$1,"* ]]; then return 1; fi
  return 0
}
status() {
  printf '{"tool":"%s","state":"%s","exit":%s,"note":"%s"}\n' "$1" "$2" "$3" "$4" >> "$out_abs/status.ndjson"
  printf '  %-15s %-8s exit=%-3s %s\n' "$1" "$2" "$3" "$4" >&2
}

env_args=()
for name in NPM_TOKEN NODE_AUTH_TOKEN; do
  if [ -n "${!name:-}" ]; then env_args+=(-e "$name"); fi
done

node_wanted=0
for t in tsc eslint-project eslint-audit stylelint knip bundle npm-audit; do
  if want "$t"; then node_wanted=1; fi
done

# A token goes to whatever host the project's .npmrc / .yarnrc.yml binds it
# to, and pnpmfile / yarnPath / plugins run next to it. Refuse until read.
if [ "${#env_args[@]}" -gt 0 ] && [ "$trust_pm" = 0 ] && [ "$no_install" = 0 ] && [ "$node_wanted" = 1 ]; then
  pm_hits=""
  pm_dirs=("$project_abs"); [ "$package" != . ] && pm_dirs+=("$project_abs/$package")
  for dir in "${pm_dirs[@]}"; do
    for f in .npmrc .yarnrc .yarnrc.yml pnpm-workspace.yaml .pnpmfile.cjs .pnpmfile.mjs; do
      [ -f "$dir/$f" ] || continue
      case "$f" in
        .pnpmfile.*) pm_hits+="  $dir/$f (runs at every pnpm install)"$'\n' ;;
        # Setting name and URL host only: a value can be a literal secret.
        *) pm_hits+="$(grep -inE 'registry|auth|token|password|yarnpath|yarn-path|plugins|pnpmfile|proxy|script-shell|node-options' "$dir/$f" \
             | awk -v f="$dir/$f" '{ n = $0; sub(/:.*/, "", n); l = substr($0, length(n) + 2)
                 if (match(l, /=/) || match(l, /:/)) { k = substr(l, 1, RSTART - 1); v = substr(l, RSTART + 1) } else { k = l; v = "" }
                 if (k ~ /^\/\//) { h = k; sub(/^\/\//, "", h); sub(/[\/:].*/, "", h); sub(/.*:/, "", k); k = k " (for host " h ")" }
                 h = ""; if (match(v, /https?:\/\/[^\/:" ]+/)) h = " = host " substr(v, RSTART, RLENGTH); else if (v ~ /[^ "]/) h = " = [value hidden]"
                 gsub(/^[ \t-]+|[ \t]+$/, "", k); printf "  %s:%s: %s%s\n", f, n, k, h }')"$'\n' ;;
      esac
    done
  done
  if [ -n "${pm_hits//[$'\n ']/}" ]; then
    printf 'refused: a registry token is set and the project configures its package manager:\n%s' "$pm_hits" >&2
    echo "Every host the token is bound to must be a registry the owner named; every pnpmfile," >&2
    echo "yarnPath or plugin must have been read. Then rerun with --trust-pm-config. Otherwise" >&2
    echo "unset the token: private packages fail to install, list them under \"Not verified\"." >&2
    exit 2
  fi
fi

echo "[1/4] node tools in $NODE_IMAGE" >&2
if [ "$node_wanted" = 0 ]; then
  : > "$out_abs/status.ndjson"
  echo "  no node tool selected: install and node stages skipped" >&2
else
  work_vol="audit-frontend-work-$$-$RANDOM"
  docker volume create "$work_vol" >/dev/null
  cp_vol="$work_vol-corepack"
  trap 'docker volume rm -f "$work_vol" "$cp_vol" >/dev/null 2>&1' EXIT
  common=(--rm --init -v "$out_abs:/out" -v "$SKILL_DIR/scripts:/skill:ro"
    -e AUDIT_PACKAGE="$package" -e AUDIT_BUILD="$build" -e AUDIT_DIST="$dist"
    -e AUDIT_TSCONFIG="$tsconfig" -e AUDIT_ONLY="$only" -e AUDIT_SKIP="$skip"
    -e AUDIT_NO_INSTALL="$no_install" -e AUDIT_ALLOW_SCRIPTS="$allow_scripts"
    -e CI=1 -e NO_UPDATE_NOTIFIER=1 -e COREPACK_ENABLE_DOWNLOAD_PROMPT=0)
  # Package managers fetched by corepack at install are reused offline.
  pmcache=(-v "$cp_vol:/corepack" -e COREPACK_HOME=/corepack)
  run_net=(--network none -e AUDIT_OFFLINE=1 -e COREPACK_ENABLE_NETWORK=0)
  [ "$online" = 1 ] && run_net=()
  fail() { echo "error: the node container failed to start ($1 stage)" >&2; exit 2; }
  docker run "${common[@]}" -e AUDIT_STAGE=tools -v "audit-frontend-tools:/tools" \
    "$NODE_IMAGE" bash /skill/lib/battery-inner.sh || fail tools
  docker run "${common[@]}" "${pmcache[@]}" -e AUDIT_STAGE=install -v "$project_abs:/src:ro" -v "$work_vol:/work" \
    -v "audit-frontend-npm-cache:/root/.npm" "${env_args[@]+"${env_args[@]}"}" \
    "$NODE_IMAGE" bash /skill/lib/battery-inner.sh || fail install
  docker run "${common[@]}" "${pmcache[@]}" "${run_net[@]+"${run_net[@]}"}" -e AUDIT_STAGE=run \
    -v "$work_vol:/work" -v "audit-frontend-tools:/tools:ro" \
    "$NODE_IMAGE" bash /skill/lib/battery-inner.sh || fail run
  if want npm-audit; then
    docker run "${common[@]}" -e AUDIT_STAGE=advisories -v "$project_abs:/src:ro" \
      "$NODE_IMAGE" bash /skill/lib/battery-inner.sh || fail advisories
  fi
fi

echo "[2/4] HTML and CSS validity (Nu Html Checker)" >&2
if want vnu; then
  vnu_mounts=()
  if [ -d "$out_abs/vnu-input/dist" ]; then vnu_mounts+=(-v "$out_abs/vnu-input/dist:/in/dist:ro"); fi
  i=0
  for d in "${html_dirs[@]+"${html_dirs[@]}"}"; do
    if [ -d "$d" ]; then vnu_mounts+=(-v "$(cd "$d" && pwd):/in/extra-$i:ro"); i=$((i + 1)); fi
  done
  if [ "${#vnu_mounts[@]}" -eq 0 ]; then
    status vnu skipped 0 "no HTML to validate: build the project (--build) or pass --html-dir <probe-out>/dom"
  else
    set +e
    docker run --rm "${vnu_mounts[@]}" "$VNU_IMAGE" \
      java -jar /vnu.jar --format json --stdout --exit-zero-always --also-check-css /in \
      > "$out_abs/vnu.json" 2> "$out_abs/vnu.log"
    code=$?
    set -e
    status vnu ran "$code" "vnu.jar --also-check-css on the build output and --html-dir folders"
  fi
fi

echo "[3/4] dependency vulnerabilities (OSV)" >&2
if want osv; then
  lock=""
  for f in package-lock.json pnpm-lock.yaml yarn.lock; do
    if [ -f "$project_abs/$f" ]; then lock="$f"; break; fi
  done
  if [ -z "$lock" ]; then
    status osv skipped 0 "no lockfile at the project root"
  else
    set +e
    docker run --rm -v "$project_abs/$lock:/src/$lock:ro" "$OSV_IMAGE" \
      scan source --format json --lockfile "/src/$lock" \
      > "$out_abs/osv.json" 2> "$out_abs/osv.log"
    code=$?
    set -e
    # osv-scanner exits 1 when it finds vulnerabilities, above 1 on failure.
    if [ "$code" -le 1 ]; then status osv ran "$code" "osv-scanner on $lock (dev dependencies included)"
    else status osv error "$code" "osv-scanner failed, see osv.log (it needs network access to api.osv.dev)"; fi
  fi
fi

echo "[4/4] summary" >&2
docker run --rm -v "$out_abs:/out" -v "$SKILL_DIR/scripts:/skill:ro" "$NODE_IMAGE" \
  node /skill/lib/summarize.mjs /out
