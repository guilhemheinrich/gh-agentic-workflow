---
name: project-philosophy
description: >-
  Create or amend the PHILOSOPHY.md file at the root of a repository and make
  sure it is referenced from CLAUDE.md and/or AGENTS.md so every agent loads
  it. Use when a project adopts, refines, or replaces a guiding paradigm
  (e.g. data-first, state transitions), when a philosophy skill such as
  philosophy-data-first must be written to the repo, when recording an
  implementation decision a philosophy requires (orchestrator, ORM), or when
  PHILOSOPHY.md exists but agents ignore it. Écrire / amender la philosophie
  du projet.
---

# Project Philosophy

## Purpose

`PHILOSOPHY.md` is the single file, at the repository root, that states **why**
the project is built the way it is: the paradigms humans and AI agents must
respect before any feature, spec or prompt is written. Rules and skills say
*how*; the philosophy says *what we refuse to compromise on*.

This skill is the **procedure** (write, amend, reference). The **content** of a
given philosophy lives in a dedicated `philosophy-*` skill — for instance
`philosophy-data-first`. Use both together.

## Workflow

### 1. Inspect the repository

- Does `PHILOSOPHY.md` exist at the root? Read it entirely before touching it.
- Do `CLAUDE.md` and `AGENTS.md` exist? Note whether `CLAUDE.md` only imports
  `AGENTS.md` (`@AGENTS.md`), in which case `AGENTS.md` is the real entry point.
- Identify the stack (database, language, frameworks): philosophies often
  require implementation decisions that depend on it.

### 2. Write or amend `PHILOSOPHY.md`

New file → start from [references/philosophy-skeleton.md](references/philosophy-skeleton.md)
and insert the content provided by the `philosophy-*` skill.

Existing file → amend, never rewrite blindly:

- Keep the section order of the skeleton: *Philosophies adoptées*, *Principes*,
  *Formats obligatoires*, *Décisions d'implémentation*, *Journal des amendements*.
- A new philosophy is added as a new entry, not merged into an unrelated one.
  If two philosophies conflict, stop and ask the human which one prevails;
  record the arbitration in the principles.
- Weakening or removing a principle is an explicit decision: ask first, then
  log it in *Journal des amendements* (date, change, reason).
- Every decision a philosophy marks as **required** (e.g. job orchestrator,
  ORM) must appear in *Décisions d'implémentation*, either filled in or
  marked `à choisir`. Never leave a required decision silently absent: if it
  is not taken yet, ask the human and propose options.
- Write for both audiences: short imperative principles, a template that can be
  copied into an issue or a spec, one concrete example.

### 3. Reference it from the agent entry points

Agents only follow `PHILOSOPHY.md` if their entry file points to it. Insert the
following block (idempotent: replace the block between the markers if it is
already there) near the top of the file(s):

```markdown
<!-- philosophy:start -->
## Philosophie du projet

Avant toute spec, feature, migration ou prompt majeur, lire et respecter
[`PHILOSOPHY.md`](./PHILOSOPHY.md). En cas de conflit entre une demande et la
philosophie, le signaler explicitement au lieu de trancher silencieusement.
<!-- philosophy:end -->
```

Placement rules:

| Situation | Where to insert |
|---|---|
| `AGENTS.md` and `CLAUDE.md` both have real content | both |
| `CLAUDE.md` only imports `@AGENTS.md` | `AGENTS.md` only |
| Only one of them exists | that one |
| Neither exists | create `AGENTS.md` with the block, and `CLAUDE.md` containing `@AGENTS.md` |

### 4. Verify

```bash
test -f PHILOSOPHY.md
grep -l "philosophy:start" AGENTS.md CLAUDE.md 2>/dev/null
grep -n "à choisir" PHILOSOPHY.md   # pending decisions to report to the human
```

Report to the human: what was added or amended, which entry files reference
the philosophy, and every decision still `à choisir`.

## Anti-patterns

- Copying a philosophy into `AGENTS.md` instead of referencing it: two copies
  drift.
- Philosophy text that names no decision (“use a good ORM”): name the tool
  chosen, or mark it `à choisir`.
- Amending a principle to fit a feature that violates it, without logging it.
