---
name: grievances
description: >-
  Maintain `specs/GRIEVANCES.md`, the committed per-repo ledger of non-blocking
  findings — underlying problems, technical debt and improvements met outside the
  scope of an in-flight spec ("what works but will not scale"). The file is
  maintained programmatically by `scripts/grievances.py`: declare a grievance
  (short description, severity, date), close it (date + commit hash), bump a
  recurrence, audit a repo, or migrate a legacy `DOLEANCES.md`. Use when creating
  the ledger in a repo, when recording or closing a finding at the end of an
  implementation / test / review phase, or when deciding whether a finding stays
  in the ledger or must be promoted to a spec or a pilot-roadmap fiche. Triggers
  on "grievance", "GRIEVANCES.md", "doléance", "doleances", "DOLEANCES.md",
  "small problem", "papercut", "technical debt backlog", "note this for later".
tags:
  - common
  - documentation
  - process
---

# Grievances — the ledger of non-blocking findings

## Why this exists

Every implementation, test or review pass produces findings that are real but
outside the scope of the spec in flight: a command that needs an undocumented
flag, a fixture that lags the norm, a table name singular in the DB and plural in
the code, a worker co-hosted with the API that will not scale. Those findings
normally die in the session that met them — nobody writes them down because
writing them down costs more than living with them once, and so the same twenty
minutes are lost again by the next person.

`specs/GRIEVANCES.md` is where they go: one file per repo, committed, so friction
accumulates **visibly** — and **maintained by a CLI**, so an agent can declare
and close entries without ever reformatting a table by hand.

## The canonical location and name

**Path: `<repo>/specs/GRIEVANCES.md`.** Beside a `<repo>/specs/CLAUDE.md` that
says when to read it and when to write to it.

- It lives in `specs/` because a grievance is the raw material a spec is made of —
  one step upstream, in the same folder, so promotion is a move within one
  directory rather than a leap across the repo.
- **The file name is English**, like every other committed artifact. Its
  **content** follows each repo's language rule.
- A `DOLEANCES.md` is the **legacy** name (the convention started in
  `modelo-homestaging`). It is not a second ledger: migrate it, never duplicate it
  — see [Migrating a legacy ledger](#migrating-a-legacy-ledger).

## The CLI — the normal way to touch the file

`scripts/grievances.py` (Python 3, standard library only). By default it resolves
`<git root>/specs/GRIEVANCES.md`; override with `--file`, `--repo`, or
`GRIEVANCES_FILE`. Under the Septeo Docker-only execution policy, run it in a
container:

```bash
docker run --rm -v "$PWD:/repo" -v "<skill>:/skill:ro" -w /repo python:3.12-alpine \
  python /skill/scripts/grievances.py <subcommand> ...
```

| Subcommand | What it does |
|---|---|
| `init` | Create the ledger + `specs/CLAUDE.md` guidance; print the root-`CLAUDE.md` pointer to paste. Never overwrites. |
| `add` | Declare a grievance. Allocates the next `GRV-NNNN`, appends the detail block, rebuilds the tables. |
| `resolve <id>` | Close it: date + commit hash. Moves its row to the resolved table. |
| `reopen <id>` | Move it back to the open table, keeping the history. |
| `bump <id>` | Count another occurrence (`×N`) instead of declaring a duplicate. |
| `list` / `show` | Read it — `--json` for agents. |
| `rebuild` | Regenerate the tables and headings, re-sorted. Idempotent. |
| `check` | Audit one repo (`--strict` also fails on a drifted file), or every repo under a pilot root with `--all --root <path>`. |
| `migrate` | Rename a legacy `DOLEANCES.md` and index it, preserving its prose verbatim. |

### Declaring one

```bash
grievances.py add \
  --short "worker co-hosted with the API will not scale" \
  --severity high \
  --locus "internal/worker/main.go:42" \
  --source "spec 156 implementation" \
  --finding "The River worker runs in the API container, so scaling reads scales the queue too." \
  --impact "A traffic spike on the read path starves the queue; nothing warns." \
  --fix "Split the worker into its own deployment." --effort 1d
# → GRV-0007 declared (high, 2026-08-04) in …/specs/GRIEVANCES.md
```

- `--short`, `--severity` (`critical|high|medium|low`) and the date (`--date`,
  default today) are the three table columns — the fields the tool owns.
- `--impact` is **required**. An entry without an impact line gets ignored
  forever: the reader cannot tell whether it matters. For a pure papercut whose
  cost is self-evident, say so explicitly with `--allow-no-impact`.
- `--locus` (`file.ext:line`), `--source`, `--tag`, `--why-tests-miss`,
  `--fix`/`--effort` are optional context. `--body-file <md>` replaces the
  generated prose with your own markdown.
- Declaring a second entry with the same `--short` as an open one is **refused**,
  with the `bump` command to run instead. Frequency is the severity signal, and a
  duplicate hides it.

### Closing one

```bash
grievances.py resolve GRV-0007 --commit 1a2b3c4d --note "worker runs in its own deployment"
grievances.py resolve GRV-0008 --promoted-to "specs/160-db-naming/" --note "became a spec"
grievances.py resolve GRV-0009 --wont-fix --note "the DB name stays; the code aliases it"
```

Exactly one of `--commit` (7–40 hex chars, validated), `--promoted-to <ref>` or
`--wont-fix` (which requires `--note`, so the decision is recorded once and for
all). The date defaults to today. The row moves from the open table to the
resolved one, **same columns plus `Resolved` and `Commit`**, and a resolution line
is appended to the detail block.

## The file's shape

Three regions, in this order:

1. a preamble stating what the file is and its boundary;
2. **the synthetic report**: `## Open grievances (N)` then
   `## Resolved grievances (N)`, both generated, each row's ID linking down to the
   full analysis;
3. `# Details`: one block per grievance, appended, newest last.

```markdown
| ID | Date | Severity | Seen | Short description |
|---|---|---|---|---|
| [GRV-0002](#grv-0002) | 2026-07-12 | medium | ×4 | make integration hardcodes its domain list |
```

```markdown
<!-- grievance:GRV-0007 {"id": "GRV-0007", "severity": "high", …} -->
<a id="grv-0007"></a>
### GRV-0007 · high · 2026-08-04 — worker co-hosted with the API will not scale

`internal/worker/main.go:42` · declared in spec 156 implementation

**Resolved 2026-08-06** — worker runs in its own deployment · `1a2b3c4d`

<!-- grievance:GRV-0007:prose -->

**Finding.** …

**Impact.** …

**Fix.** … **Effort: 1d.**
<!-- /grievance:GRV-0007 -->
```

**The ownership contract — this is what makes the file safe to edit by hand:**

- The **tool owns** both tables, the `<!-- grievance:… -->` markers and their JSON
  (the single source of truth), the anchor, the `###` heading, the context line and
  the resolution lines. Hand-edit those and the next mutation reverts them;
  `check --strict` reports the drift.
- **You own** everything after `<!-- grievance:ID:prose -->` — kept verbatim
  through every mutation. Add evidence, a log excerpt, a diagram there.
- Free-form sections may live below `<!-- grievances:details:end -->`; the tool
  never touches them.

**Sorting.** Every mutation re-sorts both tables chronologically (oldest first,
ties by ID): the open table by declaration date — so the oldest grievance, the one
that has been rotting longest, is the first thing read — and the resolved table by
resolution date. Detail blocks stay in declaration order so git diffs stay small.

## The boundary — read this before adding anything

A repo already has many places where a fact can live: its own `ROADMAP.md`,
`_todo.md`, `PROGRESS.md`, `specs/NNN-*/review.md`, ad-hoc `debug-report.md`, and
the **pilot** `ROADMAP.md` one level up. The ledger is worth having **only** if
its boundary is sharp. **One fact lives in exactly one artifact.**

**A grievance is** at once **non-blocking** (the work it was met during could
complete anyway) and **factual** (an observed symptom, not an architectural
opinion). Size is not the criterion — real ledgers carry entries worth several
days; what they share is that nobody is blocked today.

**A grievance is NOT:**

| Not this | Where it goes instead |
|---|---|
| A defect with a regulatory, security, data-loss or money dimension | A spec, or a fiche in the pilot `ROADMAP.md` — immediately |
| Anything needing an arbitration or a design decision | A pilot roadmap fiche with a named arbiter |
| A task on the spec in flight | That spec's `tasks.md` |
| A finding on the diff under review | That spec's `review.md` |
| A live incident | The incident/debug report, then a pilot roadmap fiche |
| "This module should be rewritten" | Nowhere. That is an opinion; make it a proposal with evidence, or drop it |

### The promotion rule

The moment a finding grows teeth — it recurs, it blocks someone, or it turns out
to have a regulatory or security edge — it stops being a grievance. It is
**promoted**: open the spec or the pilot fiche, then close the grievance with
`resolve --promoted-to <ref>`. The pointer stays; the analysis lives in exactly
one place. Never restate a promoted finding in both.

Promotion is not the ledger failing; it is the ledger working. Its job is to hold
findings long enough for the important ones to reveal themselves.

## Lifecycle — what to do, and when

### While working (any phase)

The moment you hit friction, run `add`. Not at the end — at the moment, while the
locus and the exact symptom are in front of you. Cost: one command.

Before adding, **`list --json` or grep the file for the symptom**. If it already
exists, `bump` it instead of declaring a second entry.

### At the end of every implementation / test / review phase

1. `add` what you did not fix.
2. `resolve --commit <hash>` what you did fix, including in passing.
3. `resolve --promoted-to <ref>` anything with teeth.
4. Then **say in one sentence what you changed, including "no change"**:
   *"Grievances: 3 declared, 2 resolved (`1a2b3c4d`, `9f8e7d6`)"* or *"Grievances:
   no change this phase"*. A silent no-op is indistinguishable from forgetting,
   and the second one is what kills ledgers.

### Pruning

A file that only grows stops being read; git carries the trail, so the ledger does
not need to.

- Drop a resolved block entirely once it is more than a couple of months old — its
  row and its commit hash are the history worth keeping, and git has the rest.
- Delete a promoted pointer once the target spec is itself closed and archived.
- A grievance that has sat untouched for six months is a decision waiting to be
  made: either it is not a real problem (`resolve --wont-fix --note …`, with that
  word), or nobody owns it (`resolve --promoted-to …`). Both beat a line nobody
  reads. The open table, sorted oldest first, puts those candidates on top.

## Wiring it into a repo

```bash
grievances.py init --repo <repo>     # writes specs/GRIEVANCES.md + specs/CLAUDE.md
grievances.py check --repo <repo>    # audits both, plus the root CLAUDE.md pointer
grievances.py check --all --root <pilot-root>   # sweeps every sibling repo
```

`init` never overwrites, and it never edits a hand-curated root `CLAUDE.md`: it
prints the block to paste there so an agent finds the ledger unprompted. Commit
both files together:

```
docs(grievances): add the non-blocking findings ledger and its scope guidance
```

## Migrating a legacy ledger

```bash
grievances.py migrate --from specs/DOLEANCES.md   # → specs/GRIEVANCES.md
```

The legacy file's content is preserved **verbatim** under a
`## Legacy ledger — imported from DOLEANCES.md` section below the indexed
grievances; the old file is removed (`git rm` when tracked, `--keep-legacy` to
keep it). Nothing is reformatted and no entry is invented: re-declare with `add`
whatever is still open so it appears in the table at the top, then strike it from
the legacy section. Then update `specs/CLAUDE.md` and the root `CLAUDE.md` pointer,
and commit:

```
docs(grievances)!: rename the ledger to GRIEVANCES.md and index it programmatically
```

## Anti-patterns

- **A second ledger under another name.** `DOLEANCES.md` beside `GRIEVANCES.md` is
  the exact failure the boundary rule exists to prevent. One file, one name,
  checked by `check`.
- **Hand-editing the tables or a JSON header.** They are generated; your edit dies
  at the next mutation. Use the CLI, or `rebuild` after a genuine repair.
- **Using it as a second backlog.** If entries acquire owners and sprints, the
  boundary has failed — those were roadmap fiches all along. Severity and `×N` are
  the only ranking signals here.
- **Findings without an impact line.** "The repository layer is badly designed" is
  unusable in six months. "`consumer_credential` is singular in the DB and plural
  in the code — every ad-hoc query fails first try" is actionable forever.
- **Writing the phase's entries from memory at the end.** You will remember the two
  loudest findings and lose the six that each cost ten minutes.
- **Duplicating instead of `bump`.** Forty near-identical entries hide the signal
  the `×N` would have shown.
- **Closing without a commit hash.** `resolve` demands `--commit`, `--promoted-to`
  or an explicit `--wont-fix --note`, because "fixed" with no trace is unverifiable.
- **Restating a promoted finding.** The pointer replaces the analysis; it does not
  accompany it.
- **Secrets.** A finding about a credential records the *command* that retrieves
  it, never its value — same rule as every other committed artifact.
