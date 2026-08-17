// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// PIC12F675 adapter for the shared libgpsim fault-injection harness. 1024
// program words, and an output "latch" that is not a register at all: this part
// has no LATx, so the shell keeps gpio_shadow_ in SRAM and writes shadow ->
// GPIO. The core's per-part output hook therefore injects NINE cases where the
// PIC10F322 injects three: four shadow faults, four physical-port faults, and a
// valid effect-state mismatch that leaves both shadow and port untouched. Those
// groups isolate expected-vs-shadow and shadow-vs-port independently.
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
// Output-stage fault policy is variant-split (see docs/relay_coil_fault_correction.md).
//
// Relay variant: hw_outputs_reassert_safe() re-drives set_relay_coils_low() at
// the top of every serviced tick, before the sanity gate. Because this part has
// no LATx and writes the WHOLE shadow to GPIO, that re-assert (a) clears the
// coil bits in the shadow and (b) refreshes the ENTIRE physical port from the
// shadow. So a coil SHADOW upset and ANY physical-PORT upset are corrected
// within one iteration with no reset; only a non-coil SHADOW (intent) upset and
// the expected-mask (effect_state) upset still reset. A persistent port fault
// (pin will not follow the refresh) is still caught by port-follows-shadow.
//
// CD4053 variants: hw_outputs_reassert_safe() is a no-op, so every output upset
// still resets, exactly as before.
#if defined(TQ2_L2_5V_RELAY)
// expected_resets=0 asserts "corrected, no reset." That transitively proves
// within-one-tick correction: an uncorrected coil/port bit would diverge from
// the shadow and trip the port-follows-shadow gate at the next tick -> reset.
// A shadow coil injection never drives the port high on this part (the re-assert
// clears the shadow bit before the next GPIO=shadow write), so we cannot use the
// 320-style inject_relay_correction_case, whose observed_port==mask precondition
// only holds where the latch drives the port.
#  define PIC_FAULT_EXPECTED_CHECKS 45u
#  define PIC_FAULT_EXTRA_OUTPUT_INJECTIONS() do { \
    inject_case("shadow.GP0", PIC_REG_LATCH_ADDR, PIC_REG_LATCH_TOKEN, false, 0x01, 1, \
                "GP0 LED shadow (intent) corruption still resets"); \
    inject_case("shadow.GP4", PIC_REG_LATCH_ADDR, PIC_REG_LATCH_TOKEN, false, 0x10, 1, \
                "parked GP4 shadow (intent) corruption still resets"); \
    inject_case("shadow.GP1", PIC_REG_LATCH_ADDR, PIC_REG_LATCH_TOKEN, false, 0x02, 0, \
                "GP1 RESET-coil shadow corrected low each tick, no reset"); \
    inject_case("shadow.GP2", PIC_REG_LATCH_ADDR, PIC_REG_LATCH_TOKEN, false, 0x04, 0, \
                "GP2 SET-coil shadow corrected low each tick, no reset"); \
    inject_case("GPIO.GP0", PIC_REG_PORT_ADDR, PIC_REG_PORT_TOKEN, false, 0x01, 0, \
                "GP0 LED port glitch refreshed low from shadow, no reset"); \
    inject_case("GPIO.GP1", PIC_REG_PORT_ADDR, PIC_REG_PORT_TOKEN, false, 0x02, 0, \
                "GP1 RESET-coil port energized, refreshed low from shadow, no reset"); \
    inject_case("GPIO.GP2", PIC_REG_PORT_ADDR, PIC_REG_PORT_TOKEN, false, 0x04, 0, \
                "GP2 SET-coil port energized, refreshed low from shadow, no reset"); \
    inject_case("GPIO.coils", PIC_REG_PORT_ADDR, PIC_REG_PORT_TOKEN, false, 0x06, 0, \
                "both coil ports energized, refreshed low from shadow, no reset"); \
    inject_case("GPIO.GP4", PIC_REG_PORT_ADDR, PIC_REG_PORT_TOKEN, false, 0x10, 0, \
                "parked GP4 port glitch refreshed low from shadow, no reset"); \
    inject_case("ctx.expected", CTX_EFFECT_STATE, nullptr, true, 0x01, 1, \
                "BYPASS shadow/GPIO stay matching; ENGAGED expectation isolates shadow mismatch"); \
} while (0)
#else
#  define PIC_FAULT_EXPECTED_CHECKS 37u
// The shadow cases make both output-integrity clauses false. The GPIO cases
// isolate port-follows-shadow: the shadow still matches settled BYPASS. The
// final context case does the converse: valid ENGAGED changes only the expected
// mask while settled BYPASS shadow/GPIO remain matching, so only
// shadow-versus-expected can explain its reset.
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
    inject_case("ctx.expected", CTX_EFFECT_STATE, nullptr, true, 0x01, 1, \
                "BYPASS shadow/GPIO stay matching; ENGAGED expectation isolates shadow mismatch"); \
} while (0)
#endif
#define PIC_FAULT_PROGRAM_STATE_NOTE \
    "0->2: > RELEASE_DEBOUNCE_WAIT (also core res.fault)"

#if (defined(CD4053_SIMPLE) + defined(CD4053_WITH_MUTE) + \
     defined(TQ2_L2_5V_RELAY)) != 1
#  error "define exactly one output variant"
#endif

#include "pic/test_fault_pic_core.h"
