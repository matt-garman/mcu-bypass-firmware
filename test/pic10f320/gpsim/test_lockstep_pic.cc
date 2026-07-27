// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// Silicon-level LOCK-STEP co-simulation: the REAL built HEX vs. the reference
// model, comparing the firmware's internal debounce state EVERY loop iteration.
//
// WHY THIS EXISTS (the gap it closes)
//   test-equiv already compares the firmware to the model tick-for-tick -- but it
//   runs the firmware *C source* on host gcc, NOT the XC8-compiled instruction
//   stream. On the real core, test-gpsim/test-fault-gpsim only check *settled*
//   register state at a few checkpoints. So the shipped HEX's per-tick debounce
//   trajectory (the exact ctx_ evolution the compiled code produces) is never
//   pinned against the model. This layer closes that: it drives the SAME footswitch
//   stimulus into the real HEX (in gpsim) and the model's step(), and after every
//   main-loop iteration asserts the firmware's live ctx_ SRAM
//   (program_state / effect_state / debounce_counter) matches the model's post-step
//   state. It is the child's analogue of the parent's simavr lock-step
//   (mcu-bypass-firmware test/avr/test_sim.c :: test_lockstep_cosim).
//
// WHAT IT PROVES -- and DELIBERATELY DOES NOT
//   It proves XC8 CODEGEN FIDELITY: the compiled instruction stream reproduces the
//   verified model's state trajectory. It does NOT re-prove the algorithm: the
//   oracle is the same model the firmware inlines, so a logic bug present in BOTH
//   (e.g. a threshold change in firmware AND model) cannot be caught here -- that
//   is the model's formal/host suite's job (test-host / test-model-check /
//   test-symbolic / test-cbmc) plus test-gpsim's independent hard-coded checkpoints.
//   Same boundary the parent documents (test_sim.c near test_minimum_press_toggles).
//
// HOW IT WORKS (the tick boundary on a POLLING core)
//   The parent's AVR firmware SLEEPS between ticks, so simavr keys tick boundaries
//   off cpu_Sleeping. The PIC firmware never sleeps -- it busy-polls TMR2IF -- so
//   there is no sleep signal. Instead we set a gpsim NOTIFY breakpoint at the main
//   loop's CLRWDT (the end-of-loop "pet the dog"): it fires once per completed loop
//   iteration, with ctx_ fully settled (post state-machine, post hw_set_*_state()).
//   That callback is the exact analogue of the host harness's CLRWDT hook
//   (test/equiv/fw_harness.c :: bypass_equiv_on_clrwdt): after the first callback
//   primes the pin, each callback reads ctx_, steps the model with the input just
//   consumed, compares, and presents the level the NEXT iteration will read.
//
//   Two subtleties, both confirmed empirically (a de-risk spike) and handled here:
//     1. There are two CLRWDT sites (init + loop). Their addresses are NOT ordered
//        (the loop one can be the LOWER address), so we identify the loop CLRWDT
//        BEHAVIOURALLY: after settle, only the loop CLRWDT keeps firing.
//     2. We lock-step on ITERATIONS, never on milliseconds. A toggling iteration
//        blocks ~13 ms in __delay_ms (relay/mute) yet is ONE model step; and the
//        TMR2IF latched during that delay makes the firmware run one extra immediate
//        iteration afterward. Driving one input per CLRWDT firing handles both for
//        free -- exactly as the host harness (one input per loop iteration) does.
//
// Build/run via the Makefile:  `make test-lockstep-gpsim`
//   Links libgpsim (needs gpsim-dev + libglib2.0-dev) and the reference model.
//   It is not part of development `make test`; individual invocation is
//   skip-clean, while regular CI's fail-closed `make test-target-variants`
//   aggregate runs it for every variant and requires its PASS marker.

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include <iostream>

#include <stdint.h>

#include <glib.h>                 // guint64
#include "interface.h"            // initialize_gpsim_core(), gpsim_set_bulk_mode()
#include "sim_context.h"          // CSimulationContext
#include "processor.h"            // Processor (pma, rma, run)
#include "pic-processor.h"        // pic_processor
#include "modules.h"              // Module::get_pin/get_pin_name/get_pin_count
#include "ioports.h"              // IOPIN
#include "stimuli.h"              // Stimulus_Node, source_stimulus
#include "gpsim_time.h"           // get_cycles()
#include "breakpoints.h"          // get_bp(), set_notify_break
#include "trigger.h"              // TriggerObject
#include "registers.h"            // Register::get_value()

// The reference model (shared with test-equiv / the formal proofs). C linkage:
// bypass_pure.c is compiled as C and linked in by the Makefile.
extern "C" {
#include "model_step.h"           // step(), state_t, RELEASE_THRESH/PRESSED_THRESH,
                                  // and (via bypass_pure.h) debounce_init_context()
                                  // + the program_state_t/effect_state_t enums.
}

// ---- Firmware / MCU parameters (injected by the Makefile build rule) --------
#ifndef FW_PATH
#  define FW_PATH  "build_pic/bypass_mcu_tq2-relay_pic10f320.hex"
#endif
#ifndef PROC_NAME
#  define PROC_NAME "p10f320"
#endif
#ifndef F_CPU_HZ
#  define F_CPU_HZ 2000000UL           // FOSC; instruction clock = FOSC/4
#endif
#ifndef CTX_ADDR
#  error "CTX_ADDR (the _ctx_ SRAM address from the XC8 .sym) must be passed by the Makefile"
#endif
#define CYCLES_PER_MS  ((F_CPU_HZ / 4UL) / 1000UL)   // 500 @ 2 MHz
#define CLRWDT_OPCODE  0x0064u                        // 14-bit enhanced-midrange CLRWDT
#define FOOTSW_PIN_NAME "ra3"

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
struct NullBuf : std::streambuf { int overflow(int c) override { return c; } };
static NullBuf g_nullbuf;

static pic_processor   *g_cpu      = nullptr;
static Stimulus_Node   *g_fsw_node = nullptr;
static source_stimulus *g_fsw_src  = nullptr;
static unsigned  g_checks  = 0;
static unsigned  g_fails   = 0;

// ---- Model-state coverage (BFS, ported from test/equiv/test_equiv.c) ---------
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
static IOPIN *find_pin(Module *m, const char *name) {
    for (int i = 1; i <= m->get_pin_count(); ++i) {
        std::string &pn = m->get_pin_name((unsigned)i);
        if (pn == name) return m->get_pin((unsigned)i);
    }
    return nullptr;
}
static void footsw_set(int pressed) {  // 1 = pressed (RA3 low), 0 = released (high)
    g_fsw_src->set_Vth(pressed ? 0.0 : 5.0);
    g_fsw_node->update();
}
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
    std::cout.rdbuf(&g_nullbuf);                 // silence gpsim console chatter
    initialize_gpsim_core();
    gpsim_set_bulk_mode(1);
    CSimulationContext *ctx = CSimulationContext::GetContext();

    Processor *p = nullptr;
    ctx->LoadProgram(FW_PATH, PROC_NAME, &p, "u1");
    if (p == nullptr) p = ctx->GetActiveCPU();
    if (p == nullptr) { fprintf(stderr, "FATAL: could not load %s on %s\n", FW_PATH, PROC_NAME); return 1; }
    g_cpu = static_cast<pic_processor *>(p);

    printf("LOCK-STEP START: fw=%s proc=%s FOSC=%lu ctx_=0x%03x iters=%u\n",
           FW_PATH, PROC_NAME, (unsigned long)F_CPU_HZ, (unsigned)CTX_ADDR, (unsigned)LOCKSTEP_ITERS);
    fflush(stdout);

    // Footswitch stimulus source on RA3.
    IOPIN *ra3 = find_pin(g_cpu, FOOTSW_PIN_NAME);
    if (ra3 == nullptr) { fprintf(stderr, "FATAL: pin %s not found\n", FOOTSW_PIN_NAME); return 1; }
    g_fsw_src = new source_stimulus();
    g_fsw_src->set_digital();
    g_fsw_src->set_Zth(250.0);                   // dominate RA3's weak pull-up
    g_fsw_src->set_Vth(5.0);                     // released at power-on
    g_fsw_node = new Stimulus_Node("fsw");
    g_fsw_node->attach_stimulus(g_fsw_src);
    g_fsw_node->attach_stimulus(ra3);

    // Power-on RELEASED + settle, so the anchor is the stable released init state.
    footsw_set(0);
    if (!run_ms(SETTLE_MS)) return 1;

    // Find CLRWDT sites, then identify the LOOP one behaviourally (only it keeps
    // firing after init settles; addresses are not reliably ordered).
    std::vector<ClrwdtHook *> hooks;
    for (unsigned a = 0; a < 0x200u; ++a) {
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
