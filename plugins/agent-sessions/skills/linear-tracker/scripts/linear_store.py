"""linear_store.py: a local SQLite cache of the Linear entities the dependency graph reads.

Standard library only. The schema follows Linear's own entities and association tables (teams, users,
workflow states, projects, milestones, labels, issues, and the issue-label, project-team,
project-member and issue-relation links), so a later consumer can join them the way Linear does.
Out of scope: comments, cycles, history, webhooks, schema migrations (the file is a cache: delete it
to start over). The API key is never stored.

`Store.project_dict(slug)` returns exactly what `linear_deps.fetch_live` returns, so the renderer and
the filters do not know whether the data came from the API or from this file.

Threading: one connection per thread, WAL mode, and every write goes through one lock, so the
background sync thread is the only writer in practice and the HTTP threads only read.
"""
import os
import sqlite3
import threading

import linear_deps as ld

SCHEMA = """
CREATE TABLE IF NOT EXISTS teams (
  id TEXT PRIMARY KEY, key TEXT, name TEXT);
CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY, name TEXT, display_name TEXT);
CREATE TABLE IF NOT EXISTS workflow_states (
  id TEXT PRIMARY KEY, team_id TEXT, name TEXT, type TEXT, color TEXT);
CREATE TABLE IF NOT EXISTS projects (
  id TEXT PRIMARY KEY, slug_id TEXT UNIQUE, name TEXT, url TEXT, state TEXT, lead_id TEXT,
  updated_at TEXT, archived_at TEXT,
  tracked INTEGER NOT NULL DEFAULT 0,   -- 1: kept fresh by the sync
  synced_at TEXT);                      -- last successful pull touching this project (ISO, UTC)
CREATE TABLE IF NOT EXISTS project_teams (
  project_id TEXT, team_id TEXT, PRIMARY KEY (project_id, team_id));
CREATE TABLE IF NOT EXISTS project_members (
  project_id TEXT, user_id TEXT, PRIMARY KEY (project_id, user_id));
CREATE TABLE IF NOT EXISTS milestones (
  id TEXT PRIMARY KEY, project_id TEXT, name TEXT, sort_order REAL, target_date TEXT);
CREATE TABLE IF NOT EXISTS labels (
  id TEXT PRIMARY KEY, name TEXT, color TEXT, parent_id TEXT);
CREATE TABLE IF NOT EXISTS issues (
  id TEXT PRIMARY KEY, identifier TEXT, title TEXT NOT NULL DEFAULT '',
  team_id TEXT, project_id TEXT, milestone_id TEXT, state_id TEXT, assignee_id TEXT, parent_id TEXT,
  description TEXT, priority INTEGER NOT NULL DEFAULT 0, priority_label TEXT,
  created_at TEXT, updated_at TEXT, archived_at TEXT,
  partial INTEGER NOT NULL DEFAULT 0);  -- 1: only seen as the end of a link (identifier and title)
CREATE INDEX IF NOT EXISTS issues_project ON issues(project_id);
CREATE INDEX IF NOT EXISTS issues_identifier ON issues(identifier);
CREATE TABLE IF NOT EXISTS issue_labels (
  issue_id TEXT, label_id TEXT, PRIMARY KEY (issue_id, label_id));
CREATE TABLE IF NOT EXISTS issue_relations (
  id TEXT PRIMARY KEY, issue_id TEXT, related_issue_id TEXT, type TEXT,
  created_at TEXT, updated_at TEXT);
CREATE INDEX IF NOT EXISTS relations_issue ON issue_relations(issue_id);
CREATE INDEX IF NOT EXISTS relations_related ON issue_relations(related_issue_id);
CREATE TABLE IF NOT EXISTS sync_state (
  scope TEXT PRIMARY KEY,   -- 'delta:<team id>' holds the watermark, 'project:<slug id>' the run status
  cursor TEXT, last_run_at TEXT, last_full_at TEXT, last_error TEXT);
"""


class Store:
    def __init__(self, path):
        self.path = path
        self.local = threading.local()
        self.lock = threading.RLock()
        if path != ":memory:":
            os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        with self.lock:
            self.conn().executescript(SCHEMA)

    def conn(self):
        c = getattr(self.local, "c", None)
        if c is None:
            c = sqlite3.connect(self.path, timeout=30)
            c.row_factory = sqlite3.Row
            if self.path != ":memory:":
                c.execute("PRAGMA journal_mode=WAL")
            self.local.c = c
        return c

    # ---- writes -------------------------------------------------------------------------------

    def apply_project(self, node, tracked=None):
        """Upsert a project node (id slugId name url state updatedAt archivedAt lead teams members milestones)."""
        c = self.conn()
        with self.lock, c:
            c.execute(
                "INSERT INTO projects(id, slug_id, name, url, state, lead_id, updated_at, archived_at) "
                "VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET slug_id=excluded.slug_id, "
                "name=excluded.name, url=excluded.url, state=excluded.state, lead_id=excluded.lead_id, "
                "updated_at=excluded.updated_at, archived_at=excluded.archived_at",
                (node["id"], node.get("slugId"), node["name"], node.get("url"), node.get("state"),
                 (node.get("lead") or {}).get("id"), node.get("updatedAt"), node.get("archivedAt")))
            if tracked is not None:
                c.execute("UPDATE projects SET tracked=? WHERE id=?", (1 if tracked else 0, node["id"]))
            if node.get("teams") is not None:
                c.execute("DELETE FROM project_teams WHERE project_id=?", (node["id"],))
                for t in (node["teams"] or {}).get("nodes", []):
                    self._team(c, t)
                    c.execute("INSERT OR IGNORE INTO project_teams VALUES(?,?)", (node["id"], t["id"]))
            if node.get("members") is not None:
                c.execute("DELETE FROM project_members WHERE project_id=?", (node["id"],))
                for u in (node["members"] or {}).get("nodes", []):
                    self._user(c, u)
                    c.execute("INSERT OR IGNORE INTO project_members VALUES(?,?)", (node["id"], u["id"]))
            if node.get("projectMilestones") is not None:
                keep = []
                for m in (node["projectMilestones"] or {}).get("nodes", []):
                    self._milestone(c, m, node["id"])
                    keep.append(m["id"])
                c.execute("DELETE FROM milestones WHERE project_id=? AND id NOT IN (%s)"
                          % ",".join("?" * len(keep)), [node["id"]] + keep)

    def apply_issue(self, n, relations=True):
        """Upsert one issue node and its label links; with `relations`, replace every link touching it
        (its own `relations` and `inverseRelations` are the complete list unless a page was truncated)."""
        c = self.conn()
        with self.lock, c:
            team, proj = n.get("team"), n.get("project")
            if team:
                self._team(c, team)
            state = n.get("state")
            if state:
                c.execute(
                    "INSERT INTO workflow_states(id, team_id, name, type, color) VALUES(?,?,?,?,?) "
                    "ON CONFLICT(id) DO UPDATE SET team_id=excluded.team_id, name=excluded.name, "
                    "type=excluded.type, color=excluded.color",
                    (state["id"], (team or {}).get("id"), state.get("name"), state.get("type"), state.get("color")))
            if n.get("assignee"):
                self._user(c, n["assignee"])
            ms = n.get("projectMilestone")
            if ms and proj:
                self._milestone(c, ms, proj["id"])
            par = n.get("parent")
            if par:
                self._stub(c, par)
            c.execute(
                "INSERT INTO issues(id, identifier, title, team_id, project_id, milestone_id, state_id, "
                "assignee_id, parent_id, description, priority, priority_label, created_at, updated_at, "
                "archived_at, partial) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,0) "
                "ON CONFLICT(id) DO UPDATE SET identifier=excluded.identifier, title=excluded.title, "
                "team_id=excluded.team_id, project_id=excluded.project_id, milestone_id=excluded.milestone_id, "
                "state_id=excluded.state_id, assignee_id=excluded.assignee_id, parent_id=excluded.parent_id, "
                "description=excluded.description, priority=excluded.priority, "
                "priority_label=excluded.priority_label, created_at=excluded.created_at, "
                "updated_at=excluded.updated_at, archived_at=excluded.archived_at, partial=0",
                (n["id"], n["identifier"], n["title"], (team or {}).get("id"), (proj or {}).get("id"),
                 (ms or {}).get("id"), (state or {}).get("id"), (n.get("assignee") or {}).get("id"),
                 (par or {}).get("id"), n.get("description"), n.get("priority") or 0, n.get("priorityLabel"),
                 n.get("createdAt"), n.get("updatedAt"), n.get("archivedAt")))
            if n.get("labels") is not None:
                c.execute("DELETE FROM issue_labels WHERE issue_id=?", (n["id"],))
                for l in n["labels"].get("nodes", []):
                    if l.get("parent"):
                        c.execute("INSERT INTO labels(id, name) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET "
                                  "name=excluded.name", (l["parent"]["id"], l["parent"]["name"]))
                    c.execute("INSERT INTO labels(id, name, color, parent_id) VALUES(?,?,?,?) "
                              "ON CONFLICT(id) DO UPDATE SET name=excluded.name, color=excluded.color, "
                              "parent_id=excluded.parent_id",
                              (l["id"], l["name"], l.get("color"), (l.get("parent") or {}).get("id")))
                    c.execute("INSERT OR IGNORE INTO issue_labels VALUES(?,?)", (n["id"], l["id"]))
            if not relations:
                return
            out, inc = n.get("relations") or {}, n.get("inverseRelations") or {}
            if (out.get("pageInfo") or {}).get("hasNextPage") or (inc.get("pageInfo") or {}).get("hasNextPage"):
                relations = False   # a truncated list cannot replace the stored one: only add what we saw
            if relations:
                c.execute("DELETE FROM issue_relations WHERE issue_id=? OR related_issue_id=?", (n["id"], n["id"]))
            for r in out.get("nodes", []):
                self._stub(c, r["relatedIssue"])
                self._relation(c, r, n["id"], r["relatedIssue"]["id"])
            for r in inc.get("nodes", []):
                self._stub(c, r["issue"])
                self._relation(c, r, r["issue"]["id"], n["id"])

    def delete_issue(self, issue_id):
        """The issue no longer exists on Linear (deleted, or trashed past retention)."""
        c = self.conn()
        with self.lock, c:
            c.execute("DELETE FROM issue_labels WHERE issue_id=?", (issue_id,))
            c.execute("DELETE FROM issue_relations WHERE issue_id=? OR related_issue_id=?", (issue_id, issue_id))
            c.execute("DELETE FROM issues WHERE id=?", (issue_id,))

    def set_state(self, scope, **fields):
        c = self.conn()
        with self.lock, c:
            c.execute("INSERT OR IGNORE INTO sync_state(scope) VALUES(?)", (scope,))
            for k, v in fields.items():
                assert k in ("cursor", "last_run_at", "last_full_at", "last_error")
                c.execute("UPDATE sync_state SET %s=? WHERE scope=?" % k, (v, scope))

    def touch_project(self, project_id, when):
        c = self.conn()
        with self.lock, c:
            c.execute("UPDATE projects SET synced_at=? WHERE id=?", (when, project_id))

    @staticmethod
    def _team(c, t):
        c.execute("INSERT INTO teams(id, key, name) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET "
                  "key=COALESCE(excluded.key, key), name=COALESCE(excluded.name, name)",
                  (t["id"], t.get("key"), t.get("name")))

    @staticmethod
    def _user(c, u):
        c.execute("INSERT INTO users(id, name, display_name) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET "
                  "name=COALESCE(excluded.name, name), display_name=COALESCE(excluded.display_name, display_name)",
                  (u["id"], u.get("name"), u.get("displayName")))

    @staticmethod
    def _milestone(c, m, project_id):
        c.execute("INSERT INTO milestones(id, project_id, name, sort_order, target_date) VALUES(?,?,?,?,?) "
                  "ON CONFLICT(id) DO UPDATE SET project_id=excluded.project_id, name=excluded.name, "
                  "sort_order=excluded.sort_order, target_date=excluded.target_date",
                  (m["id"], project_id, m["name"], m.get("sortOrder"), m.get("targetDate")))

    @staticmethod
    def _stub(c, i):
        """An issue only known by id, identifier and title: keep a row so links and parents can point at it."""
        c.execute("INSERT INTO issues(id, identifier, title, partial) VALUES(?,?,?,1) ON CONFLICT(id) DO UPDATE "
                  "SET identifier=excluded.identifier, title=excluded.title WHERE issues.partial=1",
                  (i["id"], i["identifier"], i.get("title") or ""))

    @staticmethod
    def _relation(c, r, from_id, to_id):
        c.execute("INSERT INTO issue_relations(id, issue_id, related_issue_id, type, created_at, updated_at) "
                  "VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET issue_id=excluded.issue_id, "
                  "related_issue_id=excluded.related_issue_id, type=excluded.type, updated_at=excluded.updated_at",
                  (r["id"], from_id, to_id, r["type"], r.get("createdAt"), r.get("updatedAt")))

    # ---- reads --------------------------------------------------------------------------------

    def get_state(self, scope):
        row = self.conn().execute("SELECT * FROM sync_state WHERE scope=?", (scope,)).fetchone()
        return dict(row) if row else {}

    def project_row(self, slug):
        row = self.conn().execute("SELECT * FROM projects WHERE slug_id=? OR id=?", (slug, slug)).fetchone()
        return dict(row) if row else None

    def tracked_projects(self):
        return [dict(r) for r in self.conn().execute("SELECT * FROM projects WHERE tracked=1 ORDER BY name")]

    def project_teams(self, project_id):
        return [r["team_id"] for r in self.conn().execute(
            "SELECT team_id FROM project_teams WHERE project_id=?", (project_id,))]

    def issue_ids(self, project_id):
        return {r["id"] for r in self.conn().execute(
            "SELECT id FROM issues WHERE project_id=? AND partial=0", (project_id,))}

    def has_issue(self, issue_id):
        return self.conn().execute("SELECT 1 FROM issues WHERE id=? AND partial=0", (issue_id,)).fetchone() is not None

    def project_dict(self, slug):
        """The project as `linear_deps.fetch_live` returns it, built from the stored rows."""
        c = self.conn()
        project = self.project_row(slug)
        if project is None:
            return None
        pid = project["id"]
        miles = [{"name": m["name"], "sortOrder": m["sort_order"], "targetDate": m["target_date"]}
                 for m in c.execute("SELECT * FROM milestones WHERE project_id=?", (pid,))]
        labels = {}
        for r in c.execute(
                "SELECT il.issue_id, l.name, p.name AS grp FROM issue_labels il JOIN labels l ON l.id=il.label_id "
                "LEFT JOIN labels p ON p.id=l.parent_id ORDER BY il.rowid"):
            labels.setdefault(r["issue_id"], []).append({"name": r["name"], "group": r["grp"]})
        rows = c.execute(
            "SELECT i.*, s.name AS state_name, s.type AS state_type, s.color AS state_color, "
            "u.display_name AS assignee_name, m.name AS milestone_name, par.identifier AS parent_identifier "
            "FROM issues i LEFT JOIN workflow_states s ON s.id=i.state_id LEFT JOIN users u ON u.id=i.assignee_id "
            "LEFT JOIN milestones m ON m.id=i.milestone_id LEFT JOIN issues par ON par.id=i.parent_id "
            "WHERE i.project_id=? AND i.partial=0 AND i.archived_at IS NULL ORDER BY i.created_at, i.id",
            (pid,)).fetchall()
        issues, ident = [], {}
        for r in rows:
            ident[r["id"]] = r["identifier"]
            issues.append({
                "identifier": r["identifier"], "title": r["title"],
                "state": r["state_type"] or "", "state_name": r["state_name"], "state_color": r["state_color"],
                "assignee": r["assignee_name"],
                "description_excerpt": ld.excerpt(r["description"]), "body": ld.body_facts(r["description"]),
                "parent": r["parent_identifier"], "milestone": r["milestone_name"],
                "priority": r["priority"] or 0, "priority_name": r["priority_label"] or ld.PRIORITY_NAMES[0],
                "labels": labels.get(r["id"], []),
            })
        relations, external_ids = set(), {}
        marks = ",".join("?" * len(ident)) or "NULL"
        for r in c.execute(
                "SELECT r.type, a.id AS aid, a.identifier AS a, a.title AS at, b.id AS bid, b.identifier AS b, "
                "b.title AS bt FROM issue_relations r JOIN issues a ON a.id=r.issue_id "
                "JOIN issues b ON b.id=r.related_issue_id "
                "WHERE r.issue_id IN (%s) OR r.related_issue_id IN (%s)" % (marks, marks),
                list(ident) * 2):
            relations.add((r["type"], r["a"], r["b"]))
            for iid, name, title in ((r["aid"], r["a"], r["at"]), (r["bid"], r["b"], r["bt"])):
                if iid not in ident:
                    external_ids[iid] = (name, title)
        external = {name: title for name, title in external_ids.values()}
        external_labels = {}
        for iid, (name, _) in external_ids.items():
            external_labels[name] = labels.get(iid, [])
        return {
            "project": {"name": project["name"], "milestones": ld.sort_milestones(miles)},
            "issues": issues,
            "relations": [{"type": t, "from": a, "to": b} for t, a, b in sorted(relations)],
            "external": external,
            "external_labels": external_labels,
        }
