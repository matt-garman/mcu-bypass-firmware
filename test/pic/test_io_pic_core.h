// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// Include-only built-HEX GPIO transition and pulse-timing implementation shared
// by the PIC part adapters. It observes the XC8-generated instruction stream in
// libgpsim and checks exact distinct output-latch states, ordering, the
// corresponding physical port levels, and delay between pulse edges. The timing
// assertion validates code generation at the configured FOSC; it does not
// validate oscillator tolerance on real silicon.
//
// Register identity -- addresses, gpsim name tokens, printable names, masks and
// expected init values -- is NOT here: the adapter includes its family's
// pic*_regs.h (e.g. pic/pic10f32x_regs.h) and this file carries only mechanism.

#ifndef TEST_PIC_TEST_IO_PIC_CORE_H
#define TEST_PIC_TEST_IO_PIC_CORE_H

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <string>
#include <vector>
#include <iostream>

#include <glib.h>
#include "processor.h"
#include "pic-processor.h"
#include "gpsim_time.h"
#include "registers.h"

// gpsim bring-up shared with the lock-step / fault / soak harnesses: NullBuf,
// g_cpu / g_fsw_node / g_fsw_src, FOOTSW_PIN_NAME, gpsim_bootstrap_cpu(),
// gpsim_attach_footswitch() and footsw_set().
#include "pic/gpsim_bootstrap.h"

#ifndef PIC_REG_PORT_ADDR
#  error "part adapter must include its family register map (e.g. pic/pic10f32x_regs.h)"
#endif
#ifndef PIC_IO_DEFAULT_PROC_NAME
#  error "PIC_IO_DEFAULT_PROC_NAME must be defined by the part adapter"
#endif
#ifndef PIC_IO_PART_NAME
#  error "PIC_IO_PART_NAME must be defined by the part adapter"
#endif
// FW_PATH names an output STAGE, which the Makefile selects per run -- unlike
// PROC_NAME below, which names the PART and so is legitimately the adapter's to
// default. An adapter default for FW_PATH looked like the same thing and was
// not: it is per-part correct and per-variant wrong, so a severed injection
// tested one output stage while the run reported another.
#ifndef FW_PATH
#  error "FW_PATH must be injected: -DFW_PATH from PIC10F322_IO_HEX or PIC10F320_IO_HEX"
#endif
#ifndef PROC_NAME
#  define PROC_NAME PIC_IO_DEFAULT_PROC_NAME
#endif
// FOSC; instruction clock = FOSC/4. A part fact, and the two PIC parts share
// one value today -- which is exactly why a default here is a hazard: re-pin
// one chip's XTAL and this harness goes on simulating the other's.
#ifndef F_CPU_HZ
#  error "F_CPU_HZ must be injected: -DF_CPU_HZ from PIC10F322_XTAL or PIC10F320_XTAL"
#endif

#if (defined(PIC_IO_SIMPLE) + defined(PIC_IO_MUTE) + \
     defined(PIC_IO_RELAY)) != 1
/* name-contract: exempt-begin (PIC_IO_* is a C macro family, not make vars) */
#  error "part adapter must select exactly one PIC_IO_* variant"
/* name-contract: exempt-end */
#endif

// Device identity comes from the adapter's family register map; only the
// derived shorthands the mechanism below reads are named here.
#define OUTPUT_MASK PIC_REG_OUTPUT_MASK
#define TRIS_INIT   PIC_REG_TRIS_INIT
#define CYCLES_PER_MS ((F_CPU_HZ / 4UL) / 1000UL)
#define STARTUP_MS 30u
#define PRESS_TRACE_MS 30u
#define RELEASE_TRACE_MS 40u
#define MAX_RESUMES_PER_CYCLE 64
#define PULSE_TOLERANCE_CYCLES (CYCLES_PER_MS / 5u)  // +/-0.2 ms

struct Transition {
    unsigned latch;
    guint64 cycle;
};

struct IoTrace {
    const char *name;
    std::vector<Transition> transitions;
    bool saw_configured = false;
    bool tris_ok = true;
    bool ansel_ok = true;
    bool port_ok = true;
    bool relay_coils_ok = true;

    explicit IoTrace(const char *trace_name) : name(trace_name) {}
};

// g_cpu / g_fsw_node / g_fsw_src come from pic/gpsim_bootstrap.h.
static Register *g_port = nullptr;
static Register *g_tris = nullptr;
static Register *g_latch = nullptr;
static Register *g_ansel = nullptr;
static unsigned g_checks = 0;
static unsigned g_fails = 0;

static void check(bool condition, const char *message) {
    g_checks++;
    if (!condition) {
        g_fails++;
        fprintf(stderr, "FAIL: %s\n", message);
    }
}

static unsigned reg8(Register *r) {
    return r->get_value() & 0xFFu;
}

// footsw_set() comes from pic/gpsim_bootstrap.h.

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
    unsigned previous = reg8(g_latch) & OUTPUT_MASK;
    for (guint64 i = 0; i < cycles; ++i) {
        if (!run_one_cycle()) {
            trace->tris_ok = trace->ansel_ok = trace->port_ok = false;
            return;
        }

        unsigned const tris = reg8(g_tris) & PIC_REG_PORT_MASK;
        unsigned const ansel = reg8(g_ansel) & OUTPUT_MASK;
        unsigned const latch = reg8(g_latch) & OUTPUT_MASK;
        unsigned const port = reg8(g_port) & OUTPUT_MASK;

        if (tris == TRIS_INIT && ansel == 0u) trace->saw_configured = true;
        if (require_configured || trace->saw_configured) {
            if (tris != TRIS_INIT) trace->tris_ok = false;
            if (ansel != 0u) trace->ansel_ok = false;
            if (port != latch) trace->port_ok = false;
        }
#if defined(PIC_IO_RELAY)
        if ((latch & PIC_REG_COIL_MASK) == PIC_REG_COIL_MASK) trace->relay_coils_ok = false;
#endif
        if (latch != previous) {
            trace->transitions.push_back({latch, get_cycles().get()});
            previous = latch;
        }
    }
}

static void check_trace_health(const IoTrace &trace, bool require_seen) {
    if (require_seen) check(trace.saw_configured,
        "startup never reached digital " PIC_REG_TRIS_NAME "=" PIC_REG_TRIS_INIT_STR " configuration");
    check(trace.tris_ok,
        PIC_REG_TRIS_NAME " did not remain exact " PIC_REG_TRIS_LAYOUT " " PIC_REG_TRIS_INIT_STR);
    check(trace.ansel_ok, PIC_REG_ANSEL_NAME " re-selected an output pin as analog");
    check(trace.port_ok,
        "physical " PIC_REG_PORT_NAME " output bits did not follow " PIC_REG_LATCH_NAME);
#if defined(PIC_IO_RELAY)
    check(trace.relay_coils_ok, "relay RESET and SET coils were high simultaneously");
#endif
}

static void check_sequence(const IoTrace &trace, const unsigned *expected, size_t count) {
    g_checks++;
    bool match = trace.transitions.size() == count;
    if (match) {
        for (size_t i = 0; i < count; ++i) {
            if (trace.transitions[i].latch != expected[i]) { match = false; break; }
        }
    }
    if (!match) {
        g_fails++;
        fprintf(stderr, "FAIL: %s " PIC_REG_LATCH_NAME " trace [", trace.name);
        for (size_t i = 0; i < trace.transitions.size(); ++i)
            fprintf(stderr, "%s0x%x", i ? "," : "", trace.transitions[i].latch);
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
        if (trace.transitions[i].latch == pulse_state) {
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
    if (!gpsim_bootstrap_cpu(FW_PATH, PROC_NAME)) return 1;

    g_port = g_cpu->rma.get_register(PIC_REG_PORT_ADDR);
    g_tris = g_cpu->rma.get_register(PIC_REG_TRIS_ADDR);
    g_latch = g_cpu->rma.get_register(PIC_REG_LATCH_ADDR);
    g_ansel = g_cpu->rma.get_register(PIC_REG_ANSEL_ADDR);
    if (g_port == nullptr || g_tris == nullptr || g_latch == nullptr || g_ansel == nullptr) {
        fprintf(stderr, "FATAL: %s GPIO register map is unavailable\n", PIC_IO_PART_NAME);
        return 1;
    }

    if (!gpsim_attach_footswitch(FOOTSW_PIN_NAME, PROC_NAME)) return 1;
    footsw_set(0);

    printf("TARGET-IO START: fw=%s proc=%s FOSC=%lu\n",
           FW_PATH, PROC_NAME, (unsigned long)F_CPU_HZ);

    IoTrace startup("startup");
    trace_cycles(&startup, (guint64)STARTUP_MS * CYCLES_PER_MS, false);
    check_trace_health(startup, true);
    check((reg8(g_tris) & PIC_REG_PORT_MASK) == TRIS_INIT,
          "startup " PIC_REG_TRIS_NAME " is not exact " PIC_REG_TRIS_INIT_STR);
    check((reg8(g_latch) & OUTPUT_MASK) == 0u,
          "startup did not settle in BYPASS " PIC_REG_LATCH_NAME "=0x0");
    check((reg8(g_port) & OUTPUT_MASK) == 0u, "startup physical outputs did not settle low");

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

#if defined(PIC_IO_SIMPLE)
    static const unsigned engage_expected[] = {0x1u, 0x3u};
    static const unsigned bypass_expected[] = {0x2u, 0x0u};
    check_sequence(startup, nullptr, 0u);
    check_sequence(engage, engage_expected, 2u);
    check_sequence(bypass, bypass_expected, 2u);
    check((reg8(g_latch) & OUTPUT_MASK) == 0u, "simple output did not finish in BYPASS");
#elif defined(PIC_IO_MUTE)
    static const unsigned engage_expected[] = {0x1u, 0x5u, 0x7u};
    static const unsigned bypass_expected[] = {0x6u, 0x4u, 0x0u};
    check_sequence(startup, nullptr, 0u);
    check_sequence(engage, engage_expected, 3u);
    check_sequence(bypass, bypass_expected, 3u);
    check_pulse(engage, 0x5u, 5u, false);
    check_pulse(bypass, 0x4u, 5u, false);
#elif defined(PIC_IO_RELAY)
    static const unsigned startup_expected[] = {0x2u, 0x0u};
    static const unsigned engage_expected[] = {0x1u, 0x5u, 0x1u};
    static const unsigned bypass_expected[] = {0x0u, 0x2u, 0x0u};
    check_sequence(startup, startup_expected, 2u);
    check_sequence(engage, engage_expected, 3u);
    check_sequence(bypass, bypass_expected, 3u);
    check_pulse(startup, 0x2u, 12u, true);
    check_pulse(engage, 0x5u, 12u, true);
    check_pulse(bypass, 0x2u, 12u, true);
    check((reg8(g_latch) & PIC_REG_COIL_MASK) == 0u, "relay coils were not parked low");
#endif

    bool const pass = g_fails == 0u;
    printf("TARGET-IO %s: %u checks, %u failures\n",
           pass ? "PASS" : "FAIL", g_checks, g_fails);
    return pass ? 0 : 1;
}

#endif
