// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// PIC12F675 adapter for the shared libgpsim fault-injection harness. 1024
// program words, and an output "latch" that is not a register at all: this part
// has no LATx, so the shell keeps gpio_shadow_ in SRAM and writes shadow ->
// GPIO. The core's per-part output hook therefore injects nine output cases for
// each CD4053 variant and twelve for relay, versus three CD4053 or six relay
// cases on PIC10F322: shadow faults, modeled-GPIO faults, and a valid
// effect-state mismatch that leaves both views untouched. Those groups isolate
// expected-vs-shadow and shadow-vs-port independently.
//
// Everything else this part guards, and the two OPTION_REG bits it deliberately
// does not, live in the injection matrix beside this file.

/* name-contract: exempt-begin (PIC_REG_ and PIC_FAULT_ names are C macro
   families, not make vars) */
#include "pic/pic12f675_regs.h"          // PIC_REG_* device identity, FOOTSW_PIN_NAME
#include "pic/pic12f675_fault_matrix.h"  // PIC_FAULT_* injection matrix
/* name-contract: exempt-end */

// The shadow address is a per-build fact lifted from the XC8 .sym, not a device
// address, so the register map leaves its macros undefined when the build did
// not supply one. This lane CORRUPTS the shadow, so it says so by name rather
// than failing later on an undeclared identifier. There is no value a default
// could carry that would be right, and the obvious one is actively wrong:
// register 0x000 is INDF, which is not storage at all -- a write through it
// lands wherever FSR happens to point, so the four shadow cases would be
// corrupting an arbitrary GPR under a label that says shadow.
#ifndef PIC_SHADOW_ADDR
#  error "PIC_SHADOW_ADDR (_gpio_shadow_ from the XC8 .sym) is required: this lane injects into the shadow"
#endif

#define PIC_FAULT_DEFAULT_PROC_NAME "p12f675"
// 1024 words of flash, matching this part's budget in the Makefile.
#define PIC_FAULT_PROGRAM_WORDS 0x400u
// The shared core adds one IN-RANGE ctx.debounce_counter case (only F2's
// XOR-fold shadow catches it) iff the firmware image opts into BYPASS_CTX_CHECK.
// PIC12F675 always enables F2 (see docs/context_seu_detection.md and the
// Makefile), so the fault compile passes -DBYPASS_CTX_CHECK and this term is 1;
// keep it macro-driven so the count and the case can never disagree.
#if defined(BYPASS_CTX_CHECK)
#  define PIC_FAULT_CTX_INRANGE 1u
#else
#  define PIC_FAULT_CTX_INRANGE 0u
#endif
// Output-stage fault policy (see docs/relay_coil_fault_correction.md). Nothing
// re-drives the port ahead of the gate on any variant now, so EVERY modeled
// output injection at this pre-gate seam resets -- which is also what finally
// makes this part's unique port-follows-shadow clause load-bearing at the
// settled seam instead of pre-empted by a refresh.
//
// The relay variant adds the second half of the F1 contract on top of that
// shared response: the escalation path must de-energize both coils before the
// spin, and the watchdog recovery must command a minimum-qualified RESET-coil
// pulse while firmware settles to BYPASS. Both the shadow (intent) and
// modeled-GPIO (pin) coil
// views are injected, because on this part they fail independently: a shadow
// coil bit trips shadow-vs-expected without the pin ever being energized, while
// a GPIO coil bit energizes the pin with the shadow still clean and trips
// port-follows-shadow.
#if defined(TQ2_L2_5V_RELAY)
// Twelve output checks plus three physical comparator checks, one per mode one
// bit from comparator-off. Modes 011 and 101 route COUT to the GP2 pad and must
// force it High, reject a latch-only clear, and still complete escalation and
// recovery; mode 110 does not own GP2 and must leave the pad under its
// settled-low GPIO driver. Every case costs one check.
//
// The parked-GP4 shadow case is an inject_parked_output_resync_case() on this
// variant rather than the CD4053 arm's inject_case: the relay escalation path
// publishes the whole shadow in one write, so GP4's PAD -- not just the reset --
// is part of the contract (B1). Same one check either way, so the total below
// is unchanged by that substitution.
#  define PIC_FAULT_EXPECTED_CHECKS (42u + PIC_FAULT_CTX_INRANGE)
#  define PIC_FAULT_REQUIRE_PHYSICAL_COIL_IDLE 1
#  define PIC_FAULT_EXTRA_OUTPUT_INJECTIONS() do { \
    inject_case("shadow.GP0", PIC_REG_LATCH_ADDR, PIC_REG_LATCH_TOKEN, false, 0x01, 1, \
                "GP0 LED shadow (intent) corruption resets"); \
    inject_parked_output_resync_case( \
                "parked GP4 shadow (intent) corruption: reset, and the" \
                " escalation's one whole-port write must not drive the pad"); \
    inject_case("GPIO.GP0", PIC_REG_PORT_ADDR, PIC_REG_PORT_TOKEN, false, 0x01, 1, \
                "GP0 LED pin high with its shadow low: port stopped following"); \
    inject_case("GPIO.GP4", PIC_REG_PORT_ADDR, PIC_REG_PORT_TOKEN, false, 0x10, 1, \
                "parked GP4 pin high with its shadow low: port stopped following"); \
    inject_relay_resync_case(PIC_REG_LATCH_ADDR, PIC_REG_LATCH_TOKEN, \
                             0x02u, false, "GP1 RESET-coil shadow (intent) forced high"); \
    inject_relay_resync_case(PIC_REG_LATCH_ADDR, PIC_REG_LATCH_TOKEN, \
                             0x04u, false, "GP2 SET-coil shadow (intent) forced high"); \
    inject_relay_resync_case(PIC_REG_PORT_ADDR, PIC_REG_PORT_TOKEN, \
                             0x02u, false, "GP1 RESET-coil pin energized"); \
    inject_relay_resync_case(PIC_REG_PORT_ADDR, PIC_REG_PORT_TOKEN, \
                             0x04u, false, "GP2 SET-coil pin energized"); \
    inject_relay_resync_case(PIC_REG_PORT_ADDR, PIC_REG_PORT_TOKEN, \
                             0x06u, false, "both coil pins energized"); \
    inject_relay_resync_case(PIC_REG_PORT_ADDR, PIC_REG_PORT_TOKEN, \
                             0x02u, true, "GP1 RESET-coil pin energized"); \
    inject_relay_resync_case(PIC_REG_PORT_ADDR, PIC_REG_PORT_TOKEN, \
                             0x04u, true, "GP2 SET-coil pin energized"); \
    inject_shadow_expected_case("shadow.expected", 0x01, \
                "shadow+port GP0 high vs BYPASS expected: isolates shadow-vs-expected, F2-blind (ctx_ untouched)"); \
} while (0)
#else
#  define PIC_FAULT_EXPECTED_CHECKS (37u + PIC_FAULT_CTX_INRANGE)
// The shadow cases make both output-integrity clauses false. The GPIO cases
// isolate port-follows-shadow: the shadow still matches settled BYPASS. The
// final shadow.expected case does the converse: it drives shadow AND port to
// the same high value while ctx_ (hence the expected mask) stays settled
// BYPASS, so shadow-versus-expected is the sole trip and -- ctx_ being
// untouched -- the F2 fold cannot mask it.
#  define PIC_FAULT_EXTRA_OUTPUT_INJECTIONS() do { \
    inject_case("shadow.GP0", PIC_REG_LATCH_ADDR, PIC_REG_LATCH_TOKEN, false, 0x01, 1, \
                "GP0 LED shadow changed from settled low to high"); \
    inject_case("shadow.GP1", PIC_REG_LATCH_ADDR, PIC_REG_LATCH_TOKEN, false, 0x02, 1, \
                "GP1 control/reset-coil shadow changed from low to high"); \
    inject_case("shadow.GP2", PIC_REG_LATCH_ADDR, PIC_REG_LATCH_TOKEN, false, 0x04, 1, \
                "GP2 control/set-coil/spare shadow changed from low to high"); \
    inject_case("shadow.GP4", PIC_REG_LATCH_ADDR, PIC_REG_LATCH_TOKEN, false, 0x10, 1, \
                "parked GP4 shadow changed from low to high"); \
    inject_case("GPIO.GP0",   PIC_REG_PORT_ADDR,  PIC_REG_PORT_TOKEN,  false, 0x01, 1, \
                "GP0 pin driven high with its shadow low: port stopped following"); \
    inject_case("GPIO.GP1",   PIC_REG_PORT_ADDR,  PIC_REG_PORT_TOKEN,  false, 0x02, 1, \
                "GP1 pin driven high with its shadow low: port stopped following"); \
    inject_case("GPIO.GP2",   PIC_REG_PORT_ADDR,  PIC_REG_PORT_TOKEN,  false, 0x04, 1, \
                "GP2 pin driven high with its shadow low: port stopped following"); \
    inject_case("GPIO.GP4",   PIC_REG_PORT_ADDR,  PIC_REG_PORT_TOKEN,  false, 0x10, 1, \
                "parked GP4 pin high with its shadow low: port stopped following"); \
    inject_shadow_expected_case("shadow.expected", 0x01, \
                "shadow+port GP0 high vs BYPASS expected: isolates shadow-vs-expected, F2-blind (ctx_ untouched)"); \
} while (0)
#endif
#define PIC_FAULT_PROGRAM_STATE_NOTE \
    "0->2: > RELEASE_DEBOUNCE_WAIT (also core res.fault)"
// Unlike the 10F32x lanes, this part has no WDTCON: its prescaler is OPTION_REG,
// and at 0x0C (PSA=1, 1:16) gpsim models ~288 ms = 18 ms x 16, matching the
// datasheet nominal. The characterized silicon MINIMUM at this ratio is 160 ms,
// and no simulator models the RC spread that produces it. Descriptive only --
// the gate asserts a reset within a generous window, never a period (see
// test_soak_pic12f675.cc for the matching soak note).
#define PIC_FAULT_WDT_NOTE \
    "(NB: gpsim WDT ~288ms = 1:16 nominal at OPTION_REG=0x0C; silicon min 160ms -- recovery reset, not RC spread)"

#if (defined(CD4053_SIMPLE) + defined(CD4053_WITH_MUTE) + \
     defined(TQ2_L2_5V_RELAY)) != 1
#  error "define exactly one output variant"
#endif

#include "pic/test_fault_pic_core.h"
