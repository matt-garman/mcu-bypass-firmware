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

# Missing PIC tools normally make the PIC mutation subset an explicit partial
# local run. Strict/full-tool contexts default to failure unless the caller
# explicitly authorizes a partial mutation run.
source "$SCRIPT_DIR/mutation_policy.sh"
MUTATION_ALLOW_SKIP=$(resolve_mutation_allow_skip)
policy_rc=$?
[ "$policy_rc" -eq 0 ] || exit "$policy_rc"

# PIC build/test knobs (mirror the Makefile defaults; override via env). Used by
# the PIC-shell mutants and their toolchain probe below.
FW_BASE="${FW_BASE:-bypass}"
PIC_TAG="${PIC_TAG:-pic10f322}"
GPSIM="${GPSIM:-gpsim}"
PIC_SOAK_GPSIM_INC="${PIC_SOAK_GPSIM_INC:-/usr/include/gpsim}"
# Short soak window for the WDT-liveness mutant: must exceed one gpsim WDT period
# (~1.057s at WDTPS=0x08, per the soak's own note) so an un-pet dog actually
# fires, while staying quick. The baseline (pet) run sees zero resets and passes.
PIC_SOAK_MUT_MS="${PIC_SOAK_MUT_MS:-2500}"
# Liveness interval for that short window. The shared soak timing contract
# statically asserts SOAK_LIVENESS_INTERVAL_MS <= SOAK_DURATION_MS, so the
# Makefile default (60000 ms) will not compile against PIC_SOAK_MUT_MS. Keep it
# comfortably inside the window so the baseline (pet) run performs at least one
# real press/release round-trip instead of a vacuous zero-check pass. Must stay
# <= PIC_SOAK_MUT_MS.
PIC_SOAK_MUT_LIVENESS_MS="${PIC_SOAK_MUT_LIVENESS_MS:-1000}"

# Parallelism. Every mutant runs in its own throwaway mktemp sandbox with its own
# build dirs (copy_tree + `make -C "$work"`), so mutants share nothing and can run
# concurrently. MUTATION_JOBS caps how many run at once; it defaults to the core
# count and is overridable (e.g. MUTATION_JOBS=4 to leave headroom, or =1 to force
# the old serial behaviour). Results are collected per-mutant into files and
# tallied deterministically after the pool drains, so the pass/fail verdict and
# the survivor list are identical to a serial run regardless of job count.
MUTATION_JOBS="${MUTATION_JOBS:-$(nproc 2>/dev/null || echo 4)}"
case "$MUTATION_JOBS" in
    ''|*[!0-9]*|0) echo "ERROR: MUTATION_JOBS must be a positive integer (got '$MUTATION_JOBS')" >&2; exit 2 ;;
esac

# Per-mutant result sink (one $idx.status + $idx.out file per mutant). Cleaned on
# exit so an interrupted run leaves nothing behind.
RESULT_DIR="$(mktemp -d)"
trap 'rm -rf "$RESULT_DIR"' EXIT

# Bounded-concurrency dispatch: launch a mutant in the background, and once
# MUTATION_JOBS are in flight, block (`wait -n`) for one to finish before
# launching the next. A final `wait` (at the call site) drains the pool.
_active=0
dispatch() {
    run_mutant "$@" &
    _active=$((_active + 1))
    if [ "$_active" -ge "$MUTATION_JOBS" ]; then
        wait -n
        _active=$((_active - 1))
    fi
}

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
"src/bypass_mcu_avr_classic.c	s@(actual_direction_mask == (uint8_t)BYPASS_OUTPUT_DDR_MASK)@(1U != 0U)@	test-sim-cd4053	DDRB exact-mask predicate removed: PB0 output and PB4 input corruptions evade the former caller-output subset check"
"src/bypass_mcu_avr_classic.c	s@PORTB & (uint8_t)BYPASS_OUTPUT_DDR_MASK@PORTB \& (uint8_t)0x0EU@	test-sim-cd4053	output-latch mask omits spare PB4; PB4 corruption must still force watchdog recovery"
"src/bypass_mcu_avr_classic.c	s@if ( (ctx_.program_state > RELEASE_DEBOUNCE_WAIT)@if ( 0 \&\& (ctx_.program_state > RELEASE_DEBOUNCE_WAIT)@	test-sim-cd4053	sanity guard disabled: DDRB/state corruption goes undetected; corruption test catches it"
"src/bypass_pure.c	s@res.effect_state = BYPASS;@res.effect_state = ENGAGED;@	test-sim-cd4053	toggle: always sets ENGAGED (never returns to BYPASS); round-trip and lock-step tests catch it"
# --- CD4053 simple output driver -----------------------------------------------
"src/bypass_output_cd4053_simple.c	s@hw_pin_set_low(CD4053_PIN)@hw_pin_set_high(CD4053_PIN)@	test-sim-cd4053	bypass routes CD4053 the wrong way (PB2 stuck high); power-on control-output test catches it"
"src/bypass_output_cd4053_simple.c	s@hw_pin_set_high(CD4053_PIN)@hw_pin_set_low(CD4053_PIN)@	test-sim-cd4053	engaged routes CD4053 the wrong way (PB2 stuck low); control-output test catches it"
# --- TQ2 relay output driver ---------------------------------------------------
"src/bypass_output_tq2_l2_5v_relay.c	s@BYPASS_DELAY_MS(TQ2_L2_5V_PULSE_MS)@BYPASS_DELAY_MS(1)@g	test-sim-relay	relay coil pulse shortened to 1ms (< 4ms datasheet min); pulse-width test catches it"
"src/bypass_output_tq2_l2_5v_relay.c	s@pin_set_high(RELAY_SET_PIN)@pin_set_high(RELAY_RESET_PIN)@	test-sim-relay	engage pulses the wrong (RESET) coil; relay test catches SET-not-pulsed / RESET-moved"
# --- CD4053 with-mute output driver --------------------------------------------
"src/bypass_output_cd4053_with_mute.c	s@BYPASS_DELAY_MS(CD4053_MUTE_DELAY_MS)@BYPASS_DELAY_MS(1)@g	test-sim-mute	mute settle window shortened to 1ms; mute-window timing test catches it"

# --- shared core: migrated from the PIC10F320 project (merge, 2026-07-26) ------
# Its other five model mutants duplicate entries already above; this one does
# not. It is the oracle for verify_corrupt_state_faults(), the property Phase 3
# moved into test/formal/test_model_check.c, and it is retargeted from the dead
# vendored copy to the single verified core.
"src/bypass_pure.c	s@res.fault = true;@res.fault = false;@	test-model-check	MODEL corrupt-state fault suppressed (verify_corrupt_state_faults catches it)"
)

# Files copied into each sandbox (all firmware sources + headers + harness +
# Makefile). Copying the whole source set keeps this robust as variants are
# added or renamed.
copy_tree() {
    local dst="$1"
    mkdir -p "$dst/src" "$dst/test"
    cp "$PROJ_DIR"/src/*.c "$PROJ_DIR"/src/*.h "$dst/src/"
    cp "$PROJ_DIR/Makefile" "$dst/"
    # The Makefile's build/validate recipes invoke helper scripts under
    # scripts/ -- notably IHEX_VALIDATOR (scripts/validate-ihex.sh), which
    # `make pic` and the .hex rules REQUIRE and fail closed without. Mirror the
    # whole dir so a sandbox build behaves exactly like the real tree; -a
    # preserves the executable bit the validator-present check relies on.
    cp -a "$PROJ_DIR/scripts" "$dst/"
    # Shared shims/config live at the test root; the test programs themselves
    # live in per-substrate subdirectories (host/ formal/ avr/ pic/). Recreate
    # that tree so the Makefile's test/<sub>/test_*.c paths resolve in the
    # sandbox. Iterating over the subdirs keeps this robust as substrates are
    # added or renamed.
    cp "$PROJ_DIR"/test/*.h "$dst/test/"
    # PIC10F320's harnesses nest TWO levels deep (test/pic10f320/{equiv,actuation,
    # fault,gpsim}/), which the single-level loop below cannot reach, and they
    # include .stc gpsim scripts and .sh helpers that it does not copy either.
    # Mirror that subtree wholesale; -a keeps the executable bit on
    # check_fw_coverage.sh. Without this a PIC10F320 mutant builds against a
    # sandbox missing its own harness and "dies" for the wrong reason -- an
    # error, not a kill, but an equally misleading one.
    if [ -d "$PROJ_DIR/test/pic10f320" ]; then
        cp -a "$PROJ_DIR/test/pic10f320" "$dst/test/"
    fi
    for sub in "$PROJ_DIR"/test/*/; do
        local name ext; name="$(basename "$sub")"
        # C/C++ sources cover the compiled harnesses. Shell wrappers and .stc
        # stimuli are equally load-bearing now that PIC10F320 reuses the shared
        # test/pic gpsim entry points; omitting them makes a mutant die from a
        # missing harness and falsely score as killed.
        for ext in c cc sh stc; do
            if compgen -G "$sub"*."$ext" >/dev/null 2>&1; then
                mkdir -p "$dst/test/$name"
                cp -a "$sub"*."$ext" "$dst/test/$name/"
            fi
        done
    done
}

validate_pic320_sandbox() {
    local root="$1" required ok=1
    for required in \
        test/pic/footswitch_toggle.stc \
        test/pic/power_on_pressed.stc \
        test/pic/test_soak_pic.cc; do
        if [ ! -f "$root/$required" ]; then
            echo "ERROR: PIC10F320 mutation sandbox is missing $required" >&2
            ok=0
        fi
    done
    for required in \
        test/pic/run_gpsim_test.sh \
        test/pic/run_gpsim_power_on_pressed.sh; do
        if [ ! -x "$root/$required" ]; then
            echo "ERROR: PIC10F320 mutation sandbox helper is missing or not executable: $required" >&2
            ok=0
        fi
    done
    [ "$ok" -eq 1 ]
}

if [ "${MUTATION_SANDBOX_SELFTEST:-0}" = 1 ]; then
    SELFTEST_DIR="$(mktemp -d)"
    if ! copy_tree "$SELFTEST_DIR" || ! validate_pic320_sandbox "$SELFTEST_DIR"; then
        rm -rf "$SELFTEST_DIR"
        exit 1
    fi

    rm -f "$SELFTEST_DIR/test/pic/run_gpsim_test.sh"
    if validate_pic320_sandbox "$SELFTEST_DIR" >/dev/null 2>&1; then
        echo "ERROR: mutation sandbox validator accepted a missing gpsim wrapper" >&2
        rm -rf "$SELFTEST_DIR"
        exit 1
    fi

    copy_tree "$SELFTEST_DIR"
    chmod -x "$SELFTEST_DIR/test/pic/run_gpsim_power_on_pressed.sh"
    if validate_pic320_sandbox "$SELFTEST_DIR" >/dev/null 2>&1; then
        echo "ERROR: mutation sandbox validator accepted a non-executable gpsim wrapper" >&2
        rm -rf "$SELFTEST_DIR"
        exit 1
    fi

    rm -rf "$SELFTEST_DIR"
    echo "mutation sandbox copy validation: 3 checks, 0 failures"
    exit 0
fi

# Run one PIC gpsim register-level check against a freshly built (mutated) HEX.
# We build + drive the wrapper DIRECTLY rather than via `make pic-test-gpsim`,
# because that target has a git-mode guard on its wrapper scripts that cannot
# pass inside a non-git mktemp sandbox; the wrapper itself has no such guard. The
# cd4053 variant with its full ENGAGED LATA (0x3) exercises the LED (RA0), the
# footswitch read (RA3) and a control pin (RA1) in one run -- enough to kill
# every PIC gpsim mutant below. Returns nonzero (killed) on a build break or a
# failed gpsim assertion.
pic_gpsim_run() {
    local work="$1"
    make -C "$work" pic >/dev/null 2>&1 || return 1
    local hex="$work/build_pic/${FW_BASE}_cd4053_${PIC_TAG}.hex"
    [ -f "$hex" ] || return 1
    GPSIM="$GPSIM" "$PROJ_DIR/test/pic/run_gpsim_test.sh" "$hex" 0x3 >/dev/null 2>&1
}

# Apply one mutation in a throwaway sandbox and run the mapped checker.
#   $1 idx  : 1-based mutant number (stable, assigned at dispatch time)
#   $2 kind : make | picgpsim | picsoak | pictarget
#   $3 arg  : make target (kind=make), PIC variant (kind=pictarget), ignored otherwise
#   $4 file ; $5 sed-expr ; $6 description
# Runs in the background under the dispatch() pool, so it must NOT touch shared
# shell state. It records its verdict to two files under $RESULT_DIR, keyed by a
# zero-padded index (lexical order == numeric order):
#   $idx.status : first line = killed|survived|errored;
#                 second line (survived only) = "file: desc" for the survivor list
#   $idx.out    : the human-readable "[idx] ..." line, replayed in order after the
#                 pool drains so the log stays deterministic regardless of timing
# The main shell tallies these files after `wait`, so the summary is identical to
# a serial run.
run_mutant() {
    local idx="$1" kind="$2" arg="$3" file="$4" sed_expr="$5" desc="$6"
    local stem; stem="$RESULT_DIR/$(printf '%04d' "$idx")"

    local work; work="$(mktemp -d)"
    copy_tree "$work"

    # Apply the mutation; confirm it actually changed the file.
    if ! sed -i "$sed_expr" "$work/$file"; then
        printf 'errored\n' > "$stem.status"
        printf '[%s] ERROR  applying sed to %s: %s\n' "$idx" "$file" "$desc" > "$stem.out"
        rm -rf "$work"; return
    fi
    if cmp -s "$work/$file" "$PROJ_DIR/$file"; then
        printf 'errored\n' > "$stem.status"
        printf '[%s] ERROR  mutation did not change %s (pattern stale?): %s\n' "$idx" "$file" "$desc" > "$stem.out"
        rm -rf "$work"; return
    fi

    # Run the mapped checker. Killed == nonzero exit (a build OR a test failure
    # both count as "the suite did not silently accept the fault").
    local label rc
    case "$kind" in
        make)
            label="$arg"
            make -C "$work" $arg >/dev/null 2>&1; rc=$?
            ;;
        picgpsim)
            label="pic-test-gpsim"
            pic_gpsim_run "$work"; rc=$?
            ;;
        picsoak)
            label="pic-test-soak"
            make -C "$work" pic-test-soak \
                PIC_SOAK_DURATION_MS="$PIC_SOAK_MUT_MS" \
                PIC_SOAK_LIVENESS_INTERVAL_MS="$PIC_SOAK_MUT_LIVENESS_MS" \
                PIC_SOAK_VARIANT=cd4053 \
                >/dev/null 2>&1; rc=$?
            ;;
        pictarget)
            label="pic-test-target($arg)"
            make -C "$work" PIC_TARGET_VARIANT="$arg" pic-test-target >/dev/null 2>&1; rc=$?
            ;;
        *)
            label="$kind"; rc=0
            ;;
    esac

    if [ "$rc" -eq 0 ]; then
        printf 'survived\n%s\n' "$file: $desc" > "$stem.status"
        printf '[%s] SURVIVED (%s): %s\n' "$idx" "$label" "$desc" > "$stem.out"
    else
        printf 'killed\n' > "$stem.status"
        printf '[%s] killed   (%s): %s\n' "$idx" "$label" "$desc" > "$stem.out"
    fi
    rm -rf "$work"
}

# --- PIC shell mutants (src/bypass_mcu_pic10f322.c) ----------------------------
# The PIC shell target-level mutants drive the real XC8-built HEX in gpsim and
# libgpsim. They are GATED on the PIC toolchain being present AND the unmutated tree
# genuinely PASSING (see the PIC toolchain probe below): gpsim/XC8/gpsim-dev
# absence makes the targets skip (exit 0), which would otherwise read as a false
# "survivor". gpsim's WDT calibration is wrong (~1.057s vs the silicon ~256ms)
# and it does not model the analog BOR, so WDT-timing / BOR / tick-RATE mutants
# are deliberately excluded; only faults observable as register state or a
# qualitative WDT reset are included.
#
# Each entry: file<TAB>sed-expression<TAB>description. These are killed by the
# PORTA/LATA assertions in test/pic/run_gpsim_test.sh, including the mid-debounce
# PRESS1_EARLY cadence checkpoint.
PIC_GPSIM_MUTATIONS=(
"src/bypass_mcu_pic10f322.c	s@LATA |=  (uint8_t)(1U << LED_PIN)@LATA \&= (uint8_t)~(1U << LED_PIN)@	PIC set_engaged LED inverted (LATA RA0 stays dark); ENGAGED checkpoint catches it"
"src/bypass_mcu_pic10f322.c	s@LATA &= (uint8_t)~(1U << LED_PIN)@LATA |= (uint8_t)(1U << LED_PIN)@	PIC set_bypass LED clear inverted (RA0 stuck on); INIT/BYPASS_AGAIN checkpoints catch it"
"src/bypass_mcu_pic10f322.c	s@(0U == (PORTA & (uint8_t)(1U << FOOTSW_PIN)))@(0U != (PORTA \& (uint8_t)(1U << FOOTSW_PIN)))@	PIC footswitch read polarity inverted (RA3 sense flipped -> toggles on release, not press); PRESS1 LED-on (toggle-on-press) checkpoint catches it"
"src/bypass_mcu_pic10f322.c	s@LATA |=  (uint8_t)(1U << pin)@LATA \&= (uint8_t)~(1U << pin)@	PIC control-pin drive inverted (LATA bit never set); ENGAGED full-LATA (0x3) check catches it"
"src/bypass_mcu_pic10f322.c	s@T2CON = TMR2_T2CON_CONFIG;@T2CON = 0x03U;@	PIC TMR2 tick disabled (TMR2ON = bit2 cleared); main loop hangs in hw_wait_for_tick -> never toggles"
"src/bypass_mcu_pic10f322.c	s@PIR1bits.TMR2IF = 0;@@	PIC TMR2IF tick-flag clear removed: loop free-runs and PRESS1_EARLY catches the too-fast debounce"
)

# Mutants killed by the fail-closed PIC target aggregate (fault + lock-step +
# target I/O). Each entry: file<TAB>sed-expression<TAB>variant<TAB>description.
PIC_TARGET_MUTATIONS=(
"src/bypass_mcu_pic10f322.c	s@WPUA = (uint8_t)(1U << FOOTSW_PIN);@WPUA |= (uint8_t)(1U << FOOTSW_PIN);@	cd4053	PIC pull-up init regressed to read-modify-write; exact WPUA state can preserve unexpected output-pin latches"
"src/bypass_mcu_pic10f322.c	s@wpua_latches == (uint8_t)(1U << FOOTSW_PIN)@0U != (wpua_latches \& (uint8_t)(1U << FOOTSW_PIN))@	cd4053	PIC exact WPUA guard weakened to RA3-present only; extra RA0..RA2 latches go undetected"
"src/bypass_mcu_pic10f322.c	s@(actual_direction_mask == expected_direction_mask)@(1U != 0U)@	cd4053	PIC exact-TRISA predicate removed: spare RA2 direction corruption evades the remaining required-subset check"
"src/bypass_mcu_pic10f322.c	s@LATA & (uint8_t)BYPASS_OUTPUT_DDR_MASK@LATA \& (uint8_t)0x03U@	cd4053	PIC output-latch mask omits RA2; an unexpected high spare/control/coil latch goes undetected"
"src/bypass_mcu_pic10f322.c	s@ANSELA & BYPASS_OUTPUT_DDR_MASK@ANSELA \& 0x01U@	cd4053	PIC ANSELA sanity mask narrowed to RA0 only; RA1/RA2 analog re-selection undetected"
"src/bypass_output_cd4053_with_mute.c	s@hw_led_pin_set_low();          // dark status LED@hw_pin_set_high(CD4053_CTL1);  // MUTANT: reassert ENGAGED at startup\\n    hw_pin_set_high(CD4053_CTL2);\\n\\n    hw_led_pin_set_low();          // dark status LED@	mute	PIC cd4053-mute startup reasserts ENGAGED before MUTE; target I/O startup trace catches it"
"src/bypass_output_cd4053_with_mute.c	s@BYPASS_DELAY_MS(CD4053_MUTE_DELAY_MS)@BYPASS_DELAY_MS(1)@g	mute	PIC cd4053-mute pre-switch mute window shortened; target I/O pulse-width check catches it"
"src/bypass_output_tq2_l2_5v_relay.c	s@BYPASS_DELAY_MS(TQ2_L2_5V_PULSE_MS)@BYPASS_DELAY_MS(1)@g	relay	PIC relay coil pulse shortened below datasheet minimum; target I/O pulse-width check catches it"
)

# WDT-liveness mutant: gpsim's ~200ms functional run is too short to see an
# un-pet WDT fire (period ~1.057s), so this is killed by the libgpsim soak (which
# counts resets) over a short window > one WDT period. Gated additionally on
# gpsim-dev + glib + a C++ compiler.
# --- PIC10F320 mutants (merged 2026-07-26) -----------------------------------
# Split by what they NEED, not by what they test: the host lanes want only a C
# compiler, so they run wherever `make test` runs; the rest need XC8 + gpsim +
# libgpsim and are gated by the PIC10F320 probe below. Without that split the
# tool-dependent ones would "survive" on any box lacking the toolchain -- the
# exact false-pass the existing PIC probe was written to prevent.
PIC320_HOST_MUTATIONS=(
"src/bypass_mcu_pic10f320.c	s@++ctx_.debounce_counter@--ctx_.debounce_counter@	pic320-test-equiv	FW integrator: increment-on-press becomes decrement (never reaches threshold)"
"src/bypass_mcu_pic10f320.c	s@ctx_.debounce_counter >= PRESSED_THRESH@ctx_.debounce_counter > PRESSED_THRESH@	pic320-test-equiv	FW press threshold off-by-one (>= becomes >): 1-tick latency divergence"
"src/bypass_mcu_pic10f320.c	s@if (0U == ctx_.debounce_counter)@if (0U != ctx_.debounce_counter)@	pic320-test-equiv	FW release re-arm condition inverted (lock-out never clears / clears wrongly)"
"src/bypass_mcu_pic10f320.c	s@#define PRESSED_THRESH  (8U)@#define PRESSED_THRESH  (4U)@	pic320-test-equiv	FW press threshold shortened 8->4 (diverges from the model's 8)"
"src/bypass_mcu_pic10f320.c	s@#define RELEASE_THRESH  (25U)@#define RELEASE_THRESH  (15U)@	pic320-test-equiv	FW release lock-out shortened 25->15 (diverges from the model)"
"src/bypass_mcu_pic10f320.c	s@ctx_.program_state = RELEASE_DEBOUNCE_WAIT;@ctx_.program_state = PRESS_DEBOUNCE_WAIT;@	pic320-test-equiv	FW power-on-pressed: wrong program_state (held switch could spuriously engage)"
"src/bypass_mcu_pic10f320.c	s@(uint8_t)(0x0FU ^ BYPASS_OUTPUT_DDR_MASK)@(uint8_t)(TRISA \& 0x0FU)@	pic320-test-fault-variants	FW output-pin SEU check neutered (exact-TRISA compare made a tautology; no direction fault ever detected)"
"src/bypass_mcu_pic10f320.c	s@(0U == wpu_global)@1U@	pic320-test-fault-variants	FW global footswitch pull-up SEU check neutered (nWPUEN corruption never detected)"
"src/bypass_mcu_pic10f320.c	s@(ctx_.effect_state > ENGAGED)@(ctx_.effect_state > 99U)@	pic320-test-fault-variants	FW effect_state range guard defeated (corrupt effect_state never forces reset)"
"src/bypass_mcu_pic10f320.c	s@(ctx_.debounce_counter > RELEASE_THRESH)@(ctx_.debounce_counter > 255U)@	pic320-test-fault-variants	FW counter range guard defeated (corrupt debounce_counter never forces reset)"
"src/bypass_mcu_pic10f320.c	s@WPUA = (uint8_t)(1U << FOOTSW_PIN);@WPUA |= (uint8_t)(1U << FOOTSW_PIN);@	pic320-test-fault-variants	FW pull-up init regressed to read-modify-write: WPUA reset value 0x0F preserved instead of exact RA3-only 0x08"
"src/bypass_mcu_pic10f320.c	s@WPUA \& 0x0FU@WPUA \& (1U << FOOTSW_PIN)@	pic320-test-fault-variants	FW pull-up integrity guard masks away unexpected RA0..RA2 WPUA latches"
"src/bypass_mcu_pic10f320.c	s@(HFINTOSC_2MHZ_IRCF == OSCCONbits.IRCF)@1U@	pic320-test-fault-variants	FW clock-select (OSCCON IRCF) SEU guard defeated (corrupt clock never forces reset)"
"src/bypass_mcu_pic10f320.c	s@(WDT_WDTPS_256MS == WDTCONbits.WDTPS)@1U@	pic320-test-fault-variants	FW watchdog-period (WDTCON WDTPS) SEU guard defeated (corrupt WDT period never forces reset)"
"src/bypass_mcu_pic10f320.c	s@(TMR2_PR2_PERIOD == PR2)@1U@	pic320-test-fault-variants	FW tick-period (PR2) SEU guard defeated (corrupt 1 ms reload never forces reset)"
"src/bypass_mcu_pic10f320.c	s@(TMR2_T2CON_CONFIG == T2CON)@1U@	pic320-test-fault-variants	FW tick-control (T2CON) SEU guard defeated (corrupt prescale/enable never forces reset)"
"src/bypass_mcu_pic10f320.c	s@(0U == (uint8_t)(ANSELA & BYPASS_OUTPUT_DDR_MASK))@1U@	pic320-test-fault-variants	FW digital-port (ANSELA) SEU guard defeated (output pin re-selected analog never forces reset)"
"src/bypass_mcu_pic10f320.c	s@ANSELA & BYPASS_OUTPUT_DDR_MASK@ANSELA \& 0x01U@	pic320-test-fault-variants	FW ANSELA sanity mask narrowed to RA0 only (RA1/RA2 analog re-selection undetected)"
"src/bypass_mcu_pic10f320.c	s@LATA |=  (uint8_t)(1U << LED_PIN)@LATA \&= (uint8_t)~(1U << LED_PIN)@	pic320-test-equiv	FW set_engaged LED output inverted (RA0 stays dark when ENGAGED)"
"src/bypass_mcu_pic10f320.c	s@hw_x4053_ctl_low();@hw_x4053_ctl_high();@	PIC320_VARIANT=cd4053-simple pic320-test-actuation	FW CD4053 control routed the wrong way (set_engaged drives the bypass level); settled ENGAGED LATA 0x1 not 0x3 (RA0 unaffected, so equiv/gpsim-RA0 miss it; killed by the actuation settled-LATA check)"
"src/bypass_mcu_pic10f320.c	s@static void hw_x4053_ctl_high(void) { LATA \&= (uint8_t)~(1U << CD4053_PIN); }@static void hw_x4053_ctl_high(void) { LATA |=  (uint8_t)(1U << CD4053_PIN); }@	PIC320_VARIANT=cd4053-simple pic320-test-actuation	FW CD4053 control-pin drive polarity inverted at the definition (ctl_high drives the pin HIGH not LOW); bypass control pin settles wrong (BYPASS 0x2 not 0x0), RA0 unaffected so equiv/gpsim-RA0 miss it"
"src/bypass_mcu_pic10f320.c	s@(0U == (PORTA & (uint8_t)(1U << FOOTSW_PIN)))@(0U != (PORTA \& (uint8_t)(1U << FOOTSW_PIN)))@	pic320-test-equiv	FW footswitch read polarity inverted (toggles on release, not press)"
"src/bypass_mcu_pic10f320.c	s@hw_relay_set_pin_set_high(); // pulse set coil@hw_relay_reset_pin_set_high(); // MUTANT@	PIC320_VARIANT=tq2-relay pic320-test-actuation	FW relay ENGAGE pulses the RESET coil instead of SET (relay latches backwards; settles to same LATA, so equiv/gpsim miss it)"
"src/bypass_mcu_pic10f320.c	s@hw_relay_reset_pin_set_high(); // pulse reset coil@hw_relay_set_pin_set_high(); // MUTANT@	PIC320_VARIANT=tq2-relay pic320-test-actuation	FW relay BYPASS pulses the SET coil instead of RESET (relay latches backwards)"
"src/bypass_mcu_pic10f320.c	s@#  define CD4053_MUTE_DELAY_MS (5U)@#  define CD4053_MUTE_DELAY_MS (0U)@	PIC320_VARIANT=cd4053-mute pic320-test-actuation	FW cd4053-mute pre-switch mute window defeated (5->0 ms): audible click on every switch"
"src/bypass_mcu_pic10f320.c	s@#  define CD4053_CTL1     (1U) // RA1@#  define CD4053_CTL1     (2U) // MUTANT@;s@#  define CD4053_CTL2     (2U) // RA2@#  define CD4053_CTL2     (1U) // MUTANT@	PIC320_VARIANT=cd4053-mute pic320-test-actuation	FW cd4053-mute CTL1/CTL2 pins swapped (mute applied to wrong control; mid-mute LATA pattern wrong, settles to same LATA so equiv/gpsim miss it)"
"src/bypass_mcu_pic10f320.c	s@    hw_x4053_ctl1_high(); // ENGAGED -> MUTE@    hw_x4053_ctl1_low(); // MUTANT: reassert ENGAGED at startup\\n    hw_x4053_ctl2_low();\\n\\n    hw_x4053_ctl1_high(); // ENGAGED -> MUTE@	PIC320_VARIANT=cd4053-mute pic320-test-actuation	FW cd4053-mute startup reasserts ENGAGED before MUTE, traversing INVALID/ENGAGED routing instead of remaining continuously in BYPASS"
)

PIC320_TOOL_MUTATIONS=(
"src/bypass_mcu_pic10f320.c	s@PIR1bits.TMR2IF = 0;@@	pic320-test-gpsim	FW TMR2IF tick-flag clear removed: 1 ms poll never re-blocks, loop free-runs, debounce window collapses (host forces TMR2IF=1, so only gpsim's PRESS1_EARLY catches it)"
"src/bypass_mcu_pic10f320.c	s@WPUA = (uint8_t)(1U << FOOTSW_PIN);@WPUA |= (uint8_t)(1U << FOOTSW_PIN);@	PIC320_VARIANT=cd4053-simple PIC320_TARGET_VARIANT=cd4053-simple pic320-test-target	TARGET pull-up init regressed to read-modify-write; exact startup WPUA check catches retained RA0..RA2 latches"
"src/bypass_mcu_pic10f320.c	s@wpua_latches == (uint8_t)(1U << FOOTSW_PIN)@0U != (wpua_latches \& (uint8_t)(1U << FOOTSW_PIN))@	PIC320_VARIANT=cd4053-simple PIC320_TARGET_VARIANT=cd4053-simple pic320-test-target	TARGET exact WPUA guard weakened to RA3-present only; target fault injections catch extra output-pin latches"
"src/bypass_mcu_pic10f320.c	s@static uint8_t hw_output_pins_intact(void) {@static uint8_t hw_output_pins_intact(void) { return 1U;@	PIC320_VARIANT=cd4053-simple PIC320_TARGET_VARIANT=cd4053-simple pic320-test-target	TARGET output-direction guard disabled; simulated-core TRISA injections no longer recover"
"src/bypass_mcu_pic10f320.c	s@ANSELA & BYPASS_OUTPUT_DDR_MASK@ANSELA \& 0x01U@	PIC320_VARIANT=cd4053-simple PIC320_TARGET_VARIANT=cd4053-simple pic320-test-target	TARGET ANSELA sanity mask narrowed to RA0; RA1/RA2 analog re-selection goes undetected"
"src/bypass_mcu_pic10f320.c	s@    hw_x4053_ctl1_high(); // ENGAGED -> MUTE@    hw_x4053_ctl1_low(); // MUTANT: reassert ENGAGED at startup\n    hw_x4053_ctl2_low();\n\n    hw_x4053_ctl1_high(); // ENGAGED -> MUTE@	PIC320_VARIANT=cd4053-mute PIC320_TARGET_VARIANT=cd4053-mute pic320-test-target	TARGET mute startup reasserts ENGAGED before MUTE; physical startup transition trace catches it"
"src/bypass_mcu_pic10f320.c	s@#  define CD4053_MUTE_DELAY_MS (5U)@#  define CD4053_MUTE_DELAY_MS (1U)@	PIC320_VARIANT=cd4053-mute PIC320_TARGET_VARIANT=cd4053-mute pic320-test-target	TARGET mute window shortened below 5ms; cycle-exact target I/O timing catches it"
"src/bypass_mcu_pic10f320.c	s@#  define TQ2_L2_5V_PULSE_MS (12U)@#  define TQ2_L2_5V_PULSE_MS (1U)@	PIC320_VARIANT=tq2-relay PIC320_TARGET_VARIANT=tq2-relay pic320-test-target	TARGET relay pulse shortened below the 4ms datasheet minimum; cycle-exact target I/O timing catches it"
"src/bypass_mcu_pic10f320.c	/void main(void)/,\$s@CLRWDT();@(void)0; /* MUTANT: no main-loop WDT pet */@	PIC320_VARIANT=cd4053-simple PIC320_SOAK_DURATION_MS=$PIC_SOAK_MUT_MS PIC320_SOAK_LIVENESS_INTERVAL_MS=$PIC_SOAK_MUT_MS pic320-test-soak	SOAK main-loop WDT pet removed; reset notifier catches the un-pet watchdog within the short mutation window"
)

PIC_SOAK_MUTATIONS=(
"src/bypass_mcu_pic10f322.c	s@{ CLRWDT(); }@{ (void)0; /* MUTANT: no WDT pet */ }@	PIC WDT pet (CLRWDT) removed; soak reset counter trips within ~1s of an un-pet WDT"
)

# Combined work list, filled in mutant order (core/AVR first, then any enabled PIC
# subsets). Each element packs: category<US>kind<US>arg<US>file<US>sed<US>desc,
# where <US> is the ASCII unit-separator (\x1f). A NON-whitespace separator is
# required: the `arg` field is empty for the PIC gpsim/soak kinds, and `read`
# with an IFS-whitespace delimiter (space/tab/newline) COLLAPSES the adjacent
# delimiters around an empty field, shifting every later field left. \x1f cannot
# appear in a sed expression or description, so the pack/unpack is lossless.
# `category` is a display label used only to group the ordered replay of results;
# the whole list is dispatched through one bounded-parallel pool below.
US=$'\x1f'
job_specs=()

# Sanity: the unmutated tree must PASS every target we rely on, otherwise a
# "killed" result is meaningless (it would just mean the baseline is broken).
# Baseline-check EVERY distinct kill target the MUTATIONS list uses -- not just
# test-sim -- so a mutant killed by e.g. test-model-check can never be a false
# kill against a baseline that was never verified. (The PIC-shell mutants have
# their own baseline probe below, since their tools may be absent.)
echo "=== mutation testing: baseline sanity check ==="
BASE_DIR="$(mktemp -d)"
copy_tree "$BASE_DIR"
if ! validate_pic320_sandbox "$BASE_DIR"; then
    rm -rf "$BASE_DIR"
    exit 2
fi
BASE_TARGETS=$(printf '%s\n' "${MUTATIONS[@]}" | cut -f3 | sort -u)
for t in $BASE_TARGETS; do
    if make -C "$BASE_DIR" "$t" >/dev/null 2>&1; then
        echo "baseline $t: PASS"
    else
        echo "ERROR: baseline $t FAILS on unmutated tree; aborting." >&2
        rm -rf "$BASE_DIR"
        exit 2
    fi
done
rm -rf "$BASE_DIR"
echo

# Collect the core/AVR mutants (always run). Dispatch happens once, after the PIC
# probe below has decided which PIC subsets are eligible.
core_cat="${#MUTATIONS[@]} core/AVR mutants"
for entry in "${MUTATIONS[@]}"; do
    IFS=$'\t' read -r file sed_expr target desc <<< "$entry"
    job_specs+=("$core_cat$US""make$US$target$US$file$US$sed_expr$US$desc")
done

# PIC10F320 host-lane mutants: only a C compiler is required, so these ride with
# the core batch and are never skipped.
p320_host_cat="${#PIC320_HOST_MUTATIONS[@]} PIC10F320 host mutants (equiv/actuation/fault)"
for entry in "${PIC320_HOST_MUTATIONS[@]}"; do
    IFS=$'\t' read -r file sed_expr target desc <<< "$entry"
    job_specs+=("$p320_host_cat$US""make$US$target$US$file$US$sed_expr$US$desc")
done

# --- PIC toolchain probe ------------------------------------------------------
# Enable the PIC-shell mutants only when the PIC tools are present AND the
# UNMUTATED tree genuinely PASSES (a clean skip is NOT a pass). pic-test-gpsim /
# pic-test-soak both exit 0 when their tools are absent, so without this gate an
# unguarded PIC mutant would be a false "survivor" on any box lacking XC8/gpsim.
PIC_GPSIM_OK=0
PIC_SOAK_OK=0
PIC_TARGET_OK=0
echo
echo "=== PIC toolchain probe (gates the PIC-shell mutants) ==="
PIC_BASE="$(mktemp -d)"
copy_tree "$PIC_BASE"
make -C "$PIC_BASE" pic >/dev/null 2>&1
PIC_BASE_HEX="$PIC_BASE/build_pic/${FW_BASE}_cd4053_${PIC_TAG}.hex"
if command -v "$GPSIM" >/dev/null 2>&1 && [ -f "$PIC_BASE_HEX" ]; then
    if GPSIM="$GPSIM" "$PROJ_DIR/test/pic/run_gpsim_test.sh" \
            "$PIC_BASE_HEX" 0x3 >/dev/null 2>&1; then
        PIC_GPSIM_OK=1
        echo "gpsim + XC8 present, baseline PASS -> PIC gpsim mutants ENABLED"
        if command -v c++ >/dev/null 2>&1 \
           && [ -f "$PIC_SOAK_GPSIM_INC/sim_context.h" ] \
           && pkg-config --exists glib-2.0 2>/dev/null; then
            if make -C "$PIC_BASE" pic-test-soak \
                    PIC_SOAK_DURATION_MS="$PIC_SOAK_MUT_MS" \
                    PIC_SOAK_LIVENESS_INTERVAL_MS="$PIC_SOAK_MUT_LIVENESS_MS" \
                    PIC_SOAK_VARIANT=cd4053 >/dev/null 2>&1; then
                PIC_SOAK_OK=1
                echo "gpsim-dev + glib + c++ present, soak baseline PASS -> WDT mutant ENABLED"
            else
                echo "soak baseline did not pass cleanly -> WDT (soak) mutant SKIPPED"
            fi
            if make -C "$PIC_BASE" pic-test-target-variants >/dev/null 2>&1; then
                PIC_TARGET_OK=1
                echo "target aggregate baseline PASS -> PIC target mutants ENABLED"
            else
                echo "target aggregate baseline did not pass cleanly -> PIC target mutants SKIPPED"
            fi
        else
            echo "gpsim-dev/glib/c++ absent -> WDT (soak) mutant SKIPPED"
        fi
    else
        echo "PIC gpsim baseline did not pass -> PIC-shell mutants SKIPPED"
    fi
else
    echo "gpsim and/or XC8 absent -> PIC-shell mutants SKIPPED"
fi
rm -rf "$PIC_BASE"

# --- PIC10F320 toolchain probe -----------------------------------------------
# Same discipline as the PIC10F322 probe above: the tool-dependent PIC10F320
# mutants are enabled only when the tools exist AND every DISTINCT kill command
# passes on the unmutated sandbox. Testing only pic320-test-target-variants does
# not baseline pic320-test-gpsim or pic320-test-soak; worse, a missing wrapper in
# either mutant sandbox then produces a nonzero status that is falsely scored as
# a kill. pic320-test-{gpsim,target,soak} can all skip with status 0, so the outer
# tool checks and exact per-command baselines are both required.
PIC320_TOOL_OK=0
echo
echo "=== PIC10F320 toolchain probe (gates its tool-dependent mutants) ==="
P320_BASE="$(mktemp -d)"
copy_tree "$P320_BASE"
if ! validate_pic320_sandbox "$P320_BASE"; then
    rm -rf "$P320_BASE"
    exit 2
fi
echo "PIC10F320 mutation sandbox helpers: PASS"

if make -C "$P320_BASE" pic320-variants >/dev/null 2>&1 \
   && command -v "$GPSIM" >/dev/null 2>&1 \
   && command -v c++ >/dev/null 2>&1 \
   && [ -f "$PIC_SOAK_GPSIM_INC/sim_context.h" ] \
   && pkg-config --exists glib-2.0 2>/dev/null; then
    P320_BASELINES_OK=1
    while IFS= read -r target; do
        # Intentional word splitting: each field contains optional VAR=value
        # assignments followed by one Make target, never shell metacharacters.
        if make -C "$P320_BASE" GPSIM="$GPSIM" $target >/dev/null 2>&1; then
            echo "baseline $target: PASS"
        else
            echo "baseline $target: FAIL"
            P320_BASELINES_OK=0
        fi
    done < <(printf '%s\n' "${PIC320_TOOL_MUTATIONS[@]}" | cut -f3 | sort -u)
    if [ "$P320_BASELINES_OK" -eq 1 ]; then
        PIC320_TOOL_OK=1
        echo "XC8 + gpsim + libgpsim present, all baselines PASS -> PIC10F320 tool mutants ENABLED"
    else
        echo "a PIC10F320 kill-target baseline failed -> its tool mutants SKIPPED"
    fi
else
    echo "XC8/gpsim/libgpsim absent -> PIC10F320 tool mutants SKIPPED"
fi
rm -rf "$P320_BASE"

# Collect the enabled PIC subsets onto the same work list.
if [ "$PIC320_TOOL_OK" -eq 1 ]; then
    p320_tool_cat="${#PIC320_TOOL_MUTATIONS[@]} PIC10F320 target mutants (gpsim/libgpsim/soak)"
    for entry in "${PIC320_TOOL_MUTATIONS[@]}"; do
        IFS=$'\t' read -r file sed_expr target desc <<< "$entry"
        job_specs+=("$p320_tool_cat$US""make$US$target$US$file$US$sed_expr$US$desc")
    done
fi

if [ "$PIC_GPSIM_OK" -eq 1 ]; then
    gpsim_cat="${#PIC_GPSIM_MUTATIONS[@]} PIC-shell mutants (gpsim register-level)"
    for entry in "${PIC_GPSIM_MUTATIONS[@]}"; do
        IFS=$'\t' read -r file sed_expr desc <<< "$entry"
        job_specs+=("$gpsim_cat$US""picgpsim$US$US$file$US$sed_expr$US$desc")
    done
fi

if [ "$PIC_SOAK_OK" -eq 1 ]; then
    soak_cat="${#PIC_SOAK_MUTATIONS[@]} PIC-shell mutant (WDT liveness, libgpsim soak ${PIC_SOAK_MUT_MS}ms)"
    for entry in "${PIC_SOAK_MUTATIONS[@]}"; do
        IFS=$'\t' read -r file sed_expr desc <<< "$entry"
        job_specs+=("$soak_cat$US""picsoak$US$US$file$US$sed_expr$US$desc")
    done
fi

if [ "$PIC_TARGET_OK" -eq 1 ]; then
    target_cat="${#PIC_TARGET_MUTATIONS[@]} PIC target mutants (fault + lock-step + target I/O)"
    for entry in "${PIC_TARGET_MUTATIONS[@]}"; do
        IFS=$'\t' read -r file sed_expr variant desc <<< "$entry"
        job_specs+=("$target_cat$US""pictarget$US$variant$US$file$US$sed_expr$US$desc")
    done
fi

# --- dispatch every collected mutant through the bounded-parallel pool ---------
# Each mutant gets a stable 1-based index (its position in job_specs) so its
# result files and the ordered replay below line up regardless of finish order.
echo
echo "=== running ${#job_specs[@]} mutants across up to $MUTATION_JOBS parallel job(s) ==="
job_cat=("")   # 1-based; index 0 unused
idx=0
for spec in "${job_specs[@]}"; do
    idx=$((idx + 1))
    IFS="$US" read -r category kind arg file sed_expr desc <<< "$spec"
    job_cat[idx]="$category"
    dispatch "$idx" "$kind" "$arg" "$file" "$sed_expr" "$desc"
done
wait   # drain the pool: every mutant has now written its result files

# --- tally + ordered replay ---------------------------------------------------
# Read the per-mutant result files in index order so the log and the survivor
# list are deterministic no matter how the pool interleaved the runs.
killed=0
survived=0
errored=0
SURVIVORS=()
prev_cat=""
for idx in $(seq 1 "${#job_specs[@]}"); do
    stem="$RESULT_DIR/$(printf '%04d' "$idx")"
    if [ "${job_cat[idx]}" != "$prev_cat" ]; then
        echo
        echo "=== ${job_cat[idx]} ==="
        prev_cat="${job_cat[idx]}"
    fi
    if [ ! -f "$stem.status" ]; then
        # A mutant that produced no result file never ran to completion (killed
        # background job, disk error): fail closed rather than silently drop it.
        echo "[$idx] ERROR  no result recorded (mutant did not complete)"
        errored=$((errored + 1))
        continue
    fi
    cat "$stem.out"
    case "$(sed -n 1p "$stem.status")" in
        killed)   killed=$((killed + 1)) ;;
        survived) survived=$((survived + 1)); SURVIVORS+=("$(sed -n 2p "$stem.status")") ;;
        errored)  errored=$((errored + 1)) ;;
        *)        echo "[$idx] ERROR  unrecognized result status" ; errored=$((errored + 1)) ;;
    esac
done

echo
# Make the PIC-shell coverage explicit in the summary: a run on a host without
# XC8/gpsim silently omits the PIC mutants, and "all killed" must not be read as
# "PIC mutants passed" when they never ran. (CI's PIC job has the toolchain.)
pic_skipped=0
if [ "$PIC_GPSIM_OK" -eq 1 ]; then
    msg="PIC-shell mutants: RAN (gpsim register-level"
    if [ "$PIC_SOAK_OK" -eq 1 ]; then
        msg="$msg + libgpsim soak WDT"
    else
        msg="$msg; soak WDT skipped"
        pic_skipped=$((pic_skipped + ${#PIC_SOAK_MUTATIONS[@]}))
    fi
    if [ "$PIC_TARGET_OK" -eq 1 ]; then
        msg="$msg + target aggregate"
    else
        msg="$msg; target aggregate skipped"
        pic_skipped=$((pic_skipped + ${#PIC_TARGET_MUTATIONS[@]}))
    fi
    echo "$msg)"
else
    echo "PIC-shell mutants: SKIPPED (PIC toolchain absent -- not gated on this host)"
    pic_skipped=$((pic_skipped + ${#PIC_GPSIM_MUTATIONS[@]} + ${#PIC_SOAK_MUTATIONS[@]} + ${#PIC_TARGET_MUTATIONS[@]}))
fi
if [ "$PIC320_TOOL_OK" -eq 1 ]; then
    echo "PIC10F320 mutants: RAN (host lanes + gpsim/libgpsim/soak)"
else
    echo "PIC10F320 mutants: host lanes RAN; target/soak SKIPPED (toolchain absent)"
    pic_skipped=$((pic_skipped + ${#PIC320_TOOL_MUTATIONS[@]}))
fi
echo "=== mutation summary: $killed killed, $survived survived, $errored errored, $pic_skipped PIC skipped ==="
if [ "$survived" -ne 0 ]; then
    echo "SURVIVING MUTANTS (test suite gap -- a real fault went undetected):"
    for s in "${SURVIVORS[@]}"; do echo "  - $s"; done
fi
if [ "$survived" -ne 0 ] || [ "$errored" -ne 0 ]; then
    exit 1
fi
if [ "$pic_skipped" -ne 0 ] && [ "$MUTATION_ALLOW_SKIP" -ne 1 ]; then
    echo "ERROR: $pic_skipped PIC mutant(s) skipped; complete mutation gate did not run." >&2
    echo "       Install the PIC toolchain/libgpsim stack, or set MUTATION_ALLOW_SKIP=1 for an explicitly partial local run." >&2
    exit 1
fi
if [ "$pic_skipped" -ne 0 ]; then
    echo "PARTIAL: all evaluated mutants killed, but $pic_skipped PIC mutant(s) were explicitly allowed to skip."
    exit 0
fi
echo "all mutants killed: the suite detects every injected fault."
exit 0
