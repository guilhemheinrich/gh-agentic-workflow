---
name: cursor-adversarial-review
description: >-
  Get a spec, a diff or a design attacked by a panel of models from different
  lineages, through the Cursor CLI (`cursor-agent`), from the command line. The
  symmetric counterpart of openrouter-adversarial-review, and a better fit for
  code: the reviewer is an agent that reads files itself, so context arrives as
  a staged workspace rather than as text pasted into a prompt, and a finding
  comes back as `path:line` that opens in your editor. Covers the login, the
  workspace-trust gate, the read-only `--mode ask` guarantee, and the two traps
  that make a naive `cursor-agent -p` review worthless — piped stdin is silently
  discarded, and user-level hooks and skills are injected into every call. Ships
  `cursor-review.sh`, which stages `-f` files, `-d` directories, `--diff` and
  `--changed` into an ephemeral workspace, materialises stdin into a file the
  agent can actually read, fans a panel of one-model-per-vendor lanes out
  concurrently with `--panel 3 --exclude-vendor anthropic`, and bounds the whole
  run rather than just one request. Use when asking another model to attack your
  work, reviewing a change outside the agent that produced it, running a
  multi-model panel over one code context, or debugging a `cursor-agent` call
  that returns a confident review of nothing.
tags:
  - llm
  - quality
  - security
  - shell
  - tooling
  - verification
---

# Cursor Adversarial Review

The model that wrote a diff is the worst judge of it: it shares every assumption
that produced the bug. A review by a *different lineage* surfaces what no amount
of self-review will — and through the Cursor CLI it is one subscription, one
command, and a model id you can swap in a string.

This is the counterpart of [openrouter-adversarial-review](../openrouter-adversarial-review/SKILL.md),
and the difference is not the URL. `cursor-agent` is an **agent**, not a
completions endpoint. It reads files itself, from a workspace, with its own
tools. So context is *staged as files* rather than embedded as text — which is
why a finding comes back as `src/tax.py:3` instead of "line 3 of the second
block you pasted".

```text
  spec + plan ─────────┐
  git diff ────────────┼──▶ cursor-review.sh ──▶ ephemeral workspace ──▶ N lanes
  changed files ───────┤          │                                        │
  stdin ───────────────┘          │                                        ▼
                        stage, manifest, fan out            GPT · Gemini · Grok · Kimi
                        read-only, budget, exit codes       one review file per lane
                                                            (candidates — never a verdict)
```

## 1. What is in this bundle

| File                            | Role                                                        |
| ------------------------------- | ----------------------------------------------------------- |
| `scripts/cursor-review.sh`      | The client. Staging, panel selection, dispatch, reporting.  |
| `scripts/test-cursor-review.sh` | Regression suite. Offline; asserts bounds, not answers.     |
| `templates/adversarial.md`      | The review charter. Refutation, citations, scope discipline.|

## 2. Setup: log in once per machine

The CLI is `cursor-agent`, not `cursor` — `cursor` is the editor launcher and
knows nothing about any of this.

```bash
curl https://cursor.com/install -fsS | bash
```

```bash
cursor-agent login
```

Confirm, and note the account: the panel bills against **that** subscription.

```bash
cursor-agent status
```

```text
✓ Logged in as you@example.com
```

Then put the client on your PATH:

```bash
install -m 755 ~/.claude/skills/cursor-adversarial-review/scripts/cursor-review.sh ~/.local/bin/cursor-review.sh
```

### No key to export, and what that changes

There is no `OPENROUTER_API_KEY` equivalent to leak, which removes a whole class
of setup problem — and creates a smaller one. Authentication is **not** a file
under `~/.cursor`: running with a different `HOME`, or with a curated
`~/.cursor` containing every entry except hooks and skills, both report
`Not logged in`. `CURSOR_CONFIG_DIR` leaves auth intact but changes nothing else
(§9). So the reviewer runs as *you*, with your machine's whole Cursor
configuration attached. Budget for that rather than trying to strip it.

`CURSOR_API_KEY` (or `--api-key`) exists for CI, where no interactive login is
possible. That is the one path that does involve a secret; treat it like any
other, and never in a project-scope config file that gets committed.

## 3. Verify before spending anything

```bash
cursor-review.sh --doctor
```

Binary, version, login, reachable model count — and an audit of what your
machine will inject into every review whether you want it or not (§9). Costs
nothing.

```bash
cursor-review.sh --list-models kimi
```

```text
kimi-k3-low
kimi-k3-high
kimi-k3-max
kimi-k2.7-code
```

Live ids. They drift, and this is the only trustworthy source for them. A bad
id is not a silent failure — `cursor-agent` exits 1 and prints the full list.

```bash
cursor-review.sh --dry-run --panel 3 --exclude-vendor anthropic --changed HEAD~1 -d specs/012 "Attack this."
```

Stages everything, prints the resulting workspace tree, the assembled prompt and
the exact per-lane command, and calls nothing.

## 4. The review itself

The charter does the work. Ask for a verdict and you get flattery; ask for
refutation and you get findings. Reviewing an implementation against its spec:

```bash
cursor-review.sh --no-stdin --panel 3 --exclude-vendor anthropic --changed HEAD~1 -d specs/012 -s @adversarial.md -o reviews "Does this change implement specs/012/spec.md? Attack it."
```

```text
cursor-review: 3 lane(s) [gpt-5.6-sol-high gemini-3.7-flash-high cursor-grok-4.6-high] · mode ask · staged in /var/folders/…/cursor-review.2QCnP7 · budget 545s

gpt-5.6-sol-high                      622 bytes  reviews/review-gpt-5.6-sol-high.md
gemini-3.7-flash-high                 938 bytes  reviews/review-gemini-3.7-flash-high.md
cursor-grok-4.6-high                  602 bytes  reviews/review-cursor-grok-4.6-high.md

reviews in reviews/ — candidates, not a verdict. Verify each finding against the code.
```

Reviews land in `-o`, which defaults to a timestamped directory in the working
directory. That is one untracked directory per run, so add `cursor-review-*/` to
the repository's ignore file, or point `-o` somewhere already ignored.

`--exclude-vendor anthropic` is the flag that matters most: reviewing Claude's
output, you want everything *except* Claude. Reviewing Cursor Composer's, drop
`cursor`. `--no-stdin` states the intent when nothing is being piped in (§7.1).

Reviewing a spec before any code exists — no diff, just documents:

```bash
cursor-review.sh --no-stdin --panel 2 --exclude-vendor anthropic -d specs/012 -s @adversarial.md "Which of these requirements is untestable as written?"
```

`templates/adversarial.md` is the charter, and its load-bearing paragraphs are
the ones that bound the review rather than direct it: cite `path:line`, stay
inside `REVIEW-CONTEXT.md`, ignore ambient context, say `no defect found` rather
than invent one, and label unfounded claims `SPECULATIVE`.

Three rules for consuming the output, each learned the expensive way:

- **It is a list of candidates, not a verdict.** A confident third-party model is
  wrong about as often as a confident first-party one. Every finding gets checked
  against the code before it changes anything.
- **Keep it out of the loop that produced the code.** Feeding the review straight
  back into the authoring agent produces an argument between two models instead
  of a decision by a person.
- **Read the lanes against each other.** Three lanes naming the same missing
  guard is a different signal from one lane naming it alone. The panel is worth
  running precisely because that disagreement is visible.

## 5. Staging: the context boundary is the review boundary

`cursor-agent` reads files. So `cursor-review.sh` builds an **ephemeral
workspace** under `$TMPDIR`, copies the context into it at the paths it occupies
in your repository, writes a manifest, and runs every lane there:

```text
/var/folders/…/cursor-review.2QCnP7/
├── REVIEW-CONTEXT.md          the manifest — what was staged, and the instruction
├── review-context/
│   └── diff.patch             output of `git diff HEAD~1`
├── specs/012/spec.md          -d specs/012
└── src/tax.py                 --changed, in full, at its repository path
```

Paths are preserved on purpose. A finding that reads `src/tax.py:3` is a place
you can open; a finding that reads `staged_file_2:3` is a place you have to
decode.

| Flag              | Stages                                                          |
| ----------------- | --------------------------------------------------------------- |
| `-f PATH`         | One file, at its repository-relative path. Repeatable.           |
| `-d PATH`         | A directory, recursively, skipping `.git`, `node_modules`, `.venv`. |
| `--diff [REF]`    | `git diff REF` as `review-context/diff.patch`. Default `HEAD`.   |
| `--changed [REF]` | The diff **and every file it touches, in full**.                 |
| stdin             | Materialised as `review-context/stdin.patch`. §7.1.              |
| `--add-dir PATH`  | An extra workspace root, read in place, not copied.              |
| `--in-place`      | No staging: the reviewer gets your repository.                   |

**`--changed` is the sweet spot.** A hunk without its enclosing function is the
main source of false positives: the model flags an uninitialised variable that
was initialised twenty lines above the hunk. Staging the changed files in full
costs a few thousand tokens and removes that class of finding.

**`--in-place` is the one to reach for last.** A reviewer given the whole
repository reviews the whole repository: you asked about one change and get
fifteen remarks on files you never touched. Use it when the question genuinely
is repository-wide — "does anything else call this the old way?" — and accept
the noise.

To widen past the changed files without drifting, add *callers*, not everything:
`spaghetti-compass impact <file> -c . --json` yields the reverse-impact set, and
each path in it is one more `-f`.

### Cost, and why there is no price table here

Nothing in this skill can quote a price. The Cursor CLI bills against a
subscription rather than per call, and exposes no rate card; there is no
`--dry-run` arithmetic to do. What it *does* expose, under `--json`, is the
per-call token usage:

```json
{"type":"result","subtype":"success","is_error":false,"duration_ms":35065,
 "result":"…","session_id":"…","request_id":"…",
 "usage":{"inputTokens":12497,"outputTokens":1158,"cacheReadTokens":66365,"cacheWriteTokens":0}}
```

Note `cacheReadTokens`: on a measured trivial call, 66365 cached tokens arrived
before your instruction did. That is the ambient context of §9, and it is on
every lane of every panel.

Building a file list means a loop, and **the shell matters**:
`$(printf ' -f %s' *.md)` word-splits in bash but arrives as one argument in zsh
and fish, where the script rejects it with `unknown option`.

```bash
set ctx; for f in specs/012/*.md; set -a ctx -f $f; end; cursor-review.sh --panel 2 $ctx "Review this spec set."
```

That is fish. In bash it is an array:

```bash
ctx=(); while IFS= read -r f; do ctx+=(-f "$f"); done < <(find specs/012 -name '*.md'); cursor-review.sh --panel 2 "${ctx[@]}" "Review this spec set."
```

## 6. Choosing the panel without knowing model ids

Cursor publishes no benchmark scores, so there is no `--top … --by coding` to
rank against — that ranking is OpenRouter's, and it is the one thing the sibling
skill does better. What Cursor gives instead is a live catalogue of about 200
ids, from which `--panel N` picks **one model per vendor**, flagship first,
resolved against the live list so a retired id is skipped rather than turned
into a 404:

```bash
cursor-review.sh --panel 4 --exclude-vendor anthropic --dry-run -f src/tax.py "x"
```

```text
cursor-review: 4 lane(s) [gpt-5.6-sol-high gemini-3.7-flash-high cursor-grok-4.6-high kimi-k3-max] · …
```

Vendors are inferred from the id prefix, and that mapping is the whole ranking
model:

| Prefix                  | Vendor      |
| ----------------------- | ----------- |
| `claude-*`              | `anthropic` |
| `gpt-*`, `codex-*`      | `openai`    |
| `gemini-*`              | `google`    |
| `cursor-grok-*`         | `xai`       |
| `kimi-*`                | `moonshot`  |
| `glm-*`                 | `zhipu`     |
| `composer-*`            | `cursor`    |

One model per vendor is deliberate: a panel needs distinct lineages, not three
checkpoints of one family. Mixing `-m` and `--panel` is allowed — `-m` entries
are added first, duplicates collapse.

Ids carry their reasoning effort as a suffix (`-low`, `-medium`, `-high`,
`-xhigh`, `-max`) and sometimes `-fast`. For a review, prefer `-high` and up:
the failure you are paying to find is the one a cheap pass walks past. The
preference list in the script is ordered accordingly, and is the one place to
edit when a new flagship lands.

## 7. Script reference

Every flag, and the environment variable that presets it:

| Flag                   | Env                            | Default   | Effect                                                        |
| ---------------------- | ------------------------------ | --------- | ------------------------------------------------------------- |
| `-m, --model ID`       | —                              | —         | A lane. Repeatable. Required unless `--panel`.                |
| `--panel N`            | —                              | `0`       | N models, one per vendor, flagship first. §6.                 |
| `--exclude-vendor V`   | —                              | —         | Drop a vendor. Repeatable. Your own lineage.                  |
| `--mode ask\|plan`     | —                              | `ask`     | Read-only agent mode. §7.3.                                   |
| `-s, --system TEXT`    | —                              | —         | Review charter, prepended. `@path` reads it from disk.        |
| `-f, --file PATH`      | —                              | —         | Stage a file. Repeatable. §5.                                 |
| `-d, --dir PATH`       | —                              | —         | Stage a directory. Repeatable. §5.                            |
| `--diff [REF]`         | —                              | `HEAD`    | Stage `git diff REF`. §5.                                     |
| `--changed [REF]`      | —                              | `HEAD`    | The diff plus every file it touches, in full. §5.             |
| `--add-dir PATH`       | —                              | —         | Extra workspace root, passed through. Repeatable.             |
| `--in-place`           | —                              | off       | Review the current repository, no staging. §5.                |
| `--stdin`              | —                              | auto      | Always read stdin, waiting for EOF. §7.1.                     |
| `--no-stdin`           | `CURSOR_REVIEW_NO_STDIN=1`     | auto      | Never read stdin. What an agent or a cron job wants. §7.1.    |
| `-o, --out DIR`        | —                              | timestamp | Where the review files land.                                  |
| `--jobs N`             | `CURSOR_REVIEW_JOBS`           | `3`       | Concurrent lanes.                                             |
| `--timeout S`          | `CURSOR_REVIEW_TIMEOUT_S`      | `900`     | Per-lane wall clock. §7.2.                                    |
| `--budget S`           | `CURSOR_REVIEW_BUDGET_S`       | derived   | Ceiling on the **whole run**, armed at start-up. §7.2.        |
| `--json`               | —                              | off       | Keep each lane's raw `cursor-agent` JSON result.              |
| `--keep`               | —                              | off       | Keep the staged workspace, and print its path.                |
| `--dry-run`            | —                              | off       | Stage, print tree, prompt and commands — call nothing.        |
| `--doctor`             | —                              | —         | Environment and ambient-context audit. Costs nothing. §9.     |
| `--list-models [F]`    | —                              | —         | Live model ids, substring-filtered.                           |
| `-v, --verbose`        | `CURSOR_REVIEW_VERBOSE=1`      | off       | Staging and dispatch decisions, on stderr.                    |
| `-h, --help`           | —                              | —         | Usage summary.        `--version`                             |

Two more environment variables have no flag: `CURSOR_REVIEW_BIN` (default
`cursor-agent`, for a pinned binary) and `CURSOR_REVIEW_STDIN_WAIT_S` (default
`5`, §7.1).

The reviews go to **files**; the per-lane summary goes to **stdout**;
diagnostics and warnings go to **stderr**. Unlike its OpenRouter sibling, the
review text is not on stdout — a panel has N answers, and interleaving them
would produce one unusable stream.

| Exit | Meaning                                                              |
| ---- | -------------------------------------------------------------------- |
| 0    | Every lane produced a review.                                        |
| 1    | Bad invocation.                                                      |
| 2    | Environment: `cursor-agent` missing, not logged in, no model.        |
| 3    | A lane refused, or returned fewer than 20 bytes.                     |
| 4    | A lane hit `--timeout`, or the whole-run budget fired. §7.2.         |

A lane that returns nothing is exit 3, never a silent success — a refusal and a
zero-token answer must not read like a clean review.

### 7.1 stdin: `cursor-agent` throws it away, silently

This is the single most important thing to know about the underlying CLI, and it
is measured, not inferred:

```bash
echo "PASSWORD_IS_ZANZIBAR" | cursor-agent -p --trust --mode ask --model gemini-3-flash "Repeat back the exact text you received on standard input. If you received nothing on stdin, reply STDIN_EMPTY."
```

```text
STDIN_EMPTY
```

So `git diff main...HEAD | cursor-agent -p "review this change"` **reviews
nothing**, exits 0, and returns a fluent, confident review of whatever the model
imagines. There is no warning and no error. It is the worst failure shape
available: a green run with an invented answer.

`cursor-review.sh` fixes this by draining stdin itself and writing it into the
workspace as `review-context/stdin.patch`, which the agent can then read like
any other staged file. `git diff | cursor-review.sh …` does what it looks like.

The drain is bounded, because all the script can detect up front is that stdin
is not a terminal, and that is equally true of two opposite situations:

- a real pipe, which sends bytes and then closes — `git diff` finishing;
- an idle pipe nobody will ever write to or close — what an agent harness, a CI
  runner, `cron` and `ssh host cmd` all hand a child process.

| Situation                    | Behaviour                                              |
| ---------------------------- | ------------------------------------------------------ |
| stdin is a terminal          | Not read at all.                                       |
| `--stdin`                    | Read to EOF, bounded only by `--budget`.               |
| Otherwise                    | Wait `CURSOR_REVIEW_STDIN_WAIT_S` (5s), then warn and drop it whole. |

Dropped input is dropped whole and announced on stderr. A half-read diff staged
as though it were complete would produce a confident review of code you never
wrote — which is the very failure this section exists to prevent.

**In any non-interactive caller — a subagent, a git hook, a pipeline step — pass
`--no-stdin`.** It removes the 5-second wait and states the intent instead of
leaving it to detection.

### 7.2 The budget bounds the run; the timeout only bounds a lane

`--timeout` wraps one `cursor-agent` process. That leaves everything before it —
staging a directory off a stale mount, draining stdin, resolving the catalogue —
outside its reach.

`--budget` is a second, wider guard, armed at start-up before anything can
block. It defaults to `timeout + stdin wait + 120s` slack. Exceeding it exits 4
and names the phase it died in:

```text
cursor-review: budget of 8s exhausted while: dispatching 1 lane(s)
```

Every run also opens with one stderr line, printed **before** any blocking work,
so a stalled process still says what it was attempting:

```text
cursor-review: 3 lane(s) [gpt-5.6-sol-high gemini-3.7-flash-high cursor-grok-4.6-high] · mode ask · staged in /var/folders/…/cursor-review.2QCnP7 · budget 545s
```

Two defects found while building this, both worth knowing if you write your own:
a watchdog that `sleep`s for the whole budget keeps the caller's stderr open, so
`cursor-review.sh … | head` hangs long after the script has died of SIGPIPE; and
a backgrounded lane does the same unless it closes its inherited descriptors.
Both are fixed here — the watchdog polls the parent every second and exits with
it, and each lane runs with its fds closed — and both are the reason a naive
`… &` panel script hangs your terminal.

**Do not shrink `--timeout` to fail fast.** A reasoning-tier model handed a real
review context routinely works for several minutes; a timeout that fires early
throws away an answer you have already waited for. Measured latencies on this
machine: 10–45s for a trivial call, 24s wall clock for a 3-lane panel over a
two-file context.

### 7.3 Read-only is enforced, and worth relying on

`--mode ask` and `--mode plan` are read-only, and `cursor-review.sh` never
passes `-f`, `--force` or `--yolo`. Verified rather than assumed — asked in
`ask` mode to overwrite a file and create another:

```text
I'm currently in Ask mode, which means I can only provide information and
guidance without making any changes to your files or system.
```

The target file was byte-identical afterwards and the new file was never
created. That guarantee is what makes `--in-place` tolerable at all: a reviewer
loose in your repository can read it, and cannot touch it.

### 7.4 Workspace trust

`cursor-agent` refuses to run non-interactively in a directory it has not been
told to trust:

```text
⚠ Workspace Trust Required
```

It exits **1** with empty stdout, which is honest — but a caller that only
checks for output sees an empty review rather than an error. `cursor-review.sh`
passes `--trust` for the staged workspace, which it created itself moments
earlier and whose entire contents you named on the command line. With
`--in-place`, `--trust` applies to your repository, which you already trust.

## 8. Failure modes

| Symptom                                             | Cause                                                             |
| --------------------------------------------------- | ------------------------------------------------------------------ |
| A fluent review of code that was never sent          | Piped stdin was discarded by `cursor-agent`. §7.1.                 |
| `⚠ Workspace Trust Required`, exit 1, no output      | Missing `--trust` in a non-interactive run. §7.4.                  |
| `Cannot use this model: …` + the full catalogue      | Id drifted or was mistyped. `--list-models`.                        |
| `Not logged in`                                      | `cursor-agent login`. Auth is not portable across `HOME`. §2.       |
| A review that discusses your unrelated projects      | User-level hooks or skills injected into the prompt. §9.            |
| Findings about files you never staged                | `--in-place`, or an `--add-dir` wider than you meant. §5.           |
| The lane returns in 3s with two sentences            | The charter asked for a verdict, not a refutation. §4.              |
| `budget … exhausted while: <phase>`                  | The whole-run guard fired. The phase names what blocked. §7.2.      |
| A piped invocation hangs after the script exits      | A background child still holding the pipe. Fixed here; §7.2.        |
| `no model — pass -m ID … or --panel N`               | `--exclude-vendor` removed every candidate.                         |

## 9. What the reviewer sees that you did not send

A staged review keeps your repository out of the reviewer's context. It cannot
keep your **machine** out of it. `cursor-agent` injects user-level configuration
into every call, and this is measured, not theoretical — asked only to say `OK`,
a lane in an empty directory answered:

```text
OK.

J'ai bien noté l'état du Tiger Bus : 13 fils sont au-delà de leur échéance …
```

That text came from a user-level Cursor hook, and arrived alongside a catalogue
of 171 user-level skills. `--doctor` inventories exactly what your machine will
attach:

```text
ambient context injected into EVERY review (not suppressible):
  hooks      : /Users/…/.cursor/hooks.json — hook events below run for every lane
               - beforeShellExecution
  skills     : 91 user-level SKILL.md, their names and descriptions are in the system prompt
  rules      : 43 user-level .mdc (only alwaysApply ones are injected)
  mcp        : /Users/…/.cursor/mcp.json — servers here are offered to the reviewer as tools
```

`CURSOR_CONFIG_DIR` does not help: pointed at a curated directory it keeps you
logged in and injects the real configuration anyway. A sandboxed `HOME` drops
the injection and the login with it. So there is no clean switch, and the honest
mitigations are two:

1. **Bound the review in the charter.** `templates/adversarial.md` has a
   paragraph doing exactly this — ignore anything that did not arrive through
   the staged files. It is not a guarantee, and it measurably helps.
2. **Know what is attached** before you read a finding that came out of nowhere.
   That is what `--doctor` is for.

If your `~/.cursor/mcp.json` holds a server with credentials — a SonarQube token,
a Jira account — those tools are offered to every lane of every panel. Decide
once whether that is acceptable.

## 10. What leaves the building

A spec or a diff sent through `cursor-agent` leaves your network, reaches
Cursor, and is routed onward to an upstream vendor. Decide once, per repository,
whether that is acceptable — then keep secrets, `.env` files, customer data and
credentials out of the staged workspace regardless. Staging is what gives you
that control: `--changed` sends the files you touched, where `--in-place` sends
whatever the reviewer decides to open. `cursor-review.sh --dry-run` prints the
exact tree before anything is sent, and that is the moment to look.

## 11. Cursor or OpenRouter?

Both skills answer the same question and neither replaces the other.

| Use                                        | Reach for                                    |
| ------------------------------------------ | --------------------------------------------- |
| Reviewing code, a diff, a repository       | **Cursor** — the reviewer reads files and cites `path:line`. |
| Reviewing a document with no repository    | Either; OpenRouter is one process fewer.      |
| Picking a reviewer by benchmark score      | **OpenRouter** — `--top 5 --by coding`. Cursor publishes none. |
| Knowing the price before you send          | **OpenRouter** — `--dry-run` prices it. Cursor is subscription-billed. |
| A model Cursor does not carry              | **OpenRouter** — 400-odd models against 200-odd. |
| No per-token billing relationship          | **Cursor** — the subscription already exists.  |
| Answer straight to stdout, one model       | **OpenRouter** — `llm-ask.sh … > review.md`.  |
| A concurrent panel over one code context   | **Cursor** — `--panel 3`, one file per lane.  |

Running both is a defensible panel of its own: two gateways, two sets of
lineages, and no shared failure mode between them.

## 12. Anti-patterns

| Anti-pattern                                             | Why it fails                                                        |
| -------------------------------------------------------- | ------------------------------------------------------------------- |
| `git diff \| cursor-agent -p "review this"`              | stdin is discarded; you get a confident review of nothing. §7.1.     |
| Reviewing with the same model that wrote the code        | Shares the blind spot that produced the bug. `--exclude-vendor`.     |
| Treating the output as a verdict                         | It produces candidates. Verification is not optional.                |
| Feeding the review back into the authoring agent         | Two models arguing; nobody decides.                                  |
| `--in-place` by default                                  | The reviewer reviews the whole repo and buries the change. §5.       |
| Staging the diff without the changed files               | Hunks without their enclosing function produce false positives. §5.  |
| Passing `--force` or `--yolo` to get "a better review"   | Grants write access to a process whose job is to read. §7.3.         |
| Assuming a staged workspace isolates the reviewer        | Your hooks, skills and MCP servers come along regardless. §9.        |
| Shrinking `--timeout` to fail fast                       | You wait for a reasoning model, then throw its answer away. §7.2.    |
| Trusting a per-lane timeout to bound the run             | It bounds a lane. Anything before it needs `--budget`. §7.2.         |
| A background lane that inherits the caller's stdout      | The pipeline hangs after the script is gone. §7.2.                   |
| Hardcoding model ids across scripts                      | Ids drift weekly. `--panel` resolves against the live catalogue.     |
| `CURSOR_API_KEY` in a committed config                   | Committed secret, and it is the only secret this skill has.          |
| A dollar sign directly before a digit in a SKILL.md      | Slash-command argument substitution eats it.                         |
| `grep`/`sed` over prose to drive control flow            | Ask for a delimited block, or use `--json` and parse with jq.        |

## 13. See also

- [openrouter-adversarial-review](../openrouter-adversarial-review/SKILL.md) — the same discipline through a pay-per-token gateway, with a benchmark-ranked catalogue and a price estimate. §11 compares them.
- [static-validation-hooks](../static-validation-hooks/SKILL.md) — deterministic checks belong in a hook, not in an LLM call. Run those first; a model is for judgement, not for lint.
- [grievances](../grievances/SKILL.md) — where a confirmed finding goes when it is out of scope for the current spec.
- [spaghetti-compass](../spaghetti-compass/SKILL.md) — reverse impact analysis, to widen review context by callers rather than by volume.

---

## Implementation Status

**Fully implemented, and live-verified end to end — including the review call
itself**, which is where this skill differs from its OpenRouter sibling: no key
was missing, so a real panel really ran.

**The live end-to-end run.** A throwaway git repository was seeded with a spec
carrying three requirements and an implementation violating two of them
(`FR-2`, a missing negative-amount guard; `FR-3`, a guard reading `rate > 1`
instead of a two-sided range check). `cursor-review.sh --panel 3
--exclude-vendor anthropic --changed HEAD~1 -d specs/012 -s @adversarial.md`
returned in 134s with three review files. All three lanes — `gpt-5.6-sol-high`,
`gemini-3.7-flash-high`, `cursor-grok-4.6-high` — found both seeded defects,
cited `src/tax.py:2` and `src/tax.py:4`, and followed the charter's finding
format without being shown an example of it. Two lanes independently found a
third defect that had not been seeded: `int(amount * rate + 0.5)` is not half-up
under IEEE 754, demonstrated with `100 * 0.145 = 14.499999999999998`. No lane
mentioned the ambient hook content of §9, which is the evidence that the
charter's scoping paragraph earns its place.

**What was measured on the CLI rather than assumed** (`cursor-agent`
2026.08.31-4057e58, macOS, bash 3.2.57):

- **Piped stdin is silently discarded.** Asked to echo its stdin, a lane fed
  `PASSWORD_IS_ZANZIBAR` answered `STDIN_EMPTY`. §7.1. An idle pipe on stdin does
  not block the process — it exits 0 having read nothing.
- **`--mode ask` is genuinely read-only.** Instructed to overwrite one file and
  create another, the agent declined; the target was byte-identical afterwards
  and the second file was never created. §7.3.
- **The workspace-trust gate exits 1** with empty stdout when `--trust` is
  absent. §7.4.
- **A bad model id exits 1** and prints the full catalogue.
- **Ambient injection is real and not suppressible.** Asked only to say `OK` in
  an empty directory, a lane volunteered the contents of a user-level hook, and
  reported 171 injected skills. `CURSOR_CONFIG_DIR` pointed at a curated
  directory keeps the login and injects the real configuration anyway; a
  sandboxed `HOME`, and a `~/.cursor` symlink farm omitting hooks and skills,
  both report `Not logged in` — authentication does not live there. §9.
- **Concurrency works**: three lanes over a two-file context, 24s wall clock.
  Trivial single calls land between 10s and 45s.
- The `--json` result shape of §5 is copied from a real response.

**The regression suite is green: 41 cases, 0 failures, offline.** A stub stands
in for `cursor-agent` and records the argv it was handed, so the suite asserts
bounds — exit codes, wall clocks, staged trees, flags present and absent — and
never an answer. It runs with no account and no tokens:

```bash
bash scripts/test-cursor-review.sh
```

Coverage: argument rejection, a writable `--mode` refused, staging paths and the
manifest, `--diff` against `--changed`, an empty diff refused rather than
reviewed, stdin materialised from a closing pipe, an idle stdin dropped inside
its bound, `--no-stdin` honoured, vendor exclusion and panel de-duplication,
`--trust` and the read-only mode always passed while no write-enabling flag ever
is, an empty lane failing 3 instead of 0, lane timeout and run budget both
enforced in wall clock, a piped invocation not outliving the run, and workspace
cleanup with and without `--keep`.

**Three defects were found by that suite and fixed**, all three the kind that
only appear under an agent harness:

1. **A background drain reads `/dev/null`, not your pipe.** POSIX assigns
   `/dev/null` as the standard input of an asynchronous command, so the obvious
   `cat > file &` staged an empty patch and reported success — reproducing, inside
   the fix, the exact silent-discard bug the fix exists to prevent. The drain now
   gets the real descriptor through `exec 3<&0`.
2. **A sleeping watchdog outlives the script and hangs the pipeline.** With the
   budget guard implemented as one long `sleep`, `cursor-review.sh … | head` hung
   for the whole budget: `head` exits, the script dies of SIGPIPE without running
   its EXIT trap, and the orphaned watchdog keeps the pipe's write end open. The
   watchdog now polls the parent every second and exits with it.
3. **A backgrounded lane does the same.** Each lane now closes its inherited
   descriptors before doing anything else, and every lane pid is reaped on exit.

**Not verified:** Linux and Windows. Everything here was run on macOS 25.5 with
the system bash 3.2, and the script is written to that floor — no associative
arrays, no `mapfile`, no `readlink -f`. `CURSOR_API_KEY` authentication (§2) was
not exercised: this machine authenticates through `cursor-agent login`, and the
CI path is documented from the CLI's own help rather than from a run. The panel
preference list of §6 was resolved against a live 203-model catalogue on
2026-09-01; ids drift, and `--panel` skipping a retired id is tested against the
stub, not against a real retirement.
