#!/usr/bin/env python3
"""Render the "blocks / blocked by" graph of a Linear project as a standalone SVG.

Usage:
    LINEAR_API_KEY=lin_api_... python linear_deps.py PROJECT_URL -o deps.svg [--json-out deps.json]
    python linear_deps.py check deps.json --type Proof --blocked-by "Technical task,Feature,Improvement,Bug"
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
LABEL_PAGE = 10     # labels per issue
EXTERNAL_PAGE = 50  # outside issues per label lookup
BOX_W, BOX_H = 270, 86
GAP_X, GAP_Y = 110, 14
MARGIN = 24
TITLE_CHARS = 33
CHIP_W, CHIP_H = 96, 24

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
        description
        state { type name color }
        assignee { displayName }
        parent { identifier }
        projectMilestone { name }
        labels(first: %d) { nodes { name parent { name } } }
        relations(first: %d) {
          pageInfo { hasNextPage }
          nodes { type relatedIssue { id identifier title } }
        }
        inverseRelations(first: %d) {
          pageInfo { hasNextPage }
          nodes { type issue { id identifier title } }
        }
      }
    }
  }
}""" % (PAGE_SIZE, LABEL_PAGE, PAGE_SIZE, PAGE_SIZE)
# Labels of issues outside the project, fetched by id once the project is read, so an
# external blocker still carries its ticket type.
QUERY_EXTERNAL_LABELS = """
query($ids: [ID!]) {
  issues(filter: {id: {in: $ids}}, first: %d) {
    nodes { identifier labels(first: %d) { nodes { name parent { name } } } }
  }
}""" % (EXTERNAL_PAGE, LABEL_PAGE)

# The eight ticket types of references/ticket-types.md; a type is the label of the
# workspace label group "Type", or failing that a label named like one of these.
TICKET_TYPES = ("Bug", "Blocker", "Question", "Research", "Feature", "Improvement", "Proof", "Technical task")
TYPE_GROUP = "type"
# Directed relation types keep their direction; the others are an unordered pair.
DIRECTED = ("blocks", "duplicate")


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


def fetch_live(slug, api_url, descriptions=True):
    key = os.environ.get("LINEAR_API_KEY", "").strip()
    if not key:
        raise SystemExit("error: LINEAR_API_KEY is not set (or use --from-json)")
    nodes = gql(api_url, key, QUERY_PROJECT_BY_FILTER, {"slug": slug})["projects"]["nodes"]
    project = nodes[0] if nodes else None
    if project is None:
        project = gql(api_url, key, QUERY_PROJECT_BY_ID, {"id": slug}).get("project")
    if project is None:
        raise SystemExit("error: project not found for slug id %r" % slug)

    issues, relations, external, other_ids, truncated = [], set(), {}, {}, []
    after = None
    while True:
        query = QUERY_ISSUES if descriptions else QUERY_ISSUES.replace("        description\n", "", 1)
        page = gql(api_url, key, query, {"id": project["id"], "after": after})["project"]["issues"]
        for n in page["nodes"]:
            me = n["identifier"]
            issues.append({
                "identifier": me, "title": n["title"],
                "state": (n.get("state") or {}).get("type", ""),
                "state_name": (n.get("state") or {}).get("name"),
                "state_color": (n.get("state") or {}).get("color"),
                "assignee": (n.get("assignee") or {}).get("displayName"),
                "description_excerpt": excerpt(n.get("description")) if descriptions else None,
                "parent": (n.get("parent") or {}).get("identifier"),
                "milestone": (n.get("projectMilestone") or {}).get("name"),
                "labels": gql_labels(n),
            })
            if n["relations"]["pageInfo"]["hasNextPage"] or n["inverseRelations"]["pageInfo"]["hasNextPage"]:
                truncated.append(me)
            for r in n["relations"]["nodes"]:
                other = r["relatedIssue"]
                external[other["identifier"]] = other["title"]
                other_ids[other["identifier"]] = other.get("id")
                relations.add((r["type"], me, other["identifier"]))
            for r in n["inverseRelations"]["nodes"]:
                other = r["issue"]
                external[other["identifier"]] = other["title"]
                other_ids[other["identifier"]] = other.get("id")
                relations.add((r["type"], other["identifier"], me))
        if not page["pageInfo"]["hasNextPage"]:
            break
        after = page["pageInfo"]["endCursor"]
    if truncated:
        print("warning: more than %d relations on %s; some links may be missing"
              % (PAGE_SIZE, ", ".join(truncated)), file=sys.stderr)
    inside = {i["identifier"] for i in issues}
    external = {k: v for k, v in external.items() if k not in inside}
    ids = sorted(other_ids[k] for k in external if other_ids.get(k))
    external_labels = {}
    for start in range(0, len(ids), EXTERNAL_PAGE):
        found = gql(api_url, key, QUERY_EXTERNAL_LABELS, {"ids": ids[start:start + EXTERNAL_PAGE]})["issues"]["nodes"]
        for n in found:
            external_labels[n["identifier"]] = gql_labels(n)
    return {
        "project": {"name": project["name"]},
        "issues": issues,
        "relations": [{"type": t, "from": a, "to": b} for t, a, b in sorted(relations)],
        "external": external,
        "external_labels": external_labels,
    }


EXCERPT_CHARS = 500
MD_NOISE = [
    (re.compile(r"```.*?```", re.S), " "),                 # fenced code
    (re.compile(r"!\[[^\]]*\]\([^)]*\)"), " "),             # images
    (re.compile(r"\[([^\]]*)\]\([^)]*\)"), r"\1"),          # links keep their text
    (re.compile(r"<[^>]+>"), " "),                         # html tags
    (re.compile(r"https?://\S+"), " "),                    # bare urls
    (re.compile(r"(?m)^\s{0,3}(#{1,6}|>+|[-*+]\s+\[[ xX]\]|[-*+]|\d+[.)])\s+"), ""),  # heading, quote, list marks
    (re.compile(r"(\*\*|__|~~|`)"), ""),                    # emphasis and code marks
    (re.compile(r"(?m)^\s*([-*_]\s*){3,}$"), " "),          # horizontal rules
]


def excerpt(text, limit=EXCERPT_CHARS):
    """The beginning of a markdown description as plain text: noise stripped, whitespace collapsed."""
    if not text:
        return None
    for rx, sub in MD_NOISE:
        text = rx.sub(sub, text)
    text = " ".join(text.split())
    if len(text) <= limit:
        return text or None
    cut = text[:limit].rsplit(" ", 1)[0] if " " in text[:limit] else text[:limit]
    return cut.rstrip(" ,;:.") + "…"


def issue_excerpt(issue):
    """Normalized data may carry the excerpt (live fetch) or a raw description (MCP fallback)."""
    return issue.get("description_excerpt") or excerpt(issue.get("description"))


def drop_descriptions(data):
    for issue in data["issues"]:
        issue.pop("description", None)
        issue["description_excerpt"] = None


def gql_labels(node):
    return [{"name": l["name"], "group": (l.get("parent") or {}).get("name")}
            for l in (node.get("labels") or {}).get("nodes", [])]


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
        if t == "blocked_by":
            t, a, b = "blocks", b, a
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
                            "state": "", "parent": None, "external": True,
                            "labels": data.get("external_labels", {}).get(ident, [])}
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


def norm(name):
    return " ".join(re.split(r"[\s_-]+", (name or "").strip().lower()))


def norm_labels(labels):
    """Labels in the normalized data are {"name", "group"} dicts or bare names."""
    return [l if isinstance(l, dict) else {"name": l, "group": None} for l in labels or []]


def ticket_type(labels):
    """The label of the "Type" group, else a label named like one of the eight types, else None."""
    canonical = {norm(t): t for t in TICKET_TYPES}
    for l in labels:
        if norm(l.get("group")) == TYPE_GROUP:
            return canonical.get(norm(l["name"]), l["name"])
    for l in labels:
        if norm(l["name"]) in canonical:
            return canonical[norm(l["name"])]
    return None


def find_cycles(nodes, edges):
    """Strongly connected components of more than one issue (Tarjan, iterative)."""
    succ = defaultdict(list)
    for a, b in edges:
        succ[a].append(b)
    index, low, on_stack, stack, out, counter = {}, {}, set(), [], [], [0]
    for root in sorted(nodes, key=sort_key):
        if root in index:
            continue
        work = [(root, iter(sorted(succ[root], key=sort_key)))]
        index[root] = low[root] = counter[0]
        counter[0] += 1
        stack.append(root)
        on_stack.add(root)
        while work:
            node, it = work[-1]
            for nxt in it:
                if nxt not in index:
                    index[nxt] = low[nxt] = counter[0]
                    counter[0] += 1
                    stack.append(nxt)
                    on_stack.add(nxt)
                    work.append((nxt, iter(sorted(succ[nxt], key=sort_key))))
                    break
                if nxt in on_stack:
                    low[node] = min(low[node], index[nxt])
            else:
                work.pop()
                if work:
                    low[work[-1][0]] = min(low[work[-1][0]], low[node])
                if low[node] == index[node]:
                    comp = []
                    while True:
                        x = stack.pop()
                        on_stack.discard(x)
                        comp.append(x)
                        if x == node:
                            break
                    if len(comp) > 1:
                        out.append(sorted(comp, key=sort_key))
    return sorted(out, key=lambda c: sort_key(c[0]))


def build_export(data, project_url, workspace):
    """The whole graph as plain JSON for an agent: every relation, outside issues included."""
    internal = {i["identifier"]: i for i in data["issues"]}
    ext_titles = data.get("external", {})
    ext_labels = data.get("external_labels", {})
    edges = set()
    for r in data["relations"]:
        t, a, b = r["type"], r["from"], r["to"]
        if t == "blocked_by":
            t, a, b = "blocks", b, a
        if a == b:
            continue
        if t not in DIRECTED:
            a, b = sorted((a, b), key=sort_key)
        edges.add((t, a, b))
    edges = sorted(edges, key=lambda e: (e[0], sort_key(e[1]), sort_key(e[2])))

    idents = set(internal) | {x for _, a, b in edges for x in (a, b)}
    blockers, blocked = defaultdict(list), defaultdict(list)
    for t, a, b in edges:
        if t == "blocks":
            blocked[a].append(b)
            blockers[b].append(a)
    nodes = []
    for ident in sorted(idents, key=sort_key):
        src = internal.get(ident)
        labels = norm_labels(src.get("labels") if src else ext_labels.get(ident))
        nodes.append({
            "identifier": ident,
            "title": src["title"] if src else ext_titles.get(ident, ""),
            "url": issue_url(workspace, ident),
            "external": src is None,
            "state": src.get("state", "") if src else None,
            "state_name": src.get("state_name") if src else None,
            "state_color": src.get("state_color") if src else None,
            "assignee": src.get("assignee") if src else None,
            "description_excerpt": issue_excerpt(src) if src else None,
            "parent": src.get("parent") if src else None,
            "milestone": src.get("milestone") if src else None,
            "type": ticket_type(labels),
            "labels": labels,
            "blocked_by": sorted(blockers[ident], key=sort_key),
            "blocks": sorted(blocked[ident], key=sort_key),
        })
    block_edges = [(a, b) for t, a, b in edges if t == "blocks"]
    return {
        "format": "linear-deps/1",
        "project": {"name": data["project"]["name"], "url": project_url},
        "nodes": nodes,
        "edges": [{"from": a, "to": b, "type": t} for t, a, b in edges],
        "cycles": find_cycles(idents, block_edges),
        "no_dependency": sorted((i for i in internal if not blockers[i] and not blocked[i]), key=sort_key),
    }


def check_types(graph, ticket, blocked_by, open_only=False):
    """Every project issue of type `ticket` must be blocked by at least one issue of a type in `blocked_by`.

    Returns (checked, failures, unknown): a failure has no qualifying blocker and no blocker of unknown
    type; `unknown` has no qualifying blocker but at least one blocker whose type could not be read.
    """
    wanted = {norm(t) for t in blocked_by}
    by_id = {n["identifier"]: n for n in graph["nodes"]}
    checked, failures, unknown = [], [], []
    for n in graph["nodes"]:
        if n["external"] or norm(n["type"]) != norm(ticket):
            continue
        if open_only and n["state"] in ("completed", "canceled"):
            continue
        checked.append(n)
        types = [by_id[b]["type"] if b in by_id else None for b in n["blocked_by"]]
        if any(norm(t) in wanted for t in types if t):
            continue
        (unknown if None in types else failures).append(n)
    return checked, failures, unknown


def describe_blockers(graph, node):
    by_id = {n["identifier"]: n for n in graph["nodes"]}
    if not node["blocked_by"]:
        return "no blocker"
    return "blocked by " + ", ".join(
        "%s (%s)" % (b, (by_id.get(b) or {}).get("type") or "type unknown") for b in node["blocked_by"])


def check_main(argv):
    ap = argparse.ArgumentParser(
        prog="linear_deps.py check",
        description="Check that every issue of one ticket type is blocked by at least one issue of other types.")
    ap.add_argument("graph", help="JSON written by --json-out")
    ap.add_argument("--type", required=True, help='ticket type to check, e.g. "Proof"')
    ap.add_argument("--blocked-by", action="append", required=True, metavar="TYPES",
                    help='accepted blocker type(s); repeatable or comma-separated, e.g. "Technical task,Feature"')
    ap.add_argument("--open-only", action="store_true", help="skip completed and canceled issues of --type")
    args = ap.parse_args(argv)
    graph = load_json(args.graph)
    accepted = [t.strip() for v in args.blocked_by for t in v.split(",") if t.strip()]
    checked, failures, unknown = check_types(graph, args.type, accepted, args.open_only)
    for n in failures:
        print("FAIL     %s  %s  [%s] %s  %s" % (n["identifier"], n["url"], n["state"], n["title"],
                                                describe_blockers(graph, n)))
    for n in unknown:
        print("UNKNOWN  %s  %s  [%s] %s  %s" % (n["identifier"], n["url"], n["state"], n["title"],
                                                describe_blockers(graph, n)))
    print("%d %s issue(s) checked against %s: %d ok, %d fail, %d unknown"
          % (len(checked), args.type, " / ".join(accepted), len(checked) - len(failures) - len(unknown),
             len(failures), len(unknown)))
    if not checked:
        print("note: no issue of type %r; types present: %s" % (
            args.type, ", ".join(sorted({n["type"] for n in graph["nodes"] if n["type"]})) or "none"),
            file=sys.stderr)
    return 1 if failures or unknown else 0


# Linear's own state code: each workflow state carries its team's colour (`state.color`), and its
# type gives the icon. The fallback colours, used only when the data has no colour (offline
# fixtures), are Linear's defaults per type. The legend is built from the same functions.
STATE_ORDER = ("triage", "backlog", "unstarted", "started", "completed", "canceled")
FALLBACK_COLORS = {"triage": "#fc7840", "backlog": "#bec2c8", "unstarted": "#e2e2e2", "started": "#f2c94c",
                   "completed": "#5e6ad2", "canceled": "#95a2b3"}
FALLBACK_NAMES = {"triage": "Triage", "backlog": "Backlog", "unstarted": "Todo", "started": "In Progress",
                  "completed": "Done", "canceled": "Canceled"}
OTHER_COLOR = "#95a2b3"
HEX_RE = re.compile(r"^#[0-9a-fA-F]{3}([0-9a-fA-F]{3})?$")

STYLE = """
svg { --bg:#f5f6f8; --fg:#151a22; --muted:#5a6372; --edge:#4a5262; --cycle:#c2330f; --card:#ffffff;
  --chip:#f0f2f5; --hatch:#d5d9e0; }
@media (prefers-color-scheme: dark) { svg { --bg:#11151b; --fg:#e8ebf0; --muted:#9aa3b2; --edge:#a8b0be;
  --cycle:#ff8a65; --card:#1a1f27; --chip:#252b35; --hatch:#2f3642; } }
text { font-family: "IBM Plex Sans", system-ui, -apple-system, "Segoe UI", sans-serif; fill: var(--fg); }
.bg { fill: var(--bg); }
.h { font-size: 16px; font-weight: 600; } .sub { font-size: 12px; fill: var(--muted); }
.id { font-family: "IBM Plex Mono", ui-monospace, Menlo, monospace; font-size: 11.5px; font-weight: 500; }
.ttl { font-size: 12.5px; } .tag { font-family: "IBM Plex Mono", ui-monospace, Menlo, monospace; font-size: 10.5px; fill: var(--muted); }
.meta { font-size: 10.5px; fill: var(--muted); }
.box { fill: var(--card); stroke-width: 1.5; }
.backlog .box { stroke-dasharray: 5 3; }
.canceled .ttl { text-decoration: line-through; fill: var(--muted); }
.ext .box { fill: url(#hatch); stroke: var(--muted); }
.ext .ttl, .ext .id { fill: var(--muted); }
.chip rect { fill: var(--chip); stroke: var(--muted); stroke-width: .6; } .chip text { font-size: 10px; }
.tchip rect { fill: var(--chip); stroke: var(--fg); stroke-width: 1.1; } .tchip text { font-size: 10px; font-weight: 700; }
.xchip rect { fill: var(--bg); stroke: var(--muted); stroke-width: .8; stroke-dasharray: 1 1.5; }
.xchip text { font-size: 10px; font-style: italic; fill: var(--muted); }
a:hover .box { stroke-width: 2.6; }
.edge { stroke: var(--edge); stroke-width: 1.4; fill: none; opacity: .8; }
.rel { stroke: var(--muted); stroke-width: 1.1; stroke-dasharray: 2 3; fill: none; }
.cyc { stroke: var(--cycle); stroke-width: 1.8; stroke-dasharray: 6 3; fill: none; }
.arrow { fill: var(--edge); } .arrow-c { fill: var(--cycle); }
.warn { font-size: 12px; fill: var(--cycle); font-weight: 600; }
.lg { font-size: 11px; fill: var(--muted); }
.focus a[data-id] > g, .focus path[data-to] { opacity: .15; transition: opacity .12s; }
.focus a.hl0 > g, .focus a.hl1 > g, .focus path.hl1 { opacity: 1; } .focus a.hl2 > g, .focus path.hl2 { opacity: .7; }
a.hl0 .box { stroke-width: 3.2; } a.hl1 .box { stroke-width: 2.6; }
path.hl1 { stroke: var(--fg); stroke-width: 2.8; opacity: 1; } path.hl2 { stroke-width: 2; }
"""
CHAR_W = 6.1        # rough width of one 10-11px character, to fit text without a layout engine
CHIP_CHAR_W = 5.5   # the same for the 10px chip text
CHIP_PAD = 6


def state_kind(node):
    """The state type that picks the icon and the outline: one of STATE_ORDER, "other" or "ext"."""
    if node.get("external"):
        return "ext"
    if not node.get("state"):
        return "unstarted"      # normalized data written before states were fetched
    return node["state"] if node["state"] in STATE_ORDER else "other"


def state_look(node):
    """(kind, colour, name): colour from Linear when present and well formed, else the type default."""
    kind = state_kind(node)
    if kind == "ext":
        return kind, None, None
    color = node.get("state_color")
    if not (isinstance(color, str) and HEX_RE.match(color)):
        color = FALLBACK_COLORS.get(kind, OTHER_COLOR)
    name = node.get("state_name") or FALLBACK_NAMES.get(kind) or node.get("state") or "Unknown state"
    return kind, color, name


def state_glyph(kind, color, cx, cy, r=6):
    """Linear's status icon: dashed circle, empty circle, half-filled, filled with a check or a cross."""
    c = "stroke:%s" % color
    f = "fill:%s" % color
    if kind == "backlog":
        return ('<circle cx="%.1f" cy="%.1f" r="%.1f" style="fill:none;%s;stroke-width:1.6;stroke-dasharray:2 1.7"/>'
                % (cx, cy, r, c))
    if kind == "started":
        return ('<circle cx="%.1f" cy="%.1f" r="%.1f" style="fill:none;%s;stroke-width:1.6"/>'
                '<path d="M%.1f %.1f A%.1f %.1f 0 0 1 %.1f %.1f Z" style="%s"/>'
                % (cx, cy, r, c, cx, cy - r + 2, r - 2, r - 2, cx, cy + r - 2, f))
    if kind in ("completed", "canceled"):
        mark = ("M%.1f %.1f l2.2 2.2 l4 -4.4" % (cx - 3.2, cy) if kind == "completed"
                else "M%.1f %.1f l5 5 M%.1f %.1f l-5 5" % (cx - 2.5, cy - 2.5, cx + 2.5, cy - 2.5))
        return ('<circle cx="%.1f" cy="%.1f" r="%.1f" style="%s"/>'
                '<path d="%s" style="fill:none;stroke:#ffffff;stroke-width:1.6;stroke-linecap:round"/>'
                % (cx, cy, r, f, mark))
    if kind == "triage":
        return ('<circle cx="%.1f" cy="%.1f" r="%.1f" style="fill:none;%s;stroke-width:1.6"/>'
                '<circle cx="%.1f" cy="%.1f" r="2.4" style="%s"/>' % (cx, cy, r, c, cx, cy, f))
    return '<circle cx="%.1f" cy="%.1f" r="%.1f" style="fill:none;%s;stroke-width:1.6"/>' % (cx, cy, r, c)


def card_labels(node):
    """(type, other labels as "group/name" or "name"); the type is shown once, as its own chip."""
    labels = norm_labels(node.get("labels"))
    kind = ticket_type(labels)
    rest = []
    for l in labels:
        if norm(l.get("group")) == TYPE_GROUP or (kind and not l.get("group") and norm(l["name"]) == norm(kind)):
            continue
        rest.append("%s/%s" % (l["group"], l["name"]) if l.get("group") else l["name"])
    return kind, rest


def card_tooltip(ident, n):
    kind, rest = card_labels(n)
    lines = ["%s: %s" % (ident, n["title"] or "(outside this project)")]
    facts = [("State", n.get("state_name") or n.get("state")), ("Type", kind),
             ("Assignee", n.get("assignee")), ("Milestone", n.get("milestone")), ("Parent", n.get("parent")),
             ("Labels", ", ".join(rest))]
    lines += ["%s: %s" % (k, v) for k, v in facts if v]
    text = issue_excerpt(n)
    if text:
        lines += ["", clip(text, 240)]
    return "\n".join(lines)


def fit_chips(names, width):
    """[(index or None, text, width)]: the chips that fit on one line, then a "+N" chip for the rest."""
    out, x = [], 0
    for i, name in enumerate(names):
        label = clip(name, 26)
        w = len(label) * CHIP_CHAR_W + 2 * CHIP_PAD
        more = len(names) - i - 1
        reserve = (len("+%d" % more) * CHIP_CHAR_W + 2 * CHIP_PAD + 4) if more else 0
        if x + w + reserve > width:
            more = "+%d" % (len(names) - i)
            out.append((None, more, len(more) * CHIP_CHAR_W + 2 * CHIP_PAD))
            break
        out.append((i, label, w))
        x += w + 4
    return out


def legend_items(graph, isolated, cards):
    """Every marker actually drawn: one entry per state (type, colour, name) present, then the rest."""
    states = {}
    for n in list(graph["nodes"].values()) + [dict(n, external=False) for n in isolated]:
        kind, color, name = state_look(n)
        if kind != "ext":
            states[(kind, color.lower(), name)] = None
    order = {k: i for i, k in enumerate(STATE_ORDER + ("other",))}
    items = [("state", (kind, color), name)
             for kind, color, name in sorted(states, key=lambda t: (order[t[0]], t[2]))]
    if any(n["external"] for n in graph["nodes"].values()):
        items.append(("ext", None, "outside the project (hatched)"))
    if graph["block"] - graph["back"]:
        items.append(("line", "edge", "A blocks B (arrow)"))
    if graph["related"]:
        items.append(("line", "rel", "related (dotted)"))
    if graph["back"]:
        items.append(("line", "cyc", "link closing a cycle"))
    if any(k for k, _ in cards):
        items.append(("chip", "tchip", "ticket type"))
    if any(r for _, r in cards):
        items.append(("chip", "chip", "label"))
    if graph["block"]:
        items.append(("line", "edge hl1", "on hover: direct blocker"))
        items.append(("line", "edge hl2", "on hover: further upstream"))
    return items


PEEK_DELAY_MS = 900

# The hover preview: a panel drawn by a small inline script from data embedded at generation
# time (the SVG cannot call Linear when viewed). Viewers that block scripts keep <title>.
PEEK_CSS = """
.peek { font: 12px/1.45 "IBM Plex Sans", system-ui, -apple-system, "Segoe UI", sans-serif; color: var(--fg);
  background: var(--card); border: 1px solid var(--muted); border-left: 4px solid var(--muted); border-radius: 8px;
  padding: 10px 12px; box-shadow: 0 6px 24px #0004; box-sizing: border-box; width: 380px; }
.peek .pid { font: 500 11.5px "IBM Plex Mono", ui-monospace, Menlo, monospace; display: flex; align-items: center; gap: 6px; }
.peek .pid span { margin-left: auto; color: var(--muted); font-weight: 400; }
.peek .pttl { font-weight: 600; font-size: 13px; margin: 4px 0 2px; }
.peek .pmeta { color: var(--muted); font-size: 11px; }
.peek .pchips { margin: 6px 0 2px; display: flex; flex-wrap: wrap; gap: 4px; }
.peek .pchips b, .peek .pchips i { font-size: 10px; border-radius: 8px; padding: 1px 7px; background: var(--chip);
  border: 1px solid var(--muted); font-style: normal; font-weight: 400; }
.peek .pchips b { font-weight: 700; border-color: var(--fg); }
.peek .pdesc { margin-top: 6px; white-space: normal; overflow-wrap: anywhere; }
.peek .pnone { margin-top: 6px; color: var(--muted); font-style: italic; }
"""

PEEK_JS = """(function () {
  var data = JSON.parse(document.getElementById('peek-data').textContent);
  var svg = document.documentElement, NS = 'http://www.w3.org/2000/svg', XH = 'http://www.w3.org/1999/xhtml';
  var timer = null, fo = null;
  function el(tag, cls, text) { var e = document.createElementNS(XH, tag); if (cls) e.className = cls;
    if (text) e.textContent = text; return e; }
  function toSvg(x, y) { var p = svg.createSVGPoint(); p.x = x; p.y = y;
    return p.matrixTransform(svg.getScreenCTM().inverse()); }
  function hide() { clearTimeout(timer); if (fo) { fo.remove(); fo = null; shrink(); } }
  function show(d, ev) {
    hide();
    fo = document.createElementNS(NS, 'foreignObject');
    fo.setAttribute('width', 380); fo.setAttribute('height', 10); fo.setAttribute('pointer-events', 'none');
    var box = el('div', 'peek'); if (d.color) box.style.borderLeftColor = d.color;
    var head = el('div', 'pid');
    var g = document.createElementNS(NS, 'svg'); g.setAttribute('width', 14); g.setAttribute('height', 14);
    g.setAttribute('viewBox', '-7 -7 14 14'); g.innerHTML = d.glyph; head.appendChild(g);
    head.appendChild(document.createTextNode(d.id)); if (d.parent) head.appendChild(el('span', '', 'sub-issue of ' + d.parent));
    box.appendChild(head); box.appendChild(el('div', 'pttl', d.title));
    var meta = [d.state, d.assignee, d.milestone].filter(Boolean).join(' · ');
    if (meta) box.appendChild(el('div', 'pmeta', meta));
    if (d.type || d.labels.length) { var c = el('div', 'pchips');
      if (d.type) c.appendChild(el('b', '', d.type));
      d.labels.forEach(function (l) { c.appendChild(el('i', '', l)); }); box.appendChild(c); }
    box.appendChild(d.text ? el('div', 'pdesc', d.text) : el('div', 'pnone', 'No description.'));
    fo.appendChild(box); svg.appendChild(fo);
    var h = box.offsetHeight + 2; fo.setAttribute('height', h);
    var a = toSvg(0, 0), b = toSvg(window.innerWidth, window.innerHeight), p = toSvg(ev.clientX, ev.clientY);
    var right = Math.min(b.x, vb.width), bottom = Math.min(b.y, vb.height);
    var x = p.x + 16, y = p.y + 16;
    if (x + 380 > right) x = p.x - 396; if (y + h > bottom) y = bottom - h - 8;
    x = Math.max(a.x + 8, x); y = Math.max(a.y + 8, y);
    fo.setAttribute('x', x); fo.setAttribute('y', y);
    if (y + h + 8 > vb.height) grow(y + h + 8);   // a small graph: let the drawing grow under the panel
  }
  var vb = svg.viewBox.baseVal, base = [svg.getAttribute('height'), vb.height];
  function grow(hgt) { svg.setAttribute('height', hgt); svg.setAttribute('viewBox', '0 0 ' + vb.width + ' ' + hgt); }
  function shrink() { if (svg.getAttribute('height') != base[0]) { svg.setAttribute('height', base[0]);
    svg.setAttribute('viewBox', '0 0 ' + vb.width + ' ' + base[1]); } }
  var cards = {}, links = Array.prototype.slice.call(document.querySelectorAll('path[data-to]'));
  Array.prototype.forEach.call(document.querySelectorAll('a[data-id]'), function (a) { cards[a.getAttribute('data-id')] = a; });
  var lit = [];
  function mark(e, cls) { e.classList.add(cls); lit.push([e, cls]); }
  function focus(id, d) {   // the card, what blocks it directly, and the rest of the chain upstream
    var one = {}, two = {}; d.blockers.forEach(function (b) { one[b] = 1; }); d.upstream.forEach(function (b) { two[b] = 1; });
    svg.classList.add('focus'); if (cards[id]) mark(cards[id], 'hl0');
    d.blockers.forEach(function (b) { if (cards[b]) mark(cards[b], 'hl1'); });
    d.upstream.forEach(function (b) { if (cards[b]) mark(cards[b], 'hl2'); });
    links.forEach(function (e) { if (!e.hasAttribute('data-blocks')) return;
      var f = e.getAttribute('data-from'), t = e.getAttribute('data-to');
      if (t === id && one[f]) mark(e, 'hl1'); else if ((one[t] || two[t]) && (one[f] || two[f])) mark(e, 'hl2'); });
  }
  function unfocus() { svg.classList.remove('focus'); lit.forEach(function (x) { x[0].classList.remove(x[1]); }); lit = []; }
  Array.prototype.forEach.call(document.querySelectorAll('a[data-id]'), function (a) {
    var d = data[a.getAttribute('data-id')]; if (!d) return;
    var t = a.querySelector('title'); if (t) t.remove();   // the panel replaces the native tooltip
    var last = null;
    a.addEventListener('mouseenter', function (ev) { last = ev; clearTimeout(timer); focus(d.id, d);
      timer = setTimeout(function () { show(d, last); }, %d); });
    a.addEventListener('mousemove', function (ev) { last = ev; });
    a.addEventListener('mouseleave', function () { hide(); unfocus(); });
  });
})();""" % PEEK_DELAY_MS


NO_CHAIN = {"blockers": [], "upstream": []}


def upstream_chains(graph):
    """For every drawn issue: its direct blockers, and the blockers further up the chain.

    Breadth-first over "blocks" links, back edges included, with a visited set, so a cycle ends
    instead of looping; the issue itself is never its own upstream.
    """
    preds = defaultdict(set)
    for a, b in graph["block"]:
        preds[b].add(a)
    out = {}
    for ident in graph["nodes"]:
        direct = preds[ident] - {ident}
        seen, todo = set(direct), list(direct)
        while todo:
            for p in preds[todo.pop()]:
                if p not in seen and p != ident:
                    seen.add(p)
                    todo.append(p)
        out[ident] = {"blockers": sorted(direct, key=sort_key), "upstream": sorted(seen - direct, key=sort_key)}
    return out


def peek_entry(ident, n):
    kind, rest = card_labels(n)
    skind, color, name = state_look(n)
    return {"id": ident, "title": n.get("title") or "(outside this project)",
            "state": name if skind != "ext" else "outside this project", "color": color,
            "glyph": state_glyph(skind, color or "#95a2b3", 0, 0),
            "assignee": n.get("assignee"), "milestone": n.get("milestone"), "parent": n.get("parent"),
            "type": kind, "labels": rest, "text": issue_excerpt(n)}


def peek_script(peek):
    """The preview data as JSON with <, > and & escaped, so it can never close the CDATA section."""
    blob = json.dumps(peek, ensure_ascii=False, sort_keys=True)
    blob = blob.replace("&", "\\u0026").replace("<", "\\u003c").replace(">", "\\u003e")
    return ('<script type="application/json" id="peek-data"><![CDATA[%s]]></script>'
            '<script><![CDATA[%s]]></script>' % (blob, PEEK_JS))


def render_svg(data, graph, workspace, hide_isolated):
    nodes, layers = graph["nodes"], graph["order"]
    isolated_ids = [] if hide_isolated else graph["isolated"]
    internal = {i["identifier"]: i for i in data["issues"]}
    isolated = [internal[i] for i in isolated_ids]
    cards = [card_labels(n) for n in nodes.values()]

    n_layers = len(layers)
    graph_w = n_layers * BOX_W + max(0, n_layers - 1) * GAP_X if n_layers else 0
    width = max(MARGIN * 2 + graph_w, 640)

    legend = legend_items(graph, isolated, cards)
    lg_pos, lx, ly = [], MARGIN, 70
    for item in legend:
        w_item = 34 + len(item[2]) * CHAR_W + 18
        if lx + w_item > width - MARGIN and lx > MARGIN:
            lx, ly = MARGIN, ly + 20
        lg_pos.append((item, lx, ly))
        lx += w_item
    top = (ly + 26) if legend else 62

    tallest = max((len(l) for l in layers), default=0)
    graph_h = tallest * BOX_H + max(0, tallest - 1) * GAP_Y
    pos = {}
    for li, col in enumerate(layers):
        col_h = len(col) * BOX_H + max(0, len(col) - 1) * GAP_Y
        y0 = (graph_h - col_h) / 2
        for ri, ident in enumerate(col):
            pos[ident] = (MARGIN + li * (BOX_W + GAP_X), top + y0 + ri * (BOX_H + GAP_Y))

    strip_top = top + graph_h + 40
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
    w("<style>%s</style>" % (STYLE + PEEK_CSS))
    w('<defs><marker id="ar" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto">'
      '<path class="arrow" d="M0 0 L10 5 L0 10 z"/></marker>'
      '<marker id="ac" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto">'
      '<path class="arrow-c" d="M0 0 L10 5 L0 10 z"/></marker>'
      '<pattern id="hatch" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">'
      '<rect width="6" height="6" style="fill:var(--card)"/><rect width="2.2" height="6" style="fill:var(--hatch)"/>'
      '</pattern></defs>')
    w('<rect class="bg" width="100%" height="100%"/>')
    w('<text class="h" x="%d" y="28">%s</text>' % (MARGIN, escape(data["project"]["name"])))
    n_edges = len(graph["block"])
    w('<text class="sub" x="%d" y="46">%d issues in dependency chains, %d blocking links; arrow = blocks, left to right</text>'
      % (MARGIN, len(nodes), n_edges))

    w('<g class="legend">')
    for (kind, cls, text), x, y in lg_pos:
        if kind == "state":
            w(state_glyph(cls[0], cls[1], x + 13, y - 4))
        elif kind == "ext":
            w('<g class="ext"><rect class="box" x="%d" y="%d" width="26" height="14" rx="4"/></g>' % (x, y - 11))
        elif kind == "line":
            marker = ' marker-end="url(#ac)"' if cls == "cyc" else (' marker-end="url(#ar)"' if "edge" in cls else "")
            w('<path class="%s" d="M%d %d L%d %d"%s/>' % (cls, x, y - 4, x + 26, y - 4, marker))
        else:
            w('<g class="%s"><rect x="%d" y="%d" width="26" height="14" rx="7"/></g>' % (cls, x, y - 11))
        w('<text class="lg" x="%d" y="%d">%s</text>' % (x + 34, y, escape(text)))
    w("</g>")

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
            w('<path class="rel" d="%s" data-from=%s data-to=%s><title>related</title></path>'
              % (edge_path(a, b), quoteattr(a), quoteattr(b)))
    for a, b in sorted(graph["block"] - graph["back"]):
        w('<path class="edge" d="%s" marker-end="url(#ar)" data-from=%s data-to=%s data-blocks="1">'
          '<title>%s blocks %s</title></path>' % (edge_path(a, b), quoteattr(a), quoteattr(b), a, b))
    for a, b in sorted(graph["back"]):
        w('<path class="cyc" d="%s" marker-end="url(#ac)" data-from=%s data-to=%s data-blocks="1">'
          '<title>cycle: %s blocks %s</title></path>' % (edge_path(a, b), quoteattr(a), quoteattr(b), a, b))

    peek = {}
    chains = upstream_chains(graph)

    def box(ident, x, y):
        n = nodes[ident]
        url = issue_url(workspace, ident)
        kind, rest = card_labels(n)
        skind, color, _ = state_look(n)
        peek[ident] = dict(peek_entry(ident, n), **chains.get(ident, NO_CHAIN))
        w('<a href=%s xlink:href=%s target="_blank" rel="noopener" data-id=%s><g class="%s">'
          % (quoteattr(url), quoteattr(url), quoteattr(ident), skind))
        w('<title>%s</title>' % escape(card_tooltip(ident, n)))
        stroke = ' style="stroke:%s"' % color if color else ""
        w('<rect class="box" x="%.1f" y="%.1f" width="%d" height="%d" rx="8"%s/>' % (x, y, BOX_W, BOX_H, stroke))
        if color:
            w('<rect x="%.1f" y="%.1f" width="4" height="%d" rx="2" style="fill:%s"/>'
              % (x + 1.5, y + 8, BOX_H - 16, color))
            w(state_glyph(skind, color, x + 18, y + 14))
        w('<text class="id" x="%.1f" y="%.1f">%s</text>' % (x + (30 if color else 12), y + 18, escape(ident)))
        if n.get("parent"):
            w('<text class="tag" x="%.1f" y="%.1f" text-anchor="end">↳ %s</text>'
              % (x + BOX_W - 10, y + 18, escape(n["parent"])))
        w('<text class="ttl" x="%.1f" y="%.1f">%s</text>'
          % (x + 12, y + 36, escape(clip(n["title"], TITLE_CHARS) if n["title"] else "outside this project")))
        meta = " · ".join(v for v in (n.get("state_name"), n.get("assignee"), n.get("milestone")) if v)
        if meta:
            w('<text class="meta" x="%.1f" y="%.1f">%s</text>'
              % (x + 12, y + 53, escape(clip(meta, int((BOX_W - 24) / CHAR_W)))))
        chips = ([("xchip", "external")] if n.get("external") else []) + \
            ([("tchip", kind)] if kind else []) + [("chip", r) for r in rest]
        cx = x + 10
        fitted = fit_chips([c[1] for c in chips], BOX_W - 20)
        for i, label, cw in fitted:
            cls = chips[i][0] if i is not None else "chip"
            w('<g class="%s"><rect x="%.1f" y="%.1f" width="%.1f" height="16" rx="8"/>'
              '<text x="%.1f" y="%.1f">%s</text></g>' % (cls, cx, y + 62, cw, cx + CHIP_PAD, y + 74, escape(label)))
            cx += cw + 4
        w("</g></a>")

    for ident, (x, y) in sorted(pos.items(), key=lambda kv: sort_key(kv[0])):
        box(ident, x, y)

    if graph["back"]:
        w('<text class="warn" x="%d" y="%d">Cycle detected: %d blocking link(s) drawn dashed in red close a loop.</text>'
          % (MARGIN, int(strip_top - 14), len(graph["back"])))

    if isolated:
        w('<text class="sub" x="%d" y="%d">No dependency (%d issues)</text>' % (MARGIN, strip_top + 4, len(isolated)))
        for i, issue in enumerate(isolated):
            ident = issue["identifier"]
            r, c = divmod(i, per_row)
            x = MARGIN + c * (CHIP_W + 8)
            y = strip_top + 16 + r * (CHIP_H + 8)
            url = issue_url(workspace, ident)
            n = dict(issue, external=False)
            skind, color, _ = state_look(n)
            peek[ident] = dict(peek_entry(ident, n), **chains.get(ident, NO_CHAIN))
            w('<a href=%s xlink:href=%s target="_blank" rel="noopener" data-id=%s><g class="%s"><title>%s</title>'
              '<rect class="box" x="%d" y="%d" width="%d" height="%d" rx="6" style="stroke:%s"/>%s'
              '<text class="id" x="%d" y="%d">%s</text></g></a>'
              % (quoteattr(url), quoteattr(url), quoteattr(ident), skind, escape(card_tooltip(ident, n)),
                 x, y, CHIP_W, CHIP_H, color, state_glyph(skind, color, x + 13, y + 12, 5),
                 x + 24, y + 16, escape(ident)))

    notes = []
    if graph["dropped"]:
        notes.append("%d link(s) to issues outside this project not shown (use --external show)" % graph["dropped"])
    if hide_isolated and graph["isolated"]:
        notes.append("%d issue(s) without dependency hidden" % len(graph["isolated"]))
    if notes:
        w('<text class="sub" x="%d" y="%d">%s</text>' % (MARGIN, height - 24, escape("; ".join(notes))))
    w(peek_script(peek))
    w("</svg>")
    return "\n".join(out) + "\n"


def main(argv=None):
    argv = sys.argv[1:] if argv is None else list(argv)
    if argv[:1] == ["check"]:
        return check_main(argv[1:])
    ap = argparse.ArgumentParser(
        description="Render a Linear project's issue dependencies as a clickable SVG (and JSON with --json-out).",
        epilog='Then: linear_deps.py check deps.json --type Proof --blocked-by "Technical task,Feature" '
               "lists the issues of one type not blocked by any issue of the accepted types.")
    ap.add_argument("project_url", help="https://linear.app/<workspace>/project/<name>-<slugId>")
    ap.add_argument("-o", "--output", default="deps.svg", help="SVG file to write (default: deps.svg)")
    ap.add_argument("--json-out", metavar="FILE",
                    help="also write the graph as JSON for agents (nodes, edges, cycles); see `check`")
    ap.add_argument("--from-json", metavar="FILE", help="read normalized data from FILE instead of calling the API")
    ap.add_argument("--include-related", action="store_true", help="also draw 'related' links (dotted)")
    ap.add_argument("--external", choices=("drop", "show"), default="drop",
                    help="links to issues outside the project: drop (default, counted) or show as dashed boxes")
    ap.add_argument("--hide-isolated", action="store_true", help="hide issues that have no dependency")
    ap.add_argument("--no-descriptions", action="store_true",
                    help="do not fetch or embed description excerpts (hover preview, JSON); for SVGs that get shared")
    ap.add_argument("--api-url", default=API_URL, help=argparse.SUPPRESS)
    args = ap.parse_args(argv)

    workspace, slug = parse_project_url(args.project_url)
    data = (load_json(args.from_json) if args.from_json
            else fetch_live(slug, args.api_url, descriptions=not args.no_descriptions))
    if args.no_descriptions:
        drop_descriptions(data)
    graph = build_graph(data, args.include_related, args.external)
    svg = render_svg(data, graph, workspace, args.hide_isolated)
    with open(args.output, "w", encoding="utf-8") as fh:
        fh.write(svg)
    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as fh:
            json.dump(build_export(data, args.project_url.strip(), workspace), fh, indent=1, ensure_ascii=False)
            fh.write("\n")

    print("%s: %d issues, %d in chains, %d blocking links, %d without dependency, wrote %s"
          % (data["project"]["name"], len(data["issues"]), len(graph["nodes"]), len(graph["block"]),
             len(graph["isolated"]), args.output))
    if graph["dropped"]:
        print("note: %d link(s) to issues outside the project dropped (use --external show)" % graph["dropped"])
    if graph["back"]:
        print("warning: cycle detected; back edges: " + ", ".join("%s->%s" % e for e in sorted(graph["back"])),
              file=sys.stderr)
    if args.json_out:
        print("wrote " + args.json_out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
