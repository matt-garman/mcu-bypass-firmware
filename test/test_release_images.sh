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
.PHONY: print-RELEASE_IMAGES
print-RELEASE_IMAGES:
	@printf '%s\\n' "\$(RELEASE_IMAGES)"
EOF
	printf 'unrelated release bytes\n' > "$binding_release/a.hex"
	printf 'selected release bytes\n' > "$binding_release/$binding_image"
	printf 'mute release bytes\n' \
		> "$binding_release/bypass-pic12f675-cd4053_with_mute.hex"
	printf 'relay release bytes\n' \
		> "$binding_release/bypass-pic12f675-tq2_l2_5v_relay.hex"
	(
		cd "$binding_release"
		sha256sum $binding_canonical > SHA256SUMS
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
	"wrong-checksum|committed image checksum verification failed" \
	"duplicate-checksum|duplicate SHA256SUMS image entry" \
	"missing-image|committed release image set" \
	"extra-image|committed release image set"; do
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
