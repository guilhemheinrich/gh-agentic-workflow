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
# The IMAGE is a parameter, not a constant. The runner injects a `sh -c` wrapper
# into every validator call, so the shell inside the container is part of the
# contract under test, and one image proves that contract for one shell only.
# run.sh sets $VOE_IMAGE per matrix row; a case needing a specific image says so.
#
# bash 3.2 compatible: no associative arrays, no mapfile, no ${var^^}.

VOE_IMAGE="${VOE_IMAGE:-alpine:3.20}"

# voe_register NAME — record a container name for teardown.
voe_register() {
  printf '%s\n' "$1" >>"$VOE_REGISTRY"
}

# voe_container_start NAME PROJECT SERVICE HOST_DIR CONTAINER_DIR [IMAGE]
# Starts a detached container carrying the two Compose labels the runner
# filters on, with HOST_DIR bind-mounted at CONTAINER_DIR. Prints the id.
# IMAGE defaults to $VOE_IMAGE, the current matrix row.
voe_container_start() {
  local name="$1" project="$2" service="$3" host_dir="$4" ctr_dir="$5" cid=""
  local image="${6:-$VOE_IMAGE}"
  voe_register "$name"
  cid="$(docker run -d \
    --name "$name" \
    --label "com.docker.compose.project=$project" \
    --label "com.docker.compose.service=$service" \
    -v "$host_dir:$ctr_dir" \
    "$image" sleep 900 2>&1)" || {
      printf 'fixture: docker run failed: %s\n' "$cid" >&2
      return 1
    }
  printf '%s' "$cid"
}

# voe_container_start_ex NAME PROJECT SERVICE HOST_DIR CONTAINER_DIR [EXTRA...]
# As voe_container_start, plus arbitrary `docker run` arguments before the image
# — a working directory, a second mount, a named volume shadowing the first.
# The image is always $VOE_IMAGE, the current matrix row.
voe_container_start_ex() {
  local name="$1" project="$2" service="$3" host_dir="$4" ctr_dir="$5" cid=""
  shift 5
  voe_register "$name"
  cid="$(docker run -d \
    --name "$name" \
    --label "com.docker.compose.project=$project" \
    --label "com.docker.compose.service=$service" \
    -v "$host_dir:$ctr_dir" \
    "$@" \
    "$VOE_IMAGE" sleep 900 2>&1)" || {
      printf 'fixture: docker run failed: %s\n' "$cid" >&2
      return 1
    }
  printf '%s' "$cid"
}

# voe_volume_create NAME — a named volume this session owns and tears down.
# Named `voe-test-*` like every container, so a stray is findable with
# `docker volume ls --filter name=voe-test-`, and a name outside that prefix is
# refused rather than created.
voe_volume_create() {
  case "$1" in voe-test-*) ;; *) printf 'fixture: refusing volume name %s\n' "$1" >&2; return 1 ;; esac
  docker volume create "$1" >/dev/null 2>&1 || {
    printf 'fixture: could not create volume %s\n' "$1" >&2; return 1; }
  printf '%s\n' "$1" >>"$VOE_VOLUMES"
  return 0
}

# voe_volume_seed VOLUME RELATIVE_PATH CONTENT
# Writes one file into a volume this session created, through a throwaway
# container. A named volume mounted over a BIND destination is NOT populated
# from that bind — measured 2026-09-17, the shadowed path was simply empty — so
# the stale copy the shadowing case needs has to be written on purpose.
voe_volume_seed() {
  local vol="$1" rel="$2" content="$3"
  grep -qx "$vol" "$VOE_VOLUMES" 2>/dev/null || {
    printf 'fixture: refusing to write into unregistered volume %s\n' "$vol" >&2; return 1; }
  docker run --rm -v "$vol:/seed" "$VOE_IMAGE" \
    sh -c "mkdir -p \"/seed/\$(dirname '$rel')\"; printf '%s\n' '$content' > '/seed/$rel'" \
    >/dev/null 2>&1 || { printf 'fixture: could not seed %s\n' "$vol" >&2; return 1; }
  return 0
}

# voe_container_remove_shell NAME
# Deletes every POSIX shell from a container this suite created, leaving the
# rest of the image intact: the container's own `sleep` and a validator such as
# `grep` keep working, only `sh` becomes unreachable. This is the FR-005a
# fixture — a container with a working validator that cannot host the provenance
# wrapper. The list covers both matrix rows: busybox links /bin/sh to /bin/ash,
# Debian links it to /bin/dash, and either image may also carry bash.
#
# Verified after the fact rather than assumed: `sh` must fail AND a validator
# must still run, or the fixture fails instead of handing the case a container
# that would prove something else.
voe_container_remove_shell() {
  local name="$1"
  grep -qx "$name" "$VOE_REGISTRY" 2>/dev/null || {
    printf 'fixture: refusing to modify unregistered container %s\n' "$name" >&2
    return 1
  }
  docker exec "$name" sh -c \
    'rm -f /bin/sh /bin/ash /bin/dash /bin/bash /usr/bin/sh /usr/bin/ash /usr/bin/dash /usr/bin/bash' \
    >/dev/null 2>&1 || {
      printf 'fixture: could not remove the shell from %s\n' "$name" >&2
      return 1
    }
  if docker exec "$name" sh -c 'exit 0' >/dev/null 2>&1; then
    printf 'fixture: %s still has a working sh after removal\n' "$name" >&2
    return 1
  fi
  # /etc/os-release exists on every image in the matrix, so this probe does not
  # assume a distribution the way reading /etc/alpine-release would.
  docker exec "$name" grep -q . /etc/os-release >/dev/null 2>&1 || {
    printf 'fixture: %s lost its validator along with its shell\n' "$name" >&2
    return 1
  }
  return 0
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

# voe_teardown_all — remove every container and volume this session registered.
voe_teardown_all() {
  local n
  if [ -f "$VOE_REGISTRY" ]; then
    while IFS= read -r n; do
      # Unpause first: a frozen container (voe_container_pause) must not be able
      # to make the teardown of a failing run hang or fail.
      [ -n "$n" ] && docker unpause "$n" >/dev/null 2>&1
      [ -n "$n" ] && docker rm -f "$n" >/dev/null 2>&1
    done <"$VOE_REGISTRY"
    : >"$VOE_REGISTRY"
  fi
  # Volumes go after the containers that hold them, or the removal is refused.
  if [ -n "${VOE_VOLUMES:-}" ] && [ -f "$VOE_VOLUMES" ]; then
    while IFS= read -r n; do
      [ -n "$n" ] && docker volume rm -f "$n" >/dev/null 2>&1
    done <"$VOE_VOLUMES"
    : >"$VOE_VOLUMES"
  fi
  return 0
}

# voe_container_pause NAME
# Freezes a container this suite created. It stays in `docker ps` — so it is
# still a candidate behind its labels — while `docker exec` is refused by the
# daemon: measured 2026-09-17, rc 1, `Error response from daemon: Container …
# is paused, unpause the container before exec`. That is the one state matching
# the fourth row of the cause table: the container is alive and the call cannot
# get inside it.
#
# Verified after the fact rather than assumed, like the shell removal above.
voe_container_pause() {
  local name="$1"
  grep -qx "$name" "$VOE_REGISTRY" 2>/dev/null || {
    printf 'fixture: refusing to pause unregistered container %s\n' "$name" >&2
    return 1
  }
  docker pause "$name" >/dev/null 2>&1 || {
    printf 'fixture: could not pause %s\n' "$name" >&2
    return 1
  }
  if ! docker ps -q --no-trunc | grep -q "$(docker inspect -f '{{.Id}}' "$name" 2>/dev/null)"; then
    printf 'fixture: %s left the running set when paused\n' "$name" >&2
    return 1
  fi
  return 0
}
