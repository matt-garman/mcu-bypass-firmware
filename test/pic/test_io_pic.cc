// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// PIC10F322 adapter for the shared built-HEX GPIO/pulse-timing harness.

#define PIC_IO_DEFAULT_FW_PATH "build_pic/bypass_cd4053_pic10f322.hex"
#define PIC_IO_DEFAULT_PROC_NAME "p10f322"
#define PIC_IO_PART_NAME "PIC10F322"

#if (defined(CD4053_SIMPLE) + defined(CD4053_WITH_MUTE) + \
     defined(TQ2_L2_5V_RELAY)) != 1
#  error "define exactly one output variant"
#elif defined(CD4053_SIMPLE)
#  define PIC_IO_SIMPLE
#elif defined(CD4053_WITH_MUTE)
#  define PIC_IO_MUTE
#else
#  define PIC_IO_RELAY
#endif

#include "pic/test_io_pic_core.h"
