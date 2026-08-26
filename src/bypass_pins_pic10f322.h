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
// All three variants use RA0..RA2:
//    tq2_l2_5v_relay = LED(RA0)/RESET(RA1)/SET(RA2)
//    cd4053_with_mute = LED(RA0)/CTL1(RA1)/CTL2(RA2)
//    cd4053_simple = LED(RA0)/CD4053(RA1),
// leaving RA2 a spare driven low. Mask 0x07 for all.
#define BYPASS_OUTPUT_DDR_MASK (0x07U)  // RA0|RA1|RA2


// Watchdog pet-to-pet budget, consumed by the shared output drivers through
// WDT_PET_TO_PET_MAX_MS() (bypass_output_common.h): the worst-case WALL-CLOCK
// interval between two watchdog pets must stay under the WORST-CASE WDT period
// (de-rated minima, never nominal). Asserted in bypass_output_*.c. See
// "Watchdog pet-to-pet budget" in DESIGN_DOCUMENTATION.adoc for the derivation
// and the measured corroboration of each term below.
#define TICK_PERIOD_MS    (1U)    // ~1 ms TMR2 tick
#define WDT_MIN_PERIOD_MS (160U)  // WDTPS=0x08 ~256 ms nom; param 31 (-37%) -> ~160 ms floor

// Bounded non-blocking work in the pet-to-pet window: init()'s configuration on
// the boot path, or sanity gate + integrate + step between the polled TMR2IF
// tick and the CLRWDT in steady state. One whole tick is the allowance; a body
// that outran a tick would stop being tick-gated at all, which the gpsim
// free-run checkpoint fails on.
#define WDT_LOOP_WORK_MS  (1U)

// No ISR preemption term: this shell is a single POLLED loop with GIE clear and
// no interrupt service routine. The shared input is wall-time ISR duty, so zero
// duty converts to exactly zero additive stretch. A shell that acquired an
// interrupt would have to re-derive this.
#define WDT_ISR_STRETCH_PCT (0U)


#endif // BYPASS_PINS_PIC10F322_H__
