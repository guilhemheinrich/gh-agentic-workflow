# Routing table — NestJS backend (+ optional frontend workspace).
# Paste between the BEGIN/END ROUTING TABLE markers in validate-on-edit.sh.
#
# Container prerequisite: the `api` service is up (`make up`) with the repo
# bind-mounted at its WORKDIR and eslint resolvable from its node_modules.
#
# NestJS specifics worth knowing before you edit this table:
#
#  - Decorator metadata, DI wiring and module graph errors are NOT statically
#    detectable per file. `nest build` / `tsc --noEmit` catch them, and both are
#    whole-program (15-40s). They stay in CI. This hook is eslint only.
#  - Migrations and generated Prisma/TypeORM output are skipped: they are tool
#    output, and linting them produces noise the agent cannot act on.
#  - *.spec.ts IS linted. Test files are where agents drift most (unused
#    imports, floating promises), and eslint is just as fast on them.

route() {
  case "$REL" in
    # 1. Not validated — generated or tool-owned
    */migrations/*|*/generated/*|*.generated.ts|*.d.ts|*.snap) skip ;;

    # 2. Workspace branches — before any generic extension branch.
    apps/api/*.ts)
      svc api; strip apps/api/
      check npx --no-install eslint --fix --max-warnings=0 "$F"
      ;;
    apps/web/*.ts|apps/web/*.tsx|apps/web/*.vue)
      svc web; strip apps/web/
      check npx --no-install eslint --fix --max-warnings=0 "$F"
      ;;
    libs/*.ts|packages/*.ts)
      svc api
      check npx --no-install eslint --fix --max-warnings=0 "$F"
      ;;

    # 3. Single-package NestJS (no monorepo) — use this instead of §2:
    # src/*.ts|test/*.ts)
    #   svc api
    #   check npx --no-install eslint --fix --max-warnings=0 "$F"
    #   ;;

    # 4. Schema / config files the api container can parse cheaply
    *.json)
      svc api
      check node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$F"
      ;;
    *.prisma)
      svc api
      check npx --no-install prisma format --schema "$F"
      ;;

    # 5. Anything else warns once, then stays quiet.
    *) ;;
  esac
}
