// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

#ifndef TEST_PIC_TARGET_RESULT_H
#define TEST_PIC_TARGET_RESULT_H

#include <cstdio>

static void pic_target_result(const char *lane, bool pass,
                              unsigned checks, unsigned failures) {
#if defined(PIC_TARGET_RESULT_DEVICE) && defined(PIC_TARGET_RESULT_VARIANT)
    printf("PIC_TARGET_RESULT format=1 device=%s lane=%s variant=%s"
           " status=%s checks=%u failures=%u\n",
           PIC_TARGET_RESULT_DEVICE, lane, PIC_TARGET_RESULT_VARIANT,
           pass ? "pass" : "fail", checks, failures);
#else
    (void)lane;
    (void)pass;
    (void)checks;
    (void)failures;
#endif
}

#endif
