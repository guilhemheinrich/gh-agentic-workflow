# Case: interpolated-name-changes-the-project
#
# Spec: FR-011 ("The runner MUST resolve the Compose project name the way
# Compose itself resolves it") and FR-013, whose "at resolution time only" is
# worth nothing if a cached container can outlive the resolution that produced
# it.
#
# Shape: a Compose file that names its project through a variable —
#
#     name: ${VOE_STACK}
#
# — and two containers, one per value of that variable, mounting DIFFERENT
# directories. Nothing about the file system changes between the two edits: only
# the variable does, which is the whole point.
#
#   1. VOE_STACK=<blue>, container BLUE serves this project -> silence
#   2. VOE_STACK=<green>, container GREEN joins it — and BLUE stays up, keeping
#      the id the first edit cached -> the finding GREEN reports must arrive
#
# Both containers bind this checkout, so neither can be refused on identity and
# the mount cannot decide the verdict. Only GREEN carries the file the validator
# looks for, so the outcome answers exactly one question: which container ran.
#
# Two distinct defects both produce silence at step 2, and this case fails
# unless both are repaired:
#
#   the fingerprint. The name cache was keyed on the Compose files' timestamps
#   and on a handful of COMPOSE_* variables. An interpolated name changes
#   project when its variable changes with no file touched, so `blue` was
#   re-used from the cache and `green` was never asked for.
#
#   the container cache. A cached id was read back on the service name alone,
#   so even once the project resolved to `green` the hot path would still have
#   executed in BLUE's container — one `docker exec` on an id that belongs to
#   another project, returning a verdict about another directory's copy of the
#   file. That is the failure this whole feature exists to prevent, reached
#   without any infrastructure failing at all.
#
# Silence is the defect's signature here, and silence is exactly what an agent
# cannot tell from a clean file.

CASE_DESC="a Compose name interpolated from a variable, changed between two edits"
CASE_EXPECT="violation"

case_body() {
  local blue="$PROJECT_NAME-blue" green="$PROJECT_NAME-green"
  local elsewhere="$CASE_DIR/elsewhere"
  VOE_NO_CPN=1

  mkdir -p "$elsewhere" || return 1
  printf 'clean\n' >"$PROJECT_DIR/app.txt"
  printf 'clean\n' >"$elsewhere/app.txt"

  cat >"$PROJECT_DIR/compose.yml" <<'YML'
name: ${VOE_STACK}
services:
  app:
    image: alpine:3.20
    command: sleep 900
YML

  write_routing_table <<'RT'
route() {
  case "$REL" in
    *.txt)
      svc voe
      check sh -c 'if test -f /voe-marker; then printf "%s:1: forbidden token\n" "$1"; exit 1; fi' _ "/work/$F"
      ;;
  esac
}
RT

  # Both containers bind THIS project at /work, so both pass the identity test
  # and the two verdicts cannot differ because of a mount. They differ because
  # only GREEN carries /voe-marker, which is what the validator looks for: the
  # question this case asks is WHICH CONTAINER RAN, and nothing else.
  #
  # BLUE stays up, with the id the first edit cached, for the whole case.
  printf 'the file the validator looks for\n' >"$elsewhere/marker" || return 1
  voe_container_start "$blue" "$blue" voe "$PROJECT_DIR" /work >/dev/null || return 1

  VOE_EXTRA_ENV="VOE_STACK=$blue"
  run_hook "$PROJECT_DIR/app.txt"
  if [ "$RUN_OUTCOME" != "silence" ]; then
    printf '    setup failed: the first edit was %s, expected silence\n' "$RUN_OUTCOME" >&2
    printf '%s' "$RUN_OUTCOME" >"$CASE_DIR/observed"
    return 1
  fi

  # The project moves — one variable, no file touched, BLUE untouched and still
  # running under its own project.
  voe_container_start_ex "$green" "$green" voe "$PROJECT_DIR" /work \
    -v "$elsewhere/marker:/voe-marker" >/dev/null || return 1

  VOE_EXTRA_ENV="VOE_STACK=$green"
  run_hook "$PROJECT_DIR/app.txt"
  expect_outcome "$CASE_EXPECT" || return 1
  expect_stderr want 'forbidden token' 'the finding itself' || return 1
  return 0
}
