// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman


// ATtiny202 (AVR-XT / avrxmega3) hardware "shell" (hardware-specific
// implementation of mcu-bypass-firmware).  Uses open-source toolchain
// (gcc-avr / binutils-avr / avr-libc) + the vendored ATtiny_DFP device files
// from Microchip (see scripts/fetch_attiny_dfp.sh).
//
// Implements the bypass_hw_iface.h contract for the ATtiny202 and provides this
// family's main(), tick/watchdog model, and fuse documentation.
//
// Other hardware-specific shell implementations in this project:
//   - AVR Classic (ATtiny13a, ATtinyX5): bypass_mcu_avr_classic.c
//   - PIC10F322: bypass_mcu_pic10f322.c
//   - PIC10F320: see child project pic10f320-bypass-firmware
//     (https://github.com/matt-garman/pic10f320-bypass-firmware)
// Uses the pure debounce core (bypass_pure.c) for debounce logic, and also
// supports the same output drivers as the other projects.
//
// Tick/WDT model: ISR + idle sleep, identical in shape to the classic-AVR shell.
// TCB0 fires a 1ms periodic interrupt; the ISR samples+integrates the footswitch
// and sets timer_isr_called_; main() sleeps in IDLE between ticks and pets the
// WDT only once per serviced tick, so the WDT proves BOTH the ISR and the main
// loop are alive.  Keeping the integrator in the ISR (as on classic AVR, unlike
// the PIC's polled loop) means the relay variant's ~12ms blocking coil pulse
// cannot starve footswitch sampling.
//
// FUSE configuration (AVR-XT analogue of the classic-AVR fuse table; written by
// the programmer - see the Makefile's attiny202-fuses target - NOT embedded as
// a FUSES{} struct, since this DFP vintage exposes only per-bit fuse masks):
//
//   Fuse     | Value                         | Rationale
//   ---------+-------------------------------+---------------------------------------
//   WDTCFG   | PERIOD=256CLK (0x06), WINDOW=OFF | ~256ms WDT, ENABLED + hardware-LOCKED
//            |                               | at reset (WDT.STATUS.LOCK=1).  Stronger
//            |                               | than classic WDTON: software cannot
//            |                               | change or disable it, and there is no
//            |                               | post-reset short-window reset hazard.
//   BODCFG   | LVL=BODLEVEL7 (~4.2V),        | Peripheral-safe floor: relay/MOSFET need
//            | ACTIVE=ENABLED, SLEEP=ENABLED | >4V. ~4.2V is the AVR-XT analogue of the
//            |                               | classic 4.3V BOD.  CONFIRM the level
//            |                               | encoding + that it is a characterised
//            |                               | (non-reserved) level in the ATtiny202
//            |                               | datasheet Electrical Characteristics.
//   OSCCFG   | FREQSEL=16MHz (0x01)          | 16MHz base / MCLKCTRLB PDIV 8 = 2MHz.
//   SYSCFG0  | RSTPINCFG=UPDI, CRCSRC=NONE   | Keep PA0 as UPDI so the part stays
//            | (device default, 0xF6)        | reprogrammable. (CRCSRC=boot flash CRC
//            |                               | is a future robustness option.)
//   SYSCFG1  | SUT=64ms (0x07)               | Longest start-up delay: stable power-on
//            |                               | while an LDO rail ramps (classic SUT
//            |                               | rationale).
//   APPEND   | 0x00                          | single application section...
//   BOOTEND  | 0x00                          | ...no bootloader.
//
// Programming is over UPDI (pymcuprog / jtag2updi / a UPDI adapter); see the
// Makefile attiny202-flash / attiny202-fuses targets.

#include "bypass_config.h"        // PRESSED_THRESH / RELEASE_THRESH, TCB0_CCMP_1MS
#include "bypass_output_common.h" // -> bypass_pins_avr_xt.h (build defines -DBYPASS_MCU_AVR_XT)
#include "bypass_types.h"
#include "bypass_pure.h"
#include "bypass_hw_iface.h"
#include "bypass_static_assert.h" // static_assert()
#include "bypass_compile_checks.h"

#include <avr/io.h>        // AVR8X SFRs, PORTA, TCB0, WDT, CLKCTRL, CPU_CCP, ...
#include <avr/interrupt.h> // ISR(), sei(), cli()
#include <avr/sleep.h>     // set_sleep_mode(), sleep_mode()
#include <stdint.h>


// Compile-time constants only (mirroring the AVR classic shell: do NOT snapshot into
// file-statics - that grows BSS and can perturb the fault-injection tests).
#define MCLKCTRLB_EXPECTED    ((uint8_t)((uint8_t)CLKCTRL_PDIV_8X_gc | (uint8_t)CLKCTRL_PEN_bm)) // 16MHz/8
#define WDT_CTRLA_EXPECTED    ((uint8_t)WDT_PERIOD_256CLK_gc) // fuse-locked ~256ms
#define TCB0_CTRLA_EXPECTED   ((uint8_t)((uint8_t)TCB_CLKSEL_CLKDIV1_gc | (uint8_t)TCB_ENABLE_bm))
#define TCB0_CTRLB_EXPECTED   ((uint8_t)TCB_CNTMODE_INT_gc)
#define TCB0_INTCTRL_EXPECTED ((uint8_t)TCB_CAPT_bm)


//////////////////////////////////////////////////////////////////////////////
// FILE-SCOPED TYPES
//////////////////////////////////////////////////////////////////////////////

// a flag to "multiplex" the WDT across the timer ISR and main() loop
typedef enum {
    TIMER_ISR_CALLED = 0,
    TIMER_ISR_NOT_CALLED,
} timer_isr_called_t;


//////////////////////////////////////////////////////////////////////////////
// PROGRAM GLOBALS
//////////////////////////////////////////////////////////////////////////////

// a single volatile global, shared between main() and the TCB0 ISR
static volatile timer_isr_called_t timer_isr_called_;

// overall debounce context (volatile + file-static: shared with the ISR)
static volatile debounce_context_t ctx_;


//////////////////////////////////////////////////////////////////////////////
// SHELL-INTERNAL HELPERS
//////////////////////////////////////////////////////////////////////////////

// unlock helper for CCP-protected registers (CLKCTRL).  A protected write must
// follow CPU_CCP = CCP_IOREG_gc within 4 instructions; keep the store adjacent.
static inline void ccp_write_io(volatile uint8_t *addr, uint8_t value) {
     CPU_CCP = CCP_IOREG_gc;
    *addr = value;
}

// reset the WDT countdown ("pet the dog").  The WDT is fuse-locked (WDTCFG), so
// there is nothing to arm -- a bare wdr is the whole story.
static inline void hw_wdt_pet(void) { __asm__ __volatile__("wdr"); }

// infinite loop to force a WDT reset on a critical, unrecoverable event (cosmic
// ray / extreme EMI).  Disables interrupts first so nothing can pet the dog.
// Relies on the fuse-locked WDT being active (it always is on this part).
__attribute__((noreturn)) static void hw_force_wdt_reset(void) {
    cli();
    for (;;) { }
}


//////////////////////////////////////////////////////////////////////////////
// CROSS-BOUNDARY HW OPS (implement bypass_hw_iface.h)
//////////////////////////////////////////////////////////////////////////////

// LED_PIN high = status LED lit; low = dark.  OUTSET/OUTCLR are atomic single-
// register writes (no read-modify-write), so they are safe against the ISR.
void hw_led_pin_set_high(void) { PORTA.OUTSET = (uint8_t)(1U << LED_PIN); }
void hw_led_pin_set_low(void)  { PORTA.OUTCLR = (uint8_t)(1U << LED_PIN); }

// - set a GPIO pin high or low (assumes pin was previously configured output)
void hw_pin_set_high(uint8_t const pin) { PORTA.OUTSET = (uint8_t)(1U << pin); }
void hw_pin_set_low(uint8_t const pin)  { PORTA.OUTCLR = (uint8_t)(1U << pin); }

// configure exactly the pins in output_mask as outputs (PORTA.DIR bit = 1); all
// other pins are left as inputs.  Selected pins are driven low first (OUTCLR)
// so enabling the output direction cannot briefly drive a high.
void hw_configure_output_pins(uint8_t const output_mask) {
    PORTA.OUTCLR = output_mask; // selected outputs -> low latch
    PORTA.DIR    = output_mask; // exactly these = output, all others = input
}

// sanity check utility function: return non-zero IFF the complete direction
// configuration still matches initialization, every caller-requested output
// remains an output, and the complete output latch matches the expected state.
//
// Exact DIR protects PA7 as the footswitch input, PA1/PA2/PA3/PA6 as
// outputs, PA0 as UPDI, and unbonded PA4/PA5 as inputs.
uint8_t hw_output_state_intact(
        uint8_t const required_output_mask,
        uint8_t const expected_high_mask) {
    uint8_t const actual_direction_mask = PORTA.DIR;
    uint8_t const actual_high_mask =
        (uint8_t)(PORTA.OUT & (uint8_t)BYPASS_OUTPUT_DDR_MASK);

    return
        (actual_direction_mask == (uint8_t)BYPASS_OUTPUT_DDR_MASK) &&
        ((actual_direction_mask & required_output_mask) ==
            required_output_mask) &&
        (actual_high_mask == expected_high_mask);
}


//////////////////////////////////////////////////////////////////////////////
// SANITY CHECKS
//////////////////////////////////////////////////////////////////////////////

// non-zero ("true") IFF all critical SFRs still hold their configured values.
// SFR = special function register, the "control panel" of the MCU.
static uint8_t hw_critical_sfrs_intact(void) {
    uint8_t mclkctrlb   = CLKCTRL.MCLKCTRLB;
    uint8_t wdt_ctrla   = WDT.CTRLA;
    uint8_t wdt_locked  = (uint8_t)(WDT.STATUS & (uint8_t)WDT_LOCK_bm);
    uint8_t tcb0_ctrla  = TCB0.CTRLA;
    uint8_t tcb0_ctrlb  = TCB0.CTRLB;
    uint8_t tcb0_intctl = TCB0.INTCTRL;
    uint16_t tcb0_ccmp  = TCB0.CCMP;

    return
        (MCLKCTRLB_EXPECTED    == mclkctrlb)   &&
        (WDT_CTRLA_EXPECTED    == wdt_ctrla)   &&
        ((uint8_t)WDT_LOCK_bm  == wdt_locked)  && // WDT still hardware-locked
        (TCB0_CTRLA_EXPECTED   == tcb0_ctrla)  &&
        (TCB0_CTRLB_EXPECTED   == tcb0_ctrlb)  &&
        (TCB0_INTCTRL_EXPECTED == tcb0_intctl) &&
        ((uint16_t)TCB0_CCMP_1MS == tcb0_ccmp) ;
}

// read FOOTSW_PIN (PA7): high = switch open/released, low = closed/pressed.
static pin_state_t hw_read_footswitch(void) {
    return (0U == (PORTA.IN & (uint8_t)(1U << FOOTSW_PIN))) ?
        PIN_STATE_LOW :
        PIN_STATE_HIGH;
}

// non-zero IFF the footswitch input pull-up is still enabled.  On AVR-XT the
// pull-up lives in the per-pin PORTA.PINnCTRL PULLUPEN bit (single enable, like
// the classic PORTB latch bit -- unlike the PIC's two-part WPUA/nWPUEN).
static uint8_t hw_footswitch_pullup_intact(void) {
    return (PORTA.PIN7CTRL & (uint8_t)PORT_PULLUPEN_bm) != 0U;
}


//////////////////////////////////////////////////////////////////////////////
// BRING-UP
//////////////////////////////////////////////////////////////////////////////

// core MCU bring-up: main-clock prescaler, footswitch pull-up, reset-flag clear.
// Does NOT start the tick timer (see hw_tick_timer_start()) or enable interrupts.
// Call AFTER hw_init_output_pins() so the DIR write there has already set the
// footswitch pin (PA7) as an input before we enable its pull-up.
static void hw_mcu_init(void) {
    // 16MHz internal osc (OSCCFG fuse) / 8 => the explicit 2MHz system clock.
    // CCP-protected write; belt-and-suspenders over the fuse-derived clock.
    ccp_write_io(&CLKCTRL.MCLKCTRLB, MCLKCTRLB_EXPECTED);

    // footswitch (PA7) input pull-up.  FOOTSW_PIN high = released, low = pressed.
    PORTA.PIN7CTRL = PORT_PULLUPEN_bm;

    // clear any latched reset-cause flags (POR/BOR/WDT/UPDI); write-1-to-clear.
    RSTCTRL.RSTFR = RSTCTRL.RSTFR;

    // Note: unlike classic AVR (ADCSRA/ACSR/power_all_disable), AVR-XT leaves
    // unused peripherals unclocked at reset, so no explicit gating is needed.
}

// configure TCB0 for the 1ms periodic-interrupt tick and select IDLE sleep.
// MUST run AFTER any blocking output actuation and immediately before sei():
// TCB0 is enabled here with its CAPT flag cleared, so no timeout accumulated
// during init can fire the ISR spuriously at sei().
static void hw_tick_timer_start(void) {
    TCB0.CCMP     = (uint16_t)TCB0_CCMP_1MS;        // 1999 -> 1ms at 2MHz
    TCB0.CNT      = 0U;
    TCB0.CTRLB    = TCB_CNTMODE_INT_gc;             // periodic interrupt mode
    TCB0.INTFLAGS = TCB_CAPT_bm;                    // clear a stale timeout flag
    TCB0.INTCTRL  = TCB_CAPT_bm;                    // enable CAPT interrupt
    TCB0.CTRLA    = TCB0_CTRLA_EXPECTED; // CLK_PER, run (see macro)

    // CPU sleeps in IDLE between ticks: core halts but TCB0 keeps running, so
    // the tick ISR still wakes us. (Deeper modes would gate TCB0's clock.)
    // NOTE: set_sleep_mode()'s mask expansion trips -Wconversion; suppress
    // locally since we cannot cast inside the macro (same as the classic shell).
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wconversion"
    set_sleep_mode(SLEEP_MODE_IDLE);
#pragma GCC diagnostic pop
}

// set AVR to IDLE sleep: halts main() but leaves TCB0 + its ISR running.
static void hw_wait_for_tick(void) { sleep_mode(); }


//////////////////////////////////////////////////////////////////////////////
// TICK ISR
//////////////////////////////////////////////////////////////////////////////

// TCB0 periodic (CAPT) interrupt; fires every 1ms.  AVR-XT analogue of the
 // classic shell's TIM0_COMPA_vect.
ISR(TCB0_INT_vect) {
    TCB0.INTFLAGS = TCB_CAPT_bm; // clear the capture/timeout flag
    timer_isr_called_ = TIMER_ISR_CALLED;
    ctx_.debounce_counter = debounce_integrate(
            hw_read_footswitch(),
            ctx_.debounce_counter);
}


//////////////////////////////////////////////////////////////////////////////
// INIT + MAIN
//////////////////////////////////////////////////////////////////////////////

// called at power-on and after any reset (brown-out, watchdog timeout, ...).
static void init(void) {

    // compile-time sanity checks (zero runtime cost)
    static_assert(1U == sizeof(effect_state_t),     "sizeof(effect_state_t) != 1, use -fshort-enums");
    static_assert(1U == sizeof(program_state_t),    "sizeof(program_state_t) != 1, use -fshort-enums");
    static_assert(1U == sizeof(timer_isr_called_t), "sizeof(timer_isr_called_t) != 1, use -fshort-enums");
    static_assert(1000U == (F_CPU / ((uint32_t)TCB0_CCMP_1MS + 1U)),
                  "TCB0_CCMP_1MS/F_CPU mismatch, ISR won't be on a 1ms tick");

    // pin-map sanity: the map hard-codes PORTA bit positions as literals; pin
    // them to <avr/io.h>'s generic PINn_bp so a typo can never misroute a pin
    // (parity with the AVR-classic PBx and PIC _PORTA_RAx_POSN asserts).
    static_assert(FOOTSW_PIN      == (unsigned)PIN7_bp, "FOOTSW_PIN must be PA7");
    static_assert(LED_PIN         == (unsigned)PIN1_bp, "LED_PIN must be PA1");
    static_assert(CD4053_PIN      == (unsigned)PIN2_bp, "CD4053_PIN must be PA2");
    static_assert(RELAY_RESET_PIN == (unsigned)PIN2_bp, "RELAY_RESET_PIN must be PA2");
    static_assert(RELAY_SET_PIN   == (unsigned)PIN3_bp, "RELAY_SET_PIN must be PA3");
    static_assert(CD4053_CTL1     == (unsigned)PIN2_bp, "CD4053_CTL1 must be PA2");
    static_assert(CD4053_CTL2     == (unsigned)PIN3_bp, "CD4053_CTL2 must be PA3");

    // don't let init() be interrupted; re-enabled at the end.
    cli();

    // pet the fuse-locked WDT first thing.  Unlike classic AVR there is no
    // post-reset short-window hazard (the fuse sets the period from cycle 0),
    // so this is belt-and-suspenders, not required -- but it documents intent.
    hw_wdt_pet();

    // driver: set output-pin directions FIRST (this also sets PA7 as an input).
    hw_init_output_pins();

    // clock, footswitch pull-up, reset-flag clear.
    hw_mcu_init();

    // driver: default to bypass (may block on the relay/mute pulse).
    hw_set_bypass_state();

    // initialize global switch state from the current footswitch level.
    ctx_ = debounce_init_context(hw_read_footswitch());

    // ISR/main handshake seed.
    timer_isr_called_ = TIMER_ISR_NOT_CALLED;

    // LAST: after the blocking actuation; arms the tick + IDLE sleep.
    hw_tick_timer_start();

    sei();
    __asm__ __volatile__("" ::: "memory"); // no reorder across sei()
}

// program entry point.  ISR + idle-sleep model, identical in shape to the
// classic-AVR shell.
__attribute__((OS_main)) int main(void) {


    init();

    for (;;) {

        // sanity checks against outlier events (cosmic rays, extreme EMI);
        // always checked; force a WDT reset on any violation.
        if ( (ctx_.program_state > RELEASE_DEBOUNCE_WAIT) ||
                (ctx_.effect_state > ENGAGED) ||
                (timer_isr_called_ > TIMER_ISR_NOT_CALLED) ||
                (ctx_.debounce_counter > RELEASE_THRESH) ||
                (0U == hw_footswitch_pullup_intact()) ||
                (0U == hw_critical_sfrs_intact()) ||
                hw_is_sanity_check_failed(ctx_.effect_state)
           ) {
            hw_force_wdt_reset();
        }

        // WDT proves BOTH main() and the ISR are alive: only pet when the ISR
        // has run since we last cleared the flag.  A one-tick race with the ISR
        // is harmless -- corrected next iteration, well inside the WDT period.
        if (TIMER_ISR_CALLED == timer_isr_called_) {
            timer_isr_called_ = TIMER_ISR_NOT_CALLED;
            hw_wdt_pet();

            debounce_step_result_t const res = debounce_step(ctx_);

            ctx_.program_state = res.program_state;
            ctx_.effect_state  = res.effect_state;
            if (res.reload_lockout) {
                ctx_.debounce_counter = res.lockout_value;
            }

            if (res.fault) {
                hw_force_wdt_reset();
            }
            else if (res.toggled) {
                if (BYPASS == res.effect_state) { hw_set_bypass_state(); }
                else /*ENGAGED*/                { hw_set_engaged_state(); }
            }
            else {
                // state advanced with no toggle and no fault: nothing to do
            }
        }

        // Pause until the next 1ms TCB0 tick.  Lost-wakeup is impossible on AVR
        // IDLE sleep: if the ISR fires between clearing the flag and SLEEP, the
        // core executes SLEEP as a no-op and services the interrupt (tinyAVR-0
        // SLPCTRL/sleep semantics).  No tick is ever missed.
        hw_wait_for_tick();
    }
}

 
