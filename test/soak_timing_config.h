#ifndef TEST_SOAK_TIMING_CONFIG_H
#define TEST_SOAK_TIMING_CONFIG_H

#include <stdint.h>
#ifdef __cplusplus
#include <type_traits>
#endif

#if !defined(SOAK_DURATION_MS) || !defined(SOAK_LIVENESS_INTERVAL_MS) || \
    !defined(SOAK_PROGRESS_INTERVAL_MS)
#error "define all soak timing macros before including soak_timing_config.h"
#endif

#ifdef __cplusplus
#define SOAK_STATIC_ASSERT static_assert
#define SOAK_INTEGER_CONSTANT(expr) std::is_integral<decltype(expr)>::value
#else
#define SOAK_STATIC_ASSERT _Static_assert
#define SOAK_INTEGER_CONSTANT(expr) _Generic((expr), \
    char: 1, signed char: 1, unsigned char: 1, \
    short: 1, unsigned short: 1, int: 1, unsigned int: 1, \
    long: 1, unsigned long: 1, long long: 1, unsigned long long: 1, \
    default: 0)
#endif

#define SOAK_LIVENESS_DUE(elapsed_ms, deadline_ms) \
    ((uint64_t)(elapsed_ms) >= (uint64_t)(deadline_ms))

SOAK_STATIC_ASSERT(SOAK_INTEGER_CONSTANT(SOAK_DURATION_MS) &&
                   SOAK_DURATION_MS > 0 && SOAK_DURATION_MS < UINT32_MAX,
                   "SOAK_DURATION_MS must be in [1, UINT32_MAX - 1]");
SOAK_STATIC_ASSERT(SOAK_INTEGER_CONSTANT(SOAK_LIVENESS_INTERVAL_MS) &&
                   SOAK_LIVENESS_INTERVAL_MS > 0 &&
                   SOAK_LIVENESS_INTERVAL_MS <= UINT32_MAX,
                   "SOAK_LIVENESS_INTERVAL_MS must be in [1, UINT32_MAX]");
SOAK_STATIC_ASSERT(SOAK_LIVENESS_INTERVAL_MS <= SOAK_DURATION_MS,
                   "SOAK_LIVENESS_INTERVAL_MS must not exceed SOAK_DURATION_MS");
SOAK_STATIC_ASSERT(SOAK_LIVENESS_DUE(SOAK_LIVENESS_INTERVAL_MS,
                                     SOAK_LIVENESS_INTERVAL_MS),
                   "the liveness deadline must fire at equality");
SOAK_STATIC_ASSERT(SOAK_INTEGER_CONSTANT(SOAK_PROGRESS_INTERVAL_MS) &&
                   SOAK_PROGRESS_INTERVAL_MS > 0 &&
                   SOAK_PROGRESS_INTERVAL_MS <= UINT32_MAX,
                   "SOAK_PROGRESS_INTERVAL_MS must be in [1, UINT32_MAX]");

#undef SOAK_STATIC_ASSERT
#undef SOAK_INTEGER_CONSTANT

#endif
