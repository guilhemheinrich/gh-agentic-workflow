---
description: Eliminate double scrollbars and ensure seamless component dynamic expansion
tags:
  - css
  - vue
  - web-components
---
**Domain:** UX / Web Component Integration & Layout
**Objective:** Eliminate double scrollbars and ensure that a component's dynamic expansion (e.g., dropdown menu) is handled natively by the browser.

---

## 1. The Theory: Why Does It Break?
The problem occurs when two "scroll contexts" conflict.

* **The Shadow DOM Trap:** By default, a Web Component is `display: inline`. It does not communicate its actual height to the parent. If you force an internal height with `overflow: auto`, you create a "box within a box" that scrolls independently.
* **The Flow Conflict:** If a component uses `position: fixed` or `absolute` for its options, it leaves the CSS flow. The parent "thinks" the component is small, while its content visually overflows.

---

## 2. Behavior Rules (The "How")

### A. The Component (The Content Provider)
The component must be **"Height-Agnostic"**. It must never decide its own vertical limit.

1.  **Existence declaration:** Use `:host { display: block; }`. This allows the component to occupy the full width and calculate its height based on its content.
2.  **Scroll transparency:** Apply `overflow: visible;` on the component's root element.
3.  **Natural expansion:** Expandable elements (accordions, advanced settings) must use normal flow (`static` or `relative`). When opening, they increase the component's size, which increases the parent's size.

### B. The Parent Application (The Scroll Master)
The application is the sole authority over scrolling.

1.  **Flexible container:** The Web Component's container must have neither a fixed `height` nor `max-height`.
2.  **Scroll delegation:** Only the application root (or the main page container) owns the `overflow-y: auto` property.

---

## 3. Implementation Decision Matrix

| If I want to... | I do (Component) | I do (Parent) |
| :--- | :--- | :--- |
| **Add content** | Let the DOM stretch naturally. | Don't constrain the slot's height. |
| **Avoid double scroll** | `overflow: visible` is mandatory. | `overflow-y: auto` on the global wrapper. |
| **Display options** | Use `relative` to push the bottom. | Provide bottom padding on the page. |

---

## 4. AI Logic (System Prompting)
> "When generating a Web Component, ensure the component is a 'Flow Citizen'.
> 1. Set `:host` to `display: block`.
> 2. Prohibit the use of `height: 100%` or `100vh` inside the Shadow DOM.
> 3. Delegate overflow management to the parent to maintain a unified scroll experience (`Single Source of Scroll`)."

---

> **Design intent note:** This approach ensures the user is never stuck in a "scroll dead-end" where their scroll wheel does nothing because it hovers over a zone that has already reached its own bottom, while the global page is still long.
