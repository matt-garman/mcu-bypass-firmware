// Host-test shim for including the firmware's bypass_config.h on a native
// (non-AVR) compiler.
//
// bypass_config.h is written for the AVR target: it references AVR register
// names (PB0/PB1/PB2, TIMSK) from <avr/io.h> and enforces target-specific
// F_CPU values via #error guards. The host-compiled tests (test_logic_host.c
// and test_sim.c) do not include <avr/io.h>, so this shim provides the minimum
// definitions required to satisfy those references, then includes the REAL
// firmware config header.
//
// The whole point: the tests now pull RELEASE_THRESH / PRESSED_THRESH (and the
// pin numbers / timer reload) directly from the single source of truth in
// bypass_config.h, so they can never silently drift from the firmware.

#ifndef BYPASS_CONFIG_HOST_H__
#define BYPASS_CONFIG_HOST_H__

// --- AVR register-name shims -------------------------------------------------
// bypass_config.h defines FOOTSW_PIN/LED_PIN/CD4053_PIN in terms of these.
// On the AVR target these come from <avr/io.h>; here we mirror the documented
// pin assignment (PB0=footswitch, PB1=LED, PB2=CD4053).
// THESE FALLBACKS STAY, and the reason is specific: `CBMC_DEFS` (Makefile) is
// the ONLY thing in the tree that injects PB0/PB1/PB2, because cbmc ignores
// `-include` and so never sees this header's own definitions. Every other host
// build reaches the pin map through here. So unlike the injected parameters in
// test_soak.c or test_sim.c, an `#error` here would be wrong: nothing is
// severed when these are undefined, that is simply the normal path.
//
// The real hazard is the opposite one, and it is what the checks below close:
// the pin map exists in TWO places, this header and `CBMC_DEFS`, and nothing
// compared them. Change a pin here and cbmc would go on proving the firmware
// against the old map -- a proof about a device that no longer exists, reported
// as a pass. The canonical value is named once and asserted against whatever
// was injected, so the two copies cannot drift apart silently.
#define BYPASS_CONFIG_HOST_PB0 0
#define BYPASS_CONFIG_HOST_PB1 1
#define BYPASS_CONFIG_HOST_PB2 2
#if defined(PB0)
_Static_assert(PB0 == BYPASS_CONFIG_HOST_PB0,
               "injected PB0 (CBMC_DEFS) disagrees with the host pin shim");
#else
#  define PB0 BYPASS_CONFIG_HOST_PB0
#endif
#if defined(PB1)
_Static_assert(PB1 == BYPASS_CONFIG_HOST_PB1,
               "injected PB1 (CBMC_DEFS) disagrees with the host pin shim");
#else
#  define PB1 BYPASS_CONFIG_HOST_PB1
#endif
#if defined(PB2)
_Static_assert(PB2 == BYPASS_CONFIG_HOST_PB2,
               "injected PB2 (CBMC_DEFS) disagrees with the host pin shim");
#else
#  define PB2 BYPASS_CONFIG_HOST_PB2
#endif

// --- F_CPU shim --------------------------------------------------------------
// bypass_config.h's F_CPU #error guards only fire for the AVR targets it
// recognizes. On host (__AVR_ATtiny85__ undefined) it takes the "ATtiny13/a"
// branch and requires F_CPU == 1200000UL. Provide that if the test did not
// already set one, purely to satisfy the guard; the host tests do not depend
// on F_CPU for any logic.
//
// Same two-copy hazard as the pins above: `CBMC_DEFS` restates this value, and
// bypass_config.h's own guard would reject a disagreement only for the branch
// it recognizes. Assert it here so the two spellings are held together
// directly rather than by that coincidence.
#define BYPASS_CONFIG_HOST_F_CPU 1200000UL
#if defined(F_CPU)
_Static_assert(F_CPU == BYPASS_CONFIG_HOST_F_CPU,
               "injected F_CPU (CBMC_DEFS) disagrees with the host clock shim");
#else
#  define F_CPU BYPASS_CONFIG_HOST_F_CPU
#endif

#include "../src/bypass_config.h"

#endif // BYPASS_CONFIG_HOST_H__
