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

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-$HOME}/test-stack-bound.XXXXXX")
trap 'rm -rf "$work"' EXIT
tools="$work/tools"
build="$work/build"
xt_build="$work/xt-build"
dfp="$work/dfp"
mkdir -p "$tools" "$build" "$xt_build" \
	"$dfp/gcc/dev/attiny202/device-specs" "$dfp/include/avr"
: > "$dfp/gcc/dev/attiny202/device-specs/specs-attiny202"
: > "$dfp/include/avr/iotn202.h"
checks=0
log="$work/compile.log"
args_log="$work/compile-args.log"
unset FAKE_STACK_MODE FAKE_STACK_LOG FAKE_STACK_ARGS_LOG TEST_STACK_MAX
unset TEST_DFP STRICT_TOOLS

cat > "$tools/cc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = --version ]; then printf 'fake avr-gcc 1\n'; exit 0; fi
original_args=$*
out=
source_file= macro=
while [ "$#" -gt 0 ]; do
	case "$1" in
		-o) out=$2; shift 2 ;;
		-D*) macro=${1#-D}; shift ;;
		*.c) source_file=$1; shift ;;
		*) shift ;;
	esac
done
[ -n "$out" ] || exit 2
[ -z "${FAKE_STACK_LOG:-}" ] || printf '%s\t%s\n' "$source_file" "$macro" >> "$FAKE_STACK_LOG"
[ -z "${FAKE_STACK_ARGS_LOG:-}" ] || printf '%s\n' "$original_args" >> "$FAKE_STACK_ARGS_LOG"
su=${out%.o}.su
mode=${FAKE_STACK_MODE:-pass}
if [ "$mode" = compile_fail ]; then exit 1; fi
if [ "$mode" = no_output ]; then exit 0; fi
if [ "$mode" != no_obj ]; then printf 'object\n' > "$out"; fi
case "$mode" in
	no_su) ;;
	empty_su) : > "$su" ;;
	malformed) printf 'not a stack record\n' > "$su" ;;
	nonnumeric) printf 'fake.c:1:1:fake\tunknown\tstatic\n' > "$su" ;;
	dynamic) printf 'fake.c:1:1:fake\t8\tdynamic\n' > "$su" ;;
	over) printf 'fake.c:1:1:fake\t64\tstatic\n' > "$su" ;;
	huge) printf 'fake.c:1:1:fake\t9007199254740993\tstatic\n' > "$su" ;;
	*) printf 'fake.c:1:1:fake\t8\tstatic\n' > "$su" ;;
esac
if [ "$mode" = extra_su ]; then
	printf 'extra.c:1:1:extra\t8\tstatic\n' > "$(dirname "$out")/stack_unexpected.su"
fi
if [ "$mode" = extra_obj ]; then printf 'extra object\n' > "$(dirname "$out")/stack_unexpected.o"; fi
EOF
chmod 750 "$tools/cc"

run_gate() {
	local -a policy=()
	[ -z "${TEST_STACK_MAX+x}" ] \
		|| policy+=("AVR_STACK_MAX_FRAME=$TEST_STACK_MAX")
	make --no-print-directory -C "$ROOT" test-stack-bound \
		AVR_STACK_BUILD_DIR="$build" CC="$tools/cc" "${policy[@]}" "$@"
}

run_gate_private() {
	local -a policy=()
	[ -z "${TEST_STACK_MAX+x}" ] \
		|| policy+=("AVR_STACK_MAX_FRAME=$TEST_STACK_MAX")
	make --no-print-directory -C "$ROOT" test-stack-bound \
		CC="$tools/cc" "${policy[@]}"
}

run_xt_gate() {
	local -a policy=()
	[ -z "${TEST_STACK_MAX+x}" ] \
		|| policy+=("XT_STACK_MAX_FRAME=$TEST_STACK_MAX")
	make --no-print-directory -C "$ROOT" attiny202-test-stack-bound \
		XT_STACK_BUILD_DIR="$xt_build" XT_DFP="${TEST_DFP-$dfp}" \
		CC="$tools/cc" "${policy[@]}" "$@"
}

seed_stale() {
	: > "$log"
	printf 'stale object\n' > "$build/stack_stale.o"
	printf 'stale.c:1:1:stale\t1\tstatic\n' > "$build/stack_stale.su"
}

assert_clean() {
	local -a artifacts
	shopt -s nullglob
	artifacts=("$build"/stack_*.o "$build"/stack_*.su)
	shopt -u nullglob
	[ "${#artifacts[@]}" -eq 0 ] \
		|| { printf 'FAIL: %s left stack artifacts\n' "$1" >&2; exit 1; }
}

seed_xt_stale() {
	: > "$log"
	: > "$args_log"
	printf 'stale object\n' > "$xt_build/stack_stale.o"
	printf 'stale.c:1:1:stale\t1\tstatic\n' > "$xt_build/stack_stale.su"
}

assert_xt_clean() {
	local -a artifacts
	shopt -s nullglob
	artifacts=("$xt_build"/stack_*.o "$xt_build"/stack_*.su)
	shopt -u nullglob
	[ "${#artifacts[@]}" -eq 0 ] \
		|| { printf 'FAIL: %s left AVR-XT stack artifacts\n' "$1" >&2; exit 1; }
}

expect_failure() {
	local label=$1 expected=$2 output
	shift 2
	seed_stale
	if output=$(export "$@"; run_gate 2>&1); then
		printf 'FAIL: %s was accepted\n' "$label" >&2
		exit 1
	fi
	[[ "$output" == *"$expected"* ]] \
		|| { printf 'FAIL: %s failed for the wrong reason: %s\n' "$label" "$output" >&2; exit 1; }
	assert_clean "$label"
	checks=$((checks + 1))
}

expect_xt_failure() {
	local label=$1 expected=$2 output
	shift 2
	seed_xt_stale
	if output=$(export "$@"; run_xt_gate 2>&1); then
		printf 'FAIL: %s was accepted\n' "$label" >&2
		exit 1
	fi
	[[ "$output" == *"$expected"* ]] \
		|| { printf 'FAIL: %s failed for the wrong reason: %s\n' "$label" "$output" >&2; exit 1; }
	assert_xt_clean "$label"
	checks=$((checks + 1))
}

seed_stale
output=$(export FAKE_STACK_LOG="$log"; run_gate VARIANTS=cd4053_simple VARIANT=tq2_l2_5v_relay \
	AVR_STACK_SOURCES=src/bypass_pure.c CORE_SRC=src/bypass_pure.c \
	src_cd4053=src/bypass_pure.c src_mute=src/bypass_pure.c \
	src_relay=src/bypass_pure.c)
[[ "$output" == *"OK: 5 fresh reports"* ]] \
	|| { printf 'FAIL: valid reports did not produce the expected verdict\n' >&2; exit 1; }
expected_matrix=$'src/bypass_mcu_avr_classic.c\tCD4053_SIMPLE\nsrc/bypass_output_cd4053_simple.c\tCD4053_SIMPLE\nsrc/bypass_output_cd4053_with_mute.c\tCD4053_WITH_MUTE\nsrc/bypass_output_tq2_l2_5v_relay.c\tTQ2_L2_5V_RELAY\nsrc/bypass_pure.c\tCD4053_SIMPLE'
actual_matrix=$(LC_ALL=C sort "$log")
[[ "$actual_matrix" == "$expected_matrix" ]] \
	|| { printf 'FAIL: wrong stack compile matrix:\n%s\n' "$actual_matrix" >&2; exit 1; }
assert_clean "successful gate"
checks=$((checks + 1))

FAKE_STACK_LOG= run_gate_private >/dev/null & pid1=$!
FAKE_STACK_LOG= run_gate_private >/dev/null & pid2=$!
wait "$pid1" && wait "$pid2" \
	|| { printf 'FAIL: concurrent private stack gates interfered\n' >&2; exit 1; }
checks=$((checks + 1))

expect_failure "compiler failure" "compilation error" FAKE_STACK_MODE=compile_fail
expect_failure "successful compiler with no output" "produced no stack-check object" FAKE_STACK_MODE=no_output
expect_failure "missing object" "produced no stack-check object" FAKE_STACK_MODE=no_obj
expect_failure "missing report" "produced no stack-usage report" FAKE_STACK_MODE=no_su
expect_failure "empty report" "produced no stack-usage report" FAKE_STACK_MODE=empty_su
expect_failure "malformed report" "invalid stack-usage record" FAKE_STACK_MODE=malformed
expect_failure "nonnumeric frame" "invalid stack-usage record" FAKE_STACK_MODE=nonnumeric
expect_failure "dynamic frame" "invalid stack-usage record" FAKE_STACK_MODE=dynamic
expect_failure "oversized frame" "frame exceeds 32 B" FAKE_STACK_MODE=over
expect_failure "adjacent huge frame" "frame exceeds 9007199254740992 B" \
	FAKE_STACK_MODE=huge TEST_STACK_MAX=9007199254740992
expect_failure "unexpected extra report" "expected 5 stack-usage reports" FAKE_STACK_MODE=extra_su
expect_failure "unexpected extra object" "expected 5 stack-check objects" FAKE_STACK_MODE=extra_obj
expect_failure "zero frame limit" "positive decimal integer" TEST_STACK_MAX=0
expect_failure "malformed frame limit" "positive decimal integer" TEST_STACK_MAX=invalid

# The AVR-XT gate is a production matrix, not a caller-selected development
# subset. It must compile only the shipping shell, once under each selector,
# with the same flags used by the image build plus -fstack-usage.
seed_xt_stale
output=$(export FAKE_STACK_LOG="$log" FAKE_STACK_ARGS_LOG="$args_log"; \
	run_xt_gate VARIANTS=cd4053_simple XT_VARIANTS_SUPPORTED=bogus)
[[ "$output" == *"OK: 3 fresh AVR-XT reports"* ]] \
	|| { printf 'FAIL: valid AVR-XT reports did not produce the expected verdict\n' >&2; exit 1; }
expected_xt_matrix=$'src/bypass_mcu_avr_xt.c\tCD4053_SIMPLE\nsrc/bypass_mcu_avr_xt.c\tCD4053_WITH_MUTE\nsrc/bypass_mcu_avr_xt.c\tTQ2_L2_5V_RELAY'
actual_xt_matrix=$(LC_ALL=C sort "$log")
[[ "$actual_xt_matrix" == "$expected_xt_matrix" ]] \
	|| { printf 'FAIL: wrong AVR-XT stack compile matrix:\n%s\n' "$actual_xt_matrix" >&2; exit 1; }
expected_common="-DF_CPU=2000000UL -DBYPASS_MCU_AVR_XT -mmcu=attiny202 -B $dfp/gcc/dev/attiny202 -I $dfp/include -Os -fshort-enums -funsigned-char -ffunction-sections -fdata-sections -Werror -Wall -Wextra -Wconversion -std=c11 -DBYPASS_CTX_CHECK"
for variant in cd4053_simple cd4053_with_mute tq2_l2_5v_relay; do
	case "$variant" in
		cd4053_simple) macro=CD4053_SIMPLE ;;
		cd4053_with_mute) macro=CD4053_WITH_MUTE ;;
		tq2_l2_5v_relay) macro=TQ2_L2_5V_RELAY ;;
	esac
	expected_args="$expected_common -D$macro -fstack-usage -c src/bypass_mcu_avr_xt.c -o $xt_build/stack_xt_$variant.o"
	grep -Fqx -- "$expected_args" "$args_log" \
		|| { printf 'FAIL: AVR-XT %s stack compile did not use exact shipping flags\n' "$variant" >&2; exit 1; }
done
[ "$(wc -l < "$args_log")" -eq 3 ] \
	|| { printf 'FAIL: AVR-XT stack matrix issued an unexpected number of compiler commands\n' >&2; exit 1; }
assert_xt_clean "successful AVR-XT gate"
checks=$((checks + 1))

# This target belongs to the full-tool ATtiny202 aggregate only. The ordinary
# host TEST_GATES inventory exercises this fake regression, not the real DFP
# compile itself.
ordinary_gates=$(make --no-print-directory -s -C "$ROOT" print-TEST_GATES CC="$tools/cc")
case " $ordinary_gates " in
	*" attiny202-test-stack-bound "*)
		printf 'FAIL: AVR-XT real-tool stack gate leaked into ordinary TEST_GATES\n' >&2
		exit 1 ;;
esac
attiny202_rule=$(make --no-print-directory -np -C "$ROOT" attiny202-test \
	CC="$tools/cc" 2>/dev/null | awk '/^attiny202-test:/ && !found { print; found = 1 }')
case " $attiny202_rule " in
	*" attiny202-test-stack-bound "*) ;;
	*) printf 'FAIL: attiny202-test does not route through attiny202-test-stack-bound\n' >&2
		exit 1 ;;
esac
checks=$((checks + 1))

seed_xt_stale
output=$(export TEST_DFP="$work/missing-dfp" FAKE_STACK_LOG="$log"; \
	run_xt_gate STRICT_TOOLS= 2>&1) \
	|| { printf 'FAIL: absent DFP did not skip AVR-XT stack gate cleanly: %s\n' "$output" >&2; exit 1; }
[[ "$output" == *"skipping ATtiny202 stack bound"* ]] \
	|| { printf 'FAIL: absent DFP stack skip missing its reason: %s\n' "$output" >&2; exit 1; }
[ ! -s "$log" ] || { printf 'FAIL: absent DFP stack skip invoked the compiler\n' >&2; exit 1; }
assert_xt_clean "absent DFP AVR-XT stack skip"
checks=$((checks + 1))

seed_xt_stale
if output=$(export TEST_DFP="$work/missing-dfp"; run_xt_gate STRICT_TOOLS=1 2>&1); then
	printf 'FAIL: absent DFP under STRICT_TOOLS=1 did not fail AVR-XT stack gate\n' >&2
	exit 1
fi
[[ "$output" == *"STRICT_TOOLS=1"* ]] \
	|| { printf 'FAIL: strict absent-DFP stack failure had the wrong reason: %s\n' "$output" >&2; exit 1; }
assert_xt_clean "absent DFP strict AVR-XT stack gate"
checks=$((checks + 1))

expect_xt_failure "malformed AVR-XT report" "invalid stack-usage record" FAKE_STACK_MODE=malformed
expect_xt_failure "dynamic AVR-XT frame" "invalid stack-usage record" FAKE_STACK_MODE=dynamic
expect_xt_failure "oversized AVR-XT frame" "frame exceeds 32 B" FAKE_STACK_MODE=over

printf 'stack-bound gate validation: %d checks, 0 failures\n' "$checks"
