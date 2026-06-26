// Copyright (c) Matthew Garman.  All rights reserved.
// Licensed under the MIT License. See LICENSE in the project root for
// license information.


// PIC10F320/322 hardware shell (Microchip XC8 toolchain).
//
// Implements the bypass_hw_iface.h contract for the PIC10F32x family and
// provides this family's main(), CONFIG bits, and tick/watchdog model. It is
// the PIC counterpart of the classic-AVR shell (bypass_mcu_avr_classic.c); the
// pure debounce core (bypass_pure.c) and the three output drivers are shared
// UNCHANGED.
//
// Tick/WDT model "B" (see docs/phase2_pic_shell.md): a hardware timer (TMR2)
// drives a ~1ms tick that is POLLED in the main loop (no sleep); the watchdog
// is a pure FAULT watchdog at ~256ms, CLRWDT'd once per tick. There is no timer
// ISR and no ISR/main handshake -- the single polled loop reaching CLRWDT is
// itself the liveness proof.
//
// CONFIG / fuse rationale (PIC analogue of the AVR fuse table in the AVR shell):
//   FOSC=INTOSC  internal 16MHz HFINTOSC (CLKIN pin function disabled)
//   WDTE=ON      watchdog cannot be disabled by software (EMI/SEU resilience);
//                period set to ~256ms via WDTCON.WDTPS at runtime
//   PWRTE=ON     power-up timer: let the supply settle before code runs
//   BOREN=ON     brown-out reset enabled
//   BORV=HI      higher BOR trip point selected -- see the BOR note below
//   MCLRE=OFF    RA3 is a digital input (the footswitch); MCLR tied to VDD
//   CP=OFF       no code protection
//   LVP=OFF      high-voltage programming (no LVP); RA3/PGM not consumed
//   LPBOR=OFF    low-power BOR off (standard BOR via BOREN)
//   WRT=OFF      no flash self-write protection
//
// BOR note: the AVR uses a 4.3V BOD because the relay/MOSFET peripherals need
// >4V. The PIC10F322 BOR trip points are only ~2.4V (LO) / ~2.7V (HI), so the
// PIC CANNOT enforce a >4V floor in firmware -- that is a hardware-design
// limitation, not a firmware one. BORV=HI picks the higher (earlier) trip for
// the most conservative reset behaviour the device offers.

#include "bypass_config.h"        // PRESSED_THRESH / RELEASE_THRESH
#include "bypass_output_common.h" // -> bypass_pins_pic10f32x.h (build defines -DBYPASS_MCU_PIC10F32X)
#include "bypass_types.h"
#include "bypass_pure.h"
#include "bypass_hw_iface.h"
#include "bypass_static_assert.h" // static_assert()
#include "bypass_compile_checks.h"

#include <xc.h> // device SFRs, CLRWDT(), __delay_ms()

#include <stdint.h>


// CONFIG (configuration word)
#pragma config FOSC  = INTOSC
#pragma config BOREN = ON
#pragma config WDTE  = ON
#pragma config PWRTE = ON
#pragma config MCLRE = OFF
#pragma config CP    = OFF
#pragma config LVP   = OFF
#pragma config LPBOR = OFF
#pragma config BORV  = HI
#pragma config WRT   = OFF


//////////////////////////////////////////////////////////////////////////////
// CROSS-BOUNDARY HW OPS (implement bypass_hw_iface.h)
//////////////////////////////////////////////////////////////////////////////

// LED_PIN high = status LED lit; low = dark. Outputs are written via LATA.
void hw_led_pin_set_high(void) { LATA |=  (uint8_t)(1U << LED_PIN); }
void hw_led_pin_set_low(void)  { LATA &= (uint8_t)~(1U << LED_PIN); }


// - set a GPIO pin high or low
// - assumes pin was previously configured as output
void hw_pin_set_high(uint8_t const pin) { LATA |=  (uint8_t)(1U << pin); }
void hw_pin_set_low(uint8_t const pin)  { LATA &= (uint8_t)~(1U << pin); }


// configure exactly the pins in output_mask as outputs (TRISA bit = 0); all
// other pins are left as inputs (TRISA bit = 1). The selected pins are made
// digital (ANSELA bit = 0) and driven low (LATA bit = 0). RA3 is input-only and
// always remains an input (its TRISA bit reads 1).
void hw_configure_output_pins(uint8_t const output_mask) {
    ANSELA &= (uint8_t)~output_mask;                     // selected pins -> digital
    LATA   &= (uint8_t)~output_mask;                     // selected pins -> low
    TRISA   = (uint8_t)((uint8_t)~output_mask & 0x0FU);  // mask pins = output, rest = input
}


// sanity-check utility: return non-zero IFF every pin in expected_mask is still
// configured as an output (its TRISA direction bit is still 0).
uint8_t hw_output_pins_intact(uint8_t const expected_mask) {
    return (0U == (TRISA & expected_mask));
}


//////////////////////////////////////////////////////////////////////////////
// SHELL-INTERNAL HELPERS (file-static; NOT part of bypass_hw_iface.h)
//////////////////////////////////////////////////////////////////////////////

// infinite-loop function to force a watchdog reset, for critical, unrecoverable
// errors (presumably ultra-rare events: cosmic rays, extreme EMI). Disables
// interrupts first so nothing can pet the dog.
//
// IMPORTANT: relies on the watchdog being active (WDTE=ON in CONFIG); without
// it this would lock up the MCU.
__attribute__((noreturn)) static void hw_force_wdt_reset(void) {
    INTCONbits.GIE = 0;
    for (;;) { }
}


// read FOOTSW_PIN (RA3) to determine if it's high or low
//   FOOTSW_PIN high = switch open/released
//   FOOTSW_PIN low  = switch closed/pressed
// returns: PIN_STATE_HIGH or PIN_STATE_LOW
static pin_state_t hw_read_footswitch(void) {
    return (0U == (PORTA & (uint8_t)(1U << FOOTSW_PIN))) ?
        PIN_STATE_LOW :
        PIN_STATE_HIGH;
}


// non-zero IFF the footswitch weak pull-up is genuinely active. The PIC weak
// pull-up has a TWO-part enable: the per-pin WPUA latch AND the global,
// active-low OPTION_REG.nWPUEN. An SEU/EMI flip of EITHER silently disables the
// pull-up, so both are checked. (The AVR analogue checks the single PORTB latch
// bit that IS its pull-up enable; checking both here restores SEU-detection
// parity under the project's cosmic-ray/EMI threat model.)
//
// The two volatile SFRs are read into locals first so the && combines two plain
// (non-volatile) booleans: this keeps MISRA Rule 13.5 clean (no persistent side
// effect on the right operand of &&), which the project does not deviate.
static uint8_t hw_footswitch_pullup_intact(void) {
    uint8_t pin_latched = (uint8_t)(WPUA & (1U << FOOTSW_PIN));
    uint8_t wpu_global  = (uint8_t)OPTION_REGbits.nWPUEN; // 0 = enabled
    return (0U != pin_latched) && (0U == wpu_global);
}


// reset the WDT countdown ("pet the dog")
static void hw_wdt_pet(void) { CLRWDT(); }


// core MCU bring-up: 16MHz HFINTOSC, all-digital port, the footswitch weak
// pull-up, the global weak-pull-up enable, and the ~256ms watchdog period.
// Does NOT start the tick timer (see hw_tick_timer_start()).
//
// Ordering: call AFTER hw_init_output_pins() so the ANSELA/pull-up writes here
// do not disturb the output-pin direction setup.
static void hw_mcu_init(void) {
    // HFINTOSC = 16 MHz (IRCF = 0b111). Must match _XTAL_FREQ (asserted below),
    // which the relay/mute drivers' __delay_ms() relies on.
    OSCCONbits.IRCF = 0x07U;

    // entire port digital -- the I/O pins power up as analog inputs.
    ANSELA = 0x00U;

    // enable the footswitch (RA3) input pull-up; FOOTSW_PIN high = released,
    // low = pressed. (Belt-and-suspenders alongside any external pull-up.)
    WPUA  |= (uint8_t)(1U << FOOTSW_PIN);
    OPTION_REGbits.nWPUEN = 0; // enable weak pull-ups globally (active-low)

    // ~256ms (WDTPS = 0b01000 = 1:8192 on the ~31kHz LFINTOSC), mirroring the
    // AVR shell's 250ms. The LFINTOSC has ±25% tolerance (datasheet OS09) and
    // the WDT period is characterized at -37%/+69% (param 31), so worst-case
    // it is still ~160ms -- comfortably > the ~14ms worst-case pet-to-pet
    // window (1ms tick + 12ms relay coil pulse), unlike the prior 32ms (~1.4x
    // margin).
    WDTCONbits.WDTPS = 0x08U;
}


// configure + start the 1ms tick on TMR2, polled (no interrupt). At FOSC=16MHz
// the timer clock is FOSC/4 = 4MHz; prescale 1:16 -> 250kHz; PR2=249 -> (249+1)
// counts = 1ms (the postscaler is fixed 1:1 on this device). MUST run AFTER any
// blocking output actuation so a TMR2IF that set during init is not mistaken
// for the first real tick.
static void hw_tick_timer_start(void) {
    PR2   = 249U;        // 1ms period
    T2CON = 0x07U;       // T2CKPS = 0b11 (1:16 prescale), TMR2ON = 1
    PIR1bits.TMR2IF = 0; // start clean
}


// pause until the next 1ms tick, then clear the flag. The AVR sleeps here; the
// PIC polls TMR2IF (Model B, no sleep) -- same contract, hence the shared name.
static void hw_wait_for_tick(void) {
    while (0U == PIR1bits.TMR2IF) { }
    PIR1bits.TMR2IF = 0;
}


//////////////////////////////////////////////////////////////////////////////
// PROGRAM GLOBALS
//////////////////////////////////////////////////////////////////////////////

// overall debounce context. Unlike the AVR shell this need NOT be volatile or
// file-static for ISR sharing -- the PIC shell has no ISR; the single main loop
// is the sole owner. Kept at file scope (off main()'s stack) for parity with
// the AVR shell's resource-budget story.
static debounce_context_t ctx_;


//////////////////////////////////////////////////////////////////////////////
// INIT + MAIN
//////////////////////////////////////////////////////////////////////////////

// high-level initialization
// called at power-on, and after a reset (e.g. brown-out or watchdog timeout)
static void init(void) {

    // pin-map sanity: the PIC pin map hard-codes PORTA bit positions as literals
    // (0U,1U,2U,3U). Pin them at compile time against the DFP's _PORTA_RAx_POSN
    // so a typo in the map or a DFP change can never silently misroute a pin
    // (parity with the AVR shell's PBx asserts).
    static_assert(FOOTSW_PIN      == _PORTA_RA3_POSN, "FOOTSW_PIN must be RA3");
    static_assert(LED_PIN         == _PORTA_RA0_POSN, "LED_PIN must be RA0");
    static_assert(CD4053_PIN      == _PORTA_RA1_POSN, "CD4053_PIN must be RA1");
    static_assert(RELAY_RESET_PIN == _PORTA_RA1_POSN, "RELAY_RESET_PIN must be RA1");
    static_assert(RELAY_SET_PIN   == _PORTA_RA2_POSN, "RELAY_SET_PIN must be RA2");
    static_assert(CD4053_CTL1     == _PORTA_RA1_POSN, "CD4053_CTL1 must be RA1");
    static_assert(CD4053_CTL2     == _PORTA_RA2_POSN, "CD4053_CTL2 must be RA2");

    // _XTAL_FREQ (a build flag, used by the drivers' __delay_ms) must match the
    // 16MHz HFINTOSC selected in hw_mcu_init(), or the coil/mute pulse widths
    // would be wrong.
    static_assert(_XTAL_FREQ == 16000000UL, "_XTAL_FREQ must be 16 MHz (matches OSCCON IRCF)");


    // Pet the WDT first thing, mirroring the AVR shell's "re-arm first". Unlike
    // the AVR -- whose WDTCR collapses to the ~16ms minimum after a WDRF,
    // creating a short post-reset reset-loop hazard -- the PIC has no such
    // window: WDTE=ON runs the WDT from reset at its ~2s POR-default prescale
    // (1:65536 on the 31kHz LFINTOSC; confirm WDTCON's reset value in
    // DS40001585), which dwarfs init() + the <=12ms bypass pulse. hw_mcu_init()
    // narrows the period to ~256ms afterward (WDTPS=0x08). This early pet is
    // therefore belt-and-suspenders, not required -- it documents why no early
    // arming is needed and costs one instruction.
    hw_wdt_pet(); // i.e., CLRWDT()



    // driver: set pin directions FIRST (TRISA/ANSELA/LATA for the active variant)
    hw_init_output_pins();

    // clock, all-digital port, footswitch pull-up, watchdog period
    hw_mcu_init();

    // driver: default to bypass (may block on the relay/mute pulse, which is
    // shorter than one WDT period)
    hw_set_bypass_state();

    // initialize global switch state from the current footswitch level
    ctx_ = debounce_init_context(hw_read_footswitch());

    // LAST: start + clear the tick, immediately before the loop, so no compare
    // match accumulated during init is mistaken for the first real tick.
    hw_tick_timer_start();
}


// program entry point. Model B: a single polled 1ms loop. Each tick we sample +
// integrate the footswitch and advance the debounce state machine; CLRWDT at
// the end of every iteration is the main-loop liveness proof.
void main(void) {

    init(); // note: initializes ctx_ via debounce_init_context()

    for (;;) {

        // pause until the next 1ms TMR2 tick (polled; no sleep on Model B)
        hw_wait_for_tick();

        // basic sanity checks against outlier events (cosmic rays, extreme EMI);
        // always checked, regardless of state; force a WDT reset on any
        // violation. (No timer_isr_called_ guard as on AVR -- the PIC has no
        // ISR; main-loop liveness is proven by reaching hw_wdt_pet() below.)
        if ( (ctx_.program_state > RELEASE_DEBOUNCE_WAIT) ||
                (ctx_.effect_state > ENGAGED) ||
                // assert footswitch pull-up still enabled
                (0U == hw_footswitch_pullup_intact()) ||
                // config-specific runtime sanity checks
                hw_is_sanity_check_failed()
           ) {
            hw_force_wdt_reset();
        }

        // sample + integrate this tick (in the main loop, not an ISR)
        ctx_.debounce_counter = debounce_integrate(
                hw_read_footswitch(),
                ctx_.debounce_counter);

        // advance the debounce state machine.
        // NOTE: NOT const-qualified (unlike the AVR shell). XC8 places
        // const-qualified objects in program ROM, so a const local initialized
        // from a runtime call is rejected ("initializer element is not a
        // compile-time constant"). A required PIC/XC8 deviation.
        debounce_step_result_t res = debounce_step(ctx_);

        ctx_.program_state = res.program_state;
        ctx_.effect_state  = res.effect_state;
        if (res.reload_lockout) {
            ctx_.debounce_counter = res.lockout_value;
        }

        // note: the fault condition is defense-in-depth/belt-and-suspenders with
        // the sanity checks above
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

        // pet the dog: completing the loop body proves main() is alive
        hw_wdt_pet(); // i.e. CLRWDT()
    }
}

