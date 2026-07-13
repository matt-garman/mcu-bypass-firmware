#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VERIFY="$ROOT/scripts/verify-release-images.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/test-release-images.XXXXXX")
trap 'rm -rf "$work"' EXIT
release="$work/release"
fresh="$work/fresh"
fresh2="$work/fresh2"
checks=0

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

reset_fixture() {
	rm -rf "$release" "$fresh" "$fresh2"
	mkdir -p "$release" "$fresh"
	printf ':0100000001FE\n:00000001FF\n' > "$release/a.hex"
	printf ':0100000002FD\n:00000001FF\n' > "$release/b.hex"
	cp "$release/a.hex" "$release/b.hex" "$fresh"/
	(cd "$release" && sha256sum a.hex b.hex > SHA256SUMS)
}

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
mkdir -p "$fresh2"
mv "$fresh/b.hex" "$fresh2"/
expect_pass_dirs "matching images split across directories" "$fresh" "$fresh2"

reset_fixture
mkdir -p "$fresh2"
cp "$fresh/a.hex" "$fresh2"/
expect_fail_dirs "duplicate fresh basename" "duplicate image name" "$fresh" "$fresh2"

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
