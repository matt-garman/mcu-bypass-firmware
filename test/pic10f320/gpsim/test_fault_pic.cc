// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// PIC10F320 adapter for the shared libgpsim fault-injection harness. This part
// has 256 program words and deliberately omits the general output-latch integrity
// guard to fit its flash budget. The relay variant instead corrects RA1/RA2 to
// their safe idle state every serviced iteration, so it adds three no-reset
// physical-output correction cases to the 18 common injections.

/* name-contract: exempt-begin (PIC_REG_ and PIC_FAULT_ names are C macro
   families, not make vars) */
#include "pic/pic10f32x_regs.h"          // PIC_REG_* device identity
#include "pic/pic10f32x_fault_matrix.h"  // PIC_FAULT_* injection matrix
/* name-contract: exempt-end */

#define PIC_FAULT_DEFAULT_PROC_NAME "p10f320"
#define PIC_FAULT_PROGRAM_WORDS 0x100u
#if defined(OUTPUT_TQ2_RELAY)
#  define PIC_FAULT_EXPECTED_CHECKS 25u
#  define PIC_FAULT_EXTRA_OUTPUT_INJECTIONS() do { \
    inject_relay_correction_case(0x02u, "RA1 RESET coil latch forced high"); \
    inject_relay_correction_case(0x04u, "RA2 SET coil latch forced high"); \
    inject_relay_correction_case(0x06u, "both relay coil latches forced high"); \
} while (0)
#else
#  define PIC_FAULT_EXPECTED_CHECKS 22u
#  define PIC_FAULT_EXTRA_OUTPUT_INJECTIONS() do { } while (0)
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
