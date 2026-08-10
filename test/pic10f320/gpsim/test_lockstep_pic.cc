// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// PIC10F320 adapter for the shared built-HEX/model lock-step harness. This lane
// compares the constrained hand-inlined firmware implementation against the
// independently compiled shared pure core after every loop iteration.

#define PIC_LOCKSTEP_DEFAULT_PROC_NAME "p10f320"
#define PIC_LOCKSTEP_PROGRAM_WORDS 0x100u

#include "pic/test_lockstep_pic_core.h"
