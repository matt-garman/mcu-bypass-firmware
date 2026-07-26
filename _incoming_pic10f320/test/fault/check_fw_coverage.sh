#!/usr/bin/env bash
#
# Firmware line-coverage gate for bypass_mcu_pic10f320.c, driven by the fault +
# happy-path harness (test/fault). Unlike the model coverage gate (a percentage
# floor), this asserts an EXACT property: every firmware line must be covered
# EXCEPT the watchdog-reset fault path, which is uncoverable on the host for two
# documented reasons --
#
#   - hw_force_wdt_reset()'s body deliberately never returns (for (;;) {}). gcov's
#     edge-flow solver cannot credit the lines of a function with no exit, so they
#     read as uncovered even though the harness DOES drive them (fw_fault_run
#     proves the path is taken: the firmware has to be timed out of the spin).
#   - the switch's `default:` case is unreachable while the sanity gate is intact
#     (the gate rejects any out-of-range program_state BEFORE the switch). It is
#     defense-in-depth; the model's equivalent default IS formally proven
#     (test/formal: prove_corrupt_state_faults / verify_corrupt_state_faults).
#
# So those specific lines are allow-listed by their EXACT SOURCE TEXT (robust to
# line renumbering): the `hw_force_wdt_reset()` DEFINITION line, its body
# (`INTCONbits.GIE = 0;`, `for (;;) { }`), the unreachable `default:` label, and
# the `hw_force_wdt_reset();` call statement. gcov's edge-flow solver credits a
# no-exit function poorly, so it marks even the function's signature/opening-brace
# line as uncovered (the harness DOES enter it -- fw_fault_run proves the spin is
# reached -- but the line still reads `#####`); that line is therefore allow-listed
# too. This is deliberately a tight, enumerated list -- NOT a `*hw_force_wdt_reset*`
# wildcard -- so a comment or some future construct that merely mentions the
# function can never be silently waved through. Any OTHER uncovered firmware line
# fails the gate -- that is the regression alarm: a real piece of firmware logic
# lost its test.
#
# Note on the `hw_force_wdt_reset();` text: it appears at TWO call sites -- the
# unreachable `default:` case (legitimately uncovered) AND the live sanity-gate in
# main() (which MUST be covered). They are textually identical, so this allow-list
# necessarily permits both; it cannot, by text alone, tell a regression in the
# live call site apart from the dead one. That is acceptable because the live
# call's coverage is guaranteed INDEPENDENTLY and loudly by test/fault: its eight
# `expect_reset(...)` cases all route through that exact statement, so if it ever
# went uncovered the fault test would fail long before this gate could mask it.
#
# Usage: check_fw_coverage.sh <bypass_mcu_pic10f320.c.gcov>

set -u

GCOV="${1:?usage: check_fw_coverage.sh <firmware.c.gcov>}"
GCOV_SOURCE="$GCOV"
if [ ! -f "$GCOV_SOURCE" ]; then
    echo "FAIL: firmware gcov annotation not found: $GCOV_SOURCE"
    echo "      (gcov must run where the #included firmware source resolves.)"
    exit 1
fi

# Analyze a private snapshot so a concurrent cleanup cannot remove or replace
# the annotation between the existence check and the scans below.
SNAPSHOT=$(mktemp)
trap 'rm -f "$SNAPSHOT"' EXIT
if ! cp -- "$GCOV_SOURCE" "$SNAPSHOT"; then
    echo "FAIL: could not snapshot firmware gcov annotation: $GCOV_SOURCE"
    exit 1
fi
GCOV="$SNAPSHOT"

allowed=0
bad=0

# Walk every uncovered (#####) executable line.
while IFS= read -r rec; do
    lineno=$(printf '%s' "$rec" | awk -F: '{gsub(/[^0-9]/,"",$2); print $2}')
    src=$(printf '%s' "$rec" | cut -d: -f3- | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    case "$src" in
        "default:"|"hw_force_wdt_reset();"|"INTCONbits.GIE = 0;"|"for (;;) { }"|"__attribute__((noreturn)) static void hw_force_wdt_reset(void) {")
            echo "  allow (fault path)   L${lineno}: ${src}"
            allowed=$((allowed + 1))
            ;;
        *)
            echo "  DISALLOWED uncovered L${lineno}: ${src}"
            bad=$((bad + 1))
            ;;
    esac
done < <(grep -E '^[[:space:]]*#####:' "$GCOV")

total=$(grep -cE '^[[:space:]]*([0-9]+|#####):[[:space:]]*[0-9]+:' "$GCOV")
uncov=$(grep -cE '^[[:space:]]*#####:' "$GCOV")

if ! [[ "$total" =~ ^[0-9]+$ && "$uncov" =~ ^[0-9]+$ ]]; then
    echo "FAIL: could not count executable lines in firmware gcov annotation"
    exit 1
fi
covered=$((total - uncov))

if [ "$total" -eq 0 ]; then
    echo "FAIL: firmware gcov annotation contains no executable lines: $GCOV_SOURCE"
    exit 1
fi

echo "firmware line coverage: ${covered}/${total} executable lines (${allowed} allowed-uncovered fault-path line(s), ${bad} disallowed)"

if [ "$bad" -ne 0 ]; then
    echo "FAIL: ${bad} firmware line(s) are uncovered and NOT on the fault-path allowlist."
    echo "      Add a test that exercises them, or -- if they are genuinely"
    echo "      unreachable defensive code -- extend the allowlist in"
    echo "      test/fault/check_fw_coverage.sh with a rationale."
    exit 1
fi

echo "OK: every firmware line is covered except the allowlisted watchdog-reset fault path."
exit 0
