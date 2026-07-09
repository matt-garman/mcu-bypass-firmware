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
// cd4053-simple variant leaves PA3 a spare driven low. ("DDR" is legacy AVR
// wording, kept for a single cross-MCU macro name.)
#define BYPASS_OUTPUT_DDR_MASK (0x0EU) // PA1|PA2|PA3

#endif // BYPASS_PINS_AVR_XT_H__

