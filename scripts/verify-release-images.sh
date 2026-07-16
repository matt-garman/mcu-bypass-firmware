#!/usr/bin/env bash
# Verify one committed release against one or more fresh image directories.
set -euo pipefail

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

if [ "$#" -lt 2 ]; then
	printf 'usage: %s <release-dir> <fresh-image-dir> [fresh-image-dir ...]\n' "$0" >&2
	exit 2
fi

release_dir=$1
shift
fresh_dirs=("$@")
[ -d "$release_dir" ] || die "release directory not found: $release_dir"
release_dir=$(cd "$release_dir" && pwd -P)
for i in "${!fresh_dirs[@]}"; do
	[ -d "${fresh_dirs[$i]}" ] \
		|| die "fresh image directory not found: ${fresh_dirs[$i]}"
	fresh_dirs[$i]=$(cd "${fresh_dirs[$i]}" && pwd -P)
	[ "${fresh_dirs[$i]}" != "$release_dir" ] \
		|| die "fresh image directory must differ from committed release: ${fresh_dirs[$i]}"
	for ((j = 0; j < i; ++j)); do
		[ "${fresh_dirs[$i]}" != "${fresh_dirs[$j]}" ] \
			|| die "duplicate fresh image directory: ${fresh_dirs[$i]}"
	done
done
checksum_source="$release_dir/SHA256SUMS"
[ -f "$checksum_source" ] && [ ! -L "$checksum_source" ] \
	|| die "regular SHA256SUMS file not found: $checksum_source"

work=$(mktemp -d "${TMPDIR:-/tmp}/release-images.XXXXXX")
trap 'rm -rf "$work"' EXIT
checksum_file="$work/SHA256SUMS"
cp -a -- "$checksum_source" "$checksum_file"
[ -f "$checksum_file" ] && [ ! -L "$checksum_file" ] \
	|| die "SHA256SUMS changed type while being snapshotted: $checksum_source"
filename_re='^[A-Za-z0-9][A-Za-z0-9._-]*\.hex$'
checksum_re='^[[:xdigit:]]{64} [ *]([A-Za-z0-9][A-Za-z0-9._-]*\.hex)$'

list_images() {
	local output=$1 label=$2 snapshot=$3 dir image base copy duplicates
	shift 3
	local -a images=() paths=()
	for dir in "$@"; do
		shopt -s nullglob dotglob
		images=("$dir"/*.hex)
		shopt -u nullglob dotglob
		paths+=("${images[@]}")
	done
	[ "${#paths[@]}" -gt 0 ] || die "$label contains no .hex images"
	: > "$output"
	for image in "${paths[@]}"; do
		base=${image##*/}
		[[ "$base" =~ $filename_re ]] || die "$label has invalid image name: $base"
		printf '%s\n' "$base" >> "$output"
	done
	duplicates=$(LC_ALL=C sort "$output" | uniq -d)
	[ -z "$duplicates" ] || die "$label has duplicate image name: $duplicates"
	LC_ALL=C sort -o "$output" "$output"
	mkdir -p "$snapshot"
	for image in "${paths[@]}"; do
		[ -f "$image" ] && [ ! -L "$image" ] \
			|| die "$label image is not a regular file: $image"
		base=${image##*/}
		copy="$snapshot/$base"
		# Archive mode preserves any type change between the source check and
		# copy; validate the private copy before a checksum command sees it.
		cp -a -- "$image" "$copy"
		[ -f "$copy" ] && [ ! -L "$copy" ] \
			|| die "$label image is not a regular file: $image"
	done
}

listed_raw="$work/listed-raw.txt"
listed="$work/listed.txt"
: > "$listed_raw"
while IFS= read -r line || [ -n "$line" ]; do
	[[ "$line" =~ $checksum_re ]] \
		|| die "malformed SHA256SUMS entry: $line"
	printf '%s\n' "${BASH_REMATCH[1]}" >> "$listed_raw"
done < "$checksum_file"
[ -s "$listed_raw" ] || die "SHA256SUMS contains no image entries"
duplicates=$(LC_ALL=C sort "$listed_raw" | uniq -d)
[ -z "$duplicates" ] || die "duplicate SHA256SUMS image entry: $duplicates"
LC_ALL=C sort "$listed_raw" > "$listed"

committed="$work/committed.txt"
fresh="$work/fresh.txt"
committed_snapshot="$work/committed-images"
fresh_snapshot="$work/fresh-images"
list_images "$committed" "committed release" "$committed_snapshot" "$release_dir"
list_images "$fresh" "fresh build" "$fresh_snapshot" "${fresh_dirs[@]}"

if ! diff -u "$listed" "$committed"; then
	die "committed release image set does not exactly match SHA256SUMS"
fi
if ! diff -u "$listed" "$fresh"; then
	die "fresh build image set does not exactly match SHA256SUMS"
fi

printf '%s\n' '== committed image checksums =='
if ! (cd "$committed_snapshot" && sha256sum -c "$checksum_file"); then
	die "committed image checksum verification failed"
fi
printf '%s\n' '== fresh image checksums =='
if ! (cd "$fresh_snapshot" && sha256sum -c "$checksum_file"); then
	die "fresh image checksum verification failed"
fi

printf 'REPRODUCED: %d committed, listed, and freshly built images match exactly.\n' \
	"$(wc -l < "$listed")"
