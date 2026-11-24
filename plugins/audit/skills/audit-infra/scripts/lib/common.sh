# shellcheck shell=bash
# Helpers shared by the audit-infra host wrappers. Sourced, never executed.
# Everything that does real work runs in a container; the host needs Docker only.

AUDIT_INFRA_TOOLBOX="${AUDIT_INFRA_TOOLBOX:-audit-infra-toolbox:1}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

need_docker() {
  command -v docker >/dev/null 2>&1 || die "docker is required (nothing is installed on the host)"
  docker info >/dev/null 2>&1 || die "the Docker daemon is not reachable"
}

# Build the small toolbox image (alpine + curl, jq, openssl, dig) on first use.
ensure_toolbox() {
  local dir="$1"
  if ! docker image inspect "$AUDIT_INFRA_TOOLBOX" >/dev/null 2>&1; then
    printf 'audit-infra: building %s (first run only)\n' "$AUDIT_INFRA_TOOLBOX" >&2
    docker build -q -t "$AUDIT_INFRA_TOOLBOX" "$dir" >/dev/null || die "toolbox image build failed"
  fi
}

abs_path() { (cd "$1" 2>/dev/null && pwd) || die "no such directory: $1"; }
