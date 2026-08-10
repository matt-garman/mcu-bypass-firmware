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
#if defined(BYPASS_MCU_PIC12F675)
    fwp_set_output_state(0u, 0u);
    fwp_set_footswitch(0);
    TRISIO = 0x38u;
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
    CHECK(fwp_output_state_intact(0x07u, 0x00u) != 0,
          "clean outputs should be intact and low");
    CHECK(fwp_sanity_failed(BYPASS) == 0,
          "clean bypass output configuration should pass");
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

    sfr_clean(); TRISIO &= (uint8_t)~0x10u;
    CHECK(fwp_sanity_failed(BYPASS) != 0,
          "spare GP4 output must fail exact direction sanity");
    sfr_clean(); TRISIO &= (uint8_t)~0x20u;
    CHECK(fwp_sanity_failed(BYPASS) != 0,
          "footswitch GP5 output must fail exact direction sanity");

    sfr_clean(); fwp_set_output_state(0x01u, 0x00u);
    CHECK(fwp_sanity_failed(BYPASS) != 0, "GP0 shadow high must fail bypass sanity");
    sfr_clean(); fwp_set_output_state(0x02u, 0x00u);
    CHECK(fwp_sanity_failed(BYPASS) != 0, "GP1 shadow high must fail bypass sanity");
    sfr_clean(); fwp_set_output_state(0x04u, 0x00u);
    CHECK(fwp_sanity_failed(BYPASS) != 0, "GP2 shadow high must fail bypass sanity");

    sfr_clean(); fwp_set_output_state(0x00u, 0x01u);
    CHECK(fwp_sanity_failed(BYPASS) != 0, "physical GP0 divergence must fail sanity");
    sfr_clean(); fwp_set_output_state(0x00u, 0x02u);
    CHECK(fwp_sanity_failed(BYPASS) != 0, "physical GP1 divergence must fail sanity");
    sfr_clean(); fwp_set_output_state(0x00u, 0x04u);
    CHECK(fwp_sanity_failed(BYPASS) != 0, "physical GP2 divergence must fail sanity");

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

static void test_faults(void) {
#if defined(BYPASS_MCU_PIC12F675)
    expect_no_reset(FWI_NONE, "clean state");
    CHECK(WPU == 0x20u, "init must replace WPU reset state with GP5-only");
    CHECK(OPTION_REG == 0x0cu, "init must configure the exact timer/WDT/pull-up byte");
    CHECK(TRISIO == 0x38u, "init must configure exact GP0..GP2 outputs");
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
    expect_reset(FWI_GP4_PIN_TO_OUTPUT, "GP4 direction fault");
    expect_reset(FWI_GP5_PIN_TO_OUTPUT, "GP5 direction fault");
    expect_reset(FWI_SHADOW_GP0_HIGH, "GP0 shadow-latch fault");
    expect_reset(FWI_SHADOW_GP1_HIGH, "GP1 shadow-latch fault");
    expect_reset(FWI_SHADOW_GP2_HIGH, "GP2 shadow-latch fault");
    expect_reset(FWI_GPIO_GP0_HIGH, "physical GP0 divergence");
    expect_reset(FWI_GPIO_GP1_HIGH, "physical GP1 divergence");
    expect_reset(FWI_GPIO_GP2_HIGH, "physical GP2 divergence");
    expect_reset(FWI_OPTION_REG_SKEW, "OPTION_REG configuration fault");
    expect_reset(FWI_CMCON_SKEW, "comparator configuration fault");
    expect_reset(FWI_ADCON0_ADON_SET, "ADC enable fault");
    expect_reset(FWI_ANSEL_SKEW_GP0, "GP0 analog-selection fault");
    expect_reset(FWI_ANSEL_SKEW_GP1, "GP1 analog-selection fault");
    expect_reset(FWI_ANSEL_SKEW_GP2, "GP2 analog-selection fault");
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
#if defined(BYPASS_MCU_PIC12F675)
    if (g_checks != 78) {
        g_failures++;
        fprintf(stderr, "FAIL: PIC12F675 coverage harness ran %d checks, expected 78\n",
                g_checks);
    }
#else
    if (g_checks != 52) {
        g_failures++;
        fprintf(stderr, "FAIL: PIC10F322 coverage harness ran %d checks, expected 52\n",
                g_checks);
    }
#endif
    printf("PIC shipping-source coverage harness: %d checks, %d failures\n",
           g_checks, g_failures);
    return g_failures ? 1 : 0;
}
