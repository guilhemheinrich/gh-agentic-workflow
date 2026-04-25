---
description: >-
  Lit 3 web components: base class, reactivity, lifecycle, templates, events,
  overlay patterns, and anti-patterns. Use when building or debugging Lit WCs.
tags:
  - lit
  - web-components
---

# Lit web components — practical guide

## Context

The **invariants** for Lit usage in this repo are summarized in `rules/03-frameworks-and-libraries/3-lit.mdc`. This skill holds the **procedural** detail and Lit-specific examples.

## Base component

- Extend `LitElement`, import from `lit`.
- `render()` returns a `TemplateResult` via `` html`...` ``.
- Styles via `` static styles = css`...` `` (scoped to shadow DOM).
- Registration via `@customElement('prefix-component-name')` (use your project’s tag prefix).

## Reactive properties

- `@property()` for public props (reflected as attributes when configured).
- `@state()` for internal state (no attribute).
- Use `{ type: Number }`, `{ type: Boolean }`, `{ type: Array }` for attribute → property conversion.
- Use `{ reflect: true }` only if the attribute must be readable from outside the shadow root.

## Lifecycle (order)

1. `connectedCallback()` — setup (global listeners, timers).
2. `disconnectedCallback()` — cleanup.
3. `willUpdate(changed)` — derived state before render.
4. `updated(changed)` — post-render (focus, scroll).
5. `firstUpdated()` — one-time work after the first render.

## Templates

- Bindings: `.prop=${val}`, `@event=${handler}`, `?bool=${flag}`.
- Lists: map items to templates; use `repeat()` when you need stable keys.
- Conditionals: ternary with `html` or `nothing` from `lit`.
- Slots: named slots for composition: `<slot name="header"></slot>`.

## Events

- Dispatch with `CustomEvent`, typically `{ detail, bubbles: true, composed: true }` so events cross shadow boundaries.
- Use a consistent `prefix-action` event naming policy for your design system.

## Overlays and nested custom elements

- A parent’s `updateComplete` does **not** guarantee a child custom element is defined and finished rendering.
- Before calling a method on a child: `await customElements.whenDefined('tag-name')` then `await child.updateComplete`.
- A host with `overflow: hidden` can clip `position: fixed` children in shadow DOM; toggle `overflow: visible` (for example via an attribute) while an overlay is open.

## Avoid

- `innerHTML` for templates — use `` html`...` ``.
- `querySelector` inside `render()` — prefer `@query` decorators.
- Heavy work in `render()` — precompute in `willUpdate()`.
- Mutating reactive properties in `render()` (risk of update loops).
- Calling methods on a child before `whenDefined` + `updateComplete`.

## Related rules

- Live docs playground: [wc-live-demos-starlight](../wc-live-demos-starlight/SKILL.md)
