// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// Include-only implementation shared by the PIC10F320 and PIC10F322 adapters.
// Each adapter pins its processor, image, program-space limit, independent check
// count, output-variant vocabulary, and output-latch fault policy before including
// this file. Keeping those facts outside the common mechanism makes accidental
// cross-part drift visible while eliminating duplicated simulator logic.
//
// This test links libgpsim, drives a real built HEX, corrupts a guarded location
// at runtime (an SEU/EMI single-event-upset model), and asserts that the firmware
// detects the corruption and recovers via a watchdog reset on the simulated core.
//
// COMMON COVERAGE:
//   * output SFRs    TRISA (exact output directions)
//   * config SFRs    OSCCON.IRCF / WDTCON.WDTPS / PR2 / T2CON / ANSELA
//   * pull-up SFRs   WPUA (exactly RA3 latched, RA0..RA2 clear) +
//                    OPTION_REG.nWPUEN
//   * ctx_ SRAM      program_state / effect_state / debounce_counter (range checks)
// PIC10F322 additionally injects LATA.RA0..RA2 because that firmware guards its
// settled output latch. PIC10F320 deliberately omits that guard for flash budget,
// so its adapter supplies no LATA cases. The literal per-part expected counts
// ensure a missing case cannot silently reduce either lane.
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
// phantom resets and the gate does not fire spuriously. That control is now the
// ONLY delta == 0 assertion here: since the exact-TRISA port every injection
// below is a guarded fault expecting exactly one reset, identically on all three
// variants. (Before the port, cd4053-simple carried an extra write-back-verified
// negative injection -- its spare RA2 sat outside the old per-variant mask.
// Exact TRISA covers RA2 too, so both that blind spot and the variant split in
// these expectations are gone; see EXPECTED_CHECKS below.)
//
// CORRUPTION VALUES are chosen so the main loop keeps running and the GATE is
// the sole reset path (confound analysis, per case, below). OSCCON.IRCF and
// WDTCON.WDTPS are the cleanest: no other firmware logic reads them and the loop
// keeps petting, so absent the gate there is provably NO reset -- a WDTPS skew
// is otherwise entirely silent. PR2/T2CON are also read by the TMR2 hardware, so
// their corruption is kept tick-preserving (T2CON keeps TMR2ON set; PR2 stays a
// valid period) so the reset is the gate, not a wedged tick. ANSELA and the
// pull-up SFRs are gate-only too: the footswitch is externally driven here, so
// re-selecting an output pin analog / disabling the pull-up does not change the
// footswitch pin -- only the gate's check reacts.
//
// The ctx_ cases differ subtly. effect_state and debounce_counter persist until
// the next gate check while the device is quiescent. An out-of-range
// program_state also reaches a belt-and-suspenders state-machine fault path; the
// adapter's diagnostic names the pure-core or hand-inlined path for its part.
//
// Build/run via `make pic-test-fault` or `make pic320-test-fault-target`. The
// fail-closed `pic-test-target-variants` and `pic320-test-target-variants`
// aggregates run their respective adapter for every supported output variant.
//
// IMPORTANT (gpsim WDT calibration; see test_soak_pic.cc): gpsim honors
// WDTCON.WDTPS but does NOT match the datasheet -- at the firmware's WDTPS=0x08
// the gpsim WDT period is ~1.057 s, not the silicon ~256 ms. The recovery reset
// therefore takes ~1.06 s of simulated time here; WDT_RESET_WINDOW_MS carries
// margin over that. This test asserts nothing about WDT TIMING, only that the
// reset happens within a generous window.

#ifndef TEST_PIC_TEST_FAULT_PIC_CORE_H
#define TEST_PIC_TEST_FAULT_PIC_CORE_H

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cctype>
#include <string>
#include <vector>
#include <iostream>

#include <glib.h>                 // guint64, G_GUINT64_FORMAT
#include "interface.h"            // initialize_gpsim_core(), gpsim_set_bulk_mode()
#include "sim_context.h"          // CSimulationContext
#include "processor.h"            // Processor (rma, run)
#include "pic-processor.h"        // pic_processor
#include "modules.h"              // Module::get_pin/get_pin_name/get_pin_count
#include "ioports.h"              // IOPIN
#include "stimuli.h"              // Stimulus_Node, source_stimulus
#include "gpsim_time.h"           // get_cycles(), Cycle_Counter
#include "breakpoints.h"          // get_bp(), set_notify_break
#include "trigger.h"              // TriggerObject
#include "registers.h"            // Register::get_value()/put_value()/name()
#include "pic/find_pin_exact.h"

// gpsim narrates breakpoint/load activity on std::cout; a null streambuf
// silences it (our own output uses C stdio, so printf is unaffected).
struct NullBuf : std::streambuf { int overflow(int c) override { return c; } };
static NullBuf g_nullbuf;

// ---- Firmware / MCU parameters (provided by the part adapter / Makefile) -----
#ifndef PIC_FAULT_DEFAULT_FW_PATH
#  error "PIC_FAULT_DEFAULT_FW_PATH must be defined by the part adapter"
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
#ifndef FW_PATH
#  define FW_PATH PIC_FAULT_DEFAULT_FW_PATH
#endif
#ifndef PROC_NAME
#  define PROC_NAME PIC_FAULT_DEFAULT_PROC_NAME
#endif
#ifndef F_CPU_HZ
#  define F_CPU_HZ 2000000UL           // FOSC; instruction clock = FOSC/4
#endif
#define CYCLES_PER_MS  ((F_CPU_HZ / 4UL) / 1000UL)   // 500 @ 2 MHz
#define CLRWDT_OPCODE  0x0064u

// Shared pin map: RA3 footswitch (1=released, 0=pressed), RA0 LED on LATA bit 0.
#define FOOTSW_PIN_NAME "ra3"

// ---- SFR addresses shared by the PIC10F320/PIC10F322 DFP headers ------------
// Each is cross-checked against the register's gpsim name at runtime so an
// address drift is surfaced rather than silently corrupting the wrong register.
#define WPUA_ADDR    0x009u  // RA3 weak-pull-up latch = bit 3 (mask 0x08)
#define TRISA_ADDR   0x006u  // RA3 input; RA0..RA2 outputs after init (0x08)
#define LATA_ADDR    0x007u  // LED/control output latch (mask 0x07)
#define OPTION_ADDR  0x00Eu  // OPTION_REG; nWPUEN (global pull-up enable) = bit 7
#define OSCCON_ADDR  0x010u  // IRCF = bits 6:4 (mask 0x70)
#define PR2_ADDR     0x012u
#define T2CON_ADDR   0x013u
#define ANSELA_ADDR  0x008u  // ANSA0..ANSA2 = bits 0..2 (RA0..RA2 analog select)
#define WDTCON_ADDR  0x030u  // WDTPS = bits 5:1 (mask 0x3E)

// ctx_ is file-static SRAM in both firmware parts. The Makefile passes its .sym
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
static pic_processor   *g_cpu      = nullptr;
static Stimulus_Node   *g_fsw_node = nullptr;
static source_stimulus *g_fsw_src  = nullptr;
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
// Drive the footswitch input: 1 = released (high), 0 = pressed (low). See the
// soak for why set_Vth (not putState) and the low Zth (dominate RA3's pull-up).
static void footsw_set(int pressed) {
    g_fsw_src->set_Vth(pressed ? 0.0 : 5.0);
    g_fsw_node->update();
}

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

// ---- One injection case -----------------------------------------------------
// absolute=true writes `val`; absolute=false writes (current ^ val), i.e. an
// SEU bit-flip of the bits in `val`. Every call site passes expected_resets == 1
// since the exact-TRISA port made all three variants guard the same directions;
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
            : (delta > 1u ? "  [reset-loop: is gpsim retaining corrupted WDTCON?]"
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

// init() must establish the exact RA3-only mask before globally enabling pull-ups;
// preserving RA0..RA2 would let a later direction fault activate a pull-up against
// the fail-safe pull-down.
static void check_startup_wpua(void) {
    Register *r = fetch_sfr(WPUA_ADDR, "wpu");
    g_checks++;
    if (r == nullptr) { g_fails++; return; }
    unsigned const val = r->get_value() & 0x0Fu;
    if (val == 0x08u) {
        printf("  PASS: startup WPUA is RA3-only (0x08)\n");
    } else {
        g_fails++;
        printf("  FAIL: startup WPUA is 0x%02x (want exact RA3-only 0x08)\n", val);
    }
}

static void check_startup_trisa(void) {
    Register *r = fetch_sfr(TRISA_ADDR, "tris");
    g_checks++;
    if (r == nullptr) { g_fails++; return; }
    unsigned const val = r->get_value() & 0x0Fu;
    if (val == 0x08u) {
        printf("  PASS: startup TRISA is RA3 input, RA0..RA2 outputs (0x08)\n");
    } else {
        g_fails++;
        printf("  FAIL: startup TRISA is 0x%02x (want exact 0x08)\n", val);
    }
}

int main() {
    std::cout.rdbuf(&g_nullbuf);                 // silence gpsim's console chatter
    initialize_gpsim_core();
    gpsim_set_bulk_mode(1);
    CSimulationContext *ctx = CSimulationContext::GetContext();

    Processor *p = nullptr;
    ctx->LoadProgram(FW_PATH, PROC_NAME, &p, "u1");
    if (p == nullptr) p = ctx->GetActiveCPU();
    if (p == nullptr) {
        fprintf(stderr, "FATAL: gpsim could not load %s on %s\n", FW_PATH, PROC_NAME);
        return 1;
    }
    g_cpu = static_cast<pic_processor *>(p);

    IOPIN *ra3 = find_pin_exact(g_cpu, FOOTSW_PIN_NAME);
    if (ra3 == nullptr) {
        fprintf(stderr, "FATAL: pin %s not found on %s\n", FOOTSW_PIN_NAME, PROC_NAME);
        return 1;
    }
    g_fsw_src = new source_stimulus();
    g_fsw_src->set_digital();
    g_fsw_src->set_Zth(250.0);                   // dominate RA3's weak pull-up
    g_fsw_src->set_Vth(5.0);                     // released at power-on
    g_fsw_node = new Stimulus_Node("fsw");
    g_fsw_node->attach_stimulus(g_fsw_src);
    g_fsw_node->attach_stimulus(ra3);

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
    check_startup_wpua();
    check_startup_trisa();
    if (!identify_loop_clrwdt()) {
        printf("\nFAULT-INJECT FAIL: %u checks, %u failures\n", g_checks, g_fails);
        return 1;
    }
    control_case();

    // Output directions (hw_is_sanity_check_failed). The gate compares TRISA
    // exactly against its init() value, so all three output directions are
    // guarded on every variant -- including cd4053-simple's spare RA2, which
    // used to be a negative control here.
    inject_case("TRISA.RA0", TRISA_ADDR, "tris", false, 0x01, 1,
                "RA0 changed from output to input");
    inject_case("TRISA.RA1", TRISA_ADDR, "tris", false, 0x02, 1,
                "RA1 changed from output to input");
    inject_case("TRISA.RA2", TRISA_ADDR, "tris", false, 0x04, 1,
                "RA2 changed from output to input");

    // PIC10F322 guards its settled output latch; PIC10F320 deliberately does not.
    PIC_FAULT_EXTRA_OUTPUT_INJECTIONS();

    // config SFRs (hw_critical_sfrs_intact)
    inject_case("OSCCON.IRCF",  OSCCON_ADDR, "osccon", false, 0x10, 1,
                "IRCF 0b100->0b101: 2MHz->4MHz clock skew");
    inject_case("WDTCON.WDTPS", WDTCON_ADDR, "wdtcon", false, 0x10, 1,
                "WDTPS 0b01000->0b00000: 1:8192->1:32, WDT miscalibrated (else silent)");
    inject_case("PR2",          PR2_ADDR,    "pr2",    true,  99, 1,
                "tick period 124->99: 1ms tick skewed");
    inject_case("T2CON",        T2CON_ADDR,  "t2con",  false, 0x01, 1,
                "T2CKPS 1:4->1:1, TMR2ON preserved: timer cfg skew");
    // The ANSELA gate masks the fixed RA0|RA1|RA2 (BYPASS_OUTPUT_DDR_MASK) on every
    // variant, so re-selecting ANY output pin analog must recover via one reset --
    // not just RA0 (a narrowed mask that only checked RA0 would slip RA1/RA2 past).
    inject_case("ANSELA.RA0",   ANSELA_ADDR, "ansel",  false, 0x01, 1,
                "ANSA0=1: RA0 (LED) re-selected analog, out of digital service");
    inject_case("ANSELA.RA1",   ANSELA_ADDR, "ansel",  false, 0x02, 1,
                "ANSA1=1: RA1 (control pin) re-selected analog, out of digital service");
    inject_case("ANSELA.RA2",   ANSELA_ADDR, "ansel",  false, 0x04, 1,
                "ANSA2=1: RA2 (control pin) re-selected analog, out of digital service");

    // pull-up SFRs (hw_footswitch_pullup_intact) -- footswitch is externally
    // driven, so the pin stays released; only the gate's check reacts.
    inject_case("WPUA.RA3",     WPUA_ADDR,   "wpu",    false, 0x08, 1,
                "clear RA3 pull-up latch: footswitch weak pull-up disabled");
    inject_case("WPUA.RA0",     WPUA_ADDR,   "wpu",    false, 0x01, 1,
                "set RA0 output-pin pull-up latch: exact RA3-only mask violated");
    inject_case("WPUA.RA1",     WPUA_ADDR,   "wpu",    false, 0x02, 1,
                "set RA1 output-pin pull-up latch: exact RA3-only mask violated");
    inject_case("WPUA.RA2",     WPUA_ADDR,   "wpu",    false, 0x04, 1,
                "set RA2 output-pin pull-up latch: exact RA3-only mask violated");
    inject_case("OPTION.nWPUEN",OPTION_ADDR, "option", false, 0x80, 1,
                "set nWPUEN: global weak pull-ups disabled");

    // ctx_ SRAM range checks (see the ctx_ note in the header comment)
    inject_case("ctx.program_state",    CTX_PROGRAM_STATE,    nullptr, true, 0x02, 1,
                PIC_FAULT_PROGRAM_STATE_NOTE);
    inject_case("ctx.effect_state",     CTX_EFFECT_STATE,     nullptr, true, 0x02, 1,
                "->2: > ENGAGED (gate-only)");
    inject_case("ctx.debounce_counter", CTX_DEBOUNCE_COUNTER, nullptr, true, 0xFF, 1,
                "->255: > RELEASE_THRESH (gate-only)");

    if (g_checks != EXPECTED_CHECKS) {
        g_fails++;
        fprintf(stderr, "FAIL: executed %u checks, expected %u for this variant\n",
                g_checks, EXPECTED_CHECKS);
    }

    int pass = (g_fails == 0);
    printf("\nFAULT-INJECT %s: %u checks, %u failures\n",
           pass ? "PASS" : "FAIL", g_checks, g_fails);
    return pass ? 0 : 1;
}

#endif
