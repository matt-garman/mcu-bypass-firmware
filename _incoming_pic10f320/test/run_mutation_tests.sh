#!/usr/bin/env bash
#
# Mutation testing for the PIC10F320 bypass firmware + its reference model.
#
# WHY THIS EXISTS
#   A passing suite proves the tests pass on correct code; it does not prove they
#   FAIL on broken code. Mutation testing closes that gap: it injects a small,
#   deliberate fault ("mutant") into a production source, rebuilds, and runs a
#   fast test target. An adequate suite must DETECT the fault -- the target must
#   FAIL (the mutant is "killed"). A surviving mutant marks a real hole.
#
# WHAT IS MUTATED, AND WHAT KILLS IT
#   - The firmware (bypass_mcu_pic10f320.c): killed by host equivalence/actuation/
#     fault checks, CLI gpsim, the real-HEX target aggregate, or the libgpsim soak.
#     The target/soak mutants specifically certify the built-image oracles.
#   - The reference model (test/model/bypass_pure.c) and the model thresholds:
#     killed by `make test-host` / `make test-model-check` (logic), or by
#     `make test-equiv` (a model-threshold change diverges from the firmware).
#
# This runs on a throwaway COPY of the tree; it never modifies the real sources.
# Wired into `make test-mutation`; intentionally NOT part of `make test` (it
# rebuilds per mutant). Each mutant lists the fast target expected to kill it.

set -u

MUTATION_ALLOW_SKIP="${MUTATION_ALLOW_SKIP:-0}"
PIC_CC="${PIC_CC:-/opt/microchip/xc8/v3.10/bin/xc8-cc}"
GPSIM="${GPSIM:-gpsim}"
PIC_SOAK_CXX="${PIC_SOAK_CXX:-c++}"
PIC_SOAK_GPSIM_INC="${PIC_SOAK_GPSIM_INC:-/usr/include/gpsim}"
# Longer than gpsim's ~1.057s WDT period, but short enough for mutation CI.
PIC_SOAK_MUT_MS="${PIC_SOAK_MUT_MS:-2500}"
case "$MUTATION_ALLOW_SKIP" in
    0|1) ;;
    *) echo "ERROR: MUTATION_ALLOW_SKIP must be 0 or 1 (got '$MUTATION_ALLOW_SKIP')" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(dirname "$SCRIPT_DIR")"

# Each entry: file<TAB>sed-expression<TAB>make-target<TAB>description.
# The sed expression uses '@' as the delimiter to avoid clashing with C operators.
MUTATIONS=(
# --- firmware: debounce logic (killed by the firmware<->model equivalence test) ---
"bypass_mcu_pic10f320.c	s@++ctx_.debounce_counter@--ctx_.debounce_counter@	test-equiv	FW integrator: increment-on-press becomes decrement (never reaches threshold)"
"bypass_mcu_pic10f320.c	s@ctx_.debounce_counter >= PRESSED_THRESH@ctx_.debounce_counter > PRESSED_THRESH@	test-equiv	FW press threshold off-by-one (>= becomes >): 1-tick latency divergence"
"bypass_mcu_pic10f320.c	s@if (0U == ctx_.debounce_counter)@if (0U != ctx_.debounce_counter)@	test-equiv	FW release re-arm condition inverted (lock-out never clears / clears wrongly)"
"bypass_mcu_pic10f320.c	s@#define PRESSED_THRESH  (8U)@#define PRESSED_THRESH  (4U)@	test-equiv	FW press threshold shortened 8->4 (diverges from the model's 8)"
"bypass_mcu_pic10f320.c	s@#define RELEASE_THRESH  (25U)@#define RELEASE_THRESH  (15U)@	test-equiv	FW release lock-out shortened 25->15 (diverges from the model)"
# --- firmware: power-on init (killed by equivalence: power-on-pressed sequences) ---
"bypass_mcu_pic10f320.c	s@ctx_.program_state = RELEASE_DEBOUNCE_WAIT;@ctx_.program_state = PRESS_DEBOUNCE_WAIT;@	test-equiv	FW power-on-pressed: wrong program_state (held switch could spuriously engage)"
# --- firmware: defensive / fault-detection layer (killed by the fault harness) -----
# These mutants WEAKEN a runtime sanity check so a real fault would go undetected.
# They are invisible to test-equiv/test-gpsim (valid stimulus never trips the
# check); only test-fault, which injects corrupted state, kills them.
"bypass_mcu_pic10f320.c	s@return (hw_output_pins_intact((1U << LED_PIN) | (1U << CD4053_PIN)) == 0U);@return 0U;@	test-fault-variants	FW output-pin SEU check neutered (lost LED/CD4053 output never detected)"
"bypass_mcu_pic10f320.c	s@(0U == wpu_global)@1U@	test-fault-variants	FW global footswitch pull-up SEU check neutered (nWPUEN corruption never detected)"
"bypass_mcu_pic10f320.c	s@(ctx_.effect_state > ENGAGED)@(ctx_.effect_state > 99U)@	test-fault-variants	FW effect_state range guard defeated (corrupt effect_state never forces reset)"
"bypass_mcu_pic10f320.c	s@(ctx_.debounce_counter > RELEASE_THRESH)@(ctx_.debounce_counter > 255U)@	test-fault-variants	FW counter range guard defeated (corrupt debounce_counter never forces reset)"
# WPUA resets to 0x0F on the PIC10F320. The exact assignment must clear the
# output-pin pull-up latches, and the runtime predicate must keep checking that
# exact RA3-only mask rather than masking away unexpected RA0..RA2 latches.
"bypass_mcu_pic10f320.c	s@WPUA = (uint8_t)(1U << FOOTSW_PIN);@WPUA |= (uint8_t)(1U << FOOTSW_PIN);@	test-fault-variants	FW pull-up init regressed to read-modify-write: WPUA reset value 0x0F preserved instead of exact RA3-only 0x08"
"bypass_mcu_pic10f320.c	s@WPUA \& 0x0FU@WPUA \& (1U << FOOTSW_PIN)@	test-fault-variants	FW pull-up integrity guard masks away unexpected RA0..RA2 WPUA latches"
# The five config-SFR guards below live in hw_critical_sfrs_intact(); each mutant
# replaces one comparison with a constant true (1U), so that SFR is no longer
# checked. Valid stimulus never trips them, so test-equiv/test-gpsim stay green;
# only test-fault's IRCF/WDTPS/PR2/T2CON/ANSELA injections kill them.
"bypass_mcu_pic10f320.c	s@(HFINTOSC_2MHZ_IRCF == OSCCONbits.IRCF)@1U@	test-fault-variants	FW clock-select (OSCCON IRCF) SEU guard defeated (corrupt clock never forces reset)"
"bypass_mcu_pic10f320.c	s@(WDT_WDTPS_256MS == WDTCONbits.WDTPS)@1U@	test-fault-variants	FW watchdog-period (WDTCON WDTPS) SEU guard defeated (corrupt WDT period never forces reset)"
"bypass_mcu_pic10f320.c	s@(TMR2_PR2_PERIOD == PR2)@1U@	test-fault-variants	FW tick-period (PR2) SEU guard defeated (corrupt 1 ms reload never forces reset)"
"bypass_mcu_pic10f320.c	s@(TMR2_T2CON_CONFIG == T2CON)@1U@	test-fault-variants	FW tick-control (T2CON) SEU guard defeated (corrupt prescale/enable never forces reset)"
"bypass_mcu_pic10f320.c	s@(0U == (uint8_t)(ANSELA & BYPASS_OUTPUT_DDR_MASK))@1U@	test-fault-variants	FW digital-port (ANSELA) SEU guard defeated (output pin re-selected analog never forces reset)"
# The ANSELA guard masks the FIXED BYPASS_OUTPUT_DDR_MASK (RA0|RA1|RA2). Narrowing
# it to RA0 alone still catches an RA0 skew but silently drops RA1/RA2 detection;
# killed only because test-fault injects ANSELA skews on RA1 and RA2 as well as RA0.
"bypass_mcu_pic10f320.c	s@ANSELA & BYPASS_OUTPUT_DDR_MASK@ANSELA \& 0x01U@	test-fault-variants	FW ANSELA sanity mask narrowed to RA0 only (RA1/RA2 analog re-selection undetected)"
# --- firmware: GPIO / footswitch wiring -------------------------------------------
# LED-invert and footswitch-polarity BOTH diverge on RA0, so they are targeted at
# test-equiv (always available, host gcc) -- NOT test-gpsim, so that a gpsim-less
# run cannot silently SKIP them (a skipped mutant is not a killed one, yet the
# summary would still read "all evaluated mutants killed"). gpsim remains a
# redundant oracle via the functional scenarios (footswitch_toggle.stc), just not
# the mutation-kill target. This leaves the tick-cadence mutant below as the sole
# original mutant whose sole killer is the CLI gpsim functional wrapper. The
# target/soak sections below intentionally certify additional simulated-core oracles.
# The CD4053 control mis-route does NOT move RA0 (it is on RA1), so it is the one
# wiring fault the RA0-only equivalence test cannot see -- killed host-only by
# test-actuation's settled-LATA check (it was gpsim-only before that check existed).
"bypass_mcu_pic10f320.c	s@LATA |=  (uint8_t)(1U << LED_PIN)@LATA \&= (uint8_t)~(1U << LED_PIN)@	test-equiv	FW set_engaged LED output inverted (RA0 stays dark when ENGAGED)"
"bypass_mcu_pic10f320.c	s@hw_x4053_ctl_low();@hw_x4053_ctl_high();@	PIC_VARIANT=cd4053-simple test-actuation	FW CD4053 control routed the wrong way (set_engaged drives the bypass level); settled ENGAGED LATA 0x1 not 0x3 (RA0 unaffected, so equiv/gpsim-RA0 miss it; killed by the actuation settled-LATA check)"
# --- firmware: analog-switch control-pin DRIVE POLARITY (CD4053 / TMUX4053) --------
# The cd4053-* images drive their control pins with one unified polarity, correct
# for BOTH the CD4053 and the pin-compatible TMUX4053 board (BYPASS = MCU pin low,
# ENGAGE = high). Inverting that drive at the ctl_high definition makes the build
# settle its CONTROL pins to the wrong state (BYPASS 0x2 not 0x0) while RA0/the LED
# stay correct -- invisible to equiv (RA0 only), killed by test-actuation's per-tick
# settled-LATA check.
"bypass_mcu_pic10f320.c	s@static void hw_x4053_ctl_high(void) { LATA \&= (uint8_t)~(1U << CD4053_PIN); }@static void hw_x4053_ctl_high(void) { LATA |=  (uint8_t)(1U << CD4053_PIN); }@	PIC_VARIANT=cd4053-simple test-actuation	FW CD4053 control-pin drive polarity inverted at the definition (ctl_high drives the pin HIGH not LOW); bypass control pin settles wrong (BYPASS 0x2 not 0x0), RA0 unaffected so equiv/gpsim-RA0 miss it"
"bypass_mcu_pic10f320.c	s@(0U == (PORTA & (uint8_t)(1U << FOOTSW_PIN)))@(0U != (PORTA \& (uint8_t)(1U << FOOTSW_PIN)))@	test-equiv	FW footswitch read polarity inverted (toggles on release, not press)"
# --- firmware: 1 ms tick CADENCE (the one mutant only gpsim can kill) ---------------
# Removing the TMR2IF clear makes the flag latch set, so the `while (TMR2IF==0)` poll
# never re-blocks and the main loop free-runs: the debounce crosses PRESSED_THRESH
# within microseconds of the press edge instead of the designed ~8 ms. The host
# harnesses FORCE TMR2IF=1 (one loop iteration == one simulated tick), so test-equiv/
# test-actuation/test-fault are blind to it by construction; the real TMR2 in gpsim
# is the only oracle, caught by footswitch_toggle.stc's mid-debounce PRESS1_EARLY
# checkpoint (LED must still be OFF ~3.5 ms into the press). This is the deliberate
# original exception to host-level kills -- tick timing is unobservable on the
# host. The target/soak mutants below deliberately exercise built-image layers.
"bypass_mcu_pic10f320.c	s@PIR1bits.TMR2IF = 0;@@	test-gpsim	FW TMR2IF tick-flag clear removed: 1 ms poll never re-blocks, loop free-runs, debounce window collapses (host forces TMR2IF=1, so only gpsim's PRESS1_EARLY catches it)"
# --- firmware: blocking-actuation sequencing (killed by the actuation test) --------
# These corrupt the mid-actuation output of the BLOCKING variants (relay coil
# routing / the mute window). They settle to the SAME pin state, so test-equiv
# (RA0 only) and test-gpsim (settled state only) miss them entirely; only
# test-actuation, which snapshots LATA DURING the pulse, kills them. The target
# field carries the variant (the gap exists only for mute/relay, not cd4053-simple).
"bypass_mcu_pic10f320.c	s@hw_relay_set_pin_set_high(); // pulse set coil@hw_relay_reset_pin_set_high(); // MUTANT@	PIC_VARIANT=tq2-relay test-actuation	FW relay ENGAGE pulses the RESET coil instead of SET (relay latches backwards; settles to same LATA, so equiv/gpsim miss it)"
"bypass_mcu_pic10f320.c	s@hw_relay_reset_pin_set_high(); // pulse reset coil@hw_relay_set_pin_set_high(); // MUTANT@	PIC_VARIANT=tq2-relay test-actuation	FW relay BYPASS pulses the SET coil instead of RESET (relay latches backwards)"
"bypass_mcu_pic10f320.c	s@#  define CD4053_MUTE_DELAY_MS (5U)@#  define CD4053_MUTE_DELAY_MS (0U)@	PIC_VARIANT=cd4053-mute test-actuation	FW cd4053-mute pre-switch mute window defeated (5->0 ms): audible click on every switch"
"bypass_mcu_pic10f320.c	s@#  define CD4053_CTL1     (1U) // RA1@#  define CD4053_CTL1     (2U) // MUTANT@;s@#  define CD4053_CTL2     (2U) // RA2@#  define CD4053_CTL2     (1U) // MUTANT@	PIC_VARIANT=cd4053-mute test-actuation	FW cd4053-mute CTL1/CTL2 pins swapped (mute applied to wrong control; mid-mute LATA pattern wrong, settles to same LATA so equiv/gpsim miss it)"
"bypass_mcu_pic10f320.c	s@    hw_x4053_ctl1_high(); // ENGAGED -> MUTE@    hw_x4053_ctl1_low(); // MUTANT: reassert ENGAGED at startup\\n    hw_x4053_ctl2_low();\\n\\n    hw_x4053_ctl1_high(); // ENGAGED -> MUTE@	PIC_VARIANT=cd4053-mute test-actuation	FW cd4053-mute startup reasserts ENGAGED before MUTE, traversing INVALID/ENGAGED routing instead of remaining continuously in BYPASS"
# --- firmware: real-HEX target aggregate (fault + lock-step + target I/O) --------
# These deliberately overlap selected host-level faults: their purpose is to prove
# the newer built-image aggregate independently kills each physical failure mode.
"bypass_mcu_pic10f320.c	s@WPUA = (uint8_t)(1U << FOOTSW_PIN);@WPUA |= (uint8_t)(1U << FOOTSW_PIN);@	PIC_VARIANT=cd4053-simple test-target-gpsim	TARGET pull-up init regressed to read-modify-write; exact startup WPUA check catches retained RA0..RA2 latches"
"bypass_mcu_pic10f320.c	s@wpua_latches == (uint8_t)(1U << FOOTSW_PIN)@0U != (wpua_latches \& (uint8_t)(1U << FOOTSW_PIN))@	PIC_VARIANT=cd4053-simple test-target-gpsim	TARGET exact WPUA guard weakened to RA3-present only; target fault injections catch extra output-pin latches"
"bypass_mcu_pic10f320.c	s@return (0U == (TRISA & expected_mask));@return 1U;@	PIC_VARIANT=cd4053-simple test-target-gpsim	TARGET output-direction guard disabled; simulated-core TRISA injections no longer recover"
"bypass_mcu_pic10f320.c	s@ANSELA & BYPASS_OUTPUT_DDR_MASK@ANSELA \& 0x01U@	PIC_VARIANT=cd4053-simple test-target-gpsim	TARGET ANSELA sanity mask narrowed to RA0; RA1/RA2 analog re-selection goes undetected"
"bypass_mcu_pic10f320.c	s@    hw_x4053_ctl1_high(); // ENGAGED -> MUTE@    hw_x4053_ctl1_low(); // MUTANT: reassert ENGAGED at startup\n    hw_x4053_ctl2_low();\n\n    hw_x4053_ctl1_high(); // ENGAGED -> MUTE@	PIC_VARIANT=cd4053-mute test-target-gpsim	TARGET mute startup reasserts ENGAGED before MUTE; physical startup transition trace catches it"
"bypass_mcu_pic10f320.c	s@#  define CD4053_MUTE_DELAY_MS (5U)@#  define CD4053_MUTE_DELAY_MS (1U)@	PIC_VARIANT=cd4053-mute test-target-gpsim	TARGET mute window shortened below 5ms; cycle-exact target I/O timing catches it"
"bypass_mcu_pic10f320.c	s@#  define TQ2_L2_5V_PULSE_MS (12U)@#  define TQ2_L2_5V_PULSE_MS (1U)@	PIC_VARIANT=tq2-relay test-target-gpsim	TARGET relay pulse shortened below the 4ms datasheet minimum; cycle-exact target I/O timing catches it"
# --- firmware: long-window WDT liveness (real HEX in libgpsim soak) --------------
"bypass_mcu_pic10f320.c	/void main(void)/,\$s@CLRWDT();@(void)0; /* MUTANT: no main-loop WDT pet */@	PIC_VARIANT=cd4053-simple PIC_SOAK_DURATION_MS=$PIC_SOAK_MUT_MS PIC_SOAK_LIVENESS_INTERVAL_MS=$PIC_SOAK_MUT_MS test-soak	SOAK main-loop WDT pet removed; reset notifier catches the un-pet watchdog within the short mutation window"
# --- model: debounce logic (killed by the host / state-space tests) ---------------
"test/model/bypass_pure.c	s@{ ++counter; }@{ --counter; }@	test-host	MODEL integrator increment becomes decrement"
"test/model/bypass_pure.c	s@ctx.debounce_counter >= PRESSED_THRESH@ctx.debounce_counter > PRESSED_THRESH@	test-host	MODEL press threshold off-by-one (>= becomes >)"
"test/model/bypass_pure.c	s@res.lockout_value = RELEASE_THRESH;@res.lockout_value = 0U;@	test-host	MODEL toggle lock-out reload 0 instead of RELEASE_THRESH"
"test/model/bypass_pure.c	s@res.program_state = RELEASE_DEBOUNCE_WAIT;@res.program_state = PRESS_DEBOUNCE_WAIT;@	test-model-check	MODEL stays in PRESS_DEBOUNCE_WAIT after toggle (re-toggle cascade)"
"test/model/bypass_pure.c	s@ctx.program_state = RELEASE_DEBOUNCE_WAIT;@ctx.program_state = PRESS_DEBOUNCE_WAIT;@	test-model-check	MODEL power-on-pressed: wrong program_state (verify_init_context catches it)"
"test/model/bypass_pure.c	s@res.fault = true;@res.fault = false;@	test-model-check	MODEL corrupt-state fault suppressed (verify_corrupt_state_faults catches it)"
)

# Copy the whole project tree into a sandbox; the relative-path Makefile targets
# resolve unchanged there.
copy_tree() {
    local dst="$1"
    mkdir -p "$dst"
    cp "$PROJ_DIR/Makefile" "$PROJ_DIR/bypass_mcu_pic10f320.c" "$dst/"
    cp -a "$PROJ_DIR/scripts" "$dst/"
    cp -r "$PROJ_DIR/test" "$dst/"
}

mutation_target_available() {
    case "$1" in
        test-gpsim)              [ "$GPSIM_OK" -eq 1 ] ;;
        *" test-target-gpsim") [ "$TARGET_OK" -eq 1 ] ;;
        *" test-soak")         [ "$SOAK_OK" -eq 1 ] ;;
        *)                       return 0 ;;
    esac
}

# Baseline sanity: the unmutated tree must PASS the kill targets, otherwise a
# "killed" result would be meaningless. Run the fast logic + equivalence targets.
echo "=== mutation testing: baseline sanity check ==="
BASE="$(mktemp -d)"; copy_tree "$BASE"
base_fail=0
for t in test-host test-model-check test-equiv test-actuation test-fault-variants; do
    if make -C "$BASE" "$t" >/dev/null 2>&1; then
        echo "baseline $t: PASS"
    else
        echo "ERROR: baseline $t FAILS on the unmutated tree; aborting." >&2
        base_fail=1
    fi
done
# The actuation mutants target the BLOCKING variants (mute/relay), so confirm the
# unmutated tree also passes test-actuation for those (it is pure host gcc -- always
# available, never skipped). Unquoted on purpose: the "PIC_VARIANT=... target" form
# word-splits into separate make arguments.
for vt in "PIC_VARIANT=tq2-relay test-actuation" "PIC_VARIANT=cd4053-mute test-actuation"; do
    if make -C "$BASE" $vt >/dev/null 2>&1; then
        echo "baseline $vt: PASS"
    else
        echo "ERROR: baseline $vt FAILS on the unmutated tree; aborting." >&2
        base_fail=1
    fi
done
# Dynamic baselines: skip-clean targets count as unavailable unless the required
# tools exist and the unmutated target genuinely passes.
GPSIM_OK=0
TARGET_OK=0
SOAK_OK=0
if make -C "$BASE" test-gpsim >/dev/null 2>&1 && command -v "$GPSIM" >/dev/null 2>&1 \
   && { [ -x "$PIC_CC" ] || command -v "$PIC_CC" >/dev/null 2>&1; }; then
    GPSIM_OK=1; echo "baseline test-gpsim: PASS (gpsim mutants ENABLED)"
else
    echo "test-gpsim baseline unavailable -> gpsim-killed mutants will be SKIPPED"
fi
if [ "$GPSIM_OK" -eq 1 ] \
   && { [ -x "$PIC_SOAK_CXX" ] || command -v "$PIC_SOAK_CXX" >/dev/null 2>&1; } \
   && [ -f "$PIC_SOAK_GPSIM_INC/sim_context.h" ] \
   && command -v pkg-config >/dev/null 2>&1 \
   && pkg-config --exists glib-2.0 2>/dev/null; then
    if make -C "$BASE" test-target-variants >/dev/null 2>&1; then
        TARGET_OK=1; echo "baseline test-target-variants: PASS (target mutants ENABLED)"
    else
        echo "test-target-variants baseline failed -> target mutants will be SKIPPED"
    fi
    if make -C "$BASE" PIC_VARIANT=cd4053-simple \
            PIC_SOAK_DURATION_MS="$PIC_SOAK_MUT_MS" \
            PIC_SOAK_LIVENESS_INTERVAL_MS="$PIC_SOAK_MUT_MS" \
            test-soak >/dev/null 2>&1; then
        SOAK_OK=1; echo "baseline short test-soak: PASS (WDT-liveness mutant ENABLED)"
    else
        echo "short test-soak baseline failed -> WDT-liveness mutant will be SKIPPED"
    fi
else
    echo "gpsim-dev/glib/C++ stack unavailable -> target and soak mutants will be SKIPPED"
fi
rm -rf "$BASE"
[ "$base_fail" -eq 0 ] || exit 2
required_skips=0
for entry in "${MUTATIONS[@]}"; do
    IFS=$'\t' read -r _file _sed target _desc <<< "$entry"
    mutation_target_available "$target" || required_skips=$((required_skips + 1))
done
if [ "$required_skips" -ne 0 ] && [ "$MUTATION_ALLOW_SKIP" -ne 1 ]; then
    echo "ERROR: $required_skips mutant(s) unavailable; complete mutation evaluation requires XC8, gpsim, and libgpsim." >&2
    echo "       Install the full toolchain, or set MUTATION_ALLOW_SKIP=1 for an explicitly partial local run." >&2
    exit 2
fi
echo

killed=0; survived=0; errored=0; skipped=0; idx=0
SURVIVORS=()

for entry in "${MUTATIONS[@]}"; do
    IFS=$'\t' read -r file sed_expr target desc <<< "$entry"
    idx=$((idx + 1))

    if ! mutation_target_available "$target"; then
        echo "[$idx] SKIP   ($target unavailable): $desc"; skipped=$((skipped + 1)); continue
    fi

    work="$(mktemp -d)"; copy_tree "$work"
    if ! sed -i "$sed_expr" "$work/$file"; then
        echo "[$idx] ERROR  applying sed to $file: $desc"; errored=$((errored + 1)); rm -rf "$work"; continue
    fi
    if cmp -s "$work/$file" "$PROJ_DIR/$file"; then
        echo "[$idx] ERROR  mutation did not change $file (stale pattern?): $desc"
        errored=$((errored + 1)); rm -rf "$work"; continue
    fi

    # $target is unquoted on purpose: a mutant may carry a variant in its target
    # field (e.g. "PIC_VARIANT=tq2-relay test-actuation"), which must word-split
    # into separate make arguments. Target fields never contain globs.
    if make -C "$work" $target >/dev/null 2>&1; then
        echo "[$idx] SURVIVED ($target): $desc"; survived=$((survived + 1)); SURVIVORS+=("$file :: $desc")
    else
        echo "[$idx] killed   ($target): $desc"; killed=$((killed + 1))
    fi
    rm -rf "$work"
done

echo
echo "=== mutation summary: $killed killed, $survived survived, $errored errored, $skipped skipped ==="
if [ "$survived" -ne 0 ]; then
    echo "SURVIVING MUTANTS (a real fault went undetected -- suite gap):"
    for s in "${SURVIVORS[@]}"; do echo "  - $s"; done
fi
if [ "$survived" -ne 0 ] || [ "$errored" -ne 0 ]; then exit 1; fi
if [ "$skipped" -ne 0 ]; then
    if [ "$MUTATION_ALLOW_SKIP" -ne 1 ]; then
        echo "ERROR: $skipped mutant(s) skipped; complete mutation gate did not run." >&2
        exit 1
    fi
    echo "PARTIAL: all evaluated mutants killed, but $skipped mutant(s) were explicitly allowed to skip."
    exit 0
fi
echo "all mutants ran and were killed: the suite detects every injected fault."
exit 0
