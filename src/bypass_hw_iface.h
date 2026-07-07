// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

#ifndef BYPASS_HW_IFACE_H__
#define BYPASS_HW_IFACE_H__


#include <stdint.h>



// - set a GPIO pin high or low
// - assumes pin was previously configured as output
void hw_pin_set_high(uint8_t const pin);
void hw_pin_set_low(uint8_t const pin);


// LED_PIN high = status LED lit
// LED_PIN low = status LED dark
void hw_led_pin_set_high(void);
void hw_led_pin_set_low(void);


// - configure output pins via output_mask
// - GPIO pins in output_mask are configured as output; other GPIO pins are
//   implicitly configured as input
// - the configured output pins are pulled low
void hw_configure_output_pins(uint8_t const output_mask);


// - sanity check function for output pins: returns non-zero IFF every pin in
//   expected_mask is still configured as an output
// - consumed by the per-variant hw_is_sanity_check_failed()
uint8_t hw_output_pins_intact(uint8_t const expected_mask);


// - sets global effect state (ENGAGE/BYPASS)
// - lights or dims status LED
// - does implementation-specific audio routing device control (e.g. cd4053
//   switching, relay coil set/reset)
void hw_set_bypass_state(void);
void hw_set_engaged_state(void);


// - output-implementation-specific sanity check(s)
// - return 1 on sanity check failure: will force WDT timeout
// - return 0 on sanity check OK
uint8_t hw_is_sanity_check_failed(void);


// initialization of output pins
void hw_init_output_pins(void);




#endif // BYPASS_HW_IFACE_H__
