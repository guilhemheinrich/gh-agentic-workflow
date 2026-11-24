# shellcheck shell=bash
# Authorization gate shared by every audit-infra script that sends traffic.
# Sourced, never executed. Compatible with bash 3.2 (macOS default).
#
# Contract (see ../AUTHORIZATION.md):
#   - the caller MUST pass `--i-am-authorized <host>`;
#   - <host> MUST equal the host of the target, case-insensitively;
#   - no wildcard, no CIDR, no "all": one flag authorizes one host for one run.
# Active scans (endpoint probes, testssl, nmap, nuclei) need a SECOND, separate statement:
#   `--active-scans-agreed <host>`, same exact-match rule (authz_gate_active).
# Being allowed to look at a host is not being allowed to scan it.
# Refusal exits with code 77 so wrappers can tell "refused" from "failed".

AUDIT_INFRA_EXIT_REFUSED=77

# url_host <url-or-host>  ->  prints the bare lowercase host
# "https://User@Shop.Example.com:8443/a?b" -> "shop.example.com"; "[::1]:8080" -> "::1"
url_host() {
  local h="$1"
  case "$h" in *://*) h="${h#*://}" ;; esac
  h="${h%%/*}"
  h="${h%%\?*}"
  h="${h##*@}"
  case "$h" in
    \[*\]*) h="${h#\[}"; h="${h%%\]*}" ;;
    *:*:*) : ;;            # bare IPv6 literal, keep as is
    *) h="${h%%:*}" ;;
  esac
  printf '%s' "$h" | tr '[:upper:]' '[:lower:]'
}

# authz_gate <target-host> <value of --i-am-authorized, may be empty> <script name>
authz_gate() {
  local target="$1" claimed="$2" script="$3"
  claimed="$(printf '%s' "$claimed" | tr '[:upper:]' '[:lower:]')"
  if [ -z "$target" ]; then
    printf '%s: refused: no target host could be parsed.\n' "$script" >&2
    exit "$AUDIT_INFRA_EXIT_REFUSED"
  fi
  if [ -z "$claimed" ]; then
    cat >&2 <<EOF
$script: refused: this script sends traffic to '$target' and needs an explicit
authorization for exactly that host:

    $script --i-am-authorized $target ...

Pass the flag only if you own '$target' or hold a written permission to test
it. An agent must get that confirmation from its user, in the conversation,
for this host, before adding the flag. See scripts/AUTHORIZATION.md.
EOF
    exit "$AUDIT_INFRA_EXIT_REFUSED"
  fi
  case "$claimed" in
    *\**|*/*|all|any)
      printf '%s: refused: --i-am-authorized takes one exact host, not a pattern (%s).\n' "$script" "$claimed" >&2
      exit "$AUDIT_INFRA_EXIT_REFUSED" ;;
  esac
  if [ "$claimed" != "$target" ]; then
    printf '%s: refused: authorized host "%s" does not match target host "%s".\n' "$script" "$claimed" "$target" >&2
    exit "$AUDIT_INFRA_EXIT_REFUSED"
  fi
  # Audit trail: who claimed what, when. Appended to a file when AUDIT_INFRA_LOG is set.
  local line
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) authorized host=$target script=$script user=${USER:-unknown}"
  printf 'audit-infra: %s\n' "$line" >&2
  if [ -n "${AUDIT_INFRA_LOG:-}" ]; then printf '%s\n' "$line" >>"$AUDIT_INFRA_LOG"; fi
}

# authz_gate_active <target-host> <value of --active-scans-agreed, may be empty> <script> <what>
# Call AFTER authz_gate, before the first active probe.
authz_gate_active() {
  local target="$1" claimed="$2" script="$3" what="$4"
  claimed="$(printf '%s' "$claimed" | tr '[:upper:]' '[:lower:]')"
  if [ "$claimed" != "$target" ]; then
    cat >&2 <<EOF
$script: refused: $what is an ACTIVE scan of '$target' (hundreds to thousands of
probes, visible in logs and to a WAF). It needs a second, separate statement:

    --active-scans-agreed $target

Pass it only if the owner agreed, for this host, to active scans in a stated time
window. "It is ours" or "audit it" is not that agreement. An agent must be able to
quote the user's own sentence granting it; otherwise report
"UNKNOWN: active scans not authorized". See scripts/AUTHORIZATION.md.
EOF
    exit "$AUDIT_INFRA_EXIT_REFUSED"
  fi
  local line
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) active-agreed host=$target script=$script scan=$what user=${USER:-unknown}"
  printf 'audit-infra: %s\n' "$line" >&2
  if [ -n "${AUDIT_INFRA_LOG:-}" ]; then printf '%s\n' "$line" >>"$AUDIT_INFRA_LOG"; fi
}
