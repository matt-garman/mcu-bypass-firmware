#!/usr/bin/env bash
# Prove that a rename-only release changed no image byte, and emit the proof.
#
# WHY THIS EXISTS
#   v0.9.8 renamed every firmware image and CHANGELOG.md states three times that
#   the contents did not change -- "only the filenames moved" is the entire
#   premise of the release. Every other claim under release/ is backed by a
#   retained artifact; that one was backed by nobody having checked. This script
#   checks it and prints the evidence, so `release/<version>/RENAME_IDENTITY.md`
#   records the comparison the same way evidence/ records the soak.
#
#   The precedent is docs/pic10f320_validation.md §2, which exists because a
#   byte-identity proof from a deliberately one-shot gate still deserved durable
#   provenance.
#
# DELIBERATELY NOT A STANDING GATE, and it retires itself.
#   Pinning current images to a PREVIOUS release's hashes is correct for exactly
#   one release -- the one claiming nothing changed -- and becomes a false alarm
#   the first time a release legitimately changes a byte. So this script holds no
#   version of its own: it reads the two versions out of the rename table's own
#   header in release/README.md ("| up to `vA.B.C` | from `vX.Y.Z` |"). Run it
#   for any other version and it says so and exits 0. When that table stops
#   naming the current release, this check is already inert; delete it then.
#   The standing form of this check is per-release, and already exists
#   (test/pic10f320/expected_images.sha256, `make test-release-images`).
#
# THE MAPPING IS NOT RESTATED HERE. It is parsed from the published table in
# release/README.md -- the one a user follows to find the replacement for an old
# filename. A second copy would be a third spelling of the same fact and could
# drift from the table users actually read, which is the defect class this
# release spent itself removing.
set -euo pipefail

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

if [ "$#" -lt 2 ]; then
	printf 'usage: %s <version> <image> [image ...]\n' "$0" >&2
	exit 2
fi

VERSION=$1
shift
IMAGES=("$@")

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
RENAME_DOC="$REPO_ROOT/release/README.md"
[ -f "$RENAME_DOC" ] || die "rename table not found: $RENAME_DOC"

# --- which two releases is the published table about? -----------------------
# Both versions come from the table header, so this script cannot disagree with
# the document it is quoting.
header=$(grep -oE '^\| up to `v[0-9]+\.[0-9]+\.[0-9]+` \| from `v[0-9]+\.[0-9]+\.[0-9]+` \|$' \
	"$RENAME_DOC" | head -1) \
	|| true
[ -n "$header" ] \
	|| die "no '| up to \`vA.B.C\` | from \`vX.Y.Z\` |' header in $RENAME_DOC -- the rename table has moved or been reworded"
BASELINE=$(printf '%s' "$header" | sed -E 's/^\| up to `([^`]*)`.*/\1/')
TARGET=$(printf '%s' "$header" | sed -E 's/.*\| from `([^`]*)` \|$/\1/')

if [ "$VERSION" != "$TARGET" ]; then
	printf 'rename identity: not applicable to %s -- the rename table in release/README.md maps %s to %s.\n' \
		"$VERSION" "$BASELINE" "$TARGET"
	exit 0
fi

BASELINE_SUMS="$REPO_ROOT/release/$BASELINE/SHA256SUMS"
[ -f "$BASELINE_SUMS" ] && [ ! -L "$BASELINE_SUMS" ] \
	|| die "baseline checksum manifest not found: $BASELINE_SUMS"
# Compare against the PUBLISHED, signed manifest or not at all. An unsigned
# baseline would make this a comparison against whatever is in the tree.
[ -f "$REPO_ROOT/release/$BASELINE/SHA256SUMS.asc" ] \
	|| die "release/$BASELINE/SHA256SUMS carries no detached signature; it is not the published baseline"

# --- the old <v> / new <stage> output-stage vocabulary ----------------------
# Stated in the sentence under the table, because the retired stage tokens exist
# nowhere else in the tree -- the rename is what retired them.
#
# Newlines are folded first: the sentence wraps, and a per-line match would find
# the three old tokens, none of the new ones, and pair up nothing.
vocab_line=$(tr '\n' ' ' < "$RENAME_DOC" \
	| grep -oE 'where old `<v>` [^.]*maps to `<stage>`[^.]*' | head -1) || true
[ -n "$vocab_line" ] \
	|| die "cannot find the '<v> maps to <stage>' sentence in $RENAME_DOC"
mapfile -t old_stages < <(printf '%s' "${vocab_line%%maps to*}" \
	| grep -oE '`[A-Za-z0-9_]+`' | tr -d '`')
mapfile -t new_stages < <(printf '%s' "${vocab_line#*maps to}" \
	| grep -oE '`[A-Za-z0-9_]+`' | tr -d '`')
[ "${#old_stages[@]}" -ge 1 ] && [ "${#old_stages[@]}" -eq "${#new_stages[@]}" ] \
	|| die "the <v> -> <stage> sentence lists ${#old_stages[@]} old and ${#new_stages[@]} new stage names; they must pair up"

# --- the mapping itself -----------------------------------------------------
# Only rows whose BOTH cells name a .hex file: the same fenced block carries a
# second table for the renamed make goals, which is not this script's business.
declare -A MAP=()
rows=0
while IFS= read -r line; do
	old=$(printf '%s' "$line" | sed -E 's/^\| *`([^`]*)` *\| *`([^`]*)` *\|$/\1/')
	new=$(printf '%s' "$line" | sed -E 's/^\| *`([^`]*)` *\| *`([^`]*)` *\|$/\2/')
	case "$old$new" in *'<v>'*|*'<stage>'*)
		for i in "${!old_stages[@]}"; do
			o=${old//<v>/${old_stages[$i]}}
			n=${new//<stage>/${new_stages[$i]}}
			[ -z "${MAP[$o]+set}" ] || die "the rename table maps $o twice"
			MAP[$o]=$n
			rows=$((rows + 1))
		done
		continue ;;
	esac
	[ -z "${MAP[$old]+set}" ] || die "the rename table maps $old twice"
	MAP[$old]=$new
	rows=$((rows + 1))
done < <(grep -E '^\| *`[A-Za-z0-9_<>-]+\.hex` *\| *`[A-Za-z0-9_<>-]+\.hex` *\|$' "$RENAME_DOC")

[ "$rows" -ge 10 ] \
	|| die "parsed only $rows image rows out of the rename table; it has changed shape"

# --- index the images this release built ------------------------------------
declare -A IMAGE_PATH=()
for img in "${IMAGES[@]}"; do
	[ -f "$img" ] && [ ! -L "$img" ] || die "not a regular image file: $img"
	base=${img##*/}
	[ -z "${IMAGE_PATH[$base]+set}" ] || die "two images share the basename $base"
	IMAGE_PATH[$base]=$img
done

# --- compare ----------------------------------------------------------------
identical=0; differ=0; missing=0
declare -A CLAIMED=()
rows_md=()
# Same shape scripts/verify-release-images.sh accepts, including the ` *`
# binary-mode marker sha256sum writes for a non-text file.
checksum_re='^([[:xdigit:]]{64}) [ *]([A-Za-z0-9][A-Za-z0-9._-]*\.hex)$'

while IFS= read -r entry; do
	[ -n "$entry" ] || continue
	[[ "$entry" =~ $checksum_re ]] \
		|| die "unparsable line in $BASELINE_SUMS: $entry"
	old_hash=${BASH_REMATCH[1]}
	old_name=${BASH_REMATCH[2]}

	new_name=${MAP[$old_name]:-}
	if [ -z "$new_name" ]; then
		missing=$((missing + 1))
		rows_md+=("| \`$old_name\` | *(no row in the rename table)* | \`$old_hash\` | **UNMAPPED** |")
		continue
	fi
	path=${IMAGE_PATH[$new_name]:-}
	if [ -z "$path" ]; then
		missing=$((missing + 1))
		rows_md+=("| \`$old_name\` | \`$new_name\` | \`$old_hash\` | **NOT BUILT** |")
		continue
	fi
	CLAIMED[$new_name]=1
	new_hash=$(sha256sum -- "$path" | cut -d' ' -f1)
	if [ "$new_hash" = "$old_hash" ]; then
		identical=$((identical + 1))
		rows_md+=("| \`$old_name\` | \`$new_name\` | \`$new_hash\` | identical |")
	else
		differ=$((differ + 1))
		rows_md+=("| \`$old_name\` | \`$new_name\` | \`$new_hash\` | **DIFFERS** (was \`$old_hash\`) |")
	fi
done < "$BASELINE_SUMS"

# An image with no baseline counterpart is not a failure by itself -- a release
# may legitimately add a part -- but it must be visible, or "18 identical" would
# read as a statement about the whole release when it is a statement about the
# eighteen that existed before.
added=()
for base in "${!IMAGE_PATH[@]}"; do
	[ -n "${CLAIMED[$base]+set}" ] || added+=("$base")
done

# --- the evidence document --------------------------------------------------
printf '# %s image byte-identity against %s\n\n' "$TARGET" "$BASELINE"
printf 'Generated by `scripts/verify-rename-identity.sh`.\n\n'
printf '`%s` renamed every firmware image. `CHANGELOG.md` states that the image\n' "$TARGET"
printf 'CONTENTS did not change. This is that claim checked rather than asserted:\n'
printf 'each image built for `%s` is hashed and compared against the entry for its\n' "$TARGET"
printf 'old name in the signed `release/%s/SHA256SUMS`, through the published\n' "$BASELINE"
printf 'old-to-new table in `release/README.md`.\n\n'
printf -- '- **Baseline:** `release/%s/SHA256SUMS` (detached signature present)\n' "$BASELINE"
printf -- '- **Mapping:** `release/README.md`, %d image rows\n' "$rows"
printf -- '- **Compared:** %d images\n\n' "${#IMAGES[@]}"
printf '| up to `%s` | from `%s` | sha256 | verdict |\n' "$BASELINE" "$TARGET"
printf '|---|---|---|---|\n'
printf '%s\n' "${rows_md[@]}"
printf '\n'
if [ "${#added[@]}" -gt 0 ]; then
	printf 'Images with no `%s` counterpart (new in `%s`, nothing to compare):\n\n' \
		"$BASELINE" "$TARGET"
	printf -- '- `%s`\n' "${added[@]}"
	printf '\n'
fi
printf 'identical=%d differ=%d missing=%d added=%d\n' \
	"$identical" "$differ" "$missing" "${#added[@]}"

if [ "$differ" -ne 0 ] || [ "$missing" -ne 0 ]; then
	die "rename identity FAILED: $differ image(s) differ, $missing unmapped or not built"
fi
[ "$identical" -gt 0 ] \
	|| die "rename identity compared nothing at all"

printf '\nAll %d renamed images are byte-identical to their `%s` counterparts.\n' \
	"$identical" "$BASELINE"
