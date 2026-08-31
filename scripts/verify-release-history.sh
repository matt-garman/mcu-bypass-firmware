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
[[ "$expected_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] \
	|| die "invalid expected release version: $expected_version"
git check-ref-format "refs/tags/$expected_version" >/dev/null 2>&1 \
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
registry_path="test/published_release_digests.txt"
registry_required=0
if git -C "$repo_root" cat-file -e "$source_commit:$registry_path" 2>/dev/null; then
	registry_required=1
fi
mapfile -d '' -t changed_paths < <(git -C "$repo_root" diff-tree -z \
	--no-commit-id --name-only -r "$release_commit")
[ "${#changed_paths[@]}" -gt 0 ] || die "release commit changes no files"
saw_qualification=0
saw_registry=0
for path in "${changed_paths[@]}"; do
	case "$path" in
		"$qualification_path") saw_qualification=1 ;;
		"$release_prefix"*) ;;
		"$registry_path")
			[ "$registry_required" -eq 1 ] \
				|| die "release commit changes a path outside $release_prefix: $path"
			saw_registry=1 ;;
		*) die "release commit changes a path outside $release_prefix: $path" ;;
	esac
done
[ "$saw_qualification" -eq 1 ] \
	|| die "release commit does not add $qualification_path"
[ "$registry_required" -eq 0 ] || [ "$saw_registry" -eq 1 ] \
	|| die "release commit does not append the publication registration in $registry_path"

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

if [ "$registry_required" -eq 1 ]; then
	registration_verifier="$repo_root/test/test_published_release_immutability.py"
	[ -f "$registration_verifier" ] && [ ! -L "$registration_verifier" ] \
		|| die "publication registration verifier is missing or not a regular file"
	command -v python3 >/dev/null 2>&1 \
		|| die "python3 is required to verify the publication registration append"
	parent_entry=$(git -C "$repo_root" ls-tree "$source_commit" -- "$registry_path")
	child_entry=$(git -C "$repo_root" ls-tree "$release_commit" -- "$registry_path")
	parent_mode=${parent_entry%% *}
	parent_type=${parent_entry#* }
	parent_type=${parent_type%% *}
	child_mode=${child_entry%% *}
	child_type=${child_entry#* }
	child_type=${child_type%% *}
	[ "$parent_mode" = 100644 ] && [ "$parent_type" = blob ] \
		|| die "qualified source publication registry is not an ordinary 100644 blob"
	[ "$child_mode" = "$parent_mode" ] && [ "$child_type" = blob ] \
		|| die "release commit changes the publication registry file type or mode"
	registry="$repo_root/$registry_path"
	[ -f "$registry" ] && [ ! -L "$registry" ] && [ -s "$registry" ] \
		|| die "checked-out publication registry is missing, empty, or not a regular file"
	git -C "$repo_root" show "$release_commit:$registry_path" > "$work/registry" \
		|| die "cannot read tagged publication registry blob"
	cmp -s "$work/registry" "$registry" \
		|| die "checked-out publication registry differs from the tagged file"
	git -C "$repo_root" show "$source_commit:$registry_path" \
		| python3 "$registration_verifier" --verify-record-append "$expected_version" \
			>/dev/null \
		|| die "release commit does not append one exact canonical publication registration"
	printf 'HISTORY-BOUND: %s publishes release artifacts and their append-only registration as a child of qualified source %s.\n' \
		"$release_commit" "$source_commit"
else
	printf 'HISTORY-BOUND: %s publishes a legacy artifact-only child of qualified source %s.\n' \
		"$release_commit" "$source_commit"
fi
