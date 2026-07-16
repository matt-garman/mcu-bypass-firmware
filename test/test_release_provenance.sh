#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RELEASE="$ROOT/scripts/make-release.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/test-release-provenance.XXXXXX")
repo="$work/repo with spaces"
log="$work/check.log"
checks=0

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

cleanup() { rm -rf "$work"; }
trap cleanup EXIT HUP INT TERM

command -v git >/dev/null 2>&1 || fail "git is required"

# shellcheck source=../scripts/release-provenance.sh
source "$ROOT/scripts/release-provenance.sh"
declare -F release_source_is_unchanged >/dev/null \
	|| fail "release provenance helper was not defined"

mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.name "Release Provenance Test"
git -C "$repo" config user.email "release-provenance@example.invalid"
printf 'baseline\n' > "$repo/tracked.txt"
printf 'build/\n' > "$repo/.gitignore"
git -C "$repo" add .gitignore tracked.txt
git -C "$repo" -c commit.gpgsign=false commit -qm initial
base_sha=$(git -C "$repo" rev-parse HEAD)

expect_pass() {
	local label=$1 expected_sha=$2 allow_dirty=$3
	if ! (cd "$repo" && release_source_is_unchanged "$expected_sha" "$allow_dirty") \
			>"$log" 2>&1; then
		fail "$label unexpectedly failed: $(<"$log")"
	fi
	checks=$((checks + 1))
}

expect_fail() {
	local label=$1 expected_sha=$2 allow_dirty=$3 needle=$4
	if (cd "$repo" && release_source_is_unchanged "$expected_sha" "$allow_dirty") \
			>"$log" 2>&1; then
		fail "$label unexpectedly passed"
	fi
	grep -Fq "$needle" "$log" \
		|| fail "$label failed without '$needle': $(<"$log")"
	checks=$((checks + 1))
}

expect_pass "matching clean source" "$base_sha" 0
expect_fail "invalid dirty policy" "$base_sha" 2 \
	"invalid release provenance dirty policy"

mkdir -p "$repo/build"
: > "$repo/build/generated.hex"
expect_pass "ignored build output" "$base_sha" 0

printf 'edited\n' >> "$repo/tracked.txt"
expect_fail "tracked source drift" "$base_sha" 0 \
	"working tree is dirty at final provenance check"
expect_pass "dirty rehearsal compatibility" "$base_sha" 1
git -C "$repo" restore --source="$base_sha" --worktree tracked.txt

: > "$repo/untracked.txt"
expect_fail "untracked source drift" "$base_sha" 0 \
	"working tree is dirty at final provenance check"
rm "$repo/untracked.txt"

printf 'new commit\n' >> "$repo/tracked.txt"
git -C "$repo" add tracked.txt
git -C "$repo" -c commit.gpgsign=false commit -qm second
current_sha=$(git -C "$repo" rev-parse HEAD)
expect_fail "HEAD drift" "$base_sha" 0 "source HEAD changed during release"
expect_pass "matching updated HEAD" "$current_sha" 0

# Keep orchestration fail-closed: capture HEAD before the one final check, and
# complete that check before creating the staging directory.
mapfile -t capture_lines < <(grep -nF 'GIT_SHA=$(git rev-parse HEAD)' "$RELEASE")
mapfile -t check_lines < <(grep -nF 'release_source_is_unchanged "$GIT_SHA" "$DRY_RUN"' "$RELEASE")
mapfile -t stage_lines < <(grep -nF 'mkdir -p "$OUTPUT_DIR/evidence"' "$RELEASE")
[ "${#capture_lines[@]}" -eq 1 ] \
	&& [ "${#check_lines[@]}" -eq 1 ] \
	&& [ "${#stage_lines[@]}" -eq 1 ] \
	|| fail "release provenance capture/check/stage markers are missing or ambiguous"
capture_line=${capture_lines[0]%%:*}
check_line=${check_lines[0]%%:*}
stage_line=${stage_lines[0]%%:*}
[ "$capture_line" -lt "$check_line" ] && [ "$check_line" -lt "$stage_line" ] \
	|| fail "release provenance is not rechecked between capture and staging"
checks=$((checks + 1))

printf 'release provenance validation: %d checks, 0 failures\n' "$checks"
