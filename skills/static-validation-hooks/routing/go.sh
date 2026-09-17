# Routing table — Go (gofmt + golangci-lint), single-module backend.
# Paste between the BEGIN/END ROUTING TABLE markers in validate-on-edit.sh.
#
# Container prerequisite: the `api` service runs with the module bind-mounted at
# its WORKDIR, and `golangci-lint` is installed inside it.
#
# Four Go-specific traps this table encodes — measured 2026-09-17 on a Go
# monorepo (golangci-lint 2.12.2, go 1.26.3). Full evidence and the
# canary that proves the branch bites: references/proving-the-hook-bites.md.
#
#   1. golangci-lint has no single-file mode. A lone file typechecks as a
#      broken package and invents `typecheck` issues, so the branch lints the
#      file's package DIRECTORY.
#   2. `gofmt -l` prints the offending path and exits 0. As a `check` it can
#      never fail; it is only usable as `fix gofmt -w`.
#   3. A build-constrained file is invisible to an untagged run: the package
#      reports "0 issues." and exits 0 without ever compiling it. Measured on
#      a 120-file tagged directory — untagged 0 issues, `--build-tags
#      integration` 23 (errcheck 8, staticcheck 12, unused 3). The tagged run
#      costs 6.9s, over any per-edit budget, so this table SKIPS those files
#      and says so out loud.
#   4. A VENDORED module without `GOFLAGS=-mod=mod` fails before analysis:
#      "inconsistent vendoring in /app", listing every module, naming no line.
#      The agent reads a violation on the file it just wrote. Measured on a
#      vendored Go monorepo, 2026-09-16; the same command with the flag
#      returned 5 real findings. Set GOFLAGS in the compose service env, or
#      inline it as below when you cannot.
#
# Deliberately absent: `go vet ./...`, `go build ./...`, `go test`. All are
# project-wide or behavioural; they stay in `make lint` and CI.

route() {
  case "$REL" in
    # 1. Not validated
    #    Generated code, module files (`go mod tidy` is project-wide), and
    #    vendored trees.
    *.pb.go|*_gen.go|*.generated.go|*/mocks/*) skip ;;
    go.mod|go.sum|*/go.mod|*/go.sum|vendor/*) skip ;;

    # 2. Go sources — package-directory lint, gofmt as the formatter.
    #    The build-tag guard reads the header above the `package` clause; a
    #    tagged file is skipped rather than silently passed by an untagged run.
    *.go)
      if sed -n '/^package /q;p' "$PROJECT_ROOT/$REL" 2>/dev/null | grep -q '^//go:build'; then
        skip
      else
        svc api
        fix   gofmt -w "$F"
        check golangci-lint run "./$(dirname "$F")/"
        # Vendored module whose service env does not carry the flag — use this
        # line instead, and verify with `--check` that the output names lines:
        # check env GOFLAGS=-mod=mod golangci-lint run "./$(dirname "$F")/"
      fi
      ;;

    # 3. Anything else warns once, then stays quiet.
    *) ;;
  esac
}

# Coverage probe — run it once per routed directory before trusting this table:
#
#   go list -f '{{len .GoFiles}} {{len .IgnoredGoFiles}}' ./path/to/dir/
#
# `GoFiles` of 0 means every file there sits behind a build constraint and an
# untagged lint run checks nothing. Record that gap in a comment and in the
# repo's grievance ledger; do not leave it implicit.
