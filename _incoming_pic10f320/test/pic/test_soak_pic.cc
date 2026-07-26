// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// Long-duration soak test for the PIC10F320 firmware. It links libgpsim, drives
// the real built HEX, and verifies two properties at scale:
//
//   1. WDT liveness  -- the firmware's polled TMR2-tick/CLRWDT handshake must
//      keep the watchdog pet continuously. gpsim models the PIC10F320 WDT reset;
//      any WDT reset during the noise stream is logged as a failure but does NOT
//      stop the run -- the soak continues for the full duration.
//   2. Periodic responsiveness -- every SOAK_LIVENESS_INTERVAL_MS the noise
//      stream is paused and a 2-press round-trip is performed. The device must
//      respond with exactly 2 LED toggles and return to its prior effect state.
//
// Failures are NEVER fatal: each anomaly is logged to stderr and the loop
// continues so the full duration is exercised even after an early failure. This
// is the firmware's only at-scale test (the host equivalence test proves
// per-tick correctness; this proves the real HEX stays live and responsive over
// hours of continuous noise on a simulated core).
//
// The status LED is RA0 (LATA bit0) on every output variant, so this driver is
// variant-agnostic -- the variant only selects which HEX is loaded (and its
// per-variant ENGAGED control-pin pattern, which the gpsim functional test
// asserts; this soak only watches RA0).
//
// Build/run via the Makefile:  `make test-soak`
//   Intentionally NOT part of `make test`: it runs for minutes and needs the
//   gpsim-dev + libglib2.0-dev headers, which CI may lack. The target skips
//   cleanly when those (or XC8's HEX) are absent. Overrides: PIC_VARIANT,
//   PIC_SOAK_DURATION_MS, PIC_SOAK_LIVENESS_INTERVAL_MS, etc.
//
// IMPORTANT: gpsim honors WDTCON.WDTPS but its calibration does NOT match the
// datasheet -- at the firmware's WDTPS=0x08 the gpsim WDT period is ~1.057 s,
// not the silicon ~256 ms. The WDT is therefore used here purely as a
// QUALITATIVE liveness signal (a reset == failure); this test asserts nothing
// about WDT timing (see README "Known gaps").

#include <cstdio>
#include <cstdint>
#include <cinttypes>
#include <string>
#include <iostream>

#include <glib.h>                 // guint64, G_GUINT64_FORMAT
#include "interface.h"            // initialize_gpsim_core(), gpsim_set_bulk_mode()
#include "sim_context.h"          // CSimulationContext
#include "processor.h"            // Processor (rma, pc, run)
#include "pic-processor.h"        // pic_processor
#include "modules.h"              // Module::get_pin/get_pin_name/get_pin_count
#include "ioports.h"              // IOPIN
#include "stimuli.h"              // Stimulus_Node, source_stimulus
#include "gpsim_time.h"           // get_cycles(), Cycle_Counter
#include "breakpoints.h"          // get_bp(), set_notify_break
#include "trigger.h"              // TriggerObject
#include "registers.h"            // Register::get_value()

// gpsim narrates breakpoint/load activity on std::cout; a null streambuf
// silences it (our own output uses C stdio, so printf is unaffected).
struct NullBuf : std::streambuf { int overflow(int c) override { return c; } };
static NullBuf g_nullbuf;

// ---- Firmware / MCU parameters (injected by the Makefile build rule) --------
#ifndef FW_PATH
#  define FW_PATH  "build_pic/bypass_mcu_cd4053-simple_pic10f320.hex"
#endif
#ifndef PROC_NAME
#  define PROC_NAME "p10f320"
#endif
#ifndef F_CPU_HZ
#  define F_CPU_HZ 2000000UL           // FOSC; instruction clock = FOSC/4
#endif
#define CYCLES_PER_MS  ((F_CPU_HZ / 4UL) / 1000UL)   // 500 @ 2 MHz

// Debounce thresholds (PRESSED_THRESH, RELEASE_THRESH) come from the vendored
// reference model's config (test/model/bypass_config.h), which the equivalence
// test pins to the firmware -- so this soak can never silently drift from the
// firmware's thresholds. The Makefile adds -Itest/model.
#include "bypass_config.h"

// PIC pin map (bypass_mcu_pic10f320.c): RA3 footswitch (1=released, 0=pressed),
// RA0 = LED on LATA bit0 (1=ENGAGED). LATA is at 0x007 on the PIC10F320 (DFP
// proc/pic10f320.h: `LATA __at(0x007)`).
#define LATA_ADDR   0x07u
#define LED_MASK    0x01u              // RA0
#define FOOTSW_PIN_NAME "ra3"

// ---- Soak configuration (override with -DNAME=value from the Makefile) ------
#ifndef SOAK_DURATION_MS
#  define SOAK_DURATION_MS 3600000u    // 1 h default
#endif
#ifndef SOAK_LIVENESS_INTERVAL_MS
#  define SOAK_LIVENESS_INTERVAL_MS 60000u
#endif
#ifndef SOAK_PROGRESS_INTERVAL_MS
#  define SOAK_PROGRESS_INTERVAL_MS 3600000u
#endif

#include "../soak_timing_config.h"

// Safety cap: max run() resumes to cover one ms. A genuinely wedged core (PC
// stuck, never reaching the cycle break) trips this instead of hanging forever.
#define MAX_RESUMES_PER_MS 64

// ---- Sim globals ------------------------------------------------------------
static pic_processor   *g_cpu      = nullptr;
static Stimulus_Node   *g_fsw_node = nullptr;
static source_stimulus *g_fsw_src  = nullptr;
static int       g_led_level      = 0;
static guint64   g_led_changes    = 0;
static guint64   g_wdt_resets     = 0;   // counted by ResetNotifier (non-halting)
static guint64   g_liveness_fails = 0;
static guint64   g_total_checks   = 0;
static guint64   g_total_failures = 0;

static double sim_hours() {
    return (double)get_cycles().get() / (double)(F_CPU_HZ / 4UL) / 3600.0;
}

// ---- Reset detection --------------------------------------------------------
// A NOTIFY breakpoint at the reset vector fires its callback WITHOUT halting the
// run, so a WDT reset is counted as a side effect of the normal loop. Armed
// AFTER the power-on settle so the initial pass through 0x000 isn't counted.
class ResetNotifier : public TriggerObject {
public:
    void callback() override {
        g_wdt_resets++;
        g_total_failures++;
        g_total_checks++;
        fprintf(stderr, "SOAK FAIL [%.4f h]: unexpected WDT reset (cumulative: %"
                G_GUINT64_FORMAT ")\n", sim_hours(), g_wdt_resets);
        fflush(stderr);
    }
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

// Drive the footswitch input: 1 = released (high), 0 = pressed (low).
// A bare source_stimulus presents a constant get_Vth(), so we modulate the
// driven level directly via set_Vth. Zth is set low at init so this source
// dominates the firmware's internal weak pull-up on RA3.
static void footsw_set(int pressed) {
    g_fsw_src->set_Vth(pressed ? 0.0 : 5.0);
    g_fsw_node->update();
}

// Poll LATA bit0 (the LED) once per ms. The LED only changes on debounced edges
// (>> 1 ms apart), so per-ms sampling never misses a toggle. get_value() reads
// the latched value without triggering read-side-effects/breakpoints.
static void sample_led() {
    Register *lata = g_cpu->rma.get_register(LATA_ADDR);
    int v = (lata->get_value() & LED_MASK) ? 1 : 0;
    if (v != g_led_level) g_led_changes++;
    g_led_level = v;
}

// Advance the simulation by `ms` ms of simulated time. Cycle break at the
// target; resume run() until the target cycle is reached (a WDT reset may halt
// run() early and/or fire the notify callback -- either way we resume).
static void soak_run_ms(unsigned ms) {
    guint64 target = get_cycles().get() + (guint64)ms * CYCLES_PER_MS;
    get_cycles().set_break(target);
    int resumes = 0;
    while (get_cycles().get() < target) {
        g_cpu->run(false);
        if (++resumes > MAX_RESUMES_PER_MS) {
            g_total_failures++; g_total_checks++;
            fprintf(stderr, "SOAK FAIL [%.4f h]: core not advancing (wedged?)\n",
                    sim_hours());
            fflush(stderr);
            get_cycles().clear_break(target);
            return;
        }
    }
    sample_led();   // track LED edges at each ms boundary
}

// A toggle drives a BLOCKING output actuation (the relay coil pulse / mute
// pulse) during which the firmware busy-waits in __delay_ms() and therefore
// does NOT sample the footswitch -- the debounce integrator is frozen for the
// whole pulse. Every hold window below must budget for that lost sampling time
// on top of the debounce threshold, or a pulse straddling a window can leave
// the integrator one tick short of re-arming and swallow the next press.
//
// The firmware guarantees (a per-variant static_assert in each
// hw_is_sanity_check_failed()) that the pulse is shorter than RELEASE_THRESH,
// so one extra RELEASE_THRESH is a variant-agnostic upper bound on the worst-
// case blocking actuation -- this driver never sees the per-variant pulse width
// (it only loads the HEX), so it leans on that invariant instead. The prior
// fixed +10ms margin was smaller than the relay's 12ms coil pulse, so a coil
// pulse from the noise stream overlapping the drain could leave the integrator
// at 1 (not 0); "press 1" then could not toggle and the check saw toggles=1.
#define SOAK_ACTUATION_GUARD_MS  (RELEASE_THRESH)   // >= worst-case blocking pulse
#define SOAK_HOLD_SLACK_MS       (10u)              // tick-phase granularity slack
#define SOAK_PRESS_HOLD_MS       (PRESSED_THRESH + SOAK_ACTUATION_GUARD_MS + SOAK_HOLD_SLACK_MS)
#define SOAK_RELEASE_HOLD_MS     (RELEASE_THRESH + SOAK_ACTUATION_GUARD_MS + SOAK_HOLD_SLACK_MS)

// ---- 2-press round-trip liveness check --------------------------------------
static void soak_liveness_check(uint32_t sim_ms) {
    footsw_set(0);
    soak_run_ms(SOAK_RELEASE_HOLD_MS);          // drain release-lockout (+ any in-flight pulse)
    guint64 before = g_led_changes;
    int led_start  = g_led_level;

    footsw_set(1); soak_run_ms(SOAK_PRESS_HOLD_MS);     // press 1
    footsw_set(0); soak_run_ms(SOAK_RELEASE_HOLD_MS);
    footsw_set(1); soak_run_ms(SOAK_PRESS_HOLD_MS);     // press 2
    footsw_set(0); soak_run_ms(SOAK_RELEASE_HOLD_MS);

    guint64 delta = g_led_changes - before;
    g_total_checks++;
    if (delta != 2u || g_led_level != led_start) {
        g_liveness_fails++; g_total_failures++;
        fprintf(stderr, "SOAK FAIL [%.4f h]: liveness toggles=%" G_GUINT64_FORMAT
                " (want 2), LED %d->%d\n",
                (double)sim_ms / 3600000.0, delta, led_start, g_led_level);
        fflush(stderr);
    }
}

static uint32_t xs(uint32_t *s){uint32_t x=*s;x^=x<<13;x^=x>>17;x^=x<<5;return *s=x;}

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
    soak_run_ms(5);                             // let init() settle, reach main loop

    // Arm reset counting only now (skip the power-on pass through 0x000).
    get_bp().set_notify_break(g_cpu, 0x000, &g_reset_notifier);

    printf("SOAK START: fw=%s proc=%s FOSC=%lu  dur=%.2f h  "
           "(NB: gpsim WDT@WDTPS=0x08 ~1.057s, not 256ms -- liveness only)\n",
           FW_PATH, PROC_NAME, (unsigned long)F_CPU_HZ,
           (double)SOAK_DURATION_MS / 3600000.0);
    fflush(stdout);

    uint32_t rng = 0xDEADBEEFu;
    uint64_t next_live = SOAK_LIVENESS_INTERVAL_MS;
    uint64_t next_prog = SOAK_PROGRESS_INTERVAL_MS;
    for (uint32_t t = 0; t < (uint32_t)SOAK_DURATION_MS; ++t) {
        footsw_set(((int)(xs(&rng) & 0xFFu)) < 128);
        soak_run_ms(1);
        if (t + 1u >= next_live) { soak_liveness_check(t + 1u); next_live += SOAK_LIVENESS_INTERVAL_MS; }
        if (t + 1u >= next_prog) {
            printf("SOAK [%.2f/%.2f h] checks=%" G_GUINT64_FORMAT " fails=%"
                   G_GUINT64_FORMAT " wdt_resets=%" G_GUINT64_FORMAT "\n",
                   (double)(t + 1u) / 3600000.0, (double)SOAK_DURATION_MS / 3600000.0,
                   g_total_checks, g_total_failures, g_wdt_resets);
            fflush(stdout);
            next_prog += SOAK_PROGRESS_INTERVAL_MS;
        }
    }

    int pass = (g_total_failures == 0);
    printf("\nSOAK %s: %.2f h simulated. wdt_resets=%" G_GUINT64_FORMAT
           " liveness_fails=%" G_GUINT64_FORMAT " checks=%" G_GUINT64_FORMAT "\n",
           pass ? "PASS" : "FAIL", (double)SOAK_DURATION_MS / 3600000.0,
           g_wdt_resets, g_liveness_fails, g_total_checks);
    return pass ? 0 : 1;
}
