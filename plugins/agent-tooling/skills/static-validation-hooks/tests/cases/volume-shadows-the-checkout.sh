# Case: volume-shadows-the-checkout
#
# Plan D6, and research.md §3d — the measurement that refuted the first draft of
# the identity test. A checkout is bound at /app and a NAMED VOLUME is mounted
# over /app/src. Inside the container the deepest destination wins, so the
# validator reads the volume's stale copy of the edited file:
#
#   bind   | <checkout>          | /app
#   volume | <docker volume dir> | /app/src        <- this is what /app/src/a.txt comes from
#
# A test asking only whether some mount SOURCE is a parent of the edited host
# file accepts this container: <checkout> is a parent of <checkout>/src/a.txt.
# Starting from the container path instead names the volume, and a destination
# served by a volume is refused outright — it is not this checkout, whatever its
# name suggests.
#
# Shape: the host file says FRESH, the volume's copy says STALE, and the
# validator fails on anything but FRESH. So:
#   before the identity test : VIOLATION — a finding about a file the agent did
#                              not write, which is the harm, not a nicety
#   after                    : warning naming the checkout mismatch
#
# The fixture verifies the shadowing before asserting anything about it: if the
# container could read the fresh copy, this case would prove nothing.

CASE_DESC="a named volume shadowing a subdirectory of the bound checkout"
CASE_EXPECT="warning"

case_body() {
  local name="$PROJECT_NAME-svc" vol="$PROJECT_NAME-stale"
  mkdir -p "$PROJECT_DIR/src" || return 1
  printf 'FRESH — the copy the agent just wrote\n' >"$PROJECT_DIR/src/a.txt"

  write_routing_table <<'RT'
route() {
  case "$REL" in
    *.txt)
      svc voe
      check sh -c 'grep -q FRESH "$1" || { printf "%s:1: stale copy\n" "$1"; exit 1; }' _ "/app/$F"
      ;;
  esac
}
RT

  voe_volume_create "$vol" || return 1
  # The volume's ROOT becomes /app/src, so the stale copy is `a.txt` at the top
  # of the volume, not `src/a.txt`.
  voe_volume_seed "$vol" a.txt 'STALE' || return 1
  voe_container_start_ex "$name" "$PROJECT_NAME" voe "$PROJECT_DIR" /app \
    -w /app -v "$vol:/app/src" >/dev/null || return 1

  # The shadowing must be real, or the case is asserting against a fixture that
  # does not carry the hazard.
  local seen
  seen="$(docker exec "$name" cat /app/src/a.txt 2>&1)"
  case "$seen" in
    *STALE*) ;;
    *)
      printf '    fixture failed: the container reads %s at /app/src/a.txt\n' "$seen" >&2
      printf '%s' "unexpected:volume-does-not-shadow" >"$CASE_DIR/observed"
      return 1
      ;;
  esac

  run_hook "$PROJECT_DIR/src/a.txt"
  expect_outcome "$CASE_EXPECT" || return 1
  expect_stderr want "does not read this checkout" 'the checkout mismatch named' || return 1
  expect_stderr reject 'has no running container' 'a stopped service blamed for a shadowed mount' || return 1
  expect_stderr reject 'stale copy' 'the stale copy reported as a finding' || return 1
  return 0
}
