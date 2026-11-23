"""Tests for scripts/linear_store.py and scripts/linear_sync.py against a fake Linear (no network).

FakeLinear models the parts of Linear the sync relies on: server-side issues and links, project paging,
a delta query filtered on team and updatedAt (archived included), lookups by id, and the fact that
removing a link does not touch either issue's updatedAt.
"""
import os
import sys
import tempfile
import unittest
import xml.dom.minidom as minidom

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "scripts"))
import linear_deps as ld  # noqa: E402
import linear_store as lstore  # noqa: E402
import linear_sync as lsync  # noqa: E402

T1 = {"id": "t1", "key": "TT", "name": "Tiger"}
P1 = {"id": "p1", "slugId": "slug1", "name": "Tracked", "url": "https://linear.app/acme/project/tracked-slug1",
      "state": "started", "updatedAt": "2026-01-01T00:00:00.000Z", "archivedAt": None, "lead": None,
      "teams": {"nodes": [T1]}, "members": {"nodes": [{"id": "u1", "name": "a@x", "displayName": "ann"}]},
      "projectMilestones": {"nodes": [{"id": "m1", "name": "Staging", "sortOrder": 1, "targetDate": None},
                                      {"id": "m2", "name": "Prod", "sortOrder": 2, "targetDate": None}]}}
STATE = {"id": "s1", "name": "Todo", "type": "unstarted", "color": "#999"}
BASE = "2026-03-01T10:00:00.000Z"
WATERMARK = "2026-03-01T12:00:00.000Z"


def issue(iid, ident, title, project="p1", ms=None, updated=BASE, labels=(), archived=None, parent=None,
          priority=0, state=STATE, desc=None):
    return {"id": iid, "identifier": ident, "title": title, "priority": priority, "priorityLabel": ["No priority", "Urgent"][priority],
            "description": desc, "createdAt": "2026-01-01T00:00:00.000Z", "updatedAt": updated, "archivedAt": archived,
            "team": T1, "project": {"id": project, "slugId": "x"} if project else None,
            "projectMilestone": {"id": ms, "name": {"m1": "Staging", "m2": "Prod"}[ms], "sortOrder": int(ms[1:]), "targetDate": None} if ms else None,
            "state": state, "assignee": {"id": "u1", "name": "a@x", "displayName": "ann"}, "parent": parent,
            "labels": {"nodes": [{"id": "l-" + n, "name": n, "color": "#111",
                                  "parent": {"id": "g-" + g, "name": g} if g else None} for n, g in labels]}}


class FakeLinear:
    def __init__(self, issues, rels=()):
        self.issues = {i["id"]: i for i in issues}
        self.rels = list(rels)        # (id, type, from issue id, to issue id)
        self.project = P1
        self.calls = []
        self.since = []               # the `since` of every delta page asked for
        self.fail = False

    def ref(self, iid):
        i = self.issues[iid]
        return {"id": iid, "identifier": i["identifier"], "title": i["title"]}

    def full(self, iid):
        n = dict(self.issues[iid])
        out = [dict(id=r[0], type=r[1], createdAt=BASE, updatedAt=BASE, relatedIssue=self.ref(r[3]))
               for r in self.rels if r[2] == iid]
        inc = [dict(id=r[0], type=r[1], createdAt=BASE, updatedAt=BASE, issue=self.ref(r[2]))
               for r in self.rels if r[3] == iid]
        n["relations"] = {"pageInfo": {"hasNextPage": False}, "nodes": out}
        n["inverseRelations"] = {"pageInfo": {"hasNextPage": False}, "nodes": inc}
        return n

    @staticmethod
    def page(nodes, v, size=2):
        start = int(v.get("after") or 0)
        end = start + size
        return {"pageInfo": {"hasNextPage": end < len(nodes), "endCursor": str(end)}, "nodes": nodes[start:end]}

    def __call__(self, query, v):
        if self.fail:
            raise SystemExit("error: Linear API answered HTTP 500")
        self.calls.append(query)
        if query is lsync.Q_PROJECT_BY_SLUG:
            return {"projects": {"nodes": [self.project]}}
        if query is lsync.Q_PROJECT_ISSUES:
            ids = [i for i, n in self.issues.items() if (n["project"] or {}).get("id") == v["id"] and not n["archivedAt"]]
            return {"project": {"issues": self.page([self.full(i) for i in ids], v)}}
        if query is lsync.Q_DELTA:
            self.since.append(v["since"])
            ids = sorted((i for i, n in self.issues.items() if n["updatedAt"] > v["since"]),
                         key=lambda i: self.issues[i]["updatedAt"], reverse=True)
            return {"issues": self.page([self.full(i) for i in ids], v)}
        if query is lsync.Q_BY_IDS:
            return {"issues": {"nodes": [self.full(i) for i in v["ids"] if i in self.issues]}}
        raise AssertionError("unexpected query")


def world():
    a = issue("a", "TT-1", "Schema", ms="m1", labels=[("Bug", "Type")], desc="# Context\nWhy now")
    b = issue("b", "TT-2", "Worker", ms="m2", priority=1, parent={"id": "a", "identifier": "TT-1"})
    ext = issue("x", "TT-9", "Elsewhere", project="other", labels=[("Proof", "Type")])
    return FakeLinear([a, b, ext], [("r1", "blocks", "a", "b"), ("r2", "blocks", "x", "b")])


class StoreTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.path = os.path.join(self.tmp, "c.sqlite")
        self.fake = world()
        self.store = lstore.Store(self.path)
        self.sync = lsync.Syncer(self.store, "x", interval=0, gql=self.fake)

    def pull(self):
        self.sync.ensure("slug1")
        self.store.set_state("delta:t1", cursor=WATERMARK)   # a known server watermark, after every BASE issue


class RoundTripTest(StoreTestCase):
    def test_backfill_returns_what_fetch_live_returns(self):
        self.pull()
        d = self.store.project_dict("slug1")
        self.assertEqual(d["project"], {"name": "Tracked", "milestones": ["Staging", "Prod"]})
        by = {i["identifier"]: i for i in d["issues"]}
        self.assertEqual(set(by), {"TT-1", "TT-2"})                # TT-9 lives in another project
        self.assertEqual(by["TT-1"]["labels"], [{"name": "Bug", "group": "Type"}])
        self.assertEqual((by["TT-1"]["state"], by["TT-1"]["state_name"], by["TT-1"]["assignee"]), ("unstarted", "Todo", "ann"))
        self.assertEqual(by["TT-1"]["body"]["sections"], ["Context"])
        self.assertEqual((by["TT-2"]["parent"], by["TT-2"]["milestone"], by["TT-2"]["priority"]), ("TT-1", "Prod", 1))
        self.assertEqual(d["relations"], [{"type": "blocks", "from": "TT-1", "to": "TT-2"},
                                          {"type": "blocks", "from": "TT-9", "to": "TT-2"}])
        self.assertEqual(d["external"], {"TT-9": "Elsewhere"})
        self.assertEqual(d["external_labels"], {"TT-9": [{"name": "Proof", "group": "Type"}]})

    def test_the_stored_project_renders_like_a_live_one(self):
        self.pull()
        d = self.store.project_dict("slug1")
        graph = ld.build_graph(d, False, "show", bands=True)
        minidom.parseString(ld.render_svg(d, graph, "acme", False))

    def test_the_cache_survives_a_restart(self):
        self.pull()
        before = self.store.project_dict("slug1")
        again = lstore.Store(self.path)                              # a new process opening the same file
        self.assertEqual(again.project_dict("slug1"), before)
        self.assertEqual([p["slug_id"] for p in again.tracked_projects()], ["slug1"])

    def test_the_association_tables_are_filled(self):
        self.pull()
        q = lambda sql: [tuple(r) for r in self.store.conn().execute(sql)]   # noqa: E731
        self.assertEqual(q("SELECT project_id, team_id FROM project_teams"), [("p1", "t1")])
        self.assertEqual(q("SELECT project_id, user_id FROM project_members"), [("p1", "u1")])
        self.assertEqual(q("SELECT issue_id, label_id FROM issue_labels ORDER BY 1"), [("a", "l-Bug"), ("x", "l-Proof")])
        self.assertEqual(q("SELECT id FROM labels WHERE id='g-Type'"), [("g-Type",)])    # the group is a label too
        self.assertEqual(q("SELECT count(*) FROM issue_relations"), [(2,)])

    def test_unknown_project_is_an_error(self):
        self.sync.gql = lambda q, v: {"projects": {"nodes": []}} if q is lsync.Q_PROJECT_BY_SLUG else {"project": None}
        with self.assertRaises(SystemExit):
            self.sync.ensure("nope")


class DeltaTest(StoreTestCase):
    def test_an_updated_issue_is_refreshed_and_the_watermark_is_the_server_time(self):
        self.pull()
        self.fake.issues["a"] = issue("a", "TT-1", "Schema (renamed)", ms="m1", updated="2026-03-02T08:00:00.000Z")
        self.assertEqual(self.sync.delta(), 1)
        titles = {i["identifier"]: i["title"] for i in self.store.project_dict("slug1")["issues"]}
        self.assertEqual(titles["TT-1"], "Schema (renamed)")
        self.assertEqual(self.store.get_state("delta:t1")["cursor"], "2026-03-02T08:00:00.000Z")

    def test_a_pull_reads_every_page_and_applies_overlap_before_the_watermark(self):
        self.pull()
        for n in range(5):                                           # 5 touched issues = 3 pages of 2
            self.fake.issues["a"] = dict(self.fake.issues["a"], updatedAt="2026-03-02T08:00:0%d.000Z" % n)
        extra = [issue("e%d" % n, "TT-%d" % (20 + n), "new", ms="m1", updated="2026-03-02T09:00:0%d.000Z" % n) for n in range(4)]
        for e in extra:
            self.fake.issues[e["id"]] = e
        self.assertEqual(self.sync.delta(), 5)                      # a + four new ones, all in tracked project p1
        self.assertEqual(self.fake.since[0], "2026-03-01T11:59:55.000Z")   # watermark minus five seconds
        self.assertEqual(len(self.fake.since), 3)
        self.assertEqual(self.store.get_state("delta:t1")["cursor"], "2026-03-02T09:00:03.000Z")

    def test_a_failed_pull_does_not_move_the_watermark_and_is_reported(self):
        self.pull()
        self.fake.issues["a"] = issue("a", "TT-1", "later", ms="m1", updated="2026-03-02T08:00:00.000Z")
        self.fake.fail = True
        self.sync.tick()
        self.assertEqual(self.store.get_state("delta:t1")["cursor"], WATERMARK)
        self.assertIn("500", self.store.get_state("project:slug1")["last_error"])
        self.fake.fail = False
        self.sync.tick()
        self.assertEqual(self.store.get_state("delta:t1")["cursor"], "2026-03-02T08:00:00.000Z")

    def test_an_issue_moved_out_of_the_project_leaves_the_graph(self):
        self.pull()
        self.fake.issues["b"] = issue("b", "TT-2", "Worker", project="other", updated="2026-03-02T08:00:00.000Z")
        self.sync.delta()
        self.assertEqual([i["identifier"] for i in self.store.project_dict("slug1")["issues"]], ["TT-1"])

    def test_an_archived_issue_leaves_the_graph(self):
        self.pull()
        self.fake.issues["b"] = issue("b", "TT-2", "Worker", ms="m2", updated="2026-03-02T08:00:00.000Z",
                                      archived="2026-03-02T08:00:00.000Z")
        self.sync.delta()
        self.assertEqual([i["identifier"] for i in self.store.project_dict("slug1")["issues"]], ["TT-1"])

    def test_an_issue_of_an_untracked_project_is_ignored(self):
        self.pull()
        self.fake.issues["z"] = issue("z", "TT-77", "stranger", project="untracked", updated="2026-03-02T08:00:00.000Z")
        self.assertEqual(self.sync.delta(), 0)
        self.assertFalse(self.store.has_issue("z"))

    def test_an_issue_moved_into_the_project_appears(self):
        self.pull()
        self.fake.issues["z"] = issue("z", "TT-77", "arrives", project="p1", ms="m1", updated="2026-03-02T08:00:00.000Z")
        self.sync.delta()
        self.assertIn("TT-77", [i["identifier"] for i in self.store.project_dict("slug1")["issues"]])

    def test_a_link_change_with_its_issue_is_picked_up(self):
        self.pull()
        self.fake.rels.append(("r3", "blocks", "b", "a"))
        self.fake.issues["a"] = dict(self.fake.issues["a"], updatedAt="2026-03-02T08:00:00.000Z")
        self.sync.delta()
        self.assertIn({"type": "blocks", "from": "TT-2", "to": "TT-1"}, self.store.project_dict("slug1")["relations"])


class ReconcileTest(StoreTestCase):
    def test_a_link_removed_without_touching_an_issue_survives_a_delta_but_not_a_reconcile(self):
        self.pull()
        self.fake.rels = [r for r in self.fake.rels if r[0] != "r1"]    # no updatedAt bump: the known blind spot
        self.sync.delta()
        self.assertIn({"type": "blocks", "from": "TT-1", "to": "TT-2"}, self.store.project_dict("slug1")["relations"])
        self.sync.backfill("slug1")
        self.assertNotIn({"type": "blocks", "from": "TT-1", "to": "TT-2"}, self.store.project_dict("slug1")["relations"])

    def test_a_deleted_issue_is_removed_by_a_reconcile(self):
        self.pull()
        del self.fake.issues["b"]
        self.fake.rels = []
        self.sync.backfill("slug1")
        self.assertFalse(self.store.has_issue("b"))
        d = self.store.project_dict("slug1")
        self.assertEqual([i["identifier"] for i in d["issues"]], ["TT-1"])
        self.assertEqual(d["relations"], [])

    def test_every_nth_tick_is_a_reconcile(self):
        self.pull()
        self.sync.full_every = 3
        self.fake.calls.clear()
        for _ in range(2):
            self.sync.tick()
        self.assertNotIn(lsync.Q_PROJECT_ISSUES, self.fake.calls)
        self.sync.tick()
        self.assertIn(lsync.Q_PROJECT_ISSUES, self.fake.calls)

    def test_refresh_hook_of_the_cache_reconciles(self):
        import linear_serve as ls
        cache = ls.ProjectCache("x", ttl=60, fetch=lambda slug: (self.sync.ensure(slug), self.store.project_dict(slug))[1],
                                on_refresh=self.sync.backfill)
        cache.get("slug1")
        self.fake.calls.clear()
        cache.get("slug1")
        self.assertEqual(self.fake.calls, [])                       # served from memory
        cache.get("slug1", refresh=True)
        self.assertIn(lsync.Q_PROJECT_ISSUES, self.fake.calls)


if __name__ == "__main__":
    unittest.main()
