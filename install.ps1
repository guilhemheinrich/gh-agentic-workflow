#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ExportMcp = $false

function Show-Usage {
    Write-Host "Usage: .\install.ps1 [--export-mcp]"
    Write-Host ''
    Write-Host 'Copies resources to supported agent directories.'
    Write-Host ''
    Write-Host 'Options:'
    Write-Host '  --export-mcp  Export Cursor MCP config to supported tools'
    Write-Host '  -ExportMcp    PowerShell-style alias for --export-mcp'
    Write-Host '  -h, --help    Show this help'
}

foreach ($arg in $args) {
    switch ($arg) {
        '--export-mcp' {
            $ExportMcp = $true
        }
        '-ExportMcp' {
            $ExportMcp = $true
        }
        '-h' {
            Show-Usage
            exit 0
        }
        '--help' {
            Show-Usage
            exit 0
        }
        default {
            [Console]::Error.WriteLine("Error: unknown option: $arg")
            Show-Usage
            exit 2
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# IDE / Tool target directories
# ─────────────────────────────────────────────────────────────────────────────
$CursorTarget       = Join-Path $env:USERPROFILE '.cursor'
$PiTarget           = Join-Path $env:USERPROFILE '.pi' 'agent'
$OpenCodeTarget     = Join-Path $env:USERPROFILE '.config' 'opencode'
$AgentsShared       = Join-Path $env:USERPROFILE '.agents'
$ClaudeCodeTarget   = Join-Path $env:USERPROFILE '.claude'

# Claude configs
$ClaudeCodeConfig   = Join-Path $env:USERPROFILE '.claude.json'
$ClaudeDesktopDir   = Join-Path $env:APPDATA 'Claude'
$ClaudeDesktopConfig = Join-Path $ClaudeDesktopDir 'claude_desktop_config.json'

# ─────────────────────────────────────────────────────────────────────────────
# Copy mapping:  @{ SourceDir = DestinationDir }
#
#   SourceDir  = folder name inside this repo (skills, commands, agents, …)
#   DestDir    = absolute destination path
#
# To add a new IDE or a new resource type, just add a line here.
# ─────────────────────────────────────────────────────────────────────────────
$CopyMap = @(
    # ── Cursor ──────────────────────────────────────────────────────────────
    @{ Src = 'skills';   Dst = "$CursorTarget\skills" }
    @{ Src = 'rules';    Dst = "$CursorTarget\rules" }
    @{ Src = 'hooks';    Dst = "$CursorTarget\hooks" }
    @{ Src = 'agents';   Dst = "$CursorTarget\agents" }
    @{ Src = 'commands'; Dst = "$CursorTarget\commands" }

    # ── PI ──────────────────────────────────────────────────────────────────
    @{ Src = 'skills';   Dst = "$PiTarget\skills" }
    @{ Src = 'rules';    Dst = "$PiTarget\rules" }
    @{ Src = 'hooks';    Dst = "$PiTarget\extensions" }
    @{ Src = 'agents';   Dst = "$PiTarget\agents" }
    @{ Src = 'commands'; Dst = "$PiTarget\prompts" }   # PI uses "prompts" instead of "commands"

    # ── OpenCode ────────────────────────────────────────────────────────────
    @{ Src = 'skills';   Dst = "$OpenCodeTarget\skills" }
    @{ Src = 'commands'; Dst = "$OpenCodeTarget\commands" }
    @{ Src = 'agents';   Dst = "$OpenCodeTarget\agents" }

    # ── Claude Code (user scope) ────────────────────────────────────────────
    # Official user-level paths per https://code.claude.com/docs/en/skills
    #   skills   → ~/.claude/skills/<name>/SKILL.md
    #   commands → ~/.claude/commands/<name>.md   (slash commands)
    #   agents   → ~/.claude/agents/<name>.md     (subagents)
    @{ Src = 'skills';   Dst = "$ClaudeCodeTarget\skills" }
    @{ Src = 'commands'; Dst = "$ClaudeCodeTarget\commands" }
    @{ Src = 'agents';   Dst = "$ClaudeCodeTarget\agents" }

    # ── Shared agents directory (generic fallback) ──────────────────────────
    @{ Src = 'skills';   Dst = "$AgentsShared\skills" }
)

# ─────────────────────────────────────────────────────────────────────────────
# MCP transformation mapping
#
# Source MCP config is always Cursor's  ~/.cursor/mcp.json
# Each entry: Format = transform target name,  Config = destination file path
# ─────────────────────────────────────────────────────────────────────────────
$McpMap = @(
    @{ Format = 'opencode';       Config = "$OpenCodeTarget\opencode.jsonc" }
    @{ Format = 'claude-code';    Config = $ClaudeCodeConfig }
    @{ Format = 'claude-desktop'; Config = $ClaudeDesktopConfig }
)

# Default config content for each MCP format (used when creating a new file)
$McpDefaults = @{
    'opencode'       = '{"$schema": "https://opencode.ai/config.json", "mcp": {}}'
    'claude-code'    = '{"mcpServers": {}}'
    'claude-desktop' = '{"mcpServers": {}}'
}

# ─────────────────────────────────────────────────────────────────────────────
# Copy resources
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "Copying resources…"
Write-Host ''

foreach ($entry in $CopyMap) {
    $src = Join-Path $RepoDir $entry.Src
    if (-not (Test-Path $src -PathType Container)) { continue }

    $dst = $entry.Dst
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force
    Write-Host "  $($entry.Src) -> $dst"
}

Write-Host ''

# ─────────────────────────────────────────────────────────────────────────────
# MCP config transformations  (requires Node.js)
# ─────────────────────────────────────────────────────────────────────────────
$CursorMcp = Join-Path $CursorTarget 'mcp.json'
$NodeAvailable = $null -ne (Get-Command 'node' -ErrorAction SilentlyContinue)

if (-not $ExportMcp) {
    Write-Host "Skipping MCP config export (pass --export-mcp to enable)."
}
elseif (-not $NodeAvailable) {
    Write-Host "Warning: Node.js is required for MCP config transformations but not found"
    Write-Host "MCP configurations will not be updated"
}
elseif (-not (Test-Path $CursorMcp -PathType Leaf)) {
    Write-Host "Warning: Cursor MCP config not found at $CursorMcp"
    Write-Host "MCP configurations will not be updated"
}
else {
    Write-Host "Found Cursor MCP config, transforming for other tools…"

    # Ensure Claude Desktop directory exists
    if (-not (Test-Path $ClaudeDesktopDir -PathType Container)) {
        New-Item -ItemType Directory -Path $ClaudeDesktopDir -Force | Out-Null
    }

    foreach ($entry in $McpMap) {
        $format = $entry.Format
        $config = $entry.Config
        $tmp    = [System.IO.Path]::GetTempFileName()

        $configDir = Split-Path -Parent $config
        if (-not (Test-Path $configDir -PathType Container)) {
            New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        }

        if (-not (Test-Path $config -PathType Leaf)) {
            $McpDefaults[$format] | Set-Content -Path $config -Encoding UTF8
        }

        & node "$RepoDir\scripts\mcptools\transform-mcp.cjs" `
            --from cursor --to $format `
            --input $CursorMcp --output $tmp

        & node "$RepoDir\scripts\mcptools\merge-mcp.cjs" `
            --source $tmp --target $config --format $format

        Remove-Item -Path $tmp -Force
        Write-Host "  MCP ($format) -> $config"
    }
}

Write-Host ''
Write-Host 'Done.'
