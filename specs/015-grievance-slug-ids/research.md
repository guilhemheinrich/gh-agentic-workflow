# Research — Merge-safe grievance identifiers

**Phase 0** · 2026-08-26 · branch `015-grievance-slug-ids`

The specification carries no `NEEDS CLARIFICATION` marker, so Phase 0 resolves
design questions rather than open requirements. Every decision below was probed
against real inputs before being recorded; the probe outputs are quoted.

**Revised after adversarial review.** A three-model panel from outside this
lineage attacked the first draft of this plan. Six findings were confirmed
against the real source. D1 and D2 below carry their corrections inline; D8 and
D9 are new decisions the review forced. The full reviews are under
[reviews/](./reviews/).

---

## D1 — The two identifier forms must be lexically disjoint

**Decision.** Legacy is `GRV-` followed by exactly 4 digits and nothing else.
New is `GRV-` followed by 2 to **5** lowercase alphanumeric segments separated by
single hyphens, 40 characters maximum overall.

```
LEGACY_ID_RE  ^GRV-\d{4}$
SLUG_ID_RE    ^GRV-[a-z0-9]+(?:-[a-z0-9]+){1,4}$
ANY_ID        GRV-(?:\d{4}|[a-z0-9]+(?:-[a-z0-9]+){1,4})
```

**Revised from 4 segments to 5** after D8 introduced a conditional final
discriminator segment. Disjointness was re-probed at the new bound and still
holds — `GRV-0001` matches the legacy form only, and no legacy identifier
matches the slug form, because a slug always carries a hyphen after the prefix.
`BLOCK_RE` was re-probed too: with a 5-segment identifier it still yields group
1 = identifier, group 2 = JSON, group 3 = body, and still returns 0 matches for
a block whose closing marker names a different identifier.

**Rationale.** Requiring at least two segments is what makes the forms
disjoint: `GRV-0001` has one segment, so it cannot match the slug form, and no
slug can match the legacy form because a slug always carries a hyphen after the
prefix. Disjointness means one widened pattern reads a mixed ledger with no
ambiguity and no per-entry format flag.

**Probed.** Eleven samples classified, zero overlap:

| Sample | legacy | slug |
|---|---|---|
| `GRV-0001` | yes | no |
| `GRV-worker-colocated-api` | no | yes |
| `GRV-worker` | no | no |
| `GRV-Worker-Api` | no | no |
| `GRV-a-b-c-d-e` | no | no |
| `GRV-0001-worker` | no | yes |

The last row is intentional. Digit-only segments stay legal so a description
like "2FA bypass trap on the npm token" can keep its acronym; see D2.

**Alternatives considered.** *A separate format field in each JSON header* —
rejected, it stores what the identifier itself already says and creates a second
source of truth that can disagree. *Dropping the `GRV-` prefix* — rejected in
the specification's Assumptions: without it, cross-references become
unsearchable across specification folders and commit messages.

---

## D2 — Derivation keeps significant words, and keeps acronyms even when short

**Decision.** Fold the description to ASCII lowercase, split on non-alphanumeric
characters, drop stop words, drop tokens under 3 characters **unless the token
appears uppercase in the original**, then append surviving tokens greedily while
the assembled identifier fits the ceiling.

**Revised: no fixed segment cap.** The first draft took "the first 4 surviving
tokens", which the review showed collides on distinct descriptions — see D8.
Filling to the ceiling instead of stopping at 4 fixes two of the three probed
collision pairs on its own; D8 handles the third.

**The stop-word list is adopted, not invented.** It is the same set the
repository's branch-name generator uses at
`.specify/scripts/bash/create-new-feature.sh:184`, reproduced verbatim in
[data-model.md](./data-model.md). The review's finding 6 was correct that naming
`STOP_WORDS` without defining it left FR-003's determinism requirement
unimplementable: two conforming implementations would mint different
identifiers. Adopting the repository's existing list rather than authoring a new
one keeps one vocabulary behind both naming schemes, which is the same argument
that brought in the acronym rule below.

**Rationale.** The under-3-characters filter alone produces a false refusal on
perfectly good descriptions. The first probe rejected `"DB naming"` because `db`
is two characters, leaving one segment. The acronym exception is not invented
here — it is the rule already used by this repository's own branch-name
generator at `.specify/scripts/bash/create-new-feature.sh:200`, which keeps a
short word when it "appear[s] as uppercase in original (likely acronyms)".
Reusing it keeps two naming schemes in the same repository consistent.

**Probed.** Before and after the acronym rule:

| Description | First probe | With acronym rule |
|---|---|---|
| `DB naming` | refused | `GRV-db-naming` |
| `2FA bypass trap on the npm token` | — | `GRV-2fa-bypass-trap-npm` |
| `worker co-hosted with the API will not scale` | `GRV-worker-hosted-api-scale` | unchanged |
| `the OIDC trusted publishing default is undocumented everywhere` | — | `GRV-oidc-trusted-publishing-default` |
| `GRIEVANCES.md ledger tables drift after a hand edit` | — | `GRV-grievances-ledger-tables-drift` |

Determinism was checked directly: three derivations of one description produced
1 distinct result.

**Accent folding** uses `unicodedata.normalize("NFKD", …)` and drops combining
characters, so `requête` becomes `requete` rather than `requte`. This is
robustness, not French support: committed artifacts in this repository are
English by rule, and the tuning of the stop-word list reflects that. A French
description does derive something valid — `"requête trop lente sur le
dashboard"` yields `GRV-requete-trop-lente-sur` — but the trailing `sur` shows
the list is not tuned for it. The explicit-identifier option in D3 is the answer
for any description whose derivation reads poorly.

**Alternatives considered.** *A hash suffix to guarantee uniqueness* — rejected,
it puts an unreadable segment in a name whose entire purpose is readability.
*Asking a model to name each grievance* — rejected, a non-deterministic
identifier cannot satisfy the acceptance scenario that two identical
descriptions collide on purpose.

---

## D3 — A thin description refuses instead of padding

**Decision.** When derivation yields fewer than 2 segments, refuse the
declaration and name both ways out: lengthen the description, or pass the
identifier explicitly.

**Rationale.** The three degenerate inputs probed — `slow`, `a`, `the the the` —
all return no identifier. Padding them into a valid shape would produce a name
that describes nothing, which defeats the point of the change and would break
the specification's SC-004 (every new identifier carries at least 2 words from
its own description). Refusal keeps SC-004 true by construction, and the
explicit-identifier escape hatch means the caller is never actually blocked.

This decision changed the specification. Its "description too thin to name"
edge case originally required the system to "still produce a valid, unique
identifier"; FR-002 now carries the refusal clause and the edge case matches.

**Alternatives considered.** *Raise the minimum length of the short description*
— rejected, it punishes every caller to handle a rare input, and a two-word
description is legitimate.

---

## D4 — Collision on derivation refuses and points at the recurrence counter

**Decision.** When the derived identifier is already present in the ledger,
refuse and offer the two correct moves: increment the existing entry's
recurrence counter, or supply a distinct identifier.

**Rationale.** This mirrors the guard already in `cmd_add`
(`grievances.py:648`), which refuses a duplicate short description and points at
`bump`. Two developers who derive the same identifier described the same problem
in the same words, which is the duplicate case that guard exists for. Extending
it to the identifier makes it catch the cross-branch case the description check
cannot see, because each branch only ever reads its own copy of the ledger.

**Alternatives considered.** *Auto-suffix with `-2`* — rejected, it silently
creates two entries a reader cannot tell apart, which is the outcome the whole
feature exists to prevent.

---

## D5 — `next_id` must be deleted, not bypassed

**Decision.** Remove `Ledger.next_id` (`grievances.py:246`) entirely rather than
leaving it unused.

**Rationale.** Its body is `int(g.id.split("-")[1])` over every entry. Called on
a ledger holding one slug identifier, it raises `ValueError: invalid literal for
int()` — an unhandled crash, not a caught `UserError`. A dead method that
detonates on the new data format is a trap for the next change, so the task
list treats its removal as a required step rather than optional tidying.

**Alternatives considered.** *Keep it for the legacy path* — rejected, nothing
mints legacy identifiers any more, so there is no legacy path to serve.

---

## D6 — Detect conflict markers by the paired forms only

**Decision.** Reject a ledger containing a line starting with `<<<<<<< ` or
`>>>>>>> `. Do **not** treat a bare `=======` line as a conflict marker.

**Rationale.** `=======` is legal markdown — a setext heading underline or a
horizontal rule — and grievance prose is author-owned free text where it can
legitimately appear. Keying on it would reject valid ledgers. The angle-bracket
forms carry no markdown meaning, so they are unambiguous, and git always writes
them in pairs, so checking either one catches every conflicted file.

The check belongs in `Ledger.load` (`grievances.py:208`) before block parsing.
Placing it there means `audit_repo` (`grievances.py:830`) reports it as a check
problem for free, because it already catches `UserError` from `load`.

**Alternatives considered.** *Attempt automatic resolution* — rejected, choosing
which side of a conflict survives is a human decision, and guessing it would
silently discard someone's grievance.

---

## D7 — Tests use the standard library, run in the documented container

**Decision.** One new file, `skills/grievances/scripts/test_grievances.py`,
using `unittest`, executed as
`docker run --rm -v "$PWD:/repo" -w /repo/skills/grievances/scripts
python:3.12-alpine python3 -m unittest -v`.

**Rationale.** This repository has three Python scripts and no Python test
harness, no `pytest` in any manifest, and no CI step that would install one. The
script under test is deliberately standard-library-only, and `unittest` keeps
that true, so the tests need no image build and no dependency resolution. Naming
the file `test_*.py` beside the script makes it discoverable without turning the
directory into a package. The container is the same `python:3.12-alpine` the
skill already documents at `SKILL.md:59`, satisfying the Docker-only rule.

**What the tests must pin**, beyond the happy path:

- derivation is deterministic for a given description;
- the acronym exception keeps `DB naming` working (the regression the first
  probe found);
- the two identifier forms are disjoint, asserted directly on both patterns;
- `BLOCK_RE` still yields groups 1, 2 and 3 in that order and its `\1`
  backreference still rejects a mismatched open/close pair — probed and
  confirmed at 0 matches, and cheap to lose in a careless regex edit;
- editing a short description leaves the identifier untouched (the probe shows
  re-derivation would produce `GRV-api-deployment-also-runs` where the stored
  identifier is `GRV-worker-hosted-api-scale`);
- `audit_repo` and `cmd_migrate` never rename an identifier — both are correct
  today by accident of treating identifiers as opaque, and nothing currently
  stops a future change from breaking that.

**Alternatives considered.** *`pytest`* — rejected, it adds a dependency and an
image build for a suite that needs neither. *No tests* — rejected, D2's false
refusal was found by probing, which is evidence that this derivation logic needs
a regression net.

---

## D8 — A truncated name carries a discriminator; a complete one does not

**Decision.** When derivation drops at least one significant word, append a
final segment: the first 4 hex characters of the SHA-256 of the space-joined
**full** significant-word list. When every word fits, append nothing.

**Rationale — this is the review's blocker, and it was real.** The first draft
capped the name at 4 segments and claimed SC-001: distinct descriptions never
collide. Probed, that claim is false:

| Pair | 4-segment cap | fill-to-ceiling | with discriminator |
|---|---|---|---|
| `worker queue retry bug alpha` / `… omega` | **collides** | distinct | distinct |
| `release pipeline npm token expires after ninety days` / `… bypasses two factor auth` | **collides** | distinct | distinct |
| `the asset registry description drifts from the skill frontmatter title` / `… from the schema enum values` | **collides** | **collides** | distinct |
| `DB naming diverges from the code aliases` / `worker co-hosted with the API` | distinct | distinct | distinct |

The third pair is the load-bearing one. It still collides after removing the
segment cap, because the 40-character ceiling truncates it regardless. That is
not a tuning problem: **a readable identifier of bounded length cannot be an
injective function of an unbounded description.** Truncation is a mathematical
property of the design, so the design has to carry a discriminator rather than
hope truncation is rare.

Consequences of the collision, had it shipped: both branches declare
successfully, because each sees only its own copy of the ledger; the merge then
produces two entries with one identifier; and `Ledger.load`
(`grievances.py:233`) raises `GRV-… appears twice`, which makes every subsequent
command fail. That is exactly the bricked ledger this feature exists to prevent,
reintroduced through a narrower door.

**Why conditional and not always.** Always appending would put an unreadable
segment on `GRV-db-naming`, which needs none. Conditional keeps the common case
clean and turns the discriminator into a signal: its presence tells a reader the
name is abbreviated. Probed:

```
'DB naming'                        -> GRV-db-naming
'worker co-hosted with the API'    -> GRV-worker-hosted-api
'2FA bypass trap on the npm token' -> GRV-2fa-bypass-trap-npm-token
'release pipeline npm token expires after ninety days'
                                   -> GRV-release-pipeline-npm-token-9c23
```

**Why the hash covers the significant-word list, not the raw string.** Hashing
the raw description would make `"the worker queue"` and `"worker queue"` derive
different identifiers, which is wrong: they are the same finding described the
same way. Hashing the token list keeps FR-003 determinism while staying
insensitive to whitespace and stop-word noise. Identical descriptions still
collide, which the specification requires as the duplicate signal.

**Reserving room.** The greedy fill reserves 5 characters for the discriminator
whenever tokens remain unconsumed, and reserves nothing when the token being
added is the last one. Without the reserve, appending the discriminator could
push the identifier past the ceiling after the fact.

**Alternatives considered.** *Raise the ceiling* — rejected, it lowers collision
probability without removing it, and makes every name harder to read and type.
*Make a duplicate identifier non-fatal on load* — rejected, and this is the
important rejection: `Ledger.get` returns the first match, so tolerating
duplicates would silently route a mutation to the wrong entry. Failing loudly is
correct; the fix is to stop producing the duplicate.

---

## D9 — A marker that fails the identifier pattern must be reported, not skipped

**Decision.** `Ledger.load` sweeps for `<!-- grievance:` openers that the block
pattern did not consume and raises on any it finds. It also validates each
consumed identifier's shape, ceiling included.

**Rationale.** `Ledger.load` builds its model purely from `BLOCK_RE.finditer`,
so a marker the pattern rejects is not an error — it is *invisible*. Probed
against a three-entry document:

```
markers present in the file : ['GRV-0001', 'GRV-worker', 'GRV-Worker-Api']
consumed by BLOCK_RE        : ['GRV-0001']
SILENTLY SKIPPED            : ['GRV-worker', 'GRV-Worker-Api']
```

Two grievances vanish from the model and from the regenerated tables, while
`render` leaves their raw text in the file — `BLOCK_RE.sub` only rewrites what it
matched. The document then says one thing and contains another, with no error.

This is latent in the current code, but this feature aggravates it sharply. The
old pattern had exactly one near-miss shape, a wrong digit count. The new one has
many: wrong case, one segment, six segments, an underscore, an over-long name.

The ceiling check belongs on the same path. Probed: `GRV-` plus five 8-character
segments is 48 characters and matches the widened pattern, because the pattern
carries no length bound and `Ledger.load` never calls `check_id`. A ceiling
enforced only at declaration is not a ceiling — FR-020.

**Alternatives considered.** *Silently repair* — rejected, guessing what a
malformed identifier meant risks pointing an existing external reference at the
wrong entry. *Report at `check` time only* — rejected, every command reads
through `load`, and a mutation against a partially-parsed model writes a file
missing entries.
