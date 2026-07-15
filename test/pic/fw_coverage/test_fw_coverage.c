// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

#include <stdint.h>
#include <stdio.h>

#include "xc.h"
#include "fw_coverage_harness.h"
#include "bypass_pure.h"

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
}

static void test_predicates(void) {
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
#if !defined(CD4053_SIMPLE)
    CHECK(fwp_sanity_failed(BYPASS) != 0,
          "RA2 input must fail this variant's output sanity");
#endif

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
}

static void expect_reset(fw_inject_t inj, const char *what) {
    int r = fw_fault_run(inj);
    CHECK(r == 1, "%s must force reset (got %d)", what, r);
}

static void expect_no_reset(fw_inject_t inj, const char *what) {
    int r = fw_fault_run(inj);
    CHECK(r == 0, "%s must not force reset (got %d)", what, r);
}

static void test_faults(void) {
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
#if defined(CD4053_SIMPLE)
    expect_no_reset(FWI_RA2_PIN_TO_INPUT, "simple-variant spare RA2 direction fault");
#else
    expect_reset(FWI_RA2_PIN_TO_INPUT, "RA2 direction fault");
#endif
    expect_reset(FWI_LATA_RA0_HIGH, "RA0 output-latch fault");
    expect_reset(FWI_LATA_RA1_HIGH, "RA1 output-latch fault");
    expect_reset(FWI_LATA_RA2_HIGH, "RA2 output-latch fault");
    expect_reset(FWI_OSCCON_IRCF_SKEW, "oscillator configuration fault");
    expect_reset(FWI_WDTPS_SKEW, "watchdog configuration fault");
    expect_reset(FWI_PR2_SKEW, "timer period fault");
    expect_reset(FWI_T2CON_SKEW, "timer control fault");
    expect_reset(FWI_ANSELA_SKEW_RA0, "RA0 analog-selection fault");
    expect_reset(FWI_ANSELA_SKEW_RA1, "RA1 analog-selection fault");
    expect_reset(FWI_ANSELA_SKEW_RA2, "RA2 analog-selection fault");
    CHECK(fw_fault_run(FWI_HARNESS_STALL) == -1,
          "timeout outside the reset path must be a harness error, not a reset");
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

static void test_pure_fault_path(void) {
    debounce_context_t ctx;
    ctx.program_state = (program_state_t)2;
    ctx.effect_state = BYPASS;
    ctx.debounce_counter = 0u;
    debounce_step_result_t result = debounce_step(ctx);
    CHECK(result.fault, "pure core must flag an invalid program state");
}

int main(void) {
    test_predicates();
    test_faults();
    test_happy_path();
    test_pure_fault_path();
    printf("PIC shipping-source coverage harness: %d checks, %d failures\n",
           g_checks, g_failures);
    return g_failures ? 1 : 0;
}
