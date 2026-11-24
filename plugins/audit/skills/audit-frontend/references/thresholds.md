# Thresholds

Every number the audit compares against, with its origin. Two kinds, never to be
confused in a report:

- **Standard**: published by a browser vendor or a standards body. Quote it as is.
- **House heuristic**: chosen for this skill so that the probe can raise a flag.
  It is a trigger to investigate, not a pass/fail criterion. Say "house
  heuristic" when a finding relies on one.

## Lab versus field

Core Web Vitals thresholds are defined on **field data**: the 75th percentile
of real users' page views (CrUX aggregates them over a rolling 28 days; a RUM
tool may use another window). Everything this skill measures is **lab data**:
one machine, one network, a scripted user.

Concrete example: the probe's self-test measures a 600 ms click on
`scripts/fixtures/slow-page.html`. That is "this interaction, on this machine,
took 600 ms", which is over the 500 ms line. It is not "the page's INP is
600 ms". INP is built in two stages: each page view keeps its worst interaction
(on busy views, one highest interaction is ignored per 50 interactions), then
the field value is the 75th percentile of those per-view values.

Consequences for the report:

- A lab value over a threshold is a finding. A lab value under it is not a
  proof of health: a developer laptop is several times faster than a median
  phone. Run the probe with `--cpu 4` and without, and report both.
- `--cpu 4` slows **this host** four times. It is a stand-in, not a phone: no
  mobile memory, GPU, thermal or network behaviour. Write "4x CPU throttle on
  <host>", never "on a mid-range phone"; device claims need a real device.
- Field data (CrUX, a RUM tool, `web-vitals` beacons) says how many users are
  affected, on which devices. Use it for prevalence, for the same route and
  metric. A good field p75 does not cancel a reproducible lab defect: the p75
  hides one route, one interaction and the slowest quarter of visits.

## Interaction and runtime (probe)

| Metric | Good | Needs improvement | Poor | Origin |
|---|---|---|---|---|
| Interaction latency (INP) | <= 200 ms | 200-500 ms | > 500 ms | Standard (web.dev, Core Web Vitals) |
| Long task | - | - | any task >= 50 ms | Standard (W3C Long Tasks: definition, not a grade) |
| Blocking time of one step (`blockingMs`) | < 100 ms | 100-300 ms | >= 300 ms | House heuristic |
| Forced style and layout in one step | < 30 ms | 30-90 ms | >= 90 ms | House heuristic |
| Time until the expected result is visible (`visibleAfterMs`) | <= 1,000 ms | 1,000-3,000 ms | > 3,000 ms | 1 s: Nielsen's limit for uninterrupted flow of thought. 3 s: house heuristic |
| Layout shift during a step | <= 0.1 | 0.1-0.25 | > 0.25 | Standard values of CLS, applied to one step (house use) |
| Framework commits for one interaction | < 10 | >= 10 | - | House heuristic |
| DOM mutation records for one interaction | < 1,500 | >= 1,500 | - | House heuristic |
| Late frames while scrolling | < 5 % | 5-25 % | >= 25 %, or one frame > 100 ms | House heuristic; a `requestAnimationFrame` interval over 25 ms at 60 Hz. Main-thread frames, not compositor frames: a compositor-driven scroll can stay smooth |

Reading rules:

- The probe observes Event Timing with `durationThreshold: 16`, the lowest
  value the API accepts (its default is 104); durations are rounded to 8 ms.
  No entry is therefore ambiguous, and the probe separates four cases in
  `latencyStatus`: `measured`; `below-threshold` (printed `<16`: a trusted
  pointer or key event reached the page and no entry of 16 ms or more was
  observed: probably fast, but an entry can also be lost or arrive after the
  settle window); `not-applicable` (printed `n/a`: `hover`, `scroll`, `fill`
  and `select` are not Event Timing interactions); `no-input-event` (printed
  `none`: nothing reached the page). Only `measured` is a latency, and only it
  enters the median and max. For `<16`, `blockingMs` is the evidence: `<16`
  with blocking time over 50 ms means rerun with a larger `settleMs`. Verified
  on the fixture: a `fill` whose handler burns 80 ms has no interaction entry.
- Perception anchors (Nielsen, also the basis of the RAIL model): 100 ms feels
  instantaneous, 1 s keeps the flow of thought, 10 s loses attention. An
  interaction with a good INP and a 2.5 s `visibleAfterMs` needs a progress
  indicator, not a faster handler.
- An animation frame has 16.7 ms at 60 Hz; the browser needs part of it, which
  leaves about 10 ms for script.

The numeric constants live in `scripts/interaction-probe.mjs` (object `T`). If
you change one, change this table.

## Page load (Lighthouse, via the `testing-and-debugging:web-analysis` skill)

| Metric | Good | Poor | Origin |
|---|---|---|---|
| Largest Contentful Paint | <= 2.5 s | > 4.0 s | Standard (Core Web Vital) |
| Cumulative Layout Shift | <= 0.1 | > 0.25 | Standard (Core Web Vital) |
| First Contentful Paint | <= 1.8 s | > 3.0 s | Standard (web.dev) |
| Time to First Byte | <= 0.8 s | > 1.8 s | Standard (web.dev) |
| Total Blocking Time (lab proxy for INP) | <= 200 ms | > 600 ms | Lighthouse mobile scoring |
| Lighthouse category score | >= 90 | < 50 | Lighthouse |
| DOM size | <= ~800 elements | > ~1,400 elements | House use of the bounds of Lighthouse's legacy `dom-size` audit. Not a standard: a trigger to check style and layout cost (S10), never a finding by itself |

Lighthouse scores vary by several points between runs. Run it three times and
report the median; never report a single run as a regression or a gain.

## Bundle (static battery, `bundle.json`)

| Metric | Budget | Origin |
|---|---|---|
| JavaScript needed for first load, gzip | <= 170 kB; poor above 350 kB | 170 kB: widely used critical-path budget for mid-range phones on slow 4G. 350 kB: house heuristic |
| CSS needed for first load, gzip | <= 50 kB | House heuristic |
| Any single JS chunk, uncompressed | <= 500 kB | Vite's default `chunkSizeWarningLimit` |
| All JavaScript in one chunk | flagged when over 500 kB | House heuristic (no code splitting) |

A budget is a default. If the project defines its own (`size-limit`,
`bundlesize`, Lighthouse `budget.json`, Angular `budgets` in `angular.json`),
audit against the project's numbers and report whether CI enforces them.

`initialJsGzipKb` is a static estimate, not a transfer size: see the limits in
`tooling-matrix.md`.

## Static quality gates

| Check | Expected | Note |
|---|---|---|
| `tsc --noEmit` | 0 errors | Errors have three possible causes: CI does not type-check, CI is red on this commit, or the audit used another tsconfig or missed generated types. Compare with the CI command before reporting |
| Strictness gap (`tsc-strict` minus `tsc`) | 0 | A gap is not a defect list: it sizes the unchecked surface, as a lower bound (a strict sub-option set to `false` in the tsconfig stays off). Read the "project files checked" count in the note |
| ESLint, project config | 0 errors | Warnings: report the count and the top rules. No ESLint config is a finding only when no other linter (Biome, oxlint, `ng lint`) gates CI |
| ESLint audit overlay | no `error`-level hit | Every hit is a candidate for phase 4, not automatically a finding |
| HTML validity (vnu) | 0 errors | Duplicate ids and invalid nesting break accessibility APIs and hydration |
| Accessibility (axe, pa11y) | 0 violations of WCAG A/AA rules | The scanner's impact (`critical`..`minor`) orders the work; it is not a conformance level: a `moderate` violation can fail an AA criterion. Record rule id and criterion. Automated rules find roughly a third to a half of real issues: zero violations is not conformance |
| Keyboard pass (probe `press` steps) | Every key flow completes | Required before grading a11y: see SKILL.md, phase 3 |
| Dependency advisories | 0 advisories with established exposure | Grade by exposure (browser, build/CI, unknown), not by the scanner label and not "shipped only": see `report-template.md` |
| Console during flows | 0 errors, 0 uncaught exceptions | Warnings: report framework warnings, ignore third-party noise explicitly |
| Network during flows | 0 failed requests, 0 unexpected HTTP >= 400 | A 401 on a deliberate logged-out probe is expected: say so |

Accessibility reference values used by the tools: text contrast 4.5:1 (3:1 for
large text); pointer target at least 24 x 24 CSS px (WCAG 2.2, 2.5.8), with
exceptions: enough spacing around a smaller target, an equivalent control,
inline links in text, browser-default controls, essential presentation.
