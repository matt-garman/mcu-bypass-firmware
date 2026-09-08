#!/usr/bin/env bash
set -euo pipefail
# A bare `var=$(... grep ...)` that matches nothing takes this suite down with
# `set -e` and NO output: the failure has no diagnostic, and any guard on the
# next line never runs. Name the line instead of exiting mute. Deliberately no
# `set -E` -- without errtrace the trap is not inherited by the command
# substitution's subshell, so a failure is reported once rather than twice.
# This only reports; `set -e` still does the exiting, so control flow is unchanged.
# The `case $-` guard is required, not defensive: bash runs an ERR trap even
# inside a deliberate `set +e` block, and several suites use one around a
# command whose non-zero status IS the expected result (`make -q` returns 1).
# Without the guard those print a spurious FAIL that lands in retained
# release evidence, because test-long.summary.txt is built by grepping ^FAIL.
trap 'err_rc=$?; case $- in *e*) printf "FAIL: %s:%d exited %d with no diagnostic (a command substitution that matched nothing?)\n" "${BASH_SOURCE[0]}" "$LINENO" "$err_rc" >&2 ;; esac' ERR

# The mutation-policy probe reads STRICT_TOOLS and MUTATION_ALLOW_SKIP from its
# environment (see test/mutation_policy.sh). This regression drives both knobs
# explicitly on each make command line, so strip any ambient values inherited
# from an interactive shell or an enclosing `make` invocation. Otherwise a
# leaked MUTATION_ALLOW_SKIP is honored ahead of STRICT_TOOLS and masks the
# defaulting that the final checks assert.
#
# A plain env-var unset is not enough: when this suite runs under an enclosing
# `make test-long ... MUTATION_ALLOW_SKIP=0` (as scripts/make-release.sh does),
# that command-line override is re-applied to every child `make` through
# MAKEFLAGS/MAKEOVERRIDES, so the default-behavior probes below would inherit
# MUTATION_ALLOW_SKIP=0 and report 0 where they must observe the unset default.
# Clear the make override channels too; the probes always pass the variables
# they care about explicitly.
unset MUTATION_ALLOW_SKIP STRICT_TOOLS MAKEFLAGS MAKEOVERRIDES MFLAGS GNUMAKEFLAGS

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CI_LOCAL="$ROOT/scripts/ci-local.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/test-ci-local-routing.XXXXXX")
trap 'rm -rf "$work"' EXIT
fakebin="$work/bin"
log="$work/make.log"
checks=0
REAL_MAKE=$(command -v make)

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

mkdir -p "$fakebin" "$work/dfp/pic/include/proc" "$work/gpsim-inc" \
	"$work/xt-dfp/gcc/dev/attiny202/device-specs" \
	"$work/xt-dfp/include/avr" "$work/yasimavr-venv/bin"
# All three device headers: assert_pic_toolchain checks the 322 and the 320
# through their own PIC_*/PIC10F320_* pairs and the 12F675 through the 322's
# pair, so a fake DFP missing any one of them would fail the assert before any
# routing was exercised.
printf '/* fixture */\n' > "$work/dfp/pic/include/proc/pic10f322.h"
printf '/* fixture */\n' > "$work/dfp/pic/include/proc/pic10f320.h"
printf '/* fixture */\n' > "$work/dfp/pic/include/proc/pic12f675.h"
printf '/* fixture */\n' > "$work/gpsim-inc/sim_context.h"
: > "$work/xt-dfp/gcc/dev/attiny202/device-specs/specs-attiny202"
: > "$work/xt-dfp/include/avr/iotn202.h"

cat > "$fakebin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -eq 2 ] && [ "$1" = rev-parse ] && [ "$2" = --show-toplevel ]; then
	printf '%s\n' "${FAKE_REPO_ROOT:?}"
	exit 0
fi
printf 'unexpected fake git invocation: %s\n' "$*" >&2
exit 64
EOF

cat > "$fakebin/make" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# A `make -s print-FOO ...` is a VARIABLE QUERY, not job routing: the host/AVR
# preflight reads every tool name from the Makefile through one such call rather
# than hardcoding names that could drift. Delegate those to the real make (so
# the preflight sees real values, and any env override is honored) and keep them
# OUT of the log, so the counts below keep asserting exactly which JOBS ran.
# Scan every argument, not just $1: the query arrives as `make -s print-CC
# print-HOSTCC ...`, so $1 is the -s flag.
#
# The two exceptions are CI_LOCAL_SEQUENCE and CI_LOCAL_FOLDED. The Makefile
# refuses to PARSE unless those two partition CI_GOALS, so a doctored value
# cannot be delivered through make at all -- and the interesting cases are
# exactly the ones the partition forbids. Answer them here instead, which is
# also the only way to reach the script's own handler-correspondence checks.
for arg in "$@"; do
	case "$arg" in
	print-CI_LOCAL_SEQUENCE)
		if [ -n "${FAKE_CI_LOCAL_SEQUENCE+set}" ]; then
			printf '%s\n' "$FAKE_CI_LOCAL_SEQUENCE"; exit 0
		fi
		;;
	print-CI_LOCAL_FOLDED)
		if [ -n "${FAKE_CI_LOCAL_FOLDED+set}" ]; then
			printf '%s\n' "$FAKE_CI_LOCAL_FOLDED"; exit 0
		fi
		;;
	esac
done
for arg in "$@"; do
	case "$arg" in
	print-*) exec "${REAL_MAKE:?}" -s --no-print-directory -C "${FAKE_REPO_ROOT:?}" "$@" ;;
	esac
done
printf 'STRICT_TOOLS=%s' "${STRICT_TOOLS-}" >> "${FAKE_MAKE_LOG:?}"
for arg in "$@"; do printf '\t%s' "$arg" >> "$FAKE_MAKE_LOG"; done
printf '\n' >> "$FAKE_MAKE_LOG"

if [ "${1:-}" = test-long ]; then
	requested=
	for arg in "$@"; do
		case "$arg" in MUTATION_ALLOW_SKIP=*) requested=${arg#*=} ;; esac
	done
	[ -n "$requested" ] \
		|| { printf 'test-long omitted MUTATION_ALLOW_SKIP\n' >&2; exit 65; }
	resolved=$("${REAL_MAKE:?}" -s --no-print-directory -C "${FAKE_REPO_ROOT:?}" \
		_test-mutation-policy-probe STRICT_TOOLS="${STRICT_TOOLS-}" \
		MUTATION_ALLOW_SKIP="$requested" 2>/dev/null)
	[ "$resolved" = "$requested" ] \
		|| { printf 'mutation policy resolved incorrectly: %s\n' "$resolved" >&2; exit 66; }
fi

case "${1:-}" in
	attiny202-sim)
		for _ in 1 2 3; do printf 'SIM PASS\n'; done
		;;
	attiny202-fault)
		for _ in 1 2 3; do printf 'FAULT PASS\n'; done
		;;
	attiny202-lockstep)
		for _ in 1 2 3; do
			printf 'LOCKSTEP PASS\nco-simulated\nco-simulated\n'
		done
		;;
	attiny202-soak)
		for _ in 1 2 3; do printf 'SOAK PASS\n'; done
		;;
esac
EOF

# cc/clang/clang-tidy/cbmc/gcov/python3 join the original three so the host/AVR
# preflight resolves entirely inside this fixture. Without them the routing
# regression would start depending on which analyzers happen to be installed on
# the box running it, and would fail on a machine that legitimately lacks, say,
# cbmc -- turning a routing test into a toolchain test.
for tool in gpsim cppcheck pkg-config c++ cc clang clang-tidy cbmc gcov python3 gpg avr-objdump; do
	cat > "$fakebin/$tool" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
done
# avr-gcc exits NON-zero so the preflight's `-fanalyzer` probe reports the
# fallback as unavailable, which is what drives it down the clang/clang-tidy
# branch. That is the branch worth covering here: the alternative (a fake that
# claims -fanalyzer support) would skip those two checks entirely.
cat > "$fakebin/avr-gcc" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
# simavr headers are probed by path, not by PATH lookup.
mkdir -p "$work/simavr-inc"
: > "$work/simavr-inc/sim_avr.h"
cat > "$work/xc8" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$work/yasimavr-venv/bin/python" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 750 "$fakebin"/* "$work/xc8" "$work/yasimavr-venv/bin/python"

run_ci() {
	: > "$log"
		env PATH="$fakebin:$PATH" FAKE_REPO_ROOT="$ROOT" FAKE_MAKE_LOG="$log" \
		REAL_MAKE="$REAL_MAKE" \
		PIC_CC="$work/xc8" PIC_DFP="$work/dfp" \
		PIC10F320_CC="$work/xc8" PIC10F320_DFP="$work/dfp" \
		PIC_SOAK_GPSIM_INC="$work/gpsim-inc" \
		PIC10F320_SOAK_GPSIM_INC="${PIC10F320_SOAK_GPSIM_INC:-$work/gpsim-inc}" \
		SIMAVR_INC="$work/simavr-inc" \
		XT_DFP="$work/xt-dfp" YASIMAVR_VENV="$work/yasimavr-venv" \
		"$CI_LOCAL" --no-clean "$@" 2>&1
}

run_ci_clean() {
	: > "$log"
		env PATH="$fakebin:$PATH" FAKE_REPO_ROOT="$ROOT" FAKE_MAKE_LOG="$log" \
		REAL_MAKE="$REAL_MAKE" \
		PIC_CC="$work/xc8" PIC_DFP="$work/dfp" \
		PIC10F320_CC="$work/xc8" PIC10F320_DFP="$work/dfp" \
		PIC_SOAK_GPSIM_INC="$work/gpsim-inc" \
		PIC10F320_SOAK_GPSIM_INC="${PIC10F320_SOAK_GPSIM_INC:-$work/gpsim-inc}" \
		SIMAVR_INC="$work/simavr-inc" \
		XT_DFP="$work/xt-dfp" YASIMAVR_VENV="$work/yasimavr-venv" \
		"$CI_LOCAL" "$@" 2>&1
}

expect_calls() {
	local label=$1 index=0
	shift
	[ "${#calls[@]}" -eq "$#" ] \
		|| fail "$label executed ${#calls[@]} Make commands, expected $#"
	for expected in "$@"; do
		[ "${calls[$index]}" = "$expected" ] \
			|| fail "$label command $((index + 1)) was '${calls[$index]}', expected '$expected'"
		index=$((index + 1))
	done
}

tab=$'\t'
expected_xt_static=16
expected_xt_stack=32
expected_pic_data=48
# One command: the PIC job invokes the same ci-pic goal the hosted job does,
# and the fake make below records the invocation rather than expanding it. What
# the goal then runs is the Makefile's business, asserted by the workflow
# contract against ci-pic's recipe; what belongs here is that local CI hands it
# the installation its own preflight asserted, and the production data limit.
pic_calls=(
	"STRICT_TOOLS=1${tab}ci-pic${tab}PIC_CC=$work/xc8${tab}PIC_DFP=$work/dfp${tab}PIC10F320_CC=$work/xc8${tab}PIC10F320_DFP=$work/dfp${tab}PIC12F675_DATA_LIMIT=$expected_pic_data"
)
# Two commands, in order: the DFP half then the venv half. As with the PIC job
# the fake make records the wrapper rather than expanding it -- what each goal
# then runs, including the soak's per-variant PASS count, is asserted by the
# workflow contract against the recipe. What belongs here is that local CI runs
# the same two goals the hosted job does, with the same policy pins.
xt_calls=(
	"STRICT_TOOLS=1${tab}ci-attiny202-build${tab}XT_STATIC_RAM_LIMIT=$expected_xt_static${tab}XT_STACK_MAX_FRAME=$expected_xt_stack"
	"STRICT_TOOLS=1${tab}ci-attiny202-target${tab}XT_STATIC_RAM_LIMIT=$expected_xt_static"
)
# One command per classic AVR part, mirroring the hosted matrix row for row.
# The parts are read from the Makefile at run time (the fake make delegates
# `print-*` to the real one), so this expectation follows CI_CLASSIC_PARTS
# rather than restating it -- a new part changes both surfaces at once.
build_calls=()
for part in $("$REAL_MAKE" -s --no-print-directory -C "$ROOT" print-CI_CLASSIC_PARTS); do
	build_calls+=("STRICT_TOOLS=1${tab}ci-build-classic${tab}CI_CLASSIC_PART=$part")
done
[ "${#build_calls[@]}" -gt 0 ] || fail "CI_CLASSIC_PARTS is empty"
checks=$((checks + 1))
strict_stress=$'STRICT_TOOLS=1\ttest-long\tMUTATION_ALLOW_SKIP=0'
pic_partial_stress=$'STRICT_TOOLS=1\ttest-long\tMUTATION_ALLOW_SKIP=PIC'
xt_partial_stress=$'STRICT_TOOLS=1\ttest-long\tMUTATION_ALLOW_SKIP=ATtiny202'
both_partial_stress=$'STRICT_TOOLS=1\ttest-long\tMUTATION_ALLOW_SKIP=PIC,ATtiny202'
resource_args="${tab}XT_STATIC_RAM_LIMIT=$expected_xt_static${tab}PIC12F675_DATA_LIMIT=$expected_pic_data"
strict_stress+="$resource_args"
pic_partial_stress+="$resource_args"
xt_partial_stress+="$resource_args"
both_partial_stress+="$resource_args"

# The skip-mode calls below are safe only while both hosted inventories exclude
# the target-toolchain gates. The workflow contract separately follows the full
# transitive Make graph and binds each gate to its provisioned CI job.
mapfile -t host_gate_sets < <("$REAL_MAKE" -s --no-print-directory -C "$ROOT" \
	print-TEST_GATES print-TEST_LONG_GATES CC="$fakebin/avr-gcc")
[ "${#host_gate_sets[@]}" -eq 2 ] || fail "could not read hosted gate inventories"
for gates in "${host_gate_sets[@]}"; do
	for gate in test-attiny202-guard-mutations test-pic-guard-mutations; do
		case " $gates " in
			*" $gate "*) fail "hosted aggregate includes target-toolchain gate $gate" ;;
		esac
	done
done
checks=$((checks + 4))

if ! output=$(run_ci); then
	fail "push without skips failed: $output"
fi
mapfile -t calls < "$log"
expect_calls "push without skips" "${pic_calls[@]}" "${build_calls[@]}" \
	"${xt_calls[@]}" "$strict_stress"
[[ "$output" != *"job was skipped"* ]] \
	|| fail "push without skips emitted a skipped-job warning"
[[ "$output" == *"PIC toolchain present: XC8/DFP, gpsim, libgpsim/GLib, cppcheck, and C++"* ]] \
	|| fail "push without skips did not execute the shared PIC toolchain assertion"
[[ "$output" != *"Safe to push"* && "$output" == *"not a full push reproduction"* ]] \
	|| fail "push --no-clean claimed to be a clean push reproduction"
checks=$((checks + 1))

if output=$(PIC10F320_SOAK_GPSIM_INC="$work/missing-gpsim-inc" run_ci 2>&1); then
	fail "push accepted a missing selected PIC10F320 libgpsim header"
fi
mapfile -t calls < "$log"
[[ ${#calls[@]} -eq 0 \
	&& $output == *"PIC10F320 libgpsim header is missing"* ]] \
	|| fail "missing selected PIC10F320 libgpsim input did not fail in shared preflight: $output"
checks=$((checks + 1))

if ! output=$(run_ci_clean); then
	fail "clean push without skips failed: $output"
fi
mapfile -t calls < "$log"
expect_calls "clean push without skips" $'STRICT_TOOLS=1\tclean' \
	"${pic_calls[@]}" "${build_calls[@]}" "${xt_calls[@]}" "$strict_stress"
[[ "$output" == *"Safe to push"* && "$output" != *"not a full push reproduction"* ]] \
	|| fail "clean push without skips omitted the safe-to-push verdict"
checks=$((checks + 1))

if ! output=$(run_ci --skip-pic); then
	fail "push --skip-pic failed: $output"
fi
mapfile -t calls < "$log"
expect_calls "push --skip-pic" "${build_calls[@]}" "${xt_calls[@]}" "$pic_partial_stress"
[[ "$output" == *"PIC job was skipped"* && "$output" != *"ATtiny202 job was skipped"* ]] \
	|| fail "push --skip-pic emitted the wrong skipped-job warnings"
[[ "$output" != *"Safe to push"* && "$output" == *"not a full push reproduction"* ]] \
	|| fail "push --skip-pic claimed to be a full push reproduction"
checks=$((checks + 1))

if ! output=$(run_ci --skip-attiny202); then
	fail "push --skip-attiny202 failed: $output"
fi
mapfile -t calls < "$log"
expect_calls "push --skip-attiny202" "${pic_calls[@]}" "${build_calls[@]}" "$xt_partial_stress"
[[ "$output" == *"ATtiny202 job was skipped"* && "$output" != *"PIC job was skipped"* ]] \
	|| fail "push --skip-attiny202 emitted the wrong skipped-job warnings"
checks=$((checks + 1))

if ! output=$(run_ci --skip-pic --skip-attiny202); then
	fail "push with both target toolchains skipped failed: $output"
fi
mapfile -t calls < "$log"
expect_calls "push with both skips" "${build_calls[@]}" "$both_partial_stress"
[[ "$output" == *"PIC job was skipped"* && "$output" == *"ATtiny202 job was skipped"* ]] \
	|| fail "push with both skips omitted a skipped-job warning"
checks=$((checks + 1))

if ! output=$(run_ci --pr --skip-pic --skip-attiny202); then
	fail "PR with both skips routing failed: $output"
fi
mapfile -t calls < "$log"
# The build matrix still runs in PR mode (it has no --skip), so the expected
# tail is one command per classic part, then the verify goal.
pr_expected=("${build_calls[@]}" $'STRICT_TOOLS=1\tci-verify')
[ "${#calls[@]}" -eq "${#pr_expected[@]}" ] \
	|| fail "PR with both skips executed ${#calls[@]} Make commands, expected ${#pr_expected[@]}"
# ci-verify, not `test`: PR mode invokes the same goal the hosted verify job
# invokes, so the two cannot drift into equivalent-looking spellings. What that
# goal runs is asserted where it now lives -- against the recipe, in
# test_workflow_syntax.sh.
for i in "${!pr_expected[@]}"; do
	[ "${calls[$i]}" = "${pr_expected[$i]}" ] \
		|| fail "PR with both skips command $((i + 1)) was '${calls[$i]}', expected '${pr_expected[$i]}'"
done
[[ "${calls[1]}" != *"MUTATION_ALLOW_SKIP"* ]] \
	|| fail "PR mode unexpectedly configured mutation testing"
checks=$((checks + 1))

for policy in 0 1 PIC ATtiny202 PIC,ATtiny202; do
	resolved=$("$REAL_MAKE" -s --no-print-directory -C "$ROOT" \
		_test-mutation-policy-probe MUTATION_ALLOW_SKIP="$policy" 2>/dev/null)
	[ "$resolved" = "$policy" ] \
		|| fail "mutation policy changed explicit value '$policy' to '$resolved'"
done
for policy in '' invalid pic ATtiny202,PIC PIC,PIC; do
	if output=$("$REAL_MAKE" -s --no-print-directory -C "$ROOT" \
			_test-mutation-policy-probe MUTATION_ALLOW_SKIP="$policy" 2>&1); then
		fail "mutation policy accepted invalid explicit value '$policy'"
	fi
	[[ "$output" == *"MUTATION_ALLOW_SKIP must be 0, 1, PIC, ATtiny202, or PIC,ATtiny202"* ]] \
		|| fail "mutation policy produced the wrong invalid-value diagnostic: $output"
done
resolved=$("$REAL_MAKE" -s --no-print-directory -C "$ROOT" \
	_test-mutation-policy-probe STRICT_TOOLS= 2>/dev/null)
[ "$resolved" = 1 ] \
	|| fail "non-strict mutation policy did not default to partial: $resolved"
resolved=$("$REAL_MAKE" -s --no-print-directory -C "$ROOT" \
	_test-mutation-policy-probe STRICT_TOOLS=1 2>/dev/null)
[ "$resolved" = 0 ] \
	|| fail "strict mutation policy did not default to fail-closed: $resolved"
checks=$((checks + 1))

# --- the script EXECUTES the Make-declared sequence, and refuses if it cannot -
# The sequence used to be a hardcoded list of run_step calls described by a
# prose header. It is now read from CI_LOCAL_SEQUENCE, so the failure worth
# covering is the new one: a goal the mirror was told to run and has no handler
# for. That must ABORT, and abort before any gate runs -- a mirror that skipped
# a job and still printed "Safe to push" is the exact defect this file exists
# to catch. The reverse (a handler no longer sequenced) must abort too: it is a
# gate nobody calls.
#
# Each case asserts an EMPTY command log as well as the diagnostic. Failing
# after the PIC job would still be a failure, but it would have cost an hour
# first, and the plan checks are placed ahead of the preflight for that reason.
# The full sequence PLUS one unhandled goal, not a short list containing one:
# a short list also orphans the handlers it dropped, so the orphan check below
# would catch it and this one could be deleted without a test going red.
if output=$(FAKE_CI_LOCAL_SEQUENCE="$(
		"$REAL_MAKE" -s --no-print-directory -C "$ROOT" print-CI_LOCAL_SEQUENCE
	) ci-brand-new" run_ci 2>&1); then
	fail "a sequenced goal with no handler did not abort the run"
fi
mapfile -t calls < "$log"
[[ ${#calls[@]} -eq 0 && $output == *"defines no goal_ci_brand_new"* ]] \
	|| fail "unhandled sequenced goal produced the wrong failure: $output"
checks=$((checks + 1))

if output=$(FAKE_CI_LOCAL_SEQUENCE="ci-pic" run_ci 2>&1); then
	fail "a handler with no sequence entry did not abort the run"
fi
mapfile -t calls < "$log"
[[ ${#calls[@]} -eq 0 && $output == *"CI_LOCAL_SEQUENCE does not name its goal"* ]] \
	|| fail "orphaned handler produced the wrong failure: $output"
checks=$((checks + 1))

if output=$(FAKE_CI_LOCAL_SEQUENCE="" run_ci 2>&1); then
	fail "an empty CI_LOCAL_SEQUENCE did not abort the run"
fi
mapfile -t calls < "$log"
[[ ${#calls[@]} -eq 0 && $output == *"would mirror no CI job at all"* ]] \
	|| fail "empty sequence produced the wrong failure: $output"
checks=$((checks + 1))

# The tail invokes ci-verify by name, so it must be on the FOLDED side. Were it
# sequenced instead, every push would run it twice and only the first would be
# reported as a job.
if output=$(FAKE_CI_LOCAL_FOLDED="ci-stress ci-mutation" run_ci 2>&1); then
	fail "ci-verify absent from CI_LOCAL_FOLDED did not abort the run"
fi
mapfile -t calls < "$log"
[[ ${#calls[@]} -eq 0 && $output == *"ci-verify is not in CI_LOCAL_FOLDED"* ]] \
	|| fail "unfolded ci-verify produced the wrong failure: $output"
checks=$((checks + 1))

printf 'ci-local routing validation: %d checks, 0 failures\n' "$checks"
