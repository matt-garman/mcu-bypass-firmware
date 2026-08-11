// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// PIC12F675 fault-injection matrix for the shared harness core
// (test/pic/test_fault_pic_core.h).
//
// WHY THIS IS SEPARATE FROM pic12f675_regs.h
//   Same split as the 10F32x pair beside it: that file is pure device identity
//   -- what the silicon has and where -- while this one is GUARD POLICY. Which
//   of those locations the firmware's per-tick sanity gate promises to notice,
//   what corrupt value models a single-event upset there, and why that value
//   provokes the gate rather than some other reset path. The two answer
//   different questions and change for different reasons.
//
// WHY IT IS PER-PART RATHER THAN PER-FAMILY
//   The 10F32x matrix is per-family because two parts share it. This tree
//   builds one classic mid-range part, so the file is named for the scope it
//   actually serves. If a second classic part arrives and guards the same
//   locations with the same values, the rename is the cheap half of that work.
//
// WHAT THIS PART GUARDS THAT THE PIC10F32x DOES NOT
//   1. THE PORT MUST FOLLOW THE SHADOW. There is no LATx here, so the shell
//      keeps its output latch in SRAM and writes shadow -> GPIO. The gate can
//      therefore compare intent against reality, which the 322 cannot do at
//      all: its LATA-vs-PORTA comparison is two views of one latch. The
//      injections that exercise it are the adapter's, beside the shadow ones,
//      because output-latch policy is the core's per-PART hook.
//   2. PARKED GP4 IS GUARDED IN FOUR INDEPENDENT WAYS. It must remain an output,
//      its shadow and physical pin must remain low, and ANSEL.ANS3 must remain
//      clear. GP3 is the externally pulled-up input-only spare; gpsim cannot
//      model its board resistor, and silicon fixes its direction bit at one.
//   3. ONE BYTE CARRIES THREE SAFETY FIELDS. OPTION_REG holds the watchdog
//      period, the tick clock source and the global pull-up enable, where the
//      322 spreads them across WDTCON, T2CON/PR2 and OPTION. One exact
//      comparison covers all of it -- and a single-bit upset anywhere in that
//      byte is correspondingly more likely to matter.
//   4. THE OSCILLATOR TRIM IS A SNAPSHOT, NOT A CONSTANT. OSCCAL is factory
//      trim loaded from the last program word, so the firmware captures it at
//      init and re-checks that it has not CHANGED. Structurally this part's
//      OSCCON.IRCF, with a captured value where the 322 has a literal.
//
// CORRUPTION VALUES are chosen so the main loop keeps running and the GATE is
// the sole reset path -- the same discipline as the 10F32x matrix, and on this
// part it is what excludes two of OPTION_REG's own bits (below). The ANSEL,
// CMCON and ADCON0 cases are gate-only: they re-analogize or hand away pins the
// firmware drives, which nothing else in the loop reads. The pull-up cases are
// gate-only too, because the footswitch is externally driven by the harness, so
// disabling its pull-up does not move the pin.
//
// LOCATIONS DELIBERATELY NOT INJECTED, all of them inside registers this matrix
// does otherwise corrupt:
//
//   OPTION_REG.T0CS and OPTION_REG.PSA -- the tick, not the gate, would explain
//     the reset. hw_wait_for_tick() spins on T0IF with no bound. T0CS = 1
//     clocks TMR0 from T0CKI, which is GP2, a firmware-driven output with no
//     edges on it: the tick never arrives again. PSA = 0 moves the prescaler
//     off the watchdog and onto TMR0, stretching the tick to ~32.8 ms while
//     shortening the WDT to its ~18 ms base. Either way the loop starves and
//     the watchdog fires WITHOUT the gate ever running. That is not a distinct
//     verdict -- a probe of T0CS on all three variants reports exactly one
//     reset, the same count a guarded location produces -- so a case here would
//     read as evidence for a guard that never executed. The exact OPTION_REG
//     comparison does cover both bits; INTEDG, T0SE and PS below are the bits
//     that let the gate prove it.
//
//   TRISIO<3> -- the guard covers it and the silicon cannot violate it. GP3 is
//     input-only and its direction bit always reads 1 (datasheet: TRISIO3
//     always reads as 1). gpsim accepts a write there and reads back the
//     cleared bit, so an injection would "pass" on the strength of a simulator
//     divergence from the part. Excluded rather than asserted.
//
//   WPU<3> -- not implemented on this part at all, which is the whole reason
//     the footswitch sits on GP5 (see bypass_pins_pic12f675.h). A write reads
//     back as zero, so the core's own did-the-injection-stick check would fail
//     it. The absence is asserted where it belongs: PIC_REG_WPU_MASK, and the
//     startup-WPU check that compares against it.
//
// Each macro is a statement expression usable exactly once in main(), in the
// order the core calls them. Adding a case here changes the check count, so the
// adapter's PIC_FAULT_EXPECTED_CHECKS must move with it -- that coupling is
// deliberate and is what stops a case from silently disappearing.

#ifndef TEST_PIC_PIC12F675_FAULT_MATRIX_H
#define TEST_PIC_PIC12F675_FAULT_MATRIX_H

#include "pic/pic12f675_regs.h"

// ---- Fault-injection-only SFRs (guard policy, so not in the register map) ----
// Addresses read out of gpsim on a loaded p12f675, exactly as the register map
// beside this file was derived; the core cross-checks each one against the
// register's gpsim name at runtime.
#define PIC_REG_CMCON_ADDR   0x019u  // CM<2:0> = bits 2:0; 111 = comparator off
#define PIC_REG_ADCON0_ADDR  0x01Fu  // ADON = bit 0
#define PIC_REG_OSCCAL_ADDR  0x090u  // factory trim, snapshotted at init
// OSCCAL implements CAL5:CAL0 in bits 7:2; bits 1:0 are unimplemented and read
// zero on silicon. Toggle CAL0 for the smallest physically realizable trim upset.
#define PIC_FAULT_OSCCAL_CAL0_MASK 0x04u

// ---- Output directions (hw_output_state_intact, via hw_is_sanity_check_failed)
// The gate compares TRISIO exactly against 0x28, so this covers both directions
// of upset: GP0..GP2 or parked GP4 stopping being outputs, and footswitch GP5
// starting to drive. All five implemented flippable bits are injected; GP3 is
// the excluded sixth, for the reason in the header comment.
#define PIC_FAULT_DIRECTION_INJECTIONS() do { \
    inject_case("TRISIO.GP0", PIC_REG_TRIS_ADDR, PIC_REG_TRIS_TOKEN, false, 0x01, 1, \
                "GP0 changed from output to input"); \
    inject_case("TRISIO.GP1", PIC_REG_TRIS_ADDR, PIC_REG_TRIS_TOKEN, false, 0x02, 1, \
                "GP1 changed from output to input"); \
    inject_case("TRISIO.GP2", PIC_REG_TRIS_ADDR, PIC_REG_TRIS_TOKEN, false, 0x04, 1, \
                "GP2 changed from output to input"); \
    inject_case("TRISIO.GP4", PIC_REG_TRIS_ADDR, PIC_REG_TRIS_TOKEN, false, 0x10, 1, \
                "GP4 parked output changed to input: exact-TRISIO violation"); \
    inject_case("TRISIO.GP5", PIC_REG_TRIS_ADDR, PIC_REG_TRIS_TOKEN, false, 0x20, 1, \
                "GP5 footswitch input started driving against the switch"); \
} while (0)

// ---- Clock / tick / analog config SFRs (hw_critical_sfrs_intact) ------------
// The three OPTION_REG bits are the ones an upset can move while leaving the
// tick and the watchdog able to do their jobs: INTEDG and T0SE are otherwise
// entirely silent on this design (INT is unused, and T0SE is meaningless with
// T0CS = 0), so absent the exact comparison there would provably be NO reset;
// PS lengthens the watchdog rather than shortening it, which keeps the
// injection clear of the starvation confound at the other end.
//
// The ANSEL cases cover all four analog-capable outputs. ANS3 maps to GPIO GP4,
// not GPIO bit 3; keeping it explicit pins the non-isomorphic register mapping.
#define PIC_FAULT_CONFIG_INJECTIONS() do { \
    inject_case("OPTION.INTEDG", PIC_REG_OPTION_ADDR, PIC_REG_OPTION_TOKEN, false, 0x40, 1, \
                "INTEDG 0->1: INT edge select skewed (else silent, INT unused)"); \
    inject_case("OPTION.T0SE",   PIC_REG_OPTION_ADDR, PIC_REG_OPTION_TOKEN, false, 0x10, 1, \
                "T0SE 0->1: TMR0 edge select skewed (else silent, T0CS=0)"); \
    inject_case("OPTION.PS",     PIC_REG_OPTION_ADDR, PIC_REG_OPTION_TOKEN, false, 0x01, 1, \
                "PS 0b100->0b101: WDT 1:16->1:32 (~288ms->~576ms), tick preserved"); \
    inject_case("CMCON.CM0",     PIC_REG_CMCON_ADDR,  "cmcon",  false, 0x01, 1, \
                "CM<2:0> 111->110: comparator back on, owning GP0..GP2"); \
    inject_case("ADCON0.ADON",   PIC_REG_ADCON0_ADDR, "adcon0", false, 0x01, 1, \
                "ADON 0->1: ADC on, an output pin taken analog"); \
    inject_case("ANSEL.ANS0",    PIC_REG_ANSEL_ADDR, PIC_REG_ANSEL_TOKEN, false, 0x01, 1, \
                "ANS0=1: GP0 (LED) re-selected analog, out of digital service"); \
    inject_case("ANSEL.ANS1",    PIC_REG_ANSEL_ADDR, PIC_REG_ANSEL_TOKEN, false, 0x02, 1, \
                "ANS1=1: GP1 (control pin) re-selected analog, out of digital service"); \
    inject_case("ANSEL.ANS2",    PIC_REG_ANSEL_ADDR, PIC_REG_ANSEL_TOKEN, false, 0x04, 1, \
                "ANS2=1: GP2 (control pin) re-selected analog, out of digital service"); \
    inject_case("ANSEL.ANS3",    PIC_REG_ANSEL_ADDR, PIC_REG_ANSEL_TOKEN, false, 0x08, 1, \
                "ANS3=1: parked GP4 re-selected analog, out of digital service"); \
    inject_case("OSCCAL.CAL0",   PIC_REG_OSCCAL_ADDR, "osccal", false, \
                PIC_FAULT_OSCCAL_CAL0_MASK, 1, \
                "toggle implemented CAL0: one physically realizable trim step"); \
} while (0)

// ---- Weak pull-ups (hw_footswitch_pullup_intact) ----------------------------
// The footswitch is externally driven by the harness, so the pin stays
// released and only the gate's check reacts. Every implemented WPU bit is
// covered: the footswitch latch that must stay set, and all four that must stay
// clear -- an output-pin pull-up would become electrically active the moment a
// direction upset made that pin an input.
#define PIC_FAULT_PULLUP_INJECTIONS() do { \
    inject_case("WPU.GP5",      PIC_REG_WPU_ADDR, PIC_REG_WPU_TOKEN, false, 0x20, 1, \
                "clear GP5 pull-up latch: footswitch weak pull-up disabled"); \
    inject_case("WPU.GP0",      PIC_REG_WPU_ADDR, PIC_REG_WPU_TOKEN, false, 0x01, 1, \
                "set GP0 output-pin pull-up latch: exact GP5-only mask violated"); \
    inject_case("WPU.GP1",      PIC_REG_WPU_ADDR, PIC_REG_WPU_TOKEN, false, 0x02, 1, \
                "set GP1 output-pin pull-up latch: exact GP5-only mask violated"); \
    inject_case("WPU.GP2",      PIC_REG_WPU_ADDR, PIC_REG_WPU_TOKEN, false, 0x04, 1, \
                "set GP2 output-pin pull-up latch: exact GP5-only mask violated"); \
    inject_case("WPU.GP4",      PIC_REG_WPU_ADDR, PIC_REG_WPU_TOKEN, false, 0x10, 1, \
                "set parked-output GP4 pull-up latch: exact GP5-only mask violated"); \
    inject_case("OPTION.nGPPU", PIC_REG_OPTION_ADDR, PIC_REG_OPTION_TOKEN, false, 0x80, 1, \
                "set nGPPU: global weak pull-ups disabled"); \
} while (0)

#endif // TEST_PIC_PIC12F675_FAULT_MATRIX_H
