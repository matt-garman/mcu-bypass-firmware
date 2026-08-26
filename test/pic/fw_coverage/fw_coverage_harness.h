// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

#ifndef BYPASS_PIC_FW_COVERAGE_HARNESS_H
#define BYPASS_PIC_FW_COVERAGE_HARNESS_H

#include <stdint.h>

#include "bypass_types.h"

typedef enum {
    FWI_NONE = 0,
    FWI_VALID_ENGAGED,
    FWI_PROGRAM_STATE_OOR,
    FWI_EFFECT_STATE_OOR,
    FWI_COUNTER_OOR,
    FWI_PULLUP_LATCH_CLEARED,
#if defined(BYPASS_MCU_PIC12F675)
    FWI_PULLUP_EXTRA_GP0,
    FWI_PULLUP_EXTRA_GP1,
    FWI_PULLUP_EXTRA_GP2,
    FWI_PULLUP_EXTRA_GP4,
    FWI_PULLUP_GLOBAL_OFF,
    FWI_GP0_PIN_TO_INPUT,
    FWI_GP1_PIN_TO_INPUT,
    FWI_GP2_PIN_TO_INPUT,
    FWI_GP4_PIN_TO_INPUT,
    FWI_GP5_PIN_TO_OUTPUT,
    FWI_SHADOW_GP0_HIGH,
    FWI_SHADOW_GP1_HIGH,
    FWI_SHADOW_GP2_HIGH,
    FWI_SHADOW_GP4_HIGH,
    FWI_GPIO_GP0_HIGH,
    FWI_GPIO_GP1_HIGH,
    FWI_GPIO_GP2_HIGH,
    FWI_GPIO_GP4_HIGH,
    FWI_OPTION_REG_SKEW,
    FWI_CMCON_SKEW,
    FWI_ADCON0_ADON_SET,
    FWI_ANSEL_SKEW_GP0,
    FWI_ANSEL_SKEW_GP1,
    FWI_ANSEL_SKEW_GP2,
    FWI_ANSEL_SKEW_GP4,
    FWI_OSCCAL_SKEW,
#else
    FWI_PULLUP_EXTRA_RA0,
    FWI_PULLUP_EXTRA_RA1,
    FWI_PULLUP_EXTRA_RA2,
    FWI_PULLUP_GLOBAL_OFF,
    FWI_LED_PIN_TO_INPUT,
    FWI_CTL1_PIN_TO_INPUT,
    FWI_RA2_PIN_TO_INPUT,
    FWI_LATA_RA0_HIGH,
    FWI_LATA_RA1_HIGH,
    FWI_LATA_RA2_HIGH,
    FWI_OSCCON_IRCF_SKEW,
    FWI_WDTPS_SKEW,
    FWI_PR2_SKEW,
    FWI_T2CON_SKEW,
    FWI_ANSELA_SKEW_RA0,
    FWI_ANSELA_SKEW_RA1,
    FWI_ANSELA_SKEW_RA2,
#endif
    FWI_HARNESS_STALL
} fw_inject_t;

#if defined(TQ2_L2_5V_RELAY)
typedef struct {
    uint8_t active_mask;
    uint8_t delay_ms;
    uint8_t offset_ms;
    uint8_t entry_intent;
    uint8_t entry_physical;
    uint8_t injected_intent;
    uint8_t injected_physical;
    uint8_t injections;
    uint8_t injected_at_ms;
    uint8_t remaining_ms;
    uint8_t persistence_samples;
    uint8_t persisted_to_delay_end;
    uint8_t final_intent;
    uint8_t final_physical;
} fw_relay_pulse_observation_t;
#if defined(BYPASS_MCU_PIC12F675)
typedef struct {
    uint8_t entry_shadow;
    uint8_t entry_gpio;
    uint8_t gpio_writes;
    uint8_t physical_coil_high_samples;
    uint8_t final_shadow;
    uint8_t final_gpio;
} fw_relay_reassert_observation_t;
#endif
#endif

int fw_fault_run(fw_inject_t inj);
uint8_t fw_drive(const uint8_t *fsw, int n);
int fw_ctx_window_run(void);
#if defined(TQ2_L2_5V_RELAY)
int fw_relay_pulse_fault_run(int engaged, int inactive_high,
        uint8_t offset_ms, fw_relay_pulse_observation_t *observation);
#if defined(BYPASS_MCU_PIC12F675)
int fw_relay_reassert_run(uint8_t initial_coil_shadow,
        fw_relay_reassert_observation_t *observation);
#endif
#endif
int fwp_output_state_intact(uint8_t required_mask, uint8_t expected_high_mask);
int fwp_sanity_failed(effect_state_t effect_state);
int fwp_pullup_intact(void);
int fwp_critical_sfrs_intact(void);
int fwp_footswitch_is_high(void);
void fwp_set_footswitch(int pressed);
#if defined(BYPASS_MCU_PIC12F675)
void fwp_set_output_state(uint8_t intended, uint8_t physical);
// The MODELED PIN levels of the guarded output set, independent of the SRAM
// shadow -- the witness the escalation path's one whole-port write is judged
// by. fwp_output_state_intact() folds shadow and port together; this returns
// the port alone, which is what a pre-spin physical assertion needs.
uint8_t fwp_physical_output_state(void);
void fwp_capture_osccal(void);
#endif

#endif
