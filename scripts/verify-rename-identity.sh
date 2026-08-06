#!/usr/bin/env bash
# Prove the exact image-byte contract for the one release that renamed images.
#
# WHY THIS EXISTS
#   v0.9.8 renamed every firmware image. Seventeen image contents must not change;
#   one published exception carries the PIC10F320 relay idle-latch correction.
#   This script checks that exact 17+1 contract and prints the evidence, so
#   `release/<version>/RENAME_IDENTITY.md` records the comparison the same way
#   evidence/ records the soak.
#
#   The precedent is docs/pic10f320_validation.md §2, which exists because a
#   byte-identity proof from a deliberately one-shot gate still deserved durable
#   provenance.
#
# DELIBERATELY NOT A STANDING GATE, and it retires itself.
#   Pinning current images to a PREVIOUS release's hashes is correct for exactly
#   one release -- the one carrying this rename/change contract -- and becomes a
#   false alarm on later releases. So this script holds no
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

if [ "${1:-}" = "--compare-report" ]; then
	[ "$#" -ge 5 ] || {
		printf 'usage: %s --compare-report <committed-release-dir> <verified-report> <version> <image> [image ...]\n' \
			"$0" >&2
		exit 2
	}
	COMMITTED_RELEASE=$2
	VERIFIED_REPORT=$3
	COMPARE_VERSION=$4
	shift 4
	[ -d "$COMMITTED_RELEASE" ] && [ ! -L "$COMMITTED_RELEASE" ] \
		|| die "committed release is missing or not a regular directory: $COMMITTED_RELEASE"
	VERIFIED_REPORT_DIR=${VERIFIED_REPORT%/*}
	[ "$VERIFIED_REPORT_DIR" != "$VERIFIED_REPORT" ] \
		&& [ -d "$VERIFIED_REPORT_DIR" ] && [ ! -L "$VERIFIED_REPORT_DIR" ] \
		|| die "verified-report parent is missing or not a regular directory: $VERIFIED_REPORT_DIR"
	[ ! -e "$VERIFIED_REPORT" ] && [ ! -L "$VERIFIED_REPORT" ] \
		|| die "verified-report output already exists: $VERIFIED_REPORT"

	COMPARE_WORK=$(mktemp -d "$VERIFIED_REPORT_DIR/.rename-report-compare.XXXXXX") \
		|| die "cannot create rename-report comparison work directory"
	trap 'rm -rf "$COMPARE_WORK"' EXIT
	GENERATED_REPORT="$COMPARE_WORK/RENAME_IDENTITY.md"
	if "$0" "$COMPARE_VERSION" "$@" >"$GENERATED_REPORT"; then
		:
	else
		rc=$?
		cat "$GENERATED_REPORT" >&2
		exit "$rc"
	fi
	[ -s "$GENERATED_REPORT" ] \
		|| die "rename verifier produced an empty report for $COMPARE_VERSION"
	IFS= read -r first_line < "$GENERATED_REPORT"
	COMMITTED_REPORT="$COMMITTED_RELEASE/RENAME_IDENTITY.md"
	case "$first_line" in
	"rename identity: not applicable to "*)
		if [ -e "$COMMITTED_REPORT" ] || [ -L "$COMMITTED_REPORT" ]; then
			die "rename identity is not applicable to $COMPARE_VERSION, but committed evidence exists: $COMMITTED_REPORT"
		fi
		printf 'rename_identity_applicable=0\n'
		printf 'rename_identity_sha256=\n'
		exit 0
		;;
	'# '*) ;;
	*) die "rename verifier produced an unrecognized report for $COMPARE_VERSION" ;;
	esac

	[ -f "$COMMITTED_REPORT" ] && [ ! -L "$COMMITTED_REPORT" ] \
		&& [ -s "$COMMITTED_REPORT" ] \
		|| die "committed rename evidence is missing, empty, or not a regular file: $COMMITTED_REPORT"
	COMMITTED_SNAPSHOT="$COMPARE_WORK/COMMITTED_RENAME_IDENTITY.md"
	cp -a -- "$COMMITTED_REPORT" "$COMMITTED_SNAPSHOT" \
		|| die "cannot snapshot committed rename evidence: $COMMITTED_REPORT"
	[ -f "$COMMITTED_SNAPSHOT" ] && [ ! -L "$COMMITTED_SNAPSHOT" ] \
		&& [ -s "$COMMITTED_SNAPSHOT" ] \
		|| die "committed rename-evidence snapshot is empty or not a regular file"
	cmp -s -- "$GENERATED_REPORT" "$COMMITTED_SNAPSHOT" \
		|| die "committed rename evidence does not match the CI-regenerated report: $COMMITTED_REPORT"
	verified_hash=$(sha256sum -- "$GENERATED_REPORT")
	verified_hash=${verified_hash%% *}
	[[ "$verified_hash" =~ ^[0-9a-f]{64}$ ]] \
		|| die "cannot hash regenerated rename evidence"
	# The output must never be reopened through a pathname that appeared after
	# the initial absence check. Both names are on the same filesystem, so an
	# exclusive hard link retains these exact bytes or fails without opening an
	# attacker-supplied symlink/FIFO.
	ln -- "$GENERATED_REPORT" "$VERIFIED_REPORT" \
		|| die "cannot retain verified rename evidence: $VERIFIED_REPORT"
	[ -f "$VERIFIED_REPORT" ] && [ ! -L "$VERIFIED_REPORT" ] \
		&& [ -s "$VERIFIED_REPORT" ] \
		|| die "retained rename evidence does not match the verified report: $VERIFIED_REPORT"
	retained_hash=$(sha256sum -- "$VERIFIED_REPORT")
	retained_hash=${retained_hash%% *}
	[ "$retained_hash" = "$verified_hash" ] \
		|| die "retained rename evidence does not match the verified digest: $VERIFIED_REPORT"
	printf 'rename_identity_applicable=1\n'
	printf 'rename_identity_sha256=%s\n' "$verified_hash"
	exit 0
fi

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

# The one allowed firmware change is declared beside the published mapping, not
# restated here. Requiring exactly one declaration makes both accidental removal
# and an open-ended allowlist fail before any image hash is accepted.
mapfile -t intentional_change_lines < <(grep -E \
	'^<!-- rename-identity: intentional-change=[A-Za-z0-9][A-Za-z0-9._-]*\.hex -->$' \
	"$RENAME_DOC" || true)
[ "${#intentional_change_lines[@]}" -eq 1 ] \
	|| die "release/README.md must declare exactly one rename-identity intentional change"
INTENTIONAL_CHANGE=${intentional_change_lines[0]#*=}
INTENTIONAL_CHANGE=${INTENTIONAL_CHANGE% -->}

BASELINE_SUMS="$REPO_ROOT/release/$BASELINE/SHA256SUMS"
[ -f "$BASELINE_SUMS" ] && [ ! -L "$BASELINE_SUMS" ] \
	|| die "baseline checksum manifest not found: $BASELINE_SUMS"
BASELINE_SIGNATURE="$REPO_ROOT/release/$BASELINE/SHA256SUMS.asc"
SIGNATURE_VERIFY="$REPO_ROOT/scripts/verify-release-signature.sh"
[ -f "$SIGNATURE_VERIFY" ] && [ ! -L "$SIGNATURE_VERIFY" ] \
	&& [ -s "$SIGNATURE_VERIFY" ] && [ -x "$SIGNATURE_VERIFY" ] \
	|| die "release signature verifier is missing or not executable: $SIGNATURE_VERIFY"
# Compare against the PUBLISHED manifest or not at all. Presence of a detached
# signature proves nothing: establish that the pinned release key signed these
# exact bytes before any baseline hash is parsed. Snapshot the manifest first so
# the later parse cannot reopen a pathname that changed after GPG returned. The
# signature is consumed only by GPG, and the shared verifier validates its type.
VERIFY_WORK=$(mktemp -d "${TMPDIR:-/tmp}/rename-identity.XXXXXX") \
	|| die "cannot create baseline verification work directory"
trap 'rm -rf "$VERIFY_WORK"' EXIT
BASELINE_SUMS_SNAPSHOT="$VERIFY_WORK/SHA256SUMS"
cp -P -- "$BASELINE_SUMS" "$BASELINE_SUMS_SNAPSHOT" \
	|| die "cannot snapshot baseline checksum manifest: $BASELINE_SUMS"
if ! "$SIGNATURE_VERIFY" detached "$BASELINE_SIGNATURE" \
		"$BASELINE_SUMS_SNAPSHOT" >/dev/null; then
	die "baseline checksum signature verification failed for release/$BASELINE/SHA256SUMS"
fi

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

[ "$rows" -eq 18 ] \
	|| die "parsed $rows image mappings; the published rename contract requires exactly 18"

# --- index the images this release built ------------------------------------
declare -A IMAGE_PATH=()
for img in "${IMAGES[@]}"; do
	[ -f "$img" ] && [ ! -L "$img" ] || die "not a regular image file: $img"
	base=${img##*/}
	[ -z "${IMAGE_PATH[$base]+set}" ] || die "two images share the basename $base"
	IMAGE_PATH[$base]=$img
done

# --- compare ----------------------------------------------------------------
identical=0; intentional_change=0; differ=0; missing=0
intentional_change_absent=0
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
		if [ "$new_name" = "$INTENTIONAL_CHANGE" ]; then
			intentional_change_absent=1
			rows_md+=("| \`$old_name\` | \`$new_name\` | \`$new_hash\` | **REQUIRED CHANGE ABSENT** |")
		else
			identical=$((identical + 1))
			rows_md+=("| \`$old_name\` | \`$new_name\` | \`$new_hash\` | identical |")
		fi
	else
		if [ "$new_name" = "$INTENTIONAL_CHANGE" ]; then
			intentional_change=$((intentional_change + 1))
			rows_md+=("| \`$old_name\` | \`$new_name\` | \`$new_hash\` | intentional firmware change (was \`$old_hash\`) |")
		else
			differ=$((differ + 1))
			rows_md+=("| \`$old_name\` | \`$new_name\` | \`$new_hash\` | **UNEXPECTED DIFFERENCE** (was \`$old_hash\`) |")
		fi
	fi
done < "$BASELINE_SUMS_SNAPSHOT"

# This one-shot contract is over the exact renamed product set. A later release
# may legitimately add a part, but v0.9.8 may not silently extend this evidence.
added=()
for base in "${!IMAGE_PATH[@]}"; do
	[ -n "${CLAIMED[$base]+set}" ] || added+=("$base")
done

# --- the evidence document --------------------------------------------------
printf '# %s image rename/change evidence against %s\n\n' "$TARGET" "$BASELINE"
printf 'Generated by `scripts/verify-rename-identity.sh`.\n\n'
printf '`%s` renamed every firmware image and intentionally changed one named image.\n' "$TARGET"
printf 'This is the exact 17-identical + 1-change claim checked rather than asserted:\n'
printf 'each image built for `%s` is hashed and compared against the entry for its\n' "$TARGET"
printf 'old name in the signed `release/%s/SHA256SUMS`, through the published\n' "$BASELINE"
printf 'old-to-new table and intentional-change declaration in `release/README.md`.\n\n'
printf -- '- **Baseline:** `release/%s/SHA256SUMS` (detached signature verified against the pinned release key)\n' "$BASELINE"
printf -- '- **Mapping:** `release/README.md`, %d expanded image mappings\n' "$rows"
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
printf 'identical=%d intentional_change=%d differ=%d missing=%d added=%d\n' \
	"$identical" "$intentional_change" "$differ" "$missing" "${#added[@]}"

if [ "$intentional_change_absent" -ne 0 ] || [ "$intentional_change" -ne 1 ] \
		|| [ "$differ" -ne 0 ] || [ "$missing" -ne 0 ] || [ "${#added[@]}" -ne 0 ]; then
	die "rename/change evidence FAILED: intentional_change=$intentional_change, required_change_absent=$intentional_change_absent, unexpected_differences=$differ, missing=$missing, added=${#added[@]}"
fi
[ "$identical" -eq 17 ] \
	|| die "rename/change evidence expected 17 identical images, observed $identical"

printf '\nExactly 17 renamed images are byte-identical to their `%s` counterparts;\n' \
	"$BASELINE"
printf '`%s` is the one verified intentional firmware change.\n' "$INTENTIONAL_CHANGE"
