// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// Built-HEX GPIO transition and pulse-timing test. Unlike the host actuation
// harness, this observes the XC8-generated instruction stream in libgpsim. It
// checks exact distinct LATA states, ordering, physical PORTA output levels, and
// delay between pulse edges in simulator instruction cycles. The timing
// assertion validates code generation at the configured FOSC; it does not
// validate oscillator tolerance on real silicon.

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <string>
#include <vector>
#include <iostream>

#include <glib.h>
#include "interface.h"
#include "sim_context.h"
#include "processor.h"
#include "pic-processor.h"
#include "modules.h"
#include "ioports.h"
#include "stimuli.h"
#include "gpsim_time.h"
#include "registers.h"

#ifndef FW_PATH
#  define FW_PATH "build_pic/bypass_cd4053_pic10f322.hex"
#endif
#ifndef PROC_NAME
#  define PROC_NAME "p10f322"
#endif
#ifndef F_CPU_HZ
#  define F_CPU_HZ 2000000UL
#endif

#if (defined(CD4053_SIMPLE) + defined(CD4053_WITH_MUTE) + defined(TQ2_L2_5V_RELAY)) != 1
#  error "define exactly one output variant"
#endif

#define PORTA_ADDR  0x005u
#define TRISA_ADDR  0x006u
#define LATA_ADDR   0x007u
#define ANSELA_ADDR 0x008u
#define OUTPUT_MASK 0x07u
#define TRISA_INIT  0x08u
#define CYCLES_PER_MS ((F_CPU_HZ / 4UL) / 1000UL)
#define STARTUP_MS 30u
#define PRESS_TRACE_MS 30u
#define RELEASE_TRACE_MS 40u
#define MAX_RESUMES_PER_CYCLE 64
#define PULSE_TOLERANCE_CYCLES (CYCLES_PER_MS / 5u)  // +/-0.2 ms

struct NullBuf : std::streambuf { int overflow(int c) override { return c; } };
static NullBuf g_nullbuf;

struct Transition {
    unsigned lata;
    guint64 cycle;
};

struct IoTrace {
    const char *name;
    std::vector<Transition> transitions;
    bool saw_configured = false;
    bool trisa_ok = true;
    bool ansela_ok = true;
    bool porta_ok = true;
    bool relay_coils_ok = true;

    explicit IoTrace(const char *trace_name) : name(trace_name) {}
};

static pic_processor *g_cpu = nullptr;
static Stimulus_Node *g_fsw_node = nullptr;
static source_stimulus *g_fsw_src = nullptr;
static Register *g_porta = nullptr;
static Register *g_trisa = nullptr;
static Register *g_lata = nullptr;
static Register *g_ansela = nullptr;
static unsigned g_checks = 0;
static unsigned g_fails = 0;

static void check(bool condition, const char *message) {
    g_checks++;
    if (!condition) {
        g_fails++;
        fprintf(stderr, "FAIL: %s\n", message);
    }
}

static IOPIN *find_pin(Module *m, const char *name) {
    for (int i = 1; i <= m->get_pin_count(); ++i) {
        std::string &pin_name = m->get_pin_name((unsigned)i);
        if (pin_name == name) return m->get_pin((unsigned)i);
    }
    return nullptr;
}

static unsigned reg8(Register *r) {
    return r->get_value() & 0xFFu;
}

static void footsw_set(bool pressed) {
    g_fsw_src->set_Vth(pressed ? 0.0 : 5.0);
    g_fsw_node->update();
}

// Advance one instruction cycle. A cycle breakpoint, unlike step_one(), keeps
// gpsim peripherals active while still allowing every output state to be seen.
static bool run_one_cycle(void) {
    guint64 const target = get_cycles().get() + 1u;
    get_cycles().set_break(target);
    int resumes = 0;
    while (get_cycles().get() < target) {
        g_cpu->run(false);
        if (++resumes > MAX_RESUMES_PER_CYCLE) {
            fprintf(stderr, "FATAL: core did not advance to cycle break\n");
            get_cycles().clear_break(target);
            return false;
        }
    }
    get_cycles().clear_break(target);
    return true;
}

static void trace_cycles(IoTrace *trace, guint64 cycles, bool require_configured) {
    unsigned previous = reg8(g_lata) & OUTPUT_MASK;
    for (guint64 i = 0; i < cycles; ++i) {
        if (!run_one_cycle()) {
            trace->trisa_ok = trace->ansela_ok = trace->porta_ok = false;
            return;
        }

        unsigned const trisa = reg8(g_trisa) & 0x0Fu;
        unsigned const ansela = reg8(g_ansela) & OUTPUT_MASK;
        unsigned const lata = reg8(g_lata) & OUTPUT_MASK;
        unsigned const porta = reg8(g_porta) & OUTPUT_MASK;

        if (trisa == TRISA_INIT && ansela == 0u) trace->saw_configured = true;
        if (require_configured || trace->saw_configured) {
            if (trisa != TRISA_INIT) trace->trisa_ok = false;
            if (ansela != 0u) trace->ansela_ok = false;
            if (porta != lata) trace->porta_ok = false;
        }
#if defined(TQ2_L2_5V_RELAY)
        if ((lata & 0x06u) == 0x06u) trace->relay_coils_ok = false;
#endif
        if (lata != previous) {
            trace->transitions.push_back({lata, get_cycles().get()});
            previous = lata;
        }
    }
}

static void check_trace_health(const IoTrace &trace, bool require_seen) {
    if (require_seen) check(trace.saw_configured, "startup never reached digital TRISA=0x08 configuration");
    check(trace.trisa_ok, "TRISA did not remain exact RA3-input/RA0..RA2-output 0x08");
    check(trace.ansela_ok, "ANSELA re-selected an output pin as analog");
    check(trace.porta_ok, "physical PORTA output bits did not follow LATA");
#if defined(TQ2_L2_5V_RELAY)
    check(trace.relay_coils_ok, "relay RESET and SET coils were high simultaneously");
#endif
}

static void check_sequence(const IoTrace &trace, const unsigned *expected, size_t count) {
    g_checks++;
    bool match = trace.transitions.size() == count;
    if (match) {
        for (size_t i = 0; i < count; ++i) {
            if (trace.transitions[i].lata != expected[i]) { match = false; break; }
        }
    }
    if (!match) {
        g_fails++;
        fprintf(stderr, "FAIL: %s LATA trace [", trace.name);
        for (size_t i = 0; i < trace.transitions.size(); ++i)
            fprintf(stderr, "%s0x%x", i ? "," : "", trace.transitions[i].lata);
        fprintf(stderr, "] != expected [");
        for (size_t i = 0; i < count; ++i)
            fprintf(stderr, "%s0x%x", i ? "," : "", expected[i]);
        fprintf(stderr, "]\n");
    }
}

static void check_pulse(const IoTrace &trace, unsigned pulse_state,
                        unsigned expected_ms, bool relay_minimum) {
    const Transition *start = nullptr;
    const Transition *end = nullptr;
    for (size_t i = 0; i < trace.transitions.size(); ++i) {
        if (trace.transitions[i].lata == pulse_state) {
            start = &trace.transitions[i];
            if (i + 1u < trace.transitions.size()) end = &trace.transitions[i + 1u];
            break;
        }
    }
    g_checks++;
    if (start == nullptr || end == nullptr) {
        g_fails++;
        fprintf(stderr, "FAIL: %s has no complete 0x%x pulse state\n", trace.name, pulse_state);
        return;
    }

    guint64 const width = end->cycle - start->cycle;
    guint64 const expected = (guint64)expected_ms * CYCLES_PER_MS;
    guint64 const difference = width > expected ? width - expected : expected - width;
    double const width_ms = (double)width / (double)CYCLES_PER_MS;
    printf("  %s pulse: %" G_GUINT64_FORMAT " cycles (%.3f ms; design %u ms)\n",
           trace.name, width, width_ms, expected_ms);
    if (difference > PULSE_TOLERANCE_CYCLES) {
        g_fails++;
        fprintf(stderr,
                "FAIL: %s pulse width %" G_GUINT64_FORMAT
                " cycles is outside design %" G_GUINT64_FORMAT " +/- %lu cycles\n",
                trace.name, width, expected, (unsigned long)PULSE_TOLERANCE_CYCLES);
    }
    if (relay_minimum) {
        check(width >= 4u * CYCLES_PER_MS,
              "relay pulse is shorter than the 4 ms datasheet minimum");
    }
}

int main(void) {
    std::cout.rdbuf(&g_nullbuf);
    initialize_gpsim_core();
    gpsim_set_bulk_mode(1);
    CSimulationContext *context = CSimulationContext::GetContext();

    Processor *processor = nullptr;
    context->LoadProgram(FW_PATH, PROC_NAME, &processor, "u1");
    if (processor == nullptr) processor = context->GetActiveCPU();
    if (processor == nullptr) {
        fprintf(stderr, "FATAL: gpsim could not load %s on %s\n", FW_PATH, PROC_NAME);
        return 1;
    }
    g_cpu = static_cast<pic_processor *>(processor);

    g_porta = g_cpu->rma.get_register(PORTA_ADDR);
    g_trisa = g_cpu->rma.get_register(TRISA_ADDR);
    g_lata = g_cpu->rma.get_register(LATA_ADDR);
    g_ansela = g_cpu->rma.get_register(ANSELA_ADDR);
    if (g_porta == nullptr || g_trisa == nullptr || g_lata == nullptr || g_ansela == nullptr) {
        fprintf(stderr, "FATAL: PIC10F322 GPIO register map is unavailable\n");
        return 1;
    }

    IOPIN *ra3 = find_pin(g_cpu, "ra3");
    if (ra3 == nullptr) {
        fprintf(stderr, "FATAL: pin ra3 not found on %s\n", PROC_NAME);
        return 1;
    }
    g_fsw_src = new source_stimulus();
    g_fsw_src->set_digital();
    g_fsw_src->set_Zth(250.0);
    g_fsw_src->set_Vth(5.0);
    g_fsw_node = new Stimulus_Node("fsw");
    g_fsw_node->attach_stimulus(g_fsw_src);
    g_fsw_node->attach_stimulus(ra3);
    footsw_set(false);

    printf("TARGET-IO START: fw=%s proc=%s FOSC=%lu\n",
           FW_PATH, PROC_NAME, (unsigned long)F_CPU_HZ);

    IoTrace startup("startup");
    trace_cycles(&startup, (guint64)STARTUP_MS * CYCLES_PER_MS, false);
    check_trace_health(startup, true);
    check((reg8(g_trisa) & 0x0Fu) == TRISA_INIT, "startup TRISA is not exact 0x08");
    check((reg8(g_lata) & OUTPUT_MASK) == 0u, "startup did not settle in BYPASS LATA=0x0");
    check((reg8(g_porta) & OUTPUT_MASK) == 0u, "startup physical outputs did not settle low");

    footsw_set(true);
    IoTrace engage("engage");
    trace_cycles(&engage, (guint64)PRESS_TRACE_MS * CYCLES_PER_MS, true);
    check_trace_health(engage, false);

    footsw_set(false);
    IoTrace release_one("release-after-engage");
    trace_cycles(&release_one, (guint64)RELEASE_TRACE_MS * CYCLES_PER_MS, true);
    check_trace_health(release_one, false);
    check_sequence(release_one, nullptr, 0u);

    footsw_set(true);
    IoTrace bypass("bypass");
    trace_cycles(&bypass, (guint64)PRESS_TRACE_MS * CYCLES_PER_MS, true);
    check_trace_health(bypass, false);

    footsw_set(false);
    IoTrace release_two("release-after-bypass");
    trace_cycles(&release_two, (guint64)RELEASE_TRACE_MS * CYCLES_PER_MS, true);
    check_trace_health(release_two, false);
    check_sequence(release_two, nullptr, 0u);

#if defined(CD4053_SIMPLE)
    static const unsigned engage_expected[] = {0x1u, 0x3u};
    static const unsigned bypass_expected[] = {0x2u, 0x0u};
    check_sequence(startup, nullptr, 0u);
    check_sequence(engage, engage_expected, 2u);
    check_sequence(bypass, bypass_expected, 2u);
    check((reg8(g_lata) & OUTPUT_MASK) == 0u, "simple output did not finish in BYPASS");
#elif defined(CD4053_WITH_MUTE)
    static const unsigned engage_expected[] = {0x1u, 0x5u, 0x7u};
    static const unsigned bypass_expected[] = {0x6u, 0x4u, 0x0u};
    check_sequence(startup, nullptr, 0u);
    check_sequence(engage, engage_expected, 3u);
    check_sequence(bypass, bypass_expected, 3u);
    check_pulse(engage, 0x5u, 5u, false);
    check_pulse(bypass, 0x4u, 5u, false);
#elif defined(TQ2_L2_5V_RELAY)
    static const unsigned startup_expected[] = {0x2u, 0x0u};
    static const unsigned engage_expected[] = {0x1u, 0x5u, 0x1u};
    static const unsigned bypass_expected[] = {0x0u, 0x2u, 0x0u};
    check_sequence(startup, startup_expected, 2u);
    check_sequence(engage, engage_expected, 3u);
    check_sequence(bypass, bypass_expected, 3u);
    check_pulse(startup, 0x2u, 12u, true);
    check_pulse(engage, 0x5u, 12u, true);
    check_pulse(bypass, 0x2u, 12u, true);
    check((reg8(g_lata) & 0x06u) == 0u, "relay coils were not parked low");
#endif

    bool const pass = g_fails == 0u;
    printf("TARGET-IO %s: %u checks, %u failures\n",
           pass ? "PASS" : "FAIL", g_checks, g_fails);
    return pass ? 0 : 1;
}
