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

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
CC=${HOSTCC:-cc}
GCOV_TOOL=${GCOV:-gcov}
COVERAGE_ROOT=${COVERAGE_DIR:-$ROOT/coverage}

if [ "$#" -ne 1 ]; then
    echo "usage: run_fw_coverage.sh <pic10f322|pic12f675>" >&2
    exit 2
fi
device=$1
case "$device" in
    pic10f322)
        device_flags=(-D_XTAL_FREQ=2000000UL -DBYPASS_MCU_PIC10F322)
        shell_annotation=bypass_mcu_pic10f322.c.gcov
        shell_profile=shell_tq2_l2_5v_relay
        ;;
    pic12f675)
        device_flags=(-D_XTAL_FREQ=4000000UL -DBYPASS_MCU_PIC12F675)
        shell_annotation=bypass_mcu_pic12f675.c.gcov
        shell_profile=shell_tq2_l2_5v_relay
        ;;
    *)
        echo "FAIL: unsupported PIC firmware coverage device: $device" >&2
        exit 2
        ;;
esac

mkdir -p "$COVERAGE_ROOT"
work=$(mktemp -d "$COVERAGE_ROOT/$device-fw.XXXXXX")
cleanup() {
    if [ "${PIC_FW_COVERAGE_KEEP:-0}" = 1 ]; then
        echo "PIC firmware coverage artifacts kept at $work"
    else
        rm -rf "$work"
    fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

common=(
    -std=c11 -O0 -Wall -Wextra -Werror -Wconversion
    -fshort-enums -funsigned-char --coverage
    "${device_flags[@]}"
    # Both parts SHIP with F2's context check on -- the Makefile's
    # BYPASS_CTX_CHECK_FLAG is unconditional -- so measure that configuration.
    # Without it the shell's check clause compiles out, debounce_ctx_check_word()
    # becomes dead code, and this gate silently stops covering the real firmware.
    -DBYPASS_CTX_CHECK
    -I"$ROOT/test/pic/fw_coverage" -I"$ROOT/test" -I"$ROOT/src"
)

"$CC" "${common[@]}" -include "$ROOT/test/bypass_config_host.h" \
    -c "$ROOT/src/bypass_pure.c" -o "$work/pure.o"

variants=(
    "cd4053_simple:CD4053_SIMPLE:bypass_output_cd4053_simple.c"
    "cd4053_with_mute:CD4053_WITH_MUTE:bypass_output_cd4053_with_mute.c"
    "tq2_l2_5v_relay:TQ2_L2_5V_RELAY:bypass_output_tq2_l2_5v_relay.c"
)

for spec in "${variants[@]}"; do
    IFS=: read -r variant macro driver <<< "$spec"
    "$CC" "${common[@]}" -Wno-unknown-pragmas -Wno-attributes \
        -Dmain=fw_main -D"$macro" \
        -c "$ROOT/test/pic/fw_coverage/fw_coverage_harness.c" \
        -o "$work/shell_$variant.o"
    "$CC" "${common[@]}" -D"$macro" \
        -c "$ROOT/src/$driver" -o "$work/driver_$variant.o"
    "$CC" "${common[@]}" -D"$macro" \
        -c "$ROOT/test/pic/fw_coverage/test_fw_coverage.c" \
        -o "$work/test_$variant.o"
    "$CC" --coverage "$work/shell_$variant.o" "$work/driver_$variant.o" \
        "$work/test_$variant.o" "$work/pure.o" -o "$work/test_$variant"
    "$work/test_$variant"
done

for profile in pure "$shell_profile" driver_cd4053_simple \
		driver_cd4053_with_mute driver_tq2_l2_5v_relay; do
    if [ ! -f "$work/$profile.gcda" ] || [ ! -s "$work/$profile.gcda" ]; then
        echo "FAIL: missing fresh PIC firmware profile: $profile.gcda" >&2
        exit 1
    fi
    out=$(cd "$work" && "$GCOV_TOOL" -o . "$profile.o" 2>&1) || {
        printf '%s\n' "$out" >&2
        echo "FAIL: gcov failed for $profile.o" >&2
        exit 1
    }
done

annotations=(
    "$work/$shell_annotation"
    "$work/bypass_pure.c.gcov"
    "$work/bypass_output_cd4053_simple.c.gcov"
    "$work/bypass_output_cd4053_with_mute.c.gcov"
    "$work/bypass_output_tq2_l2_5v_relay.c.gcov"
)
"$ROOT/test/pic/fw_coverage/check_fw_coverage.sh" "${annotations[@]}"

# The PIC12F675 oracle asserts more than line coverage: the res.fault reset call
# must remain unreachable because the earlier context range gate dominates it.
# Turn that exact gcov record into a covered line and require the unchanged
# checker to reject the resulting contradiction.
#
# The record is located the way the checker locates it -- by source text, from
# the annotation itself -- so a shell edit that renumbers the main loop cannot
# leave this probe flipping a line that no longer holds the call, which would
# make it pass vacuously against a gate that is no longer being tested.
if [ "$device" = pic12f675 ]; then
    probe_dir="$work/oracle-probe"
    mkdir "$probe_dir"
    probe="$probe_dir/$shell_annotation"
    probe_recs=$(grep -E '^[[:space:]]*#####:[[:space:]]*[0-9]+:[[:space:]]*hw_force_wdt_reset\(\);[[:space:]]*$' \
        "$work/$shell_annotation" || true)
    probe_count=$(printf '%s' "$probe_recs" | grep -c . || true)
    if [ "$probe_count" -ne 1 ]; then
        echo "FAIL: PIC12F675 coverage-oracle probe expects exactly one uncovered" >&2
        echo "      hw_force_wdt_reset() call record, found $probe_count" >&2
        exit 1
    fi
    probe_line=$(printf '%s' "$probe_recs" | awk -F: '{gsub(/[^0-9]/,"",$2); print $2}')
    sed -E "s/^([[:space:]]*)#####([[:space:]]*:[[:space:]]*$probe_line:)/\1        1\2/" \
        "$work/$shell_annotation" > "$probe"
    if ! grep -Eq "^[[:space:]]*1:[[:space:]]*$probe_line:" "$probe"; then
        echo "FAIL: PIC12F675 coverage-oracle probe did not alter source line $probe_line" >&2
        exit 1
    fi
    if "$ROOT/test/pic/fw_coverage/check_fw_coverage.sh" "$probe" >/dev/null 2>&1; then
        echo "FAIL: PIC12F675 coverage oracle accepted a reachable res.fault reset call" >&2
        exit 1
    fi
    echo "PIC12F675 coverage-oracle negative probe: PASS (source line $probe_line)"
fi
