---
name: data-projection
description: >-
  Show what a change does to a relational database, before it is written, in two
  separate reports whose shape never drifts. The schema view answers which
  tables are touched and what moves structurally — columns, indexes,
  constraints, the migration, whether it is reversible. The effect view answers
  the other question entirely: what one use case does to the data, step by step
  — which rows match, which value replaces which, what refuses to write, and the
  net tally of rows inserted, updated and deleted. Ships
  `scripts/dataproj.py`, which owns every structural decision through closed
  operation vocabularies: an op outside the enum is a validation error, the
  glyphs and tallies are derived, and prose exists in exactly one column. The
  anchors are real, not declarative: task ids must exist in `tasks.md`, every
  declared DDL operation must be found in the migration files it names (raw SQL,
  TypeORM, Alembic — Django and ActiveRecord report as unverifiable rather than
  contradicted), and every write effect must cite the test that proves it. Use
  at the close of `/tasks` on any change that touches persistent data, when
  reviewing a migration, when explaining a use case at the data level, or after
  implementation to detect schema drift. Triggers on "data projection", "what
  does this do to the database", "which tables does this touch", "migration
  review", "what rows change", "schema-projection.md", "effect-projection.md".
tags:
  - spec-kit
  - sql
  - process
  - verification
  - python
---

# Data Projection

Two questions about persistent data, asked at different moments by different
readers, deserve two reports:

| Question | View | Artefact |
| --- | --- | --- |
| Which tables do we touch, and what moves? | `schema` | `specs/NNN-*/schema-projection.md` |
| What does this use case do to the data? | `effects` | `specs/NNN-*/effect-projection.md` |

The second is not a detail of the first. A migration adds a column; a use case
decides which rows get which value, and what stops it. Merging them into one
report buries the answer nobody has: *what actually happens to my rows*.

```text
  tasks.md ──────┐                            ┌─▶ render --write     the artefacts
                 ├─▶ init ─▶ the JSON ─────────┤    English, committed once, final
  data-model.md ─┘   skeleton   ▲  closed enums│
  migrations ────┐              │              └─▶ render --lang --overlay
                 │              │                   the caller's language, chat only
                 │              ├─▶ check    vocabulary · anchors · prose
                 └──────────────┴─▶ verify   declared DDL vs the migrations that landed
```

## 1. What is in this bundle

| File | Role |
| --- | --- |
| `scripts/dataproj.py` | The engine. `schema` and `effects`, each with `init`, `render`, `check`; `schema` also has `verify`. |
| `scripts/test_dataproj.py` | 49 probes on the vocabularies, the derived values, the SQL anchor, the width budget, the language rules. |

Python 3.12, standard library only, Docker-only execution.

```bash
docker run --rm -v "$PWD:/repo" -w /repo/skills/data-projection/scripts python:3.12-alpine python3 -m unittest -v
```

## 2. Why `data-model.md` is not parsed

A survey of three real specs in the fleet found no two sharing a structure:

| Spec | Headings | Column table |
| --- | --- | --- |
| `modelo-analytics/010-user-identification` | `## Entities` → `### 1. UserProfile (ClickHouse)` | `Column \| Type \| Description \| Nullable \| Default` |
| `modelo-analytics/020-cors-origins-management` | `## 1. \`environment_allowed_origins\` (migration 039)` | a different set |
| `modelo_reporting/008-opaque-cube-mode` | `## Interfaces Serveur` | none, and no SQL at all |

A parser over that prose would invent findings, and a fabricated finding is
worse than a missing one. So the declaration is a typed JSON block, and the
anchors live where the ground truth actually is: `tasks.md`, the migration
files, and the test suite.

## 3. View A — the schema

```text
public.enrollment         ★                       the table the feature writes
├── siren                 +  varchar(9) NULL      the SIREN captured on the public form
├── contact_email         +  varchar(255) NULL    the signer's email, until now only readable
│                                                 inside form_data
├── form_data             ~  jsonb, default '{}'  gains 6 prefill keys; no type change
└── idx_enrollment_siren  +  index (siren)        the back-office lookup by SIREN

public.signature_event    ~                       append-only log, no schema change; the use
                                                  case writes one row

public.signature_request  ~                       one column, for a request created outside the
                                                  form
└── siren                 +  varchar(9) NULL      fallback for the path that skips the public
                                                  screen

migration   db/migrations/041_enrollment_siren.sql  (T010, T011)
reversible  yes — down drops both columns and the index
tally       3 tables (0 created, 0 dropped) · 4 objects added · 1 altered · 0 dropped

deliberately NOT touched:
  public.tenant — no tenant-level SIREN in this change
  public.audit_log — written by the existing trigger, no schema change
```

Four columns, and only the last is prose. Closed vocabularies:

| Level | Operations |
| --- | --- |
| Table | `create-table` `drop-table` `rename-table` `alter-table` `referenced` |
| Column | `add-column` `drop-column` `alter-type` `set-not-null` `drop-not-null` `set-default` `drop-default` `rename-column` `backfill` |
| Object | `add-index` `add-fk` `add-check` `add-unique` `add-trigger`, and each `drop-` counterpart |
| Weight | `heavy` → `★` on the table line, else `added` / `touch` |

The glyph is **derived** from the operation — `add-`/`create-` → `+`, `drop-` →
`-`, everything else → `~`. The author picks the operation; the renderer picks
the shape. `tally` is summed, never written, and keeps table-level counts apart
from object-level ones: a created table and an added column are not the same
unit.

## 4. View B — the effects

```text
use case  sign the enrollment form                    FR-004 · T010-T013

  1  UPDATE  public.enrollment             rows: one
     where  token = :token AND signed_at IS NULL
     ├── siren          NULL   → '812345678'                  from the form field, checksum
     │                                                        already passed
     ├── contact_email  NULL   → 'a@b.fr'                     from the form field
     ├── form_data      {...}  → merge 6 keys                 the scalar columns stay
     │                                                        authoritative; this is the audit
     │                                                        copy
     └── signed_at      NULL   → now()                        the signature timestamp, and the
                                                              guard for a second submission

  2  INSERT  public.signature_event        rows: one
     ├── enrollment_id         ← step 1                       the row step 1 completed
     ├── kind                  = 'signed'
     └── payload               = the 6 prefill values as sent
                                                              kept verbatim, for the dispute
                                                              path

  guard  the SIREN fails the checksum      → nothing is written, step 1 never runs
  guard  the enrollment is already signed  → nothing is written, the predicate on signed_at
                                             matches no row

  net effect  public.enrollment: UPDATE ×1 · public.signature_event: INSERT ×1   (DELETE ×0)
```

| Field | Vocabulary |
| --- | --- |
| Operation | `insert` `update` `upsert` `delete` `soft-delete` `read` `no-op` |
| Cardinality | `one` `zero-or-one` `many` `one-per-input` |
| Value arrival | `value` → `→` · `from-step` → `←` · `literal` → `=` |

Three rules the script enforces so the topology holds:

1. **The predicate lives on its own line, always.** Inlining it makes a header
   whose width depends on how long the author's `WHERE` is.
2. **`from-step` carries a step number, not prose.** `after: "step 1 key"` is a
   validation error; the explanation belongs in `intent`, which is
   translatable.
3. **`net effect` is summed in SQL keywords.** `UPDATE ×1` needs no plural
   agreement in any language, and `(DELETE ×0)` is printed even when nothing is
   deleted — *what disappears* is the reader's first question.

## 5. The anchors

| Anchor | View | Behaviour |
| --- | --- | --- |
| Task ids | both | Every migration and use case cites tasks; `check` fails on an id absent from `tasks.md`. |
| Migration SQL | schema | Every declared operation must be found in the files it names. Missing → `contradicted`. |
| Unreadable DDL | schema | A migration this script cannot parse yields `unverifiable`, never a contradiction. |
| Cited test | effects | Every write effect names `path::test name`; `check` fails if the file or the name is absent. |
| Cross-view | effects | Every table an effect writes must appear in the schema projection. |
| `not_touched` / `guards` | schema / effects | Non-negotiable. `check` fails while either is empty. |

The SQL anchor reads raw SQL (Prisma, golang-migrate, plain psql), the SQL
TypeORM inlines inside `queryRunner.query`, and Alembic's `op.*` helpers —
including its `op.alter_column`, which folds type, nullability, default and
rename into one call. Django and ActiveRecord migrations are out of reach and
say so.

Real runs on a fixture reproducing spec 071:

```text
note: SQL anchor: 5 declared operation(s) confirmed in the migrations
schema projection honest
```

```text
note: SQL anchor: 3 declared operation(s) confirmed in the migrations
contradicted: public.enrollment.form_data declares alter-type, no matching statement in the migrations
contradicted: public.enrollment.idx_never_written declares add-index, no matching statement in the migrations
```

The cross-view anchor earned its place on the first run of the reference
example, where it caught a table the effect view wrote and the schema view had
never mentioned:

```text
unknown table: sign the enrollment form step 2 writes public.signature_event, absent from the schema projection
```

## 6. The loop

**Step 1 — the skeleton.** Re-runnable; existing prose survives.

```bash
docker run --rm -v "$PWD:/repo" -w /repo python:3.12-alpine python3 skills/data-projection/scripts/dataproj.py schema init --spec specs/071-siren-signature --write
```

**Step 2 — fill the JSON.** Operations from the enums, one intent line per row,
the tasks that implement each migration, `not_touched` for the schema view, and
`guards` plus a cited test per effect.

**Step 3 — render and check.** `render --write` regenerates the report;
`check` is the commit gate.

```bash
docker run --rm -v "$PWD:/repo" -w /repo python:3.12-alpine python3 skills/data-projection/scripts/dataproj.py effects check --spec specs/071-siren-signature
```

**Step 4 — hand it over in the caller's language.** Write the translated prose
to an overlay **outside the repository**, then render with it.

```bash
docker run --rm -v "$PWD:/repo" -v "$SCRATCH:/tmp/ovl" -w /repo python:3.12-alpine python3 skills/data-projection/scripts/dataproj.py effects render --spec specs/071-siren-signature --lang fr --overlay /tmp/ovl/fr.json
```

```json
{
  "use_cases": {
    "sign the enrollment form": {
      "name": "signer le formulaire d'adhésion",
      "effects": [
        {"where": "token = :token AND signed_at IS NULL",
         "fields": {"siren": "depuis le champ du formulaire"}},
        {"values": {"payload": "les 6 valeurs de préremplissage telles que reçues"}}
      ],
      "guards": [{"when": "la clé de contrôle du SIREN échoue",
                  "then": "rien n'est écrit, l'étape 1 ne tourne pas"}]
    }
  }
}
```

Effects and guards are addressed by position — the step order is part of the
declaration, so it is a stable key. `fields` translates the intent column,
`values` translates a descriptive literal.

**Step 5 — commit the final artefacts, once.** Both files ship with the change,
in English, after `check` passes. A skeleton full of `TODO` stays out of the
index.

**Step 6 — the after-shot.** Once the migration is written, re-run the SQL
anchor:

```bash
docker run --rm -v "$PWD:/repo" -w /repo python:3.12-alpine python3 skills/data-projection/scripts/dataproj.py schema verify --spec specs/071-siren-signature
```

## 7. Language, and the commit rule

Identical doctrine to the [change-projection](../change-projection/SKILL.md)
skill, enforced the same way:

- **The committed artefact is English.** `check` probes every intent, guard and
  reason for markers of the conversation's language — 31 high-signal words plus
  any accented character — and names the offending words. `--skip-language` is
  the escape hatch for prose that legitimately quotes a French UI string.
- **The rendered report speaks the caller's language.** `--lang fr|en|es`
  translates the chrome; `--overlay` substitutes the prose for that one render.
  Table names, column names and SQL keywords are never translated — they are
  identifiers.
- **One commit, at the end.** `render` refuses `--write` together with `--lang`
  or `--overlay`.

```text
refusing to write a translated report: the committed artefact is English.
Drop --write to render for the conversation, or drop --lang/--overlay.
```

## 8. Limits, stated

- **Relational, and PostgreSQL-shaped.** The vocabulary assumes tables,
  columns, indexes and constraints. A ClickHouse `ReplacingMergeTree` or a
  document store fits badly; declare it as `referenced` and put the truth in
  the intent line rather than bending the enums.
- **The SQL anchor proves existence, not correctness.** `ADD COLUMN siren` is
  confirmed whether the type is `varchar(9)` or `text`. The `shape` column is
  documentation the anchor does not verify.
- **The effect view is a declaration checked by a test reference.** The script
  verifies that the test exists and names what it claims, not that it asserts
  the values in the report. That last mile stays human.
- **One overlay per language, keyed by name and position.** Renaming a use case
  or reordering the steps orphans its translations, silently.
- **No `data-model.md` sync.** The two views neither read nor update it. If the
  entity table there disagrees with the schema projection, no tool will say so.

## 9. Definition of done

A reviewer handed the two reports answers, without opening anything else: which
tables this change touches and how deeply, whether the migration goes back, and
for each use case which rows change, from what to what, and what refuses to
write.

## Implementation Status

**Fully Implemented.** `scripts/dataproj.py` ships both views with `init`,
`render`, `check`, plus `verify` on the schema view, and 49 passing probes.
Exercised end to end on a fixture reproducing spec 071: 5 declared operations
confirmed against a real migration file, contradictions and unverifiable
migrations distinguished, Alembic helpers read, both reports rendered in English
and French, and every rendered line held under the 96-character budget in all
three languages.
