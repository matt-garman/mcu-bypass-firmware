// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman


// PIC12F675 hardware shell (Microchip XC8 toolchain).
//
// PIC12F675-near equivalent of bypass_mcu_pic10f322.c:
//     - implements bypass_hw_iface.h contract
//     - provides main(), CONFIG bits, and tick/watchdog model
//     - in Microchip jargon: pic12f675 is "classic-mid-range"; pic10f32x is
//       "enhanced-mid-range"
//     - note the peripheral set between 12f6xx and 10f32x differs, so a separate
//       shell is required
//
// Tick/WDT model "B" (see docs/phase2_pic_shell.md): a hardware timer (TMR0)
// drives a ~1ms tick that is POLLED in the main loop (no sleep); the watchdog
// is a pure FAULT watchdog at ~288ms, CLRWDT'd once per tick. There is no timer
// ISR and no ISR/main handshake: the single polled loop reaching CLRWDT is
// itself the liveness proof.
//
// Note the tick is 1.024ms, not 1.000ms; this is deliberate. OPTION_REG.PSA
// assigns the ONE prescaler to EITHER TMR0 OR the watchdog, never both, and
// this part has no period register anywhere (no TMR2/PR2, no CCP). Giving the
// prescaler to TMR0 would leave the WDT at its 18ms nominal base period. That
// value exceeds a 12ms relay pulse plus one 1.024ms tick; the safety decision
// instead rests on the 10ms characterized minimum, which is shorter than the
// normal pet-to-pet path once loop overhead is included. So the prescaler goes
// to the WDT (PSA=1, PS=1:16 -> 288ms nominal, 160ms minimum), and TMR0 runs
// unprescaled at Fosc/4 = 1MHz, rolling over every 256us; four rollovers counted
// in software make the 1.024ms tick. The 2.4% stretch changes nothing in the
// pure core (which counts samples, not milliseconds), but it changes every
// physical timing figure. See docs/pic12f675_feasibility.md section 4.4.1.
//
// CONFIG / fuse rationale (PIC analogue of the AVR fuse table in the AVR shell):
//   FOSC=INTRCIO internal 4MHz INTOSC with I/O on BOTH GP4 and GP5 -- required,
//                since GP5 is the footswitch (the CLKIN pin function must be
//                released). This part has no OSCCON and no runtime frequency
//                select: 4MHz is fixed in silicon, trimmed by OSCCAL.
//   WDTE=ON      watchdog cannot be disabled by software (EMI/SEU resilience);
//                period set to ~288ms via OPTION_REG PSA/PS at runtime
//   PWRTE=ON     power-up timer: let the supply settle before code runs
//   MCLRE=OFF    GP3 is a digital spare input with an external ICSP-safe
//                pull-up; MCLR tied internally to VDD
//   BOREN=ON     brown-out reset enabled
//   CP=OFF       no program-memory code protection
//   CPD=OFF      no data-EEPROM code protection (the 128B EEPROM is unused;
//                this field has no PIC10F322 counterpart)
// Absent relative to the PIC10F322: LVP, WRT, BORV, LPBOR.
//
// BG note: CONFIG bits 13:12 (BG1:BG0, mask 0x3000) are the factory bandgap
// calibration and have no #pragma config setting in the device pack, so they
// take the CWORD default (0b11). They set the BOD/POR trip voltages and are
// programmed per device at the factory. Whether a programmer PRESERVES them is
// a silicon-only concern -- see docs/pic12f675_feasibility.md section 8 item 1.
//
// BOR note: the AVR uses a 4.3V BOD because the relay/MOSFET peripherals need
// >4V. The PIC12F675 BOR trip point is ~2.1V and, unlike the PIC10F322, this
// part has no BORV field -- there is not even a high/low choice. So the PIC
// CANNOT enforce a >4V floor in firmware; that is a hardware-design
// limitation, not a firmware one.
//
// OSCCAL note: the oscillator calibration value lives in the LAST program
// word (0x3FF, the pack's ".oscval" CalDataZone) as a RETLW, and XC8's
// startup code calls it. A bulk erase that does not preserve that word leaves
// an untrimmed oscillator, i.e. wrong tick cadence and wrong __delay_ms()
// coil-pulse widths on a device that still appears to work. The guarded
// pic12f675-program workflow rejects an image that explicitly programs word
// 0x3FF, requires a matching baseline and immediate pre-write read, and
// records mandatory post-write trim/readback evidence. It detects
// programmer-induced loss only after the write; real preservation remains
// hardware-unvalidated. See release/README.md and
// docs/pic12f675_feasibility.md section 8 item 2.



#include "bypass_config.h"        // PRESSED_THRESH / RELEASE_THRESH
#include "bypass_output_common.h" // -> bypass_pins_pic12f675.h (build defines -DBYPASS_MCU_PIC12F675)
#include "bypass_types.h"
#include "bypass_pure.h"
#include "bypass_hw_iface.h"
#include "bypass_static_assert.h" // static_assert()
#include "bypass_compile_checks.h"

#include <xc.h> // device SFRs, CLRWDT(), __delay_ms()

#include <stdint.h>


// CONFIG (configuration word, 0x2007)
#pragma config FOSC  = INTRCIO
#pragma config WDTE  = ON
#pragma config PWRTE = ON
#pragma config MCLRE = OFF
#pragma config BOREN = ON
#pragma config CP    = OFF
#pragma config CPD   = OFF


// Implemented-bit masks. This part has 6 I/O (GP0..GP5) so the port registers
// carry 6 implemented bits, unlike the PIC10F322's 4.
#define GPIO_IMPLEMENTED_MASK  (0x3FU) // GP0..GP5
#define WPU_IMPLEMENTED_MASK   (0x37U) // GP0,GP1,GP2,GP4,GP5 (GP3 has NO pull-up)

// ANSEL bit positions match GPIO for GP0..GP2, but ANS3 controls GP4:
// GPIO bit 4 therefore maps to ANSEL bit 3. All four output-capable analog pins
// must remain digital now that spare GP4 is a parked output.
#define ANSEL_OUTPUT_MASK      (0x0FU) // ANS0..ANS3 = GP0,GP1,GP2,GP4

// OPTION_REG, written as a whole and checked exactly. It carries THREE
// safety-relevant fields on this part, where the PIC10F322 spreads the same
// state across WDTCON, PR2/T2CON and OPTION_REG:
//   nGPPU  = 0     bit 7  global weak pull-ups ENABLED (active low)
//   INTEDG = 0     bit 6  INT edge select; INT unused, pinned for exactness
//   T0CS   = 0     bit 5  TMR0 clocked from the instruction clock (Fosc/4)
//   T0SE   = 0     bit 4  TMR0 edge select; unused when T0CS=0
//   PSA    = 1     bit 3  prescaler assigned to the WATCHDOG, not TMR0
//   PS     = 0b100 bits 2:0  1:16 -> WDT ~288ms (18ms nominal base x 16)
#define OPTION_REG_CONFIG      (0x0CU)

// TMR0 is unprescaled at Fosc/4 = 1MHz, so it rolls over every 256us. Four
// rollovers make the 1.024ms tick.
#define TMR0_SUBTICKS_PER_TICK (4U)

// CMCON = 0x07 -> CM<2:0> = 111 = comparator OFF. MANDATORY: CM<2:0> = 000 out
// of reset ("Comparator Reset" mode) makes GP0/CIN+ and GP1/CIN- analog
// inputs, and an analog input ALWAYS READS 0 whatever the pin is driving. Two
// of this design's three active outputs are on GP0/GP1, so leaving CM<2:0> =
// 000 would fail the port-follows-shadow check on every tick. GP2 is not taken
// at reset; COUT reaches it in three of the eight modes, which is an upset
// path rather than the reset state. Parked GP4 has no comparator function.
#define CMCON_COMPARATOR_OFF   (0x07U)

// ADCON0 = 0x00 -> ADON = 0, ADC off.
#define ADCON0_ADC_OFF         (0x00U)



//////////////////////////////////////////////////////////////////////////////
// OUTPUT SHADOW LATCH
//////////////////////////////////////////////////////////////////////////////

// The classic mid-range core has NO LATx register. Reading GPIO returns the
// PHYSICAL PIN LEVELS, not the last value written, so the PIC10F322 idiom
//
//     LATA |= (uint8_t)(1U << pin);
//
// becomes a read-modify-write ON THE PINS if written against GPIO -- the
// classic PIC defect. A loaded output (an LED through a resistor, a relay
// coil, a pin still slewing) can read back a level different from the one
// written, and the write-back then corrupts OTHER bits in the same port.
//
// So every write goes shadow -> GPIO, and GPIO is never read-modify-written.
//
// The shadow is SRAM, which the project's cosmic-ray/EMI threat model says can
// flip. A non-coil shadow upset, or any shadow/port mismatch still present when
// hw_output_state_intact() runs, reaches the sanity gate. On the relay variant,
// hw_outputs_reassert_safe() deliberately clears settled GP1/GP2 coil-shadow
// upsets at loop top before that check.
static uint8_t gpio_shadow_;

// Snapshot of the factory oscillator trim, captured in hw_mcu_init() and
// re-checked every tick. This part has no OSCCON, so there is no constant to
// compare against: OSCCAL is device-specific factory trim loaded from program
// word 0x3FF by XC8's startup code, and the only meaningful check is that it
// has not CHANGED since init. (Structurally the PIC10F322's OSCCON.IRCF guard,
// with a captured value where the 322 has a compile-time constant.)
static uint8_t osccal_snapshot_;


//////////////////////////////////////////////////////////////////////////////
// CROSS-BOUNDARY HW OPS (implement bypass_hw_iface.h)
//////////////////////////////////////////////////////////////////////////////

// LED_PIN high = status LED lit; low = dark. Outputs are written shadow->GPIO.
void hw_led_pin_set_high(void) {
    gpio_shadow_ |= (uint8_t)(1U << LED_PIN);
    GPIO = gpio_shadow_;
}
void hw_led_pin_set_low(void) {
    gpio_shadow_ &= (uint8_t)~(1U << LED_PIN);
    GPIO = gpio_shadow_;
}


// - set a GPIO pin high or low
// - assumes pin was previously configured as output
void hw_pin_set_high(uint8_t const pin) {
    gpio_shadow_ |= (uint8_t)(1U << pin);
    GPIO = gpio_shadow_;
}
void hw_pin_set_low(uint8_t const pin) {
    gpio_shadow_ &= (uint8_t)~(1U << pin);
    GPIO = gpio_shadow_;
}
void hw_pin_mask_set_low(uint8_t const pin_mask) {
    gpio_shadow_ &= (uint8_t)~pin_mask;
    GPIO = gpio_shadow_;
}


// configure exactly the pins in output_mask as outputs (TRISIO bit = 0); all
// other pins are left as inputs (TRISIO bit = 1). The selected pins are made
// digital (ANSEL bit = 0, comparator and ADC off) and driven low (shadow and
// GPIO bit = 0). GP4 is therefore parked low with the active outputs. GP3 is
// input-only and always remains an input (its TRISIO bit reads 1).
//
// The comparator/ADC disable belongs HERE and not only in hw_mcu_init()
// because on this part "make these pins digital" genuinely requires it: with
// CM<2:0> = 000 out of reset GP0 and GP1 are comparator analog inputs, and an
// analog input reads back 0 no matter what the output driver is doing. TRISIO
// still controls direction, so a direction write DOES take effect; what it
// cannot fix is the readback, which would leave hw_output_state_intact()
// comparing a forced 0 against a set shadow bit. (The PIC10F322 has only
// ANSELA to clear.)
void hw_configure_output_pins(uint8_t const output_mask) {
    CMCON  = CMCON_COMPARATOR_OFF;                       // frees GP0/GP1, bars COUT on GP2
    ADCON0 = ADCON0_ADC_OFF;                             // ADC off
    // Do not mask ANSEL with output_mask: GPIO bit 4 maps to ANSEL bit 3.
    ANSEL &= (uint8_t)~ANSEL_OUTPUT_MASK;                // GP0..GP2/GP4 -> digital
    gpio_shadow_ &= (uint8_t)~output_mask;               // selected pins -> low (shadow)
    GPIO   = gpio_shadow_;                               // ... and on the port
    TRISIO = (uint8_t)((uint8_t)~output_mask & GPIO_IMPLEMENTED_MASK);
}


// sanity-check utility: return non-zero ("true") IFF the complete direction
// configuration still matches initialization, every pin in
// required_output_mask is still configured as an output (its TRISIO direction
// bit is still 0), the output shadow matches the expected state, AND the
// physical port still follows the shadow.
//
// Exact TRISIO protects GP0..GP2 and parked-spare GP4 as outputs, and GP3/GP5
// as inputs. The expected value is the six implemented direction bits minus
// the configured outputs (0x3F ^ 0x17 = 0x28).
//
// The shadow-vs-port comparison is STRONGER than anything the PIC10F322 can
// do. The 322 compares its LATA latch against the expected mask and stops
// there; with a shadow it becomes possible to compare intent against reality
// as well, which catches a class of fault the 322 cannot see at all: a driver,
// pin or bus fault where the port does not follow the latch.
uint8_t hw_output_state_intact(
        uint8_t const required_output_mask,
        uint8_t const expected_high_mask) {

    uint8_t expected_direction_mask =
        (uint8_t)(GPIO_IMPLEMENTED_MASK ^ BYPASS_OUTPUT_DDR_MASK); // = 0x28
    uint8_t actual_direction_mask = (uint8_t)(TRISIO & GPIO_IMPLEMENTED_MASK);
    uint8_t shadow_high_mask =
        (uint8_t)(gpio_shadow_ & (uint8_t)BYPASS_OUTPUT_DDR_MASK);
    uint8_t port_high_mask =
        (uint8_t)(GPIO & (uint8_t)BYPASS_OUTPUT_DDR_MASK);

    return
        (actual_direction_mask == expected_direction_mask) &&
        (0U == (actual_direction_mask & required_output_mask)) &&
        (shadow_high_mask == expected_high_mask) &&
        (port_high_mask   == shadow_high_mask);
}


// sanity-check utility: return non-zero ("true") IFF all the critical pin
// values are what we want
// SFR = special function register, the "control panel" of the MCU
static uint8_t hw_critical_sfrs_intact(void) {

    // OPTION_REG is checked EXACTLY, and that one comparison covers three
    // safety-relevant fields at once: the watchdog period (PSA/PS), the tick
    // clock source (T0CS/T0SE) and the global weak-pull-up enable (nGPPU).
    // On the PIC10F322 an upset to those is three independent events in three
    // registers (WDTCON, T2CON/PR2, OPTION_REG); here they are three fields in
    // ONE byte, so a single-bit upset is MORE likely to hit something
    // safety-relevant -- and one exact comparison covers all of it.
    //
    // CMCON: CM<2:0> = 000 out of reset makes GP0 and GP1 comparator analog
    // inputs, which read back 0 whatever they drive; three of the eight modes
    // additionally put COUT on GP2. All three are active outputs here, so any
    // CM<2:0> but 111 breaks the port-follows-shadow check. Only the low three
    // bits are checked: COUT (6) and CINV (4) are not meaningful with the
    // comparator disabled.  (Parked GP4 has no comparator function.)
    //
    // ADCON0.ADON: same class of hazard as CMCON -- an upset that turns the
    // ADC on takes an output pin analog.
    //
    // ANSEL: masked to ANS0..ANS3, which select GP0, GP1, GP2 and GP4. GP4 is
    // now a parked output, so ANS3 must remain clear and guarded. This cannot
    // use BYPASS_OUTPUT_DDR_MASK directly because GPIO bit 4 maps to ANSEL bit
    // 3. Bits 6:4 are ADC clock-select fields and do not matter with ADON=0.
    //
    // OSCCAL: compared against the value captured at init, not a constant --
    // it is factory trim (see osccal_snapshot_).

    uint8_t option  = (uint8_t)OPTION_REG;
    uint8_t cmcon   = (uint8_t)(CMCON & 0x07U);
    uint8_t adon    = (uint8_t)ADCON0bits.ADON;
    uint8_t ansel   = (uint8_t)(ANSEL & ANSEL_OUTPUT_MASK);
    uint8_t osccal  = (uint8_t)OSCCAL;

    return
        (OPTION_REG_CONFIG    == option) &&
        (CMCON_COMPARATOR_OFF == cmcon)  &&
        (0U                   == adon)   &&
        (0U                   == ansel)  &&
        (osccal_snapshot_     == osccal);
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


// read FOOTSW_PIN (GP5) to determine if it's high or low
//   FOOTSW_PIN high = switch open/released
//   FOOTSW_PIN low  = switch closed/pressed
// returns: PIN_STATE_HIGH or PIN_STATE_LOW
//
// Reads GPIO, which on this core returns the physical pin level -- exactly
// what is wanted for an input pin (the shadow is for OUTPUT writes only).
static pin_state_t hw_read_footswitch(void) {
    return (0U == (GPIO & (uint8_t)(1U << FOOTSW_PIN))) ?
        PIN_STATE_LOW :
        PIN_STATE_HIGH;
}


// non-zero IFF the footswitch weak pull-up is genuinely active. The PIC weak
// pull-up has a TWO-part enable: the per-pin WPU latch AND the global,
// active-low OPTION_REG.nGPPU. An SEU/EMI flip of EITHER silently disables the
// pull-up, so both are checked. (The AVR analogue checks the single PORTB latch
// bit that IS its pull-up enable; checking both here restores SEU-detection
// parity under the project's cosmic-ray/EMI threat model.)
//
// The WPU mask is 0x37, not 0x3F: this part implements WPU bits 0,1,2,4,5 and
// has NO bit 3, because GP3 has no internal weak pull-up. That absence is the
// reason the footswitch is on GP5 rather than on the input-only pin the
// PIC10F322 uses -- see bypass_pins_pic12f675.h.
//
// The two volatile SFRs are read into locals first so the && combines two plain
// (non-volatile) booleans: this keeps MISRA Rule 13.5 clean (no persistent side
// effect on the right operand of &&), which the project does not deviate.
static uint8_t hw_footswitch_pullup_intact(void) {

    // Exact pull-up configuration integrity: GP5 latch set, all other
    // implemented latches clear, and global weak pull-ups enabled. Extra
    // output-pin latches are faults because a TRISIO upset would make them
    // electrically active.

    uint8_t wpu_latches = (uint8_t)(WPU & WPU_IMPLEMENTED_MASK);
    uint8_t wpu_global  = (uint8_t)OPTION_REGbits.nGPPU; // 0 = enabled

    return
        (wpu_latches == (uint8_t)(1U << FOOTSW_PIN)) &&
        (0U == wpu_global);
}


// reset the WDT countdown ("pet the dog")
static void hw_wdt_pet(void) { CLRWDT(); }


// core MCU bring-up: all-digital port (comparator AND ADC off, not just the
// analog selects), the footswitch weak pull-up, the global weak-pull-up
// enable, the TMR0 clock source and the ~288ms watchdog period -- the last
// three all landing in the single OPTION_REG write. Finally captures the
// oscillator trim snapshot. Does NOT start the tick timer (see
// hw_tick_timer_start()).
//
// Ordering: call BEFORE hw_init_output_pins(). This is the OPPOSITE of the
// PIC10F322 shell, and for a reason specific to this part: CM<2:0> = 000 out
// of reset leaves GP0 and GP1 as comparator analog inputs, which read back 0
// regardless of what is driven. Configuring pin directions first would leave
// two of the three active outputs unreadable until CMCON is written. It is
// also the order the datasheet's own EXAMPLE 3-1 "INITIALIZING GPIO" uses:
// CMCON, then ANSEL, then TRISIO. (hw_configure_output_pins() re-asserts
// CMCON/ADCON0 for the same reason, so the ordering is belt-and-suspenders
// rather than load-bearing - but the order should still be the safe one.)
//
// There is no clock-select write here and no OSCCON on this part: the
// oscillator is a fixed 4MHz INTOSC selected by FOSC=INTRCIO in CONFIG,
// trimmed by the factory OSCCAL value that XC8's startup code loads from
// program word 0x3FF.
static void hw_mcu_init(void) {

    // entire port digital. THREE registers, where the PIC10F322 has one: the
    // comparator (CM<2:0> = 000 out of reset, holding GP0 and GP1 analog),
    // the ADC, and the analog selects.  Each is an independent
    // single-event-upset path to "the firmware still thinks it owns a digital
    // output but an analog peripheral has taken it", and each is guarded per
    // tick in hw_critical_sfrs_intact().
    CMCON  = CMCON_COMPARATOR_OFF; // CM<2:0> = 111: comparator off
    ADCON0 = ADCON0_ADC_OFF;       // ADON = 0
    ANSEL  = 0x00U;                // ANS0..ANS3 digital (also zeroes ADCS, unused)

    // Enable the footswitch (GP5) input pull-up; FOOTSW_PIN high = released,
    // low = pressed. GP3's required pull-up is external because WPU3 does not
    // exist. GP4 is an output and therefore receives no pull-up latch.
    WPU = (uint8_t)(1U << FOOTSW_PIN);

    // One write configures the global pull-up enable, the TMR0 clock source
    // and the watchdog period -- see OPTION_REG_CONFIG above.
    //
    // PSA = 1 assigns the shared prescaler to the WDT; PS = 0b100 = 1:16,
    // giving 288ms nominal (18ms x 16). DS41190G Table 12-4 parameter 31 gives
    // a 10ms unprescaled minimum, so the characterized minimum here is 160ms.
    // This is the closest analogue to the PIC10F322's ~256ms and the AVR
    // shell's 250ms. The dominant nominal pet-to-pet interval is one 1.024ms
    // tick plus the longest blocking actuation, the 12ms relay coil pulse:
    // 13.024ms plus small loop overhead, comfortably below the 160ms minimum.
    // The prescaler choice therefore retains ample margin at the fast WDT end.
    OPTION_REG = OPTION_REG_CONFIG;

    // Capture the factory oscillator trim AFTER bring-up, for the per-tick
    // comparison in hw_critical_sfrs_intact(). NOTE this snapshots whatever is
    // in OSCCAL, including garbage: it detects a LATER change, and cannot
    // detect a device programmed with word 0x3FF erased. That is a programming
    // -procedure concern, not a runtime one.
    osccal_snapshot_ = (uint8_t)OSCCAL;
}


// configure + start the 1.024ms tick on TMR0, polled (no interrupt).
//
// TMR0's clock source and (absent) prescaler were already set by the single
// OPTION_REG write in hw_mcu_init(): T0CS=0 selects the instruction clock
// (Fosc/4 = 1MHz at 4MHz INTOSC) and PSA=1 gives the shared prescaler to the
// watchdog, so TMR0 counts unprescaled and rolls over every 256 counts =
// 256us. There is no period register on this part, so the 1.024ms tick is four
// rollovers counted in software by hw_wait_for_tick().
//
// MUST run AFTER any blocking output actuation so a T0IF that set during init
// is not mistaken for the first real tick.
static void hw_tick_timer_start(void) {
    TMR0 = 0U;             // start the first sub-tick from a known count
    INTCONbits.T0IF = 0;   // start clean
}


// pause until the next 1.024ms tick, then clear the flag. The AVR sleeps here;
// the PIC polls (Model B, no sleep) -- same contract, hence the shared name.
//
// UNLIKE the PIC10F322's single TMR2IF wait, this polls T0IF four times,
// because TMR0 has no period register and rolls over every 256us. The inner
// loop does NOT disturb the max-block invariant: the blocking quantity is
// still the actuation delay, not the tick.
static void hw_wait_for_tick(void) {
    uint8_t subticks = 0U;
    while (subticks < TMR0_SUBTICKS_PER_TICK) {
        while (0U == INTCONbits.T0IF) { }
        INTCONbits.T0IF = 0;
        subticks++;
    }
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

    // pin-map sanity: the PIC pin map hard-codes GPIO bit positions as literals.
    // Pin them at compile time against the DFP's _GPIO_GPx_POSN
    // so a typo in the map or a DFP change can never silently misroute a pin
    // (parity with the AVR shell's PBx asserts).
    static_assert(FOOTSW_PIN      == _GPIO_GP5_POSN, "FOOTSW_PIN must be GP5");
    static_assert(LED_PIN         == _GPIO_GP0_POSN, "LED_PIN must be GP0");
    static_assert(CD4053_PIN      == _GPIO_GP1_POSN, "CD4053_PIN must be GP1");
    static_assert(RELAY_RESET_PIN == _GPIO_GP1_POSN, "RELAY_RESET_PIN must be GP1");
    static_assert(RELAY_SET_PIN   == _GPIO_GP2_POSN, "RELAY_SET_PIN must be GP2");
    static_assert(CD4053_CTL1     == _GPIO_GP1_POSN, "CD4053_CTL1 must be GP1");
    static_assert(CD4053_CTL2     == _GPIO_GP2_POSN, "CD4053_CTL2 must be GP2");
    static_assert(SPARE_INPUT_PIN == _GPIO_GP3_POSN,
        "SPARE_INPUT_PIN must be input-only GP3");
    static_assert(SPARE_OUTPUT_PIN == _GPIO_GP4_POSN,
        "SPARE_OUTPUT_PIN must be GP4");

    static_assert(0U == ((1U << SPARE_INPUT_PIN) & WPU_IMPLEMENTED_MASK),
        "SPARE_INPUT_PIN must use the external pull-up because GP3 has no WPU");
    static_assert(0U == ((1U << SPARE_INPUT_PIN) & BYPASS_OUTPUT_DDR_MASK),
        "SPARE_INPUT_PIN must remain an input");
    static_assert(0U != ((1U << SPARE_OUTPUT_PIN) & BYPASS_OUTPUT_DDR_MASK),
        "SPARE_OUTPUT_PIN must be a guarded low-driven output");

    // The footswitch pin must be one the silicon can weakly pull up. GP3 has no
    // WPU bit on this part, which is exactly why the map differs from the
    // PIC10F322's; assert it rather than trusting the comment.
    static_assert(0U != ((1U << FOOTSW_PIN) & WPU_IMPLEMENTED_MASK),
        "FOOTSW_PIN must have an implemented weak pull-up (GP3 does not)");

    // The footswitch must not collide with the output pins.
    static_assert(0U == ((1U << FOOTSW_PIN) & BYPASS_OUTPUT_DDR_MASK),
        "FOOTSW_PIN must not be one of the output pins");

    // _XTAL_FREQ (a build flag, used by the drivers' __delay_ms) must match the
    // fixed 4MHz INTOSC, or the coil/mute pulse widths would be wrong. Unlike
    // the PIC10F322 there is nothing to select at runtime: FOSC=INTRCIO in
    // CONFIG is the whole story.
    static_assert(_XTAL_FREQ == 4000000UL, "_XTAL_FREQ must be 4 MHz (fixed INTOSC)");


    // Pet the WDT first thing, mirroring the AVR shell's "re-arm first". Unlike
    // the AVR -- whose WDTCR collapses to the ~16ms minimum after a WDRF,
    // creating a short post-reset reset-loop hazard -- the PIC has no such
    // window: WDTE=ON runs the WDT from reset with OPTION_REG at its POR
    // default of 0xFF, i.e. PSA=1 and PS=0b111 = 1:128 = ~2.3s, which dwarfs
    // init() + the <=12ms bypass pulse. hw_mcu_init() narrows the period to
    // ~288ms afterward. This early pet is therefore belt-and-suspenders, not
    // required -- it documents why no early arming is needed and costs one
    // instruction.
    hw_wdt_pet(); // i.e., CLRWDT()


    // clock-independent bring-up FIRST on this part: GP0 and GP1 come out of
    // reset as comparator analog inputs, so the analog peripherals must be
    // turned off before a driven pin reads back what was written. (The
    // PIC10F322 shell orders these the other way; see hw_mcu_init().)
    hw_mcu_init();

    // driver: set pin directions (TRISIO/ANSEL/shadow+GPIO for the active variant)
    hw_init_output_pins();

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

    // LAST: start + clear the tick, immediately before the loop, so no rollover
    // accumulated during init is mistaken for the first real tick.
    hw_tick_timer_start();
}


// program entry point. Model B: a single polled 1.024ms loop. Each tick we
// sample + integrate the footswitch and advance the debounce state machine;
// CLRWDT at the end of every iteration is the main-loop liveness proof.
void main(void) {

    init(); // note: initializes ctx_ via debounce_init_context()

    for (;;) {

        // pause until the next 1.024ms TMR0 tick (polled; no sleep on Model B)
        hw_wait_for_tick();
        hw_outputs_reassert_safe();
        debounce_context_t next_ctx = ctx_;

        // basic sanity checks against outlier events (cosmic rays, extreme EMI);
        // always checked, regardless of state; force a WDT reset on any
        // violation. (No timer_isr_called_ guard as on AVR -- the PIC has no
        // ISR; main-loop liveness is proven by reaching hw_wdt_pet() below.)
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
