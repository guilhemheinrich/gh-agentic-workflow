---
name: cursor-dot-glow
description: >-
  Build a cursor-following "spotlight" of dots over a faint dot-grid background,
  rendered on a full-viewport canvas. Dots near the pointer light up in an accent
  colour with a smooth Gaussian falloff; the lit position trails the cursor with
  easing. Reverse-engineered from zo.computer's hero background. Use when adding an
  interactive ambient background, a hero dot field, a pointer spotlight, or a
  reveal-on-hover dotted texture.
tags:
  - frontend
  - canvas
  - animation
  - background
  - interaction
---

# Cursor Dot-Glow Background

An ambient, interactive background: a faint grid of dots covers the surface, and the
dots near the pointer brighten into an accent-coloured glow that softly trails the
cursor. This is the effect on the [zo.computer](https://www.zo.computer) hero.

## How it works

Two stacked layers fill the same box (`position: absolute; inset: 0`):

1. **Base dot texture** — a CSS `radial-gradient` tile that is always visible.
   `background-image: radial-gradient(<color> 1px, transparent 1px)` with
   `background-size: 6px 6px` and low opacity (~0.2). This is cheap and static.
2. **Glow canvas** — a full-viewport `<canvas>` with `pointer-events: none`. Every
   frame it clears, then repaints only the dots within a radius of the (eased)
   pointer position, each at an opacity that falls off with distance.

The canvas does **not** redraw the whole grid — it only iterates the grid cells inside
a bounding box around the cursor, so cost is constant regardless of viewport size.

### The measured numbers (from zo.computer)

| Parameter | Value | Notes |
|---|---|---|
| Grid spacing | `6px` | same as the CSS base layer, so they align |
| Dot size | `2px` (`fillRect(x, y, 2, 2)`) | square dots |
| Accent colour | `rgb(201, 100, 66)` | their terracotta `--primary`; set **once** per frame |
| Peak opacity | `~0.40` | alpha at the exact cursor centre |
| Falloff | **Gaussian**, `σ ≈ 26px` | `alpha = PEAK * exp(-dist² / (2σ²))` |

The falloff is the load-bearing detail: the alpha sequence sampled per column
(`…0.36, 0.389, 0.40, 0.389, 0.36…`) fits `0.40 · exp(-d²/2σ²)` with `σ≈26` almost
exactly — a linear or quadratic falloff looks wrong. Colour is set once with
`fillStyle`; per-dot intensity comes from `ctx.globalAlpha`, not from rgba strings.

## Implementation notes

- **Trail the cursor with easing.** Keep a `target` (real pointer) and a `pos`
  (painted) point; each frame `pos += (target - pos) * EASE` (EASE ≈ 0.12). This is
  what makes the glow feel soft rather than rigidly pinned to the cursor.
- **Listen on `window` with `pointermove`** (covers mouse, pen, touch). The canvas
  itself is `pointer-events: none` so it never intercepts clicks.
- **Cap DPR** at 2 (`Math.min(devicePixelRatio, 2)`) and `setTransform(dpr,…)` so dots
  stay crisp on retina without exploding the work on 3x displays.
- **Only iterate near the cursor.** Snap the loop window to the grid and skip cells
  past `RADIUS` (use `RADIUS = 3σ`) and below a tiny alpha threshold (`< 0.004`).
- **Respect `prefers-reduced-motion`** — when set, skip the rAF loop (the static base
  layer alone is a fine fallback).
- Align the canvas grid origin with the CSS tile (both start at `0` with `6px` step)
  so the lit dots register on top of the faint ones instead of shimmering between them.

## Template

[`references/dot-glow.html`](references/dot-glow.html) is a complete, self-contained,
browser-verified reproduction. Copy it and tune the constants block at the top of the
script (`GRID`, `DOT`, `SIGMA`, `PEAK`, `EASE`, `COLOR`).

## Pitfalls

- Putting the falloff in an `rgba()` string per dot instead of `globalAlpha` works but
  is slower and harder to tune — keep colour constant, vary alpha.
- A hard radius cutoff with no smooth falloff gives a visible disc edge. Use the
  Gaussian (or at least a `smoothstep`).
- Forgetting `pointer-events: none` on the canvas breaks every link/button beneath it.
