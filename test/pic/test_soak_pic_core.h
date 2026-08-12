// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// Include-only long-duration soak implementation shared by the PIC part
// adapters -- the PIC analogue of test/avr/test_soak.c (which links simavr).
// It links libgpsim, drives the real built HEX, and verifies the same two
// properties at scale:
//
//   1. WDT liveness  -- the firmware's polled tick/CLRWDT handshake must keep
//      the watchdog pet continuously. gpsim models the PIC WDT reset (verified
//      on both families); any WDT reset during the noise stream is logged as a
//      failure but does NOT stop the run -- the soak continues for the full
//      duration. A simulator core that stops advancing is different: no further
//      duration can be exercised, so that failure aborts the run immediately.
//   2. Periodic responsiveness -- every SOAK_LIVENESS_INTERVAL_MS the noise
//      stream is paused and a 2-press round-trip is performed. The device must
//      respond with exactly 2 LED toggles and return to its prior effect state.
//
// Like the AVR soak, observable firmware failures are non-fatal: each anomaly is
// logged to stderr and the loop continues so the full duration is exercised even
// after an early failure. A simulator wedge is necessarily fatal to the run;
// retrying a core that cannot advance would fabricate duration evidence. The PIC
// shells have no simavr lock-step; this is their only at-scale test.
//
// The LED is bit 0 of the output latch on every part and variant, so this driver
// is variant-agnostic -- the variant selects which HEX is loaded and how long a
// blocking actuation steals integration from a debounce window.
//
// WHAT IS NOT HERE. Three facts the adapter states before including this file,
// and the reason each one had to leave the mechanism:
//
//   1. WHERE THE LED LEVEL IS READ. The adapter includes its family register map
//      (pic*_regs.h), whose latch entry is a LATx SFR on a part that has one and
//      the shell's SRAM shadow on a part that does not. Sampling write INTENT
//      rather than the pin is deliberate and loses nothing here: this soak asks
//      whether the firmware still responds, and a port that stopped following
//      that intent is a fault the firmware's own per-tick gate turns into a WDT
//      reset -- which is the failure this file already counts.
//   2. HOW LONG A DEBOUNCE TICK IS. The firmware counts thresholds in TICKS and
//      this driver advances the simulation in MILLISECONDS, so the two units
//      coincide only where the tick is 1.000 ms. See SOAK_TICK_US below.
//   3. WHAT THE SIMULATED WATCHDOG PROVES. gpsim's WDT calibration relates to
//      the datasheet differently on each family, so the caveat printed in the
//      start banner is the adapter's to state rather than a constant here.

#ifndef TEST_PIC_TEST_SOAK_PIC_CORE_H
#define TEST_PIC_TEST_SOAK_PIC_CORE_H

#include <cstdio>
#include <cstdint>
#include <cinttypes>
#include <string>
#include <iostream>

#include <glib.h>                 // guint64, G_GUINT64_FORMAT
#include "processor.h"            // Processor (rma, pc, run)
#include "pic-processor.h"        // pic_processor
#include "gpsim_time.h"           // get_cycles(), Cycle_Counter
#include "breakpoints.h"          // get_bp(), set_notify_break
#include "trigger.h"              // TriggerObject
#include "registers.h"            // Register::get_value()

// gpsim bring-up shared with the io / lock-step / fault harnesses: NullBuf,
// g_cpu / g_fsw_node / g_fsw_src, FOOTSW_PIN_NAME, gpsim_bootstrap_cpu(),
// gpsim_attach_footswitch() and footsw_set().
#include "pic/gpsim_bootstrap.h"
#include "pic/soak_sampling.h"

// ---- Injected parameters: EVERY one is required, none has a default ---------
//
// THIS MECHANISM IS SHARED BY THREE PARTS, and the 10F32x adapter beside it by
// two of them: PIC_SOAK_SRC names test_soak_pic.cc once, and both
// PIC10F322_SOAK_COMPILE and PIC10F320_SOAK_COMPILE pass their own part's values
// through it. A single fallback here is therefore correct for at most one caller
// and silently wrong for the others -- which is not a hypothetical shape: it is
// exactly how the shared gpsim CLI wrapper came to run PIC10F320 images on a
// p10f322 model in `v0.9.8`, passing, because the 322 is a superset of the 320.
//
// The per-part harnesses (test_io/test_fault/test_lockstep) may keep an adapter
// default for PROC_NAME precisely because they DO have one adapter per part, so
// their fallback is per-part correct. The soak's 10F32x adapter serves two parts
// and so can have none -- and the PIC12F675 adapter, which serves one and could
// have had one, deliberately has none either. A rule that held for two adapters
// out of three would be a rule every reader has to re-derive.
//
// Each #error names the Makefile variable its value comes from, so a severed
// injection is reported as the rename it is rather than as a missing macro.
#ifndef FW_PATH
#  error "FW_PATH must be injected: -DFW_PATH from PIC10F322_SOAK_HEX, PIC10F320_SOAK_HEX or PIC12F675_SOAK_HEX"
#endif
#ifndef PROC_NAME
#  error "PROC_NAME must be injected: -DPROC_NAME from PIC10F322_GPSIM_PROC, PIC10F320_GPSIM_PROC or PIC12F675_GPSIM_PROC"
#endif
#ifndef F_CPU_HZ
   // FOSC; instruction clock = FOSC/4. A part fact, and NOT a shared one: the
   // two 10F32x parts run at 2 MHz and the PIC12F675 at 4 MHz.
#  error "F_CPU_HZ must be injected: -DF_CPU_HZ from PIC10F322_XTAL, PIC10F320_XTAL or PIC12F675_XTAL"
#endif
#define CYCLES_PER_MS  ((F_CPU_HZ / 4UL) / 1000UL)   // 500 @ 2 MHz, 1000 @ 4 MHz

// Debounce thresholds (PRESSED_THRESH, RELEASE_THRESH) come from the firmware's
// single source of truth (src/bypass_config.h) via the host-test shim, so this
// test can never silently drift from the firmware. The Makefile adds -Itest.
#include "bypass_config_host.h"

// ---- Where the LED level is read --------------------------------------------
// From the adapter's family register map; the firmware side of the same fact is
// src/bypass_pins_*.h. The LED is bit 0 of the output latch on every part.
#ifndef PIC_REG_LATCH_ADDR
#  error "part adapter must include its family register map (e.g. pic/pic10f32x_regs.h); on a part whose latch is an SRAM shadow, that map needs the address injected from the build's .sym"
#endif
#ifndef PIC_REG_LED_MASK
#  error "the family register map did not define PIC_REG_LED_MASK"
#endif

// ---- How long the firmware's debounce tick is, in microseconds --------------
// PRESSED_THRESH and RELEASE_THRESH are counts of that tick; every hold below is
// a count of simulated milliseconds. On the PIC10F32x parts TMR2 at 1:4 from
// 2 MHz gives an exact 1.000 ms tick and the two units are one unit. The
// PIC12F675 has no period register and counts four 256 us TMR0 rollovers, so its
// tick is 1.024 ms: 25 release ticks are 25.6 ms, not 25 ms. That 2.4% fits
// inside the slack below -- which is precisely why it is converted here instead.
// The slack is already load-bearing for a different reason (see the liveness
// check), and a margin doing two jobs reports neither when it runs out.
// ---- What this part's simulated watchdog proves -----------------------------
// A parenthetical for the start banner. Per-adapter because gpsim's WDT model
// stands in a different relation to the datasheet on each family, and a banner
// carrying another part's number would be worse than one carrying none.
#ifndef SOAK_WDT_NOTE
#  error "SOAK_WDT_NOTE must be defined by the part adapter: what this part's simulated watchdog does and does not show"
#endif

// ---- Soak configuration ----------------------------------------------------
// Set these through their Makefile variables (PIC10F322_SOAK_DURATION_MS et al),
// never by editing a default here. 24 h sim = 3.46e11 instr-cycles and gpsim is
// slower than simavr, so the MAKEFILE-side default is 1 h (the AVR's is 24 h)
// and 24 h is an explicit opt-in; that asymmetry belongs in the Makefile, where
// it is visible, rather than here, where a severed injection would reach it.
#ifndef SOAK_DURATION_MS
#  error "SOAK_DURATION_MS must be injected: -DSOAK_DURATION_MS from PIC10F322_SOAK_DURATION_MS, PIC10F320_SOAK_DURATION_MS or PIC12F675_SOAK_DURATION_MS"
#endif
#ifndef SOAK_LIVENESS_INTERVAL_MS
#  error "SOAK_LIVENESS_INTERVAL_MS must be injected: -DSOAK_LIVENESS_INTERVAL_MS from that part's SOAK_LIVENESS_INTERVAL_MS variable"
#endif
#ifndef SOAK_PROGRESS_INTERVAL_MS
#  error "SOAK_PROGRESS_INTERVAL_MS must be injected: -DSOAK_PROGRESS_INTERVAL_MS from that part's SOAK_PROGRESS_INTERVAL_MS variable"
#endif

#include "../soak_timing_config.h"

// Worst-case blocking output actuation (ms). A relay coil pulse / CD4053 mute
// runs as a busy __delay_ms() in hw_set_*_state(), which freezes the POLLED PIC
// main loop: the loop stops spinning, the tick flag merely latches once, and up
// to this many milliseconds of debounce integration are stolen from whichever
// window the pulse overlaps. (The AVR integrates in its timer ISR, which keeps
// counting through the block, so it is immune -- see the liveness-check note
// below.) The build passes the active variant's value (relay 12, mute 5, simple
// 0); the PIC12F675 derives it from the selected output driver's header, while
// the 10F32x builds use their part-local Make maps.
//
// This one previously defaulted to the relay's 12 ms on the reasoning that an
// unspecified build should be over-held rather than under-held. That reasoning
// is sound for a MISSING value and wrong for a SEVERED one: the map lookup has
// already failed once in this tree and emitted `-DSOAK_ACTUATION_BLOCK_MS=u`,
// and a default that silently absorbs the next such failure hides which variant
// the binary was actually sized for.
#ifndef SOAK_ACTUATION_BLOCK_MS
#  error "SOAK_ACTUATION_BLOCK_MS must be injected for the selected output variant"
#endif
#include "pic/soak_hold_timing.h"
// Safety cap: max run() resumes to cover one ms. A genuinely wedged core (PC
// stuck, never reaching the cycle break) trips this instead of hanging forever.
#define MAX_RESUMES_PER_MS 64

// ---- Sim globals ------------------------------------------------------------
// g_cpu / g_fsw_node / g_fsw_src come from pic/gpsim_bootstrap.h.
static int       g_led_level      = 0;
static guint64   g_led_changes    = 0;
static guint64   g_wdt_resets     = 0;   // counted by ResetNotifier (non-halting)
static guint64   g_liveness_fails = 0;
static guint64   g_total_checks   = 0;
static guint64   g_total_failures = 0;
static guint64   g_start_cycles   = 0;

static double sim_hours() {
    return (double)get_cycles().get() / (double)(F_CPU_HZ / 4UL) / 3600.0;
}

// ---- Reset detection (replaces simavr's cpu_Crashed handling) ---------------
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
// footsw_set() comes from pic/gpsim_bootstrap.h.

// Poll the output latch's LED bit once per ms. The LED only changes on debounced
// edges (>> 1 ms apart), so per-ms sampling never misses a toggle. get_value()
// reads the latched value without triggering read-side-effects/breakpoints, and
// where the latch is an SRAM shadow it reads that GPR the same way.
static void sample_led() {
    Register *latch = g_cpu->rma.get_register(PIC_REG_LATCH_ADDR);
    int v = (latch->get_value() & PIC_REG_LED_MASK) ? 1 : 0;
    if (v != g_led_level) g_led_changes++;
    g_led_level = v;
}

// Advance exactly one ms. A WDT reset may halt run() early and/or fire the
// notify callback, so resume until this millisecond's target is reached.
static bool soak_run_one_ms() {
    guint64 target = get_cycles().get() + CYCLES_PER_MS;
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
            return false;
        }
    }
    return true;
}

// Multi-ms switch holds must remain observable at every millisecond boundary;
// sampling only their endpoint can hide an even number of unintended toggles.
static bool soak_run_ms(unsigned ms) {
    return soak_run_each_ms(ms, soak_run_one_ms, sample_led);
}

// ---- 2-press round-trip liveness check --------------------------------------
// Each press/release is held for its threshold's worth of TICKS, converted to
// milliseconds, plus SOAK_ACTUATION_BLOCK_MS, plus 10 ms. The AVR soak
// (test_soak.c) holds only THRESH + 10 ms because its integrator runs in the
// timer ISR and keeps counting through a blocking actuation. The PIC is Model B
// (a polled main loop): a coil/mute pulse freezes sampling and steals up to
// SOAK_ACTUATION_BLOCK_MS of integration from a window. With only +10 ms of
// slack a relay pulse (12 ms) can leave the settle window short of
// RELEASE_THRESH ticks, so the check would enter un-re-armed and waste a press
// (observed as "toggles=1"). Sizing every window ticks + block + slack models a
// realistic minimum footswitch press on the polled core -- still far below any
// human press (>=50 ms) -- and does NOT relax what the firmware must do.
static bool soak_liveness_check(uint32_t sim_ms) {
    footsw_set(0);
    if (!soak_run_ms(SOAK_RELEASE_HOLD_MS)) return false; // drain release-lockout
    guint64 before = g_led_changes;
    int led_start  = g_led_level;

    footsw_set(1);
    if (!soak_run_ms(SOAK_PRESS_HOLD_MS)) return false; // press 1
    footsw_set(0);
    if (!soak_run_ms(SOAK_RELEASE_HOLD_MS)) return false;
    footsw_set(1);
    if (!soak_run_ms(SOAK_PRESS_HOLD_MS)) return false; // press 2
    footsw_set(0);
    if (!soak_run_ms(SOAK_RELEASE_HOLD_MS)) return false;

    guint64 delta = g_led_changes - before;
    g_total_checks++;
    if (delta != 2u || g_led_level != led_start) {
        g_liveness_fails++; g_total_failures++;
        fprintf(stderr, "SOAK FAIL [%.4f h]: liveness toggles=%" G_GUINT64_FORMAT
                " (want 2), LED %d->%d\n",
                (double)sim_ms / 3600000.0, delta, led_start, g_led_level);
        fflush(stderr);
    }
    return true;
}

static uint32_t xs(uint32_t *s){uint32_t x=*s;x^=x<<13;x^=x>>17;x^=x<<5;return *s=x;}

int main() {
    if (!gpsim_bootstrap_cpu(FW_PATH, PROC_NAME))            return 1;
    if (!gpsim_attach_footswitch(FOOTSW_PIN_NAME, PROC_NAME)) return 1;

    g_start_cycles = get_cycles().get();
    footsw_set(0);                              // released at power-on
    bool advancing = soak_run_ms(5);            // let init() settle, reach main loop

    // Arm reset counting only now (skip the power-on pass through 0x000).
    if (advancing) get_bp().set_notify_break(g_cpu, 0x000, &g_reset_notifier);

    printf("SOAK START: fw=%s proc=%s FOSC=%lu  dur=%.2f h  "
           SOAK_WDT_NOTE "\n",
           FW_PATH, PROC_NAME, (unsigned long)F_CPU_HZ,
           (double)SOAK_DURATION_MS / 3600000.0);
    fflush(stdout);

    uint32_t rng = 0xDEADBEEFu;
    uint64_t next_live = SOAK_LIVENESS_INTERVAL_MS;
    uint64_t next_prog = SOAK_PROGRESS_INTERVAL_MS;
    uint32_t completed_ms = 0; // noise milliseconds whose due liveness work also completed
    for (uint32_t t = 0; advancing && t < (uint32_t)SOAK_DURATION_MS; ++t) {
        footsw_set(((int)(xs(&rng) & 0xFFu)) < 128);
        if (!soak_run_ms(1)) {
            advancing = false;
            break;
        }
        if (SOAK_LIVENESS_DUE(t + 1u, next_live)) {
            if (!soak_liveness_check(t + 1u)) {
                advancing = false;
                break;
            }
            next_live += SOAK_LIVENESS_INTERVAL_MS;
        }
        completed_ms = t + 1u;
        if (t + 1u >= next_prog) {
            printf("SOAK [%.2f/%.2f h] checks=%" G_GUINT64_FORMAT " fails=%"
                   G_GUINT64_FORMAT " wdt_resets=%" G_GUINT64_FORMAT "\n",
                   (double)(t + 1u) / 3600000.0, (double)SOAK_DURATION_MS / 3600000.0,
                   g_total_checks, g_total_failures, g_wdt_resets);
            fflush(stdout);
            next_prog += SOAK_PROGRESS_INTERVAL_MS;
        }
    }

    guint64 advanced_cycles = get_cycles().get() - g_start_cycles;
    double advanced_ms = (double)advanced_cycles / (double)CYCLES_PER_MS;
    int pass = advancing && completed_ms == (uint32_t)SOAK_DURATION_MS
        && g_total_failures == 0;
    if (pass) {
        printf("\nSOAK PASS: %u ms (%.2f h) simulated. %" G_GUINT64_FORMAT
               " cycles (%.3f ms) advanced; wdt_resets=%" G_GUINT64_FORMAT
               " liveness_fails=%" G_GUINT64_FORMAT " checks=%" G_GUINT64_FORMAT "\n",
               (unsigned int)SOAK_DURATION_MS,
               (double)SOAK_DURATION_MS / 3600000.0, advanced_cycles, advanced_ms,
               g_wdt_resets, g_liveness_fails, g_total_checks);
    } else {
        printf("\nSOAK FAIL: %u/%u requested ms completed; %" G_GUINT64_FORMAT
               " cycles (%.3f ms) advanced. wdt_resets=%" G_GUINT64_FORMAT
               " liveness_fails=%" G_GUINT64_FORMAT " checks=%" G_GUINT64_FORMAT "\n",
               (unsigned int)completed_ms, (unsigned int)SOAK_DURATION_MS,
               advanced_cycles, advanced_ms, g_wdt_resets, g_liveness_fails,
               g_total_checks);
    }
    printf("SOAK_RESULT format=1 status=%s combination=%s duration_ms=%u"
           " liveness_interval_ms=%u checks=%" G_GUINT64_FORMAT
           " failures=%" G_GUINT64_FORMAT " watchdog_failures=%" G_GUINT64_FORMAT
           " liveness_failures=%" G_GUINT64_FORMAT "\n",
           pass ? "pass" : "fail", SOAK_COMBINATION_NAME,
           (unsigned int)completed_ms,
           (unsigned int)SOAK_LIVENESS_INTERVAL_MS,
           g_total_checks, g_total_failures, g_wdt_resets,
           g_liveness_fails);
    return pass ? 0 : 1;
}

#endif // TEST_PIC_TEST_SOAK_PIC_CORE_H
