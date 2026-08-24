// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

#ifndef BYPASS_PINS_PIC12F675_H__
#define BYPASS_PINS_PIC12F675_H__


#include <stdint.h>


// PIC12F675 pin map: GPIO/TRISIO bit positions.  The PIC12F675 has 6 I/O:
//     - GP0, GP1, GP2, GP4, GP5 bidirectional
//     - GP3 INPUT-ONLY (it shares MCLR/VPP; with MCLRE=OFF it is a plain
//       digital input)
//
// UNLIKE the PIC10F322, the footswitch does NOT go on the input-only pin. The
// 322's map rests on a coincidence: RA3 is input-only AND pull-up capable.
// The pic12f675 does not have this: the WPU register implements bits
// 0,1,2,4,5 only, so GP3 has NO internal weak pull-up. Putting the footswitch
// there would make an external pull-up mandatory and would delete
// hw_footswitch_pullup_intact() from this target.
//
// The footswitch therefore goes on GP5, the one bidirectional pin carrying no
// analog function: ANSEL implements ANS0..ANS3 = GP0, GP1, GP2, GP4, and the
// comparator's CIN+/CIN-/COUT are GP0/GP1/GP2. GP5 needs no ANSEL handling and
// cannot be silently re-analogized by an upset in either ANSEL or CMCON. Its
// alternate functions are OSC1/CLKIN (released as I/O by FOSC=INTRCIO) and
// T1CKI (unconsumed - the tick is TMR0 off Fosc/4).
//
// see also PIC10F322 counterpart bypass_pins_pic10f322.h
//
// Selected by bypass_output_common.h on the BYPASS_MCU_PIC12F675 build macro.
// Bit positions are pinned to the device header's _GPIO_GPx_POSN by
// compile-time asserts in bypass_mcu_pic12f675.c.
//
// footswitch and status LED pins are common across all output variants
#define FOOTSW_PIN      (5U) // GP5 (bidirectional, used as input) + weak pull-up
#define LED_PIN         (0U) // GP0

// Board-level electrical policies. The first two are the pins this design
// does not use; the third is a requirement the runtime integrity check
// places on an ACTIVE output:
//   - GP3 is input-only and has no internal weak pull-up; the PCB must
//     provide an external pull-up compatible with ICSP/VPP programming
//   - GP4 is an unused output parked low; the board must leave it
//     unconnected or connect it only to a load that is safe while driven
//     low
//   - GP2 must READ BACK high wherever it is held high. Having no LATx,
//     this shell keeps an SRAM shadow and hw_output_state_intact()
//     re-reads GPIO against it every tick, so the output pins' INPUT
//     thresholds become a board requirement; and per DS41190G Table 1-1
//     GP2 is the ONLY output here whose input buffer is a Schmitt Trigger
//     (VIH min 0.8*VDD, D041); GP0, GP1 and GP4 are TTL (VIH min 2.0V,
//     D040). Against that, VOH is characterized at one point only:
//     VDD-0.7V at IOH = -3.0mA (D090). A GP2 driving its load correctly
//     but reading back between 2.0V and 0.8*VDD fails the guard, and the
//     shell then resets every iteration (permanently, since the
//     condition is static). This binds cd4053_with_mute, which holds GP2
//     high in ENGAGED; cd4053_simple parks GP2 low, and the relay variant
//     raises it only inside the blocking coil pulse, which no check
//     straddles. Both board options clear it by a wide margin (a MOSFET
//     gate or a CMOS control input, plus the 100k fail-safe pulldown,
//     ~50uA at 5V), but the margin is a BOARD property and no lane here
//     can measure it: gpsim models pins ideally. See
//     docs/pic12f675_feasibility.md section 4.2 and section 8 item 9.
#define SPARE_INPUT_PIN  (3U) // GP3: externally pulled up, remains an input
#define SPARE_OUTPUT_PIN (4U) // GP4: guarded output, always driven low

// CD4053 simple
#define CD4053_PIN      (1U) // GP1

// CD4053 with muting
#define CD4053_CTL1     (1U) // GP1
#define CD4053_CTL2     (2U) // GP2

// dual-latching mechanical relay bypass (e.g. Panasonic TQ2-2L)
#define RELAY_RESET_PIN (1U)  // GP1
#define RELAY_SET_PIN   (2U)  // GP2


// Bits that must be OUTPUTS (GP0|GP1|GP2|GP4). Same macro NAME as the AVR and
// PIC10F322 maps (the shared drivers consume it); the value is the output-bit
// set, interpreted by the per-MCU hw_configure_output_pins() (PIC: TRISIO bit
// 0 = output). ("DDR" is legacy AVR wording, kept for a single cross-MCU macro
// name.)
//
// All three variants use GP0..GP2 for their active outputs:
//    tq2_l2_5v_relay = LED(GP0)/RESET(GP1)/SET(GP2)
//    cd4053_with_mute = LED(GP0)/CTL1(GP1)/CTL2(GP2)
//    cd4053_simple = LED(GP0)/CD4053(GP1),
// leaving GP2 a spare driven low.
//
// GP4 is also a spare driven low, matching the project's existing unused-pin
// policy. It is included in the exact-direction, shadow, physical-port and
// analog-selection guards. GP3 and GP5 are the only inputs.
#define BYPASS_OUTPUT_DDR_MASK (0x17U)  // GP0|GP1|GP2|GP4


// Watchdog pet-to-pet budget, consumed by the shared output drivers through
// WDT_PET_TO_PET_MAX_MS() (bypass_output_common.h): the worst-case WALL-CLOCK
// interval between two watchdog pets must stay under the WORST-CASE WDT period
// (de-rated minima, never nominal). Asserted in bypass_output_*.c. See
// "Watchdog pet-to-pet budget" in DESIGN_DOCUMENTATION.adoc for the derivation
// and the measured corroboration of each term below.
#define TICK_PERIOD_MS    (2U)    // 1.024 ms TMR0 tick, ceil to a conservative int
#define WDT_MIN_PERIOD_MS (160U)  // WDTPS=0x0C (1:16) 288 ms nom; DS41190G T12-4 p31 -> 160 ms floor

// Bounded non-blocking work in the pet-to-pet window, as on the PIC10F322. One
// whole tick is the allowance, and this map's tick is already the conservative
// 2 ms ceiling of a 1.024 ms tick.
#define WDT_LOOP_WORK_MS  (2U)

// No ISR preemption term: single polled loop, GIE clear, no interrupt service
// routine. See the PIC10F322 map.
#define WDT_ISR_STRETCH_PCT (0U)



#endif // BYPASS_PINS_PIC12F675_H__
