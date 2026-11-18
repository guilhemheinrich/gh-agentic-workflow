"""linear_sync.py: keeps a linear_store.Store fresh with a differential pull.

Three kinds of pull, all idempotent (every write is an upsert):

* backfill  : the first time a project is wanted, read all of it (issues, milestones, labels, links).
* delta     : every tick, ask Linear for the issues updated since a per-team watermark, archived ones
              included, and apply those that belong to a tracked project or are already stored (an
              issue moved out of a tracked project comes back with its new project and leaves the graph).
* reconcile : every K ticks and on the page's Refresh, re-read a whole project. This is the backstop
              for what a delta cannot see: Linear's `issueRelations` has no `updatedAt` filter, so a link
              added or removed without touching either issue stays stale until then; and an issue that was
              deleted (not archived) never comes back in a delta, so it is found by comparing id sets.

The watermark is the highest server `updatedAt` seen, never the local clock, and it only moves once every
page of a pull is applied. The one exception is the very first watermark of a team, taken from the local
clock minus five minutes: the backfill that follows heals any skew.
"""
import datetime as dt
import threading
import time

import linear_deps as ld

PAGE = 25            # issues per page: same size as the CLI's fetch, to stay under the complexity limit
OVERLAP_SECONDS = 5  # re-read this much before the watermark; upserts make the repeat harmless
FIRST_WATERMARK_BACK = 300
IDS_PAGE = 50

ISSUE_NODE = """
        id identifier title priority priorityLabel description createdAt updatedAt archivedAt
        team { id key name }
        project { id slugId }
        projectMilestone { id name sortOrder targetDate }
        state { id name type color }
        assignee { id name displayName }
        parent { id identifier }
        labels(first: 20) { nodes { id name color parent { id name } } }
        relations(first: %d) {
          pageInfo { hasNextPage }
          nodes { id type createdAt updatedAt relatedIssue { id identifier title } }
        }
        inverseRelations(first: %d) {
          pageInfo { hasNextPage }
          nodes { id type createdAt updatedAt issue { id identifier title } }
        }""" % (PAGE, PAGE)

PROJECT_NODE = """
    id slugId name url state updatedAt archivedAt
    lead { id }
    teams { nodes { id key name } }
    members(first: 100) { nodes { id name displayName } }
    projectMilestones(first: 100) { nodes { id name sortOrder targetDate } }"""

Q_PROJECT_BY_SLUG = """
query($slug: String!) { projects(filter: {slugId: {eq: $slug}}, first: 1, includeArchived: true) {
  nodes {%s} } }""" % PROJECT_NODE
Q_PROJECT_BY_ID = "query($id: String!) { project(id: $id) {%s} }" % PROJECT_NODE
Q_PROJECT_ISSUES = """
query($id: String!, $after: String) { project(id: $id) {
  issues(first: %d, after: $after) { pageInfo { hasNextPage endCursor } nodes {%s} } } }""" % (PAGE, ISSUE_NODE)
Q_DELTA = """
query($teams: [ID!], $since: DateTimeOrDuration, $after: String) {
  issues(first: %d, after: $after, includeArchived: true, orderBy: updatedAt,
         filter: {team: {id: {in: $teams}}, updatedAt: {gt: $since}}) {
    pageInfo { hasNextPage endCursor } nodes {%s} } }""" % (PAGE, ISSUE_NODE)
Q_BY_IDS = """
query($ids: [ID!]) { issues(first: %d, includeArchived: true, filter: {id: {in: $ids}}) {
  nodes {%s} } }""" % (IDS_PAGE, ISSUE_NODE)


def iso(ts):
    return ts.strftime("%Y-%m-%dT%H:%M:%S.000Z")


def minus_seconds(stamp, seconds):
    """`stamp` (Linear's ISO UTC) moved back by `seconds`."""
    t = dt.datetime.strptime(stamp[:19], "%Y-%m-%dT%H:%M:%S") - dt.timedelta(seconds=seconds)
    return iso(t)


class Syncer:
    def __init__(self, store, api_url, interval=60, full_every=30, gql=None):
        self.store, self.api_url = store, api_url
        self.interval, self.full_every = interval, full_every
        self.gql = gql or self._gql
        self.lock = threading.RLock()     # one pull at a time: the sync is the store's only writer
        self.ticks = 0
        self.stop = threading.Event()
        self.thread = None

    def _gql(self, query, variables):
        import os
        key = os.environ.get("LINEAR_API_KEY", "").strip()
        if not key:
            raise SystemExit("error: LINEAR_API_KEY is not set")
        return ld.gql(self.api_url, key, query, variables)

    # ---- the three pulls ----------------------------------------------------------------------

    def ensure(self, slug):
        """Make sure the project is stored and tracked; the first call backfills it. Returns its row."""
        with self.lock:
            row = self.store.project_row(slug)
            if row is None or not row["tracked"] or not row["synced_at"]:
                self.backfill(slug)
                row = self.store.project_row(slug)
            return row

    def backfill(self, slug):
        """Read a whole project and store it (also the body of a reconcile)."""
        with self.lock:
            started = time.time()
            node = self._read_project(slug)
            self.store.apply_project(node, tracked=True)
            seen, after = set(), None
            while True:
                page = self.gql(Q_PROJECT_ISSUES, {"id": node["id"], "after": after})["project"]["issues"]
                for n in page["nodes"]:
                    self.store.apply_issue(n)
                    seen.add(n["id"])
                if not page["pageInfo"]["hasNextPage"]:
                    break
                after = page["pageInfo"]["endCursor"]
            # Issues we stored for this project that the listing no longer returns: moved, archived or deleted.
            for chunk in _chunks(sorted(self.store.issue_ids(node["id"]) - seen), IDS_PAGE):
                found = {n["id"]: n for n in self.gql(Q_BY_IDS, {"ids": chunk})["issues"]["nodes"]}
                for iid in chunk:
                    if iid in found:
                        self.store.apply_issue(found[iid])
                    else:
                        self.store.delete_issue(iid)
            self._fill_externals(node["id"])
            now = iso(dt.datetime.now(dt.timezone.utc))
            self.store.touch_project(node["id"], now)
            self.store.set_state("project:" + node["slugId"], last_run_at=now, last_full_at=now, last_error=None)
            for team_id in self.store.project_teams(node["id"]):
                if not self.store.get_state("delta:" + team_id).get("cursor"):
                    self.store.set_state("delta:" + team_id, cursor=iso(
                        dt.datetime.fromtimestamp(started - FIRST_WATERMARK_BACK, dt.timezone.utc)))
            return node["slugId"]

    def delta(self):
        """One differential tick over the teams of the tracked projects. Returns how many issues it applied."""
        applied = 0
        with self.lock:
            tracked = self.store.tracked_projects()
            if not tracked:
                return 0
            tracked_ids = {p["id"] for p in tracked}
            teams = sorted({t for p in tracked for t in self.store.project_teams(p["id"])})
            for team_id in teams:
                state = self.store.get_state("delta:" + team_id)
                cursor = state.get("cursor")
                if not cursor:
                    continue
                since, high, after = minus_seconds(cursor, OVERLAP_SECONDS), cursor, None
                while True:
                    page = self.gql(Q_DELTA, {"teams": [team_id], "since": since, "after": after})["issues"]
                    for n in page["nodes"]:
                        high = max(high, n["updatedAt"])
                        if (n.get("project") or {}).get("id") in tracked_ids or self.store.has_issue(n["id"]):
                            self.store.apply_issue(n)
                            applied += 1
                    if not page["pageInfo"]["hasNextPage"]:
                        break
                    after = page["pageInfo"]["endCursor"]
                self.store.set_state("delta:" + team_id, cursor=high, last_run_at=iso(dt.datetime.now(dt.timezone.utc)))
            now = iso(dt.datetime.now(dt.timezone.utc))
            for p in tracked:
                self._fill_externals(p["id"])
                self.store.touch_project(p["id"], now)
        return applied

    def tick(self):
        """One scheduled round: a delta, and every `full_every`-th round a reconcile of each tracked project."""
        self.ticks += 1
        try:
            if self.full_every and self.ticks % self.full_every == 0:
                for p in self.store.tracked_projects():
                    self.backfill(p["slug_id"])
            else:
                self.delta()
        except SystemExit as exc:      # the API is down or the key is wrong: say so on the page, try again next tick
            for p in self.store.tracked_projects():
                self.store.set_state("project:" + p["slug_id"], last_error=str(exc))

    def start(self):
        if self.interval <= 0 or self.thread:
            return
        def loop():
            while not self.stop.wait(self.interval):
                self.tick()
        self.thread = threading.Thread(target=loop, name="linear-sync", daemon=True)
        self.thread.start()

    # ---- helpers ------------------------------------------------------------------------------

    def _read_project(self, slug):
        nodes = self.gql(Q_PROJECT_BY_SLUG, {"slug": slug})["projects"]["nodes"]
        node = nodes[0] if nodes else self.gql(Q_PROJECT_BY_ID, {"id": slug}).get("project")
        if node is None:
            raise SystemExit("error: project not found for slug id %r" % slug)
        return node

    def _fill_externals(self, project_id):
        """Issues linked to the project but living elsewhere are stored as stubs (id, identifier, title):
        fetch them in full once, so their labels (the ticket type) are known."""
        rows = self.store.conn().execute(
            "SELECT DISTINCT o.id FROM issue_relations r JOIN issues i ON i.id IN (r.issue_id, r.related_issue_id) "
            "JOIN issues o ON o.id IN (r.issue_id, r.related_issue_id) AND o.id != i.id "
            "WHERE i.project_id=? AND o.partial=1", (project_id,)).fetchall()
        for chunk in _chunks(sorted(r["id"] for r in rows), IDS_PAGE):
            for n in self.gql(Q_BY_IDS, {"ids": chunk})["issues"]["nodes"]:
                self.store.apply_issue(n, relations=False)


def _chunks(items, size):
    for start in range(0, len(items), size):
        yield items[start:start + size]
