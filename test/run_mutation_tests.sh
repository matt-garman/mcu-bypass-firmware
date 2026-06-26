#!/usr/bin/env bash
#
# Mutation testing for the bypass firmware (core + output-driver variants).
#
# WHY THIS EXISTS
# ---------------
# A passing test suite proves the tests PASS on correct code; it does not prove
# the tests would FAIL on broken code. Mutation testing closes that gap: it
# injects a small, deliberate fault ("mutant") into the PRODUCTION sources
# (bypass_mcu_avr_classic.c, the output drivers, or bypass_config.h), rebuilds, and runs a
# fast test target. A correct, adequate suite must DETECT the fault -- the test
# target must FAIL (the mutant is "killed"). A mutant that survives (tests still
# pass) marks a real hole in the suite.
#
# Core/config mutants map to the single fast variant target `test-sim-cd4053`
# (the core debounce/WDT logic is shared by every variant, so one variant
# suffices to kill them). Output-driver mutants map to their own variant target
# (`test-sim-relay` / `test-sim-mute` / `test-sim-cd4053`).
#
# This operates entirely on a throwaway COPY of the tree; it never modifies the
# real sources. It is wired into `make test-mutation` and is intentionally NOT
# part of the default `make test` (it rebuilds the firmware once per mutant).
#
# Each mutation lists the fast `make` target expected to kill it, so the
# mutation->test mapping is explicit and the run stays quick.
#
# A note on self-referential oracles: the host golden-model tests pull
# RELEASE_THRESH/PRESSED_THRESH from bypass_config.h (the single source of
# truth), so they intentionally CANNOT catch a threshold change (expectation and
# code move together). The threshold mutants below are therefore mapped to
# `test-sim`, where the simavr noise test asserts a HARD-CODED toggle count and
# the lock-step co-sim compares the real binary against an independent model.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(dirname "$SCRIPT_DIR")"

# Each entry: file<TAB>sed-expression<TAB>make-target<TAB>description
# The sed expression uses '@' as delimiter to avoid clashing with C operators.
MUTATIONS=(
# --- core debounce algorithm (bypass_pure.c) -----------------------------------
"src/bypass_pure.c	s@{ ++counter; }@{ --counter; }@	test-sim-cd4053	ISR integrator: increment-on-press becomes decrement (counter never rises -> never toggles)"
"src/bypass_pure.c	s@ctx.debounce_counter >= PRESSED_THRESH@ctx.debounce_counter > PRESSED_THRESH@	test-sim-cd4053	press threshold off-by-one (>= becomes >); test_minimum_press_toggles catches the 1-tick divergence"
"src/bypass_mcu_avr_classic.c	s@PORTB |=  (1 << LED_PIN)@PORTB \&= (uint8_t)~(1 << LED_PIN)@	test-sim-cd4053	set_engaged LED output inverted (lights become dark)"
"src/bypass_config.h	s@#define PRESSED_THRESH (8U)@#define PRESSED_THRESH (4U)@	test-sim-cd4053	press threshold shortened 8->4 (timing/noise-count regression)"
"src/bypass_config.h	s@#define RELEASE_THRESH (25U)@#define RELEASE_THRESH (15U)@	test-sim-cd4053	release lock-out shortened 25->15 (noise-count regression)"
# --- ISR bounds guards (bypass_pure.c) -----------------------------------------
"src/bypass_pure.c	s@if (debounce_counter < RELEASE_THRESH) { ++counter; }@++counter;@	test-sim-cd4053	ISR increment: remove saturation guard (counter wraps from 255->0 after 256 sustained ticks)"
"src/bypass_pure.c	s@if (debounce_counter > 0U) { --counter; }@--counter;@	test-sim-cd4053	ISR decrement: remove underflow guard (counter wraps 0->255 on release; lock-step catches divergence)"
# --- power-on initialization (bypass_pure.c) ------------------------------------
# simavr cannot reliably inject a held switch at power-on (PORTB write in init()
# resets the IRQ-driven pin level), so these map to test-model-check which calls
# debounce_init_context() directly and checks both return fields.
"src/bypass_pure.c	s@ctx.program_state = RELEASE_DEBOUNCE_WAIT;@ctx.program_state = PRESS_DEBOUNCE_WAIT;@	test-model-check	power-on-pressed: wrong program_state; verify_init_context() checks RELEASE_DEBOUNCE_WAIT"
"src/bypass_pure.c	s@ctx.debounce_counter = RELEASE_THRESH;@ctx.debounce_counter = 0U;@	test-model-check	power-on-pressed: lockout counter 0 instead of RELEASE_THRESH; verify_init_context() checks counter"
# --- lockout mechanism (bypass_pure.c) -----------------------------------------
"src/bypass_pure.c	s@res.lockout_value = RELEASE_THRESH;@res.lockout_value = 0;@g	test-sim-cd4053	toggle lockout: counter reset to 0 instead of RELEASE_THRESH (immediate re-arm, no hold lockout)"
"src/bypass_pure.c	s@res.program_state = RELEASE_DEBOUNCE_WAIT;@res.program_state = PRESS_DEBOUNCE_WAIT;@g	test-sim-cd4053	toggle lockout: stays in PRESS_DEBOUNCE_WAIT after toggle (counter=25 >= 8 -> immediate re-toggle cascade)"
# --- watchdog handshake (bypass_mcu_avr_classic.c) ----------------------------------------
"src/bypass_mcu_avr_classic.c	s@hw_wdt_pet();@(void)0; /* MUTANT: no WDT pet */@	test-sim-cd4053	WDT pet removed from main loop: watchdog fires within ~250ms; test_watchdog_not_tripped_normally catches it"
"src/bypass_mcu_avr_classic.c	s@timer_isr_called_ = TIMER_ISR_CALLED;@timer_isr_called_ = TIMER_ISR_NOT_CALLED;@	test-sim-cd4053	WDT handshake: ISR clears its own flag -> main never sees CALLED -> WDT fires within timeout"
# --- main-loop sanity guard / toggle dispatch (bypass_mcu_avr_classic.c) -------------------
"src/bypass_mcu_avr_classic.c	s@if ( (ctx_.program_state > RELEASE_DEBOUNCE_WAIT)@if ( 0 \&\& (ctx_.program_state > RELEASE_DEBOUNCE_WAIT)@	test-sim-cd4053	sanity guard disabled: DDRB/state corruption goes undetected; corruption test catches it"
"src/bypass_pure.c	s@res.effect_state = BYPASS;@res.effect_state = ENGAGED;@	test-sim-cd4053	toggle: always sets ENGAGED (never returns to BYPASS); round-trip and lock-step tests catch it"
# --- CD4053 simple output driver -----------------------------------------------
"src/bypass_output_cd4053_simple.c	s@pin_set_high(CD4053_PIN)@pin_set_low(CD4053_PIN)@	test-sim-cd4053	engaged routes CD4053 the wrong way (PB2 stuck low); control-output test catches it"
# --- TQ2 relay output driver ---------------------------------------------------
"src/bypass_output_tq2_l2_5v_relay.c	s@BYPASS_DELAY_MS(TQ2_L2_5V_PULSE_MS)@BYPASS_DELAY_MS(1)@g	test-sim-relay	relay coil pulse shortened to 1ms (< 4ms datasheet min); pulse-width test catches it"
"src/bypass_output_tq2_l2_5v_relay.c	s@pin_set_high(RELAY_SET_PIN)@pin_set_high(RELAY_RESET_PIN)@	test-sim-relay	engage pulses the wrong (RESET) coil; relay test catches SET-not-pulsed / RESET-moved"
# --- CD4053 with-mute output driver --------------------------------------------
"src/bypass_output_cd4053_with_mute.c	s@BYPASS_DELAY_MS(CD4053_MUTE_DELAY_MS)@BYPASS_DELAY_MS(1)@g	test-sim-mute	mute settle window shortened to 1ms; mute-window timing test catches it"
)

# Files copied into each sandbox (all firmware sources + headers + harness +
# Makefile). Copying the whole source set keeps this robust as variants are
# added or renamed.
copy_tree() {
    local dst="$1"
    mkdir -p "$dst/src" "$dst/test"
    cp "$PROJ_DIR"/src/*.c "$PROJ_DIR"/src/*.h "$dst/src/"
    cp "$PROJ_DIR/Makefile" "$dst/"
    # Shared shims/config live at the test root; the test programs themselves
    # live in per-substrate subdirectories (host/ formal/ avr/ pic/). Recreate
    # that tree so the Makefile's test/<sub>/test_*.c paths resolve in the
    # sandbox. Iterating over the subdirs keeps this robust as substrates are
    # added or renamed.
    cp "$PROJ_DIR"/test/*.h "$dst/test/"
    for sub in "$PROJ_DIR"/test/*/; do
        if compgen -G "$sub"*.c >/dev/null 2>&1; then
            local name; name="$(basename "$sub")"
            mkdir -p "$dst/test/$name"
            cp "$sub"*.c "$dst/test/$name/"
        fi
    done
}

killed=0
survived=0
errored=0
SURVIVORS=()

# Sanity: the unmutated tree must PASS the targets we rely on, otherwise a
# "killed" result is meaningless (it would just mean the baseline is broken).
echo "=== mutation testing: baseline sanity check ==="
BASE_DIR="$(mktemp -d)"
copy_tree "$BASE_DIR"
if make -C "$BASE_DIR" test-sim >/dev/null 2>&1; then
    echo "baseline test-sim: PASS"
else
    echo "ERROR: baseline test-sim FAILS on unmutated tree; aborting." >&2
    rm -rf "$BASE_DIR"
    exit 2
fi
rm -rf "$BASE_DIR"
echo

echo "=== mutation testing: ${#MUTATIONS[@]} mutants ==="
idx=0
for entry in "${MUTATIONS[@]}"; do
    idx=$((idx + 1))
    IFS=$'\t' read -r file sed_expr target desc <<< "$entry"

    work="$(mktemp -d)"
    copy_tree "$work"

    # Apply the mutation; confirm it actually changed the file.
    if ! sed -i "$sed_expr" "$work/$file"; then
        echo "[$idx] ERROR  applying sed to $file: $desc"
        errored=$((errored + 1)); rm -rf "$work"; continue
    fi
    if cmp -s "$work/$file" "$PROJ_DIR/$file"; then
        echo "[$idx] ERROR  mutation did not change $file (pattern stale?): $desc"
        errored=$((errored + 1)); rm -rf "$work"; continue
    fi

    # Run the mapped target. Killed == nonzero exit (build or test failure
    # both count as "the suite did not silently accept the fault").
    if make -C "$work" "$target" >/dev/null 2>&1; then
        echo "[$idx] SURVIVED ($target): $desc"
        survived=$((survived + 1))
        SURVIVORS+=("$file: $desc")
    else
        echo "[$idx] killed   ($target): $desc"
        killed=$((killed + 1))
    fi
    rm -rf "$work"
done

echo
echo "=== mutation summary: $killed killed, $survived survived, $errored errored ==="
if [ "$survived" -ne 0 ]; then
    echo "SURVIVING MUTANTS (test suite gap -- a real fault went undetected):"
    for s in "${SURVIVORS[@]}"; do echo "  - $s"; done
fi
if [ "$survived" -ne 0 ] || [ "$errored" -ne 0 ]; then
    exit 1
fi
echo "all mutants killed: the suite detects every injected fault."
exit 0

