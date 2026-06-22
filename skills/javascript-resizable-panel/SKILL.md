---
name: javascript-resizable-panel
description: Build controlled drag-to-resize sidebars, split panes, and panels in frontend applications using CSS variables, Pointer Events, accessible resize handles, cleanup-safe listeners, and CSS clamp limits. Use when implementing or fixing JavaScript resizing behavior for layouts, sidebars, editors, dashboards, resizable panes, or drag handles across mouse, touch, and pen input.
---

# JavaScript Resizable Panel

## Workflow

Use this skill when the UI needs application-controlled resizing rather than the browser's native `resize` CSS property.

1. Prefer a CSS layout variable for the resizable dimension, for example `--panel-width`.
2. Apply the variable to grid or flex sizing, and bound it with `clamp()` in CSS.
3. Add a dedicated resize handle that is visually narrow but has a wider hit area.
4. Use Pointer Events instead of separate mouse and touch listeners.
5. During drag, update only the CSS variable from pointer coordinates.
6. On pointer end or cancel, remove transient cursor, selection, and listener state.

## Implementation Notes

- Set `touch-action: none` on the handle so touch gestures can resize instead of being interpreted as browser pan/zoom.
- Use `clientX` or `clientY` with `getBoundingClientRect()` when resizing inside a container; avoid page-wide assumptions unless the panel starts at viewport edge.
- Use `setPointerCapture()` where possible so the drag keeps working when the pointer leaves the handle.
- Keep min/max bounds in CSS with `clamp(min, var(--size), max)` so responsive limits stay visible in styles.
- Add keyboard support when the handle is focusable: arrow keys adjust the same CSS variable in fixed steps.
- Do not leave document-level listeners, `user-select: none`, or global cursor styles active after drag completion.

## Resources

Read [grafikart-resizable-panel.md](references/grafikart-resizable-panel.md) when implementing the pattern. It contains a compact source summary and commented snippets for HTML, CSS, JavaScript, keyboard support, and framework cleanup.
