// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// PIC10F320 adapter for the shared libgpsim fault-injection harness. This part
// has 256 program words and deliberately omits the GENERAL output-latch
// integrity guard to fit its flash budget. What it does buy, on the relay
// variant only, is the two coil latch bits -- the one part of the latch that
// carries a physical hazard -- so the relay variant adds five
// resynchronization cases to the 18 common injections. The LED and any spare
// output latch remain unguarded here; that gap is documented, not closed.

/* name-contract: exempt-begin (PIC_REG_ and PIC_FAULT_ names are C macro
   families, not make vars) */
#include "pic/pic10f32x_regs.h"          // PIC_REG_* device identity
#include "pic/pic10f32x_fault_matrix.h"  // PIC_FAULT_* injection matrix
/* name-contract: exempt-end */

#define PIC_FAULT_DEFAULT_PROC_NAME "p10f320"
#define PIC_FAULT_PROGRAM_WORDS 0x100u
// F1 fail-safe contract (docs/relay_coil_fault_correction.md): an energized
// coil resets here exactly as it does on the modular shells. Both halves are
// required -- both coils de-energized before the spin, and a complete
// RESET-coil actuation after the recovery -- and both settled states are
// covered, so a coil fault arriving while the relay believes it is ENGAGED is
// tested as well as one arriving in BYPASS.
//
// The LED latch case below is the deliberate NEGATIVE control for that gap:
// RA0 is not guarded on this part, so injecting it must NOT reset. Asserting
// the exception rather than only describing it means the gap cannot quietly
// widen (a future change that stopped guarding the coils would fail the resync
// cases) and cannot quietly close either (adding a general latch guard would
// fail this case, forcing the documentation to be updated with the firmware).
#if defined(OUTPUT_TQ2_RELAY)
#  define PIC_FAULT_EXPECTED_CHECKS 29u
#  define PIC_FAULT_EXTRA_OUTPUT_INJECTIONS() do { \
    inject_case("LATA.RA0", PIC_REG_LATCH_ADDR, PIC_REG_LATCH_TOKEN, false, 0x01, 0, \
                "RA0 LED latch high: documented PIC10F320 gap, must NOT reset"); \
    inject_relay_resync_case(PIC_REG_LATCH_ADDR, PIC_REG_LATCH_TOKEN, \
                             0x02u, false, "RA1 RESET coil latch forced high"); \
    inject_relay_resync_case(PIC_REG_LATCH_ADDR, PIC_REG_LATCH_TOKEN, \
                             0x04u, false, "RA2 SET coil latch forced high"); \
    inject_relay_resync_case(PIC_REG_LATCH_ADDR, PIC_REG_LATCH_TOKEN, \
                             0x06u, false, "both relay coil latches forced high"); \
    inject_relay_resync_case(PIC_REG_LATCH_ADDR, PIC_REG_LATCH_TOKEN, \
                             0x02u, true, "RA1 RESET coil latch forced high"); \
    inject_relay_resync_case(PIC_REG_LATCH_ADDR, PIC_REG_LATCH_TOKEN, \
                             0x04u, true, "RA2 SET coil latch forced high"); \
} while (0)
#else
#  define PIC_FAULT_EXPECTED_CHECKS 24u
#  define PIC_FAULT_EXTRA_OUTPUT_INJECTIONS() do { \
    inject_case("LATA.RA0", PIC_REG_LATCH_ADDR, PIC_REG_LATCH_TOKEN, false, 0x01, 0, \
                "RA0 LED latch high: documented PIC10F320 gap, must NOT reset"); \
} while (0)
#endif
#define PIC_FAULT_PROGRAM_STATE_NOTE \
    "0->2: > RELEASE_DEBOUNCE_WAIT (also the switch default: path)"
// Shares the PIC10F32x watchdog note with PIC10F322: gpsim honors WDTCON.WDTPS
// but its calibration does not match the datasheet -- at WDTPS=0x08 the modeled
// period is ~1.057 s, not the silicon ~256 ms. Descriptive only; the gate
// asserts a reset within a generous window, never a period.
#define PIC_FAULT_WDT_NOTE \
    "(NB: gpsim WDT@WDTPS=0x08 ~1.057s -- recovery reset, not 256ms silicon)"

#if (defined(OUTPUT_CD4053_SIMPLE) + defined(OUTPUT_CD4053_WITH_MUTE) + \
     defined(OUTPUT_TQ2_RELAY)) != 1
#  error "define exactly one OUTPUT_* variant"
#endif

#include "pic/test_fault_pic_core.h"
