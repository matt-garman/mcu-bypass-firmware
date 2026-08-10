// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// PIC12F675 adapter for the shared built-HEX GPIO/pulse-timing harness.
//
// Two things differ from the 10F32x adapters beside the part name, and both
// come in through the register map rather than through this file:
//   - the footswitch stimulus attaches to gpio5, not ra3;
//   - the "output latch" is the shell's gpio_shadow_ in SRAM, so the Makefile
//     injects -DPIC_SHADOW_ADDR from the build's .sym.
// It also runs the DERIVED *_simcal.hex: without the calibration word this part
// never reaches main() (see the calibration block in the Makefile).

/* name-contract: exempt-begin (PIC_REG_ names are a C macro family, not make vars) */
#include "pic/pic12f675_regs.h"   // PIC_REG_* device identity, FOOTSW_PIN_NAME
/* name-contract: exempt-end */

#define PIC_IO_DEFAULT_PROC_NAME "p12f675"
#define PIC_IO_PART_NAME "PIC12F675"

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
