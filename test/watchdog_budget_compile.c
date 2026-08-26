// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// Compile-only fixture for the production watchdog-budget macro. The invoking
// regression selects one real pin map and supplies independently derived exact
// results; this file deliberately contains no copy of the formula.

#include "bypass_output_common.h"
#include "bypass_static_assert.h"

#if !defined(TEST_RELAY_BUDGET_MS) || !defined(TEST_MUTE_BUDGET_MS) \
        || !defined(TEST_SIMPLE_BUDGET_MS) \
        || !defined(TEST_PROBE_BLOCKING_MS) \
        || !defined(TEST_PROBE_BUDGET_MS)
#  error "watchdog budget fixture requires every TEST_* budget"
#endif

static_assert(WDT_PET_TO_PET_MAX_MS(12U) == TEST_RELAY_BUDGET_MS,
        "production relay watchdog budget differs from independent result");
static_assert(WDT_PET_TO_PET_MAX_MS(5U) == TEST_MUTE_BUDGET_MS,
        "production mute watchdog budget differs from independent result");
static_assert(WDT_PET_TO_PET_MAX_MS(0U) == TEST_SIMPLE_BUDGET_MS,
        "production simple watchdog budget differs from independent result");
static_assert(WDT_PET_TO_PET_MAX_MS(TEST_PROBE_BLOCKING_MS)
                == TEST_PROBE_BUDGET_MS,
        "production watchdog budget differs at the requested domain probe");
