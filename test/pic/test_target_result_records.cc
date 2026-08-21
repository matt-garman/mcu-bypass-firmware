// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

#ifndef PIC_TARGET_RESULT_VARIANT
#  error "PIC_TARGET_RESULT_VARIANT is required"
#endif
#ifndef PIC_TARGET_RESULT_FAULT_CHECKS
#  error "PIC_TARGET_RESULT_FAULT_CHECKS is required"
#endif
#ifndef PIC_TARGET_RESULT_LOCKSTEP_CHECKS
#  error "PIC_TARGET_RESULT_LOCKSTEP_CHECKS is required"
#endif
#ifndef PIC_TARGET_RESULT_IO_CHECKS
#  error "PIC_TARGET_RESULT_IO_CHECKS is required"
#endif

#define PIC_TARGET_RESULT_DEVICE "pic12f675"

#include "pic/target_result.h"

int main(void) {
    pic_target_result("fault", true, PIC_TARGET_RESULT_FAULT_CHECKS, 0u);
    pic_target_result("lockstep", true, PIC_TARGET_RESULT_LOCKSTEP_CHECKS, 0u);
    pic_target_result("io", true, PIC_TARGET_RESULT_IO_CHECKS, 0u);
    return 0;
}
