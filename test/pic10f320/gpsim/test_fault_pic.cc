// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// PIC10F320 adapter for the shared libgpsim fault-injection harness. This part
// has 256 program words and deliberately omits the output-latch integrity guard
// to fit its flash budget, so only the 18 common injections apply.

#define PIC_FAULT_DEFAULT_FW_PATH \
    "build_pic10f320/bypass_mcu_cd4053-simple_pic10f320.hex"
#define PIC_FAULT_DEFAULT_PROC_NAME "p10f320"
#define PIC_FAULT_PROGRAM_WORDS 0x100u
#define PIC_FAULT_EXPECTED_CHECKS 22u
#define PIC_FAULT_EXTRA_OUTPUT_INJECTIONS() do { } while (0)
#define PIC_FAULT_PROGRAM_STATE_NOTE \
    "0->2: > RELEASE_DEBOUNCE_WAIT (also the switch default: path)"

#if (defined(OUTPUT_CD4053_SIMPLE) + defined(OUTPUT_CD4053_WITH_MUTE) + \
     defined(OUTPUT_TQ2_RELAY)) != 1
#  error "define exactly one OUTPUT_* variant"
#endif

#include "pic/test_fault_pic_core.h"
