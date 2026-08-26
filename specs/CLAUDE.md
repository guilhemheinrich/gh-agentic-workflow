# specs/ — scope guidance

> Refines the root `CLAUDE.md`.

## GRIEVANCES.md — when to read it, when to write to it

`specs/GRIEVANCES.md` is the register of **underlying problems, technical debt and
improvements found outside the scope of an in-flight spec**: "what works, but will
not scale, or only holds together with tape". It lives here because a grievance is
the raw material a spec is made of — one step upstream, in the same folder.

It is **not** `ROADMAP.md` (upcoming features) and not the pilot `ROADMAP.md`
(cross-repo fiches).

### Read it

- **Before starting on an unfamiliar area** — the fastest briefing on what will
  waste your time here. The open-grievance table at the top of the file is the
  whole summary; click an ID for the analysis.
- **When opening a new spec** — grep it for the area you are about to touch: a
  finding already analysed in that zone often belongs *inside* your spec's scope,
  and closing it while you are already there costs a fraction of a dedicated pass.

### Write to it — with the CLI, never by hand

Declare a finding the moment you meet it:

```bash
grievances.py add --short "worker co-hosted with the API will not scale" \
  --severity high --locus "internal/worker/main.go:42" \
  --source "spec 156 implementation" \
  --finding "..." --impact "..." --fix "..." --effort 1d
```

Close it when a commit fixes it:

```bash
grievances.py resolve GRV-0007 --commit 1a2b3c4 --note "worker runs in its own deployment"
```

Met the same friction again? `grievances.py bump GRV-0007` — frequency is the
severity signal, and a duplicate entry hides it.

At the **end of every implementation / test / review phase**, say in one sentence
what you changed, **including "no change"**: a silent no-op is indistinguishable
from forgetting, and that is what kills ledgers.

### The boundary — what does NOT belong here

| Not this | Where it goes |
|---|---|
| A defect with a regulatory, security, data-loss or money dimension | A spec here, or a fiche in the **pilot** `ROADMAP.md` — immediately |
| Anything needing an arbitration or a design decision | A pilot roadmap fiche with a named arbiter |
| A task on the spec in flight | That spec's `tasks.md` |
| A finding on the diff under review | That spec's `review.md` |
| A live incident | The incident/debug report, then a pilot roadmap fiche |
| "This module should be rewritten" | Nowhere — that is an opinion. Make it a proposal with evidence, or drop it |

**One fact lives in exactly one artifact.** A promoted finding leaves this file:
`grievances.py resolve GRV-000N --promoted-to <spec-or-fiche>` keeps the pointer,
never a restatement.

Never paste a secret, a token, or a credential-bearing log line into an entry.

Format contract, lifecycle and the full CLI: the `grievances` skill.
