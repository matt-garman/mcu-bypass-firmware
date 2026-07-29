#!/usr/bin/env bash
# Verify one detached release signature or one signed Git tag against the pinned
# maintainer key, using an isolated keyring rather than ambient runner trust.
set -euo pipefail
LC_ALL=C
export LC_ALL

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

if [ "$#" -lt 1 ]; then
	printf 'usage: %s detached <signature> <signed-file>\n' "$0" >&2
	printf '       %s tag <git-dir> <tag-object>\n' "$0" >&2
	exit 2
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) \
	|| die "cannot locate release signature verifier"
# shellcheck source=release-signing-policy.sh
source "$script_dir/release-signing-policy.sh" \
	|| die "cannot load release signing policy"
[[ "$RELEASE_SIGNING_FINGERPRINT" =~ ^[0-9A-F]{40}$ ]] \
	|| die "release signing fingerprint is not 40 uppercase hexadecimal digits"
[ -f "$RELEASE_SIGNING_PUBLIC_KEY" ] && [ ! -L "$RELEASE_SIGNING_PUBLIC_KEY" ] \
	&& [ -s "$RELEASE_SIGNING_PUBLIC_KEY" ] \
	|| die "release public key is missing, empty, or not a regular file"
command -v gpg >/dev/null 2>&1 || die "gpg is required to verify release signatures"

work=$(mktemp -d "${TMPDIR:-/tmp}/release-signature.XXXXXX") \
	|| die "cannot create release signature work directory"
trap 'rm -rf "$work"' EXIT
keyring="$work/gnupg"
mkdir -m 700 "$keyring" || die "cannot create isolated release keyring"
gpg --batch --no-options --homedir "$keyring" --import-options import-minimal \
	--import "$RELEASE_SIGNING_PUBLIC_KEY" >"$work/import.out" 2>"$work/import.err" \
	|| die "cannot import the pinned release public key"

key_listing=$(gpg --batch --no-options --homedir "$keyring" --with-colons \
	--fingerprint --list-keys 2>/dev/null) \
	|| die "cannot inspect the imported release public key"
mapfile -t primary_fingerprints < <(
	awk -F: '$1 == "pub" { need_fpr=1; next }
		need_fpr && $1 == "fpr" { print $10; need_fpr=0 }' <<<"$key_listing"
)
[ "${#primary_fingerprints[@]}" -eq 1 ] \
	|| die "release public key file must contain exactly one primary key"
[ "${primary_fingerprints[0]}" = "$RELEASE_SIGNING_FINGERPRINT" ] \
	|| die "release public key fingerprint does not match policy"
if gpg --batch --no-options --homedir "$keyring" --with-colons \
		--list-secret-keys 2>/dev/null | grep -q '^sec:'; then
	die "release public key file contains secret key material"
fi

status="$work/status"
diagnostic="$work/diagnostic"
case "$1" in
	detached)
		[ "$#" -eq 3 ] || die "detached mode requires <signature> <signed-file>"
		signature=$2
		signed_file=$3
		[ -f "$signature" ] && [ ! -L "$signature" ] && [ -s "$signature" ] \
			|| die "detached signature is missing, empty, or not a regular file"
		[ -f "$signed_file" ] && [ ! -L "$signed_file" ] && [ -s "$signed_file" ] \
			|| die "signed file is missing, empty, or not a regular file"
		if ! gpg --batch --no-options --homedir "$keyring" --status-fd 3 \
				--verify "$signature" "$signed_file" \
				3>"$status" 2>"$diagnostic"; then
			die "detached release signature is invalid"
		fi
		;;
	tag)
		[ "$#" -eq 3 ] || die "tag mode requires <git-dir> <tag-object>"
		git_dir=$2
		tag_object=$3
		[ -d "$git_dir" ] || die "tag verification Git directory not found"
		[[ "$tag_object" =~ ^[0-9a-f]{40}$ ]] \
			|| die "tag object is not a full lowercase SHA-1"
		[ "$(git -C "$git_dir" cat-file -t "$tag_object" 2>/dev/null)" = tag ] \
			|| die "release tag object is not an annotated tag"
		if ! GNUPGHOME="$keyring" git -C "$git_dir" \
				-c gpg.format=openpgp -c gpg.openpgp.program=gpg \
				verify-tag --raw "$tag_object" >/dev/null 2>"$status"; then
			die "release tag signature is invalid"
		fi
		;;
	*) die "unknown release signature mode: $1" ;;
esac

release_signature_status_matches_policy "$status" \
	|| die "release signature does not satisfy pinned-key status policy"

printf 'SIGNATURE-VALID: %s signature made by %s.\n' \
	"$1" "$RELEASE_SIGNING_FINGERPRINT"
