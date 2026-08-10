// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// PIC10F322 adapter for the shared libgpsim fault-injection harness. This part
// has 512 program words and guards its settled output latch, so the common fault
// matrix is extended with three LATA injections.

/* name-contract: exempt-begin (PIC_REG_ and PIC_FAULT_ names are C macro
   families, not make vars) */
#include "pic/pic10f32x_regs.h"          // PIC_REG_* device identity
#include "pic/pic10f32x_fault_matrix.h"  // PIC_FAULT_* injection matrix
/* name-contract: exempt-end */

#define PIC_FAULT_DEFAULT_PROC_NAME "p10f322"
#define PIC_FAULT_PROGRAM_WORDS 0x200u
#define PIC_FAULT_EXPECTED_CHECKS 25u
#define PIC_FAULT_EXTRA_OUTPUT_INJECTIONS() do { \
    inject_case("LATA.RA0", PIC_REG_LATCH_ADDR, PIC_REG_LATCH_TOKEN, false, 0x01, 1, \
                "RA0 LED latch changed from settled low to high"); \
    inject_case("LATA.RA1", PIC_REG_LATCH_ADDR, PIC_REG_LATCH_TOKEN, false, 0x02, 1, \
                "RA1 control/reset-coil latch changed from low to high"); \
    inject_case("LATA.RA2", PIC_REG_LATCH_ADDR, PIC_REG_LATCH_TOKEN, false, 0x04, 1, \
                "RA2 control/set-coil/spare latch changed from low to high"); \
} while (0)
#define PIC_FAULT_PROGRAM_STATE_NOTE \
    "0->2: > RELEASE_DEBOUNCE_WAIT (also core res.fault)"

#if (defined(CD4053_SIMPLE) + defined(CD4053_WITH_MUTE) + \
     defined(TQ2_L2_5V_RELAY)) != 1
#  error "define exactly one output variant"
#endif

#include "pic/test_fault_pic_core.h"
