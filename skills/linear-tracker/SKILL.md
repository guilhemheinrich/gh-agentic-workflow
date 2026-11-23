---
name: linear-tracker
description: >-
  Use Linear as the tracker a repository publishes findings to, through the
  Linear MCP. Covers how a repository knows its Linear team (`team` in the
  lifecycle `phases.json`) and why the project is never a repository property
  (it is given per call, or recorded per spec), the mapping from a grievance
  record to a Linear issue and the two mappings that silently corrupt data if
  taken literally, the publish contract this skill answers on behalf of the
  `grievances` skill, and read-only triage across a workspace. It also installs,
  once, a repo-local advisory Stop hook and per-phase templates that follow a
  spec-kit change in Linear: issue at specify, In Progress at the first ticked
  task, In Review when a PR opens, Done once the merged PR is deployed (every
  pipeline of the merge commit green; ticket read from the spec or from
  `<teamKey>-<n>` in the branch name), from file, git and PR facts only, asking
  once per fact and never blocking. `publish` is a verb of the `grievances`
  skill; this skill is one backend that answers it, and it never writes a
  ledger. Use when wiring a repository to a Linear project, when a finding must
  leave a repository and become an issue someone can own, when auditing which
  findings are already tracked, or when deciding what a tracker can and cannot
  hold. What the tickets mean (types, complexity, features, proofs) is the
  `linear-semantics` skill; the dependency graph, the semantic check and the
  `lw` watcher (and its MCP server) are the `linear-atlas` skill.
  Triggers on "Linear", "phases.json", "publish a grievance", "tracker",
  "issue from a finding", "which project does this spec belong to",
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

## At a glance

| Need | Where |
|---|---|
| Draw the dependency graph, run the semantic check, watch Linear with `lw` | the [`linear-atlas`](../linear-atlas/SKILL.md) skill |
| Pick a ticket type, set a complexity, shape a feature and its proofs | the [`linear-semantics`](../linear-semantics/SKILL.md) skill |
| Publish a grievance as an issue | the publish contract below |
| Follow a spec-kit change in Linear | the lifecycle hook below |

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
| Which team this repository files in | **this skill** (`team` in `phases.json`, or `--team`) |
| Which project an issue goes to | the **caller**: the pilot's charter or brief, else a human (never the repository) |
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

## Configuration — where the team lives, and why the project does not

There is **no repository-level Linear config file.** The old `.linear.json`
(one repository → one team and one project) is gone: a monorepo holds several
Linear projects, and two pilots on two projects would route each other's issues
into the wrong one. To migrate, move its `team` into `phases.json`
(`install-lifecycle.sh <repo> --team NAME`), give each spec its `project` (below),
pass `--project` to `grievances.py publish`, and delete `.linear.json`.

| Fact | Lives in | Why there |
|---|---|---|
| **Linear is on here, and which team** | `team` in `.claude/linear/phases.json` (committed, written by `install-lifecycle.sh --team`) | The Stop hook is bash: it cannot call MCP and cannot read a pilot's charter. It needs a local, offline signal. A non-empty `team` arms the hook; absent or empty, the hook is silent and the repository keeps its findings locally. |
| **Which project** | `"project"` at the top of `specs/NNN-slug/linear.json`, or `--project` on a grievance publish | The project follows the work, never the repository. Written by the pilot or the brief before the spec exists, or by `linear-record.sh <spec-dir> project NAME`. |
| **Which issue** | the same log, `created` / `linked` events | Once an issue exists, later phases need no project at all. |
| **Credentials** | the Linear MCP server's own configuration, or `LINEAR_API_KEY` in the shell, per machine | Never in a repository file. |

**Rules, each with a reason:**

1. **The team is committed, the project is not a repository fact.** A fresh
   clone must file in the same team; but the same repository legitimately
   serves several projects.
2. **No credential in any committed file.** `phases.json` holds a team name and
   switches, nothing else.
3. **The team is readable without any Linear access**, so an audit works offline.
4. **No project means no creation.** An empty project is a trap: the hook would
   arm, mark its fact as asked and ask for `project ""`; once the projects
   exist, that spec would never be asked again. The hook therefore never emits
   an empty or guessed project (see the lifecycle section), and
   `grievances.py publish --prepare` refuses without `--project`.
5. **Where does the agent learn the project?** In this order: the spec's log,
   its session brief or charter, a search of the team for an existing issue to
   link, and otherwise a human. Never the repository name.

`LINEAR_CONFIG=PATH` still overrides the `phases.json` both the hook and
`grievances.py` read (it is a path to that file, not a second config).

**The mapping is not derivable, which is why it is never inferred.** A repository
does not name its project; the relation is neither one-to-one nor stable. Two
repositories can share a project, one repository can serve several, and a
project may be named after a product rather than after the code.

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

1. **Resolve team and project.** `--project NAME` is required: absent →
   refusal, nothing guessed. The team is `--team`, else `team` in
   `.claude/linear/phases.json`, else refusal. Both refusals name the flag.
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
`specs/NNN-slug/`, from its spec to its pull request. It shares only the team (`team` in `phases.json`)
with publishing; the grievance contract above is unchanged.

**It is a hook factory.** `scripts/install-lifecycle.sh` copies a hook and
templates into the consumer repository once. From then on the repository owns
them, edits them freely, and depends on nothing in this skill.

```bash
bash skills/linear-tracker/scripts/install-lifecycle.sh /path/to/consumer-repo --team "Tiger Team"
```

The consumer is Claude Code only: files go under `.claude/` and the Stop entry
runs `"$CLAUDE_PROJECT_DIR/.claude/hooks/linear-lifecycle.sh"`. `--team` writes
`"team"` into `phases.json` (also into one that already exists); that field is
the switch that arms the hook. Installed without a team, the hook stays silent.

| Installed path | Role | Committed |
|---|---|---|
| `.claude/hooks/linear-lifecycle.sh` | The Stop hook: gathers facts, asks once per fact | yes |
| `.claude/hooks/linear-record.sh` | Appends an event to a spec's log | yes |
| `.claude/linear/phases.json` | **`team` (arms the hook)**, phase switches, state names (EN + FR), duplicate-search size | yes |
| `.claude/linear/*.md` | One template per phase | yes |
| `.claude/settings.json` | One `Stop` entry, merged once | yes |
| `specs/NNN-slug/linear.json` | The spec's `project` and its event log: `created`, `linked`, `in_progress`, `in_review`, `deployed` | yes |
| `<git-common-dir>/linear-lifecycle/deployed.json` | Issues without a spec already moved to Done (`linear-record.sh - deployed ID URL`) | no — same place |
| `<git-common-dir>/linear-lifecycle/asked.json` | Fact keys already asked | no — inside `.git/`, shared by every worktree |
| `<git-common-dir>/linear-lifecycle/unavailable.json` | Specs marked "no Linear connector here", with a timestamp | no — same place, expires |

`install-lifecycle.sh --team-key KEY` also writes `teamKey`. Existing files are kept on re-install; `--force` overwrites them. The hook needs
bash, jq and git; `gh` is optional and only feeds the PR phase.

### Phase → fact → template

The current spec is the one the git branch names (`042-webhook-202`, or any
branch starting with `042-`). On any other branch it is every `specs/NNN-*`
folder with uncommitted files.

| Phase | Fact | Key (asked once) | Asks the agent to | Then records |
|---|---|---|---|---|
| specify (project known) | `spec.md` exists; the log has no `created`/`linked` and has a `project` | `specify:<slug>` | search issues by title (≤ 20 candidates), show a possible duplicate and ask, else render `specify.issue.md` and `save_issue` in the spec's project | `created ID URL` or `linked ID URL` |
| specify (project unknown) | same, but the log has no `project` | `specify-project:<slug>` | create nothing. Search the team for an issue to link; else take the project from the session brief or charter; else ask the human | `linked ID URL`, or `project NAME` |
| implement | ≥ 1 `- [x]` in `tasks.md`; no `in_progress` | `implement:<slug>` | move the issue to In Progress / En cours, comment `implement.comment.md` | `in_progress ID` |
| pr-open | `gh pr view <branch>` says `OPEN`; no `in_review` | `pr-open:<slug>:<pr>` | move the issue to In Review / En revue, comment `pr-open.comment.md` with the link | `in_review ID PR-URL` |
| deployed (opt-in) | `gh pr view <branch>`: `MERGED`, `baseRefName` in `phases.deployed.targets`, a merge commit; then `gh run list --commit <sha>` | `deployed:<issue>:<sha7>` (green), `deploy-failed:<issue>:<sha7>`, `deploy-nopipe:<issue>:<sha7>` | all runs `success`/`skipped`/`neutral`: move the issue to Done / Terminé, comment `deployed.comment.md` (PR, commit, run links). A failed or cancelled run: do **not** move it, name the run and link. No run after `noPipelineDelay` s: judge | `deployed ID PR-URL` (or `- deployed ID PR-URL` without a spec) |
| — | the agent has no Linear MCP tool | — | run `linear-record.sh <spec> unavailable` | local mark, 4 h TTL: the hook stays silent for that spec on this machine |

**The `deployed` phase: Done means deployed, not merged.** A merge starts
pipelines, usually the deployment, and their result is what counts. While any
run of the merge commit is not `completed`, the hook says nothing and consumes
no key, so the next stop asks. It is off by default; enable it in `phases.json`:

```json
"teamKey": "MVP",
"states": { "done": ["Done", "Terminé"] },
"phases": { "deployed": { "enabled": true, "template": "deployed.comment.md",
  "state": "done", "targets": ["develop"], "noPipelineDelay": 300 } }
```

`targets` lists the branches whose merge means "deployed" (empty or absent:
silent; nothing repository-specific lives in the script). The issue is the
spec's when there is one; otherwise it is `<teamKey>-<n>` read, case
insensitively, in the branch name (`alice/mvp-373-title`) then the PR title.
`teamKey` is read from `phases.json` (`install-lifecycle.sh --team-key MVP`),
never derived from the team name; without it the fallback is off. The phase
needs no `specs/` folder, and a ticket without a spec is remembered as Done in
the local state directory.

**Link with pr-watch.** The hook only runs at the end of a turn and only
looks at facts. The `pr-watch` daemon (separate skill, untouched) is what
gives the session turns: one at the merge, one when the post-merge build ends.
The first finds runs pending (silence); the second finds them settled and the
hook asks for Done or reports the failure. Without a watcher, the next turn does it.

**Why two keys for specify.** A fact key is consumed when the hook asks. If the
create reminder were consumed while the project is still unknown, the agent
could defer (nothing to create into) and the reminder would never come back.
So the "find a project" reminder has its own key, and `specify:<slug>` is only
consumed when the hook can actually ask for a creation, i.e. once a project is
recorded. A pilot or brief that records the project before `spec.md` exists
skips the first reminder entirely.

**Why `unavailable` is local and expires.** It used to be an event in the
committed log, so one session without the Linear MCP silenced a spec on every
machine, forever. It now lives in `<git-common-dir>/linear-lifecycle/` next to
`asked.json`, keyed by spec, and expires after 4 hours
(`LINEAR_LIFECYCLE_UNAVAILABLE_TTL`, seconds). A TTL rather than a session
scope because `linear-record.sh` runs from the agent's shell and has no session
id. `unavailable` events already present in committed logs are ignored.

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
   .claude/hooks/linear-record.sh specs/042-webhook-202 linked TT-412 https://linear.app/acme/issue/TT-412
   ```

From there the hook catches up one phase per stop: ticked tasks ask for In
Progress, then an open PR asks for In Review.

**A move never goes backwards.** The hook reads the repository log, not
Linear. If the colleague already moved `TT-412` to In Review by hand, a
catch-up ask for In Progress would regress it. So every state-move ask starts
with "read the current state first; if it is already there or later, do not
move it, record the event only". The agent does that read, since only the agent
holds the MCP.

### Sub-issues — an answer lands on the sub-issue that asked

Every state move of an issue — In Progress, In Review, and the Done that
follows a merge to staging, whether a hook asks for it or not — starts by
listing its sub-issues (`list_issues` with `parentId`). An issue with
sub-issues is a checklist, and each sub-issue is one box.

Real example (2026-11-04, project `Calendar · Notifications seule & IAM
agence`). `TT-1566` "B1 — Cadrer le modèle d'accès agence" has five
sub-issues, `TT-1598` B1.1 to `TT-1602` B1.5. The decision "no multi-tenant;
the IAM is the source of truth for groups" was posted as a comment on
`TT-1566`, which moved to In Review. Yet it answers `TT-1598` B1.1 (access
computed on the fly) and `TT-1601` B1.4 (amend the "NO MULTI-TENANT" rule).
Both stayed in Backlog and Todo, with nothing on them. Whoever opens B1.4 sees
an open question that was settled hours ago.

1. **The answer goes on the sub-issue it resolves.** The decision, the
   deliverable or the PR link is a comment on `TT-1601`, not on `TT-1566`.
   The parent gets at most one line pointing to it.
2. **A settled sub-issue moves to Done in the same gesture.** That is the
   ticked box. A sub-issue with a deliverable still to merge follows the
   normal lifecycle instead (In Progress, In Review, Done).
3. **The parent reaches Done only when every sub-issue is Done or Canceled.**
   Otherwise it keeps its state, and its comment names the open sub-issues by
   identifier.
4. **Name a sub-issue by its identifier, never by a number in prose.** On
   `TT-1566` the decision comment calls "point 4" the scope inheritance, a
   later comment calls "point 4" `Room.organizationId`, and the sub-issue
   B1.4 is a third question. `TT-1601` cannot drift.

The ticket type tells you what a sub-issue is. On a framing ticket (decisions
before code, like B1) each sub-issue is a question, closed by its decision. On
an implementation ticket each sub-issue is a slice of work, closed by its own
merge.

### Never blocking — what the hook will not do

1. **No `PreToolUse`, no permission decision, no guarded file.** The installer
   registers one `Stop` hook and nothing else.
2. **Its only output is `{"decision":"block","reason":…}` on `Stop`.** On a Stop
   hook that means "take one more turn". It refuses nothing.
3. **One ask per fact key, ever.** The key is written before the ask, so an
   ignored ask is not repeated. Never before the hook can act on the fact (no
   project: see the two specify keys). A new PR number is a new fact.
4. **Silent when the turn ended on a question**, and the key stays unconsumed so
   the fact is asked at a later stop. Silent on `stop_hook_active`, without a
   `team` in `phases.json`, while a local `unavailable` mark is fresh, and on any missing tool.
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

## Dependency graph, the semantic check and the watcher

These moved to the [`linear-atlas`](../linear-atlas/SKILL.md) skill (`linear_deps.py`, `lw`, the `lw` MCP server).
The meaning of ticket types, complexity, features and proofs moved to the
[`linear-semantics`](../linear-semantics/SKILL.md) skill.

## Boundaries

| Not this skill's job | Where it belongs |
|---|---|
| Deciding a finding may leave the repository | The `grievances` boundary and promotion rules |
| Writing `specs/GRIEVANCES.md` | The `grievances` CLI, exclusively |
| Holding a Linear token | The MCP server configuration, per machine, never committed |
| Holding the API key `linear_deps.py` reads | The shell or secret store of the person running it, as `LINEAR_API_KEY`; never a file of the repository |
| Choosing a project | The pilot's charter or brief; else a human, once, recorded on the spec (`linear-record.sh … project NAME`) |
| Deciding what team a repository files in | `phases.json` (`install-lifecycle.sh --team`) |
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
- **Guessing a project from the repository name, or from the repository.**
  Findings land on a board nobody who could act on them watches. A repository
  has no project; a spec does.
- **Creating an issue with `project ""`.** The hook never asks for it, and a
  hand-written call must not either.
- **Committing "Linear is unavailable".** It is a fact about one machine and one
  moment. Keep it in the local state dir, with an expiry.
- **Publishing on every declaration.** Declaration must stay cheap — local, no
  network, no audience — or fewer findings get declared, which is the failure
  the ledger exists to prevent. Publishing is a separate, later, deliberate act.
- **Treating "no team in `phases.json`" as an error.** A repository without
  Linear is working normally; the hook is silent.
- **A silent failure.** A publish that reports success while creating nothing
  loses the finding and the trust in the mechanism at once.
- **Publishing a security or regulatory finding as routine work.** It was never
  a grievance; the framing hides the severity.
- **Committing a token in `phases.json` or a spec log.** Credentials live in the
  MCP server's configuration or in `LINEAR_API_KEY`, never in the repository.

## Implementation Status

**Lifecycle hook — built and tested on a fixture, never run against Linear**
(2026-10-28):

- `scripts/install-lifecycle.sh`, `templates/hooks/linear-lifecycle.sh`,
  `templates/hooks/linear-record.sh`, three templates and `phases.json`.
- `tests/lifecycle.test.sh` runs the **installed** copy in a fixture repository,
  through `bash skills/linear-tracker/tests/run-in-docker.sh` (alpine + bash +
  jq + git, gh stubbed). 55 checks: no run emits a deny, exactly 10 asks over the
  whole scenario, silence without a `team`, no `project ""` and an unconsumed
  create reminder when the project is unknown, two specs routed to two
  projects, a local expiring `unavailable` that never touches the committed
  log, a hand-linked takeover catching up on In Progress, the
  no-regression guard and the sub-issue step in every state-move ask, silence on a question, on `stop_hook_active`, keys shared across worktrees,
  idempotent install that keeps edited templates. The `deployed` phase adds
  14 checks (in progress → silence, all green → one Done ask, a failure → no
  Done, outside `targets` → silence, ticket by branch name or PR title, no
  pipeline after the delay, once per fact; 14 asks in all). The PR-phase run is budgeted at 200 ms (a slow machine may exceed it; the check fails identically on the previous version). A mutation that makes the hook emit a deny turns the
  suite red.
- Not verified: the Linear MCP calls the hook asks for, and state names in a
  live workspace.

**Grievance publish — the repository half is implemented and tested; the Linear half is not.**

**Built and exercised** — `../grievances/scripts/grievances.py`, subcommand
`publish` (2026-09-23):

- `--prepare` takes `--project` (required) and `--team` (else `team` in
  `phases.json`), builds the issue payload and returns `prepared` or
  `already-published`; it refuses, loudly, without a project or a team. It
  writes nothing. (The former `not-configured` status no longer exists.)
- `--record <REF>` writes the `linear:<REF>` tag and a `published` log line.
- 19 unit tests cover it, inside the suite's 75. Run them the documented way:
  `docker run --rm -v "$PWD:/repo" -w /repo/skills/grievances/scripts
  python:3.12-alpine python3 -m unittest`.
- Exercised end to end in a throwaway repository: `init` → `add` → `bump ×2` →
  `publish --prepare` (refused without `--project`) → with `--project` and a team
  (payload, priority 2, `×3` in the header) → `--record TT-412` → the same
  `--record` again (`already-recorded`) → `--record TT-999` (refused without
  `--force`). The rewritten ledger reloads, and the header keys stay inside the
  closed field list.

**One bug this work found and fixed.** `render_log_entry` had no branch for a
`published` action, so the entry fell through to the resolution renderer and
displayed **Resolved** for a finding nothing had resolved. A test now pins it.

**Not verified: every Linear-side claim.** No issue has been created through this
skill, and the mapping
has never met a live workspace. The first real publish is what proves the
priority scale, the label names and the team's initial state.

## See also

- Linear docs: [Issue relations](https://linear.app/docs/issue-relations),
  [Project dependencies](https://linear.app/docs/project-dependencies) (projects, drawn
  on the Timeline), [API and webhooks](https://linear.app/docs/api-and-webhooks) (API keys).
- [`grievances`](../grievances/SKILL.md) — the ledger, the record, the boundary
  rules that decide whether a finding may leave, and the owner of the `publish`
  verb this skill answers.
