#!/usr/bin/env bash
# provider.sh — the one entry point for the host a subscription lives on.
#
# A repo key names a repository on one host:
#   "WS/REPO"            Bitbucket Cloud (the original form, kept so existing
#                        state keeps working)
#   "github:OWNER/REPO"  GitHub
# Every command, the daemon and the hooks go through these functions; the
# host-specific requests live in bitbucket.sh and github.sh.

# provider_of KEY — bitbucket | github
provider_of() {
  case "$1" in github:*) printf 'github\n' ;; *) printf 'bitbucket\n' ;; esac
}

# repo_of KEY — the path the host knows the repository by.
repo_of() {
  case "$1" in github:*) printf '%s\n' "${1#github:}" ;; *) printf '%s\n' "$1" ;; esac
}

# repo_from_remote [DIR] — the repo key of the origin remote, on a supported
# host only. Returns 1 when the remote is on neither host.
repo_from_remote() {
  local url key
  url="$(git -C "${1:-.}" remote get-url origin 2>/dev/null)" || return 1
  key="$(bitbucket_repo_from_url "$url")"
  [ -n "$key" ] || key="$(github_repo_from_url "$url")"
  [ -n "$key" ] || return 1
  printf '%s\n' "$key"
}

# check_credential KEY — 0 when the host of KEY has a credential loaded, else
# a message on stderr and 1.
check_credential() {
  case "$(provider_of "$1")" in
    github) github_check_credential ;;
    *) bitbucket_check_credential ;;
  esac
}

# snapshot_fetch KEY PR [PREV_SNAPSHOT_FILE] — the PR's snapshot JSON.
snapshot_fetch() {
  case "$(provider_of "$1")" in
    github) github_snapshot_fetch "$@" ;;
    *) bitbucket_snapshot_fetch "$@" ;;
  esac
}

# build_fetch KEY COMMIT [PR_SNAPSHOT_FILE] — the build snapshot of one commit.
build_fetch() {
  case "$(provider_of "$1")" in
    github) github_build_fetch "$@" ;;
    *) bitbucket_build_fetch "$@" ;;
  esac
}

# pr_for_branch KEY BRANCH — the open PR number of BRANCH, or nothing.
pr_for_branch() {
  case "$(provider_of "$1")" in
    github) github_pr_for_branch "$@" ;;
    *) bitbucket_pr_for_branch "$@" ;;
  esac
}

# pr_merge_commit KEY PR — the merge commit of a merged PR, or nothing.
pr_merge_commit() {
  case "$(provider_of "$1")" in
    github) github_pr_merge_commit "$@" ;;
    *) bitbucket_pr_merge_commit "$@" ;;
  esac
}
