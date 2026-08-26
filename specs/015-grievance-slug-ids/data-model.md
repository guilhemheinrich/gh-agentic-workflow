# Data model — Merge-safe grievance identifiers

**Phase 1** · 2026-08-26 · branch `015-grievance-slug-ids`

The ledger's storage model does not change: each grievance carries a JSON header
inside an HTML comment, that header is the single source of truth, and the index
tables are regenerated from it on every mutation. What changes is the value
space of one field — `id` — and the rules that govern it.

---

## Identifier

Not a stored entity of its own; a constrained string that is the primary key of
`Grievance`. Two forms coexist.

| Form | Shape | Minted | Mutable |
|---|---|---|---|
| Legacy sequential | `GRV-` + exactly 4 digits | never again | never |
| Descriptive | `GRV-` + 2 to 5 lowercase alphanumeric segments, hyphen-separated, ≤ 40 chars total | on declaration | never |

The fifth segment is a **discriminator**: 4 hex characters, present if and only
if derivation could not fit every significant word of the description. Its
presence tells a reader the name is abbreviated.

### Validation rules

| Rule | Source | Enforced at |
|---|---|---|
| Matches the legacy form or the descriptive form | FR-004, FR-006 | command-line parse, **and again when read back from a stored header** |
| Within the 40-character ceiling | FR-004, FR-020 | both paths above. The pattern carries no length bound, so the ceiling is a separate check |
| Every marker in the file is accounted for | FR-021 | load: any `<!-- grievance:` opener the block pattern did not consume is an error, never a skip |
| Unique within the ledger | FR-007, FR-022 | declaration, and on load, where a duplicate names the recovery procedure |
| Leading segments come from the description — derived identifiers only | FR-004a | derivation. A supplied identifier is exempt |
| Derived from the grievance's own description, never from a count of entries | FR-001 | declaration |
| Derivation is deterministic | FR-003 | pure function, no clock, no randomness, no filesystem read |
| Accents and non-ASCII folded to the permitted set | FR-005 | derivation |
| Frozen after declaration | FR-008 | no code path recomputes it; editing the short description does not touch it |

### The stop-word set

**Normative.** FR-003 requires determinism, so an unpublished list would let
two conforming implementations mint different identifiers for the same
description. 54 words, in two parts.

**Base — 48 words, verbatim from the repository's own branch-name generator** at
`.specify/scripts/bash/create-new-feature.sh:184`, so one vocabulary serves both
naming schemes:

```
i      a      an     the    to     for    of     in     on     at
by     with   from   is     are    was    were   be     been   being
have   has    had    do     does   did    will   would  should could
can    may    might  must   shall  this   that   these  those  my
your   our    their  want   need   add    get    set
```

**Extension — 6 words** the base list has no reason to carry, because a branch
name is a noun phrase while a grievance description is a sentence:

```
not    no     and    or     it     its
```

The extension is not cosmetic. Without `not`, the primary documented example
`"worker co-hosted with the API will not scale"` derives
`GRV-worker-hosted-api-not-scale`, not the `GRV-worker-hosted-api-scale` every
other artefact quotes. Measured both ways before adding it.

Note the base list's trailing five — `want`, `need`, `add`, `get`, `set`.
Adopting it verbatim means `"get endpoint returns 500 on an empty body"` derives
`GRV-endpoint-returns-500`, losing `get`. Accepted: one shared vocabulary is
worth more than a marginally better name, and `--id` covers any case where it
reads badly.

### Derivation

Input: the grievance's short description, plus the set of identifiers already
present in the ledger. Output: an identifier, or a refusal.

1. Split the description on non-alphanumeric characters, **keeping each token's
   original case**.
2. For each token, in order: fold it to ASCII and lowercase it, then decide.
   Drop it if the folded form is a stop word. Drop it if the folded form is
   under 3 characters **unless the original token was uppercase** — the acronym
   exception.

   The order matters and was wrong in the first draft. Deciding after a global
   lowercase makes the acronym test impossible, because there is no case left to
   inspect, and `DB naming` is then refused. Probed: `"DB naming"` derives
   `GRV-db-naming`, while `"db naming"` is correctly refused — the case carries
   the meaning.
3. Fewer than 2 words survive → refuse, naming both remedies (lengthen the
   description, or supply the identifier).
4. Append surviving words greedily while the assembled identifier fits within 40
   characters. There is **no fixed segment cap**; a cap at 4 was what let two
   distinct descriptions collide.
5. Fewer than 2 words fit → refuse, same remedies as step 3. This is what
   happens to `"internationalization misconfiguration"`: two legitimate words
   whose combined length exceeds the ceiling.
6. Every word fitted → the name is complete; append nothing, and stop.
7. Any word was dropped → append `-` plus the first 4 hex characters of the
   SHA-256 of the space-joined **full** surviving-word list. Then, while the
   result exceeds 40 characters, drop the last readable segment; if that would
   leave fewer than 2 readable segments, refuse.

Uniqueness is **not** part of derivation. It is checked by the caller against
the ledger, on both the derived and the supplied path — see the CLI contract.
Putting it inside derivation is what let a supplied `--id` skip it.

Step 6 hashes the token list rather than the raw description on purpose: `"the
worker queue"` and `"worker queue"` are the same finding described the same way
and must derive the same identifier.

### Injectivity, stated honestly

Derivation is injective over **significant-token lists**, not over descriptions.
Two descriptions that fold to the same token list derive the same identifier —
which is the duplicate signal the specification wants. Two descriptions with
different token lists always derive different identifiers, whether or not
truncation occurred, because the discriminator covers the whole list.

What is *not* guaranteed: absolute uniqueness under a hash collision. Two
descriptions sharing every fitted word **and** colliding in 4 hex characters
would produce one identifier. The precondition makes this negligible, and the
outcome is the loud `load` failure of FR-022, not silent corruption.

### Relationship to the short description

They are independent after declaration, and the model must not re-couple them.
The identifier is derived from the description **once**. A later reformulation
changes the description and leaves the identifier alone, so inbound references
keep resolving.

Concretely, from the probe: a grievance declared as
`"worker co-hosted with the API will not scale"` gets
`GRV-worker-hosted-api-scale`. Reformulated to
`"API deployment also runs the background worker"`, re-derivation would produce
`GRV-api-deployment-also-runs` — a different identifier. Nothing may perform
that re-derivation.

---

## Grievance

Unchanged in shape. Listed for the identifier's context and to mark what is
immutable.

| Field | Type | Mutable | Notes |
|---|---|---|---|
| `id` | Identifier | **no** | primary key; anchor and cross-reference target |
| `short` | string, ≤ 120 chars | yes | seeds the identifier at declaration, then diverges freely |
| `severity` | one of critical, high, medium, low | yes | |
| `date` | `YYYY-MM-DD` | no | declaration date; primary table sort key |
| `status` | open or resolved | yes | |
| `occurrences` | integer ≥ 1 | yes | recurrence counter; **its own merge defect is out of scope** — see the specification's Assumptions. Also the recovery lever when a duplicate identifier does land in a merged file |
| `locus` | string or absent | yes | where the finding lives |
| `source` | string or absent | yes | what surfaced it |
| `tags` | list of strings | yes | |
| `resolution` | object or absent | yes | kind, date, and commit or reference |
| `history` | list of objects | append-only | |

**Derived, not stored**: the in-document anchor, computed by lowercasing the
identifier. Descriptive identifiers are already lowercase, so the anchor equals
the identifier; legacy `GRV-0001` yields `grv-0001` as it does today. Two
distinct identifiers cannot collapse to one anchor, because lowercasing is
injective over both forms.

---

## Ledger

Unchanged in structure and unchanged in ownership.

| Region | Owner | This feature |
|---|---|---|
| Preamble and free sections | author | untouched |
| Open and resolved index tables | tool, fully regenerated | must render both identifier forms and keep their links resolving |
| Per-grievance JSON header | tool | value space of `id` widens |
| Per-grievance heading, anchor, context and resolution lines | tool | regenerated as today |
| Prose after the per-grievance prose marker | author, verbatim | untouched |

### Invariants

| Invariant | Why it matters here |
|---|---|
| Identifiers are unique within a ledger | a duplicate makes the ledger unloadable, which is the defect this feature removes |
| Tables sort by date, identifier only breaking ties | no ordering may depend on identifiers being numeric |
| Regeneration is idempotent | a second consecutive run changes nothing, which is what makes it safe as the merge-resolution step |
| A file carrying unresolved conflict markers is rejected, not parsed | prevents a misparse from silently discarding an entry |
| Every grievance marker in the file appears in the model | without this, an entry with a malformed identifier is invisible to the tables while its text stays in the file |
| Identifier shape and ceiling are checked on read, not only on write | a ceiling enforced at one end only is not a ceiling |

### State transitions

Unaffected by this feature, and listed to make the immutability claim complete:
`open → resolved` on close, `resolved → open` on reopen, `open → open` on a
recurrence increment. The identifier changes in none of them.
