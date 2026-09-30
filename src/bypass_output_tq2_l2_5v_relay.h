// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

#ifndef BYPASS_OUTPUT_TQ2_L2_5V_RELAY_H__
#define BYPASS_OUTPUT_TQ2_L2_5V_RELAY_H__


// Panasonic TQ2-L2-5V (2 coil latching), TQ relays catalog ASCTB14E (2025.07):
//   - Specifications: "Operate [Set] time" and "Release [Reset] time" are each
//     max. 3 ms at the rated coil voltage;
//   - "Cautions for usage of TQ relay", Latching: Panasonic recommends a set
//     and reset pulse time of 10 ms or more at the rated coil voltage, for
//     reliable operation across ambient temperature and operating conditions.
// 12 ms meets that recommendation for any clock error up to 20% fast (12/1.2 =
// 10), so the +/-10% design envelope leaves at worst ~10.9 ms. A fast clock is
// the only thing that shortens it: on AVR the tick ISR can only lengthen the
// delay. The driver also asserts it stays below RELEASE_THRESH.
#define TQ2_L2_5V_PULSE_MS (12U)


#endif // BYPASS_OUTPUT_TQ2_L2_5V_RELAY_H__

