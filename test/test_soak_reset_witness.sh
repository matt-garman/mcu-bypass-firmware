#!/usr/bin/env bash
#
# Proof that the Classic AVR soak's watchdog witness is load-bearing.
#
# The soak reports `watchdog_failures=N` in the SOAK_RESULT record that release
# qualification checks (scripts/verify-release-qualification.sh). That number is
# evidence only if a real watchdog reset can actually reach it. This gate proves
# it can, end to end, on the same healthy ATtiny85 image the release soaks use:
#
#   control  -- the soak exactly as released: must PASS, watchdog_failures=0,
#               and emit no SOAK FAIL line
#   injected -- the same soak plus -DSOAK_SELFTEST_KILL_TIMER_MS, which disables
#               the Timer0 compare interrupt mid-run so the main loop stops
#               petting the dog: must FAIL, with watchdog_failures >= 1
#
# Both halves are required. Without the control run a permanently broken soak
# would satisfy the failing half on its own; without the injected run a soak
# that cannot observe a reset reports watchdog_failures=0 forever and looks
# identical to a healthy one -- which is exactly the defect this test was
# written for.
#
# tinyx5 only: simavr models the WDT system reset for the ATtiny25/45/85 family
# and not for the ATtiny13a (see the watchdog backstop tests in test_sim.c).
#
# Driven by `make test-soak-reset-witness`, which supplies every SOAK_WITNESS_*
# input below.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HOSTCC=${HOSTCC:-cc}
: "${SOAK_WITNESS_CFLAGS:?compiler flags for the soak driver}"
: "${SOAK_WITNESS_LIBS:?simulator libraries for the soak driver}"
: "${SOAK_WITNESS_MACRO:?output-variant selector macro}"
: "${SOAK_WITNESS_FW:?path to the firmware ELF under soak}"
: "${SOAK_WITNESS_MCU:?simavr MCU name}"
: "${SOAK_WITNESS_F_CPU:?MCU clock in Hz}"
: "${SOAK_WITNESS_DURATION_MS:?soak duration in ms}"
: "${SOAK_WITNESS_LIVENESS_MS:?liveness interval in ms}"
: "${SOAK_WITNESS_KILL_TIMER_MS:?timer-kill offset in ms}"

checks=0
work=$(mktemp -d "${TMPDIR:-/tmp}/soak-reset-witness.XXXXXX")
trap 'rm -rf "$work"' EXIT

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

[ -f "$ROOT/$SOAK_WITNESS_FW" ] \
	|| fail "firmware image not built: $SOAK_WITNESS_FW"

# The fixture must never be reachable from a real soak. Every soak binary the
# project ships is compiled by SOAK_COMPILE, so a leaked define could only come
# from the Makefile -- assert that rather than trusting the header's default.
if grep -q -- '-DSOAK_SELFTEST' "$ROOT/Makefile"; then
	fail "a Makefile recipe defines the soak self-test hook"
fi
checks=$((checks + 1))

# $1 = output binary, remaining args = extra -D flags.
build_soak() {
	local out=$1
	shift
	local -a compiler cflags libs
	read -r -a compiler <<<"$HOSTCC"
	read -r -a cflags <<<"$SOAK_WITNESS_CFLAGS"
	read -r -a libs <<<"$SOAK_WITNESS_LIBS"
	[ "${#compiler[@]}" -gt 0 ] || fail "empty compiler command"
	(cd "$ROOT" && "${compiler[@]}" "${cflags[@]}" \
		"-D$SOAK_WITNESS_MACRO" -Itest \
		"-DFW_PATH=\"$SOAK_WITNESS_FW\"" \
		"-DMCU_NAME=\"$SOAK_WITNESS_MCU\"" \
		"-DF_CPU_HZ=$SOAK_WITNESS_F_CPU" \
		-DTARGET_TINYX5 \
		"-DSOAK_DURATION_MS=$SOAK_WITNESS_DURATION_MS" \
		"-DSOAK_LIVENESS_INTERVAL_MS=$SOAK_WITNESS_LIVENESS_MS" \
		"-DSOAK_PROGRESS_INTERVAL_MS=$SOAK_WITNESS_DURATION_MS" \
		'-DSOAK_COMBINATION_NAME="reset-witness"' \
		"$@" \
		test/avr/test_soak.c -o "$out" "${libs[@]}") \
		|| fail "could not build the soak driver ($out)"
}

# Read one field out of the single SOAK_RESULT record in $1 into RESULT_FIELD.
# A missing or duplicated record is itself a failure: every later assertion
# reads this record, so it must be unambiguous before any of them run.
RESULT_FIELD=
result_field() {
	local log=$1 field=$2 count
	local -a records=()
	mapfile -t records < <(grep '^SOAK_RESULT ' "$log" || true)
	count=${#records[@]}
	[ "$count" -eq 1 ] \
		|| fail "expected exactly one SOAK_RESULT record in $log; found $count"
	RESULT_FIELD=$(printf '%s\n' "${records[0]}" | tr ' ' '\n' \
		| sed -n "s/^$field=//p")
	[ -n "$RESULT_FIELD" ] || fail "SOAK_RESULT in $log has no $field field"
}

expected_checks=$((SOAK_WITNESS_DURATION_MS / SOAK_WITNESS_LIVENESS_MS))

# --- control: the soak exactly as released ----------------------------------
build_soak "$work/soak_control"
checks=$((checks + 1))
control_status=0
"$work/soak_control" > "$work/control.log" 2>&1 || control_status=$?
[ "$control_status" -eq 0 ] \
	|| fail "healthy control soak exited $control_status (expected 0)"
checks=$((checks + 1))

result_field "$work/control.log" status
[ "$RESULT_FIELD" = pass ] || fail "healthy control soak reported status=$RESULT_FIELD"
checks=$((checks + 1))
result_field "$work/control.log" watchdog_failures
[ "$RESULT_FIELD" = 0 ] \
	|| fail "healthy control soak reported watchdog_failures=$RESULT_FIELD"
checks=$((checks + 1))
result_field "$work/control.log" failures
[ "$RESULT_FIELD" = 0 ] || fail "healthy control soak reported failures=$RESULT_FIELD"
checks=$((checks + 1))
result_field "$work/control.log" checks
[ "$RESULT_FIELD" = "$expected_checks" ] \
	|| fail "healthy control soak ran $RESULT_FIELD liveness checks; expected $expected_checks"
checks=$((checks + 1))
if grep -q '^SOAK FAIL' "$work/control.log"; then
	fail "healthy control soak logged a SOAK FAIL line"
fi
checks=$((checks + 1))

# --- injected: same image, timer interrupt disabled mid-run -----------------
build_soak "$work/soak_injected" \
	"-DSOAK_SELFTEST_KILL_TIMER_MS=$SOAK_WITNESS_KILL_TIMER_MS"
checks=$((checks + 1))
injected_status=0
"$work/soak_injected" > "$work/injected.log" 2>&1 || injected_status=$?
[ "$injected_status" -ne 0 ] \
	|| fail "soak passed with the watchdog left un-pet (the reset went unwitnessed)"
checks=$((checks + 1))

result_field "$work/injected.log" status
[ "$RESULT_FIELD" = fail ] || fail "un-pet soak reported status=$RESULT_FIELD"
checks=$((checks + 1))

result_field "$work/injected.log" watchdog_failures
injected_wdt=$RESULT_FIELD
[[ $injected_wdt =~ ^(0|[1-9][0-9]*)$ ]] \
	|| fail "un-pet soak reported a malformed watchdog_failures: $injected_wdt"
checks=$((checks + 1))
[ "$injected_wdt" -ge 1 ] \
	|| fail "un-pet soak recorded watchdog_failures=$injected_wdt; the machine record must carry the reset"
checks=$((checks + 1))

result_field "$work/injected.log" failures
[ "$RESULT_FIELD" -ge "$injected_wdt" ] \
	|| fail "un-pet soak total failures ($RESULT_FIELD) omits its $injected_wdt watchdog failure(s)"
checks=$((checks + 1))

grep -q '^SOAK FAIL .*unexpected device reset' "$work/injected.log" \
	|| fail "un-pet soak did not log the reset it counted"
checks=$((checks + 1))
grep -q "^SOAK FAIL: $SOAK_WITNESS_DURATION_MS ms " "$work/injected.log" \
	|| fail "un-pet soak did not run the full duration before failing"
checks=$((checks + 1))

printf 'soak reset witness: %d checks, 0 failures (un-pet run recorded %s reset(s))\n' \
	"$checks" "$injected_wdt"
