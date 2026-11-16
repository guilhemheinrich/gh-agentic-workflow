# Case: doctor-probes-each-service-for-its-file
#
# `--doctor` must establish, per routed service, that the container can actually
# SEE the file the routing table would hand it — one `docker exec <svc> test -f
# <path>` each.
#
# The check nobody writes and everybody needs. A container that cannot see the
# routed path validates nothing, whatever else in the diagnostic is green: a
# `strip` removing the wrong prefix, a service mounting only part of the
# repository, a path that never existed in the image. Every other signal —
# daemon reachable, project resolved, container running, shell present — is
# green in exactly that state, and the only way to learn it today is to edit a
# file and notice that nothing happened.
#
# Shape: two services under one project, and the same project inspected twice.
#   1. both containers bind-mount the directory their branch routes to, so both
#      see their file. `--doctor` must report both visible and claim NO blind
#      service. This is the negative, and it is the half that keeps the check
#      from being a line that always fires.
#   2. `web`'s container is replaced by one mounting an empty directory at the
#      same destination — a mount covering none of the repository. `--doctor`
#      must report that one NOT VISIBLE, name it as blind, and must NOT drag
#      `api` down with it.
#
# The representative path is derived by the runner from the ROUTING TABLE
# itself, over files that exist in this checkout; nothing here tells it which
# path to probe, which is the point — a diagnostic that had to be handed a path
# would be answering a question the consumer already knew the answer to.

CASE_DESC="--doctor probes whether each routed service can see its file"
CASE_EXPECT="doctor-ok"

case_body() {
  local api_dir="$PROJECT_DIR/apps/api" web_dir="$PROJECT_DIR/apps/web"
  local empty="$CASE_DIR/nothing-here"
  local api_name="$PROJECT_NAME-api" web_name="$PROJECT_NAME-web"
  local web_blind_name="$PROJECT_NAME-web-blind"

  mkdir -p "$api_dir" "$web_dir" "$empty" || return 1
  printf 'clean\n' >"$api_dir/main.txt"
  printf 'clean\n' >"$web_dir/app.txt"

  write_routing_table <<'RT'
route() {
  case "$REL" in
    apps/api/*) svc api; strip apps/api/; check sh -c 'test -f "$1"' _ "/srv/$F" ;;
    apps/web/*) svc web; strip apps/web/; check sh -c 'test -f "$1"' _ "/srv/$F" ;;
  esac
}
RT

  # ── 1. Both containers mount what their branch routes to.
  voe_container_start "$api_name" "$PROJECT_NAME" api "$api_dir" /srv >/dev/null || return 1
  voe_container_start "$web_name" "$PROJECT_NAME" web "$web_dir" /srv >/dev/null || return 1

  # Count what the diagnostic costs. `--doctor` is a human CLI path and must not
  # become slow: the routing table is run over the checkout for its DECISION
  # only, so the file scan costs no Docker call at all and the probe costs
  # exactly one `docker exec` per running routed service. A runner that let the
  # scan reach the real validator would print exactly the same text and pay one
  # exec per routed FILE, which no sentence in the output could reveal.
  voe_docker_shim "$CASE_DIR/docker.log" || return 1

  run_doctor
  expect_equal 2 "$(voe_docker_calls "$CASE_DIR/docker.log" exec)" \
    "docker exec calls (one per running routed service)" || return 1
  # And it must not silence what it diagnoses. Running the routing table for its
  # decision has to stop before `check`: reaching `check` here takes its budget
  # arm — `--doctor` arms no deadline — which calls warn_once and writes one
  # session sentinel per service, muting for the rest of the session the exact
  # warnings the developer ran the diagnostic to understand. Measured on this
  # machine, with that stop removed: 2 sentinels, one per routed service.
  expect_doctor want 'suppressed warnings this session: 0' \
    'a read-only diagnostic leaving no warning sentinel behind' || return 1
  expect_doctor want 'api .*main\.txt .*visible' 'api reported as seeing its file' || return 1
  expect_doctor want 'web .*app\.txt .*visible' 'web reported as seeing its file' || return 1
  expect_doctor want 'blind +: none' 'no service claimed blind when none is' || return 1
  expect_doctor reject 'NOT VISIBLE' 'a blindness claimed against a container that can see' || return 1

  # ── 2. Same service, a container mounting a directory holding none of it.
  voe_container_rm "$web_name" || return 1
  voe_container_start "$web_blind_name" "$PROJECT_NAME" web "$empty" /srv >/dev/null || return 1

  run_doctor
  expect_doctor want 'web .*NOT VISIBLE' 'the blind service named' || return 1
  expect_doctor want 'blind +: web' 'the blind service summarised' || return 1
  # The other service must survive its neighbour's failure: a diagnostic that
  # condemned every service the moment one of them was blind would be as useless
  # as one that condemned none.
  expect_doctor want 'api .*main\.txt .*visible' 'api still reported as seeing its file' || return 1
  expect_doctor reject 'blind +:[^A-Za-z]*api' 'api swept into the blind list' || return 1
  return 0
}
