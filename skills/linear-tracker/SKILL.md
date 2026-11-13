---
name: linear-tracker
description: >-
  Use Linear as the tracker a repository publishes findings to, through the
  Linear MCP, and wake agent sessions on Linear changes with `lw`, its
  watcher. Covers how a repository knows its Linear team (`team` in the
  lifecycle `phases.json`) and why the project is never a repository property
  (it is given per call, or recorded per spec), the mapping from a grievance record to a Linear
  issue and the two mappings that silently corrupt data if taken literally, the
  publish contract this skill answers on behalf of the `grievances` skill, and
  read-only triage across a workspace. It also installs, once, a repo-local advisory
  Stop hook and per-phase templates that follow a spec-kit change in Linear —
  issue at specify, In Progress at the first ticked task, In Review when a PR
  opens, Done once the merged PR is deployed (every pipeline of the merge commit
  green; ticket read from the spec or from `<teamKey>-<n>` in the branch name) — from file, git and PR facts only, asking once per fact and never
  blocking. It also draws the dependency graph of a Linear project ("blocks /
  blocked by" between its issues) as a clickable SVG for humans and exports it
  as a JSON graph agents can query, with `scripts/linear_deps.py` and a Linear
  API key read from `LINEAR_API_KEY`; `linear_deps.py check` answers offline
  whether every issue of one type (every Proof) is blocked by an issue of
  other types (a development task).
  `publish` is a verb of the `grievances`
  skill; this skill is one backend that answers it, and it never writes a
  ledger. Use when wiring a repository to a Linear project, when a finding must
  leave a repository and become an issue someone can own, when auditing which
  findings are already tracked, or when deciding what a tracker can and cannot
  hold. It also proposes eight issue types (Bug, Blocker, Question, Research,
  Feature, Improvement, Proof, Technical task), the order of questions that
  picks one, and a workspace template body for each. Use it too when choosing
  which ticket type to open, telling a Question from a Blocker, proving a
  merged lot on an environment, or drafting Linear templates. It also ships
  `lw`, the Linear watcher: a launchd daemon that polls Linear every 5 minutes
  and wakes the agent sessions subscribed to a Linear project or issue with
  each new comment or state transition (`lw subscribe`, then `lw wait` in the
  background), subscriptions ending on their own when the session is archived
  or the watched issue is finished. Use it when a session must be woken by
  a Linear comment or state change, or when installing or checking the watcher
  (`lw setup --claude`, `lw daemon start`, `lw doctor`).
  Triggers on "Linear", "phases.json", "publish a grievance", "tracker",
  "issue from a finding", "which project does this spec belong to",
  "follow a spec in Linear", "spec-kit lifecycle", "ticket type",
  "Linear template", "proof ticket", "dependency tree", "dependency graph",
  "draw Linear tickets", "what blocks this issue", "is every proof blocked",
  "LINEAR_API_KEY", "linear watch", "lw subscribe", "lw wait",
  "watch this ticket", "réveiller la session sur Linear",
  "surveiller le projet Linear".
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
| **Draw a project's dependency graph** ("blocks / blocked by"), clickable boxes | `scripts/linear_deps.py URL -o deps.svg` — [Dependency graph](#dependency-graph-of-a-project--svg-for-humans-json-for-agents) |
| **Query that graph as an agent** (who blocks what, cycles, types) | `--json-out deps.json`, then `linear_deps.py check deps.json --type Proof --blocked-by "Technical task,Feature,Improvement,Bug"` |
| Pick a ticket type and its template | [Ticket types](#ticket-types--which-issue-to-open-and-its-template) |
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

## Dependency graph of a project — SVG for humans, JSON for agents

Linear stores "blocks / blocked by" between issues, and shows it nowhere as a
picture: the issue sidebar lists the relations of one issue, and the Timeline
view draws **projects**, never issues. `scripts/linear_deps.py` fills that gap
with one read of the project and two outputs:

- **for a human, a clickable SVG** (`-o deps.svg`, always written): issues in
  columns grouped in one band per project milestone, blockers on the left, an
  arrow per blocking link, and **every box a link to its issue**;
- **for an agent, a JSON graph** (`--json-out deps.json`): every issue with its
  ticket type, its direct blockers and blocked issues, every relation once, the
  cycles, and the issues with no dependency. `linear_deps.py check` then answers,
  offline, "is every issue of type X blocked by at least one issue of type Y?".
  Reason over that file instead of calling `get_issue` once per issue.

![example: a made-up checkout project](references/linear-deps-demo.svg)

*Open `references/linear-deps-demo.svg` in a browser: the boxes are clickable.*

### Run it

```bash
export LINEAR_API_KEY=...   # see "The API key" below; never paste it in a chat
docker run --rm -e LINEAR_API_KEY -v "$PWD":/work -w /work python:3.12-slim \
  python skills/linear-tracker/scripts/linear_deps.py \
  "https://linear.app/<workspace>/project/<name>-<slugId>" -o deps.svg --json-out deps.json
```

Run it from the repository root; adjust the script path if the skill is installed
elsewhere. `-e LINEAR_API_KEY` forwards the variable without writing its value on
the command line. Python standard library only; Docker is the execution rule.

| Option | Effect |
|---|---|
| `-o FILE` | SVG file (default `deps.svg`) |
| `--json-out FILE` | also write the JSON graph (see [The JSON graph](#the-json-graph)); independent of the drawing options below |
| `--include-related` | also draw "related" links, dotted. Off by default: they order nothing |
| `--external show` | draw issues outside the project as dashed boxes. Default `drop`: the links to them are counted in a footer note |
| `--no-milestones` | flat layout: no milestone bands, no dashed separators. Default: one band per project milestone |
| `--hide-isolated` | hide issues without dependency. Default: a strip of clickable chips below the graph |
| `--no-descriptions` | do not fetch or embed description excerpts (no text in the hover preview, `description_excerpt: null` in the JSON). Use it for an SVG that will be shared: descriptions can be sensitive |
| `--from-json FILE` | no API call; read the normalized data from FILE (see below) |

### How to read the picture

- **Milestone bands.** The picture is cut into vertical bands, one per project
  milestone that has an issue in the drawing, in the milestone order of Linear
  (`sortOrder`, then target date, then name). Each band has its milestone name as a
  header and a **dashed vertical line** separates it from the next. Example
  (made up): a project with milestones "Staging" then "Production" shows every
  Staging issue on the left, a dashed line, then the Production issues. Issues with
  no milestone, and outside issues drawn with `--external show`, sit in a last band
  named "No milestone". Milestones with no issue are not drawn. The issues without
  dependency (the chip strip below the graph) are grouped by band too, so the
  reading stays the same top to bottom. A link between two bands is drawn across
  them as usual; when the blocker is in a later milestone than the issue it blocks,
  the arrow simply points left (it is a normal link, not a cycle). A project whose
  issues have no milestone is drawn flat, and `--no-milestones` forces that.
- **Columns** come from the longest path **inside a band**: an issue sits one column
  to the right of its furthest blocker of the same band (links from another band do
  not move it). The leftmost issues of each band are what to unblock first.
- **States follow Linear's own code.** Each card's border and left strip take the
  colour of its workflow state as the team configured it in Linear (`state.color`),
  so "In Review" keeps its own green although its type is `started`. The icon next to
  the identifier mirrors Linear's: dashed circle backlog, empty circle todo,
  half-filled in progress, filled with a check done, filled with a cross canceled,
  ringed dot triage. Backlog cards also have a dashed outline; canceled titles are
  struck through. Offline data without a colour falls back to Linear's defaults per
  type (backlog `#bec2c8`, unstarted `#e2e2e2`, started `#f2c94c`, completed
  `#5e6ad2`, canceled `#95a2b3`, triage `#fc7840`).
- **A legend** under the title lists every state present, by its Linear name, with
  its icon and colour, then the other markers drawn: hatched boxes with an
  `external` chip for issues outside the project, solid arrows for "blocks", dotted
  lines for "related", dashed red for the link that closes a cycle, and the type and
  label chips. It is built from the same functions as the cards (`state_look`,
  `state_glyph`), so nothing is drawn without being explained.
- **Point at a card** and what leads to it stands out at once: its direct blockers
  and the links into it in full strength, the rest of the chain upstream (blockers
  of blockers, outside issues included when drawn) a little lighter, everything else
  faded. Downstream issues are not lit: the question is what stands in the way of
  this one. The chains are computed when the SVG is generated (a cycle ends, an issue
  is never its own blocker); the legend's last two lines show the two strengths.
- **Hover a card for a fifth of a second (200 ms)** to get a preview, like Linear's issue peek:
  state icon, identifier, full title, state · assignee · milestone, type and label
  chips, and the beginning of the description (about 500 characters, markdown noise
  stripped). The click still opens the issue. The text is embedded **when the SVG is
  generated**: the picture never calls Linear when viewed, so it is a snapshot, and
  it holds the descriptions of the project until you regenerate it with
  `--no-descriptions`. The preview needs the SVG opened directly in a browser (a
  small inline script); where scripts are blocked (`<img>` embedding, GitHub's file
  preview) the native tooltip (`<title>`) still shows the same facts and a shorter
  excerpt.
- **A card** shows the identifier, `↳ TT-1970` for the parent issue, the title, then
  the state name · assignee · milestone, then chips: the ticket type first (bold,
  bordered), then the other labels as `group/name` (`repo/modelo-hub`). What does not
  fit ends with `…` or a `+N` chip; the **tooltip** holds everything: full title,
  state, type, assignee, milestone, parent and every label.
- A **cycle** (A blocks B blocks A) is reported on stderr and in the SVG; the link
  that closes it is drawn dashed in red. The run still succeeds: a cycle is data
  worth showing, not a failure.

### The JSON graph

Made-up sample, trimmed to two nodes and two edges
(`tests/fixtures/linear-deps-types-fail.json`, exported with `--json-out`):

```json
{
 "format": "linear-deps/1",
 "project": {"name": "Invitations lot, broken (made up)",
             "url": "https://linear.app/acme/project/invitations-0123456789ab",
             "milestones": ["Staging: invitations"]},
 "nodes": [
  {"identifier": "INV-1", "title": "Invitation API", "url": "https://linear.app/acme/issue/INV-1",
   "external": false, "state": "started", "state_name": null, "state_color": null, "assignee": null,
   "parent": null, "milestone": null,
   "type": "Feature", "labels": [{"name": "Feature", "group": "Type"}], "description_excerpt": null,
   "blocked_by": [], "blocks": ["INV-3"]},
  {"identifier": "INV-4", "title": "Accept link works on staging", "url": "https://linear.app/acme/issue/INV-4",
   "external": false, "state": "unstarted", "state_name": null, "state_color": null, "assignee": null,
   "parent": null, "milestone": null,
   "type": "Proof", "labels": [{"name": "Proof", "group": "Type"}], "description_excerpt": null,
   "blocked_by": ["INV-5"], "blocks": []}
 ],
 "edges": [
  {"from": "INV-1", "to": "INV-3", "type": "blocks"},
  {"from": "INV-5", "to": "INV-4", "type": "blocks"}
 ],
 "cycles": [],
 "no_dependency": ["INV-6"]
}
```

- **`edges`**: one per relation. A `blocks` on A and the inverse "blocked by" on B
  are one edge, `from` blocks `to`. `related` and `similar` are an unordered pair
  (sorted `from`/`to`), `duplicate` keeps its direction.
- **`project.milestones`**: the project's milestone names in order (Linear's
  `sortOrder`, then target date, then name), empty milestones included. It is the
  band order of the SVG. In `--from-json` input this field is optional: when absent,
  the order is derived from the issues' milestones, sorted by name.
- **`type`**: the label of the workspace label group **Type** of
  [`references/ticket-types.md`](references/ticket-types.md); failing that, a label
  named like one of the eight types (`proof`, `technical-task`); else `null`.
- **Outside issues** linked to the project are nodes too, `"external": true`, with
  their type when Linear returned their labels, and `state`/`parent` `null`.
  The drawing drops them by default; the JSON never does.
- **`description_excerpt`**: the beginning of the description as plain text (about
  500 characters, cut on a word with `…`), or `null` with `--no-descriptions`. Enough
  to tell what an issue is about without a `get_issue` per node.
- **`cycles`**: each loop of `blocks` links, as the sorted list of its issues.
- **`no_dependency`**: project issues with no `blocks` link either way, outside
  links included. It can be shorter than the SVG's strip, which ignores dropped
  outside links.

### Checking a typing rule — `linear_deps.py check`

```bash
docker run --rm -v "$PWD":/work -w /work python:3.12-slim \
  python skills/linear-tracker/scripts/linear_deps.py check deps.json \
  --type Proof --blocked-by "Technical task,Feature,Improvement,Bug"
```

Every project issue of `--type` must be blocked by at least one issue whose type is
in `--blocked-by` (repeatable or comma-separated; names compare case- and
dash-insensitively). `--open-only` skips completed and canceled issues. Output on
the same made-up fixture:

```text
FAIL     INV-4  https://linear.app/acme/issue/INV-4  [unstarted] Accept link works on staging  blocked by INV-5 (Question)
FAIL     INV-6  https://linear.app/acme/issue/INV-6  [completed] Old proof, done  no blocker
UNKNOWN  INV-7  https://linear.app/acme/issue/INV-7  [unstarted] Resend works on staging  blocked by OUT-1 (type unknown)
4 Proof issue(s) checked against Technical task / Feature / Improvement / Bug: 1 ok, 2 fail, 1 unknown
```

`UNKNOWN` means no qualifying blocker was found but at least one blocker has no
readable type: open it before calling it a violation. Exit code 0 when every issue
passes, 1 otherwise. When no issue has `--type`, a note on stderr lists the types
present, so a misspelt type is not read as "all good".

### The API key — where it comes from, where it lives

The script talks to Linear's GraphQL API directly. It does **not** reuse the MCP
server's session, so it needs a credential of its own: a **personal API key**.

- **Create it:** Linear → Settings → Account → Security & access → API keys
  ([API and webhooks](https://linear.app/docs/api-and-webhooks)). A workspace admin
  may switch off member-created keys (Settings → Administration → API), in which case
  an admin has to create it.
- **Scope it down:** the script only reads. Give the key the **Read** permission and,
  if the workspace offers it, limit it to the teams of the project.
- **Hold it:** in the shell or the secret store of the person running the command, as
  `LINEAR_API_KEY`. Never in a file of the repository, never in a chat. The script never prints it: an unreachable API or a refusal shows
  the HTTP status or Linear's message, and a test pins it.
- **Not set?** Do not ask for it in the conversation. Give the command above and stop,
  or use the MCP fallback below.

### What it queries

One paginated GraphQL query per page of 25 issues, with at most 10 labels, 25
`relations` and 25 `inverseRelations` each, well under Linear's complexity limit of
10000; then one query per 50 outside issues for their labels, so an outside blocker
still has a type. Only `blocks` relations are drawn as dependencies. `inverseRelations`
is what catches a blocker that lives **outside** the project: a relation is stored
once, on its source issue. The drawing ignores `duplicate` and `similar`; the JSON
keeps them. A warning names any issue that has more relations than one page returns.

### Without a key — the MCP fallback

The same picture can be drawn from the Linear MCP, which needs no key, at the price of
one call per issue:

1. `list_issues` with `project` → every issue, with `parentId` and its labels.
2. `get_issue` with `fields: ["relations"]` **for every issue**, not only the parents.
   Reading only the parents of a 49-issue project missed 4 blocking links that sat on
   sub-issues (a question to a partner blocking two tasks, for instance).
3. Write the normalized file and run with `--from-json`:

```json
{
  "project": {"name": "Checkout redesign", "milestones": ["M1 · Payments on staging", "M2 · Refunds"]},
  "issues": [{"identifier": "DEMO-2", "title": "...", "state": "started", "parent": null,
              "state_name": "In Review", "state_color": "#0f783c", "assignee": "Sam K.", "milestone": null, "labels": [{"name": "Proof", "group": "Type"}]}],
  "relations": [{"type": "blocks", "from": "DEMO-1", "to": "DEMO-2"}],
  "external": {"OTHER-77": "title of an issue outside the project"},
  "external_labels": {"OTHER-77": [{"name": "Technical task", "group": "Type"}]}
}
```

`state` is the Linear state type (`unstarted`, `started`, `completed`, `canceled`).
`project.milestones` (the band order; without it the milestones found on the issues
are ordered by name), `state_name`, `state_color`, `assignee`, `milestone`, `labels`, `external_labels` and
`description` (raw markdown, or an already cut `description_excerpt`) are optional (without them `type` is
`null`); a label may also be a bare name. A `{"type": "blocked_by", ...}` row is read
as the inverse `blocks`. `tests/fixtures/linear-deps-demo.json` and
`linear-deps-types-pass.json` are complete examples.

## Ticket types — which issue to open, and its template

Status: **proposal**. Eight types, picked by asking eight questions in order and
stopping at the first yes. Each has a workspace-level template body to paste
into Linear. The full semantics (the Question / Blocker split, the Addressee,
Proof and the Delivery milestone, the `save_issue` creation sequence) are in
[`references/ticket-types.md`](references/ticket-types.md).

| # | First yes to | Type | Template |
|---|---|---|---|
| 1 | Something delivered breaks a promise you can cite | Bug | [`bug.md`](templates/tickets/bug.md) |
| 2 | Someone outside the team must **do** something | Blocker | [`blocker.md`](templates/tickets/blocker.md) |
| 3 | Someone must **tell** us something | Question | [`question.md`](templates/tickets/question.md) |
| 4 | Ours to find out, within a time-box | Research | [`research.md`](templates/tickets/research.md) |
| 5 | A user gains a new capability | Feature | [`feature.md`](templates/tickets/feature.md) |
| 6 | An existing capability gets better | Improvement | [`improvement.md`](templates/tickets/improvement.md) |
| 7 | One thing must be shown working on an environment, by running something, not writing code | Proof | [`proof.md`](templates/tickets/proof.md) |
| 8 | Otherwise: work that ends in a merge, with no visible change | Technical task | [`technical-task.md`](templates/tickets/technical-task.md) |

Three rules carry most of the weight:

- **Dependency is a relation, never a type.** Whether a Question stops the work
  is said with **Blocked by**, not by filing it as a Blocker.
- **A Technical task ends with a merge; a Proof ends with an observation**
  (a command and its output, or a screenshot from a Playwright or browser
  session). Every code ticket's template ends with a « Recommended proof »
  link. Example (made up): « Upgrade Node from 20 to 22 » is the Technical
  task; « `node --version` returns `v22` in the staging pod » is its Proof.
- **A Proof is blocked by every dev issue of its lot**, and a Delivery is the
  lot's milestone, reached when its last Proof is closed. Example (made up):
  milestone « Staging: invitations » holds the two dev issues of the lot and
  two Proofs, each blocked by both.

## Linear watcher — waking a session when Linear changes

A session that writes to Linear does not hear from it: a decision taken in a
comment on a `Blocked` ticket reaches nobody unless the human relays it.
`scripts/lw` is a daemon (launchd, every 5 minutes) that polls the projects and
issues sessions subscribed to and wakes each one with lines such as
`Linear · TT-2287 comment by Jane Doe (08:44) · <issue URL>`. A session runs
`lw subscribe --session <id> --project <slug> --since 3d`, then
`lw wait --session <id>` in the background; the wait's exit is the wake.
Subscriptions end on their own (unsubscribe, session archived or silent for
7 days, watched issue finished; finished projects and terminal-started
sessions are known gaps, see the reference), and the agent's own Linear MCP
writes never wake it. Install it from the installed copy
(`~/.agents/skills/linear-tracker/scripts/lw`), never from a checkout.

**The project's dependency graph rebuilds itself.** On every ticket state
change in a watched project, the daemon (each cycle) and the own-writes hook
(at once, when this session or one of its child sessions moves a ticket)
rewrite `~/linear-graphs/<slug>.svg` and `.json`: one file per project,
overwritten in place, never a copy or a second file for the same project.
`lw graph --project <slug|URL>` or `--issue TT-123` rebuilds it by hand.
**Whenever a session talks about the project, it cites the graph's local path**
as `[Graph: <project>](file:///Users/<user>/linear-graphs/<slug>.svg)`.

Install, every command, the subscription lifecycle, the procedure when woken
by `lw wait`, the graph rebuild, and `lw doctor`:
[references/linear-watch.md](references/linear-watch.md).

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

**Dependency graph — built, tested offline and against a stub server, run once
against a live project** (2026-11-09; JSON export, `check`, legend and richer cards
2026-11-10):

- `scripts/linear_deps.py`, `tests/linear_deps_test.py`,
  `tests/run-linear-deps-in-docker.sh`, four made-up fixtures, one sample SVG.
- 51 tests in Docker. The upstream chains: direct and transitive blockers, outside
  blockers only when drawn, a cycle that ends without listing the issue itself, the
  chains and edge ends embedded in the SVG, and the highlight still present with
  `--no-descriptions`. The excerpt strips markdown noise and cuts on a word; every
  linked box has preview data; a description containing `]]>` or `</script>` cannot
  break out of the embedded data; `--no-descriptions` removes the text from the SVG
  and the JSON. The hover itself (highlight, preview delay, placement, reset on leave, dark
  and light) was checked by hand in a browser, not by a test. The legend names every state drawn and only those; the colour
  comes from Linear, then from the type, and a malformed colour is refused; outline
  and icon follow the state type; outside issues are hatched, not dashed; a card
  carries type, labels, state, assignee and milestone; overflowing chips end with a
  count. The JSON export: its shape, a `blocks` and its inverse
  `blocked_by` as one edge, `related` both ways as one edge, outside issues kept with
  their type, the type read from the Type group or a bare label name, whole cycles,
  and the CLI writing both files. `check`: one passing fixture, one failing fixture
  (a Proof blocked by a Question, one with no blocker, one blocked by an outside issue
  of unknown type), `--open-only`, and the note when the type is absent. The rest: layering by longest path, cycles, external links, every box
  linking to `https://linear.app/<workspace>/issue/<ID>`, XML escaping, the key never
  printed, and the live path against a local stub server (two pages, deduplicated
  relations, the key only in the `Authorization` header). A mutation that breaks the
  issue URL turns two tests red.
- Live run (2026-11-10) on a real 53-issue project with `--external show`: 56 blocking
  links, no cycle, 12 issues without dependency, 9 outside issues; the schema fields
  (`slugId` lookup, `inverseRelations`, `labels { parent }`, `projectMilestone`,
  `assignee`, `state.color`, the outside-issue lookup by `id: {in: ...}`) and the
  `Authorization: <key>` header all answered. Not measured: how close the queries come
  to the complexity limit on a project with many relations per issue. The first live run settles them.
- The first hand-drawn graph this script generalizes covered a real 49-issue project;
  its data is not committed here (fixtures are made up).

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
