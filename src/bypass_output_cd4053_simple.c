// Copyright (c) Matthew Garman.  All rights reserved.
// Licensed under the MIT License. See LICENSE in the project root for
// license information.

#include "bypass_output_common.h"
#include "bypass_hw_iface.h"


// assert critical pin directions hold: LED & CD4053 outputs, footswitch input
uint8_t hw_is_sanity_check_failed(void) {
    return (hw_output_pins_intact((1 << LED_PIN) | (1 << CD4053_PIN)) == 0U);
}


void hw_init_output_pins(void) {
    hw_configure_output_pins(BYPASS_OUTPUT_DDR_MASK);
}


// CD4053_PIN high -> mosfet on  -> 4053 control pins low
// CD4053_PIN low  -> mosfet off -> 4053 control pins high
void hw_set_bypass_state(void) {
    hw_led_pin_set_low();        // dark status LED
    hw_pin_set_low(CD4053_PIN);  // set CD4053 pin low
}

void hw_set_engaged_state(void) {
    hw_led_pin_set_high();       // light status LED
    hw_pin_set_high(CD4053_PIN); // set CD4053 pin high
}

