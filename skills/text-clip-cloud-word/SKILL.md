---
name: text-clip-cloud-word
description: >-
  Make a single word in a heading reveal a moving layer (drifting clouds video,
  animated gradient, image) through its letter shapes, with an iridescent foil
  shimmer and an embossed 3D edge. Built by clipping stacked layers to glyph
  outlines via an SVG clipPath. Reverse-engineered from zo.computer's hero word
  "companion". Use when an accent word in a hero/title needs a living texture
  inside the letters rather than a flat colour or a plain gradient.
tags:
  - frontend
  - css
  - svg
  - clip-path
  - animation
  - typography
---

# Cloud-Word — texture clipped into letters

One word in the heading (zo.computer's "companion") isn't filled with a colour — its
letter shapes are a window onto a drifting cloud video with an iridescent shimmer on
top, raised off the page with an embossed edge. The same recipe works with any moving
fill: a `<video>`, an animated CSS gradient, or an image.

## How it works (the real zo.computer structure)

The accent word is a small stack of absolutely-positioned layers, **all clipped to the
same glyph outline** via `clip-path: url(#glyph-clip)`:

```
<a class="cloud-word">                       position:relative; display:inline-block;
  ├─ span.fallback   (z0)  ← solid gradient   isolation:isolate; drop-shadow filter
  ├─ video /clouds.mp4(z1) ← drifting clouds   (the "floating cloud")
  ├─ span.shimmer    (z2)  ← foil + highlight   mix-blend-mode: overlay
  └─ span.sr-only          ← real text for a11y
</a>
```

Key facts measured on the live site:

- **Clip source** — an SVG `<clipPath id="zo-cloud-clip-companion"
  clipPathUnits="objectBoundingBox">` containing the **glyph outlines as `<path>`** in
  normalised 0–1 coordinates. Pre-baking the outlines makes the clip resolution- and
  font-file-independent (no web font needs to load for the clip to be correct).
- **Layer rules** — every layer is `position:absolute; inset:0; width/height:100%;
  object-fit:cover; clip-path: var(--cloud-clip); pointer-events:none`.
- **The clouds** — a real `<video src="/clouds.mp4" muted autoplay loop playsinline>`
  (856×248) with `filter: brightness(.86) saturate(.25) contrast(1.05) blur(2px)`. The
  drift is the video itself, not CSS. On hover, saturation lifts.
- **The shimmer** — two stacked backgrounds, `mix-blend-mode: overlay; opacity:.65`:
  1. a diagonal white highlight band `linear-gradient(120deg, transparent 24%,
     rgba(255,255,255,.5) 44%, rgba(255,255,255,.1) 53%, transparent 70%)`
  2. an iridescent oklch "foil" gradient (`--zo-hero-foil-gradient`):
     `linear-gradient(118deg, oklch(.84 .042 236) … oklch(.82 .048 312) …
     oklch(.85 .044 12) … oklch(.92 .036 96) … oklch(.9 .036 172) …)` each mixed
     `78%` with transparent.
- **The 3D edge** — the container carries a `drop-shadow` filter stack
  (`drop-shadow(rgba(255,255,255,.55) 0 -1px 0) drop-shadow(rgba(0,0,0,.5) 0 1px 1px)
  drop-shadow(rgba(0,0,0,.2) 0 3px 6px)`). Because it's `drop-shadow` (not `box-shadow`)
  it traces the clipped glyph silhouette, giving the embossed/letterpress look.
- `isolation: isolate` on the container keeps the `overlay` blend from reacting to
  whatever is behind the heading.

## Generating the glyph clip

Two ways to get the `<clipPath>`:

1. **Live text (portable, used in the template).** Put a `<text>` element inside the
   clipPath with `clipPathUnits="userSpaceOnUse"`, matching the heading's font and
   size, and size the container box to the text metrics. No build step; depends on the
   font being available at render. Browsers clip HTML elements to `<text>` fine.
2. **Pre-baked paths (what zo ships).** Convert the word to vector outlines at build
   time (e.g. `opentype.js` `Path`, Figma/Illustrator export, or `text-to-svg`),
   normalise to `objectBoundingBox` (0–1) units, and inline as `<path>`. Resolution-
   independent and immune to font loading/FOUT. Prefer this for production.

## Choosing the moving fill

- **Video** (zo's choice): richest motion; ship a short, seamless, muted, looping
  `.mp4`/`.webm`. Remember `muted` + `playsinline` or autoplay is blocked.
- **Animated CSS gradient** (template default): zero assets, lightweight; animate
  `background-position` on layered radial blobs to fake drifting clouds.
- **Static image**: cheapest; pair it with the animated shimmer so it still feels alive.

## Template

[`references/cloud-word.html`](references/cloud-word.html) — complete, browser-verified.
It uses the live-`<text>` clip and an animated-gradient stand-in for the cloud video,
and includes commented hooks to swap in your own `clouds.mp4`. Reproduces the layering,
foil gradient, shimmer sweep, and embossed edge.

## Pitfalls

- **Accessibility:** the clipped layers are decorative (`aria-hidden`); the real word
  must live in an `sr-only` span (and an `aria-label` if the word is a link).
- Autoplay needs `muted` **and** `playsinline`; without them iOS/Safari refuse to play.
- `mix-blend-mode` needs `isolation: isolate` on the container or it blends with the
  page background unpredictably.
- `userSpaceOnUse` clip coordinates are relative to the clipped element's box — if the
  word shifts/resizes, the `<text>` x/y/size and the container box must stay in sync.
  Pre-baked `objectBoundingBox` paths avoid this entirely.
- Match the canvas/box dimensions to the video aspect with `object-fit: cover` or the
  clouds stretch.
