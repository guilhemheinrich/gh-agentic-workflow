#!/usr/bin/env bash
# Declares the bitbucket-pr-watch credential once, for bash and zsh, on Linux
# and macOS. Writes ~/.config/bitbucket-pr-watch/env (0600) with placeholders
# when absent, and adds one `source` line to each shell rc it finds.
# Idempotent: existing values are never overwritten, the source line is added
# once. `bbw setup` runs this, then fills the values without echoing them.
#
#   bash templates/bbw-env.sh
set -euo pipefail

env_file="${BBW_ENV_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/bitbucket-pr-watch/env}"
mkdir -p "$(dirname "$env_file")"

if [ -f "$env_file" ] && grep -q '^export BITBUCKET_WATCH_TOKEN=' "$env_file"; then
  echo "credential file already present: $env_file"
else
  (
    umask 077
    {
      printf '# bitbucket-pr-watch — read-only Bitbucket Cloud credential for bbw.\n'
      printf '# BITBUCKET_WATCH_USER is the Atlassian account email; the token is an\n'
      printf '# Atlassian API token with read:repository, read:pullrequest and\n'
      printf '# read:pipeline Bitbucket scopes. Rotate with `bbw setup --rotate`.\n'
      printf 'export BITBUCKET_WATCH_USER="PASTE_YOUR_EMAIL_HERE"\n'
      printf 'export BITBUCKET_WATCH_TOKEN="PASTE_YOUR_TOKEN_HERE"\n'
    } >>"$env_file"
  )
  echo "created $env_file"
fi
chmod 600 "$env_file"

# The secret lives in its own 0600 file; each rc only sources it, so a
# dotfiles repo never swallows it. Written with a literal $HOME to survive a
# home move. zsh reads .zshenv in every mode, and the Claude desktop app runs
# its shell tool as `zsh -c` (non-login, non-interactive): .zshenv is the only
# file that reaches it, so it is created for zsh users.
rc_path="$env_file"
case "$env_file" in "$HOME"/*) rc_path="\$HOME${env_file#"$HOME"}" ;; esac
if [ -f "$HOME/.zshrc" ] || [ -f "$HOME/.zprofile" ] || [ "${SHELL##*/}" = "zsh" ]; then
  [ -f "$HOME/.zshenv" ] || { touch "$HOME/.zshenv"; echo "created $HOME/.zshenv"; }
fi
for rc in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile" "$HOME/.zshenv"; do
  [ -f "$rc" ] || continue
  if grep -qF "bitbucket-pr-watch/env" "$rc"; then
    echo "already sourced from $rc"
  else
    printf '\n# bitbucket-pr-watch credential for bbw\n[ -f "%s" ] && . "%s"\n' "$rc_path" "$rc_path" >>"$rc"
    echo "source line added to $rc"
  fi
done
