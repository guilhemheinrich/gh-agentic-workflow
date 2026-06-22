# Resizable Panel Pattern

Source basis:
- Grafikart tutorial: https://grafikart.fr/tutoriels/resize-javascript-1938
- Pointer Events reference: https://developer.mozilla.org/en-US/docs/Web/API/Pointer_events
- CSS clamp reference: https://developer.mozilla.org/en-US/docs/Web/CSS/clamp

## Guidelines

- Store the live size in a CSS custom property, not in repeated inline widths.
- Let the layout consume that variable through grid or flex sizing.
- Make the pointer target larger than the visible divider.
- Use Pointer Events for mouse, touch, and pen with a single code path.
- Use `touch-action: none` on the handle.
- Clamp the resulting size in CSS so viewport-dependent limits remain declarative.
- Use pointer capture or document-level listeners, and always clean up on `pointerup` and `pointercancel`.
- Compute size relative to the layout container, not the full page, unless the panel is explicitly viewport-bound.

## HTML

```html
<div class="split-layout" data-resizable-layout>
  <aside class="split-layout__sidebar">
    <div
      class="split-layout__handle"
      role="separator"
      tabindex="0"
      aria-label="Resize sidebar"
      aria-orientation="vertical"
      aria-valuemin="240"
      aria-valuenow="320"
      data-resize-handle
    ></div>
    <!-- Sidebar content -->
  </aside>

  <main class="split-layout__main">
    <!-- Main content -->
  </main>
</div>
```

## CSS

```css
.split-layout {
  --sidebar-width: 320px;
  --sidebar-width-safe: clamp(240px, var(--sidebar-width), 50vw);

  display: grid;
  grid-template-columns: var(--sidebar-width-safe) minmax(0, 1fr);
  min-height: 100%;
}

.split-layout__sidebar {
  position: relative;
  min-width: 0;
}

.split-layout__main {
  min-width: 0;
}

.split-layout__handle {
  position: absolute;
  inset-block: 0;
  inset-inline-end: -10px;
  width: 20px;
  padding: 0;
  border: 0;
  background: transparent;
  cursor: ew-resize;
  touch-action: none;
}

.split-layout__handle::after {
  content: "";
  position: absolute;
  inset-block: 0;
  inset-inline: 9px;
  background: color-mix(in srgb, currentColor 35%, transparent);
  opacity: 0;
  transition: opacity 160ms ease;
}

.split-layout__handle:hover::after,
.split-layout__handle:focus-visible::after,
.split-layout.is-resizing .split-layout__handle::after {
  opacity: 1;
}

.split-layout.is-resizing,
.split-layout.is-resizing * {
  cursor: ew-resize;
  user-select: none;
}
```

## JavaScript

```js
/**
 * Attach a horizontal drag resizer to a split layout.
 *
 * CSS remains responsible for clamping:
 *   grid-template-columns: clamp(240px, var(--sidebar-width), 50vw) 1fr;
 *
 * @param {object} options
 * @param {HTMLElement} options.layout Element that owns the CSS variable.
 * @param {HTMLElement} options.handle Element that receives pointer interaction.
 * @param {string} [options.property] CSS variable to update.
 * @param {"left"|"right"} [options.edge] Which side owns the resizable panel.
 * @returns {() => void} Cleanup function for framework unmount hooks.
 */
export function attachHorizontalResizer({
  layout,
  handle,
  property = "--sidebar-width",
  edge = "left",
}) {
  let frame = 0;
  let activePointerId = null;
  let containerRect = null;

  function setWidthFromPointer(event) {
    if (!containerRect) return;

    const width =
      edge === "right"
        ? containerRect.right - event.clientX
        : event.clientX - containerRect.left;

    cancelAnimationFrame(frame);
    frame = requestAnimationFrame(() => {
      const roundedWidth = Math.round(width);
      layout.style.setProperty(property, `${roundedWidth}px`);
      handle.setAttribute("aria-valuenow", String(roundedWidth));
    });
  }

  function stopResize(event) {
    if (activePointerId !== event.pointerId) return;

    activePointerId = null;
    containerRect = null;
    layout.classList.remove("is-resizing");
    handle.releasePointerCapture?.(event.pointerId);
    handle.removeEventListener("pointermove", moveResize);
    handle.removeEventListener("pointerup", stopResize);
    handle.removeEventListener("pointercancel", stopResize);
  }

  function moveResize(event) {
    if (activePointerId !== event.pointerId) return;
    event.preventDefault();
    setWidthFromPointer(event);
  }

  function startResize(event) {
    if (!event.isPrimary) return;

    event.preventDefault();
    activePointerId = event.pointerId;
    containerRect = layout.getBoundingClientRect();
    layout.classList.add("is-resizing");
    handle.setPointerCapture?.(event.pointerId);
    handle.addEventListener("pointermove", moveResize);
    handle.addEventListener("pointerup", stopResize);
    handle.addEventListener("pointercancel", stopResize);
    setWidthFromPointer(event);
  }

  handle.addEventListener("pointerdown", startResize);

  return () => {
    cancelAnimationFrame(frame);
    handle.removeEventListener("pointerdown", startResize);
    handle.removeEventListener("pointermove", moveResize);
    handle.removeEventListener("pointerup", stopResize);
    handle.removeEventListener("pointercancel", stopResize);
    layout.classList.remove("is-resizing");
  };
}
```

## Keyboard Support

```js
/**
 * Add keyboard resizing to the same CSS variable used by pointer drag.
 */
export function attachKeyboardResizer({
  layout,
  handle,
  property = "--sidebar-width",
  step = 16,
}) {
  function currentWidth() {
    const raw = getComputedStyle(layout).getPropertyValue(property);
    const parsed = Number.parseFloat(raw);
    return Number.isFinite(parsed) ? parsed : 320;
  }

  function onKeyDown(event) {
    const direction =
      event.key === "ArrowRight" ? 1 : event.key === "ArrowLeft" ? -1 : 0;

    if (direction === 0) return;

    event.preventDefault();
    const nextWidth = currentWidth() + direction * step;
    layout.style.setProperty(property, `${nextWidth}px`);
    handle.setAttribute("aria-valuenow", String(nextWidth));
  }

  handle.addEventListener("keydown", onKeyDown);
  return () => handle.removeEventListener("keydown", onKeyDown);
}
```

## Framework Cleanup

```js
const cleanupPointer = attachHorizontalResizer({ layout, handle });
const cleanupKeyboard = attachKeyboardResizer({ layout, handle });

// React effect cleanup, Lit disconnectedCallback, Vue onUnmounted, etc.
function cleanup() {
  cleanupPointer();
  cleanupKeyboard();
}
```
