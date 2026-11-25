---
name: audit-frontend
description: >-
  Rigorous front-end audit of a web project, with evidence for every finding:
  measured latency of real interactions (Playwright probe recording INP-style
  event timing, long tasks, Long Animation Frames, forced layout, framework
  commit counts, console and network errors), an expert review of
  state-management and rendering errors (state at the wrong level, selectors
  returning new references, effect cascades, render loops, context churn,
  unstable keys, unvirtualized lists, layout thrashing, two-way sync, async
  races) for React, Vue, Svelte, Solid, Angular signals and Lit, a Dockerized
  static battery (TypeScript strict, ESLint, stylelint, HTML/CSS validity,
  bundle budgets, unused code, dependency advisories), and a findings report
  with severity and re-verification steps. Use when asked to audit, review or
  assess a front-end, when a UI feels slow or janky, when hunting re-render
  storms or render loops, before a release or a takeover of a front-end
  codebase, or to explain what a front-end audit covers.
tags:
  - frontend
  - performance
  - accessibility
  - playwright
  - docker
  - quality
  - typescript
  - eslint
  - web-analysis
---

# Front-end audit

An audit answers three questions with evidence: does the interface respond fast
when a user acts, is its state correct and cheap to render, does the code pass
the checks any front-end should pass. Every finding can be re-verified by others.

URL-level scans (Lighthouse, pa11y, axe CLI, broken links, security headers)
belong to the `web-analysis` skill. Client-side security (XSS sinks, token
storage, `postMessage`) is **out of scope**: say so in the report and point to
the `audit-security` skill.

**Language (mandatory).** Everything addressed to the person — the chat
answer, the report, the findings, the plan, the "not verified" list — is written
in **their language**, the one of their request (French request, French report).
Never default to English. Code, commands, SQL, file paths, identifiers, tool
output quoted as evidence and rule ids (`IDX-001`) stay as they are; the prose
around them is translated, and so are headings and severity labels.

## Ground rules

1. **No finding without evidence.** A `file:line`, a measurement with its
   conditions, or both. "This could be slow" is not a finding.
2. **A check that did not run proves nothing.** Report it under "Not
   verified". Never write "no issue found" for something no tool looked at.
3. **Lab is not field.** The probe measuring a 600 ms click means "this click,
   on this host, took 600 ms", not "the page's INP is 600 ms". Field data
   (CrUX, RUM) says how many users are affected; it does not cancel a
   reproducible lab defect.
4. **Authorized targets only.** Flows click, type and submit for real. Default
   to a build on this host with synthetic accounts. Anything else, private IPs
   and compose services included, needs the owner's approval of the host,
   the backends it calls **and** the flows; on production drive read-only
   flows only (no submit, save, delete, send). Every `origins contacted` line
   of the probe must be in scope. No approval: phases 2 and 4 only.
5. **Docker only, project code is untrusted.** The scripts run pinned images;
   the checkout is mounted read-only. Build and lint configs run offline with
   no credential; package-manager config meets a token only after you read it
   (`--trust-pm-config`); lifecycle scripts stay off (`references/tooling-matrix.md`).
6. **Patterns are candidates.** Lint hits and `smell-grep.sh` output say where
   to read. Only reading the code, or a measurement, makes a finding.
7. **Audit, do not fix; write outside the repo.** Change no project file. All
   outputs go to `$OUT`, a folder outside the checkout (e.g.
   `OUT=../audit-<project>`). They can hold session and personal data: never
   commit them, redact before sharing, delete `storage-state.json` afterwards.

## Workflow

Five phases: scope, static battery, runtime measurement, state/render review,
report. Phases 2 and 3 are independent: run them in parallel. Phase 4 needs both.

### Phase 1 - Scope

| Item | How to find it | Why it matters |
|---|---|---|
| Framework and version, state library | `package.json` | Selects the lint overlay and the smell matrix column; several smells are version-dependent |
| Target and approval | Ask: which URL, which accounts, which actions are allowed | Ground rule 4 |
| Build you can audit | Build command, deployed URL, dev server | Production build = the measurement of record; dev build = console signatures only |
| 3 to 7 key flows | Ask; else infer from routes and e2e specs | Severity depends on them; the probe needs them as `flows.json` |
| Realistic data volume | Ask for production counts (rows, items) | A list is fine with 20 rows and broken with 5,000 |
| Target devices | Ask | Picks the throttle. `--cpu 4` is 4x slower than **this host**, not a phone model |
| Existing gates | CI config, lint/test scripts, `size-limit` | A missing gate is a finding. This skill does not run the project's tests: list them under "Not verified" |
| Field data | CrUX, RUM, analytics | Prevalence and real devices, for the same route and metric |

### Phase 2 - Static battery

```bash
scripts/static-battery.sh --project <repo> --out $OUT/static --build "npm run build"
# monorepo: --project <root with lockfile> --package apps/web
# rendered DOM, after phase 3 (seconds, no reinstall):
scripts/static-battery.sh --project <repo> --out $OUT/static-dom --only vnu --html-dir $OUT/probe/dom
```

| Tool id | Question it answers | Limit to remember |
|---|---|---|
| `tsc`, `tsc-strict` | Does it type-check, and how much is left unchecked | `skipped` with "0 project files" = solution-style tsconfig: pass `--tsconfig`. The gap sizes a surface, it is not a bug list |
| `eslint-project` | Is the team's own rule set respected | `skipped` = no ESLint config: a finding unless another linter gates CI |
| `eslint-audit` | Known state, render and a11y anti-patterns (pinned overlay) | Syntactic: misses indirection. Angular not covered |
| `stylelint` | Invalid CSS | Fallback mode checks plain `.css` only |
| `vnu` | HTML conformance, CSS parse errors | An SPA shell is empty: validate dumped DOM |
| `knip` | Unused files, exports, dependencies | False positives on dynamic imports and conventions |
| `bundle` | Shipped bytes, first-load estimate | Static estimate, not what a route downloads |
| `npm-audit`, `osv` | Known advisories | Not exposure: grade with the report rubric |

Read `$OUT/static/summary.json`. Any tool whose `state` is not `ran` goes to
"Not verified" with its note. Details per tool: `references/tooling-matrix.md`.

### Phase 3 - Runtime measurement

Write `$OUT/flows.json` (format: `references/tooling-matrix.md`). Per key flow:
the actions, an `expect` on each result (a plain **CSS** selector, as specific
as possible: `[data-order-id="42"]`, not `.panel`), one `{ "axe": true }` and
one `{ "dumpDom": "<name>" }` on the final state.

```bash
scripts/run-probe.sh --self-test                 # once: asserts the probe works here
scripts/run-probe.sh --flows $OUT/flows.json --out $OUT/probe \
  --base-url http://host.docker.internal:5173 --runs 3 --cpu 4
# static build: --serve dist    non-local host: add --authorized-target (rule 4)
```

One `--out` per condition, never reused: `probe` (production build, `--cpu 4`:
the run of record, it feeds the scorecard), `probe-cpu1` (same build, no
throttle; a flag seen only at `--cpu 4` is still a finding, state the
condition), `probe-dev` (dev build: console signatures only, never latencies).

| Flag | Fires when | Suspect first |
|---|---|---|
| `interaction-latency` | Worst event > 200 ms (poor > 500 ms) | `latencyBreakdown`: high `processingMs` = handler or render work (S06, S07, S13); high `inputDelayMs` = something else was running; high `presentationMs` = large DOM or layout (S10, S11) |
| `main-thread-blocked` | >= 100 ms of blocking time in the step | `topScripts` names the script and invoker |
| `forced-layout` | >= 30 ms of forced style and layout | Proves forced layout cost; S11 only once the write/read loop is read in the source |
| `slow-result` | `expect` element visible after > 1 s | Network waterfall, missing progress state, S16 |
| `commit-storm` | >= 10 React commits for one interaction | S05, S06, S12; then S02, S03, S08 |
| `mutation-storm` | >= 1,500 DOM mutation records | S09 (rows remounting), S10 |
| `dropped-frames` | >= 5 % of main-thread frames late while scrolling | S10, S11, unthrottled scroll listeners |
| `layout-shift` | Shift score > 0.1 during the step | Content inserted above the viewport, images without dimensions |

The latency column, when it holds no number:

| Value | Meaning | Report as |
|---|---|---|
| `<16` | Input reached the page, no entry >= 16 ms observed | **No number**: probably fast, not a pass. Read `blockingMs`; over 50 ms, rerun with `--settle-ms 2000` |
| `n/a` | `hover`, `scroll`, `fill`, `select`: not timed interactions | Not a latency. Read `blockingMs`; use `type` instead of `fill` |
| `none` | No input reached the page (flag `no-input-event`) | **Not measured**: fix the step |
| `ERR` | The step failed | See the rule below |

Also collected per step: console messages, uncaught exceptions, failed
requests, HTTP >= 400. Match console text against the signature table in
`references/state-and-rendering-smells.md`.

Rules of interpretation:

- **A flag in 1 run of 3 is intermittent, not noise.** Report it as "1/3",
  rerun that flow with `--runs 10`; drop it only with a named environmental
  cause. Report median and max.
- **A step that errors is not automatically a flow bug.** Open the step's
  `error`, `pageErrors`, `console`, `httpErrors`. Exception, failed request or
  missing UI after a valid action = application finding (S1 candidate on a key
  flow). Selector that never matched a healthy page = fix the flow. Cannot
  tell = "Open questions". Later steps of that flow: "Not verified".
- Local runs have no network latency: `visibleAfterMs` is a lower bound for
  anything that waits on a request.

**Keyboard pass (required for the a11y line).** Re-drive each key flow with
`press` steps only (`Tab`, `Enter`, `Space`, `Escape`, arrows) and the same
`expect`. A failed script is not a finding yet: check where focus is, try other
keyboard paths and an `expect` fit for them. S1 only once the **task** cannot
be done by keyboard; else fix the script, or "Open questions". Focus visibility,
focus return after a dialog, screen reader, 200 % zoom and reflow need a
human: list them under "Not verified" unless someone did them. Zero axe
violations is never "WCAG conformant".

Then run the `web-analysis` tools on the same build (Lighthouse x3, median;
pa11y or axe; link check), on a URL they can reach: `--serve` is probe-only.

### Phase 4 - State and rendering review

The heart of the audit, and the part no tool completes. Procedure:

1. `scripts/smell-grep.sh <src>` for candidates; `eslint-audit.json` for lint hits.
2. Take the worst probe steps first. For each, list suspect smells (table
   above), open the handler and the components it touches, confirm or reject.
3. Sweep what tools cannot see, in this order, until the budget is spent:
   stores, contexts and selectors read by the key flows; then every data-
   changing handler of those flows (S16); then the three largest components.
   Placement (S01) and ownership (S12) are found only by reading. List what
   was **not** read under "Not verified".
4. For each confirmed smell record `file:line`, the measurement that shows its
   cost (or `proven-by-reading`), and the re-verification step.

| Id | Smell | Fastest confirmation |
|---|---|---|
| S01 | State at the wrong level (store vs component) | A store slice with one reader; a keystroke that commits far from the input |
| S02 | Subscribing to the whole store | `useStore()` without selector on a frequently written store |
| S03 | Selector returns a new reference each call | Inline `.filter`/`.map`/`{}` in a selector |
| S04 | Prop or store value mirrored into local state | `useState(props.x)`, `ref(props.x)` |
| S05 | State written during render (render loop) | Console signature; `set-state-in-render` lint hit |
| S06 | Derived data stored; effect -> setState -> effect cascade | An effect whose body only calls setters |
| S07 | Memoization missing, broken or excessive | Dependency list that lies; `memo` child fed inline objects |
| S08 | Context value identity churn | `value={{...}}` on a provider |
| S09 | Unstable or index keys | `key={index}` on a list that is reordered or holds state |
| S10 | Large list without virtualization | Real row count x nodes per row; `domNodes`; scroll frames |
| S11 | Layout thrashing | `forced-layout` flag + geometry read after a style write in a loop |
| S12 | Two-way sync between store and component | Two effects or watchers with mirrored dependencies |
| S13 | Expensive work on the render path | Deep clone, sort, formatter construction in render; template calls |
| S14 | Leaked subscriptions, timers, observers | Latency growing when a flow is repeated |
| S15 | Synchronous persistence on every update | `localStorage.setItem(JSON.stringify(state))` in a subscriber |
| S16 | Async race: a stale response overwrites newer state | Fetch in an effect or watcher with no abort and no "is this still current" guard |

Bad/good examples, the per-framework matrix, detection and limits for each id:
`references/state-and-rendering-smells.md`.

Example of what lint misses and reading finds (made-up example): in
`const done = useStore((s) => s.items.filter((i) => i.done))` no rule fires,
yet the selector allocates on every call (S03): on zustand 4 the component
re-renders on every store write, on zustand 5 it loops.

### Phase 5 - Report

Follow `references/report-template.md` exactly (sections, rubric, scorecard).
Severity: S1 a key flow fails or excludes users (render loop); S2 clearly
degraded (interaction over 500 ms, stale data); S3 confirmed, limited effect;
S4 hygiene. Deduplicate by root cause, cap `suspected` at S3, grade advisories
by exposure, give every top action a re-verify command. Verdict, first match
wins: any S1 **Blocked**; any S2 **Degraded**; no key flow driven, or no
static tool `ran`, **Insufficient evidence** (never "Healthy"); else **Healthy**.

## Decision table: where to go next

| Situation | Do |
|---|---|
| Only a production URL, no source | With approval: read-only flows + `web-analysis`; state review limited to probe signals, say so |
| `web-analysis` skill not available | Keep the probe's `axe` step; list Lighthouse, link check and headers under "Not verified" |
| `install` failed in the battery | Read `install.log`. Private registry: export a **read-only** `NPM_TOKEN`; the battery then lists the project's registry and auth settings (values redacted) and refuses until you read them and pass `--trust-pm-config`. Generated types: `--allow-scripts`, after reading the lifecycle scripts; never together with a token on a repo you do not trust |
| `build` failed offline | The build downloads (fonts, data): `--online`, only on a repo you trust |
| `tsc` reports hundreds of errors on a project whose CI is green | Wrong tsconfig (`--tsconfig`), or types generated at install. Compare with the CI command before reporting |
| Slow interaction, clean lint | Profile that step (DevTools Performance panel, framework profiler): the probe locates, it does not explain |

## Files

| Path | Content |
|---|---|
| `references/state-and-rendering-smells.md` | Smell catalogue S01-S16, console signatures, framework matrix, bad/good pairs |
| `references/thresholds.md` | Every threshold with its origin (standard vs house heuristic), lab vs field |
| `references/tooling-matrix.md` | Per tool: proves / cannot prove; trust boundary; flows file format; pinned versions |
| `references/report-template.md` | Finding format, severity rubric, scorecard, report skeleton |
| `references/glossary.md`, `references/review-dispositions.md` | Vocabulary with one example per term; log of the adversarial review of this skill |
| `scripts/static-battery.sh`, `scripts/lib/`, `scripts/eslint-audit.config.mjs` | Phase 2 runner, its stages and the pinned lint overlay |
| `scripts/run-probe.sh`, `scripts/interaction-probe.mjs`, `scripts/fixtures/`, `scripts/smell-grep.sh` | Phase 3 runner, probe, asserted self-test page; phase 4 candidate patterns |
