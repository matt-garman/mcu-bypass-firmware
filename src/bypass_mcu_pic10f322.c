// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman


// PIC10F322 hardware shell (Microchip XC8 toolchain).
//
// Implements the bypass_hw_iface.h contract for the PIC10F322 MCU and
// provides this family's main(), CONFIG bits, and tick/watchdog model. It is
// the PIC counterpart of the classic-AVR shell (bypass_mcu_avr_classic.c); the
// pure debounce core (bypass_pure.c) and the three output drivers are shared
// UNCHANGED.
//
// Tick/WDT model "B" (see "The shared model: polled tick, pure fault
// watchdog" in DESIGN_DOCUMENTATION.adoc): a hardware timer (TMR2) drives a
// ~1ms tick that is POLLED in the main loop (no sleep); the watchdog is a
// pure FAULT watchdog at ~256ms, CLRWDT'd once per tick. There is no timer
// ISR and no ISR/main handshake -- the single polled loop reaching CLRWDT is
// itself the liveness proof.
//
// CONFIG / fuse rationale (PIC analogue of the AVR fuse table in the AVR shell):
//   FOSC=INTOSC  internal 2MHz HFINTOSC (CLKIN pin function disabled)
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
#include "bypass_output_common.h" // -> bypass_pins_pic10f322.h (build defines -DBYPASS_MCU_PIC10F322)
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


#define HFINTOSC_2MHZ_IRCF  (0x04U) // 0b100 = 2 MHz; must match _XTAL_FREQ
#define WDT_WDTPS_256MS     (0x08U) // WDTCONbits.WDTPS = 1:8192 -> ~256 ms
#define TMR2_PR2_PERIOD     (124U)  // PR2 = 124 -> 125 counts @ 125 kHz = 1 ms
#define TMR2_T2CON_CONFIG   (0x05U) // T2CKPS=0b01 (1:4),  TMR2ON=1



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
void hw_pin_mask_set_low(uint8_t const pin_mask) {
    LATA &= (uint8_t)~pin_mask;
}


// configure exactly the pins in output_mask as outputs (TRISA bit = 0); all
// other pins are left as inputs (TRISA bit = 1). The selected pins are made
// digital (ANSELA bit = 0) and driven low (LATA bit = 0). RA3 is input-only and
// always remains an input (its TRISA bit reads 1).
void hw_configure_output_pins(uint8_t const output_mask) {
    ANSELA &= (uint8_t)~output_mask;                     // selected pins -> digital
    LATA   &= (uint8_t)~output_mask;                     // selected pins -> low
    TRISA   = (uint8_t)((uint8_t)~output_mask & 0x0FU);  // mask pins = output, rest = input
}


// sanity-check utility: return non-zero ("true") IFF the complete direction
// configuration still matches initialization, every pin in
// required_output_mask is still configured as an output (its TRISA direction
// bit is still 0), and the complete output latch matches the expected state.
//
// Exact TRISA protects RA0..RA2 as outputs (including the spare low-driven
// pin on the simple-CD4053 variant) and RA3 as the footswitch input. RA3 is
// input-only in silicon (its TRISA bit always reads 1), so the expected value
// is the four implemented direction bits minus the configured outputs.
uint8_t hw_output_state_intact(
        uint8_t const required_output_mask,
        uint8_t const expected_high_mask) {

    uint8_t actual_direction_mask = (uint8_t)(TRISA & 0x0FU);

    // OR-fold, not a chain of && (see hw_critical_sfrs_intact() for the full
    // rationale): every term is a pure read, so folding is equivalent, and it
    // drops XC8's per-&&-term branch scaffolding.
    uint8_t diff = 0U;

    // 0x0FU ^ BYPASS_OUTPUT_DDR_MASK = 0x08: only RA3 remains an input
    diff |= (uint8_t)(actual_direction_mask ^
                      (uint8_t)(0x0FU ^ BYPASS_OUTPUT_DDR_MASK));
    diff |= (uint8_t)(actual_direction_mask & required_output_mask);
    diff |= (uint8_t)((uint8_t)(LATA & (uint8_t)BYPASS_OUTPUT_DDR_MASK) ^
                      expected_high_mask);

    return (uint8_t)((0U == diff) ? 1U : 0U);
}

// sanity-check utility: return non-zero ("true") IFF all the critical pin
// values are what we want
// SFR = special function register, the "control panel" of the MCU
static uint8_t hw_critical_sfrs_intact(void) {

    // OSCCON: IRCF<6:4> is the ONLY read/write field on the PIC10F322 and is
    // what selects the HFINTOSC frequency, so validating it covers the whole
    // register's timing-relevant state. The rest need no check and must not be
    // checked: HFIOFS(0)/LFIOFR(1)/HFIOFR(3) are read-only oscillator-status
    // flags that change legitimately as the oscillator settles (checking them
    // would false-trip), and bits 2 and 7 are unimplemented (read 0). This part
    // has no runtime clock-source select (no SCS/OSTS/PLL) -- FOSC=INTOSC is
    // fixed in CONFIG1 at program time and is validated separately
    // (test_config_pic / the fault-injection CONFIG check).
    // (Datasheet DS40001585, Register 5-1.)

    // Each term is XORed against its expected value and OR-folded into a
    // single accumulator, rather than combined with &&. Three reasons:
    //
    //  1. FLASH. XC8 (free-mode codegen) spends ~5 program words of branch
    //     scaffolding on EVERY && / || term; the fold costs ~3 words per term
    //     total. Across this function, hw_footswitch_pullup_intact() and
    //     hw_output_state_intact() that is the ~20 words that keep the relay
    //     variant inside the PIC10F322's 512.
    //  2. Constant time. No early exit, so a sanity sweep costs the same
    //     whether it passes or fails -- one less data-dependent timing path in
    //     the tick budget.
    //  3. MISRA. Every statement below performs exactly ONE volatile SFR read,
    //     so Rule 13.5 (persistent side effect in the right-hand operand of &&)
    //     cannot arise and Rule 13.2 (order of evaluation) is satisfied without
    //     needing the intermediate non-volatile locals the && form required.
    //
    // diff == 0 IFF every term matched, so the fold is exactly equivalent to
    // the && chain it replaces.
    uint8_t diff = 0U;

    diff |= (uint8_t)(HFINTOSC_2MHZ_IRCF ^ (uint8_t)OSCCONbits.IRCF);
    diff |= (uint8_t)(WDT_WDTPS_256MS    ^ (uint8_t)WDTCONbits.WDTPS);
    diff |= (uint8_t)(TMR2_PR2_PERIOD    ^ (uint8_t)PR2);
    diff |= (uint8_t)(TMR2_T2CON_CONFIG  ^ (uint8_t)T2CON);
    diff |= (uint8_t)(ANSELA & BYPASS_OUTPUT_DDR_MASK); // 0 = pins still digital

    return (uint8_t)((0U == diff) ? 1U : 0U);
}



//////////////////////////////////////////////////////////////////////////////
// SHELL-INTERNAL HELPERS (file-static; NOT part of bypass_hw_iface.h)
//////////////////////////////////////////////////////////////////////////////

// infinite-loop function to force a watchdog reset, for critical, unrecoverable
// errors (presumably ultra-rare events: cosmic rays, extreme EMI). Disables
// interrupts first so nothing can pet the dog.
//
// The FIRST act is hw_outputs_reassert_safe(): any output with a
// continuous-energization hazard (the relay coils) is driven to its
// de-energized idle BEFORE the spin, so no fault can hold a coil energized
// for the whole ~256ms watchdog period. The reset then re-runs init(), whose
// full-width BYPASS actuation re-synchronizes the physical relay with the
// logical state and the LED.
//
// IMPORTANT: relies on the watchdog being active (WDTE=ON in CONFIG); without
// it this would lock up the MCU.
__attribute__((noreturn)) static void hw_force_wdt_reset(void) {
    hw_outputs_reassert_safe();
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
// The two terms are OR-folded rather than combined with && (see
// hw_critical_sfrs_intact() for the rationale). Each statement performs exactly
// one volatile SFR read, so MISRA Rule 13.5 (no persistent side effect on the
// right operand of &&), which the project does not deviate, cannot arise.
static uint8_t hw_footswitch_pullup_intact(void) {

    // Exact pull-up configuration integrity: RA3 latch set, RA0..RA2 clear,
    // and global weak pull-ups enabled.  Extra output-pin latches are faults
    // because a TRISA upset would make them electrically active.

    uint8_t diff = 0U;

    diff |= (uint8_t)((uint8_t)(WPUA & 0x0FU) ^ (uint8_t)(1U << FOOTSW_PIN));
    diff |= (uint8_t)OPTION_REGbits.nWPUEN; // 0 = enabled

    return (uint8_t)((0U == diff) ? 1U : 0U);
}


// reset the WDT countdown ("pet the dog")
static void hw_wdt_pet(void) { CLRWDT(); }


// core MCU bring-up: 2MHz HFINTOSC, all-digital port, the footswitch weak
// pull-up, the global weak-pull-up enable, and the ~256ms watchdog period.
// Does NOT start the tick timer (see hw_tick_timer_start()).
//
// Ordering: call AFTER hw_init_output_pins() so the ANSELA/pull-up writes here
// do not disturb the output-pin direction setup.
static void hw_mcu_init(void) {
    // HFINTOSC = 2 MHz (IRCF = 0b100).  Must match _XTAL_FREQ (asserted
    // below), which the relay/mute drivers' __delay_ms() relies on.
    OSCCONbits.IRCF = HFINTOSC_2MHZ_IRCF;

    // entire port digital -- the I/O pins power up as analog inputs.
    ANSELA = 0x00U;

    // enable the footswitch (RA3) input pull-up; FOOTSW_PIN high = released,
    // low = pressed. (Belt-and-suspenders alongside any external pull-up.)
    WPUA = (uint8_t)(1U << FOOTSW_PIN);
    OPTION_REGbits.nWPUEN = 0; // enable weak pull-ups globally (active-low)

    // ~256ms (WDTPS = 0b01000 = 1:8192 on the ~31kHz LFINTOSC), mirroring the
    // AVR shell's 250ms. The LFINTOSC has ±25% tolerance (datasheet OS09) and
    // the WDT period is characterized at -37%/+69% (param 31), so worst-case
    // it is still ~160ms -- comfortably > the 14ms worst-case pet-to-pet
    // window WDT_PET_TO_PET_MAX_MS() asserts (12ms relay coil pulse + 1ms
    // scheduling latency + 1ms bounded loop work), unlike the prior 32ms
    // (~1.4x margin).
    WDTCONbits.WDTPS = WDT_WDTPS_256MS;
}


// configure + start the 1ms tick on TMR2, polled (no interrupt).  At
// FOSC=2MHz the timer clock is FOSC/4 = 500kHz; the 1:4 PREscaler (T2CKPS) ->
// 125kHz, and  │ PR2=124 -> (124+1) = 125 counts = 1ms period.  The output
// POSTscaler (T2OUTPS) is set to 1:1, so TMR2IF asserts on every PR2 match
// (once per 1ms), not once per N matches. MUST run AFTER any blocking output
// actuation so a TMR2IF that set during init is not mistaken for the first
// real tick.
static void hw_tick_timer_start(void) {
    PR2   = TMR2_PR2_PERIOD;   // 1ms period
    T2CON = TMR2_T2CON_CONFIG; // T2CKPS = 0b01 (1:4 prescale), TMR2ON = 1
    PIR1bits.TMR2IF = 0;       // start clean
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

// Persisted debounce context. The PIC has no ISR, but volatile is load-bearing
// for the F2 transaction: each tick must take one real snapshot and publish one
// real successor rather than let the compiler reuse live global values.
static volatile debounce_context_t ctx_;

#if defined(BYPASS_CTX_CHECK)
// debounce_context_t checksum; see debounce_ctx_check_word()
static volatile uint8_t ctx_check_;
#endif



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
    // 2MHz HFINTOSC selected in init(), or the coil/mute pulse widths
    // would be wrong.
    static_assert(_XTAL_FREQ ==  2000000UL, "_XTAL_FREQ must be 2 MHz (matches OSCCON IRCF)");


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

    // Build one intended initial context, then publish its check and bytes.
    // XC8 rejects a runtime-initialized const local, so this is non-const.
    debounce_context_t next_ctx =
        debounce_init_context(hw_read_footswitch());

#if defined(BYPASS_CTX_CHECK)
    ctx_check_ = debounce_ctx_check_word(next_ctx);
#endif
    ctx_ = next_ctx;

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
        debounce_context_t next_ctx = ctx_;

        // basic sanity checks against outlier events (cosmic rays, extreme EMI);
        // always checked, regardless of state; force a WDT reset on any
        // violation. (No timer_isr_called_ guard as on AVR -- the PIC has no
        // ISR; main-loop liveness is proven by reaching hw_wdt_pet() below.)
        //
        // hw_is_sanity_check_failed() is also the relay coil guard: it compares
        // the complete output latch, so an unexpectedly energized coil is an
        // output-latch mismatch and escalates here. Nothing re-drives the coils
        // ahead of this check -- a below-minimum pulse cannot be proven
        // mechanically harmless, so recovery, not a silent clear, decides the
        // relay position.
        if (
#if defined(BYPASS_CTX_CHECK)
                (ctx_check_ != debounce_ctx_check_word(next_ctx)) ||
#endif
                (next_ctx.program_state > RELEASE_DEBOUNCE_WAIT) ||
                (next_ctx.debounce_counter > RELEASE_THRESH) ||
                (next_ctx.effect_state > ENGAGED) ||
                // assert footswitch pull-up still enabled
                (0U == hw_footswitch_pullup_intact()) ||
                // config-specific runtime sanity checks
                hw_is_sanity_check_failed(next_ctx.effect_state) ||
                (0U == hw_critical_sfrs_intact())
           ) {
            hw_force_wdt_reset();
        }

        // sample + integrate this tick (in the main loop, not an ISR)
        next_ctx.debounce_counter = debounce_integrate(
                hw_read_footswitch(),
                next_ctx.debounce_counter);

        // advance the debounce state machine.
        // NOTE: NOT const-qualified (unlike the AVR shell). XC8 places
        // const-qualified objects in program ROM, so a const local initialized
        // from a runtime call is rejected ("initializer element is not a
        // compile-time constant"). A required PIC/XC8 deviation.
        debounce_step_result_t res = debounce_step(next_ctx);

        next_ctx.program_state = res.program_state;
        next_ctx.effect_state  = res.effect_state;
        if (res.reload_lockout) {
            next_ctx.debounce_counter = res.lockout_value;
        }
#if defined(BYPASS_CTX_CHECK)
        // Derive from the validated intended successor, never live persisted
        // SRAM: a post-snapshot upset is overwritten or remains a mismatch.
        ctx_check_ = debounce_ctx_check_word(next_ctx);
#endif
        ctx_ = next_ctx;

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
