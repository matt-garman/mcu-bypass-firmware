#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HEADER="$ROOT/test/soak_timing_config.h"
RELEASE="$ROOT/scripts/make-release.sh"
HOSTCC=${HOSTCC:-cc}
HOSTCXX=${HOSTCXX:-c++}
checks=0

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

compile_config() {
	local compiler_string=$1 language=$2 duration=$3 liveness=$4 progress=$5 standard
	local -a compiler
	read -r -a compiler <<<"$compiler_string"
	[ "${#compiler[@]}" -gt 0 ] || fail "empty compiler command for $language"
	if [ "$language" = c ]; then standard=c11; else standard=c++17; fi
	printf '#define SOAK_DURATION_MS %s\n#define SOAK_LIVENESS_INTERVAL_MS %s\n#define SOAK_PROGRESS_INTERVAL_MS %s\n#include "%s"\n' \
		"$duration" "$liveness" "$progress" "$HEADER" \
		| "${compiler[@]}" -std="$standard" -Wall -Wextra -Werror \
			-x "$language" -fsyntax-only - >/dev/null 2>&1
}

expect_compile_pass() {
	local compiler=$1 language=$2 duration=$3 liveness=$4 progress=$5
	compile_config "$compiler" "$language" "$duration" "$liveness" "$progress" \
		|| fail "$language rejected valid timing: $duration/$liveness/$progress"
	checks=$((checks + 1))
}

expect_compile_fail() {
	local compiler=$1 language=$2 duration=$3 liveness=$4 progress=$5
	if compile_config "$compiler" "$language" "$duration" "$liveness" "$progress"; then
		fail "$language accepted invalid timing: $duration/$liveness/$progress"
	fi
	checks=$((checks + 1))
}

expect_release_reject() {
	local value=$1 expected=$2 output
	if output=$("$RELEASE" --soak-duration-ms "$value" v99.0.0 2>&1); then
		fail "release accepted invalid duration: $value"
	fi
	[[ "$output" == *"$expected"* ]] \
		|| fail "release rejected '$value' for the wrong reason: $output"
	checks=$((checks + 1))
}

expect_release_version_reject() {
	local value=$1 expected=${2:-is not vX.Y.Z} output
	if output=$("$RELEASE" "$value" 2>&1); then
		fail "release accepted invalid version: $value"
	fi
	[[ "$output" == *"$expected"* ]] \
		|| fail "release rejected version '$value' for the wrong reason: $output"
	checks=$((checks + 1))
}

expect_release_range_pass() {
	local mode=$1 value=$2 output tmp
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/soak-timing.XXXXXX")
	if [ "$mode" = dry ]; then
		output=$(cd "$tmp" && "$RELEASE" --dry-run --soak-duration-ms "$value" v99.0.0 2>&1) || true
	else
		output=$(cd "$tmp" && "$RELEASE" --soak-duration-ms "$value" v99.0.0 2>&1) || true
	fi
	rm -rf "$tmp"
	[[ "$output" == *"not inside a git repo"* ]] \
		|| fail "release rejected valid $mode duration '$value' during range validation: $output"
	if [ "$mode" = dry ] && [ "$value" -lt 60000 ]; then
		[[ "$output" == *"liveness interval ${value}ms"* ]] \
			|| fail "short dry run did not clamp liveness to '$value' ms: $output"
	fi
	checks=$((checks + 1))
}

expect_default_dry_run_shortened() {
	local output tmp
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/soak-timing.XXXXXX")
	output=$(cd "$tmp" && "$RELEASE" --dry-run v99.0.0 2>&1) || true
	rm -rf "$tmp"
	[[ "$output" == *"DRY RUN: short 60000ms soak (liveness interval 60000ms)"* ]] \
		|| fail "default dry run did not retain one liveness interval: $output"
	checks=$((checks + 1))
}

# Every release soak combo must receive the SAME validated liveness interval.
# A combo that silently keeps the Makefile default would soak for the full
# release duration while checking liveness on a different schedule from the
# evidence the MANIFEST claims -- and it would still print SOAK PASS.
expect_release_liveness_wiring() {
	grep -Eq '^[[:space:]]+SOAK_LIVENESS_INTERVAL_MS="\$SOAK_LIVENESS_INTERVAL_MS"' "$RELEASE" \
		|| fail "release does not pass the liveness interval to Classic AVR soaks"
	grep -Eq '^[[:space:]]+PIC_SOAK_LIVENESS_INTERVAL_MS="\$SOAK_LIVENESS_INTERVAL_MS"' "$RELEASE" \
		|| fail "release does not pass the liveness interval to PIC10F322 soaks"
	grep -Eq '^[[:space:]]+PIC320_SOAK_LIVENESS_INTERVAL_MS="\$SOAK_LIVENESS_INTERVAL_MS"' "$RELEASE" \
		|| fail "release does not pass the liveness interval to PIC10F320 soaks"
	checks=$((checks + 1))
}

# ...and the release must actually HAVE a PIC10F320 soak combo to wire. The grep
# above passes vacuously if the loop that builds those combos is deleted, since
# the string simply stops appearing -- which is a failure, not a pass, so assert
# the duration knob is threaded too. Both are per-combo `make` arguments, so
# their presence is the closest a static check gets to "the combo exists".
expect_release_pic320_soak_combos() {
	grep -Eq '^[[:space:]]+PIC320_SOAK_DURATION_MS="\$SOAK_DURATION_MS"' "$RELEASE" \
		|| fail "release does not build PIC10F320 soak combos at the release duration"
	grep -Eq 'PIC320_SOAK_VARIANT="\$v"' "$RELEASE" \
		|| fail "release does not select a PIC10F320 soak combo per output variant"
	checks=$((checks + 1))
}

# The ATtiny202 combos are generated wrappers rather than compiled binaries, so
# the same "does the combo actually exist to be wired" question is answered by
# asserting the duration and liveness interval reach the driver's own env names
# and that the wrapper is written once per supported variant.
expect_release_avrxt_soak_combos() {
	grep -q 'ATTINY202_SOAK_DURATION_MS=%q' "$RELEASE" \
		|| fail "release does not run ATtiny202 soak combos at the release duration"
	grep -q 'ATTINY202_SOAK_LIVENESS_INTERVAL_MS=%q' "$RELEASE" \
		|| fail "release does not pass the liveness interval to ATtiny202 soaks"
	grep -q 'ATTINY202_SOAK_COMBINATION_NAME=%q' "$RELEASE" \
		|| fail "release does not bind a combination name into the ATtiny202 SOAK_RESULT"
	grep -Eq '^for v in \$XT_VARIANTS; do' "$RELEASE" \
		|| fail "release does not select an ATtiny202 soak combo per output variant"
	checks=$((checks + 1))
}

# ...and the driver must actually EMIT the shared contract the orchestrator
# matches on. Without this the greps above pass while every ATtiny202 combo fails
# validate_soak_result() at the end of a full-length release soak.
expect_avrxt_soak_contract() {
	local driver="$ROOT/test/avr/test_soak_attiny202.py"
	grep -q 'SOAK_RESULT format=1 status=%s combination=%s duration_ms=%d' "$driver" \
		|| fail "ATtiny202 soak driver does not emit the release SOAK_RESULT record"
	grep -q 'SOAK %s: %d ms' "$driver" \
		|| fail "ATtiny202 soak driver does not emit the '<duration> ms' PASS line"
	grep -q 'self.liveness_checks' "$driver" \
		|| fail "ATtiny202 soak driver does not count liveness checks separately"
	checks=$((checks + 1))
}

expect_pic_per_ms_transition_sampling() {
	local tmp source="$ROOT/test/pic/test_soak_pic.cc"
	local -a compiler
	read -r -a compiler <<<"$HOSTCXX"
	[ "${#compiler[@]}" -gt 0 ] || fail "empty C++ compiler command"
	tmp=$(mktemp "${TMPDIR:-/tmp}/soak-sampling.XXXXXX")
	if ! "${compiler[@]}" -std=c++17 -Wall -Wextra -Werror -I"$ROOT/test" \
			-x c++ -o "$tmp" - <<'CPP'
#include "pic/soak_sampling.h"

int main() {
    // A held-switch fault toggles four times but ends at its initial level.
    // Endpoint-only observation sees zero; per-ms observation must see all four.
    const int levels[] = {1, 0, 1, 0};
    unsigned index = 0;
    int prior = 0;
    unsigned changes = 0;
    bool complete = soak_run_each_ms(4,
        []() { return true; },
        [&]() {
            int current = levels[index++];
            if (current != prior) ++changes;
            prior = current;
        });
    if (!complete || index != 4 || changes != 4 || prior != 0) return 1;

    unsigned attempts = 0;
    unsigned samples = 0;
    complete = soak_run_each_ms(5,
        [&]() { return ++attempts < 3; },
        [&]() { ++samples; });
    return (!complete && attempts == 3 && samples == 2) ? 0 : 2;
}
CPP
	then
		rm -f "$tmp"
		fail "could not compile PIC per-ms soak-sampling fixture"
	fi
	"$tmp" || { rm -f "$tmp"; fail "PIC per-ms soak-sampling fixture failed"; }
	rm -f "$tmp"
	python3 - "$source" <<'PY'
import re
import sys

with open(sys.argv[1], encoding="utf-8") as source_file:
    source = source_file.read()
source = re.sub(r"/\*.*?\*/", "", source, flags=re.DOTALL)
source = re.sub(r"//[^\n]*", "", source)
match = re.search(r"static\s+void\s+soak_run_ms\s*\(unsigned\s+ms\)\s*"
                  r"\{([^{}]*)\}", source)
if not match or match.group(1).count(
        "soak_run_each_ms(ms, soak_run_one_ms, sample_led)") != 1:
    raise SystemExit("PIC soak_run_ms is not wired to per-ms sampling")
PY
	checks=$((checks + 2))
}

for language in c c++; do
	if [ "$language" = c ]; then compiler=$HOSTCC; else compiler=$HOSTCXX; fi
	expect_compile_pass "$compiler" "$language" 1 1 1
	expect_compile_pass "$compiler" "$language" 4294967294 4294967294 4294967295
	expect_compile_fail "$compiler" "$language" 0 60000 3600000
	expect_compile_fail "$compiler" "$language" -1 60000 3600000
	expect_compile_fail "$compiler" "$language" 1.5 60000 3600000
	expect_compile_fail "$compiler" "$language" 4294967295 60000 3600000
	expect_compile_fail "$compiler" "$language" 1000 0 3600000
	expect_compile_fail "$compiler" "$language" 1000 -1 3600000
	expect_compile_fail "$compiler" "$language" 1000 1001 3600000
	expect_compile_fail "$compiler" "$language" 1000 60000 4294967296
done

python3 - "$ROOT/test/avr/test_soak_attiny202.py" <<'PY'
import os
import runpy
import sys
import types

fake_module = types.ModuleType("sim_attiny202")
fake_module.REG_GPR0 = 0x1c
sys.modules["sim_attiny202"] = fake_module
namespace = runpy.run_path(sys.argv[1])
env_ms = namespace["_env_ms"]

for value in ("1", "4294967294"):
    os.environ["SOAK_TEST_MS"] = value
    actual = env_ms("SOAK_TEST_MS", 1, 0xFFFFFFFE)
    if actual != int(value):
        raise AssertionError("parsed %r as %r" % (value, actual))

for value in ("", "0", "-1", "1.5", "abc", "4294967295"):
    os.environ["SOAK_TEST_MS"] = value
    try:
        env_ms("SOAK_TEST_MS", 1, 0xFFFFFFFE)
    except ValueError:
        continue
    raise AssertionError("accepted invalid timing: %r" % value)


class FakeLoop:
    def __init__(self):
        self.cycles = 0

    def cycle(self):
        return self.cycles


class FinalRoundTripFailureSim:
    def __init__(self, mode):
        self.loop = FakeLoop()
        self.f_cpu = 1000
        self.register = namespace["SENTINEL"]
        self.pressed = False
        self.led = False
        self.runs = 0
        self.mode = mode
        self.done = False

    def press(self):
        self.pressed = True

    def release(self):
        self.pressed = False

    def run_ms(self, duration):
        self.runs += 1
        self.loop.cycles += duration
        if self.pressed:
            self.led = not self.led
        if self.runs == 4:
            if self.mode == "reset":
                self.register = 0  # reset during the final release hold
            elif self.mode == "force-reset":
                self.done = True   # trap before the watchdog clears GPR0

    def led_on(self):
        return self.led

    def read_ioreg(self, _address):
        return self.register

    def write_ioreg(self, _address, value):
        self.register = value

    def is_done(self):
        return self.done


soak_type = namespace["Soak"]


def new_soak(mode):
    soak = soak_type.__new__(soak_type)
    soak.sim = FinalRoundTripFailureSim(mode)
    soak.combination = "fixture"
    soak.checks = 0
    soak.liveness_checks = 0
    soak.failures = 0
    soak.resets = 0
    soak.liveness_fails = 0
    soak.clock_base_ms = 0
    soak.liveness_ms_consumed = 0
    return soak

import contextlib
import io

soak = new_soak("reset")
with contextlib.redirect_stderr(io.StringIO()):
    completed = soak._liveness_check()
if (soak.resets != 1 or soak.failures != 1 or soak.liveness_fails != 0
        or soak.checks != 5 or soak.liveness_checks != 1
        or soak.liveness_ms_consumed != 120 or not completed
        or soak.sim.register != namespace["SENTINEL"]):
    raise AssertionError("final liveness reset escaped: resets=%d failures=%d "
                         "liveness=%d checks=%d liveness_checks=%d elapsed=%d "
                         "completed=%r witness=%#x"
                         % (soak.resets, soak.failures, soak.liveness_fails,
                            soak.checks, soak.liveness_checks,
                            soak.liveness_ms_consumed, completed,
                            soak.sim.register))

soak = new_soak("force-reset")
with contextlib.redirect_stderr(io.StringIO()):
    completed = soak._liveness_check()
if (soak.resets != 0 or soak.failures != 1 or soak.liveness_fails != 0
        or soak.checks != 4 or soak.liveness_checks != 1
        or soak.liveness_ms_consumed != 120 or completed
        or not soak.sim.is_done()):
    raise AssertionError("final liveness force-reset escaped: resets=%d "
                         "failures=%d liveness=%d checks=%d "
                         "liveness_checks=%d elapsed=%d completed=%r done=%r"
                         % (soak.resets, soak.failures, soak.liveness_fails,
                            soak.checks, soak.liveness_checks,
                            soak.liveness_ms_consumed, completed,
                            soak.sim.is_done()))
PY
checks=$((checks + 10))

expect_default_dry_run_shortened
expect_release_range_pass dry 1
expect_release_range_pass real 86400000
expect_release_range_pass dry 4294967294
expect_release_reject 0 "positive base-10 integer"
expect_release_reject -1 "positive base-10 integer"
expect_release_reject malformed "positive base-10 integer"
expect_release_reject 60000 "real releases require"
expect_release_reject 4294967295 "must not exceed"
expect_release_reject 9999999999999999999999999999999999999999 "must not exceed"
expect_release_version_reject v99.0.0.rc1
expect_release_version_reject v99.0.0-.
expect_release_version_reject v99.0.0-foo.lock "is not a valid Git tag name"
expect_release_liveness_wiring
expect_release_pic320_soak_combos
expect_release_avrxt_soak_combos
expect_avrxt_soak_contract
expect_pic_per_ms_transition_sampling

printf 'soak timing validation: %d checks, 0 failures\n' "$checks"
