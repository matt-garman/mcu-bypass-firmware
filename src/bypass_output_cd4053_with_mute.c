// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

#include "bypass_output_cd4053_with_mute.h"
#include "bypass_output_common.h"
#include "bypass_config.h"
#include "bypass_hw_iface.h"
#include "bypass_blocking_delay.h"
#include "bypass_static_assert.h" // static_assert()


uint8_t hw_is_sanity_check_failed(void) {

    static_assert(CD4053_MUTE_DELAY_MS < RELEASE_THRESH,
            "CD4053 mute delay must be shorter than the release-lockout window, "
            "or the re-arm point can be missed during the blocking actuation");

    return (0U == hw_output_pins_intact((1 << LED_PIN) | (1 << CD4053_CTL1) | (1 << CD4053_CTL2)));
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

