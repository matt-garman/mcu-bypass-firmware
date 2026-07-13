#!/usr/bin/env bash

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
CC=${HOSTCC:-cc}
GCOV_TOOL=${GCOV:-gcov}
COVERAGE_ROOT=${COVERAGE_DIR:-$ROOT/coverage}

mkdir -p "$COVERAGE_ROOT"
work=$(mktemp -d "$COVERAGE_ROOT/pic-fw.XXXXXX")
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
    -D_XTAL_FREQ=2000000UL -DBYPASS_MCU_PIC10F322
    -I"$ROOT/test/pic/fw_coverage" -I"$ROOT/test" -I"$ROOT/src"
)

"$CC" "${common[@]}" -include "$ROOT/test/bypass_config_host.h" \
    -c "$ROOT/src/bypass_pure.c" -o "$work/pure.o"

variants=(
    "cd4053:CD4053_SIMPLE:bypass_output_cd4053_simple.c"
    "mute:CD4053_WITH_MUTE:bypass_output_cd4053_with_mute.c"
    "relay:TQ2_L2_5V_RELAY:bypass_output_tq2_l2_5v_relay.c"
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

for profile in pure shell_cd4053 driver_cd4053 driver_mute driver_relay; do
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
    "$work/bypass_mcu_pic10f322.c.gcov"
    "$work/bypass_pure.c.gcov"
    "$work/bypass_output_cd4053_simple.c.gcov"
    "$work/bypass_output_cd4053_with_mute.c.gcov"
    "$work/bypass_output_tq2_l2_5v_relay.c.gcov"
)
"$ROOT/test/pic/fw_coverage/check_fw_coverage.sh" "${annotations[@]}"
