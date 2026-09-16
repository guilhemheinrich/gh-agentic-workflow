# Routing table — TypeScript / frontend monorepo (eslint or biome).
# Paste between the BEGIN/END ROUTING TABLE markers in validate-on-edit.sh.
#
# Container prerequisite: each workspace has a running compose service with the
# repo bind-mounted, and its linter resolvable from that service's node_modules.
#
# Deliberately absent: `tsc --noEmit`. There is no per-file mode — it loads the
# whole program graph (15-40s on a monorepo). Type errors stay a CI/verify
# concern; this hook only covers what is genuinely file-local.
#
# `--no-install` on npx matters: without it, npx silently downloads a random
# eslint version on a cache miss and the hook blows its budget.
#
# `--max-warnings=0` is not a strictness preference, it is the false-pass guard.
# ESLint reports a file it will not lint as a WARNING and exits 0: "File ignored
# because outside of base path" (a wrong or missing `strip`) or "File ignored
# because of a matching ignore pattern". Measured 2026-09-17 with ESLint 9.39.4:
# exit 0 without the flag, exit 1 with it. Never drop it. Probe a routed path
# with `eslint --print-config <path>` — `undefined` means no config applies and
# nothing is checked. See references/proving-the-hook-bites.md §5.

route() {
  case "$REL" in
    # 1. Not validated
    *.d.ts|*.snap|*.min.js|*/__generated__/*|*.generated.ts) skip ;;

    # 2. Workspace branches — MUST precede the generic *.ts branch, otherwise a
    #    file under apps/web/ gets linted with the wrong workspace config.
    apps/web/*.ts|apps/web/*.tsx|apps/web/*.vue|apps/web/*.js)
      svc web; strip apps/web/
      check npx --no-install eslint --fix --max-warnings=0 "$F"
      ;;
    packages/ui/*.ts|packages/ui/*.tsx)
      svc web; strip packages/ui/
      check npx --no-install eslint --fix --max-warnings=0 "$F"
      ;;

    # Biome variant — one binary for format + lint, ~10x faster than eslint.
    # apps/web/*.ts|apps/web/*.tsx)
    #   svc web; strip apps/web/
    #   check npx --no-install biome check --write --error-on-warnings "$F"
    #   ;;

    # 3. Generic extension branches (single-package repos)
    # *.ts|*.tsx|*.js|*.jsx)
    #   svc app
    #   check npx --no-install eslint --fix --max-warnings=0 "$F"
    #   ;;

    *.json)
      svc web
      check node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$F"
      ;;

    # 4. Anything else warns once, then stays quiet.
    *) ;;
  esac
}
