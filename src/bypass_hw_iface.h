// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

#ifndef BYPASS_HW_IFACE_H__
#define BYPASS_HW_IFACE_H__


#include "bypass_types.h"

#include <stdint.h>



// - set a GPIO pin high or low
// - assumes pin was previously configured as output
void hw_pin_set_high(uint8_t const pin);
void hw_pin_set_low(uint8_t const pin);

// - set every GPIO pin selected by pin_mask low in one target operation
// - assumes selected pins were previously configured as outputs
// - pin_mask contains bit masks, unlike the pin-number argument above
void hw_pin_mask_set_low(uint8_t const pin_mask);


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
//   required_output_mask is still configured as an output and the complete
//   output latch matches expected_high_mask
// - consumed by the per-variant sanity check
// - implementations additionally require the complete direction configuration
//   to match initialization
uint8_t hw_output_state_intact(
        uint8_t const required_output_mask,
        uint8_t const expected_high_mask);


// - sets global effect state (ENGAGE/BYPASS)
// - lights or dims status LED
// - does implementation-specific audio routing device control (e.g. cd4053
//   switching, relay coil set/reset)
void hw_set_bypass_state(void);
void hw_set_engaged_state(void);


// - output-implementation-specific sanity check(s)
// - return 1 on sanity check failure: will force WDT timeout
// - return 0 on sanity check OK
uint8_t hw_is_sanity_check_failed(effect_state_t const effect_state);


// initialization of output pins
void hw_init_output_pins(void);


// Fail-safe output de-energization, on the ESCALATION PATH ONLY.
//
// Forces every output carrying a continuous-energization or spurious-actuation
// hazard -- today, the relay coils -- to its de-energized idle. Each shell
// calls it as the first act of its hw_force_wdt_reset(), so no fault can hold
// a coil energized for the length of the deliberate watchdog spin.
//
// It is NOT a loop-top corrector. An unexpectedly energized coil is a FAULT
// and is escalated by the shell's sanity gate rather than silently re-driven
// low: a below-minimum coil pulse cannot be proven mechanically harmless, so
// the firmware cannot know whether the latching relay moved. What restores
// agreement between logical state, LED and physical relay position is the
// recovery itself -- init() drives a complete BYPASS actuation.
// See docs/relay_coil_fault_correction.md.
void hw_outputs_reassert_safe(void);



#endif // BYPASS_HW_IFACE_H__
