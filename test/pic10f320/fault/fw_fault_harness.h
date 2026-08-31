// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// Host harness API for exercising the REAL PIC10F320 firmware's defensive /
// fault-detection paths -- the SEU/EMI sanity gate, the pull-up and output-pin
// checks, and hw_force_wdt_reset() -- which the firmware<->model equivalence
// test (test/pic10f320/equiv) deliberately never reaches (a faithful mock keeps every
// state valid, so a check that only fires on CORRUPTED state is invisible to it).
//
// The implementation (fw_fault_harness.c) #includes the firmware verbatim, so it
// can drive the real main() loop, corrupt the firmware's live state between
// ticks, and observe whether the firmware forces a watchdog reset. See that file
// for the technique. The driver (test/pic10f320/fault/test_fault.c) consumes this API.

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
                              // for cd4053_with_mute / tq2_l2_5v_relay; harmless for cd4053_simple)
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
    // the spare RA2 on cd4053_simple -- so re-selecting ANY of RA0/RA1/RA2 must reset
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

#if defined(OUTPUT_TQ2_RELAY)
// Result of injecting one or both relay-coil latch bits after a clean iteration.
// Under the F1 fail-safe policy (docs/relay_coil_fault_correction.md) an
// energized coil is a FAULT: the next gate escalates it, and
// hw_force_wdt_reset() drives both coils low before it spins.
//
// This host lane proves the FIRST half of that contract -- escalation, and
// de-energization ahead of the spin -- against the shipping source. It does not
// and cannot prove the second half (the recovery RESET-coil command after the
// watchdog reset), because the mock elides __delay_ms() and
// aborts the spin on a timer rather than modelling a reset. The libgpsim fault
// lane (test/pic10f320/gpsim/test_fault_pic.cc) measures that pulse on the real
// image; simulation still proves nothing about relay MECHANICS.
//
//   final_coils          -- the coil latch bits when the reset spin was aborted
//   partial_clear_coils  -- see below; must be 0
//   completed_iterations -- must be 0: no further clean iteration may run
//
// partial_clear_coils is this lane's view of the coil clear's WRITE SEQUENCE.
// set_relay_coils_low() is contracted to drive both coil bits low in ONE
// output write; a per-bit clear reaches the same settled state through a
// different transient, and with BOTH coils energized it leaves the second one
// driven for the whole of the first write. The mock routes every LATA access
// through the harness, so that transient is directly observable here as a coil
// field with strictly fewer bits than the previous one but not none -- which is
// what this field records. It stays 0 for a single masked write.
//
// It is the both-coils injection that carries the check: with only one coil
// energized a per-bit clear delays the useful de-energization by one write but
// passes through no distinct state, so no oracle at this level can see it.
typedef struct {
    uint8_t injected_coils;
    uint8_t observed_coils;
    uint8_t final_coils;
    uint8_t partial_clear_coils;
    uint8_t footswitch_stayed_released;
    uint8_t completed_iterations;
} fw_relay_fault_result_t;

// `coil_mask` must select RESET/RA1, SET/RA2, or both (0x02/0x04/0x06).
// Returns the same reset/no-reset status as fw_fault_run(); an energized coil
// must now return 1.
int fw_relay_fault_run(uint8_t coil_mask, fw_relay_fault_result_t *result);
#endif

// Drive the real firmware over `fsw[0..n-1]` (1 = pressed / RA3 low, 0 =
// released). fsw[0] is the power-on level init() samples. Returns the final
// status-LED bit RA0 (LATA & 0x01): 1 == ENGAGED, 0 == BYPASS (0xFF on an
// unexpected hang). RA0 is the variant-independent effect witness; the variant-
// specific RA1/RA2 levels are asserted in modeled PORTA by the gpsim test. Used
// to drive the firmware's happy-path lines for the coverage gate (and as a light
// behavioural cross-check; the equivalence test remains the behavioural oracle).
uint8_t fw_drive(const uint8_t *fsw, int n);

// Direct probes of the firmware's static defensive predicates, evaluated against
// the CURRENT mock-SFR state (set TRISA/WPUA/PORTA/OPTION_REGbits via the extern
// <xc.h> symbols first, then call).
int fwp_output_pins_intact(void);         // nonzero IFF TRISA exactly matches init()
int fwp_sanity_failed(void);              // nonzero IFF the output-direction gate trips
int fwp_pullup_intact(void);              // nonzero IFF the footswitch pull-up is fully on
int fwp_footswitch_is_high(void);         // 1 IFF RA3 reads HIGH (released), else 0

#endif // FW_FAULT_HARNESS_H
