#!/usr/bin/env bash
# rotate-npm-publish-token.sh — create a correctly scoped npm publish token.
#
# For registries WITHOUT trusted publishing (Bitbucket Pipelines today). If your
# CI is GitHub Actions, GitLab CI/CD or CircleCI, do not use this: register a
# trusted publisher instead and carry no credential at all.
#
# What this buys you over the npmjs web form: identical scoping every quarter,
# --bypass-2fa never forgotten (its absence makes every publish fail with EOTP,
# and it cannot be added to an existing token), a dated name so the next
# rotation is obvious, and a real publish check before the old token is revoked.
#
# What it does NOT buy: an unattended rotation. Creating a token needs the
# account password and, with 2FA on, a one-time code. Storing a TOTP secret to
# remove that step would trade away the whole point.
#
# Usage:
#   ./rotate-npm-publish-token.sh --scope @septeo-immo
#   ./rotate-npm-publish-token.sh --package @septeo-immo/spaghetti-compass
#   ./rotate-npm-publish-token.sh --package @org/pkg --expires 60 --verify-publish .
#   ./rotate-npm-publish-token.sh --scope @org --dry-run
#
# Options:
#   --scope <@scope>      scope the token to a whole npm scope
#   --package <name>      scope it to one package (narrower — prefer this)
#   --expires <days>      lifetime in days, default 90 (npm's write-token cap)
#   --name <name>         token name, default <target>-publish-<YYYY-MM>
#   --verify-publish <d>  run `npm publish --dry-run` in <d> with the new token
#   --revoke <id>         revoke this token id, only after verification passes
#   --dry-run             print the command that would run, create nothing
#
# Honours NPM_BIN, so the npm call can be wrapped on a Docker-only host.
#
# The new token is printed ONCE on stdout, alone on its last line, so it can be
# piped into a secret store. Nothing else on stdout. Do not paste it into a
# shell history or a ticket.

set -euo pipefail

NPM_BIN="${NPM_BIN:-npm}"
SCOPE=""
PACKAGE=""
EXPIRES=90
NAME=""
VERIFY_DIR=""
REVOKE_ID=""
DRY_RUN=0

die() {
	printf '%s\n' "$*" >&2
	exit 2
}

while [ $# -gt 0 ]; do
	case "$1" in
	--scope)
		shift
		SCOPE="${1:?--scope needs a value}"
		;;
	--package)
		shift
		PACKAGE="${1:?--package needs a value}"
		;;
	--expires)
		shift
		EXPIRES="${1:?--expires needs a value}"
		;;
	--name)
		shift
		NAME="${1:?--name needs a value}"
		;;
	--verify-publish)
		shift
		VERIFY_DIR="${1:?--verify-publish needs a directory}"
		;;
	--revoke)
		shift
		REVOKE_ID="${1:?--revoke needs a token id}"
		;;
	--dry-run) DRY_RUN=1 ;;
	-h | --help)
		sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*) die "unknown argument: $1" ;;
	esac
	shift
done

[ -n "$SCOPE" ] || [ -n "$PACKAGE" ] || die "one of --scope or --package is required"
[ -z "$SCOPE" ] || [ -z "$PACKAGE" ] || die "--scope and --package are mutually exclusive"

case "$EXPIRES" in
'' | *[!0-9]*) die "--expires must be a whole number of days" ;;
esac
[ "$EXPIRES" -ge 1 ] || die "--expires must be at least 1"
if [ "$EXPIRES" -gt 90 ]; then
	die "--expires above 90 is refused by npm for a write token; 90 is the cap"
fi

TARGET_FLAG=()
if [ -n "$SCOPE" ]; then
	case "$SCOPE" in @*) ;; *) die "--scope must start with @, e.g. @septeo-immo" ;; esac
	TARGET_FLAG=(--scopes "$SCOPE")
	SLUG="${SCOPE#@}"
else
	TARGET_FLAG=(--packages "$PACKAGE")
	SLUG="$(printf '%s' "$PACKAGE" | tr -c 'a-zA-Z0-9' '-' | sed 's/^-*//; s/-*$//')"
fi

[ -n "$NAME" ] || NAME="${SLUG}-publish-$(date -u +%Y-%m)"

CREATE_CMD=(
	$NPM_BIN token create
	--name "$NAME"
	--token-description "CI publish token, scoped, rotate before expiry"
	--expires "$EXPIRES"
	"${TARGET_FLAG[@]}"
	--packages-and-scopes-permission read-write
	--orgs-permission no-access
	--bypass-2fa
)

if [ "$DRY_RUN" -eq 1 ]; then
	printf 'Would run:\n' >&2
	printf '  %q' "${CREATE_CMD[@]}" >&2
	printf '\n' >&2
	exit 0
fi

printf 'Creating token %s (expires in %s days). npm will ask for your password and OTP.\n' \
	"$NAME" "$EXPIRES" >&2

# npm prints the token among other lines; keep only something token-shaped and
# never echo the whole output.
CREATE_OUT="$("${CREATE_CMD[@]}" 2>&1)" || {
	printf '%s\n' "$CREATE_OUT" | grep -viE 'npm_[A-Za-z0-9]{10,}' >&2
	die "token creation failed (output above, token values stripped)"
}

NEW_TOKEN="$(printf '%s\n' "$CREATE_OUT" | grep -oE 'npm_[A-Za-z0-9_-]{20,}' | head -1 || true)"
[ -n "$NEW_TOKEN" ] || die "could not find a token in npm's output; nothing was verified or revoked"

printf 'Token created. Verifying it before touching the old one.\n' >&2

NPMRC="$(mktemp)"
cleanup() { rm -f "$NPMRC"; }
trap cleanup EXIT
printf '//registry.npmjs.org/:_authToken=%s\n' "$NEW_TOKEN" >"$NPMRC"

if ! $NPM_BIN whoami --userconfig "$NPMRC" --registry https://registry.npmjs.org/ >/dev/null 2>&1; then
	die "the new token does not authenticate. Old token left untouched."
fi
printf '  whoami: ok\n' >&2

if [ -n "$VERIFY_DIR" ]; then
	if ! $NPM_BIN publish "$VERIFY_DIR" --dry-run --userconfig "$NPMRC" \
		--registry https://registry.npmjs.org/ >/dev/null 2>&1; then
		die "publish --dry-run failed with the new token. Old token left untouched."
	fi
	printf '  publish --dry-run: ok\n' >&2
fi

if [ -n "$REVOKE_ID" ]; then
	printf 'Revoking old token %s\n' "$REVOKE_ID" >&2
	$NPM_BIN token revoke "$REVOKE_ID" >/dev/null || die "revoke failed; the NEW token is live, revoke $REVOKE_ID by hand"
	printf '  revoked\n' >&2
fi

cat >&2 <<EOF

Next: store the token below in your CI as a masked/secured variable.
  Bitbucket: Repository settings > Repository variables > NPM_TOKEN, Secured ticked.
Then rotate again before $(date -u -v +"${EXPIRES}"d +%Y-%m-%d 2>/dev/null || date -u -d "+${EXPIRES} days" +%Y-%m-%d 2>/dev/null || echo "the expiry above").
The token is on the last line of stdout and appears nowhere else.

EOF

printf '%s\n' "$NEW_TOKEN"
