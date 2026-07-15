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
    FWI_HARNESS_STALL
} fw_inject_t;

int fw_fault_run(fw_inject_t inj);
uint8_t fw_drive(const uint8_t *fsw, int n);
int fwp_output_state_intact(uint8_t required_mask, uint8_t expected_high_mask);
int fwp_sanity_failed(effect_state_t effect_state);
int fwp_pullup_intact(void);
int fwp_critical_sfrs_intact(void);
int fwp_footswitch_is_high(void);

#endif
