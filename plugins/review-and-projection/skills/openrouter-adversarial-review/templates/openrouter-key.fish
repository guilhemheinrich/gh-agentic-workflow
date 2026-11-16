#!/usr/bin/env fish
# Creates or amends ~/.config/fish/conf.d/openrouter.fish, then tells you what to
# edit. Idempotent: an existing key is never overwritten, and the file is never
# duplicated. Run it, then paste your key over PASTE_YOUR_KEY_HERE.
#
#   fish templates/openrouter-key.fish

set -l target ~/.config/fish/conf.d/openrouter.fish
mkdir -p (dirname $target)

if test -f $target; and grep -q OPENROUTER_API_KEY $target
    echo "already declared in $target — edit it in place:"
    grep -n OPENROUTER_API_KEY $target
else
    printf '# OpenRouter — https://openrouter.ai/keys\nset -gx OPENROUTER_API_KEY "PASTE_YOUR_KEY_HERE"\n' >> $target
    echo "added to $target"
end

chmod 600 $target
echo
echo "1. get a key at https://openrouter.ai/keys"
echo "2. replace PASTE_YOUR_KEY_HERE in $target"
echo "3. open a new shell, then: llm-ask.sh --doctor"
