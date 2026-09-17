# Case: compose-file-variable-points-elsewhere
#
# Spec: FR-011 — "The runner MUST resolve the Compose project name the way
# Compose itself resolves it, across all four sources AND WHICHEVER COMPOSE
# FILES APPLY. It MUST obtain that answer by delegating to Compose rather than
# by reimplementing the precedence."
#
# Shape: a repository with NO Compose file in its root, whose stack is declared
# in `deploy/compose.yml` and reached through `COMPOSE_FILE=deploy/compose.yml`
# — the arrangement of every repository that keeps its deployment files in a
# subdirectory. The declared name differs from the directory basename, so the
# two candidate answers cannot be confused.
#
# The defect: resolution asked only whether a Compose file sat in the project
# ROOT, and returned the basename when none did — before Compose was consulted
# at all. COMPOSE_FILE is the variable Compose itself reads FIRST when deciding
# which files to load, so the one consumer who was explicit about it got the
# one answer that ignored them: a label no container carries, one "no running
# container" warning, and silence for every edit after that.
#
# Expected: silence — the container is found and the validator runs clean.

CASE_DESC="a Compose file named by COMPOSE_FILE, with none in the project root"
CASE_EXPECT="silence"

case_body() {
  local declared="$PROJECT_NAME-deployed" name="$PROJECT_NAME-svc"
  VOE_NO_CPN=1
  printf 'clean\n' >"$PROJECT_DIR/app.txt"

  mkdir -p "$PROJECT_DIR/deploy" || return 1
  cat >"$PROJECT_DIR/deploy/compose.yml" <<YML
name: $declared
services:
  app:
    image: $VOE_IMAGE
    command: sleep 900
YML

  # The project root must carry no Compose file of its own, or the case would
  # prove nothing about the variable.
  local stray
  stray="$(ls "$PROJECT_DIR"/compose.y*ml "$PROJECT_DIR"/docker-compose.y*ml 2>/dev/null | wc -l | tr -d ' ')"
  voe_assert_tick
  if [ "$stray" != "0" ]; then
    printf '    fixture failed: %s Compose file(s) in the project root\n' "$stray" >&2
    printf '%s' "unexpected:root-compose-file-present" >"$CASE_DIR/observed"
    return 1
  fi

  write_routing_table <<'RT'
route() {
  case "$REL" in
    *.txt) svc voe; check sh -c 'test -f "$1"' _ "/work/$F" ;;
  esac
}
RT

  # Labelled with the DECLARED name. The basename — the old answer — is
  # $PROJECT_NAME, which no container carries here.
  voe_container_start "$name" "$declared" voe "$PROJECT_DIR" /work >/dev/null || return 1

  VOE_COMPOSE_FILE="deploy/compose.yml"
  run_hook "$PROJECT_DIR/app.txt"
  expect_outcome "$CASE_EXPECT"
}
