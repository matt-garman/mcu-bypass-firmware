#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
#
# test_sim_attiny202.py -- ATtiny202 (AVR-XT) register-level FUNCTIONAL test on
# a patched yasimavr. The AVR-XT analogue of the AVR-Classic simavr functional
# test (test/avr/test_sim.c) and the PIC gpsim toggle test (pic-test-gpsim):
# drive the real built firmware image, wiggle the footswitch, and assert the
# status LED engages/disengages on each debounced press -- plus the boot-health
# and idle-stability properties the shell's per-tick sanity gate guarantees.
#
# This is also the in-harness regression for upstream yasimavr WDT patch 0002:
# were the WINDOW=OFF bug present, the fuse-locked WDT would reset ~every pet and
# the LED would never engage, so the toggle assertions below would fail.
#
# Usage:   make attiny202-sim  (supplies the ELF and required production fuses)
# Exit:    0 = PASS, 1 = a check failed, 2 = bad invocation / missing image.

import sys

import sim_attiny202 as S

# Hold times: comfortably past the debounce thresholds (8 ms press, 25 ms
# release) so a press/release is unambiguously registered.
PRESS_HOLD_MS = 20
RELEASE_HOLD_MS = 40
SETTLE_MS = 50
IDLE_STABILITY_MS = 250     # idle soak for the sanity-gate / no-spurious-reset check
N_TOGGLES = 6


class Checker:
    def __init__(self):
        self.fails = 0

    def check(self, ok, msg):
        status = "OK  " if ok else "FAIL"
        stream = sys.stdout if ok else sys.stderr
        stream.write("[sim] %s  %s\n" % (status, msg))
        stream.flush()
        if not ok:
            self.fails += 1
        return ok


def test_boot_health(sim, ck):
    # After reset the shell should be running (not wedged in the force-reset
    # spin), the WDT should be locked with the programmed period, and the LED
    # should be dark (bypass at power-on with the footswitch released).
    sim.run_ms(SETTLE_MS)
    ck.check(not sim.in_trap_spin(),
             "boot: PC not in force-reset spin (PC=0x%04X)" % sim.pc())
    ck.check(sim.wdt_locked(), "boot: WDT.STATUS.LOCK set")
    ck.check(sim.read_ioreg(S.REG_WDT_CTRLA) == S.WDTCFG_LOCKED,
             "boot: WDT.CTRLA == 0x%02X" % S.WDTCFG_LOCKED)
    ck.check(sim.critical_sfrs_intact(), "boot: critical SFRs intact")
    ck.check(not sim.led_on(), "boot: LED dark at idle")


def test_toggles(sim, ck):
    # Each debounced press flips the engage state; the LED must alternate
    # ON, off, ON, off, ...
    for i in range(1, N_TOGGLES + 1):
        sim.press()
        sim.run_ms(PRESS_HOLD_MS)
        sim.release()
        sim.run_ms(RELEASE_HOLD_MS)
        expect_on = (i % 2 == 1)
        ck.check(sim.led_on() == expect_on,
                 "press #%d -> LED %s" % (i, "ON" if expect_on else "off"))


def test_idle_stability(sim, ck):
    # Idle with the footswitch released for a long stretch: the sanity gate must
    # never force the reset spin and the WDT must stay locked (this is what a
    # regressed WDT window bug would break). Sample in 1 ms steps because
    # SimLoop.run is atomic over its budget.
    state = {"trapped": False, "unlocked": False}

    def sample(_elapsed):
        if sim.in_trap_spin():
            state["trapped"] = True
        if not sim.wdt_locked():
            state["unlocked"] = True

    sim.run_ms_stepped(IDLE_STABILITY_MS, step_ms=1, on_step=sample)
    ck.check(not state["trapped"],
             "idle %d ms: never entered force-reset spin" % IDLE_STABILITY_MS)
    ck.check(not state["unlocked"],
             "idle %d ms: WDT stayed locked" % IDLE_STABILITY_MS)
    ck.check(not sim.led_on(), "idle %d ms: LED stayed dark" % IDLE_STABILITY_MS)


def test_power_on_pressed(elf, ck):
    # Special case: footswitch held at power-on must stay BYPASS (LED dark) and
    # wait for release before it will respond -- mirrors the PIC
    # power_on_pressed gpsim scenario and the shell's debounce_init_context.
    sim = S.Sim(elf)
    sim.press()                     # held down through reset
    sim.run_ms(SETTLE_MS + 30)
    ck.check(not sim.led_on(), "power-on-pressed: stays bypass (LED dark)")
    ck.check(not sim.in_trap_spin(),
             "power-on-pressed: not in force-reset spin")

    # Release, then a fresh press must now engage the effect.
    sim.release()
    sim.run_ms(RELEASE_HOLD_MS)
    sim.press()
    sim.run_ms(PRESS_HOLD_MS)
    sim.release()
    sim.run_ms(RELEASE_HOLD_MS)
    ck.check(sim.led_on(), "power-on-pressed: first press after release engages")


def main(argv):
    elf = S.resolve_elf(argv[1] if len(argv) > 1 else None)
    print("SIM START: fw=%s  F_CPU=%d Hz" % (elf, S.F_CPU_HZ))

    ck = Checker()
    sim = S.Sim(elf)
    test_boot_health(sim, ck)
    test_toggles(sim, ck)
    test_idle_stability(sim, ck)
    test_power_on_pressed(elf, ck)

    verdict = "PASS" if ck.fails == 0 else "FAIL"
    print("\nSIM %s: %d check(s) failed." % (verdict, ck.fails))
    return 0 if ck.fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
