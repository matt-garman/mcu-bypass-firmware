#!/usr/bin/env bash
# Immediately before publication, prove the remote tag still peels to the commit
# whose source/evidence history was verified at workflow start.
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
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]] \
	|| die "invalid release tag: $tag"
[[ "$expected_commit" =~ ^[0-9a-f]{40}$ ]] \
	|| die "expected release commit is not a full lowercase SHA-1"

refs=$(git ls-remote --tags "$remote" "refs/tags/$tag" "refs/tags/$tag^{}") \
	|| die "cannot query release tag $tag from $remote"
declare -a direct=() peeled=()
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
[ "${#peeled[@]}" -le 1 ] || die "remote peeled tag $tag is ambiguous"
if [ "${#peeled[@]}" -eq 1 ]; then target=${peeled[0]}; else target=${direct[0]}; fi
[ "$target" = "$expected_commit" ] \
	|| die "remote tag $tag moved: expected $expected_commit, found $target"

printf 'TAG-BOUND: %s on %s still targets verified commit %s.\n' \
	"$tag" "$remote" "$expected_commit"
