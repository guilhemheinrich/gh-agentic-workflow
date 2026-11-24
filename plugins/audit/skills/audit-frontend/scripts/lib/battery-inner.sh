#!/usr/bin/env bash
# battery-inner.sh - runs INSIDE the Node container started by static-battery.sh.
# Never run it on the host.
#
# Runs once per AUDIT_STAGE, each in its own container (see static-battery.sh):
#   tools    /tools writable: install the pinned audit tools. No project code.
#   install  /src (project, read-only) copied to /work, dependencies installed.
#            The only stage that sees registry credentials.
#   run      /work + /tools read-only: every check. Project-controlled code
#            (build, lint configs) runs here, without credentials and, unless
#            --online, without network.
#   advisories  networked, no credential: the package manager's audit only,
#            on a fresh copy of the read-only checkout (nothing written by
#            the run stage reaches it).
# The host checkout is never modified.
set -uo pipefail
STAGE="${AUDIT_STAGE:-}"

OUT=/out
WORK=/work
PKG_REL="${AUDIT_PACKAGE:-.}"
PKG="$WORK/$PKG_REL"
ONLY="${AUDIT_ONLY:-}"
SKIP="${AUDIT_SKIP:-}"

# Pinned audit tools. Change a version here and the tool volume is rebuilt.
TOOLS=(
  eslint@9.39.5 typescript@5.9.3 typescript-eslint@8.74.0
  eslint-plugin-react-hooks@7.1.1 eslint-plugin-react@7.37.5 eslint-plugin-jsx-a11y@6.10.2
  eslint-plugin-vue@10.12.1 vue-eslint-parser@10.4.2
  eslint-plugin-svelte@3.24.1 svelte@5.59.1
  eslint-plugin-solid@0.20.1 eslint-plugin-lit@2.3.1
  stylelint@16.26.1 knip@6.48.0
)

tools_key="$(printf '%s ' "${TOOLS[@]}" | sha256sum | cut -c1-16)"

# status <tool> <state> <exit> <note>   state: ran | skipped | error
status() {
  printf '{"tool":"%s","state":"%s","exit":%s,"note":"%s"}\n' "$1" "$2" "$3" "${4//\"/\'}" >> "$OUT/status.ndjson"
  printf '  %-15s %-8s exit=%-3s %s\n' "$1" "$2" "$3" "$4" >&2
}

want() {
  local tool="$1"
  if [ -n "$ONLY" ] && [[ ",$ONLY," != *",$tool,"* ]]; then return 1; fi
  if [[ ",$SKIP," == *",$tool,"* ]]; then return 1; fi
  return 0
}

has_bin() { [ -x "$PKG/node_modules/.bin/$1" ] || [ -x "$WORK/node_modules/.bin/$1" ]; }
bin() { if [ -x "$PKG/node_modules/.bin/$1" ]; then echo "$PKG/node_modules/.bin/$1"; else echo "$WORK/node_modules/.bin/$1"; fi; }

# --- 0. pinned audit tools (stage: tools) --------------------------------------
if [ "$STAGE" = tools ]; then
  if [ ! -f "/tools/.ready-$tools_key" ]; then
    rm -rf /tools/node_modules /tools/package.json /tools/.ready-* 2>/dev/null
    if (cd /tools && npm install --no-audit --no-fund --no-package-lock --prefix /tools "${TOOLS[@]}" > "$OUT/tools-install.log" 2>&1); then
      touch "/tools/.ready-$tools_key"
    fi
  fi
  cp /skill/eslint-audit.config.mjs /tools/eslint-audit.config.mjs 2>/dev/null
  exit 0
fi

if [ "$STAGE" = install ]; then
: > "$OUT/status.ndjson"
# --- 1. copy the project ------------------------------------------------------
mkdir -p "$WORK"
if [ "${AUDIT_NO_INSTALL:-0}" = 1 ]; then
  tar -C /src --exclude=./.git -cf - . | tar -C "$WORK" -xf -
else
  tar -C /src --exclude=./.git --exclude=node_modules -cf - . | tar -C "$WORK" -xf -
fi
if [ ! -f "$PKG/package.json" ]; then
  status copy error 1 "no package.json in $PKG_REL"
  exit 0
fi
cd "$WORK" || exit 0

# --- 2. install the project's dependencies (inside the container only) --------
if [ "${AUDIT_NO_INSTALL:-0}" = 1 ]; then
  status install skipped 0 "--no-install: using the node_modules copied from the host"
else
  # Yarn Berry has no --ignore-scripts: --mode=skip-build is what stops the
  # root and dependency lifecycle scripts (YARN_ENABLE_SCRIPTS=0 does not stop
  # the root package's own postinstall).
  scripts_flag="--ignore-scripts"; berry_flag="--mode=skip-build"
  [ "${AUDIT_ALLOW_SCRIPTS:-0}" = 1 ] && scripts_flag="" && berry_flag=""
  if [ -f pnpm-lock.yaml ]; then
    corepack enable >/dev/null 2>&1
    pm="pnpm"; cmd="pnpm install --frozen-lockfile $scripts_flag"
  elif [ -f yarn.lock ]; then
    corepack enable >/dev/null 2>&1
    pm="yarn"; cmd="yarn install --immutable $berry_flag"
    grep -q '^# yarn lockfile v1' yarn.lock && cmd="yarn install --frozen-lockfile $scripts_flag"
  elif [ -f package-lock.json ]; then
    pm="npm"; cmd="npm ci --no-audit --no-fund $scripts_flag"
  else
    pm="npm"; cmd="npm install --no-audit --no-fund $scripts_flag"
  fi
  if $cmd > "$OUT/install.log" 2>&1; then
    status install ran 0 "$cmd"
  else
    status install error $? "$cmd failed, see install.log; project-local tools (tsc, eslint, stylelint) will be skipped"
  fi
fi

echo "${pm:-host}" > "$WORK/.audit-frontend-pm"
chmod -R a+rwX "$OUT" 2>/dev/null
exit 0
fi

# --- dependency vulnerabilities (package manager's own advisory source) -------
# Runs in the advisories stage. It loads no project code: pnpmfile ignored;
# Yarn Berry is skipped when .yarnrc.yml loads code (yarnPath, plugins).
run_advisories() {
if want npm-audit; then
  if [ -f pnpm-lock.yaml ]; then
    npm_config_ignore_pnpmfile=true pnpm audit --prod --json > "$OUT/npm-audit.json" 2> "$OUT/npm-audit.log"
    status npm-audit ran $? "pnpm audit --prod (pnpmfile ignored)"
  elif [ -f yarn.lock ] && ! grep -q '^# yarn lockfile v1' yarn.lock && grep -qE '^(yarnPath|plugins):' .yarnrc.yml 2>/dev/null; then
    status npm-audit skipped 0 ".yarnrc.yml sets yarnPath or plugins (project code): yarn npm audit not run; osv covers the lockfile"
  elif [ -f yarn.lock ] && ! grep -q '^# yarn lockfile v1' yarn.lock; then
    yarn npm audit --environment production --json > "$OUT/npm-audit.json" 2> "$OUT/npm-audit.log"
    status npm-audit ran $? "yarn npm audit --environment production"
  elif [ -f package-lock.json ]; then
    npm audit --omit=dev --json > "$OUT/npm-audit.json" 2> "$OUT/npm-audit.log"
    status npm-audit ran $? "npm audit --omit=dev"
  else
    status npm-audit skipped 0 "no supported lockfile: versions are not pinned, which is itself a finding"
  fi
fi
}

# --- 3. stages: run, advisories --------------------------------------------------
if [ "$STAGE" = advisories ]; then
  mkdir -p "$WORK"
  tar -C /src --exclude=./.git --exclude=node_modules -cf - . | tar -C "$WORK" -xf -
  if [ ! -f "$PKG/package.json" ]; then status npm-audit error 1 "no package.json in $PKG_REL"; exit 0; fi
fi
[ -f "$PKG/package.json" ] || exit 0
pm="$(cat "$WORK/.audit-frontend-pm" 2>/dev/null)"
if [ "$STAGE" = advisories ]; then
  cd "$WORK" || exit 0
  if [ -f pnpm-lock.yaml ] || [ -f yarn.lock ]; then corepack enable >/dev/null 2>&1; fi
  run_advisories
  chmod -R a+rwX "$OUT" 2>/dev/null
  exit 0
fi
[ -f "/tools/.ready-$tools_key" ] || status tools error 1 "pinned tool install failed, see tools-install.log"
cd "$WORK" || exit 0
if [ -f pnpm-lock.yaml ] || [ -f yarn.lock ]; then corepack enable >/dev/null 2>&1; fi

# --- 4. detect frameworks from package.json -----------------------------------
AUDIT_FRAMEWORKS="$(node -e '
  const fs = require("fs");
  const deps = {};
  for (const f of process.argv.slice(1)) {
    try { const p = JSON.parse(fs.readFileSync(f, "utf8")); Object.assign(deps, p.dependencies, p.devDependencies, p.peerDependencies); } catch {}
  }
  const has = (...n) => n.some((x) => x in deps);
  const out = [];
  if (has("react", "preact", "next")) out.push("react");
  if (has("vue", "nuxt")) out.push("vue");
  if (has("svelte", "@sveltejs/kit")) out.push("svelte");
  if (has("solid-js")) out.push("solid");
  if (has("lit", "lit-element", "lit-html")) out.push("lit");
  if (has("@angular/core")) out.push("angular");
  console.log(out.join(","));
' "$PKG/package.json" "$WORK/package.json")"
export AUDIT_FRAMEWORKS
printf '{"frameworks":"%s","packageManager":"%s","node":"%s"}\n' "$AUDIT_FRAMEWORKS" "${pm:-host}" "$(node --version)" > "$OUT/context.json"
echo "  frameworks: ${AUDIT_FRAMEWORKS:-none detected}" >&2

cd "$PKG" || exit 0

# --- 5. type checking ----------------------------------------------------------
if want tsc; then
  tsconfig="${AUDIT_TSCONFIG:-}"
  if [ -z "$tsconfig" ]; then
    # Solution-style tsconfig (Vite templates): tsconfig.json only holds
    # "references" and checks nothing by itself.
    if [ -f tsconfig.app.json ] && grep -q '"references"' tsconfig.json 2>/dev/null; then tsconfig=tsconfig.app.json
    elif [ -f tsconfig.json ]; then tsconfig=tsconfig.json; fi
  fi
  checker=""
  if has_bin vue-tsc; then checker="$(bin vue-tsc)"; elif has_bin tsc; then checker="$(bin tsc)"; fi
  if [ -z "$tsconfig" ]; then
    status tsc skipped 0 "no tsconfig.json: the project is not type-checked at all"
  elif [ -z "$checker" ]; then
    status tsc skipped 0 "typescript is not installed in the project"
  else
    # How many of the project's own files this tsconfig really checks: a
    # solution-style or empty config exits 0 with 0 errors on 0 files.
    nfiles="unknown"
    if listed="$("$checker" -p "$tsconfig" --listFilesOnly 2>/dev/null)"; then
      nfiles="$(printf '%s\n' "$listed" | grep -v '/node_modules/' | grep -c .)"
    fi
  fi
  if [ -n "$tsconfig" ] && [ -n "$checker" ] && [ "$nfiles" = 0 ]; then
    status tsc skipped 0 "$tsconfig checks 0 project files (solution-style or empty include): pass --tsconfig <the tsconfig that includes the sources>"
  elif [ -n "$tsconfig" ] && [ -n "$checker" ]; then
    "$checker" --noEmit -p "$tsconfig" --pretty false > "$OUT/tsc.txt" 2>&1
    status tsc ran $? "$(basename "$checker") --noEmit -p $tsconfig ($nfiles project files checked)"
    # Strictness gap: how many more errors appear under the strictest settings.
    "$checker" --noEmit -p "$tsconfig" --pretty false --strict --noUncheckedIndexedAccess --noImplicitOverride > "$OUT/tsc-strict.txt" 2>&1
    status tsc-strict ran $? "same, forcing --strict --noUncheckedIndexedAccess --noImplicitOverride"
  fi
  if has_bin svelte-check; then
    "$(bin svelte-check)" --output machine > "$OUT/svelte-check.txt" 2>&1
    status svelte-check ran $? "svelte-check --output machine"
  fi
fi

# --- 6. ESLint with the project's own configuration ---------------------------
if want eslint-project; then
  cfg="$(ls eslint.config.* .eslintrc* 2>/dev/null | head -1)"
  [ -z "$cfg" ] && cfg="$(cd "$WORK" && ls eslint.config.* .eslintrc* 2>/dev/null | head -1)"
  if [ -z "$cfg" ]; then
    status eslint-project skipped 0 "no ESLint configuration in the project: a finding unless another linter (Biome, oxlint, ng lint) gates CI"
  elif ! has_bin eslint; then
    status eslint-project skipped 0 "eslint is not installed in the project"
  else
    "$(bin eslint)" . -f json -o "$OUT/eslint-project.json" > "$OUT/eslint-project.log" 2>&1
    status eslint-project ran $? "project config $cfg"
  fi
fi

# --- 7. ESLint audit overlay (pinned plugins, state/render/a11y rules only) ---
if want eslint-audit; then
  if [ -z "${AUDIT_FRAMEWORKS//angular/}" ] || [ "${AUDIT_FRAMEWORKS}" = "angular" ]; then
    status eslint-audit skipped 0 "no framework covered by the overlay (react, vue, svelte, solid, lit)"
  elif [ ! -x /tools/node_modules/.bin/eslint ]; then
    status eslint-audit error 1 "pinned tools are missing"
  else
    /tools/node_modules/.bin/eslint --no-config-lookup -c /tools/eslint-audit.config.mjs \
      --no-error-on-unmatched-pattern -f json -o "$OUT/eslint-audit.json" . > "$OUT/eslint-audit.log" 2>&1
    status eslint-audit ran $? "overlay for: $AUDIT_FRAMEWORKS (inline eslint-disable comments ignored)"
  fi
fi

# --- 8. CSS: stylelint ----------------------------------------------------------
if want stylelint; then
  scfg="$(ls .stylelintrc* stylelint.config.* 2>/dev/null | head -1)"
  if [ -n "$scfg" ] && has_bin stylelint; then
    "$(bin stylelint)" "**/*.{css,scss,sass,less,vue,svelte}" --allow-empty-input -f json -o "$OUT/stylelint.json" > "$OUT/stylelint.log" 2>&1
    status stylelint ran $? "project config $scfg"
  elif [ -x /tools/node_modules/.bin/stylelint ]; then
    # Fallback: validity-only rules on plain .css files. Sass, Less and
    # single-file components need the project's own syntax plugins.
    /tools/node_modules/.bin/stylelint "**/*.css" --config /skill/lib/stylelint-validity.json \
      --config-basedir /tools --ignore-pattern "**/node_modules/**" --ignore-pattern "**/dist/**" --ignore-pattern "**/build/**" \
      --ignore-pattern "**/coverage/**" --ignore-pattern "**/*.min.css" \
      --allow-empty-input -f json -o "$OUT/stylelint.json" > "$OUT/stylelint.log" 2>&1
    status stylelint ran $? "no project config: validity-only fallback on plain .css (scss/less/vue/svelte styles NOT checked)"
  else
    status stylelint error 1 "pinned tools are missing"
  fi
fi

# --- 9. unused files, exports and dependencies: knip ---------------------------
if want knip; then
  if [ -x /tools/node_modules/.bin/knip ]; then
    /tools/node_modules/.bin/knip --reporter json --no-progress > "$OUT/knip.json" 2> "$OUT/knip.log"
    status knip ran $? "knip --reporter json"
  else
    status knip error 1 "pinned tools are missing"
  fi
fi

# --- 10. build (optional) and bundle sizes --------------------------------------
if want bundle; then
  if [ -n "${AUDIT_BUILD:-}" ]; then
    if bash -c "$AUDIT_BUILD" > "$OUT/build.log" 2>&1; then
      status build ran 0 "$AUDIT_BUILD"
    else
      status build error $? "$AUDIT_BUILD failed, see build.log${AUDIT_OFFLINE:+ (run stage is offline: a build that downloads fonts or data needs --online)}"
    fi
  fi
  dist="${AUDIT_DIST:-}"
  if [ -z "$dist" ]; then
    for d in dist build out .output/public; do [ -d "$d" ] && dist="$d" && break; done
  fi
  if [ -n "$dist" ] && [ -d "$dist" ]; then
    node /skill/lib/bundle-sizes.mjs "$dist" > "$OUT/bundle.json" 2> "$OUT/bundle.log"
    status bundle ran $? "sizes of $dist"
    # Hand the built HTML and CSS to the validator step that runs on the host side.
    mkdir -p "$OUT/vnu-input/dist"
    (cd "$dist" && find . -type f \( -name '*.html' -o -name '*.css' \) -print0 | tar --null -T - -cf -) \
      | tar -C "$OUT/vnu-input/dist" -xf - 2>/dev/null
  else
    status bundle skipped 0 "no build output found (pass --build '<cmd>' and/or --dist <dir>)"
  fi
fi


chmod -R a+rwX "$OUT" 2>/dev/null
exit 0
