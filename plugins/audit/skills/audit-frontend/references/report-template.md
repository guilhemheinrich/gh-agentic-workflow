# Report contract

The audit's deliverable is one Markdown report with the sections below, in this
order. A reader must be able to act on any finding without the auditor in the
room, and to re-run the check that produced it.

## Finding format

Every finding has all nine fields. A finding missing its evidence or its
re-verification step is not a finding: move it to "Open questions".

| Field | Content |
|---|---|
| `id` | `FE-001`, `FE-002`, ... stable for the life of the report; never renumber |
| `title` | The defect, stated as a fact, in one line |
| `severity` | `S1`..`S4` from the rubric below |
| `category` | `runtime` \| `state-render` \| `types` \| `lint` \| `css` \| `html` \| `a11y` \| `bundle` \| `deps` \| `network` \| `console` |
| `confidence` | `measured` \| `proven-by-reading` \| `suspected` (definitions below) |
| `evidence` | `path:line` and/or a measurement with its unit, its conditions (CPU throttle, runs, build type) and the output file it comes from |
| `why it matters` | The consequence for a user or for the team, in one or two sentences. No generic principle |
| `fix` | The smallest change that removes the defect, concrete enough to start coding. Mention the smell id (`S06`) when one applies |
| `re-verify` | The exact command or probe step, the metric and the target value that will show the fix worked |

Confidence levels:

- `measured`: a tool or the probe produced a number or an error, reproducible
  with the command given. Example: "`latencyMs` 600, 3 runs of 3".
- `proven-by-reading`: the code alone establishes the defect, whatever the data.
  Example: a selector that calls `.filter()` inline allocates on every call.
- `suspected`: a pattern matched and the code looks wrong, but the impact was
  not measured and depends on data or usage. Maximum severity `S3`.

### Example finding (made-up project, real probe output shape)

```markdown
### FE-003 - Opening an order blocks the main thread for 840 ms

- **Severity**: S2 · **Category**: state-render · **Confidence**: measured
- **Evidence**: `interaction-probe.json`, flow `search-and-open`, step 2
  (`click tr[data-id]`): `latencyMs` median 808 / max 848 over 3 runs, CPU x4,
  production build. `latencyBreakdown.processingMs` 838, `forcedLayoutMs` 822,
  `topScripts[0]`: `assets/index-3f9a.js:char48211`, invoker `TR.onclick`.
  Source: `src/orders/OrderTable.tsx:118-131`, a loop that sets
  `row.style.height` then reads `row.offsetHeight` for each of 3,000 rows.
- **Why it matters**: every click on a row freezes the page for most of a
  second under a 4x CPU throttle on the audit host; over 500 ms is "poor" on
  the INP scale. Not measured on a real phone.
- **Fix**: read all heights first, then write (smell S11); or drop the manual
  measurement and let CSS size the rows.
- **Re-verify**: `scripts/run-probe.sh --flows $OUT/flows.json --out $OUT/probe-fix
  --serve dist --runs 3 --cpu 4`; step 2 must show `latencyMs` max <= 200 and
  no `forced-layout` flag.
```

## Severity rubric

Severity is impact on users multiplied by reach. The table grades the defect
**as if it were on a key flow**; reach is then applied once, by the first
modifier.

| Severity | Definition | Typical examples |
|---|---|---|
| **S1 - Blocker** | The flow fails, loses data, or excludes a group of users | Uncaught exception or render loop; failed request that breaks the flow; a key task a group of users cannot complete (keyboard-only, confirmed beyond a failed `press` script); an advisory whose preconditions are met in the browser or in a credentialed build |
| **S2 - Major** | The flow works but is clearly degraded | Interaction `poor` (> 500 ms); LCP > 4 s; a WCAG A/AA violation that makes a task much harder but still completable (no visible focus, unlabeled field); first-load JS over twice the budget; state bug showing stale or wrong data (S16) |
| **S3 - Moderate** | A confirmed defect with limited visible effect | Interaction `needs-improvement`; effect cascade with a measured extra commit; index keys on a stateful list; type errors under the project's own config; advisory whose exposure is unknown |
| **S4 - Minor** | Hygiene: no user-visible effect today, raises the cost of change | Unused exports and dependencies; redundant memoization; strictness gap; CSS validity warnings without visual effect |

Modifiers, applied once each:

- Not on a key flow (as listed in the report's scope): lower by one level.
- Confidence `suspected`: cap at S3.
- Affects only a development build: cap at S4, except when it hides a
  production defect (a dev-only console signature of a real loop keeps its level).
- CPU throttle never changes the level: a defect seen only with `--cpu 4`
  keeps its level, and the finding states the condition.

Dependency advisories: grade by exposure, not by the scanner's label, and not
by "build-time means harmless". For each advisory kept, record the id, the
affected and fixed versions, and answer three questions:

| Question | How to check | Consequence |
|---|---|---|
| Does the vulnerable code run in the **browser**, on input an attacker controls? | Import present in the bundle, vulnerable function called, source of its input | Preconditions met: S1 or S2 by impact. Shipped but preconditions not shown: S3, `suspected` |
| Does it run at **build or CI** time, where secrets live (registry tokens, signing keys, deploy credentials)? | Which tool, on which input (untrusted files, pull-request content), in which pipeline | A build tool that executes untrusted input in a credentialed pipeline is S1 or S2, although nothing ships |
| Neither established? | - | Say **exposure unknown**, S3 at most, and put the question under "Open questions". Never force S4 or S1 |

Made-up example: a `critical` code-execution advisory in an image-optimiser
used by the build. It ships nothing to the browser; it does run in CI on
images that contributors upload, next to the deploy token: S1, not hygiene.

## Scorecard

One line per category. The score is a communication device for comparing two
audits of the same project; it is not a measurement and must not be compared
across projects.

Start each category at 100 and subtract per finding: S1 = 40, S2 = 15, S3 = 5,
S4 = 1. Floor at 0. Coverage is stated next to the grade, never hidden by it:

- no check of the category ran: `not verified`, no grade;
- some ran: the grade, followed by `partial` and the name of what did not run.
  Example: `deps: C, partial (osv did not run)` keeps the two S2 that
  `npm-audit` found visible;
- `a11y` stays `partial` until a human did the manual checks:
  `partial (automated only)` before the keyboard pass, then
  `partial (keyboard done; focus visibility, screen reader, zoom not checked)`.

| Grade | Score | Any S1? |
|---|---|---|
| A | 90-100 | no |
| B | 75-89 | no |
| C | 50-74 | no |
| D | 25-49 | or exactly one S1 |
| E | 0-24 | or two or more S1 |

Overall verdict, one of four, tested in this order (the first that applies
wins; a known S1 is reported even when coverage is thin):

- **Blocked**: at least one S1.
- **Degraded**: no S1, at least one S2.
- **Insufficient evidence**: no S1 or S2, but no key flow was driven by the
  probe, or no applicable static tool has `state: ran` in `summary.json`
  (a battery that ran with every tool `skipped` or `error` is no evidence). Absence of findings on things
  nobody checked is not health.
- **Healthy**: none of the above. Every scorecard line marked `partial` or
  `not verified` is named in the verdict sentence ("Healthy; a11y automated
  only, project tests not run").

## Report skeleton

```markdown
# Front-end audit - <project> - <date>

## Verdict
<Blocked | Degraded | Insufficient evidence | Healthy> - <one sentence: the single most important fact>

## Scope
- Commit: <sha> · Build audited: <production | development> · Framework: <...>
- Target: <URL> · Approved by: <who, for which flows, hosts and backends> · Accounts: <synthetic | ...>
- Origins contacted (probe `requestOrigins`): <list>, all inside the approved scope
- Key flows: <the 3 to 7 flows that were driven, by name>
- Conditions: probe runs <n>, CPU throttle x<n> on <host>, viewport <w x h>
- Field data available: <none | source and period>
- Out of scope: client-side security (see the `audit:audit-security` skill)

## Scorecard
| Category | Grade | S1 | S2 | S3 | S4 | Verified by |
|---|---|---|---|---|---|---|

## Top actions
1. <FE-id> - <fix in one line> - <expected gain, with the metric>
(at most five, ordered by severity then effort)

## Findings
### FE-001 - ...
(all fields; ordered by severity, then category)

## Measurements
- Interaction table (the probe's summary table, verbatim)
- Static battery table (`summary.json` tools, state and counts)
- Lighthouse medians when run

## Checked and cleared
- <candidate> - <why it is not a finding> (keeps the next audit from re-raising it)

## Not verified
- <check> - <why it did not run> - <what it would take>
- Always state: project test suite (not run by this audit), human accessibility
  checks not done (focus visibility, screen reader, zoom/reflow), files of the
  state layer that were not read

## Open questions
- <question for the team whose answer changes a severity>
```

## Triage rules for the auditor

1. Deduplicate by root cause, not by symptom or rule id: 40
   `jsx-a11y/alt-text` hits from one image component are one finding with a
   count and three sample locations. Hits of the same rule with different
   causes or different fixes stay separate findings.
2. One finding, one fix. If the fix section contains "and also", split it.
3. Never copy a tool's count into the report as the finding count. A tool
   count is evidence for a finding you wrote.
4. A threshold marked "house heuristic" in `thresholds.md` is said to be one
   in the finding.
5. Prefer five findings someone will fix over fifty nobody will read: S4
   findings may be grouped into one "hygiene" finding per category.
6. Everything in "Top actions" must have a `re-verify` that the team can run
   without the auditor.
