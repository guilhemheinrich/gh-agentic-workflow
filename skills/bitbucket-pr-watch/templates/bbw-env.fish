# bitbucket-pr-watch — load the read-only Bitbucket credential for bbw.
# Installed by `bbw setup` into ~/.config/fish/conf.d/. The env file is the
# single source; this only translates its `export K="V"` lines for fish.
set -l bbw_env_file "@ENV_FILE@"
if test -f "$bbw_env_file"
    for line in (string match -r '^export [A-Z_]+=.*' < "$bbw_env_file")
        set -l kv (string replace -r '^export ' '' -- $line | string split -m1 =)
        set -gx $kv[1] (string trim -c '"' -- $kv[2])
    end
end
