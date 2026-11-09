#!/usr/bin/env python3
"""Render the "blocks / blocked by" graph of a Linear project as a standalone SVG.

Usage:
    LINEAR_API_KEY=lin_api_... python linear_deps.py PROJECT_URL -o deps.svg
    python linear_deps.py PROJECT_URL --from-json ../tests/fixtures/linear-deps-demo.json -o deps.svg   # offline

PROJECT_URL looks like https://linear.app/<workspace>/project/<name>-<slugId>.
Every box is a link to https://linear.app/<workspace>/issue/<IDENTIFIER>.
Standard library only; the API key is read from LINEAR_API_KEY and never printed.
"""
import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from collections import defaultdict
from xml.sax.saxutils import escape, quoteattr

API_URL = "https://api.linear.app/graphql"
PAGE_SIZE = 25      # issues per page; relations are capped at the same size to stay under the complexity limit
BOX_W, BOX_H = 270, 54
GAP_X, GAP_Y = 110, 14
MARGIN = 24
TITLE_CHARS = 33
CHIP_W, CHIP_H = 84, 24

PROJECT_URL_RE = re.compile(r"^https?://linear\.app/([^/]+)/project/([^/?#]+)")

QUERY_PROJECT_BY_FILTER = """
query($slug: String!) {
  projects(filter: {slugId: {eq: $slug}}, first: 1) { nodes { id name } }
}"""
QUERY_PROJECT_BY_ID = """
query($id: String!) { project(id: $id) { id name } }"""
QUERY_ISSUES = """
query($id: String!, $after: String) {
  project(id: $id) {
    issues(first: %d, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes {
        identifier title
        state { type }
        parent { identifier }
        relations(first: %d) {
          pageInfo { hasNextPage }
          nodes { type relatedIssue { identifier title } }
        }
        inverseRelations(first: %d) {
          pageInfo { hasNextPage }
          nodes { type issue { identifier title } }
        }
      }
    }
  }
}""" % (PAGE_SIZE, PAGE_SIZE, PAGE_SIZE)


def parse_project_url(url):
    m = PROJECT_URL_RE.match(url.strip())
    if not m:
        raise SystemExit("error: expected https://linear.app/<workspace>/project/<name>-<slugId>")
    workspace, last = m.group(1), m.group(2)
    tail = last.rsplit("-", 1)[-1]
    slug = tail if re.fullmatch(r"[0-9a-f]{8,}", tail) else last
    return workspace, slug


def gql(api_url, key, query, variables):
    body = json.dumps({"query": query, "variables": variables}).encode()
    req = urllib.request.Request(
        api_url, data=body,
        headers={"Content-Type": "application/json", "Authorization": key},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            payload = json.load(resp)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:500]
        raise SystemExit("error: Linear API answered HTTP %d: %s" % (exc.code, detail))
    except urllib.error.URLError as exc:
        raise SystemExit("error: cannot reach the Linear API: %s" % exc.reason)
    if payload.get("errors"):
        msgs = "; ".join(e.get("message", "?") for e in payload["errors"])
        raise SystemExit("error: Linear API: " + msgs)
    return payload["data"]


def fetch_live(slug, api_url):
    key = os.environ.get("LINEAR_API_KEY", "").strip()
    if not key:
        raise SystemExit("error: LINEAR_API_KEY is not set (or use --from-json)")
    nodes = gql(api_url, key, QUERY_PROJECT_BY_FILTER, {"slug": slug})["projects"]["nodes"]
    project = nodes[0] if nodes else None
    if project is None:
        project = gql(api_url, key, QUERY_PROJECT_BY_ID, {"id": slug}).get("project")
    if project is None:
        raise SystemExit("error: project not found for slug id %r" % slug)

    issues, relations, external, truncated = [], set(), {}, []
    after = None
    while True:
        page = gql(api_url, key, QUERY_ISSUES, {"id": project["id"], "after": after})["project"]["issues"]
        for n in page["nodes"]:
            me = n["identifier"]
            issues.append({
                "identifier": me, "title": n["title"],
                "state": (n.get("state") or {}).get("type", ""),
                "parent": (n.get("parent") or {}).get("identifier"),
            })
            if n["relations"]["pageInfo"]["hasNextPage"] or n["inverseRelations"]["pageInfo"]["hasNextPage"]:
                truncated.append(me)
            for r in n["relations"]["nodes"]:
                other = r["relatedIssue"]
                external[other["identifier"]] = other["title"]
                relations.add((r["type"], me, other["identifier"]))
            for r in n["inverseRelations"]["nodes"]:
                other = r["issue"]
                external[other["identifier"]] = other["title"]
                relations.add((r["type"], other["identifier"], me))
        if not page["pageInfo"]["hasNextPage"]:
            break
        after = page["pageInfo"]["endCursor"]
    if truncated:
        print("warning: more than %d relations on %s; some links may be missing"
              % (PAGE_SIZE, ", ".join(truncated)), file=sys.stderr)
    return {
        "project": {"name": project["name"]},
        "issues": issues,
        "relations": [{"type": t, "from": a, "to": b} for t, a, b in sorted(relations)],
        "external": external,
    }


def load_json(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def build_graph(data, include_related, external_mode):
    """Return a dict describing nodes, layers, edges and counters."""
    internal = {i["identifier"]: i for i in data["issues"]}
    ext_titles = data.get("external", {})
    block, related, dropped = set(), set(), 0
    for r in data["relations"]:
        a, b, t = r["from"], r["to"], r["type"]
        if a == b:
            continue
        if t == "blocks":
            target = block
        elif t == "related" and include_related:
            a, b = sorted((a, b))
            target = related
        else:
            continue
        if (a not in internal or b not in internal) and external_mode == "drop":
            dropped += 1
            continue
        target.add((a, b))

    touched = {x for e in block | related for x in e}
    nodes = {}
    for ident in touched:
        if ident in internal:
            nodes[ident] = dict(internal[ident], external=False)
        else:
            nodes[ident] = {"identifier": ident, "title": ext_titles.get(ident, ""),
                            "state": "", "parent": None, "external": True}
    isolated = sorted((i for i in internal if i not in touched), key=sort_key)

    back = find_back_edges(nodes, block)
    dag = block - back
    layer = longest_path_layers(nodes, dag)
    order = order_layers(nodes, dag, layer)
    return {"nodes": nodes, "block": block, "related": related, "back": back,
            "layer": layer, "order": order, "isolated": isolated, "dropped": dropped}


def sort_key(ident):
    m = re.match(r"^(.*?)-(\d+)$", ident)
    return (m.group(1), int(m.group(2))) if m else (ident, 0)


def find_back_edges(nodes, edges):
    """Iterative DFS; edges closing a cycle are returned so they can be drawn apart."""
    succ = defaultdict(list)
    for a, b in sorted(edges, key=lambda e: (sort_key(e[0]), sort_key(e[1]))):
        succ[a].append(b)
    color, back = {}, set()
    for start in sorted(nodes, key=sort_key):
        if color.get(start):
            continue
        color[start] = 1
        stack = [(start, iter(succ[start]))]
        while stack:
            node, it = stack[-1]
            for nxt in it:
                state = color.get(nxt, 0)
                if state == 0:
                    color[nxt] = 1
                    stack.append((nxt, iter(succ[nxt])))
                    break
                if state == 1:
                    back.add((node, nxt))
            else:
                color[node] = 2
                stack.pop()
    return back


def longest_path_layers(nodes, dag):
    preds, succ = defaultdict(set), defaultdict(set)
    for a, b in dag:
        preds[b].add(a)
        succ[a].add(b)
    layer = {n: 0 for n in nodes}
    indeg = {n: len(preds[n]) for n in nodes}
    queue = sorted((n for n in nodes if indeg[n] == 0), key=sort_key)
    while queue:
        n = queue.pop(0)
        for m in sorted(succ[n], key=sort_key):
            layer[m] = max(layer[m], layer[n] + 1)
            indeg[m] -= 1
            if indeg[m] == 0:
                queue.append(m)
    return layer


def order_layers(nodes, dag, layer):
    """Group nodes per layer and reduce crossings with a few barycenter sweeps."""
    layers = defaultdict(list)
    for n in sorted(nodes, key=sort_key):
        layers[layer[n]].append(n)
    depth = max(layers) if layers else 0
    preds, succ = defaultdict(list), defaultdict(list)
    for a, b in dag:
        preds[b].append(a)
        succ[a].append(b)

    def pos(l):
        return {n: i for i, n in enumerate(layers[l])}

    for _ in range(4):
        for l in range(1, depth + 1):
            p = pos(l - 1) if l - 1 in layers else {}
            layers[l].sort(key=lambda n: (bary(preds[n], p), sort_key(n)))
        for l in range(depth - 1, -1, -1):
            p = pos(l + 1) if l + 1 in layers else {}
            layers[l].sort(key=lambda n: (bary(succ[n], p), sort_key(n)))
    return [layers[l] for l in range(depth + 1)] if layers else []


def bary(neigh, p):
    xs = [p[n] for n in neigh if n in p]
    return sum(xs) / len(xs) if xs else 1e9


def clip(text, limit):
    text = " ".join(text.split())
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def issue_url(workspace, ident):
    return "https://linear.app/%s/issue/%s" % (workspace, ident)


STYLE = """
svg { --bg:#f5f6f8; --fg:#151a22; --muted:#5a6372; --edge:#4a5262; --cycle:#c2330f;
  --todo-bg:#e8edfc; --todo-bd:#3d5bd9; --todo-fg:#1f2f78;
  --run-bg:#fdebdc; --run-bd:#c2530f; --run-fg:#6e2d06;
  --done-bg:#e6e9ee; --done-bd:#8b93a1; --done-fg:#4a5262;
  --ext-bg:#ffffff; --ext-bd:#8b93a1; --ext-fg:#4a5262; }
@media (prefers-color-scheme: dark) { svg { --bg:#11151b; --fg:#e8ebf0; --muted:#9aa3b2; --edge:#a8b0be; --cycle:#ff8a65;
  --todo-bg:#1d2748; --todo-bd:#8ea2f5; --todo-fg:#d3dbff;
  --run-bg:#3d2312; --run-bd:#f0944f; --run-fg:#ffddc2;
  --done-bg:#232933; --done-bd:#7c8594; --done-fg:#b7bfcc;
  --ext-bg:#181d25; --ext-bd:#7c8594; --ext-fg:#b7bfcc; } }
text { font-family: "IBM Plex Sans", system-ui, -apple-system, "Segoe UI", sans-serif; fill: var(--fg); }
.bg { fill: var(--bg); }
.h { font-size: 16px; font-weight: 600; } .sub { font-size: 12px; fill: var(--muted); }
.id { font-family: "IBM Plex Mono", ui-monospace, Menlo, monospace; font-size: 11.5px; font-weight: 500; }
.ttl { font-size: 12.5px; } .tag { font-family: "IBM Plex Mono", ui-monospace, Menlo, monospace; font-size: 10.5px; fill: var(--muted); }
.box { stroke-width: 1.5; }
.todo { fill: var(--todo-bg); stroke: var(--todo-bd); } .todo text { fill: var(--todo-fg); }
.run { fill: var(--run-bg); stroke: var(--run-bd); } .run text { fill: var(--run-fg); }
.done { fill: var(--done-bg); stroke: var(--done-bd); } .done text { fill: var(--done-fg); }
.ext { fill: var(--ext-bg); stroke: var(--ext-bd); stroke-dasharray: 5 3; } .ext text { fill: var(--ext-fg); }
a:hover .box { stroke-width: 2.6; }
.edge { stroke: var(--edge); stroke-width: 1.4; fill: none; opacity: .8; }
.rel { stroke: var(--muted); stroke-width: 1.1; stroke-dasharray: 2 3; fill: none; }
.cyc { stroke: var(--cycle); stroke-width: 1.8; stroke-dasharray: 6 3; fill: none; }
.arrow { fill: var(--edge); } .arrow-c { fill: var(--cycle); }
.warn { font-size: 12px; fill: var(--cycle); font-weight: 600; }
"""


def state_class(node):
    if node["external"]:
        return "ext"
    if node["state"] in ("completed", "canceled"):
        return "done"
    if node["state"] == "started":
        return "run"
    return "todo"


def render_svg(data, graph, workspace, hide_isolated):
    nodes, layers = graph["nodes"], graph["order"]
    n_layers = len(layers)
    graph_w = n_layers * BOX_W + max(0, n_layers - 1) * GAP_X if n_layers else 0
    tallest = max((len(l) for l in layers), default=0)
    graph_h = tallest * BOX_H + max(0, tallest - 1) * GAP_Y

    pos = {}
    for li, col in enumerate(layers):
        col_h = len(col) * BOX_H + max(0, len(col) - 1) * GAP_Y
        y0 = (graph_h - col_h) / 2
        for ri, ident in enumerate(col):
            pos[ident] = (MARGIN + li * (BOX_W + GAP_X), 62 + y0 + ri * (BOX_H + GAP_Y))

    isolated = [] if hide_isolated else graph["isolated"]
    width = max(MARGIN * 2 + graph_w, 640)
    strip_top = 62 + graph_h + 40
    per_row = max(1, int((width - 2 * MARGIN) // (CHIP_W + 8)))
    strip_rows = (len(isolated) + per_row - 1) // per_row
    strip_h = (30 + strip_rows * (CHIP_H + 8)) if isolated else 0
    height = strip_top + strip_h + 60

    out = []
    w = out.append
    w('<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
      'width="%d" height="%d" viewBox="0 0 %d %d" role="img" aria-label=%s>'
      % (width, height, width, height, quoteattr("Dependency graph of " + data["project"]["name"])))
    w("<title>%s</title>" % escape("Dependencies: " + data["project"]["name"]))
    w("<style>%s</style>" % STYLE)
    w('<defs><marker id="ar" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto">'
      '<path class="arrow" d="M0 0 L10 5 L0 10 z"/></marker>'
      '<marker id="ac" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto">'
      '<path class="arrow-c" d="M0 0 L10 5 L0 10 z"/></marker></defs>')
    w('<rect class="bg" width="100%" height="100%"/>')
    w('<text class="h" x="%d" y="28">%s</text>' % (MARGIN, escape(data["project"]["name"])))
    n_edges = len(graph["block"])
    w('<text class="sub" x="%d" y="46">%d issues in dependency chains, %d blocking links; arrow = blocks, left to right</text>'
      % (MARGIN, len(nodes), n_edges))

    def edge_path(a, b):
        (x1, y1), (x2, y2) = pos[a], pos[b]
        if x2 > x1:
            sx, sy, ex, ey = x1 + BOX_W, y1 + BOX_H / 2, x2, y2 + BOX_H / 2
        elif x2 < x1:                       # back edge pointing left
            sx, sy, ex, ey = x1, y1 + BOX_H / 2, x2 + BOX_W, y2 + BOX_H / 2
        else:                               # same layer (cycle remnant)
            sx, sy, ex, ey = x1 + BOX_W, y1 + BOX_H / 2, x2 + BOX_W, y2 + BOX_H / 2
            off = 60
            return "M%.1f %.1f C %.1f %.1f, %.1f %.1f, %.1f %.1f" % (sx, sy, sx + off, sy, ex + off, ey, ex, ey)
        dx = max(30, abs(ex - sx) / 2)
        sign = 1 if ex >= sx else -1
        return "M%.1f %.1f C %.1f %.1f, %.1f %.1f, %.1f %.1f" % (sx, sy, sx + sign * dx, sy, ex - sign * dx, ey, ex, ey)

    for a, b in sorted(graph["related"]):
        if a in pos and b in pos:
            w('<path class="rel" d="%s"><title>related</title></path>' % edge_path(a, b))
    for a, b in sorted(graph["block"] - graph["back"]):
        w('<path class="edge" d="%s" marker-end="url(#ar)"><title>%s blocks %s</title></path>'
          % (edge_path(a, b), a, b))
    for a, b in sorted(graph["back"]):
        w('<path class="cyc" d="%s" marker-end="url(#ac)"><title>cycle: %s blocks %s</title></path>'
          % (edge_path(a, b), a, b))

    def box(ident, x, y):
        n = nodes[ident]
        url = issue_url(workspace, ident)
        tip = "%s: %s" % (ident, n["title"] or "(outside this project)")
        w('<a href=%s xlink:href=%s target="_blank" rel="noopener"><g class="%s">'
          % (quoteattr(url), quoteattr(url), state_class(n)))
        w('<title>%s</title>' % escape(tip))
        w('<rect class="box" x="%.1f" y="%.1f" width="%d" height="%d" rx="8"/>' % (x, y, BOX_W, BOX_H))
        w('<text class="id" x="%.1f" y="%.1f">%s</text>' % (x + 12, y + 20, escape(ident)))
        if n["parent"]:
            w('<text class="tag" x="%.1f" y="%.1f" text-anchor="end">↳ %s</text>'
              % (x + BOX_W - 10, y + 20, escape(n["parent"])))
        w('<text class="ttl" x="%.1f" y="%.1f">%s</text>'
          % (x + 12, y + 39, escape(clip(n["title"], TITLE_CHARS) if n["title"] else "outside this project")))
        w("</g></a>")

    for ident, (x, y) in sorted(pos.items(), key=lambda kv: sort_key(kv[0])):
        box(ident, x, y)

    if graph["back"]:
        w('<text class="warn" x="%d" y="%d">Cycle detected: %d blocking link(s) drawn dashed in red close a loop.</text>'
          % (MARGIN, int(strip_top - 14), len(graph["back"])))

    if isolated:
        w('<text class="sub" x="%d" y="%d">No dependency (%d issues)</text>' % (MARGIN, strip_top + 4, len(isolated)))
        for i, ident in enumerate(isolated):
            r, c = divmod(i, per_row)
            x = MARGIN + c * (CHIP_W + 8)
            y = strip_top + 16 + r * (CHIP_H + 8)
            n = nodes.get(ident) or {"state": "", "title": "", "external": False}
            internal = next(j for j in data["issues"] if j["identifier"] == ident)
            url = issue_url(workspace, ident)
            cls = state_class(dict(internal, external=False))
            w('<a href=%s xlink:href=%s target="_blank" rel="noopener"><g class="%s"><title>%s</title>'
              '<rect class="box" x="%d" y="%d" width="%d" height="%d" rx="6"/>'
              '<text class="id" x="%d" y="%d">%s</text></g></a>'
              % (quoteattr(url), quoteattr(url), cls, escape("%s: %s" % (ident, internal["title"])),
                 x, y, CHIP_W, CHIP_H, x + 9, y + 16, escape(ident)))

    notes = []
    if graph["dropped"]:
        notes.append("%d link(s) to issues outside this project not shown (use --external show)" % graph["dropped"])
    if hide_isolated and graph["isolated"]:
        notes.append("%d issue(s) without dependency hidden" % len(graph["isolated"]))
    if notes:
        w('<text class="sub" x="%d" y="%d">%s</text>' % (MARGIN, height - 24, escape("; ".join(notes))))
    w("</svg>")
    return "\n".join(out) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description="Render a Linear project's issue dependencies as a clickable SVG.")
    ap.add_argument("project_url", help="https://linear.app/<workspace>/project/<name>-<slugId>")
    ap.add_argument("-o", "--output", default="deps.svg", help="SVG file to write (default: deps.svg)")
    ap.add_argument("--from-json", metavar="FILE", help="read normalized data from FILE instead of calling the API")
    ap.add_argument("--include-related", action="store_true", help="also draw 'related' links (dotted)")
    ap.add_argument("--external", choices=("drop", "show"), default="drop",
                    help="links to issues outside the project: drop (default, counted) or show as dashed boxes")
    ap.add_argument("--hide-isolated", action="store_true", help="hide issues that have no dependency")
    ap.add_argument("--api-url", default=API_URL, help=argparse.SUPPRESS)
    args = ap.parse_args(argv)

    workspace, slug = parse_project_url(args.project_url)
    data = load_json(args.from_json) if args.from_json else fetch_live(slug, args.api_url)
    graph = build_graph(data, args.include_related, args.external)
    svg = render_svg(data, graph, workspace, args.hide_isolated)
    with open(args.output, "w", encoding="utf-8") as fh:
        fh.write(svg)

    print("%s: %d issues, %d in chains, %d blocking links, %d without dependency, wrote %s"
          % (data["project"]["name"], len(data["issues"]), len(graph["nodes"]), len(graph["block"]),
             len(graph["isolated"]), args.output))
    if graph["dropped"]:
        print("note: %d link(s) to issues outside the project dropped (use --external show)" % graph["dropped"])
    if graph["back"]:
        print("warning: cycle detected; back edges: " + ", ".join("%s->%s" % e for e in sorted(graph["back"])),
              file=sys.stderr)


if __name__ == "__main__":
    main()
