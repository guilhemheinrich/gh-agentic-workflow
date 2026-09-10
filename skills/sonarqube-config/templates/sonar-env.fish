#!/usr/bin/env fish
# Declares the machine-level SonarQube variables once, for fish, on macOS and
# Linux. The values live in ~/.config/sonarqube/admin.env — the SAME file the
# bash/zsh template writes — and ~/.config/fish/conf.d/sonarqube.fish only reads
# it. One file to edit, whichever shell starts the agent. Idempotent.
#
#   fish templates/sonar-env.fish [https://sonarqube.example.com]

set -l host (test -n "$argv[1]"; and echo $argv[1]; or echo PASTE_HOST_URL_HERE)
set -l env_file (set -q SONAR_ENV_FILE; and echo $SONAR_ENV_FILE; or echo (set -q XDG_CONFIG_HOME; and echo $XDG_CONFIG_HOME; or echo ~/.config)/sonarqube/admin.env)
set -l conf ~/.config/fish/conf.d/sonarqube.fish
mkdir -p (dirname $env_file) (dirname $conf)

if test -f $env_file; and grep -q '^export SONAR_ADMIN_TOKEN=' $env_file
    echo "already declared in $env_file — edit it in place:"
    grep -n '^export SONAR_' $env_file | sed -E 's/(squ_|sqp_|sqa_)[0-9a-f]+/\1…/'
else
    printf '# SonarQube — machine-level access for sonarctl.sh (bind, doctor).\n' >> $env_file
    printf '# SONAR_ADMIN_TOKEN is a USER_TOKEN (squ_…) with the "Create Projects" permission.\n' >> $env_file
    printf '# Project analysis tokens never live here: `sonarctl.sh bind` writes them to\n' >> $env_file
    printf '# <repo>/.sonar-config.\n' >> $env_file
    printf 'export SONAR_HOST_URL="%s"\n' $host >> $env_file
    printf 'export SONAR_ADMIN_TOKEN="PASTE_YOUR_ADMIN_TOKEN_HERE"\n' >> $env_file
    echo "added to $env_file"
end
chmod 600 $env_file

# The conf.d loader parses `export KEY="value"` lines itself: fish has no
# `source` for bash syntax, and duplicating the token here would mean two
# places to rotate it.
if test -f $conf; and grep -q 'sonarqube/admin.env' $conf
    echo "already loaded from $conf"
else
    printf '%s\n' \
        '# SonarQube machine-level variables for sonarctl.sh — values live in admin.env.' \
        'set -l __sonar_env (set -q SONAR_ENV_FILE; and echo $SONAR_ENV_FILE; or echo (set -q XDG_CONFIG_HOME; and echo $XDG_CONFIG_HOME; or echo ~/.config)/sonarqube/admin.env)' \
        'if test -f $__sonar_env' \
        '    for __line in (grep -E "^export SONAR_[A-Z_]+=" $__sonar_env)' \
        '        set -l __kv (string replace -r "^export " "" -- $__line)' \
        '        set -l __k (string split -m1 = -- $__kv)[1]' \
        '        set -l __v (string split -m1 = -- $__kv)[2]' \
        '        set -gx $__k (string trim -c "\"'"'"'" -- $__v)' \
        '    end' \
        'end' >> $conf
    chmod 600 $conf
    echo "loader added to $conf"
end

echo
echo "1. in SonarQube: My Account → Security → Generate Tokens, type User Token, on an account with Create Projects"
echo "2. replace PASTE_YOUR_ADMIN_TOKEN_HERE in $env_file"
echo "3. open a new shell, then: sonarctl.sh doctor"
