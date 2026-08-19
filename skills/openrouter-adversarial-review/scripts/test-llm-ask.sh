#!/usr/bin/env bash
# test-llm-ask.sh — regression suite for llm-ask.sh.
#
# The bug this suite exists for: the client blocked forever on a stdin that was
# not a terminal and never reached EOF — the shape every agent harness, CI
# runner, cron job and `ssh host cmd` hands a process. The block happened
# before the HTTP request, so --timeout, which only wraps curl, never armed.
# One run was killed by its operator after 9 hours, having printed nothing.
#
# Every case here therefore asserts a bound, not just an answer. The suite runs
# offline: the provider is a local stub, and the assembly cases use --dry-run.
#
#   ./test-llm-ask.sh            # all cases
#   ./test-llm-ask.sh stdin      # only cases whose name matches
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Overridable so the suite can be pointed at an older revision to confirm it
# still fails there — a regression test that was never seen red proves nothing.
SUT="${LLM_ASK_SUT:-$SCRIPT_DIR/llm-ask.sh}"
FILTER="${1:-}"
PASS=0
FAIL=0
WORK="$(mktemp -d)"

# A test that hangs cannot report that it hangs, so every case runs under this.
# perl is in the macOS and Debian base images; GNU timeout is not on macOS.
run_bounded() {
  local secs="$1"; shift
  perl -e '
    my $secs = shift @ARGV;
    my $pid = fork();
    if ($pid == 0) { exec(@ARGV) or die "exec: $!"; }
    $SIG{ALRM} = sub { kill "KILL", $pid; waitpid($pid, 0); exit 124 };
    alarm $secs;
    waitpid($pid, 0);
    alarm 0;
    exit($? >> 8);
  ' "$secs" "$@"
}

# A pipe with a writer that holds it open and never sends EOF. This is the
# environment the reported hang came from, reduced to two lines.
IDLE_HOLDER=""
open_idle_stdin() {
  rm -f "$WORK/idle.fifo"
  mkfifo "$WORK/idle.fifo"
  sleep 300 >"$WORK/idle.fifo" &
  IDLE_HOLDER=$!
  # Disowned so tearing it down does not print a "Killed: 9" job notice between
  # the test results.
  disown "$IDLE_HOLDER" 2>/dev/null || true
}
close_idle_stdin() {
  if [ -n "$IDLE_HOLDER" ]; then kill -9 "$IDLE_HOLDER" 2>/dev/null; fi
  IDLE_HOLDER=""
  rm -f "$WORK/idle.fifo"
}

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n     %s\n' "$1" "$2"; }
skip() { printf '  skip %s (%s)\n' "$1" "$2"; }

selected() {
  [ -z "$FILTER" ] && return 0
  case "$1" in *"$FILTER"*) return 0 ;; *) return 1 ;; esac
}

cleanup_all() {
  close_idle_stdin
  if [ -n "${STUB_PID:-}" ]; then kill -9 "$STUB_PID" 2>/dev/null; fi
  rm -rf "$WORK"
}
trap cleanup_all EXIT

# ── Fixtures ──────────────────────────────────────────────────────────────────

printf 'You review specs and refute claims.\n' >"$WORK/sys.md"
# ~17 KB and ~16 KB, matching the sizes in the bug report.
awk 'BEGIN { for (i = 0; i < 420; i++) print "spec line " i " lorem ipsum dolor sit amet consectetur" }' >"$WORK/spec.md"
awk 'BEGIN { for (i = 0; i < 400; i++) print "+ diff line " i " lorem ipsum dolor sit amet consectetur" }' >"$WORK/fix.diff"

# ── Case 1 — the reported hang ────────────────────────────────────────────────
#
# Two -f blocks plus a system message on an idle stdin. Before the fix this ran
# unbounded and printed nothing on either stream.

if selected "stdin-idle-multifile"; then
  open_idle_stdin
  START=$(date +%s)
  # The budget goes through the environment, not --budget: an older revision
  # would reject the unknown flag and exit 1, and the case would then go red
  # for the wrong reason instead of reproducing the hang.
  run_bounded 45 env LLM_BUDGET_S=30 bash "$SUT" --dry-run -m openai/gpt-4o --max-tokens 6000 \
    -s "@$WORK/sys.md" -f "$WORK/spec.md" -f "$WORK/fix.diff" "What is wrong with these fixes?" \
    <"$WORK/idle.fifo" >"$WORK/c1.out" 2>"$WORK/c1.err"
  RC=$?
  ELAPSED=$(( $(date +%s) - START ))
  close_idle_stdin
  if [ "$RC" = "124" ]; then
    bad "stdin-idle-multifile" "hung: still running after 45s"
  elif [ "$ELAPSED" -gt 20 ]; then
    bad "stdin-idle-multifile" "took ${ELAPSED}s, expected the 5s stdin cap to release it"
  elif [ ! -s "$WORK/c1.out" ]; then
    bad "stdin-idle-multifile" "exited $RC with an empty stdout"
  else
    ok "stdin-idle-multifile — released in ${ELAPSED}s with a payload"
  fi
fi

# ── Case 2 — silence is the part that costs an afternoon ──────────────────────

if selected "stdin-idle-explains-itself"; then
  open_idle_stdin
  run_bounded 45 env LLM_BUDGET_S=30 bash "$SUT" --dry-run -m openai/gpt-4o \
    -f "$WORK/spec.md" "review" <"$WORK/idle.fifo" >"$WORK/c2.out" 2>"$WORK/c2.err"
  close_idle_stdin
  if ! grep -q 'openai/gpt-4o' "$WORK/c2.err"; then
    bad "stdin-idle-explains-itself" "no start-up line naming the model on stderr"
  elif ! grep -q 'attached bytes' "$WORK/c2.err"; then
    bad "stdin-idle-explains-itself" "start-up line does not report the attachment size"
  elif ! grep -q 'no EOF' "$WORK/c2.err"; then
    bad "stdin-idle-explains-itself" "gave up on stdin without saying so"
  else
    ok "stdin-idle-explains-itself"
  fi
fi

# ── Case 3 — the budget bounds a run that never sends a request ───────────────
#
# --stdin waits for EOF on purpose, so only the global budget can end this. It
# is the assertion the report asks for: terminate within the declared budget
# even when the request is never sent.

if selected "budget-bounds-assembly"; then
  open_idle_stdin
  START=$(date +%s)
  run_bounded 60 bash "$SUT" --dry-run --stdin --budget 8 -m openai/gpt-4o "hi" \
    <"$WORK/idle.fifo" >"$WORK/c3.out" 2>"$WORK/c3.err"
  RC=$?
  ELAPSED=$(( $(date +%s) - START ))
  close_idle_stdin
  if [ "$RC" != "4" ]; then
    bad "budget-bounds-assembly" "exit $RC, expected 4 (timeout)"
  elif [ "$ELAPSED" -gt 20 ]; then
    bad "budget-bounds-assembly" "budget was 8s, took ${ELAPSED}s"
  elif ! grep -q 'reading stdin' "$WORK/c3.err"; then
    bad "budget-bounds-assembly" "did not name the phase it died in"
  else
    ok "budget-bounds-assembly — exit 4 in ${ELAPSED}s, phase named"
  fi
fi

# ── Case 4 — --no-stdin is instant ────────────────────────────────────────────

if selected "no-stdin-skips"; then
  open_idle_stdin
  START=$(date +%s)
  run_bounded 30 bash "$SUT" --dry-run --no-stdin -m openai/gpt-4o "hi" \
    <"$WORK/idle.fifo" >"$WORK/c4.out" 2>"$WORK/c4.err"
  RC=$?
  ELAPSED=$(( $(date +%s) - START ))
  close_idle_stdin
  if [ "$RC" != "0" ]; then
    bad "no-stdin-skips" "exit $RC, expected 0"
  elif [ "$ELAPSED" -gt 3 ]; then
    bad "no-stdin-skips" "took ${ELAPSED}s, expected no wait at all"
  else
    ok "no-stdin-skips — ${ELAPSED}s"
  fi
fi

# ── Case 5 — a real pipe is still read whole ──────────────────────────────────
#
# The fix must not buy its bound by dropping legitimate piped input, which is
# the documented `git diff | llm-ask.sh` shape.

if selected "real-pipe-read-whole"; then
  awk 'BEGIN { for (i = 0; i < 2000; i++) print "piped line " i }' >"$WORK/piped.txt"
  # Downstream `cat` matters: a background job holding the inherited stdout
  # would block the reader until its own timer expired.
  run_bounded 30 sh -c "bash '$SUT' --dry-run -m openai/gpt-4o 'look' <'$WORK/piped.txt' 2>/dev/null | cat" >"$WORK/c5.out"
  RC=$?
  if [ "$RC" = "124" ]; then
    bad "real-pipe-read-whole" "hung with output piped onward"
  elif ! grep -q 'piped line 1999' "$WORK/c5.out"; then
    bad "real-pipe-read-whole" "last piped line missing from the payload"
  elif ! grep -q 'BEGIN INPUT' "$WORK/c5.out"; then
    bad "real-pipe-read-whole" "piped block lost its delimiter"
  else
    ok "real-pipe-read-whole"
  fi
fi

# ── Case 6 — multi-file assembly, the path the report asked us to exercise ────

if selected "multifile-assembly"; then
  run_bounded 30 bash "$SUT" --dry-run -m openai/gpt-4o --max-tokens 6000 \
    -s "@$WORK/sys.md" -f "$WORK/spec.md" -f "$WORK/fix.diff" "review" \
    </dev/null >"$WORK/c6.out" 2>"$WORK/c6.err"
  RC=$?
  # -o, not -c: the payload is JSON, so both delimiters sit on one line and a
  # line count would report 1 for any number of files.
  BLOCKS="$(grep -o '===== FILE:' "$WORK/c6.out" | wc -l | tr -d ' ')"
  if [ "$RC" != "0" ]; then
    bad "multifile-assembly" "exit $RC"
  elif [ "$BLOCKS" != "2" ]; then
    bad "multifile-assembly" "$BLOCKS file blocks in the payload, expected 2"
  elif ! grep -q '"role": "system"' "$WORK/c6.out"; then
    bad "multifile-assembly" "system message missing from the payload"
  elif ! grep -q 'spec line 419' "$WORK/c6.out" || ! grep -q 'diff line 399' "$WORK/c6.out"; then
    bad "multifile-assembly" "a file was truncated"
  else
    ok "multifile-assembly — 2 blocks, system message, nothing truncated"
  fi
fi

# ── Case 7 — stub provider, end to end ────────────────────────────────────────
#
# Proves the fix did not break the request path, and that a provider answering
# HTTP 200 with an error body is still a failure.

STUB_PID=""
if selected "stub-provider"; then
  if ! command -v python3 >/dev/null 2>&1; then
    skip "stub-provider" "python3 not available"
  else
    cat >"$WORK/stub.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

class Stub(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])) or b"{}")
        # A /slow base URL never answers: it stands in for a provider that
        # accepts the connection and then stops talking. Matched anywhere in
        # the path because the client appends /chat/completions to the base.
        if "/slow" in self.path:
            import time; time.sleep(600)
        text = "STUB-OK model=%s messages=%d" % (body.get("model"), len(body.get("messages", [])))
        out = {"choices": [{"message": {"content": text}, "finish_reason": "stop"}],
               "usage": {"prompt_tokens": 1, "completion_tokens": 1}}
        raw = json.dumps(out).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, *a):
        pass

port = int(sys.argv[1])
HTTPServer(("127.0.0.1", port), Stub).serve_forever()
PY
    PORT=8731
    python3 "$WORK/stub.py" "$PORT" >/dev/null 2>&1 &
    STUB_PID=$!
    # Wait for the listener rather than guessing at a sleep duration.
    READY=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$PORT/chat/completions" -d '{}' 2>/dev/null; then
        READY=1; break
      fi
      sleep 0.5
    done
    if [ "$READY" != "1" ]; then
      skip "stub-provider" "stub did not come up on port $PORT"
    else
      run_bounded 30 env LLM_OPENAI_API_KEY=stub-key bash "$SUT" \
        -p openai --base-url "http://127.0.0.1:$PORT" -m stub-model "hello" \
        </dev/null >"$WORK/c7.out" 2>"$WORK/c7.err"
      RC=$?
      if [ "$RC" != "0" ]; then
        bad "stub-provider" "exit $RC: $(tr '\n' ' ' <"$WORK/c7.err")"
      elif ! grep -q 'STUB-OK model=stub-model' "$WORK/c7.out"; then
        bad "stub-provider" "completion text not returned on stdout"
      else
        ok "stub-provider — round trip on stdout"
      fi

      # A provider that goes quiet must still be bounded by the budget.
      START=$(date +%s)
      run_bounded 60 env LLM_OPENAI_API_KEY=stub-key bash "$SUT" \
        -p openai --base-url "http://127.0.0.1:$PORT/slow" -m stub-model \
        --timeout 6 --retries 0 "hello" </dev/null >/dev/null 2>"$WORK/c8.err"
      RC=$?
      ELAPSED=$(( $(date +%s) - START ))
      if [ "$RC" != "4" ]; then
        bad "stub-provider-silent" "exit $RC after ${ELAPSED}s, expected 4"
      elif [ "$ELAPSED" -gt 25 ]; then
        bad "stub-provider-silent" "took ${ELAPSED}s for a 6s timeout"
      else
        ok "stub-provider-silent — exit 4 in ${ELAPSED}s"
      fi
    fi
    kill -9 "$STUB_PID" 2>/dev/null
    STUB_PID=""
  fi
fi

# ── Case 8 — the watchdog does not outlive the run ────────────────────────────
#
# A guard that survives its own process eventually signals an unrelated pid.

if selected "watchdog-reaped"; then
  BEFORE="$(pgrep -f 'sleep 1[0-9][0-9][0-9]' 2>/dev/null | wc -l | tr -d ' ')"
  run_bounded 30 bash "$SUT" --dry-run --no-stdin -m openai/gpt-4o "hi" \
    </dev/null >/dev/null 2>&1
  sleep 1
  AFTER="$(pgrep -f 'sleep 1[0-9][0-9][0-9]' 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$AFTER" -gt "$BEFORE" ]; then
    bad "watchdog-reaped" "$((AFTER - BEFORE)) watchdog sleep(s) still alive after exit"
  else
    ok "watchdog-reaped"
  fi
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
