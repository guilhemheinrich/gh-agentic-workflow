#!/usr/bin/env python3
"""session-meta — open, durable metadata for agent sessions, keyed by harness.

The store holds triples: (harness, session_id, key) -> JSON value. Neither this
CLI nor the store knows any key: a tool that needs a new fact about a session
writes a new key, and every reader gets it through `get`.

    session-meta.py get <session_id> [--key K]
    session-meta.py set <session_id> <key> <value> [--json]
    session-meta.py append <session_id> <key> <value> [--json]
    session-meta.py incr <session_id> <key> [--by N]
    session-meta.py unset <session_id> <key>
    session-meta.py find --key K [--value V] [--json]
    session-meta.py sessions

Every command takes --harness (default: $AGENT_HARNESS, else "claude-code"
when $CLAUDECODE is set, else "unknown") and --db (default:
$AGENT_SESSION_META_DB, else $XDG_STATE_HOME/agent-session/meta.sqlite, else
~/.local/state/agent-session/meta.sqlite). The location is a state directory on
purpose: a cache directory may be wiped, and this is the record.

Standard library only. Output is JSON on stdout; errors go to stderr, exit 2.
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (
  harness    TEXT NOT NULL,
  session_id TEXT NOT NULL,
  key        TEXT NOT NULL,
  value      TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (harness, session_id, key)
);
CREATE INDEX IF NOT EXISTS meta_key ON meta (key);
"""


def default_db() -> Path:
    if os.environ.get("AGENT_SESSION_META_DB"):
        return Path(os.environ["AGENT_SESSION_META_DB"]).expanduser()
    state = os.environ.get("XDG_STATE_HOME") or "~/.local/state"
    return Path(state).expanduser() / "agent-session" / "meta.sqlite"


def default_harness() -> str:
    if os.environ.get("AGENT_HARNESS"):
        return os.environ["AGENT_HARNESS"]
    if os.environ.get("CLAUDECODE"):
        return "claude-code"
    return "unknown"


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def connect(db: Path) -> sqlite3.Connection:
    db.parent.mkdir(parents=True, exist_ok=True)
    # isolation_level=None: transactions are explicit, so read-modify-write
    # commands take the write lock up front (BEGIN IMMEDIATE) and two hooks
    # appending at once both keep their item.
    conn = sqlite3.connect(db, timeout=5, isolation_level=None)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.executescript(SCHEMA)
    return conn


def parse_value(raw: str, as_json: bool):
    if not as_json:
        return raw
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"session-meta: --json value is not JSON: {exc}")


def read(conn, harness, sid, key):
    row = conn.execute(
        "SELECT value FROM meta WHERE harness=? AND session_id=? AND key=?",
        (harness, sid, key),
    ).fetchone()
    return None if row is None else json.loads(row[0])


def write(conn, harness, sid, key, value) -> None:
    conn.execute(
        "INSERT INTO meta (harness, session_id, key, value, updated_at) VALUES (?,?,?,?,?) "
        "ON CONFLICT (harness, session_id, key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at",
        (harness, sid, key, json.dumps(value, ensure_ascii=False), now()),
    )


def emit(obj) -> None:
    print(json.dumps(obj, ensure_ascii=False, indent=2))


def cmd_get(conn, a) -> None:
    if a.key:
        emit(read(conn, a.harness, a.session_id, a.key))
        return
    rows = conn.execute(
        "SELECT key, value FROM meta WHERE harness=? AND session_id=? ORDER BY key",
        (a.harness, a.session_id),
    ).fetchall()
    emit({k: json.loads(v) for k, v in rows})


def cmd_set(conn, a) -> None:
    value = parse_value(a.value, a.json)
    write(conn, a.harness, a.session_id, a.key, value)
    emit(value)


def cmd_append(conn, a) -> None:
    item = parse_value(a.value, a.json)
    conn.execute("BEGIN IMMEDIATE")
    try:
        current = read(conn, a.harness, a.session_id, a.key)
        if current is None:
            current = []
        elif not isinstance(current, list):
            current = [current]
        current.append(item)
        write(conn, a.harness, a.session_id, a.key, current)
        conn.execute("COMMIT")
    except BaseException:
        conn.execute("ROLLBACK")
        raise
    emit(current)


def cmd_incr(conn, a) -> None:
    conn.execute("BEGIN IMMEDIATE")
    try:
        current = read(conn, a.harness, a.session_id, a.key)
        value = (current if isinstance(current, (int, float)) else 0) + a.by
        write(conn, a.harness, a.session_id, a.key, value)
        conn.execute("COMMIT")
    except BaseException:
        conn.execute("ROLLBACK")
        raise
    emit(value)


def cmd_unset(conn, a) -> None:
    conn.execute(
        "DELETE FROM meta WHERE harness=? AND session_id=? AND key=?",
        (a.harness, a.session_id, a.key),
    )
    emit(None)


def cmd_find(conn, a) -> None:
    sql = "SELECT harness, session_id, value, updated_at FROM meta WHERE key=?"
    params: list = [a.key]
    if not a.all_harnesses:
        sql += " AND harness=?"
        params.append(a.harness)
    if a.value is not None:
        # Compare decoded values, so "focused" matches the stored '"focused"'.
        sql += " AND value=?"
        params.append(json.dumps(parse_value(a.value, a.json), ensure_ascii=False))
    rows = conn.execute(sql + " ORDER BY updated_at DESC", params).fetchall()
    emit([
        {"harness": h, "session_id": s, "value": json.loads(v), "updated_at": u}
        for h, s, v, u in rows
    ])


def cmd_sessions(conn, a) -> None:
    sql = "SELECT harness, session_id, COUNT(*), MAX(updated_at) FROM meta"
    params: list = []
    if not a.all_harnesses:
        sql += " WHERE harness=?"
        params.append(a.harness)
    rows = conn.execute(sql + " GROUP BY harness, session_id ORDER BY 4 DESC", params).fetchall()
    emit([
        {"harness": h, "session_id": s, "keys": n, "updated_at": u}
        for h, s, n, u in rows
    ])


def build_parser() -> argparse.ArgumentParser:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--harness", default=default_harness())
    common.add_argument("--db", type=Path, default=default_db())

    p = argparse.ArgumentParser(prog="session-meta", description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)

    g = sub.add_parser("get", parents=[common])
    g.add_argument("session_id")
    g.add_argument("--key")
    g.set_defaults(fn=cmd_get)

    for name, fn in (("set", cmd_set), ("append", cmd_append)):
        s = sub.add_parser(name, parents=[common])
        s.add_argument("session_id")
        s.add_argument("key")
        s.add_argument("value")
        s.add_argument("--json", action="store_true", help="parse the value as JSON")
        s.set_defaults(fn=fn)

    i = sub.add_parser("incr", parents=[common])
    i.add_argument("session_id")
    i.add_argument("key")
    i.add_argument("--by", type=int, default=1)
    i.set_defaults(fn=cmd_incr)

    u = sub.add_parser("unset", parents=[common])
    u.add_argument("session_id")
    u.add_argument("key")
    u.set_defaults(fn=cmd_unset)

    f = sub.add_parser("find", parents=[common])
    f.add_argument("--key", required=True)
    f.add_argument("--value")
    f.add_argument("--json", action="store_true", help="parse --value as JSON")
    f.add_argument("--all-harnesses", action="store_true")
    f.set_defaults(fn=cmd_find)

    ss = sub.add_parser("sessions", parents=[common])
    ss.add_argument("--all-harnesses", action="store_true")
    ss.set_defaults(fn=cmd_sessions)
    return p


def main(argv=None) -> int:
    a = build_parser().parse_args(argv)
    try:
        conn = connect(a.db)
        a.fn(conn, a)
    except sqlite3.Error as exc:
        print(f"session-meta: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
