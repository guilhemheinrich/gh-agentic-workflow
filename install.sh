#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─────────────────────────────────────────────────────────────────────────────
# IDE / Tool target directories
# ─────────────────────────────────────────────────────────────────────────────
CURSOR_TARGET="$HOME/.cursor"
PI_TARGET="$HOME/.pi/agent"
OPENCODE_TARGET="$HOME/.config/opencode"
AGENTS_SHARED="$HOME/.agents"

# Claude configs (MCP-only, no file copy)
CLAUDE_CODE_CONFIG="$HOME/.claude.json"
if [[ "$OSTYPE" == "darwin"* ]]; then
	CLAUDE_DESKTOP_CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
elif [[ -n "${APPDATA:-}" ]]; then
	CLAUDE_DESKTOP_CONFIG="$APPDATA/Claude/claude_desktop_config.json"
else
	echo "Warning: Cannot determine Claude Desktop config location, skipping"
	CLAUDE_DESKTOP_CONFIG=""
fi

# ─────────────────────────────────────────────────────────────────────────────
# Copy mapping: each entry is  "source_dir:target_dir"
#
#   source_dir  = folder name inside this repo (skills, commands, agents, …)
#   target_dir  = absolute destination path
#
# To add a new IDE or a new resource type, just add a line here.
# ─────────────────────────────────────────────────────────────────────────────
COPY_MAP=(
	# ── Cursor ──────────────────────────────────────────────────────────────
	"skills:$CURSOR_TARGET/skills"
	"rules:$CURSOR_TARGET/rules"
	"hooks:$CURSOR_TARGET/hooks"
	"agents:$CURSOR_TARGET/agents"
	"commands:$CURSOR_TARGET/commands"

	# ── PI ──────────────────────────────────────────────────────────────────
	"skills:$PI_TARGET/skills"
	"rules:$PI_TARGET/rules"
	"hooks:$PI_TARGET/extensions"
	"agents:$PI_TARGET/agents"
	"commands:$PI_TARGET/prompts"          # PI uses "prompts" instead of "commands"

	# ── OpenCode ────────────────────────────────────────────────────────────
	"skills:$OPENCODE_TARGET/skills"
	"commands:$OPENCODE_TARGET/commands"
	"agents:$OPENCODE_TARGET/agents"

	# ── Shared agents directory (Claude Code / generic) ─────────────────────
	"skills:$AGENTS_SHARED/skills"
)

# ─────────────────────────────────────────────────────────────────────────────
# MCP transformation mapping: each entry is  "format:config_path"
#
# Source MCP config is always Cursor's  ~/.cursor/mcp.json
# The transform-mcp + merge-mcp scripts handle format conversion.
# ─────────────────────────────────────────────────────────────────────────────
MCP_MAP=(
	"opencode:$OPENCODE_TARGET/opencode.jsonc"
	"claude-code:$CLAUDE_CODE_CONFIG"
)
if [[ -n "$CLAUDE_DESKTOP_CONFIG" ]]; then
	MCP_MAP+=("claude-desktop:$CLAUDE_DESKTOP_CONFIG")
fi

# Default config content for each MCP format (used when creating a new file)
# Plain function instead of associative array for bash 3.2 (macOS default) compat
mcp_default_content() {
	case "$1" in
		opencode)       echo '{"$schema": "https://opencode.ai/config.json", "mcp": {}}' ;;
		claude-code)    echo '{"mcpServers": {}}' ;;
		claude-desktop) echo '{"mcpServers": {}}' ;;
	esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Copy resources
# ─────────────────────────────────────────────────────────────────────────────
echo "Copying resources…"
echo ""

for entry in "${COPY_MAP[@]}"; do
	src_name="${entry%%:*}"
	dst="${entry#*:}"
	src="$REPO_DIR/$src_name"

	[ -d "$src" ] || continue

	mkdir -p "$dst"
	cp -Rf "$src"/* "$dst"/ 2>/dev/null || true
	echo "  $src_name -> $dst"
done

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# MCP config transformations  (requires Node.js)
# ─────────────────────────────────────────────────────────────────────────────
CURSOR_MCP="$CURSOR_TARGET/mcp.json"

if ! command -v node &>/dev/null; then
	echo "Warning: Node.js is required for MCP config transformations but not found"
	echo "MCP configurations will not be updated"
elif [ ! -f "$CURSOR_MCP" ]; then
	echo "Warning: Cursor MCP config not found at $CURSOR_MCP"
	echo "MCP configurations will not be updated"
else
	echo "Found Cursor MCP config, transforming for other tools…"

	for entry in "${MCP_MAP[@]}"; do
		format="${entry%%:*}"
		config="${entry#*:}"
		tmp="$(mktemp)"

		mkdir -p "$(dirname "$config")"

		if [ ! -f "$config" ]; then
			mcp_default_content "$format" >"$config"
		fi

		node "$REPO_DIR/scripts/mcptools/transform-mcp.cjs" \
			--from cursor --to "$format" \
			--input "$CURSOR_MCP" --output "$tmp"

		node "$REPO_DIR/scripts/mcptools/merge-mcp.cjs" \
			--source "$tmp" --target "$config" --format "$format"

		rm -f "$tmp"
		echo "  MCP ($format) -> $config"
	done
fi

echo ""
echo "Done."
