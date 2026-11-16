# Case: declared-name-with-uppercase-and-dots
#
# Spec: US2 acceptance 7 and FR-012 — "Given a declared name carrying uppercase
# letters or dots, When the runner resolves it, Then it matches the label
# Compose actually writes." FR-012 applies that to EVERY source, not only to the
# declared one.
#
# The label is not the declared string. Measured 2026-09-17, Compose v5.1.2:
# `name: VOE.Test.Upper` is reported as `voetestupper` — lowercased, and dots
# DROPPED rather than replaced by a separator. A runner passing the declared
# string through verbatim would filter on a label no container carries, which is
# the same silent miss as reading the wrong source.
#
# ── Two halves, because one of them cannot exercise the normaliser ───────────
#
# Half one is the spec's own sentence: a declared name, and the container
# carrying the label Compose writes for it.
#
# It does NOT exercise the runner's normaliser, and the suite said it did. When
# the name comes from a Compose file, COMPOSE ITSELF returns it already
# normalised — `docker compose config` answers `voetestupper` for a file
# declaring `VOE.Test.Upper` — so deleting the runner's normalisation of
# Compose's answer left this half green. What it does prove, and what nothing
# else does, is that the runner and Compose agree on the final label end to end:
# the expected value is computed by the runner's own two `tr` steps, never by
# asking Compose, so if Compose ever changed that rule this half fails.
#
# Half two carries the normalisation. It uses the source where Compose is not
# consulted at all — the directory basename, applied when there is no Compose
# file to ask — and a directory named with uppercase letters and dots. The
# runner's `tr` pair is then the only thing between the directory name and the
# label, so deleting it makes this half filter on `Voe.Upper.Case…`, find no
# container, and warn.
#
# That the basename rule must produce the same answer Compose would is measured,
# not assumed: 2026-09-17, a directory named `Voe.Upper.Case` holding a Compose
# file with no `name:` is reported by `docker compose config` as `voeuppercase`.

CASE_DESC="uppercase and dots, in a declared name and in a directory basename"
CASE_EXPECT="silence"

case_body() {
  local declared expected name="$PROJECT_NAME-svc"
  declared="$(printf '%s' "$PROJECT_NAME" | tr '[:lower:]' '[:upper:]').Upper.Case"
  expected="$(printf '%s' "$declared" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
  VOE_NO_CPN=1
  printf 'clean\n' >"$PROJECT_DIR/app.txt"

  printf '    declared %s -> expected label %s\n' "$declared" "$expected" >&2

  cat >"$PROJECT_DIR/compose.yml" <<YML
name: $declared
services:
  app:
    image: $VOE_IMAGE
    command: sleep 900
YML

  write_routing_table <<'RT'
route() {
  case "$REL" in
    *.txt) svc voe; check sh -c 'test -f "$1"' _ "/work/$F" ;;
  esac
}
RT

  voe_container_start "$name" "$expected" voe "$PROJECT_DIR" /work >/dev/null || return 1

  # Half one: the declared name, resolved through Compose.
  run_hook "$PROJECT_DIR/app.txt"
  if [ "$RUN_OUTCOME" != "silence" ]; then
    printf '    the declared name did not resolve: %s\n' "$RUN_OUTCOME" >&2
    printf '%s' "$RUN_OUTCOME" >"$CASE_DIR/observed"
    return 1
  fi

  # ── Half two: the basename source, where the runner normalises or nothing does
  local dir_declared dir_expected root2 name2="$PROJECT_NAME-svc2"
  dir_declared="$(printf '%s' "$PROJECT_NAME" | tr '[:lower:]' '[:upper:]').Base.Name"
  dir_expected="$(printf '%s' "$dir_declared" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
  root2="$CASE_DIR/$dir_declared"
  mkdir -p "$root2" || return 1
  # A Makefile and NO Compose file: find_project_root stops here, and the name
  # can only come from the basename.
  : >"$root2/Makefile"
  printf 'clean\n' >"$root2/app.txt"
  printf '    directory %s -> expected label %s\n' "$dir_declared" "$dir_expected" >&2

  voe_container_start "$name2" "$dir_expected" voe "$root2" /work >/dev/null || return 1

  PROJECT_DIR="$root2"
  run_hook "$root2/app.txt"
  expect_outcome "$CASE_EXPECT"
}
