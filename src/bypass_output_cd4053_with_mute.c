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
//
// NOTE: both set_bypass and set_engaged claim a re-assertion of the state
//       from which we're switching.  Note that "re-assertion" is not
//       technically true for the set_bypass function at startup (or after a
//       RESET) - this is because the hardware design intent is to default to
//       bypass state at power-on.  In effect, at power-on, the following
//       happens:
//          - the effect state is bypass due to hardware wiring
//          - the MCU boots, and immediately calls hw_set_bypass_state()
//          - the engaged state is "re-asserted": in this specific case, it
//            actually flips to engaged, then...
//          - immediately flips to bypass
//
void hw_set_bypass_state(void) {   // ...coming from ENGAGE (1,1)
    hw_pin_set_high(CD4053_CTL1);  // re-assert ENGAGE (1,1)
    hw_pin_set_high(CD4053_CTL2);

    hw_led_pin_set_low();          // dark status LED

    hw_pin_set_low(CD4053_CTL1);   // MUTE (0,1)
    BYPASS_DELAY_MS(CD4053_MUTE_DELAY_MS);

    hw_pin_set_low(CD4053_CTL2);   // BYPASS (0,0)
}

void hw_set_engaged_state(void) {  // ...coming from BYPASS (0,0)
    hw_pin_set_low(CD4053_CTL1);   // re-assert BYPASS (0,0)
    hw_pin_set_low(CD4053_CTL2);

    hw_led_pin_set_high();         // light status LED

    hw_pin_set_high(CD4053_CTL2);  // MUTE (0,1)
    BYPASS_DELAY_MS(CD4053_MUTE_DELAY_MS);

    hw_pin_set_high(CD4053_CTL1);  // ENGAGE (1,1)
}

