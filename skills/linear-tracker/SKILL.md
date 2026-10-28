---
name: linear-tracker
description: >-
  Use Linear as the tracker a repository publishes findings to, through the
  Linear MCP. Covers the per-repository configuration that names a team and a
  project (`.linear.json`), the mapping from a grievance record to a Linear
  issue and the two mappings that silently corrupt data if taken literally, the
  publish contract this skill answers on behalf of the `grievances` skill, and
  read-only triage across a workspace. It also installs, once, a repo-local advisory
  Stop hook and per-phase templates that follow a spec-kit change in Linear —
  issue at specify, In Progress at the first ticked task, In Review when a PR
  opens — from file, git and PR facts only, asking once per fact and never
  blocking. `publish` is a verb of the `grievances`
  skill; this skill is one backend that answers it, and it never writes a
  ledger. Use when wiring a repository to a Linear project, when a finding must
  leave a repository and become an issue someone can own, when auditing which
  findings are already tracked, or when deciding what a tracker can and cannot
  hold. Triggers on "Linear", "linear.json", "publish a grievance", "tracker",
  "issue from a finding", "which project does this repo belong to",
  "follow a spec in Linear", "spec-kit lifecycle".
license: Apache-2.0
tags:
  - hooks
  - linear
  - mcp
  - process
  - spec-kit
  - workflow
---

# Linear — the tracker a repository publishes findings to

## What this skill is, and what it is not

**It is one backend.** A repository accumulates findings. Some deserve to leave
the repository and become work someone can own. The act of sending one out is
called **publishing**, and `publish` is a verb of the
[`grievances`](../grievances/SKILL.md) skill — it belongs there because only
that skill may write the ledger.

This skill answers one half of that verb: *given a record, make it an issue in
Linear, and hand the reference back*. It is the Linear adapter, not the
workflow.

```text
  a finding
      |
      v
  grievances skill  ──────────────────────────────┐
   owns: the record, the ledger, the verb          │  calls a backend
   decides: whether this finding may leave         │
                                                   v
                                          ┌─────────────────────┐
                                          │  linear-tracker     │  <- this skill
                                          │  owns: the mapping, │
                                          │  the config, the    │
                                          │  MCP calls          │
                                          └─────────────────────┘
                                                   │
                                          returns: "TT-412" + url
                                                   │
  grievances skill  <──────────────────────────────┘
   writes the reference into the record
```

**Consequences, and they are load-bearing:**

- **This skill never edits `specs/GRIEVANCES.md`.** Not once, not to fix a
  drift, not to attach a reference. The ledger has exactly one writer.
- **This skill never decides whether a finding should leave.** That judgement
  lives in the grievances boundary rules. A caller that asks to publish has
  already decided.
- **A repository with no Linear configuration is not this skill's business.**
  The grievances skill keeps working on its own; that is its normal mode, not a
  degraded one.
- **Another backend could answer the same verb.** Nothing in the grievances
  contract names Linear. A repository on a different tracker gets a different
  adapter and the same workflow.

## The seam with the grievances skill

### Who owns what

| Concern | Owner |
|---|---|
| Whether a finding may leave the repository | `grievances` (its boundary and promotion rules) |
| The record: id, short, severity, impact, `×N` | `grievances` |
| Writing anything into `specs/GRIEVANCES.md` | `grievances`, exclusively |
| The `publish` verb, and when it runs | `grievances` |
| Which team and project this repository publishes to | **this skill** (`.linear.json`) |
| Turning a record into an issue | **this skill** |
| Talking to the Linear MCP | **this skill** |
| The reference returned, and its format | **this skill** |

**One script serves both.** `../grievances/scripts/grievances.py` implements the
verb, the config reader and the field mapping; this skill's SKILL.md is that
code's specification, not a second implementation of it. The dependency runs one
way: the script knows a backend named `linear` from a one-row table, and knows
nothing about the MCP.

### The contract, in both directions

**What this skill receives** — one grievance record, as the CLI emits it:

```bash
grievances.py show GRV-worker-hosted-api-scale --json
```

```json
{
  "id": "GRV-worker-hosted-api-scale",
  "short": "worker co-hosted with the API will not scale",
  "severity": "high",
  "date": "2026-08-04",
  "status": "open",
  "occurrences": 4,
  "locus": "internal/worker/main.go:42",
  "source": "spec 156 implementation",
  "tags": ["scaling"]
}
```

…plus the prose body, which the CLI keeps verbatim after the
`<!-- grievance:ID:prose -->` marker: **Finding**, **Impact**, optionally
**Why tests miss it**, **Fix** and **Effort**.

**What this skill returns** — a reference and a URL, and nothing else:

```json
{ "ref": "TT-412", "url": "https://linear.app/<org>/issue/TT-412/..." }
```

The caller writes that reference into the record. This skill does not.

### Where the reference lands, and why it is a tag

**It lands in the record's `tags`, as `linear:TT-412`.**

That choice is forced, and it is worth stating why, because the obvious
alternative breaks the ledger.

The record's JSON header looks tempting as a home for a new `"linear"` key. It
is not: `grievances.py` validates the header against a closed field list and
**refuses to read a ledger carrying an unknown field**:

```python
unknown = set(meta) - known
if unknown:
    raise UserError(f"{meta.get('id', '?')}: unknown JSON field(s): {sorted(unknown)}")
```

Adding a `"linear"` key by hand therefore makes every subsequent `add`,
`resolve`, `list` and `check` fail on that file. `tags` is already a
`list[str]`, is already free-form, and survives a full round-trip through the
CLI unchanged — verified by declaring an entry with `--tag "linear:TT-412"` and
reading it back with `list --json`.

So the binding is:

```text
tags: ["scaling", "linear:TT-412"]
                  ^^^^^^^^^^^^^^^
                  one tag, prefix "linear:", then the issue identifier
```

**Reading it costs nothing and needs no network.** "Is this finding already
tracked?" is a string match on a committed file. That is what makes the publish
step idempotent, and what lets an audit run offline.

**Writing it is the grievances CLI's job, through `publish --record`.** Never by
hand: the JSON header and the tables are tool-owned, and an edit made around the
CLI dies at the next mutation or breaks the file.

```bash
grievances.py publish GRV-worker-hosted-api-scale --record TT-412 --url "https://linear.app/…"
```

### Do not use publishing to launder a finding

The grievances boundary says a finding with a regulatory, security, data-loss or
money dimension **is not a grievance**. It goes to a spec or a roadmap item,
immediately.

Publishing must not become the back door. A caller that hands this skill such a
finding is asking for the wrong artifact: an issue in a run project reads as
routine work, and the severity is lost in the framing. **Refuse, and say which
rule applies.** The correct destination is decided in the grievances skill,
before this one is called.

## Configuration — how a repository knows its Linear root

**File: `<repo>/.linear.json`.** Committed. Override the path with
`LINEAR_CONFIG`.

```json
{
  "team": "Tiger Team",
  "project": "Broker PA · Run & évolutions — courant",
  "labels": ["modelo-broker-pa"]
}
```

| Key | Required | Meaning |
|---|---|---|
| `team` | yes | The Linear team that owns published issues. |
| `project` | yes | The project they are attached to. **No default, no guess.** |
| `labels` | no | Labels applied to every published issue, on top of the record's own tags. |

**Five rules, each with a reason:**

1. **It is committed.** A fresh clone must publish to the same place as the
   machine it was cloned from. A config that lives in one developer's home
   directory routes the same repository to two projects.
2. **It holds no credential.** Not a token, not a key, not a URL carrying one.
   Authentication belongs to the MCP server's own configuration, which is
   per-machine and never committed. A `.linear.json` containing a secret is a
   committed secret.
3. **It is readable without any Linear access.** An agent with no network can
   still answer "which project does this repository publish to?". That is what
   makes an audit possible offline.
4. **Its absence is a valid state, and it means "do not publish".** No
   configuration is not an error and not a warning. It is a repository that
   keeps its findings locally.
5. **A missing `project` refuses the publish.** Guessing a project from the
   repository name puts findings in the wrong board, where nobody who could act
   on them will look. Refuse and name the missing key.

**The mapping is not derivable, which is why it is written down.** A repository
does not name its project; the relation is neither one-to-one nor stable. Two
repositories can share a project, and one repository's findings can belong to a
project named after a product rather than after the code.

## The mapping — a record to an issue

| Linear field | From | Rule |
|---|---|---|
| `title` | `short` | Verbatim. It is already constrained to one line under 120 characters. |
| `description` | the prose body, plus a provenance header | See below — the header is not optional. |
| `priority` | `severity` | `critical`→1 Urgent, `high`→2 High, `medium`→3 Medium, `low`→4 Low. |
| `labels` | `tags` minus the `linear:` binding tag, plus `labels` from the config | Never publish the binding tag as a Linear label. |
| `project` | config | Refuse if absent. |
| `team` | config | Refuse if absent. |
| `state` | **the team's own initial state** | **Never the record's `status`.** See the trap below. |
| `estimate` | — | Left unset. See the trap below. |
| `assignee` | — | Left unset unless a human names one. Never derived. |

### The provenance header, and why it is mandatory

Four facts have no field of their own in Linear and are lost unless the
description carries them. Put them at the top, in a fixed shape, so they can be
found by search and by eye:

```markdown
> `GRV-worker-hosted-api-scale` · declared 2026-08-04 · seen ×4
> `internal/worker/main.go:42` · surfaced by spec 156 implementation
```

| Fact | Why it cannot go elsewhere |
|---|---|
| The record id | There is no external-identifier field. Without it, the issue cannot be traced back to the ledger. |
| The declaration date | `createdAt` belongs to Linear and is set on creation. A four-month-old finding would read as filed today, and "the one rotting longest" stops being visible. |
| `×N`, the recurrence count | Linear has priority, not a recurrence counter. A comment is not a sortable field. This is the record's strongest ranking signal and the easiest to lose. |
| The locus (`file:line`) | There is no location field. Optionally also attach a permalink, which needs a commit sha to be stable. |

### Two mappings that look right and corrupt data

**1. `state` must never be copied from `status`.** The two describe opposite
lifecycles. A finding is typically published *as it is closed in the ledger* —
its `status` becomes `resolved` at the same moment the issue is born as work
nobody has started. Copying one to the other **creates an issue that is already
done**. Use the team's initial state, always.

**2. `estimate` must not be filled from `--effort`.** The record's effort is a
free string (`"0.5d"`, `"1d"`); Linear's estimate is a number on a scale each
team configures. There is no safe conversion without a per-team table. Leave the
estimate unset and let the effort stay in the description, where it reads
correctly.

### What a published issue still does not have

**An owner.** The grievances skill forbids owners on purpose — "if entries
acquire owners and sprints, the boundary has failed". A record therefore carries
none. But an unassigned issue in a run project is an issue nobody reads. **Ask a
human, or publish deliberately unassigned and say so.** Do not invent an
assignee from the git blame, the last committer, or the repository owner.

## Publishing — the protocol this skill answers

**The script is shared, and it is the grievances skill's.** Steps 1 to 5 below
are implemented in `../grievances/scripts/grievances.py` — the same file that
owns the ledger. This skill does not reimplement them, and must not: a second
copy of the mapping drifts from the first, and only one of the two writes the
ledger. `./install.sh` copies the whole `skills/` tree to one root, so that
relative path holds after installation as it does in the repository.

What is left for this skill is **step 6 alone: the MCP call.** That is the only
step needing a credential, and the only one a script cannot make.

```bash
# 1-5  build the payload, and stop on every refusal
grievances.py publish GRV-worker-hosted-api-scale --prepare --json
# 6    this skill: create the issue through the Linear MCP, get TT-412 back
# 7    write the reference into the record's tags
grievances.py publish GRV-worker-hosted-api-scale --record TT-412 --url "https://linear.app/…"
```

1. **Read `.linear.json`.** Absent → `status: not-configured`, exit 0. This is
   not a failure.
2. **Read the record** — the JSON header plus the prose body.
3. **Check the binding.** A `linear:` tag already present → `already-published`,
   exit 0. Publishing twice makes two issues nobody reconciles.
4. **Flag out-of-boundary findings.** A tag reading `security`, `regulatory`,
   `data-loss` or `money` fills `warnings`. It **warns and does not block**:
   whether such a tag marks a real security defect or a missing response header
   is a judgement no script can make, and a heuristic that blocks is a heuristic
   that gets worked around. **Read the warning and apply the rule above.**
5. **Build the issue** per the mapping table, provenance header included.
6. **Create it** through the Linear MCP. ← this skill, and only this.
7. **Hand `{ref, url}` back** to `publish --record`, which writes the tag.

**On failure, fail loudly and write nothing.** A publish that silently does
nothing is the worst outcome available: the caller believes the finding left the
repository, and it did not. An expired token, a renamed project and a network
error must all surface as an error the caller can see, never as a success with
an empty result.

**The gap between step 6 and the caller's write is not atomic.** If the issue is
created and the binding is never recorded, the next publish makes a duplicate.
Two defences, and use both: check step 3 first, and when a duplicate is
suspected, search Linear for the record id — which is in the provenance header
precisely so this search works.

## Reading Linear without publishing

Publishing is the write path and the rare one. Most use is read-only, needs no
configuration beyond the MCP itself, and changes nothing.

- **What is assigned to me, and is it still true?** List issues by assignee,
  then verify each claim against the repository — a branch that landed, a file
  that moved, a deadline that passed. An issue is a statement about the world at
  the time someone wrote it.
- **What is already tracked?** Grep the ledgers for `linear:` tags. Offline, and
  exact. This is the cheap audit: findings that left, versus findings that
  stayed.
- **What should leave next?** Read the open records across repositories and rank
  them by the ledger's own signals — severity, `×N`, age. Those three do not
  exist in Linear, which is why the proposal step reads the ledger rather than
  the tracker. **Propose; do not publish.** The decision is a human's.

## Lifecycle — following a spec-kit change in Linear

**This is a second job, separate from publishing.** Publishing sends one finding
out. The lifecycle keeps one Linear issue in step with one spec-kit change,
`specs/NNN-slug/`, from its spec to its pull request. It shares `.linear.json`
with publishing and nothing else; the grievance contract above is unchanged.

**It is a hook factory.** `scripts/install-lifecycle.sh` copies a hook and
templates into the consumer repository once. From then on the repository owns
them, edits them freely, and depends on nothing in this skill.

```bash
bash skills/linear-tracker/scripts/install-lifecycle.sh /path/to/consumer-repo
```

| Installed path | Role | Committed |
|---|---|---|
| `.agents/hooks/linear-lifecycle.sh` | The Stop hook: gathers facts, asks once per fact | yes |
| `.agents/hooks/linear-record.sh` | Appends an event to a spec's log | yes |
| `.agents/linear/phases.json` | Phase switches, state names (EN + FR), duplicate-search size | yes |
| `.agents/linear/*.md` | One template per phase | yes |
| `.claude/settings.json` | One `Stop` entry, merged once | yes |
| `specs/NNN-slug/linear.json` | The spec's event log: `created`, `linked`, `in_progress`, `in_review`, `unavailable` | yes |
| `<git-common-dir>/linear-lifecycle/asked.json` | Fact keys already asked | no — inside `.git/`, shared by every worktree |

Existing files are kept on re-install; `--force` overwrites them. The hook needs
bash, jq and git; `gh` is optional and only feeds the PR phase.

### Phase → fact → template

The current spec is the one the git branch names (`042-webhook-202`, or any
branch starting with `042-`). On any other branch it is every `specs/NNN-*`
folder with uncommitted files.

| Phase | Fact | Key (asked once) | Asks the agent to | Then records |
|---|---|---|---|---|
| specify | `spec.md` exists; the log has no `created`/`linked` | `specify:<slug>` | search issues by title (≤ 20 candidates), show a possible duplicate and ask, else render `specify.issue.md` and `save_issue` | `created ID URL` or `linked ID URL` |
| implement | ≥ 1 `- [x]` in `tasks.md`; no `in_progress` | `implement:<slug>` | move the issue to In Progress / En cours, comment `implement.comment.md` | `in_progress ID` |
| pr-open | `gh pr view <branch>` says `OPEN`; no `in_review` | `pr-open:<slug>:<pr>` | move the issue to In Review / En revue, comment `pr-open.comment.md` with the link | `in_review ID PR-URL` |
| — | the agent has no Linear MCP tool | — | run `linear-record.sh <spec> unavailable` | `unavailable`: the hook stays silent for that spec |

Example: on branch `042-webhook-202` the agent writes
`specs/042-webhook-202/spec.md`. At the end of that turn the hook asks for the
issue once. The next turn it is silent, whether or not the agent complied.

**In Progress fires on the first ticked task, not on `tasks.md` existing.** A
generated task list is a plan; a ticked box is work started.

### Taking over a change someone else started

Example: a colleague wrote `spec.md` and `plan.md` for `042-webhook-202`, and
you pick up the implementation.

1. **They had the hook.** Their `specs/042-webhook-202/linear.json` is committed
   and names `TT-412`. The hook reads it: specify is done, and your first
   ticked task asks for In Progress. The asked-keys store is local to each
   clone, but the decision rests on the committed log, which travels.
2. **They created the issue by hand.** No log exists, so the specify ask fires.
   Its first step searches issues by title; if `TT-412` shows up, the agent
   asks you and records `linked`. If the title differs, link it yourself:

   ```bash
   .agents/hooks/linear-record.sh specs/042-webhook-202 linked TT-412 https://linear.app/acme/issue/TT-412
   ```

From there the hook catches up one phase per stop: ticked tasks ask for In
Progress, then an open PR asks for In Review.

**A move never goes backwards.** The hook reads the repository log, not
Linear. If the colleague already moved `TT-412` to In Review by hand, a
catch-up ask for In Progress would regress it. So every state-move ask starts
with "read the current state first; if it is already there or later, do not
move it, record the event only". The agent does that read, since only the agent
holds the MCP.

### Never blocking — what the hook will not do

1. **No `PreToolUse`, no permission decision, no guarded file.** The installer
   registers one `Stop` hook and nothing else.
2. **Its only output is `{"decision":"block","reason":…}` on `Stop`.** On a Stop
   hook that means "take one more turn". It refuses nothing.
3. **One ask per fact key, ever.** The key is written before the ask, so an
   ignored ask is not repeated. A new PR number is a new fact.
4. **Silent when the turn ended on a question**, and the key stays unconsumed so
   the fact is asked at a later stop. Silent on `stop_hook_active`, without
   `.linear.json`, after `unavailable`, and on any missing tool.
5. **Facts only.** File presence, ticked-box count, branch, PR state, the log.
   Never the quality or completeness of a document: that is a judgement, and
   deterministic checks of it proved too heavy and too brittle.

A hook cannot call MCP. So the hook detects, the agent acts, and the log closes
the loop.

### spec-kit's own extension hooks

**Not registered.** `.specify/extensions.yml` hooks (`after_specify`,
`after_implement`, …) fire only when a `/speckit.*` command runs. Every such
command writes its artifact, which the Stop hook sees at the end of the same
turn. A second entry point would add code without detecting one more fact. It
would also stay mute for any tool that writes spec-kit artifacts directly.

### Follow-ups, not in this increment

- Phases `plan` (comment), `tasks` (comment with the task list) and merge
  (`Done`), each with its template.
- A Cursor adapter (`stop` hook with `followup_message`).
- PR detection through a Bitbucket CLI.
- Re-asking when `plan.md` changes after its comment.

## Boundaries

| Not this skill's job | Where it belongs |
|---|---|
| Deciding a finding may leave the repository | The `grievances` boundary and promotion rules |
| Writing `specs/GRIEVANCES.md` | The `grievances` CLI, exclusively |
| Holding a Linear token | The MCP server configuration, per machine, never committed |
| Choosing a project when the config has none | A human, once, in `.linear.json` |
| Mirroring every record into Linear | Nothing. A mirror is two homes for one fact, and they drift |
| Deciding what a repository's Linear project is called | The team, in the tracker |

## Anti-patterns

- **Editing the ledger from this skill.** One writer. A reference attached by
  hand dies at the next CLI mutation, or breaks the file if it went into the
  JSON header.
- **Adding a `"linear"` key to a record's JSON header.** The CLI refuses unknown
  fields and stops reading the file. Use a `linear:` tag.
- **Copying `status` into `state`.** Creates issues that are already closed.
- **Publishing without the provenance header.** The id, the declaration date and
  `×N` have no field of their own; omitted, they are gone.
- **Guessing a project from the repository name.** Findings land on a board
  nobody who could act on them watches.
- **Publishing on every declaration.** Declaration must stay cheap — local, no
  network, no audience — or fewer findings get declared, which is the failure
  the ledger exists to prevent. Publishing is a separate, later, deliberate act.
- **Treating "not configured" as an error.** A repository without Linear is
  working normally.
- **A silent failure.** A publish that reports success while creating nothing
  loses the finding and the trust in the mechanism at once.
- **Publishing a security or regulatory finding as routine work.** It was never
  a grievance; the framing hides the severity.
- **Committing a token in `.linear.json`.** Same rule as every other committed
  artifact: record the *command* that retrieves a credential, never its value.

## Implementation Status

**Lifecycle hook — built and tested on a fixture, never run against Linear**
(2026-10-28):

- `scripts/install-lifecycle.sh`, `templates/hooks/linear-lifecycle.sh`,
  `templates/hooks/linear-record.sh`, three templates and `phases.json`.
- `tests/lifecycle.test.sh` runs the **installed** copy in a fixture repository,
  through `bash skills/linear-tracker/tests/run-in-docker.sh` (alpine + bash +
  jq + git, gh stubbed). 35 checks: no run emits a deny, exactly 6 asks over the
  whole scenario, a hand-linked takeover catching up on In Progress, the
  no-regression guard in every state-move ask, silence on a question, on `stop_hook_active`, without
  `.linear.json` and after `unavailable`, keys shared across worktrees,
  idempotent install that keeps edited templates. The PR-phase run measured
  under 200 ms. A mutation that makes the hook emit a deny turns the
  suite red.
- Not verified: the Linear MCP calls the hook asks for, and state names in a
  live workspace.

**Grievance publish — the repository half is implemented and tested; the Linear half is not.**

**Built and exercised** — `../grievances/scripts/grievances.py`, subcommand
`publish` (2026-09-23):

- `--prepare` reads `.linear.json`, validates it, builds the issue payload and
  returns one of `prepared` / `not-configured` / `already-published`. It writes
  nothing.
- `--record <REF>` writes the `linear:<REF>` tag and a `published` log line.
- 19 unit tests cover it, inside the suite's 75. Run them the documented way:
  `docker run --rm -v "$PWD:/repo" -w /repo/skills/grievances/scripts
  python:3.12-alpine python3 -m unittest`.
- Exercised end to end in a throwaway repository: `init` → `add` → `bump ×2` →
  `publish --prepare` with no config (`not-configured`, exit 0) → with a config
  (payload, priority 2, `×3` in the header) → `--record TT-412` → the same
  `--record` again (`already-recorded`) → `--record TT-999` (refused without
  `--force`). The rewritten ledger reloads, and the header keys stay inside the
  closed field list.

**One bug this work found and fixed.** `render_log_entry` had no branch for a
`published` action, so the entry fell through to the resolution renderer and
displayed **Resolved** for a finding nothing had resolved. A test now pins it.

**Not verified: every Linear-side claim.** No issue has been created through this
skill, no `.linear.json` exists in any repository of the fleet, and the mapping
has never met a live workspace. The first real publish is what proves the
priority scale, the label names and the team's initial state.

## See also

- [`grievances`](../grievances/SKILL.md) — the ledger, the record, the boundary
  rules that decide whether a finding may leave, and the owner of the `publish`
  verb this skill answers.
