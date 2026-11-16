---
description: >-
  Lit 3 web components: update lifecycle order, scrolling and overlay pitfalls,
  child-element readiness, and anti-patterns. Use when building or debugging Lit WCs.
tags:
  - lit
  - web-components
---

# Lit web components — practical guide

Invariants for Lit usage are summarized in `rules/03-frameworks-and-libraries/3-lit.mdc`.
Baseline Lit knowledge (`LitElement`, `@property`, `@state`, `html`, `css`, events) is assumed.

## Lifecycle

- `connectedCallback()` / `disconnectedCallback()` are custom-element callbacks, **not** part of the update cycle. Use them to add/remove global listeners and timers.
- Each update runs in this order: `willUpdate(changed)` -> `render()` -> `firstUpdated()` (first update only) -> `updated(changed)`.
- Compute derived state in `willUpdate()`; do focus/scroll work in `updated()`.

## Nested custom elements

- A parent's `updateComplete` does **not** guarantee a child custom element is defined and finished rendering.
- Before calling a method on a child: `await customElements.whenDefined('tag-name')`, then `await child.updateComplete`.

## Scrolling and overlays

- Set `:host { display: block }`. Avoid `100vh` or fixed heights inside shadow DOM; the page/app root owns the single scroll.
- For a nested scroller: `min-height: 0` on the flex parent plus `overscroll-behavior: contain` (add `scrollbar-gutter: stable` when layout shift matters).
- `overflow: hidden` does not clip `position: fixed` descendants. Clipping happens only when an ancestor has `transform`, `filter`, `contain` or `will-change`, which makes it the containing block.
- For menus and dropdowns, prefer `popover` / the top layer over relative-positioning tricks.

## Avoid

- `innerHTML` for templates; use `` html`...` ``.
- `querySelector` inside `render()`; prefer `@query`.
- Heavy work in `render()`; precompute in `willUpdate()`.
- Mutating reactive properties in `render()` (update loops).

## Related

- Live docs playground: [wc-live-demos-starlight](../wc-live-demos-starlight/SKILL.md)
