// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// Include-only implementation shared by the PIC part adapters. Each adapter
// pins its processor, image, program-space limit, independent check count,
// output-variant vocabulary, and output-latch fault policy, and includes its
// family's register map (pic*_regs.h) and injection matrix (pic*_fault_matrix.h)
// before including this file. Keeping those facts outside the common mechanism
// makes accidental cross-part drift visible while eliminating duplicated
// simulator logic.
//
// This test links libgpsim, drives a real built HEX, corrupts a guarded location
// at runtime (an SEU/EMI single-event-upset model), and asserts that the firmware
// detects the corruption and recovers via a watchdog reset on the simulated core.
//
// COMMON COVERAGE (the register sets are the family matrix's to name; this core
// only sequences them):
//   * output directions   PIC_FAULT_DIRECTION_INJECTIONS()
//   * output latch        PIC_FAULT_EXTRA_OUTPUT_INJECTIONS()  (per PART)
//   * config SFRs         PIC_FAULT_CONFIG_INJECTIONS()
//   * pull-up SFRs        PIC_FAULT_PULLUP_INJECTIONS()
//   * ctx_ SRAM           program_state / effect_state / debounce_counter
//                         (range checks -- genuinely device-independent, so they
//                         are the only injections still written out below)
// The output-latch policy is the per-PART hook, and the three consumers show
// why it has to be: PIC10F322 injects its latch bits because that firmware
// guards the settled latch; PIC10F320 deliberately omits that general guard for
// flash budget and its relay adapter instead injects coil bits and requires
// their idle safe-state rewrite to correct both latch and physical port within
// one serviced iteration, without a reset; and PIC12F675 has no latch REGISTER
// at all, so it injects into the SRAM shadow that serves as one AND into the
// pins, which the gate requires to follow it. The literal per-part expected
// counts ensure a missing case cannot silently reduce any lane.
//
// CTX_ADDR is required. The Makefile extracts _ctx_'s data address from the XC8
// .sym so the test self-adjusts per variant and cannot pass with SRAM cases
// silently omitted.
//
// WHY THIS IS THE MIRROR IMAGE OF THE SOAK (test/pic/test_soak_pic.cc):
// the polled PIC firmware has no recovery path OTHER than the watchdog. When the
// per-tick gate sees a skewed SFR it calls hw_force_wdt_reset(), which clears
// GIE and spins in for(;;){} -- it simply STOPS petting the dog, so the fault
// surfaces as a WDT reset that re-vectors to 0x000. That is the identical event
// the soak's ResetNotifier detects, EXCEPT the soak treats a reset as a FAILURE
// while this test treats exactly one reset as the expected PASS. So this driver
// reuses the soak's proven notify-break-at-0x000 machinery and inverts the
// verdict.
//
// SCENARIO (per guarded positive injection case):
//   1. Hold the footswitch RELEASED so the device is quiescent -- the debounce
//      context stays in range and the pull-up stays intact, so ONLY the injected
//      SFR can trip the gate (clean fault isolation).
//   2. Snapshot the cumulative reset count.
//   3. put_value() a corrupt value into the target SFR (an SEU bit-flip).
//   4. Run one WDT window.
//   5. Assert EXACTLY ONE reset fired (delta == 1). "Exactly one" -- not ">=1" --
//      also catches a reset-LOOP (the only gpsim-modeling risk; see the WDTCON
//      note below), which would otherwise pass silently.
// A no-injection CONTROL case runs first and asserts delta == 0: a quiescent
// device must NOT reset in a full window, proving the window is not catching
// phantom resets and the gate does not fire spuriously.
//
// Whether any OTHER delta == 0 case exists is the matrix's call, not this
// core's. Every current part now guards every injected location: the exact
// direction/output checks brought each spare output inside the policy, including
// PIC12F675 GP4 and its non-isomorphic ANSEL.ANS3 mapping. The zero-expectation
// support remains because a future deliberate non-guard must be pinned rather
// than assumed.
//
// CORRUPTION VALUES are chosen so the main loop keeps running and the GATE is
// the sole reset path. That confound analysis is per-register and therefore
// lives with the matrix that picks the values (e.g. pic/pic10f32x_fault_matrix.h).
//
// The ctx_ cases differ subtly. effect_state and debounce_counter persist until
// the next gate check while the device is quiescent. An out-of-range
// program_state also reaches a belt-and-suspenders state-machine fault path; the
// adapter's diagnostic names the pure-core or hand-inlined path for its part.
//
// Build/run via `make pic10f322-test-fault`, `make pic10f320-test-fault-target`
// or `make pic12f675-test-fault`. The fail-closed `pic10f322-test-target-variants`
// and `pic10f320-test-target-variants` aggregates run their respective adapter
// for every supported output variant.
//
// IMPORTANT (gpsim WDT calibration; see test_soak_pic.cc): on the PIC10F32x
// gpsim honors WDTCON.WDTPS but does NOT match the datasheet -- at that
// firmware's WDTPS=0x08 the gpsim WDT period is ~1.057 s, not the silicon
// ~256 ms. The recovery reset therefore takes ~1.06 s of simulated time there;
// WDT_RESET_WINDOW_MS carries margin over it. This test asserts nothing about
// WDT TIMING, only that the reset happens within a generous window -- which is
// what lets one window serve parts whose watchdog models differ.

#ifndef TEST_PIC_TEST_FAULT_PIC_CORE_H
#define TEST_PIC_TEST_FAULT_PIC_CORE_H

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cctype>
#include <string>
#include <vector>
#include <iostream>

#include "pic/target_result.h"

#include <glib.h>                 // guint64, G_GUINT64_FORMAT
#include "processor.h"            // Processor (rma, run)
#include "pic-processor.h"        // pic_processor
#include "gpsim_time.h"           // get_cycles(), Cycle_Counter
#include "breakpoints.h"          // get_bp(), set_notify_break
#include "trigger.h"              // TriggerObject
#include "registers.h"            // Register::get_value()/put_value()/name()

// gpsim bring-up shared with the io / lock-step / soak harnesses: NullBuf,
// g_cpu / g_fsw_node / g_fsw_src, FOOTSW_PIN_NAME, gpsim_bootstrap_cpu(),
// gpsim_attach_footswitch() and footsw_set().
#include "pic/gpsim_bootstrap.h"

// ---- Firmware / MCU parameters (provided by the part adapter / Makefile) -----
#ifndef PIC_REG_PORT_ADDR
#  error "part adapter must include its family register map (e.g. pic/pic10f32x_regs.h)"
#endif
#ifndef PIC_FAULT_DIRECTION_INJECTIONS
#  error "part adapter must include its family fault matrix (e.g. pic/pic10f32x_fault_matrix.h)"
#endif
#ifndef PIC_FAULT_CONFIG_INJECTIONS
#  error "PIC_FAULT_CONFIG_INJECTIONS must come from the family fault matrix"
#endif
#ifndef PIC_FAULT_PULLUP_INJECTIONS
#  error "PIC_FAULT_PULLUP_INJECTIONS must come from the family fault matrix"
#endif
#ifndef PIC_FAULT_DEFAULT_PROC_NAME
#  error "PIC_FAULT_DEFAULT_PROC_NAME must be defined by the part adapter"
#endif
#ifndef PIC_FAULT_PROGRAM_WORDS
#  error "PIC_FAULT_PROGRAM_WORDS must be defined by the part adapter"
#endif
#ifndef PIC_FAULT_EXPECTED_CHECKS
#  error "PIC_FAULT_EXPECTED_CHECKS must be defined by the part adapter"
#endif
#ifndef PIC_FAULT_EXTRA_OUTPUT_INJECTIONS
#  error "PIC_FAULT_EXTRA_OUTPUT_INJECTIONS must be defined by the part adapter"
#endif
#ifndef PIC_FAULT_PROGRAM_STATE_NOTE
#  error "PIC_FAULT_PROGRAM_STATE_NOTE must be defined by the part adapter"
#endif
// FW_PATH names an output STAGE, which the Makefile selects per run -- unlike
// PROC_NAME below, which names the PART and so is legitimately the adapter's to
// default. An adapter default for FW_PATH looked like the same thing and was
// not: it is per-part correct and per-variant wrong, so a severed injection
// tested one output stage while the run reported another.
#ifndef FW_PATH
#  error "FW_PATH must be injected: -DFW_PATH from PIC10F322_FAULT_HEX, PIC10F320_FAULT_HEX or PIC12F675_FAULT_HEX"
#endif
#ifndef PROC_NAME
#  define PROC_NAME PIC_FAULT_DEFAULT_PROC_NAME
#endif
// FOSC; instruction clock = FOSC/4. A part fact, and NOT a shared one: the two
// 10F32x parts run at 2 MHz and the PIC12F675 at 4 MHz. A default here would be
// a hazard even had they agreed -- re-pin one chip's XTAL and this harness goes
// on simulating the other's.
#ifndef F_CPU_HZ
#  error "F_CPU_HZ must be injected: -DF_CPU_HZ from PIC10F322_XTAL, PIC10F320_XTAL or PIC12F675_XTAL"
#endif
#define CYCLES_PER_MS  ((F_CPU_HZ / 4UL) / 1000UL)   // 500 @ 2 MHz, 1000 @ 4 MHz
#define CLRWDT_OPCODE  0x0064u

// The footswitch is driven by footsw_set() on FOOTSW_PIN_NAME; both come from
// gpsim_bootstrap.h. Every SFR address, gpsim name token and expected init
// value comes from the family register map the adapter included, and each
// address is cross-checked against the register's gpsim name at runtime by
// fetch_sfr() so an address drift is surfaced rather than silently corrupting
// the wrong register.

// ctx_ is file-static SRAM in all three firmware parts. The Makefile passes its .sym
// address and asserts the generated allocation is three bytes. Field offsets
// follow the common program_state/effect_state/debounce_counter order. ctx_ is a
// GPR, so pass a null token to fetch_sfr to skip the name cross-check.
#ifndef CTX_ADDR
#  error "CTX_ADDR (the _ctx_ SRAM address from the XC8 .sym) is required"
#endif
#define CTX_PROGRAM_STATE     ((unsigned)(CTX_ADDR) + 0u)
#define CTX_EFFECT_STATE      ((unsigned)(CTX_ADDR) + 1u)
#define CTX_DEBOUNCE_COUNTER  ((unsigned)(CTX_ADDR) + 2u)

// ---- Timing -----------------------------------------------------------------
// Settle time to (re)reach the quiescent main loop after power-on or a recovery
// reset. Must exceed init()'s worst-case blocking bypass actuation (relay coil
// pulse, 12 ms) plus margin.
#define SETTLE_MS  30u
// One WDT window to observe the recovery reset. gpsim's WDT@WDTPS=0x08 is
// ~1.057 s (see header note); 2000 ms carries margin AND is long enough that a
// (WDTPS-corrupted, hence faster) reset-LOOP would show as delta >> 1.
#define WDT_RESET_WINDOW_MS  2000u
// Safety cap: max run() resumes to cover one ms. A genuinely wedged core (PC
// stuck, never reaching the cycle break) trips this instead of hanging forever.
#define MAX_RESUMES_PER_MS 64
// Injections are parked at the behaviorally identified loop CLRWDT so the
// corruption lands at a DETERMINISTIC
// loop phase: CLRWDT is the last thing before looping back to the tick poll, so
// the very next sanity gate reads the injected value BEFORE the debounce
// integrator (which rewrites ctx_.debounce_counter every tick) can overwrite it.
// Without this, injecting at the arbitrary phase where the ms-settle happens to
// halt is racy for the every-tick-rewritten ctx_ fields (it depends on FOSC and
// per-variant loop layout).
#define PROGRAM_WORDS PIC_FAULT_PROGRAM_WORDS
#define CLRWDT_CALIB_MS 8u
#define EXPECTED_CHECKS PIC_FAULT_EXPECTED_CHECKS

// ---- Sim globals ------------------------------------------------------------
// g_cpu / g_fsw_node / g_fsw_src come from pic/gpsim_bootstrap.h.
static guint64   g_resets  = 0;   // incremented by ResetNotifier at 0x000
static unsigned  g_checks  = 0;
static unsigned  g_fails   = 0;
static unsigned  g_loop_clrwdt_addr = 0;

// ---- Reset detection (identical to the soak; verdict inverted at the call
// site). A NOTIFY breakpoint at the reset vector fires WITHOUT halting the run,
// so a WDT reset is counted as a side effect of normal execution. Armed AFTER
// the power-on settle so the initial pass through 0x000 is not counted.
class ResetNotifier : public TriggerObject {
public:
    void callback() override { g_resets++; }
};
static ResetNotifier g_reset_notifier;

// ---- Helpers ----------------------------------------------------------------
// footsw_set() comes from pic/gpsim_bootstrap.h.

// Fetch a register by file address and (for named SFRs) require that its gpsim
// name contains the expected token (lowercase). A mismatch is fatal: injecting
// the wrong register must never count as evidence that the named guard works. Pass
// token == nullptr for GPRs (e.g. ctx_), which have no meaningful name.
static Register *fetch_sfr(unsigned addr, const char *token) {
    Register *r = g_cpu->rma.get_register(addr);
    if (r == nullptr) {
        fprintf(stderr, "FATAL: no register at 0x%03x\n", addr);
        return nullptr;
    }
    if (token != nullptr) {
        std::string nm = r->name();
        for (char &c : nm) c = (char)tolower((unsigned char)c);
        if (nm.find(token) == std::string::npos) {
            fprintf(stderr, "FATAL: register at 0x%03x is named '%s', expected '%s'\n",
                    addr, r->name().c_str(), token);
            return nullptr;
        }
    }
    return r;
}

// Advance the simulation by `ms` ms of simulated time. Cycle break at the
// target; resume run() until the target cycle is reached (a WDT reset may halt
// run() early and/or fire the notify callback -- either way we resume).
static bool run_ms(unsigned ms) {
    guint64 target = get_cycles().get() + (guint64)ms * CYCLES_PER_MS;
    get_cycles().set_break(target);
    int resumes = 0;
    while (get_cycles().get() < target) {
        g_cpu->run(false);
        if (++resumes > MAX_RESUMES_PER_MS) {
            fprintf(stderr, "FATAL: core not advancing (wedged?) at run_ms\n");
            get_cycles().clear_break(target);
            return false;
        }
    }
    return true;
}

// Identify the loop CLRWDT behaviorally. init() and the main loop each contain
// one, and their addresses are not reliably ordered; after settle only the loop
// site fires repeatedly.
struct ClrwdtCounter : public TriggerObject {
    unsigned addr;
    long hits = 0;
    explicit ClrwdtCounter(unsigned a) : addr(a) {}
    void callback() override { hits++; }
};

static bool identify_loop_clrwdt(void) {
    std::vector<ClrwdtCounter *> hooks;
    for (unsigned addr = 0; addr < PROGRAM_WORDS; ++addr) {
        if (g_cpu->pma->get_opcode(addr) == CLRWDT_OPCODE) {
            ClrwdtCounter *hook = new ClrwdtCounter(addr);
            hooks.push_back(hook);
            get_bp().set_notify_break(g_cpu, addr, hook);
        }
    }
    if (!run_ms(CLRWDT_CALIB_MS)) {
        g_checks++;
        g_fails++;
        return false;
    }
    long best = -1;
    for (ClrwdtCounter *hook : hooks) {
        if (hook->hits > best) {
            best = hook->hits;
            g_loop_clrwdt_addr = hook->addr;
        }
    }
    g_checks++;
    if (hooks.empty() || best < (long)(CLRWDT_CALIB_MS / 2u)) {
        g_fails++;
        fprintf(stderr,
                "FAIL: could not identify loop CLRWDT (%zu sites, max %ld hits in %u ms)\n",
                hooks.size(), best, CLRWDT_CALIB_MS);
        return false;
    }
    printf("  loop CLRWDT identified at 0x%03x (%ld hits in %u ms)\n",
           g_loop_clrwdt_addr, best, CLRWDT_CALIB_MS);
    return true;
}

// Advance (single-cycle steps via run(), which -- unlike step_one -- services
// peripherals) until the core is parked AT the loop CLRWDT, so a subsequent
// injection lands at a deterministic, gate-before-integrate loop phase. Caps at a
// few ticks' worth of cycles so a wedged core cannot spin forever.
static bool advance_to_loop_clrwdt(void) {
    for (int i = 0; i < 8000; ++i) {
        if (g_cpu->pc->get_value() == g_loop_clrwdt_addr)
            return true;
        guint64 c = get_cycles().get() + 1;
        get_cycles().set_break(c);
        g_cpu->run(false);
        get_cycles().clear_break(c);
    }
    fprintf(stderr, "FAIL: never reached loop CLRWDT 0x%03x\n", g_loop_clrwdt_addr);
    return false;
}

// PIC10F320 relay-only policy: a stable-state coil latch upset is corrected, not
// reset. Inject at the trailing loop CLRWDT, then stop at its next occurrence.
// That is exactly one serviced iteration and places the verdict before its pet.
static void inject_relay_correction_case(unsigned mask, const char *note) {
    static unsigned const coil_mask = PIC_REG_COIL_MASK;
    footsw_set(0);
    if (!run_ms(SETTLE_MS) || !advance_to_loop_clrwdt()) {
        g_checks++;
        g_fails++;
        return;
    }

    Register *latch = fetch_sfr(PIC_REG_LATCH_ADDR, PIC_REG_LATCH_TOKEN);
    Register *port = fetch_sfr(PIC_REG_PORT_ADDR, PIC_REG_PORT_TOKEN);
    if (latch == nullptr || port == nullptr) {
        g_checks++;
        g_fails++;
        return;
    }

    unsigned const initial_latch = latch->get_value() & 0xFFu;
    unsigned const injected = initial_latch | mask;
    guint64 const resets_before = g_resets;
    guint64 const injection_cycle = get_cycles().get();
    guint64 correction_cycle = 0u;
    latch->put_value(injected);
    unsigned const written = latch->get_value() & 0xFFu;
    unsigned observed_latch = written & coil_mask;
    unsigned observed_port = port->get_value() & coil_mask;
    bool footswitch_released = (port->get_value() & PIC_REG_FOOTSW_MASK) != 0u;
    bool left_clrwdt = false;
    bool completed_iteration = false;

    printf("  inject relay coils    @0x%03x: 0x%02x -> 0x%02x  (%s)\n",
           PIC_REG_LATCH_ADDR, initial_latch, injected, note);
    fflush(stdout);

    for (int i = 0; i < 8000; ++i) {
        unsigned const pc = g_cpu->pc->get_value();
        if (left_clrwdt && pc == g_loop_clrwdt_addr) {
            completed_iteration = true;
            break;
        }

        guint64 const cycle = get_cycles().get() + 1;
        get_cycles().set_break(cycle);
        g_cpu->run(false);
        get_cycles().clear_break(cycle);

        if (g_cpu->pc->get_value() != g_loop_clrwdt_addr) {
            left_clrwdt = true;
        }
        observed_latch |= latch->get_value() & coil_mask;
        observed_port |= port->get_value() & coil_mask;
        if (correction_cycle == 0u &&
                (latch->get_value() & coil_mask) == 0u &&
                (port->get_value() & coil_mask) == 0u) {
            correction_cycle = get_cycles().get();
        }
        footswitch_released = footswitch_released &&
                              ((port->get_value() & PIC_REG_FOOTSW_MASK) != 0u);
    }

    unsigned const final_latch = latch->get_value() & coil_mask;
    unsigned const final_port = port->get_value() & coil_mask;
    guint64 const reset_delta = g_resets - resets_before;
    guint64 const correction_cycles = correction_cycle > injection_cycle
        ? correction_cycle - injection_cycle : 0u;
    bool const pass = (initial_latch & coil_mask) == 0u &&
                      written == injected &&
                      observed_latch == mask && observed_port == mask &&
                      correction_cycles > 0u && completed_iteration &&
                      final_latch == 0u &&
                      final_port == 0u && reset_delta == 0u &&
                      footswitch_released;

    // Keep cases independent even when exercising a mutant that fails to clear
    // the injected state. The verdict above already captured the physical and
    // latch failure; the next case must still begin from the quiescent contract.
    latch->put_value((latch->get_value() & 0xFFu) & ~coil_mask);

    g_checks++;
    if (pass) {
        printf("    PASS: physical/latch coil mask 0x%02x cleared in %" G_GUINT64_FORMAT
               " cycles (%.3f ms), within one iteration and without reset\n",
               mask, correction_cycles,
               (double)correction_cycles / (double)CYCLES_PER_MS);
    } else {
        g_fails++;
        fprintf(stderr,
                "    FAIL: init=0x%02x write=0x%02x seen-" PIC_REG_LATCH_LC "=0x%02x "
                "seen-" PIC_REG_PORT_LC "=0x%02x final-" PIC_REG_LATCH_LC "=0x%02x "
                "final-" PIC_REG_PORT_LC "=0x%02x "
                "completed=%u correction-cycles=%" G_GUINT64_FORMAT
                " resets=%" G_GUINT64_FORMAT " released=%u\n",
                initial_latch & coil_mask, written & coil_mask, observed_latch,
                observed_port, final_latch, final_port,
                completed_iteration ? 1u : 0u, correction_cycles, reset_delta,
                footswitch_released ? 1u : 0u);
    }
    fflush(stdout);
}

// ---- One injection case -----------------------------------------------------
// absolute=true writes `val`; absolute=false writes (current ^ val), i.e. an
// SEU bit-flip of the bits in `val`. Every call site passes expected_resets == 1
// since the exact-direction port made all three variants guard the same pins;
// the parameter and its restore-and-verify branch below are kept because a
// zero-expectation case is exactly what a future unguarded location would need,
// and because that branch is what proved the old RA2 negative control genuinely
// left the register unchanged rather than silently failing to inject.
static void inject_case(const char *label, unsigned addr, const char *token,
                        bool absolute, unsigned val, unsigned expected_resets,
                        const char *note) {
    footsw_set(0);                 // released: quiescent, only the SFR can trip
    if (!run_ms(SETTLE_MS)) {      // (re)reach the main loop after any prior reset
        g_checks++;
        g_fails++;
        return;
    }
    if (!advance_to_loop_clrwdt()) {
        g_checks++;
        g_fails++;
        return;
    }

    Register *r = fetch_sfr(addr, token);
    if (r == nullptr) { g_checks++; g_fails++; return; }

    unsigned cur = r->get_value() & 0xFFu;
    unsigned bad = absolute ? (val & 0xFFu) : (cur ^ val);

    guint64 before = g_resets;
    r->put_value(bad);
    unsigned const written = r->get_value() & 0xFFu;
    printf("  inject %-18s @0x%03x: 0x%02x -> 0x%02x  (%s)\n",
           label, addr, cur, bad, note);
    fflush(stdout);

    if (written != bad) {
        g_checks++;
        g_fails++;
        fprintf(stderr,
                "    FAIL: injection did not stick (read 0x%02x, wanted 0x%02x)\n",
                written, bad);
        r->put_value(cur);
        return;
    }

    if (!run_ms(WDT_RESET_WINDOW_MS)) {
        g_checks++;
        g_fails++;
        if (expected_resets == 0u) r->put_value(cur);
        return;
    }
    guint64 delta = g_resets - before;

    g_checks++;
    if (delta == expected_resets) {
        printf("    PASS: observed exactly %u WDT reset%s\n", expected_resets,
               expected_resets == 1u ? "" : "s");
    } else {
        g_fails++;
        char const *reason = expected_resets == 0u
            ? "  [unexpected reset path fired]"
            : (delta > 1u ? "  [reset-loop: is gpsim retaining the corrupted"
                            " watchdog-period register?]"
                          : "  [gate did not fire?]");
        printf("    FAIL: %" G_GUINT64_FORMAT " resets in %u ms (want exactly %u)%s\n",
               delta, WDT_RESET_WINDOW_MS, expected_resets, reason);
    }
    if (expected_resets == 0u) {
        r->put_value(cur); // restore negative-control faults that intentionally do not reset
        g_checks++;
        if ((r->get_value() & 0xFFu) != cur) {
            g_fails++;
            fprintf(stderr, "    FAIL: could not restore register after negative control\n");
        }
    }
    fflush(stdout);
}

// No-injection control: a quiescent device must NOT reset in a full window.
static void control_case(void) {
    footsw_set(0);
    if (!run_ms(SETTLE_MS)) {
        g_checks++;
        g_fails++;
        return;
    }
    guint64 before = g_resets;
    printf("  control (no injection)\n");
    fflush(stdout);
    if (!run_ms(WDT_RESET_WINDOW_MS)) {
        g_checks++;
        g_fails++;
        return;
    }
    guint64 delta = g_resets - before;
    g_checks++;
    if (delta == 0u) {
        printf("    PASS: quiescent device did not reset\n");
    } else {
        g_fails++;
        printf("    FAIL: %" G_GUINT64_FORMAT " spurious reset(s) with no injection\n", delta);
    }
    fflush(stdout);
}

// init() must establish the exact footswitch-only pull-up mask before globally
// enabling pull-ups; preserving the output pins' latches would let a later
// direction fault activate a pull-up against the fail-safe pull-down.
static void check_startup_wpu(void) {
    Register *r = fetch_sfr(PIC_REG_WPU_ADDR, PIC_REG_WPU_TOKEN);
    g_checks++;
    if (r == nullptr) { g_fails++; return; }
    unsigned const val = r->get_value() & PIC_REG_WPU_MASK;
    if (val == PIC_REG_WPU_INIT) {
        printf("  PASS: startup " PIC_REG_WPU_NAME " is " PIC_REG_WPU_DESC "\n");
    } else {
        g_fails++;
        printf("  FAIL: startup " PIC_REG_WPU_NAME " is 0x%02x"
               " (want exact " PIC_REG_WPU_DESC ")\n", val);
    }
}

static void check_startup_tris(void) {
    Register *r = fetch_sfr(PIC_REG_TRIS_ADDR, PIC_REG_TRIS_TOKEN);
    g_checks++;
    if (r == nullptr) { g_fails++; return; }
    unsigned const val = r->get_value() & PIC_REG_PORT_MASK;
    if (val == PIC_REG_TRIS_INIT) {
        printf("  PASS: startup " PIC_REG_TRIS_NAME " is " PIC_REG_TRIS_DESC "\n");
    } else {
        g_fails++;
        printf("  FAIL: startup " PIC_REG_TRIS_NAME " is 0x%02x"
               " (want exact " PIC_REG_TRIS_INIT_STR ")\n", val);
    }
}

int main() {
    if (!gpsim_bootstrap_cpu(FW_PATH, PROC_NAME))            return 1;
    if (!gpsim_attach_footswitch(FOOTSW_PIN_NAME, PROC_NAME)) return 1;

    footsw_set(0);                              // released at power-on
    if (!run_ms(SETTLE_MS)) {                   // let init() settle, reach main loop
        return 1;
    }

    // Arm reset counting only now (skip the power-on pass through 0x000).
    get_bp().set_notify_break(g_cpu, 0x000, &g_reset_notifier);

    printf("FAULT-INJECT START: fw=%s proc=%s FOSC=%lu window=%u ms\n"
           "  (NB: gpsim WDT@WDTPS=0x08 ~1.057s -- recovery reset, not 256ms silicon)\n",
           FW_PATH, PROC_NAME, (unsigned long)F_CPU_HZ, WDT_RESET_WINDOW_MS);
    fflush(stdout);

    // Negative control first, then one case per guarded location.
    check_startup_wpu();
    check_startup_tris();
    if (!identify_loop_clrwdt()) {
        printf("\nFAULT-INJECT FAIL: %u checks, %u failures\n", g_checks, g_fails);
        return 1;
    }
    control_case();

    // Output directions (hw_is_sanity_check_failed).
    PIC_FAULT_DIRECTION_INJECTIONS();

    // The output latch, whose guard policy is the one thing that differs
    // BETWEEN parts of a family rather than between families: PIC10F322 guards
    // its settled latch, PIC10F320 has no general latch guard but its relay
    // adapter requires idle correction of both coil bits.
    PIC_FAULT_EXTRA_OUTPUT_INJECTIONS();

    // Clock / tick / analog config SFRs (hw_critical_sfrs_intact).
    PIC_FAULT_CONFIG_INJECTIONS();

    // Weak pull-ups (hw_footswitch_pullup_intact).
    PIC_FAULT_PULLUP_INJECTIONS();

    // ctx_ SRAM range checks (see the ctx_ note in the header comment)
    inject_case("ctx.program_state",    CTX_PROGRAM_STATE,    nullptr, true, 0x02, 1,
                PIC_FAULT_PROGRAM_STATE_NOTE);
    inject_case("ctx.effect_state",     CTX_EFFECT_STATE,     nullptr, true, 0x02, 1,
                "->2: > ENGAGED (gate-only)");
    inject_case("ctx.debounce_counter", CTX_DEBOUNCE_COUNTER, nullptr, true, 0xFF, 1,
                "->255: > RELEASE_THRESH (gate-only)");

#if defined(BYPASS_CTX_CHECK)
    // F2 context-SEU: an IN-RANGE single-bit flip the range clauses above cannot
    // see. 0x10 = 16, with PRESSED_THRESH(8) <= 16 <= RELEASE_THRESH(25), so the
    // gate's `ctx_.debounce_counter > RELEASE_THRESH` clause stays FALSE -- the
    // pre-F2 firmware would have silently phantom-toggled on this value. The only
    // clause that fires is the complemented XOR-fold shadow mismatch
    // (ctx_check_ != debounce_ctx_check_word(ctx_)), which is first in the gate
    // (see bypass_mcu_pic10f322.c / bypass_mcu_pic12f675.c). inject_case parks the
    // write at the loop CLRWDT, AFTER the tick's shadow refresh and BEFORE the
    // next gate, so that gate reads the corrupted counter against the stale
    // shadow -> exactly one WDT reset. Compiled only where the firmware opts into
    // BYPASS_CTX_CHECK (PIC10F322 / PIC12F675); PIC10F320 is EXCLUDED and never
    // defines the macro (docs/context_seu_detection.md), so this case and its
    // EXPECTED_CHECKS contribution both vanish there.
    inject_case("ctx.debounce.inrange", CTX_DEBOUNCE_COUNTER, nullptr, true, 0x10, 1,
                "->16: in range, only the F2 XOR-fold shadow catches");
#endif

    if (g_checks != EXPECTED_CHECKS) {
        g_fails++;
        fprintf(stderr, "FAIL: executed %u checks, expected %u for this variant\n",
                g_checks, EXPECTED_CHECKS);
    }

    int pass = (g_fails == 0);
    printf("\nFAULT-INJECT %s: %u checks, %u failures\n",
           pass ? "PASS" : "FAIL", g_checks, g_fails);
    pic_target_result("fault", pass != 0, g_checks, g_fails);
    return pass ? 0 : 1;
}

#endif
