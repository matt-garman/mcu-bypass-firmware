// Copyright (c) Matthew Garman.  All rights reserved.
// Licensed under the MIT License. See LICENSE in the project root for
// license information.

#ifndef BYPASS_PINS_AVR_CLASSIC_H__
#define BYPASS_PINS_AVR_CLASSIC_H__


#include <stdint.h>


// Classic-AVR (ATtiny13a / tinyx5) pin map — PORTB/DDRB/PINB bit positions.
// PB0 = footswitch (input), PB1..PB4 = outputs, PB5 = RESET (input, untouched).
// Single source of truth for the classic-AVR pinout.
//
// footswitch and status LED pins are common across all output variants
//   - FOOTSW_PIN is configured for input, with both internal and external
//     pullup resistors
//   - LED_PIN is output
#define FOOTSW_PIN (0U) // PB0
#define LED_PIN    (1U) // PB1

// CD4053 simple
#define CD4053_PIN (2U)

// dual-latching mechanical relay bypass (e.g. Panasonic TQ2-2L)
#define RELAY_RESET_PIN (2U) // PB2
#define RELAY_SET_PIN   (3U) // PB3

// CD4053 with muting
#define CD4053_CTL1 (2U) // PB2
#define CD4053_CTL2 (3U) // PB3


// NOTE: all three variants (4053-simple, 4053-with-mute, tq2-l2 relay) have
// the same output mask:
//
//   PB0 => input (footswitch)
//   PB1-PB4 are outputs (driven low in init())
//   PB5 => unused (also functions as AVR Classic RESET)
#define BYPASS_OUTPUT_DDR_MASK (0x1EU) // ((uint8_t)((1U<<1)|(1U<<2)|(1U<<3)|(1U<<4)))


#endif // BYPASS_PINS_AVR_CLASSIC_H__
