// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

#include "bypass_output_common.h"
#include "bypass_hw_iface.h"


// assert critical pin directions hold: LED & CD4053 outputs, footswitch input
uint8_t hw_is_sanity_check_failed(void) {
    return (hw_output_pins_intact((1 << LED_PIN) | (1 << CD4053_PIN)) == 0U);
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


