# Sets OPENROUTER_API_KEY as a persistent Windows user environment variable, so
# every new process inherits it — including Git Bash, where llm-ask.sh actually
# runs, and GUI-launched agents that read no shell profile.
#
#   powershell -ExecutionPolicy Bypass -File templates\openrouter-key.ps1
#
# NOTE: llm-ask.sh is a bash script. On Windows it needs Git Bash or WSL, plus
# curl and jq. Under WSL, use openrouter-key.sh inside the WSL environment
# instead — Windows user variables do not cross into WSL unless WSLENV forwards
# them.

$existing = [Environment]::GetEnvironmentVariable('OPENROUTER_API_KEY', 'User')

if ($existing -and $existing -ne 'PASTE_YOUR_KEY_HERE') {
    Write-Host "OPENROUTER_API_KEY is already set for this user ($($existing.Length) chars). Leaving it alone."
    Write-Host "To replace it:  [Environment]::SetEnvironmentVariable('OPENROUTER_API_KEY','<new key>','User')"
} else {
    [Environment]::SetEnvironmentVariable('OPENROUTER_API_KEY', 'PASTE_YOUR_KEY_HERE', 'User')
    Write-Host "OPENROUTER_API_KEY created at user scope with a placeholder value."
}

Write-Host ""
Write-Host "1. get a key at https://openrouter.ai/keys"
Write-Host "2. set it for real:"
Write-Host "     [Environment]::SetEnvironmentVariable('OPENROUTER_API_KEY','sk-or-v1-...','User')"
Write-Host "   (or run:  setx OPENROUTER_API_KEY ""sk-or-v1-..."" )"
Write-Host "3. open a NEW terminal — existing ones keep the old environment"
Write-Host "4. in Git Bash:  llm-ask.sh --doctor"
