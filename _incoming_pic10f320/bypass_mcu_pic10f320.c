// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman


/*****************************************************************************
 * NOTE: this source code makes numerous references to the parent project,
 *       mcu-bypass-firmware:
 *       https://github.com/matt-garman/mcu-bypass-firmware
 *****************************************************************************/


//
// PIC10F320 DIP-8 Pinout
//                                                     +----+
//                                            N/C pin1-|    |-pin8 RA3 (~MCLR/V_PP)
//                                           V_DD pin2-|    |-pin7 V_SS (GND)
// (INT/T0CKI/NCO1/CLC1IN1/CLKR/AN2/~CWG1FLT) RA2 pin3-|    |-pin6 N/C
//(PWM2/CLC1/CWG1B/AN1/CLKIN/ICSPCLK/NCO1CLK) RA1 pin4-|    |-pin5 RA0 (PWM1/CLC1IN0/CWG1A/AN0/ICSPDAT)
//                                                     +----+
//

#include <xc.h> // device SFRs, CLRWDT(), __delay_ms()

#include <assert.h>
#include <stdint.h>


// number of HIGH footswitch pin reads to be considered release-debounced,
// i.e. the "lock-out" period
#define RELEASE_THRESH  (25U)

// number of LOW footswitch pin reads to be considered press-debounced
#define PRESSED_THRESH  (8U)


// PIC10F320 pin map: PORTA/TRISA/LATA bit positions.  The PIC10F320 has four
// GPIO pins: RA0, RA1, RA2 are bidirectional, and RA3 is INPUT-ONLY (it
// shares MCLR/VPP; with MCLRE=OFF it is a plain digital input).  So the
// footswitch (an input) goes on RA3, freeing RA0-RA2 as the three outputs.
//
// footswitch and status LED pins are common across all output variants
#define FOOTSW_PIN      (3U) // RA3 (input-only) + weak pull-up
#define LED_PIN         (0U) // RA0


// RA1/RA2 designation depending on output scheme
#if defined(OUTPUT_CD4053_SIMPLE)
#  define CD4053_PIN      (1U) // RA1
#elif defined(OUTPUT_CD4053_WITH_MUTE)
#  define CD4053_CTL1     (1U) // RA1
#  define CD4053_CTL2     (2U) // RA2
#elif defined(OUTPUT_TQ2_RELAY)
#  define RELAY_RESET_PIN (1U) // RA1
#  define RELAY_SET_PIN   (2U) // RA2
#else
#  error "output scheme not defined: define one of OUTPUT_CD4053_SIMPLE, OUTPUT_CD4053_WITH_MUTE, or OUTPUT_TQ2_RELAY"
#endif



// Analog-switch control-pin drive polarity (CD4053 / TMUX4053): see parent
// project code/git history and also parent DESIGN_DOCUMENTATION.adoc:
// previous code had a polarity-inversion bug for the TMUX4053.  This is now
// fixed.

// Bits that must be OUTPUTS (RA0|RA1|RA2).
//
// Macro name ("DDR") is the AVR Classic convention from the parent project;
// we keep the DDR naming here to try to maintain conventions between
// projects.
//
// Macro value is the output-bit set, interpreted by
// the inline TRISA/LATA setup in init(); on PIC: TRISA bit 0 = output
// (hw_configure_output_pins() in the parent project)
//
// All output schemes use RA0..RA2:
//    relay = LED(RA0), RESET(RA1), SET(RA2)
//    mute = LED(RA0), CTL1(RA1), CTL2(RA2)
//    cd4053-simple = LED(RA0), CD4053(RA1), leaving RA2 a spare driven low
// Mask 0x07 for all
#define BYPASS_OUTPUT_DDR_MASK (0x07U) // RA0|RA1|RA2


// HFINTOSC frequency select value for 2 MHz (OSCCONbits.IRCF = 0b100).
// Must agree with _XTAL_FREQ (which is asserted below).
// Referenced both in init() and per-tick runtime sanity in main()
#define HFINTOSC_2MHZ_IRCF (0x04U) // 0b100 = 2 MHz

// WDT postscaler value for the chosen ~256 ms watchdog period.
// Per DS40001585: WDTPS = 0b01000 => 1:8192 on the ~31 kHz LFINTOSC.
// De-rated worst-case is asserted via WDT_MIN_PERIOD_MS below.
// Referenced both in init() and per-tick runtime sanity in main()
#define WDT_WDTPS_256MS (0x08U)

#define TMR2_T2CON_CONFIG (0x05U) // T2CKPS=0b01 (1:4),  TMR2ON=1
#define TMR2_PR2_PERIOD   (124U)  // PR2 = 124 -> 125 counts @ 125 kHz




// Upper bound for values stored in the uint8_t debounce counter, as an
// UNSIGNED constant.  We deliberately do NOT use <stdint.h>'s UINT8_MAX: by C
// integer-promotion rules a uint8_t promotes to (signed) int, so UINT8_MAX
// itself has type int.  Comparing it to our unsigned thresholds is an
// essential-type-category mix (MISRA 10.4), and its expansion (0x7f*2+1) also
// trips MISRA 12.1.  A plain unsigned literal means the same thing and avoids
// both -- see MISRA_COMPLIANCE.md.
//
// Loosely speaking: MISRA-C compliant UINT8_MAX
#define DEBOUNCE_COUNTER_MAX (255U)



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



// static_assert() shim for xc8-cc
//   - XC8 v3.10 supports only C99 (not C11), which does not have
//     static_assert() in <assert.h>
//   - this firmware makes extensive use of static_assert() compile-time
//     checks
//   - so here we alias static_assert() to _Static_assert(), which xc8 does
//     provide
#if !defined(static_assert)
#  define static_assert _Static_assert
#endif

// MCU-neutral threshold invariants -- identical across all shells, so defined
// once here.  Evaluated at file scope (zero runtime cost); a violation fails the
// build of every shell that includes this header.
static_assert(RELEASE_THRESH < DEBOUNCE_COUNTER_MAX, "RELEASE_THRESH >= DEBOUNCE_COUNTER_MAX (i.e. UINT8_MAX)");
static_assert(RELEASE_THRESH > 0U,                   "RELEASE_THRESH <= 0");
static_assert(RELEASE_THRESH > PRESSED_THRESH,       "RELEASE_THRESH <= PRESSED_THRESH");
static_assert(PRESSED_THRESH < DEBOUNCE_COUNTER_MAX, "PRESSED_THRESH >= DEBOUNCE_COUNTER_MAX (i.e. UINT8_MAX)");
static_assert(PRESSED_THRESH > 0U,                   "PRESSED_THRESH <= 0");

// pin-map sanity: the PIC pin map hard-codes PORTA bit positions as literals
// (0U,1U,2U,3U).  Pin them at compile time against the DFP's _PORTA_RAx_POSN
// so a typo in the map or a DFP change can never silently misroute a pin
static_assert(FOOTSW_PIN  == _PORTA_RA3_POSN, "FOOTSW_PIN must be RA3");
static_assert(LED_PIN     == _PORTA_RA0_POSN, "LED_PIN must be RA0");

// _XTAL_FREQ (a build flag, used by the drivers' __delay_ms) must match the
// 2MHz HFINTOSC selected in init(), or the coil/mute pulse widths
// would be wrong.
static_assert(_XTAL_FREQ ==  2000000UL, "_XTAL_FREQ must be 2 MHz (matches OSCCON IRCF)");


// Watchdog safety margin: formalises the hand-calculated budget described in
// init()'s WDTCON comment as a build-time invariant.  The longest stretch between
// two CLRWDT() "pets" is one tick wait plus the longest BLOCKING output actuation
// in a toggling tick (the relay/mute pulse).  That window must stay safely under
// the WDT's worst-case (shortest) period, or a healthy main loop could trip the
// dog.  The per-variant pulse term is asserted next to the existing
// "pulse < RELEASE_THRESH" check in each hw_is_sanity_check_failed().
//   TICK_PERIOD_MS    : the 1ms TMR2 tick (PR2=124 with the 1:4 prescaler on
//                       FOSC/4=500kHz -> 125kHz, so 125 counts = 1ms).
//   WDT_MIN_PERIOD_MS : ~256ms nominal (WDTPS=0x08 = 1:8192 on the ~31kHz
//                       LFINTOSC), de-rated by the datasheet worst-case -37%
//                       (param 31) to a ~160ms floor.
#define TICK_PERIOD_MS    (1U)
#define WDT_MIN_PERIOD_MS (160U)




//////////////////////////////////////////////////////////////////////////////
// TYPES
//////////////////////////////////////////////////////////////////////////////

// possible high-level states of the debounce/bypass scheme
typedef enum {
    // 1ms footswitch pin sampling, waiting for footswitch to be
    // press-debounced (i.e. footswitch considered open/released in this
    // state)
    PRESS_DEBOUNCE_WAIT = 0,

    // 1ms footswitch pin sampling, footswitch was previously confirmed
    // debounce-pressed, now waiting for footswitch to be release-debounced
    // (i.e. footswitch considered closed/pressed in this state)
    RELEASE_DEBOUNCE_WAIT,
} program_state_t;


// a flag to keep track of the effect/bypass state
typedef enum {
    BYPASS = 0,
    ENGAGED,
} effect_state_t;


// return type of hw_read_footswitch()
typedef enum {
    PIN_STATE_LOW = 0,
    PIN_STATE_HIGH
} pin_state_t;


// wrap up the three global variables that comprise the runtime context of the
// debounce-bypass algorithm
typedef struct {
    program_state_t program_state;
    effect_state_t  effect_state;
    uint8_t         debounce_counter;
} debounce_context_t;





//////////////////////////////////////////////////////////////////////////////
// HARDWARE INTERFACE FUNCTIONS
//////////////////////////////////////////////////////////////////////////////

// LED_PIN high = status LED lit; low = dark.  Outputs are written via LATA.
static void hw_led_pin_set_high(void) { LATA |=  (uint8_t)(1U << LED_PIN); }
static void hw_led_pin_set_low(void)  { LATA &= (uint8_t)~(1U << LED_PIN); }


// sanity-check utility: return non-zero IFF every pin in expected_mask is still
// configured as an output (its TRISA direction bit is still 0).
static uint8_t hw_output_pins_intact(uint8_t const expected_mask) {
    return (0U == (TRISA & expected_mask));
}


// Per-output-pin set-high/set-low functions live in each OUTPUT_* block below
// (one pair per control pin), not as a single hw_pin_set_high/low(pin) helper:
// every call site passes a compile-time-constant pin, but free-tier XC8 does
// not propagate that constant through a function-call boundary, so a
// parametric helper compiles to a real runtime shift loop.  Baking the bit into
// each pin's own function lets it collapse to a single bsf/bcf, matching what
// hw_led_pin_set_high/low above already do.





//////////////////////////////////////////////////////////////////////////////
// OUTPUT VARIANT: CD4053 SIMPLE
#if defined(OUTPUT_CD4053_SIMPLE)

// assert critical pin directions hold: LED & CD4053 outputs, footswitch input
static uint8_t hw_is_sanity_check_failed(void) {
    static_assert(CD4053_PIN  == _PORTA_RA1_POSN, "CD4053_PIN must be RA1");

    return (hw_output_pins_intact((1U << LED_PIN) | (1U << CD4053_PIN)) == 0U);
}

// Unified drive polarity (see the drive-polarity comment above): hw_x4053_ctl_high()
// asserts the analog-switch control signal for BYPASS -> drives CD4053_PIN LOW (the
// pulled-down fail-safe state); hw_x4053_ctl_low() asserts it for ENGAGE -> drives
// CD4053_PIN HIGH.  Correct for both the CD4053 (via its MOSFET inverter) and the
// pin-compatible logic-level TMUX4053 board.
//
// constant-bit functions, not a parametric hw_pin_set_high/low(pin) helper:
// see the comment below hw_output_pins_intact() for why.
static void hw_x4053_ctl_high(void) { LATA &= (uint8_t)~(1U << CD4053_PIN); }
static void hw_x4053_ctl_low(void)  { LATA |=  (uint8_t)(1U << CD4053_PIN); }

static void hw_set_bypass_state(void) {
    hw_led_pin_set_low(); // dark status LED
    hw_x4053_ctl_high(); // set CD4053 pin high
}

static void hw_set_engaged_state(void) {
    hw_led_pin_set_high(); // light status LED
    hw_x4053_ctl_low();   // set CD4053 pin low
}

//////////////////////////////////////////////////////////////////////////////
// OUTPUT VARIANT: CD4053 WITH MUTING
#elif defined(OUTPUT_CD4053_WITH_MUTE)

// how long to mute the effect before switching between effect/bypass
#  define CD4053_MUTE_DELAY_MS (5U)

static uint8_t hw_is_sanity_check_failed(void) {

    static_assert(CD4053_CTL1 == _PORTA_RA1_POSN, "CD4053_CTL1 must be RA1");
    static_assert(CD4053_CTL2 == _PORTA_RA2_POSN, "CD4053_CTL2 must be RA2");

    static_assert(CD4053_MUTE_DELAY_MS < RELEASE_THRESH,
            "CD4053 mute delay must be shorter than the release-lockout window, "
            "or the re-arm point can be missed during the blocking actuation");

    static_assert((TICK_PERIOD_MS + CD4053_MUTE_DELAY_MS) < WDT_MIN_PERIOD_MS,
            "1ms tick + mute pulse must stay under the worst-case WDT period");

    return (0U == hw_output_pins_intact((1U << LED_PIN) | (1U << CD4053_CTL1) | (1U << CD4053_CTL2)));
}

// wrap this into a function to save firmware space
// direct/inline use of __delay_ms() in the hw_set_xxx_state() calls below
// duplicates code and blows our 256-word flash budget of the PIC10F320;
// wrapping this into a single re-used function saves precious flash space
static void hw_x4053_mute_delay(void) {
    __delay_ms(CD4053_MUTE_DELAY_MS); // busy sleep for pre-switch mute time
}

// constant-bit functions, not a parametric hw_pin_set_high/low(pin) helper:
// see the comment below hw_output_pins_intact() for why.  Unified drive polarity
// for both the CD4053 and the pin-compatible TMUX4053 board (see the drive-
// polarity comment above the CD4053 SIMPLE block).
static void hw_x4053_ctl1_high(void) { LATA &= (uint8_t)~(1U << CD4053_CTL1); }
static void hw_x4053_ctl1_low(void)  { LATA |=  (uint8_t)(1U << CD4053_CTL1); }
static void hw_x4053_ctl2_high(void) { LATA &= (uint8_t)~(1U << CD4053_CTL2); }
static void hw_x4053_ctl2_low(void)  { LATA |=  (uint8_t)(1U << CD4053_CTL2); }

// See "Improved Scheme With Muting" in parent project
// DESIGN_DOCUMENTATION.adoc
static void hw_set_bypass_state(void) {
    hw_led_pin_set_low(); // dark status LED

    hw_x4053_ctl1_high(); // ENGAGED -> MUTE
    hw_x4053_mute_delay(); // busy sleep for pre-switch mute time

    hw_x4053_ctl2_high(); // MUTE -> BYPASS (i.e. un-mute in BYPASS state)
}

static void hw_set_engaged_state(void) {
    hw_x4053_ctl1_high(); // re-assert previous BYPASS state
    hw_x4053_ctl2_high();

    hw_led_pin_set_high(); // light status LED

    hw_x4053_ctl2_low(); // MUTE
    hw_x4053_mute_delay(); // busy sleep for pre-switch mute time

    hw_x4053_ctl1_low(); // un-mute in ENGAGED state
}

//////////////////////////////////////////////////////////////////////////////
// OUTPUT VARIANT: TQ2-L2-5V MECHANICAL RELAY
#elif defined(OUTPUT_TQ2_RELAY)

// Panasonic TQ-L2-5V specifies a 4ms minimum current pulse for the set/reset
// coils; multiply by a factor of three for a safety margin
#  define TQ2_L2_5V_PULSE_MS (12U)

static uint8_t hw_is_sanity_check_failed(void) {

    static_assert(TQ2_L2_5V_PULSE_MS < RELEASE_THRESH,
            "relay coil pulse must be shorter than the release-lockout window, "
            "or the re-arm point can be missed during the blocking actuation");

    static_assert((TICK_PERIOD_MS + TQ2_L2_5V_PULSE_MS) < WDT_MIN_PERIOD_MS,
            "1ms tick + relay coil pulse must stay under the worst-case WDT period");

    static_assert(RELAY_RESET_PIN == _PORTA_RA1_POSN, "RELAY_RESET_PIN must be RA1");
    static_assert(RELAY_SET_PIN   == _PORTA_RA2_POSN, "RELAY_SET_PIN must be RA2");

    return (0U == hw_output_pins_intact((1U << LED_PIN) | (1U << RELAY_SET_PIN) | (1U << RELAY_RESET_PIN)));
}

// constant-bit functions, not a parametric hw_pin_set_high/low(pin) helper:
// see the comment below hw_output_pins_intact() for why.  No polarity
// indirection needed here (the relay coils are not an x4053 control input).
static void hw_relay_reset_pin_set_high(void) { LATA |=  (uint8_t)(1U << RELAY_RESET_PIN); }
static void hw_relay_reset_pin_set_low(void)  { LATA &= (uint8_t)~(1U << RELAY_RESET_PIN); }
static void hw_relay_set_pin_set_high(void)   { LATA |=  (uint8_t)(1U << RELAY_SET_PIN); }
static void hw_relay_set_pin_set_low(void)    { LATA &= (uint8_t)~(1U << RELAY_SET_PIN); }

// force both coils low
// - it's not strictly necessary to set both low; but we do this as part of
//   the project's overall defense-in-depth/belt-and-suspenders paradigm
// - the intent is to prevent accidentally leaving the relay coil active too
//   long (e.g. programmer mistake)
static void set_relay_coils_low(void) {
    hw_relay_reset_pin_set_low();
    hw_relay_set_pin_set_low();
}

// wrap this into a function to save firmware space
// see notes for hw_x4053_mute_delay() above
static void hw_tq2_pulse_delay(void) {
    __delay_ms(TQ2_L2_5V_PULSE_MS);   // busy sleep for coil pulse time
}

static void hw_set_bypass_state(void) {
    set_relay_coils_low(); // re-assert expected state (both coils should already be low)

    hw_led_pin_set_low(); // dark status LED

    hw_relay_reset_pin_set_high(); // pulse reset coil
    hw_tq2_pulse_delay();          // busy sleep for coil pulse time

    set_relay_coils_low(); // done pulsing, force both coils low
}

static void hw_set_engaged_state(void) {
    set_relay_coils_low(); // re-assert expected state (both coils should already be low)

    hw_led_pin_set_high(); // light status LED

    hw_relay_set_pin_set_high(); // pulse set coil
    hw_tq2_pulse_delay();        // busy sleep for coil pulse time

    set_relay_coils_low(); // done pulsing, force both coils low
}

#else
#  error "output scheme not defined: define one of OUTPUT_CD4053_SIMPLE, OUTPUT_CD4053_WITH_MUTE, or OUTPUT_TQ2_RELAY"
#endif





// infinite-loop function to force a watchdog reset, for critical, unrecoverable
// errors (presumably ultra-rare events: cosmic rays, extreme EMI).  Disables
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


// non-zero IFF the footswitch weak pull-up is genuinely active.  The PIC weak
// pull-up has a TWO-part enable: the per-pin WPUA latch AND the global,
// active-low OPTION_REG.nWPUEN.  An SEU/EMI flip of EITHER silently disables the
// pull-up, so both are checked.
//
// The two volatile SFRs are read into locals first so the && combines two plain
// (non-volatile) booleans: this keeps MISRA Rule 13.5 clean (no persistent side
// effect on the right operand of &&), a rule from which the project does not
// deviate.
static uint8_t hw_footswitch_pullup_intact(void) {

    // Exact pull-up configuration integrity: RA3 latch set, RA0..RA2 clear,
    // and global weak pull-ups enabled.  Extra output-pin latches are faults
    // because a TRISA upset would make them electrically active.

    uint8_t wpua_latches = (uint8_t)(WPUA & 0x0FU);
    uint8_t wpu_global   = (uint8_t)OPTION_REGbits.nWPUEN; // 0 = enabled

    return
        (wpua_latches == (uint8_t)(1U << FOOTSW_PIN)) &&
        (0U == wpu_global);
}


// non-zero IFF the critical configuration SFRs still hold the values init() set:
// the 2MHz clock select (OSCCON.IRCF), the ~256ms watchdog period
// (WDTCON.WDTPS), the 1ms tick timer (PR2 + T2CON), and the all-digital
// output-pin select (ANSELA bits for RA0..RA2 clear).  An SEU/EMI flip of any of
// these silently breaks timing, or -- for ANSELA -- takes an output pin out of
// digital service (dark LED / dead control pin) while its TRISA direction bit
// still reads "output", which hw_is_sanity_check_failed() cannot see.
//
// A previous iteration of this function read each volatile SFR into a local
// first so the combining "&&" operators have no persistent side effect on
// their right operand so as to not deviate from MISRA Rule 13.5.  However,
// using locals eats into the space of the flash-constrained PIC10F320 part;
// and in practice, using the "&&" operator is not flagged as a MISRA
// violation.  In case this function ever fails MISRA 13.5, we can
// re-introduce the local variables (assuming there is flash space).
static uint8_t hw_critical_sfrs_intact(void) {
    return
        (HFINTOSC_2MHZ_IRCF == OSCCONbits.IRCF) &&
        (WDT_WDTPS_256MS == WDTCONbits.WDTPS) &&
        (TMR2_PR2_PERIOD == PR2) &&
        (TMR2_T2CON_CONFIG == T2CON) &&
        (0U == (uint8_t)(ANSELA & BYPASS_OUTPUT_DDR_MASK));
}



//////////////////////////////////////////////////////////////////////////////
// PROGRAM GLOBAL: overall debounce context
//////////////////////////////////////////////////////////////////////////////

static debounce_context_t ctx_;



//////////////////////////////////////////////////////////////////////////////
// INIT + MAIN
//////////////////////////////////////////////////////////////////////////////

// high-level initialization
// called at power-on, and after a reset (e.g. brown-out or watchdog timeout)
static void init(void) {

    // Pet the WDT first thing, mirroring the AVR shell's "re-arm first".
    // Unlike the AVR -- whose WDTCR collapses to the ~16ms minimum after a
    // WDRF, creating a short post-reset reset-loop hazard -- the PIC has no
    // such window: WDTE=ON runs the WDT from reset at its ~2s POR-default
    // prescale (1:65536 on the 31kHz LFINTOSC; confirm WDTCON's reset value
    // in DS40001585), which dwarfs init() + the <=12ms bypass pulse.  init()
    // narrows the period to ~256ms afterward (WDTPS=0x08).  This early pet is
    // therefore belt-and-suspenders, not required -- it documents why no
    // early arming is needed and costs one instruction.

    CLRWDT(); // reset the WDT countdown ("pet the dog")


    // configure exactly the pins in output_mask as outputs (TRISA bit = 0); all
    // other pins are left as inputs (TRISA bit = 1).  The selected pins are made
    // digital (ANSELA bit = 0) and driven low (LATA bit = 0).  RA3 is input-only and
    // always remains an input (its TRISA bit reads 1).
    LATA   &= (uint8_t)~BYPASS_OUTPUT_DDR_MASK;                     // selected pins -> low
    TRISA   = (uint8_t)((uint8_t)~BYPASS_OUTPUT_DDR_MASK & 0x0FU);  // mask pins = output, rest = input



    // core MCU bring-up: 2MHz HFINTOSC, all-digital port, the footswitch weak
    // pull-up, the global weak-pull-up enable, and the ~256ms watchdog period.
    // Does NOT start the tick timer (see below).
    //
    // Ordering: call AFTER output pins are configured (above) so the
    // ANSELA/pull-up writes here do not disturb the output-pin direction
    // setup.
    //
    // HFINTOSC = 2 MHz (IRCF = 0b100).  Must match _XTAL_FREQ (asserted
    // below), which the relay/mute drivers' __delay_ms() relies on.
    OSCCONbits.IRCF = HFINTOSC_2MHZ_IRCF;

    // entire port digital -- the I/O pins power up as analog inputs.
    ANSELA = 0x00U;

    // enable the footswitch (RA3) input pull-up
    // FOOTSW_PIN high = released; low = pressed
    // belt-and-suspenders alongside any external pull-up
    WPUA = (uint8_t)(1U << FOOTSW_PIN);
    OPTION_REGbits.nWPUEN = 0; // enable weak pull-ups globally (active-low)


    // ~256ms (WDTPS = 0b01000 = 1:8192 on the ~31kHz LFINTOSC), mirroring the
    // AVR shell's 250ms.  The LFINTOSC has ±25% tolerance (datasheet OS09)
    // and the WDT period is characterized at -37%/+69% (param 31), so
    // worst-case it is still ~160ms -- comfortably > the ~13ms worst-case
    // pet-to-pet window (1ms tick + 12ms relay coil pulse), unlike the prior
    // 32ms (~1.4x margin).
    WDTCONbits.WDTPS = WDT_WDTPS_256MS;



    // default to bypass (may block on the relay/mute pulse, which is shorter
    // than one WDT period)
    // note, the 4053-with-mute and relay variants use __delay_ms(): so it's
    // important that this is invoked AFTER the OSCCONbits.IRCF setting above
    hw_set_bypass_state();

    // initialize global switch state from the current footswitch level
    // typical startup case: assume switch is not pressed
    ctx_.program_state    = PRESS_DEBOUNCE_WAIT;
    ctx_.effect_state     = BYPASS;
    ctx_.debounce_counter = 0U;

    // special case: footswitch pressed during power-on: keep in bypass state,
    // but use timer + footswitch polling to wait for release
    if (PIN_STATE_LOW == hw_read_footswitch()) {
        ctx_.program_state = RELEASE_DEBOUNCE_WAIT;
        ctx_.debounce_counter = RELEASE_THRESH;
    }



    // LAST: start + clear the tick, immediately before the loop, so no
    // compare match accumulated during init is mistaken for the first real
    // tick.
    //
    // configure + start the 1ms tick on TMR2, polled (no interrupt).  At
    // FOSC=2MHz the timer clock is FOSC/4 = 500kHz; the 1:4 PREscaler
    // (T2CKPS) -> 125kHz, and  │ PR2=124 -> (124+1) = 125 counts = 1ms
    // period.  The output POSTscaler (T2OUTPS) is set to 1:1, so TMR2IF
    // asserts on every PR2 match (once per 1ms), not once per N matches.
    // MUST run AFTER any blocking output actuation so a TMR2IF that set
    // during init is not mistaken for the first real tick.
    PR2   = TMR2_PR2_PERIOD;   // 1ms period
    T2CON = TMR2_T2CON_CONFIG; // T2CKPS = 0b01 (1:4 prescale), TMR2ON = 1
    PIR1bits.TMR2IF = 0;       // start clean
}


// program entry point: a single polled 1ms loop.
// Each tick we sample + integrate the footswitch and advance the debounce
// state machine; CLRWDT at the end of every iteration is the main-loop
// liveness proof.
void main(void) {

    init(); // note: initializes ctx_

    for (;;) {

        // pause until the next 1ms tick, then clear the flag; the PIC polls
        // TMR2IF (no sleep)
        while (0U == PIR1bits.TMR2IF) { }
        PIR1bits.TMR2IF = 0;



        // basic sanity checks against outlier events (cosmic rays, extreme
        // EMI); always checked, regardless of state; force a WDT reset on any
        // violation.
        // main-loop liveness is proven by reaching CLRWDT() below.
        if ( (ctx_.program_state > RELEASE_DEBOUNCE_WAIT) ||
                (ctx_.effect_state > ENGAGED) ||
                (ctx_.debounce_counter > RELEASE_THRESH) ||
                // assert footswitch pull-up still enabled
                (0U == hw_footswitch_pullup_intact()) ||
                // assert the critical config SFRs still hold their init() values
                // (2MHz clock, ~256ms WDT period, 1ms tick timer, all-digital
                // output pins) -- see hw_critical_sfrs_intact()
                (0U == hw_critical_sfrs_intact()) ||
                // config-specific runtime sanity checks
                hw_is_sanity_check_failed()
           ) {
            hw_force_wdt_reset();
        }



        // inline version of parent project's pure debounce_integrate()
        //
        // sample + integrate this tick (in the main loop, not an ISR)
        //
        // saturating integrator update:
        //   footswitch pin zero (low) == switch closed
        //   footswitch pin one (high) == switch open
        if (PIN_STATE_LOW == hw_read_footswitch()) { // switch closed
            if (ctx_.debounce_counter < RELEASE_THRESH) { ++ctx_.debounce_counter; }
        }
        else { // footswitch pin is high -> switch open
            if (ctx_.debounce_counter > 0U) { --ctx_.debounce_counter; }
        }




        // inline version of parent project's pure debounce_step()
        //
        // advance the debounce state machine
        switch (ctx_.program_state) {

            // waiting for the footswitch to be press-debounced
            case PRESS_DEBOUNCE_WAIT:
                {
                    // check for press-debounced condition
                    if (ctx_.debounce_counter >= PRESSED_THRESH) {
                        ctx_.debounce_counter = RELEASE_THRESH;
                        ctx_.program_state = RELEASE_DEBOUNCE_WAIT;
                        if (BYPASS == ctx_.effect_state) {
                            ctx_.effect_state = ENGAGED;
                            hw_set_engaged_state();
                        }
                        else { // ENGAGED == ctx_.effect_state
                            ctx_.effect_state = BYPASS;
                            hw_set_bypass_state();
                        }
                    }
                }
                break;

            // waiting for the footswitch to be release-debounced
            // note: holding the switch closed, or mechanical
            //       failure (e.g. switch welded shut) causes this
            //       state to exist indefinitely: this is the design
            //       intent (software is "helpless", need physical
            //       human resolution)
            case RELEASE_DEBOUNCE_WAIT:
                {
                    if (0U == ctx_.debounce_counter) {
                        ctx_.program_state = PRESS_DEBOUNCE_WAIT;
                    }
                }
                break;

            // technically impossible to reach (sanity checks above would
            // catch this); but left for defense-in-depth/belt-and-suspenders
            // idiom of the overall project
            default:
                hw_force_wdt_reset();
                break;
        }


        // completing the loop body proves main() is alive
        CLRWDT(); // reset the WDT countdown ("pet the dog")
    }
}

