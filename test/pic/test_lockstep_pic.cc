// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// PIC10F322 adapter for the shared built-HEX/model lock-step harness. This lane
// proves that the XC8-compiled shell and shipping pure core preserve the model's
// state trajectory after every loop iteration.

#define PIC_LOCKSTEP_DEFAULT_FW_PATH \
    "build_pic10f322/bypass-pic10f322-tq2_l2_5v_relay.hex"
#define PIC_LOCKSTEP_DEFAULT_PROC_NAME "p10f322"

#include "pic/test_lockstep_pic_core.h"
