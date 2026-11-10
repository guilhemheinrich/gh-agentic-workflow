"""Tests for scripts/linear_deps.py: layout, links, cycles, and the live path against a stub server.

Run through run-linear-deps-in-docker.sh. The stub server proves the pagination, the
Authorization header and the normalization of the code; it cannot prove Linear's real schema.
"""
import http.server
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import unittest
import xml.dom.minidom as minidom

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "scripts", "linear_deps.py")
sys.path.insert(0, os.path.dirname(SCRIPT))
import linear_deps as ld  # noqa: E402

DEMO = os.path.join(HERE, "fixtures", "linear-deps-demo.json")
CYCLE = os.path.join(HERE, "fixtures", "linear-deps-cycle.json")
URL = "https://linear.app/acme/project/checkout-redesign-0123456789ab"


def load(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def run_cli(*args, env=None):
    full_env = {k: v for k, v in os.environ.items() if k != "LINEAR_API_KEY"}
    full_env.update(env or {})
    return subprocess.run([sys.executable, SCRIPT, *args], capture_output=True, text=True, env=full_env)


def hrefs(svg_text):
    doc = minidom.parseString(svg_text)
    return [a.getAttribute("href") for a in doc.getElementsByTagName("a")]


class UrlTests(unittest.TestCase):
    def test_workspace_and_slug_are_extracted(self):
        self.assertEqual(ld.parse_project_url(URL), ("acme", "0123456789ab"))

    def test_non_project_url_is_refused(self):
        with self.assertRaises(SystemExit):
            ld.parse_project_url("https://example.com/acme/project/x")


class LayoutTests(unittest.TestCase):
    def graph(self, related=False, external="drop"):
        return ld.build_graph(load(DEMO), related, external)

    def test_layers_follow_the_longest_path(self):
        g = self.graph()
        self.assertEqual(g["layer"]["DEMO-1"], 0)
        self.assertEqual(g["layer"]["DEMO-3"], 0)
        self.assertEqual(g["layer"]["DEMO-2"], 1)
        self.assertEqual(g["layer"]["DEMO-4"], 2)
        self.assertEqual(g["layer"]["DEMO-5"], 2)

    def test_issues_without_blocking_links_are_isolated(self):
        self.assertEqual(self.graph()["isolated"], ["DEMO-8", "DEMO-9"])

    def test_external_links_are_dropped_and_counted_by_default(self):
        g = self.graph()
        self.assertEqual(g["dropped"], 1)
        self.assertNotIn("OTHER-77", g["nodes"])

    def test_external_issue_is_drawn_when_asked(self):
        g = self.graph(external="show")
        self.assertTrue(g["nodes"]["OTHER-77"]["external"])
        self.assertEqual(g["layer"]["OTHER-77"], 0)

    def test_related_links_are_off_unless_asked(self):
        self.assertEqual(self.graph()["related"], set())
        self.assertEqual(self.graph(related=True)["related"], {("DEMO-4", "DEMO-7")})

    def test_cycle_is_detected_and_does_not_loop(self):
        g = ld.build_graph(load(CYCLE), False, "show")
        self.assertEqual(len(g["back"]), 1)
        self.assertEqual(set(g["layer"]), set(g["nodes"]))


class SvgTests(unittest.TestCase):
    def test_every_box_links_to_its_issue(self):
        data = load(DEMO)
        g = ld.build_graph(data, True, "show")
        links = hrefs(ld.render_svg(data, g, "acme", False))
        expected = {"https://linear.app/acme/issue/" + n for n in list(g["nodes"]) + g["isolated"]}
        self.assertEqual(set(links), expected)
        self.assertEqual(len(links), len(expected))

    def test_every_link_opens_in_a_new_tab(self):
        data = load(DEMO)
        svg = ld.render_svg(data, ld.build_graph(data, False, "drop"), "acme", False)
        self.assertEqual(svg.count("<a "), svg.count('target="_blank"'))

    def test_titles_are_escaped(self):
        data = load(DEMO)
        data["issues"][0]["title"] = "Fix <b>&\"quotes\""
        svg = ld.render_svg(data, ld.build_graph(data, False, "drop"), "acme", False)
        minidom.parseString(svg)  # raises when the XML is broken

    def test_hide_isolated_removes_the_strip(self):
        data = load(DEMO)
        g = ld.build_graph(data, False, "drop")
        links = hrefs(ld.render_svg(data, g, "acme", True))
        self.assertNotIn("https://linear.app/acme/issue/DEMO-8", links)


class CliTests(unittest.TestCase):
    def test_offline_run_writes_the_svg(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "g.svg")
            r = run_cli(URL, "--from-json", DEMO, "-o", out)
            self.assertEqual(r.returncode, 0, r.stderr)
            with open(out, encoding="utf-8") as fh:
                self.assertIn("https://linear.app/acme/issue/DEMO-4", fh.read())

    def test_cycle_is_reported_on_stderr_and_exit_is_zero(self):
        with tempfile.TemporaryDirectory() as tmp:
            r = run_cli(URL, "--from-json", CYCLE, "-o", os.path.join(tmp, "c.svg"))
            self.assertEqual(r.returncode, 0)
            self.assertIn("cycle detected", r.stderr)

    def test_missing_key_stops_with_a_clear_message(self):
        r = run_cli(URL)
        self.assertEqual(r.returncode, 1)
        self.assertIn("LINEAR_API_KEY", r.stderr)

    def test_the_key_is_never_printed_even_when_the_api_is_unreachable(self):
        r = run_cli(URL, "--api-url", "http://127.0.0.1:9", env={"LINEAR_API_KEY": "lin_api_SECRET_VALUE"})
        self.assertEqual(r.returncode, 1)
        self.assertNotIn("SECRET_VALUE", r.stdout + r.stderr)


class StubHandler(http.server.BaseHTTPRequestHandler):
    """Answers the three queries of linear_deps with canned data, over two issue pages."""
    seen_auth = []
    seen_external_ids = []

    def log_message(self, *args):
        pass

    @staticmethod
    def node(ident, rel, inv):
        return {"identifier": ident, "title": "Title " + ident, "state": {"type": "unstarted"}, "parent": None,
                "relations": {"pageInfo": {"hasNextPage": False}, "nodes": rel},
                "inverseRelations": {"pageInfo": {"hasNextPage": False}, "nodes": inv}}

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        StubHandler.seen_auth.append(self.headers.get("Authorization"))
        q, v = body["query"], body["variables"]
        if "projects(filter" in q:
            data = {"projects": {"nodes": [{"id": "uuid-1", "name": "Stub project"}]}}
        elif "issues(filter" in q:
            StubHandler.seen_external_ids.append(v["ids"])
            data = {"issues": {"nodes": [{"identifier": "OUT-9", "labels": {"nodes": [
                {"name": "Technical task", "parent": {"name": "Type"}}]}}]}}
        elif "issues(first" in q:
            page2 = v.get("after") == "cursor-1"
            if not page2:
                nodes = [self.node("S-1", [{"type": "blocks", "relatedIssue": {"identifier": "S-2", "title": "Title S-2"}}], [])]
            else:
                nodes = [self.node("S-2", [], [{"type": "blocks", "issue": {"identifier": "S-1", "title": "Title S-1"}},
                                              {"type": "blocks", "issue": {"id": "uuid-out-9", "identifier": "OUT-9", "title": "Outside"}}])]
            data = {"project": {"issues": {"pageInfo": {"hasNextPage": not page2, "endCursor": "cursor-1"}, "nodes": nodes}}}
        else:
            data = {}
        payload = json.dumps({"data": data}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


class LivePathTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.HTTPServer(("127.0.0.1", 0), StubHandler)
        cls.url = "http://127.0.0.1:%d/graphql" % cls.server.server_port
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def test_two_pages_are_merged_and_relations_are_deduplicated(self):
        os.environ["LINEAR_API_KEY"] = "stub-key"
        try:
            data = ld.fetch_live("0123456789ab", self.url)
        finally:
            del os.environ["LINEAR_API_KEY"]
        self.assertEqual([i["identifier"] for i in data["issues"]], ["S-1", "S-2"])
        blocks = [r for r in data["relations"] if r["type"] == "blocks"]
        self.assertEqual(len([r for r in blocks if (r["from"], r["to"]) == ("S-1", "S-2")]), 1)
        self.assertIn({"type": "blocks", "from": "OUT-9", "to": "S-2"}, blocks)
        self.assertEqual(data["external"]["OUT-9"], "Outside")
        self.assertEqual(set(StubHandler.seen_auth), {"stub-key"})
        self.assertEqual(StubHandler.seen_external_ids, [["uuid-out-9"]])
        self.assertEqual(data["external_labels"]["OUT-9"], [{"name": "Technical task", "group": "Type"}])
        self.assertNotIn("S-1", data["external"])

    def test_query_stays_far_below_the_complexity_limit(self):
        sizes = [int(n) for n in re.findall(r"first: (\d+)", ld.QUERY_ISSUES)]
        self.assertEqual(len(sizes), 4)  # issues, labels, relations, inverseRelations
        self.assertLessEqual(sizes[0] * (1 + sum(sizes[1:])), 5000)  # Linear rejects above 10000
        ext = [int(n) for n in re.findall(r"first: (\d+)", ld.QUERY_EXTERNAL_LABELS)]
        self.assertLessEqual(ext[0] * (1 + ext[1]), 5000)


class CardAndLegendTests(unittest.TestCase):
    def svg(self, path=DEMO, **kw):
        data = load(path)
        return ld.render_svg(data, ld.build_graph(data, kw.get("related", False), kw.get("external", "drop")),
                             "acme", False)

    def legend(self, svg_text):
        doc = minidom.parseString(svg_text)
        g = [g for g in doc.getElementsByTagName("g") if g.getAttribute("class") == "legend"][0]
        return [t.firstChild.data for t in g.getElementsByTagName("text")]

    def test_every_state_drawn_is_in_the_legend_with_its_name(self):
        for path, kw in ((DEMO, {"external": "show", "related": True}), (CYCLE, {}), (PASS, {"external": "show"})):
            data = load(path)
            legend = self.legend(self.svg(path, **kw))
            graph = ld.build_graph(data, kw.get("related", False), kw.get("external", "drop"))
            for n in list(graph["nodes"].values()) + [dict(i, external=False) for i in data["issues"]
                                                      if i["identifier"] in graph["isolated"]]:
                kind, _, name = ld.state_look(n)
                self.assertIn("outside the project (hatched)" if kind == "ext" else name, legend, (path, n))

    def test_legend_names_only_what_is_drawn(self):
        legend = self.legend(self.svg(CYCLE))
        self.assertIn("link closing a cycle", legend)
        self.assertNotIn("related (dotted)", legend)
        self.assertNotIn("Triage", legend)
        self.assertNotIn("outside the project (hatched)", legend)
        legend = self.legend(self.svg(related=True, external="show"))
        self.assertIn("related (dotted)", legend)
        self.assertIn("In Review", legend)
        self.assertIn("outside the project (hatched)", legend)

    def test_colour_comes_from_linear_then_from_the_type(self):
        self.assertEqual(ld.state_look({"state": "started", "state_name": "In Review", "state_color": "#26b37a"}),
                         ("started", "#26b37a", "In Review"))
        self.assertEqual(ld.state_look({"state": "completed"}), ("completed", "#5e6ad2", "Done"))
        self.assertEqual(ld.state_look({"state": "backlog", "state_color": "red;}<script>"})[1], "#bec2c8")
        self.assertEqual(ld.state_look({"external": True}), ("ext", None, None))

    def test_outline_and_icon_follow_the_state_type(self):
        self.assertIn(".backlog .box { stroke-dasharray", ld.STYLE)
        self.assertNotIn("dasharray", ld.STYLE.split(".ext .box")[1].split("}")[0])
        self.assertIn("stroke-dasharray:2 1.7", ld.state_glyph("backlog", "#bec2c8", 0, 0))
        self.assertIn(" A", ld.state_glyph("started", "#f2c94c", 0, 0))
        self.assertIn("l2.2 2.2", ld.state_glyph("completed", "#5e6ad2", 0, 0))
        self.assertIn("l-5 5", ld.state_glyph("canceled", "#95a2b3", 0, 0))

    def test_card_is_tinted_with_the_state_colour(self):
        text = self.svg()
        self.assertIn('style="stroke:#26b37a"', text)
        self.assertIn('style="fill:#26b37a"', text)

    def test_external_box_is_hatched_and_tagged(self):
        text = self.svg(external="show")
        self.assertIn('<pattern id="hatch"', text)
        self.assertIn(">external<", text)

    def test_card_shows_type_labels_state_assignee_milestone(self):
        text = self.svg()
        self.assertIn(">In Progress · Sam K. · M1 · Payments on…<", text)
        self.assertIn("Milestone: M1 · Payments on staging", text)
        self.assertIn('<g class="tchip"><rect', text)
        self.assertIn(">repo/backend<", text)
        tips = [t.firstChild.data for t in minidom.parseString(text).getElementsByTagName("title")]
        tip = [t for t in tips if t.startswith("DEMO-3:")][0]
        self.assertIn("Type: Technical task", tip)
        self.assertIn("Labels: repo/backend, database, performance", tip)

    def test_too_many_chips_end_with_a_count(self):
        chips = ld.fit_chips(["a-rather-long-label-%d" % i for i in range(6)], 250)
        self.assertEqual(chips[-1][0], None)
        self.assertEqual(chips[-1][1], "+%d" % (6 - len(chips) + 1))
        self.assertLessEqual(sum(w for _, _, w in chips) + 4 * (len(chips) - 1), 250)

    def test_unknown_state_type_is_other(self):
        self.assertEqual(ld.state_kind({"external": False, "state": "paused"}), "other")
        self.assertEqual(ld.state_kind({"external": False, "state": "triage"}), "triage")


PASS = os.path.join(HERE, "fixtures", "linear-deps-types-pass.json")
FAIL = os.path.join(HERE, "fixtures", "linear-deps-types-fail.json")


class ExportTests(unittest.TestCase):
    def setUp(self):
        self.g = ld.build_export(load(PASS), URL, "acme")
        self.by_id = {n["identifier"]: n for n in self.g["nodes"]}

    def test_shape(self):
        self.assertEqual(self.g["format"], "linear-deps/1")
        self.assertEqual(self.g["project"], {"name": "Invitations lot (made up)", "url": URL})
        n = self.by_id["INV-3"]
        self.assertEqual(n["url"], "https://linear.app/acme/issue/INV-3")
        self.assertEqual(n["type"], "Proof")
        self.assertEqual(n["milestone"], "Staging: invitations")
        self.assertEqual(n["blocked_by"], ["INV-1", "INV-2"])
        self.assertEqual(self.by_id["INV-1"]["blocks"], ["INV-3"])
        self.assertEqual(set(n), {"identifier", "title", "url", "external", "state", "state_name", "state_color", "assignee", "parent", "milestone",
                                  "type", "labels", "blocked_by", "blocks"})
        json.dumps(self.g)  # serializable as is

    def test_blocks_and_inverse_blocked_by_are_one_edge(self):
        inv1_inv3 = [e for e in self.g["edges"] if {e["from"], e["to"]} == {"INV-1", "INV-3"}]
        self.assertEqual(inv1_inv3, [{"from": "INV-1", "to": "INV-3", "type": "blocks"}])

    def test_related_in_both_directions_is_one_edge(self):
        rel = [e for e in self.g["edges"] if e["type"] == "related"]
        self.assertEqual(rel, [{"from": "INV-1", "to": "INV-5", "type": "related"}])

    def test_outside_issues_are_kept_with_their_type(self):
        out = self.by_id["CORE-9"]
        self.assertTrue(out["external"])
        self.assertEqual(out["type"], "Technical task")
        self.assertEqual(out["title"], "Shared token service")

    def test_type_falls_back_to_a_bare_label_name(self):
        self.assertEqual(self.by_id["INV-4"]["type"], "Proof")
        self.assertEqual(self.by_id["INV-4"]["labels"], [{"name": "proof", "group": None}])

    def test_no_dependency_counts_blocking_links_only(self):
        self.assertEqual(self.g["no_dependency"], ["INV-5"])

    def test_cycles_are_whole_loops(self):
        g = ld.build_export(load(CYCLE), URL, "acme")
        self.assertEqual(g["cycles"], [["X-1", "X-2", "X-3"]])
        self.assertEqual(ld.build_export(load(DEMO), URL, "acme")["cycles"], [])

    def test_old_fixtures_without_labels_give_no_type(self):
        g = ld.build_export(load(CYCLE), URL, "acme")
        self.assertTrue(all(n["type"] is None for n in g["nodes"]))

    def test_cli_writes_svg_and_json(self):
        with tempfile.TemporaryDirectory() as d:
            svg, js = os.path.join(d, "g.svg"), os.path.join(d, "g.json")
            res = run_cli(URL, "--from-json", PASS, "-o", svg, "--json-out", js)
            self.assertEqual(res.returncode, 0, res.stderr)
            self.assertTrue(os.path.exists(svg))
            self.assertEqual(load(js), json.loads(json.dumps(self.g)))


class CheckTests(unittest.TestCase):
    def export(self, fixture, d):
        path = os.path.join(d, "g.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(ld.build_export(load(fixture), URL, "acme"), fh)
        return path

    def test_every_proof_blocked_by_dev_work_passes(self):
        with tempfile.TemporaryDirectory() as d:
            res = run_cli("check", self.export(PASS, d), "--type", "Proof",
                          "--blocked-by", "Technical task,Feature", "--blocked-by", "Improvement")
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertIn("2 Proof issue(s) checked", res.stdout)
        self.assertIn("2 ok, 0 fail, 0 unknown", res.stdout)

    def test_violations_are_listed_with_their_links(self):
        with tempfile.TemporaryDirectory() as d:
            res = run_cli("check", self.export(FAIL, d), "--type", "proof", "--blocked-by", "technical-task,Feature")
        self.assertEqual(res.returncode, 1)
        lines = res.stdout.splitlines()
        self.assertIn("FAIL     INV-4  https://linear.app/acme/issue/INV-4  [unstarted] Accept link works on staging"
                      "  blocked by INV-5 (Question)", lines)
        self.assertTrue(any(l.startswith("FAIL     INV-6") and l.endswith("no blocker") for l in lines))
        self.assertTrue(any(l.startswith("UNKNOWN  INV-7") and "OUT-1 (type unknown)" in l for l in lines))
        self.assertFalse(any("INV-3" in l for l in lines[:-1]))
        self.assertIn("4 proof issue(s) checked against technical-task / Feature: 1 ok, 2 fail, 1 unknown", lines)

    def test_open_only_skips_closed_issues(self):
        g = ld.build_export(load(FAIL), URL, "acme")
        checked, failures, unknown = ld.check_types(g, "Proof", ["Feature"], open_only=True)
        self.assertEqual([n["identifier"] for n in failures], ["INV-4"])
        self.assertEqual(len(checked), 3)

    def test_absent_type_is_reported(self):
        with tempfile.TemporaryDirectory() as d:
            res = run_cli("check", self.export(PASS, d), "--type", "Bug", "--blocked-by", "Feature")
        self.assertEqual(res.returncode, 0)
        self.assertIn("no issue of type 'Bug'; types present: Feature, Proof, Question, Technical task", res.stderr)


if __name__ == "__main__":
    unittest.main()
