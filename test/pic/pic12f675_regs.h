// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// PIC12F675 device identity for the shared libgpsim harness cores
// (test_io_pic_core.h, test_fault_pic_core.h).
//
// The classic mid-range counterpart of pic10f32x_regs.h -- see that file for
// why device identity lives beside the cores rather than inside them. This is
// the "second family" its closing comment anticipated, and it is a genuinely
// different map rather than the same map with different numbers:
//
//   1. THE SECOND BANK IS A DIFFERENT ADDRESS, not an alias. TRISIO/WPU/ANSEL/
//      OPTION_REG all live at 0x08x/0x09x here, against 0x006..0x00E on the
//      enhanced mid-range part.
//   2. THERE IS NO OUTPUT LATCH SFR. GPIO reads the physical pins, so the
//      firmware keeps its own SRAM shadow and writes shadow -> GPIO. The
//      "latch" this map names is that shadow (see PIC_SHADOW_ADDR below).
//   3. SIX I/O, NOT FOUR, and the footswitch is on GP5 rather than the
//      input-only pin -- GP3 has no weak pull-up on this part, which is the
//      whole reason for the move (src/bypass_pins_pic12f675.h).
//
// EVERY ADDRESS AND INIT VALUE HERE WAS READ OUT OF gpsim, not off a datasheet
// page. To re-derive after a toolchain or firmware change, load a *_simcal.hex
// on p12f675, run past init(), and print rma.get_register(addr)->name() and
// ->get_value() for each address below; the observed steady state is
// TRISIO=0x38, ANSEL=0x00, WPU=0x20, OPTION_REG=0x0C, GPIO=0x20.
//
// The fault-injection-only SFRs of this part (CMCON, ADCON0, OSCCAL) are NOT
// here, for the same reason OSCCON/PR2/T2CON/WDTCON are not in the 10F32x map:
// they are guard policy, so they belong to pic12f675_fault_matrix.h.

#ifndef TEST_PIC_PIC12F675_REGS_H
#define TEST_PIC_PIC12F675_REGS_H

// ---- The output "latch" is SRAM, so its address is per-build ----------------
// gpio_shadow_ is a file-static in the shell, placed by XC8, so unlike every
// other entry here its address is not a device fact. The Makefile lifts it from
// the build's .sym and injects it, exactly as the fault and lock-step lanes
// already do for _ctx_ (-DCTX_ADDR=...).
//
// A missing injection is a hard error rather than a default, because the
// fallback would be register 0x000 -- INDF, which reads plausibly and would
// make the shadow-vs-port comparison silently meaningless.
#ifndef PIC_SHADOW_ADDR
#  error "PIC_SHADOW_ADDR must be injected: -DPIC_SHADOW_ADDR=0x<addr> for _gpio_shadow_ from the XC8 .sym"
#endif

// ---- gpsim pin identity -----------------------------------------------------
// Consumed by pic/gpsim_bootstrap.h, whose own default is the 10F32x's "ra3".
// It lives here rather than in each adapter so every PIC12F675 harness -- io,
// fault, soak -- attaches its stimulus to the same pin by construction.
#ifndef FOOTSW_PIN_NAME
#  define FOOTSW_PIN_NAME "gpio5"
#endif

// ---- Port / direction / latch / analog-select -------------------------------
#define PIC_REG_PORT_ADDR    0x005u   // GPIO: physical pin levels (no separate latch)
#define PIC_REG_PORT_NAME    "GPIO"
#define PIC_REG_PORT_TOKEN   "gpio"
#define PIC_REG_PORT_LC      "gpio"    // lowercase, for compact diagnostics

#define PIC_REG_TRIS_ADDR    0x085u   // TRISIO (bank 1): 1 = input, 0 = output
#define PIC_REG_TRIS_NAME    "TRISIO"
#define PIC_REG_TRIS_TOKEN   "trisio"

// The output latch: the shell's gpio_shadow_, NOT an SFR. Every output write is
// shadow -> GPIO, so the shadow is write intent and GPIO is the physical
// result; comparing them is the check this part can make and the 10F32x cannot.
#define PIC_REG_LATCH_ADDR   PIC_SHADOW_ADDR
#define PIC_REG_LATCH_NAME   "gpio_shadow_"
// No gpsim name to match: SRAM registers are named positionally ("REG040"), so
// a name cross-check would assert the placement rather than the identity. The
// core treats a null token as "not checkable"; see PIC_REG_LATCH_LC in
// pic10f32x_regs.h for why the printable name is a separate macro.
#define PIC_REG_LATCH_TOKEN  nullptr
#define PIC_REG_LATCH_LC     "gpio_shadow_"

#define PIC_REG_ANSEL_ADDR   0x09Fu   // ANSEL (bank 1); ANS0..ANS3 = GP0,GP1,GP2,GP4
#define PIC_REG_ANSEL_NAME   "ANSEL"
#define PIC_REG_ANSEL_TOKEN  "ansel"

// ---- Weak pull-ups ----------------------------------------------------------
#define PIC_REG_WPU_ADDR     0x095u   // WPU (bank 1): per-pin weak-pull-up latch
#define PIC_REG_WPU_NAME     "WPU"
#define PIC_REG_WPU_TOKEN    "wpu"

#define PIC_REG_OPTION_ADDR  0x081u   // OPTION_REG (bank 1); nGPPU (global pull-up enable) = bit 7
#define PIC_REG_OPTION_NAME  "OPTION_REG"
#define PIC_REG_OPTION_TOKEN "option"

// ---- Masks and expected init values -----------------------------------------
// Implemented I/O bits: six (GP0..GP5) against the 10F32x's four, so every
// masked comparison widens -- which is exactly why the cores never spell 0x0F.
#define PIC_REG_PORT_MASK    0x3Fu
// Pins the firmware drives as outputs (BYPASS_OUTPUT_DDR_MASK): GP0|GP1|GP2.
#define PIC_REG_OUTPUT_MASK  0x07u
// The footswitch pin: GP5. NOT the input-only pin (GP3), which has no pull-up.
#define PIC_REG_FOOTSW_MASK  0x20u
// The two relay coil bits (RELAY_RESET_PIN | RELAY_SET_PIN) = GP1|GP2.
#define PIC_REG_COIL_MASK    0x06u

// Exact steady-state TRISIO after init(): GP3..GP5 inputs, GP0..GP2 outputs.
// GP3 reads back as an input on this part whatever is written to it.
#define PIC_REG_TRIS_INIT      0x38u
#define PIC_REG_TRIS_INIT_STR  "0x38"
// Pin-role phrasing for the two differently-worded assertions that print it.
#define PIC_REG_TRIS_LAYOUT    "GP3..GP5-input/GP0..GP2-output"
#define PIC_REG_TRIS_DESC      "GP3..GP5 inputs, GP0..GP2 outputs (0x38)"

// Implemented WPU bits, and the exact latch init(): GP5 only. The mask is 0x37,
// not 0x3F -- this part has NO WPU bit 3, matching WPU_IMPLEMENTED_MASK in the
// shell's hw_footswitch_pullup_intact().
#define PIC_REG_WPU_MASK       0x37u
#define PIC_REG_WPU_INIT       0x20u
#define PIC_REG_WPU_INIT_STR   "0x20"
#define PIC_REG_WPU_DESC       "GP5-only (0x20)"

// ---- Physical port vs output latch ------------------------------------------
// On a part with a real latch SFR the port follows it within the same trace
// sample, so any divergence at all is a fault. Here the propagation is two
// firmware instructions (store shadow, then copy shadow to GPIO), so the port
// legitimately trails the shadow for a bounded moment.
//
// MEASURED, not budgeted: across all three variants, over startup and both
// toggles, the longest observed divergence is exactly one trace sample -- two
// instruction cycles, because gpsim advances this part two cycles per
// single-cycle breakpoint. A divergence that outlives that bound is the real
// fault this check exists to catch (a stuck pin, a lost write, a direction
// upset), and it would persist for thousands of samples, not one.
#define PIC_REG_PORT_SKEW_SAMPLES 1u
#define PIC_REG_PORT_SKEW_DESC    " within 1 trace sample"

#endif // TEST_PIC_PIC12F675_REGS_H
