#!/usr/bin/env bash
# test-cursor-review.sh — offline regression suite for cursor-review.sh.
#
# Every case asserts a BOUND — an exit code, a wall clock, a file that must or
# must not exist, a flag that must or must not be on the command line — rather
# than the content of an answer. No network, no Cursor account, no tokens: a
# stub stands in for cursor-agent and records the argv it was handed.
#
#   bash scripts/test-cursor-review.sh
#   CURSOR_REVIEW_SUT=/path/to/other/cursor-review.sh bash scripts/test-cursor-review.sh
#
# Exits 0 when green, 1 with a per-case report when not.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
SUT="${CURSOR_REVIEW_SUT:-$HERE/cursor-review.sh}"
[ -x "$SUT" ] || { echo "not executable: $SUT" >&2; exit 2; }

PASS=0; FAIL=0; FAILED_CASES=""
LAB="$(mktemp -d "${TMPDIR:-/tmp}/cursor-review-test.XXXXXX")"
STUB="$LAB/bin/cursor-agent"
ARGV_LOG="$LAB/argv.log"
trap 'rm -rf "$LAB"' EXIT

ok()   { PASS=$(( PASS + 1 )); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$(( FAIL + 1 )); FAILED_CASES="$FAILED_CASES
  - $1: $2"; printf '  FAIL %s — %s\n' "$1" "$2"; }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
lt()   { if [ "$2" -lt "$3" ]; then ok "$1"; else bad "$1" "expected < $3, got $2"; fi; }

# ------------------------------------------------------------------- the stub
mkdir -p "$LAB/bin"
cat > "$STUB" <<'STUB_EOF'
#!/usr/bin/env bash
# Stands in for cursor-agent. Records argv, then plays a scripted outcome
# chosen by STUB_BEHAVIOUR: ok | empty | fail | slow.
printf '%s\n' "$*" >> "$ARGV_LOG"
case "${1:-}" in
  --version)     echo "0.0.0-stub"; exit 0 ;;
  status)        echo "✓ Logged in as stub@example.com"; exit 0 ;;
  --list-models) cat <<'MODELS'
Available models

auto - Auto (default)
gpt-5.6-sol-high - GPT stub high
gpt-5.4-mini-medium - GPT stub mini
claude-opus-5-thinking-high - Claude stub
claude-sonnet-5-thinking-high - Claude stub sonnet
gemini-3.7-flash-high - Gemini stub
cursor-grok-4.6-high - Grok stub
kimi-k3-max - Kimi stub
glm-5.2-max - GLM stub
composer-2.5 - Composer stub
MODELS
                 exit 0 ;;
esac
case "${STUB_BEHAVIOUR:-ok}" in
  empty) exit 0 ;;
  fail)  echo "stub refused" >&2; exit 7 ;;
  slow)  sleep 120; exit 0 ;;
  *)     echo "### stub finding
- location: src/x.py:1
- trigger: anything
- consequence: this is a stub answer long enough to clear the 20-byte floor"
         exit 0 ;;
esac
STUB_EOF
chmod +x "$STUB"
export ARGV_LOG
export CURSOR_REVIEW_BIN="$STUB"

# ------------------------------------------------------------ a fixture repo
REPO="$LAB/repo"
mkdir -p "$REPO/src" "$REPO/specs/012"
( cd "$REPO" && git init -q . && git config user.email t@t.t && git config user.name t
  printf 'FR-1: must round half-up.\n' > specs/012/spec.md
  printf 'def f(a):\n    return int(a)\n' > src/tax.py
  git add -A && git commit -qm init
  printf 'def f(a):\n    return int(a + 0.5)\n' > src/tax.py
  printf 'helper\n' > src/helper.py
  git add -A && git commit -qm change ) >/dev/null 2>&1

run() { ( cd "$REPO" && "$SUT" "$@" ); }
reset_log() { : > "$ARGV_LOG"; }

echo "cursor-review.sh regression suite"
echo "sut: $SUT"
echo

# ---------------------------------------------------------------- invocation
echo "invocation"
out="$(run --version 2>&1)"; is "version exits 0" "$?" "0"
run --help >/dev/null 2>&1; is "help exits 0" "$?" "0"
run --nope >/dev/null 2>&1; is "unknown option exits 1" "$?" "1"
run -m >/dev/null 2>&1; is "missing option value exits 1" "$?" "1"
run --dry-run -f specs/012/spec.md "x" >/dev/null 2>&1; is "no model exits 2" "$?" "2"
run --mode agent -m gpt-5.6-sol-high --dry-run -f specs/012/spec.md "x" >/dev/null 2>&1
is "a writable --mode is refused" "$?" "1"
CURSOR_REVIEW_BIN=/nonexistent/cursor-agent run --doctor >/dev/null 2>&1
is "missing cursor-agent exits 2" "$?" "2"

# -------------------------------------------------------------------- staging
echo
echo "staging"
run --no-stdin -m gpt-5.6-sol-high --dry-run -f NOPE.md "x" >/dev/null 2>&1
is "-f on a missing file exits 1" "$?" "1"
run --no-stdin -m gpt-5.6-sol-high --dry-run -f src "x" >/dev/null 2>&1
is "-f on a directory exits 1" "$?" "1"
run --no-stdin -m gpt-5.6-sol-high --dry-run "x" >/dev/null 2>&1
is "nothing staged exits 1" "$?" "1"

tree="$(run --no-stdin -m gpt-5.6-sol-high --dry-run -f src/tax.py -d specs/012 "x" 2>/dev/null)"
case "$tree" in *"src/tax.py"*) ok "-f preserves the repository-relative path" ;;
  *) bad "-f preserves the repository-relative path" "not in tree" ;; esac
case "$tree" in *"specs/012/spec.md"*) ok "-d stages a directory's contents" ;;
  *) bad "-d stages a directory's contents" "not in tree" ;; esac
case "$tree" in *"REVIEW-CONTEXT.md"*) ok "a manifest is always written" ;;
  *) bad "a manifest is always written" "not in tree" ;; esac

tree="$(run --no-stdin -m gpt-5.6-sol-high --dry-run --diff HEAD~1 "x" 2>/dev/null)"
case "$tree" in *"review-context/diff.patch"*) ok "--diff stages the patch" ;;
  *) bad "--diff stages the patch" "not in tree" ;; esac
case "$tree" in *"src/tax.py"*) bad "--diff alone does not stage changed files" "tax.py present" ;;
  *) ok "--diff alone does not stage changed files" ;; esac

tree="$(run --no-stdin -m gpt-5.6-sol-high --dry-run --changed HEAD~1 "x" 2>/dev/null)"
case "$tree" in *"src/tax.py"*) ok "--changed stages a changed file in full" ;;
  *) bad "--changed stages a changed file in full" "not in tree" ;; esac
case "$tree" in *"src/helper.py"*) ok "--changed stages every changed file" ;;
  *) bad "--changed stages every changed file" "helper.py missing" ;; esac

run --no-stdin -m gpt-5.6-sol-high --dry-run --diff HEAD "x" >/dev/null 2>&1
is "an empty diff is refused, not reviewed" "$?" "1"
run --no-stdin -m gpt-5.6-sol-high --dry-run --diff no-such-ref "x" >/dev/null 2>&1
is "a bad --diff ref exits 1" "$?" "1"

# ---------------------------------------------------------------------- stdin
echo
echo "stdin"
tree="$(printf 'diff --git a b\n' | run -m gpt-5.6-sol-high --dry-run -f src/tax.py "x" 2>/dev/null)"
case "$tree" in *"review-context/stdin.patch"*) ok "a closing pipe is materialised into the workspace" ;;
  *) bad "a closing pipe is materialised into the workspace" "not in tree" ;; esac

tree="$(printf 'x\n' | run --no-stdin -m gpt-5.6-sol-high --dry-run -f src/tax.py "x" 2>/dev/null)"
case "$tree" in *"stdin.patch"*) bad "--no-stdin never reads stdin" "stdin.patch present" ;;
  *) ok "--no-stdin never reads stdin" ;; esac

# An idle stdin — a pipe with a writer that never writes and never closes, as
# handed out by agent harnesses, CI runners and `ssh host cmd`. Timing the
# pipeline instead of the script would just measure the producer, so the writer
# is held open on a fifo and only the script's own wall clock is asserted.
mkfifo "$LAB/idle.fifo" 2>/dev/null
( exec 3> "$LAB/idle.fifo"; sleep 40 ) 2>/dev/null & IDLE_PRODUCER=$!
disown 2>/dev/null || true
s=$(date +%s)
run -m gpt-5.6-sol-high --dry-run -f src/tax.py --budget 60 "x" < "$LAB/idle.fifo" >/dev/null 2>&1
e=$(( $(date +%s) - s ))
kill "$IDLE_PRODUCER" 2>/dev/null; wait "$IDLE_PRODUCER" 2>/dev/null
lt "an idle stdin is dropped, not waited on forever" "$e" "20"

# --------------------------------------------------------------------- panel
echo
echo "panel"
line="$(run --no-stdin --panel 3 --exclude-vendor anthropic --dry-run -f src/tax.py "x" 2>&1 | grep 'lane(s)')"
case "$line" in *claude-*) bad "--exclude-vendor drops the vendor" "a claude id survived" ;;
  *) ok "--exclude-vendor drops the vendor" ;; esac
n="$(printf '%s' "$line" | tr ' ' '\n' | grep -c -- '-')"
case "$line" in *"3 lane(s)"*) ok "--panel N yields N lanes" ;;
  *) bad "--panel N yields N lanes" "got: $line" ;; esac
line="$(run --no-stdin --panel 9 --dry-run -f src/tax.py "x" 2>&1 | grep 'lane(s)')"
dupes="$(printf '%s' "$line" | sed 's/.*\[//;s/\].*//' | tr ' ' '\n' | sort | uniq -d)"
is "the panel never repeats a model" "$dupes" ""
line="$(run --no-stdin -m gpt-5.6-sol-high --panel 1 --dry-run -f src/tax.py "x" 2>&1 | grep 'lane(s)')"
case "$line" in *"gpt-5.6-sol-high gpt-5.6-sol-high"*) bad "-m and --panel collapse duplicates" "repeated" ;;
  *) ok "-m and --panel collapse duplicates" ;; esac
run --no-stdin --panel 2 --exclude-vendor anthropic --exclude-vendor openai \
  --exclude-vendor google --exclude-vendor xai --exclude-vendor moonshot \
  --exclude-vendor zhipu --exclude-vendor cursor --dry-run -f src/tax.py "x" >/dev/null 2>&1
is "excluding every vendor exits 2" "$?" "2"

# ------------------------------------------------------------------ dispatch
echo
echo "dispatch"
reset_log
out="$(run --no-stdin -m gpt-5.6-sol-high -f src/tax.py -o "$LAB/out1" "x" 2>&1)"; rc=$?
is "a green lane exits 0" "$rc" "0"
[ -s "$LAB/out1/review-gpt-5.6-sol-high.md" ] && ok "the review lands in --out" \
  || bad "the review lands in --out" "file missing or empty"
argv="$(cat "$ARGV_LOG")"
case "$argv" in *"--trust"*) ok "--trust is always passed" ;;
  *) bad "--trust is always passed" "absent" ;; esac
case "$argv" in *"--mode ask"*) ok "the read-only mode is always passed" ;;
  *) bad "the read-only mode is always passed" "absent" ;; esac
case "$argv" in *" -f "*|*"--force"*|*"--yolo"*) bad "no write-enabling flag is ever passed" "found one" ;;
  *) ok "no write-enabling flag is ever passed" ;; esac

reset_log
STUB_BEHAVIOUR=empty run --no-stdin -m gpt-5.6-sol-high -f src/tax.py -o "$LAB/out2" "x" >/dev/null 2>&1
is "an empty lane exits 3, not 0" "$?" "3"
STUB_BEHAVIOUR=fail run --no-stdin -m gpt-5.6-sol-high -f src/tax.py -o "$LAB/out3" "x" >/dev/null 2>&1
is "a refusing lane exits 3" "$?" "3"
s=$(date +%s)
STUB_BEHAVIOUR=slow run --no-stdin -m gpt-5.6-sol-high -f src/tax.py -o "$LAB/out4" \
  --timeout 5 --budget 60 "x" >/dev/null 2>&1
rc=$?; e=$(( $(date +%s) - s ))
is "a lane timeout exits 4" "$rc" "4"
lt "the lane timeout is enforced in wall clock" "$e" "25"

# -------------------------------------------------------- bounds and cleanup
echo
echo "bounds and cleanup"
s=$(date +%s)
STUB_BEHAVIOUR=slow run --no-stdin -m gpt-5.6-sol-high -f src/tax.py -o "$LAB/out5" \
  --timeout 300 --budget 6 "x" >/dev/null 2>&1
rc=$?; e=$(( $(date +%s) - s ))
is "the run budget exits 4" "$rc" "4"
lt "the run budget is enforced in wall clock" "$e" "20"

# The regression that made a naive panel script hang a terminal: a background
# lane, or a sleeping watchdog, still holding the caller's pipe after the
# script itself is gone.
s=$(date +%s)
( cd "$REPO" && STUB_BEHAVIOUR=slow "$SUT" --no-stdin -m gpt-5.6-sol-high -f src/tax.py \
    -o "$LAB/out6" --timeout 300 --budget 6 "x" 2>&1 | head -2 ) >/dev/null 2>&1
e=$(( $(date +%s) - s ))
lt "piping to head does not outlive the run" "$e" "25"

ws="$(run --no-stdin -m gpt-5.6-sol-high -f src/tax.py -o "$LAB/out7" --keep "x" 2>&1 \
      | sed -n 's/.*staged workspace kept at \(.*\)/\1/p' | tail -1)"
if [ -n "$ws" ] && [ -d "$ws" ]; then ok "--keep keeps the workspace"; rm -rf "$ws"
else bad "--keep keeps the workspace" "no surviving directory reported"; fi

before="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'cursor-review.*' 2>/dev/null | wc -l | tr -d ' ')"
run --no-stdin -m gpt-5.6-sol-high -f src/tax.py -o "$LAB/out8" "x" >/dev/null 2>&1
after="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'cursor-review.*' 2>/dev/null | wc -l | tr -d ' ')"
is "the workspace is removed without --keep" "$after" "$before"

# ------------------------------------------------------------------- verdict
echo
printf 'passed %s, failed %s\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then printf '%s\n' "$FAILED_CASES"; exit 1; fi
exit 0
