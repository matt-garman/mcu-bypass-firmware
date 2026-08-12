// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman

// PIC12F675 adapter for the shared libgpsim soak harness: the same noise stream
// and the same periodic 2-press round-trip, on the third part and the second
// core family. Three things differ from the 10F32x adapter beside it, and the
// first is the reason this lane needed a device-parameterisation pass at all.
//
//   1. THE OUTPUT LATCH IS NOT A REGISTER. This part has no LATx, so the shell
//      keeps gpio_shadow_ in SRAM and writes shadow -> GPIO. Its address is a
//      per-build fact from the XC8 .sym, not a device address, so the register
//      map only defines the latch entries when the build injected one -- and
//      this lane, which reads the LED out of that latch every simulated
//      millisecond, says so by name below.
//   2. THE TICK IS 1.024 ms. Sampling still happens per millisecond, but the
//      firmware's thresholds are counts of a tick that is no longer one, so the
//      core converts. See docs/pic12f675_feasibility.md section 4.4.1, which
//      asked for exactly this: stated and re-derived, not absorbed by a margin
//      that is already doing another job.
//   3. THE SIMULATED WATCHDOG IS FAITHFUL HERE, which is the opposite of the
//      10F32x situation and still not a licence to assert timing -- see the
//      banner note below.

#include "pic/pic12f675_regs.h"   // device identity: the shadow, and the LED bit

// The register map leaves its latch macros undefined when the build supplied no
// shadow address, so that a lane which never looks at the output path (lock-step)
// need not be given one. This lane READS the latch once per simulated
// millisecond -- it is the entire LED observation -- so it names the missing
// injection rather than failing later on an undeclared identifier. There is no
// value a default could carry that would be right: register 0x000 is INDF, which
// is not storage at all, so an LED sampled through it reads whatever FSR happens
// to point at and a soak that never sees a toggle would report lost
// responsiveness the firmware never lost.
#ifndef PIC_SHADOW_ADDR
#  error "PIC_SHADOW_ADDR (_gpio_shadow_ from the XC8 .sym) is required: this lane reads the LED out of the shadow"
#endif

// TMR0 has no period register on this part. The build derives SOAK_TICK_US from
// the shell's TMR0_SUBTICKS_PER_TICK and derives SOAK_ACTUATION_BLOCK_MS from
// the selected output driver's header. The host timing contract pins the result:
// four unprescaled 256 us rollovers make a 1.024 ms tick.

// Unlike the 10F32x lanes, gpsim's watchdog model matches this part's datasheet
// exactly: with PSA=1 and PS=1:16 a starved reset fires at cycle 288,039, i.e.
// 288.0 ms at 1 MIPS = 18 ms x 16 (docs/pic12f675_feasibility.md section 6.1).
// That agreement is still not permission to assert WDT timing here. The
// datasheet's characterized MINIMUM at this ratio is 160 ms, not 288 ms, and no
// simulator models the RC spread that produces it; what this soak uses the
// watchdog for is unchanged -- a reset, at any period, means liveness was lost.
#define SOAK_WDT_NOTE \
    "(NB: gpsim WDT ~288ms = the 1:16 nominal; silicon min is 160ms -- liveness only)"

#include "pic/test_soak_pic_core.h"
