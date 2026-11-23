#!/usr/bin/env python3
"""prw_mcp — the PR watcher `prw` as a local MCP server (stdio, standard library only).

An agent calls `prw_subscribe`, `prw_wait`, ... as tools instead of shelling out to `prw`
(or to a Docker wrapper). Every tool maps to one `prw` subcommand and returns its
stdout, stderr and exit code; nothing is interpreted here, so `prw` stays the one
source of truth for the watcher's behaviour.

Which `prw` is run:  $PRW_BIN (a path, or several words such as `docker compose ... exec -T prw prw`),
else the `prw` next to this skill (../scripts/prw, run with bash), else `prw` on PATH.

`prw_wait` is bounded (default 25 s, max 55 s) because an MCP call must return: call it again
when it answers `timeout`. A wake is a non-empty `lines` list.
"""
import json
import os
import shlex
import subprocess
import sys

PROTOCOL = "2024-11-05"
SERVER = {"name": "prw", "version": "1.0.0"}
HERE = os.path.dirname(os.path.abspath(__file__))
MAX_WAIT = 55


def prw_command():
    env = os.environ.get("PRW_BIN", "").strip()
    if env:
        return shlex.split(env)
    local = os.path.join(HERE, "..", "scripts", "prw")
    if os.path.isfile(local):
        return ["bash", local]
    return ["prw"]


def _s(desc):
    return {"type": "string", "description": desc}


SESSION = _s("the agent session id")
REPO = _s("WS/REPO on Bitbucket, github:OWNER/REPO on GitHub")


def _need(a, *keys):
    miss = [k for k in keys if not a.get(k)]
    if miss:
        raise ValueError("missing: " + ", ".join(miss))


def _subscribe(a):
    _need(a, "session")
    argv = ["subscribe"]
    if a.get("commit"):
        argv += ["--commit", a["commit"]] + (["--branch", a["branch"]] if a.get("branch") else [])
        argv += (["--repo", a["repo"]] if a.get("repo") else [])
    elif a.get("branch"):
        argv += ["--branch", a["branch"]] + (["--repo", a["repo"]] if a.get("repo") else [])
    else:
        _need(a, "repo", "pr")
        argv += [a["repo"], str(a["pr"])]
    argv += ["--session", a["session"]]
    if a.get("harness"):
        argv += ["--harness", a["harness"]]
    if a.get("head"):
        argv += ["--head", a["head"]]
    return argv


def _unsubscribe(a):
    _need(a, "session", "repo")
    if a.get("commit"):
        return ["unsubscribe", a["repo"], "--commit", a["commit"], "--session", a["session"]]
    _need(a, "pr")
    return ["unsubscribe", a["repo"], str(a["pr"]), "--session", a["session"]]


def _ignore_comment(a):
    _need(a, "session", "repo", "pr", "comment_id")
    return ["ignore-comment", a["repo"], str(a["pr"]), str(a["comment_id"]), "--session", a["session"]]


def _status(a):
    if a.get("session"):
        return ["status", "--session", a["session"]]
    if a.get("repo") and a.get("pr"):
        return ["status", a["repo"], str(a["pr"])]
    raise ValueError("give `session`, or `repo` and `pr`")


def _wait(a):
    _need(a, "session")
    t = max(1, min(int(a.get("timeout", 25)), MAX_WAIT))
    return ["wait", "--session", a["session"], "--timeout", str(t)]


def _daemon(a):
    action = a.get("action")
    if action not in ("once", "alive", "start", "stop"):
        raise ValueError("`action` is once, alive, start or stop")
    return ["daemon", action]


# name -> (description, properties, required, argv builder)
TOOLS = {
    "prw_subscribe": (
        "Wake this session once per real change of a PR (or of a merge commit's build). "
        "Give `repo` and `pr`, or `branch` (and `repo`), or `commit`. Then call prw_wait in a loop.",
        {"session": SESSION, "repo": REPO, "pr": {"type": "integer", "description": "pull request number"},
         "branch": _s("watch the PR of this branch"), "commit": _s("watch the build of this merge commit"),
         "harness": _s("agent harness name"), "head": _s("current head SHA")},
        ["session"], _subscribe),
    "prw_unsubscribe": (
        "Stop watching a PR or a commit.",
        {"session": SESSION, "repo": REPO, "pr": {"type": "integer"}, "commit": _s("a merge commit SHA")},
        ["session", "repo"], _unsubscribe),
    "prw_ignore_comment": (
        "Never wake this session again for one PR comment.",
        {"session": SESSION, "repo": REPO, "pr": {"type": "integer"}, "comment_id": _s("the comment id")},
        ["session", "repo", "pr", "comment_id"], _ignore_comment),
    "prw_list": ("List the subscriptions (optionally of one session).", {"session": SESSION}, [],
                 lambda a: ["list"] + (["--session", a["session"]] if a.get("session") else [])),
    "prw_status": (
        "The last known state of a session's PRs, or of one PR.",
        {"session": SESSION, "repo": REPO, "pr": {"type": "integer"}}, [], _status),
    "prw_wait": (
        "Return the PR lines not delivered yet to this session, or `timeout` after `timeout` seconds "
        "(default 25, max 55). A non-empty `lines` is the wake. Call again after a timeout, and after a "
        "wake while the lines say `still watching`.",
        {"session": SESSION, "timeout": {"type": "integer", "description": "seconds, 1 to 55"}},
        ["session"], _wait),
    "prw_doctor": ("Check the watcher: tokens, daemon heartbeat, transport.", {}, [], lambda a: ["doctor"]),
    "prw_daemon": (
        "Control the prw daemon: `once` (one poll cycle), `alive` (is the heartbeat fresh), `start`, `stop`.",
        {"action": {"type": "string", "enum": ["once", "alive", "start", "stop"]}}, ["action"], _daemon),
}


def run_tool(name, args):
    if name not in TOOLS:
        raise ValueError("unknown tool %r" % name)
    argv = TOOLS[name][3](args or {})
    timeout = MAX_WAIT + 15 if name == "prw_wait" else 120
    try:
        p = subprocess.run(prw_command() + argv, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"exit_code": None, "error": "the prw command did not finish in %ds" % timeout}, True
    out = {"exit_code": p.returncode, "stdout": p.stdout.strip(), "stderr": p.stderr.strip()}
    if name == "prw_wait":
        out["lines"] = p.stdout.strip().splitlines() if p.returncode == 0 else []
        out["status"] = {0: "wake", 2: "timeout", 3: "no-open-subscription", 4: "already-waiting"}.get(p.returncode, "error")
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
