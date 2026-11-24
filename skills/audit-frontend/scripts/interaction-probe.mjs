#!/usr/bin/env node
// interaction-probe.mjs - measure what a user feels when they interact with a page.
//
// Drives real flows with Playwright (Chromium) and records, per step:
//   - interaction latency (Event Timing API, the raw material of INP)
//   - long tasks and Long Animation Frames (LoAF), with script attribution
//   - forced synchronous layout time (layout thrashing), from LoAF scripts
//   - layout shifts, DOM mutation volume, framework commit counts (React, Vue dev)
//   - time until an expected element becomes visible (async work INP cannot see)
//   - console errors/warnings, uncaught exceptions, failed requests, HTTP >= 400
//
// Run it through scripts/run-probe.sh (Docker, pinned Playwright image). It is
// not meant to be run with a host Node.
//
// Usage:
//   node interaction-probe.mjs --flows flows.json --out <dir>
//        [--base-url URL | --serve DIR] [--runs 3] [--cpu 4] [--viewport 1280x800]
//        [--settle-ms 700] [--timeout-ms 15000] [--storage-state state.json]
//        [--no-react-hook] [--no-mutations] [--strict] [--authorized-target]
//
// Targets other than local hosts are refused unless --authorized-target is
// passed: driving flows clicks, types and submits for real.
//
// Optional per-step assertions (used by the self-test): "expectFlags": [ids
// that must be raised], "expectNoFlags": true, "expectLatency": <latencyStatus>.
//
// Exit codes: 0 = ran; 1 = --strict and at least one "poor" flag; 2 = a step
// could not be executed (selector not found, navigation failed, bad flows
// file, unauthorized target); 3 = a step assertion failed.

import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

// --- thresholds (documented in references/thresholds.md; keep both in sync) ---
const T = {
  interactionGoodMs: 200, // INP "good" upper bound (web.dev)
  interactionPoorMs: 500, // INP "poor" lower bound (web.dev)
  longTaskMs: 50, // definition of a long task (W3C Long Tasks API)
  stepBlockingMs: 100, // house heuristic: blocking time attributable to one step
  forcedLayoutMs: 30, // house heuristic: forced style+layout inside one step
  visibleGoodMs: 1000, // Nielsen: 1 s keeps the user's flow of thought
  visiblePoorMs: 3000, // house heuristic: needs a progress indicator well before this
  clsGood: 0.1, // CLS "good" upper bound (web.dev)
  clsPoor: 0.25,
  commitStorm: 10, // house heuristic: framework commits for a single interaction
  mutationStorm: 1500, // house heuristic: DOM mutation records for a single interaction
  droppedFrameMs: 25, // a frame interval above this skipped at least one 60 Hz frame (16.7 ms)
  droppedFrameRatio: 0.05, // house heuristic: share of dropped frames during a scroll
  droppedFrameRatioPoor: 0.25,
};

// --- args ---------------------------------------------------------------------
function parseArgs(argv) {
  const out = { runs: 1, cpu: 1, viewport: '1280x800', settleMs: 700, timeoutMs: 15000 };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) continue;
    const key = a.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase());
    const next = argv[i + 1];
    if (next === undefined || next.startsWith('--')) out[key] = true;
    else {
      out[key] = next;
      i++;
    }
  }
  for (const k of ['runs', 'cpu', 'settleMs', 'timeoutMs']) out[k] = Number(out[k]);
  return out;
}

const args = parseArgs(process.argv.slice(2));
if (args.help || !args.flows || !args.out) {
  console.error(
    'usage: interaction-probe.mjs --flows flows.json --out <dir> [--base-url URL | --serve DIR] [--runs N] [--cpu RATE]\n' +
      '       [--viewport WxH] [--settle-ms N] [--timeout-ms N] [--storage-state FILE]\n' +
      '       [--no-react-hook] [--no-mutations] [--strict] [--authorized-target]',
  );
  process.exit(args.help ? 0 : 2);
}

// Resolve dependencies from the working directory (run-probe.sh installs them
// in a Docker volume), not from this script's own directory.
const require = createRequire(path.join(process.env.PROBE_MODULES || process.cwd(), 'noop.js'));
let chromium;
try {
  ({ chromium } = require('playwright-core'));
} catch {
  try {
    ({ chromium } = require('playwright'));
  } catch {
    console.error('playwright-core not found. Run this script through scripts/run-probe.sh.');
    process.exit(2);
  }
}

// --- in-page instrumentation ----------------------------------------------------
// Runs before any page script, in every document. Must stay dependency-free.
function instrument(opts) {
  if (window.__afp || window.top !== window) return;
  const s = (window.__afp = {
    docId: Math.random().toString(36).slice(2),
    events: [],
    inputs: 0,
    eventTiming: (PerformanceObserver.supportedEntryTypes || []).includes('event'),
    longtasks: [],
    loafs: [],
    shifts: [],
    lcp: null,
    commits: [],
    vueUpdates: 0,
    mut: { records: 0, added: 0, removed: 0, attributes: 0, text: 0 },
    frames: null,
    watch: null,
  });
  const describe = (el) => {
    if (!el || !el.tagName) return null;
    let d = el.tagName.toLowerCase();
    if (el.id) d += '#' + el.id;
    else if (typeof el.className === 'string' && el.className.trim()) d += '.' + el.className.trim().split(/\s+/).slice(0, 2).join('.');
    return d;
  };
  const observe = (type, cb, extra) => {
    try {
      new PerformanceObserver((list) => list.getEntries().forEach(cb)).observe({ type, buffered: true, ...extra });
    } catch {
      /* entry type not supported by this browser */
    }
  };
  // Event Timing: 16 ms is the lowest durationThreshold the API accepts (its
  // default is 104). Trusted input events are counted here, independently, so
  // that "no entry" can be told apart from "no input". No entry after a real
  // input is not a measurement: fast, or an entry lost or delivered late.
  for (const type of ['pointerdown', 'keydown', 'click']) {
    addEventListener(type, (e) => e.isTrusted && s.inputs++, { capture: true, passive: true });
  }
  observe(
    'event',
    (e) =>
      s.events.push({
        name: e.name,
        start: e.startTime,
        duration: e.duration,
        inputDelay: e.processingStart - e.startTime,
        processing: e.processingEnd - e.processingStart,
        presentation: Math.max(0, e.startTime + e.duration - e.processingEnd),
        interactionId: e.interactionId || 0,
        target: describe(e.target),
      }),
    { durationThreshold: 16 },
  );
  observe('longtask', (e) => s.longtasks.push({ start: e.startTime, duration: e.duration }));
  observe('long-animation-frame', (e) =>
    s.loafs.push({
      start: e.startTime,
      duration: e.duration,
      blocking: e.blockingDuration,
      renderStart: e.renderStart,
      styleAndLayoutStart: e.styleAndLayoutStart,
      scripts: (e.scripts || []).map((x) => ({
        invoker: x.invoker,
        invokerType: x.invokerType,
        sourceURL: x.sourceURL,
        sourceFunctionName: x.sourceFunctionName,
        sourceCharPosition: x.sourceCharPosition,
        duration: x.duration,
        forcedStyleAndLayout: x.forcedStyleAndLayoutDuration,
        pause: x.pauseDuration,
      })),
    }),
  );
  observe('layout-shift', (e) => {
    if (!e.hadRecentInput) s.shifts.push({ start: e.startTime, value: e.value });
  });
  observe('largest-contentful-paint', (e) => {
    s.lcp = { time: e.startTime, size: e.size, element: describe(e.element), url: e.url || null };
  });

  if (opts.mutations) {
    const mo = new MutationObserver((records) => {
      s.mut.records += records.length;
      for (const r of records) {
        if (r.type === 'childList') {
          s.mut.added += r.addedNodes.length;
          s.mut.removed += r.removedNodes.length;
        } else if (r.type === 'attributes') s.mut.attributes++;
        else s.mut.text++;
      }
    });
    mo.observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
  }

  // React: a minimal DevTools global hook. React calls onCommitFiberRoot once
  // per commit when a hook is present at load, in production builds too.
  // actualDuration only exists in development and profiling builds.
  if (opts.reactHook && !window.__REACT_DEVTOOLS_GLOBAL_HOOK__) {
    const renderers = new Map();
    window.__REACT_DEVTOOLS_GLOBAL_HOOK__ = {
      supportsFiber: true,
      renderers,
      inject(renderer) {
        const id = renderers.size + 1;
        renderers.set(id, renderer);
        return id;
      },
      onCommitFiberRoot(_id, root) {
        let dur = null;
        try {
          const d = root && root.current && root.current.actualDuration;
          if (typeof d === 'number') dur = d;
        } catch {
          /* ignore */
        }
        s.commits.push({ t: performance.now(), duration: dur });
      },
      onPostCommitFiberRoot() {},
      onCommitFiberUnmount() {},
      setStrictMode() {},
      checkDCE() {},
      on() {},
      off() {},
      sub() {
        return () => {};
      },
      emit() {},
    };
  }
  // Vue 3: component updates are only emitted to a devtools hook in development
  // builds (or with __VUE_PROD_DEVTOOLS__). Counted when available.
  if (opts.reactHook && !window.__VUE_DEVTOOLS_GLOBAL_HOOK__) {
    window.__VUE_DEVTOOLS_GLOBAL_HOOK__ = {
      enabled: true,
      emit(event) {
        if (event === 'component:updated') s.vueUpdates++;
      },
      on() {},
      once() {},
      off() {},
      appRecords: [],
      apps: [],
    };
  }

  s.cursor = () => {
    s.watch = null;
    s.frames = null;
    return s.snapshot();
  };
  s.snapshot = () => ({
    docId: s.docId,
    now: performance.now(),
    events: s.events.length,
    inputs: s.inputs,
    longtasks: s.longtasks.length,
    loafs: s.loafs.length,
    shifts: s.shifts.length,
    commits: s.commits.length,
    vueUpdates: s.vueUpdates,
    mut: { ...s.mut },
  });
  s.since = (c) => ({
    docId: s.docId,
    now: performance.now(),
    events: s.events.slice(c.events),
    inputs: s.inputs - (c.inputs || 0),
    eventTiming: s.eventTiming,
    longtasks: s.longtasks.slice(c.longtasks),
    loafs: s.loafs.slice(c.loafs),
    shifts: s.shifts.slice(c.shifts),
    commits: s.commits.slice(c.commits),
    vueUpdates: s.vueUpdates - c.vueUpdates,
    mut: {
      records: s.mut.records - c.mut.records,
      added: s.mut.added - c.mut.added,
      removed: s.mut.removed - c.mut.removed,
      attributes: s.mut.attributes - c.mut.attributes,
      text: s.mut.text - c.mut.text,
    },
    frames: s.frames,
    watch: s.watch,
    lcp: s.lcp,
  });
  // Record when a CSS selector first matches a rendered element.
  s.startWatch = (selector) => {
    const visible = () => {
      const el = document.querySelector(selector);
      return !!el && el.getClientRects().length > 0;
    };
    const w = (s.watch = { selector, alreadyVisible: visible(), at: null });
    if (w.alreadyVisible) return;
    const tick = () => {
      if (s.watch !== w) return;
      if (visible()) w.at = performance.now();
      else requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  };
  // Sample frame intervals (used for scroll steps only).
  s.startFrames = () => {
    const f = (s.frames = { count: 0, max: 0, dropped: 0, running: true });
    let last = performance.now();
    const tick = (t) => {
      if (!f.running) return;
      const d = t - last;
      last = t;
      f.count++;
      if (d > f.max) f.max = d;
      if (d > opts.droppedFrameMs) f.dropped++;
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  };
  s.stopFrames = () => {
    if (s.frames) s.frames.running = false;
  };
}

// --- step actions ----------------------------------------------------------------
const INTERACTIVE = new Set(['click', 'dblclick', 'hover', 'fill', 'type', 'press', 'select', 'check', 'scroll']);
// Actions that dispatch a trusted pointer or key event, the only ones Event
// Timing counts as interactions. hover, scroll, fill and select are not.
const TIMED = new Set(['click', 'dblclick', 'check', 'type', 'press']);
// What the latency column means when there is no number.
const LATENCY_LABEL = { 'below-threshold': '<16', 'not-applicable': 'n/a', 'no-input-event': 'none', unsupported: 'unsup' };

// Hosts the probe may drive without --authorized-target: the audit host itself
// (loopback, host.docker.internal). Never inferred from an address class: a
// private IP or a single-label name can be a shared or production service.
function isLocalTarget(url) {
  let host;
  try {
    const u = new URL(url);
    if (!/^https?:$/.test(u.protocol)) return true;
    host = u.hostname.replace(/^\[|\]$/g, '');
  } catch {
    return true;
  }
  return host === 'localhost' || host.endsWith('.localhost') || host === '::1' || host === 'host.docker.internal' || /^127\./.test(host);
}

function resolveUrl(target, baseUrl) {
  if (/^(https?|file|about|data):/.test(target)) return target;
  if (baseUrl) return new URL(target, baseUrl.endsWith('/') ? baseUrl : baseUrl + '/').href;
  return pathToFileURL(path.resolve(target)).href;
}

const ACTIONS = {
  goto: (page, v, _s, ctx) => page.goto(resolveUrl(v, ctx.baseUrl), { waitUntil: 'load' }),
  click: (page, v) => page.locator(v).first().click(),
  dblclick: (page, v) => page.locator(v).first().dblclick(),
  hover: (page, v) => page.locator(v).first().hover(),
  fill: (page, v) => page.locator(v[0]).first().fill(v[1]),
  // One key at a time: this is what surfaces per-keystroke input lag.
  type: (page, v, step) => page.locator(v[0]).first().pressSequentially(v[1], { delay: step.delayMs ?? 60 }),
  press: (page, v) => page.keyboard.press(v),
  select: (page, v) => page.locator(v[0]).first().selectOption(v[1]),
  check: (page, v) => page.locator(v).first().check(),
  scroll: async (page, v, step) => {
    if (step.in) await page.locator(step.in).first().hover();
    else {
      const vp = page.viewportSize();
      await page.mouse.move(vp.width / 2, vp.height / 2);
    }
    const total = Number(v);
    const delta = total < 0 ? -120 : 120;
    for (let done = 0; Math.abs(done) < Math.abs(total); done += delta) {
      await page.mouse.wheel(0, delta);
      await page.waitForTimeout(16);
    }
  },
  waitFor: (page, v) => page.locator(v).first().waitFor({ state: 'visible' }),
  wait: (page, v) => page.waitForTimeout(Number(v)),
  axe: async (page, v, _s, ctx) => {
    const src = fs.readFileSync(require.resolve('axe-core/axe.min.js'), 'utf8');
    await page.evaluate(src);
    const res = await page.evaluate(async (scope) => {
      const r = await window.axe.run(typeof scope === 'string' ? scope : document, { resultTypes: ['violations'] });
      return r.violations.map((x) => ({
        id: x.id,
        impact: x.impact,
        help: x.help,
        helpUrl: x.helpUrl,
        nodes: x.nodes.length,
        targets: x.nodes.slice(0, 5).map((n) => n.target.join(' ')),
      }));
    }, v);
    ctx.extra = { axeViolations: res };
  },
  dumpDom: async (page, v, _s, ctx) => {
    const dir = path.join(ctx.outDir, 'dom');
    fs.mkdirSync(dir, { recursive: true });
    const name = (typeof v === 'string' ? v : `${ctx.flowName}-${ctx.stepIndex}`).replace(/[^a-zA-Z0-9._-]+/g, '-') + '.html';
    fs.writeFileSync(path.join(dir, name), await page.content());
    ctx.extra = { domFile: path.join('dom', name) };
  },
};

const round = (n) => (typeof n === 'number' ? Math.round(n * 10) / 10 : n);
const sum = (xs) => xs.reduce((a, b) => a + b, 0);
const median = (xs) => {
  if (!xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
};

function summarise(kind, d, t0) {
  // Group Event Timing entries by interaction; an interaction's latency is its
  // longest event (pointerdown / pointerup / click share one interactionId).
  const byId = new Map();
  for (const e of d.events) {
    if (!e.interactionId) continue;
    const cur = byId.get(e.interactionId);
    if (!cur || e.duration > cur.duration) byId.set(e.interactionId, e);
  }
  const interactions = [...byId.values()].sort((a, b) => b.duration - a.duration);
  const worst = interactions[0] || null;
  // pointerdown, pointerup and click often share one duration; the entry whose
  // listeners ran longest is the one that explains it.
  const culprit = worst
    ? d.events.filter((e) => e.interactionId === worst.interactionId).sort((a, b) => b.processing - a.processing)[0]
    : null;
  const firstEventStart = d.events.length ? Math.min(...d.events.map((e) => e.start)) : t0;

  const scripts = d.loafs.flatMap((l) => l.scripts);
  const topScripts = [...scripts]
    .sort((a, b) => b.duration - a.duration)
    .slice(0, 5)
    .map((x) => ({
      source: x.sourceURL ? `${x.sourceURL}${x.sourceCharPosition >= 0 ? ':char' + x.sourceCharPosition : ''}` : null,
      fn: x.sourceFunctionName || null,
      invoker: x.invoker,
      durationMs: round(x.duration),
      forcedStyleAndLayoutMs: round(x.forcedStyleAndLayout),
    }));

  const out = {
    interactions: interactions.length,
    latencyMs: worst ? worst.duration : null,
    // measured | below-threshold (trusted input seen, no entry >= 16 ms: no number) |
    // no-input-event (nothing reached the page: NOT a measurement) |
    // not-applicable (action is not an Event Timing interaction) | unsupported
    latencyStatus: worst
      ? 'measured'
      : !TIMED.has(kind)
        ? 'not-applicable'
        : !d.eventTiming
          ? 'unsupported'
          : d.inputs > 0
            ? 'below-threshold'
            : 'no-input-event',
    inputEvents: d.inputs,
    latencyBreakdown: culprit
      ? {
          event: culprit.name,
          target: culprit.target,
          inputDelayMs: round(culprit.inputDelay),
          processingMs: round(culprit.processing),
          presentationMs: round(culprit.presentation),
        }
      : null,
    medianLatencyMs: interactions.length > 1 ? median(interactions.map((i) => i.duration)) : undefined,
    longTasks: d.longtasks.length,
    maxLongTaskMs: d.longtasks.length ? round(Math.max(...d.longtasks.map((l) => l.duration))) : 0,
    blockingMs: round(sum(d.longtasks.map((l) => Math.max(0, l.duration - T.longTaskMs)))),
    loafs: d.loafs.length,
    maxLoafMs: d.loafs.length ? round(Math.max(...d.loafs.map((l) => l.duration))) : 0,
    forcedLayoutMs: round(sum(scripts.map((x) => x.forcedStyleAndLayout || 0))),
    topScripts,
    cls: round(sum(d.shifts.map((x) => x.value)) * 1000) / 1000,
    domMutations: d.mut,
    reactCommits: d.commits.length,
    reactRenderMs: d.commits.some((c) => c.duration !== null) ? round(sum(d.commits.map((c) => c.duration || 0))) : null,
    vueComponentUpdates: d.vueUpdates,
  };
  if (d.watch) {
    out.expect = d.watch.selector;
    out.expectAlreadyVisible = d.watch.alreadyVisible;
    out.visibleAfterMs = d.watch.at === null ? null : round(d.watch.at - firstEventStart);
  }
  if (kind === 'scroll' && d.frames) {
    out.frames = { count: d.frames.count, maxIntervalMs: round(d.frames.max), dropped: d.frames.dropped };
  }
  return out;
}

function flagsFor(kind, m) {
  const flags = [];
  const add = (id, level, detail) => flags.push({ id, level, detail });
  if (INTERACTIVE.has(kind) && m.latencyMs !== null) {
    if (m.latencyMs > T.interactionPoorMs) add('interaction-latency', 'poor', `${m.latencyMs} ms > ${T.interactionPoorMs} ms`);
    else if (m.latencyMs > T.interactionGoodMs) add('interaction-latency', 'needs-improvement', `${m.latencyMs} ms > ${T.interactionGoodMs} ms`);
  }
  if (m.latencyStatus === 'no-input-event') add('no-input-event', 'invalid', 'no trusted pointer or key event reached the page: latency was not measured');
  if (INTERACTIVE.has(kind) && m.blockingMs >= T.stepBlockingMs) add('main-thread-blocked', m.blockingMs >= 3 * T.stepBlockingMs ? 'poor' : 'needs-improvement', `${m.blockingMs} ms of blocking time in ${m.longTasks} long task(s)`);
  if (m.forcedLayoutMs >= T.forcedLayoutMs) add('forced-layout', m.forcedLayoutMs >= 3 * T.forcedLayoutMs ? 'poor' : 'needs-improvement', `${m.forcedLayoutMs} ms of forced style and layout`);
  if (m.visibleAfterMs !== undefined) {
    if (m.expectAlreadyVisible) add('expect-already-visible', 'invalid', `"${m.expect}" was visible before the action: visibleAfterMs is meaningless`);
    else if (m.visibleAfterMs === null) add('expect-not-timed', 'invalid', `"${m.expect}" not seen by the in-page watcher (use a plain CSS selector)`);
    else if (m.visibleAfterMs > T.visiblePoorMs) add('slow-result', 'poor', `${m.visibleAfterMs} ms until "${m.expect}" is visible`);
    else if (m.visibleAfterMs > T.visibleGoodMs) add('slow-result', 'needs-improvement', `${m.visibleAfterMs} ms until "${m.expect}" is visible`);
  }
  if (m.cls > T.clsPoor) add('layout-shift', 'poor', `CLS ${m.cls}`);
  else if (m.cls > T.clsGood) add('layout-shift', 'needs-improvement', `CLS ${m.cls}`);
  if (INTERACTIVE.has(kind) && kind !== 'type' && m.reactCommits >= T.commitStorm) add('commit-storm', 'needs-improvement', `${m.reactCommits} React commits for one interaction`);
  if (INTERACTIVE.has(kind) && kind !== 'type' && kind !== 'scroll' && m.domMutations.records >= T.mutationStorm) add('mutation-storm', 'needs-improvement', `${m.domMutations.records} DOM mutation records`);
  if (m.frames && m.frames.count > 0) {
    const ratio = m.frames.dropped / m.frames.count;
    const detail = `${m.frames.dropped}/${m.frames.count} frame intervals over ${T.droppedFrameMs} ms, worst ${m.frames.maxIntervalMs} ms`;
    if (ratio >= T.droppedFrameRatioPoor || m.frames.maxIntervalMs > 100) add('dropped-frames', 'poor', detail);
    else if (ratio >= T.droppedFrameRatio) add('dropped-frames', 'needs-improvement', detail);
  }
  return flags;
}

// --- optional static server (--serve <dir>) -----------------------------------------
// Serves a built site (dist/) from inside the container, with an index.html
// fallback for client-side routes. No compression, no HTTP/2, no caching
// headers: fine for interaction latency, not representative for load metrics.
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.webp': 'image/webp', '.avif': 'image/avif', '.gif': 'image/gif', '.ico': 'image/x-icon', '.woff': 'font/woff', '.woff2': 'font/woff2', '.ttf': 'font/ttf', '.map': 'application/json', '.txt': 'text/plain', '.wasm': 'application/wasm', '.webmanifest': 'application/manifest+json' };
async function serveDir(dir) {
  const http = await import('node:http');
  const root = path.resolve(dir);
  const server = http.createServer((req, res) => {
    let rel;
    try {
      rel = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    } catch {
      res.writeHead(400).end();
      return;
    }
    let file = path.join(root, rel);
    if (!file.startsWith(root)) {
      res.writeHead(403).end();
      return;
    }
    if (fs.existsSync(file) && fs.statSync(file).isDirectory()) file = path.join(file, 'index.html');
    if (!fs.existsSync(file)) {
      // Client-side route: fall back to the app shell. Asset paths stay 404.
      if (path.extname(rel) === '' && fs.existsSync(path.join(root, 'index.html'))) file = path.join(root, 'index.html');
      else {
        res.writeHead(404, { 'content-type': 'text/plain' }).end('not found');
        return;
      }
    }
    res.writeHead(200, { 'content-type': MIME[path.extname(file).toLowerCase()] || 'application/octet-stream' });
    fs.createReadStream(file).pipe(res);
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return { server, url: `http://127.0.0.1:${server.address().port}` };
}

// --- main ----------------------------------------------------------------------
const spec = JSON.parse(fs.readFileSync(args.flows, 'utf8'));
const served = args.serve && args.serve !== true ? await serveDir(args.serve) : null;
const baseUrl = served ? served.url : args.baseUrl || spec.baseUrl || null;
const [vw, vh] = String(args.viewport).split('x').map(Number);

const targets = [baseUrl, ...spec.flows.flatMap((f) => f.steps.map((st) => st.goto))].filter((t) => typeof t === 'string' && /^https?:/.test(t));
const remote = [...new Set(targets.filter((t) => !isLocalTarget(t)).map((t) => new URL(t).host))];
if (remote.length && !args.authorizedTarget) {
  console.error(
    `refused: ${remote.join(', ')} is not a local host. The flows click, type and submit for real.\n` +
      'Pass --authorized-target only when the owner approved this target and these flows\n' +
      '(production: read-only flows, no form submission, no state change).',
  );
  process.exit(2);
}
fs.mkdirSync(args.out, { recursive: true });

const report = {
  meta: {
    tool: 'audit-frontend/interaction-probe',
    startedAt: new Date().toISOString(),
    baseUrl,
    servedDir: served ? String(args.serve) : null,
    runs: args.runs,
    cpuThrottle: args.cpu,
    authorizedRemoteTargets: remote,
    viewport: { width: vw, height: vh },
    settleMs: args.settleMs,
    thresholds: T,
    browser: null,
    caveat: 'Lab measurement in headless Chromium on this machine; CPU throttle is relative to this host, not a device model. Not field data, not an INP percentile.',
  },
  runs: [],
  summary: null,
};

let stepFailure = false;
let assertionFailure = false;
const origins = new Map(); // request origin -> count, all runs
const browser = await chromium.launch({ args: ['--no-sandbox', '--disable-dev-shm-usage'] });
report.meta.browser = `chromium ${browser.version()}`;

for (let run = 1; run <= args.runs; run++) {
  for (const flow of spec.flows) {
    const context = await browser.newContext({
      viewport: { width: vw, height: vh },
      storageState: args.storageState && args.storageState !== true ? args.storageState : undefined,
    });
    await context.addInitScript(instrument, {
      mutations: !args.noMutations,
      reactHook: !args.noReactHook,
      droppedFrameMs: T.droppedFrameMs,
    });
    const page = await context.newPage();
    page.setDefaultTimeout(args.timeoutMs);
    if (args.cpu > 1) {
      const cdp = await context.newCDPSession(page);
      await cdp.send('Emulation.setCPUThrottlingRate', { rate: args.cpu });
    }

    const flowOut = { run, flow: flow.name, steps: [] };
    let current = null; // step that console and network events are attributed to
    const attach = (key, item) => {
      if (current) (current[key] ||= []).push(item);
      else (flowOut[key] ||= []).push(item);
    };
    page.on('console', (msg) => {
      const type = msg.type();
      if (type !== 'error' && type !== 'warning') return;
      const loc = msg.location();
      attach('console', { type, text: msg.text().slice(0, 500), at: loc.url ? `${loc.url}:${loc.lineNumber}` : null });
    });
    page.on('pageerror', (err) => attach('pageErrors', { message: String(err.message || err).slice(0, 500) }));
    page.on('requestfailed', (req) =>
      attach('failedRequests', { url: req.url(), method: req.method(), type: req.resourceType(), error: req.failure()?.errorText || null }),
    );
    // Every origin the page talked to: approval must cover the backends too.
    page.on('request', (req) => {
      try {
        const o = new URL(req.url()).origin;
        if (o !== 'null') origins.set(o, (origins.get(o) || 0) + 1);
      } catch {
        /* data: and blob: URLs */
      }
    });
    page.on('response', (res) => {
      if (res.status() >= 400) attach('httpErrors', { url: res.url(), status: res.status(), method: res.request().method(), type: res.request().resourceType() });
    });

    for (let i = 0; i < flow.steps.length; i++) {
      const step = flow.steps[i];
      const kind = Object.keys(step).find((k) => ACTIONS[k]);
      const record = { index: i, action: kind, target: step[kind], label: step.label || null };
      flowOut.steps.push(record);
      current = record;
      if (!kind) {
        record.error = `unknown step: ${JSON.stringify(step)}`;
        stepFailure = true;
        break;
      }
      const ctx = { baseUrl, outDir: args.out, flowName: flow.name, stepIndex: i, extra: null };
      try {
        let cursor = null;
        if (kind !== 'goto') {
          cursor = await page.evaluate(() => (window.__afp ? window.__afp.cursor() : null));
          if (step.expect) await page.evaluate((sel) => window.__afp && window.__afp.startWatch(sel), step.expect);
          if (kind === 'scroll') await page.evaluate(() => window.__afp && window.__afp.startFrames());
        }
        await ACTIONS[kind](page, step[kind], step, ctx);
        if (step.expect && kind !== 'goto') await page.locator(step.expect).first().waitFor({ state: 'visible' });
        if (kind !== 'wait' && kind !== 'axe' && kind !== 'dumpDom') await page.waitForTimeout(step.settleMs ?? args.settleMs);
        if (kind === 'scroll') await page.evaluate(() => window.__afp && window.__afp.stopFrames());

        const zero = { events: 0, longtasks: 0, loafs: 0, shifts: 0, commits: 0, vueUpdates: 0, mut: { records: 0, added: 0, removed: 0, attributes: 0, text: 0 } };
        const data = await page.evaluate(
          ({ c, z }) => {
            const s = window.__afp;
            if (!s) return null;
            // A different docId means the step caused a full page load.
            return { fresh: !c || c.docId !== s.docId, ...s.since(c && c.docId === s.docId ? c : z) };
          },
          { c: cursor, z: zero },
        );
        if (!data) {
          record.error = 'instrumentation missing in this document (cross-origin frame or blocked init script)';
        } else {
          const m = summarise(kind, data, cursor ? cursor.now : 0);
          if (data.fresh) {
            record.fullPageLoad = true;
            // The old document's entries are gone: the action was not timed.
            if (kind !== 'goto' && m.latencyMs === null) m.latencyStatus = 'not-applicable';
            m.navigation = await page.evaluate(() => {
              const n = performance.getEntriesByType('navigation')[0];
              const fcp = performance.getEntriesByName('first-contentful-paint')[0];
              const res = performance.getEntriesByType('resource');
              return {
                url: location.href,
                ttfbMs: n ? Math.round(n.responseStart) : null,
                domContentLoadedMs: n ? Math.round(n.domContentLoadedEventEnd) : null,
                loadMs: n ? Math.round(n.loadEventEnd) : null,
                fcpMs: fcp ? Math.round(fcp.startTime) : null,
                requests: res.length,
                transferKb: Math.round(res.reduce((a, r) => a + (r.transferSize || 0), 0) / 1024),
                domNodes: document.getElementsByTagName('*').length,
              };
            });
            m.navigation.lcpMs = data.lcp ? Math.round(data.lcp.time) : null;
            m.navigation.lcpElement = data.lcp ? data.lcp.element : null;
          }
          record.metrics = m;
          record.flags = flagsFor(kind, m);
          const raised = record.flags.map((f) => f.id);
          const failed = [];
          for (const id of step.expectFlags || []) if (!raised.includes(id)) failed.push(`expected flag ${id}, got [${raised.join(', ')}]`);
          if (step.expectNoFlags && raised.length) failed.push(`expected no flag, got [${raised.join(', ')}]`);
          if (step.expectLatency && step.expectLatency !== m.latencyStatus) failed.push(`expected latencyStatus ${step.expectLatency}, got ${m.latencyStatus}`);
          if (failed.length) {
            record.assertionFailures = failed;
            assertionFailure = true;
          }
        }
        if (ctx.extra) Object.assign(record, ctx.extra);
      } catch (err) {
        record.error = String(err.message || err).split('\n')[0].slice(0, 400);
        stepFailure = true;
        break; // later steps of this flow depend on this one
      }
    }
    current = null;
    report.runs.push(flowOut);
    await context.close();
  }
}
await browser.close();
if (served) served.server.close();

// --- aggregate across runs --------------------------------------------------------
const agg = new Map();
for (const r of report.runs) {
  for (const s of r.steps) {
    const key = `${r.flow}#${s.index}`;
    const a = agg.get(key) || { flow: r.flow, index: s.index, action: s.action, target: s.target, label: s.label, latencies: [], statuses: new Set(), asserts: 0, visible: [], blocking: [], flags: new Map(), errors: 0, console: 0, pageErrors: 0, failedRequests: 0, httpErrors: 0 };
    agg.set(key, a);
    if (s.error) a.errors++;
    a.asserts += (s.assertionFailures || []).length;
    if (s.metrics) {
      a.statuses.add(s.metrics.latencyStatus);
      if (s.metrics.latencyMs !== null) a.latencies.push(s.metrics.latencyMs);
      if (typeof s.metrics.visibleAfterMs === 'number') a.visible.push(s.metrics.visibleAfterMs);
      a.blocking.push(s.metrics.blockingMs);
    }
    for (const f of s.flags || []) {
      const cur = a.flags.get(f.id) || { id: f.id, level: f.level, runs: 0, detail: f.detail };
      cur.runs++;
      if (f.level === 'poor') cur.level = 'poor';
      a.flags.set(f.id, cur);
    }
    for (const k of ['console', 'pageErrors', 'failedRequests', 'httpErrors']) a[k] += (s[k] || []).length;
  }
}
const steps = [...agg.values()].map((a) => ({
  flow: a.flow,
  index: a.index,
  action: a.action,
  target: a.target,
  label: a.label,
  latencyMs: { median: median(a.latencies), max: a.latencies.length ? Math.max(...a.latencies) : null, samples: a.latencies.length },
  latencyStatus: [...a.statuses].sort().join('|') || 'error',
  assertionFailures: a.asserts,
  visibleAfterMs: a.visible.length ? { median: round(median(a.visible)), max: round(Math.max(...a.visible)) } : undefined,
  blockingMs: { median: round(median(a.blocking)), max: a.blocking.length ? round(Math.max(...a.blocking)) : null },
  flags: [...a.flags.values()],
  errors: a.errors,
  console: a.console,
  pageErrors: a.pageErrors,
  failedRequests: a.failedRequests,
  httpErrors: a.httpErrors,
}));
const interactive = steps.filter((s) => INTERACTIVE.has(s.action) && s.latencyMs.max !== null);
const worst = interactive.sort((a, b) => b.latencyMs.max - a.latencyMs.max)[0] || null;
report.summary = {
  steps: steps.sort((a, b) => (a.flow === b.flow ? a.index - b.index : a.flow.localeCompare(b.flow))),
  worstInteraction: worst ? { flow: worst.flow, index: worst.index, action: worst.action, target: worst.target, latencyMs: worst.latencyMs.max } : null,
  poorFlags: steps.reduce((n, s) => n + s.flags.filter((f) => f.level === 'poor').length, 0),
  needsImprovementFlags: steps.reduce((n, s) => n + s.flags.filter((f) => f.level === 'needs-improvement').length, 0),
  stepErrors: steps.reduce((n, s) => n + s.errors, 0),
  assertionFailures: steps.reduce((n, s) => n + s.assertionFailures, 0),
  consoleMessages: steps.reduce((n, s) => n + s.console, 0),
  pageErrors: steps.reduce((n, s) => n + s.pageErrors, 0),
  failedRequests: steps.reduce((n, s) => n + s.failedRequests, 0),
  httpErrors: steps.reduce((n, s) => n + s.httpErrors, 0),
};
report.meta.requestOrigins = Object.fromEntries([...origins].sort((a, b) => b[1] - a[1]));
report.meta.finishedAt = new Date().toISOString();

const outFile = path.join(args.out, 'interaction-probe.json');
fs.writeFileSync(outFile, JSON.stringify(report, null, 2));

// --- human-readable table ---------------------------------------------------------
const pad = (v, n) => String(v ?? '-').slice(0, n).padEnd(n);
console.log(`${pad('flow', 16)} ${pad('#', 2)} ${pad('action', 8)} ${pad('target', 26)} ${pad('lat(med/max)', 13)} ${pad('block', 7)} ${pad('visible', 8)} flags`);
for (const s of report.summary.steps) {
  const lat = s.latencyMs.max !== null ? `${s.latencyMs.median}/${s.latencyMs.max}` : !INTERACTIVE.has(s.action) ? '-' : LATENCY_LABEL[s.latencyStatus] || 'ERR';
  const tgt = Array.isArray(s.target) ? s.target[0] : s.target;
  const extra = [s.errors && `ERROR x${s.errors}`, s.assertionFailures && `ASSERT x${s.assertionFailures}`, s.console && `console x${s.console}`, s.pageErrors && `exception x${s.pageErrors}`, s.failedRequests && `reqfail x${s.failedRequests}`, s.httpErrors && `http>=400 x${s.httpErrors}`].filter(Boolean);
  const flags = s.flags.map((f) => `${f.id}:${f.level}${args.runs > 1 ? `(${f.runs}/${args.runs})` : ''}`).concat(extra);
  console.log(`${pad(s.flow, 16)} ${pad(s.index, 2)} ${pad(s.action, 8)} ${pad(tgt, 26)} ${pad(lat, 13)} ${pad(s.blockingMs.max, 7)} ${pad(s.visibleAfterMs ? s.visibleAfterMs.max : '-', 8)} ${flags.join(' ')}`);
}
console.log('\nlat: <16 = input seen, no entry >= 16 ms (no number: read block); n/a = action is not a timed interaction; none = no input reached the page (not measured); ERR = step failed');
console.log(`origins contacted: ${[...origins.keys()].join(', ') || 'none'}  (each must be inside the approved scope)`);
for (const r of report.runs) for (const st of r.steps) for (const f of st.assertionFailures || []) console.log(`ASSERT run ${r.run} ${r.flow}#${st.index} ${st.action}: ${f}`);
console.log(`report: ${outFile}`);

if (stepFailure) process.exit(2);
if (assertionFailure) process.exit(3);
if (args.strict && report.summary.poorFlags > 0) process.exit(1);
