// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// Silicon-level lock-step co-simulation: the real built PIC HEX vs. the shared
// reference model, comparing firmware ctx_ state after every completed main-loop
// iteration. This is the PIC analogue of the AVR simavr lock-step coverage.

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include <iostream>

#include <stdint.h>

#include <glib.h>
#include "interface.h"
#include "sim_context.h"
#include "processor.h"
#include "pic-processor.h"
#include "modules.h"
#include "ioports.h"
#include "stimuli.h"
#include "gpsim_time.h"
#include "breakpoints.h"
#include "trigger.h"
#include "registers.h"

extern "C" {
#include "model_step.h"
}

#ifndef FW_PATH
#  define FW_PATH "build_pic/bypass_relay_pic10f322.hex"
#endif
#ifndef PROC_NAME
#  define PROC_NAME "p10f322"
#endif
#ifndef F_CPU_HZ
#  define F_CPU_HZ 2000000UL
#endif
#ifndef CTX_ADDR
#  error "CTX_ADDR (the _ctx_ SRAM address from the XC8 .sym) must be passed by the Makefile"
#endif

#define CYCLES_PER_MS  ((F_CPU_HZ / 4UL) / 1000UL)
#define CLRWDT_OPCODE  0x0064u
#define FOOTSW_PIN_NAME "ra3"

#define CTX_PS  ((unsigned)(CTX_ADDR) + 0u)
#define CTX_ES  ((unsigned)(CTX_ADDR) + 1u)
#define CTX_DC  ((unsigned)(CTX_ADDR) + 2u)

#define SETTLE_MS 30u
#define CALIB_MS  8u

#ifndef LOCKSTEP_ITERS
#  define LOCKSTEP_ITERS 3000u
#endif

struct NullBuf : std::streambuf { int overflow(int c) override { return c; } };
static NullBuf g_nullbuf;

static pic_processor   *g_cpu      = nullptr;
static Stimulus_Node   *g_fsw_node = nullptr;
static source_stimulus *g_fsw_src  = nullptr;
static unsigned  g_checks  = 0;
static unsigned  g_fails   = 0;

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

static IOPIN *find_pin(Module *m, const char *name) {
    for (int i = 1; i <= m->get_pin_count(); ++i) {
        std::string &pn = m->get_pin_name((unsigned)i);
        if (pn == name) return m->get_pin((unsigned)i);
    }
    return nullptr;
}

static void footsw_set(int pressed) {
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

static void run_ms(unsigned ms) {
    guint64 target = get_cycles().get() + (guint64)ms * CYCLES_PER_MS;
    get_cycles().set_break(target);
    int resumes = 0;
    while (get_cycles().get() < target) {
        g_cpu->run(false);
        if (++resumes > 4096) {
            fprintf(stderr, "FATAL: core not advancing (wedged?)\n");
            return;
        }
    }
}

enum Phase { PHASE_CALIB, PHASE_LOCKSTEP };
static Phase   g_phase     = PHASE_CALIB;
static unsigned g_loop_addr = 0;

static std::vector<uint8_t> g_stim;
static size_t   g_i         = 0;
static state_t  g_model;
static bool     g_done      = false;
static unsigned g_toggles   = 0;
static unsigned g_mismatch  = 0;

static bool g_primed = false;

static void lockstep_on_iteration(void) {
    if (g_done) return;

    // Phase sync. Until this point the footswitch is still held at the settled
    // anchor level (released) that init_state()/fw_ctx() were captured at, so the
    // firmware and model are both quiescent at the anchor and no stimulus has been
    // applied yet. Consume this first CLRWDT hit as a clean loop boundary: apply
    // g_stim[0] here (no compare, no model step) so the NEXT iteration samples it
    // exactly once before its own CLRWDT -- identical to how every later
    // footsw_set() below is issued at the boundary. Applying the first stimulus at
    // a real loop boundary (rather than at an arbitrary PC outside the loop) makes
    // the initial alignment independent of the variant's startup timing -- e.g.
    // the relay driver's ~5 ms power-on coil pulse, which otherwise shifts the
    // sample phase and lagged the firmware one stimulus sample behind the model.
    if (!g_primed) {
        g_primed = true;
        footsw_set(g_stim[0]);
        return;
    }

    state_t fw = fw_ctx();
    step_result_t r = step(g_model, g_stim[g_i]);
    g_model = r.next;
    if (r.toggled) g_toggles++;
    mark_state_seen(g_model);

    g_checks++;
    if (!state_eq(fw, g_model)) {
        if (g_mismatch < 5u) {
            fprintf(stderr,
                "FAIL: lock-step divergence at iter %zu (in=%u): "
                "fw(ps=%u es=%u dc=%u) != model(ps=%u es=%u dc=%u)\n",
                g_i, (unsigned)g_stim[g_i], fw.program_state, fw.effect_state,
                fw.debounce_counter, g_model.program_state, g_model.effect_state,
                g_model.debounce_counter);
        }
        g_fails++;
        g_mismatch++;
    }

    g_i++;
    if (g_i < g_stim.size()) {
        footsw_set(g_stim[g_i]);
    } else {
        g_done = true;
    }
}

struct ClrwdtHook : public TriggerObject {
    unsigned addr;
    long     hits = 0;
    explicit ClrwdtHook(unsigned a) : addr(a) {}
    void callback() override {
        if (g_phase == PHASE_CALIB) { hits++; return; }
        if (addr != g_loop_addr)    return;
        lockstep_on_iteration();
    }
};

static uint32_t xorshift32(uint32_t *st) {
    uint32_t x = *st; x ^= x << 13; x ^= x >> 17; x ^= x << 5; *st = x; return x;
}

static void build_stimulus(void) {
    auto push = [](int level, unsigned n) { for (unsigned k = 0; k < n; ++k) g_stim.push_back((uint8_t)level); };
    push(1, 12);
    push(0, 30);
    push(1, 12);
    push(0, 30);
    push(1, 3);
    push(0, 10);
    uint32_t rng = 0xC051A1EDu;
    while (g_stim.size() < (size_t)LOCKSTEP_ITERS) {
        int level = ((xorshift32(&rng) & 0xFFu) < 128u) ? 1 : 0;
        unsigned hold = 1u + (xorshift32(&rng) % 30u);
        push(level, hold);
    }
    g_stim.resize((size_t)LOCKSTEP_ITERS);
}

int main() {
    std::cout.rdbuf(&g_nullbuf);
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

    IOPIN *ra3 = find_pin(g_cpu, FOOTSW_PIN_NAME);
    if (ra3 == nullptr) { fprintf(stderr, "FATAL: pin %s not found\n", FOOTSW_PIN_NAME); return 1; }
    g_fsw_src = new source_stimulus();
    g_fsw_src->set_digital();
    g_fsw_src->set_Zth(250.0);
    g_fsw_src->set_Vth(5.0);
    g_fsw_node = new Stimulus_Node("fsw");
    g_fsw_node->attach_stimulus(g_fsw_src);
    g_fsw_node->attach_stimulus(ra3);

    footsw_set(0);
    run_ms(SETTLE_MS);

    std::vector<ClrwdtHook *> hooks;
    for (unsigned a = 0; a < 0x200u; ++a) {
        if (g_cpu->pma->get_opcode(a) == CLRWDT_OPCODE) {
            ClrwdtHook *h = new ClrwdtHook(a);
            hooks.push_back(h);
            get_bp().set_notify_break(g_cpu, a, h);
        }
    }
    g_phase = PHASE_CALIB;
    run_ms(CALIB_MS);
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

    build_stimulus();
    g_phase = PHASE_LOCKSTEP;
    g_i = 0; g_done = false;
    // Do NOT drive g_stim[0] here: the footswitch stays at the settled anchor
    // level until the first lockstep callback applies g_stim[0] at a clean loop
    // boundary (see lockstep_on_iteration's priming step), which keeps the
    // initial phase alignment independent of variant startup timing.
    guint64 hardcap_ms = (guint64)LOCKSTEP_ITERS * 3u + 2000u;
    guint64 t0 = get_cycles().get();
    while (!g_done && (get_cycles().get() - t0) < hardcap_ms * CYCLES_PER_MS) {
        run_ms(50);
    }
    g_checks++;
    if (!g_done) {
        g_fails++;
        fprintf(stderr, "FAIL: lock-step did not complete %u iters within budget\n",
                (unsigned)LOCKSTEP_ITERS);
    }

    g_checks++;
    if (g_toggles < 5u) {
        g_fails++;
        fprintf(stderr, "FAIL: stimulus exercised only %u toggles (want >=5)\n", g_toggles);
    }
    g_checks++;
    if (reachable_states_unvisited() != 0) {
        g_fails++;
        fprintf(stderr, "FAIL: stimulus left reachable model states unvisited\n");
    }

    printf("  lock-step: %zu iterations compared, %u toggles, %u mismatches\n",
           g_i, g_toggles, g_mismatch);
    int pass = (g_fails == 0);
    printf("LOCK-STEP %s: %u checks, %u failures\n", pass ? "PASS" : "FAIL", g_checks, g_fails);
    return pass ? 0 : 1;
}
