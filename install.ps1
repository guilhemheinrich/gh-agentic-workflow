#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

$Targets = @(
    Join-Path $env:USERPROFILE '.cursor'
    Join-Path $env:USERPROFILE '.pi'
)

$Resources = @('skills', 'rules', 'hooks', 'agents')

foreach ($target in $Targets) {
    foreach ($res in $Resources) {
        $src = Join-Path $RepoDir $res
        if (-not (Test-Path $src -PathType Container)) { continue }
        $dest = Join-Path $target $res
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Copy-Item -Path (Join-Path $src '*') -Destination $dest -Recurse -Force
        Write-Host "  $res -> $dest"
    }
    Write-Host ''
}

Write-Host 'Done.'
