// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// PIC12F675 adapter for the shared built-HEX/model lock-step harness. Like the
// 10F32x adapters it proves that the XC8-compiled shell and the shipping pure
// core preserve the model's state trajectory after every loop iteration -- here
// for a third code generation, on a different core family, against the same
// reference model.
//
// Three things differ from the 10F32x adapters, and only the first two are
// visible in this file:
//
//   - PROGRAM SPACE IS FOUR TIMES THE SIZE, and the scan that identifies the
//     main loop's CLRWDT covers all of it. That scan ran to a hard-coded 0x200
//     until this part arrived, which would have stopped 512 words short of this
//     image's end and hidden the very instruction the lane anchors on.
//   - THE FOOTSWITCH IS gpio5, not ra3. The name arrives through the device
//     register map rather than being spelled here, so this lane and the io and
//     fault lanes cannot drift onto different pins. That header is included for
//     that one identity: this lane reads firmware state, not registers.
//   - THE IMAGE IS THE DERIVED *_simcal.hex. Without the injected oscillator
//     calibration word this part never reaches main() at all -- see the
//     calibration block in the Makefile. That choice is the Makefile's; the
//     adapter only ever sees FW_PATH.
//
// What does NOT differ is worth stating, because much of this part's suite had
// to re-derive it: the lane locks steps on ITERATIONS, one model step per
// completed main-loop pass, so neither the 1.024 ms tick nor the 12 ms blocking
// coil pulse changes a single constant here.

#include "pic/pic12f675_regs.h"   // device identity; here, FOOTSW_PIN_NAME = "gpio5"

#define PIC_LOCKSTEP_DEFAULT_PROC_NAME "p12f675"
// 1024 words of flash, matching this part's budget in the Makefile.
#define PIC_LOCKSTEP_PROGRAM_WORDS 0x400u

#include "pic/test_lockstep_pic_core.h"
