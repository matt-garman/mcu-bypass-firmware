// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

#ifndef BYPASS_BLOCKING_DELAY_H__
#define BYPASS_BLOCKING_DELAY_H__


// Blocking coil-pulse delay. AVR uses avr-libc's _delay_ms(); the PIC uses
// XC8's __delay_ms() from <xc.h> (which needs _XTAL_FREQ, supplied via -D in
// the PIC build). Model B keeps the WDT period (~256ms) longer than the 12ms
// pulse, so a plain blocking delay is safe on both targets.
//
// platform agnostic blocking delay, millisecond precision
//   - AVR Classic uses avr-libc's _delay_ms()
//   - PIC10F32x uses XC8's __delay_ms()
#if defined(__AVR__)
#  include <util/delay.h> // _delay_ms()
#  define BYPASS_DELAY_MS(n) _delay_ms(n)
#else
#  include <xc.h>         // __delay_ms()
#  define BYPASS_DELAY_MS(n) __delay_ms(n)
#endif


#endif // BYPASS_BLOCKING_DELAY_H__
