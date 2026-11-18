"""linear_deps.py serve: a local web page that draws one Linear project's dependency SVG with live filters.

Standard library only. The Linear API key stays in this process (read from LINEAR_API_KEY); the
browser only talks to http://localhost:<port>. One project is shown at a time. The page lists the
projects the key's user belongs to (member or lead), then filters the chosen project by milestone
and by label; each change re-renders the SVG server side with the same renderer as the CLI, and the
page shows it in an iframe so the SVG's own hover preview keeps working.
"""
import http.server
import json
import os
import sys
import threading
import time
import urllib.parse

import linear_deps as ld

CACHE_TTL = 60  # seconds a fetched project is reused before the next request refetches it

QUERY_MY_PROJECTS = """
query($after: String) {
  viewer { id }
  projects(first: 100, after: $after, filter: {or: [
      {members: {isMe: {eq: true}}}, {lead: {isMe: {eq: true}}}]}) {
    pageInfo { hasNextPage endCursor }
    nodes { name slugId url state }
  }
}"""

INACTIVE_PROJECT_STATES = ("completed", "canceled")


def list_my_projects(api_url):
    key = os.environ.get("LINEAR_API_KEY", "").strip()
    if not key:
        raise SystemExit("error: LINEAR_API_KEY is not set")
    out, after = [], None
    while True:
        page = ld.gql(api_url, key, QUERY_MY_PROJECTS, {"after": after})["projects"]
        for p in page["nodes"]:
            out.append({"name": p["name"], "slug": p["slugId"], "url": p["url"],
                        "state": p.get("state") or "",
                        "active": (p.get("state") or "") not in INACTIVE_PROJECT_STATES})
        if not page["pageInfo"]["hasNextPage"]:
            return sorted(out, key=lambda p: (not p["active"], p["name"].lower()))
        after = page["pageInfo"]["endCursor"]


def facets(data):
    """The values the filters offer: milestones in project order, labels with their group, with counts."""
    ms = {}
    for i in data["issues"]:
        ms[i.get("milestone") or ""] = ms.get(i.get("milestone") or "", 0) + 1
    milestones = [{"name": n, "count": ms[n]} for n in ld.milestone_order(data) if n in ms]
    if "" in ms:
        milestones.append({"name": "", "count": ms[""]})
    lb = {}
    for i in data["issues"]:
        for l in i.get("labels") or []:
            e = lb.setdefault(l["name"], {"name": l["name"], "group": l.get("group"), "count": 0})
            e["count"] += 1
    labels = sorted(lb.values(), key=lambda e: ((e["group"] or "~").lower(), e["name"].lower()))
    return {"milestones": milestones, "labels": labels}


def filter_data(data, milestones, labels, neighbors=False):
    """Keep the issues in one of `milestones` ("" means none) AND carrying one of `labels`; None = no filter.
    With `neighbors`, also keep the issues one blocking link away from a kept one (the context a filter
    would otherwise cut), and only the links that touch a kept issue. Links to issues that are not shown
    become external links, which the renderer drops or shows."""
    seeds = []
    for i in data["issues"]:
        if milestones is not None and (i.get("milestone") or "") not in milestones:
            continue
        if labels is not None and not ({l["name"] for l in i.get("labels") or []} & labels):
            continue
        seeds.append(i)
    seed_ids = {i["identifier"] for i in seeds}
    keep = seeds
    if neighbors:
        near = set()
        for r in data["relations"]:
            if r["type"] not in ("blocks", "blocked_by"):
                continue
            if r["from"] in seed_ids:
                near.add(r["to"])
            if r["to"] in seed_ids:
                near.add(r["from"])
        keep = [i for i in data["issues"] if i["identifier"] in seed_ids or i["identifier"] in near]
    kept = {i["identifier"] for i in keep}
    out = dict(data, issues=keep)
    out["external"] = dict(data.get("external", {}))
    out["external_labels"] = dict(data.get("external_labels", {}))
    for i in data["issues"]:
        if i["identifier"] not in kept:
            out["external"][i["identifier"]] = i["title"]
            out["external_labels"][i["identifier"]] = i.get("labels") or []
    out["relations"] = [r for r in data["relations"] if r["from"] in seed_ids or r["to"] in seed_ids] \
        if neighbors else [r for r in data["relations"] if r["from"] in kept or r["to"] in kept]
    return out


class ProjectCache:
    def __init__(self, api_url, fetch=None):
        self.api_url, self.fetch = api_url, fetch or (lambda slug: ld.fetch_live(slug, api_url))
        self.items, self.lock = {}, threading.Lock()

    def get(self, slug, refresh=False):
        with self.lock:
            hit = self.items.get(slug)
            if hit and not refresh and time.time() - hit[0] < CACHE_TTL:
                return hit[1]
        data = self.fetch(slug)  # outside the lock: one slow project must not block the others
        with self.lock:
            self.items[slug] = (time.time(), data)
        return data


def render_filtered(data, workspace, milestones, labels, hide_isolated, show_external, neighbors=False):
    shown = filter_data(data, milestones, labels, neighbors)
    graph = ld.build_graph(shown, False, "show" if show_external else "drop", bands=True)
    return ld.render_svg(shown, graph, workspace, hide_isolated)


def multi(params, name):
    """None when the parameter is absent (no filter), else the set of its values."""
    return set(params[name]) if name in params else None


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "linear-deps-serve"
    cache = None
    workspace = None
    allowed_hosts = ()

    def log_message(self, fmt, *args):
        pass

    def send(self, code, body, ctype):
        raw = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(raw)

    def fail(self, code, message):
        self.send(code, json.dumps({"error": message}), "application/json")

    def do_GET(self):
        host = (self.headers.get("Host") or "").lower()
        if host not in self.allowed_hosts:  # refuse DNS rebinding: only the names we bound to
            return self.fail(403, "unexpected Host header")
        url = urllib.parse.urlsplit(self.path)
        params = urllib.parse.parse_qs(url.query, keep_blank_values=True)
        one = lambda k, d="": (params.get(k) or [d])[0]  # noqa: E731
        try:
            if url.path == "/":
                return self.send(200, PAGE, "text/html; charset=utf-8")
            if url.path == "/api/projects":
                return self.send(200, json.dumps(list_my_projects(self.cache.api_url)), "application/json")
            slug = one("project")
            if url.path in ("/api/facets", "/graph.svg"):
                if not slug:
                    return self.fail(400, "missing ?project=<slugId>")
                data = self.cache.get(slug, refresh=one("refresh") == "1")
                if url.path == "/api/facets":
                    return self.send(200, json.dumps(dict(facets(data), name=data["project"]["name"],
                                                          issues=len(data["issues"]))), "application/json")
                svg = render_filtered(data, self.workspace, multi(params, "milestone"), multi(params, "label"),
                                      one("hide_isolated") == "1", one("external") == "1",
                                      one("neighbors", "1") == "1")
                return self.send(200, svg, "image/svg+xml")
        except SystemExit as exc:  # fetch_live and gql report API trouble this way
            return self.fail(502, str(exc))
        self.fail(404, "not found")


def serve_main(argv):
    import argparse
    ap = argparse.ArgumentParser(
        prog="linear_deps.py serve",
        description="Serve a local page: pick one of your Linear projects, filter it by milestone and label.")
    ap.add_argument("--workspace", help="Linear workspace slug used for issue links (default: read from the first project)")
    ap.add_argument("--host", default="127.0.0.1",
                    help="address to bind (default 127.0.0.1; use 0.0.0.0 only inside a container with a localhost-only port mapping)")
    ap.add_argument("--port", type=int, default=4420)
    ap.add_argument("--api-url", default=ld.API_URL, help=argparse.SUPPRESS)
    args = ap.parse_args(argv)
    if not os.environ.get("LINEAR_API_KEY", "").strip():
        raise SystemExit("error: LINEAR_API_KEY is not set")

    workspace = args.workspace
    if not workspace:
        projects = list_my_projects(args.api_url)
        workspace = ld.parse_project_url(projects[0]["url"])[0] if projects else ""
    Handler.cache = ProjectCache(args.api_url)
    Handler.workspace = workspace
    Handler.allowed_hosts = tuple("%s:%d" % (h, args.port) for h in ("localhost", "127.0.0.1", "[::1]"))
    srv = http.server.ThreadingHTTPServer((args.host, args.port), Handler)
    print("linear_deps serve: http://localhost:%d  (workspace %s, Ctrl+C to stop)" % (args.port, workspace or "?"))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print()
    return 0


PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Linear dependencies</title>
<style>
:root{--bg:#fff;--fg:#1d2330;--mute:#6b7688;--line:#d9dee7;--panel:#f6f8fb;--acc:#3b5bdb}
@media (prefers-color-scheme:dark){:root{--bg:#151922;--fg:#e6e9ef;--mute:#9aa5b8;--line:#2d3545;--panel:#1c2230;--acc:#7c93ff}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:14px system-ui,sans-serif;display:flex;flex-direction:column;height:100vh}
header{display:flex;gap:12px;align-items:center;padding:10px 16px;border-bottom:1px solid var(--line);flex-wrap:wrap}
select,button{font:inherit;color:var(--fg);background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:5px 9px}
button{cursor:pointer}
main{display:flex;flex:1;min-height:0}
aside{width:260px;overflow:auto;padding:12px 16px;border-right:1px solid var(--line);background:var(--panel)}
aside h2{font-size:12px;text-transform:uppercase;letter-spacing:.05em;color:var(--mute);margin:14px 0 6px}
aside h2:first-child{margin-top:0}
label{display:flex;gap:6px;align-items:baseline;padding:2px 0;cursor:pointer}
label small{color:var(--mute);margin-left:auto}
.group{color:var(--mute);font-size:12px;margin-top:6px}
#view{flex:1;border:0;background:var(--bg)}
#msg{color:var(--mute);padding:6px 16px}
.err{color:#d6336c}
@media (max-width:700px){main{flex-direction:column}aside{width:100%;max-height:35vh;border-right:0;border-bottom:1px solid var(--line)}}
</style></head><body>
<header>
  <strong>Linear dependencies</strong>
  <select id="project" aria-label="Project"></select>
  <label><input type="checkbox" id="iso"> hide issues without dependency</label>
  <label title="Also draw the issues one blocking link away from the filtered ones"><input type="checkbox" id="nb" checked> keep direct neighbors</label>
  <label><input type="checkbox" id="ext"> show outside links</label>
  <button id="refresh" title="Refetch from Linear">Refresh</button>
  <span id="msg"></span>
</header>
<main>
  <aside id="filters"><div class="group">Pick a project.</div></aside>
  <iframe id="view" title="Dependency graph"></iframe>
</main>
<script>
const $ = id => document.getElementById(id);
const state = {milestones: new Set(), labels: new Set(), facets: null};
const say = (t, err) => { $('msg').textContent = t || ''; $('msg').className = err ? 'err' : ''; };
async function api(path) {
  const r = await fetch(path);
  const body = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(body.error || r.statusText);
  return body;
}
function query(refresh) {
  const q = new URLSearchParams({project: $('project').value});
  const f = state.facets;
  // an untouched category sends nothing (no filter); a partly ticked one sends only the ticked values
  if (state.milestones.size < f.milestones.length) state.milestones.forEach(m => q.append('milestone', m));
  if (state.labels.size) state.labels.forEach(l => q.append('label', l));
  if ($('iso').checked) q.set('hide_isolated', '1');
  if ($('ext').checked) q.set('external', '1');
  q.set('neighbors', $('nb').checked ? '1' : '0');
  if (refresh) q.set('refresh', '1');
  return q;
}
function draw(refresh) {
  if (!state.facets) return;
  if (state.milestones.size === 0 && state.facets.milestones.length) { $('view').srcdoc = ''; say('No milestone ticked.'); return; }
  say('Drawing…');
  $('view').onload = () => say('');
  $('view').src = '/graph.svg?' + query(refresh);
}
function box(kind, value, text, count, on) {
  const l = document.createElement('label');
  const c = document.createElement('input'); c.type = 'checkbox'; c.checked = on;
  c.onchange = () => { const s = state[kind]; c.checked ? s.add(value) : s.delete(value); draw(false); };
  const s = document.createElement('span'); s.textContent = text;
  const n = document.createElement('small'); n.textContent = count;
  l.append(c, s, n); return l;
}
async function load(refresh) {
  const slug = $('project').value; if (!slug) return;
  say('Loading the project from Linear…');
  try {
    const f = await api('/api/facets?project=' + encodeURIComponent(slug) + (refresh ? '&refresh=1' : ''));
    state.facets = f; state.milestones = new Set(f.milestones.map(m => m.name)); state.labels = new Set();
    const a = $('filters'); a.replaceChildren();
    const h1 = document.createElement('h2'); h1.textContent = 'Milestones'; a.append(h1);
    f.milestones.forEach(m => a.append(box('milestones', m.name, m.name || '(no milestone)', m.count, true)));
    const h2 = document.createElement('h2'); h2.textContent = 'Labels (any of)'; a.append(h2);
    let group = Symbol();
    f.labels.forEach(l => {
      if (l.group !== group) { group = l.group; const g = document.createElement('div'); g.className = 'group'; g.textContent = l.group || 'Ungrouped'; a.append(g); }
      a.append(box('labels', l.name, l.name, l.count, false));
    });
    draw(false);
  } catch (e) { say(e.message, true); }
}
(async () => {
  try {
    const ps = await api('/api/projects');
    $('project').replaceChildren(...ps.map(p => { const o = document.createElement('option'); o.value = p.slug; o.textContent = p.name + (p.active ? '' : ' (' + p.state + ')'); return o; }));
    if (!ps.length) say('No project found for this API key.', true);
    const saved = localStorage.getItem('linear-deps-project'); if (saved && ps.some(p => p.slug === saved)) $('project').value = saved;
    await load(false);
  } catch (e) { say(e.message, true); }
})();
$('project').onchange = () => { try { localStorage.setItem('linear-deps-project', $('project').value); } catch (e) {} load(false); };
$('iso').onchange = $('ext').onchange = $('nb').onchange = () => draw(false);
$('refresh').onclick = () => load(true);
</script></body></html>
"""
