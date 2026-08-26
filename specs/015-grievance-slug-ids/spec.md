# Feature Specification: Merge-safe grievance identifiers

**Feature Branch**: `015-grievance-slug-ids`
**Created**: 2026-08-26
**Status**: Draft
**Input**: User description: "Replace sequential GRV-NNNN grievance IDs with merge-safe slug IDs — two developers branching from a common ancestor always collide on the next number; a three-word phrase describing the grievance would not."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Two developers declare a grievance on sibling branches (Priority: P1)

Two developers branch from the same ancestor. Each finds a distinct non-blocking
problem and records it in the ledger. Both branches merge back. Each grievance
survives the merge with its own identifier, and the ledger stays machine-readable.

**Why this priority**: This is the whole defect. Today the second merge either
raises a noisy conflict that requires renumbering by hand, or — worse — merges
cleanly into two entries carrying the same identifier, at which point the ledger
tool refuses to load the file and every subsequent command fails. A ledger that
blocks is worse than no ledger.

**Independent Test**: Create two branches from one ancestor, declare one
grievance on each, merge both into a third branch, and confirm the two entries
carry different identifiers and that a read command lists both.

**Acceptance Scenarios**:

1. **Given** two branches from a common ancestor, **When** each declares a
   grievance describing a different problem, **Then** the two entries carry
   different identifiers.
2. **Given** both branches merged into one file, **When** any ledger command
   reads the file, **Then** it succeeds and reports both grievances.
3. **Given** a grievance declared on a branch, **When** the identifier is
   allocated, **Then** it is derived only from that grievance's own description
   and never from a count of pre-existing entries.
4. **Given** two developers describing the *same* problem in the *same* words,
   **When** both declare it, **Then** both receive the same identifier, so the
   merge surfaces the duplication instead of hiding it as two entries.
5. **Given** two descriptions long enough that the identifier cannot hold every
   significant word — for example `"release pipeline npm token expires after
   ninety days"` and `"release pipeline npm token bypasses two factor auth"`,
   which share their first four significant words — **When** each is declared on
   its own branch, **Then** the two identifiers still differ.

---

### User Story 2 - Existing ledgers keep working untouched (Priority: P2)

A repository already carries a ledger whose entries use the old sequential
identifiers. Those identifiers are quoted in commit messages, in specification
folders and in cross-references between grievances. After the change, every
command still operates on those entries and none of them is renamed.

**Why this priority**: Identifiers already published outside the ledger cannot
be rewritten without breaking every inbound reference. Renaming them would
trade one merge problem for a much larger traceability problem. Without this
story, the feature is unshippable on any repository that already has a ledger.

**Independent Test**: Take a ledger containing only old-style identifiers, run
every read and mutate command against it, and confirm each succeeds and that no
identifier changed.

**Acceptance Scenarios**:

1. **Given** a ledger of old-style identifiers, **When** the ledger is read,
   **Then** every entry loads and no identifier is rewritten.
2. **Given** an old-style entry, **When** it is closed, reopened, or its
   recurrence counter is incremented, **Then** the command succeeds and the
   identifier is unchanged.
3. **Given** a ledger holding both old-style and new-style identifiers, **When**
   the ledger is read or regenerated, **Then** both forms appear correctly in
   the generated tables and both remain addressable by command.
4. **Given** a new grievance declared into a ledger of old-style identifiers,
   **When** it is allocated an identifier, **Then** it receives a new-style one
   and no existing entry is renumbered.

---

### User Story 3 - Resolving a ledger merge conflict is one command (Priority: P3)

A merge still puts two new entries at the same insertion point, so git reports a
textual conflict. The developer keeps both sides, then runs one command that
normalizes the file — ordering, generated tables, spacing.

**Why this priority**: Story 1 removes the *unresolvable* conflict; a textual
conflict remains and is expected. This story makes its resolution mechanical
rather than a careful hand-edit. Valuable, but the feature already pays for
itself without it.

**Independent Test**: Hand-build a file that looks like a keep-both merge
resolution — duplicated table rows, entries out of order — run the
regeneration command, and confirm the output is a correctly ordered, correctly
tabulated ledger.

**Acceptance Scenarios**:

1. **Given** a file where both sides of a conflict were kept, producing stale or
   duplicated generated content, **When** the regeneration command runs, **Then**
   the generated regions match what the entries imply and no entry is lost.
2. **Given** a file that still contains unresolved conflict markers, **When** any
   command reads it, **Then** it fails with a message naming the conflict and
   telling the developer to resolve it first, rather than misparsing the file.
3. **Given** a merged file, **When** the regeneration command runs twice,
   **Then** the second run changes nothing.

---

### Edge Cases

- **Description too thin to name.** A description yielding fewer than two
  significant words (for example a single common word) must not silently
  produce a one-segment or padded identifier. Automatic derivation refuses and
  says what to do; supplying an identifier explicitly stays available.
- **Description too long.** A long description must be cut at a word boundary,
  never mid-word, and never past the identifier length ceiling.
- **Accented and non-ASCII descriptions.** A French description must yield an
  identifier made only of the permitted characters, with accents folded, not
  stripped into gibberish.
- **Derived identifier already taken in the same ledger.** Two genuinely
  different problems can yield the same derived identifier. The declare command
  must refuse rather than create a second entry the reader cannot tell apart,
  and must say how to proceed.
- **Description reformulated after declaration.** Editing the short description
  of an existing grievance must leave its identifier untouched, so inbound
  references keep resolving. The two are allowed to diverge.
- **Explicitly supplied identifier that is malformed or already used.** Must be
  rejected with a message naming the rule it broke. "Already used" is checked on
  the supplied path exactly as on the derived path.
- **Overriding the duplicate-description guard without naming the grievance.**
  Must be refused. The override cannot work on its own any more, because both
  declarations would derive the same identifier.
- **Two long descriptions sharing their opening words.** The identifier cannot
  hold every significant word of a long description, so a name built only from
  the words that fit is not unique. Two distinct findings that share their
  opening words must still receive different identifiers.
- **A marker whose identifier does not match the documented shape.** Reading
  must report it. Skipping it makes the grievance vanish from the generated
  tables while its text stays in the file — a silent divergence between what the
  document says and what it contains.
- **An identifier that is well-formed but over the length ceiling, present in a
  stored header.** Reading must reject it. A ceiling enforced only when
  declaring is not a ceiling.
- **A description whose first two significant words alone exceed the ceiling.**
  Refused, with the explicit-identifier remedy, like any other description too
  thin to name.
- **Two entries carrying the same identifier in a merged file.** Reading must
  refuse and name the recovery procedure, rather than fail with a bare
  statement that a duplicate exists.
- **Legacy ledger that predates the programmatic format.** The existing
  migration path must keep working and must not attempt to rename anything.

## Requirements *(mandatory)*

### Functional Requirements

**Identifier allocation**

- **FR-001**: The system MUST allocate a new grievance's identifier from that
  grievance's own description, and MUST NOT derive it from the number of
  entries already present in the ledger.
- **FR-002**: The system MUST accept an explicitly supplied identifier for a new
  grievance, and MUST derive one automatically when none is supplied. When
  automatic derivation cannot produce a valid identifier, the system MUST
  refuse and tell the caller to lengthen the description or supply an
  identifier.
- **FR-003**: The system MUST derive identifiers deterministically: the same
  description yields the same identifier on any machine, in any repository, at
  any time.
- **FR-004**: A derived or supplied identifier MUST match a documented shape:
  the reserved prefix, then 2 to 5 lowercase hyphen-separated alphanumeric
  segments, at most 40 characters in total.
- **FR-004a**: A **derived** identifier MUST draw its leading segments from the
  grievance's own description. A **supplied** identifier is exempt: it is the
  escape hatch for a description whose derivation reads poorly, and requiring
  word overlap would defeat it.
- **FR-004b**: When derivation cannot fit every significant word of the
  description within the ceiling, it MUST append a final segment derived from
  the **whole** set of significant words, so that two descriptions sharing only
  their opening words still receive different identifiers. When every
  significant word fits, that segment MUST be absent.
- **FR-005**: The system MUST fold accented and non-ASCII characters to the
  permitted character set when deriving an identifier.
- **FR-006**: The system MUST reject a supplied identifier that violates the
  shape, naming the rule that failed.
- **FR-007**: The system MUST refuse to declare a grievance whose identifier is
  already used in the ledger, and MUST tell the caller how to proceed —
  increment the existing entry's recurrence counter, or supply a distinct
  identifier. This check MUST apply equally to a derived and to a supplied
  identifier: it is a property of the ledger, not of how the name was obtained.
- **FR-007a**: The override that allows declaring a second grievance with an
  existing short description MUST require an explicit identifier. Without one,
  the two declarations derive the same identifier and the override cannot
  succeed, so accepting it alone would promise something the system cannot
  deliver.
- **FR-008**: An identifier MUST be frozen at declaration. Later edits to a
  grievance's short description MUST NOT change it.

**Reading and integrity**

- **FR-020**: The system MUST validate an identifier's shape, including the
  length ceiling, when reading it back from a stored header — not only when it
  is supplied on the command line.
- **FR-021**: The system MUST report a grievance marker whose identifier does
  not match either documented form, rather than skipping the entry.
- **FR-022**: When a loaded ledger carries the same identifier twice, the system
  MUST refuse and name the recovery procedure: keep one entry, increment its
  recurrence counter, and regenerate.

**Backward compatibility**

- **FR-009**: The system MUST read, address, and mutate entries whose
  identifiers use the legacy sequential form.
- **FR-010**: The system MUST NOT rename any existing identifier, in any
  command, including the legacy-format migration path.
- **FR-011**: The system MUST support a ledger containing both identifier forms
  at once, in generated tables, in cross-reference links, and in every command
  that addresses an entry by identifier.
- **FR-012**: The system MUST keep generated in-document links resolving for
  both identifier forms.

**Ordering and generated content**

- **FR-013**: The system MUST keep ordering the generated tables by date, using
  the identifier only to break ties, so no ordering depends on identifiers being
  numeric.
- **FR-014**: Regenerating a ledger MUST be idempotent: a second consecutive
  regeneration changes nothing.

**Merge safety**

- **FR-015**: The system MUST fail with an explicit, actionable message when it
  reads a ledger containing unresolved merge conflict markers, instead of
  parsing the file as if the markers were content.
- **FR-016**: Regenerating a ledger after a keep-both conflict resolution MUST
  restore correct generated content without losing any entry.

**Documentation**

- **FR-017**: The skill documentation MUST state the identifier shape, the
  freeze rule, and the fact that both forms coexist.
- **FR-018**: The skill documentation MUST give the merge-conflict resolution
  procedure: keep both sides, then regenerate.
- **FR-019**: The skill documentation MUST record that hand-editing an
  identifier breaks inbound references and is not supported.

### Key Entities

- **Grievance**: one recorded non-blocking finding. Carries an identifier, a
  short description, a severity, a declaration date, a status, a recurrence
  count, an optional resolution, and free prose owned by the author. The
  identifier is immutable; the short description is not.
- **Identifier**: the stable, human-readable handle for a grievance. Two forms
  exist — the legacy sequential form, read-only and never minted again, and the
  descriptive form, minted from the description at declaration.
- **Ledger**: the per-repository document holding all grievances, part
  human-authored prose and part generated content.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Across 20 pairs of independently declared grievances describing
  different problems, 0 pairs receive the same identifier. At least 5 of those
  pairs must share their first four significant words, so the measurement
  covers the case where the identifier cannot hold the whole description.
- **SC-002**: 100% of ledgers produced by merging two branches that each
  declared one grievance load successfully once the textual merge is resolved.
- **SC-003**: 0 identifiers already present in a ledger change value after the
  upgrade, measured by comparing every identifier before and after running each
  command once.
- **SC-004**: 100% of **derived** identifiers contain at least 2 words taken
  from their own grievance's short description, so a reader can tell what an
  entry is about without opening it. Explicitly supplied identifiers are out of
  this measurement per FR-004a.
- **SC-005**: Resolving a ledger merge conflict takes keeping both sides plus
  exactly 1 command, with no hand-editing of generated content.
- **SC-006**: A ledger carrying unresolved conflict markers produces an error
  naming the conflict in 100% of commands, and never a silent misparse.

## Assumptions

These record decisions taken where the feature description left a choice open.
Each was chosen over the alternative for the stated reason.

- **The reserved prefix stays.** New identifiers keep a fixed prefix rather than
  being a bare phrase. A bare three-word phrase is indistinguishable from
  surrounding prose, which breaks the ability to find every cross-reference to
  grievances across specifications and commit messages by searching for the
  prefix.
- **2 to 4 segments, not exactly 3.** The feature description proposed three
  words. Some findings name themselves in two, others need four. A fixed count
  would force padding or truncation that costs readability, so the rule is a
  range with a length ceiling.
- **Coexistence, not migration.** Existing sequential identifiers are kept as
  they are rather than rewritten to the new form. They are quoted in commit
  messages and specification folders that the ledger cannot reach.
- **Automatic derivation is the default path.** The caller may name a grievance
  explicitly when the derived name reads poorly, but is not required to, so
  declaring stays a one-line action.
- **Identical descriptions colliding is correct behaviour**, not a defect. Two
  developers who describe the same problem identically have found the same
  problem; the collision is the signal, and the resolution is to keep one entry
  and increment its recurrence counter.
- **The textual merge conflict is accepted, not engineered away.** Both sides
  still write near the same point in the document. Eliminating that would mean
  restructuring the document layout, which is a much larger change for a
  conflict that is trivially resolvable once identifiers no longer collide.
- **The recurrence counter's own merge defect is out of scope.** Two branches
  each incrementing the same grievance's counter lose one increment on merge.
  It is the same class of bug and it is real, but it needs a different fix — an
  append-only structure instead of a counter — and folding it in would double
  this feature's surface. It is recorded as a follow-up.
- **A truncated name carries a discriminator; a complete one does not.** A
  readable identifier of bounded length cannot be a unique function of an
  unbounded description — truncation is not a heuristic weakness but a
  mathematical property. The discriminator is therefore conditional: absent when
  every significant word fits, so short names stay clean, and present when
  anything was dropped, where it doubles as a visible signal that the name is
  abbreviated. Always appending one was rejected because it would put an
  unreadable segment on `GRV-db-naming`, which needs none.
- **The ledger's authoring model is unchanged.** Generated regions stay
  generated and author-owned prose stays preserved verbatim; this feature
  changes what an identifier looks like, not who owns which part of the file.
