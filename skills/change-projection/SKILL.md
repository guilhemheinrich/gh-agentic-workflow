---
name: change-projection
description: >-
  Hand the human a spatial view of a change before a single line is written —
  the file tree the implementation is about to touch, one line of intent per
  file, and an explicit list of what it leaves alone. A `tasks.md` is ordered by
  execution; a reviewer of scope thinks in space, and only one of the two
  projections was ever produced. Ships `scripts/projection.py`, which derives
  the file set from `tasks.md` (so the projection cannot claim a file no task
  edits), renders a chat-safe tree with the weight of each file signalled,
  checks the projection against the task list, and runs the after-shot — the
  same projection diffed against `git diff --name-only` once the code lands, so
  unplanned scope and silently skipped tasks both surface for the cost of one
  diff. Enforces the two language rules rather than trusting them: the
  committed artefact is final and English, so `check` probes the intents for
  non-English prose and `render` refuses to write a translated tree, while the
  tree pasted into the conversation is rendered in the caller's language
  through `--lang` and a throwaway overlay. Use at the close of `/tasks`, after
  any scope change, when negotiating what to cut from a feature, or after
  implementation to detect drift. Triggers
  on "projection", "what will this touch", "scope review", "which files does
  this change hit", "drift detection", "unplanned scope", "projection.md".
tags:
  - spec-kit
  - process
  - verification
  - documentation
  - python
---

# Change Projection

A `tasks.md` answers *in what order*. It never answers *where, and how deeply*.
Those are two projections of the same change, and a human reviewing scope needs
the second one.

The projection is also the cheapest scope-negotiation surface available. On the
session this skill comes from — a public signature form gaining a SIREN field —
the task list held 32 items across 7 phases and the projection held 9 files on
25 lines. The human read the projection, not the task list, and answered two
questions in one exchange: which two files carry the weight, and which one can
still be cut.

```text
  tasks.md ──┐                                      ┌─▶ render --write      the artefact
             ├─▶ scaffold ──▶ projection.md ────────┤    English, committed once, final
  plan.md ───┘   file set,    JSON = truth          │
                 weight hint       │                └─▶ render --lang --overlay
                                   │                     the caller's language, chat only
                                   │
                                   ├─▶ check    honest? English? gate before the commit
                                   │
  git diff --name-only ────────────┴─▶ verify   unplanned scope · skipped tasks
```

## 1. What is in this bundle

| File                        | Role                                                      |
| --------------------------- | --------------------------------------------------------- |
| `scripts/projection.py`     | The engine. `scaffold`, `render`, `check`, `verify`.      |
| `scripts/test_projection.py`| 39 probes on the path filter, the chain collapse, brace expansion, the guide bars, the two language rules. |
| `specs/NNN-*/projection.md` | The artefact it writes, in the spec directory, committed. |

Python 3.12, standard library only. Run it through Docker, per the repository's
Docker-only execution policy.

```bash
docker run --rm -v "$PWD:/repo" -w /repo/skills/change-projection/scripts python:3.12-alpine python3 -m unittest -v
```

## 2. The seven properties

1. **Derived, never improvised.** The file set comes from `tasks.md` alone. The
   projection therefore cannot claim a file no task edits, nor omit one a task
   does. `plan.md` is read only to report what it names and no task carries
   out — that divergence is itself a finding.
2. **Grouped by directory.** Space, not execution order. The deepest common
   prefix becomes the root line, and every single-child chain folds into one
   line: `app/` → `(public)/` → `enroll/` → `[token]/` carries no information as
   four lines.
3. **One line of intent per file**, in domain words. No task ids, no
   requirement ids, no branch names — those live in `tasks.md` and stay there.
4. **Relative weight signalled.** The reader must tell a 200-line rewrite from
   a 2-line addition without opening anything.
5. **An explicit "not touched" section.** Non-negotiable. It answers the
   reader's real question — *does this leak into the back office?* — and
   `check` fails while it is empty.
6. **Chat-safe rendering.** No ANSI colour, no OSC 8 hyperlink, no Nerd Font
   icon. Each of those is a terminal feature that reaches a chat transcript as
   literal garbage. Same constraint as the `eza-file-overview` skill, same
   reason.
7. **Bookkeeping separated** from the files carrying logic, so the reader is not
   counting `PROGRESS.md` as part of the change.

## 3. The vocabulary

Three weights, one glyph each, plus a derived marker:

| Marker | Meaning                                                       |
| ------ | ------------------------------------------------------------- |
| `★`    | `heavy` — load-bearing. The change actually happens here.     |
| `+`    | `added` — new code, nothing existing rewritten.               |
| `~`    | `touch` — a few lines inside existing code.                   |
| `NEW`  | The file does not exist yet. Read off disk, never asserted.   |

`scaffold` suggests a weight from the number of tasks landing in the file: 4 or
more → `heavy`, 2 or 3 → `added`, 1 → `touch`. That is a proxy, and the author
is expected to correct it — a single task can rewrite 200 lines.

Three roles: `logic` and `test` are drawn in the tree, `bookkeeping` is listed
under it. `scaffold` classifies by pattern (`PROGRESS.md`, `stats.md`,
lockfiles, anything under a spec directory) and the author overrides in the
JSON.

## 4. The loop

**Step 1 — derive the skeleton.** Run it at the close of `/tasks`, and again
after any scope change; intents already written survive, and a file no task
edits any more is reported as `scope shrank`.

```bash
docker run --rm -v "$PWD:/repo" -w /repo python:3.12-alpine python3 skills/change-projection/scripts/projection.py scaffold --spec specs/071-siren-signature --write
```

**Step 2 — write the intents.** Edit the JSON block inside
`specs/071-siren-signature/projection.md`, never the tree. Fill `intent` for
every file, add a `dirs` note where a directory needs one line of context, and
fill `not_touched` — the section the reader came for.

**Step 3 — re-render and check.** `render --write` rewrites the tree from the
JSON. `check` exits non-zero while any intent is still `TODO`, any task path is
missing, `not_touched` is empty, or an intent was written in the conversation's
language instead of English.

```bash
docker run --rm -v "$PWD:/repo" -w /repo python:3.12-alpine python3 skills/change-projection/scripts/projection.py render --spec specs/071-siren-signature --write
```

```bash
docker run --rm -v "$PWD:/repo" -w /repo python:3.12-alpine python3 skills/change-projection/scripts/projection.py check --spec specs/071-siren-signature
```

**Step 4 — hand it over in the caller's language.** Write the translated intent
lines to an overlay **outside the repository** — the scratchpad — and render
with it. Paste the result into the conversation, then stop and wait. The
projection exists to be argued with; carry on implementing only once the human
has answered.

```bash
docker run --rm -v "$PWD:/repo" -v "$SCRATCH:/tmp/ovl" -w /repo python:3.12-alpine python3 skills/change-projection/scripts/projection.py render --spec specs/071-siren-signature --lang fr --overlay /tmp/ovl/fr.json
```

The overlay is a flat map, keyed by the same paths:

```json
{
  "dirs": {"apps/web/app/(public)/enroll/[token]/": "l'écran public, avant signature"},
  "files": {"apps/web/app/(public)/enroll/[token]/actions.ts": "le deuxième gros morceau. Nouveaux refus, écrit contactEmail + siren + fusion form_data."},
  "not_touched": {"apps/back-office/": "aucun écran back-office ne lit ni n'écrit siren"}
}
```

**Step 5 — commit the final artefact, once.** `projection.md` is committed
with the rest of the change, in its reviewed state. A scaffold full of `TODO`
is a draft and stays out of the index; passing `check` is the gate.

## 5. What the output looks like

Real projection, spec 071, `render` on the committed JSON:

```text
apps/web/
│
├── app/(public)/enroll/[token]/       ← the public screen, before signature
│   ├── actions.ts                     ★ the second heavy one. New refusals, writes
│   │                                  contactEmail + siren + form_data merge.
│   │
│   ├── page.tsx                       + 6 prefill values read from form_data, falling back
│   │                                  to the scalar columns. ~15 lines.
│   │
│   └── SignatureInfoForm.tsx          ★ the heavy one. SIREN field + email field, 6
│                                      prefilled inputs, arrival lookup.
│
├── src/
│   ├── i18n/locales/{fr,en,es}/
│   │   └── common.json                ~ 7 keys. Not optional — the locale coverage check
│   │                                  fails both ways.
│
│   └── lib/
│       └── createSignatureRequest.ts  ~ two lines, only buys the fallback for a path
│                                      outside this feature.
└── tests/e2e/
    └── enroll-siren.spec.ts           + NEW — the journey: prefilled form, SIREN refused,
                                       SIREN accepted.

bookkeeping — not part of the change:
  specs/071-siren-signature/PROGRESS.md — phase log

deliberately NOT touched:
  apps/back-office/ — no back-office screen reads or writes siren in this change
  packages/db/schema.prisma — the columns already exist; no migration
```

A brace group stays one line, because it carries one intent:
`src/i18n/locales/{fr,en,es}/common.json`. `verify` expands it to three real
paths when matching the diff.

## 6. The after-shot

Run the same projection against the change that actually landed. Files touched
but not projected are unplanned scope. Files projected but untouched are tasks
silently skipped. Both cost one `git diff --name-only` to detect, and that is
the reason the projection is derived and structured rather than prose.

The Python image carries no git, so the caller pipes the change set in:

```bash
git diff --name-only main..HEAD | docker run --rm -i -v "$PWD:/repo" -w /repo python:3.12-alpine python3 skills/change-projection/scripts/projection.py verify --spec specs/015-grievance-slug-ids --changed-from -
```

Real run, this repository, spec 015 against its merge commit:

```text
after-shot — specs/015-grievance-slug-ids: 25 path(s) changed
  unplanned scope: .cursor/rules/specify-rules.mdc — touched, never projected
  unplanned scope: .gitignore — touched, never projected
  unplanned scope: AGENTS.md — touched, never projected
```

Three files nobody planned, all three real: the spec added a `.gitignore` entry
for Python bytecode and recorded itself in the agent context. `verify` exits 1
on any drift, so a CI job or a review gate can consume it. Changes inside the
spec's own directory are excluded by default; add `--ignore GLOB` for anything
else that churns outside the projection's remit.

## 7. Language, and the commit rule

Two rules meet here, and the script enforces the boundary rather than trusting
it.

**The committed artefact is English.** `projection.md` is a repository file.
`check` probes every intent and every `not_touched` reason for markers of the
conversation's language — 31 high-signal words plus any accented character —
and fails with the offending words named. `--skip-language` exists for an
intent that legitimately quotes a French UI string.

```text
not English: skills/grievances/SKILL.md — ajoute, dans, fichier, le, les.
The committed artefact is English; translate at render time.
```

**The rendered tree speaks the caller's language.** `--lang fr|en|es`
translates the strings the renderer owns — `NOUVEAU`, `intendance`,
`délibérément PAS touché` — and `--overlay` substitutes the intent lines for
that one render. Nothing translated is stored.

**One commit, at the end.** Only the final artefact is committed. `render`
refuses `--write` together with `--lang` or `--overlay`, so a translated tree
cannot reach the file by accident:

```text
refusing to write a translated tree: the committed artefact is English.
Drop --write to render for the conversation, or drop --lang/--overlay.
```

The same tree as section 5, rendered for a French caller:

```text
apps/web/
│
├── app/(public)/enroll/[token]/       ← l'écran public, avant signature
│   ├── actions.ts                     ★ le deuxième gros morceau. Nouveaux refus, écrit
│   │                                  contactEmail + siren + fusion form_data.
│   │
│   ├── page.tsx                       + 6 valeurs de préremplissage lues dans form_data,
│   │                                  avec repli sur les colonnes scalaires. ~15 lignes.
│   │
│   └── SignatureInfoForm.tsx          ★ le gros morceau. Champ SIREN + champ email, 6
│                                      champs préremplis, recherche d'arrivée.
│
├── src/
│   ├── i18n/locales/{fr,en,es}/
│   │   └── common.json                ~ 7 clés. Pas optionnel — le contrôle de couverture
│   │                                  des locales échoue dans les deux sens.
│
│   └── lib/
│       └── createSignatureRequest.ts  ~ deux lignes, n'achète que le repli pour un parcours
│                                      hors de cette fonctionnalité.
└── tests/e2e/
    └── enroll-siren.spec.ts           + NOUVEAU — le parcours : formulaire prérempli, SIREN
                                       refusé, SIREN accepté.

intendance — ne fait pas partie du changement :
  specs/071-siren-signature/PROGRESS.md — journal de phase

délibérément PAS touché :
  apps/back-office/ — aucun écran back-office ne lit ni n'écrit siren dans ce changement
  packages/db/schema.prisma — les colonnes existent déjà ; pas de migration
```

The translated line carries its own size hint: the overlay drops the English
`size_hint`, otherwise `~15 lines.` lands under `~15 lignes.`.

## 8. Limits, stated

- **Path extraction reads inline code spans only.** A task that names a file in
  plain prose is invisible. Backtick every path in `tasks.md`; the discipline
  costs nothing and `check` reports the omission either way.
- **The `plan.md` tree parser is best-effort.** A plan is prose and its Project
  Structure block is drawn for humans. When no tree parses, `scaffold` says so
  rather than reporting a divergence that does not exist.
- **The weight hint is a task count, not a line count.** Correct it.
- **The language probe is a word list, not a language detector.** It carries 31
  markers and an accent test. An English intent quoting `à la carte` trips it;
  `--skip-language` is the escape hatch. The 7 real intents of the section 5
  example are pinned as non-matches, so the list cannot drift into noise.
- **It replaces nothing yet.** The candidate is the "Files changed" table in
  `plan.md`, which arrives 100 lines into a technical document and goes unread.
  Removing it is a separate decision.

## 9. Definition of done

A human handed only the projection answers three questions without opening
another file: how big is this change, where does it land, and what does it
leave alone.

## Implementation Status

**Fully Implemented.** `scripts/projection.py` ships all four subcommands, with
39 passing probes in `scripts/test_projection.py`. Exercised on this
repository: `scaffold` and `check` on `specs/015-grievance-slug-ids`, `render`
on the spec 071 example above, and `verify` against the spec 015 merge commit,
which surfaced three genuinely unplanned files.

Two bugs the probes now pin, both found this way: a folded directory chain read
its dict key instead of the child's name and lost `enroll/[token]/`, and a
projected directory sitting on the common prefix dropped its own intent line.
