// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

#ifndef BYPASS_PINS_AVR_XT_H__
#define BYPASS_PINS_AVR_XT_H__

#include <stdint.h>

// AVR-XT (tinyAVR-0/1, e.g. ATtiny202) pin map: a single 8-bit PORTA.
// The ATtiny202 is an 8-pin part: PA0 is the UPDI/programming pin (kept as UPDI
// via the RSTPINCFG fuse, NOT used as GPIO), and PA4/PA5 are not bonded out on
// the 8-pin package. That leaves PA1, PA2, PA3, PA6, PA7 as usable I/O.
//
// See also the classic-AVR (bypass_pins_avr_classic.h) and PIC
// (bypass_pins_pic10f322.h) counterparts. Selected by bypass_output_common.h on
// the BYPASS_MCU_AVR_XT build macro. Bit positions are pinned to <avr/io.h>'s
// generic PINn_bp by compile-time asserts in bypass_mcu_avr_xt.c.
//
// Footswitch and status LED pins are common across all output variants:
//   - FOOTSW_PIN: input with internal pull-up (on PA7, well clear of UPDI/PA0)
//   - LED_PIN:    output
#define FOOTSW_PIN (7U) // PA7, input + internal pull-up
#define LED_PIN    (1U) // PA1

// CD4053 simple
#define CD4053_PIN (2U) // PA2

// CD4053 with muting
#define CD4053_CTL1 (2U) // PA2
#define CD4053_CTL2 (3U) // PA3

// dual-latching mechanical relay bypass (e.g. Panasonic TQ2-2L)
#define RELAY_RESET_PIN (2U) // PA2
#define RELAY_SET_PIN   (3U) // PA3

// Bits that must be OUTPUTS (PA1|PA2|PA3). Same macro NAME as the other maps
// (the shared output drivers consume it); the value is interpreted by the
// per-MCU hw_configure_output_pins() (AVR-XT: PORTA.DIR bit = 1 => output).
// All three variants use PA1..PA3: LED(PA1) + two control pins (PA2/PA3); the
// cd4053_simple variant leaves PA3 a spare driven low. ("DDR" is legacy AVR
// wording, kept for a single cross-MCU macro name.)
//
// we also include PA6 here: it's unused, but we don't want it to float, so
// we'll configure it as an output driven low.
//
//   PA0 => UPDI/input
//   PA1-PA3 => outputs
//   PA4-PA5 => unbonded inputs
//   PA6 => spare low-driven output
//   PA7 => footswitch input
#define BYPASS_OUTPUT_DDR_MASK (0x4EU) // PA1|PA2|PA3|PA6



// Watchdog pet-to-pet budget, consumed by the shared output drivers through
// WDT_PET_TO_PET_MAX_MS() (bypass_output_common.h): the worst-case WALL-CLOCK
// interval between two watchdog pets must stay under the WORST-CASE WDT period
// (de-rated minima, never nominal). Asserted in bypass_output_*.c. See
// "Watchdog pet-to-pet budget" in DESIGN_DOCUMENTATION.adoc for the derivation
// and the measured corroboration of each term below.
#define TICK_PERIOD_MS    (1U)    // 1 ms TCB0 periodic tick
#define WDT_MIN_PERIOD_MS (128U)  // PERIOD=256CLK ~256 ms nom; de-rated 50% for
                                  // ATtiny202 OSCULP32K accuracy (datasheet)

// Bounded non-blocking work in the pet-to-pet window (boot: init() plus the
// first loop pass; steady state: one loop pass) -- see the classic-AVR map for
// the shape of the term. The AVR-XT runs the same code at 2 MHz, so one tick is
// a wider allowance here than the 0.46 ms measured there.
#define WDT_LOOP_WORK_MS  (1U)

// ISR preemption allowance. Interrupt-driven, like the classic shell. No
// cycle-accurate AVR-XT simulator is trusted for this measurement (see the
// yasimavr stepping note in test/README.md), so the term is bounded from the
// built image instead: the TCB0 ISR and its callees are 84 instructions, and no
// AVR-XT instruction the shell emits exceeds 3 cycles, so the ISR cannot exceed
// 252 of the 2000 cycles in a 1 ms tick at 2 MHz (12.6%). The classic map's
// 25% therefore bounds this part too, with the same re-derivation duty.
#define WDT_ISR_STRETCH_PCT (25U)



#endif // BYPASS_PINS_AVR_XT_H__

