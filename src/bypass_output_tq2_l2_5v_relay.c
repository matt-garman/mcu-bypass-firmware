// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

#include "bypass_output_tq2_l2_5v_relay.h"
#include "bypass_output_common.h"
#include "bypass_config.h"
#include "bypass_hw_iface.h"
#include "bypass_blocking_delay.h"
#include "bypass_static_assert.h" // static_assert()


uint8_t hw_is_sanity_check_failed(effect_state_t const effect_state) {

    static_assert(TQ2_L2_5V_PULSE_MS < RELEASE_THRESH,
        "relay coil pulse must be shorter than RELEASE_THRESH so the "
        "polled-core release/re-arm budget stays below 2 * RELEASE_THRESH");

    uint8_t const output_mask =
        (1U << LED_PIN) | (1U << RELAY_SET_PIN) | (1U << RELAY_RESET_PIN);
    uint8_t const led_high    = (1U << LED_PIN);
    uint8_t       intact      = 0U;

    if (BYPASS == effect_state) {
        // every configured output latch must be low
        intact = hw_output_state_intact(output_mask, 0U);
    }
    else if (ENGAGED == effect_state) {
        // only the LED is high; both relay coils must be low
        intact = hw_output_state_intact(output_mask, led_high);
    }
    else {
        intact = 0U; // invalid logical state fails closed
    }

    return (0U == intact);
}


void hw_init_output_pins(void) {
    hw_configure_output_pins(BYPASS_OUTPUT_DDR_MASK);
}


// force both coils low
static void set_relay_coils_low(void) {
    hw_pin_set_low(RELAY_RESET_PIN);
    hw_pin_set_low(RELAY_SET_PIN);
}

void hw_set_bypass_state(void) {
    set_relay_coils_low();

    hw_led_pin_set_low();        // dark status LED

    hw_pin_set_high(RELAY_RESET_PIN); // pulse reset coil
    BYPASS_DELAY_MS(TQ2_L2_5V_PULSE_MS); // busy sleep for coil pulse time

    set_relay_coils_low();
}

void hw_set_engaged_state(void) {
    set_relay_coils_low();

    hw_led_pin_set_high();       // light status LED

    hw_pin_set_high(RELAY_SET_PIN);   // pulse set coil
    BYPASS_DELAY_MS(TQ2_L2_5V_PULSE_MS); // busy sleep for coil pulse time

    set_relay_coils_low();
}

