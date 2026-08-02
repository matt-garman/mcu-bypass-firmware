#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
#
# test_lockstep_attiny202.py -- ATtiny202 (AVR-XT) firmware/model LOCK-STEP
# co-simulation on a patched yasimavr.
#
# This is the AVR-XT counterpart of the AVR-Classic lock-step co-sim
# (test_lockstep_cosim() in test/avr/test_sim.c) and the PIC one
# (test/pic/test_lockstep_pic.cc), and it closes the last structural gap between
# the AVR-XT lane and its release-supported peers.
#
# WHAT LOCK-STEP ADDS OVER THE FUNCTIONAL TEST
# --------------------------------------------
# test_sim_attiny202.py asserts the firmware's OBSERVABLE BEHAVIOUR: press the
# footswitch, watch the LED and the PA2/PA3 control lines. That proves the
# outputs are right, but not that they arise from the intended internal
# trajectory -- a firmware that reached the correct LED state by a different
# path through its state machine would pass.
#
# This driver asserts the INTERNAL STATE instead. After every settled 1 ms tick
# it reads the shell's `ctx_` struct straight out of simulated SRAM (three bytes:
# program_state, effect_state, debounce_counter) and requires it to equal, byte
# for byte, the golden model's state after the same tick with the same input.
# The golden model is not a copy of the algorithm: it is src/bypass_pure.c
# itself, reached through test/model_step.h and the ctypes bridge in
# model_step_ffi.py/.c. Firmware and model therefore run the same verified core,
# one in an AVR-XT simulator and one natively, and any divergence in the SHELL
# that drives it -- a mis-sequenced result write-back, a dropped lockout reload,
# an ISR/main handshake race -- shows up as a mismatched byte on the tick it
# happens, not several ticks later as a wrong LED.
#
# TICK BOUNDARIES
# ---------------
# Comparisons are only meaningful at a settled tick boundary, so advance_tick()
# waits for the core to WAKE (the TCB0 CAPT ISR fired) and then to SLEEP again
# (main finished reacting, including any blocking coil pulse inside
# hw_set_*_state()). That is phase- and drift-free: the shell enables no other
# interrupt source, so only the 1 ms tick can wake it.
#
# The footswitch level is held constant across each whole settled tick. That is
# not just convenience -- it is what makes lock-step well-defined across a
# TOGGLE tick. The ISR keeps integrating during the variant's blocking
# actuation pulse (5 ms mute, 12 ms relay), so main sees one tick while the ISR
# samples a dozen. The firmware relies on the counter already sitting at its
# RELEASE_THRESH ceiling after a lockout reload, where further pressed samples
# saturate and change nothing; holding the pin steady keeps the simulated switch
# faithful to that invariant instead of feeding the integrator releases real
# hardware would never see mid-pulse.
#
# Usage:   make attiny202-lockstep  (supplies the ELF, fuses and the model .so)
# Exit:    0 = PASS, 1 = a check failed, 2 = bad invocation / missing image.

import os
import sys

import model_step_ffi
import sim_attiny202 as S

from yasimavr.lib import core as _core

VARIANTS = ("cd4053_simple", "cd4053_with_mute", "tq2_l2_5v_relay")

# Ticks of pseudo-random stimulus. Parity with the classic lock-step's
# SIM_LOCKSTEP_ITERS (5000 full / 1500 fast); overridable from the Makefile.
DEFAULT_ITERS = 5000

# A run that never toggles the effect state agrees with the model trivially, so
# every run asserts it saw at least one toggle. That makes very short runs
# meaningless rather than merely quick: the pressed-at-boot scenario has to
# clear a full RELEASE_THRESH lock-out (25 ticks) before a press can even begin
# to count, and the random hold lengths mean a few dozen ticks can easily
# produce none. Reject such a request up front with an explanation instead of
# letting it surface later as a confusing red toggle-count check.
MIN_ITERS = 200

# Stop after this many divergences: the first one is the finding, the rest are
# usually the same fault echoing. Matches the classic driver's cap.
MAX_MISMATCHES = 5

# One settled tick is ~176 cycles of work inside a 2000-cycle period, but a
# toggle tick also blocks in _delay_ms() for the variant's coil pulse. 50 ms of
# cycles is four times the longest of those (the relay's 12 ms) while still
# catching a genuinely stuck core. The margin also absorbs the upstream
# SimLoop.run() cycle-rewind defect described in the delay oracle's header: the
# 256-cycle probe stride below loses at most one instruction's worth of cycles
# per call (under 2%), which only makes a pulse elapse sooner than the budget,
# never later.
TICK_BUDGET_MS = 50

# Probe granularity while hunting for the wake and sleep edges. The awake window
# is ~176 cycles, so the sleeping-probe stride MUST stay well under that or a
# whole tick could be stepped over unseen -- which would silently desynchronise
# firmware and model. Once awake, overshooting into sleep is harmless (the next
# wake is ~1800 cycles away), so a coarser stride keeps the run fast.
SLEEP_PROBE_CYCLES = 32
AWAKE_PROBE_CYCLES = 256


class Checker:
    def __init__(self):
        self.fails = 0

    def check(self, ok, msg):
        status = "OK  " if ok else "FAIL"
        stream = sys.stdout if ok else sys.stderr
        stream.write("[lockstep] %s  %s\n" % (status, msg))
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


def resolve_iters():
    raw = os.environ.get("ATTINY202_LOCKSTEP_ITERS")
    if not raw:
        return DEFAULT_ITERS
    try:
        value = int(raw, 0)
    except ValueError:
        sys.stderr.write(
            "ERROR: ATTINY202_LOCKSTEP_ITERS must be an integer (got %r).\n" % raw
        )
        return None
    if value < MIN_ITERS:
        sys.stderr.write(
            "ERROR: ATTINY202_LOCKSTEP_ITERS must be >= %d (got %d).\n"
            "  Shorter runs cannot be relied on to toggle the effect state at "
            "all, and a run\n  that never toggles agrees with the model "
            "trivially.\n" % (MIN_ITERS, value)
        )
        return None
    return value


def xorshift32(state):
    """Deterministic PRNG, identical to the classic lock-step's stimulus source,
    so a failing run is exactly reproducible from the seed alone."""
    x = state & 0xFFFFFFFF
    x ^= (x << 13) & 0xFFFFFFFF
    x ^= x >> 17
    x ^= (x << 5) & 0xFFFFFFFF
    return x & 0xFFFFFFFF


def is_sleeping(sim):
    return sim.dev.state() == _core.Device.State.Sleeping


def run_until_first_sleep(sim, budget_ms):
    """Advance from reset until the shell finishes init() and first sleeps.

    init() ends with sei() then the main loop's first pass, and on the relay
    variant it also drives a blocking park pulse, so the first sleep is the
    earliest point at which `ctx_` is settled and comparable."""
    budget = sim.cycles(budget_ms)
    spent = 0
    while spent < budget:
        if is_sleeping(sim):
            return True
        sim.run_cycles(AWAKE_PROBE_CYCLES)
        spent += AWAKE_PROBE_CYCLES
    return is_sleeping(sim)


def advance_tick(sim, pin_low):
    """Advance EXACTLY one settled 1 ms tick, holding the footswitch at
    `pin_low` throughout (see this file's header for why that matters).

    Precondition: the core is asleep between ticks. Returns True when the
    wake -> process -> sleep cycle completed inside the budget, False on a
    stuck or halted core (itself a failure worth reporting)."""
    if pin_low:
        sim.press()
    else:
        sim.release()

    budget = sim.cycles(TICK_BUDGET_MS)
    spent = 0

    # 1. Wait for the tick ISR to wake the core. Small stride: the whole awake
    #    window can be under 200 cycles and must not be stepped over.
    while is_sleeping(sim):
        if spent >= budget or sim.is_done():
            return False
        sim.run_cycles(SLEEP_PROBE_CYCLES)
        spent += SLEEP_PROBE_CYCLES

    # 2. Wait until main has fully reacted and gone back to sleep.
    while not is_sleeping(sim):
        if spent >= budget or sim.is_done():
            return False
        sim.run_cycles(AWAKE_PROBE_CYCLES)
        spent += AWAKE_PROBE_CYCLES

    return True


def firmware_context(sim):
    """The shell's `ctx_` as (program_state, effect_state, debounce_counter)."""
    raw = sim.read_ram(sim.addr_ctx, 3)
    return (raw[0], raw[1], raw[2])


def check_context_layout(sim, ck):
    """`ctx_` must be the 3 packed bytes this driver reads.

    debounce_context_t is two enums plus a uint8_t; avr-gcc's -fshort-enums
    makes that 3 bytes, and the shell static_asserts each enum's size. The
    firmware places timer_isr_called_ immediately after it, so the gap between
    the two symbols is an independent, link-time check that nothing repacked
    the struct under the byte offsets used here and by the fault driver."""
    gap = sim.addr_timer_isr - sim.addr_ctx
    return ck.check(
        gap == 3,
        "ctx_ occupies exactly 3 bytes (ctx_=0x%04X, timer_isr_called_=0x%04X, gap=%d)"
        % (sim.addr_ctx, sim.addr_timer_isr, gap),
    )


def expected_control_state(variant, effect_state):
    """Settled PA2/PA3 state (bit0=PA2, bit1=PA3) for a given effect state.

    Mirrors the steady-state expectations test_sim_attiny202.py derives from its
    output traces: the simple x4053 drives PA2 only and parks the spare PA3 low,
    the muted x4053 drives both lines together, and both relay coils are parked
    low between pulses."""
    if variant == "cd4053_simple":
        return effect_state          # PA2 tracks the effect, PA3 stays low
    if variant == "cd4053_with_mute":
        return 0x3 if effect_state else 0x0
    return 0x0                       # relay: coils parked after every pulse


def check_thresholds(model, ck):
    """The harness's own timing constants must equal the firmware's.

    sim_attiny202.py carries PRESSED_THRESH_MS / RELEASE_THRESH_MS for its hold
    times; the model reads the real values out of src/bypass_config.h through
    the FFI, so this catches a config change that the harness did not follow."""
    ck.check(
        model.pressed_thresh == S.PRESSED_THRESH_MS,
        "PRESSED_THRESH: firmware %d == harness %d"
        % (model.pressed_thresh, S.PRESSED_THRESH_MS),
    )
    ck.check(
        model.release_thresh == S.RELEASE_THRESH_MS,
        "RELEASE_THRESH: firmware %d == harness %d"
        % (model.release_thresh, S.RELEASE_THRESH_MS),
    )


def check_anchor(sim, model, ck, label):
    """Firmware and model must already agree before any stimulus is applied."""
    fw = firmware_context(sim)
    return ck.check(
        fw == model.context(),
        "%s anchor: fw(ps=%d es=%d dc=%d) == model(ps=%d es=%d dc=%d)"
        % ((label,) + fw + model.context()),
    )


def run_lockstep(elf, variant, ck, iters, pressed_at_power_on, seed, label):
    """Co-simulate `iters` ticks of pseudo-random footswitch stimulus."""
    sim = S.Sim(elf)
    model = model_step_ffi.Model()

    # The switch level must be established BEFORE the shell samples it in
    # init(), so the power-on-pressed lock-out branch is genuinely exercised.
    if pressed_at_power_on:
        sim.press()

    if not ck.check(run_until_first_sleep(sim, TICK_BUDGET_MS),
                    "%s: shell reached its first idle sleep after reset" % label):
        return

    if not check_context_layout(sim, ck):
        return

    check_thresholds(model, ck)

    model.init(pressed_at_power_on)
    if not check_anchor(sim, model, ck, label):
        return

    rng = seed
    ticks = 0
    toggles = 0
    mismatches = 0

    # Outer loop picks a level and a hold length; holds run past PRESSED_THRESH
    # (toggle) and RELEASE_THRESH (full re-arm), so press, lock-out, release and
    # re-arm are all exercised in lock-step rather than only the easy paths.
    while ticks < iters and mismatches < MAX_MISMATCHES:
        rng = xorshift32(rng)
        pin_low = (rng & 0xFF) < 128        # ~50% pressed
        rng = xorshift32(rng)
        hold = 1 + (rng % 30)               # up to 30 ticks at that level

        for _ in range(hold):
            if ticks >= iters or mismatches >= MAX_MISMATCHES:
                break

            if not advance_tick(sim, pin_low):
                ck.check(False,
                         "%s: firmware failed to complete tick %d "
                         "(stuck or halted core)" % (label, ticks))
                return

            if model.step(pin_low):
                toggles += 1
            ticks += 1

            fw = firmware_context(sim)
            if fw != model.context():
                mismatches += 1
                ck.check(False,
                         "%s: divergence at tick %d (pressed=%d): "
                         "fw(ps=%d es=%d dc=%d) != model(ps=%d es=%d dc=%d)"
                         % ((label, ticks, int(pin_low)) + fw + model.context()))
                continue

            # The LED is the effect state made visible: it must agree on every
            # settled tick, in every variant.
            if sim.led_on() != bool(model.effect_state):
                mismatches += 1
                ck.check(False,
                         "%s: LED (%s) disagrees with model effect_state=%d "
                         "at tick %d" % (label, "on" if sim.led_on() else "off",
                                         model.effect_state, ticks))
                continue

            want_ctl = expected_control_state(variant, model.effect_state)
            got_ctl = sim.control_state()
            if got_ctl != want_ctl:
                mismatches += 1
                ck.check(False,
                         "%s: PA2/PA3 settled state 0x%X != expected 0x%X for "
                         "effect_state=%d at tick %d"
                         % (label, -1 if got_ctl is None else got_ctl,
                            want_ctl, model.effect_state, ticks))

    ck.check(mismatches == 0,
             "%s: co-simulated %d tick(s), %d divergence(s)"
             % (label, ticks, mismatches))

    # A run that never toggled would agree trivially. Require the stimulus to
    # have actually driven state changes, so a passing run is meaningful.
    ck.check(toggles > 0,
             "%s: stimulus produced %d effect-state toggle(s) over %d tick(s)"
             % (label, toggles, ticks))


def main(argv):
    elf = S.resolve_elf(argv[1] if len(argv) > 1 else None)
    variant = resolve_variant()
    if variant is None:
        return 2
    iters = resolve_iters()
    if iters is None:
        return 2

    try:
        # Load once up front so a missing or stale shared object fails before
        # any simulation time is spent.
        probe = model_step_ffi.Model()
    except model_step_ffi.ModelFFIError as exc:
        sys.stderr.write("ERROR: %s\n" % exc)
        return 2

    print("LOCKSTEP START: fw=%s  variant=%s  ticks=%d  model=%s"
          % (elf, variant, iters, probe.lib_path))

    ck = Checker()
    # Released at power-on: the ordinary path.
    run_lockstep(elf, variant, ck, iters, False, 0xC051A1ED, "released-at-boot")
    # Held at power-on: the shell starts in the lock-out branch, so this
    # co-simulates debounce_init_context()'s other outcome from tick one.
    run_lockstep(elf, variant, ck, iters, True, 0x5EED1A7E, "pressed-at-boot")

    verdict = "PASS" if ck.fails == 0 else "FAIL"
    print("\nLOCKSTEP %s: %d check(s) failed." % (verdict, ck.fails))
    return 0 if ck.fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
