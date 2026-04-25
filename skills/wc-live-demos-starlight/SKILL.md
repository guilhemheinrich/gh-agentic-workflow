---
description: >-
  Live playground for Web Components in Astro Starlight: iframe srcdoc, CodeMirror,
  bidirectional sync, controlled components, IIFE bundling, Docker pitfalls.
tags:
  - astro
  - documentation
  - starlight
  - web-components
---

# Web Components live demos in Starlight — full procedure

## Context

The **invariants** (iframe isolation, bidirectional sync, vanilla playground host) are in `rules/03-frameworks-and-libraries/3-wc-live-demos-in-starlight.mdc`. This skill is the **end-to-end tutorial** for building and maintaining the playground.

## Architecture (typical)

```
Starlight page (parent)
├── <live-playground>          ← vanilla WC (Shadow DOM, not Lit)
│   ├── CodeMirror 6 editor    ← code pane
│   └── <iframe srcdoc="...">  ← preview (isolation)
│       ├── component IIFE bundle
│       ├── init script        ← controlled-event wiring, fixtures
│       ├── ResizeObserver     ← height → postMessage
│       └── MutationObserver   → attribute changes → postMessage
```

- Implement the shell as a **vanilla** custom element to avoid version clashes with the Lit components inside the iframe.
- Use `srcdoc` on the iframe for full CSS/JS/DOM isolation; load the component as a consumer would in production.
- Use `postMessage` between the editor, parent, and iframe as needed.

## Code → preview

- Editor `updateListener` (or equivalent) detects document changes.
- Debounce (for example 500ms) to limit re-renders.
- Fast path: update the user markup inside the iframe without a full reload when safe.
- Slow path: full `srcdoc` reload on first load or after unrecoverable errors.

## Preview → code

- `MutationObserver` in the iframe watches relevant nodes (for example attribute changes on a container’s direct children).
- Post messages with attribute lists; the parent updates the editor document in a transaction.
- Only **reflected** HTML attributes need to round-trip; JS-only properties are set in the init script, not in the visible snippet.

## Anti-loop

- Set a boolean flag before applying editor updates that originate from the iframe; skip editor-driven preview updates while that flag is set; reset on the next frame.

## Controlled component pattern

If components are “controlled” (state driven from outside), the iframe init script must wire events that write back, for example:

```javascript
el.addEventListener('range-change', (e) => { el.date = e.detail.start; });
el.addEventListener('view-change', (e) => { el.view = e.detail.newView; });
```

Without this wiring, the preview can look “frozen”.

## MDX usage

- Pass the initial HTML in a `code` attribute with HTML-entity encoding as required by MDX.
- Keep only reflected attributes in the snippet; set complex props in the init script.

## IIFE bundle and tree-shaking

- If `package.json` has `"sideEffects": false`, bundlers may drop side-effect-only imports that register custom elements.
- **Mitigations**: export component classes from the package entry; configure `treeshake.moduleSideEffects: true` (or equivalent) for the IIFE build; verify the bundle contains CSS class names and strings unique to the component after build.

## Build pipeline (typical)

| Artifact        | Source              | Output                    |
|----------------|---------------------|---------------------------|
| Component IIFE | app package         | `dist-iife/*.iife.js`     |
| Playground     | `src/playground/*`  | `public/playground-*.js`  |

Regenerate playground assets when the editor component changes; wire `predev` / `prebuild` if the project does so.

## Starlight `head` scripts

- Load the IIFE with a regular script tag (not `type="module"`) if that matches the bundle.
- Load the playground bundle after or alongside any legacy static demo scripts.

## Docker pitfalls

- Bind-mounting all of `public/` over the container can hide built IIFE assets. Prefer narrow mounts or build inside the image.
- Ensure the IIFE path in the image matches the path referenced in doc pages.

## Checklist (new component)

1. Export from the library entry so the class is not tree-shaken away.
2. Extend the iframe init: `whenDefined`, event wiring, fixtures.
3. Add MDX with encoded `code` attribute.
4. Rebuild IIFE and playground; verify strings/CSS in the output bundle.

## Related

- Lit component patterns: [lit-web-components](../lit-web-components/SKILL.md)
