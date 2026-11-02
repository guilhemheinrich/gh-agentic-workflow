#!/usr/bin/env bash
# diff.test.sh — every transition kind, its exact text and its wake flags.
. "$(dirname "$0")/lib.sh"
lib() { bash -c ". '$SKILL_DIR/scripts/lib/config.sh'; . '$SKILL_DIR/scripts/lib/diff.sh'; $1"; }

URL="https://bitbucket.org/septeo-immobilier/modelo-bill-e/pull-requests/229"
base() { jq -n --arg url "$URL" '{repo:"septeo-immobilier/modelo-bill-e", pr:229, state:"OPEN",
  head:"abc123def456", dest_head:"def456", title:"t", url:$url, participants:{},
  statuses:{"pr-analysis":{name:"PR analysis",state:"INPROGRESS"}},
  comments:{"4500":{author:"Guilhem Heinrich",path:null,line:null,deleted:false}},
  conflict:false, fetched_at:"x"}'; }
SUB='{"repo":"septeo-immobilier/modelo-bill-e","pr":229,"session":"s1","own_heads":["abc123def4567890aaaa"],"ignored_comments":["4600"]}'

base >"$WORK/old.json"
diff_with() { # JQ_EDIT
  base | jq "$1" >"$WORK/new.json"
  lib "diff_snapshots '$WORK/old.json' '$WORK/new.json' '$SUB'"
}
one() { # NAME JQ_EDIT KIND WAKE URGENT TEXT
  local out got want
  out="$(diff_with "$2")"
  got="$(printf '%s' "$out" | jq -sc 'map([.kind,.wake,.urgent,.text])')"
  want="$(jq -cn --arg k "$3" --argjson w "$4" --argjson u "$5" --arg t "$6" '[[$k,$w,$u,$t]]')"
  check "$1" '[ "$got" = "$want" ]' "got=$got want=$want"
}

one "pipeline success wakes" '.statuses["pr-analysis"].state = "SUCCESSFUL"' status true false \
  "modelo-bill-e#229 pipeline \"PR analysis\" INPROGRESS→SUCCESSFUL · $URL"
one "pipeline stop wakes" '.statuses["pr-analysis"].state = "STOPPED"' status true false \
  "modelo-bill-e#229 pipeline \"PR analysis\" INPROGRESS→STOPPED · $URL"
one "pipeline failure wakes urgently" '.statuses["pr-analysis"].state = "FAILED"' status true true \
  "modelo-bill-e#229 pipeline \"PR analysis\" INPROGRESS→FAILED · $URL"
one "new running pipeline does not wake" '.statuses.build = {name:"build",state:"INPROGRESS"}' status false false \
  "modelo-bill-e#229 pipeline \"build\" new→INPROGRESS · $URL"
one "inline comment wakes" '.comments["4521"] = {author:"Julien Boutet",path:"src/a.ts",line:42,deleted:false}' comment true false \
  "modelo-bill-e#229 comment by Julien Boutet on src/a.ts:42 (id 4521)"
one "general comment wakes" '.comments["4522"] = {author:"Guilhem Heinrich",path:null,line:null,deleted:false}' comment true false \
  "modelo-bill-e#229 comment by Guilhem Heinrich (id 4522)"
one "approval wakes" '.participants["acc-1"] = {name:"Julien Boutet",state:"approved"}' review true false \
  "modelo-bill-e#229 Julien Boutet approved"
one "changes requested wakes" '.participants["acc-1"] = {name:"Julien Boutet",state:"changes_requested"}' review true false \
  "modelo-bill-e#229 Julien Boutet requested changes"
one "conflict appears" '.conflict = true' conflict true false "modelo-bill-e#229 merge conflict appeared"
# A new head also makes every status "new" (statuses belong to a commit), so
# head cases look at the head line and at wake lines only.
out="$(diff_with '.head = "999888777666"')"
check "foreign head wakes" '[ "$(printf "%s" "$out" | jq -r "select(.kind == \"head\") | [.wake, .text] | @tsv")" = "$(printf "true\tmodelo-bill-e#229 new commit 9998887 pushed outside this session")" ]' "$out"
one "merge wakes" '.state = "MERGED"' state true false "modelo-bill-e#229 merged"
one "decline wakes" '.state = "DECLINED"' state true false "modelo-bill-e#229 declined"
one "supersede wakes" '.state = "SUPERSEDED"' state true false "modelo-bill-e#229 superseded"

# Withdrawals and clearing, from a richer old snapshot.
base | jq '.participants["acc-1"] = {name:"Julien Boutet",state:"approved"} | .conflict = true' >"$WORK/old.json"
one "withdrawn approval wakes" '.conflict = true' review true false "modelo-bill-e#229 Julien Boutet withdrew approval"
one "conflict cleared" '.participants["acc-1"] = {name:"Julien Boutet",state:"approved"}' conflict true false \
  "modelo-bill-e#229 merge conflict cleared"
base >"$WORK/old.json"

out="$(diff_with '.comments["4600"] = {author:"Guilhem Heinrich",path:null,line:null,deleted:false}')"
check "ignored comment yields nothing" '[ -z "$out" ]' "$out"
out="$(diff_with '.comments["4601"] = {author:"X",path:null,line:null,deleted:true}')"
check "deleted new comment yields nothing" '[ -z "$out" ]' "$out"
out="$(diff_with '.head = "abc123def456"')"
check "unchanged head yields nothing" '[ -z "$out" ]' "$out"
base >"$WORK/old.json"; jq '.head = "000000000000"' "$WORK/old.json" >"$WORK/o2.json"; mv "$WORK/o2.json" "$WORK/old.json"
out="$(diff_with '.head = "abc123def456"')"
check "own head (short hash vs full hash) wakes nobody" '[ -z "$(printf "%s" "$out" | jq -c "select(.wake)")" ]' "$out"
base >"$WORK/old.json"
out="$(diff_with '.comments["4500"].author = "Guilhem Heinrich"')"
check "comment edit yields nothing" '[ -z "$out" ]' "$out"
out="$(base >"$WORK/new.json"; lib "diff_snapshots '$WORK/missing.json' '$WORK/new.json' '$SUB'")"
check "missing old snapshot is a silent baseline" '[ -z "$out" ]' "$out"

summary
