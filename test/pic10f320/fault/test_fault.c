// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// Firmware fault-injection + defensive-path test driver.
//
// Proves the PIC10F320 firmware's fault-detection layer -- which the
// firmware<->model equivalence test deliberately never reaches -- actually
// works on the SHIPPING code:
//
//   A. Predicate probes: the static sanity predicates (output-pin direction,
//      footswitch pull-up, footswitch read) return the right verdict for both
//      good and SEU-corrupted SFR state.
//   B. Fault injection: after one clean main-loop iteration, an SEU/EMI flip of
//      the firmware's runtime state or a critical SFR makes the next iteration's
//      sanity gate force a watchdog reset (and valid states do NOT) -- end to
//      end, through the real main() loop and hw_force_wdt_reset().
//   C. Happy path: a few presses/releases drive the firmware's normal toggle
//      lines (so this harness, combined with A+B, covers the whole firmware TU
//      for the coverage gate). The equivalence test remains the behavioural
//      oracle; the checks here are a light cross-check.
//
// All firmware interaction goes through fw_fault_harness.c (which #includes the
// real firmware). SFRs are the extern mock symbols from <xc.h>.

#include <stdint.h>
#include <stdio.h>

#include "xc.h"               // mock: extern SFR declarations + types
#include "fw_fault_harness.h"

static int g_checks = 0;
static int g_failures = 0;

#define CHECK(cond, ...) do {                                  \
    g_checks++;                                                \
    if (!(cond)) {                                             \
        g_failures++;                                          \
        fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__);   \
        fprintf(stderr, __VA_ARGS__);                          \
        fprintf(stderr, "\n");                                 \
    }                                                          \
} while (0)

// Set a known-good post-init SFR state for the predicate probes.
static void sfr_clean(void) {
    TRISA = 0x08u;              // RA0..RA2 outputs, RA3 input (matches init())
    WPUA  = (uint8_t)(1u << 3); // footswitch pull-up latch on
    OPTION_REGbits.nWPUEN = 0u; // global pull-ups enabled (active-low)
    PORTA = (uint8_t)(1u << 3); // footswitch released
    INTCONbits.GIE = 1u;
}

//////////////////////////////////////////////////////////////////////////////
// A. Predicate probes
//////////////////////////////////////////////////////////////////////////////
static void test_predicates(void) {
    sfr_clean();
    CHECK(fwp_output_pins_intact((uint8_t)((1u << 0) | (1u << 1))) != 0,
          "clean: LED+CD4053 should read as outputs");
    CHECK(fwp_output_pins_intact(0x07u) != 0, "clean: RA0..RA2 should all be outputs");
    CHECK(fwp_sanity_failed() == 0, "clean: no sanity failure expected");
    CHECK(fwp_pullup_intact() != 0, "clean: pull-up should read intact");
    CHECK(fwp_footswitch_is_high() == 1, "clean: released footswitch reads HIGH");

    // footswitch pressed
    sfr_clean(); PORTA &= (uint8_t)~(1u << 3);
    CHECK(fwp_footswitch_is_high() == 0, "pressed footswitch reads LOW");

    // LED pin (RA0) flipped to input -- SEU on TRISA bit 0
    sfr_clean(); TRISA |= (uint8_t)(1u << 0);
    CHECK(fwp_output_pins_intact(0x01u) == 0, "RA0 as input must read NOT intact");
    CHECK(fwp_sanity_failed() != 0, "lost LED output must flag sanity failure");

    // CD4053 pin (RA1) flipped to input -- SEU on TRISA bit 1
    sfr_clean(); TRISA |= (uint8_t)(1u << 1);
    CHECK(fwp_sanity_failed() != 0, "lost CD4053 output must flag sanity failure");

    // RA2 flipped to input -- SEU on TRISA bit 2.  RA2 is load-bearing for
    // mute/relay variants (CTL2/SET coil); for cd4053-simple it
    // is configured as an output but not logically driven, so the firmware does
    // not expect it as an output and flipping it to input must NOT be a reset.
    // The variant sweep covers both cases.
    sfr_clean(); TRISA |= (uint8_t)(1u << 2);
    CHECK(fwp_output_pins_intact(0x04u) == 0, "RA2 as input must read NOT intact");
#if !defined(OUTPUT_CD4053_SIMPLE)
    CHECK(fwp_sanity_failed() != 0, "lost RA2 output must flag sanity failure");
#endif

    // pull-up latch cleared -- SEU on WPUA
    sfr_clean(); WPUA &= (uint8_t)~(1u << 3);
    CHECK(fwp_pullup_intact() == 0, "cleared WPUA latch must read pull-up NOT intact");

    // Output-pin pull-up latches must remain clear. They are electrically dormant
    // while TRISA says output, but become active immediately after a direction
    // fault and can oppose the external fail-safe pull-down until watchdog reset.
    sfr_clean(); WPUA |= (uint8_t)(1u << 0);
    CHECK(fwp_pullup_intact() == 0, "extra WPUA RA0 latch must read pull-up configuration NOT intact");
    sfr_clean(); WPUA |= (uint8_t)(1u << 1);
    CHECK(fwp_pullup_intact() == 0, "extra WPUA RA1 latch must read pull-up configuration NOT intact");
    sfr_clean(); WPUA |= (uint8_t)(1u << 2);
    CHECK(fwp_pullup_intact() == 0, "extra WPUA RA2 latch must read pull-up configuration NOT intact");

    // global pull-up disable -- SEU on OPTION_REG nWPUEN
    sfr_clean(); OPTION_REGbits.nWPUEN = 1u;
    CHECK(fwp_pullup_intact() == 0, "global nWPUEN=1 must read pull-up NOT intact");
}

//////////////////////////////////////////////////////////////////////////////
// B. Fault injection through the real main() loop
//////////////////////////////////////////////////////////////////////////////
// A forced reset is detected by fw_fault_run returning 1: the firmware's ONLY
// spin point is hw_force_wdt_reset() (the mock makes the TMR2IF tick always
// ready, so the poll loop never hangs), so "the run had to be timed out" means
// the sanity gate fired and entered the reset path. This signal is robust at any
// optimisation level. (We deliberately do NOT also assert the GIE=0 store the
// reset path makes: the mock SFRs are non-volatile, so at -O2 that store -- dead,
// since it is followed by a non-returning loop that never reads it -- can be
// optimised away. The reset-fired signal already proves the path was taken.)
static void expect_reset(fw_inject_t inj, const char *what) {
    int r = fw_fault_run(inj);
    CHECK(r == 1, "corruption [%s] must force a watchdog reset (got r=%d)", what, r);
}
static void expect_no_reset(fw_inject_t inj, const char *what) {
    int r = fw_fault_run(inj);
    CHECK(r == 0, "valid state [%s] must NOT force a reset (got r=%d)", what, r);
}
static void test_fault_injection(void) {
    // Negative controls: a valid state must run on without a reset.
    expect_no_reset(FWI_NONE,          "no corruption");
    CHECK(WPUA == (uint8_t)(1u << 3),
          "init must replace WPUA's 0x0F reset value with RA3-only 0x08 (got 0x%02X)",
          (unsigned)WPUA);
    expect_no_reset(FWI_VALID_ENGAGED, "valid ENGAGED/RELEASE-wait state");

    // Positive: each SEU/EMI corruption must be caught by the sanity gate.
    expect_reset(FWI_PROGRAM_STATE_OOR,    "program_state=2 (out of range)");
    expect_reset(FWI_PROGRAM_STATE_MAX,    "program_state=255");
    expect_reset(FWI_EFFECT_STATE_OOR,     "effect_state=2 (out of range)");
    expect_reset(FWI_COUNTER_OOR,          "debounce_counter > RELEASE_THRESH (out of range)");
    expect_reset(FWI_PULLUP_LATCH_CLEARED, "WPUA pull-up latch cleared");
    expect_reset(FWI_PULLUP_EXTRA_RA0,     "WPUA RA0 output-pin pull-up latch set");
    expect_reset(FWI_PULLUP_EXTRA_RA1,     "WPUA RA1 output-pin pull-up latch set");
    expect_reset(FWI_PULLUP_EXTRA_RA2,     "WPUA RA2 output-pin pull-up latch set");
    expect_reset(FWI_PULLUP_GLOBAL_OFF,    "OPTION_REG nWPUEN=1 (global pull-up off)");
    expect_reset(FWI_LED_PIN_TO_INPUT,     "TRISA RA0 (LED) flipped to input");
    expect_reset(FWI_CD4053_PIN_TO_INPUT,  "TRISA RA1 (CD4053/RESET) flipped to input");
    // RA2 is only load-bearing for variants that use it (cd4053-mute /
    // tq2-relay); for cd4053-simple it is a spare output and the
    // sanity check does not include it, so flipping it to input must NOT force a
    // reset. The variant sweep covers both cases.
#if defined(OUTPUT_CD4053_SIMPLE)
    expect_no_reset(FWI_RA2_PIN_TO_INPUT, "TRISA RA2 flipped to input (spare on simple)");
#else
    expect_reset(FWI_RA2_PIN_TO_INPUT, "TRISA RA2 (CTL2/SET) flipped to input");
#endif

    // Critical configuration SFRs (variant-independent): an SEU that skews the
    // clock select, watchdog period, or the 1 ms tick timer off its configured
    // value must force a reset. These four gate checks were previously exercised
    // by neither fault injection nor mutation.
    expect_reset(FWI_OSCCON_IRCF_SKEW, "OSCCON IRCF skewed off the 2 MHz select");
    expect_reset(FWI_WDTPS_SKEW,       "WDTCON WDTPS skewed off the ~256 ms period");
    expect_reset(FWI_PR2_SKEW,         "PR2 skewed off the 1 ms tick reload");
    expect_reset(FWI_T2CON_SKEW,       "T2CON skewed off the configured prescale/enable");
    // ANSELA analog re-selection. Unlike the TRISA output-pin check -- whose mask is
    // per-variant, making RA2 a negative control on cd4053-simple above -- the ANSELA
    // term in hw_critical_sfrs_intact() masks the FIXED BYPASS_OUTPUT_DDR_MASK
    // (RA0|RA1|RA2) on EVERY variant. All three output pins are always driven digital
    // (even the spare RA2 on cd4053-simple), so an analog re-selection of ANY of them
    // must force a reset regardless of output scheme (no per-variant #if here).
    expect_reset(FWI_ANSELA_SKEW_RA0,  "ANSELA RA0 (LED) re-selected analog");
    expect_reset(FWI_ANSELA_SKEW_RA1,  "ANSELA RA1 (control pin) re-selected analog");
    expect_reset(FWI_ANSELA_SKEW_RA2,  "ANSELA RA2 (control pin) re-selected analog");
}

//////////////////////////////////////////////////////////////////////////////
// C. Happy path (covers the firmware's normal toggle lines)
//////////////////////////////////////////////////////////////////////////////
static void test_happy_path(void) {
    uint8_t a[96];
    int n;

    // Released power-on, then a clean press -> ENGAGED.
    n = 0;
    for (int i = 0; i < 3;  ++i) { a[n++] = 0; } // released
    for (int i = 0; i < 20; ++i) { a[n++] = 1; } // press well past PRESSED_THRESH
    CHECK(fw_drive(a, n) == 0x01u, "clean press should drive ENGAGED (LED RA0 on)");

    // Full round trip: engage, release past the lock-out, engage again -> BYPASS.
    // (Released preamble so this is a clean power-on, not a power-on-pressed.)
    n = 0;
    for (int i = 0; i < 3;  ++i) { a[n++] = 0; } // released power-on
    for (int i = 0; i < 20; ++i) { a[n++] = 1; } // engage
    for (int i = 0; i < 30; ++i) { a[n++] = 0; } // release + drain lock-out (>=25)
    for (int i = 0; i < 20; ++i) { a[n++] = 1; } // engage again -> toggles back
    CHECK(fw_drive(a, n) == 0x00u, "second press should toggle back to BYPASS (LED off)");

    // Power-on with the switch HELD: stay BYPASS, never engage while held.
    uint8_t b[96];
    int m = 0;
    for (int i = 0; i < 30; ++i) { b[m++] = 1; } // held pressed from power-on
    CHECK(fw_drive(b, m) == 0x00u, "power-on-pressed must stay BYPASS while held");

    // ...then a genuine release + fresh press engages.
    m = 0;
    for (int i = 0; i < 30; ++i) { b[m++] = 1; } // held at boot
    for (int i = 0; i < 30; ++i) { b[m++] = 0; } // release, drain lock-out
    for (int i = 0; i < 20; ++i) { b[m++] = 1; } // fresh press -> ENGAGED
    CHECK(fw_drive(b, m) == 0x01u, "fresh press after power-on-hold engages (LED on)");
}

int main(void) {
    printf("firmware fault-injection + defensive-path tests:\n");
    test_predicates();
    test_fault_injection();
    test_happy_path();
    printf("firmware fault harness: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
