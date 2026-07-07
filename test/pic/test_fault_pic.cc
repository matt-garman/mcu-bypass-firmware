// Fault-injection test for the PIC10F322 shell's per-tick sanity gate -- the PIC
// analogue of the AVR simavr `inject_config_sfr` tests in test/avr/test_sim.c. It
// links libgpsim, drives the real built HEX, corrupts a guarded location at
// runtime (an SEU/EMI single-event-upset model), and asserts the firmware DETECTS
// the corruption and RECOVERS via a watchdog reset -- exactly what the main-loop
// gate + hw_force_wdt_reset() promise.
//
// COVERAGE -- every location the gate guards:
//   * config SFRs    OSCCON.IRCF / WDTCON.WDTPS / PR2 / T2CON (hw_critical_sfrs_intact)
//   * pull-up SFRs   WPUA (RA3 latch) + OPTION_REG.nWPUEN     (hw_footswitch_pullup_intact)
//   * ctx_ SRAM      program_state / effect_state / debounce_counter (range checks)
// The ctx_ cases run only when CTX_ADDR is passed (the Makefile extracts _ctx_'s
// data address from the XC8 .sym so the test self-adjusts per variant); they are
// skipped with a note otherwise.
//
// WHY THIS IS THE MIRROR IMAGE OF THE SOAK (test/pic/test_soak_pic.cc):
// the polled PIC shell has no recovery path OTHER than the watchdog. When the
// per-tick gate sees a skewed SFR it calls hw_force_wdt_reset(), which clears
// GIE and spins in for(;;){} -- it simply STOPS petting the dog, so the fault
// surfaces as a WDT reset that re-vectors to 0x000. That is the identical event
// the soak's ResetNotifier detects, EXCEPT the soak treats a reset as a FAILURE
// while this test treats exactly one reset as the expected PASS. So this driver
// reuses the soak's proven notify-break-at-0x000 machinery and inverts the
// verdict.
//
// SCENARIO (per injection case):
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
// CORRUPTION VALUES are chosen so the main loop keeps running and the GATE is
// the sole reset path (confound analysis, per case, below). OSCCON.IRCF and
// WDTCON.WDTPS are the cleanest: no other firmware logic reads them and the loop
// keeps petting, so absent the gate there is provably NO reset -- a WDTPS skew
// is otherwise entirely silent. PR2/T2CON are also read by the TMR2 hardware, so
// their corruption is kept tick-preserving (T2CON keeps TMR2ON set; PR2 stays a
// valid period) so the reset is the gate, not a wedged tick. The pull-up SFRs
// are gate-only too: the footswitch is externally driven here, so disabling the
// pull-up does not change the pin -- only the gate's check reacts.
//
// The ctx_ cases differ subtly. effect_state and debounce_counter are copied
// through debounce_step unchanged when the device is quiescent (no toggle), so a
// single injection persists to the next gate check -- and they are caught ONLY by
// the gate (gate discriminators, like the SFRs). program_state is DIFFERENT: an
// out-of-range value also drives debounce_step into its `default:` -> res.fault
// path, so main() resets via the pure core's belt-and-suspenders too; it is
// therefore redundantly protected (defense in depth), not a pure gate
// discriminator. All three still yield exactly one reset, which is the assertion.
//
// Build/run via the Makefile:  `make pic-test-fault`
//   STANDALONE -- like pic-test-soak it links libgpsim (needs gpsim-dev +
//   libglib2.0-dev) and is NOT part of `make test`/`pic-test` (whose PIC leg,
//   pic-test-gpsim, needs only the gpsim CLI). Skips cleanly when the compiler,
//   those headers, or the built HEX are absent. The gate is variant-agnostic
//   (all three output shells share main()'s gate), so this is variant-agnostic
//   too; PIC_FAULT_VARIANT only selects which HEX is loaded.
//
// IMPORTANT (gpsim WDT calibration; see test_soak_pic.cc): gpsim honors
// WDTCON.WDTPS but does NOT match the datasheet -- at the firmware's WDTPS=0x08
// the gpsim WDT period is ~1.057 s, not the silicon ~256 ms. The recovery reset
// therefore takes ~1.06 s of simulated time here; WDT_RESET_WINDOW_MS carries
// margin over that. This test asserts nothing about WDT TIMING, only that the
// reset happens within a generous window.

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cctype>
#include <string>
#include <iostream>

#include <glib.h>                 // guint64
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

// gpsim narrates breakpoint/load activity on std::cout; a null streambuf
// silences it (our own output uses C stdio, so printf is unaffected).
struct NullBuf : std::streambuf { int overflow(int c) override { return c; } };
static NullBuf g_nullbuf;

// ---- Firmware / MCU parameters (injected by the Makefile build rule) --------
#ifndef FW_PATH
#  define FW_PATH  "build_pic/bypass_cd4053_pic10f322.hex"
#endif
#ifndef PROC_NAME
#  define PROC_NAME "p10f322"
#endif
#ifndef F_CPU_HZ
#  define F_CPU_HZ 2000000UL           // FOSC; instruction clock = FOSC/4
#endif
#define CYCLES_PER_MS  ((F_CPU_HZ / 4UL) / 1000UL)   // 500 @ 2 MHz

// PIC pin map (src/bypass_pins_pic10f322.h): RA3 footswitch (1=released,
// 0=pressed), RA0 = LED on LATA bit0.
#define FOOTSW_PIN_NAME "ra3"

// ---- Guarded-SFR addresses (PIC10F322 DFP header; gpsim mirrors these; the
// soak proves gpsim's rma uses the SAME file addresses, e.g. LATA@0x07). Each is
// cross-checked against the register's gpsim name at runtime (fetch_sfr) so an
// address drift is surfaced rather than silently corrupting the wrong register.
#define WPUA_ADDR    0x009u  // RA3 weak-pull-up latch = bit 3 (mask 0x08)
#define OSCCON_ADDR  0x010u
#define PR2_ADDR     0x012u
#define T2CON_ADDR   0x013u
#define OPTION_ADDR  0x00Eu  // OPTION_REG; nWPUEN (global pull-up enable) = bit 7
#define WDTCON_ADDR  0x030u

// ctx_ (debounce_context_t, src/bypass_types.h) is file-static SRAM; the Makefile
// passes CTX_ADDR = _ctx_'s data address (from the XC8 .sym). Field OFFSETS follow
// the struct order (program_state, effect_state, debounce_counter), each a 1-byte
// object as XC8 lays them out -- confirmed against the generated .s ((_ctx_),
// (_ctx_+1), (_ctx_+2)). ctx_ is a GPR, so its gpsim register has no meaningful
// name: pass a null token to fetch_sfr to skip the name cross-check.
#ifdef CTX_ADDR
#  define CTX_PROGRAM_STATE     ((unsigned)(CTX_ADDR) + 0u)
#  define CTX_EFFECT_STATE      ((unsigned)(CTX_ADDR) + 1u)
#  define CTX_DEBOUNCE_COUNTER  ((unsigned)(CTX_ADDR) + 2u)
#endif

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

// ---- Sim globals ------------------------------------------------------------
static pic_processor   *g_cpu      = nullptr;
static Stimulus_Node   *g_fsw_node = nullptr;
static source_stimulus *g_fsw_src  = nullptr;
static guint64   g_resets  = 0;   // incremented by ResetNotifier at 0x000
static unsigned  g_checks  = 0;
static unsigned  g_fails   = 0;

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
static IOPIN *find_pin(Module *m, const char *name) {
    for (int i = 1; i <= m->get_pin_count(); ++i) {
        std::string &pn = m->get_pin_name((unsigned)i);
        if (pn == name) return m->get_pin((unsigned)i);
    }
    return nullptr;
}

// Drive the footswitch input: 1 = released (high), 0 = pressed (low). See the
// soak for why set_Vth (not putState) and the low Zth (dominate RA3's pull-up).
static void footsw_set(int pressed) {
    g_fsw_src->set_Vth(pressed ? 0.0 : 5.0);
    g_fsw_node->update();
}

// Fetch a register by file address and (for named SFRs) cross-check its gpsim
// name contains the expected token (lowercase). A mismatch warns but does not
// abort: the address is authoritative (from the DFP header, proven by the soak),
// and gpsim naming quirks should not fail an otherwise-correct injection. Pass
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
            fprintf(stderr, "WARN: register at 0x%03x is named '%s', expected '%s'\n",
                    addr, r->name().c_str(), token);
        }
    }
    return r;
}

// Advance the simulation by `ms` ms of simulated time. Cycle break at the
// target; resume run() until the target cycle is reached (a WDT reset may halt
// run() early and/or fire the notify callback -- either way we resume).
static void run_ms(unsigned ms) {
    guint64 target = get_cycles().get() + (guint64)ms * CYCLES_PER_MS;
    get_cycles().set_break(target);
    int resumes = 0;
    while (get_cycles().get() < target) {
        g_cpu->run(false);
        if (++resumes > MAX_RESUMES_PER_MS) {
            fprintf(stderr, "FATAL: core not advancing (wedged?) at run_ms\n");
            get_cycles().clear_break(target);
            return;
        }
    }
}

// After settle the firmware loops forever, so init()'s one-shot CLRWDT is never
// revisited -- the ONLY CLRWDT reached in quiescent steady state is the main
// loop's "pet the dog", the last instruction before looping back to the tick
// poll. Single-step (via run(false), which -- unlike step_one -- services
// peripherals) until the opcode at the PC is that CLRWDT, so a subsequent
// injection lands at a DETERMINISTIC, gate-before-integrate loop phase: the next
// iteration's sanity gate reads the corruption before debounce_step (which
// rewrites ctx_ every tick) can overwrite it. Detecting the opcode rather than a
// hardcoded address keeps this variant-independent -- the loop CLRWDT sits at a
// different program address in each output variant (0x05a / 0x05d / 0x078 here).
// Caps the search at a few ticks' worth of cycles so a wedged core cannot spin
// forever.
//
// Without this, injecting at whatever loop phase the ms-based settle happens to
// halt on is a race: at 2 MHz every variant lands some ctx_ case in the
// integrate-before-gate window, the integrator overwrites the injected field, and
// the gate never sees it -> 0 resets -> false FAIL. (16 MHz happened to land safe
// phases, which is why the parent never flagged it.)
#define CLRWDT_OPCODE 0x0064u
static void advance_to_loop_clrwdt(void) {
    for (int i = 0; i < 8000; ++i) {
        unsigned pc = g_cpu->pc->get_value();
        if (g_cpu->pma->get_opcode(pc) == CLRWDT_OPCODE)
            return;
        guint64 c = get_cycles().get() + 1;
        get_cycles().set_break(c);
        g_cpu->run(false);
        get_cycles().clear_break(c);
    }
    fprintf(stderr, "WARN: never reached loop CLRWDT (opcode 0x%04x) -- layout changed?\n",
            CLRWDT_OPCODE);
}

// ---- One injection case -----------------------------------------------------
// absolute=true writes `val`; absolute=false writes (current ^ val), i.e. an
// SEU bit-flip of the bits in `val`. Asserts EXACTLY ONE recovery reset.
static void inject_case(const char *label, unsigned addr, const char *token,
                        bool absolute, unsigned val, const char *note) {
    footsw_set(0);                 // released: quiescent, only the SFR can trip
    run_ms(SETTLE_MS);             // (re)reach the main loop after any prior reset
    advance_to_loop_clrwdt();      // park at a deterministic loop phase (see note)

    Register *r = fetch_sfr(addr, token);
    if (r == nullptr) { g_checks++; g_fails++; return; }

    unsigned cur = r->get_value() & 0xFFu;
    unsigned bad = absolute ? (val & 0xFFu) : (cur ^ val);

    guint64 before = g_resets;
    r->put_value(bad);
    printf("  inject %-13s @0x%03x: 0x%02x -> 0x%02x  (%s)\n",
           label, addr, cur, bad, note);
    fflush(stdout);

    run_ms(WDT_RESET_WINDOW_MS);
    guint64 delta = g_resets - before;

    g_checks++;
    if (delta == 1u) {
        printf("    PASS: gate forced exactly 1 WDT reset\n");
    } else {
        g_fails++;
        printf("    FAIL: %" G_GUINT64_FORMAT " resets in %u ms (want exactly 1)%s\n",
               delta, WDT_RESET_WINDOW_MS,
               delta > 1u ? "  [reset-loop: is gpsim retaining corrupted WDTCON?]"
                          : "  [gate did not fire?]");
    }
    fflush(stdout);
}

// No-injection control: a quiescent device must NOT reset in a full window.
static void control_case(void) {
    footsw_set(0);
    run_ms(SETTLE_MS);
    guint64 before = g_resets;
    printf("  control (no injection)\n");
    fflush(stdout);
    run_ms(WDT_RESET_WINDOW_MS);
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

    IOPIN *ra3 = find_pin(g_cpu, FOOTSW_PIN_NAME);
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
    run_ms(SETTLE_MS);                          // let init() settle, reach main loop

    // Arm reset counting only now (skip the power-on pass through 0x000).
    get_bp().set_notify_break(g_cpu, 0x000, &g_reset_notifier);

    printf("FAULT-INJECT START: fw=%s proc=%s FOSC=%lu window=%u ms\n"
           "  (NB: gpsim WDT@WDTPS=0x08 ~1.057s -- recovery reset, not 256ms silicon)\n",
           FW_PATH, PROC_NAME, (unsigned long)F_CPU_HZ, WDT_RESET_WINDOW_MS);
    fflush(stdout);

    // Negative control first, then one case per guarded location.
    control_case();

    // config SFRs (hw_critical_sfrs_intact)
    inject_case("OSCCON.IRCF",  OSCCON_ADDR, "osccon", false, 0x10,
                "IRCF 0b100->0b101: 2MHz->4MHz clock skew");
    inject_case("WDTCON.WDTPS", WDTCON_ADDR, "wdtcon", false, 0x10,
                "WDTPS 0b01000->0b00000: 1:8192->1:32, WDT miscalibrated (else silent)");
    inject_case("PR2",          PR2_ADDR,    "pr2",    true,  99,
                "tick period 124->99: 1ms tick skewed");
    inject_case("T2CON",        T2CON_ADDR,  "t2con",  false, 0x01,
                "T2CKPS 1:4->1:1, TMR2ON preserved: timer cfg skew");

    // pull-up SFRs (hw_footswitch_pullup_intact) -- footswitch is externally
    // driven, so the pin stays released; only the gate's check reacts.
    inject_case("WPUA.RA3",     WPUA_ADDR,   "wpu",    false, 0x08,
                "clear RA3 pull-up latch: footswitch weak pull-up disabled");
    inject_case("OPTION.nWPUEN",OPTION_ADDR, "option", false, 0x80,
                "set nWPUEN: global weak pull-ups disabled");

    // ctx_ SRAM range checks (see the ctx_ note in the header comment)
#ifdef CTX_ADDR
    inject_case("ctx.program_state",    CTX_PROGRAM_STATE,    nullptr, true, 0x02,
                "0->2: > RELEASE_DEBOUNCE_WAIT (also core res.fault)");
    inject_case("ctx.effect_state",     CTX_EFFECT_STATE,     nullptr, true, 0x02,
                "->2: > ENGAGED (gate-only)");
    inject_case("ctx.debounce_counter", CTX_DEBOUNCE_COUNTER, nullptr, true, 0xFF,
                "->255: > RELEASE_THRESH (gate-only)");
#else
    printf("  (ctx_ SRAM cases skipped: no CTX_ADDR -- pass -DCTX_ADDR=0x<_ctx_> from the .sym)\n");
#endif

    int pass = (g_fails == 0);
    printf("\nFAULT-INJECT %s: %u checks, %u failures\n",
           pass ? "PASS" : "FAIL", g_checks, g_fails);
    return pass ? 0 : 1;
}
