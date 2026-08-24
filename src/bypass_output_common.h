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
//   ISR stretch         WDT_ISR_STRETCH_PCT of it again, because on the
//                       interrupt-driven AVRs the tick ISR preempts the
//                       busy-wait and the delay is longer in wall time than in
//                       delay-body cycles. Zero on the polled PIC shells;
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
// so the four modular shells cannot drift apart. `+ 99U` is the usual round-up:
// the stretch is never credited a fraction of a millisecond it did not earn.
//
// This is a conservative INEQUALITY, not a measurement. Simulator and
// disassembly timing corroborate the per-target terms (see the pin maps and
// DESIGN_DOCUMENTATION.adoc); they do not replace this bound.
#define WDT_PET_TO_PET_MAX_MS(blocking_ms)                                     \
    (   (blocking_ms)                                                          \
      + ((((blocking_ms) * WDT_ISR_STRETCH_PCT) + 99U) / 100U)                 \
      + TICK_PERIOD_MS                                                         \
      + WDT_LOOP_WORK_MS )


#endif // BYPASS_OUTPUT_COMMON_H__
