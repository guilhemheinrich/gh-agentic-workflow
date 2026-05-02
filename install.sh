#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# Original targets
CURSOR_TARGET="$HOME/.cursor"
PI_TARGET="$HOME/.pi"
TARGETS=("$CURSOR_TARGET" "$PI_TARGET")

# New targets
OPENCODE_TARGET="$HOME/.config/opencode"
OPENCODE_COMMANDS="$OPENCODE_TARGET/commands"
AGENTS_SKILLS="$HOME/.agents/skills"
CLAUDE_CODE_CONFIG="$HOME/.claude.json"

# On macOS, Claude Desktop config is in ~/Library/Application Support/Claude
# On Windows, it's in %APPDATA%\Claude
if [[ "$OSTYPE" == "darwin"* ]]; then
  # macOS
  CLAUDE_DESKTOP_CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
else
  # For Windows when running under WSL, Cygwin, or similar
  if [[ -n "${APPDATA:-}" ]]; then
    CLAUDE_DESKTOP_CONFIG="$APPDATA/Claude/claude_desktop_config.json"
  else
    # Skip Claude Desktop if we can't determine the location
    echo "Warning: Cannot determine Claude Desktop config location, skipping"
    CLAUDE_DESKTOP_CONFIG=""
  fi
fi

# Create directory for Claude Desktop config if needed
if [[ -n "$CLAUDE_DESKTOP_CONFIG" ]]; then
  mkdir -p "$(dirname "$CLAUDE_DESKTOP_CONFIG")"
fi

# Resources to copy for each target
CURSOR_RESOURCES=(skills rules hooks agents commands)
PI_RESOURCES=(skills rules hooks agents commands)
OPENCODE_RESOURCES=(skills commands)
OPENCODE_COMMANDS_RESOURCES=(commands)
AGENTS_SKILLS_RESOURCES=(skills)

# Function to copy resources
copy_resources() {
  local target=$1
  shift
  local resources=("$@")
  
  for res in "${resources[@]}"; do
    src="$REPO_DIR/$res"
    [ -d "$src" ] || continue
    mkdir -p "$target/$res"
    cp -Rf "$src"/* "$target/$res"/
    echo "  $res -> $target/$res"
  done
}

# Function to ensure parent directories exist
ensure_dir() {
  mkdir -p "$(dirname "$1")"
}

# Copy resources to traditional targets (Cursor, PI)
for target in "${TARGETS[@]}"; do
  copy_resources "$target" "${CURSOR_RESOURCES[@]}"
  echo ""
done

# Copy resources to OpenCode
mkdir -p "$OPENCODE_TARGET"
for res in "${OPENCODE_RESOURCES[@]}"; do
  src="$REPO_DIR/$res"
  [ -d "$src" ] || continue
  mkdir -p "$OPENCODE_TARGET/$res"
  cp -Rf "$src"/* "$OPENCODE_TARGET/$res"/
  echo "  $res -> $OPENCODE_TARGET/$res"
done

# Copy commands to ~/.config/opencode/commands
mkdir -p "$OPENCODE_COMMANDS"
src="$REPO_DIR/commands"
if [ -d "$src" ]; then
  cp -Rf "$src"/* "$OPENCODE_COMMANDS"/
  echo "  commands -> $OPENCODE_COMMANDS"
fi

# Copy skills to ~/.agents/skills
mkdir -p "$AGENTS_SKILLS"
src="$REPO_DIR/skills"
if [ -d "$src" ]; then
  cp -Rf "$src"/* "$AGENTS_SKILLS"/
  echo "  skills -> $AGENTS_SKILLS"
fi

echo ""

# Check if Node.js is installed for MCP transformations
if ! command -v node &> /dev/null; then
  echo "Warning: Node.js is required for MCP config transformations but not found"
  echo "MCP configurations will not be updated"
else
  # Source MCP config from Cursor
  CURSOR_MCP="$CURSOR_TARGET/mcp.json"
  
  if [ -f "$CURSOR_MCP" ]; then
    echo "Found Cursor MCP config, transforming for other tools..."
    
    # Transform for OpenCode
    OPENCODE_MCP="$OPENCODE_TARGET/opencode.jsonc"
    TEMP_OPENCODE_MCP="$(mktemp)"
    
    # Create OpenCode config if it doesn't exist
    if [ ! -f "$OPENCODE_MCP" ]; then
      echo '{"$schema": "https://opencode.ai/config.json", "mcp": {}}' > "$OPENCODE_MCP"
    fi
    
    # Transform Cursor MCP to OpenCode format
    node "$REPO_DIR/scripts/mcptools/transform-mcp.js" --from cursor --to opencode --input "$CURSOR_MCP" --output "$TEMP_OPENCODE_MCP"
    
    # Merge with existing OpenCode config
    node "$REPO_DIR/scripts/mcptools/merge-mcp.js" --source "$TEMP_OPENCODE_MCP" --target "$OPENCODE_MCP" --format opencode
    
    # Remove temporary file
    rm "$TEMP_OPENCODE_MCP"
    
    echo "  Updated OpenCode MCP config at $OPENCODE_MCP"
    
    # Transform for Claude Code
    TEMP_CLAUDE_CODE_MCP="$(mktemp)"
    
    # Create Claude Code config if it doesn't exist
    if [ ! -f "$CLAUDE_CODE_CONFIG" ]; then
      echo '{"mcpServers": {}}' > "$CLAUDE_CODE_CONFIG"
    fi
    
    # Transform Cursor MCP to Claude Code format
    node "$REPO_DIR/scripts/mcptools/transform-mcp.js" --from cursor --to claude-code --input "$CURSOR_MCP" --output "$TEMP_CLAUDE_CODE_MCP"
    
    # Merge with existing Claude Code config
    node "$REPO_DIR/scripts/mcptools/merge-mcp.js" --source "$TEMP_CLAUDE_CODE_MCP" --target "$CLAUDE_CODE_CONFIG" --format claude-code
    
    # Remove temporary file
    rm "$TEMP_CLAUDE_CODE_MCP"
    
    echo "  Updated Claude Code MCP config at $CLAUDE_CODE_CONFIG"
    
    # Transform for Claude Desktop (if available)
    if [[ -n "$CLAUDE_DESKTOP_CONFIG" ]]; then
      TEMP_CLAUDE_DESKTOP_MCP="$(mktemp)"
      
      # Create Claude Desktop config if it doesn't exist
      if [ ! -f "$CLAUDE_DESKTOP_CONFIG" ]; then
        echo '{"mcpServers": {}}' > "$CLAUDE_DESKTOP_CONFIG"
      fi
      
      # Transform Cursor MCP to Claude Desktop format
      node "$REPO_DIR/scripts/mcptools/transform-mcp.js" --from cursor --to claude-desktop --input "$CURSOR_MCP" --output "$TEMP_CLAUDE_DESKTOP_MCP"
      
      # Merge with existing Claude Desktop config
      node "$REPO_DIR/scripts/mcptools/merge-mcp.js" --source "$TEMP_CLAUDE_DESKTOP_MCP" --target "$CLAUDE_DESKTOP_CONFIG" --format claude-desktop
      
      # Remove temporary file
      rm "$TEMP_CLAUDE_DESKTOP_MCP"
      
      echo "  Updated Claude Desktop MCP config at $CLAUDE_DESKTOP_CONFIG"
    fi
  else
    echo "Warning: Cursor MCP config not found at $CURSOR_MCP"
    echo "MCP configurations will not be updated"
  fi
fi

echo ""
echo "Done."
