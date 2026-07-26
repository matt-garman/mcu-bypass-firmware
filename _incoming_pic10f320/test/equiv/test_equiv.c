// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// Firmware<->model equivalence test.
//
// Proves that the REAL PIC10F320 firmware (run on the host via fw_harness.c)
// produces the EXACT same LED output AND internal state (program_state,
// effect_state, debounce_counter), tick for tick, as the vendored reference
// model (test/model/bypass_pure.c) for the same footswitch stimulus.
// This is what licenses the project's "correctness inherited by derivation"
// claim concretely: the firmware inlines the model's algorithm to fit flash, and
// this test pins that the inlining did not change behaviour. It also
// AUTOMATICALLY guards against the firmware and model debounce thresholds
// drifting apart -- a mismatch makes the traces diverge and fails here.
//
// Coverage:
//   - exhaustive: every footswitch bit-pattern of length EQUIV_EXHAUSTIVE_LEN
//     (so every bounce/spike pattern up to that horizon, from both power-on
//     states, is checked);
//   - randomized: many pseudo-random sequences of varied length and duty cycle,
//     long enough to exercise multiple toggles, the full release lock-out drain,
//     and re-arm.
//
// Output convention (both sides): the status-LED bit RA0 (LATA & 0x01) -- 0x00
// when BYPASS, 0x01 when ENGAGED. RA0 is the one output that means the same thing
// across every variant -- the per-variant output stage differs only in the
// RA1/RA2 control pins, never the LED; that variant-specific RA1/RA2 control
// pattern is asserted on real silicon by the gpsim test.
// Stimulus convention: 1 = pressed (RA3 low), 0 = released.

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bypass_config.h" // RELEASE_THRESH, PRESSED_THRESH (model side)
#include "model_step.h"    // step(), state_t, debounce_init_context(), enums

// Provided by fw_harness.c (the real firmware on the host).
extern void fw_run(const uint8_t *fsw, int n, uint8_t *trace);
extern uint8_t fw_tick_ps(int i);
extern uint8_t fw_tick_es(int i);
extern uint8_t fw_tick_dc(int i);
extern int fw_tick_state_count(void); // # ticks of internal state the harness captured for the last run

#ifndef EQUIV_EXHAUSTIVE_LEN
#define EQUIV_EXHAUSTIVE_LEN 18   // 2^18 = 262144 sequences
#endif
#ifndef EQUIV_RANDOM_SEQS
#define EQUIV_RANDOM_SEQS 4000
#endif
#ifndef EQUIV_RANDOM_MAXLEN
#define EQUIV_RANDOM_MAXLEN 1200  // > PRESSED_THRESH + RELEASE_THRESH for full cycles
#endif

static long g_compared = 0; // number of (stimulus) sequences compared
static long g_failures = 0;

//////////////////////////////////////////////////////////////////////////////
// Model-state coverage. The equivalence run proves the firmware matches the
// model only on the inputs it actually exercises -- and it is exhaustive only to
// EQUIV_EXHAUSTIVE_LEN ticks (shorter than one full press+lock-out cycle), with
// longer horizons sampled randomly. To make sure that sampling did not leave any
// reachable model state unexercised, we record which states the stimulus drives
// the model through and gate that EVERY reachable state was visited. (The model
// itself is proven exhaustively over all reachable states by test-model-check;
// this ties the equivalence run to that same state set.)
//////////////////////////////////////////////////////////////////////////////
#define COUNTER_VALUES ((int)RELEASE_THRESH + 1)
#define NUM_STATES     (2 * 2 * COUNTER_VALUES)

static int state_index(state_t s) {
    return (s.program_state * 2 + s.effect_state) * COUNTER_VALUES
           + s.debounce_counter;
}

static uint8_t g_state_seen[NUM_STATES];

static void mark_state_seen(state_t s) {
    int const idx = state_index(s);
    if (idx >= 0 && idx < NUM_STATES) { g_state_seen[idx] = 1u; }
}

// BFS the reachable state set from both power-on roots (the same roots and the
// same step() the equivalence compares against), then report how many reachable
// states the stimulus actually visited. Returns the count of reachable-but-
// unvisited states (0 == full coverage).
static int reachable_states_unvisited(void) {
    uint8_t reach[NUM_STATES];
    memset(reach, 0, sizeof reach);
    state_t stack[NUM_STATES];
    int sp = 0;
    state_t const roots[2] = {
        { PRESS_DEBOUNCE_WAIT,   BYPASS, 0 },
        { RELEASE_DEBOUNCE_WAIT, BYPASS, (uint8_t)RELEASE_THRESH },
    };
    for (int i = 0; i < 2; ++i) {
        int const idx = state_index(roots[i]);
        if (!reach[idx]) { reach[idx] = 1u; stack[sp++] = roots[i]; }
    }
    int reachable = 0, unvisited = 0;
    while (sp > 0) {
        state_t const s = stack[--sp];
        reachable++;
        if (!g_state_seen[state_index(s)]) {
            unvisited++;
            fprintf(stderr,
                "  state-coverage: reachable state ps=%u es=%u dc=%u never visited\n",
                s.program_state, s.effect_state, s.debounce_counter);
        }
        for (int bit = 0; bit < 2; ++bit) {
            step_result_t const r = step(s, bit);
            int const nidx = state_index(r.next);
            if (!reach[nidx]) { reach[nidx] = 1u; stack[sp++] = r.next; }
        }
    }
    printf("  state-coverage: %d/%d reachable model states visited by the stimulus\n",
           reachable - unvisited, reachable);
    return unvisited;
}

// Per-tick internal-state record, matching fw_harness.c's fw_internal_state_t
// layout. The model's state_t has the same fields in the same order, so the
// comparison in compare_one() is a direct field-by-field match.
typedef struct {
    uint8_t program_state;
    uint8_t effect_state;
    uint8_t debounce_counter;
} fw_state_t;

// The reference-model oracle: the same per-tick output trace and internal state
// the firmware should produce. init from fsw[0] (power-on level), then one
// step() per tick.
static void model_run(const uint8_t *fsw, int n, uint8_t *trace, fw_state_t *ms) {
    pin_state_t const p0 = fsw[0] ? PIN_STATE_LOW : PIN_STATE_HIGH;
    debounce_context_t const c = debounce_init_context(p0);
    state_t s = { (uint8_t)c.program_state, (uint8_t)c.effect_state, c.debounce_counter };
    mark_state_seen(s); // power-on state
    for (int i = 0; i < n; ++i) {
        step_result_t const r = step(s, fsw[i]);
        s = r.next;
        mark_state_seen(s);
        trace[i] = (uint8_t)((s.effect_state == ENGAGED) ? 0x01u : 0x00u);
        ms[i].program_state    = s.program_state;
        ms[i].effect_state     = s.effect_state;
        ms[i].debounce_counter = s.debounce_counter;
    }
}

// Compare one stimulus; report the first diverging tick on mismatch (LED output
// and internal state: program_state, effect_state, debounce_counter).
static int compare_one(const uint8_t *fsw, int n) {
    static uint8_t   fw_trace[EQUIV_RANDOM_MAXLEN];
    static uint8_t   md_trace[EQUIV_RANDOM_MAXLEN];
    static fw_state_t md_state[EQUIV_RANDOM_MAXLEN];
    fw_run(fsw, n, fw_trace);
    // Ticks for which the harness actually captured internal state (== min(n,
    // FW_TICK_TRACE_MAX)). Gating on the harness's own count -- rather than a
    // second hardcoded window -- means the internal-state comparison automatically
    // spans as far as the harness records, with no constant to keep in sync. The
    // capacity self-check in main() guarantees this covers the full stimulus.
    int const state_n = fw_tick_state_count();
    model_run(fsw, n, md_trace, md_state);
    g_compared++;
    for (int i = 0; i < n; ++i) {
        if (fw_trace[i] != md_trace[i]) {
            g_failures++;
            fprintf(stderr,
                "FAIL: LED divergence at tick %d/%d: firmware LED(RA0)=%u, model=%u\n",
                i, n, fw_trace[i], md_trace[i]);
            int lo = i - 6; if (lo < 0) { lo = 0; }
            fprintf(stderr, "  stimulus[%d..%d] (1=pressed): ", lo, i);
            for (int k = lo; k <= i; ++k) { fprintf(stderr, "%d", fsw[k]); }
            fprintf(stderr, "\n");
            return 1;
        }
        if (i < state_n &&
            (fw_tick_ps(i) != md_state[i].program_state ||
             fw_tick_es(i) != md_state[i].effect_state  ||
             fw_tick_dc(i) != md_state[i].debounce_counter)) {
            g_failures++;
            fprintf(stderr,
                "FAIL: internal-state divergence at tick %d/%d: "
                "fw(ps=%u es=%u dc=%u) model(ps=%u es=%u dc=%u)\n",
                i, n,
                fw_tick_ps(i), fw_tick_es(i), fw_tick_dc(i),
                md_state[i].program_state, md_state[i].effect_state,
                md_state[i].debounce_counter);
            int lo = i - 6; if (lo < 0) { lo = 0; }
            fprintf(stderr, "  stimulus[%d..%d] (1=pressed): ", lo, i);
            for (int k = lo; k <= i; ++k) { fprintf(stderr, "%d", fsw[k]); }
            fprintf(stderr, "\n");
            return 1;
        }
    }
    return 0;
}

// xorshift32: small reproducible PRNG.
static uint32_t xorshift32(uint32_t *st) {
    uint32_t x = *st; x ^= x << 13; x ^= x >> 17; x ^= x << 5; *st = x; return x;
}

static void run_exhaustive(void) {
    enum { L = EQUIV_EXHAUSTIVE_LEN };
    static uint8_t fsw[L];
    unsigned long const combos = 1UL << L;
    for (unsigned long pat = 0; pat < combos; ++pat) {
        for (int b = 0; b < L; ++b) { fsw[b] = (uint8_t)((pat >> b) & 1UL); }
        if (compare_one(fsw, L)) { return; } // stop at first divergence
    }
    printf("  exhaustive: %lu sequences of length %d : OK\n", combos, L);
}

static void run_random(void) {
    static uint8_t fsw[EQUIV_RANDOM_MAXLEN];
    uint32_t rng = 0xC0FFEEu;
    for (long s = 0; s < EQUIV_RANDOM_SEQS; ++s) {
        int n = (int)(1u + (xorshift32(&rng) % (EQUIV_RANDOM_MAXLEN)));
        // Vary the duty cycle so some seqs hold long (toggles), others chatter.
        uint32_t thresh = (xorshift32(&rng) % 256u);
        for (int i = 0; i < n; ++i) {
            fsw[i] = (uint8_t)((xorshift32(&rng) & 0xFFu) < thresh);
        }
        if (compare_one(fsw, n)) { return; }
    }
    printf("  randomized: %d sequences (len<=%d, varied duty) : OK\n",
           EQUIV_RANDOM_SEQS, EQUIV_RANDOM_MAXLEN);
}

int main(void) {
    printf("firmware<->model equivalence (PRESSED_THRESH=%u, RELEASE_THRESH=%u):\n",
           (unsigned)PRESSED_THRESH, (unsigned)RELEASE_THRESH);

    // Capacity self-check: the harness captures per-tick internal state only up to
    // its buffer size (FW_TICK_TRACE_MAX). If that is smaller than the longest
    // stimulus we run, ticks beyond it would silently fall back to LED-only
    // comparison -- exactly the gap this internal-state trace closes. Drive one
    // full-horizon stimulus and confirm the harness recorded state for every tick;
    // fail loudly (not silently) if the buffer is too small.
    {
        static uint8_t probe[EQUIV_RANDOM_MAXLEN];
        static uint8_t probe_trace[EQUIV_RANDOM_MAXLEN];
        memset(probe, 0, sizeof probe); // all-released: valid stimulus, no fault path
        fw_run(probe, EQUIV_RANDOM_MAXLEN, probe_trace);
        if (fw_tick_state_count() < EQUIV_RANDOM_MAXLEN) {
            fprintf(stderr,
                "FAIL: harness internal-state capture (%d ticks) < equivalence horizon "
                "(%d); long sequences would compare LED only. Raise FW_TICK_TRACE_MAX "
                "in test/equiv/fw_harness.c to >= EQUIV_RANDOM_MAXLEN.\n",
                fw_tick_state_count(), EQUIV_RANDOM_MAXLEN);
            return 1;
        }
        printf("  internal-state capture spans the full %d-tick horizon\n",
               EQUIV_RANDOM_MAXLEN);
    }

    run_exhaustive();
    if (g_failures == 0) { run_random(); }
    printf("equivalence: %ld sequences compared, %ld divergence(s)\n",
           g_compared, g_failures);

    // Gate: the stimulus above must have driven the model through every
    // reachable state, so no reachable state is left unverified by equivalence.
    if (reachable_states_unvisited() != 0) {
        fprintf(stderr, "FAIL: equivalence stimulus did not visit every reachable "
                        "model state (see above)\n");
        g_failures++;
    }
    return g_failures ? 1 : 0;
}
