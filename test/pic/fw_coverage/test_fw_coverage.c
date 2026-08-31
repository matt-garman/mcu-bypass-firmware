// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

#include <stdint.h>
#include <stdio.h>

#include "xc.h"
#include "fw_coverage_harness.h"
#include "bypass_pure.h"
#if defined(TQ2_L2_5V_RELAY)
#include "bypass_output_tq2_l2_5v_relay.h"
#include "bypass_output_common.h"
#define FW_RELAY_COIL_MASK ((uint8_t)( \
        (uint8_t)(1u << RELAY_SET_PIN) | \
        (uint8_t)(1u << RELAY_RESET_PIN)))
#endif

static int g_checks;
static int g_failures;

#define CHECK(cond, ...) do {                                \
    g_checks++;                                              \
    if (!(cond)) {                                           \
        g_failures++;                                        \
        fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
        fprintf(stderr, __VA_ARGS__);                        \
        fprintf(stderr, "\n");                              \
    }                                                        \
} while (0)

static void sfr_clean(void) {
#if defined(BYPASS_MCU_PIC12F675)
    fwp_set_output_state(0u, 0u);
    fwp_set_footswitch(0);
    TRISIO = 0x28u;
    ANSEL = 0u;
    WPU = 0x20u;
    OPTION_REG = 0x0cu;
    CMCON = 0x07u;
    ADCON0 = 0u;
    OSCCAL = 0x80u;
    fwp_capture_osccal();
    TMR0 = 0u;
    INTCONbits.GIE = 1u;
#else
    LATA = 0u;
    TRISA = 0x08u;
    ANSELA = 0u;
    WPUA = 0x08u;
    OPTION_REGbits.nWPUEN = 0u;
    OSCCONbits.IRCF = 0x04u;
    WDTCONbits.WDTPS = 0x08u;
    PR2 = 124u;
    T2CON = 0x05u;
    PORTA = 0x08u;
    INTCONbits.GIE = 1u;
#endif
}

static void test_predicates(void) {
#if defined(BYPASS_MCU_PIC12F675)
    sfr_clean();
    CHECK(fwp_output_state_intact(0x17u, 0x00u) != 0,
          "clean outputs should be intact and low");
    CHECK(fwp_sanity_failed(BYPASS) == 0,
          "clean bypass output configuration should pass");
    CHECK(fwp_sanity_failed(ENGAGED) != 0,
          "ENGAGED expectation must reject matching settled BYPASS shadow and GPIO");
    CHECK(fwp_pullup_intact() != 0, "clean GP5 pull-up should be intact");
    CHECK(fwp_critical_sfrs_intact() != 0, "clean critical SFRs should pass");
    CHECK(fwp_footswitch_is_high() == 1, "released GP5 footswitch should read high");

    fwp_set_footswitch(1);
    CHECK(fwp_footswitch_is_high() == 0, "pressed GP5 footswitch should read low");

    sfr_clean(); TRISIO |= 0x01u;
    CHECK(fwp_output_state_intact(0x01u, 0x00u) == 0,
          "GP0 input must fail direction check");
    CHECK(fwp_sanity_failed(BYPASS) != 0, "GP0 input must fail output sanity");

    sfr_clean(); TRISIO |= 0x02u;
    CHECK(fwp_sanity_failed(BYPASS) != 0, "GP1 input must fail output sanity");

    sfr_clean(); TRISIO |= 0x04u;
    CHECK(fwp_output_state_intact(0x04u, 0x00u) == 0,
          "GP2 input must fail direction check");
    CHECK(fwp_output_state_intact(0x03u, 0x00u) == 0,
          "GP2 input must fail the exact check outside the required subset");
    CHECK(fwp_sanity_failed(BYPASS) != 0,
          "GP2 input must fail every variant's output sanity");

    sfr_clean(); TRISIO |= 0x10u;
    CHECK(fwp_sanity_failed(BYPASS) != 0,
          "parked GP4 input must fail exact direction sanity");
    sfr_clean(); TRISIO &= (uint8_t)~0x20u;
    CHECK(fwp_sanity_failed(BYPASS) != 0,
          "footswitch GP5 output must fail exact direction sanity");

    sfr_clean(); fwp_set_output_state(0x01u, 0x00u);
    CHECK(fwp_sanity_failed(BYPASS) != 0, "GP0 shadow high must fail bypass sanity");
    sfr_clean(); fwp_set_output_state(0x02u, 0x00u);
    CHECK(fwp_sanity_failed(BYPASS) != 0, "GP1 shadow high must fail bypass sanity");
    sfr_clean(); fwp_set_output_state(0x04u, 0x00u);
    CHECK(fwp_sanity_failed(BYPASS) != 0, "GP2 shadow high must fail bypass sanity");
    sfr_clean(); fwp_set_output_state(0x10u, 0x00u);
    CHECK(fwp_sanity_failed(BYPASS) != 0, "parked GP4 shadow high must fail bypass sanity");

    sfr_clean(); fwp_set_output_state(0x00u, 0x01u);
    CHECK(fwp_sanity_failed(BYPASS) != 0, "physical GP0 divergence must fail sanity");
    sfr_clean(); fwp_set_output_state(0x00u, 0x02u);
    CHECK(fwp_sanity_failed(BYPASS) != 0, "physical GP1 divergence must fail sanity");
    sfr_clean(); fwp_set_output_state(0x00u, 0x04u);
    CHECK(fwp_sanity_failed(BYPASS) != 0, "physical GP2 divergence must fail sanity");
    sfr_clean(); fwp_set_output_state(0x00u, 0x10u);
    CHECK(fwp_sanity_failed(BYPASS) != 0, "physical GP4 divergence must fail sanity");

    sfr_clean();
#if defined(CD4053_SIMPLE)
    fwp_set_output_state(0x03u, 0x03u);
#elif defined(CD4053_WITH_MUTE)
    fwp_set_output_state(0x07u, 0x07u);
#else
    fwp_set_output_state(0x01u, 0x01u);
#endif
    CHECK(fwp_sanity_failed(ENGAGED) == 0,
          "variant's settled engaged GPIO state must pass sanity");
    CHECK(fwp_sanity_failed((effect_state_t)2) != 0,
          "invalid effect state must fail output sanity");

    sfr_clean(); WPU = 0u;
    CHECK(fwp_pullup_intact() == 0, "missing GP5 pull-up must fail");
    sfr_clean(); WPU |= 0x01u;
    CHECK(fwp_pullup_intact() == 0, "extra GP0 pull-up must fail");
    sfr_clean(); WPU |= 0x02u;
    CHECK(fwp_pullup_intact() == 0, "extra GP1 pull-up must fail");
    sfr_clean(); WPU |= 0x04u;
    CHECK(fwp_pullup_intact() == 0, "extra GP2 pull-up must fail");
    sfr_clean(); WPU |= 0x10u;
    CHECK(fwp_pullup_intact() == 0, "extra GP4 pull-up must fail");
    sfr_clean(); OPTION_REGbits.nGPPU = 1u;
    CHECK(fwp_pullup_intact() == 0, "global pull-up disable must fail");

    sfr_clean(); OPTION_REG ^= 0x01u;
    CHECK(fwp_pullup_intact() != 0,
          "OPTION_REG skew fixture must leave the pull-up enabled");
    CHECK(fwp_critical_sfrs_intact() == 0, "OPTION_REG skew must fail critical SFRs");
    sfr_clean(); CMCON ^= 0x01u;
    CHECK(fwp_critical_sfrs_intact() == 0, "CMCON skew must fail critical SFRs");
    sfr_clean(); ADCON0bits.ADON = 1u;
    CHECK(fwp_critical_sfrs_intact() == 0, "ADCON0.ADON must fail critical SFRs");
    sfr_clean(); ANSEL |= 0x01u;
    CHECK(fwp_critical_sfrs_intact() == 0, "GP0 analog select must fail critical SFRs");
    sfr_clean(); ANSEL |= 0x02u;
    CHECK(fwp_critical_sfrs_intact() == 0, "GP1 analog select must fail critical SFRs");
    sfr_clean(); ANSEL |= 0x04u;
    CHECK(fwp_critical_sfrs_intact() == 0, "GP2 analog select must fail critical SFRs");
    sfr_clean(); ANSEL |= 0x08u;
    CHECK(fwp_critical_sfrs_intact() == 0, "parked GP4 analog select must fail critical SFRs");
    sfr_clean(); OSCCAL ^= 0x04u;
    CHECK(fwp_critical_sfrs_intact() == 0, "OSCCAL skew must fail critical SFRs");

    sfr_clean(); OPTION_REGbits.nGPPU = 1u;
    CHECK(OPTION_REG == 0x8cu,
          "OPTION_REG and nGPPU bitfield must share one backing byte");
    sfr_clean(); ADCON0bits.ADON = 1u;
    CHECK(ADCON0 == 0x01u,
          "ADCON0 and ADON bitfield must share one backing byte");
#else
    sfr_clean();
    CHECK(fwp_output_state_intact(0x07u, 0x00u) != 0,
          "clean outputs should be intact and low");
    CHECK(fwp_sanity_failed(BYPASS) == 0,
          "clean bypass output configuration should pass");
    CHECK(fwp_pullup_intact() != 0, "clean pull-up should be intact");
    CHECK(fwp_critical_sfrs_intact() != 0, "clean critical SFRs should pass");
    CHECK(fwp_footswitch_is_high() == 1, "released footswitch should read high");

    PORTA = 0u;
    CHECK(fwp_footswitch_is_high() == 0, "pressed footswitch should read low");

    sfr_clean(); TRISA |= 0x01u;
    CHECK(fwp_output_state_intact(0x01u, 0x00u) == 0,
          "RA0 input must fail direction check");
    CHECK(fwp_sanity_failed(BYPASS) != 0, "RA0 input must fail output sanity");

    sfr_clean(); TRISA |= 0x02u;
    CHECK(fwp_sanity_failed(BYPASS) != 0, "RA1 input must fail output sanity");

    sfr_clean(); TRISA |= 0x04u;
    CHECK(fwp_output_state_intact(0x04u, 0x00u) == 0,
          "RA2 input must fail direction check");
    CHECK(fwp_output_state_intact(0x03u, 0x00u) == 0,
          "RA2 input must fail the exact check outside the required subset");
    CHECK(fwp_sanity_failed(BYPASS) != 0,
          "RA2 input must fail every variant's output sanity");

    sfr_clean(); LATA = 0x01u;
    CHECK(fwp_sanity_failed(BYPASS) != 0, "RA0 high must fail bypass sanity");
    sfr_clean(); LATA = 0x02u;
    CHECK(fwp_sanity_failed(BYPASS) != 0, "RA1 high must fail bypass sanity");
    sfr_clean(); LATA = 0x04u;
    CHECK(fwp_sanity_failed(BYPASS) != 0, "RA2 high must fail bypass sanity");

    sfr_clean();
#if defined(CD4053_SIMPLE)
    LATA = 0x03u;
#elif defined(CD4053_WITH_MUTE)
    LATA = 0x07u;
#else
    LATA = 0x01u;
#endif
    CHECK(fwp_sanity_failed(ENGAGED) == 0,
          "variant's settled engaged latch must pass sanity");
    CHECK(fwp_sanity_failed((effect_state_t)2) != 0,
          "invalid effect state must fail output sanity");

    sfr_clean(); WPUA = 0u;
    CHECK(fwp_pullup_intact() == 0, "missing RA3 pull-up must fail");
    sfr_clean(); WPUA |= 0x01u;
    CHECK(fwp_pullup_intact() == 0, "extra RA0 pull-up must fail");
    sfr_clean(); WPUA |= 0x02u;
    CHECK(fwp_pullup_intact() == 0, "extra RA1 pull-up must fail");
    sfr_clean(); WPUA |= 0x04u;
    CHECK(fwp_pullup_intact() == 0, "extra RA2 pull-up must fail");
    sfr_clean(); OPTION_REGbits.nWPUEN = 1u;
    CHECK(fwp_pullup_intact() == 0, "global pull-up disable must fail");
#endif
}

static void expect_reset(fw_inject_t inj, const char *what) {
    int r = fw_fault_run(inj);
    CHECK(r == 1, "%s must force reset (got %d)", what, r);
}

static void expect_no_reset(fw_inject_t inj, const char *what) {
    int r = fw_fault_run(inj);
    CHECK(r == 0, "%s must not force reset (got %d)", what, r);
}

#if defined(TQ2_L2_5V_RELAY)
// A relay coil found energized is a FAULT, not something to clear quietly: a
// pulse below the TQ2-L2-5V 4 ms minimum is not proven mechanically harmless,
// so the firmware cannot know whether the latching relay moved (F1;
// docs/relay_coil_fault_correction.md). The gate escalates it like any other
// output-state mismatch, and hw_force_wdt_reset() de-energizes both coils
// before it spins.
//
// "Forced a reset" on its own would not distinguish this from any other guarded
// fault, so the second assertion is the one that is coil-specific: after the
// run, every output must be settled LOW. That is the de-energization, observed
// on the shipping source. It is deliberately NOT called recovery -- final-low
// coils are not resynchronization. The gpsim lanes
// (test/pic/test_fault_pic.cc, test/pic/test_fault_pic12f675.cc) measure the
// recovery RESET-coil pulse on the real image, and nothing in
// any simulator speaks to relay mechanics.
//
// A dead injection cannot hide here: apply_injection()'s arms are not
// variant-conditional, and the two CD4053 variants -- run from this same gate
// invocation -- expect_reset() on these very injection codes.
#if defined(BYPASS_MCU_PIC12F675)
#define FW_OUTPUT_REQUIRED_MASK 0x17u // GP0|GP1|GP2|GP4
#else
#define FW_OUTPUT_REQUIRED_MASK 0x07u // RA0|RA1|RA2
#endif

static void expect_coil_fault_escalates(fw_inject_t inj, const char *what) {
    int r = fw_fault_run(inj);
    CHECK(r == 1, "%s must force the fail-safe reset (got %d)", what, r);
    CHECK(fwp_output_state_intact(FW_OUTPUT_REQUIRED_MASK, 0x00u) != 0,
          "%s must leave both coils de-energized before the reset spin", what);
}

#if defined(BYPASS_MCU_PIC12F675)
// The parked spare is not a coil, and reaching the reset is not the whole
// contract for it either. Having no LATx, this part's relay escalation path
// commits its coil clear as ONE whole-port write of the SRAM shadow, and that
// write publishes EVERY shadow bit -- so a GP4 intent bit corrupted from low to
// high is converted by the escalation itself from inert SRAM into a physically
// driven pad, held for the length of the watchdog period. The board contract
// permits GP4 only while it is low (src/bypass_pins_pic12f675.h).
//
// Reset entry alone cannot witness that: the reset is what ENDS the unsafe
// interval, so a case that only observes "a reset happened" passes either way.
// The modeled PIN is therefore read at the point fw_fault_run() escapes the
// watchdog spin -- before the recovery -- and folded into this case's SINGLE
// check, deliberately without a second CHECK, so the harness totals stay
// hand-verifiable against the counts below.
static void expect_parked_output_fault_escalates(fw_inject_t inj,
        const char *what) {
    int const r = fw_fault_run(inj);
    uint8_t const physical = fwp_physical_output_state();
    CHECK(r == 1 &&
          (physical & (uint8_t)(1u << SPARE_OUTPUT_PIN)) == 0u,
          "%s must force the fail-safe reset with parked GP4 physically low "
          "before the spin (got r=%d gpio=%02x)", what, r, physical);
}
#endif
#endif

static void test_faults(void) {
    CHECK(fw_ctx_window_run() == 0,
          "post-check context upset must not change output or become re-folded");
#if defined(BYPASS_MCU_PIC12F675)
    expect_no_reset(FWI_NONE, "clean state");
    CHECK(WPU == 0x20u, "init must replace WPU reset state with GP5-only");
    CHECK(OPTION_REG == 0x0cu, "init must configure the exact timer/WDT/pull-up byte");
    CHECK(TRISIO == 0x28u, "init must configure GP0..GP2/GP4 outputs exactly");
    CHECK(CMCON == 0x07u, "init must disable the comparator");
    CHECK(OSCCAL == 0x80u, "init must preserve the oscillator calibration value");
    expect_no_reset(FWI_VALID_ENGAGED, "valid engaged state");
    expect_reset(FWI_PROGRAM_STATE_OOR, "invalid program state");
    expect_reset(FWI_EFFECT_STATE_OOR, "invalid effect state");
    expect_reset(FWI_COUNTER_OOR, "invalid debounce counter");
    expect_reset(FWI_PULLUP_LATCH_CLEARED, "missing GP5 pull-up latch");
    expect_reset(FWI_PULLUP_EXTRA_GP0, "extra GP0 pull-up latch");
    expect_reset(FWI_PULLUP_EXTRA_GP1, "extra GP1 pull-up latch");
    expect_reset(FWI_PULLUP_EXTRA_GP2, "extra GP2 pull-up latch");
    expect_reset(FWI_PULLUP_EXTRA_GP4, "extra GP4 pull-up latch");
    expect_reset(FWI_PULLUP_GLOBAL_OFF, "global pull-up disable");
    expect_reset(FWI_GP0_PIN_TO_INPUT, "GP0 direction fault");
    expect_reset(FWI_GP1_PIN_TO_INPUT, "GP1 direction fault");
    expect_reset(FWI_GP2_PIN_TO_INPUT, "GP2 direction fault");
    expect_reset(FWI_GP4_PIN_TO_INPUT, "parked GP4 direction fault");
    expect_reset(FWI_GP5_PIN_TO_OUTPUT, "GP5 direction fault");
    // Nothing re-drives the port ahead of the gate on any variant, so every
    // modeled output injection at this pre-gate seam resets -- which is also
    // what makes this part's port-follows-shadow clause load-bearing at the
    // settled seam instead of pre-empted by a refresh. On the relay variant the
    // two coil bits additionally have to be de-energized before the spin; the
    // blocking actuation window is characterized separately below.
    expect_reset(FWI_SHADOW_GP0_HIGH, "GP0 LED shadow (intent) fault");
#if defined(TQ2_L2_5V_RELAY)
    // Same single check as the CD4053 arm, with the pre-spin physical-pin
    // observation folded in: only the relay variant has a non-empty
    // hw_outputs_reassert_safe(), so only it can publish this shadow bit.
    expect_parked_output_fault_escalates(FWI_SHADOW_GP4_HIGH,
            "parked GP4 shadow (intent) fault");
#else
    expect_reset(FWI_SHADOW_GP4_HIGH, "parked GP4 shadow (intent) fault");
#endif
    expect_reset(FWI_GPIO_GP0_HIGH, "physical GP0 divergence");
    expect_reset(FWI_GPIO_GP4_HIGH, "physical GP4 divergence");
#if defined(TQ2_L2_5V_RELAY)
    expect_coil_fault_escalates(FWI_SHADOW_GP1_HIGH, "GP1 RESET-coil shadow fault");
    expect_coil_fault_escalates(FWI_SHADOW_GP2_HIGH, "GP2 SET-coil shadow fault");
    expect_coil_fault_escalates(FWI_GPIO_GP1_HIGH, "physical GP1 coil divergence");
    expect_coil_fault_escalates(FWI_GPIO_GP2_HIGH, "physical GP2 coil divergence");
#else
    expect_reset(FWI_SHADOW_GP1_HIGH, "GP1 shadow-latch fault");
    expect_reset(FWI_SHADOW_GP2_HIGH, "GP2 shadow-latch fault");
    expect_reset(FWI_GPIO_GP1_HIGH, "physical GP1 divergence");
    expect_reset(FWI_GPIO_GP2_HIGH, "physical GP2 divergence");
#endif
    expect_reset(FWI_OPTION_REG_SKEW, "OPTION_REG configuration fault");
    expect_reset(FWI_CMCON_SKEW, "comparator configuration fault");
    expect_reset(FWI_ADCON0_ADON_SET, "ADC enable fault");
    expect_reset(FWI_ANSEL_SKEW_GP0, "GP0 analog-selection fault");
    expect_reset(FWI_ANSEL_SKEW_GP1, "GP1 analog-selection fault");
    expect_reset(FWI_ANSEL_SKEW_GP2, "GP2 analog-selection fault");
    expect_reset(FWI_ANSEL_SKEW_GP4, "parked GP4 analog-selection fault");
    expect_reset(FWI_OSCCAL_SKEW, "oscillator calibration fault");
    CHECK(fw_fault_run(FWI_HARNESS_STALL) == -1,
          "timeout outside the reset path must be a harness error, not a reset");
#else
    expect_no_reset(FWI_NONE, "clean state");
    CHECK(WPUA == 0x08u, "init must replace WPUA reset state with RA3-only");
    expect_no_reset(FWI_VALID_ENGAGED, "valid engaged state");
    expect_reset(FWI_PROGRAM_STATE_OOR, "invalid program state");
    expect_reset(FWI_EFFECT_STATE_OOR, "invalid effect state");
    expect_reset(FWI_COUNTER_OOR, "invalid debounce counter");
    expect_reset(FWI_PULLUP_LATCH_CLEARED, "missing pull-up latch");
    expect_reset(FWI_PULLUP_EXTRA_RA0, "extra RA0 pull-up latch");
    expect_reset(FWI_PULLUP_EXTRA_RA1, "extra RA1 pull-up latch");
    expect_reset(FWI_PULLUP_EXTRA_RA2, "extra RA2 pull-up latch");
    expect_reset(FWI_PULLUP_GLOBAL_OFF, "global pull-up disable");
    expect_reset(FWI_LED_PIN_TO_INPUT, "RA0 direction fault");
    expect_reset(FWI_CTL1_PIN_TO_INPUT, "RA1 direction fault");
    expect_reset(FWI_RA2_PIN_TO_INPUT, "RA2 direction fault");
    // RA0 is the LED on every variant: this pre-gate intent injection resets.
    expect_reset(FWI_LATA_RA0_HIGH, "RA0 output-latch fault");
#if defined(TQ2_L2_5V_RELAY)
    // RA1/RA2 are the coils: the same reset every other latch bit gets, plus the
    // de-energization that has to happen before the spin.
    expect_coil_fault_escalates(FWI_LATA_RA1_HIGH, "RA1 RESET-coil latch fault");
    expect_coil_fault_escalates(FWI_LATA_RA2_HIGH, "RA2 SET-coil latch fault");
#else
    expect_reset(FWI_LATA_RA1_HIGH, "RA1 output-latch fault");
    expect_reset(FWI_LATA_RA2_HIGH, "RA2 output-latch fault");
#endif
    expect_reset(FWI_OSCCON_IRCF_SKEW, "oscillator configuration fault");
    expect_reset(FWI_WDTPS_SKEW, "watchdog configuration fault");
    expect_reset(FWI_PR2_SKEW, "timer period fault");
    expect_reset(FWI_T2CON_SKEW, "timer control fault");
    expect_reset(FWI_ANSELA_SKEW_RA0, "RA0 analog-selection fault");
    expect_reset(FWI_ANSELA_SKEW_RA1, "RA1 analog-selection fault");
    expect_reset(FWI_ANSELA_SKEW_RA2, "RA2 analog-selection fault");
    CHECK(fw_fault_run(FWI_HARNESS_STALL) == -1,
          "timeout outside the reset path must be a harness error, not a reset");
#endif
}

static void test_happy_path(void) {
    uint8_t stimulus[128];
    int n = 0;
    for (int i = 0; i < 3; ++i) stimulus[n++] = 0u;
    for (int i = 0; i < 20; ++i) stimulus[n++] = 1u;
    CHECK(fw_drive(stimulus, n) == 0x01u, "clean press should engage");

    n = 0;
    for (int i = 0; i < 3; ++i) stimulus[n++] = 0u;
    for (int i = 0; i < 20; ++i) stimulus[n++] = 1u;
    for (int i = 0; i < 30; ++i) stimulus[n++] = 0u;
    for (int i = 0; i < 20; ++i) stimulus[n++] = 1u;
    CHECK(fw_drive(stimulus, n) == 0x00u, "second press should bypass");

    n = 0;
    for (int i = 0; i < 30; ++i) stimulus[n++] = 1u;
    CHECK(fw_drive(stimulus, n) == 0x00u, "power-on hold should remain bypassed");

    n = 0;
    for (int i = 0; i < 30; ++i) stimulus[n++] = 1u;
    for (int i = 0; i < 30; ++i) stimulus[n++] = 0u;
    for (int i = 0; i < 20; ++i) stimulus[n++] = 1u;
    CHECK(fw_drive(stimulus, n) == 0x01u, "fresh press after release should engage");
}

#if defined(TQ2_L2_5V_RELAY)
// The EXCLUDED window, characterized rather than guarded. Between the shared
// driver's pre-pulse clear and its post-pulse clear -- the 12 ms blocking
// actuation included -- no sanity gate runs, so an upset arriving there is not
// escalated and not corrected. These cases record what the shipping driver
// actually does across that window; they are residual-risk evidence, not a
// claim that an external output accepts the write or that the relay cannot
// move. They do not cover the instruction boundaries between the pre-clear,
// the coil assertion, the delay, and the post-clear.
static void test_relay_pulse_fault_window(void) {
    static const uint8_t offsets_ms[] = { 1u, 6u, 11u };
    size_t i;
    int engaged;
    int inactive_high;

    for (engaged = 0; engaged <= 1; ++engaged) {
        for (inactive_high = 0; inactive_high <= 1; ++inactive_high) {
            for (i = 0u; i < sizeof offsets_ms / sizeof offsets_ms[0]; ++i) {
                fw_relay_pulse_observation_t observation;
                uint8_t expected_physical;
                uint8_t expected_intent;
                int const result = fw_relay_pulse_fault_run(engaged,
                        inactive_high, offsets_ms[i], &observation);

                expected_physical =
                    inactive_high != 0 ? FW_RELAY_COIL_MASK : 0u;
#if defined(BYPASS_MCU_PIC12F675)
                // A modeled GPIO/readback upset does not corrupt the
                // authoritative SRAM shadow; the normal post-pulse writes
                // reconcile both views.
                expected_intent = observation.active_mask;
#else
                // PIC10F322 has no independent modeled port readback in this
                // shell; its writable and observable output state is LATA.
                expected_intent = expected_physical;
#endif
                CHECK(result == 0 &&
                      observation.delay_ms == TQ2_L2_5V_PULSE_MS &&
                      observation.offset_ms == offsets_ms[i] &&
                      observation.entry_intent == observation.active_mask &&
                      observation.entry_physical == observation.active_mask &&
                      observation.injected_intent == expected_intent &&
                      observation.injected_physical == expected_physical &&
                      observation.injections == 1u &&
                      observation.injected_at_ms == offsets_ms[i] &&
                      observation.remaining_ms ==
                          (uint8_t)(TQ2_L2_5V_PULSE_MS - offsets_ms[i]) &&
                      observation.persistence_samples ==
                          observation.remaining_ms &&
                      observation.persisted_to_delay_end != 0u &&
                      observation.final_intent == 0u &&
                      observation.final_physical == 0u,
                      "%s pulse %s fault at %u ms must persist through the blocking "
                      "window and finish with both coils low "
                      "(r=%d delay=%u entry=%02x/%02x injected=%02x/%02x "
                      "count=%u at=%u remaining=%u samples=%u persisted=%u "
                      "final=%02x/%02x)",
                      engaged != 0 ? "SET" : "RESET",
                      inactive_high != 0 ? "inactive-high" : "active-low",
                      offsets_ms[i], result, observation.delay_ms,
                      observation.entry_intent, observation.entry_physical,
                      observation.injected_intent, observation.injected_physical,
                      observation.injections,
                      observation.injected_at_ms, observation.remaining_ms,
                      observation.persistence_samples,
                      observation.persisted_to_delay_end,
                      observation.final_intent, observation.final_physical);
            }
        }
    }
}

#if defined(BYPASS_MCU_PIC12F675)
// hw_outputs_reassert_safe() now runs on the escalation path rather than at
// loop top, but WHAT it must do is unchanged and is unique to this part: with
// no LATx, two sequential single-pin clears could replay the other coil's
// corrupt shadow bit onto the physical port between them. One masked clear --
// both shadow bits down, then exactly one whole-port write -- is the only
// ordering that cannot. A mutation restoring the sequential form is killed
// here.
static void test_relay_reassert_atomic_clear(void) {
    static const uint8_t initial_coils[] = {
        (uint8_t)(1u << RELAY_RESET_PIN),
        (uint8_t)(1u << RELAY_SET_PIN),
        FW_RELAY_COIL_MASK
    };
    uint8_t const led_mask = (uint8_t)(1u << LED_PIN);
    uint8_t const spare_mask = (uint8_t)(1u << SPARE_OUTPUT_PIN);
    size_t i;

    for (i = 0u; i < sizeof initial_coils / sizeof initial_coils[0]; ++i) {
        fw_relay_reassert_observation_t observation;
        int const result =
            fw_relay_reassert_run(initial_coils[i], &observation);

        CHECK(result == 0 &&
              observation.entry_shadow ==
                  (uint8_t)(led_mask | initial_coils[i]) &&
              observation.entry_gpio == spare_mask &&
              observation.gpio_writes == 1u &&
              observation.physical_coil_high_samples == 0u &&
              observation.final_shadow == led_mask &&
              observation.final_gpio == led_mask,
              "relay reassert from shadow coils %02x must clear both bits "
              "before one whole-port write and preserve full-port refresh "
              "(r=%d entry=%02x/%02x writes=%u high=%u final=%02x/%02x)",
              initial_coils[i], result,
              observation.entry_shadow, observation.entry_gpio,
              observation.gpio_writes,
              observation.physical_coil_high_samples,
              observation.final_shadow, observation.final_gpio);
    }
}
#endif
#endif

static void test_pure_fault_path(void) {
    debounce_context_t ctx;
    ctx.program_state = (program_state_t)2;
    ctx.effect_state = BYPASS;
    ctx.debounce_counter = 0u;
    debounce_step_result_t result = debounce_step(ctx);
    CHECK(result.fault, "pure core must flag an invalid program state");
}

// The total assertion count is pinned so a variant that silently stops running
// a case cannot pass.  Reset cases assert once; each coil-escalation case
// asserts twice (forced reset, plus outputs settled low -- the de-energization),
// so the relay variant adds exactly one check per coil case: the 2 coil-latch
// cases on the PIC10F322, and on the PIC12F675 the 2 coil-shadow plus 2
// coil-port cases.  The PIC12F675 relay's parked-GP4 shadow case adds NO check:
// its pre-spin physical-pin observation is folded into the single check the
// CD4053 arm already spends there, so this total is variant-independent for
// that case.  Expressed as base + count rather than a fresh magic number,
// so the delta stays tied to the cases above. The relay variant also adds the 12-case active-pulse
// characterization matrix. The base includes one post-check persisted-context
// transaction case on every variant. Mirrors PIC_FAULT_EXPECTED_CHECKS in the
// gpsim fault adapters apart from the host-only transaction and pulse probes.
#if defined(BYPASS_MCU_PIC12F675)
#define FW_DEVICE_NAME     "PIC12F675"
#define FW_BASE_CHECKS     86
// Coil-escalation cases spend a SECOND check on the de-energization assertion;
// every other injection contributes exactly one. Four here (both coils in both
// the shadow and modeled-GPIO views), two on the PIC10F322, which has a real
// latch and therefore no port-only injections.
#define FW_COIL_ESCALATION_CASES 4
#else
#define FW_DEVICE_NAME     "PIC10F322"
#define FW_BASE_CHECKS     53
#define FW_COIL_ESCALATION_CASES 2
#endif
#if defined(TQ2_L2_5V_RELAY)
#define FW_RELAY_PULSE_CASES 12
#if defined(BYPASS_MCU_PIC12F675)
#define FW_RELAY_REASSERT_CASES 3
#else
#define FW_RELAY_REASSERT_CASES 0
#endif
#define FW_EXPECTED_CHECKS \
    (FW_BASE_CHECKS + FW_COIL_ESCALATION_CASES + FW_RELAY_PULSE_CASES + \
     FW_RELAY_REASSERT_CASES)
#else
#define FW_EXPECTED_CHECKS FW_BASE_CHECKS
#endif

int main(void) {
    test_predicates();
    test_faults();
    test_happy_path();
#if defined(TQ2_L2_5V_RELAY)
    test_relay_pulse_fault_window();
#if defined(BYPASS_MCU_PIC12F675)
    test_relay_reassert_atomic_clear();
#endif
#endif
    test_pure_fault_path();
    if (g_checks != FW_EXPECTED_CHECKS) {
        g_failures++;
        fprintf(stderr, "FAIL: %s coverage harness ran %d checks, expected %d\n",
                FW_DEVICE_NAME, g_checks, FW_EXPECTED_CHECKS);
    }
    printf("PIC shipping-source coverage harness: %d checks, %d failures\n",
           g_checks, g_failures);
    return g_failures ? 1 : 0;
}
