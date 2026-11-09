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
        elif "issues(first" in q:
            page2 = v.get("after") == "cursor-1"
            if not page2:
                nodes = [self.node("S-1", [{"type": "blocks", "relatedIssue": {"identifier": "S-2", "title": "Title S-2"}}], [])]
            else:
                nodes = [self.node("S-2", [], [{"type": "blocks", "issue": {"identifier": "S-1", "title": "Title S-1"}},
                                              {"type": "blocks", "issue": {"identifier": "OUT-9", "title": "Outside"}}])]
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

    def test_query_stays_far_below_the_complexity_limit(self):
        sizes = [int(n) for n in re.findall(r"first: (\d+)", ld.QUERY_ISSUES)]
        self.assertEqual(len(sizes), 3)  # issues, relations, inverseRelations
        self.assertLessEqual(sizes[0] * (sizes[1] + sizes[2]), 5000)  # Linear rejects above 10000


if __name__ == "__main__":
    unittest.main()
