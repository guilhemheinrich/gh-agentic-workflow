"""linear_creds — which Linear API key goes with which workspace (standard library only).

A Linear personal API key is scoped to one workspace, the `<workspace>` slug of
https://linear.app/<workspace>/... . Credentials therefore live in one file per
workspace, plus a default for the single-workspace setup:

    ~/.config/linear/<workspace>.env     LINEAR_API_KEY=...   that workspace only
    ~/.config/linear/env                 LINEAR_API_KEY=...   the default (unchanged)

Key selection for a workspace, first hit wins:
    1. ~/.config/linear/<workspace>.env
    2. LINEAR_API_KEY in the environment
    3. ~/.config/linear/env

With no workspace (a bare slugId or issue identifier), steps 2 and 3 apply.
Step 2 and 3 serve every workspace without a file of its own: that is how the
old single-file setup keeps working. The files are parsed, never sourced, and a
key is returned to the caller only: never printed, never put on argv.
"""
import os
import re
from pathlib import Path

ENV_LINE_RE = re.compile(r"^\s*(?:export\s+)?LINEAR_API_KEY\s*=\s*(.*?)\s*$")
WORKSPACE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$")
URL_WORKSPACE_RE = re.compile(r"^https?://linear\.app/([^/?#]+)/", re.IGNORECASE)
RESERVED_URL_SEGMENTS = {"settings", "login", "signup", "new", "join"}
DEFAULT_FILE = "env"


def config_dir() -> Path:
    return Path.home() / ".config" / "linear"


def normalize_workspace(value):
    """A workspace slug (lowercase), or None for an empty value; ValueError when unusable."""
    value = (value or "").strip()
    if not value:
        return None
    if not WORKSPACE_RE.match(value) or value.lower() == DEFAULT_FILE:
        raise ValueError("not a Linear workspace slug: %r (the <workspace> in linear.app/<workspace>/...)" % value)
    return value.lower()


def workspace_from_url(value):
    """The workspace slug of a linear.app URL, else None."""
    match = URL_WORKSPACE_RE.match((value or "").strip())
    if not match or match.group(1).lower() in RESERVED_URL_SEGMENTS:
        return None
    try:
        return normalize_workspace(match.group(1))
    except ValueError:
        return None


def env_file(workspace=None) -> Path:
    """The credential file of a workspace (None = the default one)."""
    return config_dir() / ("%s.env" % workspace if workspace else DEFAULT_FILE)


def display_path(workspace=None) -> str:
    return "~/.config/linear/%s" % ("%s.env" % workspace if workspace else DEFAULT_FILE)


def read_key_file(path):
    """The LINEAR_API_KEY of an env file (the last non-empty line wins), or None."""
    try:
        lines = Path(path).read_text().splitlines()
    except OSError:
        return None
    key = None
    for line in lines:
        match = ENV_LINE_RE.match(line)
        if not match:
            continue
        value = match.group(1)
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        if value:
            key = value
    return key


def resolve(workspace=None):
    """(key or None, source) for a workspace; source is 'file', 'environment' or 'default file'."""
    if workspace:
        key = read_key_file(env_file(workspace))
        if key:
            return key, "file"
    key = (os.environ.get("LINEAR_API_KEY") or "").strip()
    if key:
        return key, "environment"
    key = read_key_file(env_file(None))
    if key:
        return key, "default file"
    return None, ""


def load_key(workspace=None):
    return resolve(workspace)[0]


def missing_message(workspace=None) -> str:
    """What to do when no key serves the workspace; names the file to create."""
    if workspace:
        return ("no Linear API key for workspace %r: create %s with a line LINEAR_API_KEY=<key>"
                " (a key made in that workspace), or set LINEAR_API_KEY, or fill the default %s"
                % (workspace, display_path(workspace), display_path()))
    return "no LINEAR_API_KEY in the environment nor in %s" % display_path()


def configured_workspaces():
    """Workspace slugs that have a credential file of their own (sorted)."""
    found = []
    try:
        names = sorted(p.name for p in config_dir().iterdir() if p.is_file())
    except OSError:
        return found
    for name in names:
        stem = name[:-len(".env")] if name.endswith(".env") else ""
        if stem and stem != DEFAULT_FILE and WORKSPACE_RE.match(stem) and stem == stem.lower():
            found.append(stem)
    return found


def key_for_url(url):
    """(key or None, workspace) for a project/issue URL: the credential of its workspace."""
    workspace = workspace_from_url(url)
    return load_key(workspace), workspace
