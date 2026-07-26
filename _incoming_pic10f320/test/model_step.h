// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// Shared single-step bridge for the host unit tests, the CBMC/symbolic proofs,
// and the firmware<->model equivalence test.
//
// step() DELEGATES to the vendored reference model's pure functions --
// debounce_integrate() and debounce_step() from test/model/bypass_pure.c -- so
// the host tests and the formal proofs all exercise the EXACT model code that
// the equivalence test pins the real firmware against. Nothing is reimplemented
// here, so nothing can drift.
//
// The vendored model is itself a copy of the parent project's host- and
// formally-verified pure core (see test/model/README.md for provenance); the
// firmware inlines the same algorithm to fit flash. This header is the seam that
// lets all three test layers speak to it.
//
// Each translation unit that includes this header must also link
// test/model/bypass_pure.c, and be compiled with -Itest/model so
// "bypass_config.h" / "bypass_pure.h" resolve to the vendored model.

#ifndef MODEL_STEP_H__
#define MODEL_STEP_H__

#include <stdint.h>

#include "bypass_config.h" // RELEASE_THRESH, PRESSED_THRESH
#include "bypass_pure.h"   // debounce_integrate(), debounce_step(), and the
                           // program_state_t / effect_state_t / pin_state_t
                           // enums (via bypass_types.h).

// Test-facing state. Mirrors the firmware's debounce_context_t with plain
// uint8_t fields; step() converts to/from the model's enum-typed context.
typedef struct {
    uint8_t program_state;    // PRESS_DEBOUNCE_WAIT or RELEASE_DEBOUNCE_WAIT
    uint8_t effect_state;     // BYPASS or ENGAGED
    uint8_t debounce_counter; // 0 .. RELEASE_THRESH
} state_t;

// Result of a single 1ms step: the successor state plus a flag indicating
// whether a toggle (effect-state change) occurred during the step.
typedef struct {
    state_t next;
    int     toggled;
} step_result_t;

// One 1ms step: the saturating integrator followed by one state-machine pass --
// exactly the per-tick work the firmware's main() loop body does (integrate the
// live footswitch level, then advance the state machine). Delegates to the real
// model functions. pin_low != 0 => footswitch reads LOW => switch pressed.
static step_result_t step(state_t s, int pin_low) {
    pin_state_t const pin        = (pin_low != 0) ? PIN_STATE_LOW : PIN_STATE_HIGH;
    uint8_t     const integrated = debounce_integrate(pin, s.debounce_counter);

    debounce_context_t ctx;
    ctx.program_state    = (program_state_t)s.program_state;
    ctx.effect_state     = (effect_state_t)s.effect_state;
    ctx.debounce_counter = integrated;
    debounce_step_result_t const dr = debounce_step(ctx);

    // Apply exactly as the firmware main() does: caller-owned fields always, and
    // the counter ONLY on an explicit lockout reload -- otherwise keep the
    // integrated value.
    step_result_t r;
    r.next.program_state    = (uint8_t)dr.program_state;
    r.next.effect_state     = (uint8_t)dr.effect_state;
    r.next.debounce_counter = dr.reload_lockout ? dr.lockout_value : integrated;
    r.toggled               = (int)dr.toggled;
    return r;
}

#endif // MODEL_STEP_H__
