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
// TRISIO=0x28, ANSEL=0x00, WPU=0x20, OPTION_REG=0x0C, GPIO=0x20.
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
// The injection is required of the lanes that COMPARE the latch, not of every
// lane that includes this file. The lock-step lane reads ctx_ and never looks
// at the output path, so demanding a shadow address of it would be demanding a
// value it has no use for. The latch macros below therefore exist only when the
// build supplied one, and a lane that reads them without one cannot compile:
// test_io_pic_core.h and test_fault_pic12f675.cc each say so by name, and any
// other consumer stops on an undeclared identifier.
//
// Absent, rather than defaulted, on purpose: a default would point the
// comparison at register 0x000 -- INDF, which reads plausibly -- and a
// shadow-vs-port check against INDF passes while checking nothing. A macro that
// does not exist cannot do that.

// ---- gpsim pin identity -----------------------------------------------------
// Consumed by pic/gpsim_bootstrap.h, whose own default is the 10F32x's "ra3".
// It lives here rather than in each adapter so every PIC12F675 harness -- io,
// lock-step, fault, soak -- attaches its stimulus to the same pin by
// construction.
#ifndef FOOTSW_PIN_NAME
#  define FOOTSW_PIN_NAME "gpio5"
#endif

// Exact libgpsim pin names for physical relay-coil and comparator observation.
// GPIO register readback is insufficient when COUT owns GP2, so the fault lane
// attaches nodes to both package pins and measures their voltages directly. GP0
// also receives a normally high-impedance source that the fault lane drives low
// and high while the comparator fixture is active; this supplies both modeled
// output states without relying on the observed mode-110 behavior where gpsim
// stores CINV but does not invert its modeled COUT.
#define PIC_REG_COMPARATOR_INPUT_PIN_NAME "gpio0"
#define PIC_REG_RESET_COIL_PIN_NAME "gpio1"
#define PIC_REG_SET_COIL_PIN_NAME   "gpio2"
// The parked spare output. It is observed on the same physical footing as the
// coils because the relay escalation path publishes the WHOLE output shadow in
// one write (see hw_emergency_outputs_quiesce()), so a corrupt GP4 intent bit
// becomes a driven pad for the watchdog interval unless the escalation
// canonicalizes it. A post-reset read cannot see that: the reset is what ends
// the unsafe interval.
#define PIC_REG_SPARE_OUTPUT_PIN_NAME "gpio4"

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
// Defined only when the build injected the address -- see above.
#ifdef PIC_SHADOW_ADDR
#  define PIC_REG_LATCH_ADDR   PIC_SHADOW_ADDR
#  define PIC_REG_LATCH_NAME   "gpio_shadow_"
// The token the fault lane's fetch_sfr() requires the gpsim register name to
// contain. gpsim names SRAM positionally ("REG040") and SFRs by their datasheet
// name, so "reg" asserts exactly one thing: the address being corrupted is an
// unnamed GPR and not a special-function register. It deliberately does NOT
// assert WHICH GPR -- that would pin the placement, which is XC8's to choose --
// and it is what stops a mis-edited injection from corrupting GPIO or TRISIO
// while its label still says shadow. The check is a substring match, so the one
// SFR it cannot separate from a GPR is OPTION_REG, whose name contains "reg";
// every other register on this part is excluded by name.
//
// See PIC_REG_LATCH_LC in pic10f32x_regs.h for why the printable name is a
// separate macro.
#  define PIC_REG_LATCH_TOKEN  "reg"
#  define PIC_REG_LATCH_LC     "gpio_shadow_"
#endif

#define PIC_REG_ANSEL_ADDR   0x09Fu   // ANSEL (bank 1); ANS0..ANS3 = GP0,GP1,GP2,GP4
#define PIC_REG_ANSEL_NAME   "ANSEL"
#define PIC_REG_ANSEL_TOKEN  "ansel"
#define PIC_REG_ANSEL_MASK   0x0Fu

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
// Pins the firmware drives as outputs (BYPASS_OUTPUT_DDR_MASK): GP0|GP1|GP2|GP4.
#define PIC_REG_OUTPUT_MASK  0x17u
// The status LED (BYPASS_LED_PIN): GP0, bit 0 of the "latch" above -- which on
// this part means bit 0 of the SRAM shadow, so the soak that polls it once per
// simulated millisecond is reading the firmware's write intent rather than a
// register the silicon owns.
#define PIC_REG_LED_MASK     0x01u
// The footswitch pin: GP5. NOT the input-only pin (GP3), which has no pull-up.
#define PIC_REG_FOOTSW_MASK  0x20u
// The two relay coil bits (RELAY_RESET_PIN | RELAY_SET_PIN) = GP1|GP2.
#define PIC_REG_COIL_MASK    0x06u
// The two coils separately: the relay resynchronization cases require the
// recovery actuation to be a RESET-coil pulse (the known BYPASS position) and
// require the SET coil to stay dark throughout it.
#define PIC_REG_RESET_COIL_MASK 0x02u
#define PIC_REG_SET_COIL_MASK   0x04u
// The parked spare output bit (SPARE_OUTPUT_PIN): GP4. Guarded low at every
// settled seam and, since the relay escalation path's single whole-port write,
// required low at the watchdog spin too.
#define PIC_REG_SPARE_OUTPUT_MASK 0x10u

// Exact steady-state TRISIO after init(): GP3/GP5 inputs, GP0..GP2/GP4 outputs.
// GP3 reads back as an input on this part whatever is written to it; GP4 is the
// parked low output whose direction, shadow, pin level and ANS3 bit are guarded.
#define PIC_REG_TRIS_INIT      0x28u
#define PIC_REG_TRIS_INIT_STR  "0x28"
// Pin-role phrasing for the two differently-worded assertions that print it.
#define PIC_REG_TRIS_LAYOUT    "GP3/GP5-input/GP0..GP2/GP4-output"
#define PIC_REG_TRIS_DESC      "GP3/GP5 inputs, GP0..GP2/GP4 outputs (0x28)"

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
