"""Tests for scripts/linear_serve.py: the filters, the project cache and the local HTTP server.

Run through run-linear-deps-in-docker.sh. No network: the Linear fetch is replaced by a fixture.
"""
import http.client
import http.server
import json
import os
import re
import sys
import threading
import unittest
import xml.dom.minidom as minidom

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "scripts"))
import linear_deps as ld  # noqa: E402
import linear_serve as ls  # noqa: E402

MILESTONES = os.path.join(HERE, "fixtures", "linear-deps-milestones.json")


def load():
    with open(MILESTONES, encoding="utf-8") as fh:
        return json.load(fh)


def labelled():
    data = load()
    for n, issue in enumerate(data["issues"]):
        issue["labels"] = [{"name": "api" if n % 2 else "ui", "group": "Area"}]
        issue["priority"] = n % 5                      # 0 none, 1 urgent ... 4 low
        issue["priority_name"] = ld.PRIORITY_NAMES[n % 5]
    return data


class FilterTest(unittest.TestCase):
    def test_no_filter_keeps_everything(self):
        data = load()
        self.assertEqual(ls.filter_data(data, None, None)["issues"], data["issues"])

    def test_milestone_filter_keeps_only_its_issues(self):
        out = ls.filter_data(load(), {"Staging"}, None)
        self.assertTrue(out["issues"])
        self.assertEqual({i["milestone"] for i in out["issues"]}, {"Staging"})

    def test_empty_name_selects_issues_without_milestone(self):
        out = ls.filter_data(load(), {""}, None)
        self.assertEqual([i["identifier"] for i in out["issues"]], ["MS-5", "MS-9"])

    def test_label_filter_is_any_of(self):
        data = labelled()
        out = ls.filter_data(data, None, {"api"})
        self.assertEqual({i["identifier"] for i in out["issues"]},
                         {i["identifier"] for n, i in enumerate(data["issues"]) if n % 2})
        both = ls.filter_data(data, None, {"api", "ui"})
        self.assertEqual(len(both["issues"]), len(data["issues"]))

    def test_a_link_to_a_filtered_out_issue_becomes_external(self):
        data = load()
        out = ls.filter_data(data, {"Staging"}, None)
        gone = {i["identifier"] for i in data["issues"]} - {i["identifier"] for i in out["issues"]}
        for r in out["relations"]:
            for end in (r["from"], r["to"]):
                if end in gone:
                    self.assertIn(end, out["external"])
        graph = ld.build_graph(out, False, "drop", bands=True)
        self.assertGreaterEqual(graph["dropped"], 0)

    def test_neighbors_add_the_issues_one_blocking_link_away(self):
        data = load()
        plain = ls.filter_data(data, {"Production"}, None)
        self.assertEqual({i["identifier"] for i in plain["issues"]}, {"MS-3", "MS-4", "MS-8"})
        near = ls.filter_data(data, {"Production"}, None, neighbors=True)
        self.assertEqual({i["identifier"] for i in near["issues"]}, {"MS-3", "MS-4", "MS-6", "MS-8"})
        pairs = {(r["from"], r["to"]) for r in near["relations"]}
        self.assertIn(("MS-3", "MS-6"), pairs)          # seed to neighbor: kept
        self.assertNotIn(("MS-2", "MS-5"), pairs)       # neither end is a seed: left out

    def test_priority_filter_keeps_only_the_ticked_priorities(self):
        data = labelled()
        out = ls.filter_data(data, None, None, priorities={1, 2})
        self.assertEqual({i["priority"] for i in out["issues"]}, {1, 2})
        self.assertEqual(len(ls.filter_data(data, None, None, priorities={0})["issues"]),
                         len([i for i in data["issues"] if i["priority"] == 0]))

    def test_facets_list_priorities_urgent_first_and_none_last(self):
        f = ls.facets(labelled())
        self.assertEqual([p["value"] for p in f["priorities"]], [1, 2, 3, 4, 0])
        self.assertEqual(f["priorities"][0]["name"], "Urgent")
        self.assertEqual(sum(p["count"] for p in f["priorities"]), len(load()["issues"]))

    def test_issues_without_priority_data_count_as_none(self):
        f = ls.facets(load())                          # the fixture predates priorities
        self.assertEqual([p["value"] for p in f["priorities"]], [0])

    def test_priority_tints_the_card_background(self):
        data = labelled()
        graph = ld.build_graph(data, False, "drop", bands=True)
        svg = ld.render_svg(data, graph, "acme", False)
        minidom.parseString(svg)
        self.assertIn('id="pr1"', svg)                 # gradients are defined
        self.assertIn('fill="url(#pr1)"', svg)          # an urgent card uses it
        self.assertNotIn("url(#pr0)", svg)              # no priority: no tint
        self.assertIn("Priority: Urgent", svg)          # and the tooltip says it

    def test_neighbors_without_a_filter_change_nothing(self):
        data = load()
        self.assertEqual(ls.filter_data(data, None, None, neighbors=True)["issues"], data["issues"])

    def test_facets_follow_project_order_and_count(self):
        f = ls.facets(labelled())
        self.assertEqual([m["name"] for m in f["milestones"]][:2], ["Staging", "Production"])
        self.assertEqual(sum(m["count"] for m in f["milestones"]), len(load()["issues"]))
        self.assertEqual({l["name"] for l in f["labels"]}, {"api", "ui"})


class CliEntryTest(unittest.TestCase):
    def test_serve_starts_under_isolated_mode(self):
        """`python -I` drops the script dir from sys.path; serve must still find linear_serve."""
        import subprocess
        script = os.path.join(HERE, "..", "scripts", "linear_deps.py")
        env = {k: v for k, v in os.environ.items() if k != "LINEAR_API_KEY"}
        res = subprocess.run([sys.executable, "-I", script, "serve"], capture_output=True, text=True, env=env)
        self.assertNotIn("ModuleNotFoundError", res.stderr)
        self.assertIn("LINEAR_API_KEY", res.stderr)


class CacheTest(unittest.TestCase):
    def test_second_get_reuses_the_fetch_until_refresh(self):
        calls = []
        cache = ls.ProjectCache("x", fetch=lambda slug: calls.append(slug) or load())
        cache.get("p")
        cache.get("p")
        self.assertEqual(calls, ["p"])
        cache.get("p", refresh=True)
        self.assertEqual(calls, ["p", "p"])


class ServerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        ls.Handler.cache = ls.ProjectCache("x", fetch=lambda slug: labelled())
        ls.Handler.workspace = "acme"
        cls.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), ls.Handler)
        cls.port = cls.srv.server_address[1]
        ls.Handler.allowed_hosts = ("localhost:%d" % cls.port, "127.0.0.1:%d" % cls.port)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()
        cls.srv.server_close()

    def get(self, path, host=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port)
        conn.request("GET", path, headers={"Host": host or "127.0.0.1:%d" % self.port})
        r = conn.getresponse()
        return r.status, r.getheader("Content-Type"), r.read().decode("utf-8")

    def test_page_is_served(self):
        status, ctype, body = self.get("/")
        self.assertEqual(status, 200)
        self.assertIn("text/html", ctype)
        self.assertIn("graph.svg", body)

    def test_foreign_host_header_is_refused(self):
        self.assertEqual(self.get("/", host="evil.example")[0], 403)

    def test_facets_endpoint(self):
        status, _, body = self.get("/api/facets?project=p")
        self.assertEqual(status, 200)
        out = json.loads(body)
        self.assertEqual(out["issues"], len(load()["issues"]))
        self.assertTrue(out["milestones"] and out["labels"])

    def test_graph_is_a_wellformed_svg_and_filters_apply(self):
        status, ctype, full = self.get("/graph.svg?project=p")
        self.assertEqual((status, ctype), (200, "image/svg+xml"))
        minidom.parseString(full)
        _, _, one = self.get("/graph.svg?project=p&milestone=Production")
        minidom.parseString(one)
        self.assertIn("MS-3", one)
        self.assertNotIn('data-id="MS-1"', one)
        self.assertIn('data-id="MS-1"', full)

    def test_graph_priority_param_filters(self):
        _, _, svg = self.get("/graph.svg?project=p&priority=1&neighbors=0")
        minidom.parseString(svg)
        ids = set(re.findall(r'data-id="([^"]+)"', svg))
        urgent = {i["identifier"] for i in labelled()["issues"] if i["priority"] == 1}
        self.assertTrue(urgent)
        self.assertEqual(ids, urgent)

    def test_graph_requires_a_project(self):
        self.assertEqual(self.get("/graph.svg")[0], 400)

    def test_unknown_path_is_404(self):
        self.assertEqual(self.get("/nope")[0], 404)

    def test_api_trouble_becomes_a_502_not_a_crash(self):
        def boom(slug):
            raise SystemExit("error: Linear API answered HTTP 401")
        saved = ls.Handler.cache
        ls.Handler.cache = ls.ProjectCache("x", fetch=boom)
        try:
            status, _, body = self.get("/api/facets?project=p")
        finally:
            ls.Handler.cache = saved
        self.assertEqual(status, 502)
        self.assertIn("401", body)

    def test_projects_endpoint_lists_active_first(self):
        pages = {"projects": {"pageInfo": {"hasNextPage": False, "endCursor": None}, "nodes": [
            {"name": "Old", "slugId": "aa", "url": "https://linear.app/acme/project/old-aa", "state": "completed"},
            {"name": "Live", "slugId": "bb", "url": "https://linear.app/acme/project/live-bb", "state": "started"}]}}
        saved_gql, saved_key = ld.gql, os.environ.get("LINEAR_API_KEY")
        ld.gql = lambda api, key, q, v: pages
        os.environ["LINEAR_API_KEY"] = "k"
        try:
            status, _, body = self.get("/api/projects")
        finally:
            ld.gql = saved_gql
            if saved_key is None:
                del os.environ["LINEAR_API_KEY"]
            else:
                os.environ["LINEAR_API_KEY"] = saved_key
        self.assertEqual(status, 200)
        self.assertEqual([p["slug"] for p in json.loads(body)], ["bb", "aa"])


if __name__ == "__main__":
    unittest.main()
