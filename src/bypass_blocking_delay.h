// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

#ifndef BYPASS_BLOCKING_DELAY_H__
#define BYPASS_BLOCKING_DELAY_H__


// Blocking output delay. AVR uses avr-libc's _delay_ms(); PIC uses XC8's
// __delay_ms() from <xc.h> (which needs _XTAL_FREQ, supplied via -D in the PIC
// build). Each shell supplies target-specific tick, loop-work, ISR-stretch and
// de-rated WDT bounds; the output drivers assert that the whole worst-case
// wall-clock pet-to-pet window -- this delay, the ISR preemption that stretches
// it, one tick of scheduling latency and one pass of bounded loop work --
// remains below the WDT floor (WDT_PET_TO_PET_MAX_MS() in
// bypass_output_common.h). That is a healthy-loop watchdog margin, not fault
// safety during an actuation sequence.
//
// platform agnostic blocking delay, millisecond precision
//   - AVR Classic and AVR XT use avr-libc's _delay_ms()
//   - PIC10F32x and PIC12F675 use XC8's __delay_ms()
#if defined(__AVR__)
#  include <util/delay.h> // _delay_ms()
#  define BYPASS_DELAY_MS(n) _delay_ms(n)
#else
#  include <xc.h>         // __delay_ms()
#  define BYPASS_DELAY_MS(n) __delay_ms(n)
#endif


#endif // BYPASS_BLOCKING_DELAY_H__
