#!/usr/bin/env bash
# Shared release-signing trust root and machine-status policy.

_release_signing_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P) \
	|| return 1
RELEASE_SIGNING_FINGERPRINT=6184219C6670945D7174F2B0149F042FCC3D3AEC
RELEASE_SIGNING_PUBLIC_KEY=$_release_signing_root/release/signing-key.asc
readonly RELEASE_SIGNING_FINGERPRINT RELEASE_SIGNING_PUBLIC_KEY
unset _release_signing_root

release_signature_status_matches_policy() {
	local status_file=$1
	local -a newsig_records=() goodsig_records=() valid_fingerprints=()
	[ -f "$status_file" ] && [ ! -L "$status_file" ] || return 1
	mapfile -t newsig_records < <(
		awk '$1 == "[GNUPG:]" && $2 == "NEWSIG" { print }' "$status_file"
	)
	mapfile -t goodsig_records < <(
		awk '$1 == "[GNUPG:]" && $2 == "GOODSIG" { print }' "$status_file"
	)
	mapfile -t valid_fingerprints < <(
		awk '$1 == "[GNUPG:]" && $2 == "VALIDSIG" {
			if (NF >= 12) print $12; else print $3
		}' "$status_file"
	)
	[ "${#newsig_records[@]}" -eq 1 ] \
		&& [ "${#goodsig_records[@]}" -eq 1 ] \
		&& [ "${#valid_fingerprints[@]}" -eq 1 ] \
		&& [ "${valid_fingerprints[0]}" = "$RELEASE_SIGNING_FINGERPRINT" ] \
		|| return 1
	# GnuPG may exit zero and emit VALIDSIG for a cryptographically correct
	# signature whose key or signature is expired/revoked. Those are not valid
	# release identities under this policy.
	if awk '$1 == "[GNUPG:]" &&
		$2 ~ /^(BADSIG|ERRSIG|EXPSIG|EXPKEYSIG|REVKEYSIG|KEYEXPIRED|SIGEXPIRED|KEYREVOKED)$/ {
		bad=1
	} END { exit bad ? 0 : 1 }' "$status_file"; then
		return 1
	fi
	return 0
}
