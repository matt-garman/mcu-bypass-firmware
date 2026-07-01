// Copyright (c) Matthew Garman.  All rights reserved.
// Licensed under the MIT License. See LICENSE in the project root for
// license information.


// designed for avrtools (standard avr-gcc, avr-libc, avrdude toolchain)
//
// compile with:
//     -fshort-enums // so that typedef'ed enums below are 8-bit ints
//     -funsigned-char
//     -ffunction-sections
//     -fdata-sections
//     -Wl,--gc-sections
//     -Werror
//     -Wall
//     -Wextra
//
// Fuse configuration:
// Fuse      | Value                                     | Rationale
// ----------+-------------------------------------------+----------------------------------------------------------------
// CKSEL     | 0b0010 (Internal 9.6MHz)                  | Required for 1.2MHz operation with CKDIV8
// SUT       | 0b00 (14 CK + 4ms) or 0b10 (14 CK + 64ms) | 64ms recommended for stable power-on with LDO regulator ramp-up
// CKDIV8    | 0 (enabled, i.e., divide by 8)            | Yields 1.2MHz system clock
// WDTON     | 0 (enabled, i.e., WDT always on)          | Silicon-level guarantee: WDT cannot be disabled by software;
//           |                                           | resilient against stray WDTCR writes (EMI, cosmic rays)
// BODEN     | 0 (enabled)                               | Required for brown-out protection
// BODLEVEL  | 0b00 (4.3V)                               | Peripheral-safe: relay and MOSFET
//           |                                           | control both require >4V; 4.3V ensures
//           |                                           | BOD fires while hardware can still respond
// RSTDISBL  | 1 (disabled, i.e., PB5 remains RESET)     | Critical: clearing this disables ISP programming
// SELFPRGEN | 1 (disabled)                              | No self-programming needed
// DWEN      | 1 (disabled)                              | debugWIRE not needed in production; consumes PB5
//
// avrdude fuse targets: -U lfuse:w:0x4a:m -U hfuse:w:0xf9:m
// 
// Note: useful fuse tool here: https://www.engbedded.com/fusecalc/
//

#include "bypass_config.h"
#include "bypass_output_common.h"
#include "bypass_types.h"
#include "bypass_pure.h"
#include "bypass_hw_iface.h"
#include "bypass_static_assert.h" // for static_assert()
#include "bypass_compile_checks.h"

#include <avr/io.h>        // Defines register and bit names
#include <avr/wdt.h>       // watchdog timer: wdt_enable(), wdt_reset(), WDTO_* timeouts
#include <avr/power.h>     // clock_prescale_set(), power_all_disable()
#include <avr/sleep.h>     // sleep states
#include <avr/interrupt.h> // ISR() interrupt service routine macro


// Compile-time constants only
// Do NOT snapshot into a file-static (it grows BSS, moves ctx_, and breaks
// test_fault_inject_stack_pointer).
#define CLKPR_EXPECTED   ((uint8_t)clock_div_8)                // system clock /8
#define WDTCR_EXPECTED   ((uint8_t)((1 << WDE) | (1 << WDP2))) // WDTO_250MS -> WDP=0b0100 (verified t13a+t85)
#define TCCR0A_EXPECTED  ((uint8_t)(1 << WGM01))               // CTC
#define TCCR0B_EXPECTED  ((uint8_t)(1 << CS01))                // /8
#define OCR0A_EXPECTED   ((uint8_t)TIMER0_OCR0A_1MS)
#define TIMSK0_EXPECTED  ((uint8_t)(1 << OCIE0A))




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

// a single volatile global variable, shared between main() and the timer ISR
static volatile timer_isr_called_t timer_isr_called_;

// overall debounce context
static volatile debounce_context_t ctx_;


//////////////////////////////////////////////////////////////////////////////
// FUNCTIONS
//////////////////////////////////////////////////////////////////////////////

// infinite-loop function to force watchdog reset
//
// this function is designed for critical, unrecoverable errors (presumably by
// ultra-rare events, e.g. cosmic rays, extreme EMI)
//
// IMPORTANT: this function relies on the watchdog being active; calling this
// without an active WDT will lock up the MCU
__attribute__((noreturn)) static void hw_force_wdt_reset(void) {
    cli();
    while (1) {}
}


// LED_PIN high = status LED lit
// LED_PIN low = status LED dark
void hw_led_pin_set_high(void) { PORTB |=  (1 << LED_PIN); }
void hw_led_pin_set_low(void)  { PORTB &= (uint8_t)~(1 << LED_PIN); }


// - set a GPIO pin high or low
// - assumes pin was previously configured as output
void hw_pin_set_high(uint8_t const pin) { PORTB |=  (uint8_t)(1 << pin); }
void hw_pin_set_low(uint8_t const pin)  { PORTB &= (uint8_t)~(1 << pin); }


// configure exactly the pins in output_mask as outputs; all other pins are
// left as inputs, and the configured outputs are driven low (their PORTB
// latch bits are 0 at this point).
void hw_configure_output_pins(uint8_t const output_mask) { DDRB = output_mask; }


// sanity check utility function: return non-zero IFF every pin in
// expected_mask is still configured as output
uint8_t hw_output_pins_intact(uint8_t const expected_mask) {
    return (DDRB & expected_mask) == expected_mask;
}


// sanity-check utility: return non-zero ("true") IFF all the critial pin
// values are what we want
// SRF = special function register, the "control panel" of the MCU
static uint8_t hw_critical_sfrs_intact(void) {
    uint8_t clkpr  = CLKPR;
    uint8_t wdtcr  = WDTCR;
    uint8_t tccr0a = TCCR0A;
    uint8_t tccr0b = TCCR0B;
    uint8_t ocr0a  = OCR0A;
    uint8_t timsk  = TIMSK0;

    return 
        (CLKPR_EXPECTED  == clkpr)  &&
        (WDTCR_EXPECTED  == wdtcr)  &&
        (TCCR0A_EXPECTED == tccr0a) &&
        (TCCR0B_EXPECTED == tccr0b) &&
        (OCR0A_EXPECTED  == ocr0a)  &&
        (TIMSK0_EXPECTED == timsk)  ;
}


// read FOOTSW_PIN to determine if it's high or low
// returns: PIN_STATE_HIGH or PIN_STATE_LOW
static pin_state_t hw_read_footswitch(void) {
    return (0U == (PINB & (1 << FOOTSW_PIN))) ?
        PIN_STATE_LOW :
        PIN_STATE_HIGH;
}


// non-zero IFF the footswitch input pull-up latch bit is still asserted
static uint8_t hw_footswitch_pullup_intact(void) {
    return (PORTB & (1 << FOOTSW_PIN)) != 0;
}


// set AVR to IDLE SLEEP mode: halts main() loop, but ISRs continue to run
static void hw_wait_for_tick(void) { sleep_mode(); }


// Watchdog: ~250ms timeout in system-reset mode. wdt_enable() sets WDE
// (reset mode) for us. WDTO_250MS is the nearest standard step.
//
// NOTE: the AVR watchdog timer uses a separate oscillator that is
// independent of the system clock; it has *very* loose tolerance.  We
// should expect our 250ms watchdog timeout to be 100-350ms in practice.
//
// Also note: after a watchdog-triggered reset, WDTCR resets to 0 with WDE
// forced on by WDRF, so the effective timeout is ~16ms until wdt_enable()
// runs.  With a 50% margin, this could be as low as 7-8ms.
//
// We need to ensure that we don't create a WDT reset loop by making
// init() so long that the WDT bites.  Hence, one of the first things we
// do in init() is reset the WDT and then set the timeout to 250ms.  After
// RESET, we expect a few dozen instructions, therefore a few dozen
// microseconds until wdt_reset()/wdt_enable() is called.
//
// Therefore, there is a few milliseconds of margin against WDT reset
// loop; but the WDT reset and re-arm should remain at the very start of
// this function.
//
// TL;DR: keep this call as close to the start of init() as possible
static void hw_wdt_arm(void) {
    wdt_reset(); // pet the dog (init() could be called from a previous WDT timeout)
    MCUSR &= (uint8_t)~(1 << WDRF); // must clear WDRF before WDE can be cleared
    wdt_enable(WDTO_250MS); // (re-)arm the WDT
}

// reset the WDT countdown ("pet the dog")
static void hw_wdt_pet(void) { wdt_reset(); }


// core MCU bring-up: clock prescaler, unused-peripheral gating, footswitch
// input pull-up, and interrupt-source clearing. Does NOT configure the tick
// timer (see hw_tick_timer_start()) or enable global interrupts.
//
// Ordering: call AFTER hw_init_output_pins() so the footswitch pull-up write
// lands after the output-pin directions are set (the same write drives the
// configured output pins low).
static void hw_mcu_init(void) {
    // make the 1.2MHz system clock explicit at runtime
    // (9.6MHz internal RC / 8). The CKDIV8 fuse already does this at
    // power-on; setting it here is belt-and-suspenders and survives any prior
    // prescaler change.
    clock_prescale_set(clock_div_8);

    // disable unused analog blocks (save power, reduce chance of spurious
    // activity).  ADC must be disabled BEFORE its clock is gated by
    // power_all_disable().
    ADCSRA = 0;          // disable ADC (analog to digital converter)
    ACSR = (1 << ACD);   // disable analog comparator

    // gate clocks to unused modules, explicitly re-enable Timer0, used for
    // 1ms footswitch pin polling
    power_all_disable();
    power_timer0_enable();

    // enable the input pullup for FOOTSW_PIN
    // note additional external 10k pullup
    // FOOTSW_PIN high = switch open/released
    // FOOTSW_PIN low = switch closed/pressed
    // this also sets unused pins low
    PORTB = (1 << FOOTSW_PIN);

    GIMSK = 0; // pin change interrupts: not needed
    PCMSK = 0; // external interrupts: not used
}


// configure Timer0 for the 1ms CTC tick and select IDLE sleep. MUST run AFTER
// any blocking output actuation and immediately before sei(): the timer
// starts here with OCF0A cleared, so no compare-match accumulated during init
// fires the ISR spuriously at sei().
static void hw_tick_timer_start(void) {
    // Timer0: CTC mode (WGM01=1), prescaler /8, compare match every 1ms.
    TCCR0A = (1 << WGM01);     // CTC: clear timer on compare A
    TCCR0B = (1 << CS01);      // prescaler = clk/8
    OCR0A  = TIMER0_OCR0A_1MS; // 149 -> 1ms tick at 1.2MHz/8
    TCNT0  = 0;                // start count from 0
    TIMSK0 = (1 << OCIE0A);    // enable Compare Match A interrupt
    TIFR0  = (1 << OCF0A);     // explicitly clear TIFR0's OCF0A (prevent ISR firing immediately below after sei() from state compare-match flag from WDT reset)

    // CPU sleeps in IDLE between 1ms ticks: core halts, but Timer0 keeps
    // running so the tick ISR still wakes us. (Deeper modes would stop
    // Timer0)
    // NOTE: set_sleep_mode() is an avr-libc macro whose ~mask expansion trips
    // -Wconversion; suppress locally since we cannot cast inside the macro.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wconversion"
    set_sleep_mode(SLEEP_MODE_IDLE);
#pragma GCC diagnostic pop
}





// Timer ISR
// Timer0 Compare-Match A interrupt; fires every 1ms (see init()).
ISR(TIM0_COMPA_vect) {
    timer_isr_called_ = TIMER_ISR_CALLED; // used by main() to reset WDT
    ctx_.debounce_counter = debounce_integrate(
            hw_read_footswitch(),
            ctx_.debounce_counter);
}


// high-level initialization
// called at power-on, and after RESET (e.g. due to watchdog timeout)
static void init(void) {

    // compile-time sanity checks
    // zero runtime cost - these are only evaluated at compile-time
    static_assert(1U == sizeof(effect_state_t),                    "sizeof(effect_state_t) != 1, use -fshort-enums");
    static_assert(1U == sizeof(program_state_t),                   "sizeof(program_state_t) != 1, use -fshort-enums");
    static_assert(1U == sizeof(timer_isr_called_t),                "sizeof(timer_isr_called_t) != 1, use -fshort-enums");
    static_assert(1000U == (F_CPU / 8U / (TIMER0_OCR0A_1MS + 1U)), "OCR0A/F_CPU mismatch, ISR won't be on 1ms timer");
    // pin-map sanity
    // The pin map hard-codes PORTB bit positions as literals (0U,1U,...) rather than
    // <avr/io.h>'s PBx names. Classic-AVR PBx have always equalled their ordinal
    // positions, but pin that at compile time so a toolchain change or a typo in the
    // map can never silently misroute a pin.
    static_assert(PB0 == 0, "PB0 != 0");
    static_assert(PB1 == 1, "PB1 != 1");
    static_assert(PB2 == 2, "PB2 != 2");
    static_assert(PB3 == 3, "PB3 != 3");
    static_assert(PB4 == 4, "PB4 != 4");
    static_assert(PB5 == 5, "PB5 != 5");
    // and that the logical pin map lands on the intended physical pins:
    static_assert(FOOTSW_PIN      == (unsigned)PB0, "FOOTSW_PIN must be PB0");
    static_assert(LED_PIN         == (unsigned)PB1, "LED_PIN must be PB1");
    static_assert(CD4053_PIN      == (unsigned)PB2, "CD4053_PIN must be PB2");
    static_assert(RELAY_RESET_PIN == (unsigned)PB2, "RELAY_RESET_PIN must be PB2");
    static_assert(RELAY_SET_PIN   == (unsigned)PB3, "RELAY_SET_PIN must be PB3");
    static_assert(CD4053_CTL1     == (unsigned)PB2, "CD4053_CTL1 must be PB2");
    static_assert(CD4053_CTL2     == (unsigned)PB3, "CD4053_CTL2 must be PB3");



    // disable interrupts (don't want init() to be interrupted); will
    // re-enable at end of function
    cli();

    // FIRST: (re-)arm inside the post-reset WDT window
    hw_wdt_arm();

    // driver: DDRB: MUST precede the pull-up write
    hw_init_output_pins();

    // clock, peripheral gating, footswitch pull-up, IRQ-source clear
    hw_mcu_init();

    // driver: default bypass (may block on relay/mute pulse)
    hw_set_bypass_state();

    // initialize global switch state
    ctx_ = debounce_init_context(hw_read_footswitch());

    // ISR-main() WDT handshake: let ISR set this to called when timer is
    // activated
    timer_isr_called_ = TIMER_ISR_NOT_CALLED;

    // LAST: after the blocking actuation; arms the tick + IDLE sleep
    hw_tick_timer_start();

    // init done, now re-enable interrupts
    sei();
    __asm__ __volatile__("" ::: "memory"); // belt-and-suspenders to prevent compiler reordering across sei()
}


// program entry point
__attribute__((OS_main)) int main(void) {

    init(); // note: initializes ctx_ via debounce_init_context()

    while (1) {

        // basic sanity checks against outlier events (cosmic rays, extreme
        // EMI)
        // always called, regardless of state
        // force WDT timeout if fail
        if ( (ctx_.program_state > RELEASE_DEBOUNCE_WAIT) ||
                (ctx_.effect_state > ENGAGED) ||
                (timer_isr_called_ > TIMER_ISR_NOT_CALLED) ||
                (ctx_.debounce_counter > RELEASE_THRESH) ||
                // assert footswitch pullup still enabled
                (0U == hw_footswitch_pullup_intact()) ||
                (0U == hw_critical_sfrs_intact()) ||
                // config-specific runtime sanity checks
                hw_is_sanity_check_failed()
           ) {
            hw_force_wdt_reset();
        }

        // - the intent is to make sure both main() is running AND
        //   the timer ISR is being invoked
        // - if main() loop fails or timer ISR stops running,
        //   watchdog timeout will expire
        // - potential logical race here with timer ISR - could possibly miss
        //   one timer ISR update, but will be correct on next loop iteration,
        //   so will not trigger WDT timeout
        if (TIMER_ISR_CALLED == timer_isr_called_) {
            timer_isr_called_ = TIMER_ISR_NOT_CALLED;
            hw_wdt_pet(); // WDT reset ("pet the dog")

            debounce_step_result_t const res = debounce_step(ctx_);

            ctx_.program_state = res.program_state;
            ctx_.effect_state = res.effect_state;
            if (res.reload_lockout)
            {
                ctx_.debounce_counter = res.lockout_value;
            }

            // note: the fault condition is
            // defense-in-depth/belt-and-suspenders with the sanity checks
            // above
            if (res.fault) {
                hw_force_wdt_reset();
            }
            else if (res.toggled) {
                if (BYPASS == res.effect_state) { hw_set_bypass_state(); }
                else /*ENGAGED == res.effect_state*/ { hw_set_engaged_state(); }
            }
            else {
                // state advanced this tick with no toggle and no fault: nothing to do
            }
        }

        // Pause until the next 1ms Timer0 compare-match ISR wakes the core.
        // Lost-wakeup is impossible on AVR IDLE sleep: if the ISR fires in
        // the window between clearing timer_isr_called_ and the SLEEP
        // instruction, the hardware aborts SLEEP immediately and services the
        // interrupt before the next instruction (ATtiny13A datasheet §7.3,
        // Sleep Modes). No tick is ever missed even without disabling
        // interrupts around the check-then-sleep sequence.
        hw_wait_for_tick();
    }

}

