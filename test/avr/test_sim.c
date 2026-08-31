// simavr integration tests for the bypass firmware (all output variants).
//
// This runs the ACTUAL compiled firmware ELF inside the simavr
// instruction-accurate simulator, drives the footswitch pin (PB0) over
// simulated time, and asserts on the LED (PB1) and the variant's control
// outputs (PB2/PB3).
//
// Unlike test_logic_host.c (a golden model), this exercises the real ISR,
// Timer0 configuration, sleep/wake, and main-loop state machine as compiled
// for the AVR.
//
// Build & run: see Makefile target `test-sim-attiny13a` (one binary per variant).
//
// The debounce algorithm -- and therefore the LED behavior -- is IDENTICAL
// across all three output variants: PB1 is lit when engaged, dark when
// bypassed, with exactly one transition per toggle. So the bulk of this suite
// (debounce, timing, noise immunity, watchdog, fault recovery) is
// variant-independent and observes only the LED. Only the CONTROL outputs
// differ between variants, and those are checked by dedicated per-variant
// tests (see "variant-specific control output" below).
//
// Pin mapping (from the firmware headers, single source of truth):
//   PB0 = footswitch input : LOW = pressed, HIGH = released
//   PB1 = status LED output: HIGH = engaged/lit, LOW = bypass/dark
//   PB2/PB3 = control outputs, meaning depends on the selected variant:
//     CD4053_SIMPLE    : PB2 = CD4053 ctrl, PB3 unused (low)
//     CD4053_WITH_MUTE : PB2 = CTL1, PB3 = CTL2 (mute-before-switch)
//     TQ2_L2_5V_RELAY  : PB2 = RESET coil, PB3 = SET coil (pulsed, then parked low)
//   The CD4053 analog-switch variants use one MCU pin polarity for both CD4053
//   and pin-compatible TMUX4053 boards (see X4053_CTL_FOR_STATE): LOW in BYPASS
//   and HIGH when ENGAGED.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "sim_avr.h"
#include "sim_elf.h"
#include "avr_ioport.h"
#include "sim_irq.h"
#include "sim_cycle_timers.h"
#include "sim_vcd_file.h"

// Pull PRESSED_THRESH / RELEASE_THRESH directly from the firmware's
// bypass_config.h, via the host shim, so the sim tests can never drift from the
// real firmware thresholds.
#include "bypass_config_host.h"

// Pull the pin assignments (FOOTSW_PIN, LED_PIN, and the variant control pins)
// directly from the firmware output headers, via the host shim, so the harness
// reads the SAME pins the firmware drives. The selected variant (CD4053_SIMPLE /
// CD4053_WITH_MUTE / TQ2_L2_5V_RELAY) is passed by the Makefile as -D, matching
// the firmware build.
#include "bypass_output_host.h"

// Canonical single-step model (state_t, step_result_t, step()), shared with
// test_model_check.c and test_symbolic.c.  The lock-step model below delegates
// to step() so the three test files always exercise the same algorithm. Only
// the lock-step test uses it, so the TRACE build (which only emits a waveform)
// does not need it.
#ifndef TRACE
#include "model_step.h"
#endif

// ---- Injected parameters: EVERY one is required, none has a default ---------
//
// These three were `#ifndef` fallbacks holding the ATtiny13a's values, which
// made this harness the last place in the tree where a part was identified by
// the OMISSION of a field: the tinyx5 rules injected all three, the ATtiny13a
// rules injected only FW_PATH and let the other two default. `v0.9.8` removed
// exactly that pattern from the image basenames and the make goals; the C
// harness kept it one layer down, where a severed injection is silent and the
// simulated part is whatever the last editor of this file believed.
//
// The MCU_NAME default was also the wrong spelling -- "attiny13", where the
// rest of the tree says attiny13a. simavr accepts both, so nothing ever
// complained. Both ATtiny13a rules now pass ATTINY13A_MCU and ATTINY13A_F_CPU.
//
// Each #error names the Makefile variable its value comes from, so a severed
// injection is reported as the rename it is rather than as a missing macro.
#ifndef FW_PATH
#  error "FW_PATH must be injected: -DFW_PATH from the VARIANT_SIM_T13/VARIANT_SIM_X5 rule"
#endif
#ifndef MCU_NAME
#  error "MCU_NAME must be injected: -DMCU_NAME from ATTINY13A_MCU or mmcu_<n>"
#endif
#ifndef F_CPU_HZ
#  error "F_CPU_HZ must be injected: -DF_CPU_HZ from ATTINY13A_F_CPU or TINYX5_F_CPU"
#endif

// Worst-case blocking delay (ms) the selected variant performs inside
// set_bypass_state()/set_engaged_state(): the relay coil pulse or the
// mute-before-switch settle. The CD4053 simple variant does no delay. The test
// harness uses this to size settle/budget windows so a toggle that blocks the
// main loop for this long is not mistaken for a hung core.
#if defined(TQ2_L2_5V_RELAY)
#  define CTL_DELAY_MS  TQ2_L2_5V_PULSE_MS
// Panasonic TQ2-L2-5V specified minimum coil pulse for GUARANTEED actuation.
// The firmware drives TQ2_L2_5V_PULSE_MS (12 ms, 3x margin); the recovery pulse
// must clear this electrical floor before mechanical convergence can be expected
// under the documented hardware assumptions. Simulation proves the PULSE, never
// the relay mechanics.
#  define TQ2_L2_5V_MIN_PULSE_MS 4U
#elif defined(CD4053_WITH_MUTE)
#  define CTL_DELAY_MS  CD4053_MUTE_DELAY_MS
#else
#  define CTL_DELAY_MS  0
#endif

// Expected MCU control-pin level for a given effect state on the CD4053
// analog-switch variants. The one supported polarity serves both CD4053 and
// pin-compatible TMUX4053 boards. The natural, MCU-absent state (control pins at
// the bypass level via pulldown/pullup) is BYPASS by design.
//   MCU pin == effect_state  (ENGAGED -> MCU HIGH, BYPASS -> MCU LOW)
// (effect_state: 1 = ENGAGED, 0 = BYPASS. Not meaningful for the relay variant,
// whose coil pins are pulsed and parked low regardless of polarity.)
#define X4053_CTL_FOR_STATE(es)  ((int)(es))

// Cycle at which control line `ctl` last settled to its level for effect state
// `es`. The mute-before-switch sequence (CD4053_WITH_MUTE) reaches the engaged
// level via a rising edge and the bypass level via a falling edge; selecting the
// edge by the target level keeps the mute-window timing measurement correct.
// (g_ctl_rise_cycle / g_ctl_fall_cycle are defined below; this macro is only
// expanded after them.)
#define X4053_CTL_EDGE_CYCLE(ctl, es) \
    (X4053_CTL_FOR_STATE(es) ? g_ctl_rise_cycle[ctl] : g_ctl_fall_cycle[ctl])

// Settle time after (re)loading firmware: enough for init() -- which on the
// relay/mute variants performs one blocking coil/mute pulse before enabling the
// timer -- to finish AND for the first few 1ms ticks to land. 5ms base + the
// variant's init pulse.
#define SETTLE_MS (5u + CTL_DELAY_MS)

// ---- Workload knobs: these fallbacks are LOAD-BEARING, do not make them errors
//
// Every SIM_* default below IS the exhaustive workload. `make test` passes the
// smaller FAST_SIM_DEFS; `make test-long` -- the release gate -- sets
// SIM_DEFS = FULL_SIM_DEFS, and FULL_SIM_DEFS is deliberately EMPTY, so the
// full run reaches these values by NOT overriding them.
//
// That makes them the opposite case from the injected parameters at the top of
// this file, and the distinction is the whole point of classifying them: there,
// reaching a default means an injection was severed and the test silently
// measured the wrong thing; here, reaching a default is the exhaustive run
// working as designed. Turning these into #errors would fail `make test-long`.
#ifndef SIM_RANDOM_NOISE_DURATION_MS
#define SIM_RANDOM_NOISE_DURATION_MS 60000u
#endif

// Expected toggle count for the fixed-seed (0xDEADBEEF) random-noise stream.
// This is duration-dependent and empirically measured against BOTH the real
// firmware (simavr) and the golden model -- they agree exactly. When changing
// SIM_RANDOM_NOISE_DURATION_MS, set a matching expected count (or 0 to disable
// the exact check and rely only on the physical ceiling).
//   5000 ms  -> 10 toggles
//   10000 ms -> 16 toggles
//   60000 ms -> 77 toggles
#ifndef SIM_NOISE_EXPECTED_TOGGLES
#  if (SIM_RANDOM_NOISE_DURATION_MS == 60000u)
#    define SIM_NOISE_EXPECTED_TOGGLES 77u
#  elif (SIM_RANDOM_NOISE_DURATION_MS == 5000u)
#    define SIM_NOISE_EXPECTED_TOGGLES 10u
#  else
#    define SIM_NOISE_EXPECTED_TOGGLES 0u /* 0 => skip exact check */
#  endif
#endif

#ifndef SIM_ADVERSARIAL_CYCLES
#define SIM_ADVERSARIAL_CYCLES 50
#endif

#ifndef SIM_EXTREME_BOUNCE_PRESSES
#define SIM_EXTREME_BOUNCE_PRESSES 10
#endif

#ifndef SIM_EXTREME_BOUNCE_CHATTER_MS
#define SIM_EXTREME_BOUNCE_CHATTER_MS 50
#endif

#ifndef SIM_SUSTAINED_NOISE_DURATION_MS
#define SIM_SUSTAINED_NOISE_DURATION_MS 10000u
#endif

// Number of asymmetric-EMI bursts (each burst = 50ms noise + 200ms silence,
// i.e. 250ms of simulated time). 240 bursts == 60s.
#ifndef SIM_EMI_BURSTS
#define SIM_EMI_BURSTS 240
#endif

// Number of simulated power-on cycles for the power-on robustness test.
#ifndef SIM_POWER_ON_BOOTS
#define SIM_POWER_ON_BOOTS 30
#endif

// Iterations for the odd/even toggle-parity invariant stream. Each iteration
// holds a random level for up to ~12ms of *real-firmware* simulated time, so
// this is the dominant cost of the sim suite; keep modest for `make test` and
// crank it up via -D for `make test-long`.
#ifndef SIM_PARITY_ITERS
#define SIM_PARITY_ITERS 400u
#endif

// Number of 1ms ticks driven through the lock-step co-simulation (AVR image vs
// host-compiled shipping core, internal-state comparison every tick). Each tick
// is one full wake/process/sleep cycle of the real firmware, so this is
// comparable in cost to the parity stream; keep modest for `make test`, crank
// via -D for `make test-long`.
#ifndef SIM_LOCKSTEP_ITERS
#define SIM_LOCKSTEP_ITERS 5000u
#endif

// SRAM-mapped I/O register addresses (I/O addr + 0x20 SFR offset). Used by the
// fault-injection tests to poke registers directly.
#define TIMSK_MEM_ADDR 0x59  // TIMSK0/TIMSK I/O addr 0x39 + SFR offset 0x20
#define DDRB_MEM_ADDR  0x37  // DDRB I/O addr 0x17 + SFR offset 0x20
#define DDRB_EXPECTED  0x1EU // PB1..PB4 outputs; PB0 footswitch/PB5 RESET inputs
#define PORTB_MEM_ADDR 0x38  // PORTB I/O addr 0x18 + SFR offset 0x20
#define SPL_MEM_ADDR   0x5D  // SPL I/O addr 0x3D + SFR offset 0x20
#define SPH_MEM_ADDR   0x5E  // SPH I/O addr 0x3E + SFR offset 0x20 (not present on ATtiny13a)
#define WDTCSR_MEM_ADDR 0x41 // WDTCR I/O addr 0x21 + SFR offset 0x20 (same on t13a and tinyx5)
#define TIMER_ISR_CALLED_VALUE     0x00U // timer_isr_called_t values in firmware
#define TIMER_ISR_NOT_CALLED_VALUE 0x01U
// Config SFRs re-checked by the firmware's per-tick SFR-integrity gate. CLKPR
// and TCCR0B share the same I/O address on both families, but TCCR0A and OCR0A
// do NOT (verified against avr-libc iotn13a.h vs iotn85.h), so they are selected
// per target -- mirroring the SPH per-family note above.
#define CLKPR_MEM_ADDR  0x46 // CLKPR  I/O addr 0x26 + SFR offset 0x20 (same on t13a and tinyx5)
#define TCCR0B_MEM_ADDR 0x53 // TCCR0B I/O addr 0x33 + SFR offset 0x20 (same on t13a and tinyx5)
#ifdef TARGET_TINYX5
#  define TCCR0A_MEM_ADDR 0x4A // ATtiny85 TCCR0A I/O addr 0x2A + SFR offset 0x20
#  define OCR0A_MEM_ADDR  0x49 // ATtiny85 OCR0A  I/O addr 0x29 + SFR offset 0x20
#else
#  define TCCR0A_MEM_ADDR 0x4F // ATtiny13A TCCR0A I/O addr 0x2F + SFR offset 0x20
#  define OCR0A_MEM_ADDR  0x56 // ATtiny13A OCR0A  I/O addr 0x36 + SFR offset 0x20
#endif

// --- global sim state shared with output-watch callbacks -------------------
static avr_t      *g_avr = NULL;
static int         g_led_level    = 0; // current PB1 level
static uint32_t    g_led_changes  = 0; // count of PB1 transitions
static int         g_saw_sleep    = 0; // set if CPU ever entered cpu_Sleeping
static int         g_saw_crash    = 0; // set if CPU ever hit cpu_Crashed
static uint32_t    g_resets       = 0; // count of device resets (see reset_hook)

// simavr calls avr->reset from avr_reset(). A watchdog timeout reaches
// avr_reset() through avr_watchdog_run_callback_software_reset(), so this hook
// is a direct, positive witness that the WDT actually reset the device.
//
// Do NOT use cpu_Crashed for this: simavr 1.6 sets that state only from
// avr_sadly_crashed() (illegal opcode / stack crash). Its watchdog reset path
// leaves the core in cpu_Running, and a core parked in cli()+busy-loop is
// simply "running" as far as the simulator is concerned.
//
// The MCU model's own reset callback is chained rather than replaced. On the
// tinyx5 it is currently empty (simavr's tx5_reset), but a harness that
// silently drops a part's reset work would be wrong the moment that changes.
static void (*g_mcu_reset)(struct avr_t *avr) = NULL;
static void reset_hook(avr_t *avr) {
    g_resets++;
    if (g_mcu_reset != NULL) { g_mcu_reset(avr); }
}

// Control-output watchers. PB2 and PB3 are watched generically; their meaning
// is variant-specific (see the pin-mapping comment at the top of the file).
// Tracking rising/falling edge timestamps lets the relay test measure coil
// pulse width and the mute test measure the mute window.
#define CTL_PB2 0
#define CTL_PB3 1
#define N_CTL   2
static int               g_ctl_level[N_CTL]      = {0, 0}; // current PB2/PB3 level
static uint32_t          g_ctl_changes[N_CTL]    = {0, 0}; // transition counts
static avr_cycle_count_t g_ctl_rise_cycle[N_CTL] = {0, 0}; // cycle of last 0->1
static avr_cycle_count_t g_ctl_fall_cycle[N_CTL] = {0, 0}; // cycle of last 1->0
// cycle timestamp of the most recent PB1 (LED) transition; used by the latency
// test to measure press->toggle time against the real firmware.
static avr_cycle_count_t g_last_led_change_cycle = 0;

// Resolved SRAM addresses of firmware globals (looked up from the ELF symbol
// table in sim_reset()). 0 == not found. Used by the fault-injection tests to
// corrupt firmware RAM and exercise the main-loop sanity-check path.
static uint32_t    g_addr_program_state = 0;
static uint32_t    g_addr_effect_state  = 0;
static uint32_t    g_addr_timer_isr     = 0;
static uint32_t    g_addr_debounce      = 0;
// Base of the debounce_context_t struct, if the firmware stores its runtime
// state as a single file-scope context object (`ctx`) instead of three separate
// globals. The per-field addresses above are then derived from this base.
static uint32_t    g_addr_ctx           = 0;
static uint32_t    g_addr_ctx_check     = 0;
static uint32_t    g_addr_ctx_check_fn  = 0;
static uint32_t    g_addr_debounce_step_fn = 0;
// First SRAM byte ABOVE the static data (.data + .bss), from the linker's
// __bss_end / _end. This is the ceiling the stack must not reach, and it is the
// reference point for the stack high-water-mark margin. Taken from the ELF
// rather than computed from the globals above so that a future static grows the
// floor automatically instead of silently loosening the gate.
static uint32_t    g_addr_bss_end       = 0;

// --- test bookkeeping ------------------------------------------------------
// (unused in the TRACE build, which only generates a VCD waveform)
static int g_failures __attribute__((unused)) = 0;
static int g_checks   __attribute__((unused)) = 0;

#define CHECK(cond, ...) do {                                  \
    g_checks++;                                                \
    if (!(cond)) {                                             \
        g_failures++;                                          \
        fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__);   \
        fprintf(stderr, __VA_ARGS__);                          \
        fprintf(stderr, "\n");                                 \
    }                                                          \
} while (0)

// Called by simavr whenever PB1 (LED) changes level.
static void led_hook(struct avr_irq_t *irq, uint32_t value, void *param) {
    (void)irq; (void)param;
    int v = value ? 1 : 0;
    if (v != g_led_level) {
        g_led_changes++;
        if (g_avr) { g_last_led_change_cycle = g_avr->cycle; }
    }
    g_led_level = v;
}

// Called by simavr whenever a watched control pin (PB2/PB3) changes level.
// `param` carries the control index (CTL_PB2 / CTL_PB3).
static void ctl_hook(struct avr_irq_t *irq, uint32_t value, void *param) {
    (void)irq;
    int idx = (int)(intptr_t)param;
    int v = value ? 1 : 0;
    if (v != g_ctl_level[idx]) {
        g_ctl_changes[idx]++;
        if (g_avr) {
            if (v) { g_ctl_rise_cycle[idx] = g_avr->cycle; }
            else   { g_ctl_fall_cycle[idx] = g_avr->cycle; }
        }
    }
    g_ctl_level[idx] = v;
}

// (unused in the TRACE build, which drives a fixed scenario)
static uint32_t xorshift32(uint32_t *state) __attribute__((unused));
static uint32_t xorshift32(uint32_t *state) {
    uint32_t x = *state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *state = x;
    return x;
}

// The external switch level the harness intends (1 = high/released, 0 =
// low/pressed).
static int g_footsw_intended = 1;

// Drive the footswitch as a PERSISTENT external pull on PB0 via simavr's
// SET_EXTERNAL ioctl (the ioport's external.pull_mask/pull_value). This models a
// real footswitch -- a switch to ground: closed, it drives the pin low and beats
// the MCU's weak internal pull-up. Unlike a one-shot avr_raise_irq (which a later
// firmware PORTB write re-asserting the pull-up overrides -- the failure the
// relay shell's per-tick coil re-assert exposed), the external pull is resolved
// on every read and survives PORT writes. pressed != 0 => drive LOW.
static void footsw_set(int pressed) {
    g_footsw_intended = pressed ? 0 : 1;
    // Persistent external pull: survives firmware PORTB writes; but SET_EXTERNAL
    // alone lands on the NEXT port sync, a one-tick input latency the lock-step
    // model catches. So also raise the pin IRQ now for a zero-latency edge; the
    // external pull then holds that level across subsequent PORT writes.
    avr_ioport_external_t ext = {
        .name  = 'B',
        .mask  = (uint8_t)(1U << FOOTSW_PIN),
        .value = (uint8_t)((unsigned)g_footsw_intended << FOOTSW_PIN),
    };
    avr_ioctl(g_avr, AVR_IOCTL_IOPORT_SET_EXTERNAL('B'), &ext);
    avr_raise_irq(avr_io_getirq(g_avr, AVR_IOCTL_IOPORT_GETIRQ('B'), FOOTSW_PIN),
                  (uint32_t)g_footsw_intended);
}

// Run the simulation for `ms` milliseconds of simulated time.
// Tracks whether the CPU ever enters sleep (cpu_Sleeping) or crashes/
// watchdog-resets (cpu_Crashed) during the interval.
static void run_ms(unsigned ms) {
    // cycles per ms = F_CPU / 1000
    avr_cycle_count_t target = g_avr->cycle + (F_CPU_HZ / 1000UL) * (avr_cycle_count_t)ms;
    while (g_avr->cycle < target) {
        int st = avr_run(g_avr);
        if (st == cpu_Sleeping)  { g_saw_sleep = 1; }
        if (st == cpu_Crashed)   { g_saw_crash = 1; }
        if (st == cpu_Done || st == cpu_Crashed) {
            // Either state is terminal for avr_run(), so stop rather than spin.
            // Note a watchdog reset produces NEITHER: simavr resets the core in
            // place and keeps running (see reset_hook / g_resets).
            break;
        }
    }
}

static inline void footsw_drive(int pressed, unsigned ms) {
    footsw_set(pressed);
    run_ms(ms);
}

// Run for an exact number of AVR clock cycles rather than whole milliseconds.
// Used to place footswitch edges at arbitrary phase offsets within the 1ms
// Timer0 tick period (CYCLES_PER_MS = F_CPU_HZ/1000 cycles per tick).
static void run_cycles(avr_cycle_count_t cycles) __attribute__((unused));
static void run_cycles(avr_cycle_count_t cycles) {
    avr_cycle_count_t target = g_avr->cycle + cycles;
    while (g_avr->cycle < target) {
        int st = avr_run(g_avr);
        if (st == cpu_Sleeping) { g_saw_sleep = 1; }
        if (st == cpu_Crashed)  { g_saw_crash = 1; }
        if (st == cpu_Done || st == cpu_Crashed) { break; }
    }
}

// Stop before executing the instruction at `pc`. Used by the F2 transaction
// test to inject after debounce_ctx_check_word() has received its healthy
// by-value argument but before the shell resumes and consumes persisted SRAM.
static int run_until_pc(uint32_t pc, avr_cycle_count_t cycle_budget)
    __attribute__((unused));
static int run_until_pc(uint32_t pc, avr_cycle_count_t cycle_budget) {
    avr_cycle_count_t const deadline = g_avr->cycle + cycle_budget;
    while (g_avr->cycle < deadline) {
        if (g_avr->pc == pc) return 0;
        int const st = avr_run(g_avr);
        if (st == cpu_Sleeping) { g_saw_sleep = 1; }
        if (st == cpu_Crashed)  { g_saw_crash = 1; return -1; }
        if (st == cpu_Done) return -1;
    }
    return (g_avr->pc == pc) ? 0 : -1;
}

// Run until the CPU first enters IDLE sleep (which only happens in the main
// loop AFTER init() completes and the state machine has nothing to do), or
// until `cycle_budget` cycles elapse. Returns the cycle count at which sleep
// was first observed, or 0 if it never slept within the budget.
//
// This is the cleanest "init() finished and the main loop is live" signal:
// init() runs with interrupts disabled and never sleeps, so the first
// cpu_Sleeping marks the transition into steady-state operation.
static avr_cycle_count_t run_until_first_sleep(avr_cycle_count_t cycle_budget)
    __attribute__((unused));
static avr_cycle_count_t run_until_first_sleep(avr_cycle_count_t cycle_budget) {
    avr_cycle_count_t start  = g_avr->cycle;
    avr_cycle_count_t target = start + cycle_budget;
    while (g_avr->cycle < target) {
        int st = avr_run(g_avr);
        if (st == cpu_Sleeping) {
            g_saw_sleep = 1;
            return g_avr->cycle;
        }
        if (st == cpu_Crashed) { g_saw_crash = 1; return 0; }
        if (st == cpu_Done)    { return 0; }
    }
    return 0;
}

// (Re)load firmware and reset sim to a clean power-on state with the
// footswitch in the given initial position.
//
// `settle` controls whether we advance 5ms so init() finishes and the first
// ticks land before returning. Most tests want that (sim_reset()). The init()
// timing test wants the sim positioned EXACTLY at reset so it can measure how
// long init() takes, so it calls sim_reset_raw(..., 0).
static int sim_reset_raw(int footsw_pressed_at_power_on, int settle) {
    static elf_firmware_t fw; // persistent: avr keeps pointers into it
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

    // Resolve firmware-global SRAM addresses from the ELF symbol table so the
    // fault-injection tests can poke them without hardcoding addresses. Symbol
    // addresses for the data space carry the 0x800000 marker; mask to the raw
    // SRAM index used by g_avr->data[].
    g_addr_program_state = g_addr_effect_state = 0;
    g_addr_timer_isr = g_addr_debounce = g_addr_ctx = 0;
    g_addr_ctx_check = g_addr_ctx_check_fn = 0;
    g_addr_debounce_step_fn = 0;
    g_addr_bss_end = 0;
#if defined(ELF_SYMBOLS) && ELF_SYMBOLS
    uint32_t addr_end_fallback = 0;
    for (uint32_t i = 0; i < fw.symbolcount; ++i) {
        const char *name = fw.symbol[i]->symbol;
        uint32_t    a    = fw.symbol[i]->addr & 0xFFFFu;
        if      (strcmp(name, "program_state_")    == 0) g_addr_program_state = a;
        else if (strcmp(name, "effect_state_")     == 0) g_addr_effect_state  = a;
        else if (strcmp(name, "timer_isr_called_") == 0) g_addr_timer_isr     = a;
        else if (strcmp(name, "debounce_counter_") == 0) g_addr_debounce      = a;
        else if (strcmp(name, "ctx")               == 0) g_addr_ctx           = a;
        else if (strcmp(name, "ctx_")              == 0) g_addr_ctx           = a;
        else if (strcmp(name, "ctx_check_")        == 0) g_addr_ctx_check     = a;
        else if (strcmp(name, "debounce_ctx_check_word") == 0)
            g_addr_ctx_check_fn = a;
        else if (strcmp(name, "debounce_step")           == 0)
            g_addr_debounce_step_fn = a;
        // Top of the static data. avr-libc's linker script emits both; prefer
        // __bss_end and keep _end only as a fallback, since _end also moves with
        // the (unused here) heap base on parts that have one.
        else if (strcmp(name, "__bss_end")         == 0) g_addr_bss_end       = a;
        else if (strcmp(name, "_end")              == 0) addr_end_fallback    = a;
    }
    if (g_addr_bss_end == 0) g_addr_bss_end = addr_end_fallback;
    // If the firmware keeps its debounce state in one file-scope context struct
    // (debounce_context_t ctx) rather than three separate globals, derive the
    // per-field addresses from the struct base. The firmware builds with
    // -fshort-enums and static_asserts sizeof()==1 for both enum members, so the
    // members are tightly packed in declaration order (see bypass_types.h):
    //   program_state @+0, effect_state @+1, debounce_counter @+2.
    if (g_addr_ctx != 0) {
        if (g_addr_program_state == 0) g_addr_program_state = g_addr_ctx + 0u;
        if (g_addr_effect_state  == 0) g_addr_effect_state  = g_addr_ctx + 1u;
        if (g_addr_debounce      == 0) g_addr_debounce      = g_addr_ctx + 2u;
    }
#endif

    // Witness every subsequent device reset. Installed after avr_init()/
    // avr_load_firmware() so the power-on reset they perform is not counted.
    g_mcu_reset  = g_avr->reset;
    g_avr->reset = reset_hook;

    // reset instrumentation
    g_led_level = 0;
    g_led_changes = 0;
    g_saw_sleep = 0;
    g_saw_crash = 0;
    g_resets = 0;
    g_last_led_change_cycle = 0;
    for (int i = 0; i < N_CTL; ++i) {
        g_ctl_level[i] = 0;
        g_ctl_changes[i] = 0;
        g_ctl_rise_cycle[i] = 0;
        g_ctl_fall_cycle[i] = 0;
    }

    // Register output watchers: LED on PB1, control outputs on PB2 and PB3.
    // PB2/PB3 are watched regardless of variant (for CD4053_SIMPLE, PB3 is an
    // unused output parked low and simply never transitions).
    avr_irq_register_notify(
        avr_io_getirq(g_avr, AVR_IOCTL_IOPORT_GETIRQ('B'), LED_PIN),
        led_hook, NULL);
    avr_irq_register_notify(
        avr_io_getirq(g_avr, AVR_IOCTL_IOPORT_GETIRQ('B'), PB2),
        ctl_hook, (void *)(intptr_t)CTL_PB2);
    avr_irq_register_notify(
        avr_io_getirq(g_avr, AVR_IOCTL_IOPORT_GETIRQ('B'), PB3),
        ctl_hook, (void *)(intptr_t)CTL_PB3);
    // The footswitch is driven as a persistent external pull (see footsw_set),
    // so it survives firmware PORTB writes -- no per-write re-drive needed.

    // Establish the footswitch level BEFORE the firmware samples it in init().
    footsw_set(footsw_pressed_at_power_on);

    // Let init() run and settle (clock, timer, first ticks) unless the caller
    // wants the sim left exactly at reset (init() timing measurement). On the
    // relay/mute variants init() performs one blocking coil/mute pulse before
    // enabling the timer, so SETTLE_MS includes that (see its definition).
    if (settle) { run_ms(SETTLE_MS); }
    return 0;
}

// Convenience wrapper: reset + 5ms settle (the behavior every existing test
// relies on).
static int sim_reset(int footsw_pressed_at_power_on) {
    return sim_reset_raw(footsw_pressed_at_power_on, 1);
}

//////////////////////////////////////////////////////////////////////////////
// Tests against the REAL firmware
//////////////////////////////////////////////////////////////////////////////
#ifndef TRACE

// Power-on default: BYPASS -> LED dark (PB1 low). All variants also park both
// control lines (PB2/PB3) low at the bypass steady state (CD4053 low; relay
// coils de-energized; mute CTL1/CTL2 low). Variant-specific control behavior
// during switching is checked by the per-variant control tests.
static void test_power_on_default(void) {
    if (sim_reset(0) != 0) { g_failures++; return; }
    CHECK(g_avr->data[DDRB_MEM_ADDR] == (uint8_t)DDRB_EXPECTED,
          "power-on DDRB should be exact 0x%02x, got 0x%02x",
          (unsigned)DDRB_EXPECTED,
          (unsigned)g_avr->data[DDRB_MEM_ADDR]);
    CHECK(g_led_level == 0, "power-on LED should be dark, got %d", g_led_level);
#if defined(TQ2_L2_5V_RELAY)
    CHECK(g_ctl_level[CTL_PB2] == 0 && g_ctl_level[CTL_PB3] == 0,
          "power-on relay coils should be parked low, got PB2=%d PB3=%d",
          g_ctl_level[CTL_PB2], g_ctl_level[CTL_PB3]);
#elif defined(CD4053_WITH_MUTE)
    // Both control lines are LOW at the BYPASS steady-state level.
    CHECK(g_ctl_level[CTL_PB2] == X4053_CTL_FOR_STATE(0) &&
          g_ctl_level[CTL_PB3] == X4053_CTL_FOR_STATE(0),
          "power-on mute control lines wrong, got PB2=%d PB3=%d expected=%d",
          g_ctl_level[CTL_PB2], g_ctl_level[CTL_PB3], X4053_CTL_FOR_STATE(0));
#else // CD4053_SIMPLE
    // PB2 is LOW at the BYPASS control level; PB3 is unused and LOW.
    CHECK(g_ctl_level[CTL_PB2] == X4053_CTL_FOR_STATE(0) && g_ctl_level[CTL_PB3] == 0,
          "power-on CD4053 control wrong, got PB2=%d PB3=%d (expected PB2=%d PB3=0)",
          g_ctl_level[CTL_PB2], g_ctl_level[CTL_PB3], X4053_CTL_FOR_STATE(0));
#endif
}

// One clean press engages: LED lit, exactly one LED transition. (The control
// output is verified per-variant; here we only assert the universal LED.)
static void test_single_press_engages(void) {
    if (sim_reset(0) != 0) { g_failures++; return; }
    uint32_t before = g_led_changes;
    footsw_set(1); run_ms(50);   // press & hold past threshold
    footsw_set(0); run_ms(50);   // release
    CHECK(g_led_level == 1, "after press LED should be lit, got %d", g_led_level);
    CHECK((g_led_changes - before) == 1,
          "exactly one LED transition, got %u", g_led_changes - before);
}

// Two presses return to BYPASS.
static void test_two_presses_round_trip(void) {
    if (sim_reset(0) != 0) { g_failures++; return; }
    footsw_set(1); run_ms(50); footsw_set(0); run_ms(50); // press 1
    CHECK(g_led_level == 1, "press1 -> lit");
    footsw_set(1); run_ms(50); footsw_set(0); run_ms(50); // press 2
    CHECK(g_led_level == 0, "press2 -> dark");
}

// Holding for seconds does not repeat-toggle.
static void test_long_hold_single_toggle(void) {
    if (sim_reset(0) != 0) { g_failures++; return; }
    uint32_t before = g_led_changes;
    footsw_set(1); run_ms(3000); // hold 3s
    CHECK((g_led_changes - before) == 1,
          "3s hold = single LED change, got %u", g_led_changes - before);
    CHECK(g_led_level == 1, "still engaged during hold");
    footsw_set(0); run_ms(50);
}

// Sub-threshold spike rejected (< PRESSED_THRESH ms ~ 8ms). Use 3ms.
static void test_short_spike_rejected(void) {
    if (sim_reset(0) != 0) { g_failures++; return; }
    uint32_t before = g_led_changes;
    footsw_set(1); run_ms(3);     // brief spike
    footsw_set(0); run_ms(50);
    CHECK((g_led_changes - before) == 0,
          "short spike must not toggle, LED changes=%u", g_led_changes - before);
    CHECK(g_led_level == 0, "remain dark after spike");
}

// Power-on with footswitch held: stays BYPASS, no toggle while held; first
// real press only counts after release.
static void test_power_on_pressed(void) {
    if (sim_reset(1) != 0) { g_failures++; return; }
    CHECK(g_led_level == 0, "power-on-pressed stays dark");
    uint32_t before = g_led_changes;
    run_ms(500);                  // keep holding
    CHECK((g_led_changes - before) == 0,
          "no toggle while held at power-on, changes=%u", g_led_changes - before);
    footsw_set(0); run_ms(50);    // release
    footsw_set(1); run_ms(50);    // first real press
    CHECK(g_led_level == 1, "first real press engages after power-on hold");
    footsw_set(0); run_ms(50);
}

// Fast repeated taps each register.
static void test_fast_repeated_taps(void) {
    if (sim_reset(0) != 0) { g_failures++; return; }
    uint32_t before = g_led_changes;
    int taps = 4;
    for (int i = 0; i < taps; ++i) {
        footsw_drive(1, 20);
        footsw_drive(0, 40);
    }
    CHECK((g_led_changes - before) == (uint32_t)taps,
          "%d taps -> %d LED changes, got %u", taps, taps, g_led_changes - before);
    CHECK(g_led_level == 0, "even taps -> back to dark");
}

// Random noise fuzz: 60s of random chatter should not spam toggles.
//
// This drives PB0 with a fixed-seed 50%-duty random stream. 50% duty is the
// integrator's worst case: the saturating counter random-walks around its
// midpoint and occasionally crosses PRESSED_THRESH, so a *handful* of toggles
// is expected and correct -- but the count must stay far below the physical
// ceiling.
//
// Bounds (for the default 60s / seed 0xDEADBEEF run):
//   - Hard physical ceiling: a real toggle needs at least
//     (PRESSED_THRESH + RELEASE_THRESH) = 33 ms, so 60000/33 ~= 1818 is the
//     absolute maximum any correct implementation could ever produce.
//   - Empirically, the real firmware (and the golden model, byte-for-byte)
//     produce EXACTLY SIM_NOISE_EXPECTED_TOGGLES for this seed/duration. We
//     assert that exact value as a tight regression lock, and also re-check
//     the physical ceiling as a defense-in-depth invariant.
//
// The old `< 2000` bound was nearly meaningless: it would pass even if the
// firmware toggled on essentially every threshold crossing.
static void test_random_noise_resilience(void) {
    if (sim_reset(0) != 0) { g_failures++; return; }

    uint32_t before = g_led_changes;
    uint32_t rng = 0xDEADBEEF;

    for (uint32_t t = 0; t < SIM_RANDOM_NOISE_DURATION_MS; ++t) {
        int pressed = (xorshift32(&rng) & 0xFF) < 128;
        footsw_drive(pressed, 1);
    }

    uint32_t toggles = g_led_changes - before;

    // Physical ceiling: at most one toggle per (PRESSED_THRESH+RELEASE_THRESH)
    // milliseconds, regardless of input. This invariant scales with duration
    // and seed, so it stays valid under -D overrides.
    uint32_t physical_max =
        SIM_RANDOM_NOISE_DURATION_MS / (PRESSED_THRESH + RELEASE_THRESH) + 1u;
    CHECK(toggles <= physical_max,
          "random noise exceeded physical toggle ceiling: %u > %u",
          toggles, physical_max);

    // Tight regression lock for the fixed seed + duration. SIM_NOISE_EXPECTED_
    // TOGGLES == 0 means "duration not a known calibration point, skip".
    if (SIM_NOISE_EXPECTED_TOGGLES != 0u) {
        CHECK(toggles == SIM_NOISE_EXPECTED_TOGGLES,
              "random noise toggle count drifted: got %u, expected %u "
              "(firmware/algorithm change? re-measure and update)",
              toggles, (unsigned)SIM_NOISE_EXPECTED_TOGGLES);
    }
}

// Adversarial thresholds: oscillate just below and just above PRESSED_THRESH.
static void test_adversarial_patterns(void) {
    if (sim_reset(0) != 0) { g_failures++; return; }

    uint32_t before = g_led_changes;
    for (int cycle = 0; cycle < SIM_ADVERSARIAL_CYCLES; ++cycle) {
        footsw_drive(1, PRESSED_THRESH - 1);
        footsw_drive(0, PRESSED_THRESH);
    }
    CHECK((g_led_changes - before) == 0,
          "sub-threshold oscillation should not toggle, got %u",
          g_led_changes - before);

    before = g_led_changes;
    for (int cycle = 0; cycle < SIM_ADVERSARIAL_CYCLES; ++cycle) {
        footsw_drive(1, PRESSED_THRESH + 1);
        footsw_drive(0, RELEASE_THRESH + 5);
    }
    CHECK((g_led_changes - before) == (uint32_t)SIM_ADVERSARIAL_CYCLES,
          "just-past-threshold presses should toggle %u times, got %u",
          (uint32_t)SIM_ADVERSARIAL_CYCLES, g_led_changes - before);
    CHECK(g_led_level == 0,
          "after even toggles LED should be dark, got %d", g_led_level);
}

// Extreme bounce: random chatter before each press should still yield one toggle.
static void test_extreme_bounce(void) {
    if (sim_reset(0) != 0) { g_failures++; return; }

    uint32_t before = g_led_changes;

    for (int press = 0; press < SIM_EXTREME_BOUNCE_PRESSES; ++press) {
        uint32_t rng = 0x12345678u + (uint32_t)press;
        for (int i = 0; i < SIM_EXTREME_BOUNCE_CHATTER_MS; ++i) {
            int pressed = xorshift32(&rng) & 1;
            footsw_drive(pressed, 1);
        }
        footsw_drive(1, 20);
        footsw_drive(0, 40);
    }

    CHECK((g_led_changes - before) == (uint32_t)SIM_EXTREME_BOUNCE_PRESSES,
          "extreme bounce should yield %u toggles, got %u",
          (uint32_t)SIM_EXTREME_BOUNCE_PRESSES, g_led_changes - before);
}

// Sustained 1kHz chatter should never reach the threshold.
static void test_sustained_noise(void) {
    if (sim_reset(0) != 0) { g_failures++; return; }

    uint32_t before = g_led_changes;
    for (uint32_t t = 0; t < SIM_SUSTAINED_NOISE_DURATION_MS; ++t) {
        int pressed = (t & 1) ? 1 : 0;
        footsw_drive(pressed, 1);
    }

    CHECK((g_led_changes - before) == 0,
          "sustained 1ms square wave should not toggle, got %u",
          g_led_changes - before);
    CHECK(g_led_level == 0, "square wave should leave LED dark, got %d", g_led_level);
}


//////////////////////////////////////////////////////////////////////////////
// Timing verification against the REAL firmware
//////////////////////////////////////////////////////////////////////////////

// Cycles per simulated millisecond at the configured CPU frequency.
#define CYCLES_PER_MS (F_CPU_HZ / 1000UL)

// (#2) init() / power-on timing: init() runs with interrupts disabled and never
// sleeps, so the first cpu_Sleeping marks "init() finished and main loop is
// idle". Measure how long that takes from reset and assert it completes WELL
// within the WDT window (~250ms nominal, but as low as ~100ms with the WDT's
// loose oscillator). The firmware header claims "100s of microseconds"; we
// require a generous <50ms ceiling so a future init() bloat that risks a
// WDT-reset loop fails here instead of bricking a board.
static void test_init_completes_before_wdt(void) {
    if (sim_reset_raw(0, 0) != 0) { g_failures++; return; }

    avr_cycle_count_t start = g_avr->cycle;
    // Give it up to 100ms of budget; we EXPECT it far sooner.
    avr_cycle_count_t slept_at =
        run_until_first_sleep((avr_cycle_count_t)(100UL * CYCLES_PER_MS));

    CHECK(slept_at != 0,
          "init() never reached idle sleep within 100ms (init() too long / hung?)");
    if (slept_at == 0) return;

    double init_ms = (double)(slept_at - start) / (double)CYCLES_PER_MS;
    printf("  init()->first-idle: %.3f ms (must be << WDT ~100-250ms)\n", init_ms);
    // The first sleep happens after init() AND one main-loop pass; the first
    // tick may need up to ~1ms. Require comfortably under the worst-case WDT.
    CHECK(init_ms < 50.0,
          "init() to first idle took %.3f ms; too close to WDT window", init_ms);
}

// (#WDT) WDT re-arm window: after a watchdog reset the AVR runs with the WDT's
// SHORTEST (~16ms, prescaler 0) timeout until software reconfigures it, and with
// the WDT oscillator's loose tolerance that window can be as short as ~7ms.
// init()'s first actions are wdt_reset() then wdt_enable(WDTO_250MS) (see
// hw_wdt_arm() in bypass_mcu_avr_classic.c, called at the top of init() before
// any blocking output pulse), so the re-arm
// MUST land comfortably inside that window or a fault that survives reset could
// re-trigger the WDT before init() widens the timeout -- a tight boot-loop.
//
// We measure the cycles from reset to the WDTCR write that selects the 250ms
// prescaler.  At reset the prescaler nibble (WDP3:0) is 0 (~16ms);
// wdt_enable(WDTO_250MS) sets it to 0b0100 (WDP2 only).  Masking with 0x27
// isolates WDP3|WDP2|WDP1|WDP0 so the detection is independent of WDE/WDCE/WDIE,
// which may already be set at reset (the design uses the WDTON always-on fuse).
static void test_wdt_rearm_window(void) {
    if (sim_reset_raw(0, 0) != 0) { g_failures++; return; } // sit exactly at reset

    avr_cycle_count_t start  = g_avr->cycle;
    avr_cycle_count_t target = start + (avr_cycle_count_t)(50UL * CYCLES_PER_MS);
    avr_cycle_count_t armed_at = 0;

    while (g_avr->cycle < target) {
        int st = avr_run(g_avr);
        if (st == cpu_Crashed) { g_saw_crash = 1; break; }
        if (st == cpu_Done)    { break; }
        // WDP3:0 == 0b0100 == the WDTO_250MS prescaler selection.
        if ((g_avr->data[WDTCSR_MEM_ADDR] & 0x27u) == 0x04u) {
            armed_at = g_avr->cycle;
            break;
        }
    }

    CHECK(armed_at != 0,
          "WDT re-arm: wdt_enable(WDTO_250MS) write never observed within 50ms");
    if (armed_at == 0) return;

    double rearm_ms = (double)(armed_at - start) / (double)CYCLES_PER_MS;
    printf("  WDT re-arm: %.4f ms reset -> wdt_enable(250ms) "
           "(post-reset window can be as low as ~7ms)\n", rearm_ms);
    // A few dozen instructions at 1.2MHz is well under 0.1ms; require < 1ms with
    // generous margin so any future init() bloat that pushes the re-arm toward
    // the ~7ms window fails here instead of risking a boot-loop on silicon.
    CHECK(rearm_ms < 1.0,
          "WDT re-arm took %.4f ms from reset; too close to the ~7ms post-reset "
          "window (wdt_enable must stay at the very top of init())", rearm_ms);
}

// (#2) Power-on sampling order: the footswitch level present at reset must be
// the one init() acts on. If held at power-on, the firmware enters
// RELEASE_DEBOUNCE_WAIT and must NOT toggle when later released (verified
// functionally elsewhere); here we assert the converse race direction -- a
// switch that is RELEASED at power-on must leave the device immediately ready
// so that a press arriving very soon after boot is honored.
static void test_power_on_sampling_race(void) {
    // Released at power-on, then press almost immediately after init settles.
    if (sim_reset(0) != 0) { g_failures++; return; }
    CHECK(g_led_level == 0, "released-at-power-on must boot dark");
    uint32_t before = g_led_changes;
    footsw_set(1); run_ms(50);
    CHECK((g_led_changes - before) == 1,
          "press right after boot should engage exactly once, got %u",
          g_led_changes - before);
    footsw_set(0); run_ms(50);
}

// (#2) Tick period: measure the real Timer0 ISR period by timing two
// consecutive LED-relevant events. We do this indirectly: drive a clean press
// and measure press->toggle latency, which is exactly PRESSED_THRESH ticks; the
// implied tick period must be ~1ms (the whole debounce-timing contract).
//
// (#6) Latency assertion on the REAL ELF: a clean press must toggle the LED in
// PRESSED_THRESH ticks, and the wall-clock latency must satisfy the <10ms
// design goal under nominal clock.
static void test_clean_press_latency(void) {
    if (sim_reset(0) != 0) { g_failures++; return; }

    uint32_t before = g_led_changes;
    footsw_set(1);                       // press
    avr_cycle_count_t press_cycle = g_avr->cycle;
    run_ms(50);                          // hold past threshold
    CHECK((g_led_changes - before) == 1, "clean press should toggle once");
    CHECK(g_led_level == 1, "clean press should engage (LED lit)");

    double latency_ms =
        (double)(g_last_led_change_cycle - press_cycle) / (double)CYCLES_PER_MS;
    printf("  clean-press latency (real ELF): %.3f ms "
           "(PRESSED_THRESH=%d ticks)\n", latency_ms, PRESSED_THRESH);

    // Implied tick period from the measured latency.
    double tick_ms = latency_ms / (double)PRESSED_THRESH;

    // The tick must be ~1ms (allow the +/-10% RC tolerance plus a little
    // measurement slack for when within the tick the press was sampled).
    CHECK(tick_ms >= 0.8 && tick_ms <= 1.25,
          "implied tick period %.4f ms is outside the ~1ms contract", tick_ms);

    // The headline latency goal: <10ms under nominal clock.
    CHECK(latency_ms <= 10.0,
          "clean-press latency %.3f ms exceeds the 10ms design goal", latency_ms);

    footsw_set(0); run_ms(50);
}

// (#6) Odd/even toggle PARITY invariant across a long random stream against the
// REAL firmware: the LED level must always equal (toggle_count is odd). i.e.
// engaged iff an odd number of state changes have occurred. This catches any
// firmware path that could change the LED without going through the single
// toggle point (e.g. a stray PORTB write, a missed inversion, a glitch).
static void test_toggle_parity_invariant(void) {
    if (sim_reset(0) != 0) { g_failures++; return; }

    uint32_t rng = 0x5A17C0DEu;
    uint32_t base = g_led_changes; // should be 0 at boot, but be robust

    // Drive a long, moderately-correlated random stream so we actually get a
    // healthy mix of real toggles (not just noise). Hold each level for a few
    // ms so presses can cross PRESSED_THRESH.
    const unsigned iters = SIM_PARITY_ITERS;
    for (unsigned i = 0; i < iters; ++i) {
        int pressed = (xorshift32(&rng) & 0xFF) < 96; // ~37% pressed
        unsigned hold = 1u + (xorshift32(&rng) % 12u);
        footsw_drive(pressed, hold);

        uint32_t toggles = g_led_changes - base;
        int expect_lit = (int)(toggles & 1u); // odd toggles => engaged/lit
        CHECK(g_led_level == expect_lit,
              "parity broken at i=%u: toggles=%u led=%d expected=%d",
              i, toggles, g_led_level, expect_lit);
#if defined(CD4053_SIMPLE) || (!defined(CD4053_WITH_MUTE) && !defined(TQ2_L2_5V_RELAY))
        // CD4053 simple: the control output (PB2) tracks the effect state and
        // therefore the LED. The mute/relay variants drive PB2/PB3 differently
        // (pulses), so this mirror invariant is simple-only.
        CHECK(g_ctl_level[CTL_PB2] == X4053_CTL_FOR_STATE(g_led_level),
              "CD4053 (PB2=%d) diverged from LED (PB1=%d) at i=%u",
              g_ctl_level[CTL_PB2], g_led_level, i);
#endif
    }
}


//////////////////////////////////////////////////////////////////////////////
// Lock-step co-simulation: AVR-image state vs host-compiled shipping core, EVERY
// tick.
//
// The output-only tests above prove the LED/CD4053 *transitions* match
// expectations. This test goes deeper: it drives the SAME input stream into the
// compiled AVR firmware in simavr and a host-side step() adapter, then compares
// the firmware's internal RAM (debounce_counter_, program_state_, effect_state_)
// after every 1ms tick. step() reproduces the shell's pin conversion, operation
// order and result application, but delegates the transitions themselves to
// debounce_integrate() and debounce_step() in the same shipping bypass_pure.c
// used by the AVR image. This lane therefore checks target compilation and shell
// integration against a host build of the core; it is not an independent
// transition oracle, and a semantic defect in bypass_pure.c can agree on both
// sides.
//
// test_symbolic.c and the principal state-graph checks in test_model_check.c call
// that same adapter and core. The model checker separately uses handwritten
// substeps for its nondeterministic-scheduling proof. The broad independent
// re-implementation is test/host/test_logic_host.c: model_tick_isr() and
// model_main_step() are handwritten against only the shared thresholds, and do
// not feed this lock-step comparison. ls_model_init() below independently spells
// the released-at-power-on stable state used by this lane; its pressed branch is
// not exercised here.
//////////////////////////////////////////////////////////////////////////////

enum { LS_PRESS_WAIT = 0, LS_RELEASE_WAIT = 1 };
enum { LS_BYPASS = 0, LS_ENGAGED = 1 };

typedef struct {
    uint8_t program_state;
    uint8_t effect_state;
    uint8_t debounce_counter;
} ls_model_t;

static void ls_model_init(ls_model_t *m, int pressed_at_power_on) {
    m->effect_state = LS_BYPASS;
    if (pressed_at_power_on) {
        m->program_state    = LS_RELEASE_WAIT;
        m->debounce_counter = RELEASE_THRESH;
    } else {
        m->program_state    = LS_PRESS_WAIT;
        m->debounce_counter = 0;
    }
}

// One 1ms tick: ISR saturating integrator, then one main-loop state-machine
// pass. pin_low != 0 means PB0 reads low == switch pressed.
//
// Delegates to step() from model_step.h, the host adapter around the shipping
// bypass_pure.c core also used by test_model_check.c and test_symbolic.c. LS_*
// enum values are numerically identical to the model_step.h values (both are
// 0/1), so the conversion between ls_model_t and state_t is lossless.
static void ls_model_step(ls_model_t *m, int pin_low) {
    state_t s = { m->program_state, m->effect_state, m->debounce_counter };
    step_result_t r = step(s, pin_low);
    m->program_state    = r.next.program_state;
    m->effect_state     = r.next.effect_state;
    m->debounce_counter = r.next.debounce_counter;
}

// Advance the firmware by EXACTLY one 1ms Timer0 tick and leave it settled:
// wait for the compare-match ISR to wake the core, then run until it returns to
// IDLE sleep (main has fully reacted to this tick -- including the extra,
// non-sleeping main-loop pass on a toggle or re-arm). This is a phase- and
// drift-free tick boundary: the firmware disables pin-change interrupts, so
// changing PB0 never wakes the core -- only the timer does -- and the input set
// before this call is the one this single tick integrates.
//
// `pin_low` is the footswitch level to hold for this tick. We re-assert it on
// every avr_run() step (not just once) to work around a simavr modeling quirk:
// when the firmware does a read-modify-write of PORTB (to drive the LED or a
// control pin), simavr re-evaluates the IRQ-driven INPUT pin PB0 back to its
// pull-up level, dropping the externally-driven "pressed" (low) state. On real
// hardware, writing PB1/PB2/PB3 cannot disturb the PB0 switch input, so the
// switch stays pressed. This matters on the relay/mute variants, where the
// toggle's set_*_state() blocks in _delay_ms() and several more timer ISRs
// sample PB0 AFTER those PORTB writes -- without re-asserting, simavr would feed
// the integrator spurious "released" samples that real hardware never sees.
// Re-driving each step keeps the simulated switch faithfully held.
//
// Returns 0 on success, -1 if the expected wake/sleep cycle did not occur
// within a safety budget (a crash or a stuck core -- itself a failure).
static int run_one_tick_settled(int pin_low) {
    // Safety ceiling for one wake->process->sleep cycle. On a toggle tick the
    // relay/mute variants block in _delay_ms() inside set_*_state() before the
    // main loop sleeps again, so the budget must exceed that pulse. 5ms base +
    // 2x the variant delay leaves generous margin while still catching a truly
    // stuck core.
    const avr_cycle_count_t budget =
        (avr_cycle_count_t)((5UL + 2UL * CTL_DELAY_MS) * (F_CPU_HZ / 1000UL));
    avr_cycle_count_t start = g_avr->cycle;

    // 1. Wait for the core to WAKE (timer ISR fired). While idle, avr_run
    //    returns cpu_Sleeping and fast-forwards to the next timer event.
    for (;;) {
        footsw_set(pin_low);
        int st = avr_run(g_avr);
        if (st == cpu_Crashed) { g_saw_crash = 1; return -1; }
        if (st == cpu_Done) return -1;
        if (st != cpu_Sleeping) break;
        if (g_avr->cycle - start > budget) return -1;
    }
    // 2. Wait until it SLEEPS again (main finished processing this tick).
    for (;;) {
        footsw_set(pin_low);
        int st = avr_run(g_avr);
        if (st == cpu_Crashed) { g_saw_crash = 1; return -1; }
        if (st == cpu_Done) return -1;
        if (st == cpu_Sleeping) { g_saw_sleep = 1; break; }
        if (g_avr->cycle - start > budget) return -1;
    }
    return 0;
}

// Minimum-threshold press: exactly PRESSED_THRESH ticks must toggle.
//
// The firmware uses >=, not >, so a counter of exactly PRESSED_THRESH is
// sufficient to fire. This test drives PRESSED_THRESH ticks via
// run_one_tick_settled() (tick-accurate, immune to phase jitter) and asserts
// that the toggle occurs. A >= -> > mutant requires PRESSED_THRESH+1 ticks
// and does NOT toggle here, making it the independent killer for that mutation.
//
// The lock-step co-sim cannot catch this mutation because its host transition
// oracle calls debounce_step() from bypass_pure.c through step() -- both the
// firmware binary and the oracle receive the same mutated code and continue to
// agree tick-for-tick. This test has an independent hard-coded expectation that
// breaks the symmetry.
static void test_minimum_press_toggles(void) {
    if (sim_reset(0) != 0) { g_failures++; return; }

    uint32_t before = g_led_changes;

    for (unsigned t = 0; t < (unsigned)PRESSED_THRESH; ++t) {
        if (run_one_tick_settled(1) != 0) {
            CHECK(0, "min-press: tick %u failed (crash or stuck core)", t);
            return;
        }
    }

    CHECK((g_led_changes - before) == 1,
          "PRESSED_THRESH=%u ticks must toggle (>= check, not >), got %u changes",
          (unsigned)PRESSED_THRESH, g_led_changes - before);
    CHECK(g_led_level == 1,
          "LED should be lit after PRESSED_THRESH=%u ticks pressed",
          (unsigned)PRESSED_THRESH);

    footsw_drive(0, 50);
}

static void test_lockstep_cosim(void) {
    if (sim_reset(0) != 0) { g_failures++; return; }

    CHECK(g_addr_debounce != 0 && g_addr_program_state != 0 && g_addr_effect_state != 0,
          "lock-step: could not resolve firmware global addresses (need ELF symbols)");
    if (!g_addr_debounce || !g_addr_program_state || !g_addr_effect_state) return;

    ls_model_t m;
    ls_model_init(&m, 0); // released at power-on, matching sim_reset(0)

    // Establish the sleeping precondition and verify the anchor: after the 5ms
    // settle with the switch released, firmware and model must already agree.
    run_until_first_sleep((avr_cycle_count_t)(10UL * (F_CPU_HZ / 1000UL)));
    CHECK(g_avr->data[g_addr_program_state] == m.program_state &&
          g_avr->data[g_addr_effect_state]  == m.effect_state  &&
          g_avr->data[g_addr_debounce]      == m.debounce_counter,
          "lock-step anchor mismatch: fw(ps=%u es=%u dc=%u) model(ps=%u es=%u dc=%u)",
          g_avr->data[g_addr_program_state], g_avr->data[g_addr_effect_state],
          g_avr->data[g_addr_debounce], m.program_state, m.effect_state, m.debounce_counter);

    // Anchor: control-output steady state at power-on BYPASS. The SETTLE_MS
    // settle guarantees init()'s blocking output call has completed.
#if defined(TQ2_L2_5V_RELAY)
    CHECK(g_ctl_level[CTL_PB2] == 0 && g_ctl_level[CTL_PB3] == 0,
          "lock-step anchor: relay coils not parked at init (PB2=%d PB3=%d)",
          g_ctl_level[CTL_PB2], g_ctl_level[CTL_PB3]);
#elif defined(CD4053_WITH_MUTE)
    CHECK(g_ctl_level[CTL_PB2] == X4053_CTL_FOR_STATE(0) &&
          g_ctl_level[CTL_PB3] == X4053_CTL_FOR_STATE(0),
          "lock-step anchor: mute not in BYPASS steady state at init (PB2=%d PB3=%d expected=%d)",
          g_ctl_level[CTL_PB2], g_ctl_level[CTL_PB3], X4053_CTL_FOR_STATE(0));
#endif

    uint32_t rng = 0xC051A1EDu;
    unsigned ticks = 0;
    unsigned mismatches = 0;
    unsigned toggles = 0; // sanity: confirm the stream actually exercises toggles

    // Outer loop picks a level and a hold duration; holds long enough to cross
    // PRESSED_THRESH (toggle) and RELEASE_THRESH (full re-arm), so every code
    // path -- press, lock-out, release, re-arm -- is exercised in lock-step.
    while (ticks < SIM_LOCKSTEP_ITERS && mismatches < 5) {
        int pin_low = ((xorshift32(&rng) & 0xFF) < 128); // ~50% pressed
        unsigned hold = 1u + (xorshift32(&rng) % 30u);   // up to 30 ticks
        for (unsigned h = 0; h < hold && ticks < SIM_LOCKSTEP_ITERS; ++h, ++ticks) {
            uint8_t es_before = m.effect_state;

            // pressed => drive LOW; run_one_tick_settled re-asserts it on every
            // step (see its comment) so the relay/mute toggle delay doesn't feed
            // the integrator spurious samples via simavr's input-pin quirk.
            if (run_one_tick_settled(pin_low) != 0) {
                CHECK(0, "lock-step: firmware failed to complete tick %u "
                         "(crash or stuck core)", ticks);
                return;
            }
            ls_model_step(&m, pin_low);
            if (m.effect_state != es_before) { toggles++; }

            uint8_t fw_ps = g_avr->data[g_addr_program_state];
            uint8_t fw_es = g_avr->data[g_addr_effect_state];
            uint8_t fw_dc = g_avr->data[g_addr_debounce];

            int ok = (fw_ps == m.program_state)
                  && (fw_es == m.effect_state)
                  && (fw_dc == m.debounce_counter);
            CHECK(ok,
                  "lock-step divergence at tick %u (in=%d): "
                  "fw(ps=%u es=%u dc=%u) != model(ps=%u es=%u dc=%u)",
                  ticks, pin_low, fw_ps, fw_es, fw_dc,
                  m.program_state, m.effect_state, m.debounce_counter);
            if (!ok) { mismatches++; }

            // The LED must track the model's effect state exactly in every
            // variant (LED lit == ENGAGED).
            CHECK(g_led_level == (int)m.effect_state,
                  "lock-step: LED (PB1=%d) disagrees with model effect_state=%u at tick %u",
                  g_led_level, m.effect_state, ticks);
#if defined(CD4053_SIMPLE) || (!defined(CD4053_WITH_MUTE) && !defined(TQ2_L2_5V_RELAY))
            // CD4053 simple only: PB2 tracks effect state exactly.
            CHECK(g_ctl_level[CTL_PB2] == X4053_CTL_FOR_STATE(m.effect_state),
                  "lock-step: CD4053 (PB2=%d) disagrees with model effect_state=%u at tick %u",
                  g_ctl_level[CTL_PB2], m.effect_state, ticks);
#elif defined(TQ2_L2_5V_RELAY)
            // Relay: both coils must be parked low after every settled tick.
            // run_one_tick_settled() waits for the CPU to re-enter sleep, which
            // only occurs after the blocking coil pulse and set_relay_coils_low()
            // have both completed.
            CHECK(g_ctl_level[CTL_PB2] == 0 && g_ctl_level[CTL_PB3] == 0,
                  "lock-step relay: coils not parked at tick %u (PB2=%d PB3=%d)",
                  ticks, g_ctl_level[CTL_PB2], g_ctl_level[CTL_PB3]);
#elif defined(CD4053_WITH_MUTE)
            // Mute: both control lines equal the effect state in steady state:
            // LOW for BYPASS and HIGH for ENGAGED.
            // ls_model_step() has already updated m.effect_state to the
            // post-tick value, so this compares against the same state the
            // firmware just settled into.
            {
                int expected_ctl = X4053_CTL_FOR_STATE(m.effect_state);
                CHECK(g_ctl_level[CTL_PB2] == expected_ctl &&
                      g_ctl_level[CTL_PB3] == expected_ctl,
                      "lock-step mute: control lines wrong at tick %u "
                      "(PB2=%d PB3=%d expected=%d)",
                      ticks, g_ctl_level[CTL_PB2], g_ctl_level[CTL_PB3], expected_ctl);
            }
#endif
        }
    }

    CHECK(toggles >= 5,
          "lock-step: stream exercised only %u toggles (expected >=5); "
          "input not stimulating the toggle path", toggles);
    printf("  lock-step: %u ticks compared, %u toggles, %u mismatches\n",
           ticks, toggles, mismatches);
}

// Multi-seed lock-step: test_lockstep_cosim runs ONE fixed seed; this drives
// several more random seeds through the REAL firmware vs. the host shipping-core
// adapter and asserts byte-for-byte agreement on every tick, so the fixed-seed
// co-sim lock cannot hide a seed-dependent divergence between the compiled
// firmware and host execution. Kept short per seed -- simavr is slow -- because
// the wide, long-duration sweep is covered far more cheaply by the independent
// golden-model Monte Carlo (test_monte_carlo_seeds in test_logic_host.c). Tunable
// via -D.
#ifndef MC_SIM_SEED_COUNT
#define MC_SIM_SEED_COUNT 5u
#endif
#ifndef MC_SIM_SEED_TICKS
#define MC_SIM_SEED_TICKS 1000u
#endif
static void test_monte_carlo_lockstep(void) {
    for (uint32_t s = 0; s < MC_SIM_SEED_COUNT; ++s) {
        if (sim_reset(0) != 0) { g_failures++; return; }
        if (!g_addr_debounce || !g_addr_program_state || !g_addr_effect_state) {
            CHECK(0, "mc-lockstep: could not resolve firmware globals "
                     "(need ELF symbols)");
            return;
        }

        ls_model_t m;
        ls_model_init(&m, 0); // released at power-on, matching sim_reset(0)
        run_until_first_sleep((avr_cycle_count_t)(10UL * CYCLES_PER_MS));

        // Distinct, well-spread seed per iteration (never 0: xorshift32 sticks
        // at 0).  0x9E3779B9 is the golden-ratio odd constant used elsewhere.
        uint32_t rng = 0x9E3779B9u * (s + 1u);
        if (rng == 0u) { rng = 0xA5A5A5A5u; }

        unsigned ticks = 0, mismatches = 0;
        while (ticks < MC_SIM_SEED_TICKS && mismatches < 3) {
            int pin_low      = ((xorshift32(&rng) & 0xFF) < 128); // ~50% pressed
            unsigned hold    = 1u + (xorshift32(&rng) % 30u);     // up to 30 ticks
            for (unsigned h = 0; h < hold && ticks < MC_SIM_SEED_TICKS;
                 ++h, ++ticks) {
                if (run_one_tick_settled(pin_low) != 0) {
                    CHECK(0, "mc-lockstep seed %u: firmware tick %u failed "
                             "(crash or stuck core)", s, ticks);
                    return;
                }
                ls_model_step(&m, pin_low);

                uint8_t fw_ps = g_avr->data[g_addr_program_state];
                uint8_t fw_es = g_avr->data[g_addr_effect_state];
                uint8_t fw_dc = g_avr->data[g_addr_debounce];
                int ok = (fw_ps == m.program_state)
                      && (fw_es == m.effect_state)
                      && (fw_dc == m.debounce_counter)
                      && (g_led_level == (int)m.effect_state);
                CHECK(ok,
                      "mc-lockstep seed %u divergence at tick %u (in=%d): "
                      "fw(ps=%u es=%u dc=%u led=%d) != model(ps=%u es=%u dc=%u)",
                      s, ticks, pin_low, fw_ps, fw_es, fw_dc, g_led_level,
                      m.program_state, m.effect_state, m.debounce_counter);
                if (!ok) { mismatches++; }
            }
        }
    }
    printf("  mc-lockstep: %u seeds x %u ticks, AVR image vs host shipping core\n",
           (unsigned)MC_SIM_SEED_COUNT, (unsigned)MC_SIM_SEED_TICKS);
}


//////////////////////////////////////////////////////////////////////////////
// Sleep + watchdog behavior
//////////////////////////////////////////////////////////////////////////////

// The firmware should sleep (SLEEP_MODE_IDLE) between 1ms ticks while idle.
// simavr reports cpu_Sleeping when the core executes SLEEP and is idle.
static void test_enters_idle_sleep(void) {
    if (sim_reset(0) != 0) { g_failures++; return; }
    g_saw_sleep = 0;
    footsw_set(0);      // released/idle
    run_ms(50);         // let it idle across many ticks
    CHECK(g_saw_sleep == 1, "firmware should enter IDLE sleep while waiting");
}

// Watchdog must NOT fire during normal operation: the timer ISR pets the dog
// every tick. Run a long idle period and confirm no crash/reset.
//
// g_resets is the load-bearing assertion here: a watchdog timeout resets the
// core in place and never sets cpu_Crashed (see reset_hook), so a check written
// only against g_saw_crash cannot observe the very fault this test names. The
// crash flag is still asserted, as an independent anomaly.
static void test_watchdog_not_tripped_normally(void) {
    if (sim_reset(0) != 0) { g_failures++; return; }
    g_saw_crash = 0;
    g_resets = 0;
    footsw_set(0);
    run_ms(1000);       // 1s, well beyond the 250ms WDT window
    CHECK(g_resets == 0, "watchdog must not reset during normal idle operation");
    CHECK(g_saw_crash == 0, "CPU must not crash during normal idle operation");
    // and the device should still respond afterwards
    uint32_t before = g_led_changes;
    footsw_set(1); run_ms(50); footsw_set(0); run_ms(50);
    CHECK((g_led_changes - before) == 1, "still responsive after long idle");
}

// Watchdog pet-to-pet BUDGET, measured on the real image.
//
// The firmware asserts a conservative compile-time inequality: the worst-case
// WALL-CLOCK interval between two `wdr`s -- blocking actuation, the ISR
// preemption that stretches it, one tick of scheduling latency and one pass of
// bounded loop work -- stays under the de-rated watchdog floor
// (WDT_PET_TO_PET_MAX_MS() in src/bypass_output_common.h). That inequality is
// arithmetic over per-target constants a human derived. Nothing in it observes
// the compiled firmware, so a shell whose ISR or loop grew past its declared
// allowance would keep asserting a bound it no longer meets.
//
// So measure it. Step the real image and record the longest interval between
// consecutive executions of a `wdr`, across boot (whose first interval spans
// init()'s blocking bypass actuation) and across toggles in both directions.
// The result must fit the SAME budget the firmware compiled against -- not
// merely fit under the watchdog floor, which a badly derived constant would
// also do.
//
// This CORROBORATES the compile-time guard; it does not replace it. One
// simulated run over one stimulus cannot enumerate every path, which is exactly
// why the conservative inequality is the primary artifact.
#define MAX_PET_SITES 8
static uint32_t g_pet_site[MAX_PET_SITES];
static int      g_pet_sites;

// `wdr` is a single 16-bit opcode with no operands, so its encoding is a
// constant and the pet sites can be recovered from flash without debug info.
// (avr-libc's wdt_reset() and the shell's hw_wdt_pet() both compile to it.)
#define AVR_OPCODE_WDR 0x95a8U
static void find_pet_sites(void) {
    g_pet_sites = 0;
    for (uint32_t a = 0; (a + 1U) <= g_avr->flashend; a += 2U) {
        uint16_t op = (uint16_t)((uint16_t)g_avr->flash[a] |
                                 ((uint16_t)g_avr->flash[a + 1U] << 8));
        if (op != AVR_OPCODE_WDR) { continue; }
        if (g_pet_sites < MAX_PET_SITES) { g_pet_site[g_pet_sites] = a; }
        g_pet_sites++;
    }
}

static int is_pet_site(uint32_t pc) {
    for (int i = 0; i < g_pet_sites && i < MAX_PET_SITES; ++i) {
        if (g_pet_site[i] == pc) { return 1; }
    }
    return 0;
}

static void test_wdt_pet_interval_within_budget(void) {
    if (sim_reset_raw(0, 0) != 0) { g_failures++; return; }
    g_saw_crash = 0;
    g_resets = 0;
    footsw_set(0);

    find_pet_sites();
    // Three: wdt_reset() and wdt_enable()'s own pet in init(), plus the one
    // main() reaches per serviced tick. Pinned so a fourth (or a vanished
    // third) is reported here rather than silently changing what is measured.
    CHECK(g_pet_sites == 3,
          "pet-budget: expected 3 wdr sites in the image, found %d", g_pet_sites);
    if (g_pet_sites != 3) { return; }

    avr_cycle_count_t const stop = g_avr->cycle +
        (avr_cycle_count_t)(1200UL * CYCLES_PER_MS);
    // Two full round trips: each press toggles, and a toggle is what makes the
    // loop perform its blocking actuation -- the longest interval there is.
    avr_cycle_count_t next_edge = g_avr->cycle +
        (avr_cycle_count_t)(200UL * CYCLES_PER_MS);
    int pressed = 0;
    int pets = 0;
    avr_cycle_count_t prev = 0;
    avr_cycle_count_t worst = 0;

    while (g_avr->cycle < stop) {
        if (g_avr->cycle >= next_edge) {
            pressed = !pressed;
            footsw_set(pressed);
            next_edge += (avr_cycle_count_t)(200UL * CYCLES_PER_MS);
        }
        if (is_pet_site(g_avr->pc)) {
            if (pets > 0) {
                avr_cycle_count_t const gap = g_avr->cycle - prev;
                if (gap > worst) { worst = gap; }
            }
            prev = g_avr->cycle;
            pets++;
        }
        int const st = avr_run(g_avr);
        if (st == cpu_Crashed) { g_saw_crash = 1; break; }
        if (st == cpu_Done) { break; }
    }

    CHECK(g_saw_crash == 0, "pet-budget: CPU must not crash while being measured");
    CHECK(g_resets == 0, "pet-budget: no reset may occur, or a gap would span one");
    // Well over a thousand ticks in 1200 ms; a run that petted a handful of
    // times measured nothing and must not pass on a small `worst`.
    CHECK(pets > 1000, "pet-budget: only %d pets observed, too few to bound anything", pets);
    // Toggles must actually have happened, or the blocking actuation -- the
    // longest interval, and the whole point -- was never exercised.
    CHECK(g_led_changes >= 2,
          "pet-budget: %u LED transitions, so no toggle blocked the loop",
          (unsigned)g_led_changes);

    double const worst_ms = (double)worst / (double)CYCLES_PER_MS;
    unsigned long const budget_ms =
        (unsigned long)WDT_PET_TO_PET_MAX_MS((unsigned)CTL_DELAY_MS);
    CHECK(worst_ms <= (double)budget_ms,
          "pet-budget: worst measured pet-to-pet %.3f ms exceeds the compile-time "
          "budget of %lu ms the firmware asserted", worst_ms, budget_ms);
    CHECK(worst_ms < (double)WDT_MIN_PERIOD_MS,
          "pet-budget: worst measured pet-to-pet %.3f ms reaches the de-rated "
          "WDT floor of %u ms", worst_ms, (unsigned)WDT_MIN_PERIOD_MS);
    printf("  [pet-budget] worst measured pet-to-pet %.3f ms; compile-time budget "
           "%lu ms; de-rated WDT floor %u ms\n",
           worst_ms, budget_ms, (unsigned)WDT_MIN_PERIOD_MS);
}

#ifdef TARGET_TINYX5
// Watchdog BACKSTOP: verify WDT system reset on the tinyx5 family (simavr
// models the ATtiny25/45/85 watchdog reset).
//
// If the timer ISR stops running, the main loop never pets the dog, and the
// WDT (~250ms) performs a SYSTEM RESET.  The firmware must reinitialize in
// BYPASS and be fully responsive.
static void test_watchdog_backstop_reset(void) {
    if (sim_reset(0) != 0) { g_failures++; return; }

    // Verify normal operation first
    CHECK(g_led_level == 0, "WDT test: power-on LED dark");
    footsw_set(1); run_ms(50); footsw_set(0); run_ms(50);
    CHECK(g_led_level == 1, "WDT test: press engages");
    uint32_t changes_before = g_led_changes;

    // Kill the timer interrupt: no more ticks -> main loop never pets the dog.
    avr_core_watch_write(g_avr, TIMSK_MEM_ADDR, 0x00);

    // Wait well past WDT timeout (250ms) for the system reset to fire.
    run_ms(600);

    // After WDT reset, firmware should reinit in BYPASS (LED dark, CD4053 low).
    // The fact that LED returned to dark proves the MCU was reset and init()
    // ran again correctly.
    CHECK(g_led_level == 0,
          "WDT test: after reset LED should be dark (reinit to BYPASS)");

    // Post-reset responsiveness is a hardware verification item: simavr resets
    // PINB to 0x00 on WDT reset, which puts the footswitch model in an
    // inconsistent state with respect to the external IRQ drive level.  The
    // firmware's power-on-pressed path handles this gracefully (LED stays
    // dark), but subsequent pin transitions in the sim do not match hardware
    // behavior.
    (void)changes_before;
}

// (#3) Watchdog timeout BOUND: not only must the WDT eventually reset after the
// ISR dies, it must do so within the part's WDT window. The AVR WDT oscillator
// is loose (~100-350ms for a nominal 250ms setting), so we assert the reset
// lands inside a generous [50ms, 500ms] envelope -- catching both a WDT that
// never fires AND one mis-configured to an absurdly long timeout.
static void test_watchdog_timeout_within_bound(void) {
    if (sim_reset(0) != 0) { g_failures++; return; }

    // Engage so the LED is LIT; the post-reset reinit to BYPASS (LED dark) is
    // our reset timestamp.
    footsw_set(1); run_ms(50); footsw_set(0); run_ms(50);
    CHECK(g_led_level == 1, "WDT-bound: press engages before we break the ISR");
    if (g_led_level != 1) return;

    // Kill the timer ISR; record the moment.
    avr_core_watch_write(g_avr, TIMSK_MEM_ADDR, 0x00);
    avr_cycle_count_t kill_cycle = g_avr->cycle;

    // Run up to 500ms, stopping as soon as the LED goes dark (reset reinit).
    avr_cycle_count_t deadline =
        kill_cycle + (avr_cycle_count_t)(500UL * CYCLES_PER_MS);
    avr_cycle_count_t reset_cycle = 0;
    while (g_avr->cycle < deadline) {
        int st = avr_run(g_avr);
        if (st == cpu_Crashed) { g_saw_crash = 1; }
        if (g_led_level == 0) { reset_cycle = g_avr->cycle; break; }
        if (st == cpu_Done) break;
    }

    CHECK(reset_cycle != 0,
          "WDT-bound: device did not reset to BYPASS within 500ms of ISR death");
    if (reset_cycle == 0) return;

    double wdt_ms = (double)(reset_cycle - kill_cycle) / (double)CYCLES_PER_MS;
    printf("  WDT reset fired %.1f ms after ISR death "
           "(nominal 250ms, RC tolerance ~100-350ms)\n", wdt_ms);
    CHECK(wdt_ms >= 50.0 && wdt_ms <= 500.0,
          "WDT reset latency %.1f ms outside expected [50,500] ms envelope",
          wdt_ms);
}
#else
// Watchdog BACKSTOP (documented simavr limitation for ATtiny13).
//
// On real hardware, if the timer ISR stops running the main loop never pets
// the dog and the WDT (~250ms) performs a SYSTEM RESET.
//
// However, simavr 1.6's ATtiny13 model does NOT emulate the watchdog system
// reset: the WDT timer expires but the core is not reset (it just keeps
// sleeping/waking). simavr only reports cpu_Crashed for a CPU stuck asleep
// with interrupts globally disabled -- not for a watchdog timeout.
//
// What we CAN assert here is the weaker property that the firmware does not
// lock the CPU in a way that even simavr would flag. The real backstop check
// must be validated on hardware (e.g. scope PB1/PB2 and confirm the device
// resets to BYPASS ~250ms after the ISR is artificially stopped).
static void test_watchdog_backstop_documented(void) {
    if (sim_reset(0) != 0) { g_failures++; return; }
    g_saw_crash = 0;
    footsw_set(0);
    run_ms(20);                       // confirm running normally first
    CHECK(g_saw_crash == 0, "should be healthy before we break the ISR");

    // Kill the timer interrupt: no more ticks -> main loop never pets the dog.
    avr_core_watch_write(g_avr, TIMSK_MEM_ADDR, 0x00);
    run_ms(600);

    // We do NOT assert a reset here (simavr can't model it). We only document
    // that the firmware keeps the global interrupt path alive (does not wedge
    // the CPU into simavr's crash detector). Hardware validates the true reset.
    CHECK(g_saw_crash == 0,
          "simavr cannot model WDT reset; verify backstop on hardware (see comment)");
}
#endif

// Register corruption recovery: corrupt DDRB/PORTB to trigger the firmware's
// sanity-check force_wdt_reset() path.
//
// On the tinyx5 family, simavr models WDT reset, so the firmware recovers and
// reinitializes in BYPASS.  On the ATtiny13a, the WDT is not fully modeled, so
// the weaker property (CPU enters stuck state without wedging simavr) is checked.
static void test_register_corruption_recovery(void) {
    if (sim_reset(0) != 0) { g_failures++; return; }

    footsw_set(1); run_ms(50); footsw_set(0); run_ms(50);
    CHECK(g_led_level == 1, "corruption test: normal press engages");

    // Corrupt DDRB: clear the LED output bit, making PB1 an input.
    // This violates the main-loop sanity check.
    avr_core_watch_write(g_avr, DDRB_MEM_ADDR,
                         g_avr->data[DDRB_MEM_ADDR] & ~(1 << LED_PIN));

#ifdef TARGET_TINYX5
    // tinyx5: WDT reset is emulated.  Firmware recovers via reset.
    // The LED returning to dark proves the MCU reset and init() ran.
    run_ms(500);
    CHECK(g_led_level == 0,
          "corruption test: WDT reset recovered, LED dark (reinit BYPASS)");
    // Post-reset responsiveness for the corruption path has the same
    // PINB-reset-to-0x00 limitation documented in the WDT backstop test.
#else
    // ATtiny13: simavr does not emulate WDT reset.  After corruption, the
    // firmware hits the sanity check, calls force_wdt_reset() (cli + busy
    // loop).  Verify the CPU enters the stuck state without wedging simavr.
    g_saw_sleep = 0;
    run_ms(200);
    CHECK(g_saw_sleep == 0,
          "corruption test: ATtiny13 in stuck force_wdt_reset loop "
          "(no sleep with cli active)");
#endif
}

//////////////////////////////////////////////////////////////////////////////
// Fault injection: corrupt each variable checked by the main-loop sanity
// guard and confirm the firmware detects it and takes the force_wdt_reset()
// path. These exercise the sanity-check branches that the existing
// DDRB-corruption test does not reach:
//
//   firmware main() guard (bypass_mcu_avr_classic.c):
//     program_state_ > RELEASE_DEBOUNCE_WAIT   -> invalid program state
//     effect_state_  > ENGAGED                 -> invalid effect state
//     timer_isr_called_ > TIMER_ISR_NOT_CALLED -> invalid handshake flag
//     footswitch pullup bit cleared in PORTB   -> lost input pullup
//   plus the switch() default: (program_state_ out of enum range).
//
// On the tinyx5 family simavr models the WDT system reset, so we assert full
// recovery to BYPASS. On the ATtiny13a the WDT reset is not modeled, so we
// assert the weaker property that the firmware wedges into the cli()+busy-loop
// (no further sleep) -- the same approach the register-corruption test uses.

// Shared helper: after injecting a fault, verify the firmware reacts.
//   tinyx5: WDT reset fires -> firmware reinits -> LED dark (BYPASS).
//   t13a  : firmware enters force_wdt_reset() cli/busy loop -> no more sleeps.
static void expect_fault_response(const char *what) {
#ifdef TARGET_TINYX5
    run_ms(500); // > WDT 250ms timeout
    CHECK(g_led_level == 0,
          "fault-inject [%s]: WDT reset recovered, LED dark (reinit BYPASS)",
          what);
#else
    // A fault injected at an arbitrary point in the main loop may land just
    // after the current tick's sanity gate has already run, so the core can
    // complete one more IDLE sleep before the next tick's gate catches it (a
    // <=1ms detection latency). Allow a bounded settle window for the gate to
    // react, then assert the core is PERMANENTLY wedged in the cli()+busy loop
    // (no further sleeps). A genuinely undetected fault keeps sleeping through
    // the 200ms window and still fails.
    run_ms(10);
    g_saw_sleep = 0;
    run_ms(200);
    CHECK(g_saw_sleep == 0,
          "fault-inject [%s]: ATtiny13 stuck in force_wdt_reset loop "
          "(no sleep with cli active)", what);
#endif
}

// Corrupt program_state_ to an out-of-range value (hits both the explicit
// `program_state_ > RELEASE_DEBOUNCE_WAIT` guard and the switch() default).
static void test_fault_inject_program_state(void) {
    if (sim_reset(0) != 0) { g_failures++; return; }
    CHECK(g_addr_program_state != 0,
          "fault-inject: could not resolve program_state_ address");
    if (g_addr_program_state == 0) return;

    footsw_set(1); run_ms(50); footsw_set(0); run_ms(50);
    CHECK(g_led_level == 1, "fault-inject [program_state_]: normal press engages");

    // 0xFF is far outside {PRESS_DEBOUNCE_WAIT, RELEASE_DEBOUNCE_WAIT}.
    avr_core_watch_write(g_avr, g_addr_program_state, 0xFF);
    expect_fault_response("program_state_");
}

// Corrupt effect_state_ to an out-of-range value (> ENGAGED).
static void test_fault_inject_effect_state(void) {
    if (sim_reset(0) != 0) { g_failures++; return; }
    CHECK(g_addr_effect_state != 0,
          "fault-inject: could not resolve effect_state_ address");
    if (g_addr_effect_state == 0) return;

    footsw_set(1); run_ms(50); footsw_set(0); run_ms(50);
    CHECK(g_led_level == 1, "fault-inject [effect_state_]: normal press engages");

    avr_core_watch_write(g_avr, g_addr_effect_state, 0x7F);
    expect_fault_response("effect_state_");
}

// F2 context-SEU (BYPASS_CTX_CHECK): corrupt debounce_counter_ to an IN-RANGE
// value that the main-loop range gate cannot see. 0x10 = 16, with
// PRESSED_THRESH(8) <= 16 <= RELEASE_THRESH(25), so `debounce_counter >
// RELEASE_THRESH` stays false -- the pre-F2 firmware would silently phantom-
// toggle on this. The next ISR snapshots the mismatched persisted pair and skips
// integration; its timer handshake wakes main, whose atomic transaction validates
// the same pair and forces reset. This exercises the retained-fault path (the
// sibling range/SFR cases above are caught by main()'s polled gate).
//
// The poke MUST land while the core is IDLE-asleep right after a serviced tick
// -- run_one_tick_settled(0) leaves it exactly there with the shadow synced --
// so the very next event is the timer ISR, which performs the F2 comparison
// before any legitimate transaction can overwrite it. This remains the
// favorable-phase control beside the post-check transaction test below.
static void test_fault_inject_ctx_debounce_inrange(void) {
    if (sim_reset(0) != 0) { g_failures++; return; }
    CHECK(g_addr_debounce != 0,
          "fault-inject: could not resolve debounce_counter address");
    if (g_addr_debounce == 0) return;

    // Prove normal operation first, then settle released at a tick boundary:
    // debounce_counter == 0, shadow synced, core asleep.
    footsw_set(1); run_ms(50); footsw_set(0); run_ms(50);
    CHECK(g_led_level == 1,
          "fault-inject [ctx.debounce in-range]: normal press engages");
    if (g_led_level != 1) return;

    CHECK(run_one_tick_settled(0) == 0,
          "fault-inject [ctx.debounce in-range]: could not settle at tick boundary");
    CHECK(g_avr->data[g_addr_debounce] == 0,
          "fault-inject [ctx.debounce in-range]: counter not settled to 0 (got %u)",
          (unsigned)g_avr->data[g_addr_debounce]);

    // Single-bit in-range flip (bit 4): 0 -> 0x10.
    avr_core_watch_write(g_avr, g_addr_debounce, 0x10);
    CHECK(g_avr->data[g_addr_debounce] == 0x10,
          "fault-inject [ctx.debounce in-range]: injection did not stick (got 0x%02x)",
          (unsigned)g_avr->data[g_addr_debounce]);

    // A genuine F2 detection forces a WDT reset. Assert the reset DIRECTLY via
    // g_resets rather than through expect_fault_response()'s LED-dark heuristic:
    // an undetected in-range SEU does not merely fail to reset, it phantom-
    // toggles the effect state, and from the ENGAGED setup that toggle darkens
    // the LED -- indistinguishable from a reset's reinit-to-BYPASS. Only the
    // reset counter separates the two. (Mirrors the timer_isr_called_ case.)
    g_resets = 0;
    run_ms(500); // > WDT 250ms timeout
    CHECK(g_resets != 0,
          "fault-inject [ctx.debounce in-range]: F2 shadow did not force a WDT "
          "reset (an undetected in-range SEU phantom-toggles instead)");
    CHECK(g_led_level == 0,
          "fault-inject [ctx.debounce in-range]: reset recovered, LED dark "
          "(reinit BYPASS)");
}

// Inject one in-range counter upset after a healthy by-value argument has been
// captured. The ISR case stops in its successful check-word call; the main case
// stops in debounce_step() after validation and snapshot capture. Both
// transactions must finish from that local snapshot and safely overwrite the
// persisted upset. The old implementation resumed by consuming or folding live
// ctx_, which legitimized the corruption and eventually phantom-toggled.
static void test_fault_inject_ctx_transaction_phase(int main_phase) {
    if (sim_reset(0) != 0) { g_failures++; return; }
    CHECK(g_addr_ctx != 0 && g_addr_ctx_check != 0 &&
               g_addr_ctx_check_fn != 0 && g_addr_debounce_step_fn != 0,
          "fault-inject [ctx transaction]: required symbols were not resolved");
    if (g_addr_ctx == 0 || g_addr_ctx_check == 0 ||
            g_addr_ctx_check_fn == 0 || g_addr_debounce_step_fn == 0) return;

    char const *const phase = main_phase ? "main post-check" : "ISR post-check";
    uint32_t const target = main_phase ? g_addr_debounce_step_fn
                                       : g_addr_ctx_check_fn;

    CHECK(run_one_tick_settled(0) == 0,
          "fault-inject [ctx %s]: could not settle at tick boundary", phase);
    CHECK(g_avr->data[g_addr_program_state] == 0U &&
               g_avr->data[g_addr_effect_state] == 0U &&
               g_avr->data[g_addr_debounce] == 0U &&
               g_avr->data[g_addr_ctx_check] == 0xFFU,
          "fault-inject [ctx %s]: initial context/check not canonical", phase);

    uint32_t const led_changes_before = g_led_changes;
    uint32_t const ctl2_changes_before = g_ctl_changes[CTL_PB2];
    uint32_t const ctl3_changes_before = g_ctl_changes[CTL_PB3];
    CHECK(run_until_pc(target,
                        (avr_cycle_count_t)(2UL * CYCLES_PER_MS)) == 0,
          "fault-inject [ctx %s]: transaction seam not reached", phase);
    if (g_avr->pc != target) return;

    // Exactly one persisted single-bit flip after the healthy argument capture.
    avr_core_watch_write(g_avr, g_addr_debounce, 0x10U);
    CHECK(g_avr->data[g_addr_debounce] == 0x10U,
          "fault-inject [ctx %s]: injection did not stick", phase);
    run_ms(20);

    CHECK(g_avr->data[g_addr_program_state] == 0U &&
               g_avr->data[g_addr_effect_state] == 0U &&
               g_avr->data[g_addr_debounce] == 0U &&
               g_avr->data[g_addr_ctx_check] == 0xFFU,
          "fault-inject [ctx %s]: upset changed or was folded into context", phase);
    CHECK(g_led_level == 0 && g_led_changes == led_changes_before,
          "fault-inject [ctx %s]: LED changed before safe overwrite", phase);
    CHECK(g_ctl_changes[CTL_PB2] == ctl2_changes_before &&
               g_ctl_changes[CTL_PB3] == ctl3_changes_before,
          "fault-inject [ctx %s]: control output changed before safe overwrite", phase);
}

static void test_fault_inject_ctx_postcheck_transaction(void) {
    test_fault_inject_ctx_transaction_phase(0);
    test_fault_inject_ctx_transaction_phase(1);
}

// Corrupt timer_isr_called_ to an out-of-range value
// (> TIMER_ISR_NOT_CALLED).
//
// NOTE: the timer ISR rewrites this flag to TIMER_ISR_CALLED every 1ms. Settle
// at IDLE with the flag at NOT_CALLED, single-step until the ISR writes CALLED,
// then replace that value before main() can execute its sanity check. On tinyx5,
// the modeled WDT reset is an unambiguous witness that the guard caught it: the
// reset_hook() count rises, and the LED returns dark from ENGAGED. This
// particular injection remains tinyx5-only because ATtiny13a has no modeled WDT
// reset to provide the same positive witness.
#ifdef TARGET_TINYX5
static void test_fault_inject_timer_isr_flag(void) {
    if (sim_reset(0) != 0) { g_failures++; return; }
    CHECK(g_addr_timer_isr != 0,
          "fault-inject: could not resolve timer_isr_called_ address");
    if (g_addr_timer_isr == 0) return;

    // Begin ENGAGED so a dark LED after the crash is an independent reset witness.
    footsw_set(1); run_ms(50); footsw_set(0); run_ms(50);
    CHECK(g_led_level == 1,
          "fault-inject [timer_isr_called_]: normal press engages");
    if (g_led_level != 1) return;

    CHECK(run_one_tick_settled(0) == 0,
          "fault-inject [timer_isr_called_]: could not settle at tick boundary");
    CHECK(g_avr->data[g_addr_timer_isr] == TIMER_ISR_NOT_CALLED_VALUE,
          "fault-inject [timer_isr_called_]: flag not NOT_CALLED at IDLE");
    if (g_avr->data[g_addr_timer_isr] != TIMER_ISR_NOT_CALLED_VALUE) return;

    int injected = 0;
    avr_cycle_count_t const deadline =
        g_avr->cycle + (avr_cycle_count_t)(2UL * CYCLES_PER_MS);
    while (g_avr->cycle < deadline) {
        int const st = avr_run(g_avr);
        if (st == cpu_Crashed) { g_saw_crash = 1; break; }
        if (st == cpu_Done) break;
        if (g_avr->data[g_addr_timer_isr] == TIMER_ISR_CALLED_VALUE) {
            avr_core_watch_write(g_avr, g_addr_timer_isr, 0x55);
            injected = (g_avr->data[g_addr_timer_isr] == 0x55U);
            break;
        }
    }
    CHECK(injected != 0,
          "fault-inject [timer_isr_called_]: could not inject after ISR write");
    if (injected == 0) return;

    g_resets = 0;
    run_ms(500);
    CHECK(g_resets != 0,
          "fault-inject [timer_isr_called_]: WDT system reset was not observed");
    CHECK(g_led_level == 0,
          "fault-inject [timer_isr_called_]: reset returned LED output dark");
}
#endif

// Clear the footswitch pullup bit in PORTB: the firmware's sanity check
// requires PORTB & (1<<FOOTSW_PIN) to remain set.
static void test_fault_inject_lost_pullup(void) {
    if (sim_reset(0) != 0) { g_failures++; return; }

    footsw_set(1); run_ms(50); footsw_set(0); run_ms(50);
    CHECK(g_led_level == 1, "fault-inject [pullup]: normal press engages");

    avr_core_watch_write(g_avr, PORTB_MEM_ADDR,
                         g_avr->data[PORTB_MEM_ADDR] & (uint8_t)~(1 << FOOTSW_PIN));
    expect_fault_response("PORTB pullup");
}

// Clear a control-output direction bit (PB2) in DDRB (companion to the existing
// LED DDRB test; together they cover both required output-direction bits). PB2
// is a checked output in every variant's is_sanity_check_failed() (CD4053 ctrl /
// CTL1 / RESET coil), so this exercises the variant's control-output guard.
static void test_fault_inject_control_ddr(void) {
    if (sim_reset(0) != 0) { g_failures++; return; }

    footsw_set(1); run_ms(50); footsw_set(0); run_ms(50);
    CHECK(g_led_level == 1, "fault-inject [control DDR]: normal press engages");

    avr_core_watch_write(g_avr, DDRB_MEM_ADDR,
                         g_avr->data[DDRB_MEM_ADDR] & (uint8_t)~(1 << PB2));
    expect_fault_response("control DDR (PB2)");
}

// Set the footswitch direction bit, changing PB0 from a pulled-up input into a
// strong output. All required active-output bits remain set, so this specifically
// distinguishes the exact DDRB invariant from the former output-subset check.
static void test_fault_inject_footswitch_ddr(void) {
    if (sim_reset(0) != 0) { g_failures++; return; }

    footsw_set(1); run_ms(50); footsw_set(0); run_ms(50);
    CHECK(g_led_level == 1,
          "fault-inject [footswitch DDR]: normal press engages");

    avr_core_watch_write(g_avr, DDRB_MEM_ADDR,
                         g_avr->data[DDRB_MEM_ADDR]
                         | (uint8_t)(1U << FOOTSW_PIN));
    expect_fault_response("footswitch DDR (PB0 output)");
}

// PB4 is intentionally configured as a low-driven spare output on every classic
// AVR variant. It is absent from each driver's active-output subset, so losing
// this direction proves the complete initialization mask is enforced.
static void test_fault_inject_spare_ddr(void) {
    if (sim_reset(0) != 0) { g_failures++; return; }

    footsw_set(1); run_ms(50); footsw_set(0); run_ms(50);
    CHECK(g_led_level == 1,
          "fault-inject [spare DDR]: normal press engages");

    avr_core_watch_write(g_avr, DDRB_MEM_ADDR,
                         g_avr->data[DDRB_MEM_ADDR]
                         & (uint8_t)~(1U << PB4));
    expect_fault_response("spare DDR (PB4 input)");
}

// Flip each output-latch bit away from its settled value while preserving the
// complete direction configuration. PB1 starts in BYPASS so a missed fault
// leaves the LED visibly high; PB2..PB4 start ENGAGED so a missed fault leaves
// the LED high. In either case recovery to a dark LED is an independent reset
// witness on tinyx5, while ATtiny13a uses the established no-sleep witness.
static void inject_output_latch_bit(uint8_t const pin, const char *what) {
    if (sim_reset(0) != 0) { g_failures++; return; }

    if (pin == LED_PIN) {
        footsw_set(0); run_ms(20);
        CHECK(g_led_level == 0,
              "fault-inject [%s]: normal BYPASS starts with LED dark", what);
    }
    else {
        footsw_set(1); run_ms(50); footsw_set(0); run_ms(50);
        CHECK(g_led_level == 1,
              "fault-inject [%s]: normal press engages", what);
    }

    uint8_t const bad = (uint8_t)(g_avr->data[PORTB_MEM_ADDR]
                                  ^ (uint8_t)(1U << pin));
    avr_core_watch_write(g_avr, PORTB_MEM_ADDR, bad);
    CHECK(g_avr->data[PORTB_MEM_ADDR] == bad,
          "fault-inject [%s]: PORTB latch corruption did not stick", what);
    expect_fault_response(what);
}

#if defined(TQ2_L2_5V_RELAY)
// Relay coil fail-safe resynchronization (docs/relay_coil_fault_correction.md).
//
// An unexpectedly energized coil is a FAULT: a pulse below the TQ2-L2-5V 4 ms
// minimum is not proven mechanically harmless, so the firmware cannot know
// whether the latching relay moved, and a latching relay that moved without the
// firmware's knowledge leaves the audio route disagreeing with the effect state
// and the LED. The sanity gate escalates it like any other PORTB latch
// mismatch, and hw_force_wdt_reset() de-energizes BOTH coils before it spins.
//
// Two halves, asserted separately -- final-low output alone is not recovery:
//
//   1. DE-ENERGIZATION, which both classic parts can show: after the gate
//      fires, neither coil latch is still driven.
//   2. ELECTRICAL RECOVERY, the recovery's BYPASS command. Only the
//      tinyx5 build can show it: simavr does not model the ATtiny13A watchdog
//      SYSTEM RESET, so on t13a the firmware is (correctly) observed wedged in
//      the cli()+spin loop and the reset that would follow on silicon simply
//      does not happen in the model. That gap is a simulator limitation, stated
//      here and in the docs, not a firmware exclusion.
//
// `engaged` selects the settled state the fault arrives in, so both directions
// of the desynchronization hazard are covered: BYPASS with an unintended SET,
// and ENGAGED with an unintended RESET.
//
// Inject while the core is asleep (bottom of the loop, after this tick's gate)
// so the next wake runs the gate on the injected latch -- the deterministic
// analogue of the PIC harness's advance_to_loop_clrwdt(). This case never
// injects during the blocking relay pulse; that window is excluded by design.
static void inject_coil_resync(uint8_t const pin, int const engaged,
                               const char *what) {
    if (sim_reset(0) != 0) { g_failures++; return; }
    if (engaged) {
        footsw_set(1); run_ms(50); footsw_set(0); run_ms(50);
        CHECK(g_led_level == 1, "coil-resync [%s]: normal press engages", what);
    }
    else {
        footsw_set(0); run_ms(20);
        CHECK(g_led_level == 0, "coil-resync [%s]: settled BYPASS, LED dark", what);
    }

    if (run_until_first_sleep((avr_cycle_count_t)(4UL * CYCLES_PER_MS)) == 0) {
        g_failures++;
        printf("  FAIL: coil-resync [%s]: core never slept before injection\n", what);
        return;
    }

    // Corrupt the PORTB output latch (the coil bit) -- the same fault site the
    // firmware's output-intact gate reads. avr_core_watch_write updates the data
    // latch but does not re-drive the pin IRQ, so assert on the latch, not on the
    // pin-level watcher (g_ctl_level), exactly as inject_output_latch_bit does.
    uint32_t const resets_before = g_resets;
    uint8_t const coil_mask = (uint8_t)((1U << PB2) | (1U << PB3));
    uint8_t const bad = (uint8_t)(g_avr->data[PORTB_MEM_ADDR] | (uint8_t)(1U << pin));
    avr_core_watch_write(g_avr, PORTB_MEM_ADDR, bad);
    CHECK((g_avr->data[PORTB_MEM_ADDR] & (uint8_t)(1U << pin)) != 0,
          "coil-resync [%s]: coil latch injection did not stick", what);

    uint32_t const rst_changes_before = g_ctl_changes[CTL_PB2];
    uint32_t const set_changes_before = g_ctl_changes[CTL_PB3];

    // A fault injected while the core sleeps is seen by the NEXT tick's gate, so
    // allow a bounded settle before judging anything (the same discipline
    // expect_fault_response() uses). Watching g_saw_sleep any earlier would
    // observe the sleep the core was ALREADY in at injection time.
    run_ms(10);

    // Half 1, on BOTH parts: the escalation path drove both coils low before it
    // spun. A mutant that spins with a coil still driven fails here.
    CHECK((g_avr->data[PORTB_MEM_ADDR] & coil_mask) == 0,
          "coil-resync [%s]: both coil latches de-energized on the escalation path"
          " (PORTB=0x%02x)", what, (unsigned)g_avr->data[PORTB_MEM_ADDR]);

#ifdef TARGET_TINYX5
    // Half 2, tinyx5 only: simavr models this part's WDT SYSTEM RESET, so the
    // recovery actually runs and can be measured. init() re-initializes to
    // BYPASS, which means a RESET-coil pulse -- one rise, one fall, at least the
    // datasheet minimum apart -- with the SET coil never driven.
    // THAT is the recovery electrical sequence; the clear in half 1 is not.
    // Mechanical convergence remains conditional on the documented hardware.
    //
    // The injected latch bit never reached the pin (avr_core_watch_write does
    // not re-drive the pin IRQ), so every transition counted below is one the
    // firmware itself drove.
    run_ms(500); // > WDT 250 ms timeout
    CHECK(g_resets > resets_before,
          "coil-resync [%s]: watchdog recovery fired (saw %u resets)",
          what, (unsigned)(g_resets - resets_before));
    CHECK((g_ctl_changes[CTL_PB2] - rst_changes_before) == 2,
          "coil-resync [%s]: recovery drove exactly one RESET-coil pulse"
          " (saw %u edges)", what,
          (unsigned)(g_ctl_changes[CTL_PB2] - rst_changes_before));
    if ((g_ctl_changes[CTL_PB2] - rst_changes_before) == 2) {
        double const pulse_ms =
            (double)(g_ctl_fall_cycle[CTL_PB2] - g_ctl_rise_cycle[CTL_PB2])
            / (double)CYCLES_PER_MS;
        CHECK(pulse_ms >= (double)TQ2_L2_5V_MIN_PULSE_MS,
              "coil-resync [%s]: recovery RESET-coil pulse %.2f ms >= %u ms"
              " datasheet minimum", what, pulse_ms,
              (unsigned)TQ2_L2_5V_MIN_PULSE_MS);
    }
    CHECK((g_ctl_changes[CTL_PB3] - set_changes_before) == 0,
          "coil-resync [%s]: SET coil never driven during recovery (saw %u edges)",
          what, (unsigned)(g_ctl_changes[CTL_PB3] - set_changes_before));
    CHECK(g_led_level == 0,
          "coil-resync [%s]: recovered image settled in BYPASS (LED dark)", what);
    CHECK((g_avr->data[PORTB_MEM_ADDR] & coil_mask) == 0,
          "coil-resync [%s]: recovered image left both coils idle", what);
#else
    // ATtiny13A: simavr has NO watchdog system-reset model for this part, so
    // half 2 simply cannot be observed here -- a simulator limitation, not a
    // firmware exclusion (see docs/relay_coil_fault_correction.md). What this
    // part can prove is that the firmware is PERMANENTLY wedged in the
    // cli()+spin loop, which on silicon is exactly what the watchdog turns into
    // the reset the tinyx5 branch measures, and that the coils stay de-energized
    // for the whole spin.
    (void)resets_before;
    (void)rst_changes_before;
    (void)set_changes_before;
    g_saw_sleep = 0;
    run_ms(200);
    CHECK(g_saw_sleep == 0,
          "coil-resync [%s]: ATtiny13 stuck in force_wdt_reset loop"
          " (no sleep with cli active)", what);
    CHECK((g_avr->data[PORTB_MEM_ADDR] & coil_mask) == 0,
          "coil-resync [%s]: coils stayed de-energized for the whole reset spin",
          what);
#endif
}
#endif

static void test_fault_inject_output_latches(void) {
    // Every PORTB latch bit resets on every variant. On the relay variant the
    // two coil bits additionally have to be de-energized before the reset spin
    // and receive the recovery electrical sequence. The fault is delivered in
    // both settled states so BYPASS+unintended-SET and
    // ENGAGED+unintended-RESET are both covered.
    inject_output_latch_bit(PB1, "PORTB.PB1 LED latch");
#if defined(TQ2_L2_5V_RELAY)
    inject_coil_resync(PB2, 1, "PORTB.PB2 RESET-coil latch, ENGAGED");
    inject_coil_resync(PB3, 1, "PORTB.PB3 SET-coil latch, ENGAGED");
    inject_coil_resync(PB2, 0, "PORTB.PB2 RESET-coil latch, BYPASS");
    inject_coil_resync(PB3, 0, "PORTB.PB3 SET-coil latch, BYPASS");
#else
    inject_output_latch_bit(PB2, "PORTB.PB2 control latch");
    inject_output_latch_bit(PB3, "PORTB.PB3 control latch");
#endif
    inject_output_latch_bit(PB4, "PORTB.PB4 spare latch");
}

//////////////////////////////////////////////////////////////////////////////
// SFR-integrity fault injection: corrupt each critical CONFIG register the
// firmware writes once in init() -- the clock prescaler, the watchdog config,
// and the Timer0 tick config -- and confirm the firmware's per-tick
// SFR-integrity gate detects the mismatch and forces a reset.
//
// These complement the pull-up / DDRB checks above. Those catch a corrupted pin
// DIRECTION or pull-up; these catch a corrupted clock/WDT/timer CONFIG that
// would silently skew the tick rate, the coil/mute pulse widths, or the WDT
// safety margin while the timer ISR keeps firing -- so the ISR-liveness
// handshake alone (which only notices the ISR STOPPING) would not detect it.
// This is the AVR-shell parity of the PIC shell's OSCCON/WDTCON/PR2/T2CON gate.
//
// Each register is written once at init and never touched again, so a single
// poke persists until the next gate pass -- deterministic on both families.
// Every corruption value is chosen to (a) differ from the init value, (b) keep
// the Timer0 compare ISR firing so main() runs the gate again, and (c) preserve
// WDE so hw_force_wdt_reset()'s watchdog still bites on tinyx5.
static void inject_config_sfr(uint32_t addr, uint8_t bad, const char *what) {
    if (sim_reset(0) != 0) { g_failures++; return; }

    footsw_set(1); run_ms(50); footsw_set(0); run_ms(50);
    CHECK(g_led_level == 1, "fault-inject [%s]: normal press engages", what);

    avr_core_watch_write(g_avr, addr, bad);
    expect_fault_response(what);
}

// Clock prescaler (CLKPR): init selects clock_div_8 (0x03); corrupt to div1
// (0x00). The Timer0 clock still runs, so the ISR keeps firing.
static void test_fault_inject_clkpr(void) {
    inject_config_sfr(CLKPR_MEM_ADDR, 0x00, "CLKPR (clock prescaler)");
}

// Watchdog config (WDTCR): init sets WDE + the ~250 ms prescaler; corrupt to
// WDE-only (1<<WDE == 0x08), i.e. all WDP bits cleared -> the ~16 ms minimum.
// WDE stays set so the forced reset still fires (just faster) on tinyx5, and the
// value differs from any 250 ms encoding so the gate trips.
static void test_fault_inject_wdtcr(void) {
    inject_config_sfr(WDTCSR_MEM_ADDR, (uint8_t)(1u << 3), "WDTCR (watchdog config)"); // 1<<WDE
}

// Timer0 mode (TCCR0A): init selects CTC (1<<WGM01); corrupt to 0x00 (normal
// mode). The OCR0A compare-match interrupt still fires in normal mode, so main()
// runs the gate again.
static void test_fault_inject_tccr0a(void) {
    inject_config_sfr(TCCR0A_MEM_ADDR, 0x00, "TCCR0A (timer mode)");
}

// Timer0 clock select (TCCR0B): init selects /8 (1<<CS01 == 0x02); corrupt to
// /64 (CS01|CS00 == 0x03). The timer keeps running (slower), ISR still fires.
static void test_fault_inject_tccr0b(void) {
    inject_config_sfr(TCCR0B_MEM_ADDR, 0x03, "TCCR0B (timer prescaler)");
}

// Timer0 compare (OCR0A): init sets the 1 ms period value; corrupt by flipping
// bit6, which keeps a sane, nonzero period so the ISR still fires at a modest
// rate (device-independent -- no need to know the exact per-family init value).
static void test_fault_inject_ocr0a(void) {
    if (sim_reset(0) != 0) { g_failures++; return; }

    footsw_set(1); run_ms(50); footsw_set(0); run_ms(50);
    CHECK(g_led_level == 1, "fault-inject [OCR0A]: normal press engages");

    uint8_t bad = (uint8_t)(g_avr->data[OCR0A_MEM_ADDR] ^ 0x40u);
    avr_core_watch_write(g_avr, OCR0A_MEM_ADDR, bad);
    expect_fault_response("OCR0A (timer compare)");
}

// Redirect the stack pointer into the ctx_ BSS region and verify the firmware
// detects the resulting corruption.
//
// When SP is set to ctx_+2, the next Timer0 ISR's hardware interrupt dispatch
// pushes the return PC into ctx_.debounce_counter (data[ctx+2]) and
// ctx_.effect_state (data[ctx+1]).  The ISR prologue then saves r0 into
// ctx_.program_state (data[ctx+0]), writing whatever r0 held at interrupt
// time.  Further register saves spill into I/O register address space:
// the fourth push lands on data[0x5F] = the SREG I/O register, which clears
// the global-interrupt-enable (I) bit, disabling future ISRs.  With the ISR
// stopped, the main loop can no longer pet the watchdog, and the WDT fires
// within ~250 ms and resets the MCU to BYPASS.
//
// If the sanity check fires first (program_state or effect_state out of range
// from the PC-byte write), hw_force_wdt_reset() triggers the same outcome.
//
// Gated to tinyx5: simavr models the WDT system reset on that family, giving
// a clean LED-dark recovery signal.  ATtiny13a's WDT is not simulated, and the
// I-bit-clear path (firmware sleeps forever) makes the no-sleep assertion
// unreliable there -- the same limitation as test_fault_inject_timer_isr_flag.
#ifdef TARGET_TINYX5
static void test_fault_inject_stack_pointer(void) {
    if (sim_reset(0) != 0) { g_failures++; return; }
    CHECK(g_addr_ctx != 0,
          "fault-inject-stack: could not resolve ctx_ address (need ELF symbols)");
    if (g_addr_ctx == 0) return;

    footsw_set(1); run_ms(50); footsw_set(0); run_ms(50);
    CHECK(g_led_level == 1, "fault-inject-stack: normal press engages");

    avr_core_watch_write(g_avr, SPL_MEM_ADDR, (uint8_t)(g_addr_ctx + 2u));
    avr_core_watch_write(g_avr, SPH_MEM_ADDR, 0x00u);
    expect_fault_response("stack pointer -> ctx BSS");
}
#endif

// Corrupt a byte in the unused SRAM gap between BSS globals and the active
// stack, and verify the sanity check does NOT fire (negative / defense-in-depth
// test).  The target (ctx_ base + 10) lies past all known globals (ctx_ = 3 B,
// timer_isr_called_ = 1 B, giving 4 B total; +10 clears that with margin) and
// safely below the stack high-water mark (~0x81 on ATtiny13a, measured by
// test_stack_high_water_mark), so the write is never touched by normal
// execution.  The firmware must remain fully responsive after the corruption.
static void test_fault_inject_unused_sram(void) {
    if (sim_reset(0) != 0) { g_failures++; return; }
    CHECK(g_addr_ctx != 0,
          "fault-inject-unused-sram: could not resolve ctx_ address (need ELF symbols)");
    if (g_addr_ctx == 0) return;

    uint32_t unused_addr = g_addr_ctx + 10u;
    avr_core_watch_write(g_avr, unused_addr, 0x42u);

    g_saw_crash = 0;
    g_saw_sleep = 0;
    run_ms(50);

    CHECK(g_saw_crash == 0,
          "fault-inject-unused-sram: unexpected WDT reset "
          "(sanity check false-fired on unused SRAM byte?)");
    CHECK(g_saw_sleep == 1,
          "fault-inject-unused-sram: CPU not sleeping "
          "(stuck in force_wdt_reset loop from false alarm?)");

    uint32_t before = g_led_changes;
    footsw_set(1); run_ms(50); footsw_set(0); run_ms(50);
    CHECK((g_led_changes - before) == 1u,
          "fault-inject-unused-sram: not responsive after unused-SRAM write");
}

// Boot-loop under a PERSISTENT fault.  The firmware is designed so a fault that
// survives a reset (a stuck pin, a corrupted fuse, or an SEU that re-flips the
// same byte on every boot) produces a harmless, BOUNDED boot-loop: reset ->
// re-init to BYPASS -> sanity check fires -> force another reset, forever, never
// drifting into an undefined state.  This test confirms that bounded behavior
// over several rapid cycles by RE-injecting the corruption after each recovery.
//
// Per cycle: corrupt program_state_ to 0xFF (out of enum range -> the main-loop
// sanity check forces a WDT reset), wait past the WDT window, then assert the
// firmware (a) actually reset -- the reinit cleared our 0xFF back into the valid
// [0, RELEASE_DEBOUNCE_WAIT] range; (b) recovered to BYPASS (LED dark); and (c)
// is alive again (re-entered idle sleep) rather than wedged.  We deliberately do
// NOT re-press across resets: post-WDT-reset footswitch responsiveness is a
// documented simavr limitation (PINB is cleared to 0x00 on reset, inconsistent
// with the IRQ-driven level -- see test_watchdog_backstop_reset), so the
// reset-occurred proof is the cleared-corruption check, not a re-toggle.
//
// tinyx5-only: simavr models the WDT system reset there, giving a deterministic
// recovery signal.  On the ATtiny13a the WDT reset is not modeled.
#ifdef TARGET_TINYX5
static void test_boot_loop_persistent_fault(void) {
    if (sim_reset(0) != 0) { g_failures++; return; }
    CHECK(g_addr_program_state != 0,
          "boot-loop: could not resolve program_state_ address");
    if (g_addr_program_state == 0) return;

    const int cycles = 5;
    for (int c = 0; c < cycles; ++c) {
        // Released level for the post-reset reinit (mitigates the PINB quirk).
        footsw_set(0);

        // Inject the persistent fault: an out-of-enum-range program_state_ that
        // re-appears on this boot.  The sanity check catches it -> WDT reset.
        avr_core_watch_write(g_avr, g_addr_program_state, 0xFFu);

        g_saw_sleep = 0;
        run_ms(500); // > WDT 250ms timeout: let the reset fire and init() re-run

        // (a) A reset really happened: reinit overwrote our 0xFF with a valid
        //     in-range program_state_ (PRESS_DEBOUNCE_WAIT, or RELEASE_DEBOUNCE_
        //     WAIT if the PINB quirk made the reinit sample the pin as pressed).
        uint8_t ps = g_avr->data[g_addr_program_state];
        CHECK(ps <= (uint8_t)RELEASE_DEBOUNCE_WAIT,
              "boot-loop cycle %d: program_state_ still corrupt (%u) -- no reset?",
              c, ps);
        // (b) Recovered to BYPASS.
        CHECK(g_led_level == 0,
              "boot-loop cycle %d: did not recover to BYPASS (LED=%d)",
              c, g_led_level);
        // (c) Alive, not wedged: the firmware re-entered steady-state idle sleep.
        CHECK(g_saw_sleep == 1,
              "boot-loop cycle %d: firmware not sleeping after recovery "
              "(wedged instead of bounded boot-loop?)", c);
    }
}
#endif

static void run_fault_injection_suite(void) {
    test_fault_inject_program_state();
    test_fault_inject_effect_state();
    test_fault_inject_ctx_debounce_inrange(); // F2 ISR-path (both families)
    test_fault_inject_ctx_postcheck_transaction(); // F2 post-check window
#ifdef TARGET_TINYX5
    test_fault_inject_timer_isr_flag();
    test_fault_inject_stack_pointer();
    test_boot_loop_persistent_fault();
#endif
    test_fault_inject_lost_pullup();
    test_fault_inject_control_ddr();
    test_fault_inject_footswitch_ddr();
    test_fault_inject_spare_ddr();
    test_fault_inject_output_latches();
    // SFR-integrity gate: clock / watchdog / Timer0 config registers
    test_fault_inject_clkpr();
    test_fault_inject_wdtcr();
    test_fault_inject_tccr0a();
    test_fault_inject_tccr0b();
    test_fault_inject_ocr0a();
    test_fault_inject_unused_sram();
}

// Oscillator drift tolerance: verify the <10ms press-latency goal holds across
// the ±10% RC oscillator tolerance documented in the design spec.
//
// The simavr firmware is cycle-accurate, so drift cannot be modeled by changing
// g_avr->frequency (run_ms uses compile-time F_CPU_HZ and the timer fires on
// cycle counts regardless). Instead we measure cycle latency to first toggle,
// convert to ticks (cycles_per_tick = F_CPU_HZ/1000 is exact for both MCUs),
// then interpret those ticks at the drifted real-world frequency. A +10% clock
// means each tick completes in 1ms/1.1 ≈ 0.909ms of real time; the design goal
// of <10ms must hold for the worst case (-10%: 1 tick = 1.111ms, so
// PRESSED_THRESH=8 ticks × 1.111ms = 8.89ms).
static void test_oscillator_drift_tolerance(void) {
    static const double drift_factors[] = { 0.9, 1.1 };
    // Exact cycles per 1ms tick for both MCUs (f/prescaler/(OCR0A+1) = 1000 Hz).
    const double cycles_per_tick = (double)(F_CPU_HZ / 1000UL);

    for (int f = 0; f < 2; ++f) {
        if (sim_reset(0) != 0) { g_failures++; return; }

        CHECK(g_led_level == 0, "drift %.1fx: power-on BYPASS", drift_factors[f]);

        uint32_t before = g_led_changes;
        footsw_set(1);
        avr_cycle_count_t press_cycle = g_avr->cycle;
        // Hold for 20ms (16+ ticks) -- well past PRESSED_THRESH even at worst drift.
        run_ms(20);

        CHECK((g_led_changes - before) == 1,
              "drift %.1fx: press should toggle exactly once, got %u",
              drift_factors[f], g_led_changes - before);

        if ((g_led_changes - before) == 1) {
            // Convert cycle latency to real wall-clock ms at the drifted frequency.
            // At drift d: 1 tick = (cycles_per_tick / (F_CPU_HZ * d)) seconds
            //           = 1ms / d real time.
            double ticks = (double)(g_last_led_change_cycle - press_cycle) / cycles_per_tick;
            double latency_ms = ticks / drift_factors[f];
            printf("  drift %.1fx: latency %.2f ms "
                   "(PRESSED_THRESH=%d ticks, goal <10ms)\n",
                   drift_factors[f], latency_ms, PRESSED_THRESH);
            CHECK(latency_ms <= 10.0,
                  "drift %.1fx: latency %.2f ms exceeds the 10ms design goal",
                  drift_factors[f], latency_ms);
        }

        footsw_set(0); run_ms(50);
        before = g_led_changes;
        footsw_set(1); run_ms(20); footsw_set(0); run_ms(50);
        CHECK((g_led_changes - before) == 1,
              "drift %.1fx: second press should toggle once, got %u",
              drift_factors[f], g_led_changes - before);
        CHECK(g_led_level == 0, "drift %.1fx: round trip returns to BYPASS", drift_factors[f]);
    }
}

// Asymmetric EMI bursts: 50ms ON at 500Hz, 200ms OFF.  Models cell-phone
// TDMA handshake interference near audio gear.
static void test_asymmetric_emi_bursts(void) {
    if (sim_reset(0) != 0) { g_failures++; return; }

    uint32_t changes_before = g_led_changes;

    for (int burst = 0; burst < SIM_EMI_BURSTS; ++burst) {
        for (int i = 0; i < 50; ++i) { footsw_drive(i & 1, 1); }
        footsw_drive(0, 200);
    }

    uint32_t toggles = g_led_changes - changes_before;
    CHECK(toggles == 0, "asymmetric EMI: no toggle from bursty interference");
    CHECK(g_led_level == 0, "asymmetric EMI: remained dark (BYPASS)");
}

// Power-on robustness: simulate multiple power cycles, verify consistent
// BYPASS initialization and responsiveness.
static void test_power_on_robustness(void) {
    for (int boot = 0; boot < SIM_POWER_ON_BOOTS; ++boot) {
        if (sim_reset(0) != 0) { g_failures++; return; }

        CHECK(g_led_level == 0, "power-on boot %d: always BYPASS", boot);

        run_ms(50);
        CHECK(g_led_level == 0, "power-on boot %d: stays dark idle", boot);

        footsw_set(1); run_ms(50); footsw_set(0); run_ms(50);
        CHECK(g_led_level == 1, "power-on boot %d: press engages", boot);
        footsw_set(1); run_ms(50); footsw_set(0); run_ms(50);
        CHECK(g_led_level == 0, "power-on boot %d: return to BYPASS", boot);
    }
}


//////////////////////////////////////////////////////////////////////////////
// Phase-jitter stimulus
//
// All tests above drive footswitch edges on whole-millisecond boundaries.
// In reality the edge can arrive at any point within the 1ms tick period.
// These tests scatter the edge timing across the tick window to confirm
// that partial-tick positioning does not prevent press detection or cause
// spurious toggles. The firmware is tolerant by design (the ISR samples on
// the next compare-match after the edge regardless of when within the period
// it arrives), but the test makes this explicit and measurable.
//////////////////////////////////////////////////////////////////////////////

// (#6) Verify press detection at five phase offsets across the 1ms tick window.
// run_cycles() advances by a fractional-tick offset so the footswitch edge
// does not align to a Timer0 compare-match boundary.
static void test_clean_press_phase_jitter(void) {
    static const unsigned offsets[] = { 100u, 300u, 600u, 900u, 1100u };
    const unsigned n = sizeof(offsets) / sizeof(offsets[0]);

    for (unsigned o = 0; o < n; ++o) {
        if (sim_reset(0) != 0) { g_failures++; return; }
        uint32_t before = g_led_changes;

        // Advance by a sub-millisecond offset, then assert the press edge.
        // The ISR samples the new level on the next compare-match, so at
        // most 1 extra tick of latency is incurred -- well within PRESSED_THRESH.
        run_cycles((avr_cycle_count_t)offsets[o]);
        footsw_set(1);
        run_ms(20); // hold well past PRESSED_THRESH even with one extra tick of jitter

        CHECK((g_led_changes - before) == 1u,
              "phase-jitter press (offset=%u/%lu cycles): expected 1 toggle, got %u",
              offsets[o], (unsigned long)CYCLES_PER_MS, g_led_changes - before);
        CHECK(g_led_level == 1,
              "phase-jitter press (offset=%u cycles): should be engaged", offsets[o]);

        footsw_set(0); run_ms(50);
        footsw_set(1); run_ms(20); footsw_set(0); run_ms(50);
        CHECK(g_led_level == 0,
              "phase-jitter round-trip (offset=%u cycles): should return to BYPASS",
              offsets[o]);
    }
}


//////////////////////////////////////////////////////////////////////////////
// Stack high-water mark
//
// Fill SRAM with a 0xAA canary pattern before the firmware starts, then run
// a representative workload. Scan from the top of SRAM downward to find the
// deepest stack address. Asserts adequate margin between the stack bottom and
// the BSS region.
//
// The margin is measured against __bss_end (the first byte above the static
// data), NOT against the bottom of SRAM: the static data sits at the bottom, so
// measuring to 0x60 would count those bytes as free and report a margin larger
// than the stack actually has. The reported number is the count of genuinely
// free bytes between the two.
//
// Limitation: a register or local variable that coincidentally holds 0xAA
// during a stack frame produces a false-clean canary byte, making the result
// a conservative (optimistic) estimate. For these small MCUs and short ISR
// frames, collisions are extremely rare in practice.
//////////////////////////////////////////////////////////////////////////////

static void test_stack_high_water_mark(void) {
    if (sim_reset_raw(0, 0) != 0) { g_failures++; return; }

    const uint32_t sram_bot = 0x60u;         // first SRAM byte on AVR (data space)
    const uint32_t sram_top = g_avr->ramend; // last  SRAM byte (0x9F t13a, 0x25F t85)

    // Fail closed: without __bss_end there is no reference point for the margin,
    // and falling back to sram_bot would silently loosen the gate by the size of
    // the static data.
    CHECK(g_addr_bss_end > sram_bot && g_addr_bss_end <= sram_top,
          "stack HWM: could not resolve __bss_end (got 0x%03X; need ELF symbols)",
          g_addr_bss_end);
    if (g_addr_bss_end <= sram_bot || g_addr_bss_end > sram_top) return;
    const uint32_t bss_end = g_addr_bss_end;

    // Paint the entire SRAM with 0xAA before any firmware code runs.
    for (uint32_t a = sram_bot; a <= sram_top; ++a) {
        g_avr->data[a] = 0xAAu;
    }

    // Representative workload: init(), two press/release cycles (covers the ISR
    // frame, toggle path including the variant's set_*_state() delay, lockout
    // drain, and re-arm -- the deepest call paths).
    run_ms(SETTLE_MS);
    footsw_set(1); run_ms(20 + CTL_DELAY_MS); footsw_set(0); run_ms(40);
    footsw_set(1); run_ms(20 + CTL_DELAY_MS); footsw_set(0); run_ms(40);

    // Scan downward from ramend; the first 0xAA byte we encounter is the
    // deepest address the stack never reached. Everything above (toward ramend)
    // was written by stack pushes.
    uint32_t hwm = sram_top;
    while (hwm >= sram_bot && g_avr->data[hwm] != 0xAAu) {
        hwm--;
    }
    uint32_t deepest_sp   = hwm + 1u;
    uint32_t stack_used   = sram_top - deepest_sp + 1u;
    uint32_t sram_size    = sram_top - sram_bot + 1u;
    uint32_t static_bytes = bss_end - sram_bot;
    // Free bytes between the deepest stack push and the top of the static data.
    // 0 means the stack reached into (or past) BSS.
    uint32_t margin_bytes = (deepest_sp > bss_end) ? (deepest_sp - bss_end) : 0u;

    printf("  stack HWM [%s]: deepest SP=0x%03X, used=%u B, margin=%u B free "
           "(SRAM 0x%03X-0x%03X, %u B total; static 0x%03X-0x%03X, %u B)\n",
           MCU_NAME, deepest_sp, stack_used, margin_bytes,
           sram_bot, sram_top, sram_size,
           sram_bot, bss_end - 1u, static_bytes);

    CHECK(margin_bytes >= 8u,
          "stack leaves only %u free bytes between deepest SP (0x%03X) and the "
          "top of static data (0x%03X); expected >=8 bytes margin",
          margin_bytes, deepest_sp, bss_end);
}


//////////////////////////////////////////////////////////////////////////////
// Variant-specific control-output verification
//
// The tests above observe only the LED (PB1), which behaves identically across
// all variants. These tests verify what makes each variant DIFFERENT: how the
// PB2/PB3 control outputs drive the audio-switching hardware on a toggle.
// Exactly one of these is compiled in, selected by the same -D the firmware was
// built with.
//////////////////////////////////////////////////////////////////////////////

//////////////////////////////////////////////////////////////////////////////
// Busy-wait width band (shared by the relay-pulse and mute-window checks)
//
// hw_set_*_state() holds its control lines with BYPASS_DELAY_MS(), an avr-libc
// _delay_ms() busy loop. _delay_ms() counts FOREGROUND cycles, so the 1 ms tick
// ISR that preempts the loop never pays into the loop's own budget -- every
// preemption adds its cycles on top of the wall-clock width a scope, and this
// harness, actually observes. The overhead is therefore PROPORTIONAL to the
// delay (a longer delay is preempted proportionally more often), which is what
// this harness measures: at the tinyx5's 1 MHz the 12 ms coil pulse arrives at
// 14.03 ms and the 5 ms mute window at 5.87 ms -- +16.9% and +17.4%, the same
// overhead expressed two ways. The ATtiny13a's faster 1.2 MHz clock fits more
// foreground cycles between ticks and lands near +13%.
//
// A fixed +/- ms band cannot express that: the same physics left the 5 ms mute
// window 23% of headroom and the 12 ms coil pulse under 1%, so the longest
// delay in the matrix sat one small ISR change away from failing with no
// defect present. PULSE_PREEMPTION_MARGIN bounds the overhead as a fraction
// of the design width instead, exactly as test_sim_attiny202.py does for the
// XT part (which needs only 0.10 -- at 2 MHz its tick ISR costs about 5.5%).
//
// 25% is roughly 1.5x the worst measured overhead, which leaves the tick ISR
// (footswitch sample, debounce integrate and, under BYPASS_CTX_CHECK, the
// persisted-context validate + refresh) room to grow before this gate trips,
// while still rejecting a halved, doubled or clock-mis-scaled delay by a wide
// margin. Nothing else checks the delivered width on these parts -- the classic
// AVR has no compiled-image delay oracle -- so the band stays no looser.
//
// Preemption can only LENGTHEN the observed width, so the lower edge stays
// tight against the design value; it allows only avr-libc loop-count rounding.
#define PULSE_PREEMPTION_MARGIN  0.25
#define BUSY_WAIT_MIN_MS(design_ms) ((double)(design_ms) - 0.5)
#define BUSY_WAIT_MAX_MS(design_ms) \
    ((double)(design_ms) * (1.0 + PULSE_PREEMPTION_MARGIN))
// Observed width as a percentage over (or under) the design width. Directly
// comparable to PULSE_PREEMPTION_MARGIN.
#define PREEMPTION_PCT(observed_ms, design_ms) \
    (((observed_ms) / (double)(design_ms) - 1.0) * 100.0)

#if defined(TQ2_L2_5V_RELAY)
// TQ2-L2-5V latching relay: a toggle must pulse exactly one coil for the
// configured duration, leave the other coil idle, and PARK BOTH COILS LOW
// afterward (a coil left energized would overheat). Engage pulses the SET coil
// (PB3); bypass pulses the RESET coil (PB2). The pulse must meet the relay's
// 4ms datasheet minimum and sit near the design value.
static void check_coil_pulse(int pulse_idx, int idle_idx, const char *what) {
    double pulse_ms =
        (double)(g_ctl_fall_cycle[pulse_idx] - g_ctl_rise_cycle[pulse_idx])
        / (double)CYCLES_PER_MS;
    printf("  relay %s pulse: %.2f ms (datasheet min 4ms, design %d ms; "
           "tick-ISR preemption %+.1f%%, budget %+.0f%%)\n",
           what, pulse_ms, TQ2_L2_5V_PULSE_MS,
           PREEMPTION_PCT(pulse_ms, TQ2_L2_5V_PULSE_MS),
           PULSE_PREEMPTION_MARGIN * 100.0);
    CHECK(pulse_ms >= 4.0,
          "relay %s pulse %.2f ms below 4ms datasheet minimum", what, pulse_ms);
    CHECK(pulse_ms >= BUSY_WAIT_MIN_MS(TQ2_L2_5V_PULSE_MS) &&
          pulse_ms <= BUSY_WAIT_MAX_MS(TQ2_L2_5V_PULSE_MS),
          "relay %s pulse %.2f ms (%+.1f%% vs the %d ms design) outside "
          "[%.2f, %.2f] ms: tick-ISR preemption may stretch a busy-wait by at "
          "most %+.0f%%",
          what, pulse_ms, PREEMPTION_PCT(pulse_ms, TQ2_L2_5V_PULSE_MS),
          TQ2_L2_5V_PULSE_MS,
          BUSY_WAIT_MIN_MS(TQ2_L2_5V_PULSE_MS),
          BUSY_WAIT_MAX_MS(TQ2_L2_5V_PULSE_MS),
          PULSE_PREEMPTION_MARGIN * 100.0);
    CHECK(g_ctl_level[pulse_idx] == 0 && g_ctl_level[idle_idx] == 0,
          "relay %s: both coils must be parked low after the pulse "
          "(PB2=%d PB3=%d)", what, g_ctl_level[CTL_PB2], g_ctl_level[CTL_PB3]);
}

static void test_control_relay_pulse(void) {
    if (sim_reset(0) != 0) { g_failures++; return; }

    // Power-on bypass: both coils must be de-energized (parked low).
    CHECK(g_ctl_level[CTL_PB2] == 0 && g_ctl_level[CTL_PB3] == 0,
          "relay: both coils low at power-on (PB2=%d PB3=%d)",
          g_ctl_level[CTL_PB2], g_ctl_level[CTL_PB3]);

    // --- Engage: SET coil (PB3) pulses once; RESET (PB2) stays idle. ---
    uint32_t set_before = g_ctl_changes[CTL_PB3];
    uint32_t rst_before = g_ctl_changes[CTL_PB2];
    footsw_set(1); run_ms(50); footsw_set(0); run_ms(50);
    CHECK(g_led_level == 1, "relay: engage lights LED");
    CHECK((g_ctl_changes[CTL_PB3] - set_before) == 2,
          "relay: SET coil should pulse once (2 edges) on engage, got %u edges",
          g_ctl_changes[CTL_PB3] - set_before);
    CHECK((g_ctl_changes[CTL_PB2] - rst_before) == 0,
          "relay: RESET coil must not move on engage, got %u edges",
          g_ctl_changes[CTL_PB2] - rst_before);
    check_coil_pulse(CTL_PB3, CTL_PB2, "SET (engage)");

    // --- Bypass: RESET coil (PB2) pulses once; SET (PB3) stays idle. ---
    set_before = g_ctl_changes[CTL_PB3];
    rst_before = g_ctl_changes[CTL_PB2];
    footsw_set(1); run_ms(50); footsw_set(0); run_ms(50);
    CHECK(g_led_level == 0, "relay: second press bypasses (LED dark)");
    CHECK((g_ctl_changes[CTL_PB2] - rst_before) == 2,
          "relay: RESET coil should pulse once (2 edges) on bypass, got %u edges",
          g_ctl_changes[CTL_PB2] - rst_before);
    CHECK((g_ctl_changes[CTL_PB3] - set_before) == 0,
          "relay: SET coil must not move on bypass, got %u edges",
          g_ctl_changes[CTL_PB3] - set_before);
    check_coil_pulse(CTL_PB2, CTL_PB3, "RESET (bypass)");
}

#elif defined(CD4053_WITH_MUTE)
// "Improved scheme with muting": a toggle asserts the mute, waits the
// mute-settle time, switches, then releases the mute -- so the analog switch
// changes state silently. BYPASS steady state = both control lines low; ENGAGED
// = both high. We verify the steady states and that the mute window between the
// two control-line edges matches the design settle time.
static void test_control_mute_sequence(void) {
    if (sim_reset(0) != 0) { g_failures++; return; }

    // Power-on bypass steady state: both control lines are LOW.
    CHECK(g_ctl_level[CTL_PB2] == X4053_CTL_FOR_STATE(0) &&
          g_ctl_level[CTL_PB3] == X4053_CTL_FOR_STATE(0),
          "mute: bypass steady state both at bypass level (PB2=%d PB3=%d expected=%d)",
          g_ctl_level[CTL_PB2], g_ctl_level[CTL_PB3], X4053_CTL_FOR_STATE(0));

    // --- Engage: CTL2 (PB3) asserts mute first, CTL1 (PB2) un-mutes after the
    //     settle delay. End state: both at the ENGAGED level. ---
    footsw_set(1); run_ms(50); footsw_set(0); run_ms(50);
    CHECK(g_led_level == 1, "mute: engage lights LED");
    CHECK(g_ctl_level[CTL_PB2] == X4053_CTL_FOR_STATE(1) &&
          g_ctl_level[CTL_PB3] == X4053_CTL_FOR_STATE(1),
          "mute: engaged steady state both at engaged level (PB2=%d PB3=%d expected=%d)",
          g_ctl_level[CTL_PB2], g_ctl_level[CTL_PB3], X4053_CTL_FOR_STATE(1));
    double mute_engage_ms =
        (double)(X4053_CTL_EDGE_CYCLE(CTL_PB2, 1) - X4053_CTL_EDGE_CYCLE(CTL_PB3, 1))
        / (double)CYCLES_PER_MS;
    printf("  mute window (engage): %.2f ms (design %d ms; "
           "tick-ISR preemption %+.1f%%, budget %+.0f%%)\n",
           mute_engage_ms, CD4053_MUTE_DELAY_MS,
           PREEMPTION_PCT(mute_engage_ms, CD4053_MUTE_DELAY_MS),
           PULSE_PREEMPTION_MARGIN * 100.0);
    CHECK(mute_engage_ms >= BUSY_WAIT_MIN_MS(CD4053_MUTE_DELAY_MS) &&
          mute_engage_ms <= BUSY_WAIT_MAX_MS(CD4053_MUTE_DELAY_MS),
          "mute window (engage) %.2f ms (%+.1f%% vs the %d ms design) outside "
          "[%.2f, %.2f] ms: tick-ISR preemption may stretch a busy-wait by at "
          "most %+.0f%%",
          mute_engage_ms, PREEMPTION_PCT(mute_engage_ms, CD4053_MUTE_DELAY_MS),
          CD4053_MUTE_DELAY_MS,
          BUSY_WAIT_MIN_MS(CD4053_MUTE_DELAY_MS),
          BUSY_WAIT_MAX_MS(CD4053_MUTE_DELAY_MS),
          PULSE_PREEMPTION_MARGIN * 100.0);

    // --- Bypass: CTL1 (PB2) asserts mute first, CTL2 (PB3) un-mutes after the
    //     settle delay. End state: both at the BYPASS level. ---
    footsw_set(1); run_ms(50); footsw_set(0); run_ms(50);
    CHECK(g_led_level == 0, "mute: second press bypasses (LED dark)");
    CHECK(g_ctl_level[CTL_PB2] == X4053_CTL_FOR_STATE(0) &&
          g_ctl_level[CTL_PB3] == X4053_CTL_FOR_STATE(0),
          "mute: bypass steady state both at bypass level (PB2=%d PB3=%d expected=%d)",
          g_ctl_level[CTL_PB2], g_ctl_level[CTL_PB3], X4053_CTL_FOR_STATE(0));
    double mute_bypass_ms =
        (double)(X4053_CTL_EDGE_CYCLE(CTL_PB3, 0) - X4053_CTL_EDGE_CYCLE(CTL_PB2, 0))
        / (double)CYCLES_PER_MS;
    printf("  mute window (bypass): %.2f ms (tick-ISR preemption %+.1f%%)\n",
           mute_bypass_ms,
           PREEMPTION_PCT(mute_bypass_ms, CD4053_MUTE_DELAY_MS));
    CHECK(mute_bypass_ms >= BUSY_WAIT_MIN_MS(CD4053_MUTE_DELAY_MS) &&
          mute_bypass_ms <= BUSY_WAIT_MAX_MS(CD4053_MUTE_DELAY_MS),
          "mute window (bypass) %.2f ms (%+.1f%% vs the %d ms design) outside "
          "[%.2f, %.2f] ms: tick-ISR preemption may stretch a busy-wait by at "
          "most %+.0f%%",
          mute_bypass_ms, PREEMPTION_PCT(mute_bypass_ms, CD4053_MUTE_DELAY_MS),
          CD4053_MUTE_DELAY_MS,
          BUSY_WAIT_MIN_MS(CD4053_MUTE_DELAY_MS),
          BUSY_WAIT_MAX_MS(CD4053_MUTE_DELAY_MS),
          PULSE_PREEMPTION_MARGIN * 100.0);
}

#else // CD4053_SIMPLE (default)
// Simple CD4053 analog-switch stage: one control line (PB2) follows the effect
// state and the LED, with one edge per toggle. The same polarity also serves the
// pin-compatible TMUX4053 board. PB3 is an unused output parked low.
static void test_control_cd4053_simple(void) {
    if (sim_reset(0) != 0) { g_failures++; return; }

    CHECK(g_ctl_level[CTL_PB2] == X4053_CTL_FOR_STATE(0), "cd4053: bypass -> control at bypass level");

    uint32_t before = g_ctl_changes[CTL_PB2];
    footsw_set(1); run_ms(50); footsw_set(0); run_ms(50);
    CHECK(g_led_level == 1 && g_ctl_level[CTL_PB2] == X4053_CTL_FOR_STATE(1),
          "cd4053: engage -> control at engaged level (PB2=%d LED=%d)",
          g_ctl_level[CTL_PB2], g_led_level);
    CHECK((g_ctl_changes[CTL_PB2] - before) == 1,
          "cd4053: exactly one control edge on engage, got %u",
          g_ctl_changes[CTL_PB2] - before);

    before = g_ctl_changes[CTL_PB2];
    footsw_set(1); run_ms(50); footsw_set(0); run_ms(50);
    CHECK(g_led_level == 0 && g_ctl_level[CTL_PB2] == X4053_CTL_FOR_STATE(0),
          "cd4053: bypass -> control at bypass level (PB2=%d LED=%d)",
          g_ctl_level[CTL_PB2], g_led_level);
    CHECK((g_ctl_changes[CTL_PB2] - before) == 1,
          "cd4053: exactly one control edge on bypass, got %u",
          g_ctl_changes[CTL_PB2] - before);

    CHECK(g_ctl_changes[CTL_PB3] == 0,
          "cd4053: PB3 is unused and must stay parked low, got %u edges",
          g_ctl_changes[CTL_PB3]);
}
#endif

// Dispatch to the control-output test for the variant this binary was built for.
static void test_control_output(void) {
#if defined(TQ2_L2_5V_RELAY)
    test_control_relay_pulse();
#elif defined(CD4053_WITH_MUTE)
    test_control_mute_sequence();
#else
    test_control_cd4053_simple();
#endif
}

#endif // !TRACE

//////////////////////////////////////////////////////////////////////////////
// VCD waveform trace (opt-in; built when TRACE is defined)
//////////////////////////////////////////////////////////////////////////////
#ifdef TRACE
// Output path for the trace, relative to the CWD (the repo root, where `make`
// runs). The Makefile passes -DTRACE_VCD_PATH=... pointing into the AVR build
// directory; this fallback keeps a standalone build self-contained.
#ifndef TRACE_VCD_PATH
#define TRACE_VCD_PATH "bypass_trace.vcd"
#endif
// Produce a GTKWave-viewable trace of PB0/PB1/PB2 through a representative
// press/release sequence. Writes TRACE_VCD_PATH in the CWD.
static int generate_trace(void) {
    if (sim_reset(0) != 0) { return 1; }

    avr_vcd_t vcd;
    if (avr_vcd_init(g_avr, TRACE_VCD_PATH, &vcd, 1000 /*usec flush*/) != 0) {
        fprintf(stderr, "ERROR: avr_vcd_init failed\n");
        return 1;
    }
    avr_vcd_add_signal(&vcd,
        avr_io_getirq(g_avr, AVR_IOCTL_IOPORT_GETIRQ('B'), FOOTSW_PIN),
        1, "PB0_footswitch");
    avr_vcd_add_signal(&vcd,
        avr_io_getirq(g_avr, AVR_IOCTL_IOPORT_GETIRQ('B'), LED_PIN),
        1, "PB1_LED");
    // Control outputs (PB2/PB3): variant-specific meaning (CD4053 ctrl, or
    // CTL1/CTL2, or RESET/SET coils). Traced generically so the same harness
    // produces a useful waveform for every variant.
    avr_vcd_add_signal(&vcd,
        avr_io_getirq(g_avr, AVR_IOCTL_IOPORT_GETIRQ('B'), PB2),
        1, "PB2_ctrl");
    avr_vcd_add_signal(&vcd,
        avr_io_getirq(g_avr, AVR_IOCTL_IOPORT_GETIRQ('B'), PB3),
        1, "PB3_ctrl");

    avr_vcd_start(&vcd);

    // Scenario: idle, press (engage), release, press (bypass), release. Hold
    // each phase long enough to capture the variant's coil/mute pulse too.
    footsw_set(0); run_ms(30);
    footsw_set(1); run_ms(40 + CTL_DELAY_MS);
    footsw_set(0); run_ms(40);
    footsw_set(1); run_ms(40 + CTL_DELAY_MS);
    footsw_set(0); run_ms(40);

    avr_vcd_stop(&vcd);
    avr_vcd_close(&vcd);
    printf("wrote %s (open with: gtkwave %s)\n", TRACE_VCD_PATH, TRACE_VCD_PATH);
    return 0;
}
#endif

int main(int argc, char **argv) {
#ifdef TRACE
    (void)argc; (void)argv;
    int rc = generate_trace();
    if (g_avr) { avr_terminate(g_avr); free(g_avr); }
    return rc;
#else
    // `test_sim fault-inject` runs ONLY the fault-injection suite (used by the
    // Makefile `test-fault-inject` target against the tinyx5 builds). With no
    // argument, run the full suite, which includes fault injection.
    int fault_only = (argc > 1 && strcmp(argv[1], "fault-inject") == 0);

    if (fault_only) {
        run_fault_injection_suite();
        if (g_avr) { avr_terminate(g_avr); free(g_avr); }
        printf("\nsimavr fault-injection tests: %d checks, %d failures\n",
               g_checks, g_failures);
        return g_failures ? 1 : 0;
    }

    test_power_on_default();
    test_single_press_engages();
    test_two_presses_round_trip();
    test_long_hold_single_toggle();
    test_short_spike_rejected();
    test_power_on_pressed();
    test_fast_repeated_taps();
    test_random_noise_resilience();
    test_adversarial_patterns();
    test_minimum_press_toggles();
    test_extreme_bounce();
    test_sustained_noise();
    test_init_completes_before_wdt();
    test_wdt_rearm_window();
    test_power_on_sampling_race();
    test_clean_press_latency();
    test_toggle_parity_invariant();
    test_lockstep_cosim();
    test_monte_carlo_lockstep();
    test_enters_idle_sleep();
    test_watchdog_not_tripped_normally();
    test_wdt_pet_interval_within_budget();
#ifdef TARGET_TINYX5
    test_watchdog_backstop_reset();
    test_watchdog_timeout_within_bound();
#else
    test_watchdog_backstop_documented();
#endif
    test_register_corruption_recovery();
    run_fault_injection_suite();
    test_oscillator_drift_tolerance();
    test_asymmetric_emi_bursts();
    test_power_on_robustness();
    test_clean_press_phase_jitter();
    test_stack_high_water_mark();
    test_control_output();

    if (g_avr) { avr_terminate(g_avr); free(g_avr); }

    printf("\nsimavr firmware tests: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
#endif
}
