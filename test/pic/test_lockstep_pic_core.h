// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// Include-only silicon-level lock-step co-simulation shared by the PIC part
// adapters: the real built HEX vs. the reference model, comparing the
// firmware's internal debounce state EVERY loop iteration.
//
// WHY THIS EXISTS (the gap it closes)
//   Host equivalence runs C source rather than the XC8-compiled instruction
//   stream, while checkpoint tests observe only selected settled states. This
//   layer drives the same footswitch stimulus into the real HEX and model step(),
//   then compares live ctx_ SRAM after every completed main-loop iteration.
//
// WHAT IT PROVES -- and DELIBERATELY DOES NOT
//   Every adapter proves XC8 code-generation and integration fidelity for its
//   part. PIC10F320 additionally checks its hand-inlined constrained
//   implementation against the shared pure core; PIC10F322 and PIC12F675 call
//   that core directly, from two different core families and two different
//   shells. This does not re-prove the algorithm, so the independent formal,
//   host, and checkpoint layers remain necessary.
//
// HOW IT WORKS (the tick boundary on a POLLING core)
//   The PIC firmware never sleeps -- it busy-polls the tick flag -- so there is
//   no sleep signal. Instead we set a gpsim NOTIFY breakpoint at the main
//   loop's CLRWDT (the end-of-loop "pet the dog"): it fires once per completed loop
//   iteration, with ctx_ fully settled (post state-machine, post hw_set_*_state()).
//   That callback is the exact analogue of the host harness's CLRWDT hook
//   (test/pic10f320/equiv/fw_harness.c :: bypass_equiv_on_clrwdt): after the first callback
//   primes the pin, each callback reads ctx_, steps the model with the input just
//   consumed, compares, and presents the level the NEXT iteration will read.
//
//   Two subtleties, both confirmed empirically (a de-risk spike) and handled here:
//     1. There are two CLRWDT sites (init + loop). Their addresses are NOT ordered
//        (the loop one can be the LOWER address), so we identify the loop CLRWDT
//        BEHAVIOURALLY: after settle, only the loop CLRWDT keeps firing.
//     2. We lock-step on ITERATIONS, never on milliseconds. A toggling iteration
//        blocks ~13 ms in __delay_ms (relay/mute) yet is ONE model step; and the
//        tick flag latched during that delay makes the firmware run one extra
//        immediate iteration afterward. Driving one input per CLRWDT firing handles both for
//        free -- exactly as the host harness (one input per loop iteration) does.
//
// Build/run via `make pic10f322-test-lockstep`, `make pic10f320-test-lockstep`
// or `make pic12f675-test-lockstep`. The fail-closed target-variant aggregates
// run the matching adapter for every image and require its PASS marker.

#ifndef TEST_PIC_TEST_LOCKSTEP_PIC_CORE_H
#define TEST_PIC_TEST_LOCKSTEP_PIC_CORE_H

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include <iostream>

#include <stdint.h>

#include <glib.h>                 // guint64
#include "processor.h"            // Processor (pma, rma, run)
#include "pic-processor.h"        // pic_processor
#include "gpsim_time.h"           // get_cycles()
#include "breakpoints.h"          // get_bp(), set_notify_break
#include "trigger.h"              // TriggerObject
#include "registers.h"            // Register::get_value()

// gpsim bring-up shared with the io / fault / soak harnesses: NullBuf,
// g_cpu / g_fsw_node / g_fsw_src, FOOTSW_PIN_NAME, gpsim_bootstrap_cpu(),
// gpsim_attach_footswitch() and footsw_set().
#include "pic/gpsim_bootstrap.h"

// The reference model (shared with test-equiv / the formal proofs). C linkage:
// bypass_pure.c is compiled as C and linked in by the Makefile.
extern "C" {
#include "model_step.h"           // step(), state_t, RELEASE_THRESH/PRESSED_THRESH,
                                  // and (via bypass_pure.h) debounce_init_context()
                                  // + the program_state_t/effect_state_t enums.
}

// ---- Firmware / MCU parameters (injected by the Makefile build rule) --------
#ifndef PIC_LOCKSTEP_DEFAULT_PROC_NAME
#  error "PIC_LOCKSTEP_DEFAULT_PROC_NAME must be defined by the part adapter"
#endif
// Program-space size in words, for the CLRWDT site scan below. A part fact --
// it was hard-coded to the PIC10F322's 0x200 while both consumers happened to
// fit inside it, which silently over-scanned the 256-word PIC10F320 and would
// silently UNDER-scan any larger part, hiding its loop CLRWDT entirely. The
// 1024-word PIC12F675 is that larger part: half its program space sits above
// the old constant.
#ifndef PIC_LOCKSTEP_PROGRAM_WORDS
#  error "PIC_LOCKSTEP_PROGRAM_WORDS must be defined by the part adapter"
#endif
// FW_PATH names an output STAGE, which the Makefile selects per run -- unlike
// PROC_NAME below, which names the PART and so is legitimately the adapter's to
// default. An adapter default for FW_PATH looked like the same thing and was
// not: it is per-part correct and per-variant wrong, so a severed injection
// tested one output stage while the run reported another.
#ifndef FW_PATH
#  error "FW_PATH must be injected: -DFW_PATH from PIC10F322_LOCKSTEP_HEX, PIC10F320_LOCKSTEP_HEX or PIC12F675_LOCKSTEP_HEX"
#endif
#ifndef PROC_NAME
#  define PROC_NAME PIC_LOCKSTEP_DEFAULT_PROC_NAME
#endif
// FOSC; instruction clock = FOSC/4. A part fact, and NOT a shared one: the two
// 10F32x parts run at 2 MHz and the PIC12F675 at 4 MHz. Even when values
// coincide a default here would be a hazard -- re-pin one chip's XTAL and the
// harness goes on simulating the other's.
#ifndef F_CPU_HZ
#  error "F_CPU_HZ must be injected: -DF_CPU_HZ from PIC10F322_XTAL, PIC10F320_XTAL or PIC12F675_XTAL"
#endif
#ifndef CTX_ADDR
#  error "CTX_ADDR (the _ctx_ SRAM address from the XC8 .sym) must be passed by the Makefile"
#endif
#define CYCLES_PER_MS  ((F_CPU_HZ / 4UL) / 1000UL)   // 500 @ 2 MHz, 1000 @ 4 MHz
// CLRWDT is the same 14-bit encoding on the classic and enhanced mid-range
// cores, so this is genuinely shared rather than a family fact.
#define CLRWDT_OPCODE  0x0064u
#define PROGRAM_WORDS  PIC_LOCKSTEP_PROGRAM_WORDS

// ctx_ field offsets (struct order; each a 1-byte object -- the Makefile asserts
// `_ctx_: ds 3` in the .s, so these offsets are pinned).
#define CTX_PS  ((unsigned)(CTX_ADDR) + 0u)
#define CTX_ES  ((unsigned)(CTX_ADDR) + 1u)
#define CTX_DC  ((unsigned)(CTX_ADDR) + 2u)

// Settle after power-on: exceed init()'s worst-case blocking bypass pulse (relay
// 12 ms) so the core is quiescent in the poll loop before we calibrate/anchor.
#define SETTLE_MS 30u
// Calibration window (released, so the debounce state does not change): long
// enough that the loop CLRWDT fires several times and self-identifies.
#define CALIB_MS  8u

// Number of lock-step iterations (footswitch inputs). Modest by default; crank via
// -D for a longer sweep. gpsim runs the shared debounce path fast.
#ifndef LOCKSTEP_ITERS
#  define LOCKSTEP_ITERS 3000u
#endif

// ---- Sim globals ------------------------------------------------------------
// NullBuf/g_nullbuf and g_cpu / g_fsw_node / g_fsw_src come from
// pic/gpsim_bootstrap.h.
static unsigned  g_checks  = 0;
static unsigned  g_fails   = 0;

// ---- Model-state coverage (BFS, ported from test/pic10f320/equiv/test_equiv.c) ---------
#define COUNTER_VALUES ((int)RELEASE_THRESH + 1)
#define NUM_STATES     (2 * 2 * COUNTER_VALUES)
static uint8_t g_state_seen[NUM_STATES];

static int state_index(state_t s) {
    return (s.program_state * 2 + s.effect_state) * COUNTER_VALUES + s.debounce_counter;
}
static void mark_state_seen(state_t s) {
    int const idx = state_index(s);
    if (idx >= 0 && idx < NUM_STATES) g_state_seen[idx] = 1u;
}
// BFS the reachable state set from both power-on roots (same roots + step() the
// lock-step compares against); return the count of reachable-but-unvisited states.
static int reachable_states_unvisited(void) {
    uint8_t reach[NUM_STATES];
    memset(reach, 0, sizeof reach);
    state_t stack[NUM_STATES];
    int sp = 0;
    state_t const roots[2] = {
        { (uint8_t)PRESS_DEBOUNCE_WAIT,   (uint8_t)BYPASS, 0 },
        { (uint8_t)RELEASE_DEBOUNCE_WAIT, (uint8_t)BYPASS, (uint8_t)RELEASE_THRESH },
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
            fprintf(stderr, "  coverage: reachable state ps=%u es=%u dc=%u never visited\n",
                    s.program_state, s.effect_state, s.debounce_counter);
        }
        for (int bit = 0; bit < 2; ++bit) {
            step_result_t const r = step(s, bit);
            int const nidx = state_index(r.next);
            if (!reach[nidx]) { reach[nidx] = 1u; stack[sp++] = r.next; }
        }
    }
    printf("  coverage: %d/%d reachable model states visited by the stimulus\n",
           reachable - unvisited, reachable);
    return unvisited;
}

// ---- Helpers ----------------------------------------------------------------
// footsw_set() comes from pic/gpsim_bootstrap.h.
static uint8_t rd(unsigned addr) {
    Register *r = g_cpu->rma.get_register(addr);
    return r ? (uint8_t)r->get_value() : 0xFFu;
}
static state_t fw_ctx(void) {
    state_t s = { rd(CTX_PS), rd(CTX_ES), rd(CTX_DC) };
    return s;
}
static state_t init_state(int pin_low) {
    debounce_context_t const c = debounce_init_context(pin_low ? PIN_STATE_LOW : PIN_STATE_HIGH);
    state_t s = { (uint8_t)c.program_state, (uint8_t)c.effect_state, c.debounce_counter };
    return s;
}
static int state_eq(state_t a, state_t b) {
    return a.program_state == b.program_state && a.effect_state == b.effect_state
        && a.debounce_counter == b.debounce_counter;
}
// Advance simulated time by `ms`, letting notify callbacks fire during the run.
static bool run_ms(unsigned ms) {
    guint64 target = get_cycles().get() + (guint64)ms * CYCLES_PER_MS;
    get_cycles().set_break(target);
    int resumes = 0;
    while (get_cycles().get() < target) {
        g_cpu->run(false);
        if (++resumes > 4096) {
            fprintf(stderr, "FATAL: core not advancing (wedged?)\n");
            get_cycles().clear_break(target);
            return false;
        }
    }
    return true;
}

// ---- The per-iteration hook (analogue of the host CLRWDT hook) --------------
enum Phase { PHASE_CALIB, PHASE_LOCKSTEP };
static Phase   g_phase     = PHASE_CALIB;
static unsigned g_loop_addr = 0;

// Lock-step stimulus + running model state.
static std::vector<uint8_t> g_stim;   // per-iteration footswitch: 1=pressed
static size_t   g_i         = 0;     // next stimulus index to APPLY to the pin
static size_t   g_applied   = 0;     // stimulus index now on the pin (just integrated)
static bool     g_primed    = false; // false until the first pin value is applied
static size_t   g_compared  = 0;     // number of lock-step comparisons performed
static state_t  g_model;             // running model state (post last step)
static bool     g_done      = false;
static unsigned g_toggles   = 0;
static unsigned g_mismatch  = 0;

// Called at every loop CLRWDT during PHASE_LOCKSTEP. The firmware samples the
// footswitch at the top of each main-loop iteration and reaches CLRWDT at the
// bottom, so the ctx_ read here reflects the pin value applied at the previous
// CLRWDT. Compare that consumed input first, then apply the next input for the
// iteration about to run. The first callback only primes stimulus[0].
static void lockstep_on_iteration(void) {
    if (g_done) return;

    if (g_primed) {
        state_t fw = fw_ctx();
        step_result_t r = step(g_model, g_stim[g_applied]);
        g_model = r.next;
        if (r.toggled) g_toggles++;
        mark_state_seen(g_model);

        g_checks++;
        g_compared++;
        if (!state_eq(fw, g_model)) {
            if (g_mismatch < 5u) {
                fprintf(stderr,
                    "FAIL: lock-step divergence at iter %zu (in=%u): "
                    "fw(ps=%u es=%u dc=%u) != model(ps=%u es=%u dc=%u)\n",
                    g_applied, (unsigned)g_stim[g_applied], fw.program_state,
                    fw.effect_state, fw.debounce_counter, g_model.program_state,
                    g_model.effect_state, g_model.debounce_counter);
            }
            g_fails++;
            g_mismatch++;
        }
    }

    if (g_i < g_stim.size()) {
        footsw_set(g_stim[g_i]);
        g_applied = g_i;
        g_i++;
        g_primed = true;
    } else {
        g_done = true;
    }
}

// A CLRWDT notify: counts hits during calibration; runs the lock-step during the
// main phase (only for the identified loop CLRWDT).
struct ClrwdtHook : public TriggerObject {
    unsigned addr;
    long     hits = 0;
    explicit ClrwdtHook(unsigned a) : addr(a) {}
    void callback() override {
        if (g_phase == PHASE_CALIB) { hits++; return; }
        if (addr != g_loop_addr)    return;      // ignore init's CLRWDT (resets, etc.)
        lockstep_on_iteration();
    }
};

// ---- Stimulus: directed warm-up (guarantees both toggle directions + a full
// lock-out drain + partial counts) followed by a random hold-based stream, sized
// to LOCKSTEP_ITERS. Wide + long enough to visit every reachable model state.
static uint32_t xorshift32(uint32_t *st) {
    uint32_t x = *st; x ^= x << 13; x ^= x >> 17; x ^= x << 5; *st = x; return x;
}
static void build_stimulus(void) {
    auto push = [](int level, unsigned n) { for (unsigned k = 0; k < n; ++k) g_stim.push_back((uint8_t)level); };
    // Directed: engage, drain lock-out, engage back to bypass, drain again.
    push(1, 12);   // press -> cross PRESSED_THRESH -> ENGAGED (visits press counts + toggle)
    push(0, 30);   // release -> drain RELEASE_THRESH -> re-armed (visits RELEASE_WAIT/ENGAGED drain)
    push(1, 12);   // press -> toggle back to BYPASS (visits press-under-ENGAGED + toggle)
    push(0, 30);   // release -> drain (visits RELEASE_WAIT/BYPASS drain)
    push(1, 3);    // sub-threshold spike (partial press count)
    push(0, 10);   // relax
    // Random hold-based stream (~50% duty, holds up to 30 ticks so presses cross
    // PRESSED_THRESH and releases cross RELEASE_THRESH) fills the rest.
    uint32_t rng = 0xC051A1EDu;
    while (g_stim.size() < (size_t)LOCKSTEP_ITERS) {
        int level = ((xorshift32(&rng) & 0xFFu) < 128u) ? 1 : 0;
        unsigned hold = 1u + (xorshift32(&rng) % 30u);
        push(level, hold);
    }
    g_stim.resize((size_t)LOCKSTEP_ITERS);
}

int main() {
    if (!gpsim_bootstrap_cpu(FW_PATH, PROC_NAME)) return 1;

    printf("LOCK-STEP START: fw=%s proc=%s FOSC=%lu ctx_=0x%03x iters=%u\n",
           FW_PATH, PROC_NAME, (unsigned long)F_CPU_HZ, (unsigned)CTX_ADDR, (unsigned)LOCKSTEP_ITERS);
    fflush(stdout);

    // Footswitch stimulus source (FOOTSW_PIN_NAME, per part).
    if (!gpsim_attach_footswitch(FOOTSW_PIN_NAME, PROC_NAME)) return 1;

    // Power-on RELEASED + settle, so the anchor is the stable released init state.
    footsw_set(0);
    if (!run_ms(SETTLE_MS)) return 1;

    // Find CLRWDT sites, then identify the LOOP one behaviourally (only it keeps
    // firing after init settles; addresses are not reliably ordered).
    std::vector<ClrwdtHook *> hooks;
    for (unsigned a = 0; a < PROGRAM_WORDS; ++a) {
        if (g_cpu->pma->get_opcode(a) == CLRWDT_OPCODE) {
            ClrwdtHook *h = new ClrwdtHook(a);
            hooks.push_back(h);
            get_bp().set_notify_break(g_cpu, a, h);
        }
    }
    g_phase = PHASE_CALIB;
    if (!run_ms(CALIB_MS)) return 1;
    long best = -1;
    for (ClrwdtHook *h : hooks) {
        if (h->hits > best) { best = h->hits; g_loop_addr = h->addr; }
    }
    g_checks++;
    if (hooks.empty() || best < (long)(CALIB_MS / 2u)) {
        g_fails++;
        fprintf(stderr, "FAIL: could not identify the loop CLRWDT (%zu sites, max %ld hits in %u ms)\n",
                hooks.size(), best, CALIB_MS);
        printf("LOCK-STEP FAIL: %u checks, %u failures\n", g_checks, g_fails);
        return 1;
    }
    printf("  loop CLRWDT identified at 0x%03x (%ld hits in %u ms; %zu CLRWDT sites total)\n",
           g_loop_addr, best, CALIB_MS, hooks.size());

    // Anchor: after the released settle, the firmware ctx_ must equal the model's
    // released power-on state before a single stimulus step is applied.
    g_model = init_state(0);
    mark_state_seen(g_model);
    {
        state_t fw = fw_ctx();
        g_checks++;
        if (!state_eq(fw, g_model)) {
            g_fails++;
            fprintf(stderr, "FAIL: anchor mismatch: fw(ps=%u es=%u dc=%u) model(ps=%u es=%u dc=%u)\n",
                    fw.program_state, fw.effect_state, fw.debounce_counter,
                    g_model.program_state, g_model.effect_state, g_model.debounce_counter);
        }
    }

    // Leave the pin RELEASED through the anchor. The first lock-step CLRWDT
    // applies stimulus[0] at a fresh iteration boundary instead of dropping it
    // when calibration happened to pause after the loop's input sample.
    build_stimulus();
    g_phase = PHASE_LOCKSTEP;
    g_i = 0; g_applied = 0; g_primed = false; g_compared = 0; g_done = false;
    guint64 hardcap_ms = (guint64)LOCKSTEP_ITERS * 3u + 2000u; // generous
    guint64 t0 = get_cycles().get();
    while (!g_done && (get_cycles().get() - t0) < hardcap_ms * CYCLES_PER_MS) {
        if (!run_ms(50)) return 1;
    }
    g_checks++;
    if (!g_done) { g_fails++; fprintf(stderr, "FAIL: lock-step did not complete %u iters within budget\n",
                                     (unsigned)LOCKSTEP_ITERS); }

    // Sanity: the stimulus must actually have exercised toggles, and every
    // reachable model state must have been visited (no lucky-sample blind spots).
    g_checks++;
    if (g_toggles < 5u) { g_fails++; fprintf(stderr, "FAIL: stimulus exercised only %u toggles (want >=5)\n", g_toggles); }
    g_checks++;
    if (reachable_states_unvisited() != 0) { g_fails++; fprintf(stderr, "FAIL: stimulus left reachable model states unvisited\n"); }

    printf("  lock-step: %zu iterations compared, %u toggles, %u mismatches\n",
           g_compared, g_toggles, g_mismatch);
    int pass = (g_fails == 0);
    printf("LOCK-STEP %s: %u checks, %u failures\n", pass ? "PASS" : "FAIL", g_checks, g_fails);
    return pass ? 0 : 1;
}

#endif
