#!/usr/bin/env bash
# Bind one PIC12F675 programming snapshot to a clean, signed release checkout.
set -euo pipefail
LC_ALL=C
export LC_ALL

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

usage() {
	printf 'usage: %s source <release-tag>\n' "$0" >&2
	printf '       %s image <release-tag> <variant> <candidate-hex>\n' "$0" >&2
	exit 2
}

[ "$#" -ge 1 ] || usage
mode=$1
shift
case "$mode" in
	source) [ "$#" -eq 1 ] || usage ;;
	image) [ "$#" -eq 3 ] || usage ;;
	*) usage ;;
esac

release_tag=$1
[[ "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] \
	|| die "invalid release tag: $release_tag"
git check-ref-format "refs/tags/$release_tag" >/dev/null 2>&1 \
	|| die "invalid release tag: $release_tag"

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) \
	|| die "cannot locate release-program image verifier"
repo_root=$(cd -- "$script_dir/.." && pwd -P) \
	|| die "cannot locate repository root"
signature_verifier="$script_dir/verify-release-signature.sh"
image_verifier="$script_dir/verify-release-images.sh"
[ -x "$signature_verifier" ] && [ -f "$signature_verifier" ] \
	&& [ ! -L "$signature_verifier" ] \
	|| die "release signature verifier is missing or not executable"
[ -x "$image_verifier" ] && [ -f "$image_verifier" ] \
	&& [ ! -L "$image_verifier" ] \
	|| die "release image verifier is missing or not executable"
# shellcheck source=release-signing-policy.sh
source "$script_dir/release-signing-policy.sh" \
	|| die "cannot load release signing policy"

check_source() {
	local tag_object tag_type embedded_tag tag_commit head_commit status
	local signature_output expected_signature

	git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
		|| die "release programming must run inside a Git worktree"
	tag_object=$(git -C "$repo_root" rev-parse --verify "refs/tags/$release_tag^{object}" 2>/dev/null) \
		|| die "release tag does not exist: $release_tag"
	[[ "$tag_object" =~ ^[0-9a-f]{40}$ ]] \
		|| die "release tag object is not a full lowercase SHA-1"
	tag_type=$(git -C "$repo_root" cat-file -t "$tag_object" 2>/dev/null) \
		|| die "cannot inspect release tag object: $release_tag"
	[ "$tag_type" = tag ] || die "release tag is not an annotated tag: $release_tag"
	embedded_tag=$(git -C "$repo_root" for-each-ref --format='%(tag)' \
		"refs/tags/$release_tag") \
		|| die "cannot inspect annotated release tag name"
	[ "$embedded_tag" = "$release_tag" ] \
		|| die "annotated release tag name does not match requested tag"
	tag_commit=$(git -C "$repo_root" rev-parse --verify \
		"refs/tags/$release_tag^{commit}" 2>/dev/null) \
		|| die "release tag cannot be peeled to a commit: $release_tag"
	head_commit=$(git -C "$repo_root" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) \
		|| die "cannot resolve checked-out HEAD"
	[ "$head_commit" = "$tag_commit" ] \
		|| die "checked-out HEAD is not release tag $release_tag"
	status=$(git -C "$repo_root" status --porcelain=v1 --untracked-files=all) \
		|| die "cannot inspect release-programming worktree"
	[ -z "$status" ] \
		|| die "release-programming worktree is not clean"

	signature_output=$(TMPDIR="$temp_root" "$signature_verifier" \
		tag "$repo_root" "$tag_object") \
		|| die "release tag signature verification failed"
	expected_signature="SIGNATURE-VALID: tag signature made by $RELEASE_SIGNING_FINGERPRINT."
	[ "$signature_output" = "$expected_signature" ] \
		|| die "release tag verifier did not emit its exact success record"
}

temp_root=${TMPDIR:-${XDG_RUNTIME_DIR:-${HOME:-}}}
[ -n "$temp_root" ] && [ -d "$temp_root" ] \
	|| die "set TMPDIR, XDG_RUNTIME_DIR, or HOME to an existing temporary root"

if [ "$mode" = source ]; then
	check_source
	printf 'PIC12F675_RELEASE_SOURCE_CHECK PASS tag=%s\n' "$release_tag"
	exit 0
fi

variant=$2
candidate=$3
case "$variant" in
	cd4053_simple|cd4053_with_mute|tq2_l2_5v_relay) ;;
	*) die "unsupported PIC12F675 release variant: $variant" ;;
esac
[ -f "$candidate" ] && [ ! -L "$candidate" ] && [ -s "$candidate" ] \
	|| die "candidate image is missing, empty, or not a regular file: $candidate"

check_source
release_dir="$repo_root/release/$release_tag"
[ -d "$release_dir" ] && [ ! -L "$release_dir" ] \
	|| die "release directory is missing or not a real directory: $release_dir"

work=$(mktemp -d "$temp_root/release-program-image.XXXXXX") \
	|| die "cannot create release-program verification directory"
trap 'rm -rf "$work"' EXIT
release_snapshot="$work/release"
candidate_set="$work/candidate-set"
mkdir -m 700 "$release_snapshot" "$candidate_set" \
	|| die "cannot create private release snapshots"
cp -a -- "$release_dir/." "$release_snapshot/" \
	|| die "cannot snapshot release metadata and images"

checksum_file="$release_snapshot/SHA256SUMS"
checksum_signature="$release_snapshot/SHA256SUMS.asc"
[ -f "$checksum_file" ] && [ ! -L "$checksum_file" ] && [ -s "$checksum_file" ] \
	|| die "release SHA256SUMS is missing, empty, or not a regular file"
[ -f "$checksum_signature" ] && [ ! -L "$checksum_signature" ] \
	&& [ -s "$checksum_signature" ] \
	|| die "release SHA256SUMS signature is missing, empty, or not a regular file"

detached_output=$(TMPDIR="$temp_root" "$signature_verifier" detached \
	"$checksum_signature" "$checksum_file") \
	|| die "release checksum signature verification failed"
expected_detached="SIGNATURE-VALID: detached signature made by $RELEASE_SIGNING_FINGERPRINT."
[ "$detached_output" = "$expected_detached" ] \
	|| die "release checksum verifier did not emit its exact success record"

hash_file() {
	local output digest
	output=$(sha256sum -- "$1") || return 1
	digest=${output%% *}
	[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
	printf '%s' "$digest"
}

candidate_digest_before=$(hash_file "$candidate") \
	|| die "cannot hash candidate image: $candidate"
cp -a -- "$release_snapshot/." "$candidate_set/" \
	|| die "cannot create candidate release image set"
selected_basename="bypass-pic12f675-$variant.hex"
cp -a -- "$candidate" "$candidate_set/$selected_basename" \
	|| die "cannot snapshot candidate image"
[ -f "$candidate_set/$selected_basename" ] \
	&& [ ! -L "$candidate_set/$selected_basename" ] \
	&& [ -s "$candidate_set/$selected_basename" ] \
	|| die "candidate snapshot is not a nonempty regular file"
candidate_digest_after=$(hash_file "$candidate") \
	|| die "cannot re-hash candidate image: $candidate"
candidate_copy_digest=$(hash_file "$candidate_set/$selected_basename") \
	|| die "cannot hash candidate image snapshot"
[ "$candidate_digest_before" = "$candidate_digest_after" ] \
	&& [ "$candidate_digest_before" = "$candidate_copy_digest" ] \
	|| die "candidate image changed while being snapshotted"

verification_output=$(TMPDIR="$temp_root" "$image_verifier" \
	"$release_snapshot" "$candidate_set") \
	|| die "candidate image does not match the signed release image set"
mapfile -t verification_lines <<<"$verification_output"
[ "${#verification_lines[@]}" -gt 0 ] \
	|| die "release image verifier emitted no success record"
terminal_record=${verification_lines[${#verification_lines[@]}-1]}
[[ "$terminal_record" =~ ^REPRODUCED:\ [1-9][0-9]*\ committed,\ listed,\ and\ freshly\ built\ images\ match\ the\ canonical\ set\ exactly\.$ ]] \
	|| die "release image verifier did not emit its exact terminal record"

printf 'PIC12F675_RELEASE_IMAGE_CHECK PASS tag=%s variant=%s image=%s sha256=%s\n' \
	"$release_tag" "$variant" "$candidate" "$candidate_digest_before"
