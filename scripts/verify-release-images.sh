#!/usr/bin/env bash
# Verify one committed release against one or more fresh image directories.
#
# Four sets must agree, not three. The committed directory, the SHA256SUMS
# entries and the fresh build output are all observations of what happened to be
# produced; the CANONICAL SET (Makefile RELEASE_IMAGES, merge plan §10) is the
# independent statement of what a complete release must contain. Without it,
# three sets computed by the same glob agree perfectly on an incomplete release
# -- omit an entire MCU from the build and nothing here would notice (§14.8).
# With it, the omission fails at the first comparison.
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
# Every checksum entry, image or not. A release is its exact firmware image set
# PLUS the required non-image artifacts the Makefile declares, and the two are
# separated below by NAME against those declarations -- never by file suffix,
# and never by whatever the staging directory happened to contain.
checksum_re='^[[:xdigit:]]{64} [ *]([A-Za-z0-9][A-Za-z0-9._-]*)$'
helper_name_re='^[A-Za-z0-9][A-Za-z0-9._-]*$'

# --- the canonical release product set --------------------------------------
# Always read straight from the adjacent Makefile, the single source of truth.
# Synthetic regressions run a copy of this verifier beside a fixture Makefile;
# production has no alternate environment or command-line oracle that ambient
# state can accidentally select.
expected_source='Makefile RELEASE_IMAGES'
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P) \
	|| die "could not locate the repository root"
command -v make >/dev/null 2>&1 \
	|| die "make is required to read the canonical release image set"
mkv_from_repo() {
	# Do not inherit recursive-Make flags, command-line variable assignments, or
	# injected makefiles from the caller. The tracked repository Makefile is the
	# oracle, not ambient GNU Make process state.
	unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKEFILES MAKEOVERRIDES
	cd "$repo_root" \
		&& make --no-print-directory -s -f "$repo_root/Makefile" \
			print-"$1"
}
expected_raw=$(mkv_from_repo RELEASE_IMAGES) \
	|| die "could not read RELEASE_IMAGES from the Makefile"

read -r -a expected_images <<<"$expected_raw"
[ "${#expected_images[@]}" -gt 0 ] \
	|| die "the canonical release image set is empty ($expected_source)"

# The unset above strips command-line assignments, but NOT the environment, and
# the per-part MCU tags are `?=` -- an exported PIC12F675_TAG moves RELEASE_IMAGES
# in this very process. Reproduction is the public attestation that a published
# binary IS the tagged source, so it may not accept whatever set the ambient
# environment happens to select. RELEASE_IDENTITY_IMAGES is the same Makefile's
# `override` pin: literal image names that no channel can move. Requiring the
# two to agree is what makes the comparisons below a check on the RELEASE rather
# than on the environment that ran the verifier.
identity_raw=$(mkv_from_repo RELEASE_IDENTITY_IMAGES) \
	|| die "could not read RELEASE_IDENTITY_IMAGES from the Makefile"
read -r -a identity_images <<<"$identity_raw"
[ "${#identity_images[@]}" -gt 0 ] \
	|| die "the pinned release image identity is empty (Makefile RELEASE_IDENTITY_IMAGES)"
canonical_sorted=$(printf '%s\n' "${expected_images[@]}" | LC_ALL=C sort)
identity_sorted=$(printf '%s\n' "${identity_images[@]}" | LC_ALL=C sort)
[ "$canonical_sorted" = "$identity_sorted" ] \
	|| die "$expected_source does not match the pinned production release identity (Makefile RELEASE_IDENTITY_IMAGES).
  canonical: $expected_raw
  pinned:    $identity_raw
An identity-changing Make override was in effect; a reproduction must be run without it."

# --- required release artifacts that are not firmware images ----------------
# A release also ships tools. They are staged, checksummed and signed exactly
# like an image, but they are NOT images: folding them into the image set would
# quietly move a reviewed count, and treating every checksum entry as an image
# would make the exact-set comparisons below meaningless. So they are declared
# separately, as <staged basename>=<tracked source>, and each is proved to be
# the tracked source byte for byte -- which is the reproduction claim for a
# file no compiler produces.
helper_raw=$(mkv_from_repo RELEASE_HELPER_MAP) \
	|| die "could not read RELEASE_HELPER_MAP from the Makefile"
read -r -a helper_map <<<"$helper_raw"
[ "${#helper_map[@]}" -gt 0 ] \
	|| die "the required release artifact set is empty (Makefile RELEASE_HELPER_MAP)"
declare -A helper_source=()
helper_expected="$work/helper-expected.txt"
: > "$helper_expected"
for entry in "${helper_map[@]}"; do
	helper_base=${entry%%=*}
	helper_src=${entry#*=}
	[ -n "$helper_base" ] && [ -n "$helper_src" ] && [ "$helper_base" != "$entry" ] \
		|| die "malformed release artifact declaration: $entry (Makefile RELEASE_HELPER_MAP)"
	[[ "$helper_base" =~ $helper_name_re ]] \
		|| die "release artifact has an invalid staged name: $helper_base (Makefile RELEASE_HELPER_MAP)"
	case "$helper_base" in
		*.hex) die "a release artifact may not be named like a firmware image: $helper_base (Makefile RELEASE_HELPER_MAP)" ;;
	esac
	[ -z "${helper_source[$helper_base]+set}" ] \
		|| die "duplicate release artifact: $helper_base (Makefile RELEASE_HELPER_MAP)"
	helper_source[$helper_base]=$helper_src
	printf '%s\n' "$helper_base" >> "$helper_expected"
done
LC_ALL=C sort -o "$helper_expected" "$helper_expected"

expected="$work/expected.txt"
: > "$expected"
for base in "${expected_images[@]}"; do
	[[ "$base" =~ $filename_re ]] \
		|| die "canonical release image set has an invalid image name: $base ($expected_source)"
	printf '%s\n' "$base" >> "$expected"
done
duplicates=$(LC_ALL=C sort "$expected" | uniq -d)
[ -z "$duplicates" ] \
	|| die "canonical release image set has a duplicate image name: $duplicates ($expected_source)"
LC_ALL=C sort -o "$expected" "$expected"

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
listed_helpers_raw="$work/listed-helpers-raw.txt"
listed_helpers="$work/listed-helpers.txt"
listed_all="$work/listed-all.txt"
# A fresh build produces images, not tools, so the fresh leg is checked against
# an image-only view of the same signed file rather than a second manifest.
checksum_images="$work/SHA256SUMS.images"
: > "$listed_raw"
: > "$listed_helpers_raw"
: > "$listed_all"
: > "$checksum_images"
while IFS= read -r line || [ -n "$line" ]; do
	[[ "$line" =~ $checksum_re ]] \
		|| die "malformed SHA256SUMS entry: $line"
	entry_name=${BASH_REMATCH[1]}
	printf '%s\n' "$entry_name" >> "$listed_all"
	if [ -n "${helper_source[$entry_name]+set}" ]; then
		printf '%s\n' "$entry_name" >> "$listed_helpers_raw"
	else
		printf '%s\n' "$entry_name" >> "$listed_raw"
		printf '%s\n' "$line" >> "$checksum_images"
	fi
done < "$checksum_file"
[ -s "$listed_raw" ] || die "SHA256SUMS contains no image entries"
duplicates=$(LC_ALL=C sort "$listed_all" | uniq -d)
[ -z "$duplicates" ] || die "duplicate SHA256SUMS entry: $duplicates"
LC_ALL=C sort "$listed_raw" > "$listed"
LC_ALL=C sort "$listed_helpers_raw" > "$listed_helpers"

committed="$work/committed.txt"
fresh="$work/fresh.txt"
committed_snapshot="$work/committed-images"
fresh_snapshot="$work/fresh-images"
list_images "$committed" "committed release" "$committed_snapshot" "$release_dir"
list_images "$fresh" "fresh build" "$fresh_snapshot" "${fresh_dirs[@]}"

# The canonical set is the anchor for all three comparisons, so an omission
# common to every observed set is caught rather than confirmed. Each message
# still names the set that disagreed.
if ! diff -u "$expected" "$listed"; then
	die "SHA256SUMS entries do not exactly match the canonical release product set ($expected_source)"
fi
if ! diff -u "$expected" "$committed"; then
	die "committed release image set does not exactly match the canonical release product set ($expected_source)"
fi
if ! diff -u "$expected" "$fresh"; then
	die "fresh build image set does not exactly match the canonical release product set ($expected_source)"
fi
# Checked after the image sets, so the headline release contents are always the
# first thing a failure reports.
if ! diff -u "$helper_expected" "$listed_helpers"; then
	die "SHA256SUMS entries do not exactly match the required release artifact set (Makefile RELEASE_HELPER_MAP)"
fi

# The committed directory must hold each required artifact, and each must be the
# tracked source byte for byte. No build step produces these files, so "the
# published bytes are the tagged source" is the whole of their reproduction
# claim, and it is checked here rather than assumed from the signature.
for helper_base in $(LC_ALL=C sort "$helper_expected"); do
	helper_path="$release_dir/$helper_base"
	[ -f "$helper_path" ] && [ ! -L "$helper_path" ] && [ -s "$helper_path" ] \
		|| die "committed release is missing required artifact: $helper_base"
	cp -a -- "$helper_path" "$committed_snapshot/$helper_base"
	[ -f "$committed_snapshot/$helper_base" ] && [ ! -L "$committed_snapshot/$helper_base" ] \
		|| die "required release artifact is not a regular file: $helper_path"
	helper_src_path="$repo_root/${helper_source[$helper_base]}"
	[ -f "$helper_src_path" ] && [ ! -L "$helper_src_path" ] && [ -s "$helper_src_path" ] \
		|| die "tracked source for release artifact $helper_base not found: ${helper_source[$helper_base]}"
	staged_digest=$(sha256sum -- "$committed_snapshot/$helper_base") \
		|| die "could not hash staged release artifact: $helper_base"
	source_digest=$(sha256sum -- "$helper_src_path") \
		|| die "could not hash tracked release artifact source: ${helper_source[$helper_base]}"
	[ "${staged_digest%% *}" = "${source_digest%% *}" ] \
		|| die "staged release artifact $helper_base differs from its tracked source ${helper_source[$helper_base]}"
done

printf '%s\n' '== committed release checksums =='
if ! (cd "$committed_snapshot" && sha256sum -c "$checksum_file"); then
	die "committed release checksum verification failed"
fi
printf '%s\n' '== fresh image checksums =='
if ! (cd "$fresh_snapshot" && sha256sum -c "$checksum_images"); then
	die "fresh image checksum verification failed"
fi

printf 'REPRODUCED-ARTIFACTS: %d required non-image release artifact(s) match their tracked source exactly.\n' \
	"$(wc -l < "$helper_expected")"
printf 'REPRODUCED: %d committed, listed, and freshly built images match the canonical set exactly.\n' \
	"$(wc -l < "$expected")"
