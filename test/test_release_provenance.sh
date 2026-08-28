#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RELEASE="$ROOT/scripts/make-release.sh"
RELEASE_WORKFLOW="$ROOT/.github/workflows/release.yml"
RELEASE_IMAGE_VERIFY="$ROOT/scripts/verify-release-images.sh"
PUBLICATION_VERIFY="$ROOT/scripts/verify_release_publication.py"
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
declare -F release_pinned_version_matches >/dev/null \
	|| fail "release version-pin helper was not defined"
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

# The three image-defining compiler pins compare an exact version TOKEN. They
# were shell substring patterns until v0.9.10, which accepted any banner
# CONTAINING the pin -- so avr-gcc 17.3.0 satisfied the 7.3.0 pin and XC8
# V3.100 satisfied the V3.10 pin, which are exactly the versions a drifting
# host has. The boundary is pinned here, at the helper, because these cost
# nothing to run and can enumerate banner forms the end-to-end preflight cases
# (test_release_preflight.sh) only sample.
pin_cases=0
while read -r verdict pin banner; do
	pin_cases=$((pin_cases + 1))
	if release_pinned_version_matches "$banner" "$pin"; then
		[ "$verdict" = accept ] \
			|| fail "version pin $pin accepted a drifted banner: [$banner]"
	else
		[ "$verdict" = reject ] \
			|| fail "version pin $pin rejected its own banner: [$banner]"
	fi
done <<'PIN_CASES'
accept 7.3.0 avr-gcc (GCC) 7.3.0
accept 7.3.0 avr-gcc (Ubuntu 7.3.0-16ubuntu3) 7.3.0
accept 7.3.0 avr-gcc (GCC) 7.3.0 20180101 (prerelease)
reject 7.3.0 avr-gcc (GCC) 17.3.0
reject 7.3.0 avr-gcc (GCC) 7.3.01
reject 7.3.0 avr-gcc (GCC) 7.3.0.1
reject 7.3.0 avr-gcc (GCC) 7.3.0-1
reject 7.3.0 avr-gcc (GCC) 7.4.0
reject 7.3.0 avr-gcc (GCC) 6.3.0
reject 7.3.0 avr-gcc (GCC) 7.3.0 (GCC) 7.4.0
reject 7.3.0 avr-gcc: version information unavailable
reject 7.3.0
accept 3.10 Microchip MPLAB XC8 C Compiler V3.10
accept 3.10 Microchip MPLAB XC8 C Compiler v3.10
accept 3.10 Microchip MPLAB XC8 C Compiler V3.10 (Free license)
reject 3.10 Microchip MPLAB XC8 C Compiler V3.100
reject 3.10 Microchip MPLAB XC8 C Compiler V13.10
reject 3.10 Microchip MPLAB XC8 C Compiler V3.1
reject 3.10 Microchip MPLAB XC8 C Compiler V3.10.1
reject 3.10 Microchip MPLAB XC8 C Compiler V3.10 V3.11
reject 3.10 Microchip MPLAB XC8 C Compiler
PIN_CASES
[ "$pin_cases" -eq 21 ] \
	|| fail "version-pin table ran $pin_cases cases, expected 21"
checks=$((checks + 1))

# Called wrong, the pin helper must report a usage error (2) rather than a
# verdict: a caller that silently drops an argument would otherwise compare a
# banner against the empty string and, on reaching the `found -eq 1` test, look
# exactly like an ordinary rejection.
release_pinned_version_matches "avr-gcc (GCC) 7.3.0" >"$log" 2>&1 && rc=0 || rc=$?
[ "$rc" -eq 2 ] \
	|| fail "version-pin helper returned $rc for a missing argument, expected 2"
grep -Fq 'requires a version line and a pinned version' "$log" \
	|| fail "version-pin arity error lacked its diagnostic: $(<"$log")"
checks=$((checks + 1))

# Both compiler-selection checks below assert a rule that lives in the Makefile
# -- PIC10F320_CC ?= PIC_CC -- so they must ask a Make that has been told
# NOTHING about either name. THREE separate channels would otherwise answer for
# it, and `make release` feeds all three:
#
#   The NAME, as an exported environment variable. make-release.sh exports
#     PIC_CC/PIC10F320_CC, and Make additionally exports every command-line
#     variable into the environment of every recipe -- so the name is already
#     defined here, and ?= keeps that value rather than deriving one. This is
#     the channel that actually bit: clearing only the Make flags below still
#     left PIC10F320_CC standing in the environment.
#   MAKEFLAGS / MAKEOVERRIDES, carrying the release's `PIC10F320_CC=<path>`
#     down from its test-long command line as a COMMAND-LINE override, which
#     outranks the ?= for the same reason.
#   MAKEFLAGS again, carrying a literal w: make-release.sh holds the worktree
#     lock, so the serialization wrapper that would supply --no-print-directory
#     never runs, and an inherited -w OVERRIDES -s and wraps every reply in
#     "Entering/Leaving directory" banners.
#
# Clear all three. Unsetting the two NAMES is what makes this a real test of the
# Makefile rather than an echo of the caller's configuration.
# _MAKE_SERIAL_LOCK_HELD is a plain variable, not a Make flag, so it survives
# and these queries still skip the worktree lock the outer run already holds.
read_pic_cc() {
	(
		unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKEOVERRIDES MAKELEVEL
		unset PIC_CC PIC10F320_CC
		make -s --no-print-directory -C "$ROOT" "$@"
	)
}
shared_cc="$work/shared-xc8"
pic_cc=$(read_pic_cc "PIC_CC=$shared_cc" print-PIC_CC)
pic10f320_cc=$(read_pic_cc "PIC_CC=$shared_cc" print-PIC10F320_CC)
[ "$pic_cc" = "$shared_cc" ] && [ "$pic10f320_cc" = "$shared_cc" ] \
	|| fail "PIC10F320_CC did not inherit an overridden PIC_CC"
checks=$((checks + 1))

separate_cc="$work/separate-xc8"
pic_cc=$(read_pic_cc "PIC_CC=$shared_cc" "PIC10F320_CC=$separate_cc" print-PIC_CC)
pic10f320_cc=$(read_pic_cc \
	"PIC_CC=$shared_cc" "PIC10F320_CC=$separate_cc" print-PIC10F320_CC)
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

# The final classic-AVR HEX digest must be captured after regeneration, and the
# source-loaded copy/compare helper must complete before SHA256SUMS or retained
# evidence can accept staged bytes.
mapfile -t avr_final_hash_lines < <(grep -nF \
	'final_avr_image_hashes=$(release_hash_classic_avr_images "${AVR_IMAGES[@]}")' "$RELEASE")
mapfile -t avr_stage_bind_lines < <(grep -nF \
	'release_stage_classic_avr_images "$OUTPUT_DIR" "$final_avr_image_hashes"' "$RELEASE")
# Prefix-matched: the checksum command now also covers the required non-image
# release artifacts and wraps onto a second line. What this marker pins is WHERE
# checksumming happens relative to staging, not its argument list.
mapfile -t checksum_lines < <(grep -nF \
	'( cd "$OUTPUT_DIR" && sha256sum -- "${release_basenames[@]}"' "$RELEASE")
mapfile -t evidence_copy_lines < <(grep -nF \
	'for f in "$EVID"/*.log; do' "$RELEASE")
[ "${#avr_final_hash_lines[@]}" -eq 1 ] \
	&& [ "${#avr_stage_bind_lines[@]}" -eq 1 ] \
	&& [ "${#checksum_lines[@]}" -eq 1 ] \
	&& [ "${#evidence_copy_lines[@]}" -eq 1 ] \
	|| fail "classic-AVR final-hash/staging/checksum markers are missing or ambiguous"
avr_final_hash_line=${avr_final_hash_lines[0]%%:*}
avr_stage_bind_line=${avr_stage_bind_lines[0]%%:*}
checksum_line=${checksum_lines[0]%%:*}
evidence_copy_line=${evidence_copy_lines[0]%%:*}
[ "$avr_final_hash_line" -lt "$stage_line" ] \
	&& [ "$stage_line" -lt "$avr_stage_bind_line" ] \
	&& [ "$avr_stage_bind_line" -lt "$checksum_line" ] \
	&& [ "$checksum_line" -lt "$evidence_copy_line" ] \
	|| fail "classic-AVR byte binding does not dominate checksum/evidence acceptance"
checks=$((checks + 1))

# The reproduction step is not practical to execute without a full release
# toolchain. Keep its security-sensitive freeze boundary structural; parsed
# workflow topology and publication ordering are owned by test-workflow-syntax.
ci_repro_block=$(awk '/^[[:space:]]+id: repro$/ { in_block=1 }
	/# --- re-run the gates on the clean runner/ { in_block=0 }
	in_block { print }' "$RELEASE_WORKFLOW")
for required in \
	'set -euo pipefail' \
	'image_dirs_text=$(make -s print-RELEASE_IMAGE_DIRS)' \
	'shopt -s nullglob dotglob' \
	'cp -a -- "${image_dirs[$i]}"/. "$fresh_dir"/' \
	'scripts/verify-release-images.sh "$dir" "${fresh_dirs[@]}"' \
	'release_images_text=$(make -s --no-print-directory print-RELEASE_IMAGES)' \
	'release_helper_text=$(make -s --no-print-directory print-RELEASE_HELPER_MAP)' \
	'expected_assets+=(SHA256SUMS SHA256SUMS.asc MANIFEST.md QUALIFICATION)' \
	'frozen_root=/opt/mcu-bypass-publication' \
	'sudo install -d -o root -g root -m 0700 -- "$frozen_root" "$publish"' \
	'record "$publish" "$inventory" "${expected_assets[@]}"' \
	'sudo chmod 0555 -- "$publish" "$frozen_root"'; do
	[[ "$ci_repro_block" == *"$required"* ]] \
		|| fail "tag-CI reproduction step omits required wiring: $required"
done
if grep -Fq 'RELEASE_EXPECTED_IMAGES' "$RELEASE_WORKFLOW"; then
	fail "tag CI exposes a non-Makefile canonical release-image input"
fi
if grep -Eq 'verify-rename-identity|RENAME_IDENTITY|rename_identity' \
		"$RELEASE_WORKFLOW" "$RELEASE"; then
	fail "active release production still carries retired rename-identity state"
fi
checks=$((checks + 1))

# Execute the workflow's publication shell itself with fake tag verification
# and GitHub CLI commands. This proves the step-output consumer publishes the
# exact frozen asset vector rather than only looking right to grep.
publish_step="$work/publish-step.sh"
awk '
	/^[[:space:]]+id: publish$/ { in_step=1 }
	in_step && /^        run: \|$/ { in_run=1; next }
	in_run && /^          / { print substr($0, 11); next }
	in_run { exit }
' "$RELEASE_WORKFLOW" > "$publish_step"
[ -s "$publish_step" ] || fail "could not extract release publication shell"
bash -n "$publish_step" || fail "extracted release publication shell is invalid"

publish_fixture="$work/publish fixture"
publish_assets="$publish_fixture/frozen assets"
publish_bin="$publish_fixture/bin"
publish_args="$publish_fixture/gh.args"
mkdir -p "$publish_fixture/scripts" "$publish_assets" "$publish_bin"
cp "$PUBLICATION_VERIFY" "$publish_fixture/scripts/verify_release_publication.py"
cat > "$publish_fixture/scripts/verify-release-tag-target.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 3 ]
[ "${TEST_TAG_VERIFY_FAIL:-0}" -eq 0 ] \
	|| { printf 'tag verification fixture failure\n' >&2; exit 91; }
printf '%s\n' "$@" > "$TAG_VERIFY_LOG"
EOF
cat > "$publish_fixture/scripts/verify-release-signature.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 3 ] && [ "$1" = detached ]
[ "$2" = "$RELEASE_DIR/SHA256SUMS.asc" ]
[ "$3" = "$RELEASE_DIR/SHA256SUMS" ]
[ "${TEST_SIGNATURE_FAIL:-0}" -eq 0 ] \
	|| { printf 'signature verification fixture failure\n' >&2; exit 92; }
if [ "${TEST_SIGNATURE_MUTATE:-0}" -eq 1 ]; then
	printf 'post-signature mutation\n' >> "$RELEASE_DIR/MANIFEST.md"
fi
EOF
cat > "$publish_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$GH_ARGS"
EOF
chmod 750 "$publish_fixture/scripts/verify-release-tag-target.sh" \
	"$publish_fixture/scripts/verify-release-signature.sh" \
	"$publish_bin/gh"
printf ':00000001FF\n' > "$publish_assets/a.hex"
# The frozen bundle also carries the required non-image artifacts. The
# publication shell must upload them without re-reading the Makefile, so the
# fixture supplies them exactly the way the reproduction step does: as a
# carried-forward name list beside the file itself.
printf '#!/usr/bin/env python3\n' > "$publish_assets/flash-pic12f675.py"
publish_helper_assets='flash-pic12f675.py'
publish_image_hash=$(sha256sum -- "$publish_assets/a.hex")
printf '%s  a.hex\n' "${publish_image_hash%% *}" > "$publish_assets/SHA256SUMS"
printf 'dummy signature\n' > "$publish_assets/SHA256SUMS.asc"
printf '# Test release\n' > "$publish_assets/MANIFEST.md"
printf 'dummy qualification\n' > "$publish_assets/QUALIFICATION"
tag_verify_log="$work/tag-verify.log"
publish_inventory="$publish_fixture/publication.inventory.json"
publish_inventory_sha256=
publish_expected=(a.hex flash-pic12f675.py SHA256SUMS SHA256SUMS.asc \
	MANIFEST.md QUALIFICATION)

record_publish_inventory() {
	rm -f "$publish_inventory"
	publish_inventory_sha256=$(python3 "$PUBLICATION_VERIFY" record \
		"$publish_assets" "$publish_inventory" "${publish_expected[@]}") \
		|| fail "could not record publication-shell fixture inventory"
}

run_publish_step() {
	local tag=${1:-v1.2.3}
	rm -f "$publish_args" "$tag_verify_log"
	(
		cd "$publish_fixture"
		PATH="$publish_bin:$PATH" GH_ARGS="$publish_args" \
			TAG_VERIFY_LOG="$tag_verify_log" \
			RELEASE_DIR="$publish_assets" RELEASE_TAG="$tag" \
			RELEASE_INVENTORY="$publish_inventory" \
			RELEASE_INVENTORY_SHA256="$publish_inventory_sha256" \
			VERIFIED_RELEASE_COMMIT=0000000000000000000000000000000000000000 \
			RELEASE_HELPER_ASSETS="${TEST_HELPER_ASSETS-$publish_helper_assets}" \
			TEST_TAG_VERIFY_FAIL="${TEST_TAG_VERIFY_FAIL:-0}" \
			TEST_SIGNATURE_FAIL="${TEST_SIGNATURE_FAIL:-0}" \
			TEST_SIGNATURE_MUTATE="${TEST_SIGNATURE_MUTATE:-0}" \
			bash "$publish_step"
	)
}

expect_recorded_args() {
	local label=$1 file=$2
	shift 2
	local -a actual=() expected=("$@")
	local i
	[ -f "$file" ] || fail "$label did not record an invocation"
	mapfile -t actual < "$file"
	[ "${#actual[@]}" -eq "${#expected[@]}" ] \
		|| fail "$label recorded ${#actual[@]} arguments, expected ${#expected[@]}"
	for ((i = 0; i < ${#expected[@]}; i++)); do
		[ "${actual[$i]}" = "${expected[$i]}" ] \
			|| fail "$label argument $((i + 1)) is '${actual[$i]}', expected '${expected[$i]}'"
	done
}

expect_publish_invocation() {
	local tag=$1 prerelease=$2 asset
	local -a expected=(release create "$tag" --title "Firmware $tag"
		--notes-file "$publish_assets/MANIFEST.md" --verify-tag)
	[ "$prerelease" -eq 0 ] || expected+=(--prerelease)
	for asset in "${publish_expected[@]}"; do
		expected+=("$publish_assets/$asset")
	done
	expect_recorded_args "release publication" "$publish_args" "${expected[@]}"
	expect_recorded_args "release tag verification" "$tag_verify_log" \
		origin "$tag" 0000000000000000000000000000000000000000
}

expect_publish_fail() {
	local label=$1 expected=$2 tag=${3:-v1.2.3}
	if run_publish_step "$tag" \
			>"$work/publish-fail.out" 2>&1; then
		fail "$label: invalid frozen publication state was accepted"
	fi
	grep -Fq "$expected" "$work/publish-fail.out" \
		|| fail "$label failed without '$expected': $(<"$work/publish-fail.out")"
	[ ! -e "$publish_args" ] \
		|| fail "$label invoked gh after rejecting the frozen bundle"
	checks=$((checks + 1))
}

record_publish_inventory
run_publish_step >"$work/publish.out" 2>"$work/publish.err" \
	|| fail "valid frozen bundle did not publish: $(<"$work/publish.err")"
expect_publish_invocation v1.2.3 0
checks=$((checks + 1))

# Any stray file must be rejected by the generic exact inventory before
# publication state can be recorded.
printf 'unexpected asset\n' > "$publish_assets/UNEXPECTED_ASSET"
rm -f "$publish_inventory"
if python3 "$PUBLICATION_VERIFY" record "$publish_assets" "$publish_inventory" \
		"${publish_expected[@]}" >"$work/publish-extra.out" 2>&1; then
	fail "publication inventory admitted an unexpected asset"
fi
grep -Fq 'differs from the expected publication asset set' "$work/publish-extra.out" \
	|| fail "unexpected publication asset failed for the wrong reason: $(<"$work/publish-extra.out")"
rm "$publish_assets/UNEXPECTED_ASSET"
record_publish_inventory
checks=$((checks + 1))

# The required non-image artifacts are a fail-closed input, not a convenience.
# A release that lost them between freezing and publication would otherwise
# upload firmware for a part whose only safe writer is the missing tool.
TEST_HELPER_ASSETS='' expect_publish_fail 'no carried-forward artifacts' \
	'no required release artifacts were carried forward'
TEST_HELPER_ASSETS='../escape.py' expect_publish_fail 'a path-bearing artifact name' \
	'invalid required release artifact'
TEST_HELPER_ASSETS='absent-helper.py' expect_publish_fail 'an artifact the bundle lacks' \
	'frozen bundle is missing required artifact'

# Publication kind. The same verified bundle must publish as an ordinary
# release under a bare vX.Y.Z and as a GitHub PRERELEASE under any accepted
# suffix, so a candidate can never win latest-release selection. A shape
# outside the version grammar must abort before gh is reached: the locate step
# already rejected it before any build, so one arriving here means that gate
# was bypassed, and defaulting to either kind would publish it.
run_publish_step v1.2.3-rc.1 >"$work/publish.out" 2>"$work/publish.err" \
	|| fail "suffixed tag did not publish: $(<"$work/publish.err")"
expect_publish_invocation v1.2.3-rc.1 1
checks=$((checks + 1))

for malformed_tag in 'v1.2.3-' 'v1.2.3-rc..1' 'v1.2.3--rc' 'v1.2.3+1' 'v1.2' '1.2.3'; do
	expect_publish_fail "malformed tag '$malformed_tag'" \
		"is not vX.Y.Z (optionally -suffix)" "$malformed_tag"
done

TEST_TAG_VERIFY_FAIL=1 expect_publish_fail "failed final tag verification" \
	"tag verification fixture failure"

TEST_SIGNATURE_FAIL=1 expect_publish_fail "failed final checksum signature" \
	"signature verification fixture failure"

printf 'post-freeze mutation\n' >> "$publish_assets/MANIFEST.md"
expect_publish_fail "failed first final inventory verification" \
	"frozen publication bundle differs from its inventory"
printf '# Test release\n' > "$publish_assets/MANIFEST.md"
record_publish_inventory

printf 'malformed checksum record\n' > "$publish_assets/SHA256SUMS"
record_publish_inventory
# Assert on the WORKFLOW's own annotation, not on sha256sum's text: the tool is
# third-party and coreutils 9.x dropped the "SHA256" token from its message,
# which broke this assertion once already.
expect_publish_fail "failed strict image checksum verification" \
	"::error::strict image checksum verification failed"
printf '%s  a.hex\n' "${publish_image_hash%% *}" > "$publish_assets/SHA256SUMS"
record_publish_inventory

TEST_SIGNATURE_MUTATE=1 expect_publish_fail "failed post-signature inventory verification" \
	"frozen publication bundle differs from its inventory"
printf '# Test release\n' > "$publish_assets/MANIFEST.md"
record_publish_inventory

# Exercise the standing four-way reproduction contract using only current
# Makefile declarations: canonical, checksum, committed and fresh image sets.
repro_fresh="$work/reproduction fresh"
repro_release="$work/reproduction release"
mkdir -p "$repro_fresh" "$repro_release"

repro_images_raw=$(cd "$ROOT" \
	&& make -s --no-print-directory print-RELEASE_IMAGES) \
	|| fail "could not read RELEASE_IMAGES from the Makefile"
read -r -a repro_image_names <<<"$repro_images_raw"
[ "${#repro_image_names[@]}" -gt 0 ] \
	|| fail "Makefile declares no release images"
repro_image_paths=()
for name in "${repro_image_names[@]}"; do
	printf 'synthetic fresh image %s\n' "$name" > "$repro_fresh/$name"
	repro_image_paths+=("$repro_fresh/$name")
done
cp -- "${repro_image_paths[@]}" "$repro_release/"

repro_helpers_raw=$(cd "$ROOT" \
	&& make -s --no-print-directory print-RELEASE_HELPER_MAP) \
	|| fail "could not read RELEASE_HELPER_MAP from the Makefile"
read -r -a repro_helper_entries <<<"$repro_helpers_raw"
[ "${#repro_helper_entries[@]}" -gt 0 ] \
	|| fail "Makefile declares no required release artifacts"
repro_helper_names=()
for entry in "${repro_helper_entries[@]}"; do
	helper_name=${entry%%=*}
	helper_source=${entry#*=}
	cp -p -- "$ROOT/$helper_source" "$repro_release/$helper_name" \
		|| fail "could not stage required release artifact $helper_name"
	repro_helper_names+=("$helper_name")
done
(
	cd "$repro_release"
	sha256sum -- "${repro_image_names[@]}" "${repro_helper_names[@]}" \
		> SHA256SUMS
)

ambient_release_expected=${repro_image_names[0]}
if ! RELEASE_EXPECTED_IMAGES="$ambient_release_expected" \
		"$RELEASE_IMAGE_VERIFY" "$repro_release" "$repro_fresh" \
		>"$work/reproduction-valid.out" 2>&1; then
	fail "ambient reduced image set replaced Makefile truth during valid reproduction: $(<"$work/reproduction-valid.out")"
fi
checks=$((checks + 1))

printf '\npost-validation mutation\n' \
	>> "$repro_fresh/${repro_image_names[0]}"
if RELEASE_EXPECTED_IMAGES="$ambient_release_expected" \
		"$RELEASE_IMAGE_VERIFY" "$repro_release" "$repro_fresh" \
		>"$work/reproduction-mutation.out" 2>&1; then
	fail "release reproduction accepted a changed fresh image"
fi
grep -Fq 'fresh image checksum verification failed' \
	"$work/reproduction-mutation.out" \
	|| fail "release reproduction rejected the changed image for the wrong reason"
checks=$((checks + 1))

# The release orchestrator must identify each selected compiler before building
# and attribute each result to the corresponding image family in the manifest.
mapfile -t xc8_322_lines < <(grep -nF \
	'TC_XC8_322=$(release_tool_version_line "PIC10F322 XC8 (PIC_CC=$PIC_CC)" "$PIC_CC")' \
	"$RELEASE")
mapfile -t xc8_320_lines < <(grep -nF \
	'TC_XC8_320=$(release_tool_version_line "PIC10F320 XC8 (PIC10F320_CC=$PIC10F320_CC)" "$PIC10F320_CC")' \
	"$RELEASE")
mapfile -t pic12_python_lines < <(grep -nF \
	'TC_PIC12F675_PY=$(release_tool_version_line' "$RELEASE")
mapfile -t clean_lines < <(grep -nF 'make clean >/dev/null' "$RELEASE")
mapfile -t manifest_renderer_lines < <(grep -nF \
	'release_render_pic_toolchain_rows "$PIC_CC" "$TC_XC8_322"' "$RELEASE")
[ "${#xc8_322_lines[@]}" -eq 1 ] \
	&& [ "${#xc8_320_lines[@]}" -eq 1 ] \
	&& [ "${#pic12_python_lines[@]}" -eq 1 ] \
	&& [ "${#clean_lines[@]}" -eq 1 ] \
	&& [ "${#manifest_renderer_lines[@]}" -eq 1 ] \
	|| fail "release compiler provenance wiring is missing or ambiguous"
xc8_322_line=${xc8_322_lines[0]%%:*}
xc8_320_line=${xc8_320_lines[0]%%:*}
pic12_python_line=${pic12_python_lines[0]%%:*}
clean_line=${clean_lines[0]%%:*}
[ "$xc8_322_line" -lt "$clean_line" ] && [ "$xc8_320_line" -lt "$clean_line" ] \
	&& [ "$pic12_python_line" -lt "$clean_line" ] \
	|| fail "release compiler/interpreter identity is not captured before the clean build"
grep -Fq '"$PIC_CC" "$TC_XC8_322"' "$RELEASE" \
	|| fail "manifest renderer does not receive the shared selected compiler and version"
grep -Fq '"$PIC10F320_CC" "$TC_XC8_320"' "$RELEASE" \
	|| fail "manifest renderer does not receive the PIC10F320 selected compiler and version"
grep -Fq "printf -- '| PIC12F675 Python | %s |" "$RELEASE" \
	|| fail "manifest does not record the selected PIC12F675 Python"
if grep -Fq "printf -- '| XC8 |" "$RELEASE"; then
	fail "release manifest still contains an ambiguous generic XC8 row"
fi
checks=$((checks + 1))

version_assignments=$(grep -Ec '^TC_[A-Z0-9_]+=\$\(release_tool_version_line ' "$RELEASE")
[ "$version_assignments" -eq 11 ] \
	|| fail "release has $version_assignments fail-closed executable version probes, expected 11"
! grep -Fq 'v1()' "$RELEASE" \
	|| fail "release still contains the fail-open v1 tool-version helper"
checks=$((checks + 1))

# The three image-defining compiler pins. Their POSITION is part of the
# contract: each must run after the banner it judges is captured and before the
# preflight exit, which puts it ahead of every scratch tree, build and soak on
# the --preflight path and the real one alike. Their ARGUMENTS are too: each
# names the selected tool the preconditions resolved rather than a default on
# PATH, and carries its own pin, so one compiler cannot satisfy another's check.
mapfile -t preflight_exit_lines < <(grep -nF \
	'ok "preflight passed: this host can start a release."' "$RELEASE")
[ "${#preflight_exit_lines[@]}" -eq 1 ] \
	|| fail "release preflight success marker is missing or ambiguous"
preflight_exit_line=${preflight_exit_lines[0]%%:*}
for pin_call in \
		'require_pinned_compiler "avr-gcc" CC "$AVR_CC" "$TC_AVR_GCC" 7.3.0 7.3.0' \
		'require_pinned_compiler "PIC10F322/PIC12F675 XC8" PIC_CC "$PIC_CC" "$TC_XC8_322" 3.10 V3.10' \
		'require_pinned_compiler "PIC10F320 XC8" PIC10F320_CC "$PIC10F320_CC" "$TC_XC8_320" 3.10 V3.10'; do
	mapfile -t pin_lines < <(grep -nFx "$pin_call" "$RELEASE")
	[ "${#pin_lines[@]}" -eq 1 ] \
		|| fail "image-defining compiler pin is missing or ambiguous: $pin_call"
	pin_line=${pin_lines[0]%%:*}
	[ "$pin_line" -lt "$preflight_exit_line" ] && [ "$pin_line" -lt "$clean_line" ] \
		|| fail "image-defining compiler pin runs after the preflight exit or the clean build: $pin_call"
done
# The substring patterns these replaced accepted any banner CONTAINING the pin,
# which is how avr-gcc 17.3.0 and XC8 V3.100 passed. Keep them out of the CODE
# -- comments still quote them, which is why this reads uncommented lines only.
for stale_pattern in '*7.3.0*' '*V3.10*' '*v3.10*'; do
	if grep -vE '^[[:space:]]*#' "$RELEASE" | grep -Fq "$stale_pattern"; then
		fail "release still matches a compiler pin as the substring pattern $stale_pattern"
	fi
done
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
