---
name: eza-file-overview
description: >-
  Show which files a change touched, at a glance, in a chat transcript or in a
  terminal. Ships git-impacted.sh, which turns any git range — or the working
  tree — into a directory-grouped list where every path is a clickable markdown
  link carrying its status and its +added/-removed tail, and eza-docs.sh, a
  version-keyed local cache of eza's own help and man pages so nothing here
  paraphrases the binary. Documents the four things eza cannot do (no commit
  range, no deleted files, no annotation column, colour globs match the basename
  only) and the one that matters most: ANSI colour, OSC 8 hyperlinks and Nerd
  Font icons are terminal features that arrive as literal garbage in a chat. Use
  when reporting the files an AI iteration created or modified, rendering a file
  tree with per-file semantics, colouring a listing with EZA_COLORS, or looking
  up an eza flag.
tags:
  - shell
  - git
  - tooling
  - documentation
---

# eza File Overview

Its first job: after an iteration, answer *"what did this touch?"* in one glance —
what is new, what changed, what disappeared — with every path clickable so the
reader lands in the file instead of hunting for it.

eza does part of that work beautifully and part of it not at all. The split is
worth learning once:

```text
                        ┌──────────────────────────────────────────┐
  a git range ─────────▶│  git-impacted.sh                         │
  or the working tree   │  status · directory grouping · +/- tail   │
                        └───────────────┬──────────────────────────┘
                                        │
                    ┌───────────────────┴───────────────────┐
                    ▼                                       ▼
              --md  (a chat)                          --term  (your shell)
        markdown links, plain text                eza --long: sizes, dates,
        no ANSI, no icons                         icons, grouped by status
```

## 1. What is in this bundle

| File                      | Role                                                        |
| ------------------------- | ----------------------------------------------------------- |
| `scripts/git-impacted.sh` | The workhorse. Any git range → annotated, clickable listing. |
| `scripts/eza-docs.sh`     | Version-keyed cache of `eza --help` and its three man pages. |
| `INSTALL.md`              | Per-platform install. Read it only if `eza` is missing.      |

## 2. Documentation: looked up, never paraphrased

This skill deliberately contains no flag reference. eza ships 86 lines of
`--help` and 956 lines of man pages; copying any of it here would guarantee a
version where the copy is wrong. Query the cache instead:

```bash
scripts/eza-docs.sh --grep hyperlink
```

```bash
scripts/eza-docs.sh --grep 'two-letter code' colors
```

```bash
scripts/eza-docs.sh --show help
```

The cache is keyed on `eza --version`, because help text changes when the binary
changes and not on a clock — a stale entry is detected by comparison, not by
guessing a TTL. `--status` reports what is cached; `--list` shows the four pages;
`--refresh` forces a rebuild. A 30-day TTL is kept as a backstop for local builds
whose version string never moves.

**Rule of thumb:** if the question is "which flag does X", grep the cache. If the
question is "how do I show a change set", the rest of this file answers it.

## 3. The one thing to know before printing anything

A terminal and a chat transcript are not the same output device, and eza's best
features belong to the first:

| eza feature        | In your terminal          | In a chat transcript                        |
| ------------------ | ------------------------- | ------------------------------------------- |
| `--color=always`   | colour                    | literal `[32m` noise — the escape is stripped |
| `--hyperlink=always` | clickable OSC 8 link    | `^[]8;;file:///…^[\` garbage                |
| `--icons=always`   | glyphs, with a Nerd Font  | tofu for anyone without the font            |
| `--long` columns   | aligned                   | aligned only inside a code fence, which kills links |

So the chat rendering uses **markdown links and plain words**, never eza's
decoration. `git-impacted.sh` picks the right one by looking at stdout: a pipe or
a file means an agent is capturing it, so `--md`; a TTY means a human is reading
it, so `--term`. Override either way with the explicit flag.

What actually makes a path clickable in a transcript is a relative markdown link,
optionally with a line number:

```markdown
[llm-ask.sh](skills/openrouter-adversarial-review/scripts/llm-ask.sh) — and to land on a line, skills/…/llm-ask.sh:283
```

❌ **Counter-example.** `eza --hyperlink=always` looks like the answer to
"clickable links" and is not: it emits terminal escapes for a file:// URL. In a
transcript you get the escape sequence; in a code fence you get it verbatim.

## 4. Case: the files in a git range

```bash
scripts/git-impacted.sh HEAD~1 HEAD
```

```bash
scripts/git-impacted.sh main...HEAD --limit 30
```

```bash
scripts/git-impacted.sh          # no range: staged + unstaged + untracked
```

The range is whatever `git diff` accepts. Output, on a real repository:

```text
**5 file(s)** — 2 new, 1 modified, 1 renamed, 1 deleted _(HEAD~1 HEAD)_

`docs/`
- **new** [added.md](docs/added.md) · +1 -0

`src/`
- **deleted** `delete-me.ts` · +0 -1
- **modified** [keep.ts](src/keep.ts) · +1 -0
- **renamed** [renamed.ts](src/renamed.ts) ← `src/rename-me.ts`

`src/deep/`
- **new** [brand-new.ts](src/deep/brand-new.ts) · +1 -0
```

Status leads each line so the shape of the change reads without parsing paths.
Directories are grouped and ordered, so a 40-file diff still scans. The deleted
file is deliberately **not** a link: there is nothing to open.

❌ **Counter-example — `eza --git` is not a range.** It reports the working-tree
status of each file (`-M`, `-N`, `--`) and has no notion of two commits. This is
the whole reason the script exists:

```bash
eza --long --git src/        # working tree only, never HEAD~1..HEAD
```

❌ **Counter-example — eza cannot show a deleted file.** It is a filesystem
lister, and the path is gone:

```text
$ eza src/delete-me.ts
"src/delete-me.ts": No such file or directory (os error 2)   # exit 2
```

Any range view that leans on eza alone silently loses every deletion — the single
most important category when reviewing what an agent did.

## 5. Case: any file set, with per-file semantics

For a terminal listing where file *kinds* should read differently, `EZA_COLORS`
takes `glob=ANSI` pairs on top of the usual two-letter codes:

```bash
EZA_COLORS='*.spec.ts=38;5;208:*.md=38;5;42:Dockerfile=38;5;33:*.lock=38;5;240' eza --long --no-permissions --no-user src/
```

Read that as a semantic palette: tests orange, docs green, container files blue,
lockfiles greyed out because nobody reviews them. `scripts/eza-docs.sh --grep
'two-letter code' colors` documents the code half.

❌ **Counter-example — the glob matches the basename, not the path.** Verified on
v0.23.5:

```bash
EZA_COLORS='brand-*=38;5;196'   eza --color=always src/deep/brand-new.ts   # applies
EZA_COLORS='*/brand-*=38;5;196' eza --color=always src/deep/brand-new.ts   # ignored
EZA_COLORS='src/deep/*=38;5;196' eza --color=always src/deep/brand-new.ts  # ignored
```

So "colour this one directory differently" is not expressible. Semantics travel by
naming convention — `*.spec.ts`, `*.generated.*`, `*.lock` — which is a decent
argument for naming conventions and a bad one for fighting the tool.

❌ **Counter-example — `--tree` on a file list flattens it.** eza builds a tree by
walking a directory, not by reconstructing one from paths:

```bash
eza --tree docs/added.md src/deep/brand-new.ts src/keep.ts
# docs/added.md
# src/deep/brand-new.ts
# src/keep.ts        ← three flat lines, no hierarchy
```

To show a hierarchy for an arbitrary set, group by directory yourself — which is
what `--md` does.

### Always hand over the command

A markdown listing ends with a bare command line, emitted **by the script** rather
than left to whoever is driving it. A listing a reader cannot regenerate is a
screenshot.

```text
bash ~/lab/myrepo/skills/eza-file-overview/scripts/git-impacted.sh -C ~/lab/myrepo main --heat
```

Three deliberate choices, each one a mistake made first:

| Choice                  | Why                                                                    |
| ----------------------- | ---------------------------------------------------------------------- |
| `bash` + full path      | Nothing installed, nothing on `PATH`, no `cd` first, no thinking — and immune to a lost executable bit, which editing tools reset to 644 whenever they write a temp file and move it into place. The path names the copy that actually ran. |
| `-C <repo>`             | The script resolves git from its working directory. `-C` carries the repository inside the single command, so the line survives a paste from anywhere and changes no shell state. |
| `--md` **stripped**      | Whoever pastes this has a terminal, and a terminal should get the coloured rendering. The markdown above already *is* the transcript view of the same data; forcing `--md` would hand a human the one mode with no colour in it. |

No label, no code fence: in a terminal those are three lines of ceremony around
one useful line. A relayer wraps it in a fence; the script does not.

`--no-command` suppresses it. `--term` never prints it — a reader in a terminal is
the person who typed the command.

### Ranking by volume: `--heat`

The one thing eza's gradient cannot key on is how much a file changed —
`--color-scale` accepts `all | age | size`, so it shades by bytes on disk or by
mtime, never by a diff. `--heat` fills that gap: it ranks by lines added and
shades each entry by bucket.

```bash
scripts/git-impacted.sh origin/main --heat
```

```text
**5 file(s)** — 4 untracked, 1 modified _(origin/main → working tree)_

heat by lines added, steps `10,50,150,500`

- `▆`   +315  [skills/eza-file-overview/scripts/git-impacted.sh](…) — untracked
- `▆`   +298  [skills/eza-file-overview/SKILL.md](…) — untracked
- `▅`   +129  [skills/eza-file-overview/scripts/eza-docs.sh](…) — untracked
- `▃`    +42  [skills/eza-file-overview/INSTALL.md](…) — untracked
- `▃`    +19  [asset-registry.yml](…) — modified
```

Intensity travels as a block character in markdown and as 256-colour blue
(`45 39 33 27 21`, light to deep) in `--term`, for the reason in §3: a transcript
strips ANSI. `--heat` drops the directory grouping on purpose — it answers "where
did the volume go", and that ranking fights a per-directory layout.

Boundaries are configuration, not a formula, because the useful thresholds differ
wildly between a bugfix and a new module:

```bash
scripts/git-impacted.sh main...HEAD --heat-steps 50,150,400,800
```

`GIT_IMPACTED_HEAT_STEPS` presets it. Five buckets, so four boundaries; the
default `10,50,150,500` suits review-sized diffs and compresses badly on freshly
written code, where everything lands in the top two.

**Untracked files are counted, without touching the index.** `git diff --numstat`
knows nothing about a file git has never seen, so a new file would rank at +0 —
exactly backwards, since new files are usually the point. The script runs `wc -l`
on them instead. The tempting alternative, `git add -N .`, would work too but
mutates the index as a side effect:

```bash
# equivalent as a one-liner, at the cost of an index you must reset afterwards
git add -N . && git diff --numstat -M origin/main | sort -rn | awk '{n=$(1)+0; c=(n>=100?21:n>=50?27:n>=20?33:n>=10?39:n>=1?45:240); printf "\033[38;5;%dm%6s  %s\033[0m\n", c, "+"n, $(3)}'; git reset -q
```

## 6. Case: a metadata line behind each file

eza has **no annotation column**. Its `--long` columns are fixed (size, dates,
permissions, git status, inode, blocks…), and none of them accepts arbitrary text.
So the metadata tail is the wrapper's job:

```bash
scripts/git-impacted.sh HEAD~1 HEAD          # · +12 -3 after each entry
scripts/git-impacted.sh HEAD~1 HEAD --no-stat # drop it
```

`+12 -3` comes from `git diff --numstat`, joined onto the status rows. A pure
rename reports `+0 -0`, which says nothing, so it is suppressed and replaced by
`← old/path`.

When the useful metadata is filesystem metadata rather than diff metadata, that is
exactly what eza is for, and `--term` uses it:

```bash
scripts/git-impacted.sh HEAD~1 HEAD --term
```

```text
new (2)
   4 5 minutes docs/added.md
   4 5 minutes src/deep/brand-new.ts

modified (1)
   8 5 minutes src/keep.ts

deleted (1)
  src/delete-me.ts        ← printed plainly; eza would exit 2 on it
```

One `eza --long` invocation per status group: eza supplies size and relative age,
the grouping supplies the range semantics eza has no concept of.

To annotate with something eza cannot know — a purpose, a spec id, a review verdict
— pipe the markdown through your own join. The output is line-oriented on purpose:

```bash
scripts/git-impacted.sh main...HEAD | sed 's|^\(.*llm-ask\.sh.*\)$|\1 — the client|'
```

## 7. Anti-patterns

| Anti-pattern                                            | Why it fails                                                       |
| ------------------------------------------------------- | ------------------------------------------------------------------ |
| `eza --color=always` in output an agent will capture     | Escapes arrive as literal `[32m`; you have made the listing harder to read, not easier. |
| `eza --hyperlink` to get clickable paths in a chat       | OSC 8 is a terminal protocol. Use a markdown link. §3.             |
| `eza --icons` in shared output                           | Renders as tofu for anyone without a Nerd Font.                    |
| `eza --git` to describe a commit range                   | Working-tree status only. §4.                                      |
| Listing a change set with eza alone                      | Every deleted file vanishes, and deletions are half the review. §4. |
| `EZA_COLORS` keyed on a directory path                   | Globs match the basename. §5.                                      |
| `eza --tree file1 file2`                                 | Flattens. §5.                                                      |
| Pasting a 400-file diff into the chat                    | Not a glance. `--limit N` truncates loudly with a count.            |
| Showing a listing without the command that made it | The reader has a picture they cannot regenerate. The script prints the line; relay it. §5. |
| Copying flag documentation into this file                | It goes stale silently. Grep the cache. §2.                        |
| `ls` when a git-aware view is wanted                     | Neither `ls` nor `eza` knows what the last commit changed.          |

## 8. See also

- [makefile-conventions](../makefile-conventions/SKILL.md) — where a `make impacted` target would live if this becomes a routine step.
- [openrouter-adversarial-review](../openrouter-adversarial-review/SKILL.md) — the same file set, sent to another model for review rather than displayed.

---

## Implementation Status

**Fully implemented and verified against eza v0.23.5.**

`git-impacted.sh` was exercised on a purpose-built fixture repository carrying all
five statuses at once — added, modified, deleted, renamed (`R100`) and untracked —
plus a repository-root file, and on this repository's own five-commit range (40
files, 19 new / 4 modified / 17 deleted). Checked: both render modes, mode
auto-selection by `[ -t 1 ]`, directory grouping and ordering, the `+adds -dels`
tail joined from `--numstat` including the `dir/{old => new}` rename spelling,
suppression of a meaningless `+0 -0`, deletions rendered without a link, `--limit`
in both modes with a truncation notice, `--no-stat`, an empty change set, an
invalid range (exit 2) and running outside a git repository (exit 2).

Three bugs were found and fixed during that pass: a repository-root file shifted
every column, because a tab is IFS whitespace and `read` folds runs of them, so
the empty leading field vanished — the row now carries `./` explicitly; `--limit`
was silently ignored in markdown mode; and once an ADDS column was joined onto
each row, the same IFS-whitespace fold hit the empty OLD field of every
non-renamed file, zeroing the volume for all of them. The row separator is now US
(0x1f), which is not IFS whitespace, so an empty middle field is no longer
representable as a bug.

`eza-docs.sh` caches 1042 lines across four pages (`--help` 86, `eza` 432,
`eza_colors` 293, `eza_colors-explanation` 231). Verified: cold build, version
mismatch detected and auto-refreshed on next use, `--grep` across all pages and
scoped to one, `--show`, `--list`, `--status`.

Every eza limitation asserted in §3–§5 was reproduced on this machine rather than
assumed: the working-tree-only `--git` column, exit 2 on a deleted path, flattened
`--tree` on a file list, basename-only colour globs, the OSC 8 escape emitted by
`--hyperlink=always`, and ANSI arriving as literal text in captured output.

**Not verified:** Windows. `git-impacted.sh` is bash and assumes `git`, `awk`,
`sed` and `sort`; under Git Bash it should behave, but no Windows machine was
available to confirm it.
