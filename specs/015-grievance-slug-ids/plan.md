# Implementation Plan: Merge-safe grievance identifiers

**Branch**: `015-grievance-slug-ids` | **Date**: 2026-08-26 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/015-grievance-slug-ids/spec.md`

## Summary

Grievance identifiers stop being a counter and become a name derived from the
grievance's own short description. A counter read from the ledger's contents is
the collision: two branches from one ancestor both compute the same next number.
A name derived from the description collides only when two people describe the
same thing the same way, which is the one case where collision is the correct
signal.

The change is contained in one script and its skill documentation. Legacy
sequential identifiers stay readable and addressable forever and are never
rewritten, because they are quoted in commit messages and specification folders
the ledger cannot reach. The two forms are lexically disjoint, so a single
widened pattern accepts both without ambiguity.

A bounded readable name cannot be a unique function of an unbounded
description, so a truncated name carries a 4-character discriminator computed
from the whole description and a complete one does not. That is not a detail: an
adversarial review proved that without it, two distinct findings declared on
sibling branches derive one identifier and the merged ledger stops loading —
the exact failure this feature exists to remove.

Three hardening items ride along because they are what makes the merge story
usable end to end: the loader rejects a file still carrying merge conflict
markers instead of misparsing it, it reports a grievance marker whose identifier
it cannot parse instead of silently dropping the entry, and the first test file
for this script pins the derivation as deterministic.

**Revised after adversarial review.** A three-model panel from outside this
lineage attacked the first draft. Six findings were confirmed against the real
source: one blocker (the collision above), three major (unvalidated read path,
unenforced ceiling, a requirement that bound supplied identifiers to the
description), two minor. All six are applied. Reviews and the verification
probes are recorded in [research.md](./research.md) D8 and D9 and under
[reviews/](./reviews/).

## Technical Context

**Language/Version**: Python 3.12, standard library only
**Primary Dependencies**: none — `argparse`, `dataclasses`, `hashlib`, `json`, `re`, `unicodedata`, `pathlib`, `subprocess`. `unicodedata` and `hashlib` are the two new imports.
**Storage**: the committed markdown ledger itself; JSON headers inside HTML comments are the source of truth, the tables are derived
**Testing**: `unittest` from the standard library, run inside `python:3.12-alpine`
**Target Platform**: any host with Docker; the script is documented to run in `python:3.12-alpine` with the repo mounted
**Project Type**: single-file CLI shipped inside a skill directory
**Performance Goals**: N/A — ledgers hold tens of entries and every mutation already rewrites the whole file
**Constraints**: standard library only; no existing identifier may change value; the ownership contract between generated regions and author-owned prose is unchanged; derivation must be deterministic across machines, which rules out any clock, randomness or filesystem read
**Scale/Scope**: 1 script (1061 lines), 1 skill document, 1 new test file. Roughly 10 touchpoints in the script, listed under Project Structure.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

The constitution scopes itself in its own first sentence: it "governs SpecKit
planning and reviews for **backend TypeScript work** in this repository." This
feature is a Python CLI inside a skill. The stack-bound principles are therefore
out of scope rather than waived, and the Complexity Tracking table stays empty.

| Principle | Applies | Assessment |
|---|---|---|
| I — Explicit Type Contracts | Transposes | The script already annotates every signature and uses `from __future__ import annotations`. New functions carry full annotations. No `Any` in the new code. |
| II — Semantic Documentation | **Yes** | Each new function gets a docstring stating intent, matching the density already in the file. The derivation rules get a comment explaining *why* the two identifier forms are disjoint — the non-obvious part. |
| III — Readable Functional Style | **Yes** | Derivation is a pure function taking the description and the set of taken identifiers, returning the identifier. No hidden state, no cleverness. |
| IV — Pure Functional Core | Transposes | Derivation, shape validation and conflict-marker detection are pure and side-effect free. File I/O stays where it already is. |
| V — Flat Orchestration | Transposes | `cmd_add` stays a straight pipeline: validate, derive, construct, append, save. No new branching depth. |
| VI — Typed I/O Boundaries | Transposes | The identifier is validated at both boundaries it crosses — supplied on the command line, and read back from a JSON header. |
| VII — Strict Module Isolation | N/A | Single file, no modules. |

**Gate result: PASS.** No violation, no waiver, nothing to justify.

Two repository-level rules also bind this work and are not in the constitution:

- **Docker-only execution.** Every command in tasks and verification runs
  through `docker run … python:3.12-alpine`, never a host interpreter.
- **English-only committed artifacts.** Code, comments, docstrings, the skill
  document and commit messages are in English.

## Project Structure

### Documentation (this feature)

```text
specs/015-grievance-slug-ids/
├── spec.md              # Phase 0 input
├── plan.md              # This file
├── research.md          # Phase 0 output — the seven decisions
├── data-model.md        # Phase 1 output — Identifier, Grievance, Ledger
├── contracts/
│   └── cli-commands.md  # Phase 1 output — the CLI contract that changes
├── quickstart.md        # Phase 1 output — verify the feature by hand
└── tasks.md             # Phase 2 output (/speckit.tasks — not created here)
```

### Source Code (repository root)

```text
skills/grievances/
├── SKILL.md                      # documentation: identifier shape, freeze rule, merge procedure
└── scripts/
    ├── grievances.py             # all behaviour changes
    └── test_grievances.py        # NEW — first test file for this script
```

**Structure Decision**: The feature lives entirely inside the existing
`skills/grievances/` directory. No new module, no new dependency, no change to
where the ledger lives. The single new file is the test file, placed beside the
script it tests so `python3 -m unittest` discovers it from that directory
without packaging.

### Touchpoints inside `grievances.py`

Listed so the task breakdown has concrete anchors rather than a vague "update
the script". Line numbers are as of `3aae427`.

| Line | Symbol | Change |
|---|---|---|
| 77 | `BLOCK_RE` | Widen the identifier group to `GRV-(?:\d{4}|[a-z0-9]+(?:-[a-z0-9]+){1,4})`. Inner groups must stay non-capturing so `\1`, group 2 and group 3 keep their numbers — re-probed at the 5-segment bound. |
| 82 | `ID_RE` | Same widening, but **anchored** — `^…$`. Only the pattern embedded in `BLOCK_RE` is unanchored. A reviewer claimed line 82 holds `COMMIT_RE`; verified false, line 81 does. |
| — | new | `LEGACY_ID_RE`, `SLUG_ID_RE`, `ID_PREFIX`, `ID_MAX_LEN`, `ID_DISCRIMINATOR_LEN`, `STOP_WORDS` constants. |
| — | new | `derive_id(short, taken)` — pure derivation, greedy fill with a conditional discriminator. |
| — | new | `find_conflict_markers(text)` — pure detection. |
| — | new | `MARKER_OPEN_RE` — sweeps `<!-- grievance:` openers, so a marker `BLOCK_RE` rejects is reported rather than skipped. |
| 208 | `Ledger.load` | Three additions before and during block parsing: reject conflict markers; raise on any opener `BLOCK_RE` did not consume; validate each identifier's shape and ceiling. |
| 246 | `Ledger.next_id` | **Delete.** It calls `int(g.id.split("-")[1])`, which raises `ValueError` on any slug identifier. Leaving it in place is a latent crash, not dead code. |
| 390 | `check_id` | Accept both forms; error message names the actual rule. |
| 660 | `cmd_add` | Replace the `ledger.next_id()` call; honour a new `--id` option; refuse on derivation failure; check uniqueness **outside** derivation so a supplied `--id` cannot skip it; require `--id` alongside `--force`, which can no longer do its old job. |
| 967 | `build_parser` | Add `--id` to the `add` subparser. |

`audit_repo` (line 806) and `cmd_migrate` (line 908) need **no** change:
`audit_repo` treats identifiers as opaque strings, and `migrate` imports legacy
content as prose without minting anything. Both facts are worth asserting in
tests so a later refactor cannot break them silently. `audit_repo` also gains
the three new load-time failures for free, because it already catches
`UserError` from `load` at line 830.

## Complexity Tracking

> Not applicable — the Constitution Check passed with no violations.

## Post-design Constitution re-check

*Re-evaluated after Phase 1.* Still **PASS**, unchanged verdict, nothing added
to Complexity Tracking.

The design added no dependency (`unicodedata` is standard library), no module,
and no layer. The three new units — derivation, shape validation, conflict-marker
detection — are pure functions taking their inputs as named parameters and
returning values, which is what Principles III and IV ask for where they
transpose. The one new file is a test file.

One process note surfaced during Phase 1 and belongs in the task list: this
repository's `AGENTS.md` requires `asset-registry.yml` to be updated in the same
change whenever a skill's registered metadata moves. The registry entry for
`skills/grievances/` mirrors the skill's frontmatter description
(`asset-registry.yml:1208`). If the documentation work changes that description,
`make sync-registry` must run in the same commit.
