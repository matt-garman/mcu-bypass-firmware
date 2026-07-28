#!/usr/bin/env bash
set -euo pipefail

# Proof that optional-tool recipes route their "tool absent" path through the
# Makefile's central STRICT_TOOLS/$(SKIP) mechanism: clean skip (exit 0) by
# default, hard failure with the ::error:: marker under STRICT_TOOLS=1.
#
# INVENTORY SCOPE (merge plan §6.12, §12). This used to cover exactly two
# recipes -- test-cbmc and analyze-cppcheck -- which meant NEITHER PIC chip had
# an enforcing regression, and a pic320- recipe with a private early `exit 0`
# would have passed review. It now covers both chips' XC8 and cppcheck/MISRA
# recipes as well.
#
# It also covers both chips' CLI-gpsim recipes, which used to be a stated gap --
# and the reason that gap is gone is worth recording, because the sentence that
# justified it was WRONG in the one place it mattered. It read: "Those recipes
# use the same $(SKIP) mechanism; what is unproven is only that they still will."
# pic320-test-gpsim did not use it. It had no tool probe at all, so
# `make pic320-test STRICT_TOOLS=1` on a host without gpsim printed "all
# PIC10F320 pre-hardware checks complete" having run zero of its six scenarios
# (the wrappers exit 0 on a missing gpsim by design). An assumed mechanism is not
# a mechanism, which is the whole argument for enumerating recipes here.
#
# The obstacle was real, though: these recipes sit behind a BUILD prerequisite,
# so driving them normally makes the verdict depend on whether XC8 happens to be
# installed -- with XC8 the guard fires, without it the prerequisite answers
# first, with a different message. `-o <build-target>` (--old-file) removes the
# dependence: Make is told not to remake that prerequisite, so the recipe body is
# entered directly and only $(GPSIM) decides the outcome. Same verdict on any
# runner, XC8 or not.
#
# Still NOT covered, same prerequisite problem and no equivalent lever: the
# libgpsim and soak recipes (pic320-test-fault-target, pic{,320}-test-soak, ...),
# whose guards check headers, glib and a C++ compiler rather than one binary, and
# which -o would strand mid-way (the harness still has to compile and link). That
# remains a stated gap -- but a narrower one, and both chips' gpsim lanes now
# share ONE preflight definition in the Makefile, so the specific failure above
# (a probe present on one chip, absent on the other) is no longer expressible.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/test-strict-tools.XXXXXX")
trap 'rm -rf "$work"' EXIT
checks=0

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

read -r -a MAKE_CMD <<<"${PROJECT_MAKE:-make}"
[ "${#MAKE_CMD[@]}" -gt 0 ] || fail "PROJECT_MAKE must name a Make command"
command -v "${MAKE_CMD[0]}" >/dev/null 2>&1 \
	|| fail "Make command not found: ${MAKE_CMD[0]}"

run_make() {
	(
		unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL MAKE STRICT_TOOLS CBMC CPPCHECK GPSIM
		[ -z "${FAKE_TOOL_LOG:-}" ] || export FAKE_TOOL_LOG
		"${MAKE_CMD[@]}" --no-print-directory -C "$ROOT" "$@"
	)
}

# Both take: <target> <expected-reason> [VAR=value ...] -- variadic because the
# PIC recipes need a second assignment to redirect their build directory (see
# below).
expect_missing_skip() {
	local target=$1 reason=$2; shift 2
	local output
	output=$(run_make "$target" STRICT_TOOLS= "$@" 2>&1) \
		|| fail "$target did not skip a missing tool by default: $output"
	[[ "$output" == *"$reason"* && "$output" != *"STRICT_TOOLS=1:"* ]] \
		|| fail "$target produced the wrong default-skip diagnostic: $output"
	checks=$((checks + 1))
}

expect_missing_strict_failure() {
	local target=$1 reason=$2; shift 2
	local output
	if output=$(run_make "$target" STRICT_TOOLS=1 "$@" 2>&1); then
		fail "$target accepted a missing tool under STRICT_TOOLS=1"
	fi
	[[ "$output" == *"$reason"* && "$output" == *"STRICT_TOOLS=1:"* ]] \
		|| fail "$target produced the wrong strict failure: $output"
	checks=$((checks + 1))
}

# Both modes for every registered recipe.
expect_both() {
	expect_missing_skip "$@"
	expect_missing_strict_failure "$@"
}

missing_cbmc="$work/missing-cbmc"
missing_cppcheck="$work/missing-cppcheck"
missing_xc8="$work/missing-xc8"
missing_gpsim="$work/missing-gpsim"

expect_both test-cbmc "cbmc not installed" "CBMC=$missing_cbmc"
expect_both analyze-cppcheck "cppcheck not installed" "CPPCHECK=$missing_cppcheck"

# --- both PIC chips' optional-tool recipes -----------------------------------
# The build directories are redirected into the scratch tree: `pic` and `pic320`
# BOTH remove their output image(s) as the very first recipe step, before the
# XC8 guard is reached, so driving them against the real build_pic/ and
# build_pic10f320/ would delete a developer's images as a side effect of running
# `make test`. Redirecting costs one assignment and removes the side effect
# entirely. Everything the guards themselves check is unaffected.
pic_build="$work/build_pic"
pic320_build="$work/build_pic10f320"

expect_both pic "XC8 not found at $missing_xc8" \
	"PIC_CC=$missing_xc8" "PIC_BUILD_DIR=$pic_build"
expect_both pic320 "XC8 not found at $missing_xc8" \
	"PIC320_CC=$missing_xc8" "PIC320_BUILD_DIR=$pic320_build"

expect_both pic-analyze-cppcheck "cppcheck not installed" \
	"CPPCHECK=$missing_cppcheck"
expect_both pic320-analyze-cppcheck "cppcheck not installed" \
	"CPPCHECK=$missing_cppcheck"

expect_both pic-analyze-misra "cppcheck and/or python3 not available" \
	"CPPCHECK=$missing_cppcheck"
expect_both pic320-analyze-misra "cppcheck and/or python3 not available" \
	"CPPCHECK=$missing_cppcheck"

# Both chips' CLI-gpsim lanes. `-o pic` / `-o pic320` suppresses the build
# prerequisite (see the header), so these run identically with or without XC8.
# The reason strings are chip-specific on purpose: they also pin that the shared
# preflight's label argument is threaded per chip, so the two lanes cannot
# collapse into one indistinguishable diagnostic.
expect_both pic-test-gpsim \
	"gpsim not installed; skipping PIC10F322 gpsim register-level test" \
	"GPSIM=$missing_gpsim" -o pic
expect_both pic320-test-gpsim \
	"gpsim not installed; skipping PIC10F320 gpsim register-level test" \
	"GPSIM=$missing_gpsim" -o pic320

fake_cbmc="$work/fake-cbmc"
fake_cppcheck="$work/fake-cppcheck"
cbmc_log="$work/cbmc.log"
cppcheck_log="$work/cppcheck.log"
cat > "$fake_cbmc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_TOOL_LOG:?}"
EOF
cat > "$fake_cppcheck" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_TOOL_LOG:?}"
EOF
chmod 750 "$fake_cbmc" "$fake_cppcheck"

: > "$cbmc_log"
if ! output=$(FAKE_TOOL_LOG="$cbmc_log" run_make test-cbmc STRICT_TOOLS=1 \
		"CBMC=$fake_cbmc" 2>&1); then
	fail "test-cbmc rejected an available tool under STRICT_TOOLS=1: $output"
fi
[ "$(wc -l < "$cbmc_log")" -eq 9 ] \
	|| fail "test-cbmc did not execute all 9 proof commands"
[[ "$output" == *"all debounce-core proofs SUCCESSFUL"* ]] \
	|| fail "test-cbmc omitted its completion sentinel"
checks=$((checks + 1))

: > "$cppcheck_log"
if ! output=$(FAKE_TOOL_LOG="$cppcheck_log" run_make analyze-cppcheck \
		STRICT_TOOLS=1 "CPPCHECK=$fake_cppcheck" 2>&1); then
	fail "analyze-cppcheck rejected an available tool under STRICT_TOOLS=1: $output"
fi
[ "$(wc -l < "$cppcheck_log")" -eq 1 ] \
	|| fail "analyze-cppcheck did not execute exactly one analyzer command"
[[ "$output" == *"cppcheck: $fake_cppcheck"* ]] \
	|| fail "analyze-cppcheck omitted its execution diagnostic"
checks=$((checks + 1))

printf 'strict optional-tool validation (host + both PIC chips): %d checks, 0 failures\n' "$checks"
