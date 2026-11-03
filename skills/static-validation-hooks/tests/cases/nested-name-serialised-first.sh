# Case: nested-name-serialised-first
#
# Plan D5: "The runner's existing JSON extractor cannot be used here.
# `extract_json_string` returns the FIRST `"name"` in the document, and a Compose
# document can serialise a nested `name` — under `configs`, `networks`,
# `secrets` — before the project's own."
#
# That is not a hypothetical. Measured 2026-09-17, Compose v5.1.2 serialises its
# top-level keys in alphabetical order, so a project whose service USES a
# `configs:` entry produces:
#
#   { "configs": { "aaa_conf": { "name": "<the config's name>", … } },
#     "name": "<the project>", … }
#
# The first `"name"` in that document belongs to the config.
#
# Shape, two edits, so the case can only be satisfied by reading the TOP-LEVEL
# key and not by reading either name that happens to be present:
#   1. a container carrying the NESTED name, and nothing else  -> warning:
#      the runner must NOT have resolved the config's name
#   2. a container carrying the TOP-LEVEL name                 -> silence
#
# Step 1 is the discriminator. An implementation reusing extract_json_string
# passes step 2 and fails step 1, which is exactly the defect being guarded
# against: right on the documents it was written for, silently wrong on the next.

CASE_DESC="a Compose document carrying a nested name before the project's own"
CASE_EXPECT="silence"

case_body() {
  local top="$PROJECT_NAME-topmost" nested="$PROJECT_NAME-nested"
  local ctr_nested="$PROJECT_NAME-svc-nested" ctr_top="$PROJECT_NAME-svc-top"
  VOE_NO_CPN=1
  printf 'clean\n' >"$PROJECT_DIR/app.txt"

  # `aaa_conf` sorts before `name` among the top-level keys, and the config is
  # referenced by the service so Compose keeps it in the rendered document.
  cat >"$PROJECT_DIR/compose.yml" <<YML
name: $top
configs:
  aaa_conf:
    name: $nested
    content: "x"
services:
  app:
    image: $VOE_IMAGE
    command: sleep 900
    configs:
      - aaa_conf
YML

  write_routing_table <<'RT'
route() {
  case "$REL" in
    *.txt) svc voe; check sh -c 'test -f "$1"' _ "/work/$F" ;;
  esac
}
RT

  # The fixture must really carry the trap, or the case proves nothing: the
  # first "name" in the rendered document has to be the config's.
  local first
  first="$(cd "$PROJECT_DIR" && docker compose config --format json 2>/dev/null \
           | grep -o '"name": *"[^"]*"' | head -n1)"
  case "$first" in
    *"$nested"*) ;;
    *)
      printf '    fixture failed: the first "name" is %s, expected the config'"'"'s\n' "$first" >&2
      printf '%s' "unexpected:fixture-has-no-nested-name-first" >"$CASE_DIR/observed"
      return 1
      ;;
  esac

  # 1. only the NESTED name is running. The runner must find nothing.
  voe_container_start "$ctr_nested" "$nested" voe "$PROJECT_DIR" /work >/dev/null || return 1
  run_hook "$PROJECT_DIR/app.txt"
  if [ "$RUN_OUTCOME" != "warning" ]; then
    printf '    the runner resolved the nested name: first edit was %s, expected warning\n' \
      "$RUN_OUTCOME" >&2
    printf '%s' "unexpected:nested-name-resolved" >"$CASE_DIR/observed"
    return 1
  fi

  # 2. the TOP-LEVEL name is running too. The runner must validate.
  #
  # Silence is NOT sufficient on its own here, and measurement is what showed it:
  # step 1 burns the per-service "no running container" warning, so a runner that
  # still resolves neither name is silent on step 2 through warn_once
  # suppression, not through validating anything. Against the runner at
  # `c16f50e` this case passed for exactly that reason. The shim counts the
  # `docker exec` that only a resolved container can produce.
  local logf="$CASE_DIR/docker-calls.log"
  voe_docker_shim "$logf" || return 1

  voe_container_start "$ctr_top" "$top" voe "$PROJECT_DIR" /work >/dev/null || return 1
  printf 'clean again\n' >>"$PROJECT_DIR/app.txt"
  run_hook "$PROJECT_DIR/app.txt"
  expect_outcome "$CASE_EXPECT" || return 1

  local exec_calls; exec_calls="$(voe_docker_calls "$logf" exec)"
  printf '    docker exec calls on the second edit: %s\n' "$exec_calls" >&2
  if [ "${exec_calls:-0}" = "0" ]; then
    printf '    silent because no container was resolved, not because it validated\n' >&2
    printf '%s' "unexpected:silent-without-validating" >"$CASE_DIR/observed"
    return 1
  fi
  return 0
}
