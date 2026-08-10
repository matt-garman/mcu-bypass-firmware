// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// PIC10F32x adapter for the shared libgpsim soak harness -- ONE adapter for TWO
// parts, where the io / lock-step / fault lanes have one each. The PIC10F322 and
// PIC10F320 share a register map and a timebase, and the soak reads nothing else
// about the device, so both Makefile lanes compile this file with their own
// image, processor, FOSC and blocking-actuation duration. Everything stated
// below is a fact about the FAMILY; everything the two parts differ in is
// injected. The mechanism is test/pic/test_soak_pic_core.h.
//
// Build/run via the Makefile:  `make pic10f322-test-soak`
//                              `make pic10f320-test-soak`
//   Neither target is part of `make test` or `make pic10f322-test`: they run for
//   minutes and need the gpsim-dev + libglib2.0-dev headers, which CI may lack.
//   Each skips cleanly when those (or XC8's HEX) are absent.
//   Overrides: PIC10F322_SOAK_VARIANT (cd4053_simple/cd4053_with_mute/
//   tq2_l2_5v_relay), PIC10F322_SOAK_DURATION_MS, etc.

#include "pic/pic10f32x_regs.h"   // device identity: LATA, and the LED bit in it

// TMR2 at 1:4 from 2 MHz gives an exact 1.000 ms tick on both parts of this
// family (src/bypass_mcu_pic10f322.c), so a threshold in ticks and a hold in
// simulated milliseconds are the same number here. The core converts anyway,
// which is what makes this line a claim about the family rather than an
// assumption nobody wrote down.
#define SOAK_TICK_US 1000u

// IMPORTANT (see docs / project notes): gpsim honors WDTCON.WDTPS but its
// calibration does NOT match the datasheet -- at the firmware's WDTPS=0x08 the
// gpsim WDT period is ~1.057 s, not the silicon ~256 ms. The WDT is therefore
// used here purely as a QUALITATIVE liveness signal (a reset == failure); this
// test asserts nothing about WDT timing.
#define SOAK_WDT_NOTE \
    "(NB: gpsim WDT@WDTPS=0x08 ~1.057s, not 256ms -- liveness only)"

#include "pic/test_soak_pic_core.h"
