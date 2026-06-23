// Soak test for the bypass firmware.
//
// Drives a random footswitch input stream for SOAK_DURATION_MS of simulated
// time (default 86 400 000 ms = 24 h) and verifies two properties at scale:
//
//   1. WDT liveness: the firmware's timer-ISR/main-loop handshake must keep
//      the watchdog pet continuously.  On the tinyx5 build simavr models the
//      WDT system reset; any unexpected reset (cpu_Crashed during the noise
//      stream) is logged as a failure but does NOT stop the run -- the
//      firmware self-reinitializes on tinyx5, and the soak loop continues
//      for the remaining simulated time.
//
//   2. Periodic responsiveness: every SOAK_LIVENESS_INTERVAL_MS the noise
//      stream is paused and a 2-press round-trip is performed.  The device
//      must respond with exactly 2 LED toggles and return to the same effect
//      state it was in before the check.
//
// Differences from test_sim.c:
//   - Failures are never fatal.  Every anomaly is logged to stderr and the
//     soak loop continues uninterrupted.  A failure at hour 1 does not leave
//     the remaining 23 hours untested.
//   - Progress lines are printed to stdout every SOAK_PROGRESS_INTERVAL_MS.
//   - This is a standalone binary; it does not link bypass_pure.c or
//     model_step.h (no lock-step co-simulation -- that is covered by the
//     regular test-sim suite at smaller scale).
//
// Build:  `make test-soak`
// This target is intentionally NOT part of `make test` or `make test-long`.
//
// Default configuration: cd4053 variant, ATtiny85 @ 1 MHz (simavr models the
// WDT system reset for the tinyx5 family).
// Override via Makefile variables: SOAK_VARIANT, SOAK_CHIP, SOAK_DURATION_MS.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <inttypes.h>

#include "sim_avr.h"
#include "sim_elf.h"
#include "avr_ioport.h"
#include "sim_irq.h"

// Pin assignments (FOOTSW_PIN, LED_PIN, and variant-specific control pins).
// bypass_output_host.h provides the AVR-name shims and includes the correct
// variant header for the -D selector passed from the Makefile, mirroring what
// the firmware was compiled with.
#include "bypass_output_host.h"

// Debounce thresholds (PRESSED_THRESH, RELEASE_THRESH) from the firmware's
// single source of truth, via the host-test shim.
#include "bypass_config_host.h"

// ---- Firmware / MCU parameters (injected by the Makefile build rule) --------
#ifndef FW_PATH
#  define FW_PATH  "bypass_cd4053_t85.elf"
#endif
#ifndef MCU_NAME
#  define MCU_NAME "attiny85"
#endif
#ifndef F_CPU_HZ
#  define F_CPU_HZ 1000000UL
#endif

// ---- Soak configuration (override with -DNAME=value on the command line) ----

// Total simulated duration in milliseconds. Default: 86 400 000 ms = 24 h.
#ifndef SOAK_DURATION_MS
#  define SOAK_DURATION_MS 86400000u
#endif

// How often (simulated ms) to pause the noise stream for a liveness check.
// Each check performs a 2-press round-trip (~(4*(PRESSED_THRESH+RELEASE_THRESH
// +10)) ms of simulated time; ~141 ms at default thresholds).
#ifndef SOAK_LIVENESS_INTERVAL_MS
#  define SOAK_LIVENESS_INTERVAL_MS 60000u
#endif

// How often (simulated ms) to print a progress line to stdout.
#ifndef SOAK_PROGRESS_INTERVAL_MS
#  define SOAK_PROGRESS_INTERVAL_MS 3600000u
#endif

// ---- Variant-specific settle time ------------------------------------------
// init() on the relay/mute variants performs one blocking coil/mute pulse
// before enabling the timer.  SETTLE_MS must cover that delay plus a few
// timer ticks so the first main-loop iteration has already run when we return
// from sim_init().
#if defined(TQ2_L2_5V_RELAY)
#  define CTL_DELAY_MS  TQ2_L2_5V_PULSE_MS
#elif defined(CD4053_WITH_MUTE)
#  define CTL_DELAY_MS  CD4053_MUTE_DELAY_MS
#else
#  define CTL_DELAY_MS  0
#endif
#define SETTLE_MS (5u + (unsigned)CTL_DELAY_MS)

// ---- Sim globals ------------------------------------------------------------
static avr_t    *g_avr         = NULL;
static int       g_led_level   = 0;    // current PB1 output level
static uint32_t  g_led_changes = 0;    // total LED transitions (monotonic)
static int       g_saw_crash   = 0;    // set by soak_run_ms() on cpu_Crashed

// ---- Soak-run counters (all reset only at startup) --------------------------
static uint64_t  g_wdt_crashes    = 0; // unexpected WDT resets during noise
static uint64_t  g_liveness_fails = 0; // liveness check failures
static uint64_t  g_total_checks   = 0; // total assertions evaluated
static uint64_t  g_total_failures = 0; // total assertion failures

// ---- Callbacks --------------------------------------------------------------
static void led_hook(struct avr_irq_t *irq, uint32_t value, void *param) {
    (void)irq; (void)param;
    int v = value ? 1 : 0;
    if (v != g_led_level) { g_led_changes++; }
    g_led_level = v;
}

// ---- Helpers ----------------------------------------------------------------
static uint32_t xorshift32(uint32_t *state) {
    uint32_t x = *state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *state = x;
    return x;
}

static void footsw_set(int pressed) {
    avr_irq_t *pin = avr_io_getirq(g_avr, AVR_IOCTL_IOPORT_GETIRQ('B'), FOOTSW_PIN);
    avr_raise_irq(pin, pressed ? 0 : 1);   // 0=low=pressed, 1=high=released
}

// Advance the simulation by `ms` milliseconds of simulated time.
//
// Unlike test_sim.c's run_ms(), this function does NOT break on cpu_Crashed.
// On tinyx5, simavr models the WDT system reset: after cpu_Crashed the
// firmware reinitializes and avr_run() resumes normally from the next call.
// We want that reinitialization to be part of the simulated run rather than
// a hard stop, so we note the crash in g_saw_crash and continue the loop.
static void soak_run_ms(unsigned ms) {
    avr_cycle_count_t target =
        g_avr->cycle + (F_CPU_HZ / 1000UL) * (avr_cycle_count_t)ms;
    while (g_avr->cycle < target) {
        int st = avr_run(g_avr);
        if (st == cpu_Crashed) { g_saw_crash = 1; }
        if (st == cpu_Done)    { break; }
        // cpu_Crashed intentionally falls through: firmware reinits on tinyx5.
    }
}

// (Re)initialize the simavr instance: load firmware, register the LED output
// watcher, drive the initial footswitch level, and let init() settle.
static int sim_init(int footsw_pressed_at_power_on) {
    static elf_firmware_t fw;
    memset(&fw, 0, sizeof(fw));
    if (elf_read_firmware(FW_PATH, &fw) != 0) {
        fprintf(stderr, "ERROR: cannot read firmware '%s'\n", FW_PATH);
        return -1;
    }
    fw.frequency = F_CPU_HZ;

    if (g_avr) { avr_terminate(g_avr); free(g_avr); g_avr = NULL; }
    g_avr = avr_make_mcu_by_name(MCU_NAME);
    if (!g_avr) {
        fprintf(stderr, "ERROR: unknown MCU '%s'\n", MCU_NAME);
        return -1;
    }
    avr_init(g_avr);
    avr_load_firmware(g_avr, &fw);
    g_avr->frequency = F_CPU_HZ;

    g_led_level   = 0;
    g_led_changes = 0;
    g_saw_crash   = 0;

    avr_irq_register_notify(
        avr_io_getirq(g_avr, AVR_IOCTL_IOPORT_GETIRQ('B'), LED_PIN),
        led_hook, NULL);

    footsw_set(footsw_pressed_at_power_on);
    soak_run_ms(SETTLE_MS);
    return 0;
}

// Check g_saw_crash and log any WDT reset observed since the last call.
// Records the failure in the soak counters and clears the flag so the next
// call starts clean.  `sim_t` is the current simulated millisecond, used only
// for the log timestamp.
static void check_and_log_crash(uint32_t sim_t) {
    if (!g_saw_crash) { return; }
    g_wdt_crashes++;
    g_total_failures++;
    g_total_checks++;
    fprintf(stderr,
            "SOAK FAIL [%.4f h elapsed]: unexpected WDT reset "
            "(cumulative crash count: %" PRIu64 ")\n",
            (double)sim_t / 3600000.0, g_wdt_crashes);
    fflush(stderr);
    g_saw_crash = 0;
}

// 2-press round-trip liveness check.
//
// Drives two clean presses separated by RELEASE_THRESH ms to ensure the
// release-lockout drains completely between them.  Verifies that the device
// toggles exactly twice (so the net effect state is unchanged) and that the
// LED returns to the same level it was at before the check.
//
// Works from any starting effect state.  Records failures but always returns
// to allow the soak loop to continue.
static void soak_liveness_check(uint32_t sim_t) {
    // 1. Idle long enough to drain any release-lockout left from the noise
    //    stream; this also establishes a clean starting state for the check.
    g_saw_crash = 0;
    footsw_set(0);
    soak_run_ms(RELEASE_THRESH + 10u);
    check_and_log_crash(sim_t);

    uint32_t before    = g_led_changes;
    int      led_start = g_led_level;

    // 2. Press 1: hold past PRESSED_THRESH to trigger a toggle.
    g_saw_crash = 0;
    footsw_set(1);
    soak_run_ms(PRESSED_THRESH + 10u);
    footsw_set(0);
    soak_run_ms(RELEASE_THRESH + 10u);  // drain lockout before press 2
    check_and_log_crash(sim_t);

    // 3. Press 2: should toggle back to the starting effect state.
    g_saw_crash = 0;
    footsw_set(1);
    soak_run_ms(PRESSED_THRESH + 10u);
    footsw_set(0);
    soak_run_ms(RELEASE_THRESH + 10u);
    check_and_log_crash(sim_t);

    uint32_t delta   = g_led_changes - before;
    int      led_end = g_led_level;

    g_total_checks++;
    if (delta != 2u) {
        g_liveness_fails++;
        g_total_failures++;
        fprintf(stderr,
                "SOAK FAIL [%.4f h]: liveness: "
                "expected 2 LED toggles, got %" PRIu32 "\n",
                (double)sim_t / 3600000.0, delta);
        fflush(stderr);
    } else if (led_end != led_start) {
        g_liveness_fails++;
        g_total_failures++;
        fprintf(stderr,
                "SOAK FAIL [%.4f h]: liveness: "
                "effect state changed (LED %d -> %d after 2-press round-trip)\n",
                (double)sim_t / 3600000.0, led_start, led_end);
        fflush(stderr);
    }
}

// ---- Main soak loop ---------------------------------------------------------
int main(void) {
    if (sim_init(0) != 0) {
        fprintf(stderr, "FATAL: could not initialize simulation; aborting.\n");
        return 1;
    }

    printf("SOAK START: firmware=%s  MCU=%s  F_CPU=%lu Hz\n",
           FW_PATH, MCU_NAME, (unsigned long)F_CPU_HZ);
    printf("SOAK START: duration=%" PRIu32 " ms (%.1f h)  "
           "liveness every %" PRIu32 " ms  "
           "progress every %" PRIu32 " ms\n",
           (uint32_t)SOAK_DURATION_MS,
           (double)SOAK_DURATION_MS / 3600000.0,
           (uint32_t)SOAK_LIVENESS_INTERVAL_MS,
           (uint32_t)SOAK_PROGRESS_INTERVAL_MS);
    fflush(stdout);

    uint32_t rng             = 0xDEADBEEF;
    uint32_t next_liveness_t = SOAK_LIVENESS_INTERVAL_MS;
    uint32_t next_progress_t = SOAK_PROGRESS_INTERVAL_MS;

    for (uint32_t t = 0; t < (uint32_t)SOAK_DURATION_MS; ++t) {
        // Drive one millisecond of random footswitch noise and run the sim.
        int pressed = ((int)(xorshift32(&rng) & 0xFFu)) < 128;
        footsw_set(pressed);
        g_saw_crash = 0;
        soak_run_ms(1);
        check_and_log_crash(t + 1u);

        // Periodic liveness check: pause noise, do 2-press round-trip.
        if (t + 1u >= next_liveness_t) {
            soak_liveness_check(t + 1u);
            next_liveness_t += SOAK_LIVENESS_INTERVAL_MS;
        }

        // Periodic progress report.
        if (t + 1u >= next_progress_t) {
            printf("SOAK [%.1f / %.1f h]: "
                   "checks=%" PRIu64 "  fails=%" PRIu64
                   "  (wdt_crashes=%" PRIu64 "  liveness_fails=%" PRIu64 ")\n",
                   (double)(t + 1u) / 3600000.0,
                   (double)SOAK_DURATION_MS / 3600000.0,
                   g_total_checks, g_total_failures,
                   g_wdt_crashes, g_liveness_fails);
            fflush(stdout);
            next_progress_t += SOAK_PROGRESS_INTERVAL_MS;
        }
    }

    // Final summary.
    int pass = (g_total_failures == 0);
    printf("\nSOAK %s: %" PRIu32 " ms (%.1f h) simulated.\n",
           pass ? "PASS" : "FAIL",
           (uint32_t)SOAK_DURATION_MS,
           (double)SOAK_DURATION_MS / 3600000.0);
    printf("  WDT crashes:       %" PRIu64 "\n", g_wdt_crashes);
    printf("  Liveness failures: %" PRIu64 "\n", g_liveness_fails);
    printf("  Total checks:      %" PRIu64 "\n", g_total_checks);
    printf("  Total failures:    %" PRIu64 "\n", g_total_failures);

    if (g_avr) { avr_terminate(g_avr); free(g_avr); }
    return pass ? 0 : 1;
}
