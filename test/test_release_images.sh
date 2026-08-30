#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VERIFY="$ROOT/scripts/verify-release-images.sh"
BIND_VERIFY_SOURCE="$ROOT/scripts/verify-release-program-image.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/test-release-images.XXXXXX")
trap 'rm -rf "$work"' EXIT
release="$work/release"
fresh="$work/fresh"
fresh2="$work/fresh2"
release_alias="$work/release-alias"
fresh_alias="$work/fresh-alias"
fakebin="$work/fakebin"
fixture_root="$work/verifier-fixture"
fixture_verify="$fixture_root/scripts/verify-release-images.sh"
checks=0

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

mkdir -p "$fixture_root/scripts"
cp -p "$VERIFY" "$fixture_verify"
cat > "$fixture_root/Makefile" <<'EOF'
override RELEASE_IMAGES := $(shell cat expected-images.txt)
override RELEASE_IDENTITY_IMAGES := $(shell cat expected-identity.txt)
override RELEASE_HELPER_MAP := $(shell cat expected-helpers.txt)
override RELEASE_PROVENANCE_FILES := $(shell cat expected-provenance.txt)
.PHONY: print-RELEASE_IMAGES print-RELEASE_IDENTITY_IMAGES print-RELEASE_HELPER_MAP
.PHONY: print-RELEASE_PROVENANCE_FILES
print-RELEASE_IMAGES:
	@printf '%s\n' "$(RELEASE_IMAGES)"
print-RELEASE_IDENTITY_IMAGES:
	@printf '%s\n' "$(RELEASE_IDENTITY_IMAGES)"
print-RELEASE_HELPER_MAP:
	@printf '%s\n' "$(RELEASE_HELPER_MAP)"
print-RELEASE_PROVENANCE_FILES:
	@printf '%s\n' "$(RELEASE_PROVENANCE_FILES)"
EOF

# The canonical set and the pinned identity agree in every synthetic case except
# the one that exists to make them differ, so the rest of this file keeps
# exercising the comparisons it was written for.
set_fixture_expected_images() {
	printf '%s\n' "$1" > "$fixture_root/expected-images.txt"
	printf '%s\n' "$1" > "$fixture_root/expected-identity.txt"
}

set_fixture_identity_images() {
	printf '%s\n' "$1" > "$fixture_root/expected-identity.txt"
}

# The required non-image artifacts, declared as <staged basename>=<tracked
# source>. A release ships tools beside its images, and the verifier must hold
# them to the tracked bytes without letting them join -- or move -- the image
# set.
set_fixture_helper_map() {
	printf '%s\n' "$1" > "$fixture_root/expected-helpers.txt"
}

# The provenance files a release signs for itself. Declared as bare staged
# names: unlike the helpers they have no tracked source, because make-release.sh
# generates them from the qualified run.
set_fixture_provenance_files() {
	printf '%s\n' "$1" > "$fixture_root/expected-provenance.txt"
}

# Every fixture that rebuilds SHA256SUMS still has to sign its own provenance,
# so the checksum list stays a complete partition of images, helpers and
# provenance. Named once here rather than repeated at each site: a test that
# rebuilds the list to exercise an IMAGE or HELPER failure must not
# accidentally start exercising a provenance failure instead.
FIXTURE_PROVENANCE='QUALIFICATION MANIFEST.md README.md'

reset_fixture() {
	rm -rf "$release" "$fresh" "$fresh2" "$release_alias" "$fresh_alias" \
		"$fakebin"
	mkdir -p "$release" "$fresh"
	printf ':0100000001FE\n:00000001FF\n' > "$release/a.hex"
	printf ':0100000002FD\n:00000001FF\n' > "$release/b.hex"
	cp "$release/a.hex" "$release/b.hex" "$fresh"/
	# The fixture's required non-image artifact and its tracked source. A fresh
	# build never produces it, so it is staged into the committed release only.
	printf '#!/usr/bin/env python3\nprint("fixture helper")\n' \
		> "$fixture_root/scripts/helper.py"
	cp -p "$fixture_root/scripts/helper.py" "$release/helper.py"
	# The provenance files. A fresh build never produces these either: they are
	# written from the qualified run, and as of QUALIFICATION format=4 they are
	# inside the checksum list so one signature reaches them.
	printf 'format=4\n' > "$release/QUALIFICATION"
	printf '# Firmware release fixture\n' > "$release/MANIFEST.md"
	printf '# fixture\n' > "$release/README.md"
	(cd "$release" && sha256sum a.hex b.hex helper.py \
		QUALIFICATION MANIFEST.md README.md > SHA256SUMS)
	# Synthetic tests use the production verifier unchanged beside a test-only
	# Makefile. Production therefore retains exactly one canonical-set input.
	set_fixture_expected_images 'a.hex b.hex'
	set_fixture_helper_map 'helper.py=scripts/helper.py'
	set_fixture_provenance_files 'QUALIFICATION MANIFEST.md README.md'
}

real_sha256sum=$(command -v sha256sum) \
	|| fail "sha256sum is required for the release-image regression"

expect_pass() {
	expect_pass_dirs "$1" "$fresh"
}

expect_pass_dirs() {
	local label=$1
	shift
	"$fixture_verify" "$release" "$@" >/dev/null \
		|| fail "$label: valid release was rejected"
	checks=$((checks + 1))
}

expect_fail() {
	expect_fail_dirs "$1" "$2" "$fresh"
}

expect_fail_dirs() {
	local label=$1 expected=$2 output
	shift 2
	if output=$("$fixture_verify" "$release" "$@" 2>&1); then
		fail "$label: invalid release was accepted"
	fi
	[[ "$output" == *"$expected"* ]] \
		|| fail "$label: failed for the wrong reason: $output"
	checks=$((checks + 1))
}

reset_fixture
expect_pass "matching sets and hashes"

reset_fixture
expect_fail_dirs "committed directory reused as fresh" \
	"fresh image directory must differ" "$release"

reset_fixture
ln -s "$release" "$release_alias"
expect_fail_dirs "committed directory alias reused as fresh" \
	"fresh image directory must differ" "$release_alias"

reset_fixture
mkdir -p "$fresh2"
mv "$fresh/b.hex" "$fresh2"/
expect_pass_dirs "matching images split across directories" "$fresh" "$fresh2"

reset_fixture
ln -s "$fresh" "$fresh_alias"
expect_fail_dirs "duplicate fresh directory alias" \
	"duplicate fresh image directory" "$fresh" "$fresh_alias"

reset_fixture
expect_fail_dirs "duplicate fresh directory" \
	"duplicate fresh image directory" "$fresh" "$fresh"

reset_fixture
mkdir -p "$fresh2"
cp "$fresh/a.hex" "$fresh2"/
expect_fail_dirs "duplicate fresh basename" "duplicate image name" "$fresh" "$fresh2"

# Mutate every original input at the first checksum command. The verifier must
# already have snapshotted SHA256SUMS plus both image sets, so the private
# pre-mutation copies still pass. Any later read from a mutable source fails.
reset_fixture
mkdir -p "$fakebin"
printf '%s\n' \
	'#!/usr/bin/env bash' \
	'set -euo pipefail' \
	'if [ ! -e "$MUTATION_SENTINEL" ]; then' \
	'    : > "$MUTATION_SENTINEL"' \
	'    printf "mutated\\n" >> "$MUTATE_RELEASE/a.hex"' \
	'    printf "mutated\\n" >> "$MUTATE_FRESH/a.hex"' \
	'    printf "not a checksum\\n" > "$MUTATE_RELEASE/SHA256SUMS"' \
	'fi' \
	'exec "$REAL_SHA256SUM" "$@"' \
	> "$fakebin/sha256sum"
chmod +x "$fakebin/sha256sum"
snapshot_sentinel="$work/snapshot-mutation-ran"
if ! output=$(PATH="$fakebin:$PATH" \
		REAL_SHA256SUM="$real_sha256sum" \
		MUTATION_SENTINEL="$snapshot_sentinel" \
		MUTATE_RELEASE="$release" \
		MUTATE_FRESH="$fresh" \
		"$fixture_verify" "$release" "$fresh" 2>&1); then
	fail "private input snapshots: valid snapshot was rejected: $output"
fi
[ -f "$snapshot_sentinel" ] \
	|| fail "private input snapshots: checksum hook did not mutate source inputs"
checks=$((checks + 1))

reset_fixture
sed -i '1s/  / */' "$release/SHA256SUMS"
expect_pass "GNU binary checksum marker"

reset_fixture
cp "$release/a.hex" "$release/unlisted.hex"
expect_fail "unlisted committed image" "committed release image set"

reset_fixture
cp "$release/a.hex" "$release/.hidden.hex"
expect_fail "hidden committed image" "invalid image name"

reset_fixture
rm "$release/b.hex"
expect_fail "listed committed image missing" "committed release image set"

reset_fixture
ln -s a.hex "$release/symlink.hex"
expect_fail "committed symlink image" "not a regular file"

reset_fixture
cp "$fresh/a.hex" "$fresh/extra.hex"
expect_fail "extra fresh image" "fresh build image set"

# An unlisted image reaching a release, named for a part number this repository
# does not build at all -- so the coverage cannot go vacuous behind a rename of a
# real part. (Until v0.9.9 the PIC12F675 was the staged part pinned here; it is
# now release-supported and appears in the canonical set below, so a real
# bypass-pic12f675-*.hex name would no longer be a rejection case.)
reset_fixture
cp "$release/a.hex" "$release/bypass-pic99f999-cd4053_simple.hex"
expect_fail "unlisted image in committed release" "committed release image set"

reset_fixture
cp "$fresh/a.hex" "$fresh/bypass-pic99f999-cd4053_simple.hex"
expect_fail "unlisted image in fresh build" "fresh build image set"

reset_fixture
cp "$fresh/a.hex" "$fresh/.hidden.hex"
expect_fail "hidden fresh image" "invalid image name"

reset_fixture
mv "$fresh/b.hex" "$fresh/renamed.hex"
expect_fail "renamed fresh image" "fresh build image set"

reset_fixture
rm "$fresh/b.hex"
ln -s a.hex "$fresh/b.hex"
expect_fail "fresh symlink image" "not a regular file"

reset_fixture
rm "$fresh/a.hex" "$fresh/b.hex"
expect_fail "empty fresh image set" "contains no .hex images"

reset_fixture
mkfifo "$fresh/fifo.hex"
expect_fail "fresh FIFO image" "not a regular file"

reset_fixture
mkdir "$fresh/directory.hex"
expect_fail "fresh directory image" "not a regular file"

reset_fixture
printf ':00000001FE\n' >> "$release/a.hex"
expect_fail "committed byte mismatch" "committed release checksum verification failed"

reset_fixture
printf ':00000001FE\n' >> "$fresh/a.hex"
expect_fail "fresh byte mismatch" "fresh image checksum verification failed"

reset_fixture
printf '%s\n' "$(sed -n '1p' "$release/SHA256SUMS")" >> "$release/SHA256SUMS"
expect_fail "duplicate checksum entry" "duplicate SHA256SUMS entry"

reset_fixture
printf 'not a checksum\n' >> "$release/SHA256SUMS"
expect_fail "malformed checksum entry" "malformed SHA256SUMS entry"

# ---------------------------------------------------------------------------
# Required release artifacts that are NOT firmware images.
#
# A release also ships tools -- as of v0.9.10, the standalone PIC12F675 flashing
# helper. They are staged, checksummed and signed like an image, and they must
# be held to the tracked source byte for byte, because no build step produces
# them and the signature alone says nothing about WHICH bytes were signed.
#
# The failure this section exists to prevent is subtler than a missing file: if
# every checksum entry were treated as a firmware image, adding one tool would
# silently move the reviewed 21-image count, and the exact-set comparison that
# catches a whole missing MCU would start accepting whatever the staging
# directory happened to contain.
# ---------------------------------------------------------------------------

reset_fixture
rm "$release/helper.py"
expect_fail "required artifact absent from the committed release" \
	"committed release is missing required artifact"

reset_fixture
(cd "$release" && sha256sum a.hex b.hex $FIXTURE_PROVENANCE > SHA256SUMS)
expect_fail "required artifact absent from SHA256SUMS" \
	"do not exactly match the required release artifact set"

reset_fixture
printf '# staged bytes that are not the tracked source\n' >> "$release/helper.py"
(cd "$release" && sha256sum a.hex b.hex helper.py $FIXTURE_PROVENANCE > SHA256SUMS)
expect_fail "staged artifact drifted from its tracked source" \
	"differs from its tracked source"

reset_fixture
rm "$fixture_root/scripts/helper.py"
expect_fail "tracked artifact source missing" \
	"tracked source for release artifact"

# Fail closed, not open: an empty declaration must be an error rather than a
# silently disabled artifact gate.
reset_fixture
set_fixture_helper_map ''
expect_fail "empty required artifact set" \
	"required release artifact set is empty"

reset_fixture
set_fixture_helper_map 'helper.hex=scripts/helper.py'
expect_fail "artifact named like a firmware image" \
	"may not be named like a firmware image"

reset_fixture
set_fixture_helper_map 'helper.py'
expect_fail "malformed artifact declaration" \
	"malformed release artifact declaration"

reset_fixture
set_fixture_helper_map 'helper.py=scripts/helper.py helper.py=scripts/other.py'
expect_fail "duplicate artifact declaration" "duplicate release artifact"

# An undeclared non-image entry is not quietly tolerated as "some other
# artifact": it lands in the image comparison and fails there by name.
reset_fixture
printf '%064d  stowaway.txt\n' 0 >> "$release/SHA256SUMS"
expect_fail "undeclared non-image checksum entry" \
	"do not exactly match the canonical release product set"

# --- the provenance leg -------------------------------------------------------
# A release signs three things about itself: what the firmware is, how to
# program it, and where it came from. The third set is held exactly like the
# other two, so a provenance file cannot go missing from the signature, appear
# in it undeclared, or be listed without being there.
reset_fixture
grep -v '  QUALIFICATION$' "$release/SHA256SUMS" > "$release/SHA256SUMS.tmp"
mv "$release/SHA256SUMS.tmp" "$release/SHA256SUMS"
expect_fail "provenance file absent from SHA256SUMS" \
	"do not exactly match the provenance file set"

reset_fixture
rm -f "$release/README.md"
expect_fail "declared provenance file absent from the release" \
	"provenance file is missing, empty, or not a regular file"

reset_fixture
rm -f "$release/README.md"
printf 'elsewhere\n' > "$release/real-readme"
ln -s real-readme "$release/README.md"
expect_fail "symlinked provenance file" \
	"provenance file is missing, empty, or not a regular file"

# The digest leg: listed under the right name, wrong bytes. `sha256sum -c` over
# the committed snapshot is what makes the listing mean something.
reset_fixture
printf 'rewritten after sealing\n' >> "$release/MANIFEST.md"
expect_fail "provenance file edited after sealing" \
	"committed release checksum verification failed"

# Fail closed, exactly as the helper set does.
reset_fixture
set_fixture_provenance_files ''
expect_fail "empty provenance set" "provenance file set is empty"

reset_fixture
set_fixture_provenance_files 'QUALIFICATION MANIFEST.md README.md QUALIFICATION'
expect_fail "duplicate provenance declaration" "duplicate provenance file"

reset_fixture
set_fixture_provenance_files 'QUALIFICATION MANIFEST.md README.md SHA256SUMS'
expect_fail "checksum list declared as its own provenance" \
	"cannot be listed in itself"

reset_fixture
set_fixture_provenance_files 'QUALIFICATION MANIFEST.md README.md provenance.hex'
expect_fail "provenance named like a firmware image" \
	"may not be named like a firmware image"

# A name cannot be both a tool and a provenance file: the two sets carry
# different reproduction claims, and an entry in both would satisfy whichever
# comparison ran first.
reset_fixture
set_fixture_provenance_files 'QUALIFICATION MANIFEST.md README.md helper.py'
expect_fail "name declared as both artifact and provenance" \
	"declared as both a release artifact and a provenance file"

# --- the three published eras -------------------------------------------------
# This verifier is not only run on releases being staged. Every PIC12F675 field
# programming runs it against a PUBLISHED directory, and those signatures cannot
# be reissued. release/ currently holds three contracts: no QUALIFICATION at all
# (v0.9.0-v0.9.5), format=1 (v0.9.6-v0.9.9) and format=3 (v0.9.10-v0.9.11), none
# of which signed provenance. The release's own format field is what tells them
# apart, so it is exercised here in both directions rather than assumed.
unseal_fixture_provenance() {
	(
		cd "$release"
		grep -v -E '  (QUALIFICATION|MANIFEST\.md|README\.md)$' SHA256SUMS \
			> SHA256SUMS.tmp
		mv SHA256SUMS.tmp SHA256SUMS
	)
}

reset_fixture
printf 'format=3\n' > "$release/QUALIFICATION"
unseal_fixture_provenance
expect_pass "format=3 release with provenance outside the signature"

reset_fixture
printf 'format=1\n' > "$release/QUALIFICATION"
unseal_fixture_provenance
expect_pass "format=1 release with provenance outside the signature"

reset_fixture
rm -f "$release/QUALIFICATION" "$release/MANIFEST.md" "$release/README.md"
unseal_fixture_provenance
expect_pass "pre-QUALIFICATION release with no provenance at all"

# Half-adopting the new contract is rejected from the other side: a recipient
# who sees one provenance file inside the signature and the rest outside cannot
# tell which era they are verifying.
reset_fixture
printf 'format=3\n' > "$release/QUALIFICATION"
expect_fail "format=3 release listing provenance in its signature" \
	"declares QUALIFICATION format=3 but its SHA256SUMS lists provenance files"

reset_fixture
printf 'format=notanumber\n' > "$release/QUALIFICATION"
expect_fail "release declaring a non-numeric format" \
	"declares a non-numeric format"

# The reproduction leg rebuilds IMAGES. A tool sitting in a fresh build
# directory is not part of what a compiler reproduced, and is ignored.
reset_fixture
cp "$fixture_root/scripts/helper.py" "$fresh/helper.py"
expect_pass "a stray tool in the fresh build directory is ignored"

# ---------------------------------------------------------------------------
# The canonical product set (merge plan §10). Everything above compares the
# three OBSERVED sets -- committed directory, SHA256SUMS, fresh build -- against
# each other. That is the check that cannot catch an omission the observations
# share. These assert the independent fourth opinion.
# ---------------------------------------------------------------------------

# THE headline case: delete an image from ALL THREE observed sets at once, so
# every pairwise comparison agrees perfectly. This is precisely what shipping a
# release with an entire MCU missing looks like, and before the canonical set
# existed it PASSED.
reset_fixture
rm "$release/b.hex" "$fresh/b.hex"
(cd "$release" && sha256sum a.hex helper.py $FIXTURE_PROVENANCE > SHA256SUMS)
expect_fail "image omitted from all three observed sets" \
	"do not exactly match the canonical release product set"

# ...and the same omission in the other direction: an image present everywhere
# but absent from the canonical set is equally a release-contents change, and
# must not slip through as "all three agree".
reset_fixture
set_fixture_expected_images 'a.hex'
expect_fail "image present everywhere but not canonical" \
	"do not exactly match the canonical release product set"

# Fail closed, not open: an empty value from the test-only Makefile must be an
# error rather than a silently disabled canonical-set gate.
reset_fixture
set_fixture_expected_images ''
expect_fail "empty canonical set" "canonical release image set is empty"

reset_fixture
set_fixture_expected_images 'a.hex ../escape.hex'
expect_fail "invalid name in canonical set" \
	"canonical release image set has an invalid image name"

reset_fixture
set_fixture_expected_images 'a.hex b.hex a.hex'
expect_fail "duplicate in canonical set" \
	"canonical release image set has a duplicate image name"

# The canonical set is composed from FW_BASE and the per-part MCU tags, all of
# which a caller can move; RELEASE_IDENTITY_IMAGES is the `override` pin that
# no channel reaches. A reproduction run whose canonical set has drifted from
# that pin is verifying the wrong release, however perfectly its three observed
# sets agree with each other -- so it is rejected in BOTH directions.
reset_fixture
set_fixture_identity_images 'a.hex'
expect_fail "canonical set wider than the pinned identity" \
	"does not match the pinned production release identity"

reset_fixture
set_fixture_identity_images 'a.hex b.hex c.hex'
expect_fail "canonical set narrower than the pinned identity" \
	"does not match the pinned production release identity"

# Fail closed here too: an empty pin must not silently disable the comparison.
reset_fixture
set_fixture_identity_images ''
expect_fail "empty pinned identity" \
	"pinned release image identity is empty"

# Same members, different order: identity is a SET, and a reordered declaration
# is not drift.
reset_fixture
set_fixture_identity_images 'b.hex a.hex'
expect_pass "pinned identity declared in another order"

# Drive the production verifier with no hostile ambient value against a fixture
# that cannot match, and require the failure to name the Makefile as the source.
# Otherwise a broken `make -s print-RELEASE_IMAGES` could leave the gate reading
# an empty set.
reset_fixture
unset RELEASE_EXPECTED_IMAGES
if output=$("$VERIFY" "$release" "$fresh" 2>&1); then
	fail "canonical set read from the Makefile by default: synthetic release was accepted"
fi
[[ "$output" == *"(Makefile RELEASE_IMAGES)"* ]] \
	|| fail "production canonical-set failure did not name the Makefile: $output"
checks=$((checks + 1))

# The exact ambient-reduction exploit: all three observed sets contain one
# valid image and agree on its bytes. A stale exported one-image value must not
# replace the production Makefile's complete 18-image oracle. The same applies
# to GNU Make's inherited option, variable and injected-makefile channels.
reset_fixture
rm "$release/b.hex" "$fresh/b.hex"
(cd "$release" && sha256sum a.hex helper.py $FIXTURE_PROVENANCE > SHA256SUMS)
injected_makefile="$work/injected-release-images.mk"
printf 'override RELEASE_IMAGES := a.hex\n' > "$injected_makefile"

expect_ambient_reduction_rejected() {
	local label=$1 output
	shift
	if output=$(env "$@" "$VERIFY" "$release" "$fresh" 2>&1); then
		fail "$label reduced the production canonical set"
	fi
	[[ "$output" == *"SHA256SUMS entries do not exactly match"* \
		&& "$output" == *"(Makefile RELEASE_IMAGES)"* ]] \
		|| fail "$label failed for the wrong reason: $output"
	checks=$((checks + 1))
}

expect_ambient_reduction_rejected "inherited RELEASE_EXPECTED_IMAGES" \
	RELEASE_EXPECTED_IMAGES=a.hex
expect_ambient_reduction_rejected "inherited MAKEFLAGS assignment" \
	MAKEFLAGS=RELEASE_IMAGES=a.hex
expect_ambient_reduction_rejected "inherited GNUMAKEFLAGS assignment" \
	GNUMAKEFLAGS=RELEASE_IMAGES=a.hex
expect_ambient_reduction_rejected "inherited MAKEFILES injection" \
	MAKEFILES="$injected_makefile"
expect_ambient_reduction_rejected "inherited Make environment precedence" \
	MAKEFLAGS=-e RELEASE_IMAGES=a.hex

# Finally, the content of the real canonical set. Every check above works
# equally well on a set that has quietly lost a whole MCU, so assert what the
# Makefile actually declares: all seven release-supported MCU parts present, in the
# quantity each part's variant matrix implies.
#
# --no-print-directory is load-bearing on every capture below, and -s does not
# imply it: Make enables -w in a sub-make and propagates a literal w through
# MAKEFLAGS, where it OVERRIDES -s. `make release` runs this gate through such
# a sub-make (make-release.sh holds the worktree lock, so the serialization
# wrapper that would supply the flag is skipped), and `read -r -a` then parsed
# the first line of the reply -- the directory banner -- into a 4-word
# "canonical set". Direct `make test-long` never saw it.
canonical=$(cd "$ROOT" && make -s --no-print-directory print-RELEASE_IMAGES) \
	|| fail "could not read RELEASE_IMAGES from the Makefile"
read -r -a canonical_arr <<<"$canonical"
[ "${#canonical_arr[@]}" -eq 21 ] \
	|| fail "canonical release set has ${#canonical_arr[@]} images, expected 21"
checks=$((checks + 1))

subset_canonical=$(cd "$ROOT" && \
	make -s --no-print-directory VARIANTS=cd4053_with_mute print-RELEASE_IMAGES) \
	|| fail "could not read RELEASE_IMAGES with a classic-output subset override"
[ "$subset_canonical" = "$canonical" ] \
	|| fail "VARIANTS override changed the canonical release set"
checks=$((checks + 1))

subset_canonical=$(cd "$ROOT" && \
	make -s --no-print-directory PIC10F320_VARIANTS_ALL=cd4053_with_mute \
		print-RELEASE_IMAGES) \
	|| fail "could not read RELEASE_IMAGES with a PIC10F320 subset override"
[ "$subset_canonical" = "$canonical" ] \
	|| fail "PIC10F320_VARIANTS_ALL override changed the canonical release set"
checks=$((checks + 1))

count_matching() {
	local pattern=$1 n=0 base
	for base in "${canonical_arr[@]}"; do
		case "$base" in $pattern) n=$((n + 1)) ;; esac
	done
	printf '%s' "$n"
}

expect_count() {
	local label=$1 pattern=$2 want=$3 got
	got=$(count_matching "$pattern")
	[ "$got" -eq "$want" ] \
		|| fail "canonical set has $got $label images, expected $want (pattern $pattern)"
	checks=$((checks + 1))
}

# Every image names its MCU in the same field, so one pattern shape covers all
# six parts -- and an image with NO MCU field (the pre-v0.9.8 bare `bypass_<v>.hex`
# ATtiny13a spelling) matches none of them, which the total below then catches.
expect_count "ATtiny13a"  'bypass-attiny13a-*.hex' 3
expect_count "ATtiny85"   'bypass-attiny85-*.hex'  3
expect_count "ATtiny45"   'bypass-attiny45-*.hex'  3
expect_count "ATtiny202"  'bypass-attiny202-*.hex' 3
expect_count "PIC10F322"  'bypass-pic10f322-*.hex' 3
expect_count "PIC10F320"  'bypass-pic10f320-*.hex' 3
expect_count "PIC12F675"  'bypass-pic12f675-*.hex' 3
expect_count "canonically named" 'bypass-*-*.hex'  21
[ "${#canonical_arr[@]}" -eq 21 ] \
	|| fail "canonical release set has ${#canonical_arr[@]} images, expected 21"
checks=$((checks + 1))

# Name the ATtiny202 and PIC10F320 images explicitly. A count alone would survive
# a rename, and these basenames are a published interface.
for base in bypass-attiny202-cd4053_simple.hex \
		bypass-attiny202-cd4053_with_mute.hex \
		bypass-attiny202-tq2_l2_5v_relay.hex; do
	[[ " $canonical " == *" $base "* ]] \
		|| fail "canonical release set is missing $base"
	checks=$((checks + 1))
done

for base in bypass-pic10f320-cd4053_simple.hex \
		bypass-pic10f320-cd4053_with_mute.hex \
		bypass-pic10f320-tq2_l2_5v_relay.hex; do
	[[ " $canonical " == *" $base "* ]] \
		|| fail "canonical release set is missing $base"
	checks=$((checks + 1))
done

for base in bypass-pic12f675-cd4053_simple.hex \
		bypass-pic12f675-cd4053_with_mute.hex \
		bypass-pic12f675-tq2_l2_5v_relay.hex; do
	[[ " $canonical " == *" $base "* ]] \
		|| fail "canonical release set is missing $base"
	checks=$((checks + 1))
done

# The PIC12F675 build directory IS now a reproduction input: as of v0.9.9 the
# part is release-supported, so RELEASE_IMAGE_DIRS must include it (a released
# image cannot be withheld from the set the verifier rebuilds from).
release_dirs=$(cd "$ROOT" && make -s --no-print-directory print-RELEASE_IMAGE_DIRS) \
	|| fail "could not read RELEASE_IMAGE_DIRS from the Makefile"
pic12f675_dir=$(cd "$ROOT" && make -s --no-print-directory print-PIC12F675_BUILD_DIR) \
	|| fail "could not read PIC12F675_BUILD_DIR from the Makefile"
[ -n "$pic12f675_dir" ] || fail "PIC12F675_BUILD_DIR is empty"
[[ " $release_dirs " == *" $pic12f675_dir "* ]] \
	|| fail "RELEASE_IMAGE_DIRS is missing the PIC12F675 build directory $pic12f675_dir"
checks=$((checks + 1))

# ---------------------------------------------------------------------------
# The production release identity is PINNED, and neither channel can move it.
#
# Everything above reads the canonical set out of the Makefile -- and the
# canonical set is composed from $(FW_BASE), the per-part MCU tags and the
# tinyx5 membership, every one of which a caller can override. So is
# scripts/make-release.sh's independent enumeration, which reads the same
# variables through print-<VAR>. Two opinions built from one overridden input
# agree with each other, so `make release FW_BASE=other` used to stage and
# publish a complete, self-consistent set of images nobody had reviewed.
#
# The two channels are NOT equivalent and both are exercised below. A command
# line reaches a sub-make through MAKEOVERRIDES and beats a plain `=`
# assignment; the environment cannot move a plain `=` but DOES win every `?=`,
# which is how all four per-part MCU tags are declared -- an exported
# PIC12F675_TAG changes the release without appearing in any command anyone
# typed.
# ---------------------------------------------------------------------------
identity_images=$(cd "$ROOT" && make -s --no-print-directory print-RELEASE_IDENTITY_IMAGES) \
	|| fail "could not read RELEASE_IDENTITY_IMAGES from the Makefile"
read -r -a identity_arr <<<"$identity_images"
[ "${#identity_arr[@]}" -eq 21 ] \
	|| fail "pinned release identity has ${#identity_arr[@]} images, expected 21"
checks=$((checks + 1))

# The pin and the canonical set are computed from disjoint inputs -- literal
# words versus the live build variables -- so requiring them to agree is a real
# cross-check, and it is what makes every count assertion above meaningful.
[ "$(printf '%s\n' "${identity_arr[@]}" | LC_ALL=C sort)" \
	= "$(printf '%s\n' "${canonical_arr[@]}" | LC_ALL=C sort)" ] \
	|| fail "RELEASE_IMAGES does not match the pinned RELEASE_IDENTITY_IMAGES"
checks=$((checks + 1))

identity_soaks=$(cd "$ROOT" && make -s --no-print-directory print-RELEASE_IDENTITY_SOAKS) \
	|| fail "could not read RELEASE_IDENTITY_SOAKS from the Makefile"
read -r -a identity_soak_arr <<<"$identity_soaks"
[ "${#identity_soak_arr[@]}" -eq 18 ] \
	|| fail "pinned release identity has ${#identity_soak_arr[@]} soak combinations, expected 18"
checks=$((checks + 1))

release_soaks=$(cd "$ROOT" && make -s --no-print-directory print-RELEASE_SOAK_NAMES) \
	|| fail "could not read RELEASE_SOAK_NAMES from the Makefile"
read -r -a release_soak_arr <<<"$release_soaks"
[ "$(printf '%s\n' "${identity_soak_arr[@]}" | LC_ALL=C sort)" \
	= "$(printf '%s\n' "${release_soak_arr[@]}" | LC_ALL=C sort)" ] \
	|| fail "RELEASE_SOAK_NAMES does not match the pinned RELEASE_IDENTITY_SOAKS"
checks=$((checks + 1))

# The pin itself must be unreachable from both channels, or it is just another
# selected value wearing the word "identity".
for pinned_var in RELEASE_IDENTITY_PINNED RELEASE_IDENTITY_IMAGES \
		RELEASE_IDENTITY_SOAKS RELEASE_IDENTITY_PARTS RELEASE_IDENTITY_VARIANTS; do
	pinned_value=$(cd "$ROOT" && make -s --no-print-directory print-"$pinned_var") \
		|| fail "could not read $pinned_var from the Makefile"
	[ -n "$pinned_value" ] || fail "Makefile $pinned_var is empty"
	checks=$((checks + 1))

	moved=$(cd "$ROOT" && make -s --no-print-directory "$pinned_var=hijacked" \
		print-"$pinned_var") \
		|| fail "could not read $pinned_var under a command-line override"
	[ "$moved" = "$pinned_value" ] \
		|| fail "a command-line assignment moved the pinned $pinned_var"
	checks=$((checks + 1))

	moved=$(cd "$ROOT" && env "$pinned_var=hijacked" make -s --no-print-directory \
		print-"$pinned_var") \
		|| fail "could not read $pinned_var under an environment override"
	[ "$moved" = "$pinned_value" ] \
		|| fail "an inherited environment value moved the pinned $pinned_var"
	checks=$((checks + 1))
done

# A canonical tree drifts from nothing.
drift=$(cd "$ROOT" && make -s --no-print-directory print-RELEASE_IDENTITY_DRIFT) \
	|| fail "could not read RELEASE_IDENTITY_DRIFT from the Makefile"
[ -z "$drift" ] \
	|| fail "an unmodified tree reports release identity drift: $drift"
checks=$((checks + 1))

# `make -n release` parses the Makefile and prints the recipe without running
# it, so it exercises the parse-time guard -- the outermost enforcement point,
# which fires before the worktree lock and before make-release.sh exists as a
# process -- at no cost and with no side effect.
expect_release_goal_accepted() {   # usage: <label> <channel> [assignment ...]
	local label=$1 channel=$2
	shift 2
	local output rc=0
	case "$channel" in
		command-line) output=$(cd "$ROOT" && env -i PATH="$PATH" HOME="$HOME" \
			TMPDIR="${TMPDIR:-$HOME}" make -n release "$@" 2>&1) || rc=$? ;;
		environment)  output=$(cd "$ROOT" && env -i PATH="$PATH" HOME="$HOME" \
			TMPDIR="${TMPDIR:-$HOME}" "$@" make -n release 2>&1) || rc=$? ;;
		*) fail "unknown override channel: $channel" ;;
	esac
	[ "$rc" -eq 0 ] \
		|| fail "$label ($channel) was refused by the release identity guard: $output"
	[[ "$output" == *"scripts/make-release.sh"* ]] \
		|| fail "$label ($channel) did not reach the release recipe: $output"
	checks=$((checks + 1))
}

expect_release_goal_refused() {   # usage: <label> <named variable> <channel> [assignment ...]
	local label=$1 named=$2 channel=$3
	shift 3
	local output rc=0
	case "$channel" in
		command-line) output=$(cd "$ROOT" && env -i PATH="$PATH" HOME="$HOME" \
			TMPDIR="${TMPDIR:-$HOME}" make -n release "$@" 2>&1) || rc=$? ;;
		environment)  output=$(cd "$ROOT" && env -i PATH="$PATH" HOME="$HOME" \
			TMPDIR="${TMPDIR:-$HOME}" "$@" make -n release 2>&1) || rc=$? ;;
		*) fail "unknown override channel: $channel" ;;
	esac
	[ "$rc" -ne 0 ] \
		|| fail "$label ($channel) staged a release under an overridden identity"
	[[ "$output" == *"overridden production release identity"* ]] \
		|| fail "$label ($channel) was refused for the wrong reason: $output"
	[[ "$output" == *"$named"* ]] \
		|| fail "$label ($channel) did not name $named in its diagnostic: $output"
	[[ "$output" != *"scripts/make-release.sh"* ]] \
		|| fail "$label ($channel) reached the release recipe before failing: $output"
	checks=$((checks + 1))
}

expect_release_override_refused() { # usage: <label> <named variable> <channel> [assignment ...]
	local label=$1 named=$2 channel=$3
	shift 3
	local output rc=0
	case "$channel" in
		command-line) output=$(cd "$ROOT" && env -i PATH="$PATH" HOME="$HOME" \
			TMPDIR="${TMPDIR:-$HOME}" make -n release "$@" 2>&1) || rc=$? ;;
		environment)  output=$(cd "$ROOT" && env -i PATH="$PATH" HOME="$HOME" \
			TMPDIR="${TMPDIR:-$HOME}" "$@" make -n release 2>&1) || rc=$? ;;
		*) fail "unknown override channel: $channel" ;;
	esac
	[ "$rc" -ne 0 ] \
		|| fail "$label ($channel) reached a release under an unsupported override"
	[[ "$output" == *"unsupported release overrides"* ]] \
		|| fail "$label ($channel) was refused for the wrong reason: $output"
	[[ "$output" == *"$named"* ]] \
		|| fail "$label ($channel) did not name $named in its diagnostic: $output"
	[[ "$output" != *"scripts/make-release.sh"* ]] \
		|| fail "$label ($channel) reached the release recipe before failing: $output"
	checks=$((checks + 1))
}

expect_release_goal_accepted "an unmodified release goal" command-line

# Both channels, over every field the acceptance criteria name: the basename,
# the tinyx5 membership, all seven MCU tags, and the three variant sets.
for spec in \
		"FW_BASE=hijacked|FW_BASE" \
		"ATTINY13A_MCU=attiny13|ATTINY13A_MCU" \
		"TINYX5=85|TINYX5" \
		"mmcu_85=attiny861|TINYX5_PARTS" \
		"XT_TAG=attiny402|XT_TAG" \
		"XT_MCU=attiny402|XT_MCU" \
		"PIC10F322_TAG=pic10f322a|PIC10F322_TAG" \
		"PIC10F322_CHIP=10F320|PIC10F322_CHIP" \
		"PIC10F320_TAG=pic10f320a|PIC10F320_TAG" \
		"PIC10F320_CHIP=10F322|PIC10F320_CHIP" \
		"PIC12F675_TAG=pic12f629|PIC12F675_TAG" \
		"TINYX5_F_CPU=8000000UL|TINYX5_F_CPU" \
		"PIC10F320_XTAL=8000000UL|PIC10F320_XTAL" \
		"VARIANTS=cd4053_simple|VARIANTS" \
		"PIC10F320_VARIANTS_ALL=cd4053_simple|PIC10F320_VARIANTS_ALL" \
		"ATTINY13A_F_CPU=9600000UL|ATTINY13A_F_CPU" \
		"XT_F_CPU=3333333UL|XT_F_CPU" \
		"PIC12F675_XTAL=8000000UL|PIC12F675_XTAL" ; do
	assignment=${spec%%|*}
	named=${spec##*|}
	expect_release_goal_refused "an overridden ${assignment%%=*}" "$named" \
		command-line "$assignment"
done

# The environment moves only what the Makefile declares with `?=`, which is
# exactly the set a reader is least likely to suspect: the per-part MCU tags and
# die selectors are all `?=`, so they change a release from an export. The
# plain-`=` names below are inert from the environment, and asserting that is
# what keeps the two channels from being confused for each other.
for spec in \
		"XT_TAG=attiny402|XT_TAG" \
		"XT_MCU=attiny402|XT_MCU" \
		"PIC10F322_TAG=pic10f322a|PIC10F322_TAG" \
		"PIC10F322_CHIP=10F320|PIC10F322_CHIP" \
		"PIC10F320_TAG=pic10f320a|PIC10F320_TAG" \
		"PIC10F320_CHIP=10F322|PIC10F320_CHIP" \
		"PIC12F675_TAG=pic12f629|PIC12F675_TAG" \
		"PIC12F675_XTAL=8000000UL|PIC12F675_XTAL" \
		"XT_F_CPU=3333333UL|XT_F_CPU" \
		"PIC10F320_XTAL=8000000UL|PIC10F320_XTAL" \
		"PIC10F322_XTAL=8000000UL|PIC10F322_XTAL" ; do
	assignment=${spec%%|*}
	named=${spec##*|}
	expect_release_goal_refused "an inherited ${assignment%%=*}" "$named" \
		environment "$assignment"
done

for assignment in FW_BASE=hijacked ATTINY13A_MCU=attiny13 TINYX5=85 \
		ATTINY13A_F_CPU=9600000UL TINYX5_F_CPU=8000000UL; do
	expect_release_goal_accepted "an inherited ${assignment%%=*} (a plain = assignment the environment cannot move)" \
		environment "$assignment"
done

# Four identity fields are already unreachable from both channels because the
# Makefile declares them with `override`. The pin still names them: it is what
# catches a SOURCE edit -- the one channel `override` does not defend against --
# and it is why this loop asserts the value rather than a refusal.
for immutable_var in PIC12F675_CHIP CLASSIC_VARIANTS_SUPPORTED \
		XT_VARIANTS_SUPPORTED PIC10F320_VARIANTS_SUPPORTED; do
	immutable_value=$(cd "$ROOT" && make -s --no-print-directory print-"$immutable_var") \
		|| fail "could not read $immutable_var from the Makefile"
	[ -n "$immutable_value" ] || fail "Makefile $immutable_var is empty"
	moved=$(cd "$ROOT" && make -s --no-print-directory "$immutable_var=hijacked" \
		print-"$immutable_var") \
		|| fail "could not read $immutable_var under a command-line override"
	[ "$moved" = "$immutable_value" ] \
		|| fail "a command-line assignment moved $immutable_var, which the Makefile overrides"
	checks=$((checks + 1))
	moved=$(cd "$ROOT" && env "$immutable_var=hijacked" make -s --no-print-directory \
		print-"$immutable_var") \
		|| fail "could not read $immutable_var under an environment override"
	[ "$moved" = "$immutable_value" ] \
		|| fail "an inherited environment value moved $immutable_var, which the Makefile overrides"
	checks=$((checks + 1))
	expect_release_goal_accepted "an attempted $immutable_var override" \
		command-line "$immutable_var=hijacked"
done

# Source lists and compile/link flag bundles remain useful development override
# surfaces, but none is a supported release input. Cover each shipping target,
# both direct command-line transport and inherited Make precedence, and the two
# internally immutable PIC12F675 declarations (whose attempted origin would
# otherwise disappear behind `override`).
for assignment in \
		'CFLAGS=-DINJECTED_CLASSIC_FLAGS' \
		'LDFLAGS=-DINJECTED_CLASSIC_LINK' \
		'CORE_SRC=/dev/null' \
		'src_cd4053_simple=/dev/null' \
		'pic10f320_macro_cd4053_simple=OUTPUT_TQ2_RELAY' \
		'XT_CFLAGS=-DINJECTED_XT_FLAGS' \
		'XT_LDFLAGS=-DINJECTED_XT_LINK' \
		'XT_CORE_SRC=/dev/null' \
		'PIC10F322_CFLAGS=-DINJECTED_322_FLAGS' \
		'PIC10F322_CORE_SRC=/dev/null' \
		'PIC10F320_CFLAGS=-DINJECTED_320_FLAGS' \
		'PIC10F320_SRC=/dev/null' \
		'PIC12F675_CFLAGS=-DINJECTED_675_FLAGS' \
		'PIC12F675_CORE_SRC=/dev/null'; do
	expect_release_override_refused "an artifact-defining ${assignment%%=*} override" \
		"${assignment%%=*}" command-line "$assignment"
done

for assignment in \
		'CFLAGS=-DINHERITED_CLASSIC_FLAGS' \
		'CORE_SRC=/dev/null' \
		'XT_CFLAGS=-DINHERITED_XT_FLAGS' \
		'XT_CORE_SRC=/dev/null' \
		'PIC10F322_CFLAGS=-DINHERITED_322_FLAGS' \
		'PIC10F322_CORE_SRC=/dev/null' \
		'PIC10F320_CFLAGS=-DINHERITED_320_FLAGS' \
		'PIC10F320_SRC=/dev/null'; do
	expect_release_override_refused "an inherited artifact-defining ${assignment%%=*}" \
		"${assignment%%=*}" environment MAKEFLAGS=-e "$assignment"
done

# `?=` validation controls move under an ordinary export, without `-e`. They
# are release inputs just as surely as source/compile flags: accepting them can
# lower sanitizer, static-analysis, coverage, or workload gates.
for assignment in 'SANITIZE=' 'COVERAGE_MIN=0' 'CLANG_TIDY_CHECKS=-*'; do
	expect_release_override_refused "an inherited ${assignment%%=*} validation override" \
		"${assignment%%=*}" environment "$assignment"
done

# Assignment-bearing MAKEFLAGS/GNUMAKEFLAGS and a preloaded MAKEFILES fragment
# are indirect command-line channels. The former must still name the moved
# source/flag variable; the latter is rejected as injection before its contents
# can participate in release configuration.
expect_release_override_refused "a MAKEFLAGS source override" CORE_SRC \
	environment 'MAKEFLAGS=CORE_SRC=/dev/null'
expect_release_override_refused "a GNUMAKEFLAGS flag override" XT_CFLAGS \
	environment 'GNUMAKEFLAGS=XT_CFLAGS=-DINJECTED_XT_FLAGS'
injected_release_makefile="$work/injected-release.mk"
printf 'override CFLAGS := -DINJECTED_MAKEFILE_FLAGS\n' \
	> "$injected_release_makefile"
expect_release_override_refused "an injected makefile" MAKEFILES \
	environment "MAKEFILES=$injected_release_makefile"

# GNU Make evaluates --eval before the Makefile. Reject the option itself,
# including inherited transport, rather than trying to enumerate statements it
# can install with `override` origin.
for channel in direct inherited; do
	rc=0
	if [ "$channel" = direct ]; then
		output=$(cd "$ROOT" && env -i PATH="$PATH" HOME="$HOME" \
			TMPDIR="${TMPDIR:-$HOME}" make --eval='override SANITIZE :=' \
			-n release 2>&1) || rc=$?
	else
		output=$(cd "$ROOT" && env -i PATH="$PATH" HOME="$HOME" \
			TMPDIR="${TMPDIR:-$HOME}" \
			'MAKEFLAGS=--eval=override\ SANITIZE\ :=' make -n release 2>&1) || rc=$?
	fi
	[ "$rc" -ne 0 ] || fail "$channel --eval reached the release recipe"
	[[ "$output" == *"unsupported GNU Make options: --eval"* ]] \
		|| fail "$channel --eval was refused for the wrong reason: $output"
	[[ "$output" != *"scripts/make-release.sh"* ]] \
		|| fail "$channel --eval reached the release recipe before failing"
	checks=$((checks + 1))
done

# Ignore-errors is uniquely unsafe at the outer Make boundary: it converts a
# parse-approved release recipe's failed nested gates into successful recipes.
# Exercise both public goals and every spelling/transport GNU Make normalizes.
expect_release_make_mode_refused() { # usage: <label> <goal> <channel> [option/env ...]
	local label=$1 goal=$2 channel=$3
	shift 3
	local output rc=0
	case "$channel" in
		direct) output=$(cd "$ROOT" && env -i PATH="$PATH" HOME="$HOME" \
			TMPDIR="${TMPDIR:-$HOME}" make "$@" -n "$goal" 2>&1) || rc=$? ;;
		environment) output=$(cd "$ROOT" && env -i PATH="$PATH" HOME="$HOME" \
			TMPDIR="${TMPDIR:-$HOME}" "$@" make -n "$goal" 2>&1) || rc=$? ;;
		*) fail "unknown GNU Make option channel: $channel" ;;
	esac
	[ "$rc" -ne 0 ] || fail "$label reached the $goal recipe"
	[[ "$output" == *"unsupported GNU Make options"* \
		&& "$output" == *"ignore-errors"* ]] \
		|| fail "$label was refused for the wrong reason: $output"
	[[ "$output" != *"scripts/make-release.sh"* ]] \
		|| fail "$label reached the $goal recipe before failing: $output"
	checks=$((checks + 1))
}

expect_release_make_mode_refused "short -i" release direct -i
expect_release_make_mode_refused "long --ignore-errors" release-preflight \
	direct --ignore-errors
expect_release_make_mode_refused "compact inherited i" release environment \
	MAKEFLAGS=i
expect_release_make_mode_refused "short inherited -i" release-preflight environment \
	MAKEFLAGS=-i
expect_release_make_mode_refused "long inherited --ignore-errors" release environment \
	MAKEFLAGS=--ignore-errors
expect_release_make_mode_refused "GNUMAKEFLAGS --ignore-errors" release-preflight \
	environment GNUMAKEFLAGS=--ignore-errors

make_function_marker="$work/allowlisted-make-function-ran"
for channel in direct inherited; do
	rc=0
	assignment="PIC_CC=\$(shell touch $make_function_marker)"
	if [ "$channel" = direct ]; then
		output=$(cd "$ROOT" && env -i PATH="$PATH" HOME="$HOME" \
			TMPDIR="${TMPDIR:-$HOME}" make -n release "$assignment" 2>&1) || rc=$?
	else
		output=$(cd "$ROOT" && env -i PATH="$PATH" HOME="$HOME" \
			TMPDIR="${TMPDIR:-$HOME}" "$assignment" make -n release 2>&1) || rc=$?
	fi
	[ "$rc" -ne 0 ] || fail "$channel Make function in PIC_CC reached the release recipe"
	[[ "$output" == *"override values must not contain dollar signs or GNU Make functions: PIC_CC"* ]] \
		|| fail "$channel Make function in PIC_CC was refused for the wrong reason: $output"
	[ ! -e "$make_function_marker" ] \
		|| fail "$channel Make function in PIC_CC executed before rejection"
	[[ "$output" != *"scripts/make-release.sh"* ]] \
		|| fail "$channel Make function in PIC_CC reached the release recipe before failing"
	checks=$((checks + 1))
done

for tool_var in AWK OBJDUMP READELF MAKE; do
	rm -f "$make_function_marker"
	assignment="$tool_var=\$(shell touch $make_function_marker)"
	rc=0
	output=$(cd "$ROOT" && env -i PATH="$PATH" HOME="$HOME" \
		TMPDIR="${TMPDIR:-$HOME}" "$assignment" make -n release 2>&1) || rc=$?
	[ "$rc" -ne 0 ] || fail "inherited Make function in $tool_var reached the release recipe"
	[[ "$output" == *"override values must not contain dollar signs or GNU Make functions: $tool_var"* ]] \
		|| fail "inherited Make function in $tool_var was refused for the wrong reason: $output"
	[ ! -e "$make_function_marker" ] \
		|| fail "inherited Make function in $tool_var executed before rejection"
	[[ "$output" != *"scripts/make-release.sh"* ]] \
		|| fail "inherited Make function in $tool_var reached the release recipe before failing"
	checks=$((checks + 1))
done

# A preloaded fragment must not erase its own provenance and leave only its
# source/flag override behind.
cat > "$injected_release_makefile" <<'EOF'
override CFLAGS := -DINJECTED_MAKEFILE_FLAGS
override MAKEFILES :=
override MAKEFILE_LIST := Makefile
EOF
expect_release_override_refused "a self-erasing injected makefile" MAKEFILES \
	environment "MAKEFILES=$injected_release_makefile"

alternate_release_makefile="$work/alternate-release.mk"
cp "$ROOT/Makefile" "$alternate_release_makefile"
rc=0
output=$(cd "$ROOT" && env -i PATH="$PATH" HOME="$HOME" \
	TMPDIR="${TMPDIR:-$HOME}" make -n -f "$alternate_release_makefile" \
	release 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "an alternate top-level makefile reached the release recipe"
[[ "$output" == *"noncanonical makefile"* ]] \
	|| fail "an alternate top-level makefile was refused for the wrong reason: $output"
[[ "$output" != *"scripts/make-release.sh"* ]] \
	|| fail "an alternate top-level makefile reached the release recipe before failing"
checks=$((checks + 1))

expect_duplicate_inventory_refused() { # usage: <variable> <member> <diagnostic>
	local variable=$1 member=$2 diagnostic=$3
	local mutated_root="$work/duplicate-$variable" output rc=0
	local mutated_makefile="$mutated_root/Makefile"
	mkdir -p "$mutated_root"
	awk -v append="override $variable += $member" '
		/^override RELEASE_FIXED_EVIDENCE_FILES :=/ { print append }
		{ print }
	' "$ROOT/Makefile" > "$mutated_makefile"
	output=$(env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-$HOME}" \
		make -n -C "$mutated_root" release 2>&1) || rc=$?
	[ "$rc" -ne 0 ] \
		|| fail "a duplicate $variable member reached the release recipe"
	[[ "$output" == *"$diagnostic"* ]] \
		|| fail "a duplicate $variable member was refused for the wrong reason: $output"
	[[ "$output" != *"scripts/make-release.sh"* ]] \
		|| fail "a duplicate $variable member reached the release recipe before failing"
	checks=$((checks + 1))
}

# Source-level canonical inventory mistakes have no external override origin.
# They still fail at parse time, with duplicate detection preceding the set
# equality that would otherwise erase the extra member.
expect_duplicate_inventory_refused RELEASE_IMAGES "${canonical_arr[0]}" \
	'canonical RELEASE_IMAGES contains duplicate image names'
expect_duplicate_inventory_refused RELEASE_SOAK_NAMES "${identity_soak_arr[0]}" \
	'canonical RELEASE_SOAK_NAMES contains duplicate soak names'

expect_short_inventory_refused() { # usage: <variable> <diagnostic>
	local variable=$1 diagnostic=$2
	local mutated_root="$work/short-$variable" output rc=0
	local mutated_makefile="$mutated_root/Makefile"
	local append="override $variable := \$(wordlist 2,999,\$($variable))"
	mkdir -p "$mutated_root"
	awk -v append="$append" '
		/^override RELEASE_FIXED_EVIDENCE_FILES :=/ { print append }
		{ print }
	' "$ROOT/Makefile" > "$mutated_makefile"
	output=$(env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-$HOME}" \
		make -n -C "$mutated_root" release 2>&1) || rc=$?
	[ "$rc" -ne 0 ] \
		|| fail "a short $variable inventory reached the release recipe"
	[[ "$output" == *"$diagnostic"* ]] \
		|| fail "a short $variable inventory was refused for the wrong reason: $output"
	[[ "$output" != *"scripts/make-release.sh"* ]] \
		|| fail "a short $variable inventory reached the release recipe before failing"
	checks=$((checks + 1))
}

expect_short_inventory_refused RELEASE_IMAGES \
	'canonical RELEASE_IMAGES contains 20 images; expected exactly 21'
expect_short_inventory_refused RELEASE_SOAK_NAMES \
	'canonical RELEASE_SOAK_NAMES contains 17 soaks; expected exactly 18'

# Build directories and tool paths do not change what an artifact IS, a release
# host legitimately relocates them, and make-release.sh asserts and records the
# tool it actually selected. They must keep working.
expect_release_goal_accepted "relocated build directories" command-line \
	AVR_BUILD_DIR=out/avr PIC10F322_BUILD_DIR=out/322 \
	PIC10F320_BUILD_DIR=out/320 PIC12F675_BUILD_DIR=out/675 XT_BUILD_DIR=out/xt
expect_release_goal_accepted "relocated tool paths" command-line \
	CC=/opt/avr/bin/avr-gcc PIC_CC=/opt/xc8/bin/xc8-cc GPSIM=/opt/gpsim/bin/gpsim \
	CPPCHECK=/opt/cppcheck/bin/cppcheck
expect_release_goal_accepted "relocated tool paths" environment \
	OBJDUMP=/opt/avr/bin/avr-objdump READELF=/opt/bin/readelf
expect_release_goal_accepted "a relocated PIC12F675 Python" command-line \
	PIC12F675_PYTHON=/opt/python/bin/python3
expect_release_goal_accepted "a single-target VARIANT selection" command-line \
	VARIANT=tq2_l2_5v_relay

worktree_lock_id=$(stat -Lc '%d:%i' "$ROOT") \
	|| fail "could not identify the worktree lock"
expect_release_override_refused "a caller-supplied serialization marker" \
	_MAKE_SERIAL_LOCK_HELD command-line \
	"_MAKE_SERIAL_LOCK_HELD=$worktree_lock_id"

# ---------------------------------------------------------------------------
# The manifest generator's arms, cross-checked against the canonical set.
# scripts/make-release.sh's img_row describes each released image by matching
# its MCU field, and refuses outright to describe a name it does not recognize.
# That refusal is the graduation trip-wire -- adding a part to RELEASE_IMAGES
# without adding an arm fails the release -- so it is worth knowing that the
# arms and the canonical set agree in BOTH directions (checked below).
# ---------------------------------------------------------------------------
mapfile -t arm_specs < <(sed -n 's/^\t\t\(\${FW_BASE}[^)]*\))$/\1/p' \
	"$ROOT/scripts/make-release.sh")
# Pinned so a reformat of that case block fails here rather than silently
# extracting nothing and passing every check below vacuously.
[ "${#arm_specs[@]}" -eq 6 ] \
	|| fail "extracted ${#arm_specs[@]} manifest arms from make-release.sh, expected 6"
checks=$((checks + 1))

declare -A mkvar=()
for v in FW_BASE ATTINY13A_MCU XT_TAG PIC10F322_TAG PIC10F320_TAG PIC12F675_TAG; do
	mkvar[$v]=$(cd "$ROOT" && make -s --no-print-directory print-"$v") \
		|| fail "could not read $v from the Makefile"
	[ -n "${mkvar[$v]}" ] || fail "Makefile $v is empty"
done

arm_patterns=()
for spec in "${arm_specs[@]}"; do
	# One arm may carry several alternatives (attiny85|attiny45).
	IFS='|' read -r -a alternatives <<<"$spec"
	for pattern in "${alternatives[@]}"; do
		for v in "${!mkvar[@]}"; do
			pattern=${pattern//"\${$v}"/${mkvar[$v]}}
		done
		# No eval anywhere above, so an arm naming a variable this test does not
		# know stays unexpanded -- and says so instead of silently matching
		# nothing.
		[[ "$pattern" != *'$'* ]] \
			|| fail "manifest arm pattern has an unresolved variable: $pattern"
		arm_patterns+=("$pattern")
	done
done
[ "${#arm_patterns[@]}" -eq 7 ] \
	|| fail "expanded ${#arm_patterns[@]} manifest patterns, expected 7"
checks=$((checks + 1))

matches_an_arm() {
	local base=$1 pattern
	for pattern in "${arm_patterns[@]}"; do
		case "$base" in $pattern) return 0 ;; esac
	done
	return 1
}

for base in "${canonical_arr[@]}"; do
	matches_an_arm "$base" \
		|| fail "no make-release.sh manifest arm describes released image $base"
	checks=$((checks + 1))
done

# The other direction: an arm matching nothing is a part that left the release
# set without its manifest arm being removed.
for pattern in "${arm_patterns[@]}"; do
	matched=0
	for base in "${canonical_arr[@]}"; do
		case "$base" in $pattern) matched=1; break ;; esac
	done
	[ "$matched" -eq 1 ] \
		|| fail "make-release.sh manifest arm '$pattern' describes no released image"
	checks=$((checks + 1))
done

# No retired variant may return (§1).
[[ "$canonical" != *tmux4053* ]] \
	|| fail "canonical release set contains a retired tmux4053 image"
checks=$((checks + 1))

# Compose the signed tag, detached checksum, exact-set, and selected-image gates
# over a scratch Git repository. The production signature verifier has its own
# real-GPG regression; this fixture replaces only that cryptographic leaf so the
# byte-binding behavior can be exercised without the maintainer's private key.
binding_repo="$work/release-program-binding"
binding_temp="$work/release-program-temp"
binding_tag=v1.0.0
binding_variant=cd4053_simple
binding_image=bypass-pic12f675-cd4053_simple.hex
binding_canonical='a.hex bypass-pic12f675-cd4053_simple.hex bypass-pic12f675-cd4053_with_mute.hex bypass-pic12f675-tq2_l2_5v_relay.hex'
binding_helper=flash-pic12f675.py

setup_binding_fixture() {
	local mutation=${1:-none} binding_release="$binding_repo/release/$binding_tag"
	rm -rf "$binding_repo" "$binding_temp"
	mkdir -p "$binding_repo/scripts" "$binding_release" "$binding_temp"
	chmod 700 "$binding_temp"
	cp -p "$BIND_VERIFY_SOURCE" "$binding_repo/scripts/verify-release-program-image.sh"
	cp -p "$VERIFY" "$binding_repo/scripts/verify-release-images.sh"
	cp -p "$ROOT/scripts/release-signing-policy.sh" \
		"$binding_repo/scripts/release-signing-policy.sh"
	cat > "$binding_repo/scripts/verify-release-signature.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "$0")/release-signing-policy.sh"
[ "${BINDING_SIGNATURE_MODE:-pass}" != "fail-${1:-}" ] || {
	printf 'fixture signature rejection\n' >&2
	exit 1
}
case "${1:-}" in
	tag|detached) \
		printf 'SIGNATURE-VALID: %s signature made by %s.\n' \
			"$1" "$RELEASE_SIGNING_FINGERPRINT" ;;
	*) exit 2 ;;
esac
EOF
	chmod 755 "$binding_repo/scripts/verify-release-signature.sh"
	cat > "$binding_repo/Makefile" <<EOF
override RELEASE_IMAGES := $binding_canonical
override RELEASE_IDENTITY_IMAGES := $binding_canonical
override RELEASE_HELPER_MAP := $binding_helper=scripts/$binding_helper
override RELEASE_PROVENANCE_FILES := $FIXTURE_PROVENANCE
.PHONY: print-RELEASE_IMAGES print-RELEASE_IDENTITY_IMAGES print-RELEASE_HELPER_MAP
.PHONY: print-RELEASE_PROVENANCE_FILES
print-RELEASE_IMAGES:
	@printf '%s\\n' "\$(RELEASE_IMAGES)"
print-RELEASE_IDENTITY_IMAGES:
	@printf '%s\\n' "\$(RELEASE_IDENTITY_IMAGES)"
print-RELEASE_HELPER_MAP:
	@printf '%s\\n' "\$(RELEASE_HELPER_MAP)"
print-RELEASE_PROVENANCE_FILES:
	@printf '%s\\n' "\$(RELEASE_PROVENANCE_FILES)"
EOF
	printf '#!/usr/bin/env python3\nprint("binding fixture helper")\n' \
		> "$binding_repo/scripts/$binding_helper"
	cp -p "$binding_repo/scripts/$binding_helper" "$binding_release/$binding_helper"
	printf 'unrelated release bytes\n' > "$binding_release/a.hex"
	printf 'selected release bytes\n' > "$binding_release/$binding_image"
	printf 'mute release bytes\n' \
		> "$binding_release/bypass-pic12f675-cd4053_with_mute.hex"
	printf 'relay release bytes\n' \
		> "$binding_release/bypass-pic12f675-tq2_l2_5v_relay.hex"
	printf 'format=4\n' > "$binding_release/QUALIFICATION"
	printf '# Firmware release binding fixture\n' > "$binding_release/MANIFEST.md"
	printf '# binding fixture\n' > "$binding_release/README.md"
	(
		cd "$binding_release"
		sha256sum $binding_canonical "$binding_helper" $FIXTURE_PROVENANCE \
			> SHA256SUMS
	)
	printf 'fixture detached signature\n' > "$binding_release/SHA256SUMS.asc"
	case "$mutation" in
		none) ;;
		missing-checksum)
			while IFS= read -r line; do
				case "$line" in *"  $binding_image") ;; *) printf '%s\n' "$line" ;; esac
			done < "$binding_release/SHA256SUMS" \
				> "$binding_release/SHA256SUMS.new"
			mv "$binding_release/SHA256SUMS.new" "$binding_release/SHA256SUMS"
			;;
		wrong-checksum)
			while IFS= read -r line; do
				case "$line" in
					*"  $binding_image") printf '%064d  %s\n' 0 "$binding_image" ;;
					*) printf '%s\n' "$line" ;;
				esac
			done < "$binding_release/SHA256SUMS" \
				> "$binding_release/SHA256SUMS.new"
			mv "$binding_release/SHA256SUMS.new" "$binding_release/SHA256SUMS"
			;;
		duplicate-checksum)
			while IFS= read -r line; do
				case "$line" in *"  $binding_image") printf '%s\n' "$line"; break ;; esac
			done < "$binding_release/SHA256SUMS" >> "$binding_release/SHA256SUMS"
			;;
		missing-image) rm "$binding_release/a.hex" ;;
		extra-image) printf 'extra\n' > "$binding_release/extra.hex" ;;
		missing-helper) rm "$binding_release/$binding_helper" ;;
		drifted-helper)
			printf '# staged but not the tracked source\n' \
				>> "$binding_release/$binding_helper"
			(
				cd "$binding_release"
				sha256sum $binding_canonical "$binding_helper" \
					$FIXTURE_PROVENANCE > SHA256SUMS
			)
			;;
		*) fail "unknown release-program binding fixture mutation: $mutation" ;;
	esac
	git -C "$binding_repo" init -q
	git -C "$binding_repo" config user.name 'Release Image Test'
	git -C "$binding_repo" config user.email 'release-image@example.invalid'
	git -C "$binding_repo" add .
	git -C "$binding_repo" -c commit.gpgsign=false commit -qm fixture
	git -C "$binding_repo" tag -a -m fixture "$binding_tag"
	printf 'selected release bytes\n' > "$work/release-program-candidate.hex"
}

run_binding_verify() {
	TMPDIR="$binding_temp" \
		"$binding_repo/scripts/verify-release-program-image.sh" "$@"
}

expect_binding_fail() {
	local label=$1 expected=$2 output
	shift 2
	if output=$(run_binding_verify "$@" 2>&1); then
		fail "$label: invalid release-program binding was accepted"
	fi
	[[ "$output" == *"$expected"* ]] \
		|| fail "$label: failed for the wrong reason: $output"
	checks=$((checks + 1))
}

setup_binding_fixture
binding_source_output=$(run_binding_verify source "$binding_tag") \
	|| fail "valid release source binding was rejected"
[ "$binding_source_output" = \
		"PIC12F675_RELEASE_SOURCE_CHECK PASS tag=$binding_tag" ] \
	|| fail "release source binding emitted the wrong success record: $binding_source_output"
binding_output=$(run_binding_verify image "$binding_tag" "$binding_variant" \
	"$work/release-program-candidate.hex") \
	|| fail "valid signed release image binding was rejected"
binding_digest=$(sha256sum "$work/release-program-candidate.hex")
binding_digest=${binding_digest%% *}
[ "$binding_output" = \
		"PIC12F675_RELEASE_IMAGE_CHECK PASS tag=$binding_tag variant=$binding_variant image=$work/release-program-candidate.hex sha256=$binding_digest" ] \
	|| fail "release image binding emitted the wrong success record: $binding_output"
checks=$((checks + 1))

printf 'byte-different but regular candidate\n' > "$work/release-program-candidate.hex"
expect_binding_fail "byte-different candidate" \
	"candidate image does not match the signed release image set" \
	image "$binding_tag" "$binding_variant" "$work/release-program-candidate.hex"

setup_binding_fixture
expect_binding_fail "wrong selected variant" \
	"candidate image does not match the signed release image set" \
	image "$binding_tag" cd4053_with_mute "$work/release-program-candidate.hex"

for spec in \
	"missing-checksum|SHA256SUMS entries do not exactly match" \
	"wrong-checksum|committed release checksum verification failed" \
	"duplicate-checksum|duplicate SHA256SUMS entry" \
	"missing-image|committed release image set" \
	"extra-image|committed release image set" \
	"missing-helper|committed release is missing required artifact" \
	"drifted-helper|differs from its tracked source"; do
	mutation=${spec%%|*}
	expected_failure=${spec#*|}
	setup_binding_fixture "$mutation"
	expect_binding_fail "$mutation" "$expected_failure" \
		image "$binding_tag" "$binding_variant" "$work/release-program-candidate.hex"
done

setup_binding_fixture
if output=$(BINDING_SIGNATURE_MODE=fail-detached run_binding_verify image "$binding_tag" \
		"$binding_variant" "$work/release-program-candidate.hex" 2>&1); then
	fail "failed detached signature reached release-image acceptance"
fi
[[ "$output" == *"release checksum signature verification failed"* ]] \
	|| fail "failed signature was rejected for the wrong reason: $output"
checks=$((checks + 1))

expect_binding_fail "missing release tag" "release tag does not exist" \
	source v1.0.1

setup_binding_fixture
git -C "$binding_repo" tag v1.0.1 HEAD
expect_binding_fail "lightweight release tag" "release tag is not an annotated tag" \
	source v1.0.1

setup_binding_fixture
tag_object=$(git -C "$binding_repo" rev-parse "refs/tags/$binding_tag^{object}")
git -C "$binding_repo" update-ref refs/tags/v1.0.1 "$tag_object"
expect_binding_fail "aliased annotated tag object" \
	"annotated release tag name does not match requested tag" source v1.0.1

setup_binding_fixture
printf '\n# tracked mutation\n' >> "$binding_repo/Makefile"
expect_binding_fail "dirty tagged source" "release-programming worktree is not clean" \
	source "$binding_tag"

printf 'release image verification: %d checks, 0 failures\n' "$checks"
