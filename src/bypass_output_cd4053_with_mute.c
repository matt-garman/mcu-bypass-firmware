// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

#include "bypass_output_cd4053_with_mute.h"
#include "bypass_output_common.h"
#include "bypass_config.h"
#include "bypass_hw_iface.h"
#include "bypass_blocking_delay.h"
#include "bypass_static_assert.h" // static_assert()


uint8_t hw_is_sanity_check_failed(effect_state_t const effect_state) {

    static_assert(CD4053_MUTE_DELAY_MS < RELEASE_THRESH,
            "CD4053 mute delay must be shorter than the release-lockout window, "
            "or the re-arm point can be missed during the blocking actuation");

    uint8_t const output_mask =
        (1U << LED_PIN) | (1U << CD4053_CTL1) | (1U << CD4053_CTL2);

    uint8_t       intact      = 0U;

    if (BYPASS == effect_state) {
        // every configured output latch must be low
        intact = hw_output_state_intact(output_mask, 0U);
    }
    else if (ENGAGED == effect_state) {
        // LED and both CD4053 controls must be high
        intact = hw_output_state_intact(output_mask, output_mask);
    }   
    else {
        intact = 0U; // invalid logical state fails closed
    }   

    return (0U == intact);
}


void hw_init_output_pins(void) {
    hw_configure_output_pins(BYPASS_OUTPUT_DDR_MASK);
}


// See "Improved Scheme With Muting" in DESIGN_DOCUMENTATION.adoc
void hw_set_bypass_state(void) {   // ...coming from ENGAGE (1,1)
    hw_led_pin_set_low();          // dark status LED

    hw_pin_set_low(CD4053_CTL1);   // ENGAGED -> MUTE (0,1)
    BYPASS_DELAY_MS(CD4053_MUTE_DELAY_MS); // busy sleep for pre-switch mute time

    hw_pin_set_low(CD4053_CTL2);   // MUTE -> BYPASS (0,0) (i.e. un-mute in BYPASS state)
}

void hw_set_engaged_state(void) {  // ...coming from BYPASS (0,0)
    hw_pin_set_low(CD4053_CTL1);   // re-assert BYPASS (0,0)
    hw_pin_set_low(CD4053_CTL2);

    hw_led_pin_set_high();         // light status LED

    hw_pin_set_high(CD4053_CTL2);  // MUTE (0,1)
    BYPASS_DELAY_MS(CD4053_MUTE_DELAY_MS);

    hw_pin_set_high(CD4053_CTL1);  // ENGAGE (1,1)
}

