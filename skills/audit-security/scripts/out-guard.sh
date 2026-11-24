# out-guard.sh - sourced by the scan scripts. Validates the output directory.
#
# The audited checkout is untrusted: it can ship a symlink where a report
# would be written, and a write through it lands outside the checkout. So the
# output directory must already exist (OUT=$(mktemp -d)), must not be a
# symlink, and must be outside the checkout both as typed and once resolved:
# "--out repo/link/sub" with repo/link pointing elsewhere is refused too.
#
# Usage: check_out_dir [TARGET_DIR]   (reads and rewrites $OUT; exits 2 on refusal)

check_out_dir() {
  local target="${1:-}" logical phys t o
  refuse() { echo "output directory refused: $1. Run once: OUT=\$(mktemp -d), then pass --out \"\$OUT\" to every script (or export SECURITY_AUDIT_OUT)." >&2; exit 2; }
  [ -n "$OUT" ] || refuse "none given"
  case "$OUT" in /*) logical="$OUT" ;; *) logical="$PWD/$OUT" ;; esac
  [ ! -L "$logical" ] || refuse "$OUT is a symlink"
  [ -d "$logical" ] || refuse "$OUT does not exist (it is never created for you)"
  phys="$(cd "$logical" && pwd -P)"
  if [ -n "$target" ]; then
    for t in "$target" "$(cd "$target" && pwd -P)"; do
      for o in "$logical" "$phys"; do
        case "$o/" in "$t"/*) refuse "$OUT is inside the audited checkout $target" ;; esac
      done
    done
  fi
  OUT="$phys"
}
