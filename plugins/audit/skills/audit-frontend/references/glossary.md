# Glossary for human readers

Each term with one concrete example. Examples that cite a path are real and can
be opened; the others are marked "made-up example".

## Measuring what users feel

**Main thread** - The single thread on which a page runs its JavaScript, computes
styles and layout, and reacts to input. While it is busy, clicks wait.
Real example: `scripts/fixtures/slow-page.html:44-47`, a click handler that
burns 600 ms; during that time the page cannot react to anything.

**Long task** - Any uninterrupted piece of main-thread work of 50 ms or more.
Real example: the handler above is one 600 ms long task; the probe reports
`longTasks: 1`, `blockingMs: 550` (the part beyond 50 ms).

**Interaction latency** - How long the page takes to paint the next frame
after a click, tap or key press (the frame need not show the final result).
Made-up example: you tap "Add to cart" and the button only looks pressed
700 ms later: that interaction's latency is 700 ms.

**INP (Interaction to Next Paint)** - The score of a whole page view: the
latency of its **worst** interaction (on busy views, one highest interaction
is ignored per 50). Good is 200 ms or less, poor is over 500 ms. Made-up example: a visit
with clicks of 40, 90 and 700 ms has an INP of 700 ms. The probe measures
single interactions, never an INP.

**Input delay / processing / presentation** - The three parts of an
interaction's latency: waiting for the main thread to be free, running the
event listeners, then rendering the result. Real example (probe self-test, the
`#slow` button): input delay 0.4 ms, processing 600 ms, presentation 0 ms, so
the listener itself is the problem.

**Long Animation Frame (LoAF)** - A browser report on any frame that took over
50 ms to produce, naming the scripts that ran in it. Real example: for the
`#thrash` button the probe prints `invoker: "BUTTON#thrash.onclick"` with
`forcedStyleAndLayoutMs: 822`.

**Layout thrashing (forced synchronous layout)** - Alternating "change a style"
and "read a size" so that the browser must recompute the page layout on every
read. Real example: `scripts/fixtures/slow-page.html:50-58` does it 3,000
times in a loop.

**Late (dropped) frame** - A screen refresh the page's main thread failed to
prepare in time (every 16.7 ms at 60 Hz), seen as stutter. Real example: the
fixture's scroll listener (`slow-page.html:81`) burns 40 ms per scroll event,
so about one frame in four is late.

**Core Web Vitals** - Google's three user-experience metrics: LCP (loading),
INP (responsiveness), CLS (visual stability). Made-up example, one page: the
order heading appears at 2 s (LCP); the filter button repaints 80 ms after the
click (that interaction's latency); an unsized banner then pushes the heading
down (CLS). The results arriving 2 s after the click are none of the three:
that is the probe's `visibleAfterMs`.

**LCP (Largest Contentful Paint)** - When the biggest visible element (hero
image, main heading) finishes rendering. Good is 2.5 s or less. Real example:
the probe's `goto` step reports `lcpMs` and `lcpElement` for the fixture.

**CLS (Cumulative Layout Shift)** - How much content jumps around unexpectedly.
Made-up example: an ad loads above an article and pushes the text down while
you read; a score over 0.1 needs work.

**TBT (Total Blocking Time)** - Sum of the "over 50 ms" parts of long tasks
during page load. A lab stand-in for responsiveness.

**Lab data vs field data** - Lab: one scripted run on one machine (everything
this skill measures). Field: what real users experienced, aggregated (CrUX,
RUM). Made-up example: the lab shows a 180 ms click on a developer laptop; the
field shows 450 ms at the 75th percentile because most users are on phones.

**p75 (75th percentile)** - The value that 75 % of measurements are better
than. "INP p75 = 300 ms" means one visit in four was worse than 300 ms.

**CPU throttling** - Artificially slowing the browser to imitate a weaker
device. `--cpu 4` makes scripts run about four times slower than on the audit
host. Made-up example: 4x on a recent laptop is roughly a mid-range phone's
script speed, 4x on an old CI runner is far slower; neither reproduces a
phone's memory, GPU or network.

## State and rendering

**State** - Data that can change while the page is open and that the UI
depends on. Made-up example: the text in a search box, the list of results,
whether a menu is open.

**Store** - A container for state shared by many components (Redux, Zustand,
Pinia, NgRx, a Svelte store). Made-up example: the shopping cart, read by the
header badge and by the checkout page.

**Component state** - State owned by one component and invisible to the rest.
Made-up example: whether one dropdown is open.

**Source of truth** - The one place where a piece of state lives; every other
use should be a view of it. Made-up example: if the selected order id is in
the URL *and* in a store, the two can disagree after "back".

**Render / re-render** - The framework recomputing what a component should
display. Cheap once, expensive when it happens for hundreds of components that
did not need it.

**Commit** - The moment the framework applies a finished render to the page.
Real example: this skill's probe counted 13 React commits for one click on a
test page that chains 12 state updates through an effect; one would have been
enough.

**Re-render storm** - One user action causing many unnecessary renders.
Made-up example: typing one letter re-renders the whole product grid because
the grid reads the same store object as the search box.

**Selector** - A function that picks one piece out of a store, so that a
component re-renders only when that piece changes. Made-up example:
`(s) => s.cart.items.length` for the header badge.

**Referential equality** - Two values are "the same" only if they are the same
object in memory, not if they look alike. `[1, 2] === [1, 2]` is `false`.
Frameworks use this test to decide whether something changed, which is why a
selector that builds a new array each time always looks "changed".

**Derived state** - A value that can be computed from other state. Made-up
example: `total = sum of item prices`. It should be computed when needed, not
stored and kept in sync by hand. The `frontend:lit-web-components` skill gives the rule
for Lit: compute derived state in `willUpdate()`.

**Effect** - Code that a framework runs after rendering, meant for talking to
the outside world (network, timers, the DOM). Using effects to copy state into
other state is the most common source of cascades.

**Memoization** - Remembering the result of a computation and reusing it while
its inputs are unchanged. Made-up example: sorting 5,000 rows once and reusing
the sorted list until the rows or the sort order change.

**Key** - The identity given to each row of a rendered list so the framework
can match rows between two renders. Made-up example: `key={order.id}` is
stable; `key={index}` changes meaning when a row is inserted at the top.

**Virtualization (windowing)** - Rendering only the rows currently visible in
a long list. Made-up example: a 10,000-row table that keeps about 30 rows in
the DOM while you scroll.

**Hydration** - A server-rendered page being taken over by client JavaScript.
The page looks ready before it can react; mismatches between server and
client HTML cause errors and re-rendering. Made-up example: the server renders
"12:00" and the client "12:01"; React logs `Hydration failed` and rebuilds
that subtree.

**Race condition (stale response)** - Two asynchronous operations finishing in
an order the code did not expect. Made-up example: you type "du", then "dup";
the answer for "du" arrives last and replaces the results for "dup".

**Change detection** (Angular) - The pass in which Angular checks which
bindings changed. Under zone.js, every `Default` component is re-checked after
every event, even when it reads signals; only `OnPush` (with or without
signals) limits the pass. Made-up example: a click in a toolbar re-runs the
template of a 500-row `Default` table that did not change.

**Signal** - A value that knows who reads it, so that a change updates only
those readers (Solid, Angular, Vue refs, Svelte runes). Made-up example:
changing a `count` signal updates one text node, not the component.

## Static checks

**TypeScript strict mode** - A set of compiler options that refuse unsafe
code, such as using a value that may be `undefined`. Real example from this
skill's test run: `App.tsx(25,11): error TS2532: Object is possibly
'undefined'` appeared only with `--strict`.

**Linter (ESLint, stylelint)** - A program that reads source code and reports
known mistakes without running it. Made-up example: `<img>` without `alt`.

**Validity (HTML, CSS)** - Conformance to the language's grammar. Real example
from this skill's test run: `<div>` directly inside `<ul>` and a duplicated
`id` were reported by the Nu Html Checker.

**Accessibility (a11y), WCAG** - Whether people using a keyboard, a screen
reader or high zoom can use the page; WCAG is the reference standard, level AA
the usual target. Made-up example: a clickable `<div>` that cannot be reached
with the Tab key. A scanner's "impact" (`serious`, `moderate`) is its own
priority scale, not a WCAG level.

**Bundle, chunk, code splitting** - The JavaScript files a build produces
(bundle), each file (chunk), and the practice of loading a chunk only when a
screen needs it. Made-up example: the admin screens in their own chunk, not
downloaded by ordinary visitors.

**Tree shaking** - The build removing code nobody imports. `import { debounce }
from 'lodash-es'` can be shaken; `import _ from 'lodash'` usually cannot.

**Performance budget** - A size or time limit the team agrees not to exceed,
checked in CI. Example used by this skill: 170 kB of compressed JavaScript for
first load.

**Dead code / unused dependency** - Files, exports or packages nothing
references. They cost install time, attack surface and reading time.

**Advisory (CVE, GHSA)** - A published vulnerability in a package version.
**Exposure** is where the vulnerable code runs and on whose input: in the
browser on user input, or in the build pipeline next to deploy credentials.
Made-up example: a flaw in a Markdown renderer matters in the browser if it
renders user comments, and in CI if it renders files from pull requests.

**Lockfile** - The file recording the exact version of every installed
package (`package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`). Without it two
installs can produce two different applications.
