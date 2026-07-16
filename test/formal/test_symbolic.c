// Symbolic / exhaustive single-step property check for the debounce step()
// function.
//
// WHY THIS EXISTS
// ---------------
// test_model_check.c proves whole-program invariants via BFS over the reachable
// state graph. This file complements it with a SYMBOLIC-style proof of the
// per-step transition relation: for EVERY invariant-valid combination of
// (program_state, effect_state, debounce_counter, input) -- including valid
// states that are NOT reachable from the power-on roots -- the single-step
// function step() must preserve a set of local invariants. The domain here is
// tiny (two program states, two effect states, counters 0..RELEASE_THRESH, and
// one input bit), so complete host enumeration is mathematically equivalent to
// KLEE's symbolic exploration of the same constrained domain.
//
// DUAL MODE
//   - Default (host cc): exhaustive enumeration of the invariant-valid domain.
//   - KLEE (cc=klee/clang -emit-llvm, this file compiled with -DUSE_KLEE):
//     mark the inputs symbolic with klee_make_symbolic() and let KLEE explore.
//     The SAME assertions are used in both modes, so the Makefile target can run
//     under KLEE when available without any code changes here.
//
// step() delegates to debounce_integrate() and debounce_step() from the shipping
// bypass_pure.c and pulls thresholds from bypass_config.h via the host shim, so
// both modes verify the real pure-core implementation rather than a copy.

#include <stdint.h>
#include <stdio.h>

// state_t, step_result_t, step(), enum constants, and firmware thresholds.
// Single source of truth shared with test_model_check.c.
#include "model_step.h"

#ifdef USE_KLEE
#include <klee/klee.h>
#include <assert.h>
#define PROP_ASSERT(cond, ...) assert(cond)
#else
#include <assert.h>
#endif

//////////////////////////////////////////////////////////////////////////////
// The single-step property bundle. Holds for ALL valid inputs, reachable or
// not -- this is the inductive step that, combined with valid initial states,
// implies the whole-program invariants.
//////////////////////////////////////////////////////////////////////////////
static int g_failures = 0;
static int g_checks = 0;

#ifndef USE_KLEE
#define PROP_ASSERT(cond, msg, ps, es, dc, in) do {                       \
    g_checks++;                                                           \
    if (!(cond)) {                                                        \
        g_failures++;                                                     \
        fprintf(stderr, "FAIL %s:%d: %s (ps=%u es=%u dc=%u in=%d)\n",     \
                __FILE__, __LINE__, msg, ps, es, dc, in);                 \
    }                                                                     \
} while (0)
#endif

static void check_step_properties(state_t s, int pin_low) {
    step_result_t r = step(s, pin_low);

#ifdef USE_KLEE
    // (P1) range safety
    assert(r.next.program_state <= RELEASE_DEBOUNCE_WAIT);
    assert(r.next.effect_state  <= ENGAGED);
    assert(r.next.debounce_counter <= RELEASE_THRESH);
    // (P2) a toggle only out of PRESS_DEBOUNCE_WAIT, lands in RELEASE w/ lockout
    if (r.toggled) {
        assert(s.program_state == PRESS_DEBOUNCE_WAIT);
        assert(r.next.program_state == RELEASE_DEBOUNCE_WAIT);
        assert(r.next.debounce_counter == RELEASE_THRESH);
        assert(r.next.effect_state != s.effect_state);
    }
    // (P3) release-wait never changes effect_state / never toggles
    if (s.program_state == RELEASE_DEBOUNCE_WAIT) {
        assert(r.next.effect_state == s.effect_state);
        assert(r.toggled == 0);
    }
    // (P4) effect_state only ever changes when toggled is set
    if (r.next.effect_state != s.effect_state) {
        assert(r.toggled == 1);
    }
    // (P5) re-arm to press-wait only when counter hit 0
    if (s.program_state == RELEASE_DEBOUNCE_WAIT &&
        r.next.program_state == PRESS_DEBOUNCE_WAIT) {
        assert(r.next.debounce_counter == 0);
    }
    // (P6) counter moves by at most 1 except the deterministic lockout reload
    if (!r.toggled) {
        int d = (int)r.next.debounce_counter - (int)s.debounce_counter;
        assert(d >= -1 && d <= 1);
    }
#else
    PROP_ASSERT(r.next.program_state <= RELEASE_DEBOUNCE_WAIT,
                "(P1) program_state out of range",
                s.program_state, s.effect_state, s.debounce_counter, pin_low);
    PROP_ASSERT(r.next.effect_state <= ENGAGED,
                "(P1) effect_state out of range",
                s.program_state, s.effect_state, s.debounce_counter, pin_low);
    PROP_ASSERT(r.next.debounce_counter <= RELEASE_THRESH,
                "(P1) debounce_counter out of range",
                s.program_state, s.effect_state, s.debounce_counter, pin_low);

    if (r.toggled) {
        PROP_ASSERT(s.program_state == PRESS_DEBOUNCE_WAIT,
                    "(P2) toggle from non-press-wait",
                    s.program_state, s.effect_state, s.debounce_counter, pin_low);
        PROP_ASSERT(r.next.program_state == RELEASE_DEBOUNCE_WAIT,
                    "(P2) toggle did not enter release-wait",
                    s.program_state, s.effect_state, s.debounce_counter, pin_low);
        PROP_ASSERT(r.next.debounce_counter == RELEASE_THRESH,
                    "(P2) toggle did not load full lockout",
                    s.program_state, s.effect_state, s.debounce_counter, pin_low);
        PROP_ASSERT(r.next.effect_state != s.effect_state,
                    "(P2) toggle did not change effect_state",
                    s.program_state, s.effect_state, s.debounce_counter, pin_low);
    }

    if (s.program_state == RELEASE_DEBOUNCE_WAIT) {
        PROP_ASSERT(r.next.effect_state == s.effect_state,
                    "(P3) effect_state changed during lockout",
                    s.program_state, s.effect_state, s.debounce_counter, pin_low);
        PROP_ASSERT(r.toggled == 0,
                    "(P3) toggle during lockout",
                    s.program_state, s.effect_state, s.debounce_counter, pin_low);
    }

    if (r.next.effect_state != s.effect_state) {
        PROP_ASSERT(r.toggled == 1,
                    "(P4) effect_state changed without toggle flag",
                    s.program_state, s.effect_state, s.debounce_counter, pin_low);
    }

    if (s.program_state == RELEASE_DEBOUNCE_WAIT &&
        r.next.program_state == PRESS_DEBOUNCE_WAIT) {
        PROP_ASSERT(r.next.debounce_counter == 0,
                    "(P5) re-armed with nonzero counter",
                    s.program_state, s.effect_state, s.debounce_counter, pin_low);
    }

    if (!r.toggled) {
        int d = (int)r.next.debounce_counter - (int)s.debounce_counter;
        PROP_ASSERT(d >= -1 && d <= 1,
                    "(P6) counter moved by more than 1 without toggle",
                    s.program_state, s.effect_state, s.debounce_counter, pin_low);
    }
#endif
}

int main(void) {
#ifdef USE_KLEE
    // NOTE: klee_make_symbolic() must be given a whole top-level memory object
    // and its FULL size -- KLEE resolves the pointer to its underlying
    // allocation and rejects a size that doesn't match (you cannot make an
    // individual struct field symbolic piecemeal: passing &s.program_state with
    // sizeof(field) triggers "Wrong size given to klee_make_symbolic" because
    // the object KLEE finds is the whole `state_t s`). So mark standalone
    // scalars symbolic, then assemble the struct from them.
    uint8_t program_state;
    uint8_t effect_state;
    uint8_t debounce_counter;
    int     pin_low;
    klee_make_symbolic(&program_state,   sizeof program_state,   "program_state");
    klee_make_symbolic(&effect_state,    sizeof effect_state,    "effect_state");
    klee_make_symbolic(&debounce_counter,sizeof debounce_counter,"debounce_counter");
    klee_make_symbolic(&pin_low,         sizeof pin_low,         "pin_low");

    // Constrain to the invariant-valid domain. The model checker proves all
    // reachable states stay inside these ranges; CBMC separately proves corrupt
    // program-state fault handling and out-of-range counter integrator recovery.
    klee_assume(program_state <= RELEASE_DEBOUNCE_WAIT);
    klee_assume(effect_state  <= ENGAGED);
    klee_assume(debounce_counter <= RELEASE_THRESH);
    klee_assume(pin_low == 0 || pin_low == 1);

    state_t s = { program_state, effect_state, debounce_counter };
    check_step_properties(s, pin_low);
    return 0;
#else
    printf("symbolic single-step property check "
           "(PRESSED_THRESH=%d, RELEASE_THRESH=%d):\n",
           PRESSED_THRESH, RELEASE_THRESH);

    // Exhaustive enumeration over the same invariant-valid domain KLEE admits.
    // This includes every valid tuple, not only states reachable from power-on.
    // Corrupt program-state values and counters above RELEASE_THRESH are
    // deliberately outside this proof; CBMC's C2x and C7 harnesses cover fault
    // handling for the former and integrator recovery for the latter.
    long combos = 0;
    for (int ps = 0; ps <= RELEASE_DEBOUNCE_WAIT; ++ps) {
        for (int es = 0; es <= ENGAGED; ++es) {
            for (int dc = 0; dc <= (int)RELEASE_THRESH; ++dc) {
                for (int in = 0; in <= 1; ++in) {
                    state_t s = { (uint8_t)ps, (uint8_t)es, (uint8_t)dc };
                    check_step_properties(s, in);
                    combos++;
                }
            }
        }
    }

    printf("  enumerated %ld (state x input) combinations\n", combos);
    printf("symbolic step check: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
#endif
}
