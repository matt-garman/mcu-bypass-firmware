#!/usr/bin/env bash
# Bind retained qualification to the source commit it exercised and to the
# release-artifact commit that a version tag publishes.
set -euo pipefail
LC_ALL=C
export LC_ALL

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

if [ "$#" -ne 3 ]; then
	printf 'usage: %s <release-dir> <expected-version> <release-commit>\n' "$0" >&2
	exit 2
fi

release_dir=$1
expected_version=$2
release_object=$3
[[ "$expected_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]] \
	|| die "invalid expected release version: $expected_version"
[[ "$release_object" =~ ^[0-9a-f]{40}$ ]] \
	|| die "release object is not a full lowercase SHA-1"
[ -d "$release_dir" ] || die "release directory not found: $release_dir"
release_dir=$(cd "$release_dir" && pwd -P) \
	|| die "cannot resolve release directory: $release_dir"

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P) \
	|| die "cannot locate repository root"
git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
	|| die "release history verifier is not inside a Git worktree"

qualification="$release_dir/QUALIFICATION"
[ -f "$qualification" ] && [ ! -L "$qualification" ] && [ -s "$qualification" ] \
	|| die "QUALIFICATION is missing, empty, or not a regular file"
mapfile -t source_lines < <(grep '^source_commit=' "$qualification" || true)
[ "${#source_lines[@]}" -eq 1 ] \
	|| die "QUALIFICATION must contain exactly one source_commit record"
source_commit=${source_lines[0]#source_commit=}
[[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] \
	|| die "QUALIFICATION source_commit is not a full lowercase SHA-1"

git -C "$repo_root" cat-file -e "$release_object^{commit}" 2>/dev/null \
	|| die "release object cannot be peeled to a commit: $release_object"
release_commit=$(git -C "$repo_root" rev-parse "$release_object^{commit}") \
	|| die "cannot resolve release commit from event object"
head_commit=$(git -C "$repo_root" rev-parse HEAD) \
	|| die "cannot resolve checked-out HEAD"
[ "$head_commit" = "$release_commit" ] \
	|| die "checked-out HEAD is not the release commit"

read -r -a ancestry <<<"$(git -C "$repo_root" rev-list --parents -n 1 "$release_commit")"
[ "${#ancestry[@]}" -eq 2 ] \
	|| die "release commit must have exactly one parent"
parent_commit=${ancestry[1]}
[ "$parent_commit" = "$source_commit" ] \
	|| die "release commit parent does not match QUALIFICATION source_commit"
git -C "$repo_root" cat-file -e "$source_commit^{commit}" 2>/dev/null \
	|| die "qualified source commit is unavailable: $source_commit"

release_prefix="release/$expected_version/"
qualification_path="${release_prefix}QUALIFICATION"
mapfile -d '' -t changed_paths < <(git -C "$repo_root" diff-tree -z \
	--no-commit-id --name-only -r "$release_commit")
[ "${#changed_paths[@]}" -gt 0 ] || die "release commit changes no files"
saw_qualification=0
for path in "${changed_paths[@]}"; do
	case "$path" in
		"$qualification_path") saw_qualification=1 ;;
		"$release_prefix"*) ;;
		*) die "release commit changes a path outside $release_prefix: $path" ;;
	esac
done
[ "$saw_qualification" -eq 1 ] \
	|| die "release commit does not add $qualification_path"

if git -C "$repo_root" cat-file -e "$source_commit:$qualification_path" 2>/dev/null; then
	die "qualified source commit already contains $qualification_path"
fi
git -C "$repo_root" cat-file -e "$release_commit:$qualification_path" 2>/dev/null \
	|| die "release commit does not contain $qualification_path"
work=$(mktemp -d "${TMPDIR:-/tmp}/release-history.XXXXXX")
trap 'rm -rf "$work"' EXIT
git -C "$repo_root" show "$release_commit:$qualification_path" \
	> "$work/QUALIFICATION" \
	|| die "cannot read tagged QUALIFICATION blob"
cmp -s "$work/QUALIFICATION" "$qualification" \
	|| die "verified QUALIFICATION snapshot differs from the tagged file"

printf 'HISTORY-BOUND: %s publishes an artifact-only child of qualified source %s.\n' \
	"$release_commit" "$source_commit"
