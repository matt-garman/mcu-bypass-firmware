// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

#ifndef BYPASS_PINS_AVR_CLASSIC_H__
#define BYPASS_PINS_AVR_CLASSIC_H__


#include <stdint.h>

// Classic-AVR (ATtiny13a / tinyx5) pin map: PORTB/DDRB/PINB bit positions.
// PB0 = footswitch (input), PB1..PB4 = outputs, PB5 = RESET (input, untouched).
// Single source of truth for the classic-AVR pinout.
//
// see also PIC counterpart bypass_pins_pic10f322.h
//
// footswitch and status LED pins are common across all output variants
//   - FOOTSW_PIN is configured for input, with both internal and external
//     pullup resistors
//   - LED_PIN is output
#define FOOTSW_PIN (0U) // PB0
#define LED_PIN    (1U) // PB1

// CD4053 simple
#define CD4053_PIN (2U)

// CD4053 with muting
#define CD4053_CTL1 (2U) // PB2
#define CD4053_CTL2 (3U) // PB3

// dual-latching mechanical relay bypass (e.g. Panasonic TQ2-2L)
#define RELAY_RESET_PIN (2U) // PB2
#define RELAY_SET_PIN   (3U) // PB3


// NOTE: all three variants (4053-simple, 4053-with-mute, tq2-l2 relay) have
// the same output mask:
//
//   PB0 => input (footswitch)
//   PB1-PB4 are outputs (driven low in init())
//   PB5 => unused (also functions as AVR Classic RESET)
#define BYPASS_OUTPUT_DDR_MASK (0x1EU) // ((uint8_t)((1U<<1)|(1U<<2)|(1U<<3)|(1U<<4)))


// Watchdog pet-to-pet budget, consumed by the shared output drivers through
// WDT_PET_TO_PET_MAX_MS() (bypass_output_common.h): the worst-case WALL-CLOCK
// interval between two watchdog pets must stay under the WORST-CASE WDT period
// (de-rated minima, never nominal). Asserted in bypass_output_*.c. See
// "Watchdog pet-to-pet budget" in DESIGN_DOCUMENTATION.adoc for the derivation
// and the measured corroboration of each term below.
#define TICK_PERIOD_MS    (1U)    // 1 ms Timer0 CTC tick
#define WDT_MIN_PERIOD_MS (100U)  // WDTO_250MS nom; WDT RC osc characterized 100-350 ms -> 100 ms floor

// Bounded NON-BLOCKING work inside the pet-to-pet window, in wall time. Two
// paths contribute and one allowance covers both:
//   boot    init()'s register configuration, and then -- after the tick wait --
//           the first loop pass up to the pet. This is the longer of the two;
//           it is also where the ISR-stretch term below is pure headroom,
//           because init() runs with interrupts disabled.
//   steady  one loop pass alone: sanity gate, context transaction, debounce
//           step.
// One whole tick is the allowance. A steady-state pass must already finish
// inside a tick or the loop would drift off the 1 ms sample cadence, which the
// lock-step and soak lanes fail on; init() is bounded straight-line register
// writes.
// Measured worst case (simavr): 0.46 ms of the 1 ms allowance, on the boot path
// at 1.0 MHz. test/avr/test_sim.c re-measures the real image against this whole
// budget on every run, so the allowance is not left as an unchecked assertion.
#define WDT_LOOP_WORK_MS  (1U)

// ISR preemption allowance. This shell is INTERRUPT-DRIVEN: the 1 ms tick ISR
// preempts the busy-wait inside a blocking actuation, so the actuation is
// longer in WALL time than the delay body it compiles to. The term is the
// percentage of each tick the ISR may own.
// Measured worst case (simavr): 142 ISR cycles per tick = 11.8% at 1.2 MHz
// (ATtiny13A) and 14.2% at 1.0 MHz (ATtiny25/45/85). 25% keeps ~1.8x margin on
// the worse of the two and MUST be re-derived if the ISR grows.
#define WDT_ISR_STRETCH_PCT (25U)



#endif // BYPASS_PINS_AVR_CLASSIC_H__
