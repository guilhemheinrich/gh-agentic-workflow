# shellcheck shell=bash
# out-guard.sh: sourced by scan-iac.sh. Validates the output directory.
#
# The audited checkout is untrusted: it can ship a symlink where a report would be
# written, and the host shell follows it before any container starts. Raw reports can
# also hold secrets (scanner excerpts). So the output directory must be outside the
# checkout, both as typed and once resolved, and must not be a symlink. It may exist
# already (OUT=$(mktemp -d)) or be one new level under an existing directory
# ("$OUT/iac"), which is then created with mode 0700.
#
# Usage: check_out_dir OUT TARGET   (prints the resolved directory; exits 2 on refusal)

check_out_dir() {
  local out="$1" target="$2" logical parent phys t o
  refuse() {
    printf 'output directory refused: %s. Run once: umask 077; OUT=$(mktemp -d), then pass --out "$OUT/iac".\n' "$1" >&2
    exit 2
  }
  [ -n "$out" ] || refuse "--out is required"
  case "$out" in /*) logical="$out" ;; *) logical="$PWD/$out" ;; esac
  logical="${logical%/}"
  [ ! -L "$logical" ] || refuse "$out is a symlink"
  if [ ! -d "$logical" ]; then
    [ ! -e "$logical" ] || refuse "$out exists and is not a directory"
    parent="$(dirname "$logical")"
    [ -d "$parent" ] || refuse "the parent of $out does not exist (only one level is created)"
  fi
  # Compare before creating anything, on the typed path and on the resolved parent.
  for t in "$target" "$(cd "$target" && pwd -P)"; do
    for o in "$logical" "$(cd "${parent:-$logical}" && pwd -P)"; do
      case "$o/" in "$t"/*) refuse "$out is inside the audited checkout $target" ;; esac
    done
  done
  [ -d "$logical" ] || (umask 077 && mkdir "$logical") || refuse "cannot create $out"
  phys="$(cd "$logical" && pwd -P)"
  for t in "$target" "$(cd "$target" && pwd -P)"; do
    case "$phys/" in "$t"/*) refuse "$out resolves inside the audited checkout $target" ;; esac
  done
  printf '%s\n' "$phys"
}
