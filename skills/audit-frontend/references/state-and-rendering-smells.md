# State-management and rendering smells

The catalogue used in phase 4 of the audit. Each smell has an id (`S01`..`S16`),
the runtime signal that should make you suspect it, how to detect it statically,
one bad/good pair, and what the detection cannot prove.

Conventions:

- **Every code example here is a made-up example** unless it cites a file. The
  React examples marked *verified* were linted with this skill's overlay
  (`scripts/eslint-audit.config.mjs`) and the quoted rule did fire.
- "Overlay" = the `eslint-audit` tool of `scripts/static-battery.sh`. "Grep" =
  a section of `scripts/smell-grep.sh` (candidates, never findings).
- "Probe" = a field or flag of `scripts/interaction-probe.mjs`.

A smell becomes a **finding** only with evidence: a `file:line` plus either a
measurement (commit count, latency, console signature) or an argument that
holds by reading the code alone (for example: the selector provably allocates
on every call). See `report-template.md` for the confidence levels.

## Index

| Id | Smell | Runtime signal | Static detection |
|---|---|---|---|
| S01 | State lives at the wrong level | Keystroke or pointer move re-renders unrelated UI; `commit-storm` | Manual: placement table below |
| S02 | Subscribing to the whole store | Commits on interactions that should not touch the component | Grep `S02-whole-store`, `S03-destructured-store` |
| S03 | Selector returns a new reference | Re-render on every store write; update-depth error | Grep `S03-selector-new-ref`; react-redux dev warning |
| S04 | Prop or store value mirrored into local state | Stale UI after the source changes | Grep `S04-prop-mirrored-in-state` |
| S05 | State written during render | Console signature (table below); frozen tab | Overlay `react-hooks/set-state-in-render`, `lit/no-this-assign-in-render`, `vue/no-side-effects-in-computed-properties` |
| S06 | Derived data stored, effect cascades | N commits for one click; one frame of wrong UI | Overlay `react-hooks/set-state-in-effect`, `svelte/prefer-writable-derived`; grep `S06-watch-writes-state` |
| S07 | Memoization missing, broken or excessive | High `processingMs`, long `reactRenderMs` | Overlay `react-hooks/exhaustive-deps`, `preserve-manual-memoization`; manual |
| S08 | Context value identity churn | Every consumer commits when the provider's parent renders | Overlay `react/jsx-no-constructed-context-values` |
| S09 | Unstable or index keys | Input focus or row state jumps; `mutation-storm` on reorder | Overlay `react/no-array-index-key`, `vue/require-v-for-key`, `svelte/require-each-key`; grep `S09-*` |
| S10 | Large list without virtualization | `domNodes` high, slow first render, `dropped-frames` on scroll | Grep `S10-list-rendering` + no virtualization dependency |
| S11 | Layout thrashing | `forced-layout` flag, `forcedStyleAndLayoutMs` in `topScripts` (forced layout happened: thrashing still to confirm) | Grep `S11-geometry-read`, `S11-unthrottled-listener` |
| S12 | Two-way sync between store and component | Update-depth errors, flicker, value snapping back | Grep `S12-two-way-sync`; manual |
| S13 | Expensive work on the render path | High `processingMs` with few commits | Grep `S13-deep-clone`, `S13-template-call` |
| S14 | Leaked subscriptions, timers, observers | Latency grows as the flow repeats; duplicate requests | Grep `S14-leak-candidates` vs `S14-teardown-sites` |
| S15 | Synchronous persistence on every update | Long task on each keystroke | Grep `S15-sync-storage` |
| S16 | Async race: stale response overwrites newer state | Wrong or old data after fast typing or navigation; no latency signal at all | Grep `S16-async-write-sites` vs `S16-guard-sites`; manual |

## Console signatures

The probe records console errors and warnings per step. These substrings are
triage evidence: they say which smells to look for first, and the stack trace
or the code confirms which one it is. Match by substring: wording drifts
between versions, and most appear in development builds only, so run phase 3
against a dev build at least once (`--out $OUT/probe-dev`).

| Substring in the console | Framework | Smell |
|---|---|---|
| `Too many re-renders` | React | S05 |
| `Maximum update depth exceeded` | React | S05, S06, S12, or S03 with `useSyncExternalStore` |
| `Cannot update a component` ... `while rendering a different component` | React | S05 |
| `The result of getSnapshot should be cached` | React | S03 |
| `returned a different result when called with the same parameters` | react-redux | S03 |
| `Each child in a list should have a unique "key" prop` | React | S09 |
| `Maximum recursive updates exceeded` | Vue | S05, S06, S12 |
| `NG0100` (`ExpressionChangedAfterItHasBeenChecked`) | Angular (dev) | S05, S06 or S12: a value changed between change detection and its check. Read the stack: getter that mutates, lifecycle hook writing parent state, async write |
| `NG0600` (`Writing to signals is not allowed in a computed`) | Angular | S05. Angular 19+: only writes inside `computed`. Angular 16-18: also writes inside `effect` without `allowSignalWrites` (then S06) |
| `NG0103` (infinite change detection) | Angular | S05, S12 |
| `effect_update_depth_exceeded` | Svelte 5 | S06, S12 |
| `state_unsafe_mutation` | Svelte 5 | S05 |
| `change-in-update` / `scheduled an update` ... `after an update completed` | Lit (dev mode) | S06 |
| `Potential Infinite Loop Detected` | Solid (dev build) | S06, S12 |
| `Minified React error #185` / `#301` | React (production) | Same as `Maximum update depth exceeded` / `Too many re-renders`: React keeps these loop guards in production |
| `Hydration failed`, `Minified React error #418` / `#425` | React SSR | Not an S-id: server and client rendered different HTML. Report as a `console` finding; the tree is re-rendered on the client |
| `Minified React error #423` | React SSR | An **error** was thrown during hydration and React recovered by client-rendering the root: find that error (dev build, or the preceding console line) before calling it a mismatch |
| `Hydration node mismatch`, `Hydration completed but contains mismatches` | Vue SSR | Not an S-id: server and client rendered different HTML (as React `#418`). Report as a `console` finding |
| `hydration_mismatch` | Svelte 5 SSR | Not an S-id: server and client rendered different HTML (as React `#418`). Report as a `console` finding |

Decode a minified React code against the installed React version
(`https://react.dev/errors/<code>`; codes 185, 301, 418, 423 and 425 checked
in React's `codes.json`). A clean production console proves nothing: dev-only
warnings (React's, `NG0100`, Vue's, Lit's, Solid's) are stripped there.

## Framework matrix

How each smell shows up per framework. Read the row, then open the section.

| Smell | React | Vue 3 | Svelte 5 | Solid | Angular (signals) | Lit |
|---|---|---|---|---|---|---|
| S02 whole store | `useStore()` with no selector; `useContext` of a big object | Not `storeToRefs(store)` (tracking is per property read). The Vue shape is a deep `watch` on the whole `store.$state`, or an unfiltered `store.$subscribe()` doing work on every mutation | Importing a whole `$state` object is fine: tracking is per property | Fine: per-property tracking, unless the store object is spread | Component reads a signal holding one large object | `@consume` of a large context object with `subscribe: true` |
| S03 new reference | Selector with `.filter`/`.map`/`{}`; fix with `useShallow`, `createSelector` | Vuex getter returning a function is not cached; `computed` is | `$derived` is cached; a getter function is not | `createMemo` is cached; a plain function re-runs per read | `computed` is cached; a template method call is not | A getter that allocates, read in `render()` |
| S04 mirrored prop | `useState(props.x)` | `ref(props.x)`; destructured `props` before Vue 3.5 or outside `<script setup>` (3.5+ `defineProps` destructuring stays reactive) | `let x = $state(prop)` | Destructured `props` (reactivity lost) | `signal(this.input())` | `@state` copied from a `@property` in `firstUpdated` |
| S05 write in render | `setState` in the component body | Assignment inside `computed` or in the template | Assignment inside `$derived` | Signal write in the component body is run-once, so harmless; write inside `createMemo` is not | Signal write inside `computed`; state change in a getter read by the template | `this.x = ...` in `render()`: impure, not a loop. The loop shape is a property write in `updated()` |
| S06 derived stored | `useEffect(() => setX(f(y)), [y])` | `watch(y, v => x.value = f(v))` | `$effect(() => { x = f(y) })` | `createEffect(() => setX(f(y())))` | `effect(() => this.x.set(f(this.y())))` | Assigning a reactive property in `updated()` instead of deriving in `willUpdate()` |
| S07 memoization | `useMemo`/`useCallback`/`memo` with wrong deps; moot where React Compiler is enabled | Rarely needed; `v-memo`, `shallowRef` for big immutable data | Rarely needed | Rarely needed; do not port `useMemo` habits | `OnPush` missing; pure pipes instead of template calls | `shouldUpdate`, `guard()`, `cache()` |
| S08 context identity | `value={{...}}` literal | `provide()` of a non-reactive snapshot (stale rather than churning) | `setContext` of a snapshot (stale) | Context value recreated is run-once, so stable | Service state exposed as a new object per read | `ContextProvider.setValue` with a fresh object each update |
| S09 keys | `key={index}`, random keys | `:key="index"`, missing `:key` | `{#each}` without `(key)` | `<For>` keys by reference; `<Index>` keys by position: pick deliberately | `@for` with `track $index`; `*ngFor` without `trackBy` | `map()` where `repeat(items, keyFn, ...)` is needed |
| S12 two-way sync | Two effects mirroring each other | `watch` both ways around `v-model` | `bind:` plus an `$effect` writing back | Two effects | `effect` + `model()` writing each other | Property reflected to attribute and re-read |
| S16 async race | `useEffect` + `fetch` + `setState`, no cleanup | `watch` + `await` + assignment with no stale guard: neither the callback's `onCleanup` argument (3.0+) nor `onWatcherCleanup` (3.5+) nor an "is this still current" check | `$effect` with an `await` then a write | `createEffect` + fetch instead of `createResource` | `subscribe` in `subscribe`, `mergeMap` where `switchMap` is meant | `await` in a lifecycle method, then a property write |

Angular with zone.js and default change detection (with or without signals):
every async event re-checks every non-`OnPush` component, so S07 and S13 dominate; look for
template function calls and missing `OnPush` before anything else.

---

## S01 - State lives at the wrong level

Where each kind of state belongs:

| The state is... | Example | Home |
|---|---|---|
| Used by one component and dies with it | menu open, hover, draft text of an input | Component state |
| Shared by one subtree | current step of a wizard | Nearest common parent, or a provider scoped to that subtree |
| A copy of server data | list of orders | A query cache (TanStack Query, RTK Query, SWR, Apollo), not a hand-written store slice |
| Part of the address of the screen | filters, page, selected id | The URL |
| Client-wide and long-lived | session, theme, cart | Global store |
| Changing more than ~10 times per second | pointer position, scroll offset, drag delta | A ref, a CSS custom property or a fine-grained signal: never a path that re-renders a tree |

Bad (React + Redux): the draft of a search box lives in the global store, so
each keystroke dispatches, runs every mounted selector, and re-renders every
component whose selector returns a new reference (S03).

```tsx
function SearchBox() {
  const query = useSelector((s: RootState) => s.search.draft);
  const dispatch = useDispatch();
  return <input value={query} onChange={(e) => dispatch(setDraft(e.target.value))} />;
}
```

Good: the draft is local; the store receives the committed value only.

```tsx
function SearchBox() {
  const [draft, setDraft] = useState('');
  const dispatch = useDispatch();
  return (
    <form onSubmit={(e) => { e.preventDefault(); dispatch(searchSubmitted(draft)); }}>
      <input value={draft} onChange={(e) => setDraft(e.target.value)} />
    </form>
  );
}
```

The opposite error is as common: state kept too low, then duplicated in
siblings and re-synchronised with effects (which is S04 and S12).

Detect: for each store slice, list its readers (`grep -rn "s.search.draft"`).
One reader means the slice is component state in disguise. At runtime, a
`type` step in the probe that shows React commits or DOM mutations far from
the input is the signal; confirm with the React DevTools profiler ("why did
this render").

Cannot prove: that a placement is wrong for the product. A single-reader slice
may exist because it must survive navigation. State the reason you checked.

## S02 - Subscribing to the whole store

Bad (zustand; *verified* as grep candidate `S02-whole-store`):

```tsx
const store = useStore();          // re-renders on ANY store write
return <span>{store.filter}</span>;
```

Good:

```tsx
const filter = useStore((s) => s.filter);
```

The same shape in other stacks: `useSelector((s) => s)`, `useContext(AppContext)`
where the context holds ten unrelated fields, a component injected with a whole
NgRx state object. Vue, Svelte 5 and Solid track per property, so reading a
whole reactive store there is not a problem by itself; destructuring it is
(reactivity lost in Pinia without `storeToRefs`, in Solid always).

Detect: grep, then count the store's write frequency. A whole-store reader of a
store written once per session is harmless; of a store written per keystroke it
is a finding.

Cannot prove: the cost. Only a commit count during a real interaction does.

## S03 - Selector returns a new reference on every call

Subscriptions decide whether to re-render by comparing the previous and the
next selected value by reference (`Object.is` in zustand and
`useSyncExternalStore`, `===` in react-redux; the two differ only for `NaN`
and `-0`). A selector that builds an array or object returns a value that is
never equal to the previous one.

Bad (zustand; *verified* as grep candidate `S03-selector-new-ref`):

```tsx
const done = useStore((s) => s.items.filter((i) => i.done));
```

With zustand 4 this re-renders the component on every store write. With zustand
5 it is an infinite loop (`Maximum update depth exceeded`): its `useStore`
passes `() => selector(api.getState())` as the `getSnapshot` of
`useSyncExternalStore`, so the snapshot itself is never stable. The same holds
for any hand-written `useSyncExternalStore` whose `getSnapshot` allocates. It
does **not** hold when `getSnapshot` returns a stable value and the array is
derived afterwards, nor for bindings that take an equality function
(`useStoreWithEqualityFn`, react-redux `shallowEqual`): check which binding is
used before reporting a loop.

Good, three options in order of preference:

```tsx
// 1. select the stable input, derive in the component
const items = useStore((s) => s.items);
const done = useMemo(() => items.filter((i) => i.done), [items]);

// 2. shallow comparison of the result
const done = useStore(useShallow((s) => s.items.filter((i) => i.done)));

// 3. memoized selector (Redux: reselect)
const selectDone = createSelector([(s: RootState) => s.items], (items) => items.filter((i) => i.done));
```

A reselect selector is itself a smell when its **input** selectors allocate
(`(s) => ({ a: s.a, b: s.b })` as input): the memo never hits.

Detect: grep; in development react-redux logs `returned a different result when
called with the same parameters`. Runtime: a component that commits on store
writes unrelated to it.

Cannot prove: grep sees only selectors written inline. A selector imported from
another file and allocating there is invisible: open the selector files.

## S04 - Prop or store value mirrored into local state

Bad:

```tsx
function Price({ amount }: { amount: number }) {
  const [value, setValue] = useState(amount);   // frozen at mount
  return <span>{value}</span>;
}
```

When `amount` changes, `value` does not. The usual "fix" is an effect that
copies the prop again, which is S06 plus one wasted render with stale data.

Good: use the prop. If the component needs an editable draft seeded from the
prop, make the reset explicit with a key on the caller side:

```tsx
<PriceEditor key={order.id} initialAmount={order.amount} />
```

Vue: `const local = ref(props.amount)` has the same freeze; use
`computed(() => props.amount)` or `toRef(props, 'amount')`.

Cannot prove: intent. `initialX` props are a legitimate pattern; the smell is a
mirrored value that the UI expects to stay live.

## S05 - State written during render

Rendering must be a pure computation of the UI from state. What a write during
render costs depends on the framework: in React it schedules another render,
which writes again (a loop unless guarded); in Lit it does not.

Bad (Lit; *verified*, the overlay reports `lit/no-this-assign-in-render`):

```ts
render() {
  this.count = this.items.length;   // impure: written while the update is already running
  return html`<p>${this.count}</p>`;
}
```

In Lit this is **not** a loop: a property set while an update is pending
schedules no new cycle (checked in `@lit/reactive-element` 2.1.1,
`requestUpdate`). The defect is purity: `willUpdate` and `shouldUpdate` ran
with the old value. The write is recorded in the `changedProperties` that
`updated()` receives (`lit-element` 4.2.1 calls `render()` before
`super.update()` clears the map), but nothing re-renders for it.
Report it as S05 at low severity. The Lit loop is a property write in
`updated()` that passes `hasChanged` (a new object, a counter): it schedules
another update (dev warning `change-in-update`). Writing the same primitive
again schedules nothing.

Good: derive before rendering, in `willUpdate()` (the `lit-web-components`
skill gives the same rule).

```ts
willUpdate(changed: PropertyValues<this>) {
  if (changed.has('items')) this.count = this.items.length;
}
```

Other shapes: a Vue `computed` that assigns (`vue/no-side-effects-in-computed-properties`,
*verified*), a React component calling a parent's setter in its body, an
Angular getter that mutates and is read by the template (`NG0100`).

The only tolerated case in React is a guarded write to the component's **own**
state to reset it when a prop changes (`if (prev !== next) setPrev(next)`). It
must be guarded, and it is still better replaced by a `key`.

Cannot prove: a write hidden behind a function call (`render()` calls
`this.normalise()` which assigns). Follow the calls made from render functions.

## S06 - Derived data stored instead of computed, and effect cascades

If a value can be computed from other state, storing it creates a second source
of truth, an extra render, and one frame where the two disagree.

Bad (React; *verified*, the overlay reports `react-hooks/set-state-in-effect`
twice and `react-hooks/exhaustive-deps` once):

```tsx
const [visible, setVisible] = useState<Item[]>([]);
const [count, setCount] = useState(0);

useEffect(() => {
  setVisible(rows.filter((r) => r.label.includes(filter)));
}, [rows]);                       // filter is missing: stale result

useEffect(() => {
  setCount(visible.length);       // second link of the chain
}, [visible]);
```

One change of `rows` costs three commits: with the new rows and the old list,
with the new list and the old count, then with everything consistent. In the
probe this is the `reactCommits` count of the step (measured on a comparable
chain of 12 effect-driven updates: 13 commits for one click).

Good: no state, no effect.

```tsx
const visible = useMemo(() => rows.filter((r) => r.label.includes(filter)), [rows, filter]);
const count = visible.length;
```

Equivalents: Vue `computed`, Svelte `$derived` (*verified*: the overlay reports
`svelte/prefer-writable-derived` on `$state` + `$effect`), Solid `createMemo`,
Angular `computed` (or `linkedSignal` when the derived value must stay
writable), Lit `willUpdate`.

Effects are for synchronising with something **outside** the framework: the
network, the DOM, a timer, a third-party widget. An effect whose body only
calls setters is suspect by construction.

Cannot prove: that an effect is illegitimate. Fetch-on-change is a real
external synchronisation (and belongs in a query library, which is an
architecture remark, not a defect).

## S07 - Memoization missing, broken or excessive

Three different defects under one name.

Missing: an expensive pure computation runs on every render, or a child
wrapped in `memo` receives a new object or function on every render and never
skips.

```tsx
<Chart data={points.map(toXY)} onHover={(p) => setHover(p)} />   // both props are new each render
```

Broken: the dependency list lies. *Verified*: the overlay reports
`react-hooks/exhaustive-deps` on the first line.

```tsx
const sorted = useMemo(() => visible.sort(byId), []);   // never recomputed, and sort() mutates state
```

Excessive: `useMemo`/`useCallback` around trivial expressions, with no memoized
consumer downstream. It costs a comparison and a retained closure per render,
buys nothing, and hides the places where memoization matters.

Rule of thumb for an audit: memoization is justified when (a) the computation
is measurably slow (above ~1 ms on the audit's throttled CPU), or (b) the value
is a dependency of an effect or a prop of a memoized child. Otherwise report it
as noise at the lowest severity, or not at all.

React Compiler: when the project enables it (`babel-plugin-react-compiler` or
the framework's flag), manual memoization is mostly redundant and the finding
shifts to "code the compiler bails out on": the overlay's
`react-hooks/preserve-manual-memoization` and `react-hooks/immutability` rules
report those.

Cannot prove: cost. Never recommend adding or removing memoization without a
profile (`processingMs`, `reactRenderMs`, or the DevTools flame chart).

## S08 - Context value identity churn

Bad (React; *verified*, the overlay reports `react/jsx-no-constructed-context-values`):

```tsx
<Ctx.Provider value={{ user, setUser }}>
```

A new object on every render of the provider's parent: every consumer
re-renders even when `user` did not change, and `memo` does not protect them.

Good:

```tsx
const value = useMemo(() => ({ user, setUser }), [user]);
<Ctx.Provider value={value}>
```

Better when the context mixes fast and slow data: split it (one context for
state, one for stable actions), or move it to a store with selectors.

Cannot prove: churn through a custom provider component that builds the object
elsewhere; read every `createContext` call and trace its `value`.

## S09 - Unstable or index keys

A key tells the framework which row is which between two renders.

Bad (React; *verified*, the overlay reports `react/no-array-index-key`):

```tsx
{sorted.map((item, i) => <Row key={i} item={item} />)}
```

Insert a row at the top and every existing row receives its neighbour's props
while keeping its own DOM and state: the text typed in row 0 now sits next to
another label. A random key (`key={crypto.randomUUID()}`) is worse: every row
is destroyed and recreated on every render, which the probe shows as a
`mutation-storm`.

Good: `key={item.id}`. Index keys are acceptable only for lists that are never
reordered, filtered or inserted into, and whose rows hold no state.

Angular: `@for (item of items; track item.id)`; `track $index` has the same
defect as an index key. Lit: `repeat(items, (i) => i.id, template)` rather
than `items.map(...)` when rows hold state or are expensive.

Cannot prove: that the list is reordered. Find the write sites of the array
(sort, unshift, filter, pagination) before reporting.

## S10 - Large list without virtualization

Every row of a non-virtualized list costs DOM nodes, style, layout and memory
whether it is on screen or not.

Evidence to collect: the realistic maximum length (ask for production data
volumes, do not assume the dev fixture), `domNodes` from the probe's `goto`
step, and a `scroll` step for `dropped-frames`. Node counts alone are not a
finding (~800 and ~1,400 are the bounds of Lighthouse's legacy `dom-size`
audit, a trigger): the finding is the measured style, layout or scroll cost.

Fix options, cheapest first: paginate; CSS that lets the browser skip
off-screen rows (`.row { content-visibility: auto; contain-intrinsic-size:
auto 48px; }`, where 48px is the estimated row height); windowing (`@tanstack/virtual`,
`react-window`, `vue-virtual-scroller`, Angular CDK `cdk-virtual-scroll-viewport`,
`@lit-labs/virtualizer`).

Cannot prove: grep finds rendering sites, not lengths. A `.map()` over five
items is not a finding.

## S11 - Layout thrashing (forced synchronous layout)

The browser batches layout. Reading a geometry property after a style write
forces it to compute layout immediately. In a loop, that is one forced layout
per iteration. One read after one write is not thrashing: measuring an element
once after changing it is legitimate, and can still be slow on a large DOM
(then the problem is S10, not S11).

Bad: real code from this skill's fixture,
`scripts/fixtures/slow-page.html:50-58`, measured by the probe at 822 ms of
forced style and layout for 3,000 rows:

```js
for (const row of rows) {
  row.style.paddingLeft = (total % 7) + 'px';   // write
  total += row.offsetHeight;                    // read: forces layout, every iteration
}
```

Good: read everything, then write everything, keeping the same running total
(same result as long as the padding does not change a row's height).

```js
const heights = Array.from(rows, (row) => row.offsetHeight);   // reads: one layout
let total = 0;
rows.forEach((row, i) => {                                      // writes only
  row.style.paddingLeft = (total % 7) + 'px';
  total += heights[i];
});
```

APIs that force layout when styles are dirty include `offsetWidth/Height/Top/Left`,
`clientWidth/Height`, `scrollTop/Height`, `getBoundingClientRect()`,
`innerText` and `focus()`. `getComputedStyle(el)` alone forces nothing: reading
a property on its result forces a style recalculation, and a layout only for
layout-dependent properties (`.width`, `.height`, `.top`).

Framework shapes: measuring in a React `useLayoutEffect` of each row of a list,
a Vue `updated` hook reading `el.offsetHeight` per item, a scroll listener
without `requestAnimationFrame` that reads and writes.

Detect: the probe's `forced-layout` flag proves that scripts forced layout and
what it cost; its `topScripts` entry gives the script URL and character
offset. It becomes S11 when the source at that offset shows the write/read
pair repeated (a loop, a per-row hook, a scroll listener). Grep
`S11-geometry-read` gives the candidates to match against it.

Cannot prove: LoAF attribution only exists for frames longer than 50 ms. Many
small forced layouts spread over short frames stay invisible: use the DevTools
Performance panel ("Forced reflow" warnings) for those.

## S12 - Two-way synchronisation between store and component

Bad (Vue):

```ts
const local = ref(store.filter);
watch(local, (v) => { store.filter = v; });
watch(() => store.filter, (v) => { local.value = v; });
```

Two sources of truth held equal by two watchers. Always: one extra update per
change. Sometimes: a lost edit, when one side normalises the value (the user
types "01", the store keeps `1`, the input snaps back) or when an asynchronous
write interleaves. Rarely: a real loop, only when the two sides never agree on
a value (each rewrites what the other wrote); Vue skips a write of an
unchanged primitive, so an idempotent normalisation converges. Report the
loop only when you observed it (console signature, oscillating value).

Good: one owner, one writable view of it.

```ts
const filter = computed({
  get: () => store.filter,
  set: (v) => { store.filter = v; },
});
```

React shape: `useEffect(() => setLocal(prop), [prop])` together with
`useEffect(() => onChange(local), [local])`. Fix: make the component
controlled (value + onChange, no local copy), or uncontrolled with a `key`.

Detect: grep `S12-two-way-sync` lists the binding sites; the finding is a pair
of effects or watchers with mirrored dependencies in the same component.

Cannot prove: a lost edit or a loop that only starts with specific data.
Reproduce with the probe by typing a value that the store normalises (leading
space, `01`). `expect` is a CSS selector: it cannot read text, nor an
input's live `value` (`[value="01"]` matches the attribute, which the
framework may never update). Use it only when an attribute or a distinct
element encodes the value (`[data-filter="01"]`); otherwise check
`$0.value` or `$0.textContent` by hand in DevTools.

## S13 - Expensive work on the render path

Work that runs on every render or every change-detection pass, whatever
changed: `JSON.parse(JSON.stringify(x))` or `structuredClone` of large state,
sorting or filtering thousands of rows in the component body, date or number
formatters constructed per cell (`new Intl.DateTimeFormat` per row), an
Angular template calling `{{ total(items) }}`.

Bad (Angular template): `<td>{{ formatPrice(row) }}</td>` runs for every row
on every change detection. Good: a pure pipe, or a `computed` that maps the
rows once.

Signal: an interaction with high `processingMs` and a low commit count. The
`lit-web-components` skill lists the same anti-pattern for Lit: heavy work in
`render()` belongs in `willUpdate()`.

Cannot prove: that the work is expensive for real data sizes. Measure with
production-like volumes or say that the volume is assumed.

## S14 - Leaked subscriptions, timers and observers

Bad:

```ts
onMounted(() => { window.addEventListener('resize', onResize); });   // no onUnmounted
```

Each mount adds a listener that survives the component. After ten visits to
the screen, one resize runs ten handlers on ten dead component instances.

Detect: grep compares `S14-leak-candidates` with `S14-teardown-sites`, file by
file. Runtime: every run starts a new browser context, which resets any
leak, so compare **inside one flow**: time an interaction, open and leave the
screen five times by in-app navigation (no `goto`: it reloads the document),
then time the same interaction again. Growth within the flow, seen in each of
`--runs 3`, is the signal; confirm in the code that distinct listeners survive
(re-adding the same function to the same target is a no-op). In React development builds, StrictMode's double mount
makes a missing cleanup visible as duplicated effects.

Cannot prove: memory growth. That needs heap snapshots (DevTools Memory panel),
which this skill does not automate.

## S15 - Synchronous persistence on every update

Bad: a store subscriber that runs `localStorage.setItem('state',
JSON.stringify(state))` on every change. `localStorage` is synchronous and the
serialisation is O(state size): a keystroke that touches the store pays for
the whole state.

Good: persist a small slice, debounced, or on `visibilitychange`; use
IndexedDB for large data.

Detect: grep `S15-sync-storage`, then check the call site is inside a
subscriber, a watcher or a reducer. Signal: a long task on each keystroke with
the storage call in the probe's `topScripts`.

## S16 - Async race: a stale response overwrites newer state

A correctness smell with no performance signal: latency, commits and lint can
all be clean while the screen shows the wrong data.

Bad (React; made-up example; grep candidate `S16-async-write-sites`):

```tsx
useEffect(() => {
  fetch(`/api/search?q=${q}`).then((r) => r.json()).then(setRows);
}, [q]);
```

Type "du" then "dup": if the answer for "du" arrives last, the list shows the
results for "du" under a box that says "dup".

Good: cancel or ignore what is no longer current.

```tsx
useEffect(() => {
  const ctrl = new AbortController();
  fetch(`/api/search?q=${q}`, { signal: ctrl.signal }).then((r) => r.json()).then(setRows)
    .catch((err) => { if (err.name !== 'AbortError') setError(err); });
  return () => ctrl.abort();
}, [q]);
```

Better: a query library keyed by `q` (TanStack Query, SWR, RTK Query, Solid
`createResource`, Angular `rxResource` or `switchMap`), which does this once.

The same family, to check on every data-changing handler of a key flow:

| Shape | Question to answer by reading |
|---|---|
| Stale response | Can an older request resolve after a newer one and write state? |
| Optimistic update | When the request fails, is the optimistic change rolled back and the user told? |
| Double submit | Does a second click while the first request is pending send it twice? |
| Cache key | Is every input of the request (user, tenant, filters) part of the cache key? A missing one shows one account's data to another |

Detect: compare grep `S16-async-write-sites` with `S16-guard-sites`, then
read. Runtime, only where mutating flows are allowed (ground rule 4): a `type`
step with a short `delayMs` and an `expect` that names the final value.

Cannot prove: the probe cannot reorder or fail responses. Without a test that
does, the finding is `proven-by-reading` when the code has no guard at all,
`suspected` otherwise.

---

## Review procedure

1. Start from evidence, not from the catalogue. Take the worst steps of the
   probe and the top rules of the overlay.
2. For each one, name the suspect smells from the Index and the console
   signature table, open the code, and confirm or reject.
3. Then sweep what tools cannot see, in this order, until the budget is
   spent: the stores, `createContext` calls and selector files read by the key
   flows; the data-changing handlers of those flows (S16); the three largest
   components. Apply S01 (placement) and S12 (ownership) by hand: no tool
   detects them. Write down what was not read: it goes to "Not verified".
4. For each confirmed smell, write the re-verification step before the fix:
   which probe step, which metric, which target value.
5. Reject a candidate explicitly when the code is legitimate, and keep a line
   in the report's "Checked and cleared" list: it stops the next audit from
   re-raising it.
