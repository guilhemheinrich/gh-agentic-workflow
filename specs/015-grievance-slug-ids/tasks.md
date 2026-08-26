---
description: "Task list for merge-safe grievance identifiers"
---

# Tasks: Merge-safe grievance identifiers

**Input**: Design documents from `/specs/015-grievance-slug-ids/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/cli-commands.md, quickstart.md
**Revision**: regenerated after adversarial review — 11 confirmed findings applied, see [reviews/FINDINGS.md](./reviews/FINDINGS.md)

**Tests**: Included. Not a default — decision D7 in [research.md](./research.md) makes
the first test file for this script part of the change. The review round then
justified it twice over: its blocker was a derivation defect that only a probe
could surface.

**Organization**: Grouped by user story. Each story is independently testable.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel — different files, no dependencies
- **[Story]**: US1, US2, US3 from [spec.md](./spec.md)

## Path Conventions

- `skills/grievances/scripts/grievances.py` — all behaviour
- `skills/grievances/scripts/test_grievances.py` — new test file
- `skills/grievances/SKILL.md` — documentation

**`[P]` is rare here on purpose.** Almost every implementation task edits the
same 1061-line file, so most tasks are sequential by construction.

## Running commands

Docker-only, per the repository rule. Tests:

```bash
docker run --rm -v "$PWD:/repo" -w /repo/skills/grievances/scripts python:3.12-alpine python3 -m unittest -v
```

---

## Phase 1: Setup

- [x] T001 Create `skills/grievances/scripts/test_grievances.py` with a `unittest` scaffold that imports the module under test (`import grievances`) and one placeholder assertion; confirm the Docker runner above collects and passes it

**Checkpoint**: the runner works.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The identifier primitives — pure functions and patterns, no command wiring.

**⚠️ CRITICAL**: blocks all three stories.

- [x] T002 Write the identifier-shape tests in `skills/grievances/scripts/test_grievances.py`: `LEGACY_ID_RE` matches `GRV-0001` and rejects `GRV-worker-api`; `SLUG_ID_RE` matches `GRV-db-naming` and `GRV-worker-queue-retry-bug-alpha` (5 segments) and rejects `GRV-worker`, `GRV-Worker-Api`, `GRV-a-b-c-d-e-f`, `GRV-0001`; both patterns are **anchored**, so `GRV-worker-api!!` and `GRV-0001x` are rejected; the two share no accepted string. Must FAIL — the constants do not exist yet
- [x] T003 Write the ceiling test in `skills/grievances/scripts/test_grievances.py`: an identifier of 48 characters made of 5 valid segments matches `SLUG_ID_RE` yet must be rejected by shape validation, because the pattern carries no length bound. Pins review finding 3. Must FAIL
- [x] T004 Write the `BLOCK_RE` structural tests in `skills/grievances/scripts/test_grievances.py`: parsing a ledger holding one legacy and one 5-segment slug entry yields group 1 = identifier, group 2 = JSON, group 3 = body for both; a block whose closing marker names a different identifier yields 0 matches. Must FAIL
- [x] T005 Add the identifier constants to `skills/grievances/scripts/grievances.py` beside the existing regexes (line 76 onward): `ID_PREFIX`, `ID_MAX_LEN = 40`, `ID_DISCRIMINATOR_LEN = 4`, `STOP_WORDS` (the 54-word set published in [data-model.md](./data-model.md) — 48 base plus the 6-word extension), `LEGACY_ID_RE = ^GRV-\d{4}$`, `SLUG_ID_RE = ^GRV-[a-z0-9]+(?:-[a-z0-9]+){1,4}$`. **Both anchored.** Widen `ID_RE` at line 82 to the anchored union. Widen only the identifier group **inside** `BLOCK_RE` at line 77 to the unanchored `GRV-(?:\d{4}|[a-z0-9]+(?:-[a-z0-9]+){1,4})`, with non-capturing inner groups so `\1`, group 2 and group 3 keep their numbers. Pins review finding 10 — never assign the unanchored form to a validation pattern. Makes T002 and T004 pass
- [x] T006 Write the word-selection tests in `skills/grievances/scripts/test_grievances.py`: `"DB naming"` yields `['db', 'naming']` while `"db naming"` yields `['naming']`, because the acronym test reads the **pre-fold** token; `requête` folds to `requete`; the 54-word stop set removes `with`, `will` and `not` from `"worker co-hosted with the API will not scale"`. Pins review finding 7. Must FAIL
- [x] T007 Write the derivation tests in `skills/grievances/scripts/test_grievances.py`, asserting the exact strings from [data-model.md](./data-model.md) and [contracts/cli-commands.md](./contracts/cli-commands.md): `"worker co-hosted with the API will not scale"` → `GRV-worker-hosted-api-scale`; `"DB naming"` → `GRV-db-naming`; `"2FA bypass trap on the npm token"` → `GRV-2fa-bypass-trap-npm-token`; determinism over 5 calls; every result within 40 characters and matching `SLUG_ID_RE`. Must FAIL
- [x] T008 Write the collision tests in `skills/grievances/scripts/test_grievances.py` — **this is the review's blocker, and the most important test in the suite**: all four pairs in [research.md](./research.md) D8 derive different identifiers, including `"the asset registry description drifts from the skill frontmatter title"` versus `"… from the schema enum values"`, which collide under any design without a discriminator. Also assert the discriminator is **absent** when every word fits and **present** when any word was dropped. Must FAIL
- [x] T009 Write the derivation-refusal tests in `skills/grievances/scripts/test_grievances.py`: `"slow"`, `"a"`, `"the the the"` and `"internationalization misconfiguration"` are all refused — the last because two legitimate words exceed the ceiling; each message names the two remedies. Must FAIL
- [x] T010 Implement `significant_words(short)` and `derive_id(short)` in `skills/grievances/scripts/grievances.py` per [data-model.md](./data-model.md) steps 1 to 7. Pure: no clock, no randomness, no filesystem, and **no uniqueness check** — uniqueness is the caller's, on both paths. Makes T006 to T009 pass
- [x] T011 Write the `check_id` tests in `skills/grievances/scripts/test_grievances.py`: both forms accepted; `GRV-Worker-API`, `GRV-worker` and a 48-character identifier rejected; the message names the rule broken and no longer says `expected GRV-NNNN`. Must FAIL
- [x] T012 Update `check_id` (`skills/grievances/scripts/grievances.py:390`) to accept both forms, enforce `ID_MAX_LEN`, and raise a message naming the actual rule. Makes T003 and T011 pass

**Checkpoint**: identifiers can be derived and validated. Nothing declares one yet.

---

## Phase 3: User Story 1 — Two developers declare on sibling branches (Priority: P1) 🎯 MVP

**Goal**: A declaration allocates an identifier from its own description, so two branches from one ancestor cannot collide by construction.

**Independent Test**: Declare one grievance into each of two copies of the same starting ledger, describing different problems — including a pair sharing its first four significant words; assert the identifiers differ and that a merged file loads and lists both.

### Tests for User Story 1

- [x] T013 [US1] Write the sibling-branch test in `skills/grievances/scripts/test_grievances.py`: from one starting ledger, declare a different grievance into each of two copies; assert the identifiers differ and that neither derives from the entry count. Must FAIL
- [x] T014 [US1] Write the sibling-branch **truncation** test in `skills/grievances/scripts/test_grievances.py` using the two `release pipeline npm token …` descriptions, which share their first four significant words. This is the exact trigger the review used to break the first design. Must FAIL
- [x] T015 [US1] Write the merged-ledger test in `skills/grievances/scripts/test_grievances.py`: concatenate both sides' detail blocks into one ledger, load it, and assert both grievances are present and addressable. Must FAIL
- [x] T016 [US1] Write the deliberate-collision test in `skills/grievances/scripts/test_grievances.py`: two declarations with the identical short description derive the identical identifier, and the second is refused with a message naming the recurrence counter. Must FAIL
- [x] T017 [US1] Write the `--id` option tests in `skills/grievances/scripts/test_grievances.py` covering every row of the `add` behaviour table in [contracts/cli-commands.md](./contracts/cli-commands.md): a free descriptive identifier is accepted even when it shares no word with `--short` (FR-004a); `GRV-Worker-API`, `GRV-worker`, `GRV-0099` and a 48-character identifier are each refused with the rule named. Must FAIL
- [x] T018 [US1] Write the supplied-uniqueness test in `skills/grievances/scripts/test_grievances.py`: `--id` naming an identifier already in the ledger is refused. Pins review finding 6 — this path bypassed the check entirely in the reviewed draft. Must FAIL
- [x] T019 [US1] Write the `--force` tests in `skills/grievances/scripts/test_grievances.py`: a duplicate short description is refused; `--force` alone is refused, naming the colliding entry and stating that `--force` needs `--id`; `--force --id GRV-distinct-name` succeeds. Pins review finding 5. Must FAIL

### Implementation for User Story 1

- [x] T020 [US1] Add `--id` to the `add` subparser in `build_parser` (`skills/grievances/scripts/grievances.py:967`), documented as the explicit-naming escape hatch that is exempt from word overlap
- [x] T021 [US1] Rewrite identifier allocation in `cmd_add` (`skills/grievances/scripts/grievances.py:660`): obtain the identifier from `--id` when supplied, otherwise from `derive_id`; validate its shape and ceiling; then check it against the ledger's existing identifiers **on both paths**; refuse a legacy-form `--id` because that form is never minted; require `--id` when `--force` is passed; keep the `--impact` requirement untouched
- [x] T022 [US1] Delete `Ledger.next_id` (`skills/grievances/scripts/grievances.py:246`) — see [research.md](./research.md) D5: its `int(g.id.split("-")[1])` raises an unhandled `ValueError` on any slug identifier, so leaving it is a trap, not dead code. Confirm no call site remains
- [x] T023 [US1] Run `skills/grievances/scripts/test_grievances.py` in the container and confirm T013 to T019 pass

**Checkpoint**: US1 done. The collision the feature exists to remove is gone, including the truncation case.

---

## Phase 4: User Story 2 — Existing ledgers keep working untouched (Priority: P2)

**Goal**: Legacy sequential identifiers stay readable, addressable and unrenamed, alongside new descriptive ones.

**Independent Test**: Take a ledger of legacy identifiers only, run every read and mutate command, and assert no identifier changed value.

### Tests for User Story 2

- [x] T024 [US2] Write the legacy-only round-trip test in `skills/grievances/scripts/test_grievances.py`: load a legacy-only ledger, then close, reopen and increment an entry; assert every command succeeds and the identifier is byte-identical before and after
- [x] T025 [US2] Write the mixed-ledger rendering test in `skills/grievances/scripts/test_grievances.py`: a ledger holding both forms renders both in the open and resolved tables, each linking to an anchor that exists in the document
- [x] T026 [US2] Write the mixed-ledger ordering and idempotency test in `skills/grievances/scripts/test_grievances.py`: tables sort by date with the identifier breaking ties only, and a second consecutive regeneration produces a byte-identical file
- [x] T027 [US2] Write the no-rename guard tests in `skills/grievances/scripts/test_grievances.py` for `audit_repo` and `cmd_migrate`: neither changes any identifier. Both are correct today only because they treat identifiers as opaque strings
- [x] T028 [US2] Write the new-into-legacy test in `skills/grievances/scripts/test_grievances.py`: declaring into a legacy-only ledger mints a descriptive identifier and renumbers nothing

### Implementation for User Story 2

- [x] T029 [US2] Make T024 to T028 pass in `skills/grievances/scripts/grievances.py`. Phase 2 is expected to cover this story with no further production change; if any test needs one, record what and why in this task before changing code, because an unexpected change here means an assumption in [data-model.md](./data-model.md) was wrong.
  **Outcome: no production change was needed.** Phase 2's widened patterns covered
  the whole story. The 6 tests passed against the code as Phase 2 left it, which
  confirms the data-model claim that identifiers are opaque to `audit_repo`,
  `cmd_migrate`, the sort keys and the anchor derivation.

**Checkpoint**: a mixed ledger is fully functional.

---

## Phase 5: User Story 3 — Merge safety and ledger integrity (Priority: P3)

**Goal**: A conflicted, malformed or duplicated ledger fails loudly and actionably instead of misparsing or silently dropping entries; a keep-both resolution normalizes in one command.

**Independent Test**: Hand-build a keep-both merge result with stale generated content, regenerate, and assert the output is correct and no entry was lost. Separately, feed the loader each corruption and assert it names it.

### Tests for User Story 3

- [x] T030 [US3] Write the conflict-marker rejection test in `skills/grievances/scripts/test_grievances.py`: a ledger containing a line starting with `<<<<<<< ` or with `>>>>>>> ` is refused, and the message names the unresolved conflict
- [x] T031 [US3] Write the conflict-marker **guard** test in `skills/grievances/scripts/test_grievances.py`: a bare `=======` line inside author-owned prose loads normally, because it is legal markdown — see [research.md](./research.md) D6. This is a guard against over-eager detection, not a fail-first test; it passes before T035 and must still pass after. Review finding 9 corrected an earlier claim that it "must fail"
- [x] T032 [US3] Write the silent-skip test in `skills/grievances/scripts/test_grievances.py`: a ledger whose three markers include `GRV-worker` and `GRV-Worker-Api` must be **refused**, naming the offending markers. In the reviewed draft those two entries vanished from the model while their text stayed in the file. Pins review finding 2. Must FAIL
- [x] T033 [US3] Write the stored-ceiling test in `skills/grievances/scripts/test_grievances.py`: a well-formed 48-character identifier inside a stored JSON header is refused on load, not only when supplied on the command line. Pins review finding 3. Must FAIL
- [x] T034 [US3] Write the duplicate-identifier test in `skills/grievances/scripts/test_grievances.py`: a ledger carrying one identifier on two entries is refused with a message naming the recovery — keep one entry, increment its recurrence counter, regenerate
- [x] T035 [US3] Write the keep-both normalization test in `skills/grievances/scripts/test_grievances.py`: a file with duplicated and stale generated rows regenerates to correct content with every entry preserved, and a second regeneration changes nothing
- [x] T036 [US3] Write the audit-surfacing test in `skills/grievances/scripts/test_grievances.py`: `audit_repo` reports each of the four load failures as a problem rather than raising

### Implementation for User Story 3

- [x] T037 [US3] Implement `find_conflict_markers(text)` in `skills/grievances/scripts/grievances.py` as a pure function keying on `<<<<<<< ` and `>>>>>>> ` at line start only, never on a bare `=======`
- [x] T038 [US3] Add `MARKER_OPEN_RE` to `skills/grievances/scripts/grievances.py`, matching any `<!-- grievance:` opener regardless of identifier shape, so an opener `BLOCK_RE` did not consume can be detected
- [x] T039 [US3] Extend `Ledger.load` (`skills/grievances/scripts/grievances.py:208`) with four checks, each raising a `UserError` naming the problem and the fix: conflict markers before any parsing; any `MARKER_OPEN_RE` opener not consumed by `BLOCK_RE`; each consumed identifier's shape and ceiling via the shared validator; a duplicate identifier, with the recovery procedure spelled out. All four surface through `audit_repo` for free, because it already catches `UserError` from `load` at line 830
- [x] T040 [US3] Run `skills/grievances/scripts/test_grievances.py` in the container and confirm T030 to T036 pass

**Checkpoint**: all three stories independently functional.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [x] T041 [P] Document the identifier rules in `skills/grievances/SKILL.md` per FR-017: the descriptive shape at 2 to 5 segments, the discriminator and what its presence means, that legacy identifiers coexist and are never minted again, and the freeze rule
- [x] T042 [P] Document the merge-resolution procedure in `skills/grievances/SKILL.md` per FR-018: keep both sides, then regenerate; if both sides share an identifier, keep one entry and increment its recurrence counter, which is the one sanctioned author edit to tool-owned content
- [x] T043 [P] Add hand-editing an identifier to the anti-patterns section of `skills/grievances/SKILL.md` per FR-019, stating that it breaks inbound references from commit messages and specification folders
- [x] T044 [P] Document the new `--force` contract in `skills/grievances/SKILL.md`: it now requires `--id`, because identical descriptions derive identical identifiers
- [x] T045 [P] Update the `--id` option and the `add` examples in the module docstring of `skills/grievances/scripts/grievances.py` (lines 28 to 40) so the usage block matches the real interface
- [x] T046 If T041 to T044 changed the `description` frontmatter of `skills/grievances/SKILL.md`, run `make sync-registry` and commit the `asset-registry.yml` change in the same commit, as `AGENTS.md` requires. If the frontmatter did not change, state that in this task and skip.
  **Outcome: skipped.** `git diff` on the frontmatter shows no change to `name`,
  `description` or `tags`, so `asset-registry.yml` is still in sync
- [x] T047 Run the full suite from `skills/grievances/scripts/` in the container and confirm every test in `test_grievances.py` is green
- [x] T048 Walk [quickstart.md](./quickstart.md) end to end against a scratch repository, including the real two-branch merge in step 3, which no unit test covers because it needs actual git
- [x] T049 Update [quickstart.md](./quickstart.md) for the amended design: the predicted identifiers, the `--force --id` requirement, and the four load-time refusals
- [x] T050 Record the recurrence-counter merge defect as a grievance in `specs/GRIEVANCES.md` via `skills/grievances/scripts/grievances.py add`, using the tool this feature just changed

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 Setup**: no dependencies
- **Phase 2 Foundational**: needs Phase 1 — **blocks all three stories**
- **Phase 3 US1**: needs Phase 2
- **Phase 4 US2**: needs Phase 2. Independent of US1 in principle; both edit `grievances.py`, so sequential unless in separate worktrees
- **Phase 5 US3**: needs Phase 2. Genuinely independent of US1 and US2 — it touches `Ledger.load` and adds two functions
- **Phase 6 Polish**: needs every story it documents

### Within each story

Tests first and failing, then implementation, then a suite run. T031 is the one
exception and says so: it is a guard test that must pass before **and** after.

### Parallel Opportunities

- T041 to T045 are `[P]`: T041 to T044 edit `SKILL.md`, T045 edits the script docstring
- Nothing in Phases 2 to 5 is `[P]` within its own phase — every implementation task edits `grievances.py`, and every test task edits `test_grievances.py`
- Across phases, US3 can be developed in a separate worktree in parallel with US1 and US2

---

## Implementation Strategy

### MVP (User Story 1 only)

Phases 1, 2 and 3. That delivers the whole point: identifiers stop colliding,
truncation case included. Validate with [quickstart.md](./quickstart.md) steps 2
and 3.

### Incremental delivery

1. Phases 1 and 2 → identifiers can be derived and validated
2. Phase 3 → **MVP**: collisions gone
3. Phase 4 → existing repositories safe to upgrade. Ship before Phase 5
4. Phase 5 → corrupt files fail loudly instead of misparsing
5. Phase 6 → documentation, and the follow-up grievance filed

### Order note

Phase 4 outranks Phase 5 for shipping despite the lower story priority, and the
reason is deployability rather than importance: a P3 nicety does not block
release, while an unmigratable existing ledger does.

---

## Notes

- 50 tasks: 1 setup, 11 foundational, 11 for US1, 6 for US2, 11 for US3, 10 polish
- Every command runs in `python:3.12-alpine`; no host interpreter
- Code, comments, docstrings and commit messages in English
- T008 is the single most important test: it pins the review's blocker
- T022 is not cleanup. Skipping it leaves a method that crashes on the new data format
