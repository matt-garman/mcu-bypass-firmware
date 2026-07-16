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
checks=0

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

reset_fixture() {
	rm -rf "$release" "$fresh" "$fresh2" "$release_alias" "$fresh_alias" \
		"$fakebin"
	mkdir -p "$release" "$fresh"
	printf ':0100000001FE\n:00000001FF\n' > "$release/a.hex"
	printf ':0100000002FD\n:00000001FF\n' > "$release/b.hex"
	cp "$release/a.hex" "$release/b.hex" "$fresh"/
	(cd "$release" && sha256sum a.hex b.hex > SHA256SUMS)
}

real_sha256sum=$(command -v sha256sum) \
	|| fail "sha256sum is required for the release-image regression"

expect_pass() {
	expect_pass_dirs "$1" "$fresh"
}

expect_pass_dirs() {
	local label=$1
	shift
	"$VERIFY" "$release" "$@" >/dev/null \
		|| fail "$label: valid release was rejected"
	checks=$((checks + 1))
}

expect_fail() {
	expect_fail_dirs "$1" "$2" "$fresh"
}

expect_fail_dirs() {
	local label=$1 expected=$2 output
	shift 2
	if output=$("$VERIFY" "$release" "$@" 2>&1); then
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
		"$VERIFY" "$release" "$fresh" 2>&1); then
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

printf 'release image verification: %d checks, 0 failures\n' "$checks"
