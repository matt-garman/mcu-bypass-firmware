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
#include "bypass_pure.h"
#if defined(TQ2_L2_5V_RELAY)
#include "bypass_output_tq2_l2_5v_relay.h"
#include "bypass_output_common.h"
#define FW_RELAY_COIL_MASK ((uint8_t)( \
        (uint8_t)(1u << RELAY_SET_PIN) | \
        (uint8_t)(1u << RELAY_RESET_PIN)))
#endif

#define FW_FAULT_TIMEOUT_MS 120
#define FW_DRIVE_TIMEOUT_MS 2000

#if defined(BYPASS_MCU_PIC12F675)
static uint8_t g_gpio;
static int g_footswitch_pressed;
uint8_t TRISIO, ANSEL, WPU, CMCON, OSCCAL, TMR0;
bypass_option_reg_t bypass_option_reg;
bypass_adcon0_reg_t bypass_adcon0_reg;
static volatile INTCONbits_t g_intcon;
#if defined(TQ2_L2_5V_RELAY)
static fw_relay_reassert_observation_t *g_relay_reassert_observation;
#endif

uint8_t *bypass_gpio_access(void) {
    if (g_footswitch_pressed) { g_gpio &= (uint8_t)~0x20u; }
    else                      { g_gpio |= (uint8_t) 0x20u; }
#if defined(TQ2_L2_5V_RELAY)
    if (g_relay_reassert_observation != NULL) {
        g_relay_reassert_observation->gpio_writes++;
        if ((g_gpio & FW_RELAY_COIL_MASK) != 0u) {
            g_relay_reassert_observation->physical_coil_high_samples++;
        }
    }
#endif
    return &g_gpio;
}

volatile INTCONbits_t *bypass_intcon(void) {
    g_intcon.T0IF = 1u;
    return &g_intcon;
}
#else
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
#endif

typedef enum {
    MODE_DRIVE,
    MODE_FAULT,
    MODE_CTX_WINDOW,
    MODE_RELAY_PULSE
} harness_mode_t;
static harness_mode_t g_mode;
static sigjmp_buf      g_jmp;
static int             g_clrwdt_calls;
static const uint8_t  *g_fsw;
static int             g_n;
static int             g_tick;
static uint8_t         g_last_lata;
static int             g_inject;
static int             g_ctx_check_calls;
static int             g_ctx_window_injections;
static int             g_ctx_window_result;
#if defined(TQ2_L2_5V_RELAY)
static fw_relay_pulse_observation_t *g_relay_observation;
static uint8_t         g_relay_active_mask;
static uint8_t         g_relay_inactive_mask;
static uint8_t         g_relay_offset_ms;
static int             g_relay_inactive_high;
static int             g_relay_pulse_error;
#endif

static void set_footswitch(int pressed) {
#if defined(BYPASS_MCU_PIC12F675)
    g_footswitch_pressed = pressed != 0;
    (void)bypass_gpio_access();
#else
    if (pressed) { PORTA &= (uint8_t)~0x08u; }
    else         { PORTA |= (uint8_t) 0x08u; }
#endif
}

static void present_footswitch(int i) {
    set_footswitch(g_fsw[i] != 0u);
}

static void reset_sfrs_power_on(void) {
#if defined(BYPASS_MCU_PIC12F675)
    g_gpio = 0u;
    TRISIO = 0x3fu;
    ANSEL = 0x0fu;
    WPU = CMCON = TMR0 = 0u;
    OSCCAL = 0x80u;
    OPTION_REG = 0xffu;
    ADCON0 = 0u;
    g_intcon.T0IF = 0u;
    g_intcon.GIE = 1u;
    set_footswitch(0);
#else
    g_lata = 0u;
    PORTA = TRISA = ANSELA = PR2 = T2CON = 0u;
    WPUA = 0x0fu;
    OPTION_REGbits.nWPUEN = 1u;
    OSCCONbits.IRCF = 0u;
    WDTCONbits.WDTPS = 0u;
    INTCONbits.GIE = 1u;
    g_pir1.TMR2IF = 0u;
    PORTA |= (uint8_t)(1u << 3);
#endif
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

static uint8_t fwp_ctx_check_word(debounce_context_t ctx);

// Interpose on the shell's check-word calls. The real pure-core function stays
// separately linked and is called by the wrapper below.
#define debounce_ctx_check_word fwp_ctx_check_word
#if defined(BYPASS_MCU_PIC12F675)
#  include "../../../src/bypass_mcu_pic12f675.c"
#else
#  include "../../../src/bypass_mcu_pic10f322.c"
#endif
#undef debounce_ctx_check_word

#if defined(TQ2_L2_5V_RELAY)
static uint8_t relay_intent_state(void) {
#if defined(BYPASS_MCU_PIC12F675)
    return (uint8_t)(gpio_shadow_ & FW_RELAY_COIL_MASK);
#else
    return (uint8_t)(g_lata & FW_RELAY_COIL_MASK);
#endif
}

static uint8_t relay_physical_state(void) {
#if defined(BYPASS_MCU_PIC12F675)
    return (uint8_t)(g_gpio & FW_RELAY_COIL_MASK);
#else
    // The PIC10F322 shell can observe only its output latch, so the host model's
    // physical view is the same latch. PIC12F675 keeps the views independent.
    return (uint8_t)(g_lata & FW_RELAY_COIL_MASK);
#endif
}

static void inject_relay_physical_state(uint8_t value) {
#if defined(BYPASS_MCU_PIC12F675)
    g_gpio = (uint8_t)((g_gpio & (uint8_t)~FW_RELAY_COIL_MASK) |
            (value & FW_RELAY_COIL_MASK));
#else
    g_lata = (uint8_t)((g_lata & (uint8_t)~FW_RELAY_COIL_MASK) |
            (value & FW_RELAY_COIL_MASK));
#endif
}
#endif

void bypass_on_delay_ms(unsigned ms) {
#if defined(TQ2_L2_5V_RELAY)
    unsigned elapsed;
    uint8_t injected_physical;

    if (g_mode != MODE_RELAY_PULSE) return;

    g_relay_observation->delay_ms = (uint8_t)ms;
    g_relay_observation->entry_intent = relay_intent_state();
    g_relay_observation->entry_physical = relay_physical_state();
    if (ms != TQ2_L2_5V_PULSE_MS || g_relay_offset_ms == 0u ||
            g_relay_offset_ms >= ms) {
        g_relay_pulse_error = 1;
        return;
    }

    injected_physical = relay_physical_state();
    g_relay_observation->persisted_to_delay_end = 1u;
    for (elapsed = 0u; elapsed < ms; ++elapsed) {
        if (elapsed == g_relay_offset_ms) {
            if (g_relay_inactive_high != 0) {
                injected_physical |= g_relay_inactive_mask;
            }
            else {
                injected_physical &= (uint8_t)~g_relay_active_mask;
            }
            inject_relay_physical_state(injected_physical);
            g_relay_observation->injections++;
            g_relay_observation->injected_at_ms = (uint8_t)elapsed;
            g_relay_observation->remaining_ms = (uint8_t)(ms - elapsed);
            g_relay_observation->injected_intent = relay_intent_state();
            g_relay_observation->injected_physical = relay_physical_state();
        }
        if (elapsed >= g_relay_offset_ms &&
                relay_physical_state() != injected_physical) {
            g_relay_observation->persisted_to_delay_end = 0u;
        }
        if (elapsed >= g_relay_offset_ms) {
            g_relay_observation->persistence_samples++;
        }
    }
#else
    (void)ms;
#endif
}

static uint8_t fwp_ctx_check_word(debounce_context_t ctx) {
    uint8_t const word = debounce_ctx_check_word(ctx);

    g_ctx_check_calls++;
    if (g_mode == MODE_CTX_WINDOW && g_ctx_check_calls == 2) {
        // The argument above already captured the healthy context. Corrupt the
        // persisted counter before the shell's next operation. The old shell
        // consumes and re-folds this value; a transaction must use its local
        // validated snapshot and safely overwrite or retain a mismatch.
        ctx_.debounce_counter ^= 0x10u;
        g_ctx_window_injections++;
    }
    return word;
}

// FWI_VALID_ENGAGED is the one injection that must NOT be caught: it writes a
// state the firmware could legitimately be in. That means writing F2's check
// word alongside the context, exactly as the shell does -- a stale ctx_check_
// would trip the context-check clause and reset, and the case would assert the
// opposite of what it is named for. run_fw_coverage.sh always defines
// BYPASS_CTX_CHECK (both parts ship with it), so ctx_check_ always exists;
// dropping that flag is a compile error here, by design.
static void apply_injection(int inj) {
#if defined(BYPASS_MCU_PIC12F675)
    switch (inj) {
        case FWI_VALID_ENGAGED:
            ctx_.program_state = RELEASE_DEBOUNCE_WAIT;
            ctx_.effect_state = ENGAGED;
            ctx_.debounce_counter = RELEASE_THRESH;
#if defined(CD4053_SIMPLE)
            fwp_set_output_state(0x03u, 0x03u);
#elif defined(CD4053_WITH_MUTE)
            fwp_set_output_state(0x07u, 0x07u);
#else
            fwp_set_output_state(0x01u, 0x01u);
#endif
            ctx_check_ = debounce_ctx_check_word(ctx_);
            break;
        case FWI_PROGRAM_STATE_OOR:    ctx_.program_state = (program_state_t)2; break;
        case FWI_EFFECT_STATE_OOR:     ctx_.effect_state = (effect_state_t)2; break;
        case FWI_COUNTER_OOR:          ctx_.debounce_counter = (uint8_t)(RELEASE_THRESH + 50u); break;
        case FWI_PULLUP_LATCH_CLEARED: WPU &= (uint8_t)~(1u << 5); break;
        case FWI_PULLUP_EXTRA_GP0:     WPU |= (uint8_t)(1u << 0); break;
        case FWI_PULLUP_EXTRA_GP1:     WPU |= (uint8_t)(1u << 1); break;
        case FWI_PULLUP_EXTRA_GP2:     WPU |= (uint8_t)(1u << 2); break;
        case FWI_PULLUP_EXTRA_GP4:     WPU |= (uint8_t)(1u << 4); break;
        case FWI_PULLUP_GLOBAL_OFF:    OPTION_REGbits.nGPPU = 1u; break;
        case FWI_GP0_PIN_TO_INPUT:     TRISIO |= (uint8_t)(1u << 0); break;
        case FWI_GP1_PIN_TO_INPUT:     TRISIO |= (uint8_t)(1u << 1); break;
        case FWI_GP2_PIN_TO_INPUT:     TRISIO |= (uint8_t)(1u << 2); break;
        case FWI_GP4_PIN_TO_INPUT:     TRISIO |= (uint8_t)(1u << 4); break;
        case FWI_GP5_PIN_TO_OUTPUT:    TRISIO &= (uint8_t)~(1u << 5); break;
        case FWI_SHADOW_GP0_HIGH:      gpio_shadow_ |= (uint8_t)(1u << 0); break;
        case FWI_SHADOW_GP1_HIGH:      gpio_shadow_ |= (uint8_t)(1u << 1); break;
        case FWI_SHADOW_GP2_HIGH:      gpio_shadow_ |= (uint8_t)(1u << 2); break;
        case FWI_SHADOW_GP4_HIGH:      gpio_shadow_ |= (uint8_t)(1u << 4); break;
        case FWI_GPIO_GP0_HIGH:        g_gpio |= (uint8_t)(1u << 0); break;
        case FWI_GPIO_GP1_HIGH:        g_gpio |= (uint8_t)(1u << 1); break;
        case FWI_GPIO_GP2_HIGH:        g_gpio |= (uint8_t)(1u << 2); break;
        case FWI_GPIO_GP4_HIGH:        g_gpio |= (uint8_t)(1u << 4); break;
        case FWI_OPTION_REG_SKEW:      OPTION_REG ^= (uint8_t)0x01u; break;
        case FWI_CMCON_SKEW:           CMCON ^= (uint8_t)0x01u; break;
        case FWI_ADCON0_ADON_SET:      ADCON0bits.ADON = 1u; break;
        case FWI_ANSEL_SKEW_GP0:       ANSEL |= (uint8_t)(1u << 0); break;
        case FWI_ANSEL_SKEW_GP1:       ANSEL |= (uint8_t)(1u << 1); break;
        case FWI_ANSEL_SKEW_GP2:       ANSEL |= (uint8_t)(1u << 2); break;
        case FWI_ANSEL_SKEW_GP4:       ANSEL |= (uint8_t)(1u << 3); break;
        case FWI_OSCCAL_SKEW:          OSCCAL ^= (uint8_t)0x04u; break;
        case FWI_HARNESS_STALL:        for (;;) { }
        case FWI_NONE:
        default:
            break;
    }
#else
    switch (inj) {
        case FWI_VALID_ENGAGED:
            ctx_.program_state = RELEASE_DEBOUNCE_WAIT;
            ctx_.effect_state = ENGAGED;
            ctx_.debounce_counter = RELEASE_THRESH;
#if defined(CD4053_SIMPLE)
            LATA = 0x03u;
#elif defined(CD4053_WITH_MUTE)
            LATA = 0x07u;
#else
            LATA = 0x01u;
#endif
            ctx_check_ = debounce_ctx_check_word(ctx_);
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
        case FWI_LATA_RA0_HIGH:        LATA |= (uint8_t)(1u << 0); break;
        case FWI_LATA_RA1_HIGH:        LATA |= (uint8_t)(1u << 1); break;
        case FWI_LATA_RA2_HIGH:        LATA |= (uint8_t)(1u << 2); break;
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
#endif
}

void bypass_coverage_on_clrwdt(void) {
    g_clrwdt_calls++;
    if (g_clrwdt_calls == 1) return;

    if (g_mode == MODE_DRIVE) {
#if defined(BYPASS_MCU_PIC12F675)
        g_last_lata = (uint8_t)(GPIO & 0x01u);
#else
        g_last_lata = (uint8_t)(LATA & 0x01u);
#endif
        g_tick++;
        if (g_tick >= g_n) {
            disarm_timer();
            siglongjmp(g_jmp, 1);
        }
        present_footswitch(g_tick);
        return;
    }

    if (g_mode == MODE_CTX_WINDOW) {
        uint8_t output_high;
#if defined(BYPASS_MCU_PIC12F675)
        output_high = (uint8_t)(GPIO & 0x01u);
#else
        output_high = (uint8_t)(LATA & 0x01u);
#endif
        g_ctx_window_result =
            (g_ctx_window_injections == 1 &&
             g_ctx_check_calls >= 3 &&
             ctx_.program_state == PRESS_DEBOUNCE_WAIT &&
             ctx_.effect_state == BYPASS &&
             ctx_.debounce_counter == 0u &&
             output_high == 0u &&
             ctx_check_ == debounce_ctx_check_word(ctx_)) ? 0 : 1;
        disarm_timer();
        siglongjmp(g_jmp, 1);
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

int fw_ctx_window_run(void) {
    reset_sfrs_power_on();
    g_mode = MODE_CTX_WINDOW;
    g_clrwdt_calls = 0;
    g_ctx_check_calls = 0;
    g_ctx_window_injections = 0;
    g_ctx_window_result = -1;
    set_footswitch(0);
    if (!install_alarm()) return -1;

    int sj = sigsetjmp(g_jmp, 1);
    if (sj == 0) {
        if (!arm_timer_ms(FW_DRIVE_TIMEOUT_MS)) return -1;
        fw_main();
        (void)disarm_timer();
        return -1;
    }
    if (!disarm_timer()) return -1;
    if (sj == 2) return -1;
    return g_ctx_window_result;
}

#if defined(TQ2_L2_5V_RELAY)
int fw_relay_pulse_fault_run(int engaged, int inactive_high,
        uint8_t offset_ms, fw_relay_pulse_observation_t *observation) {
    if (observation == NULL || (engaged != 0 && engaged != 1) ||
            (inactive_high != 0 && inactive_high != 1)) {
        return -1;
    }

    memset(observation, 0, sizeof *observation);
    reset_sfrs_power_on();
#if defined(BYPASS_MCU_PIC12F675)
    fwp_set_output_state(0u, 0u);
#else
    g_lata = FW_RELAY_COIL_MASK;
    hw_pin_set_low(RELAY_RESET_PIN);
    if (relay_intent_state() != (uint8_t)(1u << RELAY_SET_PIN)) {
        return -1;
    }
    hw_pin_set_low(RELAY_SET_PIN);
    if (relay_intent_state() != 0u) {
        return -1;
    }
    g_lata = 0u;
#endif
    g_mode = MODE_RELAY_PULSE;
    g_relay_observation = observation;
    g_relay_active_mask = (uint8_t)(1u <<
            (engaged != 0 ? RELAY_SET_PIN : RELAY_RESET_PIN));
    g_relay_inactive_mask =
        (uint8_t)(FW_RELAY_COIL_MASK ^ g_relay_active_mask);
    g_relay_offset_ms = offset_ms;
    g_relay_inactive_high = inactive_high;
    g_relay_pulse_error = 0;
    observation->active_mask = g_relay_active_mask;
    observation->offset_ms = offset_ms;

    if (engaged != 0) hw_set_engaged_state();
    else              hw_set_bypass_state();

    observation->final_intent = relay_intent_state();
    observation->final_physical = relay_physical_state();
    g_relay_observation = NULL;
    g_mode = MODE_DRIVE;
    return g_relay_pulse_error == 0 ? 0 : -1;
}

#if defined(BYPASS_MCU_PIC12F675)
int fw_relay_reassert_run(uint8_t initial_coil_shadow,
        fw_relay_reassert_observation_t *observation) {
    uint8_t const led_mask = (uint8_t)(1u << LED_PIN);
    uint8_t const spare_mask = (uint8_t)(1u << SPARE_OUTPUT_PIN);

    if (observation == NULL || initial_coil_shadow == 0u ||
            (initial_coil_shadow & (uint8_t)~FW_RELAY_COIL_MASK) != 0u) {
        return -1;
    }

    memset(observation, 0, sizeof *observation);
    g_relay_reassert_observation = NULL;
    reset_sfrs_power_on();
    fwp_set_output_state(FW_RELAY_COIL_MASK, FW_RELAY_COIL_MASK);
    hw_pin_set_low(RELAY_RESET_PIN);
    if (relay_intent_state() != (uint8_t)(1u << RELAY_SET_PIN) ||
            relay_physical_state() != (uint8_t)(1u << RELAY_SET_PIN)) {
        return -1;
    }
    hw_pin_set_low(RELAY_SET_PIN);
    if (relay_intent_state() != 0u || relay_physical_state() != 0u) {
        return -1;
    }

    fwp_set_output_state((uint8_t)(led_mask | initial_coil_shadow),
            spare_mask);
    observation->entry_shadow =
        (uint8_t)(gpio_shadow_ & (uint8_t)BYPASS_OUTPUT_DDR_MASK);
    observation->entry_gpio =
        (uint8_t)(g_gpio & (uint8_t)BYPASS_OUTPUT_DDR_MASK);

    g_relay_reassert_observation = observation;
    hw_outputs_reassert_safe();
    g_relay_reassert_observation = NULL;

    observation->final_shadow =
        (uint8_t)(gpio_shadow_ & (uint8_t)BYPASS_OUTPUT_DDR_MASK);
    observation->final_gpio =
        (uint8_t)(g_gpio & (uint8_t)BYPASS_OUTPUT_DDR_MASK);
    return 0;
}
#endif
#endif

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

int fwp_output_state_intact(uint8_t required_mask, uint8_t expected_high_mask) {
    return (int)hw_output_state_intact(required_mask, expected_high_mask);
}
int fwp_sanity_failed(effect_state_t effect_state) {
    return (int)hw_is_sanity_check_failed(effect_state);
}
int fwp_pullup_intact(void)              { return (int)hw_footswitch_pullup_intact(); }
int fwp_critical_sfrs_intact(void)       { return (int)hw_critical_sfrs_intact(); }
int fwp_footswitch_is_high(void) {
    return (hw_read_footswitch() == PIN_STATE_HIGH) ? 1 : 0;
}
void fwp_set_footswitch(int pressed) { set_footswitch(pressed); }
#if defined(BYPASS_MCU_PIC12F675)
void fwp_set_output_state(uint8_t intended, uint8_t physical) {
    gpio_shadow_ = (uint8_t)((gpio_shadow_ & (uint8_t)~0x17u) |
                             (intended & 0x17u));
    g_gpio = (uint8_t)((g_gpio & (uint8_t)~0x17u) | (physical & 0x17u));
}
void fwp_capture_osccal(void) { osccal_snapshot_ = OSCCAL; }
#endif
