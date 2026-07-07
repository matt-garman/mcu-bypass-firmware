// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

#ifndef BYPASS_PINS_PIC10F322_H__
#define BYPASS_PINS_PIC10F322_H__


#include <stdint.h>


// PIC10F32x pin map -- PORTA/TRISA/LATA bit positions. The PIC10F32x has only
// 4 I/O: RA0, RA1, RA2 are bidirectional, and RA3 is INPUT-ONLY (it shares
// MCLR/VPP; with MCLRE=OFF it is a plain digital input). So the footswitch (an
// input) goes on RA3, freeing RA0-RA2 as the three outputs.
//
// see also AVR Classic counterpart bypass_pins_avr_classic.h
//
// PIC vs AVR Classic selected by bypass_output_common.h on the
// BYPASS_MCU_PIC10F322 build macro. Bit positions are pinned to the device
// header's _PORTA_RAx_POSN by compile-time asserts in bypass_mcu_pic10f322.c.
//
// footswitch and status LED pins are common across all output variants
#define FOOTSW_PIN      (3U) // RA3 (input-only) + weak pull-up
#define LED_PIN         (0U) // RA0

// CD4053 simple
#define CD4053_PIN      (1U) // RA1

// CD4053 with muting
#define CD4053_CTL1     (1U) // RA1
#define CD4053_CTL2     (2U) // RA2

// dual-latching mechanical relay bypass (e.g. Panasonic TQ2-2L)
#define RELAY_RESET_PIN (1U)  // RA1
#define RELAY_SET_PIN   (2U)  // RA2


// Bits that must be OUTPUTS (RA0|RA1|RA2). Same macro NAME as the AVR map (the
// shared drivers consume it); the value is the output-bit set, interpreted by
// the per-MCU hw_configure_output_pins() (PIC: TRISA bit 0 = output). ("DDR" is
// legacy AVR wording, kept for a single cross-MCU macro name.)
//
// All three variants use RA0..RA2: relay = LED(RA0)/RESET(RA1)/SET(RA2);
// mute = LED(RA0)/CTL1(RA1)/CTL2(RA2); cd4053-simple = LED(RA0)/CD4053(RA1),
// leaving RA2 a spare driven low. Mask 0x07 for all.
#define BYPASS_OUTPUT_DDR_MASK (0x07U)  // RA0|RA1|RA2


#endif // BYPASS_PINS_PIC10F322_H__
