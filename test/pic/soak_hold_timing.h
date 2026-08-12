#ifndef TEST_PIC_SOAK_HOLD_TIMING_H
#define TEST_PIC_SOAK_HOLD_TIMING_H

#ifdef __cplusplus

#  ifndef SOAK_TICK_US
#    error "SOAK_TICK_US must name the firmware debounce tick period"
#  endif
#  ifndef SOAK_ACTUATION_BLOCK_MS
#    error "SOAK_ACTUATION_BLOCK_MS must name the selected output's blocking time"
#  endif

// Milliseconds required to deliver a whole number of firmware ticks, rounded up.
#  define SOAK_TICKS_MS(ticks) (((ticks) * SOAK_TICK_US + 999u) / 1000u)

static_assert(SOAK_TICKS_MS(PRESSED_THRESH) * 1000u >=
                  PRESSED_THRESH * SOAK_TICK_US,
              "press hold is shorter than PRESSED_THRESH ticks");
static_assert(SOAK_TICKS_MS(PRESSED_THRESH) * 1000u <
                  PRESSED_THRESH * SOAK_TICK_US + 1000u,
              "press hold overshoots PRESSED_THRESH ticks by a whole millisecond");
static_assert(SOAK_TICKS_MS(RELEASE_THRESH) * 1000u >=
                  RELEASE_THRESH * SOAK_TICK_US,
              "release hold is shorter than RELEASE_THRESH ticks");
static_assert(SOAK_TICKS_MS(RELEASE_THRESH) * 1000u <
                  RELEASE_THRESH * SOAK_TICK_US + 1000u,
              "release hold overshoots RELEASE_THRESH ticks by a whole millisecond");

#  define SOAK_PRESS_HOLD_MS \
    (SOAK_TICKS_MS(PRESSED_THRESH) + SOAK_ACTUATION_BLOCK_MS + 10u)
#  define SOAK_RELEASE_HOLD_MS \
    (SOAK_TICKS_MS(RELEASE_THRESH) + SOAK_ACTUATION_BLOCK_MS + 10u)

#endif

#endif
