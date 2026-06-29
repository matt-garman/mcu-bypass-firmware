// Copyright (c) Matthew Garman.  All rights reserved.
// Licensed under the MIT License. See LICENSE in the project root for
// license information.

#ifndef BYPASS_OUTPUT_X4053_POLARITY_H__
#define BYPASS_OUTPUT_X4053_POLARITY_H__


// The pin functions of the CD4053 and TMUX4053 are identical.  However, they
// are driven differently by the MCU: the CD4053 needs logic levels to be the
// same as the supply voltage (typically 9-18v for this application), but the
// MCU runs at 5v.  So with the CD4053, we use pullup resistors (to supply
// voltage) and a MCU-controlled MOSFET to ground.  However, with the
// TMUX4053, this is not necessary.
//
// In short:
//   - CD4053 at 9-18V: MCU drives a MOSFET inverter -> MCU high == 4053 sees LOW
//   - TMUX4053 at logic level: MCU drives the control pin directly
//
// Thus, we need opposite logic values for the switch control pins on CD4053
// vs TMUX4053.
//
// These wrappers name the level the x4053 device sees. Scoped to the x4053
// control pins ONLY; the LED driving is the same, and we don't have such a
// concern for the relay output variant.


#if defined(BYPASS_X4053_DIRECT_DRIVE) // TMUX4053, direct-drive
#  define hw_x4053_ctl_high(pin)  hw_pin_set_high(pin)
#  define hw_x4053_ctl_low(pin)   hw_pin_set_low(pin)
#else                                  // CD4053 + MOSFET inverter (default)
#  define hw_x4053_ctl_high(pin)  hw_pin_set_low(pin)
#  define hw_x4053_ctl_low(pin)   hw_pin_set_high(pin)
#endif


#endif // BYPASS_OUTPUT_X4053_POLARITY_H__
