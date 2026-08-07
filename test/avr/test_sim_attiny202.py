#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
#
# test_sim_attiny202.py -- ATtiny202 (AVR-XT) register-level FUNCTIONAL test on
# a patched yasimavr. The AVR-XT analogue of the AVR-Classic simavr functional
# test (test/avr/test_sim.c) and the PIC gpsim toggle test (pic10f322-test-gpsim):
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
import test_attiny202_delay_oracle as Delay

# Hold times: comfortably past the debounce thresholds (8 ms press, 25 ms
# release) so a press/release is unambiguously registered.
PRESS_HOLD_MS = 20
RELEASE_HOLD_MS = 40
SETTLE_MS = 50
IDLE_STABILITY_MS = 250     # idle soak for the sanity-gate / no-spurious-reset check
N_TOGGLES = 6

# Physical output tracing free-runs and captures every PA2/PA3 edge from a
# signal hook (sim_attiny202.PinEdgeRecorder), so even a one-cycle wrong
# ordering or dual-coil state is observable, and each transition carries its
# exact cycle. This driver asserts pulse ORDERING/POLARITY/exclusion and the
# DELIVERED width; the absolute design width stays owned by the compiled-image
# oracle test_attiny202_delay_oracle.py -- see check_pulse_width().
OUTPUT_TRACE_MS = 30

# Coil-pulse width band, as a fraction above and (via the oracle's tolerance)
# below the design width. The lower edge reuses the delay oracle's compile
# rounding tolerance, because avr-libc emits e.g. a 5999-iteration loop for
# 12 ms, i.e. 11.998 ms. The upper edge allows for tick-ISR preemption: the 1 ms
# TCB0 ISR interrupts the busy loop for roughly 110 cycles a tick, about 5.5% of
# elapsed time whatever the pulse length (measured: relay 12.014 ms during
# startup, before sei(), through 12.669 ms once ticking; muted x4053 5.279 ms).
# 10% therefore allows nearly twice the observed preemption overhead -- 1.2 ms
# against 0.67 ms on the relay coil, 0.5 ms against 0.28 ms on the mute window
# -- while still rejecting a half-width or double-width pulse.
PULSE_PREEMPTION_MARGIN = 0.10

VARIANTS = ("cd4053_simple", "cd4053_with_mute", "tq2_l2_5v_relay")


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
    """Free-run for `milliseconds` and fold the recorded PA2/PA3 edges into a
    transition trace.

    Edges arrive from a signal hook, so every transition is captured with its
    exact cycle however briefly it lasts, and the simulation advances in one
    millisecond-scale budget instead of being stepped a cycle at a time. Edges
    sharing a cycle -- one instruction changing both control pins -- are folded
    together before the combined state is judged, so a single write can never
    fabricate an intermediate state the hardware never presented.
    """
    recorder = sim.control_edges()
    trace = OutputTrace(name)
    levels = list(sim.control_levels())
    previous = state_from_levels(levels)
    trace.unsafe_before_config = previous is None and 1 in levels
    if previous is not None:
        trace.configured = True
        trace.initial_state = previous
        trace.saw_both_high = previous == 0x3

    sim.run_ms(milliseconds)
    # SimLoop.run() pins its cycle counter to first_cycle + budget even when the
    # device halts early, so a cycle delta cannot witness a stall. The device
    # reaching its terminal Done state is the condition that actually means the
    # simulation stopped advancing.
    trace.stalled = sim.is_done()

    events = recorder.drain()
    index = 0
    while index < len(events):
        cycle = events[index][0]
        while index < len(events) and events[index][0] == cycle:
            _cycle, pin_index, level = events[index]
            levels[pin_index] = level
            index += 1
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
            trace.transitions.append((cycle, state))
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


def design_pulse_ms(variant):
    """The single coil-pulse width `variant` is designed to drive, in ms.

    Read from the delay oracle's table so the design width has one definition in
    the tree. Every variant that pulses at all drives the same width on both the
    engage and the bypass path; a table that stopped being uniform would make
    taking the first entry silently wrong, so that is checked rather than
    assumed. Callers must not ask about a variant with no pulse at all.
    """
    widths = Delay.EXPECTED_WIDTHS_MS[variant]
    if not widths or any(width != widths[0] for width in widths):
        sys.stderr.write("ERROR: %s has no single design pulse width (%r).\n"
                         % (variant, widths))
        sys.exit(2)
    return widths[0]


def check_pulse_width(ck, trace, pulse_state, design_ms):
    """Assert a COMPLETE pulse of `pulse_state` -- an edge into it and an edge
    back out -- and that the width it held falls inside the design band.

    The width is measured from exact transition cycles, which the signal-hook
    tracer timestamps as the edges happen while the simulation free-runs.

    This is a cross-check on, not a replacement for,
    test_attiny202_delay_oracle.py. That oracle reads the compiled _delay_ms
    loop count straight out of the image: simulator-independent, resolved to a
    few loop iterations, and it remains what pins the ABSOLUTE width. What this
    check adds is the DELIVERED width -- what the pin actually held once the
    1 ms tick ISR has preempted the busy loop -- which a compile-time count
    structurally cannot show. Its lower edge also subsumes the relay's 4 ms
    datasheet coil minimum, which the oracle asserts directly.
    """
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

    width_ms = (end - start) * 1000.0 / S.F_CPU_HZ
    lowest = design_ms - Delay.WIDTH_TOLERANCE_MS
    highest = design_ms * (1.0 + PULSE_PREEMPTION_MARGIN)
    ck.check(lowest <= width_ms <= highest,
             "%s: state 0x%X pulse held %.3f ms, within [%.3f, %.3f] ms of the "
             "%g ms design width"
             % (trace.name, pulse_state, width_ms, lowest, highest, design_ms))


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

    if variant == "cd4053_simple":
        check_trace(ck, startup, [])
        check_trace(ck, engage, [0x1])
        check_trace(ck, bypass, [0x0])
        ck.check(sim.control_state() == 0x0,
                 "simple x4053: PA2 low and spare PA3 parked low in BYPASS")
    elif variant == "cd4053_with_mute":
        mute_ms = design_pulse_ms(variant)
        check_trace(ck, startup, [])
        check_trace(ck, engage, [0x2, 0x3])
        check_trace(ck, bypass, [0x2, 0x0])
        check_pulse_width(ck, engage, 0x2, mute_ms)
        check_pulse_width(ck, bypass, 0x2, mute_ms)
        ck.check(sim.control_state() == 0x0,
                 "muted x4053: PA2/PA3 finish at BYPASS 0x0")
    else:
        coil_ms = design_pulse_ms(variant)
        check_trace(ck, startup, [0x1, 0x0])
        check_trace(ck, engage, [0x2, 0x0])
        check_trace(ck, bypass, [0x1, 0x0])
        for trace in (startup, engage, release_one, bypass, release_two):
            ck.check(not trace.saw_both_high,
                     "%s: relay coils were never both high" % trace.name)
        check_pulse_width(ck, startup, 0x1, coil_ms)
        check_pulse_width(ck, engage, 0x2, coil_ms)
        check_pulse_width(ck, bypass, 0x1, coil_ms)
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
    ck.check(sim.read_ioreg(S.REG_PORTA_DIR) == S.PORTA_DIR_EXPECTED,
             "boot: PORTA.DIR == exact 0x%02X" % S.PORTA_DIR_EXPECTED)
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
