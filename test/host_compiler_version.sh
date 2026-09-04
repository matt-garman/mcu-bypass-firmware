#!/usr/bin/env bash
#
# Shared minimum-version contract for the repository's host C compiler gates.
# The Python counterpart is test/python_version.py.
#
# Every host gate that compiles C natively does so with -Werror -Wconversion
# (Makefile HOST_CFLAGS, and the PIC shipping-source coverage runners under
# test/pic/fw_coverage). GCC 9 and older emit a FALSE narrowing diagnostic on
# the PIC10F322 shell's OR-folded integrity checks: they fold an explicit
# (uint8_t) cast away whenever the operand provably fits in eight bits -- a
# narrow bitfield read, or a read masked with a small constant -- and then
# blame the compound assignment that writes the folded result back. GCC 10
# (2020) stopped doing that. The firmware is correct under both; only the
# diagnostic is wrong, and silencing it in the source costs PIC10F322 flash
# that the 512-word cd4053_with_mute variant cannot spare.
#
# The gate is the PROBE below, not the version number: a compiler is supported
# if it accepts the construct, whatever it calls itself. MINIMUM_GCC is what
# the diagnostic tells the user to install, and what README.md and
# TOOLCHAIN.adoc publish.

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

# First GCC that reports this construct correctly. Published in README.md and
# TOOLCHAIN.adoc; test/test_release_preflight.sh holds the three in agreement.
MINIMUM_GCC=10

usage() {
    echo "usage: host_compiler_version.sh [compiler]" >&2
    exit 2
}

[ "$#" -le 1 ] || usage
CC=${1:-${HOSTCC:-cc}}

if ! command -v "$CC" >/dev/null 2>&1; then
    echo "FAIL: host C compiler '$CC' was not found; the repository host gates" \
         "cannot run without one. Install GCC $MINIMUM_GCC or newer (or Clang)," \
         "or set HOSTCC to a compiler that is installed." >&2
    exit 1
fi

# Vendor and version, for the diagnostic only. Clang defines __GNUC__ too, so
# it has to be tested first. A compiler that cannot preprocess this is still
# judged by the probe; it just gets described as "unknown".
describe_compiler() {
    printf '%s\n' \
        '#if defined(__clang__)' \
        'clang|__clang_major__.__clang_minor__.__clang_patchlevel__' \
        '#elif defined(__GNUC__)' \
        'gcc|__GNUC__.__GNUC_MINOR__.__GNUC_PATCHLEVEL__' \
        '#else' \
        'unknown|0.0.0' \
        '#endif' \
        | "$CC" -E -P -x c - 2>/dev/null \
        | tr -d '[:space:]' \
        | grep -m 1 '|' \
        || echo 'unknown|0.0.0'
}

work=$(mktemp -d "${TMPDIR:-/tmp}/host-cc-floor.XXXXXX")
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# The two folding paths that GCC 9 gets wrong, in the shape the PIC shells use:
# a narrow bitfield read, and a byte read masked with a small constant, each
# cast to uint8_t and OR-accumulated. The SFR mocks are deliberately NOT
# volatile, matching test/pic/fw_coverage/xc.h -- volatile suppresses the fold
# and would make this probe vacuous.
cat > "$work/probe.c" <<'PROBE'
#include <stdint.h>

typedef struct { unsigned field : 3; } probe_bits_t;

extern probe_bits_t probe_sfr_bits;
extern uint8_t      probe_sfr_byte;

uint8_t probe_fold(void);

uint8_t probe_fold(void) {
    uint8_t diff = 0U;

    diff |= (uint8_t)(0x04U ^ (uint8_t)probe_sfr_bits.field);
    diff |= (uint8_t)(probe_sfr_byte & 0x07U);

    return (uint8_t)((0U == diff) ? 1U : 0U);
}
PROBE

# Mirrors the strict set every host gate compiles firmware under: HOST_CFLAGS
# plus the two character/enum flags the PIC coverage runners add.
PROBE_CFLAGS=(-std=c11 -O0 -Wall -Wextra -Werror -Wconversion
              -fshort-enums -funsigned-char)

if "$CC" "${PROBE_CFLAGS[@]}" -c "$work/probe.c" -o "$work/probe.o" \
        > "$work/probe.log" 2>&1; then
    exit 0
fi

description=$(describe_compiler)
vendor=${description%%|*}
version=${description#*|}

{
    echo "FAIL: GCC $MINIMUM_GCC or newer (or Clang) is required by the" \
         "repository host gates; found $vendor $version at" \
         "$(command -v "$CC")."
    echo "      It rejects a value-preserving narrowing that the PIC shells" \
         "rely on, so every -Wconversion host gate over shipping firmware" \
         "sources fails on this compiler:"
    sed 's/^/        /' "$work/probe.log"
    echo "      Install GCC $MINIMUM_GCC or newer (or any Clang) and either put" \
         "it first on PATH or select it explicitly, e.g. HOSTCC=gcc-$MINIMUM_GCC."
} >&2
exit 1
