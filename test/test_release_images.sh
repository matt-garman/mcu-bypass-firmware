#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VERIFY="$ROOT/scripts/verify-release-images.sh"
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
.PHONY: print-RELEASE_IMAGES
print-RELEASE_IMAGES:
	@printf '%s\n' "$(RELEASE_IMAGES)"
EOF

set_fixture_expected_images() {
	printf '%s\n' "$1" > "$fixture_root/expected-images.txt"
}

reset_fixture() {
	rm -rf "$release" "$fresh" "$fresh2" "$release_alias" "$fresh_alias" \
		"$fakebin"
	mkdir -p "$release" "$fresh"
	printf ':0100000001FE\n:00000001FF\n' > "$release/a.hex"
	printf ':0100000002FD\n:00000001FF\n' > "$release/b.hex"
	cp "$release/a.hex" "$release/b.hex" "$fresh"/
	(cd "$release" && sha256sum a.hex b.hex > SHA256SUMS)
	# Synthetic tests use the production verifier unchanged beside a test-only
	# Makefile. Production therefore retains exactly one canonical-set input.
	set_fixture_expected_images 'a.hex b.hex'
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
expect_fail "committed byte mismatch" "committed image checksum verification failed"

reset_fixture
printf ':00000001FE\n' >> "$fresh/a.hex"
expect_fail "fresh byte mismatch" "fresh image checksum verification failed"

reset_fixture
printf '%s\n' "$(sed -n '1p' "$release/SHA256SUMS")" >> "$release/SHA256SUMS"
expect_fail "duplicate checksum entry" "duplicate SHA256SUMS image entry"

reset_fixture
printf 'not a checksum\n' >> "$release/SHA256SUMS"
expect_fail "malformed checksum entry" "malformed SHA256SUMS entry"

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
(cd "$release" && sha256sum a.hex > SHA256SUMS)
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
(cd "$release" && sha256sum a.hex > SHA256SUMS)
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
# Makefile actually declares: all six release-supported MCU parts present, in the
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
[ "${#canonical_arr[@]}" -eq 18 ] \
	|| fail "canonical release set has ${#canonical_arr[@]} images, expected 18"
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
expect_count "canonically named" 'bypass-*-*.hex'  18
[ "${#canonical_arr[@]}" -eq 18 ] \
	|| fail "canonical release set has ${#canonical_arr[@]} images, expected 18"
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

# No retired variant may return (§1).
[[ "$canonical" != *tmux4053* ]] \
	|| fail "canonical release set contains a retired tmux4053 image"
checks=$((checks + 1))

printf 'release image verification: %d checks, 0 failures\n' "$checks"
