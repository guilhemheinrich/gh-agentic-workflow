#!/usr/bin/env bash
# skills/static-validation-hooks/tests/fixtures/container.sh
#
# Throwaway fixtures for the black-box suite. No project stack, no compose file:
# a plain `docker run` carrying the two labels `lookup_cid` filters on
# (templates/validate-on-edit.sh:240-243) is indistinguishable, from the
# runner's point of view, from a container Compose started.
#
# Everything created here is named `voe-test-<session>-*` so a stray is findable
# with `docker ps -a --filter name=voe-test-`. Containers this file starts are
# registered in $VOE_REGISTRY and removed by run.sh's EXIT trap, on success and
# on failure alike. Nothing this file does can touch a container it did not
# create.
#
# bash 3.2 compatible: no associative arrays, no mapfile, no ${var^^}.

VOE_IMAGE="${VOE_IMAGE:-alpine:3.20}"

# voe_register NAME — record a container name for teardown.
voe_register() {
  printf '%s\n' "$1" >>"$VOE_REGISTRY"
}

# voe_container_start NAME PROJECT SERVICE HOST_DIR CONTAINER_DIR
# Starts a detached container carrying the two Compose labels the runner
# filters on, with HOST_DIR bind-mounted at CONTAINER_DIR. Prints the id.
voe_container_start() {
  local name="$1" project="$2" service="$3" host_dir="$4" ctr_dir="$5" cid=""
  voe_register "$name"
  cid="$(docker run -d \
    --name "$name" \
    --label "com.docker.compose.project=$project" \
    --label "com.docker.compose.service=$service" \
    -v "$host_dir:$ctr_dir" \
    "$VOE_IMAGE" sleep 900 2>&1)" || {
      printf 'fixture: docker run failed: %s\n' "$cid" >&2
      return 1
    }
  printf '%s' "$cid"
}

# voe_container_rm NAME — remove one container this suite created.
voe_container_rm() {
  local name="$1"
  grep -qx "$name" "$VOE_REGISTRY" 2>/dev/null || {
    printf 'fixture: refusing to remove unregistered container %s\n' "$name" >&2
    return 1
  }
  docker rm -f "$name" >/dev/null 2>&1 || true
}

# voe_teardown_all — remove every container this session registered.
voe_teardown_all() {
  local n
  [ -f "$VOE_REGISTRY" ] || return 0
  while IFS= read -r n; do
    [ -n "$n" ] && docker rm -f "$n" >/dev/null 2>&1
  done <"$VOE_REGISTRY"
  : >"$VOE_REGISTRY"
  return 0
}
