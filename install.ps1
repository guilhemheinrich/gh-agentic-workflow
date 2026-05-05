#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Original targets
$CursorTarget = Join-Path $env:USERPROFILE '.cursor'
$PiTarget = Join-Path $env:USERPROFILE '.pi'
$Targets = @($CursorTarget, $PiTarget)

# New targets
$OpenCodeTarget = Join-Path $env:USERPROFILE '.config\opencode'
$OpenCodeCommands = Join-Path $OpenCodeTarget 'commands'
$AgentsSkills = Join-Path $env:USERPROFILE '.agents\skills'
$ClaudeCodeConfig = Join-Path $env:USERPROFILE '.claude.json'
$ClaudeDesktopConfig = Join-Path $env:APPDATA 'Claude\claude_desktop_config.json'

# Resources to copy for each target
$CursorResources = @('skills', 'rules', 'hooks', 'agents', 'commands')
$PiResources = @('skills', 'rules', 'hooks', 'agents', 'prompts')
$OpenCodeResources = @('skills', 'commands')

# Ensure Claude Desktop config directory exists
$ClaudeDesktopDir = Split-Path -Parent $ClaudeDesktopConfig
if (-not (Test-Path $ClaudeDesktopDir -PathType Container)) {
    New-Item -ItemType Directory -Path $ClaudeDesktopDir -Force | Out-Null
}

# Function to copy resources to a target
function Copy-Resources {
    param(
        [string]$Target,
        [string[]]$Resources
    )

    foreach ($res in $Resources) {
        $src = Join-Path $RepoDir $res
          # Special case: for PI target, copy commands to prompts folder
        if ($target -eq $PiTarget -and $res -eq 'commands') {
               $dest = Join-Path $Target prompts
           } else {
               $dest = Join-Path $Target $res
           }
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Copy-Item -Path (Join-Path $src '*') -Destination $dest -Recurse -Force
        Write-Host "  $res -> $dest"
    }
    Write-Host ''
}

# Copy resources to traditional targets (Cursor, PI)
foreach ($target in $Targets) {
    Copy-Resources -Target $target -Resources $CursorResources
}

# Copy resources to OpenCode
if (-not (Test-Path $OpenCodeTarget -PathType Container)) {
    New-Item -ItemType Directory -Path $OpenCodeTarget -Force | Out-Null
}
foreach ($res in $OpenCodeResources) {
    $src = Join-Path $RepoDir $res
    if (-not (Test-Path $src -PathType Container)) { continue }
    $dest = Join-Path $OpenCodeTarget $res
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Copy-Item -Path (Join-Path $src '*') -Destination $dest -Recurse -Force
    Write-Host "  $res -> $dest"
}

# Copy commands to .config/opencode/commands
if (-not (Test-Path $OpenCodeCommands -PathType Container)) {
    New-Item -ItemType Directory -Path $OpenCodeCommands -Force | Out-Null
}
$src = Join-Path $RepoDir 'commands'
if (Test-Path $src -PathType Container) {
    Copy-Item -Path (Join-Path $src '*') -Destination $OpenCodeCommands -Recurse -Force
    Write-Host "  commands -> $OpenCodeCommands"
}

# Copy skills to .agents/skills
if (-not (Test-Path $AgentsSkills -PathType Container)) {
    New-Item -ItemType Directory -Path $AgentsSkills -Force | Out-Null
}
$src = Join-Path $RepoDir 'skills'
if (Test-Path $src -PathType Container) {
    Copy-Item -Path (Join-Path $src '*') -Destination $AgentsSkills -Recurse -Force
    Write-Host "  skills -> $AgentsSkills"
}

Write-Host ''

# Check if Node.js is installed for MCP transformations
$NodeAvailable = $null -ne (Get-Command 'node' -ErrorAction SilentlyContinue)
if (-not $NodeAvailable) {
    Write-Host "Warning: Node.js is required for MCP config transformations but not found"
    Write-Host "MCP configurations will not be updated"
}
else {
    # Source MCP config from Cursor
    $CursorMcp = Join-Path $CursorTarget 'mcp.json'
    
    if (Test-Path $CursorMcp -PathType Leaf) {
        Write-Host "Found Cursor MCP config, transforming for other tools..."
        
        # Transform for OpenCode
        $OpenCodeMcp = Join-Path $OpenCodeTarget 'opencode.jsonc'
        $TempOpenCodeMcp = [System.IO.Path]::GetTempFileName()
        
        # Create OpenCode config if it doesn't exist
        if (-not (Test-Path $OpenCodeMcp -PathType Leaf)) {
            '{"$schema": "https://opencode.ai/config.json", "mcp": {}}' | Set-Content -Path $OpenCodeMcp -Encoding UTF8
        }
        
        # Transform Cursor MCP to OpenCode format
        & node "$RepoDir\scripts\mcptools\transform-mcp.js" --from cursor --to opencode --input $CursorMcp --output $TempOpenCodeMcp
        
        # Merge with existing OpenCode config
        & node "$RepoDir\scripts\mcptools\merge-mcp.js" --source $TempOpenCodeMcp --target $OpenCodeMcp --format opencode
        
        # Remove temporary file
        Remove-Item -Path $TempOpenCodeMcp -Force
        
        Write-Host "  Updated OpenCode MCP config at $OpenCodeMcp"
        
        # Transform for Claude Code
        $TempClaudeCodeMcp = [System.IO.Path]::GetTempFileName()
        
        # Create Claude Code config if it doesn't exist
        if (-not (Test-Path $ClaudeCodeConfig -PathType Leaf)) {
            '{"mcpServers": {}}' | Set-Content -Path $ClaudeCodeConfig -Encoding UTF8
        }
        
        # Transform Cursor MCP to Claude Code format
        & node "$RepoDir\scripts\mcptools\transform-mcp.js" --from cursor --to claude-code --input $CursorMcp --output $TempClaudeCodeMcp
        
        # Merge with existing Claude Code config
        & node "$RepoDir\scripts\mcptools\merge-mcp.js" --source $TempClaudeCodeMcp --target $ClaudeCodeConfig --format claude-code
        
        # Remove temporary file
        Remove-Item -Path $TempClaudeCodeMcp -Force
        
        Write-Host "  Updated Claude Code MCP config at $ClaudeCodeConfig"
        
        # Transform for Claude Desktop
        $TempClaudeDesktopMcp = [System.IO.Path]::GetTempFileName()
        
        # Create Claude Desktop config if it doesn't exist
        if (-not (Test-Path $ClaudeDesktopConfig -PathType Leaf)) {
            '{"mcpServers": {}}' | Set-Content -Path $ClaudeDesktopConfig -Encoding UTF8
        }
        
        # Transform Cursor MCP to Claude Desktop format
        & node "$RepoDir\scripts\mcptools\transform-mcp.js" --from cursor --to claude-desktop --input $CursorMcp --output $TempClaudeDesktopMcp
        
        # Merge with existing Claude Desktop config
        & node "$RepoDir\scripts\mcptools\merge-mcp.js" --source $TempClaudeDesktopMcp --target $ClaudeDesktopConfig --format claude-desktop
        
        # Remove temporary file
        Remove-Item -Path $TempClaudeDesktopMcp -Force
        
        Write-Host "  Updated Claude Desktop MCP config at $ClaudeDesktopConfig"
    }
    else {
        Write-Host "Warning: Cursor MCP config not found at $CursorMcp"
        Write-Host "MCP configurations will not be updated"
    }
}

Write-Host ''
Write-Host 'Done.'
