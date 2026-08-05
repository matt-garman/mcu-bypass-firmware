#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RELEASE="$ROOT/scripts/make-release.sh"
RELEASE_WORKFLOW="$ROOT/.github/workflows/release.yml"
RENAME_VERIFY="$ROOT/scripts/verify-rename-identity.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/test-release-provenance.XXXXXX")
repo="$work/repo with spaces"
log="$work/check.log"
checks=0
worker_pids=()

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

cleanup() {
	local pid
	for pid in "${worker_pids[@]}"; do kill -KILL -- "-$pid" 2>/dev/null || true; done
	for pid in "${worker_pids[@]}"; do wait "$pid" 2>/dev/null || true; done
	rm -rf "$work"
}
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
declare -F release_terminate_workers >/dev/null \
	|| fail "release worker-cleanup helper was not defined"
declare -F release_jobs_cap >/dev/null \
	|| fail "release jobs-cap helper was not defined"

expect_output_path_pass() {
	local label=$1 output_dir=$2 mode=$3
	if ! (cd "$ROOT" && release_output_path_is_safe "$ROOT" "$output_dir" "$mode" v99.0.0) \
			>"$log" 2>&1; then
		fail "$label unexpectedly failed: $(<"$log")"
	fi
	checks=$((checks + 1))
}

expect_output_path_fail() {
	local label=$1 output_dir=$2 mode=$3 needle=$4
	if (cd "$ROOT" && release_output_path_is_safe "$ROOT" "$output_dir" "$mode" v99.0.0) \
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
expect_output_path_pass "relative production release tree" release/v99.0.0 production
expect_output_path_pass "normalized production release tree" \
	"release/../release/v99.0.0" production
expect_output_path_fail "production release root" "$ROOT/release" production \
	"production output must be exactly"
expect_output_path_fail "wrong production version" "$ROOT/release/v99.0.1" production \
	"production output must be exactly"
expect_output_path_fail "external production tree" "$work/production/v99.0.0" production \
	"production output must be exactly"
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

# Interrupted release cleanup must terminate and reap every active worker. One
# fixture exits on TERM; the other ignores TERM and requires the KILL fallback.
cat > "$tools/term-worker" <<'EOF'
#!/usr/bin/env bash
trap 'printf "TERM\n" > "$WORKER_TERM_MARKER"; exit 0' TERM
bash -c 'trap "" TERM; printf "%s\n" "$BASHPID" > "$WORKER_CHILD_PID"; while :; do sleep 1; done' &
child=$!
while [ ! -s "$WORKER_CHILD_PID" ]; do sleep 0.01; done
: > "$WORKER_READY"
wait "$child"
EOF
cat > "$tools/ignore-worker" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
bash -c 'trap "" TERM; printf "%s\n" "$BASHPID" > "$WORKER_CHILD_PID"; while :; do sleep 1; done' &
child=$!
while [ ! -s "$WORKER_CHILD_PID" ]; do sleep 0.01; done
: > "$WORKER_READY"
wait "$child"
EOF
chmod 750 "$tools/term-worker" "$tools/ignore-worker"
term_ready="$work/term.ready"
ignore_ready="$work/ignore.ready"
term_marker="$work/term.marker"
term_child_file="$work/term.child"
ignore_child_file="$work/ignore.child"
WORKER_READY="$term_ready" WORKER_TERM_MARKER="$term_marker" \
	WORKER_CHILD_PID="$term_child_file" setsid "$tools/term-worker" &
term_pid=$!
worker_pids+=("$term_pid")
WORKER_READY="$ignore_ready" WORKER_CHILD_PID="$ignore_child_file" \
	setsid "$tools/ignore-worker" &
ignore_pid=$!
worker_pids+=("$ignore_pid")
for _ in {1..100}; do
	[ -f "$term_ready" ] && [ -f "$ignore_ready" ] && break
	sleep 0.01
done
[ -f "$term_ready" ] && [ -f "$ignore_ready" ] \
	|| fail "release worker fixtures did not start"
term_child=$(<"$term_child_file")
ignore_child=$(<"$ignore_child_file")
release_terminate_workers "$term_pid" "$ignore_pid" \
	|| fail "release worker cleanup failed"
worker_pids=()
[ "$(<"$term_marker")" = TERM ] \
	|| fail "cooperative release worker did not receive TERM"
! kill -0 "$term_pid" 2>/dev/null \
	|| fail "cooperative release worker survived cleanup"
! kill -0 "$ignore_pid" 2>/dev/null \
	|| fail "TERM-ignoring release worker survived KILL fallback"
# The leaders above are this shell's own children, so the helper's `wait` has
# already reaped them and a single `kill -0` is exact. Their descendants are
# not: they are grandchildren, `wait` cannot reap them, and SIGKILL to a
# process group only marks its members for death -- each still has to be
# scheduled and reaped by the reaper that adopts it before its PID goes away.
# Sampling `kill -0` once therefore fails a *correct* cleanup whenever the
# machine is loaded enough to widen that window. Poll for the exit that group
# cleanup does guarantee, bounded so a descendant that genuinely survives is
# still caught.
await_descendant_exit() {
	local pid=$1 attempt
	for ((attempt = 0; attempt < 500; attempt++)); do
		kill -0 "$pid" 2>/dev/null || return 0
		sleep 0.01
	done
	return 1
}
await_descendant_exit "$term_child" \
	|| fail "cooperative worker descendant survived group cleanup"
await_descendant_exit "$ignore_child" \
	|| fail "TERM-ignoring worker descendant survived group cleanup"
checks=$((checks + 1))

if release_terminate_workers not-a-pid >"$log" 2>&1; then
	fail "worker cleanup accepted a malformed PID"
fi
grep -Fq "invalid release worker PID" "$log" \
	|| fail "malformed worker PID failed for the wrong reason: $(<"$log")"
checks=$((checks + 1))

[ "$(release_jobs_cap '' 15)" = 15 ] \
	|| fail "default release jobs did not select all combinations"
[ "$(release_jobs_cap 1 15)" = 1 ] \
	|| fail "release jobs lowered a valid concurrency limit"
[ "$(release_jobs_cap 15 15)" = 15 ] \
	|| fail "release jobs changed an exact concurrency limit"
[ "$(release_jobs_cap 16 15)" = 15 ] \
	|| fail "release jobs did not cap a larger concurrency limit"
[ "$(release_jobs_cap 999999999999999999999999999999999999 15)" = 15 ] \
	|| fail "release jobs did not safely cap an oversized decimal"
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
pic10f320_cc=$(make -s -C "$ROOT" "PIC_CC=$shared_cc" print-PIC10F320_CC)
[ "$pic_cc" = "$shared_cc" ] && [ "$pic10f320_cc" = "$shared_cc" ] \
	|| fail "PIC10F320_CC did not inherit an overridden PIC_CC"
checks=$((checks + 1))

separate_cc="$work/separate-xc8"
pic_cc=$(make -s -C "$ROOT" "PIC_CC=$shared_cc" "PIC10F320_CC=$separate_cc" print-PIC_CC)
pic10f320_cc=$(make -s -C "$ROOT" "PIC_CC=$shared_cc" "PIC10F320_CC=$separate_cc" print-PIC10F320_CC)
[ "$pic_cc" = "$shared_cc" ] && [ "$pic10f320_cc" = "$separate_cc" ] \
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

# Rename identity has two distinct jobs: reject a changed initial build before
# the expensive gates, then replace that provisional report with one computed
# from the final validated images. Pin both calls around the rebuild window and
# before source/output provenance and staging.
mapfile -t initial_identity_lines < <(grep -nF 'verify_rename_identity "initial build"' "$RELEASE")
mapfile -t final_identity_lines < <(grep -nF 'verify_rename_identity "final validated images"' "$RELEASE")
mapfile -t validation_lines < <(grep -nF 'section "2. validation:' "$RELEASE")
mapfile -t final_image_lines < <(grep -nF 'ok "all validated release images are present and nonempty."' "$RELEASE")
[ "${#initial_identity_lines[@]}" -eq 1 ] \
	&& [ "${#final_identity_lines[@]}" -eq 1 ] \
	&& [ "${#validation_lines[@]}" -eq 1 ] \
	&& [ "${#final_image_lines[@]}" -eq 1 ] \
	|| fail "release rename-identity/final-image markers are missing or ambiguous"
initial_identity_line=${initial_identity_lines[0]%%:*}
final_identity_line=${final_identity_lines[0]%%:*}
validation_line=${validation_lines[0]%%:*}
final_image_line=${final_image_lines[0]%%:*}
[ "$initial_identity_line" -lt "$validation_line" ] \
	&& [ "$final_image_line" -lt "$final_identity_line" ] \
	&& [ "$final_identity_line" -lt "$check_line" ] \
	&& [ "$final_identity_line" -lt "$stage_line" ] \
	|| fail "rename identity is not checked both before validation and over the final pre-stage images"
checks=$((checks + 1))

# Exercise the temporal defect directly. The first comparison passes over a
# complete byte-identical v0.9.8 fixture; changing one image afterward must make
# the comparison that represents the final release fail by hash, not merely by
# a missing path or malformed fixture.
rename_images="$work/rename-images"
mkdir -p "$rename_images"
rename_pairs=(
	"bypass_cd4053.hex|bypass-attiny13a-cd4053_simple.hex"
	"bypass_mute.hex|bypass-attiny13a-cd4053_with_mute.hex"
	"bypass_relay.hex|bypass-attiny13a-tq2_l2_5v_relay.hex"
	"bypass_cd4053_t85.hex|bypass-attiny85-cd4053_simple.hex"
	"bypass_mute_t85.hex|bypass-attiny85-cd4053_with_mute.hex"
	"bypass_relay_t85.hex|bypass-attiny85-tq2_l2_5v_relay.hex"
	"bypass_cd4053_t45.hex|bypass-attiny45-cd4053_simple.hex"
	"bypass_mute_t45.hex|bypass-attiny45-cd4053_with_mute.hex"
	"bypass_relay_t45.hex|bypass-attiny45-tq2_l2_5v_relay.hex"
	"bypass_cd4053_attiny202.hex|bypass-attiny202-cd4053_simple.hex"
	"bypass_mute_attiny202.hex|bypass-attiny202-cd4053_with_mute.hex"
	"bypass_relay_attiny202.hex|bypass-attiny202-tq2_l2_5v_relay.hex"
	"bypass_cd4053_pic10f322.hex|bypass-pic10f322-cd4053_simple.hex"
	"bypass_mute_pic10f322.hex|bypass-pic10f322-cd4053_with_mute.hex"
	"bypass_relay_pic10f322.hex|bypass-pic10f322-tq2_l2_5v_relay.hex"
	"bypass_mcu_cd4053-simple_pic10f320.hex|bypass-pic10f320-cd4053_simple.hex"
	"bypass_mcu_cd4053-mute_pic10f320.hex|bypass-pic10f320-cd4053_with_mute.hex"
	"bypass_mcu_tq2-relay_pic10f320.hex|bypass-pic10f320-tq2_l2_5v_relay.hex"
)
rename_paths=()
for pair in "${rename_pairs[@]}"; do
	old=${pair%%|*}
	new=${pair#*|}
	cp "$ROOT/release/v0.9.7/$old" "$rename_images/$new"
	rename_paths+=("$rename_images/$new")
done
"$RENAME_VERIFY" v0.9.8 "${rename_paths[@]}" >"$work/rename-early.out" \
	2>"$work/rename-early.err" \
	|| fail "byte-identical rename fixture failed its initial comparison: $(<"$work/rename-early.err")"
grep -Fq 'identical=18 differ=0 missing=0 added=0' "$work/rename-early.out" \
	|| fail "initial rename fixture did not compare the complete 18-image set"
checks=$((checks + 1))
printf '\npost-validation mutation\n' >> "$rename_images/bypass-attiny13a-cd4053_simple.hex"
if "$RENAME_VERIFY" v0.9.8 "${rename_paths[@]}" >"$work/rename-final.out" \
		2>"$work/rename-final.err"; then
	fail "final rename comparison accepted an image changed after the initial check"
fi
grep -Fq '**DIFFERS**' "$work/rename-final.out" \
	&& grep -Fq 'rename identity FAILED: 1 image(s) differ' "$work/rename-final.err" \
	|| fail "final rename comparison rejected the mutation for the wrong reason"
checks=$((checks + 1))

# The release orchestrator must identify each selected compiler before building
# and attribute each result to the corresponding image family in the manifest.
mapfile -t xc8_322_lines < <(grep -nF \
	'TC_XC8_322=$(release_tool_version_line "PIC10F322 XC8 (PIC_CC=$PIC_CC)" "$PIC_CC")' \
	"$RELEASE")
mapfile -t xc8_320_lines < <(grep -nF \
	'TC_XC8_320=$(release_tool_version_line "PIC10F320 XC8 (PIC10F320_CC=$PIC10F320_CC)" "$PIC10F320_CC")' \
	"$RELEASE")
mapfile -t clean_lines < <(grep -nF 'make clean >/dev/null' "$RELEASE")
mapfile -t manifest_322_lines < <(grep -nF 'PIC10F322 XC8 (`PIC_CC=%s`)' "$RELEASE")
mapfile -t manifest_320_lines < <(grep -nF 'PIC10F320 XC8 (`PIC10F320_CC=%s`)' "$RELEASE")
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
grep -Fq '"$PIC10F320_CC" "$TC_XC8_320"' "$RELEASE" \
	|| fail "PIC10F320 manifest row does not use its selected compiler and version"
if grep -Fq "printf -- '| XC8 |" "$RELEASE"; then
	fail "release manifest still contains an ambiguous generic XC8 row"
fi
checks=$((checks + 1))

version_assignments=$(grep -Ec '^TC_[A-Z0-9_]+=\$\(release_tool_version_line ' "$RELEASE")
[ "$version_assignments" -eq 10 ] \
	|| fail "release has $version_assignments fail-closed executable version probes, expected 10"
! grep -Fq 'v1()' "$RELEASE" \
	|| fail "release still contains the fail-open v1 tool-version helper"
checks=$((checks + 1))

# The producer guard must run after the output path is selected and again between
# the final source check and staging. The second check closes the long window in
# which an external output-path component could be replaced with a symlink.
mapfile -t output_guard_lines < <(grep -nF \
	'release_output_path_is_safe "$REPO_ROOT" "$OUTPUT_DIR" "$RELEASE_MODE" "$VERSION"' "$RELEASE")
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

grep -Fq 'release_terminate_workers "${SOAK_PIDS[@]}"' "$RELEASE" \
	|| fail "release EXIT cleanup does not terminate tracked soak workers"
grep -Fq "trap '' HUP INT TERM" "$RELEASE" \
	|| fail "release cleanup remains interruptible by a repeated signal"
for signal_status in "trap 'on_signal 129' HUP" "trap 'on_signal 130' INT" "trap 'on_signal 143' TERM"; do
	grep -Fq "$signal_status" "$RELEASE" \
		|| fail "release is missing signal cleanup route: $signal_status"
done
grep -Fq 'exec setsid "${SOAK_BIN[$name]}"' "$RELEASE" \
	|| fail "release soak workers are not isolated into process groups"
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
