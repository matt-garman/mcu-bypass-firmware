#!/usr/bin/env bash
set -euo pipefail

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
: > "$work/dfp/pic/include/proc/pic10f322.h"
: > "$work/dfp/pic/include/proc/pic10f320.h"
: > "$work/dfp/pic/include/proc/pic12f675.h"
: > "$work/gpsim-inc/sim_context.h"
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
for tool in gpsim cppcheck pkg-config cc clang clang-tidy cbmc gcov python3 gpg avr-objdump; do
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

pic_calls=(
	$'STRICT_TOOLS=1\tpic10f322-test'
	$'STRICT_TOOLS=1\tpic10f322-test-target-variants'
	$'STRICT_TOOLS=1\tpic10f320-test'
	$'STRICT_TOOLS=1\tpic10f320-test-target-variants'
	$'STRICT_TOOLS=1\tpic12f675-test\tpic12f675-test-target-variants\tPIC12F675_DATA_LIMIT=48'
)
xt_calls=(
	$'STRICT_TOOLS=1\tattiny202-test\tXT_STATIC_RAM_LIMIT=16\tXT_STACK_MAX_FRAME=32'
	$'STRICT_TOOLS=1\tattiny202-test-target\tXT_STATIC_RAM_LIMIT=16'
	$'STRICT_TOOLS=1\tattiny202-soak\tXT_SOAK_DURATION_MS=300000\tXT_SOAK_PROGRESS_INTERVAL_MS=300000\tXT_STATIC_RAM_LIMIT=16'
)
build_call=$'STRICT_TOOLS=1\tattiny13a\tattiny85\tattiny45'
strict_stress=$'STRICT_TOOLS=1\ttest-long\tMUTATION_ALLOW_SKIP=0'
pic_partial_stress=$'STRICT_TOOLS=1\ttest-long\tMUTATION_ALLOW_SKIP=PIC'
xt_partial_stress=$'STRICT_TOOLS=1\ttest-long\tMUTATION_ALLOW_SKIP=ATtiny202'
both_partial_stress=$'STRICT_TOOLS=1\ttest-long\tMUTATION_ALLOW_SKIP=PIC,ATtiny202'

if ! output=$(run_ci); then
	fail "push without skips failed: $output"
fi
mapfile -t calls < "$log"
expect_calls "push without skips" "${pic_calls[@]}" "$build_call" \
	"${xt_calls[@]}" "$strict_stress"
[[ "$output" != *"job was skipped"* ]] \
	|| fail "push without skips emitted a skipped-job warning"
[[ "$output" != *"Safe to push"* && "$output" == *"not a full push reproduction"* ]] \
	|| fail "push --no-clean claimed to be a clean push reproduction"
checks=$((checks + 1))

if ! output=$(run_ci_clean); then
	fail "clean push without skips failed: $output"
fi
mapfile -t calls < "$log"
expect_calls "clean push without skips" $'STRICT_TOOLS=1\tclean' \
	"${pic_calls[@]}" "$build_call" "${xt_calls[@]}" "$strict_stress"
[[ "$output" == *"Safe to push"* && "$output" != *"not a full push reproduction"* ]] \
	|| fail "clean push without skips omitted the safe-to-push verdict"
checks=$((checks + 1))

if ! output=$(run_ci --skip-pic); then
	fail "push --skip-pic failed: $output"
fi
mapfile -t calls < "$log"
expect_calls "push --skip-pic" "$build_call" "${xt_calls[@]}" "$pic_partial_stress"
[[ "$output" == *"PIC job was skipped"* && "$output" != *"ATtiny202 job was skipped"* ]] \
	|| fail "push --skip-pic emitted the wrong skipped-job warnings"
[[ "$output" != *"Safe to push"* && "$output" == *"not a full push reproduction"* ]] \
	|| fail "push --skip-pic claimed to be a full push reproduction"
checks=$((checks + 1))

if ! output=$(run_ci --skip-attiny202); then
	fail "push --skip-attiny202 failed: $output"
fi
mapfile -t calls < "$log"
expect_calls "push --skip-attiny202" "${pic_calls[@]}" "$build_call" "$xt_partial_stress"
[[ "$output" == *"ATtiny202 job was skipped"* && "$output" != *"PIC job was skipped"* ]] \
	|| fail "push --skip-attiny202 emitted the wrong skipped-job warnings"
checks=$((checks + 1))

if ! output=$(run_ci --skip-pic --skip-attiny202); then
	fail "push with both target toolchains skipped failed: $output"
fi
mapfile -t calls < "$log"
expect_calls "push with both skips" "$build_call" "$both_partial_stress"
[[ "$output" == *"PIC job was skipped"* && "$output" == *"ATtiny202 job was skipped"* ]] \
	|| fail "push with both skips omitted a skipped-job warning"
checks=$((checks + 1))

if ! output=$(run_ci --pr --skip-pic --skip-attiny202); then
	fail "PR with both skips routing failed: $output"
fi
mapfile -t calls < "$log"
[ "${#calls[@]}" -eq 2 ] \
	|| fail "PR with both skips executed ${#calls[@]} Make commands, expected 2"
[ "${calls[0]}" = $'STRICT_TOOLS=1\tattiny13a\tattiny85\tattiny45' ] \
	&& [ "${calls[1]}" = $'STRICT_TOOLS=1\ttest' ] \
	|| fail "PR with both skips did not route the strict non-mutation suite"
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

printf 'ci-local routing validation: %d checks, 0 failures\n' "$checks"
