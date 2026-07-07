// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

#ifndef BYPASS_COMPILE_CHECKS_H__
#define BYPASS_COMPILE_CHECKS_H__

// Shared, MCU-NEUTRAL compile-time contract for the debounce thresholds.
// Included by every hardware shell (bypass_mcu_avr_classic.c,
// bypass_mcu_pic10f322.c) so the invariant lives in ONE place and cannot drift
// between shells. MCU-SPECIFIC compile-time checks stay in their shells: the
// -fshort-enums size asserts, the F_CPU / _XTAL_FREQ checks, and the per-MCU
// pin-map pinning.

#include "bypass_config.h"        // PRESSED_THRESH / RELEASE_THRESH
#include "bypass_static_assert.h" // static_assert()


// Upper bound for values stored in the uint8_t debounce counter, as an
// UNSIGNED constant. We deliberately do NOT use <stdint.h>'s UINT8_MAX: by C
// integer-promotion rules a uint8_t promotes to (signed) int, so UINT8_MAX
// itself has type int. Comparing it to our unsigned thresholds is an
// essential-type-category mix (MISRA 10.4), and its expansion (0x7f*2+1) also
// trips MISRA 12.1. A plain unsigned literal means the same thing and avoids
// both -- see MISRA_COMPLIANCE.md.
//
// Loosely speaking: MISRA-C compliant UINT8_MAX
#define DEBOUNCE_COUNTER_MAX (255U)


// MCU-neutral threshold invariants -- identical across all shells, so defined
// once here. Evaluated at file scope (zero runtime cost); a violation fails the
// build of every shell that includes this header.
static_assert(RELEASE_THRESH < DEBOUNCE_COUNTER_MAX, "RELEASE_THRESH >= UINT8_MAX");
static_assert(RELEASE_THRESH > 0U,                   "RELEASE_THRESH <= 0");
static_assert(RELEASE_THRESH > PRESSED_THRESH,       "RELEASE_THRESH <= PRESSED_THRESH");
static_assert(PRESSED_THRESH < DEBOUNCE_COUNTER_MAX, "PRESSED_THRESH >= UINT8_MAX");
static_assert(PRESSED_THRESH > 0U,                   "PRESSED_THRESH <= 0");


#endif // BYPASS_COMPILE_CHECKS_H__
 
