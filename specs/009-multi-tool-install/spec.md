# Feature Specification: Multi-Tool Install Script Update

**Feature Branch**: `009-multi-tool-install`  
**Created**: May 2, 2026  
**Status**: Draft  
**Input**: User description: "ej voudrais mettre à jour install.sh et install.ps1 pour que les script prenne en compte openrouter et claude. Cela signifie faire un etl pour les mcps, au moins pour opencode (je ne connais pas le format de claude : cherche sur internet) : regarde la configuration des mcps de cursor (dans leur mcp.json dans ~/.cursor) et ceux dans la config de opencode ~/.config/opencode/opencode.jsonc). Ce n'est pas le même format pour les ariables d'envrionnement, ni pour la commande, te il faut spécifier sir il s'agit d'un serveur mcp local ou distant (gère le automatiquement en focntion de si on utilise http(s) ou non). Les skills doivent être en plus copié dans ~/.agents/skills, les commands pour opencode doivent être copié dasn ~/.config/opencode/commands. Pas de hooks pour opencode"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Install Resources for Multiple AI Assistants (Priority: P1)

As a developer, I want to run a single install script that copies skills, commands, rules, agents, and MCP configurations to multiple tools' directories (Cursor, PI, OpenCode, Claude) so that all my AI assistants have access to the same resources without requiring manual configuration for each tool.

**Why this priority**: This is the core functionality of the script - copying resources to multiple directories to keep AI assistants in sync.

**Independent Test**: Can be fully tested by executing the install script and verifying that resources are copied to each target directory. Success means all specified directories have the correct files.

**Acceptance Scenarios**:

1. **Given** a clean environment, **When** I run the install script, **Then** resources are copied to all specified target directories (~/.cursor, ~/.pi, ~/.config/opencode, ~/.agents/skills).
2. **Given** I have a config file at ~/.cursor/mcp.json, **When** I run the install script, **Then** the MCP configuration is appropriately transformed and written to target configs.

---

### User Story 2 - Configure Claude with MCP Servers (Priority: P2)

As a Claude user, I want the install script to automatically configure Claude (both Desktop and Code versions) with the same MCP servers as my other tools, so I can use the same tools across all my AI assistants.

**Why this priority**: Claude configuration is important, but comes after the core resource copying functionality.

**Independent Test**: Can be tested by running the install script and verifying that Claude configuration files have been updated with the correct MCP server configurations.

**Acceptance Scenarios**:

1. **Given** I have MCP servers configured in ~/.cursor/mcp.json, **When** I run the install script, **Then** both ~/.claude.json and ~/Library/Application Support/Claude/claude_desktop_config.json (on macOS) or %APPDATA%\Claude\claude_desktop_config.json (on Windows) are updated with the correct MCP configurations.

---

### User Story 3 - Configure OpenCode with MCP Servers (Priority: P1)

As an OpenCode user, I want the install script to automatically configure OpenCode with the same MCP servers as Cursor, transforming the format appropriately, so I can use the same tools without reconfiguration.

**Why this priority**: OpenCode configuration is critical since it was explicitly requested and requires format transformation.

**Independent Test**: Can be tested by running the install script and verifying that ~/.config/opencode/opencode.jsonc has been updated with the correct MCP server configurations.

**Acceptance Scenarios**:

1. **Given** I have MCP servers configured in ~/.cursor/mcp.json, **When** I run the install script, **Then** ~/.config/opencode/opencode.jsonc is updated with the MCP configurations in the correct format.

### Edge Cases

- What happens when an MCP server configuration in the source is incompatible with a target? The script should handle the transformation according to defined rules or skip the incompatible server with a warning.
- What happens when target configuration files don't exist? The script should create them with appropriate initial content.
- What happens when a target directory doesn't exist? The script should create the directory structure before copying files.
- What happens if source files don't exist? The script should check for existence and skip non-existent sources with a warning.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Install script MUST copy skills from the repository to ~/.cursor/, ~/.pi/, and ~/.agents/skills/ directories
- **FR-002**: Install script MUST copy commands from the repository to ~/.cursor/, ~/.pi/, and ~/.config/opencode/commands/ directories
- **FR-003**: Install script MUST copy rules from the repository to ~/.cursor/ and ~/.pi/ directories
- **FR-004**: Install script MUST copy agents from the repository to ~/.cursor/ and ~/.pi/ directories
- **FR-005**: Install script MUST copy hooks from the repository to ~/.cursor/ and ~/.pi/ directories (but NOT to OpenCode)
- **FR-006**: Install script MUST read MCP server configurations from ~/.cursor/mcp.json
- **FR-007**: Install script MUST transform Cursor MCP format to OpenCode format (adjusting command/args format and environment variables format)
- **FR-008**: Install script MUST transform Cursor MCP format to Claude Code format (adding appropriate type fields)
- **FR-009**: Install script MUST transform Cursor MCP format to Claude Desktop format
- **FR-010**: Install script MUST write transformed MCP configurations to ~/.config/opencode/opencode.jsonc, merging with existing content
- **FR-011**: Install script MUST write transformed MCP configurations to ~/.claude.json, merging with existing content
- **FR-012**: Install script MUST write transformed MCP configurations to the Claude Desktop config file location (platform-specific)
- **FR-013**: Install script MUST automatically detect local vs remote MCP servers (based on http/https URLs)
- **FR-014**: Install script MUST handle both Bash (install.sh) and PowerShell (install.ps1) environments
- **FR-015**: Install script MUST preserve existing content in target files when merging configurations
- **FR-016**: Install script MUST create target directories if they don't exist
- **FR-017**: Install script MUST maintain correct JSON/JSONC format in all target files
- **FR-018**: Install script MUST only write MCP configs to appropriate target files (e.g., only mcpServers to Claude config)

### Key Entities

- **MCP Server Configuration**: Represents configuration for a Model Context Protocol server, containing command/args or URL and environment variables
- **InstallTarget**: Represents a target environment (Cursor, PI, OpenCode, Claude) with specific paths and format requirements
- **Format Transformer**: Logic to convert between different MCP config formats (Cursor → OpenCode, Cursor → Claude)

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: After running install.sh or install.ps1, all specified resources are copied to all target directories
- **SC-002**: After running install script, OpenCode can successfully connect to all MCP servers previously configured in Cursor
- **SC-003**: After running install script, Claude can successfully connect to all MCP servers previously configured in Cursor
- **SC-004**: The same MCP server configuration is accessible and functional across all tools (Cursor, PI, OpenCode, Claude)
- **SC-005**: The install script completes in under 10 seconds on a standard development machine

## Assumptions

- Users have Cursor, PI, OpenCode, and Claude already installed on their system
- The source ~/.cursor/mcp.json file exists and contains valid MCP server configurations
- Users want to sync all MCP servers from Cursor to other tools (no selective sync)
- Target files may or may not already exist but their parent directories exist
- If target files exist, they contain valid JSON/JSONC that can be parsed
- The script will be run with appropriate permissions to read/write all target files
- The Cursor MCP format is the canonical source, and other formats are derived from it
- MCP servers using URLs are remote, others are local
- Secrets/credentials in MCP configurations should be copied as-is (not externalized)
