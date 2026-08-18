#!/usr/bin/env bash
# llm-ask.sh — one-shot, scriptable LLM call over plain HTTP.
#
# The completion text goes to stdout; diagnostics, warnings and usage go to
# stderr. That contract is what makes the script composable:
#
#   git diff main...HEAD | llm-ask.sh -m kimi -s @review-prompt.md "Refute this" > review.md
#
# Requires curl + jq. Portable to bash 3.2 (the /bin/bash macOS still ships).
set -euo pipefail

readonly VERSION="1.0.0"

readonly OPENROUTER_BASE="https://openrouter.ai/api/v1"
readonly OPENAI_BASE="https://api.openai.com/v1"
readonly ANTHROPIC_BASE="https://api.anthropic.com/v1"
readonly ANTHROPIC_API_VERSION="2023-06-01"

# Exit codes, so a caller can branch without parsing stderr.
readonly EX_USAGE=1    # bad invocation
readonly EX_ENV=2      # missing dependency, missing key, no model
readonly EX_API=3      # provider refused, or answered with nothing usable
readonly EX_TIMEOUT=4  # wall-clock budget exhausted

MODEL="${LLM_MODEL:-}"
PROVIDER="${LLM_PROVIDER:-}"
BASE_URL="${LLM_BASE_URL:-}"
SYSTEM=""
TEMPERATURE=""
MAX_TOKENS=""
# 10 minutes. A reasoning-tier model handed 50k+ tokens of review context
# routinely thinks for several minutes before the first byte comes back, and a
# timeout that fires before the answer arrives costs the full input price for
# nothing. Generous by design; lower it for interactive one-liners.
TIMEOUT_S="${LLM_TIMEOUT_S:-600}"
RETRIES="${LLM_RETRIES:-2}"
ALIAS_FILE="${LLM_ALIAS_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/llm-ask/aliases}"
MODELS_CACHE="${LLM_MODELS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/llm-ask/models.json}"
CACHE_TTL_H="${LLM_CACHE_TTL_H:-24}"
FORCE_REFRESH=0
TOP_N=0
RANK_BY="intelligence"
MIN_CONTEXT=0
EXCLUDE_VENDORS=""
VERBOSE="${LLM_VERBOSE:-0}"
OUT_FILE=""
PROMPT_ARG=""
MODEL_FILTER=""
# Newline-delimited rather than an array: `${arr[@]}` on an empty array is an
# unbound-variable error under `set -u` in bash 3.2.
FILE_LIST=""
WARN_CHARS="${LLM_WARN_CHARS:-400000}"
WANT_JSON=0
DRY_RUN=0
DO_DOCTOR=0
DO_PING=0
DO_LIST=0

die() {
  printf 'llm-ask: %s\n' "$1" >&2
  exit "${2:-$EX_USAGE}"
}

warn() { printf 'llm-ask: %s\n' "$1" >&2; }

note() {
  if [ "$VERBOSE" = "1" ]; then printf 'llm-ask: %s\n' "$1" >&2; fi
}

usage() {
  cat <<'EOF'
llm-ask.sh — one-shot LLM call from the command line.

USAGE
  llm-ask.sh [options] [PROMPT]
  … | llm-ask.sh [options] [PROMPT]        # stdin is appended as delimited input
  llm-ask.sh --doctor [--ping]
  llm-ask.sh --list-models [FILTER]
  llm-ask.sh --top 5 [--by coding] [--exclude-vendor anthropic]
  llm-ask.sh -m @top "…"                   # best-scored model, no slug needed

OPTIONS
  -m, --model ID        Model id, or an alias from the alias file. $LLM_MODEL.
  -p, --provider NAME   openrouter | openai | anthropic | custom. Inferred if absent.
  -f, --file PATH       Embed a file as a labelled context block. Repeatable.
      --top N           Rank the N best-scored models, one per vendor, and exit.
      --by METRIC       Ranking metric: intelligence (default) | coding | agentic.
      --min-context K   With --top: require at least K tokens of context window.
      --exclude-vendor V  With --top: drop a vendor (repeatable). Your own lineage.
      --models-refresh  Refetch the model catalogue now, ignoring the 24h TTL.
  -s, --system TEXT     System prompt. Use @path to read it from a file.
      --base-url URL    Override the provider endpoint root (implies custom auth).
  -t, --temperature N   Only sent when set — some reasoning models reject it.
      --max-tokens N    Output cap. Defaults to 4096 for anthropic (required there).
      --timeout S       Wall-clock budget per attempt (default 600).
      --retries N       Retries on 429/5xx/network (default 2, exponential backoff).
  -o, --out FILE        Write the completion to FILE instead of stdout.
      --json            Emit the raw provider response instead of the text.
      --dry-run         Print the resolved route and payload, call nothing.
      --doctor          Report dependencies, keys and env hazards. --ping to auth-test.
      --list-models     List OpenRouter model ids, optionally filtered.
  -v, --verbose         Token usage and routing decisions on stderr. $LLM_VERBOSE=1.
  -h, --help            This text.       --version

EXIT
  0 ok · 1 usage · 2 environment · 3 API error · 4 timeout
EOF
}

# `@path` reads a file, anything else is a literal.
read_arg_or_file() {
  case "$1" in
    @*)
      local f="${1#@}"
      [ -r "$f" ] || die "cannot read $f" "$EX_USAGE"
      cat -- "$f"
      ;;
    *) printf '%s' "$1" ;;
  esac
}

# Fails loudly on `-m` with nothing after it, instead of letting `shift 2` abort.
need_value() {
  [ $# -ge 2 ] && [ -n "${2:-}" ] || die "option $1 requires a value" "$EX_USAGE"
}

# There is no file-upload concept in a chat/completions call: "attaching" a file
# means embedding its text, labelled so the model can cite it back by path.
add_file() {
  local p="$1"
  [ -d "$p" ] && die "-f takes a file, not a directory: $p" "$EX_USAGE"
  [ -r "$p" ] || die "cannot read -f $p" "$EX_USAGE"
  FILE_LIST="${FILE_LIST}${p}
"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -m|--model)       need_value "$@"; MODEL="$2"; shift 2 ;;
    -p|--provider)    need_value "$@"; PROVIDER="$2"; shift 2 ;;
    -f|--file)        need_value "$@"; add_file "$2"; shift 2 ;;
    --top)            need_value "$@"; TOP_N="$2"; shift 2 ;;
    --by)             need_value "$@"; RANK_BY="$2"; shift 2 ;;
    --min-context)    need_value "$@"; MIN_CONTEXT="$2"; shift 2 ;;
    --exclude-vendor) need_value "$@"; EXCLUDE_VENDORS="${EXCLUDE_VENDORS}${2}
"; shift 2 ;;
    --models-refresh) FORCE_REFRESH=1; shift ;;
    -s|--system)      need_value "$@"; SYSTEM="$(read_arg_or_file "$2")"; shift 2 ;;
    --base-url)       need_value "$@"; BASE_URL="$2"; shift 2 ;;
    -t|--temperature) need_value "$@"; TEMPERATURE="$2"; shift 2 ;;
    --max-tokens)     need_value "$@"; MAX_TOKENS="$2"; shift 2 ;;
    --timeout)        need_value "$@"; TIMEOUT_S="$2"; shift 2 ;;
    --retries)        need_value "$@"; RETRIES="$2"; shift 2 ;;
    -o|--out)         need_value "$@"; OUT_FILE="$2"; shift 2 ;;
    --json)           WANT_JSON=1; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    --doctor)         DO_DOCTOR=1; shift ;;
    --ping)           DO_PING=1; shift ;;
    --list-models)    DO_LIST=1; shift ;;
    -v|--verbose)     VERBOSE=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    --version)        printf '%s\n' "$VERSION"; exit 0 ;;
    --)               shift; PROMPT_ARG="${*:-}"; break ;;
    -*)               die "unknown option: $1" "$EX_USAGE" ;;
    *)
      if [ "$DO_LIST" = "1" ]; then MODEL_FILTER="$1"; else PROMPT_ARG="$1"; fi
      shift
      ;;
  esac
done

command -v curl >/dev/null 2>&1 || die "curl is required" "$EX_ENV"
command -v jq   >/dev/null 2>&1 || die "jq is required (brew install jq)" "$EX_ENV"

# ── Routing ───────────────────────────────────────────────────────────────────

# Aliases keep volatile model slugs out of the script and out of muscle memory.
resolve_alias() {
  local name="$1"
  if [ ! -r "$ALIAS_FILE" ]; then printf '%s' "$name"; return; fi
  local hit
  hit="$(awk -v k="$name" '
    /^[[:space:]]*#/ { next }
    index($0, "=") == 0 { next }
    {
      key = substr($0, 1, index($0, "=") - 1)
      val = substr($0, index($0, "=") + 1)
      sub(/#.*$/, "", val)          # trailing comment is not part of the slug
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
      if (key == k) { print val; exit }
    }' "$ALIAS_FILE")"
  if [ -n "$hit" ]; then
    note "alias $name -> $hit"
    printf '%s' "$hit"
  else
    printf '%s' "$name"
  fi
}

infer_provider() {
  case "$1" in
    */*)       printf 'openrouter' ;;  # a namespaced slug is a gateway slug
    claude-*)  printf 'anthropic' ;;
    "")        printf 'openrouter' ;;
    *)         printf 'openai' ;;
  esac
}

# LLM_-prefixed names win, so a key can be given to this script without
# disturbing whatever else on the machine reads the canonical name.
provider_key() {
  case "$1" in
    openrouter) printf '%s' "${LLM_OPENROUTER_API_KEY:-${OPENROUTER_API_KEY:-}}" ;;
    openai)     printf '%s' "${LLM_OPENAI_API_KEY:-${OPENAI_API_KEY:-}}" ;;
    anthropic)  printf '%s' "${LLM_ANTHROPIC_API_KEY:-${ANTHROPIC_API_KEY:-}}" ;;
    custom)     printf '%s' "${LLM_API_KEY:-}" ;;
    *)          printf '' ;;
  esac
}

key_var_name() {
  case "$1" in
    openrouter) printf 'OPENROUTER_API_KEY' ;;
    openai)     printf 'OPENAI_API_KEY' ;;
    anthropic)  printf 'ANTHROPIC_API_KEY' ;;
    custom)     printf 'LLM_API_KEY' ;;
  esac
}

# Deliberately never reads OPENAI_BASE_URL / ANTHROPIC_BASE_URL: those are
# load-bearing for other tools on the same machine (Claude Code exports
# ANTHROPIC_BASE_URL), and silently inheriting them reroutes the wrong traffic.
provider_base() {
  if [ -n "$BASE_URL" ]; then printf '%s' "${BASE_URL%/}"; return; fi
  case "$1" in
    openrouter) printf '%s' "$OPENROUTER_BASE" ;;
    openai)     printf '%s' "$OPENAI_BASE" ;;
    anthropic)  printf '%s' "$ANTHROPIC_BASE" ;;
    custom)     die "provider 'custom' needs --base-url or LLM_BASE_URL" "$EX_USAGE" ;;
    *)          die "unknown provider: $1" "$EX_USAGE" ;;
  esac
}

# ── Transport ─────────────────────────────────────────────────────────────────

CFG_FILE=""
PAYLOAD_FILE=""
BODY_FILE=""
PROMPT_FILE=""

cleanup() {
  [ -n "$CFG_FILE" ] && rm -f "$CFG_FILE"
  [ -n "$PAYLOAD_FILE" ] && rm -f "$PAYLOAD_FILE"
  [ -n "$BODY_FILE" ] && rm -f "$BODY_FILE"
  [ -n "$PROMPT_FILE" ] && rm -f "$PROMPT_FILE"
  return 0
}
trap cleanup EXIT

# Headers go through a 0600 config file rather than argv: process arguments are
# world-readable on both macOS and Linux, and the key is in there.
write_curl_config() {
  local provider="$1" key="$2"
  CFG_FILE="$(mktemp)"
  chmod 600 "$CFG_FILE"
  {
    printf 'header = "Content-Type: application/json"\n'
    case "$provider" in
      anthropic)
        printf 'header = "x-api-key: %s"\n' "$key"
        printf 'header = "anthropic-version: %s"\n' "$ANTHROPIC_API_VERSION"
        ;;
      *)
        printf 'header = "Authorization: Bearer %s"\n' "$key"
        ;;
    esac
    if [ "$provider" = "openrouter" ]; then
      printf 'header = "X-Title: llm-ask"\n'
    fi
  } >"$CFG_FILE"
}

# Sets $HTTP_STATUS, body lands in $BODY_FILE. Retries 429/5xx/network.
#
# The status is returned through a global rather than stdout on purpose: a
# command substitution would run this in a subshell, losing both the temp-file
# path and the ability to exit the script from `die`.
HTTP_STATUS=""
http_post() {
  local url="$1"
  local attempt=0 status curl_rc backoff
  while :; do
    set +e
    status="$(curl -sS \
      --config "$CFG_FILE" \
      --data-binary "@$PAYLOAD_FILE" \
      --max-time "$TIMEOUT_S" \
      --output "$BODY_FILE" \
      --write-out '%{http_code}' \
      "$url")"
    curl_rc=$?
    set -e

    if [ "$curl_rc" -eq 28 ]; then
      die "timeout after ${TIMEOUT_S}s (raise --timeout)" "$EX_TIMEOUT"
    fi

    if [ "$curl_rc" -eq 0 ]; then
      case "$status" in
        429|5??) : ;;                        # transient, fall through to retry
        *) HTTP_STATUS="$status"; return 0 ;;
      esac
    fi

    if [ "$attempt" -ge "$RETRIES" ]; then
      if [ "$curl_rc" -ne 0 ]; then
        die "curl failed (exit $curl_rc) after $((attempt + 1)) attempt(s)" "$EX_API"
      fi
      HTTP_STATUS="$status"
      return 0
    fi

    backoff=$((2 ** attempt))
    warn "HTTP ${status:-network error} — retrying in ${backoff}s ($((attempt + 1))/$RETRIES)"
    sleep "$backoff"
    attempt=$((attempt + 1))
    : >"$BODY_FILE"
  done
}

# ── Subcommands ───────────────────────────────────────────────────────────────

do_list_models() {
  ensure_models_cache || die "cannot list models without the catalogue" "$EX_ENV"
  if [ -n "$MODEL_FILTER" ]; then
    jq -r --arg f "$MODEL_FILTER" '.models[] | select(.id | ascii_downcase | contains($f | ascii_downcase)) | .id' "$MODELS_CACHE"
  else
    jq -r '.models[].id' "$MODELS_CACHE"
  fi
}

key_state() {
  local provider="$1" key
  key="$(provider_key "$provider")"
  if [ -n "$key" ]; then printf 'set (%s chars)' "${#key}"; else printf 'missing'; fi
}

# ── Model catalogue cache ─────────────────────────────────────────────────────
#
# OpenRouter publishes prices, context windows and third-party benchmark scores
# on a keyless public endpoint. Prices move — three models changed rate within an
# hour during development — so nothing is hardcoded here: the catalogue is
# fetched, distilled and cached, then refreshed when it goes stale.
#
# The cache lives under XDG cache, not in the skill directory: the skill is
# deployed with `cp -Rf` to several agent targets, so a cache inside it would be
# clobbered on every install and diverge per copy. Override with LLM_MODELS_CACHE.

cache_age_hours() {
  local epoch now
  if [ ! -r "$MODELS_CACHE" ]; then printf '%s' "-1"; return; fi
  epoch="$(jq -r '.fetched_epoch // 0' "$MODELS_CACHE" 2>/dev/null || echo 0)"
  case "$epoch" in ''|*[!0-9]*) printf '%s' "-1"; return ;; esac
  if [ "$epoch" -le 0 ]; then printf '%s' "-1"; return; fi
  now="$(date -u +%s)"
  printf '%s' "$(( (now - epoch) / 3600 ))"
}

# Distils the ~675KB catalogue down to what a review workflow actually queries.
refresh_models_cache() {
  local raw
  mkdir -p "$(dirname "$MODELS_CACHE")"
  raw="$(mktemp)"
  if ! curl -sS --max-time 30 "$OPENROUTER_BASE/models" -o "$raw" 2>/dev/null; then
    rm -f "$raw"; return 1
  fi
  if ! jq -e '.data' "$raw" >/dev/null 2>&1; then
    rm -f "$raw"; return 1
  fi
  jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson epoch "$(date -u +%s)" '{
    fetched_at: $now,
    fetched_epoch: $epoch,
    source: "https://openrouter.ai/api/v1/models",
    count: (.data | length),
    models: [ .data[] | {
      id,
      ctx: .context_length,
      in:  ((.pricing.prompt     // "0") | tonumber * 1000000),
      out: ((.pricing.completion // "0") | tonumber * 1000000),
      ii:  .benchmarks.artificial_analysis.intelligence_index,
      ci:  .benchmarks.artificial_analysis.coding_index,
      ag:  .benchmarks.artificial_analysis.agentic_index,
      reasoning: ((.supported_parameters // []) | index("reasoning") != null)
    } ]
  }' "$raw" >"$MODELS_CACHE"
  rm -f "$raw"
  note "catalogue refreshed: $(jq -r .count "$MODELS_CACHE") models -> $MODELS_CACHE"
  return 0
}

# Refreshes when missing, stale past the TTL, or forced. Never fatal by itself:
# a stale catalogue still prices a call, and no catalogue only costs the estimate.
ensure_models_cache() {
  local age
  age="$(cache_age_hours)"
  if [ "$FORCE_REFRESH" != "1" ] && [ "$age" -ge 0 ] && [ "$age" -lt "$CACHE_TTL_H" ]; then
    return 0
  fi
  if refresh_models_cache; then
    return 0
  fi
  if [ -r "$MODELS_CACHE" ]; then
    warn "catalogue refresh failed; using the copy from $(jq -r .fetched_at "$MODELS_CACHE") (${age}h old)"
    return 0
  fi
  note "no catalogue and refresh failed; price estimate unavailable"
  return 1
}


# ── Picking a reviewer without knowing model names ────────────────────────────
#
# OpenRouter republishes third-party benchmark scores per model under
# .benchmarks.artificial_analysis: intelligence_index, coding_index,
# agentic_index. That is what makes "give me the smart models" answerable without
# hardcoding a single slug.
#
# Ranking rules, all deliberate:
#   · one model per vendor — an adversarial panel needs distinct lineages, not
#     three checkpoints of the same family;
#   · `:batch` variants are dropped: the cheaper rate comes with batch delivery,
#     which a review loop does not want;
#   · `:free` and image/audio variants are dropped: rate-limited or off-task;
#   · unscored models are dropped rather than ranked last — silence beats a guess.
metric_key() {
  case "$RANK_BY" in
    intelligence) printf %s ii ;;
    coding)       printf %s ci ;;
    agentic)      printf %s ag ;;
    *) die "--by takes intelligence | coding | agentic (got: $RANK_BY)" "$EX_USAGE" ;;
  esac
}

rank_models() {
  local metric_key limit
  metric_key="$(metric_key)"
  limit="$1"
  jq -r \
    --arg k "$metric_key" \
    --argjson minctx "${MIN_CONTEXT:-0}" \
    --argjson limit "$limit" \
    --arg excl "$EXCLUDE_VENDORS" '
    ($excl | split("\n") | map(select(length > 0))) as $blocked
    | [ .models[]
        | select(.[$k] != null)
        | select(.ctx >= $minctx)
        | select(.id | test(":batch|:free|:extended") | not)
        | select(.id | test("image|audio|tts|whisper|embed") | not)
        | select(.id | startswith("~") | not)
        | . + {vendor: (.id | split("/")[0])}
        | select(.vendor as $v | ($blocked | index($v)) == null)
      ]
    | sort_by(-.[$k])
    | group_by(.vendor) | map(sort_by(-.[$k])[0])   # best per vendor
    | sort_by(-.[$k])
    | .[:$limit][]
    | [.id, (.[$k] | tostring), (.in | tostring), (.out | tostring), (.ctx | tostring)]
    | @tsv' "$MODELS_CACHE"
}

do_top() {
  metric_key >/dev/null
  ensure_models_cache || die "cannot rank without the model catalogue" "$EX_ENV"
  printf 'top %s by %s_index — one per vendor, from %s\n\n' \
    "$TOP_N" "$RANK_BY" "$(jq -r .fetched_at "$MODELS_CACHE")"
  printf '%-38s %6s %9s %9s %10s\n' MODEL SCORE 'IN $/M' 'OUT $/M' CONTEXT
  rank_models "$TOP_N" | while IFS="$(printf '\t')" read -r id score pin pout ctx; do
    printf '%-38s %6s %9s %9s %10s\n' "$id" "$score" "$pin" "$pout" "$ctx"
  done
}

# `@top` and `@top:N` resolve against the ranking, so a script can name a
# reviewer by capability instead of by slug.
resolve_selector() {
  local sel="$1" nth id
  nth="${sel#@top}"
  nth="${nth#:}"
  [ -n "$nth" ] || nth=1
  case "$nth" in ''|*[!0-9]*) die "bad selector '$sel' — use @top or @top:N" "$EX_USAGE" ;; esac
  ensure_models_cache || die "cannot resolve $sel without the model catalogue" "$EX_ENV"
  id="$(rank_models "$nth" | sed -n "${nth}p" | cut -f1)"
  [ -n "$id" ] || die "$sel resolved to nothing (try --top $nth to see the ranking)" "$EX_ENV"
  note "$sel -> $id (by ${RANK_BY}_index)"
  printf '%s' "$id"
}

# "<prompt $/Mtok> <completion $/Mtok> <context window>" for one model, or empty.
model_pricing() {
  if [ ! -r "$MODELS_CACHE" ]; then return 0; fi
  jq -r --arg m "$1" '.models[] | select(.id == $m) | "\(.in) \(.out) \(.ctx)"' \
    "$MODELS_CACHE" 2>/dev/null | head -n1
}

# Turns the prompt size into money and checks it against the context window.
# Prices arrive from the catalogue already expressed per MILLION tokens.
# Estimate only: 4 chars/token is optimistic for source code, so treat the
# number as a floor and expect 20% more on a diff-heavy prompt.
report_estimate() {
  local chars="$1" pricing="$2"
  local tokens=$((chars / 4))
  if [ -z "$pricing" ]; then
    printf 'prompt   : %s chars (~%s tokens, estimate)\n' "$chars" "$tokens"
    return 0
  fi
  printf '%s' "$pricing" | awk -v chars="$chars" -v maxtok="${MAX_TOKENS:-}" '{
    pin = $1 + 0; pout = $2 + 0; ctx = $3 + 0
    tin = int(chars / 4)
    printf "prompt   : %d chars (~%d tokens, estimate)\n", chars, tin
    printf "cost     : ~$%.4f in (@ $%.2f/M)", tin * pin / 1000000, pin
    if (maxtok != "") printf " + up to $%.4f out (%d tok @ $%.2f/M)", maxtok * pout / 1000000, maxtok, pout
    printf "\n"
    if (ctx > 0) {
      printf "context  : %d of %d tokens (%.1f%%)\n", tin, ctx, (tin * 100.0) / ctx
      if (tin > ctx) printf "WARNING  : prompt exceeds this model context window\n"
    }
  }'
}

do_doctor() {
  printf 'llm-ask %s\n' "$VERSION"
  printf '  bash            %s\n' "${BASH_VERSION:-unknown}"
  printf '  curl            %s\n' "$(command -v curl || echo MISSING)"
  printf '  jq              %s\n' "$(command -v jq || echo MISSING)"
  printf '\n  keys (values never printed)\n'
  printf '    openrouter    %s\n' "$(key_state openrouter)"
  printf '    openai        %s\n' "$(key_state openai)"
  printf '    anthropic     %s\n' "$(key_state anthropic)"
  printf '\n  defaults\n'
  printf '    LLM_MODEL     %s\n' "${LLM_MODEL:-<unset>}"
  printf '    LLM_PROVIDER  %s\n' "${LLM_PROVIDER:-<inferred from model>}"
  printf '    LLM_BASE_URL  %s\n' "${LLM_BASE_URL:-<provider default>}"
  printf '    alias file    %s%s\n' "$ALIAS_FILE" \
    "$([ -r "$ALIAS_FILE" ] && printf ' (%s entries)' "$(grep -cE '^[^#]*=' "$ALIAS_FILE" 2>/dev/null || echo 0)" || printf ' (absent)')"
  printf '\n  model catalogue\n'
  printf '    cache       %s\n' "$MODELS_CACHE"
  if [ -r "$MODELS_CACHE" ]; then
    printf '    age         %sh (TTL %sh, refetched past that)\n' "$(cache_age_hours)" "$CACHE_TTL_H"
    printf '    models      %s, fetched %s\n' "$(jq -r .count "$MODELS_CACHE")" "$(jq -r .fetched_at "$MODELS_CACHE")"
    printf '    benchmarked %s scored by artificial_analysis\n' "$(jq -r '[.models[]|select(.ii!=null)]|length' "$MODELS_CACHE")"
  else
    printf '    age         absent — fetched on first use\n'
  fi

  if [ -n "${ANTHROPIC_BASE_URL:-}" ] || [ -n "${OPENAI_BASE_URL:-}" ]; then
    printf '\n'
    warn "provider base-URL vars are set in this environment and are IGNORED on purpose:"
    [ -n "${ANTHROPIC_BASE_URL:-}" ] && warn "  ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL} (Claude Code owns this one)"
    [ -n "${OPENAI_BASE_URL:-}" ] && warn "  OPENAI_BASE_URL=${OPENAI_BASE_URL}"
    warn "  use --base-url or LLM_BASE_URL to reroute this script only."
  fi

  if [ "$DO_PING" = "1" ]; then
    [ -n "$MODEL" ] || die "--ping needs -m MODEL" "$EX_USAGE"
    printf '\n  ping\n'
    MAX_TOKENS=1
    PROMPT_ARG="ping"
    return 1  # signal the caller to run a real (tiny) call
  fi
  return 0
}

if [ "$TOP_N" -gt 0 ] 2>/dev/null; then do_top; exit 0; fi
if [ "$FORCE_REFRESH" = "1" ] && [ -z "$MODEL" ] && [ "$DO_DOCTOR" != "1" ]; then
  refresh_models_cache || die "catalogue refresh failed" "$EX_API"
  printf '%s models cached at %s\n' "$(jq -r .count "$MODELS_CACHE")" "$MODELS_CACHE"
  exit 0
fi
if [ "$DO_LIST" = "1" ]; then do_list_models; exit 0; fi

if [ "$DO_DOCTOR" = "1" ]; then
  if do_doctor; then exit 0; fi
  CFG_FILE=""  # doctor may have allocated one; force a clean rebuild below
fi

# ── Resolve the route ─────────────────────────────────────────────────────────

[ -n "$MODEL" ] || die "no model: pass -m ID or set LLM_MODEL" "$EX_ENV"
case "$MODEL" in @*) MODEL="$(resolve_selector "$MODEL")" ;; esac
MODEL="$(resolve_alias "$MODEL")"
[ -n "$PROVIDER" ] || PROVIDER="$(infer_provider "$MODEL")"
API_BASE="$(provider_base "$PROVIDER")"
note "provider=$PROVIDER model=$MODEL base=$API_BASE"

# ── Assemble the prompt ───────────────────────────────────────────────────────

STDIN_DATA=""
if [ ! -t 0 ]; then STDIN_DATA="$(cat || true)"; fi

# Fixed order — instruction, then files, then stdin — so the same invocation
# always produces the same bytes. Every block is delimited: the instruction must
# not blur into the payload, and the model needs a path to cite findings against.
PROMPT_FILE="$(mktemp)"
: >"$PROMPT_FILE"

if [ -n "$PROMPT_ARG" ]; then
  printf '%s\n' "$PROMPT_ARG" >>"$PROMPT_FILE"
fi

if [ -n "$FILE_LIST" ]; then
  printf '%s' "$FILE_LIST" | while IFS= read -r path; do
    [ -n "$path" ] || continue
    printf '\n===== FILE: %s =====\n' "$path"
    cat -- "$path"
    printf '\n===== END FILE: %s =====\n' "$path"
  done >>"$PROMPT_FILE"
fi

if [ -n "$STDIN_DATA" ]; then
  if [ -n "$PROMPT_ARG" ] || [ -n "$FILE_LIST" ]; then
    printf '\n----- BEGIN INPUT -----\n%s\n----- END INPUT -----\n' "$STDIN_DATA" >>"$PROMPT_FILE"
  else
    printf '%s\n' "$STDIN_DATA" >>"$PROMPT_FILE"
  fi
fi

if [ ! -s "$PROMPT_FILE" ]; then
  usage >&2
  die "no prompt: pass it as an argument, with -f, or on stdin" "$EX_USAGE"
fi

PROMPT_CHARS="$(wc -c <"$PROMPT_FILE" | tr -d ' ')"
note "prompt: $PROMPT_CHARS chars from $(printf '%s' "$FILE_LIST" | grep -c . || true) file(s)"
if [ "$PROMPT_CHARS" -gt "$WARN_CHARS" ]; then
  warn "prompt is $PROMPT_CHARS chars (~$((PROMPT_CHARS / 4)) tokens) — verify it fits the model's context window"
fi

# ── Build the payload ─────────────────────────────────────────────────────────
#
# jq builds the JSON, always. Interpolating a diff into a heredoc produces
# invalid JSON the first time the input contains a quote, a backslash or a
# newline — which for a diff is immediately.

PAYLOAD_FILE="$(mktemp)"

case "$PROVIDER" in
  anthropic)
    ENDPOINT="/messages"
    [ -n "$MAX_TOKENS" ] || MAX_TOKENS=4096
    jq -n --arg model "$MODEL" --argjson max_tokens "$MAX_TOKENS" --rawfile prompt "$PROMPT_FILE" \
      '{model: $model, max_tokens: $max_tokens, messages: [{role: "user", content: $prompt}]}' \
      >"$PAYLOAD_FILE"
    if [ -n "$SYSTEM" ]; then
      jq --arg s "$SYSTEM" '.system = $s' "$PAYLOAD_FILE" >"$PAYLOAD_FILE.tmp" && mv "$PAYLOAD_FILE.tmp" "$PAYLOAD_FILE"
    fi
    ;;
  *)
    ENDPOINT="/chat/completions"
    jq -n --arg model "$MODEL" --rawfile prompt "$PROMPT_FILE" \
      '{model: $model, messages: [{role: "user", content: $prompt}]}' \
      >"$PAYLOAD_FILE"
    if [ -n "$SYSTEM" ]; then
      jq --arg s "$SYSTEM" '.messages = ([{role: "system", content: $s}] + .messages)' \
        "$PAYLOAD_FILE" >"$PAYLOAD_FILE.tmp" && mv "$PAYLOAD_FILE.tmp" "$PAYLOAD_FILE"
    fi
    if [ -n "$MAX_TOKENS" ]; then
      jq --argjson n "$MAX_TOKENS" '.max_tokens = $n' "$PAYLOAD_FILE" >"$PAYLOAD_FILE.tmp" && mv "$PAYLOAD_FILE.tmp" "$PAYLOAD_FILE"
    fi
    ;;
esac

# Only sent when asked: reasoning-tier models reject a non-default temperature.
if [ -n "$TEMPERATURE" ]; then
  jq --argjson t "$TEMPERATURE" '.temperature = $t' "$PAYLOAD_FILE" >"$PAYLOAD_FILE.tmp" && mv "$PAYLOAD_FILE.tmp" "$PAYLOAD_FILE"
fi

URL="${API_BASE}${ENDPOINT}"

if [ "$DRY_RUN" = "1" ]; then
  printf 'provider : %s\n' "$PROVIDER"
  printf 'model    : %s\n' "$MODEL"
  printf 'url      : %s\n' "$URL"
  printf 'key      : %s\n' "$(key_state "$PROVIDER")"
  printf 'timeout  : %ss per attempt, %s retr(y|ies)\n' "$TIMEOUT_S" "$RETRIES"
  DRY_PRICING=""
  if [ "$PROVIDER" = "openrouter" ]; then ensure_models_cache || true; DRY_PRICING="$(model_pricing "$MODEL" || true)"; fi
  report_estimate "$PROMPT_CHARS" "$DRY_PRICING"
  printf 'payload  :\n'
  jq . "$PAYLOAD_FILE"
  exit 0
fi

# ── Call ──────────────────────────────────────────────────────────────────────

API_KEY="$(provider_key "$PROVIDER")"
if [ -z "$API_KEY" ]; then
  die "no API key for $PROVIDER: export $(key_var_name "$PROVIDER") (or LLM_$(key_var_name "$PROVIDER"))" "$EX_ENV"
fi

write_curl_config "$PROVIDER" "$API_KEY"
BODY_FILE="$(mktemp)"
http_post "$URL"
STATUS="$HTTP_STATUS"

# A JSON error object can arrive with HTTP 200 — gateways in particular do this,
# so the status alone is not a verdict.
API_ERROR="$(jq -r '(.error.message // .error // empty) | tostring' "$BODY_FILE" 2>/dev/null || true)"

if [ "$STATUS" != "200" ] || [ -n "$API_ERROR" ]; then
  case "$STATUS" in
    400) warn "HTTP 400 — malformed request or a parameter this model rejects (often temperature)" ;;
    401|403) warn "HTTP $STATUS — key rejected: wrong value, wrong provider, or no access to $MODEL" ;;
    402) warn "HTTP 402 — out of credits on the account behind that key" ;;
    404) warn "HTTP 404 — unknown model id '$MODEL' (check with --list-models)" ;;
    413) warn "HTTP 413 — prompt exceeds the model context window" ;;
    429) warn "HTTP 429 — rate limited after $RETRIES retries" ;;
    5??) warn "HTTP $STATUS — provider-side failure after $RETRIES retries" ;;
  esac
  [ -n "$API_ERROR" ] && warn "provider said: $API_ERROR"
  if [ "$VERBOSE" = "1" ]; then jq . "$BODY_FILE" >&2 2>/dev/null || cat "$BODY_FILE" >&2; fi
  die "request failed (HTTP ${STATUS})" "$EX_API"
fi

if [ "$WANT_JSON" = "1" ]; then
  jq . "$BODY_FILE"
  exit 0
fi

case "$PROVIDER" in
  anthropic)
    # Extended thinking puts non-text blocks in .content; keep only text ones.
    TEXT="$(jq -r '[.content[]? | select(.type == "text") | .text] | join("")' "$BODY_FILE")"
    FINISH="$(jq -r '.stop_reason // "" | tostring' "$BODY_FILE")"
    ;;
  *)
    TEXT="$(jq -r '.choices[0].message.content // ""' "$BODY_FILE")"
    FINISH="$(jq -r '.choices[0].finish_reason // "" | tostring' "$BODY_FILE")"
    ;;
esac

if [ "$VERBOSE" = "1" ]; then
  note "usage: $(jq -r '(.usage // {}) | "\(.prompt_tokens // .input_tokens // 0) in / \(.completion_tokens // .output_tokens // 0) out"' "$BODY_FILE")"
  note "finish_reason: ${FINISH:-<none>}"
fi

# An empty completion is a failure, not a short answer. Refusals, content
# filters and zero-token replies all land here.
if [ -z "$TEXT" ]; then
  die "empty completion (finish_reason=${FINISH:-unknown}); re-run with --json to see the body" "$EX_API"
fi

case "$FINISH" in
  length|max_tokens) warn "answer truncated (finish_reason=$FINISH) — raise --max-tokens" ;;
  content_filter)    warn "answer was filtered by the provider (finish_reason=$FINISH)" ;;
esac

if [ -n "$OUT_FILE" ]; then
  printf '%s\n' "$TEXT" >"$OUT_FILE"
  note "wrote $(printf '%s' "$TEXT" | wc -c | tr -d ' ') bytes to $OUT_FILE"
else
  printf '%s\n' "$TEXT"
fi
