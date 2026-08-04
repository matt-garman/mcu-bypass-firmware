// Host-test shim for including the firmware's output (pin-assignment) headers
// on a native (non-AVR) compiler.
//
// The firmware output headers (bypass_output_common.h and the per-variant
// bypass_output_*.h) define the pin assignments (FOOTSW_PIN, LED_PIN, and the
// variant-specific control pins) in terms of the AVR register-bit names
// PB0..PB5. On the AVR target those names come from <avr/io.h>; the headers
// guard that include behind #if defined(__AVR__), so on the host we must define
// the names ourselves BEFORE including them.
//
// The whole point: the sim tests pull the pin numbers from the SAME firmware
// headers the firmware compiles against, so a pin reassignment can never
// silently diverge between firmware and test. This mirrors how
// bypass_config_host.h shares the debounce thresholds.
//
// The variant is selected by the SAME macro the firmware build uses
// (CD4053_SIMPLE / CD4053_WITH_MUTE / TQ2_L2_5V_RELAY), so the Makefile passes
// one -D to both the firmware and the test.

#ifndef BYPASS_OUTPUT_HOST_H__
#define BYPASS_OUTPUT_HOST_H__

// --- AVR register-bit-name shims --------------------------------------------
// PORTB has 6 bits (PB0..PB5) on both the ATtiny13a and ATtiny85. Define them
// as their bit positions, matching <avr/io.h>.
// PB0..PB2 are asserted rather than merely defaulted, for the same reason as in
// bypass_config_host.h: they exist in more than one place. Here there are three
// copies -- this header, that one, and `CBMC_DEFS` -- and the host harnesses
// include BOTH headers, in an order that decides which one's values win. That
// made the agreement a property of include order rather than of anything
// checked. Now whichever is defined first is compared against this header's
// canonical value, so the three copies are held together in every build that
// touches two of them. PB3..PB5 below are defined nowhere else and stay plain.
#define BYPASS_OUTPUT_HOST_PB0 0
#define BYPASS_OUTPUT_HOST_PB1 1
#define BYPASS_OUTPUT_HOST_PB2 2
#if defined(PB0)
_Static_assert(PB0 == BYPASS_OUTPUT_HOST_PB0,
               "PB0 disagrees with the host output pin shim");
#else
#  define PB0 BYPASS_OUTPUT_HOST_PB0
#endif
#if defined(PB1)
_Static_assert(PB1 == BYPASS_OUTPUT_HOST_PB1,
               "PB1 disagrees with the host output pin shim");
#else
#  define PB1 BYPASS_OUTPUT_HOST_PB1
#endif
#if defined(PB2)
_Static_assert(PB2 == BYPASS_OUTPUT_HOST_PB2,
               "PB2 disagrees with the host output pin shim");
#else
#  define PB2 BYPASS_OUTPUT_HOST_PB2
#endif
#ifndef PB3
#  define PB3 3
#endif
#ifndef PB4
#  define PB4 4
#endif
#ifndef PB5
#  define PB5 5
#endif

// Select the classic-AVR pin map — the same map the firmware build uses (it
// keys off __AVR__, which the host compiler does not define). The PBx shims
// above stay for the sim harness's own register-bit references (e.g.
// avr_io_getirq(..., PB2)); the firmware pin POSITIONS come from the pin map.
#ifndef BYPASS_MCU_AVR_CLASSIC
#  define BYPASS_MCU_AVR_CLASSIC 1
#endif
#include "../src/bypass_output_common.h"

// Variant-specific control pins. Default to the CD4053 simple variant when no
// selector is defined, matching the firmware's behavior.
#if defined(CD4053_WITH_MUTE)
#  include "../src/bypass_output_cd4053_with_mute.h"
#elif defined(TQ2_L2_5V_RELAY)
#  include "../src/bypass_output_tq2_l2_5v_relay.h"
#else
#  include "../src/bypass_output_cd4053_simple.h"
#endif

#endif // BYPASS_OUTPUT_HOST_H__
