#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
#
# test_sim_attiny202.py -- ATtiny202 (AVR-XT) register-level FUNCTIONAL test on
# a patched yasimavr. The AVR-XT analogue of the AVR-Classic simavr functional
# test (test/avr/test_sim.c) and the PIC gpsim toggle test (pic-test-gpsim):
# drive the real built firmware image, wiggle the footswitch, and assert the
# status LED engages/disengages on each debounced press. It also traces physical
# PA2/PA3 output transitions and pulse timing for all three output variants,
# plus the boot-health and idle-stability properties the shell's per-tick sanity
# gate guarantees.
#
# This is also the in-harness regression for upstream yasimavr WDT patch 0002:
# were the WINDOW=OFF bug present, the fuse-locked WDT would reset ~every pet and
# the LED would never engage, so the toggle assertions below would fail.
#
# Usage:   make attiny202-sim  (supplies the ELF and required production fuses)
# Exit:    0 = PASS, 1 = a check failed, 2 = bad invocation / missing image.

import os
import sys

import sim_attiny202 as S

# Hold times: comfortably past the debounce thresholds (8 ms press, 25 ms
# release) so a press/release is unambiguously registered.
PRESS_HOLD_MS = 20
RELEASE_HOLD_MS = 40
SETTLE_MS = 50
IDLE_STABILITY_MS = 250     # idle soak for the sanity-gate / no-spurious-reset check
N_TOGGLES = 6

# Physical output tracing runs one simulator cycle at a time so even a one-cycle
# wrong ordering or dual-coil state is observable. Measured edges are therefore
# cycle-exact; a small tolerance covers compiled delay-loop/call overhead.
OUTPUT_SAMPLE_CYCLES = 1
OUTPUT_TIMING_TOLERANCE_CYCLES = 200
OUTPUT_TRACE_MS = 30

VARIANTS = ("cd4053", "mute", "relay")


class OutputTrace:
    def __init__(self, name):
        self.name = name
        self.transitions = []
        self.saw_both_high = False
        self.stalled = False
        self.configured = False
        self.unsafe_before_config = False
        self.invalid_after_config = False
        self.initial_state = None


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


def resolve_variant():
    variant = os.environ.get("ATTINY202_VARIANT")
    if variant not in VARIANTS:
        sys.stderr.write(
            "ERROR: ATTINY202_VARIANT must be one of %s (got %r).\n"
            % (", ".join(VARIANTS), variant)
        )
        return None
    return variant


def state_from_levels(levels):
    ctl1, ctl2 = levels
    if ctl1 is None or ctl2 is None:
        return None
    return ctl1 | (ctl2 << 1)


def trace_outputs(sim, name, milliseconds):
    trace = OutputTrace(name)
    levels = sim.control_levels()
    previous = state_from_levels(levels)
    trace.unsafe_before_config = previous is None and 1 in levels
    if previous is not None:
        trace.configured = True
        trace.initial_state = previous
        trace.saw_both_high = previous == 0x3
    end_cycle = sim.cycle() + sim.cycles(milliseconds)

    while sim.cycle() < end_cycle:
        before = sim.cycle()
        sim.run_cycles(min(OUTPUT_SAMPLE_CYCLES, end_cycle - before))
        after = sim.cycle()
        if after <= before:
            trace.stalled = True
            break
        levels = sim.control_levels()
        state = state_from_levels(levels)
        if state is None:
            if trace.configured:
                trace.invalid_after_config = True
            elif 1 in levels:
                trace.unsafe_before_config = True
            continue
        if not trace.configured:
            trace.configured = True
            trace.initial_state = state
            previous = state
            trace.saw_both_high = state == 0x3
            continue
        trace.saw_both_high = trace.saw_both_high or state == 0x3
        if state != previous:
            trace.transitions.append((after, state))
            previous = state
    return trace


def check_trace(ck, trace, expected_states):
    actual_states = [state for _cycle, state in trace.transitions]
    ck.check(not trace.stalled, "%s: simulator kept advancing" % trace.name)
    ck.check(not trace.unsafe_before_config,
             "%s: no control pin was high before both became driven" % trace.name)
    ck.check(trace.configured, "%s: PA2/PA3 became driven outputs" % trace.name)
    ck.check(not trace.invalid_after_config,
             "%s: PA2/PA3 stayed exact driven High/Low" % trace.name)
    ck.check(actual_states == expected_states,
             "%s: PA2/PA3 states %s == expected %s"
             % (trace.name, actual_states, expected_states))


def check_pulse(ck, trace, pulse_state, expected_ms, relay_minimum=False):
    start = None
    end = None
    for index, (cycle, state) in enumerate(trace.transitions):
        if state == pulse_state:
            start = cycle
            if index + 1 < len(trace.transitions):
                end = trace.transitions[index + 1][0]
            break

    if not ck.check(start is not None and end is not None,
                    "%s: complete state 0x%X pulse observed"
                    % (trace.name, pulse_state)):
        return

    width = end - start
    expected = S.F_CPU_HZ * expected_ms // 1000
    difference = abs(width - expected)
    width_ms = width * 1000.0 / S.F_CPU_HZ
    ck.check(difference <= OUTPUT_TIMING_TOLERANCE_CYCLES,
             "%s: pulse %.3f ms within %d ms +/-0.10 ms"
             % (trace.name, width_ms, expected_ms))
    if relay_minimum:
        ck.check(width >= S.F_CPU_HZ * 4 // 1000,
                 "%s: relay pulse %.3f ms meets 4 ms minimum"
                 % (trace.name, width_ms))


def test_control_outputs(elf, variant, ck):
    # Use a fresh instance so startup transitions are observed from reset.
    sim = S.Sim(elf)

    startup = trace_outputs(sim, "output startup", OUTPUT_TRACE_MS)
    ck.check(startup.initial_state == 0x0,
             "output startup: first driven PA2/PA3 state was safe low 0x0")
    sim.press()
    engage = trace_outputs(sim, "output engage", OUTPUT_TRACE_MS)
    sim.release()
    release_one = trace_outputs(sim, "output release after engage", RELEASE_HOLD_MS)
    sim.press()
    bypass = trace_outputs(sim, "output bypass", OUTPUT_TRACE_MS)
    sim.release()
    release_two = trace_outputs(sim, "output release after bypass", RELEASE_HOLD_MS)

    check_trace(ck, release_one, [])
    check_trace(ck, release_two, [])

    if variant == "cd4053":
        check_trace(ck, startup, [])
        check_trace(ck, engage, [0x1])
        check_trace(ck, bypass, [0x0])
        ck.check(sim.control_state() == 0x0,
                 "simple x4053: PA2 low and spare PA3 parked low in BYPASS")
    elif variant == "mute":
        check_trace(ck, startup, [])
        check_trace(ck, engage, [0x2, 0x3])
        check_trace(ck, bypass, [0x2, 0x0])
        check_pulse(ck, engage, 0x2, 5)
        check_pulse(ck, bypass, 0x2, 5)
        ck.check(sim.control_state() == 0x0,
                 "muted x4053: PA2/PA3 finish at BYPASS 0x0")
    else:
        check_trace(ck, startup, [0x1, 0x0])
        check_trace(ck, engage, [0x2, 0x0])
        check_trace(ck, bypass, [0x1, 0x0])
        for trace in (startup, engage, release_one, bypass, release_two):
            ck.check(not trace.saw_both_high,
                     "%s: relay coils were never both high" % trace.name)
        check_pulse(ck, startup, 0x1, 12, relay_minimum=True)
        check_pulse(ck, engage, 0x2, 12, relay_minimum=True)
        check_pulse(ck, bypass, 0x1, 12, relay_minimum=True)
        ck.check(sim.control_state() == 0x0,
                 "relay: PA2/PA3 coils finish parked low")


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
    variant = resolve_variant()
    if variant is None:
        return 2
    print("SIM START: fw=%s  variant=%s  F_CPU=%d Hz"
          % (elf, variant, S.F_CPU_HZ))

    ck = Checker()
    test_control_outputs(elf, variant, ck)
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
