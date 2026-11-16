#!/usr/bin/env bash
# Creates or amends ~/.config/openrouter/key.env and sources it from your shell
# rc, then tells you what to edit. For bash and zsh, on Linux and macOS.
# Idempotent: an existing key is never overwritten, the source line is added once.
#
#   bash templates/openrouter-key.sh
set -euo pipefail

key_file="${XDG_CONFIG_HOME:-$HOME/.config}/openrouter/key.env"
mkdir -p "$(dirname "$key_file")"

if [ -f "$key_file" ] && grep -q OPENROUTER_API_KEY "$key_file"; then
  echo "already declared in $key_file — edit it in place:"
  grep -n OPENROUTER_API_KEY "$key_file"
else
  printf '# OpenRouter — https://openrouter.ai/keys\nexport OPENROUTER_API_KEY="PASTE_YOUR_KEY_HERE"\n' >>"$key_file"
  echo "added to $key_file"
fi
chmod 600 "$key_file"

# The key lives in its own 0600 file; the rc only sources it. That keeps the
# secret out of a dotfile you might one day push to a dotfiles repo. The line is
# written with a literal $HOME so it survives a home-directory move.
rc_path="$key_file"
case "$key_file" in "$HOME"/*) rc_path="\$HOME${key_file#"$HOME"}" ;; esac
for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
  [ -f "$rc" ] || continue
  if grep -qF "openrouter/key.env" "$rc"; then
    echo "already sourced from $rc"
  else
    printf '\n# OpenRouter key for llm-ask.sh\n[ -f "%s" ] && . "%s"\n' "$rc_path" "$rc_path" >>"$rc"
    echo "source line added to $rc"
  fi
done

echo
echo "1. get a key at https://openrouter.ai/keys"
echo "2. replace PASTE_YOUR_KEY_HERE in $key_file"
echo "3. open a new shell, then: llm-ask.sh --doctor"
