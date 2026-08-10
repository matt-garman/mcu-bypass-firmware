// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// PIC10F32x device identity for the shared libgpsim harness cores
// (test_io_pic_core.h, test_fault_pic_core.h, test_lockstep_pic_core.h).
//
// WHY THIS FILE EXISTS
//   The cores used to hard-code 10F32x register addresses, register NAMES and
//   expected init values as core constants. That was invisible while every
//   consumer was a 10F32x, and wrong the moment a second family arrived: a
//   classic mid-range part (PIC12F675) has a different port register bank, no
//   LATx at all, and no TMR2/OSCCON/WDTCON. Worse, the failure MESSAGES are
//   register-named ("TRISA did not remain exact...", "physical PORTA output
//   bits did not follow LATA"), so a core that merely took different numbers
//   would still report another part's register names.
//
//   So device identity -- addresses, gpsim name tokens, printable names,
//   implemented-bit masks and expected init values -- lives here, per family,
//   and the cores carry only mechanism. A part adapter includes the header for
//   its family before including a core.
//
// THE gpsim NAME TOKENS are cross-checked at runtime by fetch_sfr(): injecting
// the wrong register must never count as evidence that the named guard works.
// A token must be lowercase and must be a SUBSTRING of the gpsim register name.
//
// Family members: PIC10F320 and PIC10F322. Their register maps are identical;
// they differ in flash size and in which guards the firmware implements, both
// of which are adapter facts, not family facts.
//
// A second family supplies its own map with the same macro names; see
// docs/pic12f675_feasibility.md section 2.1 for a classic mid-range map beside
// this one.

#ifndef TEST_PIC_PIC10F32X_REGS_H
#define TEST_PIC_PIC10F32X_REGS_H

// ---- Port / direction / latch / analog-select -------------------------------
#define PIC_REG_PORT_ADDR    0x005u   // PORTA: physical pin levels
#define PIC_REG_PORT_NAME    "PORTA"
#define PIC_REG_PORT_TOKEN   "porta"
#define PIC_REG_PORT_LC      "porta"   // lowercase, for compact diagnostics

#define PIC_REG_TRIS_ADDR    0x006u   // TRISA: 1 = input, 0 = output
#define PIC_REG_TRIS_NAME    "TRISA"
#define PIC_REG_TRIS_TOKEN   "tris"

#define PIC_REG_LATCH_ADDR   0x007u   // LATA: output latch (a real SFR on this family)
#define PIC_REG_LATCH_NAME   "LATA"
#define PIC_REG_LATCH_TOKEN  "lata"
// Lowercase printable name. Kept SEPARATE from the token because a part whose
// output latch is a RAM shadow rather than an SFR has no gpsim name to match,
// so its token is nullptr while it still needs a name to print.
#define PIC_REG_LATCH_LC     "lata"

#define PIC_REG_ANSEL_ADDR   0x008u   // ANSELA: ANSA0..ANSA2 = RA0..RA2 analog select
#define PIC_REG_ANSEL_NAME   "ANSELA"
#define PIC_REG_ANSEL_TOKEN  "ansel"

// ---- Weak pull-ups ----------------------------------------------------------
#define PIC_REG_WPU_ADDR     0x009u   // WPUA: per-pin weak-pull-up latch
#define PIC_REG_WPU_NAME     "WPUA"
#define PIC_REG_WPU_TOKEN    "wpu"

#define PIC_REG_OPTION_ADDR  0x00Eu   // OPTION_REG; nWPUEN (global pull-up enable) = bit 7
#define PIC_REG_OPTION_NAME  "OPTION_REG"
#define PIC_REG_OPTION_TOKEN "option"

// ---- Masks and expected init values -----------------------------------------
// Implemented I/O bits. Four on this family (RA0..RA3); a six-I/O part widens
// every masked comparison, which is why this is not spelled 0x0F in the cores.
#define PIC_REG_PORT_MASK    0x0Fu
// Pins the firmware drives as outputs (BYPASS_OUTPUT_DDR_MASK): RA0|RA1|RA2.
#define PIC_REG_OUTPUT_MASK  0x07u
// The footswitch pin: RA3, the input-only pin on this family.
#define PIC_REG_FOOTSW_MASK  0x08u
// The two relay coil bits (RELAY_RESET_PIN | RELAY_SET_PIN) = RA1|RA2.
#define PIC_REG_COIL_MASK    0x06u

// Exact steady-state TRISA after init(): RA3 input, RA0..RA2 outputs.
#define PIC_REG_TRIS_INIT      0x08u
#define PIC_REG_TRIS_INIT_STR  "0x08"
// Pin-role phrasing for the two differently-worded assertions that print it.
#define PIC_REG_TRIS_LAYOUT    "RA3-input/RA0..RA2-output"
#define PIC_REG_TRIS_DESC      "RA3 input, RA0..RA2 outputs (0x08)"

// Implemented WPU bits, and the exact latch init(): RA3 only. (Every bit 0..3
// exists on this family -- a part whose input-only pin has no pull-up bit
// narrows this mask.)
#define PIC_REG_WPU_MASK       0x0Fu
#define PIC_REG_WPU_INIT       0x08u
#define PIC_REG_WPU_INIT_STR   "0x08"
#define PIC_REG_WPU_DESC       "RA3-only (0x08)"

// ---- Physical port vs output latch ------------------------------------------
// LATA is a real SFR and PORTA follows it with no firmware step in between, so
// the two never disagree and the tolerance is zero: any divergence at all is a
// fault. A part whose latch is an SRAM shadow needs a non-zero bound here,
// because propagating the shadow to the port costs it an instruction.
#define PIC_REG_PORT_SKEW_SAMPLES 0u
#define PIC_REG_PORT_SKEW_DESC    ""

#endif // TEST_PIC_PIC10F32X_REGS_H
