#!/usr/bin/env bash
# Every block reason of session-title-sync.sh must tell the agent to end the
# forced continuation turn with no text, so the italic closing summary written
# by conversation-focus is not repeated.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; HOOK="$here/../../../hooks/session-title-sync.sh"
PROMPT="$here/../../../hooks/conversation-focus-prompt.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts" "$T/templates"
echo '{"statuses":{"merge":{"next":"merge it"}}}' >"$T/templates/titles.json"
# Stub of session-title.sh: STUB_MODE=changed|restore drives the two block paths.
cat >"$T/scripts/session-title.sh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  scheduled) exit 1 ;;
  check) if [[ "$STUB_MODE" == changed ]]; then
           echo '{"changed":true,"mode":"free","modeReason":"x","git":{"dirty":0,"ahead":0},"pr":null,"endsWithQuestion":false,"children":{"total":0},"currentTitle":"t","suggested":["merge"],"allowed":["merge"],"root":"/r"}'
         else echo '{"changed":false}'; fi ;;
  restore) echo "🟢 Old title" ;;
esac
STUB
run() { printf '{"session_id":"s1","cwd":"%s","last_assistant_message":"hi"}' "$T" \
  | STUB_MODE="$1" SESSION_TITLE_FORCE=1 SESSION_TITLE_SCRIPT="$T/scripts/session-title.sh" bash "$HOOK"; }
for mode in changed restore; do
  out="$(run "$mode")"
  echo "$out" | jq -e '.decision == "block" and (.reason | test("NO text at all") and test("must not be repeated"))' >/dev/null \
    || { echo "FAIL $mode: $out"; exit 1; }
done
grep -q 'must contain no text at all' "$PROMPT" || { echo "FAIL prompt sentence"; exit 1; }
echo PASS
