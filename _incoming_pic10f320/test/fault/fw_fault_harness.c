// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// Fault-injection harness: runs the REAL PIC10F320 firmware on the host and
// exercises its DEFENSIVE / fault-detection code -- the per-tick SEU/EMI sanity
// gate in main(), the footswitch pull-up check, the output-pin-direction check,
// the corrupt-state default: case, and hw_force_wdt_reset() itself.
//
// WHY THIS EXISTS
//   The firmware<->model equivalence test (test/equiv) proves the SHIPPING code
//   matches the verified model for VALID stimulus -- but by construction it never
//   presents a corrupted state, so the firmware's fault-recovery layer (the
//   project's cosmic-ray/EMI reliability story) is never reached. Disabling those
//   checks left the whole equivalence + gpsim + host suite green (confirmed by
//   mutation testing). This harness closes that gap.
//
// HOW IT WORKS
//   Like test/equiv/fw_harness.c, the mock <xc.h> (test/equiv/xc.h, via
//   -Itest/equiv) turns the firmware's SFR accesses into plain host storage
//   (defined here) and CLRWDT() into a per-tick hook. This file #includes the
//   firmware verbatim (-Dmain=fw_main), so its static functions and file-global
//   ctx_ are reachable in this translation unit.
//
//   The hard part is OBSERVING a forced reset: hw_force_wdt_reset() clears GIE
//   and spins in for(;;){} forever (on silicon the watchdog then resets the MCU).
//   On the host that would hang. So fw_fault_run() arms a short real-time timer
//   before running the firmware; if the firmware enters the spin, the SIGALRM
//   handler siglongjmp()s back out -- a fired reset is detected as "the firmware
//   hung in the spin until the timer." A clean iteration instead reaches the
//   end-of-loop CLRWDT hook, which disarms the timer and siglongjmp()s out with a
//   "no reset" code. The injection is applied in the hook AFTER one clean warm-up
//   iteration, so it lands just before the next iteration's sanity gate.

// POSIX sigaction / sigsetjmp / siglongjmp / setitimer are hidden under strict
// -std=c11; opt into them. Must precede every system header.
#define _GNU_SOURCE

#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <string.h>
#include <sys/time.h>

#include "xc.h"               // the mock; brings in the SFR/type declarations
#include "fw_fault_harness.h"

#ifndef FW_FAULT_TIMEOUT_MS
#define FW_FAULT_TIMEOUT_MS 120  // how long to wait before declaring "stuck in reset"
#endif
#ifndef FW_DRIVE_TIMEOUT_MS
#define FW_DRIVE_TIMEOUT_MS 2000 // safety net for fw_drive (valid stimulus terminates)
#endif

// --- SFR storage (declared extern in the mock xc.h) --------------------------
static uint8_t g_lata;
uint8_t PORTA, TRISA, ANSELA, WPUA, PR2, T2CON;
OPTION_REGbits_t OPTION_REGbits;
OSCCONbits_t     OSCCONbits;
WDTCONbits_t     WDTCONbits;
INTCONbits_t     INTCONbits;

uint8_t *bypass_lata_access(void) { return &g_lata; }

static PIR1bits_t g_pir1;
PIR1bits_t *bypass_pir1(void) {
    g_pir1.TMR2IF = 1u; // tick always ready (see xc.h)
    return &g_pir1;
}

// The mute/relay drivers call __delay_ms() mid-actuation (routed here by the mock
// <xc.h>). The fault harness only cares about the sanity gate / reset behaviour,
// not the output-pin timing, so it elides the delay. (The actuation pin pattern is
// verified separately by test/actuation.)
void bypass_on_delay_ms(unsigned ms) { (void)ms; }

// --- harness state ----------------------------------------------------------
typedef enum { MODE_DRIVE, MODE_FAULT } harness_mode_t;
static harness_mode_t g_mode;
static sigjmp_buf      g_jmp;
static int             g_clrwdt_calls;

// MODE_DRIVE stimulus
static const uint8_t *g_fsw;
static int            g_n;
static int            g_tick;
static uint8_t        g_last_lata;

// MODE_FAULT injection
static int            g_inject;

// Present the footswitch level for tick i on RA3 (pressed => RA3 low).
static void present_footswitch(int i) {
    if (g_fsw[i]) { PORTA &= (uint8_t)~0x08u; } // pressed  -> low
    else          { PORTA |=  (uint8_t) 0x08u; } // released -> high
}

// Reset all mock SFRs to a clean power-on with the footswitch released.
static void reset_sfrs_power_on(void) {
    g_lata = 0u;
    PORTA = TRISA = ANSELA = PR2 = T2CON = 0u;
    WPUA = 0x0Fu; // PIC10F320 POR/MCLR value: all per-pin pull-up latches set
    OPTION_REGbits.nWPUEN = 1u; OSCCONbits.IRCF = 0u; WDTCONbits.WDTPS = 0u;
    INTCONbits.GIE = 1u; g_pir1.TMR2IF = 0u;
    PORTA |= (uint8_t)(1u << 3); // footswitch released at power-on
}

// --- real-time timer (used to escape hw_force_wdt_reset's infinite spin) ------
static void on_sigalrm(int sig) {
    (void)sig;
    siglongjmp(g_jmp, 2); // 2 == "firmware hung in the forced-reset spin"
}
static void install_alarm(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_sigalrm;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGALRM, &sa, NULL);
}
static void arm_timer_ms(int ms) {
    struct itimerval it;
    memset(&it, 0, sizeof it);
    it.it_value.tv_sec  = ms / 1000;
    it.it_value.tv_usec = (ms % 1000) * 1000;
    setitimer(ITIMER_REAL, &it, NULL);
}
static void disarm_timer(void) {
    struct itimerval it;
    memset(&it, 0, sizeof it);
    setitimer(ITIMER_REAL, &it, NULL);
}

// Bring in the real firmware. -Dmain=fw_main renames its entry point so this TU
// keeps its own linkage; ctx_ and the static hw_* functions become visible below.
#include "../../bypass_mcu_pic10f320.c"

// Apply a corruption to the firmware's live state, modelling an SEU/EMI flip.
// Runs in the CLRWDT hook after one clean warm-up iteration, so it is in effect
// for the next iteration's sanity gate.
static void apply_injection(int inj) {
    switch (inj) {
        case FWI_VALID_ENGAGED:
            ctx_.program_state    = RELEASE_DEBOUNCE_WAIT;
            ctx_.effect_state     = ENGAGED;
            ctx_.debounce_counter = RELEASE_THRESH;
            break;
        case FWI_PROGRAM_STATE_OOR:    ctx_.program_state = (program_state_t)2;   break;
        case FWI_PROGRAM_STATE_MAX:    ctx_.program_state = (program_state_t)255; break;
        case FWI_EFFECT_STATE_OOR:     ctx_.effect_state  = (effect_state_t)2;    break;
        case FWI_COUNTER_OOR:          ctx_.debounce_counter = (uint8_t)(RELEASE_THRESH + 50U); break;
        case FWI_PULLUP_LATCH_CLEARED: WPUA &= (uint8_t)~(1u << 3);               break;
        case FWI_PULLUP_EXTRA_RA0:     WPUA |= (uint8_t)(1u << 0);                break;
        case FWI_PULLUP_EXTRA_RA1:     WPUA |= (uint8_t)(1u << 1);                break;
        case FWI_PULLUP_EXTRA_RA2:     WPUA |= (uint8_t)(1u << 2);                break;
        case FWI_PULLUP_GLOBAL_OFF:    OPTION_REGbits.nWPUEN = 1u;                break;
        case FWI_LED_PIN_TO_INPUT:     TRISA |= (uint8_t)(1u << 0);               break;
        case FWI_CD4053_PIN_TO_INPUT:  TRISA |= (uint8_t)(1u << 1);               break;
        case FWI_RA2_PIN_TO_INPUT:     TRISA |= (uint8_t)(1u << 2);               break;
        // Single-bit SEU flips of the critical config SFRs. init() leaves each at
        // its valid value (IRCF=0x07, WDTPS=0x08, PR2=249, T2CON=0x07); flipping
        // one bit skews it off that value so main()'s equality gate must fire.
        case FWI_OSCCON_IRCF_SKEW:     OSCCONbits.IRCF  ^= 1u;                    break;
        case FWI_WDTPS_SKEW:           WDTCONbits.WDTPS ^= 1u;                    break;
        case FWI_PR2_SKEW:             PR2   ^= (uint8_t)0x01u;                   break;
        case FWI_T2CON_SKEW:           T2CON ^= (uint8_t)0x08u;                   break;
        case FWI_ANSELA_SKEW_RA0:      ANSELA |= (uint8_t)(1u << 0);              break;
        case FWI_ANSELA_SKEW_RA1:      ANSELA |= (uint8_t)(1u << 1);              break;
        case FWI_ANSELA_SKEW_RA2:      ANSELA |= (uint8_t)(1u << 2);              break;
        case FWI_NONE:
        default:
            break;
    }
}

// CLRWDT() hook: fires once inside init() (the pre-loop pet), then once at the
// end of every main-loop iteration.
void bypass_equiv_on_clrwdt(void) {
    g_clrwdt_calls++;
    if (g_clrwdt_calls == 1) {
        return; // init()'s pre-loop "pet the dog"
    }

    if (g_mode == MODE_DRIVE) {
        g_last_lata = (uint8_t)(LATA & 0x01u); // LED bit (RA0) for the tick just finished
        g_tick++;
        if (g_tick >= g_n) {
            disarm_timer();
            siglongjmp(g_jmp, 1); // stimulus exhausted
        }
        present_footswitch(g_tick);
        return;
    }

    // MODE_FAULT
    if (g_clrwdt_calls == 2) {
        apply_injection(g_inject); // corrupt after exactly one clean iteration
        return;
    }
    // Reaching here means a SECOND clean iteration completed: the sanity gate did
    // NOT fire for this injection.
    disarm_timer();
    siglongjmp(g_jmp, 1);
}

int fw_fault_run(fw_inject_t inj) {
    reset_sfrs_power_on();
    g_mode = MODE_FAULT;
    g_clrwdt_calls = 0;
    g_inject = (int)inj;

    install_alarm();
    arm_timer_ms(FW_FAULT_TIMEOUT_MS);

    int sj = sigsetjmp(g_jmp, 1);
    if (sj == 0) {
        fw_main();       // hook drives control flow; never returns normally
        disarm_timer();
        return -1;       // unreachable
    }
    disarm_timer();
    return (sj == 2) ? 1 : 0; // 2 = reset spin (timer); 1 = clean completion
}

uint8_t fw_drive(const uint8_t *fsw, int n) {
    reset_sfrs_power_on();
    g_mode = MODE_DRIVE;
    g_fsw = fsw; g_n = n; g_tick = 0; g_clrwdt_calls = 0; g_last_lata = 0u;
    present_footswitch(0); // power-on level for init()'s sample

    install_alarm();
    arm_timer_ms(FW_DRIVE_TIMEOUT_MS);

    int sj = sigsetjmp(g_jmp, 1);
    if (sj == 0) {
        fw_main();
    }
    disarm_timer();
    if (sj == 2) {
        return 0xFFu; // unexpected hang on valid stimulus -> impossible LED value
    }
    return g_last_lata; // LED bit (RA0): 1 = ENGAGED, 0 = BYPASS
}

// --- direct predicate probes (no main loop) ----------------------------------
int fwp_output_pins_intact(uint8_t mask) { return (int)hw_output_pins_intact(mask); }
int fwp_sanity_failed(void)              { return (int)hw_is_sanity_check_failed(); }
int fwp_pullup_intact(void)              { return (int)hw_footswitch_pullup_intact(); }
int fwp_footswitch_is_high(void) {
    return (hw_read_footswitch() == PIN_STATE_HIGH) ? 1 : 0;
}
