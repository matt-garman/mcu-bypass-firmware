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
# local run. In strict/full-tool contexts, skipped PIC mutants are failures.
if [ -z "${MUTATION_ALLOW_SKIP+x}" ]; then
    if [ -n "${STRICT_TOOLS:-}" ]; then
        MUTATION_ALLOW_SKIP=0
    else
        MUTATION_ALLOW_SKIP=1
    fi
fi
case "$MUTATION_ALLOW_SKIP" in
    0|1) ;;
    *) echo "ERROR: MUTATION_ALLOW_SKIP must be 0 or 1 (got '$MUTATION_ALLOW_SKIP')" >&2; exit 2 ;;
esac

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
"src/bypass_mcu_avr_classic.c	s@if ( (ctx_.program_state > RELEASE_DEBOUNCE_WAIT)@if ( 0 \&\& (ctx_.program_state > RELEASE_DEBOUNCE_WAIT)@	test-sim-cd4053	sanity guard disabled: DDRB/state corruption goes undetected; corruption test catches it"
"src/bypass_pure.c	s@res.effect_state = BYPASS;@res.effect_state = ENGAGED;@	test-sim-cd4053	toggle: always sets ENGAGED (never returns to BYPASS); round-trip and lock-step tests catch it"
# --- CD4053 simple output driver -----------------------------------------------
"src/bypass_output_cd4053_simple.c	s@hw_pin_set_high(CD4053_PIN)@hw_pin_set_low(CD4053_PIN)@	test-sim-cd4053	engaged routes CD4053 the wrong way (PB2 stuck low); control-output test catches it"
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
    for sub in "$PROJ_DIR"/test/*/; do
        local name; name="$(basename "$sub")"
        # .c covers most substrates; .cc is the libgpsim PIC soak driver
        # (test/pic/test_soak_pic.cc), which the WDT-liveness mutant compiles.
        if compgen -G "$sub"*.c >/dev/null 2>&1; then
            mkdir -p "$dst/test/$name"; cp "$sub"*.c "$dst/test/$name/"
        fi
        if compgen -G "$sub"*.cc >/dev/null 2>&1; then
            mkdir -p "$dst/test/$name"; cp "$sub"*.cc "$dst/test/$name/"
        fi
    done
}

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
                PIC_SOAK_DURATION_MS="$PIC_SOAK_MUT_MS" PIC_SOAK_VARIANT=cd4053 \
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
"src/bypass_mcu_pic10f322.c	s@return (0U == (TRISA \& expected_mask));@return 1U;@	cd4053	PIC output-direction guard disabled; TRISA faults no longer force watchdog recovery"
"src/bypass_mcu_pic10f322.c	s@ANSELA & BYPASS_OUTPUT_DDR_MASK@ANSELA \& 0x01U@	cd4053	PIC ANSELA sanity mask narrowed to RA0 only; RA1/RA2 analog re-selection undetected"
"src/bypass_output_cd4053_with_mute.c	s@hw_led_pin_set_low();          // dark status LED@hw_pin_set_high(CD4053_CTL1);  // MUTANT: reassert ENGAGED at startup\\n    hw_pin_set_high(CD4053_CTL2);\\n\\n    hw_led_pin_set_low();          // dark status LED@	mute	PIC cd4053-mute startup reasserts ENGAGED before MUTE; target I/O startup trace catches it"
"src/bypass_output_cd4053_with_mute.c	s@BYPASS_DELAY_MS(CD4053_MUTE_DELAY_MS)@BYPASS_DELAY_MS(1)@g	mute	PIC cd4053-mute pre-switch mute window shortened; target I/O pulse-width check catches it"
"src/bypass_output_tq2_l2_5v_relay.c	s@BYPASS_DELAY_MS(TQ2_L2_5V_PULSE_MS)@BYPASS_DELAY_MS(1)@g	relay	PIC relay coil pulse shortened below datasheet minimum; target I/O pulse-width check catches it"
)

# WDT-liveness mutant: gpsim's ~200ms functional run is too short to see an
# un-pet WDT fire (period ~1.057s), so this is killed by the libgpsim soak (which
# counts resets) over a short window > one WDT period. Gated additionally on
# gpsim-dev + glib + a C++ compiler.
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

# Collect the enabled PIC subsets onto the same work list.
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
