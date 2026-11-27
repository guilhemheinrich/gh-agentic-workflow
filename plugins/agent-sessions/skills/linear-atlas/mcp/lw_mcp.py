#!/usr/bin/env python3
"""lw_mcp — the Linear watcher `lw` as a local MCP server (stdio, standard library only).

An agent calls `lw_subscribe`, `lw_wait`, ... as tools instead of shelling out to `lw`
(or to a Docker wrapper). Every tool maps to one `lw` subcommand and returns its
stdout, stderr and exit code; nothing is interpreted here, so `lw` stays the one
source of truth for the watcher's behaviour.

Which `lw` is run:  $LW_BIN (a path, or several words such as `docker compose ... exec -T lw lw`),
else the `lw` next to this skill (../scripts/lw), else `lw` on PATH.
On Windows a bare path with a `.cmd` sibling (D:/x/lw -> D:/x/lw.cmd) runs the `.cmd`; write the path
with forward slashes. If the command cannot start, the tool answers an error result, never crashes.

`lw_wait` is bounded (default 25 s, max 55 s) because an MCP call must return: call it again
when it answers `timeout`. A wake is a non-empty `lines` list.
"""
import json
import os
import shlex
import subprocess
import sys

PROTOCOL = "2024-11-05"
SERVER = {"name": "lw", "version": "1.0.0"}
HERE = os.path.dirname(os.path.abspath(__file__))
MAX_WAIT = 55


def _win_cmd(words):
    """On Windows, an extensionless first word with a `.cmd` sibling becomes that `.cmd`.

    shlex.split eats backslashes, so LW_BIN must use the forward-slash form D:/path/lw.
    """
    if sys.platform == "win32" and words and os.path.splitext(words[0])[1] == "" \
            and os.path.isfile(words[0] + ".cmd"):
        return [words[0] + ".cmd"] + words[1:]
    return words


def lw_command():
    env = os.environ.get("LW_BIN", "").strip()
    if env:
        return _win_cmd(shlex.split(env))
    local = os.path.join(HERE, "..", "scripts", "lw")
    if os.path.isfile(local):
        return [sys.executable, local]
    return ["lw"]


def _s(desc):
    return {"type": "string", "description": desc}


SESSION = _s("the agent session id (the one the lw hook printed at session start)")
WORKSPACE = _s("Linear workspace slug (the <ws> of linear.app/<ws>/...): picks the key "
               "~/.config/linear/<ws>.env. Default: the one in the project URL")
TARGET = {"project": _s("Linear project slug or URL"), "issue": _s("issue identifier, e.g. TT-123")}


def _target(a, allow_all=False):
    for k in ("project", "issue"):
        if a.get(k):
            return ["--%s" % k, str(a[k])]
    if allow_all and a.get("all"):
        return ["--all"]
    raise ValueError("give `project` or `issue`" + (" or `all`" if allow_all else ""))


def _need(a, *keys):
    miss = [k for k in keys if not a.get(k)]
    if miss:
        raise ValueError("missing: " + ", ".join(miss))


def _wait_args(a):
    _need(a, "session")
    t = max(1, min(int(a.get("timeout", 25)), MAX_WAIT))
    return ["wait", "--session", a["session"], "--timeout", str(t)]


def _workspace(a):
    return ["--workspace", str(a["workspace"])] if a.get("workspace") else []


def _subscribe(a):
    _need(a, "session")
    return (["subscribe", "--session", a["session"], *_target(a)] + _workspace(a)
            + (["--since", a["since"]] if a.get("since") else []))


def _unsubscribe(a):
    _need(a, "session")
    return ["unsubscribe", "--session", a["session"], *_target(a, True)]


def _own_write(a):
    if a.get("comment"):
        return ["own-write", "--comment", a["comment"]]
    if a.get("issue") and a.get("state"):
        return ["own-write", "--issue", a["issue"], "--state", a["state"]]
    raise ValueError("give `comment`, or `issue` and `state`")


# name -> (description, properties, required, argv builder)
TOOLS = {
    "lw_subscribe": (
        "Wake this session when a Linear project or issue changes (comment, state move). "
        "Then call lw_wait in a loop.",
        {"session": SESSION, **TARGET, "workspace": WORKSPACE,
         "since": _s("also deliver changes since then, e.g. 3d (max 7d)")},
        ["session"],
        _subscribe),
    "lw_unsubscribe": (
        "Stop watching a project or an issue, or everything (`all`).",
        {"session": SESSION, **TARGET, "all": {"type": "boolean", "description": "unsubscribe from everything"}},
        ["session"],
        _unsubscribe),
    "lw_list": (
        "List the subscriptions, each with its workspace (optionally of one session or one workspace).",
        {"session": SESSION, "workspace": WORKSPACE,
         "closed": {"type": "boolean", "description": "include closed subscriptions"}},
        [],
        lambda a: ["list", "--json"] + (["--session", a["session"]] if a.get("session") else [])
        + _workspace(a) + (["--closed"] if a.get("closed") else [])),
    "lw_wait": (
        "Return the Linear lines not delivered yet to this session, or `timeout` after `timeout` seconds "
        "(default 25, max 55). A non-empty `lines` is the wake. Call again after a timeout.",
        {"session": SESSION, "timeout": {"type": "integer", "description": "seconds, 1 to 55"}},
        ["session"],
        _wait_args),
    "lw_own_write": (
        "Record a comment or a state move this agent made in Linear, so it never wakes this session.",
        {"comment": _s("comment id (UUID)"), "issue": _s("issue identifier (needs `state`)"),
         "state": _s("the state name the issue was moved to")},
        [],
        _own_write),
    "lw_expire": ("Close finished or abandoned subscriptions now.", {}, [], lambda a: ["expire"]),
    "lw_doctor": ("Check the watcher: binary, credential, heartbeat, transport, and one line per Linear "
                  "workspace (credential, last error, subscriptions). Never calls Linear.",
                  {"workspace": WORKSPACE}, [], lambda a: ["doctor"] + _workspace(a)),
    "lw_graph": (
        "Rebuild a project's dependency graph (SVG + JSON in ~/linear-graphs).",
        {**TARGET, "workspace": WORKSPACE, "no_create": {"type": "boolean", "description": "never create a file, only rebuild an existing one"}},
        [],
        lambda a: ["graph", *_target(a)] + _workspace(a) + (["--no-create"] if a.get("no_create") else [])),
}


def run_tool(name, args):
    if name not in TOOLS:
        raise ValueError("unknown tool %r" % name)
    argv = TOOLS[name][3](args or {})
    timeout = MAX_WAIT + 15 if name == "lw_wait" else 120
    cmd = lw_command() + argv
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"exit_code": None, "error": "the lw command did not finish in %ds" % timeout}, True
    except OSError as e:
        msg = "could not run %r (LW_BIN=%s): %s" % (cmd[0], os.environ.get("LW_BIN") or "unset", e)
        if sys.platform == "win32":
            msg += (". On Windows set LW_BIN to the .cmd wrapper with forward slashes, e.g. "
                    "LW_BIN=D:/path/to/scripts/watchers-docker/lw.cmd, then restart the Claude "
                    "session (the environment is read at session start)")
        return {"exit_code": None, "error": msg, "command": cmd}, True
    out = {"exit_code": p.returncode, "stdout": p.stdout.strip(), "stderr": p.stderr.strip()}
    if name == "lw_wait":
        out["lines"] = p.stdout.strip().splitlines() if p.returncode == 0 else []
        out["status"] = {0: "wake", 2: "timeout", 3: "no-open-subscription", 4: "another-wait-runs"}.get(p.returncode, "error")
        return out, p.returncode not in (0, 2)
    return out, p.returncode != 0


def handle(msg):
    method, mid = msg.get("method"), msg.get("id")
    if method == "initialize":
        return {"protocolVersion": PROTOCOL, "capabilities": {"tools": {}}, "serverInfo": SERVER}
    if method == "ping":
        return {}
    if method == "tools/list":
        return {"tools": [{"name": n, "description": d,
                           "inputSchema": {"type": "object", "properties": props, "required": req}}
                          for n, (d, props, req, _) in TOOLS.items()]}
    if method == "tools/call":
        p = msg.get("params") or {}
        try:
            out, is_err = run_tool(p.get("name"), p.get("arguments") or {})
        except (ValueError, KeyError) as e:
            return {"content": [{"type": "text", "text": "error: %s" % e}], "isError": True}
        return {"content": [{"type": "text", "text": json.dumps(out, ensure_ascii=False)}], "isError": is_err}
    if mid is None:
        return None          # a notification: no answer
    raise LookupError(method)


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        try:
            result = handle(msg)
            reply = None if result is None or msg.get("id") is None else {"jsonrpc": "2.0", "id": msg["id"], "result": result}
        except LookupError:
            reply = {"jsonrpc": "2.0", "id": msg.get("id"), "error": {"code": -32601, "message": "method not found"}}
        if reply:
            sys.stdout.write(json.dumps(reply) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
