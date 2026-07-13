// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// Host harness for line coverage of the real PIC shell. The mock xc.h maps the
// shell's SFR accesses to host storage and turns CLRWDT into a loop-boundary
// hook. A timer escapes the shell's intentional watchdog-reset spin.

#define _GNU_SOURCE

#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <string.h>
#include <sys/time.h>

#include "xc.h"
#include "fw_coverage_harness.h"

#define FW_FAULT_TIMEOUT_MS 120
#define FW_DRIVE_TIMEOUT_MS 2000

static uint8_t g_lata;
uint8_t PORTA, TRISA, ANSELA, WPUA, PR2, T2CON;
OPTION_REGbits_t OPTION_REGbits;
OSCCONbits_t     OSCCONbits;
WDTCONbits_t     WDTCONbits;
volatile INTCONbits_t INTCONbits;

uint8_t *bypass_lata_access(void) { return &g_lata; }

static PIR1bits_t g_pir1;
PIR1bits_t *bypass_pir1(void) {
    g_pir1.TMR2IF = 1u;
    return &g_pir1;
}

void bypass_on_delay_ms(unsigned ms) { (void)ms; }

typedef enum { MODE_DRIVE, MODE_FAULT } harness_mode_t;
static harness_mode_t g_mode;
static sigjmp_buf      g_jmp;
static int             g_clrwdt_calls;
static const uint8_t  *g_fsw;
static int             g_n;
static int             g_tick;
static uint8_t         g_last_lata;
static int             g_inject;

static void present_footswitch(int i) {
    if (g_fsw[i]) { PORTA &= (uint8_t)~0x08u; }
    else          { PORTA |=  (uint8_t) 0x08u; }
}

static void reset_sfrs_power_on(void) {
    g_lata = 0u;
    PORTA = TRISA = ANSELA = PR2 = T2CON = 0u;
    WPUA = 0x0fu;
    OPTION_REGbits.nWPUEN = 1u;
    OSCCONbits.IRCF = 0u;
    WDTCONbits.WDTPS = 0u;
    INTCONbits.GIE = 1u;
    g_pir1.TMR2IF = 0u;
    PORTA |= (uint8_t)(1u << 3);
}

static void on_sigalrm(int sig) {
    (void)sig;
    siglongjmp(g_jmp, 2);
}

static int install_alarm(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_sigalrm;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    return sigaction(SIGALRM, &sa, NULL) == 0;
}

static int arm_timer_ms(int ms) {
    struct itimerval it;
    memset(&it, 0, sizeof it);
    it.it_value.tv_sec  = ms / 1000;
    it.it_value.tv_usec = (ms % 1000) * 1000;
    return setitimer(ITIMER_REAL, &it, NULL) == 0;
}

static int disarm_timer(void) {
    struct itimerval it;
    memset(&it, 0, sizeof it);
    return setitimer(ITIMER_REAL, &it, NULL) == 0;
}

#include "../../../src/bypass_mcu_pic10f322.c"

static void apply_injection(int inj) {
    switch (inj) {
        case FWI_VALID_ENGAGED:
            ctx_.program_state = RELEASE_DEBOUNCE_WAIT;
            ctx_.effect_state = ENGAGED;
            ctx_.debounce_counter = RELEASE_THRESH;
            break;
        case FWI_PROGRAM_STATE_OOR:    ctx_.program_state = (program_state_t)2; break;
        case FWI_EFFECT_STATE_OOR:     ctx_.effect_state = (effect_state_t)2; break;
        case FWI_COUNTER_OOR:          ctx_.debounce_counter = (uint8_t)(RELEASE_THRESH + 50u); break;
        case FWI_PULLUP_LATCH_CLEARED: WPUA &= (uint8_t)~(1u << 3); break;
        case FWI_PULLUP_EXTRA_RA0:     WPUA |= (uint8_t)(1u << 0); break;
        case FWI_PULLUP_EXTRA_RA1:     WPUA |= (uint8_t)(1u << 1); break;
        case FWI_PULLUP_EXTRA_RA2:     WPUA |= (uint8_t)(1u << 2); break;
        case FWI_PULLUP_GLOBAL_OFF:    OPTION_REGbits.nWPUEN = 1u; break;
        case FWI_LED_PIN_TO_INPUT:     TRISA |= (uint8_t)(1u << 0); break;
        case FWI_CTL1_PIN_TO_INPUT:    TRISA |= (uint8_t)(1u << 1); break;
        case FWI_RA2_PIN_TO_INPUT:     TRISA |= (uint8_t)(1u << 2); break;
        case FWI_OSCCON_IRCF_SKEW:     OSCCONbits.IRCF ^= 1u; break;
        case FWI_WDTPS_SKEW:           WDTCONbits.WDTPS ^= 1u; break;
        case FWI_PR2_SKEW:             PR2 ^= (uint8_t)0x01u; break;
        case FWI_T2CON_SKEW:           T2CON ^= (uint8_t)0x01u; break;
        case FWI_ANSELA_SKEW_RA0:      ANSELA |= (uint8_t)(1u << 0); break;
        case FWI_ANSELA_SKEW_RA1:      ANSELA |= (uint8_t)(1u << 1); break;
        case FWI_ANSELA_SKEW_RA2:      ANSELA |= (uint8_t)(1u << 2); break;
        case FWI_HARNESS_STALL:        for (;;) { } // timeout without reset entry
        case FWI_NONE:
        default:
            break;
    }
}

void bypass_coverage_on_clrwdt(void) {
    g_clrwdt_calls++;
    if (g_clrwdt_calls == 1) return;

    if (g_mode == MODE_DRIVE) {
        g_last_lata = (uint8_t)(LATA & 0x01u);
        g_tick++;
        if (g_tick >= g_n) {
            disarm_timer();
            siglongjmp(g_jmp, 1);
        }
        present_footswitch(g_tick);
        return;
    }

    if (g_clrwdt_calls == 2) {
        apply_injection(g_inject);
        return;
    }
    disarm_timer();
    siglongjmp(g_jmp, 1);
}

int fw_fault_run(fw_inject_t inj) {
    reset_sfrs_power_on();
    g_mode = MODE_FAULT;
    g_clrwdt_calls = 0;
    g_inject = (int)inj;
    if (!install_alarm()) return -1;

    int sj = sigsetjmp(g_jmp, 1);
    if (sj == 0) {
        if (!arm_timer_ms(FW_FAULT_TIMEOUT_MS)) return -1;
        fw_main();
        (void)disarm_timer();
        return -1;
    }
    if (!disarm_timer()) return -1;
    if (sj == 2) return (INTCONbits.GIE == 0u) ? 1 : -1;
    return 0;
}

uint8_t fw_drive(const uint8_t *fsw, int n) {
    reset_sfrs_power_on();
    g_mode = MODE_DRIVE;
    g_fsw = fsw;
    g_n = n;
    g_tick = 0;
    g_clrwdt_calls = 0;
    g_last_lata = 0u;
    present_footswitch(0);
    if (!install_alarm()) return 0xffu;

    int sj = sigsetjmp(g_jmp, 1);
    if (sj == 0) {
        if (!arm_timer_ms(FW_DRIVE_TIMEOUT_MS)) return 0xffu;
        fw_main();
    }
    if (!disarm_timer()) return 0xffu;
    if (sj == 2) return 0xffu;
    return g_last_lata;
}

int fwp_output_pins_intact(uint8_t mask) { return (int)hw_output_pins_intact(mask); }
int fwp_sanity_failed(void)              { return (int)hw_is_sanity_check_failed(); }
int fwp_pullup_intact(void)              { return (int)hw_footswitch_pullup_intact(); }
int fwp_critical_sfrs_intact(void)       { return (int)hw_critical_sfrs_intact(); }
int fwp_footswitch_is_high(void) {
    return (hw_read_footswitch() == PIN_STATE_HIGH) ? 1 : 0;
}
