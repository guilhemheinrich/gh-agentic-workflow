#!/usr/bin/env bash
# eza-docs.sh — keep eza's own documentation on hand, and searchable, so no skill
# has to paraphrase it.
#
# The cache is keyed on `eza --version`: help text and man pages only change when
# the binary changes, so a version stamp beats a clock. A TTL is kept as a
# backstop for local builds whose version string never moves.
#
#   eza-docs.sh --grep hyperlink     search every cached page
#   eza-docs.sh --show colors        print one page
#   eza-docs.sh --refresh            rebuild now
#   eza-docs.sh --status             what is cached, from which version
set -euo pipefail

CACHE_DIR="${EZA_DOCS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/eza-docs}"
TTL_DAYS="${EZA_DOCS_TTL_DAYS:-30}"

die() { printf 'eza-docs: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
  cat <<'USAGE'
eza-docs.sh — local cache of eza's help and man pages.

  --grep PATTERN [PAGE]  Search cached pages (case-insensitive), with context.
  --show PAGE            Print a page: help | eza | colors | colors-explanation
  --list                 List cached pages with their line counts.
  --status               Cached version, age, and whether it is stale.
  --refresh              Rebuild the cache from the installed eza.
  -h, --help             This text.

Pages come from `eza --help`, `man eza`, `man eza_colors` and
`man eza_colors-explanation`. Nothing here is hand-written, so nothing here can
drift from the installed binary.
USAGE
}

eza_version() { eza --version 2>/dev/null | sed -n '2p' | awk '{print $1}'; }

cached_version() {
  [ -r "$CACHE_DIR/version" ] && cat "$CACHE_DIR/version" || printf ''
}

cache_age_days() {
  [ -r "$CACHE_DIR/version" ] || { printf '%s' "-1"; return; }
  local mtime now
  mtime="$(stat -f %m "$CACHE_DIR/version" 2>/dev/null || stat -c %Y "$CACHE_DIR/version" 2>/dev/null || echo 0)"
  [ "$mtime" -gt 0 ] 2>/dev/null || { printf '%s' "-1"; return; }
  now="$(date -u +%s)"
  printf '%s' "$(( (now - mtime) / 86400 ))"
}

# man output is formatted for a terminal: `col -bx` strips the backspace
# overstriking that would otherwise poison every grep.
dump_man() {
  local page="$1" out="$2"
  if MANWIDTH=100 man "$page" >/dev/null 2>&1; then
    MANWIDTH=100 man "$page" 2>/dev/null | col -bx > "$out"
    return 0
  fi
  return 1
}

refresh() {
  command -v eza >/dev/null 2>&1 || die "eza is not installed — see INSTALL.md in this skill" 2
  mkdir -p "$CACHE_DIR"
  eza --help > "$CACHE_DIR/help.txt" 2>&1 || die "eza --help failed" 2
  dump_man eza                      "$CACHE_DIR/eza.txt"                || : > "$CACHE_DIR/eza.txt"
  dump_man eza_colors               "$CACHE_DIR/colors.txt"             || : > "$CACHE_DIR/colors.txt"
  dump_man eza_colors-explanation   "$CACHE_DIR/colors-explanation.txt" || : > "$CACHE_DIR/colors-explanation.txt"
  eza_version > "$CACHE_DIR/version"
  printf 'cached eza %s in %s\n' "$(cached_version)" "$CACHE_DIR"
}

ensure_fresh() {
  local installed cached age
  installed="$(eza_version)"
  cached="$(cached_version)"
  age="$(cache_age_days)"
  if [ -z "$cached" ] || [ "$cached" != "$installed" ] || [ "$age" -lt 0 ] || [ "$age" -ge "$TTL_DAYS" ]; then
    refresh >/dev/null
  fi
}

page_path() {
  case "$1" in
    help)                printf '%s' "$CACHE_DIR/help.txt" ;;
    eza|man)             printf '%s' "$CACHE_DIR/eza.txt" ;;
    colors)              printf '%s' "$CACHE_DIR/colors.txt" ;;
    colors-explanation)  printf '%s' "$CACHE_DIR/colors-explanation.txt" ;;
    *) die "unknown page '$1' — try: help | eza | colors | colors-explanation" ;;
  esac
}

case "${1:-}" in
  -h|--help|'') usage; exit 0 ;;
  --refresh) refresh; exit 0 ;;
  --status)
    printf 'cache      %s\n' "$CACHE_DIR"
    printf 'installed  %s\n' "$(eza_version)"
    printf 'cached     %s\n' "$(cached_version || echo '<empty>')"
    printf 'age        %s day(s), TTL %s\n' "$(cache_age_days)" "$TTL_DAYS"
    [ "$(cached_version)" = "$(eza_version)" ] && printf 'state      fresh\n' || printf 'state      STALE — run --refresh\n'
    exit 0 ;;
  --list)
    ensure_fresh
    for p in help eza colors colors-explanation; do
      f="$(page_path "$p")"
      printf '  %-20s %5s lines\n' "$p" "$( [ -s "$f" ] && wc -l < "$f" | tr -d ' ' || echo 0 )"
    done
    exit 0 ;;
  --show)
    [ -n "${2:-}" ] || die "--show needs a page name"
    ensure_fresh
    cat "$(page_path "$2")"
    exit 0 ;;
  --grep)
    [ -n "${2:-}" ] || die "--grep needs a pattern"
    ensure_fresh
    pattern="$2"
    if [ -n "${3:-}" ]; then
      files="$(page_path "$3")"
    else
      files="$CACHE_DIR/help.txt $CACHE_DIR/eza.txt $CACHE_DIR/colors.txt $CACHE_DIR/colors-explanation.txt"
    fi
    # shellcheck disable=SC2086
    grep -inH -B1 -A3 -- "$pattern" $files 2>/dev/null | sed "s|$CACHE_DIR/||" || die "no match for '$pattern'" 3
    exit 0 ;;
  *) die "unknown option '$1' — see --help" ;;
esac
