# CLI contract — Merge-safe grievance identifiers

**Phase 1** · 2026-08-26 · branch `015-grievance-slug-ids`

The skill's external interface is a command-line one. This file records what the
contract is after the change, and marks every line as unchanged, changed, or new,
so a reviewer can tell at a glance how wide the blast radius is.

All invocations run in the documented container:

```bash
docker run --rm -v "$PWD:/repo" -v "$PWD/skills/grievances:/skill:ro" -w /repo \
  python:3.12-alpine python3 /skill/scripts/grievances.py <subcommand> [options]
```

---

## Subcommands

| Subcommand | Status | Contract change |
|---|---|---|
| `init` | unchanged | creates an empty ledger |
| `add` | **changed** | gains `--id`; allocates a descriptive identifier instead of the next number |
| `resolve <id>` | **changed** | accepts both identifier forms |
| `reopen <id>` | **changed** | accepts both identifier forms |
| `bump <id>` | **changed** | accepts both identifier forms |
| `list` | unchanged | identifiers are opaque to it |
| `show <id>` | **changed** | accepts both identifier forms |
| `rebuild` | unchanged | already regenerates from the JSON headers; becomes the documented merge-resolution step |
| `check` | unchanged behaviour, **new failure surfaced** | reports the conflict-marker rejection, because it already reports load failures |
| `migrate` | unchanged | imports legacy content as prose; mints nothing, renames nothing |

---

## `add` — the one subcommand whose options change

### New option

```
--id <identifier>    Name the grievance explicitly instead of deriving the
                     name from --short. Must match the descriptive form:
                     GRV- plus 2 to 5 lowercase alphanumeric segments,
                     40 characters maximum. A supplied identifier need not
                     draw its words from --short.
```

### Behaviour

| Input | Output | Exit |
|---|---|---|
| `--short "worker co-hosted with the API will not scale"`, no `--id` | declares `GRV-worker-hosted-api-scale` | 0 |
| `--short "DB naming"`, no `--id` | declares `GRV-db-naming` | 0 |
| `--short "slow"`, no `--id` | refuses: too few significant words; lengthen `--short` or pass `--id` | non-zero |
| `--short "release pipeline npm token expires after ninety days"`, no `--id` | declares `GRV-release-pipeline-npm-token-9c23` — words dropped, so a discriminator is appended | 0 |
| `--short "release pipeline npm token bypasses two factor auth"`, no `--id` | declares `GRV-release-pipeline-npm-token-96f0` — same fitted words, different discriminator | 0 |
| two descriptions folding to the same significant-word list | derive the same identifier; the second is refused | non-zero |
| `--id GRV-worker-api` on a free identifier | declares `GRV-worker-api` | 0 |
| `--id GRV-Worker-API` | refuses: names the shape rule broken | non-zero |
| `--id GRV-worker` | refuses: 1 segment, needs 2 to 5 | non-zero |
| `--id` longer than 40 characters | refuses: over the ceiling | non-zero |
| `--id GRV-0099` | refuses: the legacy form is read-only and is never minted | non-zero |
| `--id` or a derived identifier already in the ledger | refuses: increment the existing entry's recurrence counter, or supply a distinct identifier | non-zero |

### `--force` changes meaning

`--force` used to mean "yes, declare a second entry with this same short
description". It cannot mean that any more: identical descriptions derive
identical identifiers, so the forced path would be refused a step later by the
uniqueness check. `--force` now requires `--id`.

| Input | Output | Exit |
|---|---|---|
| `--short <existing>` | refuses: bump the existing entry, or pass `--force --id <name>` | non-zero |
| `--short <existing> --force`, no `--id` | refuses: naming the entry it would collide with, and that `--force` needs `--id` | non-zero |
| `--short <existing> --force --id GRV-distinct-name` | declares | 0 |

### Uniqueness is checked on both paths

The identifier is checked against the ledger **after** it is obtained, whether it
was derived or supplied. A supplied `--id` gets exactly the same check; letting
derivation own the check is what allowed a supplied duplicate through.

### Unchanged guarantees

`--impact` remains required unless explicitly waived, and `--dry-run` writes
nothing.

### Machine-readable output

`--json` keeps its existing key set — `id`, `file`, `status`, `anchor`. Callers
that treated `id` as numeric-suffixed break; nothing in this repository does,
and the field was never documented as parseable.

---

## Identifier arguments on `resolve`, `reopen`, `bump`, `show`

| Argument | Result |
|---|---|
| `GRV-0007` present in the ledger | operates on it |
| `GRV-worker-hosted-api-scale` present | operates on it |
| well-formed, either form, absent from the ledger | refuses: no such grievance |
| malformed in either form | refuses: names the shape rule broken |

---

## New failure modes on every reading subcommand

| Condition | Behaviour |
|---|---|
| the ledger contains a line starting with `<<<<<<< ` or `>>>>>>> ` | every subcommand that reads the ledger refuses, naming the unresolved conflict and telling the caller to resolve it first |
| the ledger contains a bare `=======` line and no angle-bracket marker | parsed normally — legal markdown, not a conflict marker |
| a `<!-- grievance:` marker carries an identifier matching neither form | refuses, naming the marker. **Not** skipped: skipping makes the entry vanish from the tables while its text stays in the file |
| a stored identifier is well-formed but over 40 characters | refuses. The pattern has no length bound, so this is a separate check |
| the same identifier appears on two entries | refuses, and names the recovery: keep one entry, increment its recurrence counter, regenerate |

`check` reports each of these as a problem for the audited repository rather than
crashing, because it already wraps ledger loading.

---

## Merge-resolution contract

The procedure the documentation must state, and the only one supported:

1. Resolve the textual conflict by keeping **both** sides. Duplicated or stale
   generated content at this point is expected and harmless.
2. Run `rebuild`.
3. The generated regions now match the entries; no entry was lost; a second
   `rebuild` changes nothing.

If the two sides carry the same identifier, step 1 is instead: keep one entry,
and increment its recurrence counter. That is the duplicate case, and the shared
identifier is the signal — two people described the same finding in the same
words. Deleting the losing block is the one sanctioned author edit to
tool-owned content, and it exists only for this path.

Two distinct findings can no longer land on one identifier: when derivation
cannot fit every significant word, it appends a discriminator computed from the
whole word list, so the identifiers differ even when the readable parts match.

---

## Out of contract

- No identifier already present in any ledger changes value. This holds for
  every subcommand including `migrate`.
- The recurrence counter's own merge defect — two branches each incrementing the
  same entry lose one increment — is untouched. Recorded as a follow-up in the
  specification's Assumptions.
