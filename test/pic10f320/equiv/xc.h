// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// Mock <xc.h> for the firmware<->model equivalence test (make test-equiv).
//
// This lets the REAL firmware (bypass_mcu_pic10f320.c) be compiled and run on
// the host: it replaces the XC8/DFP device header with plain host storage for
// the handful of SFRs the firmware touches, and turns CLRWDT() into a per-tick
// harness hook. fw_harness.c includes this, defines the storage + hook, then
// #includes the firmware; test_equiv.c drives it and compares the firmware's
// output trace tick-for-tick against the vendored reference model.
//
// Only the SFR fields the firmware actually uses are modelled (see the grep in
// the project history); anything else is intentionally absent so an unexpected
// new register access fails to compile rather than being silently ignored.

#ifndef BYPASS_EQUIV_XC_MOCK_H
#define BYPASS_EQUIV_XC_MOCK_H

#include <stdint.h>

// --- whole-byte SFRs --------------------------------------------------------
// LATA remains an assignable lvalue, but every access passes through the
// harness. This lets the actuation test observe the result of every firmware
// LATA write, including instruction-scale startup transitions between the
// existing delay and end-of-tick snapshots.
uint8_t *bypass_lata_access(void);
#define LATA (*bypass_lata_access())
extern uint8_t PORTA;   // input port    (RA3=footswitch)
extern uint8_t TRISA;   // data direction (0=output)
extern uint8_t ANSELA;  // analog select  (0=digital)
extern uint8_t WPUA;    // weak pull-up enables
extern uint8_t PR2;     // TMR2 period
extern uint8_t T2CON;   // TMR2 control

// --- bitfield SFRs (only the fields the firmware references) -----------------
typedef struct { unsigned nWPUEN : 1; } OPTION_REGbits_t; // 0 = pull-ups enabled
typedef struct { unsigned IRCF   : 3; } OSCCONbits_t;     // osc freq select
typedef struct { unsigned WDTPS  : 5; } WDTCONbits_t;     // WDT prescale
typedef struct { unsigned GIE    : 1; } INTCONbits_t;     // global interrupt enable
extern OPTION_REGbits_t OPTION_REGbits;
extern OSCCONbits_t     OSCCONbits;
extern WDTCONbits_t     WDTCONbits;
extern INTCONbits_t     INTCONbits;

// --- TMR2 1ms tick flag -----------------------------------------------------
// In the host harness the tick is ALWAYS ready: one main-loop iteration == one
// simulated tick. bypass_pir1() forces TMR2IF=1 on every access, so the
// firmware's `while (0U == PIR1bits.TMR2IF) {}` poll falls through every
// iteration and init()'s `PIR1bits.TMR2IF = 0` cannot stall the first poll.
typedef struct { unsigned TMR2IF : 1; } PIR1bits_t;
PIR1bits_t *bypass_pir1(void);
#define PIR1bits (*bypass_pir1())

// --- CLRWDT(): per-iteration harness hook (defined in fw_harness.c) ----------
void bypass_equiv_on_clrwdt(void);
#define CLRWDT() bypass_equiv_on_clrwdt()

// --- __delay_ms(): per-actuation hook (defined by the harness) ----------------
// The cd4053-mute and tq2-relay output drivers call __delay_ms() exactly once per
// actuation, BETWEEN asserting the mute / energising the relay coil and releasing
// it again -- so it is the one seam at which the firmware's transient (mid-pulse)
// output state is observable on the host. Routing it through a hook lets a harness
// snapshot LATA there: the equiv/fault harnesses make it a no-op (they only watch
// RA0 / the sanity gate), while test/actuation captures the snapshot to verify the
// variant's mute/coil pin pattern. cd4053-simple never calls __delay_ms.
void bypass_on_delay_ms(unsigned ms);
#define __delay_ms(x) bypass_on_delay_ms((unsigned)(x))

// --- PORTA pin-position macros (PIC10F320) -----------------------------------
#define _PORTA_RA0_POSN 0
#define _PORTA_RA1_POSN 1
#define _PORTA_RA2_POSN 2
#define _PORTA_RA3_POSN 3

#endif // BYPASS_EQUIV_XC_MOCK_H
