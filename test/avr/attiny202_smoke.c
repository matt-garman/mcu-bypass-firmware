// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// ATtiny202 (AVR-XT / avrxmega3) toolchain + peripheral compile-smoke.
//
// PURPOSE (Phase 0 gate only -- this is NOT the firmware shell):
//   Prove that the OPEN-SOURCE apt toolchain (gcc-avr / binutils-avr / avr-libc
//   from Ubuntu universe) plus the vendored ATtiny_DFP device files
//   (scripts/fetch_attiny_dfp.sh) can compile AND link a real avrxmega3 image
//   that touches every peripheral group the eventual ATtiny202 shell
//   (src/bypass_mcu_avr_xt.c, Increment 2) will drive. It is built by
//   `make attiny202-smoke` with the project's exact strict CFLAGS
//   (-Werror -Wall -Wextra -Wconversion -fshort-enums ...), then checked for the
//   correct architecture and against the 2 KB flash budget.
//
// SCOPE / DISCLAIMERS:
//   - The pin choices below are ILLUSTRATIVE, not the final pin map -- the real
//     mapping (footswitch / LED / output pins) is the shell's job and lives in a
//     future bypass_pins_avr_xt.h. This file only exercises the register API.
//   - No project firmware source is included: Phase 0 must touch zero firmware.
//     bypass_pure.c / bypass_config.h gain their AVR-XT branch in Increment 2.
//   - AVR8X differs from classic AVR at essentially every register: GPIO is
//     PORTA.DIR/OUT/IN + per-pin PORTx.PINnCTRL pull-ups; clock is CLKCTRL behind
//     the CPU_CCP protected-write unlock; the tick is TCB0 (not Timer0/CTC); the
//     watchdog is WDT.CTRLA (also CCP-protected); sleep is SLPCTRL; reset cause
//     is RSTCTRL.RSTFR. This TU sanity-checks that each of those resolves.

#include <avr/io.h>
#include <avr/interrupt.h>
#include <avr/sleep.h>
#include <stdint.h>

// illustrative pins (final assignment is the shell's, not decided here)
#define SMOKE_LED_PIN     (1U)  // PA1, output
#define SMOKE_OUT_PIN     (2U)  // PA2, output
#define SMOKE_FOOTSW_PIN  (3U)  // PA3, input + pull-up

// touched by the ISR so the compiler cannot elide the tick path
static volatile uint8_t tick_flag_;

// TCB0 periodic-interrupt vector: the AVR-XT analogue of classic AVR's
// TIM0_COMPA_vect. Proves the interrupt vector name + ISR wiring link.
ISR(TCB0_INT_vect) {
    TCB0.INTFLAGS = TCB_CAPT_bm; // clear the capture/timeout flag
    tick_flag_ = 1U;
}

// unlock helper for CCP-protected registers (CLKCTRL, WDT). On AVR-XT a
// protected write must follow CPU_CCP=CCP_IOREG_gc within 4 instructions.
static inline void ccp_write_io(volatile uint8_t *addr, uint8_t value) {
    CPU_CCP = CCP_IOREG_gc;
    *addr = value;
}

int main(void) {
    // reset-cause flags (classic AVR MCUSR analogue); clear by writing back.
    uint8_t const rst = RSTCTRL.RSTFR;
    RSTCTRL.RSTFR = rst;

    // clock: prescaler via the CCP-protected CLKCTRL.MCLKCTRLB.
    ccp_write_io(&CLKCTRL.MCLKCTRLB, CLKCTRL_PDIV_2X_gc | CLKCTRL_PEN_bm);

    // GPIO directions: LED + one control pin as outputs (driven low), footswitch
    // as input with its internal pull-up (PORTx.PINnCTRL PULLUPEN bit).
    PORTA.DIRSET = (uint8_t)((1U << SMOKE_LED_PIN) | (1U << SMOKE_OUT_PIN));
    PORTA.OUTCLR = (uint8_t)((1U << SMOKE_LED_PIN) | (1U << SMOKE_OUT_PIN));
    PORTA.DIRCLR = (uint8_t)(1U << SMOKE_FOOTSW_PIN);
    PORTA.PIN3CTRL = PORT_PULLUPEN_bm;

    // watchdog: CCP-protected WDT.CTRLA period select, then a wdr ("pet").
    ccp_write_io(&WDT.CTRLA, WDT_PERIOD_256CLK_gc);
    __asm__ __volatile__("wdr");

    // tick source: TCB0 periodic interrupt (CNTMODE=INT), ~1 ms compare.
    TCB0.CCMP    = 2000U;
    TCB0.CTRLB   = TCB_CNTMODE_INT_gc;
    TCB0.INTCTRL = TCB_CAPT_bm;
    TCB0.CTRLA   = TCB_CLKSEL_CLKDIV1_gc | TCB_ENABLE_bm;

    // idle sleep between ticks (core halts, TCB0 + its ISR keep running).
    // NOTE: set_sleep_mode() is an avr-libc macro whose mask expansion trips
    // -Wconversion; suppress locally since we cannot cast inside the macro
    // (same treatment as the classic-AVR shell).
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wconversion"
    set_sleep_mode(SLEEP_MODE_IDLE);
#pragma GCC diagnostic pop
    sei();

    for (;;) {
        if (tick_flag_ != 0U) {
            tick_flag_ = 0U;
            __asm__ __volatile__("wdr"); // pet the dog once per serviced tick
            // sample the footswitch input (result deliberately unused here)
            if ((PORTA.IN & (uint8_t)(1U << SMOKE_FOOTSW_PIN)) == 0U) {
                PORTA.OUTSET = (uint8_t)(1U << SMOKE_LED_PIN);
            } else {
                PORTA.OUTCLR = (uint8_t)(1U << SMOKE_LED_PIN);
            }
        }
        sleep_mode();
    }
}
