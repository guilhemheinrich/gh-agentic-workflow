#!/usr/bin/env bash
# setup.sh <client> <scope> [languages]
#   client:    claude | cursor | opencode
#   scope:     project | global
#   languages: comma list of python,vue,nuxt,php,symfony,go (default: auto-detect)
# Writes the MCP client config for CJL.lsp-mcp, and (project scope) the
# lsp-mcp.* keys in .vscode/settings.json plus extension recommendations in
# .vscode/extensions.json. Idempotent: existing keys are merged, never duplicated.
set -euo pipefail

PORT="${LSP_MCP_PORT:-9527}"
URL="http://127.0.0.1:${PORT}/mcp"
client="${1:-}"; scope="${2:-}"; langs="${3:-auto}"

die() { printf 'setup.sh: %s\n' "$1" >&2; exit 1; }
[ -n "$client" ] && [ -n "$scope" ] || die "usage: setup.sh <claude|cursor|opencode> <project|global> [languages]"
case "$scope" in project|global) ;; *) die "scope must be project or global" ;; esac

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || die "python3 is required to merge JSON"

case "$client:$scope" in
  claude:project)   target=".mcp.json" ;;
  claude:global)    target="$HOME/.claude.json" ;;
  cursor:project)   target=".cursor/mcp.json" ;;
  cursor:global)    target="$HOME/.cursor/mcp.json" ;;
  opencode:project) target="opencode.json" ;;
  opencode:global)  target="$HOME/.config/opencode/opencode.json" ;;
  *) die "unknown client: $client" ;;
esac

if [ "$langs" = "auto" ]; then
  langs=""
  [ -n "$(find . -maxdepth 3 -name '*.py' -not -path './node_modules/*' -print -quit 2>/dev/null)" ] && langs="$langs,python"
  [ -n "$(find . -maxdepth 3 -name '*.vue' -not -path './node_modules/*' -print -quit 2>/dev/null)" ] && langs="$langs,vue"
  [ -f composer.json ] && langs="$langs,php"
  [ -f go.mod ] && langs="$langs,go"
  langs="${langs#,}"
fi

mkdir -p "$(dirname "$target")"
"$PY" - "$client" "$target" "$URL" <<'PYEOF'
import json, os, sys
client, target, url = sys.argv[1:4]
data = {}
if os.path.exists(target) and os.path.getsize(target) > 0:
    with open(target, encoding="utf-8") as f:
        data = json.load(f)
if client == "claude":
    data.setdefault("mcpServers", {})["lsp-mcp"] = {"type": "http", "url": url}
elif client == "cursor":
    data.setdefault("mcpServers", {})["lsp"] = {"url": url}
else:
    data.setdefault("$schema", "https://opencode.ai/config.json")
    data.setdefault("mcp", {})["lsp"] = {"type": "remote", "url": url, "enabled": True}
with open(target, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2); f.write("\n")
PYEOF
echo "wrote $target"

if [ "$scope" = "project" ]; then
  mkdir -p .vscode
  "$PY" - "$PORT" "$langs" <<'PYEOF'
import json, os, sys
port, langs = int(sys.argv[1]), [l for l in sys.argv[2].split(",") if l]
exts = {
    "python": ["ms-python.python", "ms-python.vscode-pylance"],
    "vue": ["Vue.volar"],
    "nuxt": ["Vue.volar", "Nuxt.mdc"],
    "php": ["bmewburn.vscode-intelephense-client"],
    "symfony": ["bmewburn.vscode-intelephense-client", "TheNouillet.symfony-vscode"],
    "go": ["golang.go"],
}
def load(p):
    if os.path.exists(p) and os.path.getsize(p) > 0:
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    return {}
def save(p, d):
    with open(p, "w", encoding="utf-8") as f:
        json.dump(d, f, indent=2); f.write("\n")
s = load(".vscode/settings.json")
s.update({"lsp-mcp.enabled": True, "lsp-mcp.port": port, "lsp-mcp.outputFormat": "json"})
save(".vscode/settings.json", s)
e = load(".vscode/extensions.json")
rec = e.setdefault("recommendations", [])
for l in langs:
    for x in exts.get(l, []):
        if x not in rec:
            rec.append(x)
if "CJL.lsp-mcp" not in rec:
    rec.append("CJL.lsp-mcp")
save(".vscode/extensions.json", e)
PYEOF
  echo "wrote .vscode/settings.json and .vscode/extensions.json (languages: ${langs:-none})"
fi
echo "Restart the client; VS Code must be open on the project with the language extensions active."
