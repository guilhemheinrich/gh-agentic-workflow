---
name: linear-tracker
description: >-
  Use Linear as the tracker a repository publishes findings to, through the
  Linear MCP. Covers the per-repository configuration that names a team and a
  project (`.linear.json`), the mapping from a grievance record to a Linear
  issue and the two mappings that silently corrupt data if taken literally, the
  publish contract this skill answers on behalf of the `grievances` skill, and
  read-only triage across a workspace. `publish` is a verb of the `grievances`
  skill; this skill is one backend that answers it, and it never writes a
  ledger. Use when wiring a repository to a Linear project, when a finding must
  leave a repository and become an issue someone can own, when auditing which
  findings are already tracked, or when deciding what a tracker can and cannot
  hold. Triggers on "Linear", "linear.json", "publish a grievance", "tracker",
  "issue from a finding", "which project does this repo belong to".
license: Apache-2.0
tags:
  - linear
  - mcp
  - process
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

**Writing it is the caller's job, and today it has no command.** The grievances
CLI has no `tag` subcommand, and hand-editing the JSON header is an explicit
anti-pattern there — the tables and headers are tool-owned. Attaching the
reference after the fact therefore requires the `publish` verb to exist in the
grievances skill. **Until it does, this skill can create issues but the binding
must be recorded by declaring the tag at `add` time, or not at all.** Do not
work around it by editing the ledger.

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

Called by the grievances skill's `publish` verb, once per record.

1. **Read `.linear.json`.** Absent → stop, report "not configured". This is not
   a failure.
2. **Read the record** (`show --json` plus the prose body).
3. **Check the binding.** A `linear:` tag already present → stop, report
   "already published as `TT-NNN`". Publishing twice makes two issues nobody
   reconciles.
4. **Refuse out-of-boundary findings.** Regulatory, security, data-loss or money
   → stop, name the rule (see above).
5. **Build the issue** per the mapping table, provenance header included.
6. **Create it** through the Linear MCP.
7. **Return `{ref, url}`** to the caller. Write nothing to the ledger.

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

**Specified, not implemented.** Nothing in this skill has been built. It
documents the contract so that the two halves can be written independently and
still meet.

**Verified against the current `grievances` skill on 2026-09-21:**

- The record schema and the closed JSON field list are read from
  `skills/grievances/scripts/grievances.py` (`Grievance` dataclass, `from_meta`).
- The refusal of unknown JSON fields was read in `from_meta` and is quoted above
  verbatim.
- The `linear:TT-412` tag binding was exercised end to end: a grievance declared
  with `--tag "linear:TT-412"` in a throwaway repository came back carrying that
  tag through `list --json`, with no change to the CLI.

**Prerequisites this skill does not own, and cannot start without:**

1. **A `publish` verb in the `grievances` skill.** It selects the record, calls
   a backend, and writes the returned reference into the record's tags. Without
   it there is no supported way to attach a reference after declaration — the
   CLI has no `tag` subcommand, and hand-editing the header is forbidden.
2. **A decision on how a backend is selected.** This skill assumes the presence
   of `.linear.json` is the signal. That convention belongs to the `publish`
   verb's design, not here, and should be confirmed there.

**Not verified:** every Linear-side claim. No issue has been created by this
skill, no `.linear.json` exists in any repository, and the field mapping has
never been exercised against a live workspace. The first real publish is what
proves the mapping, the priority scale and the initial-state behaviour.

## See also

- [`grievances`](../grievances/SKILL.md) — the ledger, the record, the boundary
  rules that decide whether a finding may leave, and the owner of the `publish`
  verb this skill answers.
