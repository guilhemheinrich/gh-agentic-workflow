#!/usr/bin/env bash
# git-impacted.sh — show the files an iteration touched, at a glance.
#
# Two audiences, two renderings:
#   --md    (default when stdout is captured) markdown for a chat transcript:
#           one clickable link per file, a status column, and a metadata tail.
#   --term  (default on a TTY) eza-backed listing: real sizes, dates and icons,
#           grouped by status because eza itself has no notion of a commit range.
#
# Why a wrapper at all — four things eza cannot do, verified against v0.23.5:
#   · `--git` reports working-tree status only; no commit range exists in eza.
#   · A deleted file cannot be listed (`No such file or directory`, exit 2).
#   · `--tree` given a file list flattens it; the hierarchy is lost.
#   · There is no annotation column, and EZA_COLORS globs match the basename
#     only, so per-path semantics are impossible.
set -euo pipefail

MODE=""
# Captured before parsing, so the reproduce line can replay the real invocation.
ORIGINAL_ARGS="$*"
WANT_STAT=1
WANT_COMMAND=1
WANT_HEAT=0
WANT_HEAT=0
HEAT_STEPS="${GIT_IMPACTED_HEAT_STEPS:-10,50,150,500}"
LIMIT=0
RANGE=""

die() { printf 'git-impacted: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
  cat <<'HELPTEXT'
git-impacted.sh — the files an iteration touched, rendered for a chat or a terminal.

USAGE
  git-impacted.sh [RANGE] [options]

RANGE  Anything `git diff` accepts: HEAD~1, main...HEAD, A..B, A B.
       Omitted, it reports the working tree: staged, unstaged and untracked.

OPTIONS
  --md            Markdown: clickable links, status column, metadata tail.
  --term          eza listing grouped by status (sizes, dates, icons).
  --no-stat       Drop the +added/-removed tail.
  --no-command    Drop the paste-ready command printed under a markdown listing.
  -C DIR          Run as if started in DIR. Lets the reproduce line skip a `cd`.
  --heat          Rank by lines added, shading each entry by volume.
  --heat-steps A,B,C,D
                  Bucket boundaries for --heat (default 10,50,150,500).
  --limit N       Show at most N files per status group.
  -h, --help      This text.

Default mode follows the destination: --md when stdout is a pipe or a file
(an agent capturing it), --term when it is a terminal.
HELPTEXT
}

while [ $# -gt 0 ]; do
  case "$1" in
    --md)       MODE=md; shift ;;
    --term)     MODE=term; shift ;;
    --no-stat)  WANT_STAT=0; shift ;;
    --no-command) WANT_COMMAND=0; shift ;;
    -C)         [ -n "${2:-}" ] || die "-C needs a directory"; cd "$2" || die "cannot cd to $2" 2; shift 2 ;;
    --heat)     WANT_HEAT=1; shift ;;
    --heat-steps) [ -n "${2:-}" ] || die "--heat-steps needs A,B,C,D"; HEAT_STEPS="$2"; WANT_HEAT=1; shift 2 ;;
    --limit)    LIMIT="${2:-0}"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    -*)         die "unknown option: $1" ;;
    *)          RANGE="${RANGE:+$RANGE }$1"; shift ;;
  esac
done

[ -n "$MODE" ] || { [ -t 1 ] && MODE=term || MODE=md; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repository" 2

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Collect ───────────────────────────────────────────────────────────────────

# A single revision (origin/main, HEAD~1) compares that commit to the WORKING
# TREE, so untracked files are part of the answer — "what changed since the last
# push" without them is misleading, since new files are usually the point. A
# commit-to-commit comparison (A..B, A...B, or two revs) has no working tree on
# either side, so untracked files are excluded.
compares_worktree() {
  case "$RANGE" in
    '')      return 0 ;;
    *..*)    return 1 ;;
    *' '*)   return 1 ;;
    *)       return 0 ;;
  esac
}

if [ -n "$RANGE" ]; then
  # shellcheck disable=SC2086
  git diff --name-status -M $RANGE -- > "$TMP/status" || die "bad range: $RANGE" 2
  # shellcheck disable=SC2086
  git diff --numstat -M $RANGE -- > "$TMP/numstat" || :
  LABEL="$RANGE"
else
  git diff --name-status -M HEAD -- > "$TMP/status" || :
  git diff --numstat -M HEAD -- > "$TMP/numstat" || :
  LABEL="working tree"
fi

if compares_worktree; then
  git ls-files --others --exclude-standard | sed 's/^/?	/' >> "$TMP/status"
  # An untracked file has no diff, so numstat knows nothing about it. Counting its
  # lines directly keeps a new file comparable to a modified one, and avoids
  # `git add -N`, which would mutate the index as a side effect.
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    printf '%s\t0\t%s\n' "$(wc -l < "$f" 2>/dev/null | tr -d ' ')" "$f"
  done < <(git ls-files --others --exclude-standard) >> "$TMP/numstat"
  [ -n "$RANGE" ] && LABEL="$RANGE → working tree"
fi

[ -s "$TMP/status" ] || { printf 'No file changed (%s).\n' "$LABEL"; exit 0; }

# numstat renames arrive as `dir/{old.ts => new.ts}`; normalise to the new path
# so the stat tail can be joined onto the name-status rows.
awk -F'\t' '
  function newpath(p,  pre, mid, post, parts) {
    if (p ~ /\{.* => .*\}/) {
      pre = p;  sub(/\{.*/, "", pre)
      mid = p;  sub(/^[^{]*\{/, "", mid); sub(/\}.*$/, "", mid)
      post = p; sub(/^.*\}/, "", post)
      split(mid, parts, / => /)
      return pre parts[2] post
    }
    return p
  }
  NF >= 3 { print newpath($3) "\t" $1 "\t" $2 }
' "$TMP/numstat" > "$TMP/stats" 2>/dev/null || :

# Volume, straight off the row.
stat_for() {
  [ "$WANT_STAT" = "1" ] || return 0
  printf '+%s -%s' "$1" "$2"
}

# Rows become: DIR BASE STATUS PATH OLD ADDS DELS, joined against the numstat
# table so every renderer reaches the volume without a second pass.
#
# The separator is US (0x1f), not a tab: a tab is IFS whitespace, so `read` folds
# runs of them together and an empty middle field — OLD, for anything that is not
# a rename — silently shifts every later column. That bug cost two debugging
# sessions; a non-whitespace separator makes it unrepresentable.
SEP="$(printf '\037')"
awk -F'\t' -v OFS="$SEP" '
  # First file is the normalised numstat table: path, adds, dels.
  NR == FNR { add[$1] = $2; del[$1] = $3; next }
  {
    code = substr($1, 1, 1)
    old  = ""
    path = $2
    if (code == "R" || code == "C") { old = $2; path = $3 }
    if      (code == "A") { label = "new" }
    else if (code == "M") { label = "modified" }
    else if (code == "D") { label = "deleted" }
    else if (code == "R") { label = "renamed" }
    else if (code == "C") { label = "copied" }
    else if (code == "T") { label = "type changed" }
    else if (code == "?") { label = "untracked" }
    else                  { label = "changed (" code ")" }
    n = split(path, seg, "/")
    base = seg[n]
    dir = substr(path, 1, length(path) - length(base))
    if (dir == "") dir = "./"
    a = (path in add) ? add[path] + 0 : 0
    d = (path in del) ? del[path] + 0 : 0
    print dir, base, label, path, old, a, d
  }
' "$TMP/stats" "$TMP/status" | sort -t"$SEP" -k1,1 -k2,2 > "$TMP/rows"

count_of() { awk -F"$SEP" -v l="$1" '$3 == l' "$TMP/rows" | wc -l | tr -d ' '; }
TOTAL="$(wc -l < "$TMP/rows" | tr -d ' ')"

# Ordered so the eye lands on additions first, deletions last.
ORDER='new untracked modified type-changed renamed copied deleted'

summary() {
  local out="" n l
  for l in $ORDER; do
    l="$(printf '%s' "$l" | tr '-' ' ')"
    n="$(count_of "$l")"
    [ "$n" -gt 0 ] && out="${out:+$out, }$n $l"
  done
  printf '%s' "$out"
}

# ── The reproduce line ────────────────────────────────────────────────────────
#
# An agent showing this listing in a chat must hand the reader the command that
# produced it, or the reader has a picture they cannot regenerate. Emitting it
# from the script rather than trusting the agent to remember is the same reflex
# as putting lint in a hook: a deterministic step does not belong in a prompt.
#
# Two things make the printed command paste-ready rather than merely accurate:
#   · `--md` is forced. The agent got markdown for free because its stdout is a
#     pipe; a human pasting into a terminal has a TTY and would get --term.
#   · The script is named by absolute path and the repository by `cd`, so the
#     line works from any directory and needs nothing installed.
self_path() {
  local p="$0" d b
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  d="$(cd "$(dirname "$p")" 2>/dev/null && pwd)" || { printf '%s' "$0"; return; }
  b="$(basename "$p")"
  p="$d/$b"
  case "$p" in "$HOME"/*) printf '~%s' "${p#"$HOME"}" ;; *) printf '%s' "$p" ;; esac
}

reproduce_line() {
  [ "$WANT_COMMAND" = "1" ] || return 0
  local root args script
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
  case "$root" in "$HOME"/*) root="~${root#"$HOME"}" ;; esac
  # Full path, and `bash` explicit: nothing installed, nothing on PATH, and
  # immune to an editing tool resetting the executable bit.
  script="$(self_path)"
  # --md is deliberately STRIPPED, not forced. Whoever pastes this has a terminal,
  # and a terminal should get the coloured rendering; the markdown above already
  # is the transcript view of the same data. Forcing --md would hand a human the
  # one mode that has no colour in it.
  args=" $ORIGINAL_ARGS "
  args="${args// --md / }"
  args="$(printf '%s' "$args" | sed 's/^ *//; s/ *$//')"
  # -C carries the repository, so no `cd` has to precede the command.
  case " $args " in *' -C '*) ;; *) args="-C $root${args:+ $args}" ;; esac
  printf '\nbash %s %s\n' "$script" "$args"
}

#
# Volume is the one signal eza cannot express: --color-scale keys on file size or
# age, never on a diff. The boundaries are configuration rather than a formula,
# because the useful thresholds differ wildly between a bugfix and a new module.
#
# The two renderings differ for the reason given in §3 of the skill: a transcript
# strips ANSI, so intensity travels as block characters there, and as 256-colour
# blue in a terminal.
# ── Heat: rank and shade by lines added ──────────────────────────────────────
HEAT_ANSI="45 39 33 27 21"
HEAT_BARS="▁ ▃ ▅ ▆ █"

# Bucket index 1..5 for a line count, against $HEAT_STEPS.
heat_bucket() {
  awk -v n="$1" -v steps="$HEAT_STEPS" 'BEGIN {
    k = split(steps, s, ",")
    b = 1
    for (i = 1; i <= k; i++) if (n + 0 >= s[i] + 0) b = i + 1
    if (b > 5) b = 5
    print b
  }'
}

heat_pick() { printf '%s' "$2" | cut -d' ' -f"$1"; }

# Heat replaces directory grouping with a flat ranking: the question it answers is
# "where did the volume go", and that ordering fights a per-directory layout.
render_heat() {
  local dir base label path old adds dels b bar colour
  if [ "$MODE" = "md" ]; then
    printf '**%s file(s)** — %s _(%s)_\n' "$TOTAL" "$(summary)" "$LABEL"
    printf '\nheat by lines added, steps `%s`\n\n' "$HEAT_STEPS"
  else
    printf '%s file(s) — %s (%s)\nheat by lines added, steps %s\n\n' \
      "$TOTAL" "$(summary)" "$LABEL" "$HEAT_STEPS"
  fi
  sort -t"$SEP" -k6,6nr "$TMP/rows" | {
    local n=0
    while IFS="$SEP" read -r dir base label path old adds dels; do
      n=$((n + 1))
      if [ "$LIMIT" -gt 0 ] 2>/dev/null && [ "$n" -gt "$LIMIT" ]; then
        printf '\n_… %s more file(s) not shown (--limit %s)._\n' "$((TOTAL - LIMIT))" "$LIMIT"
        break
      fi
      b="$(heat_bucket "$adds")"
      if [ "$MODE" = "md" ]; then
        bar="$(heat_pick "$b" "$HEAT_BARS")"
        if [ "$label" = "deleted" ]; then
          printf -- '- `%s` %6s  `%s` — %s\n' "$bar" "+$adds" "$path" "$label"
        else
          printf -- '- `%s` %6s  [%s](%s) — %s\n' "$bar" "+$adds" "$path" "$path" "$label"
        fi
      else
        colour="$(heat_pick "$b" "$HEAT_ANSI")"
        printf '\033[38;5;%sm%6s  %-11s %s\033[0m\n' "$colour" "+$adds" "$label" "$path"
      fi
    done
  }
  [ "$MODE" = "md" ] && reproduce_line
}

#
# The link is what makes this useful in a chat: a relative path in a markdown
# link is clickable and opens in the editor. eza's own --hyperlink emits OSC 8
# escapes, which a transcript renders as garbage, so it is never used here.

# ── Render: markdown for a transcript ─────────────────────────────────────────
render_md() {
  printf '**%s file(s)** — %s _(%s)_\n' "$TOTAL" "$(summary)" "$LABEL"
  local shown_dir="__none__" dir base label path old adds dels tail s n=0
  while IFS="$SEP" read -r dir base label path old adds dels; do
    n=$((n + 1))
    # A long diff pasted into a chat stops being a glance; cap it loudly.
    if [ "$LIMIT" -gt 0 ] 2>/dev/null && [ "$n" -gt "$LIMIT" ]; then
      printf '\n_… %s more file(s) not shown (--limit %s)._\n' "$((TOTAL - LIMIT))" "$LIMIT"
      break
    fi
    if [ "$dir" != "$shown_dir" ]; then
      printf '\n`%s`\n' "$dir"
      shown_dir="$dir"
    fi
    tail=""
    [ -n "$old" ] && tail=" ← \`$old\`"
    s="$(stat_for "$adds" "$dels")"
    # A pure rename reports +0 -0; saying so adds noise, not information.
    [ "$s" = "+0 -0" ] && s=""
    [ -n "$s" ] && tail="$tail · $s"
    # A deleted path has nothing to open, so it deliberately gets no link.
    if [ "$label" = "deleted" ]; then
      printf -- '- **%s** `%s`%s\n' "$label" "$base" "$tail"
    else
      printf -- '- **%s** [%s](%s)%s\n' "$label" "$base" "$path" "$tail"
    fi
  done < "$TMP/rows"
  [ "$MODE" = "md" ] && reproduce_line
}

# ── Render: eza on the terminal, grouped by status ────────────────────────────

render_term() {
  command -v eza >/dev/null 2>&1 || die "eza is not installed — see INSTALL.md in this skill" 2
  printf '%s file(s) — %s (%s)\n' "$TOTAL" "$(summary)" "$LABEL"
  local group files n
  for group in $ORDER; do
    group="$(printf '%s' "$group" | tr '-' ' ')"
    n="$(count_of "$group")"
    [ "$n" -gt 0 ] || continue
    printf '\n\033[1m%s (%s)\033[0m\n' "$group" "$n"
    files="$(awk -F"$SEP" -v l="$group" '$3 == l { print $4 }' "$TMP/rows")"
    if [ "$LIMIT" -gt 0 ] 2>/dev/null; then
      files="$(printf '%s\n' "$files" | head -n "$LIMIT")"
    fi
    if [ "$group" = "deleted" ]; then
      # eza exits 2 on a missing path, so deleted files are printed plainly.
      printf '%s\n' "$files" | sed 's/^/  /'
      continue
    fi
    printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 eza --long --no-permissions --no-user \
      --time-style=relative --icons=auto --color=auto 2>/dev/null \
      || printf '%s\n' "$files" | sed 's/^/  /'
  done
}

if [ "$WANT_HEAT" = "1" ]; then
  render_heat
  exit 0
fi

case "$MODE" in
  md)   render_md ;;
  term) render_term ;;
esac
