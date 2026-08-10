// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// PIC10F32x fault-injection matrix for the shared harness core
// (test/pic/test_fault_pic_core.h).
//
// WHY THIS IS SEPARATE FROM pic10f32x_regs.h
//   That file is pure device identity -- what the silicon has and where. This
//   file is the GUARD POLICY: which of those locations the firmware's per-tick
//   sanity gate promises to notice, what corrupt value models a single-event
//   upset there, and why that value provokes the gate rather than some other
//   reset path. The two answer different questions and change for different
//   reasons, so a part that shares one need not share the other.
//
// WHY IT IS PER-FAMILY RATHER THAN PER-PART
//   PIC10F320 and PIC10F322 guard the same registers with the same values. They
//   differ only in the OUTPUT-LATCH policy, which is why that one stayed an
//   adapter macro (PIC_FAULT_EXTRA_OUTPUT_INJECTIONS): the 322 guards its
//   settled latch and expects a reset, while the 320 omits that guard for flash
//   budget and its relay variant instead requires idle correction without one.
//
// CORRUPTION VALUES are chosen so the main loop keeps running and the GATE is
// the sole reset path. OSCCON.IRCF and WDTCON.WDTPS are the cleanest: no other
// firmware logic reads them and the loop keeps petting, so absent the gate
// there is provably NO reset -- a WDTPS skew is otherwise entirely silent.
// PR2/T2CON are also read by the TMR2 hardware, so their corruption is kept
// tick-preserving (T2CON keeps TMR2ON set; PR2 stays a valid period) so the
// reset is the gate, not a wedged tick. ANSELA and the pull-up SFRs are
// gate-only too: the footswitch is externally driven, so re-selecting an output
// pin analog / disabling the pull-up does not change the footswitch pin -- only
// the gate's check reacts.
//
// Each macro is a statement expression usable exactly once in main(), in the
// order the core calls them. Adding a case here changes the check count, so the
// adapter's PIC_FAULT_EXPECTED_CHECKS must move with it -- that coupling is
// deliberate and is what stops a case from silently disappearing.

#ifndef TEST_PIC_PIC10F32X_FAULT_MATRIX_H
#define TEST_PIC_PIC10F32X_FAULT_MATRIX_H

#include "pic/pic10f32x_regs.h"

// ---- Family-only config SFRs (no counterpart on a classic mid-range part) ----
#define PIC_REG_OSCCON_ADDR  0x010u  // IRCF = bits 6:4 (mask 0x70)
#define PIC_REG_PR2_ADDR     0x012u
#define PIC_REG_T2CON_ADDR   0x013u
#define PIC_REG_WDTCON_ADDR  0x030u  // WDTPS = bits 5:1 (mask 0x3E)

// ---- Output directions (hw_is_sanity_check_failed) --------------------------
// The gate compares TRISA exactly against its init() value, so all three output
// directions are guarded on every variant -- including cd4053_simple's spare
// RA2, which used to be a negative control here.
#define PIC_FAULT_DIRECTION_INJECTIONS() do { \
    inject_case("TRISA.RA0", PIC_REG_TRIS_ADDR, PIC_REG_TRIS_TOKEN, false, 0x01, 1, \
                "RA0 changed from output to input"); \
    inject_case("TRISA.RA1", PIC_REG_TRIS_ADDR, PIC_REG_TRIS_TOKEN, false, 0x02, 1, \
                "RA1 changed from output to input"); \
    inject_case("TRISA.RA2", PIC_REG_TRIS_ADDR, PIC_REG_TRIS_TOKEN, false, 0x04, 1, \
                "RA2 changed from output to input"); \
} while (0)

// ---- Clock / tick / analog config SFRs (hw_critical_sfrs_intact) ------------
// The ANSELA gate masks the fixed RA0|RA1|RA2 (BYPASS_OUTPUT_DDR_MASK) on every
// variant, so re-selecting ANY output pin analog must recover via one reset --
// not just RA0 (a narrowed mask that only checked RA0 would slip RA1/RA2 past).
#define PIC_FAULT_CONFIG_INJECTIONS() do { \
    inject_case("OSCCON.IRCF",  PIC_REG_OSCCON_ADDR, "osccon", false, 0x10, 1, \
                "IRCF 0b100->0b101: 2MHz->4MHz clock skew"); \
    inject_case("WDTCON.WDTPS", PIC_REG_WDTCON_ADDR, "wdtcon", false, 0x10, 1, \
                "WDTPS 0b01000->0b00000: 1:8192->1:32, WDT miscalibrated (else silent)"); \
    inject_case("PR2",          PIC_REG_PR2_ADDR,    "pr2",    true,  99, 1, \
                "tick period 124->99: 1ms tick skewed"); \
    inject_case("T2CON",        PIC_REG_T2CON_ADDR,  "t2con",  false, 0x01, 1, \
                "T2CKPS 1:4->1:1, TMR2ON preserved: timer cfg skew"); \
    inject_case("ANSELA.RA0",   PIC_REG_ANSEL_ADDR, PIC_REG_ANSEL_TOKEN, false, 0x01, 1, \
                "ANSA0=1: RA0 (LED) re-selected analog, out of digital service"); \
    inject_case("ANSELA.RA1",   PIC_REG_ANSEL_ADDR, PIC_REG_ANSEL_TOKEN, false, 0x02, 1, \
                "ANSA1=1: RA1 (control pin) re-selected analog, out of digital service"); \
    inject_case("ANSELA.RA2",   PIC_REG_ANSEL_ADDR, PIC_REG_ANSEL_TOKEN, false, 0x04, 1, \
                "ANSA2=1: RA2 (control pin) re-selected analog, out of digital service"); \
} while (0)

// ---- Weak pull-ups (hw_footswitch_pullup_intact) ----------------------------
// The footswitch is externally driven here, so the pin stays released; only the
// gate's check reacts.
#define PIC_FAULT_PULLUP_INJECTIONS() do { \
    inject_case("WPUA.RA3",     PIC_REG_WPU_ADDR, PIC_REG_WPU_TOKEN, false, 0x08, 1, \
                "clear RA3 pull-up latch: footswitch weak pull-up disabled"); \
    inject_case("WPUA.RA0",     PIC_REG_WPU_ADDR, PIC_REG_WPU_TOKEN, false, 0x01, 1, \
                "set RA0 output-pin pull-up latch: exact RA3-only mask violated"); \
    inject_case("WPUA.RA1",     PIC_REG_WPU_ADDR, PIC_REG_WPU_TOKEN, false, 0x02, 1, \
                "set RA1 output-pin pull-up latch: exact RA3-only mask violated"); \
    inject_case("WPUA.RA2",     PIC_REG_WPU_ADDR, PIC_REG_WPU_TOKEN, false, 0x04, 1, \
                "set RA2 output-pin pull-up latch: exact RA3-only mask violated"); \
    inject_case("OPTION.nWPUEN", PIC_REG_OPTION_ADDR, PIC_REG_OPTION_TOKEN, false, 0x80, 1, \
                "set nWPUEN: global weak pull-ups disabled"); \
} while (0)

#endif // TEST_PIC_PIC10F32X_FAULT_MATRIX_H
