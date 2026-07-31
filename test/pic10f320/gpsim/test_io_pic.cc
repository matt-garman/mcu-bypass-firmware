// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// PIC10F320 adapter for the shared built-HEX GPIO/pulse-timing harness.

#define PIC_IO_DEFAULT_FW_PATH \
    "build_pic10f320/bypass_mcu_cd4053-simple_pic10f320.hex"
#define PIC_IO_DEFAULT_PROC_NAME "p10f320"
#define PIC_IO_PART_NAME "PIC10F320"

#if (defined(OUTPUT_CD4053_SIMPLE) + defined(OUTPUT_CD4053_WITH_MUTE) + \
     defined(OUTPUT_TQ2_RELAY)) != 1
#  error "define exactly one OUTPUT_* variant"
#elif defined(OUTPUT_CD4053_SIMPLE)
#  define PIC_IO_SIMPLE
#elif defined(OUTPUT_CD4053_WITH_MUTE)
#  define PIC_IO_MUTE
#else
#  define PIC_IO_RELAY
#endif

#include "pic/test_io_pic_core.h"
