// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

#ifndef BYPASS_OUTPUT_COMMON_H__
#define BYPASS_OUTPUT_COMMON_H__


#if defined(BYPASS_MCU_PIC12F675)
#  include "bypass_pins_pic12f675.h"
#elif defined(BYPASS_MCU_PIC10F322)
#  include "bypass_pins_pic10f322.h"
#elif defined(BYPASS_MCU_AVR_XT)
#  include "bypass_pins_avr_xt.h"
#elif defined(__AVR__) || defined(BYPASS_MCU_AVR_CLASSIC)
#  include "bypass_pins_avr_classic.h"
#else
#  error "bypass: no pin map selected for this target"
#endif


// Conservative WALL-CLOCK upper bound on the interval between two watchdog pets
// when a toggling tick performs a blocking actuation of `blocking_ms`.
//
// The pet is the loop's liveness proof, so what the watchdog floor has to cover
// is not the delay constant but everything a healthy loop can spend between two
// consecutive pets. Both loop shapes put the same four terms in that window:
//
//   blocking_ms         the actuation's own delay body (0 where a variant has
//                       no blocking actuation at all);
//   ISR stretch         WDT_ISR_STRETCH_PCT is the percentage p of WALL time
//                       the ISR may own. Foreground work receives only 100-p,
//                       so the additive delay overhead is conservatively
//                       ceil(blocking_ms * p / (100-p)). Zero on the polled
//                       PIC shells;
//   TICK_PERIOD_MS      scheduling latency: the actuation ends at an arbitrary
//                       point inside a tick, and the next pass is gated on the
//                       next tick (AVR: IDLE-sleep wake; PIC: the TMR2IF/TMR0
//                       poll);
//   WDT_LOOP_WORK_MS    the bounded non-blocking work in the window -- sanity
//                       gate, context transaction, debounce step, and on the
//                       boot path init()'s register configuration as well.
//
// The boot path is inside this bound, not beside it: init() arms the watchdog,
// then performs the same blocking actuation before main() reaches its first
// pet. It is the LONGEST window on the variants that do not block at all, and
// its blocking half runs with interrupts disabled, so the ISR term is headroom
// there rather than a cost.
//
// Each shell's pin map supplies its own three terms; the arithmetic lives here
// so the four modular shells cannot drift apart. The quotient-plus-remainder
// ceiling avoids the overflow-prone `numerator + denominator - 1` idiom. The
// multiplication is promoted to 32 bits before it occurs. Every supported
// blocking delay is below RELEASE_THRESH, itself below UINT8_MAX, so even the
// largest valid duty gives a numerator no greater than 254 * 99 = 25146.
//
// This is a conservative INEQUALITY, not a measurement. Simulator and
// disassembly timing corroborate the per-target terms (see the pin maps and
// DESIGN_DOCUMENTATION.adoc); they do not replace this bound.
#if (WDT_ISR_STRETCH_PCT >= 100U)
#  error "WDT_ISR_STRETCH_PCT must be below 100: it is wall-time ISR duty"
#  define WDT_FOREGROUND_SHARE_PCT (1U)
#else
#  define WDT_FOREGROUND_SHARE_PCT (100U - WDT_ISR_STRETCH_PCT)
#endif

#define WDT_ISR_STRETCH_NUMERATOR(blocking_ms)                                 \
    ((uint32_t)(blocking_ms) * (uint32_t)WDT_ISR_STRETCH_PCT)

#define WDT_ISR_STRETCH_MAX_MS(blocking_ms)                                    \
    (   WDT_ISR_STRETCH_NUMERATOR(blocking_ms)                                 \
        / (uint32_t)WDT_FOREGROUND_SHARE_PCT                                   \
      + ((0U != (WDT_ISR_STRETCH_NUMERATOR(blocking_ms)                        \
                  % (uint32_t)WDT_FOREGROUND_SHARE_PCT))                       \
            ? (uint32_t)1U : (uint32_t)0U) )

#define WDT_PET_TO_PET_MAX_MS(blocking_ms)                                     \
    (   (uint32_t)(blocking_ms)                                                \
      + WDT_ISR_STRETCH_MAX_MS(blocking_ms)                                    \
      + (uint32_t)TICK_PERIOD_MS                                               \
      + (uint32_t)WDT_LOOP_WORK_MS )


#endif // BYPASS_OUTPUT_COMMON_H__
