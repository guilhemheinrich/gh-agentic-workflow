# Review dispositions

Adversarial review of this skill by three models of other lineages
(2026-11-24): GPT = `openai/gpt-6.2-astra`, Gemini = `google/gemini-4-neon`,
Kimi = `moonshotai/kimi-k3.1-pro`. None of them was given the scripts, so every
claim was checked against the files, the library sources or a live run before
being acted on. Totals: 34 root causes, 30 accepted, 2 rejected, 2 deferred.

Evidence runs: `run-probe.sh --self-test --runs 3` (exit 0, every assertion
met) and `static-battery.sh` on a throwaway React + TypeScript project (every
tool `ran`), both after the fixes. Library sources read from the npm tarballs
of `solid-js@1.9.9`, `@lit/reactive-element@2.1.1`, `zustand@5.0.8`,
`@angular/core@19.2.0`.

| # | Root cause | Raised by | Verdict | Evidence / fix |
|---|---|---|---|---|
| 1 | A missing Event Timing entry was printed `<16` and called "the best case" | GPT, Gemini | ACCEPTED | Reproduced: a `fill` whose handler burns 80 ms printed `<16`; so did `hover`, `scroll` and a failed step. The probe now counts trusted input events and reports `latencyStatus` (`measured`, `below-threshold`, `not-applicable`, `no-input-event`), printed `<16` / `n/a` / `none` / `ERR`; flag `no-input-event` |
| 2 | Event Timing "reports nothing under 16 ms" misstates the API (default threshold is 104) | Gemini | ACCEPTED | Wording fixed in `thresholds.md` and in the probe comment; the probe does set `durationThreshold: 16` |
| 3 | The self-test asserted nothing: it printed a table | found while verifying #1 | ACCEPTED | Per-step `expectFlags`, `expectNoFlags`, `expectLatency`; exit 3 on failure; the fixture covers the `not-applicable` and `no-input-event` cases |
| 4 | "A step that errors: fix the flow, do not report the app" hides application failures | GPT, Kimi | ACCEPTED | Rule replaced by a triage on `error`, `pageErrors`, `console`, `httpErrors`; later steps go to "Not verified" |
| 5 | "A flag in 1 run of 3 is noise" drops intermittent defects | Kimi | ACCEPTED | Now "intermittent": report the count, rerun with `--runs 10`, drop only with a named cause |
| 6 | `expect` proves visibility, not that the right thing appeared | GPT | ACCEPTED | Guidance and example use a selector that carries the meaning (`[data-order-id='42']`) |
| 7 | Accessibility: scanner impact used as WCAG conformance; no manual pass although keyboard exclusion is S1; target-size exceptions missing | GPT, Gemini, Kimi | ACCEPTED | Keyboard pass with `press` steps required before grading a11y; scorecard `partial (automated only)`; human-only checks listed under "Not verified"; thresholds reworded |
| 8 | A `critical` advisory in a build-time package was S4 by rule | GPT, Kimi | ACCEPTED | Rubric replaced by three exposure questions (browser, build/CI, unknown) with an example |
| 9 | No authorization gate before driving flows on a reachable URL | GPT, Gemini, Kimi | ACCEPTED | Ground rule 4, scope item, report scope line; the probe refuses a non-local host without `--authorized-target` (verified: exit 2 on `example.com`) |
| 10 | Project code ran next to `NPM_TOKEN`; `--allow-scripts` + token on an untrusted repo | GPT, Gemini, Kimi | ACCEPTED | Confirmed and wider than claimed: the build and the lint configs also ran with the token, and could write to the shared tools volume. Battery split into `tools` / `install` / `run` containers; verified with a build script that found no token (own env and PID 1) and could not write to the tools mount (`tools:/tools`). Residual: with `--allow-scripts` lifecycle scripts still see the token (documented) |
| 11 | Audit artifacts can hold session and personal data; `0.0.0.0` advice exposes a dev server | GPT, Gemini, Kimi | ACCEPTED | Outputs outside the repo, redaction and deletion rules; Docker bridge address preferred to `0.0.0.0` |
| 12 | INP described as "all interactions of all visits"; glossary defined INP as one interaction; 28 days presented as part of the metric | GPT, Gemini | ACCEPTED | Two-stage definition in `thresholds.md`; glossary split into "interaction latency" and "INP" |
| 13 | `--cpu 4` presented as a mid-range phone | GPT, Kimi | ACCEPTED | Reworded everywhere as a throttle relative to the audit host, including the probe's `caveat` and the example finding |
| 14 | `forced-layout` called proof of thrashing; S11 "good" example computed different values; `getComputedStyle()` listed as forcing layout; rAF intervals called dropped frames; commits not labelled root commits | GPT, Kimi, Gemini | ACCEPTED | Bad uses the running total, good used `heights[i]`: confirmed, fixed with the same running total. Flag and signals relabelled |
| 15 | Lit: "a property write in `render()` schedules another update" | GPT | ACCEPTED | `reactive-element.js:719`: `requestUpdate` enqueues only when `isUpdatePending === false`. Rewritten as a purity defect; the loop shape is a write in `updated()` |
| 16 | S03: "any hand-written `useSyncExternalStore` loops"; `===` equated with `Object.is` | GPT, Kimi | ACCEPTED | Narrowed to a `getSnapshot` that allocates. zustand 5 does exactly that (`react.js:8-11`), so the zustand claim stands |
| 17 | S12: "loops as soon as one side normalises" | GPT | ACCEPTED | Reworded: extra update always, lost edit sometimes, loop only when observed |
| 18 | Vue destructured props and Angular `NG0600` lacked version gates; `NG0100` mapped to S05 alone | GPT, Gemini, Kimi | ACCEPTED | Angular 19.2.0 message is "Writing to signals is not allowed in a `computed`" and `allowSignalWrites` is deprecated. Rows gated by version; signatures called triage evidence |
| 19 | Solid has no `Potential Infinite Loop Detected` message | Gemini | REJECTED | `solid-js@1.9.9/dist/dev.js:712`: `throw new Error("Potential Infinite Loop Detected.")`. Row kept, marked dev build |
| 20 | Vue `storeToRefs(store)` listed as whole-store subscription | Gemini | ACCEPTED | Cell contradicted itself; replaced by deep `watch` on `$state` and unfiltered `$subscribe` |
| 21 | TypeScript and lint results over-read as CI policy; solution-style `tsconfig.json` checks nothing | GPT, Gemini | ACCEPTED | Gemini's "silently bypasses" was wrong for the Vite layout (`tsconfig.app.json` was already picked) and right for any other name: reproduced, 0 errors on 0 files. The battery now counts project files and reports `skipped`. CI wording softened; other linters acknowledged |
| 22 | DOM-size bounds quoted as a Lighthouse verdict; bundle estimate called a lower bound | GPT | ACCEPTED | Both relabelled as house triggers / static estimate with the direction of each error |
| 23 | State review ignores async correctness (stale responses, rollback, double submit, cache keys) | GPT, Gemini | ACCEPTED | New smell S16 with example, checklist, matrix row and two grep sections. Sub-claims: network throttling in the probe DEFERRED (documented as a lower bound); LCP asset checks REJECTED (Lighthouse, via `web-analysis`, already audits them) |
| 24 | Runtime recipe not reproducible: "cold load" does not clear caches; pins never shown to resolve; `--serve` unreachable by the URL tools | GPT | REJECTED (2 of 3) | Each flow of each run gets a new browser context (`interaction-probe.mjs`, `newContext`), now stated. Both pinned stacks ran here. The `--serve` point is true and documented. A single end-to-end smoke recipe is DEFERRED |
| 25 | "Healthy" possible on negligible coverage; secondary path discounted twice; one finding per rule id hides causes; `not verified` hides findings of the tools that did run | GPT, Kimi, Gemini | ACCEPTED | Verdict "Insufficient evidence"; rubric graded as if on a key flow, reach applied once; `partial` scorecard status; grouping by cause and fix |
| 26 | Phase 3 runs overwrite each other; no run of record; `axe` and `dumpDom` absent from SKILL.md; validating dumped DOM re-ran the whole battery | Gemini | ACCEPTED | One `--out` per condition with the run of record named; flows recipe in SKILL.md; `--only vnu` now skips install (1.3 s measured) |
| 27 | `audit/` inside the repo modifies the checkout and feeds the next scan | Gemini | ACCEPTED | `$OUT` outside the checkout everywhere; `static-battery.sh` refuses `--out` inside `--project` |
| 28 | No fallback when `web-analysis` is missing; line-number citations into other skills rot | Gemini | ACCEPTED | Decision-table row; cross-skill citations now name the skill, without path or line |
| 29 | Phase 4 "read every store" is unbounded | Gemini | ACCEPTED | Ordered sweep starting from the key flows; unread files listed under "Not verified" |
| 30 | Client-side security neither checked nor excluded | Gemini | ACCEPTED | Declared out of scope in SKILL.md and in the report scope, pointing to `audit-security` |
| 31 | Hydration mismatches missing from the console signatures | Gemini | ACCEPTED | React, Vue and Svelte rows added. The `'use client'` boundary check is DEFERRED |
| 32 | "Field outranks every lab number" | Kimi | ACCEPTED | Field gives prevalence; a reproducible lab defect stays a finding |
| 33 | Glossary terms without an example | GPT, Gemini | ACCEPTED | Examples added for Core Web Vitals, LCP, INP, hydration, race, CPU throttling, `content-visibility`. Snippets for `getSnapshot`, compiler bailouts and a storage-state file are DEFERRED (volume) |
| 34 | No check that render errors are contained (error boundaries) | Gemini | DEFERRED | The probe reports uncaught exceptions where the flows walk; a containment review belongs to a resilience pass |
| 35 | Project tests are inspected but never run | Kimi | DEFERRED | Tests need the project's own environment and are not a static check. The report now always lists them under "Not verified" |

Rows 34 and 35 are the two deferred root causes; row 3 was not raised by a
reviewer and is not counted in the 34.

Known limits left by the fixes:

- The `run` stage has no registry credential, so `npm audit` / `pnpm audit`
  can fail when the default registry is private. `osv` still covers the
  lockfile.
- Container network egress is not restricted (installs need it). Narrowed
  in round 2: the `run` stage is offline (see Round 2).
- The `lit-web-components` skill of this repo lists "Mutating reactive
  properties in `render()` (update loops)"; row 15 shows it is not a loop in
  Lit. That file belongs to another skill and was not changed.

## Round 2

Second review of the fixed skill (2026-11-24), same three models. GPT:
REJECT, 8 findings; Gemini and Kimi: ACCEPT-WITH-FIXES, 7 and 6 findings.
Collapsed to 16 root causes: 16 accepted (row 2 partly), 0 rejected at
root-cause level; 3 sub-claims rejected and 7 deferred, named in their rows. Rows 17 and 18
were found while verifying and are not counted.

Evidence runs, after the fixes: `run-probe.sh --self-test --runs 3` (exit 0,
every assertion met); `static-battery.sh` on a throwaway npm project (every tool
`ran` except `eslint-project`, skipped: the fixture has no ESLint config),
and on pnpm and Yarn Berry projects for install, offline build and audit. Sources: `@lit/reactive-element@2.1.1`,
`lit-element@4.2.1`, `@vue/runtime-core@3.4.38` and `3.5.0`, React's
`scripts/error-codes/codes.json`.

| # | Root cause | Raised by | Verdict | Evidence / fix |
|---|---|---|---|---|
| 1 | The registry token met project package-manager config in `install`: "lifecycle scripts off" did not protect it | GPT, Gemini, Kimi | ACCEPTED | Reproduced in Docker with a fake token: `.pnpmfile.cjs` ran under `pnpm install --ignore-scripts` and saw the token; `yarnPath` ran; a project `.npmrc` sent `Bearer <token>` to a foreign host. `static-battery.sh` now refuses (exit 2, verified) while a token is set and the project has registry, auth or code-loading package-manager lines, printing them, until `--trust-pm-config`. Sub-claim "always pass `--ignore-pnpmfile`" REJECTED: with a lockfile that records `pnpmfileChecksum`, `--frozen-lockfile --ignore-pnpmfile` exits 1 on pnpm 9.15.9 and 10.12.1. Egress restricted to approved registries DEFERRED |
| 2 | Project code could send the checkout out (network in `run`); every stage writes the evidence folder | GPT | ACCEPTED (partly) | `run` is now `--network none` (verified: the build's `fetch` fails `EAI_AGAIN`); package managers reused offline through a corepack volume (pnpm build verified); `--online` is the opt-out. Audits moved to a networked `advisories` stage with no credential, on a fresh copy of the read-only checkout, so nothing `run` wrote reaches it; pnpmfile ignored there (`pnpm audit` also ran the pnpmfile: verified), Yarn skipped when `.yarnrc.yml` loads code; `npm-audit ran` on npm, pnpm and Berry fixtures. Not covered, DEFERRED and stated in `tooling-matrix.md`: code-loading package-manager config still runs in the networked `install` stage without a token; per-tool isolated outputs; a minimised source copy |
| 3 | Authorization inferred from network locality (private IPs, single-label names exempt) | GPT, Gemini, Kimi | ACCEPTED | `isLocalTarget` now exempts loopback and `host.docker.internal` only; `http://10.0.0.5:8080` and `http://web:3000` exit 2 (verified). The probe records every request origin (`meta.requestOrigins`, `origins contacted` line); approval covers host, backends and flows (rule 4, report scope). Sub-claim "single-label names allowed when `PROBE_NETWORK` is set" (Gemini) REJECTED: a compose name says nothing about ownership (GPT, Kimi). Blocking requests outside the approved origins DEFERRED: reported, not enforced |
| 4 | A missing Event Timing entry still read as "under 16 ms, best case" | GPT | ACCEPTED | `<16` is now "no number, not a pass" in SKILL.md, `thresholds.md`, the probe comment and its legend, with the rule "read `blockingMs`; over 50 ms, rerun with `--settle-ms 2000`". Sub-claim "keep it out of numeric summaries" REJECTED: already true, the aggregate pushes a latency only when `latencyMs !== null` and the table prints a number only when `latencyMs.max !== null` |
| 5 | One failed keyboard script declared S1 | GPT | ACCEPTED | Check focus, other keyboard paths and a fitting `expect` first; S1 only when the task is impossible by keyboard (SKILL.md, rubric example) |
| 6 | Verdict precedence: SKILL.md "Insufficient evidence when no flow was driven" vs template "Blocked: any S1" | GPT | ACCEPTED | Both now state one order, first match wins: S1, S2, coverage, Healthy |
| 7 | Lit: "the change never appears in `changedProperties`" | GPT | ACCEPTED | `lit-element` 4.2.1 `update()` calls `render()` before `super.update()`, whose `__markUpdated()` replaces the map afterwards, so `updated()` receives the write. Wording fixed; the write in `updated()` loops only when it passes `hasChanged` |
| 8 | React codes: `#423` called a mismatch; `#185`/`#301` missing; "React strips these checks" | GPT, Gemini | ACCEPTED | `codes.json`: 423 = error during hydration, recovered by client rendering; 185 and 301 are the production forms of the two loop messages. Rows split and added, note rewritten, "decode against the installed version". Gemini's sub-claim that Angular `NG0600`/`NG0103` and Svelte codes survive production builds DEFERRED: not verified |
| 9 | `thresholds.md` advisories row ("shipped dependencies") contradicted the exposure rubric | Gemini | ACCEPTED | Row now points to exposure grading |
| 10 | Angular: signals presented as a substitute for `OnPush` under zone.js | Gemini | ACCEPTED | Glossary (with example) and the matrix note reworded |
| 11 | S16 "good" example swallowed every error | Gemini | ACCEPTED | `.catch` now ignores `AbortError` only |
| 12 | Throttle modifier wording self-contradictory | Gemini | ACCEPTED | "CPU throttle never changes the level; state the condition" |
| 13 | `a11y` lost its `partial` mark after the keyboard pass | Kimi | ACCEPTED | Stays `partial (keyboard done; ... not checked)` until the human checks are done |
| 14 | Vue S16 cell required `onWatcherCleanup` (Vue 3.5+) | Kimi | ACCEPTED | Verified: absent from `@vue/runtime-core` 3.4.38 types, present in 3.5.0. Cell accepts `onCleanup`, `onWatcherCleanup` or a stale guard |
| 15 | S12 recipe asserted an input's live value with a CSS `expect` | Kimi | ACCEPTED | Recipe limited to values echoed as text, else a manual `$0.value` check. An `expectValue` step DEFERRED |
| 16 | INP "98th percentile when 50 or more" | Kimi | ACCEPTED | "one highest interaction ignored per 50" in glossary and thresholds |
| 17 | Yarn Berry ran the root `postinstall` although the battery claimed scripts off | found while verifying 1 | ACCEPTED | `yarn install --immutable` ran it; `YARN_ENABLE_SCRIPTS=0` did not stop it; `--mode=skip-build` does. Install now uses it unless `--allow-scripts` (verified in the battery: marker file absent) |
| 18 | `yarn npm audit --json` prints NDJSON, or nothing when clean: summary said `unreadable` | found while verifying 2 | ACCEPTED | `summarize.mjs` parses NDJSON and empty output (verified: 0 on a clean project, 1 on a one-advisory sample) |

Known limits left by round 2:

- `install` and `advisories` keep unrestricted egress.
- Outputs are writable by project code in `run`: evidence of a cooperative
  project, not proof against a hostile one.
- The probe reports origins outside the approved scope; it does not block them.
- `host.docker.internal` stays exempt from `--authorized-target` (it is the
  audit host); Kimi asked to gate it too: unresolved.

## Round 3

Termination check (2026-11-24). GPT: ACCEPT-WITH-FIXES, 5 findings; Gemini:
ACCEPT-WITH-FIXES, 1 finding; Kimi: ACCEPT, none. 6 root causes, 6 accepted.

| # | Root cause | Raised by | Verdict | Evidence / fix |
|---|---|---|---|---|
| 1 | The `--trust-pm-config` refusal printed raw `.npmrc` lines, literal secrets included | GPT | ACCEPTED | Reproduced: the round-2 guard echoed the whole line. It now prints file, line, setting name and URL host only. Verified with literal dummy `_authToken`, `_password` and `npmAuthToken`: exit 2, the dummy values appear in neither stdout nor stderr |
| 2 | A battery that ran with no tool `ran` could still give "Healthy" | GPT | ACCEPTED | Template and SKILL.md: coverage is read from `summary.json` tool states; no applicable tool `ran` = Insufficient evidence |
| 3 | A confirmed keyboard blocker matched both S1 and S2 | GPT | ACCEPTED | Graded by task outcome: a key task some users cannot complete = S1; the S2 example is now completable but impeded |
| 4 | S12 recipe: CSS `expect` cannot read text | GPT | ACCEPTED | CSS has no text selector. `expect` only when an attribute or distinct element encodes the value; else `$0.value` / `$0.textContent` by hand |
| 5 | S14 recipe compared across runs, but each run is a new browser context that resets the leak | GPT | ACCEPTED | Confirmed (`newContext` per flow and run). Compare before/after five in-app mount/unmount cycles inside one flow; confirm distinct listeners (same function re-added is a no-op) |
| 6 | Vue and Svelte hydration rows said "Same", which after the round-2 split pointed at React `#423` (recovered error) | Gemini | ACCEPTED | Both rows now state the mismatch meaning explicitly |
