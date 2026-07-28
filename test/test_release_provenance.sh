#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RELEASE="$ROOT/scripts/make-release.sh"
RELEASE_WORKFLOW="$ROOT/.github/workflows/release.yml"
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
declare -F release_tool_version_line >/dev/null \
	|| fail "release tool-version helper was not defined"
declare -F release_output_path_is_safe >/dev/null \
	|| fail "release output-path helper was not defined"

expect_output_path_pass() {
	local label=$1 output_dir=$2 mode=$3
	if ! (cd "$ROOT" && release_output_path_is_safe "$ROOT" "$output_dir" "$mode") \
			>"$log" 2>&1; then
		fail "$label unexpectedly failed: $(<"$log")"
	fi
	checks=$((checks + 1))
}

expect_output_path_fail() {
	local label=$1 output_dir=$2 mode=$3 needle=$4
	if (cd "$ROOT" && release_output_path_is_safe "$ROOT" "$output_dir" "$mode") \
			>"$log" 2>&1; then
		fail "$label unexpectedly passed"
	fi
	grep -Fq "$needle" "$log" \
		|| fail "$label failed without '$needle': $(<"$log")"
	checks=$((checks + 1))
}

# A production release belongs under release/<version>; a rehearsal never does.
# Canonicalization matters because --output-dir accepts arbitrary paths, including
# `..` components and aliases through an existing symlink.
expect_output_path_pass "production release tree" "$ROOT/release/v99.0.0" production
expect_output_path_pass "external dry-run tree" "$work/dry-run/v99.0.0" dry-run
expect_output_path_fail "dry-run release root" "$ROOT/release" dry-run \
	"dry-run output must not be staged under the repository release tree"
expect_output_path_fail "dry-run release child" "$ROOT/release/v99.0.0" dry-run \
	"dry-run output must not be staged under the repository release tree"
expect_output_path_fail "normalized dry-run release child" \
	"release/../release/v99.0.0" dry-run \
	"dry-run output must not be staged under the repository release tree"
ln -s "$ROOT/release" "$work/release-link"
expect_output_path_fail "symlinked dry-run release child" \
	"$work/release-link/v99.0.0" dry-run \
	"dry-run output must not be staged under the repository release tree"
expect_output_path_fail "invalid release mode" "$work/output" invalid \
	"invalid release output mode"

tools="$work/tools"
mkdir -p "$tools"
cat > "$tools/xc8-322" <<'EOF'
#!/usr/bin/env bash
[ "$#" -eq 1 ] && [ "$1" = --version ] || exit 9
printf 'XC8 322 VERSION\nsecond line\n'
EOF
cat > "$tools/xc8-320" <<'EOF'
#!/usr/bin/env bash
[ "$#" -eq 1 ] && [ "$1" = --version ] || exit 9
printf 'XC8 320 VERSION\nsecond line\n'
EOF
cat > "$tools/xc8-fail" <<'EOF'
#!/usr/bin/env bash
printf 'broken version probe\n' >&2
exit 7
EOF
cat > "$tools/xc8-empty" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 750 "$tools"/*

version=$(release_tool_version_line "PIC10F322 XC8" "$tools/xc8-322") \
	|| fail "PIC10F322 compiler version probe failed"
[ "$version" = "XC8 322 VERSION" ] \
	|| fail "PIC10F322 compiler version probe returned: $version"
checks=$((checks + 1))

version=$(release_tool_version_line "PIC10F320 XC8" "$tools/xc8-320") \
	|| fail "PIC10F320 compiler version probe failed"
[ "$version" = "XC8 320 VERSION" ] \
	|| fail "PIC10F320 compiler version probe returned: $version"
checks=$((checks + 1))

if output=$(release_tool_version_line "PIC10F320 XC8" "$tools/xc8-fail" 2>&1); then
	fail "failed compiler version command was accepted"
fi
[[ "$output" == *"PIC10F320 XC8"* && "$output" == *"exited 7"* ]] \
	|| fail "failed compiler probe produced the wrong diagnostic: $output"
checks=$((checks + 1))

if output=$(release_tool_version_line "PIC10F320 XC8" "$tools/xc8-empty" 2>&1); then
	fail "empty compiler version was accepted"
fi
[[ "$output" == *"PIC10F320 XC8"* && "$output" == *"returned no version line"* ]] \
	|| fail "empty compiler probe produced the wrong diagnostic: $output"
checks=$((checks + 1))

shared_cc="$work/shared-xc8"
pic_cc=$(make -s -C "$ROOT" "PIC_CC=$shared_cc" print-PIC_CC)
pic320_cc=$(make -s -C "$ROOT" "PIC_CC=$shared_cc" print-PIC320_CC)
[ "$pic_cc" = "$shared_cc" ] && [ "$pic320_cc" = "$shared_cc" ] \
	|| fail "PIC320_CC did not inherit an overridden PIC_CC"
checks=$((checks + 1))

separate_cc="$work/separate-xc8"
pic_cc=$(make -s -C "$ROOT" "PIC_CC=$shared_cc" "PIC320_CC=$separate_cc" print-PIC_CC)
pic320_cc=$(make -s -C "$ROOT" "PIC_CC=$shared_cc" "PIC320_CC=$separate_cc" print-PIC320_CC)
[ "$pic_cc" = "$shared_cc" ] && [ "$pic320_cc" = "$separate_cc" ] \
	|| fail "Makefile did not preserve independent PIC compiler selections"
checks=$((checks + 1))

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

# The release orchestrator must identify each selected compiler before building
# and attribute each result to the corresponding image family in the manifest.
mapfile -t xc8_322_lines < <(grep -nF \
	'TC_XC8_322=$(release_tool_version_line "PIC10F322 XC8 (PIC_CC=$PIC_CC)" "$PIC_CC")' \
	"$RELEASE")
mapfile -t xc8_320_lines < <(grep -nF \
	'TC_XC8_320=$(release_tool_version_line "PIC10F320 XC8 (PIC320_CC=$PIC320_CC)" "$PIC320_CC")' \
	"$RELEASE")
mapfile -t clean_lines < <(grep -nF 'make clean >/dev/null' "$RELEASE")
mapfile -t manifest_322_lines < <(grep -nF 'PIC10F322 XC8 (`PIC_CC=%s`)' "$RELEASE")
mapfile -t manifest_320_lines < <(grep -nF 'PIC10F320 XC8 (`PIC320_CC=%s`)' "$RELEASE")
[ "${#xc8_322_lines[@]}" -eq 1 ] \
	&& [ "${#xc8_320_lines[@]}" -eq 1 ] \
	&& [ "${#clean_lines[@]}" -eq 1 ] \
	&& [ "${#manifest_322_lines[@]}" -eq 1 ] \
	&& [ "${#manifest_320_lines[@]}" -eq 1 ] \
	|| fail "release compiler provenance wiring is missing or ambiguous"
xc8_322_line=${xc8_322_lines[0]%%:*}
xc8_320_line=${xc8_320_lines[0]%%:*}
clean_line=${clean_lines[0]%%:*}
[ "$xc8_322_line" -lt "$clean_line" ] && [ "$xc8_320_line" -lt "$clean_line" ] \
	|| fail "release compiler identity is not captured before the clean build"
grep -Fq '"$PIC_CC" "$TC_XC8_322"' "$RELEASE" \
	|| fail "PIC10F322 manifest row does not use its selected compiler and version"
grep -Fq '"$PIC320_CC" "$TC_XC8_320"' "$RELEASE" \
	|| fail "PIC10F320 manifest row does not use its selected compiler and version"
if grep -Fq "printf -- '| XC8 |" "$RELEASE"; then
	fail "release manifest still contains an ambiguous generic XC8 row"
fi
checks=$((checks + 1))

# The producer guard must run after the output path is selected and again between
# the final source check and staging. The second check closes the long window in
# which an external output-path component could be replaced with a symlink.
mapfile -t output_guard_lines < <(grep -nF \
	'release_output_path_is_safe "$REPO_ROOT" "$OUTPUT_DIR" "$RELEASE_MODE"' "$RELEASE")
mapfile -t precondition_lines < <(grep -nF 'section "0. preconditions"' "$RELEASE")
mapfile -t source_check_lines < <(grep -nF \
	'release_source_is_unchanged "$GIT_SHA" "$DRY_RUN"' "$RELEASE")
mapfile -t release_stage_lines < <(grep -nF 'section "4. stage $OUTPUT_DIR"' "$RELEASE")
[ "${#output_guard_lines[@]}" -eq 2 ] \
	&& [ "${#precondition_lines[@]}" -eq 1 ] \
	&& [ "${#source_check_lines[@]}" -eq 1 ] \
	&& [ "${#release_stage_lines[@]}" -eq 1 ] \
	|| fail "release output guard/precondition wiring is missing or ambiguous"
first_output_guard_line=${output_guard_lines[0]%%:*}
final_output_guard_line=${output_guard_lines[1]%%:*}
precondition_line=${precondition_lines[0]%%:*}
source_check_line=${source_check_lines[0]%%:*}
release_stage_line=${release_stage_lines[0]%%:*}
[ "$first_output_guard_line" -lt "$precondition_line" ] \
	&& [ "$source_check_line" -lt "$final_output_guard_line" ] \
	&& [ "$final_output_guard_line" -lt "$release_stage_line" ] \
	|| fail "release output guards do not bracket validation and staging"
grep -Fq "printf -- '- **Release mode:** %s\\n' \"\$RELEASE_MODE\"" "$RELEASE" \
	|| fail "release manifest does not record its release mode"
checks=$((checks + 1))

# The generated manifest carries the mode tag CI requires, and the workflow also
# rejects the human-readable dry-run banner. Context values enter shell through
# the environment, never by interpolation into executable shell source: release
# tags permit punctuation that is meaningful to a shell.
grep -Fq "grep -Fq 'DRY RUN -- NOT A VALIDATED RELEASE'" "$RELEASE_WORKFLOW" \
	|| fail "tag workflow does not reject the dry-run manifest banner"
grep -Fq "grep -Fxq -- '- **Release mode:** production'" "$RELEASE_WORKFLOW" \
	|| fail "tag workflow does not require an explicit production release mode"
checks=$((checks + 1))

for assignment in \
	'RELEASE_TAG: ${{ github.ref_name }}' \
	'RELEASE_DIR: ${{ steps.rel.outputs.dir }}' \
	'RELEASE_DIR: ${{ steps.repro.outputs.dir }}'; do
	grep -Fq "$assignment" "$RELEASE_WORKFLOW" \
		|| fail "tag workflow is missing safe context routing: $assignment"
done
if grep -Eq "^[[:space:]]+(tag|dir)='?\\\$\\{\\{" "$RELEASE_WORKFLOW"; then
	fail "tag workflow interpolates a context value directly into shell source"
fi
checks=$((checks + 1))

printf 'release provenance validation: %d checks, 0 failures\n' "$checks"
