// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// Host harness API for exercising the REAL PIC10F320 firmware's defensive /
// fault-detection paths -- the SEU/EMI sanity gate, the pull-up and output-pin
// checks, and hw_force_wdt_reset() -- which the firmware<->model equivalence
// test (test/equiv) deliberately never reaches (a faithful mock keeps every
// state valid, so a check that only fires on CORRUPTED state is invisible to it).
//
// The implementation (fw_fault_harness.c) #includes the firmware verbatim, so it
// can drive the real main() loop, corrupt the firmware's live state between
// ticks, and observe whether the firmware forces a watchdog reset. See that file
// for the technique. The driver (test/fault/test_fault.c) consumes this API.

#ifndef FW_FAULT_HARNESS_H
#define FW_FAULT_HARNESS_H

#include <stdint.h>

// A corruption injected AFTER one clean main-loop iteration, modelling an
// SEU/EMI bit-flip of the firmware's runtime state or a critical SFR. The two
// "negative control" entries are valid states that MUST NOT trigger a reset;
// every other entry MUST.
typedef enum {
    FWI_NONE = 0,             // negative control: no corruption at all
    FWI_VALID_ENGAGED,        // negative control: a valid ENGAGED/RELEASE-wait state
    FWI_PROGRAM_STATE_OOR,    // program_state = 2 (outside the 0..1 enum range)
    FWI_PROGRAM_STATE_MAX,    // program_state = 255
    FWI_EFFECT_STATE_OOR,     // effect_state  = 2 (outside the 0..1 enum range)
    FWI_COUNTER_OOR,          // debounce_counter > RELEASE_THRESH (SEU above valid range)
    FWI_PULLUP_LATCH_CLEARED, // WPUA footswitch pull-up latch flipped off
    FWI_PULLUP_EXTRA_RA0,     // WPUA RA0 latch flipped on (must remain RA3-only)
    FWI_PULLUP_EXTRA_RA1,     // WPUA RA1 latch flipped on (must remain RA3-only)
    FWI_PULLUP_EXTRA_RA2,     // WPUA RA2 latch flipped on (must remain RA3-only)
    FWI_PULLUP_GLOBAL_OFF,    // OPTION_REG nWPUEN set (global pull-up disable)
    FWI_LED_PIN_TO_INPUT,     // TRISA RA0 (LED) flipped from output to input
    FWI_CD4053_PIN_TO_INPUT,  // TRISA RA1 (CD4053) flipped from output to input
    FWI_RA2_PIN_TO_INPUT,     // TRISA RA2 flipped from output to input (load-bearing
                              // for cd4053-mute / tq2-relay; harmless for cd4053-simple)
    // Critical configuration SFRs: a bit-flip in the clock select, watchdog
    // period, or the 1ms tick timer must also force a reset. These four gate
    // checks (main()'s IRCF / WDTPS / PR2 / T2CON comparisons) are variant-
    // independent and MUST trip regardless of output scheme.
    FWI_OSCCON_IRCF_SKEW,     // OSCCON IRCF flipped off the 2 MHz select (clock corrupted)
    FWI_WDTPS_SKEW,           // WDTCON WDTPS flipped off the ~256 ms watchdog period
    FWI_PR2_SKEW,             // TMR2 period register PR2 flipped off the 1 ms tick reload
    FWI_T2CON_SKEW,           // T2CON flipped off the configured prescale/enable value
    // ANSELA analog re-selection of an output pin: sets the pin's ANSELA bit so it
    // leaves digital output service while its TRISA direction still reads "output"
    // (so the TRISA output-pin check cannot see it -- only the ANSELA term in
    // hw_critical_sfrs_intact() can). That term masks the FIXED BYPASS_OUTPUT_DDR_MASK
    // (RA0|RA1|RA2) on EVERY variant -- all three pins are always driven digital, even
    // the spare RA2 on cd4053-simple -- so re-selecting ANY of RA0/RA1/RA2 must reset
    // regardless of output scheme (unlike the per-variant TRISA RA2 case above).
    FWI_ANSELA_SKEW_RA0,      // ANSELA RA0 (LED) re-selected analog
    FWI_ANSELA_SKEW_RA1,      // ANSELA RA1 (control pin) re-selected analog
    FWI_ANSELA_SKEW_RA2       // ANSELA RA2 (control pin) re-selected analog
} fw_inject_t;

// Run the real firmware from a clean power-on, let it complete exactly ONE clean
// 1ms iteration, inject `inj`, then observe the NEXT iteration:
//   returns 1  -> the firmware forced a watchdog reset (entered hw_force_wdt_reset)
//   returns 0  -> the firmware completed another clean iteration (no reset)
//   returns -1 -> harness error (should be impossible)
int fw_fault_run(fw_inject_t inj);

// Drive the real firmware over `fsw[0..n-1]` (1 = pressed / RA3 low, 0 =
// released). fsw[0] is the power-on level init() samples. Returns the final
// status-LED bit RA0 (LATA & 0x01): 1 == ENGAGED, 0 == BYPASS (0xFF on an
// unexpected hang). RA0 is the variant-independent effect witness; the variant-
// specific RA1/RA2 control pins are asserted on silicon by the gpsim test. Used
// to drive the firmware's happy-path lines for the coverage gate (and as a light
// behavioural cross-check; the equivalence test remains the behavioural oracle).
uint8_t fw_drive(const uint8_t *fsw, int n);

// Direct probes of the firmware's static defensive predicates, evaluated against
// the CURRENT mock-SFR state (set TRISA/WPUA/PORTA/OPTION_REGbits via the extern
// <xc.h> symbols first, then call).
int fwp_output_pins_intact(uint8_t mask); // nonzero IFF every `mask` pin is an output
int fwp_sanity_failed(void);              // nonzero IFF LED|CD4053 are not both outputs
int fwp_pullup_intact(void);              // nonzero IFF the footswitch pull-up is fully on
int fwp_footswitch_is_high(void);         // 1 IFF RA3 reads HIGH (released), else 0

#endif // FW_FAULT_HARNESS_H
