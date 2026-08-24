// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

#include "bypass_output_common.h"
#include "bypass_hw_iface.h"
#include "bypass_static_assert.h" // static_assert()


// assert critical pin directions and the complete output latch state hold
uint8_t hw_is_sanity_check_failed(effect_state_t const effect_state) {

    // This variant performs no blocking actuation, so its pet-to-pet window is
    // scheduling latency plus bounded loop work alone. Asserted anyway: the
    // watchdog floor has to cover the loop itself, not just the pulse, and a
    // tick or floor change that broke that would otherwise be caught only on
    // the two variants that happen to block.
    static_assert(WDT_PET_TO_PET_MAX_MS(0U) < WDT_MIN_PERIOD_MS,
            "cd4053: worst-case wall-clock WDT pet-to-pet interval must stay "
            "under the de-rated WDT floor, or a healthy loop can trip the dog");

    uint8_t const output_mask = (1U << LED_PIN) | (1U << CD4053_PIN);
    uint8_t       intact      = 0U;

    if (BYPASS == effect_state) {
        // every configured output latch must be low
        intact = hw_output_state_intact(output_mask, 0U);
    }
    else if (ENGAGED == effect_state) {
        // LED and CD4053 control must both be high
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


// CD4053 case:
//   CD4053_PIN high -> mosfet on  -> 4053 control pins low
//   CD4053_PIN low  -> mosfet off -> 4053 control pins high
//
// TMUX4053 case:
//   CD4053_PIN high -> [direct drive] -> 4053 control pins high
//   CD4053_PIN low  -> [direct drive] -> 4053 control pins low
void hw_set_bypass_state(void) {
    hw_led_pin_set_low();       // dark status LED
    hw_pin_set_low(CD4053_PIN); // BYPASS = MCU low (natural/default state)
}

void hw_set_engaged_state(void) {
    hw_led_pin_set_high();       // light status LED
    hw_pin_set_high(CD4053_PIN); // ENGAGE = MCU high
}


void hw_outputs_reassert_safe(void) { }
