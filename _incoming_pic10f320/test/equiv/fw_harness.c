// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// Firmware harness for the equivalence test: runs the REAL PIC10F320 firmware
// on the host and captures its status-LED (RA0) output trace, one sample per
// tick. RA0 is the variant-independent witness of effect state -- it is high iff
// the effect is ENGAGED for every output variant (cd4053-simple, cd4053-with-
// mute, tq2-relay), whereas the RA1/RA2 control pins differ per variant (their
// per-variant LATA pattern is asserted on real silicon by the gpsim test).
//
// HOW IT WORKS
//   - The mock <xc.h> (test/equiv/xc.h) turns the firmware's SFR accesses into
//     plain host storage (defined here) and CLRWDT() into bypass_equiv_on_clrwdt().
//   - This file #includes the firmware verbatim, compiled with -Dmain=fw_main so
//     the firmware's main() becomes a callable fw_main().
//   - fw_run() seeds the footswitch level, longjmp-protects the call, and runs
//     fw_main(). The firmware's main loop runs free; the CLRWDT hook fires once
//     per loop iteration and (a) records the LATA output for the tick just
//     finished, (b) advances the stimulus, (c) longjmps back out when the
//     stimulus is exhausted.
//
// One firmware loop iteration == one simulated 1ms tick (the mock makes the
// TMR2 tick always-ready). init()'s own initial CLRWDT() is the only pre-loop
// hook call and is skipped.

#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include "xc.h" // the mock; brings in the SFR/type declarations defined below

// --- SFR storage (declared extern in the mock xc.h) --------------------------
static uint8_t g_lata;
uint8_t PORTA, TRISA, ANSELA, WPUA, PR2, T2CON;
OPTION_REGbits_t OPTION_REGbits;
OSCCONbits_t     OSCCONbits;
WDTCONbits_t     WDTCONbits;
INTCONbits_t     INTCONbits;

// Record each distinct value produced by a firmware LATA write. LATA is exposed
// by xc.h as `*bypass_lata_access()`: an access observes the result of the prior
// write before returning the backing lvalue for the next read/modify/write.
// Consecutive writes are therefore captured without adding hooks to the firmware.
#define FW_LATA_TRANSITION_MAX 64
static uint8_t g_lata_observed;
static uint8_t g_lata_transitions[FW_LATA_TRANSITION_MAX];
static int     g_lata_transition_count;
static int     g_init_lata_transition_count;
static int     g_lata_tracking;

static void observe_lata_transition(void) {
    if (g_lata_tracking && g_lata != g_lata_observed) {
        if (g_lata_transition_count < FW_LATA_TRANSITION_MAX) {
            g_lata_transitions[g_lata_transition_count] = g_lata;
        }
        g_lata_transition_count++;
        g_lata_observed = g_lata;
    }
}

uint8_t *bypass_lata_access(void) {
    observe_lata_transition();
    return &g_lata;
}

static PIR1bits_t g_pir1;
PIR1bits_t *bypass_pir1(void) {
    g_pir1.TMR2IF = 1u; // tick always ready (see xc.h)
    return &g_pir1;
}

// --- harness state ----------------------------------------------------------
static jmp_buf       g_done;
static const uint8_t *g_fsw;   // stimulus: 1 = pressed (RA3 low), 0 = released
static int            g_n;     // stimulus length (number of ticks)
static int            g_tick;  // current tick index
static uint8_t       *g_trace; // out: status-LED bit (LATA & 0x01) per tick
static int            g_clrwdt_calls;

// --- actuation-sequence capture ----------------------------------------------
// The mute/relay drivers call __delay_ms() once per actuation, AFTER asserting the
// mute / energising the coil and BEFORE releasing it -- so LATA at that instant is
// the firmware's transient (mid-pulse) output. The mock routes __delay_ms() here
// (test/equiv/xc.h); we record LATA + the requested delay for each call so
// test/actuation can assert the per-variant mid-actuation pin pattern -- the part
// the equivalence (RA0-only) and gpsim (settled-state-only) tests cannot see.
// The equivalence run itself ignores these; cd4053-simple never calls __delay_ms.
#define FW_ACTUATION_MAX 64
static uint8_t  g_act_lata[FW_ACTUATION_MAX];
static unsigned g_act_ms[FW_ACTUATION_MAX];
static int      g_act_count;

void bypass_on_delay_ms(unsigned ms) {
    if (g_act_count < FW_ACTUATION_MAX) {
        g_act_lata[g_act_count] = LATA;
        g_act_ms[g_act_count]   = ms;
        g_act_count++;
    }
}

int      fw_actuation_count(void) { return g_act_count; }
uint8_t  fw_actuation_lata(int i) { return (i >= 0 && i < g_act_count) ? g_act_lata[i] : 0xFFu; }
unsigned fw_actuation_ms(int i)   { return (i >= 0 && i < g_act_count) ? g_act_ms[i]   : 0u; }
int      fw_init_lata_transition_count(void) { return g_init_lata_transition_count; }
uint8_t  fw_init_lata_transition(int i) {
    return (i >= 0 && i < g_init_lata_transition_count && i < FW_LATA_TRANSITION_MAX)
        ? g_lata_transitions[i] : 0xFFu;
}

// --- settled per-tick full-LATA capture ---------------------------------------
// g_trace (above) records only RA0 (the LED), because that is the one bit the
// variant-agnostic equivalence test compares against the model. But the CLRWDT
// hook fires at the END of each main-loop iteration -- AFTER hw_set_*_state() has
// run to completion (including any blocking __delay_ms pulse) -- so LATA is fully
// SETTLED there for every tick, never mid-pulse. Recording the whole byte lets
// test/actuation assert each variant's per-variant control pins (RA1/RA2) at every
// settled tick, not just RA0. That closes the one hole the RA0-only equivalence
// test leaves on the host: a mis-routed / stuck control pin on the NON-blocking
// cd4053-simple variant (which has no __delay_ms for the actuation-snapshot path
// to catch) -- previously verified only on the simulated core. The equivalence run
// fills this too (and compares the per-tick internal state below). The buffer is
// sized to span the equivalence test's longest stimulus (test/equiv/test_equiv.c
// EQUIV_RANDOM_MAXLEN, currently 1200), so both the settled-LATA and the internal-
// state captures cover EVERY tick rather than a truncated prefix. If a still-longer
// stimulus is ever run the excess ticks are simply not recorded (graceful
// degradation); test_equiv's capacity self-check (via fw_tick_state_count) turns
// that into a loud failure rather than a silent LED-only fall-back.
#define FW_TICK_TRACE_MAX 1200
static uint8_t g_tick_lata[FW_TICK_TRACE_MAX];
static int     g_tick_lata_n; // number of settled per-tick LATA samples recorded

int     fw_tick_count(void) { return g_tick_lata_n; }
uint8_t fw_tick_lata(int i) { return (i >= 0 && i < g_tick_lata_n) ? g_tick_lata[i] : 0xFFu; }

// --- per-tick internal-state capture -----------------------------------------
// The equivalence test originally compared only the LED output (RA0). But the
// parent project's simavr lock-step test compares the firmware's INTERNAL state
// (program_state, effect_state, debounce_counter) against the reference model every
// tick -- a strictly stronger proof, since an internal-state divergence that does
// not yet manifest on the LED would go undetected by an output-only comparison.
// Recording ctx_ at the CLRWDT hook (end of each main-loop iteration, after the
// state machine has run) gives the post-step state for each tick, which the
// model's step() also returns, so the equivalence test can now compare internal
// state tick-for-tick -- matching the parent's co-simulation without simavr.
typedef struct {
    uint8_t program_state;
    uint8_t effect_state;
    uint8_t debounce_counter;
} fw_internal_state_t;
static fw_internal_state_t g_tick_state[FW_TICK_TRACE_MAX];

int             fw_tick_state_count(void) { return g_tick_lata_n; }
uint8_t         fw_tick_ps(int i)  { return (i >= 0 && i < g_tick_lata_n) ? g_tick_state[i].program_state    : 0xFFu; }
uint8_t         fw_tick_es(int i)  { return (i >= 0 && i < g_tick_lata_n) ? g_tick_state[i].effect_state     : 0xFFu; }
uint8_t         fw_tick_dc(int i)  { return (i >= 0 && i < g_tick_lata_n) ? g_tick_state[i].debounce_counter : 0xFFu; }

// Present the footswitch level for tick i on RA3 (pressed => RA3 low).
static void present_footswitch(int i) {
    if (g_fsw[i]) { PORTA &= (uint8_t)~0x08u; } // pressed -> low
    else          { PORTA |=  (uint8_t) 0x08u; } // released -> high
}

// CLRWDT() hook: prototype only here; the full definition follows the firmware
// #include below, where ctx_ (the firmware's debounce context) is visible for
// the per-tick internal-state capture.
void bypass_equiv_on_clrwdt(void);

// Safety net: a real firmware fault (sanity-check failure) would enter
// hw_force_wdt_reset()'s infinite loop with no CLRWDT inside, hanging the host.
// With a faithful mock that cannot happen for valid stimulus, but guard anyway.
static void on_alarm(int sig) {
    (void)sig;
    const char msg[] = "test-equiv: firmware appears stuck (fault path reached?)\n";
    ssize_t w = write(STDERR_FILENO, msg, sizeof msg - 1u);
    (void)w;
    _exit(3);
}

// Bring in the real firmware. -Dmain=fw_main renames its entry point.
#include "../../bypass_mcu_pic10f320.c"

// CLRWDT() hook: fires once per firmware loop iteration (plus once inside init).
// Defined here (after the firmware #include) so ctx_ is visible for the per-tick
// internal-state capture.
void bypass_equiv_on_clrwdt(void) {
    g_clrwdt_calls++;
    if (g_clrwdt_calls == 1) {
        return; // init()'s initial "pet the dog", before the main loop starts
    }
    if (g_clrwdt_calls == 2) {
        // Neither power-on root can toggle on its first debounce iteration, so
        // transitions observed by this boundary are exactly init()'s output
        // sequence. Flush the final init write before marking it.
        observe_lata_transition();
        g_init_lata_transition_count = g_lata_transition_count;
    }
    // A main-loop iteration just completed: capture the status-LED (RA0) output
    // for this tick -- the variant-independent witness of effect state.
    g_trace[g_tick] = (uint8_t)(LATA & 0x01u);
    if (g_tick < FW_TICK_TRACE_MAX) {   // full SETTLED LATA + internal state
        g_tick_lata[g_tick] = LATA;
        g_tick_state[g_tick].program_state    = (uint8_t)ctx_.program_state;
        g_tick_state[g_tick].effect_state     = (uint8_t)ctx_.effect_state;
        g_tick_state[g_tick].debounce_counter = ctx_.debounce_counter;
        g_tick_lata_n = g_tick + 1;
    }
    g_tick++;
    if (g_tick >= g_n) {
        longjmp(g_done, 1); // stimulus exhausted -> unwind out of fw_main()
    }
    present_footswitch(g_tick); // set the level the next iteration will read
}

// Run the firmware over `fsw[0..n-1]`, filling trace[i] with the LED bit
// (LATA & 0x01) at the end of the tick that consumed fsw[i]. init() samples
// fsw[0] (power-on level).
void fw_run(const uint8_t *fsw, int n, uint8_t *trace) {
    g_fsw = fsw; g_n = n; g_tick = 0; g_trace = trace; g_clrwdt_calls = 0;
    g_act_count = 0;    // reset the per-run actuation-snapshot log
    g_tick_lata_n = 0;  // reset the per-run settled per-tick LATA + state log

    // Reset SFR storage to the PIC10F320's relevant power-on values. WPUA's
    // implemented bits reset to 1; nWPUEN keeps those pull-ups globally disabled
    // until init() selects exactly the intended RA3 latch and enables them.
    g_lata = 0u;
    PORTA = TRISA = ANSELA = PR2 = T2CON = 0u;
    WPUA = 0x0Fu;
    OPTION_REGbits.nWPUEN = 1u; OSCCONbits.IRCF = 0u;
    WDTCONbits.WDTPS = 0u; INTCONbits.GIE = 1u; g_pir1.TMR2IF = 0u;

    g_lata_observed = g_lata;
    g_lata_transition_count = 0;
    g_init_lata_transition_count = -1;
    g_lata_tracking = 1;

    present_footswitch(0); // power-on footswitch level for init()'s sample

    signal(SIGALRM, on_alarm);
    alarm(20);
    if (setjmp(g_done) == 0) {
        fw_main(); // runs init() then the main loop; hook longjmps back here
    }
    alarm(0);
}
