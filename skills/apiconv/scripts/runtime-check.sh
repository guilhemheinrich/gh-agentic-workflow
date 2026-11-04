#!/bin/sh
# Runs the READ-ONLY requests of the converted collections with newman (Postman) and bru (Bruno)
# against a live API, and requires both tools to get the same HTTP status for every request.
# Usage (inside the apiconv image): runtime-check.sh <converted-dir> <work-dir> <plan-file> [<environment>]
# <plan-file> holds one `collection-slug|request-name-regex` line per collection (grep -E on the request
# name; blank lines and `#` comments are ignored). The plan must select only requests that do not write:
# this script sends whatever it selects.
# <environment> names the Postman 00-environment-<environment> file and, when the Bruno collections hold
# environments/<environment>.bru, the Bruno environment too (otherwise Bruno runs `staging`).
set -eu
OUT=$1; W=$2; PLAN=$3; T=${4:-}; rm -rf "$W"; mkdir -p "$W"
[ -f "$PLAN" ] || { echo "plan file not found: $PLAN" >&2; exit 2; }
ENV=$(ls "$OUT/postman/00-environment-$T.postman_environment.json" 2>/dev/null || ls "$OUT"/postman/00-environment-*.json)
BENV=staging; [ -n "$T" ] && [ -f "$(ls -d "$OUT"/bruno/*/ | head -1)environments/$T.bru" ] && BENV=$T
grep -vE '^[[:space:]]*(#|$)' "$PLAN" | while IFS='|' read -r slug pick; do
  [ -f "$OUT/postman/$slug.postman_collection.json" ] || { echo "== $slug"; echo "DIFF unknown collection slug in plan"; continue; }
  # Postman: keep only the selected items, then run them in order
  jq --arg p "$pick" '.item |= map(select(.name|test($p)))' "$OUT/postman/$slug.postman_collection.json" > "$W/$slug.json"
  node_modules/.bin/newman run "$W/$slug.json" -e "$ENV" --reporters json --reporter-json-export "$W/$slug.newman.json" >/dev/null 2>&1 || true
  # Bruno: copy the collection, drop the unselected request files, run the folder
  cp -R "$OUT/bruno/$slug" "$W/bru-$slug"
  for f in "$W/bru-$slug"/[0-9]*.bru; do n=$(grep -m1 '^  name: ' "$f" | sed 's/^  name: //'); echo "$n" | grep -qE "$pick" || rm "$f"; done
  (cd "$W/bru-$slug" && /tool/node_modules/.bin/bru run --env "$BENV" --reporter-json "$W/$slug.bru.json" >/dev/null 2>&1 || true)
  jq -r '.run.executions[] | "\(.item.name)\t\(.response.code // "ERR")"' "$W/$slug.newman.json" > "$W/$slug.p.tsv"
  jq -r '(if type=="array" then .[0] else . end).results[] | "\(.request.name // .test.filename // "?")\t\(.response.status // "ERR")"' "$W/$slug.bru.json" > "$W/$slug.b.tsv" 2>/dev/null || echo "bru report unreadable" > "$W/$slug.b.tsv"
  echo "== $slug"; paste "$W/$slug.p.tsv" "$W/$slug.b.tsv" | awk -F'\t' '{ s = ($2==$4) ? "SAME" : "DIFF"; printf "%-4s postman %-4s bruno %-4s  %s\n", s, $2, $4, $1 }'
done
