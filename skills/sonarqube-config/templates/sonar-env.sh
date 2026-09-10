#!/usr/bin/env bash
# Declares the machine-level SonarQube variables once, for bash and zsh, on Linux
# and macOS. Writes ~/.config/sonarqube/admin.env (0600) and adds one `source`
# line to each shell rc it finds. Idempotent: existing values are never
# overwritten, the source line is added once.
#
#   bash templates/sonar-env.sh [https://sonarqube.example.com]
#
# The optional argument pre-fills SONAR_HOST_URL. The token always starts as a
# placeholder: paste a USER_TOKEN (squ_…) of an account holding the "Create
# Projects" permission over PASTE_YOUR_ADMIN_TOKEN_HERE.
set -euo pipefail

host="${1:-PASTE_HOST_URL_HERE}"
env_file="${SONAR_ENV_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/sonarqube/admin.env}"
mkdir -p "$(dirname "$env_file")"

if [ -f "$env_file" ] && grep -q '^export SONAR_ADMIN_TOKEN=' "$env_file"; then
  echo "already declared in $env_file — edit it in place:"
  grep -n '^export SONAR_' "$env_file" | sed -E 's/(squ_|sqp_|sqa_)[0-9a-f]+/\1…/'
else
  {
    printf '# SonarQube — machine-level access for sonarctl.sh (bind, doctor).\n'
    printf '# SONAR_ADMIN_TOKEN is a USER_TOKEN (squ_…) with the "Create Projects" permission.\n'
    printf '# Project analysis tokens never live here: `sonarctl.sh bind` writes them to\n'
    printf '# <repo>/.sonar-config.\n'
    printf 'export SONAR_HOST_URL="%s"\n' "$host"
    printf 'export SONAR_ADMIN_TOKEN="PASTE_YOUR_ADMIN_TOKEN_HERE"\n'
  } >>"$env_file"
  echo "added to $env_file"
fi
chmod 600 "$env_file"

# The secret lives in its own 0600 file; the rc only sources it, so a dotfiles
# repo never swallows it. Written with a literal $HOME to survive a home move.
#
# Which rc, and why several: bash reads .bashrc when interactive and
# .bash_profile (else .profile) when a login shell; zsh reads .zshenv in EVERY
# mode, and a GUI-launched agent runs `zsh -c` — non-login, non-interactive — so
# .zshenv is the only file that reaches it (measured 2026-09-10: the Claude
# desktop app's shell tool is exactly that). .zshenv is created when the user
# is a zsh user; the others are amended only when they already exist.
rc_path="$env_file"
case "$env_file" in "$HOME"/*) rc_path="\$HOME${env_file#"$HOME"}" ;; esac
if [ -f "$HOME/.zshrc" ] || [ -f "$HOME/.zprofile" ] || [ "${SHELL##*/}" = "zsh" ]; then
  [ -f "$HOME/.zshenv" ] || { touch "$HOME/.zshenv"; echo "created $HOME/.zshenv (the one file every zsh mode reads)"; }
fi
for rc in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile" "$HOME/.zshenv"; do
  [ -f "$rc" ] || continue
  if grep -qF "sonarqube/admin.env" "$rc"; then
    echo "already sourced from $rc"
  else
    printf '\n# SonarQube machine-level variables for sonarctl.sh\n[ -f "%s" ] && . "%s"\n' "$rc_path" "$rc_path" >>"$rc"
    echo "source line added to $rc"
  fi
done

echo
echo "1. in SonarQube: My Account → Security → Generate Tokens, type User Token, on an account with Create Projects"
echo "2. replace PASTE_YOUR_ADMIN_TOKEN_HERE${1:+ } in $env_file"
echo "3. open a new shell, then: sonarctl.sh doctor"
