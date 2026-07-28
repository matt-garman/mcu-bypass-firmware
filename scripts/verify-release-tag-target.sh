#!/usr/bin/env bash
# Immediately before publication, prove the remote tag is an annotated tag
# signed by the pinned maintainer key and still peels to the release commit whose
# source/evidence history was verified at workflow start.
set -euo pipefail
LC_ALL=C
export LC_ALL

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

if [ "$#" -ne 3 ]; then
	printf 'usage: %s <remote> <version-tag> <expected-commit>\n' "$0" >&2
	exit 2
fi

remote=$1
tag=$2
expected_commit=$3
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] \
	|| die "invalid release tag: $tag"
git check-ref-format "refs/tags/$tag" >/dev/null 2>&1 \
	|| die "invalid release tag: $tag"
[[ "$expected_commit" =~ ^[0-9a-f]{40}$ ]] \
	|| die "expected release commit is not a full lowercase SHA-1"

resolve_remote_tag() {
	local refs object ref
	refs=$(git ls-remote --tags "$remote" "refs/tags/$tag" "refs/tags/$tag^{}") \
		|| die "cannot query release tag $tag from $remote"
	direct=()
	peeled=()
	while IFS=$'\t' read -r object ref; do
		[ -n "$object" ] || continue
		[[ "$object" =~ ^[0-9a-f]{40}$ ]] \
			|| die "remote returned a malformed object ID for $tag"
		case "$ref" in
			"refs/tags/$tag") direct+=("$object") ;;
			"refs/tags/$tag^{}") peeled+=("$object") ;;
			*) die "remote returned an unexpected ref while resolving $tag: $ref" ;;
		esac
	done <<<"$refs"
	[ "${#direct[@]}" -eq 1 ] || die "remote tag $tag is missing or ambiguous"
	[ "${#peeled[@]}" -eq 1 ] \
		|| die "remote release tag $tag must be one annotated tag"
}

declare -a direct=() peeled=()
resolve_remote_tag
remote_tag_object=${direct[0]}
remote_target=${peeled[0]}
[ "$remote_target" = "$expected_commit" ] \
	|| die "remote tag $tag moved: expected $expected_commit, found $remote_target"

if remote_url=$(git remote get-url "$remote" 2>/dev/null); then :; else remote_url=$remote; fi
work=$(mktemp -d "${TMPDIR:-/tmp}/release-tag.XXXXXX") \
	|| die "cannot create remote tag verification directory"
trap 'rm -rf "$work"' EXIT
git init --bare -q "$work/tag.git" \
	|| die "cannot initialize tag verification repository"
git -C "$work/tag.git" fetch --quiet --depth=1 --no-tags "$remote_url" \
	"refs/tags/$tag:refs/tags/$tag" \
	|| die "cannot fetch remote release tag $tag for signature verification"
fetched_object=$(git -C "$work/tag.git" rev-parse "refs/tags/$tag") \
	|| die "cannot resolve fetched release tag object"
[ "$fetched_object" = "$remote_tag_object" ] \
	|| die "remote tag $tag changed while it was fetched"
fetched_target=$(git -C "$work/tag.git" rev-parse "refs/tags/$tag^{}") \
	|| die "cannot peel fetched release tag"
[ "$fetched_target" = "$expected_commit" ] \
	|| die "fetched tag $tag moved: expected $expected_commit, found $fetched_target"
embedded_tag=$(git -C "$work/tag.git" for-each-ref --format='%(tag)' "refs/tags/$tag") \
	|| die "cannot read fetched annotated-tag name"
[ "$embedded_tag" = "$tag" ] \
	|| die "remote ref $tag contains a signed tag object named $embedded_tag"

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) \
	|| die "cannot locate release tag verifier"
"$script_dir/verify-release-signature.sh" tag "$work/tag.git" "$fetched_object" \
	>/dev/null || die "remote release tag $tag does not have the required signature"

# Detect a same-target tag-object replacement after verification. Repository tag
# protection closes the remaining interval before the create-release API call.
resolve_remote_tag
[ "${direct[0]}" = "$remote_tag_object" ] && [ "${peeled[0]}" = "$remote_target" ] \
	|| die "remote tag $tag changed during signature verification"

printf 'TAG-BOUND: signed %s on %s still targets verified commit %s.\n' \
	"$tag" "$remote" "$expected_commit"
