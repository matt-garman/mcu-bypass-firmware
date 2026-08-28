#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HEADER="$ROOT/test/soak_timing_config.h"
MAKEFILE="$ROOT/Makefile"
RELEASE="$ROOT/scripts/make-release.sh"
PIC12_TIMING="$ROOT/test/pic/pic12f675_soak_timing.py"
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

expect_release_jobs_reject() {
	local value=$1 output
	if output=$("$RELEASE" --jobs "$value" v99.0.0 2>&1); then
		fail "release accepted invalid jobs value: $value"
	fi
	[[ "$output" == *"--jobs must be a positive base-10 integer"* ]] \
		|| fail "release rejected --jobs '$value' for the wrong reason: $output"
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
	grep -Eq '^[[:space:]]+AVR_SOAK_LIVENESS_INTERVAL_MS="\$SOAK_LIVENESS_INTERVAL_MS"' "$RELEASE" \
		|| fail "release does not pass the liveness interval to Classic AVR soaks"
	grep -Eq '^[[:space:]]+PIC10F322_SOAK_LIVENESS_INTERVAL_MS="\$SOAK_LIVENESS_INTERVAL_MS"' "$RELEASE" \
		|| fail "release does not pass the liveness interval to PIC10F322 soaks"
	grep -Eq '^[[:space:]]+PIC10F320_SOAK_LIVENESS_INTERVAL_MS="\$SOAK_LIVENESS_INTERVAL_MS"' "$RELEASE" \
		|| fail "release does not pass the liveness interval to PIC10F320 soaks"
	checks=$((checks + 1))
}

# ...and the release must actually HAVE a PIC10F320 soak combo to wire. The grep
# above passes vacuously if the loop that builds those combos is deleted, since
# the string simply stops appearing -- which is a failure, not a pass, so assert
# the duration knob is threaded too. Both are per-combo `make` arguments, so
# their presence is the closest a static check gets to "the combo exists".
expect_release_pic10f320_soak_combos() {
	grep -Eq '^[[:space:]]+PIC10F320_SOAK_DURATION_MS="\$SOAK_DURATION_MS"' "$RELEASE" \
		|| fail "release does not build PIC10F320 soak combos at the release duration"
	grep -Eq 'PIC10F320_SOAK_VARIANT="\$v"' "$RELEASE" \
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
	# The mechanism moved into a shared core when the PIC12F675 lane arrived, so
	# the wiring is asserted there -- and, below, that every adapter still
	# reaches it. Checking one adapter alone would have stopped covering the
	# binaries the other adapters build.
	local tmp adapter adapters=0 source="$ROOT/test/pic/test_soak_pic_core.h"
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
match = re.search(r"static\s+bool\s+soak_run_ms\s*\(unsigned\s+ms\)\s*"
                  r"\{([^{}]*)\}", source)
if not match or match.group(1).count(
        "return soak_run_each_ms(ms, soak_run_one_ms, sample_led)") != 1:
    raise SystemExit("PIC soak_run_ms does not propagate per-ms sampling failure")
PY
	for adapter in "$ROOT"/test/pic/test_soak_pic*.cc; do
		[ -f "$adapter" ] || continue
		grep -q '#include "pic/test_soak_pic_core.h"' "$adapter" \
			|| fail "$(basename "$adapter") does not include the shared soak core"
		adapters=$((adapters + 1))
		checks=$((checks + 1))
	done
	# The glob is the enrolment: a part adapter added later is covered without
	# editing this file, and a glob that matched nothing must not read as pass.
	[ "$adapters" -ge 2 ] \
		|| fail "expected at least two PIC soak adapters, found $adapters"
	checks=$((checks + 3))
}

expect_pic12f675_hold_contract() {
	local variant expected actual defs tick block fixture press_hold release_hold
	local -a compiler
	read -r -a compiler <<<"$HOSTCXX"
	for variant in cd4053_simple cd4053_with_mute tq2_l2_5v_relay; do
		case "$variant" in
			cd4053_simple)
				expected='PIC12F675_SOAK_TIMING format=1 variant=cd4053_simple fosc_hz=4000000 option_reg=0x0C subticks=4 tick_us=1024 actuation_block_ms=0 pressed_ticks=8 release_ticks=25 press_hold_ms=19 release_hold_ms=36'
				press_hold=19 release_hold=36
				;;
			cd4053_with_mute)
				expected='PIC12F675_SOAK_TIMING format=1 variant=cd4053_with_mute fosc_hz=4000000 option_reg=0x0C subticks=4 tick_us=1024 actuation_block_ms=5 pressed_ticks=8 release_ticks=25 press_hold_ms=24 release_hold_ms=41'
				press_hold=24 release_hold=41
				;;
			*)
				expected='PIC12F675_SOAK_TIMING format=1 variant=tq2_l2_5v_relay fosc_hz=4000000 option_reg=0x0C subticks=4 tick_us=1024 actuation_block_ms=12 pressed_ticks=8 release_ticks=25 press_hold_ms=31 release_hold_ms=48'
				press_hold=31 release_hold=48
				;;
		esac
		actual=$(python3 "$PIC12_TIMING" --root "$ROOT" --variant "$variant" \
			--fosc-hz 4000000UL --format record) \
			|| fail "could not derive PIC12F675 soak timing for $variant"
		[ "$actual" = "$expected" ] \
			|| fail "PIC12F675 $variant soak timing drifted: $actual"
		defs=$(python3 "$PIC12_TIMING" --root "$ROOT" --variant "$variant" \
			--fosc-hz 4000000UL --format defines) \
			|| fail "could not emit PIC12F675 soak definitions for $variant"
		read -r tick block <<<"$defs"
		fixture=$(mktemp "${TMPDIR:-/tmp}/pic12f675-soak-holds.XXXXXX")
		if ! printf '%s\n' '#define PRESSED_THRESH 8u' \
				'#define RELEASE_THRESH 25u' \
				'#include "pic/soak_hold_timing.h"' \
				"static_assert(SOAK_PRESS_HOLD_MS == ${press_hold}u, \"press hold\");" \
				"static_assert(SOAK_RELEASE_HOLD_MS == ${release_hold}u, \"release hold\");" \
				'int main() { return 0; }' \
			| "${compiler[@]}" -std=c++17 -Wall -Wextra -Werror -I"$ROOT/test" \
				"$tick" "$block" -x c++ -o "$fixture" - >/dev/null 2>&1; then
			rm -f "$fixture"
			fail "derived PIC12F675 definitions did not compile for $variant: $defs"
		fi
		rm -f "$fixture"
		checks=$((checks + 1))
	done
	if python3 "$PIC12_TIMING" --root "$ROOT" --variant cd4053_simple \
			--fosc-hz 2000000UL --format record >/dev/null 2>&1; then
		fail "PIC12F675 soak timing accepted the wrong FOSC"
	fi
	checks=$((checks + 1))
}

# The two PIC10F32x soak maps remain independent because their firmware
# implementations are independent. Verify both copies against test-owned values
# and the constants each firmware implementation actually consumes; deriving a
# shared Make value would let firmware and its timing witness drift together.
expect_pic_actuation_block_contract() {
	local block_checks
	block_checks=$(python3 - "$ROOT" "$MAKEFILE" "$PIC12_TIMING" <<'PY'
import pathlib
import re
import runpy
import sys


root = pathlib.Path(sys.argv[1])
make_text = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
helpers = runpy.run_path(sys.argv[3])
source_define = helpers["source_define"]
source_define_text = helpers["source_define_text"]
expected = {
    "cd4053_simple": 0,
    "cd4053_with_mute": 5,
    "tq2_l2_5v_relay": 12,
}
checks = 0


def make_decimal(text, name):
    pattern = re.compile(
        r"^\s*(?:override\s+)?{}\s*(?::=|=)\s*([0-9]+)\s*$".format(
            re.escape(name)),
        re.MULTILINE,
    )
    matches = pattern.findall(text)
    if len(matches) != 1:
        raise ValueError(
            "Makefile must define {} as one decimal value (found {})".format(
                name, len(matches)
            )
        )
    return int(matches[0], 10)


def require_equal(actual, wanted, what):
    global checks
    if actual != wanted:
        raise ValueError("{} is {}, expected {}".format(what, actual, wanted))
    checks += 1


for prefix, lane in (
    ("pic_soak_block_", "PIC10F322"),
    ("pic10f320_soak_block_", "PIC10F320"),
):
    for variant, wanted in expected.items():
        require_equal(
            make_decimal(make_text, prefix + variant),
            wanted,
            "{} {} soak block".format(lane, variant),
        )

for path, name, wanted in (
    (root / "src/bypass_output_cd4053_with_mute.h", "CD4053_MUTE_DELAY_MS", 5),
    (root / "src/bypass_output_tq2_l2_5v_relay.h", "TQ2_L2_5V_PULSE_MS", 12),
    (root / "src/bypass_mcu_pic10f320.c", "CD4053_MUTE_DELAY_MS", 5),
    (root / "src/bypass_mcu_pic10f320.c", "TQ2_L2_5V_PULSE_MS", 12),
):
    if path.name == "bypass_mcu_pic10f320.c":
        actual = source_define_text(path.read_text(encoding="utf-8"), name, path)
    else:
        actual = source_define(path, name)
    require_equal(actual, wanted, "{} {}".format(path, name))


def require_rejected(operation, what):
    global checks
    try:
        operation()
    except ValueError:
        checks += 1
        return
    raise ValueError("strict decimal parser accepted {}".format(what))


require_rejected(lambda: make_decimal("", "block"), "a missing Make value")
require_rejected(
    lambda: make_decimal("block = 5\nblock = 5\n", "block"),
    "duplicate Make values",
)
require_rejected(
    lambda: make_decimal("block = five\n", "block"), "a malformed Make value"
)
require_rejected(
    lambda: source_define_text("", "BLOCK_MS", "fixture"),
    "a missing source constant",
)
require_rejected(
    lambda: source_define_text(
        "#define BLOCK_MS (5U)\n#define BLOCK_MS (5U)\n", "BLOCK_MS", "fixture"
    ),
    "duplicate source constants",
)
require_rejected(
    lambda: source_define_text("#define BLOCK_MS (five)\n", "BLOCK_MS", "fixture"),
    "a malformed source constant",
)

print(checks)
PY
	) || fail "PIC actuation-block timing contract failed"
	[ "$block_checks" = 16 ] \
		|| fail "PIC actuation-block timing contract returned $block_checks checks instead of 16"
	checks=$((checks + block_checks))
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
for jobs in 0 -1 1.5 malformed 01; do
	expect_release_jobs_reject "$jobs"
done
expect_release_liveness_wiring
expect_release_pic10f320_soak_combos
expect_release_avrxt_soak_combos
expect_avrxt_soak_contract
expect_pic_per_ms_transition_sampling
expect_pic_actuation_block_contract
expect_pic12f675_hold_contract

printf 'soak timing validation: %d checks, 0 failures\n' "$checks"
