// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

#define PIC_TARGET_RESULT_DEVICE "pic12f675"
#define PIC_TARGET_RESULT_VARIANT "tq2_l2_5v_relay"

#include "pic/target_result.h"

int main(void) {
    pic_target_result("fault", true, 37u, 0u);
    pic_target_result("lockstep", true, 3005u, 0u);
    pic_target_result("io", true, 36u, 0u);
    return 0;
}
