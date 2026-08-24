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
// This test links libgpsim, drives a real built HEX, and corrupts a selected
// location at runtime (an SEU/EMI single-event-upset model). Every guarded
// fault -- relay coils included -- requires watchdog recovery; the relay cases
// additionally require the two halves of the F1 fail-safe contract
// (de-energization, then a complete resynchronizing actuation).
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
// guards the complete settled latch; PIC10F320 deliberately omits that general
// guard for flash budget and guards only the two coil latch bits its relay
// variant cannot afford to lose; and PIC12F675 has no latch REGISTER at all, so
// it injects into the SRAM shadow that serves as one and into modeled
// GPIO/readback state, which the gate requires to follow it. What is now COMMON
// across all three is the response: an energized coil resets. The literal
// per-part expected counts ensure a missing case cannot silently reduce any
// lane.
//
// CTX_ADDR is required. The Makefile extracts _ctx_'s data address from the XC8
// .sym so the test self-adjusts per variant and cannot pass with SRAM cases
// silently omitted.
//
// WHY RESET-PRODUCING CASES MIRROR THE SOAK (test/pic/test_soak_pic.cc): when
// the per-tick gate sees a guarded fault it calls hw_force_wdt_reset(), which
// de-energizes the relay coils, clears GIE and spins in for(;;){} -- it simply
// STOPS petting the dog, so the fault surfaces as a WDT reset that re-vectors
// to 0x000. That is the identical event the soak's ResetNotifier detects,
// except the soak treats a reset as failure while these cases require exactly
// one. Relay cases require that same single reset and additionally measure the
// recovery actuation (inject_relay_resync_case).
//
// SCENARIO (`inject_case()` reset and correction cases):
//   1. Hold the footswitch RELEASED so the device is quiescent -- the debounce
//      context stays in range and the pull-up stays intact, so only the selected
//      register or storage location can trip the gate (clean fault isolation).
//   2. Snapshot the cumulative reset count.
//   3. put_value() a corrupt value into the selected location (an SEU bit-flip).
//   4. Run one WDT window.
//   5. Assert the adapter's exact reset delta: one for guarded locations, zero
//      for a deliberate NEGATIVE control at a location the part documents as
//      unguarded (PIC10F320's LED latch). "Exactly one" -- not ">=1" -- also
//      catches a reset-LOOP (the only gpsim-modeling risk; see the WDTCON note
//      below), which would otherwise pass silently.
// `inject_relay_resync_case()` asserts the same single reset, but brackets it:
// both coils low BEFORE the spin, and a full-width RESET-coil pulse AFTER the
// recovery, from either a settled BYPASS or a settled ENGAGED start.
//
// A no-injection CONTROL case runs first and asserts delta == 0: a quiescent
// device must NOT reset in a full window, proving the window is not catching
// phantom resets and the gate does not fire spuriously.
//
// The matrix chooses which cases are plain reset cases and which are relay
// resynchronization cases. Exact direction/output checks bring each spare output
// inside the guarded policy, including PIC12F675 GP4 and its non-isomorphic
// ANSEL.ANS3 mapping.
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
// IMPORTANT (gpsim WDT calibration; see test_soak_pic.cc): gpsim's watchdog
// model differs per part, so each adapter supplies its own PIC_FAULT_WDT_NOTE
// (printed into retained evidence) rather than the core baking one in. On the
// PIC10F32x gpsim honors WDTCON.WDTPS but does NOT match the datasheet -- at
// that firmware's WDTPS=0x08 the gpsim WDT period is ~1.057 s, not the silicon
// ~256 ms -- while the PIC12F675 has no WDTCON and at OPTION_REG=0x0C models
// ~288 ms (160 ms datasheet floor). The recovery reset therefore takes up to
// ~1.06 s of simulated time on the slowest part; WDT_RESET_WINDOW_MS carries
// margin over that. This test asserts nothing about WDT TIMING, only that the
// reset happens within a generous window -- which is what lets one window serve
// parts whose watchdog models differ.

#ifndef TEST_PIC_TEST_FAULT_PIC_CORE_H
#define TEST_PIC_TEST_FAULT_PIC_CORE_H

#include <cstdio>
#include <cstdlib>
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
#ifndef PIC_FAULT_WDT_NOTE
#  error "PIC_FAULT_WDT_NOTE must be defined by the part adapter"
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
// One WDT window to observe the recovery reset, sized for the SLOWEST modeled
// period across supported parts -- the PIC10F32x WDTCON.WDTPS=0x08 ~1.057 s (see
// header note); the PIC12F675 at OPTION_REG=0x0C models a much shorter ~288 ms.
// 2000 ms carries margin over the slowest AND is long enough that a
// (WDTPS-corrupted, hence faster) reset-LOOP would show as delta >> 1.
#define WDT_RESET_WINDOW_MS  2000u
// Safety cap: max run() resumes to cover one ms. A genuinely wedged core (PC
// stuck, never reaching the cycle break) trips this instead of hanging forever.
#define MAX_RESUMES_PER_MS 64
// ---- Relay resynchronization case (see inject_relay_resync_case) ------------
// Budget for the escalation path to drive both coils low: the gate that detects
// the injected coil runs at the next tick (1 ms, 1.024 ms on PIC12F675) and
// hw_force_wdt_reset() de-energizes before its spin, so 3 ms is one tick plus
// generous slack -- and short enough that a mutant which only clears the coils
// on the NEXT loop top (i.e. never, since the spin never returns) fails.
#define RESYNC_DEENERGIZE_MS 3u
// Window over which the recovery actuation is observed, comfortably wider than
// the 12 ms TQ2_L2_5V_PULSE_MS it must contain.
#define RESYNC_OBSERVE_MS 30u
// Sampling interval for that observation. 16 instruction cycles is 32 us at
// 2 MHz FOSC and 16 us at 4 MHz -- more than two orders of magnitude below the
// datasheet minimum pulse, so it cannot mistake a real actuation for a glitch
// or vice versa, while keeping the case ~940 resumes instead of ~15000.
#define RESYNC_SAMPLE_CYCLES 16u
// Panasonic TQ2-L2-5V specified minimum coil pulse for GUARANTEED actuation.
// The firmware drives 12 ms (TQ2_L2_5V_PULSE_MS, 3x margin); this is the floor
// the recovery pulse must clear for the resynchronization to be a guarantee
// rather than a hope. Simulation proves the PULSE, never the mechanics.
#define RELAY_MIN_PULSE_MS 4u
#if defined(PIC_FAULT_REQUIRE_PHYSICAL_COIL_IDLE)
// gpsim drives digital outputs at the rails. Keep the assertions in the
// datasheet-defined low/high regions rather than treating any nonzero float as
// an energized relay pin.
#  define PHYSICAL_LOW_MAX_V  0.8
#  define PHYSICAL_HIGH_MIN_V 4.0
#endif
// Footswitch drive used to reach a settled ENGAGED state before injecting.
// Press must exceed PRESSED_THRESH (8) ticks plus the 12 ms blocking actuation
// the polled loop spends not counting ticks; release must exceed
// RELEASE_THRESH (25) ticks by the same kind of margin.
#define TOGGLE_PRESS_MS   40u
#define TOGGLE_RELEASE_MS 80u
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
#if defined(PIC_FAULT_REQUIRE_PHYSICAL_COIL_IDLE)
static Stimulus_Node *g_comparator_input_node = nullptr;
static source_stimulus *g_comparator_input_src = nullptr;
static Stimulus_Node *g_reset_coil_node = nullptr;
static Stimulus_Node *g_set_coil_node   = nullptr;
static bool g_comparator_input_driven = false;
#endif

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

#if defined(PIC_FAULT_REQUIRE_PHYSICAL_COIL_IDLE)
#  if !defined(PIC_REG_COMPARATOR_INPUT_PIN_NAME) || \
      !defined(PIC_REG_RESET_COIL_PIN_NAME) || !defined(PIC_REG_SET_COIL_PIN_NAME)
#    error "physical relay checks require exact comparator/reset/set pin names"
#  endif

// Attach nodes to the package pins. Unlike GPIO readback, these nodes continue
// to report pad voltage while an analog peripheral owns the pin. GP0 also gets
// a normally high-impedance source so comparator fixtures can establish a
// defined low/high input without driving either relay coil.
static bool attach_relay_coil_observers(const char *proc_name) {
    IOPIN *comparator_input_pin =
        find_pin_exact(g_cpu, PIC_REG_COMPARATOR_INPUT_PIN_NAME);
    IOPIN *reset_pin = find_pin_exact(g_cpu, PIC_REG_RESET_COIL_PIN_NAME);
    IOPIN *set_pin   = find_pin_exact(g_cpu, PIC_REG_SET_COIL_PIN_NAME);
    if (comparator_input_pin == nullptr || reset_pin == nullptr ||
            set_pin == nullptr) {
        fprintf(stderr, "FATAL: comparator/relay pin %s/%s/%s not found on %s\n",
                PIC_REG_COMPARATOR_INPUT_PIN_NAME,
                PIC_REG_RESET_COIL_PIN_NAME, PIC_REG_SET_COIL_PIN_NAME,
                proc_name);
        return false;
    }

    g_comparator_input_src = new source_stimulus();
    g_comparator_input_src->set_Zth(1.0e12);
    g_comparator_input_src->set_Vth(0.0);
    g_comparator_input_node = new Stimulus_Node("comparator-input-pin");
    g_reset_coil_node = new Stimulus_Node("relay-reset-pin");
    g_set_coil_node   = new Stimulus_Node("relay-set-pin");
    g_comparator_input_node->attach_stimulus(g_comparator_input_src);
    g_comparator_input_node->attach_stimulus(comparator_input_pin);
    g_reset_coil_node->attach_stimulus(reset_pin);
    g_set_coil_node->attach_stimulus(set_pin);
    g_comparator_input_node->update();
    g_reset_coil_node->update();
    g_set_coil_node->update();
    return true;
}

static void comparator_input_drive(bool high) {
    g_comparator_input_src->set_Vth(high ? 5.0 : 0.0);
    g_comparator_input_src->set_Zth(250.0);
    g_comparator_input_node->update();
    g_comparator_input_driven = true;
}

static void comparator_input_release(void) {
    if (g_comparator_input_driven) {
        g_comparator_input_src->set_Zth(1.0e12);
        g_comparator_input_node->update();
        g_comparator_input_driven = false;
    }
}

static void relay_coil_voltages(double *reset_v, double *set_v) {
    g_reset_coil_node->update();
    g_set_coil_node->update();
    *reset_v = g_reset_coil_node->get_nodeVoltage();
    *set_v   = g_set_coil_node->get_nodeVoltage();
}

static bool relay_coils_physically_inactive(double *reset_v, double *set_v) {
    relay_coil_voltages(reset_v, set_v);
    return *reset_v <= PHYSICAL_LOW_MAX_V && *set_v <= PHYSICAL_LOW_MAX_V;
}

// XC8 emits the empty watchdog wait as a classic-mid-range GOTO-to-self. The
// check is behavioral rather than symbol-based, so it remains valid when the
// file-static helper moves in program memory between output variants.
static bool at_watchdog_spin(void) {
    unsigned const pc = g_cpu->pc->get_value();
    unsigned const opcode = g_cpu->pma->get_opcode(pc);
    return (opcode & 0x3800u) == 0x2800u &&
           (opcode & 0x07FFu) == (pc & 0x07FFu);
}
#endif

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

// Advance the simulation by exactly `cycles` instruction cycles. Same resume
// discipline as run_ms(); used by the relay resynchronization case, which needs
// a sampling interval finer than one millisecond.
static bool run_cycles(guint64 cycles) {
    guint64 target = get_cycles().get() + cycles;
    get_cycles().set_break(target);
    int resumes = 0;
    while (get_cycles().get() < target) {
        g_cpu->run(false);
        if (++resumes > MAX_RESUMES_PER_MS) {
            fprintf(stderr, "FATAL: core not advancing (wedged?) at run_cycles\n");
            get_cycles().clear_break(target);
            return false;
        }
    }
    get_cycles().clear_break(target);
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

// Put the device in a known SETTLED effect state and prove it got there by
// reading the LED bit on the modeled port -- the same observable a bench
// technician would use. Reads the current state and toggles only if needed
// rather than assuming entry is BYPASS: with correct firmware every case here
// ends in a recovery reset (hence BYPASS), but a MUTANT that skips the reset
// would leave the device engaged, and the next case must then still reach the
// state it says it is testing instead of silently testing the other one.
// Returning false means the state was never reached, which the caller reports
// rather than injecting into an unknown state.
static bool drive_effect_state(bool engaged) {
    footsw_set(0);
    if (!run_ms(SETTLE_MS)) { return false; }

    Register *port = fetch_sfr(PIC_REG_PORT_ADDR, PIC_REG_PORT_TOKEN);
    if (port == nullptr) { return false; }

    if (((port->get_value() & PIC_REG_LED_MASK) != 0u) != engaged) {
        footsw_set(1);
        if (!run_ms(TOGGLE_PRESS_MS)) { return false; }
        footsw_set(0);
        if (!run_ms(TOGGLE_RELEASE_MS)) { return false; }
    }
    return ((port->get_value() & PIC_REG_LED_MASK) != 0u) == engaged;
}

// A watchdog reset is only half the recovery contract: the restarted image must
// resume PETTING the dog. This proves the recovered core reaches its main-loop
// CLRWDT again -- so a reset-then-die recovery (init() completes, main loop never
// re-arms the pet) is caught rather than scored as a pass. Earlier cases get this
// implicitly from the next case's entry preamble (SETTLE + advance_to_loop_clrwdt),
// but the FINAL injection has no successor, so without this call a loop that
// resets and then wedges would pass. It reuses advance_to_loop_clrwdt() -- the
// same liveness probe every case already trusts at entry -- and is FOLDED into
// the caller's existing check slot (deliberately no g_checks++), so the
// per-variant EXPECTED_CHECKS totals stay hand-verifiable across all three
// adapters; a dead recovery flips the case through g_fails.
static void prove_post_reset_liveness(void) {
    if (!run_ms(SETTLE_MS) || !advance_to_loop_clrwdt()) {
        g_fails++;
        fprintf(stderr,
                "    FAIL: no renewed loop-pet liveness after the recovery reset\n");
        return;
    }
    printf("    PASS: recovered image reached its loop CLRWDT again"
           " (renewed liveness)\n");
}

// ---- Relay fail-safe RESYNCHRONIZATION case ---------------------------------
// F1 policy (docs/relay_coil_fault_correction.md): an unexpectedly energized
// relay coil is a FAULT, not something to clear quietly. A pulse shorter than
// the Panasonic TQ2-L2-5V 4 ms minimum is not proven mechanically harmless, so
// the firmware cannot know whether the latching relay moved -- and a latching
// relay that moved without the firmware's knowledge leaves the audio route
// disagreeing with both the logical effect state and the LED.
//
// The contract this case pins therefore has TWO halves, and it asserts them
// separately on purpose. Final-low output alone is NOT full recovery:
//
//   1. DE-ENERGIZATION. hw_force_wdt_reset() runs the target's emergency output
//      quiescence BEFORE it spins, so both coils go low within one tick of the
//      gate that detected them -- never held energized for the whole watchdog
//      period.
//   2. RESYNCHRONIZATION. The watchdog recovery re-runs init(), whose BYPASS
//      actuation drives a COMPLETE RESET-coil pulse. That, and not the clear
//      in (1), is what puts the physical relay back in agreement with the
//      logical state. This case measures that pulse and requires it to exceed
//      the datasheet minimum, and requires the SET coil to stay dark for the
//      whole recovery.
//
// EXCLUSIONS, unchanged and deliberate. The injection lands at the trailing
// loop CLRWDT -- one reviewed, deterministic settled seam. It does not sweep
// instruction phase, and it never injects inside the blocking actuation
// sequence (pre-clear, coil assertion, 12 ms delay, post-clear), where the gate
// does not run at all. Nothing here can prove what a below-minimum pulse does
// to real relay mechanics; only bench characterization can.
//
// `engaged` selects the settled state the fault arrives in, so the matrix can
// cover BYPASS plus an unintended SET (the relay may move to ENGAGED while the
// firmware believes BYPASS) and ENGAGED plus an unintended RESET (the mirror).
// Contributes exactly ONE check, with every assertion folded into the verdict,
// so each adapter's EXPECTED_CHECKS stays hand-verifiable.
static void finish_relay_resync_case(Register *target, Register *latch,
                                     Register *port, unsigned before_val,
                                     unsigned injected, unsigned written,
                                     bool injection_ok,
                                     bool require_deenergize_transition,
                                     guint64 resets_before,
                                     guint64 inject_cycle) {
    static unsigned const coil_mask = PIC_REG_COIL_MASK;

    // -- half 1: both coils de-energized on the escalation path, before the
    // spin. Sampled every instruction so `partial_clear` observes the write
    // sequence, not only its settled result. A clear that walked the two bits
    // separately would transiently leave one energized.
    //
    // Both register views are tracked because an SRAM shadow and its port write
    // can move a step apart. PIC12F675's physical-pin lane additionally follows
    // the watchdog GOTO-to-self and proves GP1/GP2 are Low there; GPIO readback
    // alone aliases COUT and is not proof.
    bool            deenergized       = false;
    bool            partial_clear     = false;
    guint64         deenergize_cycle  = 0u;
    unsigned        prev_latch_coils  = latch->get_value() & coil_mask;
    unsigned        prev_port_coils   = port->get_value() & coil_mask;
    unsigned const  deenergize_cap    =
        (unsigned)(RESYNC_DEENERGIZE_MS * CYCLES_PER_MS);
#if defined(PIC_FAULT_REQUIRE_PHYSICAL_COIL_IDLE)
    bool            spin_seen         = false;
    bool            spin_physical_low = false;
    guint64         spin_cycle        = 0u;
    double          reset_pin_v       = 0.0;
    double          set_pin_v         = 0.0;
#endif

    for (unsigned i = 0; i < deenergize_cap; ++i) {
        unsigned const latch_coils = latch->get_value() & coil_mask;
        unsigned const port_coils  = port->get_value() & coil_mask;
        if ((latch_coils != 0u) && (latch_coils != prev_latch_coils) &&
                ((latch_coils & prev_latch_coils) == latch_coils)) {
            partial_clear = true;
        }
        if ((port_coils != 0u) && (port_coils != prev_port_coils) &&
                ((port_coils & prev_port_coils) == port_coils)) {
            partial_clear = true;
        }
        prev_latch_coils = latch_coils;
        prev_port_coils  = port_coils;

        bool const registers_idle = (latch_coils == 0u) && (port_coils == 0u);
#if defined(PIC_FAULT_REQUIRE_PHYSICAL_COIL_IDLE)
        double sample_reset_v = 0.0;
        double sample_set_v   = 0.0;
        bool const physical_idle = relay_coils_physically_inactive(
            &sample_reset_v, &sample_set_v);
        if (!deenergized && registers_idle && physical_idle) {
            deenergized = true;
            deenergize_cycle = get_cycles().get();
        }
        if (at_watchdog_spin()) {
            spin_seen = true;
            spin_cycle = get_cycles().get();
            reset_pin_v = sample_reset_v;
            set_pin_v = sample_set_v;
            spin_physical_low = physical_idle;
            break;
        }
#else
        if (registers_idle) {
            deenergized = true;
            deenergize_cycle = get_cycles().get();
            break;
        }
#endif
        if (!run_cycles(1u)) { break; }
    }

#if defined(PIC_FAULT_REQUIRE_PHYSICAL_COIL_IDLE)
    // A comparator fixture may drive GP0 while the peripheral is active. Once
    // the firmware has reached its spin and physical coil state is recorded,
    // release that source before reset reinitializes GP0 as the status LED.
    comparator_input_release();
#endif

    // -- the recovery reset itself. Polled in 1 ms steps rather than one long
    // window so the observation below starts as close to the reset vector as
    // the step allows; the recovery pulse is 12 ms, so at most one step of it
    // is missed and the datasheet-minimum assertion still has ~8 ms of margin.
    unsigned elapsed_ms = 0u;
    bool     ran_clean  = true;
    while ((elapsed_ms < WDT_RESET_WINDOW_MS) && (g_resets == resets_before)) {
        if (!run_ms(1u)) { ran_clean = false; break; }
        elapsed_ms++;
    }
    guint64 const reset_delta = g_resets - resets_before;

    // -- half 2: the ordinary recovery actuation oracle, unchanged in scope.
    guint64  reset_coil_cycles = 0u;
    guint64  set_coil_cycles   = 0u;
    unsigned const samples =
        (unsigned)((RESYNC_OBSERVE_MS * CYCLES_PER_MS) / RESYNC_SAMPLE_CYCLES);
    for (unsigned i = 0; ran_clean && (i < samples); ++i) {
        unsigned const p = port->get_value() & 0xFFu;
        if ((p & PIC_REG_RESET_COIL_MASK) != 0u) {
            reset_coil_cycles += RESYNC_SAMPLE_CYCLES;
        }
        if ((p & PIC_REG_SET_COIL_MASK) != 0u) {
            set_coil_cycles += RESYNC_SAMPLE_CYCLES;
        }
        if (!run_cycles(RESYNC_SAMPLE_CYCLES)) { ran_clean = false; }
    }

    // -- and the settled result: BYPASS, LED dark, both coils idle.
    if (ran_clean && !run_ms(SETTLE_MS)) { ran_clean = false; }
    unsigned const final_port = port->get_value() & 0xFFu;
    guint64  const min_pulse_cycles =
        (guint64)RELAY_MIN_PULSE_MS * (guint64)CYCLES_PER_MS;
    bool const deenergize_order_ok = deenergized &&
        (!require_deenergize_transition || deenergize_cycle > inject_cycle);
#if defined(PIC_FAULT_REQUIRE_PHYSICAL_COIL_IDLE)
    bool const physical_spin_ok = spin_seen && spin_physical_low &&
                                  spin_cycle >= deenergize_cycle;
#else
    bool const physical_spin_ok = true;
#endif

    bool const pass = ran_clean && injection_ok && deenergize_order_ok &&
                      !partial_clear && physical_spin_ok &&
                      (reset_delta == 1u) &&
                      (reset_coil_cycles >= min_pulse_cycles) &&
                      (set_coil_cycles == 0u) &&
                      ((final_port & coil_mask) == 0u) &&
                      ((final_port & PIC_REG_LED_MASK) == 0u);

    if (pass) {
        printf("    PASS: coils inactive in %" G_GUINT64_FORMAT " cycles (%.3f ms)"
               " with no partially cleared coil latch,",
               deenergize_cycle >= inject_cycle ? deenergize_cycle - inject_cycle : 0u,
               (double)(deenergize_cycle >= inject_cycle
                            ? deenergize_cycle - inject_cycle : 0u) /
                   (double)CYCLES_PER_MS);
#if defined(PIC_FAULT_REQUIRE_PHYSICAL_COIL_IDLE)
        printf(" physical GP1=%.3fV/GP2=%.3fV at watchdog spin,", reset_pin_v,
               set_pin_v);
#endif
        printf(" 1 reset, recovery drove a %.3f ms RESET-coil pulse"
               " (>= %u ms datasheet minimum) with SET dark, settled in BYPASS\n",
               (double)reset_coil_cycles / (double)CYCLES_PER_MS,
               RELAY_MIN_PULSE_MS);
        // Folded into this same check slot (deliberately no g_checks++).
        prove_post_reset_liveness();
    } else {
        g_fails++;
        fprintf(stderr,
                "    FAIL: init=0x%02x requested=0x%02x read=0x%02x"
                " injection=%u deenergized=%u deenergize-cycles=%" G_GUINT64_FORMAT
                " partial-clear=%u",
                before_val, injected, written, injection_ok ? 1u : 0u,
                deenergized ? 1u : 0u,
                deenergized && deenergize_cycle >= inject_cycle
                    ? deenergize_cycle - inject_cycle : 0u,
                partial_clear ? 1u : 0u);
#if defined(PIC_FAULT_REQUIRE_PHYSICAL_COIL_IDLE)
        fprintf(stderr, " spin=%u GP1=%.3fV GP2=%.3fV",
                spin_seen ? 1u : 0u, reset_pin_v, set_pin_v);
#endif
        fprintf(stderr,
                " resets=%" G_GUINT64_FORMAT " reset-coil-ms=%.3f set-coil-ms=%.3f"
                " final-" PIC_REG_PORT_LC "=0x%02x clean=%u\n",
                reset_delta,
                (double)reset_coil_cycles / (double)CYCLES_PER_MS,
                (double)set_coil_cycles / (double)CYCLES_PER_MS,
                final_port, ran_clean ? 1u : 0u);
        // Leave the next case a quiescent device even after a failed verdict.
        target->put_value(before_val);
    }
    fflush(stdout);
}

static void inject_relay_resync_case(unsigned addr, const char *token,
                                     unsigned mask, bool engaged,
                                     const char *note) {
    g_checks++;

    if (!drive_effect_state(engaged)) {
        g_fails++;
        fprintf(stderr, "    FAIL: could not reach settled %s before injection\n",
                engaged ? "ENGAGED" : "BYPASS");
        return;
    }
    if (!advance_to_loop_clrwdt()) {
        g_fails++;
        return;
    }

    Register *target = fetch_sfr(addr, token);
    Register *latch  = fetch_sfr(PIC_REG_LATCH_ADDR, PIC_REG_LATCH_TOKEN);
    Register *port   = fetch_sfr(PIC_REG_PORT_ADDR,  PIC_REG_PORT_TOKEN);
    if (target == nullptr || latch == nullptr || port == nullptr) {
        g_fails++;
        return;
    }

    unsigned const before_val    = target->get_value() & 0xFFu;
    unsigned const injected      = before_val | mask;
    guint64  const resets_before = g_resets;

    printf("  inject relay coils    @0x%03x: 0x%02x -> 0x%02x  (%s, from %s)\n",
           addr, before_val, injected, note, engaged ? "ENGAGED" : "BYPASS");
    fflush(stdout);

    target->put_value(injected);
    unsigned const written     = target->get_value() & 0xFFu;
    guint64  const inject_cycle = get_cycles().get();
    bool const injection_ok = ((before_val & mask) == 0u) &&
                              (written == injected);

    finish_relay_resync_case(target, latch, port, before_val, injected,
                             written, injection_ok, true, resets_before,
                             inject_cycle);
}

#if defined(PIC_FAULT_REQUIRE_PHYSICAL_COIL_IDLE)
// Every single-bit-reachable mode is run with GP0 externally driven low and
// high while GP1 remains low. The mode-110 pair must produce opposite COUT
// states, make physical GP2 agree, and complete the firmware escalation path.
// Modes 101/011 leave GP2 under GPIO; gpsim can evaluate their ownership but was
// observed to crash if execution continued with mode 101 active, so those
// bounded fixtures restore comparator-off after two settling cycles and before
// the firmware reaches its next gate.
//
// When COUT is High, the harness also performs the old latch-only emergency
// action (clear the SRAM shadow and write zero to the GPIO coil bits) and proves
// GP2 remains physically High. This is a target-realistic negative control over
// the actual gpsim comparator/pin model, not a fake firmware implementation.
static void inject_comparator_relay_resync_case(unsigned mode, bool input_high,
                                                 bool owns_gp2,
                                                 const char *label) {
    static int cout_with_input_low[8] = {-1, -1, -1, -1, -1, -1, -1, -1};
    static unsigned const coil_mask = PIC_REG_COIL_MASK;

    g_checks++;

    // BYPASS keeps both relay coils and the GP0 shadow low. The source attached
    // to GP0 then establishes a defined comparator input without driving either
    // coil; the low-input mode-110 case consequently isolates the CMCON guard.
    if (!drive_effect_state(false)) {
        g_fails++;
        fprintf(stderr, "    FAIL: could not reach settled BYPASS comparator fixture\n");
        return;
    }
    if (!advance_to_loop_clrwdt()) {
        g_fails++;
        return;
    }

    Register *target = fetch_sfr(PIC_REG_CMCON_ADDR, "cmcon");
    Register *latch  = fetch_sfr(PIC_REG_LATCH_ADDR, PIC_REG_LATCH_TOKEN);
    Register *port   = fetch_sfr(PIC_REG_PORT_ADDR, PIC_REG_PORT_TOKEN);
    if (target == nullptr || latch == nullptr || port == nullptr) {
        g_fails++;
        return;
    }

    unsigned const before_val = target->get_value() & 0xFFu;
    unsigned const fixture_off = PIC_FAULT_CMCON_OFF;
    unsigned const injected = mode & PIC_FAULT_CMCON_MODE_MASK;
    unsigned const changed_mode_bits =
        (PIC_FAULT_CMCON_OFF ^ mode) & PIC_FAULT_CMCON_MODE_MASK;

    // Establish the external input while comparator-off still owns no output,
    // then make the single mode-bit injection at the trailing CLRWDT seam.
    comparator_input_drive(input_high);
    target->put_value(fixture_off);
    unsigned const fixture_written = target->get_value() & 0xFFu;
    guint64  const resets_before = g_resets;
    guint64  const inject_cycle  = get_cycles().get();
    target->put_value(injected);
    bool const fixture_ran = run_cycles(2u);
    unsigned const written = target->get_value() & 0xFFu;

    double reset_pin_v = 0.0;
    double set_pin_v = 0.0;
    g_comparator_input_node->update();
    relay_coil_voltages(&reset_pin_v, &set_pin_v);
    double const input_pin_v = g_comparator_input_node->get_nodeVoltage();
    bool const cout_high = (written & PIC_FAULT_CMCON_COUT_MASK) != 0u;
    bool const input_state_ok = input_high
        ? input_pin_v >= PHYSICAL_HIGH_MIN_V
        : input_pin_v <= PHYSICAL_LOW_MAX_V;
    bool const gp1_low = reset_pin_v <= PHYSICAL_LOW_MAX_V;
    bool const gp2_state_ok = owns_gp2
        ? (cout_high ? set_pin_v >= PHYSICAL_HIGH_MIN_V
                     : set_pin_v <= PHYSICAL_LOW_MAX_V)
        : set_pin_v <= PHYSICAL_LOW_MAX_V;
    bool const before_escalation = (g_resets == resets_before) &&
                                   !at_watchdog_spin();
    bool const one_mode_bit = changed_mode_bits == 0x01u ||
                              changed_mode_bits == 0x02u ||
                              changed_mode_bits == 0x04u;
    bool pair_ok = true;
    if (!input_high) {
        cout_with_input_low[mode & PIC_FAULT_CMCON_MODE_MASK] =
            cout_high ? 1 : 0;
    } else {
        int const first = cout_with_input_low[mode & PIC_FAULT_CMCON_MODE_MASK];
        pair_ok = first >= 0 && first != (cout_high ? 1 : 0);
    }

    bool latch_only_rejected = true;
    if (owns_gp2 && cout_high) {
        // This exactly models the superseded emergency action on this part:
        // coil shadow clear followed by one whole-port GPIO write. GPIO reads
        // the comparator-owned pad, so only the SRAM shadow can attest intent;
        // the node voltage is the load-bearing physical observation.
        unsigned const safe_shadow =
            (latch->get_value() & 0xFFu) & ~coil_mask;
        latch->put_value(safe_shadow);
        port->put_value(safe_shadow);
        relay_coil_voltages(&reset_pin_v, &set_pin_v);
        latch_only_rejected =
            ((latch->get_value() & coil_mask) == 0u) &&
            ((target->get_value() & PIC_FAULT_CMCON_COUT_MASK) != 0u) &&
            (set_pin_v >= PHYSICAL_HIGH_MIN_V);
    }

    bool const fixture_ok = fixture_ran && one_mode_bit &&
        ((before_val & PIC_FAULT_CMCON_MODE_MASK) == PIC_FAULT_CMCON_OFF) &&
        ((fixture_written & PIC_FAULT_CMCON_MODE_MASK) == fixture_off) &&
        ((written & PIC_FAULT_CMCON_MODE_MASK) == injected) &&
        input_state_ok && gp1_low && gp2_state_ok && before_escalation && pair_ok &&
        latch_only_rejected;

    printf("  inject %-18s @0x%03x: mode=0b%u%u%u GP0-drive=%s (%.3fV)"
           " -> COUT=%s, GP2-owner=%s, physical GP1=%.3fV GP2=%.3fV"
           " (from BYPASS)\n",
           label, PIC_REG_CMCON_ADDR, (mode >> 2) & 1u, (mode >> 1) & 1u,
           mode & 1u, input_high ? "HIGH" : "LOW", input_pin_v,
           cout_high ? "HIGH" : "LOW",
           owns_gp2 ? "COUT" : "GPIO", reset_pin_v, set_pin_v);
    if (owns_gp2 && cout_high) {
        printf("    fixture: COUT and physical GP2 were HIGH before escalation;"
               " latch-only clear left GP2 at %.3fV\n", set_pin_v);
    }
    fflush(stdout);

    if (!owns_gp2) {
        // Do not resume the core with these gpsim-only ownership fixtures
        // active. Restoring the writable mode bits is sufficient; COUT is live.
        target->put_value(PIC_FAULT_CMCON_OFF);
        unsigned const restored = target->get_value() & 0xFFu;
        comparator_input_release();
        bool const restored_off =
            (restored & PIC_FAULT_CMCON_MODE_MASK) == PIC_FAULT_CMCON_OFF;
        bool const pass = fixture_ok && restored_off;
        if (pass) {
            printf("    PASS: GP2 remained GPIO-low; comparator-off restored"
                   " before execution resumed\n");
        } else {
            g_fails++;
            fprintf(stderr,
                    "    FAIL: fixture=%u input=%.3fV COUT=%u GP1=%.3fV"
                    " GP2=%.3fV restored=0x%02x\n",
                    fixture_ok ? 1u : 0u, input_pin_v, cout_high ? 1u : 0u,
                    reset_pin_v, set_pin_v, restored);
            if (!restored_off) {
                fflush(stderr);
                std::exit(1);
            }
        }
        fflush(stdout);
        return;
    }

    finish_relay_resync_case(target, latch, port, before_val, injected,
                             written, fixture_ok, cout_high,
                             resets_before,
                             inject_cycle);
}
#endif

// ---- One injection case -----------------------------------------------------
// absolute=true writes `val`; absolute=false writes (current ^ val), i.e. an
// SEU bit-flip of the bits in `val`. Nearly every call site requires one reset.
// `readback_mask` defaults to the complete byte; CMCON cases narrow it to the
// writable mode field because COUT is a live, read-only status bit.
// expected_resets == 0 is the negative-control form, used where a part
// DOCUMENTS a location as unguarded and the test exists to pin that exception
// so it cannot widen or close unnoticed. The restore-and-verify branch keeps
// those cases independent and proves restoration succeeds.
static void inject_case(const char *label, unsigned addr, const char *token,
                         bool absolute, unsigned val, unsigned expected_resets,
                         const char *note, unsigned readback_mask = 0xFFu) {
    footsw_set(0);                 // released: quiescent, only this location can trip
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

    if ((written & readback_mask) != (bad & readback_mask)) {
        g_checks++;
        g_fails++;
        fprintf(stderr,
                "    FAIL: injection did not stick (read 0x%02x, wanted 0x%02x,"
                " mask 0x%02x)\n", written, bad, readback_mask);
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
        // A reset fired as required; now require the recovered image to live.
        // (Skipped for expected_resets == 0 correction cases, whose contract is
        // that no reset happened and the loop never stopped.)
        if (expected_resets >= 1u) {
            prove_post_reset_liveness();
        }
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
        r->put_value(cur); // restore correction cases that intentionally do not reset
        g_checks++;
        if ((r->get_value() & 0xFFu) != cur) {
            g_fails++;
            fprintf(stderr, "    FAIL: could not restore register after correction case\n");
        }
    }
    fflush(stdout);
}

// ---- Isolate the shadow-versus-expected clause, F2-blind ---------------------
// Drives BOTH the output shadow and modeled GPIO to the same value while
// leaving ctx_ untouched, so hw_output_state_intact()'s port-follows-shadow
// clause stays satisfied (port == shadow), its shadow-vs-expected clause is the
// SOLE trip (shadow != expected(ctx_.effect_state)), and the F2 context-check
// fold is blind (ctx_ unchanged). Since F2 was added, poking effect_state is
// caught redundantly by the fold, so it can no longer isolate this clause; a
// single-address shadow poke does not isolate it either (cd4053's empty reassert
// leaves the port low, so port-follows-shadow also trips). Contributes exactly
// one check, matching the inject_case it replaced.
[[maybe_unused]]
static void inject_shadow_expected_case(const char *label, unsigned val,
                                        const char *note) {
    footsw_set(0);
    if (!run_ms(SETTLE_MS))        { g_checks++; g_fails++; return; }
    if (!advance_to_loop_clrwdt()) { g_checks++; g_fails++; return; }

    Register *sh = fetch_sfr(PIC_REG_LATCH_ADDR, PIC_REG_LATCH_TOKEN);
    Register *po = fetch_sfr(PIC_REG_PORT_ADDR,  PIC_REG_PORT_TOKEN);
    if (sh == nullptr || po == nullptr) { g_checks++; g_fails++; return; }

    unsigned cur_sh = sh->get_value() & 0xFFu;
    unsigned cur_po = po->get_value() & 0xFFu;
    unsigned bad_sh = (cur_sh | (val & 0xFFu));   // intent bit(s) high ...
    unsigned bad_po = (cur_po | (val & 0xFFu));   // ... and the port, so port==shadow

    guint64 before = g_resets;
    sh->put_value(bad_sh);
    po->put_value(bad_po);
    printf("  inject %-18s " PIC_REG_LATCH_LC "@0x%03x " PIC_REG_PORT_LC
           "@0x%03x: +0x%02x  (%s)\n",
           label, PIC_REG_LATCH_ADDR, PIC_REG_PORT_ADDR, val & 0xFFu, note);
    fflush(stdout);

    if ((sh->get_value() & 0xFFu) != bad_sh || (po->get_value() & 0xFFu) != bad_po) {
        g_checks++;
        g_fails++;
        fprintf(stderr, "    FAIL: shadow/port injection did not stick\n");
        return;
    }

    if (!run_ms(WDT_RESET_WINDOW_MS)) { g_checks++; g_fails++; return; }
    guint64 delta = g_resets - before;

    g_checks++;
    if (delta == 1u) {
        printf("    PASS: observed exactly 1 WDT reset\n");
        prove_post_reset_liveness();
    } else {
        g_fails++;
        char const *reason = (delta > 1u)
            ? "  [reset-loop: is gpsim retaining the corrupted watchdog-period register?]"
            : "  [gate did not fire?]";
        printf("    FAIL: %" G_GUINT64_FORMAT " resets in %u ms (want exactly 1)%s\n",
               delta, WDT_RESET_WINDOW_MS, reason);
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
#if defined(PIC_FAULT_REQUIRE_PHYSICAL_COIL_IDLE)
    if (!attach_relay_coil_observers(PROC_NAME))              return 1;
#endif

    footsw_set(0);                              // released at power-on
    if (!run_ms(SETTLE_MS)) {                   // let init() settle, reach main loop
        return 1;
    }

    // Arm reset counting only now (skip the power-on pass through 0x000).
    get_bp().set_notify_break(g_cpu, 0x000, &g_reset_notifier);

    printf("FAULT-INJECT START: fw=%s proc=%s FOSC=%lu window=%u ms\n"
           "  %s\n",
           FW_PATH, PROC_NAME, (unsigned long)F_CPU_HZ, WDT_RESET_WINDOW_MS,
           PIC_FAULT_WDT_NOTE);
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

    // The output latch, whose guard SCOPE is the one thing that differs BETWEEN
    // parts of a family rather than between families: PIC10F322 guards its
    // complete settled latch, PIC10F320 guards only the two relay coil bits.
    // The RESPONSE no longer differs -- every energized coil resets.
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
