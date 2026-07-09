---
name: pr-history
description: >-
  Show the latest merged pull request descriptions in the terminal, newest merge
  first, so the project state and recent work are easy to scan.
tags:
  - git
  - github
  - shell
---

# `/pr-history` - Latest Merged PR Notes

Fetch the latest merged pull requests from the current GitHub repository and
print their descriptions cleanly in the terminal, ordered by `mergedAt`
descending. The most recently merged PR must be displayed first.

## Usage

```bash
/pr-history
/pr-history 20
```

Default to 10 PRs when no count is provided.

## Behavior

1. Verify `gh` is installed and authenticated with `gh auth status`.
2. Run from the target repository root, or let `gh` infer the repository from the
   current Git remote.
3. Fetch more merged PRs than the requested display count, sort locally by merge
   timestamp descending, then print only the requested count.
4. For each PR, display:
   - number and title
   - merged date and author
   - source and target branches
   - URL
   - PR description/body, or `(no description)` when empty
5. Do not open a browser and do not modify the repository.

## Bash / Zsh

```bash
pr-history() {
  local limit="${1:-10}"
  case "$limit" in
    ''|*[!0-9]*)
      echo "Usage: pr-history [count]" >&2
      return 2
      ;;
  esac
  local fetch_count=100
  if [ "$limit" -gt "$fetch_count" ]; then
    fetch_count="$limit"
  fi

  command -v gh >/dev/null 2>&1 || {
    echo "gh is required: https://cli.github.com/" >&2
    return 127
  }
  gh auth status >/dev/null || return $?
  gh pr list \
    --state merged \
    --search "sort:updated-desc" \
    --limit "$fetch_count" \
    --json number,title,body,mergedAt,author,url,baseRefName,headRefName \
    --jq "sort_by(.mergedAt) | reverse | .[:$limit] | .[] |
      \"#\\(.number)  \\(.title)\\n\" +
      \"merged: \\(.mergedAt[0:10]) by \\(.author.login // \"unknown\")\\n\" +
      \"branch: \\(.headRefName) -> \\(.baseRefName)\\n\" +
      \"url:    \\(.url)\\n\\n\" +
      ((.body // \"\") | gsub(\"\\r\\n\"; \"\\n\") | gsub(\"\\r\"; \"\\n\") |
        if length == 0 then \"(no description)\" else . end) +
      \"\\n\\n------------------------------------------------------------\\n\""
}
```

## Fish

```fish
function pr-history
    set limit 10
    if test (count $argv) -gt 0
        set limit $argv[1]
    end

    if not string match -qr '^[0-9]+$' -- "$limit"
        echo "Usage: pr-history [count]" >&2
        return 2
    end

    set fetch_count 100
    if test $limit -gt $fetch_count
        set fetch_count $limit
    end

    type -q gh; or begin
        echo "gh is required: https://cli.github.com/" >&2
        return 127
    end
    gh auth status >/dev/null; or return $status
    gh pr list \
        --state merged \
        --search "sort:updated-desc" \
        --limit "$fetch_count" \
        --json number,title,body,mergedAt,author,url,baseRefName,headRefName \
        --jq "sort_by(.mergedAt) | reverse | .[:$limit] | .[] |
          \"#\\(.number)  \\(.title)\\n\" +
          \"merged: \\(.mergedAt[0:10]) by \\(.author.login // \"unknown\")\\n\" +
          \"branch: \\(.headRefName) -> \\(.baseRefName)\\n\" +
          \"url:    \\(.url)\\n\\n\" +
          ((.body // \"\") | gsub(\"\\r\\n\"; \"\\n\") | gsub(\"\\r\"; \"\\n\") |
            if length == 0 then \"(no description)\" else . end) +
          \"\\n\\n------------------------------------------------------------\\n\""
end
```

## PowerShell

```powershell
function Invoke-PrHistory {
    param(
        [int] $Limit = 10
    )

    $fetchCount = [Math]::Max(100, $Limit)
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Error 'gh is required: https://cli.github.com/'
        return
    }
    gh auth status *> $null
    if ($LASTEXITCODE -ne 0) { return }

    $jq = @'
sort_by(.mergedAt) | reverse | .[:__LIMIT__] | .[] |
  "#\(.number)  \(.title)\n" +
  "merged: \(.mergedAt[0:10]) by \(.author.login // "unknown")\n" +
  "branch: \(.headRefName) -> \(.baseRefName)\n" +
  "url:    \(.url)\n\n" +
  ((.body // "") | gsub("\r\n"; "\n") | gsub("\r"; "\n") |
    if length == 0 then "(no description)" else . end) +
  "\n\n------------------------------------------------------------\n"
'@ -replace '__LIMIT__', [string] $Limit

    gh pr list `
        --state merged `
        --search "sort:updated-desc" `
        --limit $fetchCount `
        --json number,title,body,mergedAt,author,url,baseRefName,headRefName `
        --jq $jq
}

Set-Alias pr-history Invoke-PrHistory
```

## Notes

- Increase `fetch_count` when the repository has very high PR volume and the
  requested history may not fit in the latest 100 merged PR candidates.
- Keep sorting on `mergedAt`, not creation date, so the visible order reflects
  what landed most recently.
