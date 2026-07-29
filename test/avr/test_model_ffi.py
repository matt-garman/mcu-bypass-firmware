#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
#
# test_model_ffi.py -- host regression for the golden-model ctypes bridge
# (model_step_ffi.c / model_step_ffi.py) used by the ATtiny202 lock-step driver.
#
# WHY IT IS SEPARATE FROM THE LOCK-STEP RUN
# -----------------------------------------
# `make attiny202-lockstep` needs the vendored ATtiny_DFP and the patched
# yasimavr venv, and SKIPS CLEANLY without them. That is the right behaviour for
# a simulator gate, but it means the bridge itself -- the only path by which the
# AVR-XT harness reaches the shipping debounce core -- would have no coverage at
# all on a host that lacks those tools. This test needs neither: just HOSTCC and
# the shared object, so it runs as a hard gate inside `make test`.
#
# WHAT IT ASSERTS THAT LOCK-STEP CANNOT
# -------------------------------------
# Lock-step compares the firmware against this same model, so a mutation to
# src/bypass_pure.c mutates BOTH sides and they keep agreeing -- the classic
# harness makes exactly this point in test_sim.c's test_minimum_press_toggles()
# comment. The checks below are therefore INDEPENDENT hard-coded expectations
# about what the debounce algorithm must do, plus a threshold cross-check read
# straight out of src/bypass_config.h rather than through the library. Together
# they break that symmetry: a core whose thresholds, saturation bounds or
# lock-out behaviour changed fails here even though lock-step would stay green.
#
# Usage:   make test-attiny202-model-ffi
# Exit:    0 = PASS, 1 = a check failed, 2 = bad invocation / missing library.

import os
import re
import sys

import model_step_ffi

# Enum values from src/bypass_types.h. Duplicated deliberately and minimally:
# these two-value enums are a stable part of the firmware's published state, and
# hard-coding them is what makes the init assertions below independent.
PRESS_DEBOUNCE_WAIT = 0
RELEASE_DEBOUNCE_WAIT = 1
BYPASS = 0
ENGAGED = 1

CONFIG_HEADER = os.path.join("src", "bypass_config.h")


class Checker:
    def __init__(self):
        self.fails = 0

    def check(self, ok, msg):
        status = "OK  " if ok else "FAIL"
        stream = sys.stdout if ok else sys.stderr
        stream.write("[model-ffi] %s  %s\n" % (status, msg))
        stream.flush()
        if not ok:
            self.fails += 1
        return ok


def parse_config_thresholds(path):
    """Read PRESSED_THRESH / RELEASE_THRESH straight out of the firmware config.

    An independent read of the same source of truth the library compiles
    against, so a threshold change that the C shim silently stopped exporting
    (or exported from the wrong place) is caught rather than confirmed."""
    try:
        with open(path) as handle:
            text = handle.read()
    except OSError as exc:
        sys.stderr.write("ERROR: could not read %s (%s)\n" % (path, exc))
        return None

    found = {}
    for name in ("PRESSED_THRESH", "RELEASE_THRESH"):
        match = re.search(
            r"^\s*#\s*define\s+%s\s*\(\s*(\d+)\s*U?\s*\)" % name, text, re.M
        )
        if not match:
            sys.stderr.write(
                "ERROR: could not find #define %s in %s\n" % (name, path)
            )
            return None
        found[name] = int(match.group(1))
    return found


def test_thresholds(model, ck, config):
    ck.check(model.pressed_thresh == config["PRESSED_THRESH"],
             "PRESSED_THRESH: library %d == %s %d"
             % (model.pressed_thresh, CONFIG_HEADER, config["PRESSED_THRESH"]))
    ck.check(model.release_thresh == config["RELEASE_THRESH"],
             "RELEASE_THRESH: library %d == %s %d"
             % (model.release_thresh, CONFIG_HEADER, config["RELEASE_THRESH"]))
    # The asymmetric-debounce design depends on the release threshold being the
    # larger of the two; it is also the counter's saturation ceiling.
    ck.check(model.release_thresh > model.pressed_thresh,
             "RELEASE_THRESH (%d) > PRESSED_THRESH (%d)"
             % (model.release_thresh, model.pressed_thresh))


def test_init(model, ck):
    """debounce_init_context()'s two outcomes, stated independently."""
    model.init(pin_low=False)
    ck.check(model.context() == (PRESS_DEBOUNCE_WAIT, BYPASS, 0),
             "init released: %s == (PRESS_WAIT, BYPASS, 0)" % (model.context(),))

    model.init(pin_low=True)
    ck.check(
        model.context() == (RELEASE_DEBOUNCE_WAIT, BYPASS, model.release_thresh),
        "init pressed: %s == (RELEASE_WAIT, BYPASS, RELEASE_THRESH=%d)"
        % (model.context(), model.release_thresh),
    )


def test_minimum_press_toggles(model, ck):
    """Exactly PRESSED_THRESH pressed ticks must toggle -- the firmware tests
    `>=`, not `>`. One tick fewer must not. This is the independent killer for
    an off-by-one in the press threshold, which lock-step cannot see."""
    model.init(pin_low=False)
    toggles = sum(model.step(pin_low=True)
                  for _ in range(model.pressed_thresh - 1))
    ck.check(toggles == 0 and model.effect_state == BYPASS,
             "PRESSED_THRESH-1 = %d ticks must NOT toggle (got %d toggle(s))"
             % (model.pressed_thresh - 1, toggles))

    ck.check(model.step(pin_low=True) and model.effect_state == ENGAGED,
             "the %dth (PRESSED_THRESH) pressed tick toggles to ENGAGED"
             % model.pressed_thresh)


def test_lockout_holds(model, ck):
    """After a toggle the counter is reloaded to RELEASE_THRESH, so holding the
    switch down must never toggle again -- the anti-retrigger lock-out."""
    model.init(pin_low=False)
    for _ in range(model.pressed_thresh):
        model.step(pin_low=True)
    ck.check(model.effect_state == ENGAGED, "lock-out setup: engaged once")

    extra = sum(model.step(pin_low=True) for _ in range(500))
    ck.check(extra == 0,
             "500 further HELD ticks produce no toggle (got %d)" % extra)
    ck.check(model.effect_state == ENGAGED,
             "effect state stays ENGAGED while the switch is held")


def test_counter_saturation(model, ck):
    """The integrator is saturating in both directions: sustained press must
    never exceed RELEASE_THRESH, sustained release must never wrap below 0.
    The upper bound is what keeps lock-step well-defined across the blocking
    coil pulses, and the shell's sanity gate force-resets above it."""
    model.init(pin_low=False)
    high = 0
    for _ in range(1000):
        model.step(pin_low=True)
        high = max(high, model.debounce_counter)
    ck.check(high <= model.release_thresh,
             "sustained press: counter peaked at %d <= RELEASE_THRESH %d"
             % (high, model.release_thresh))

    low = model.release_thresh
    for _ in range(1000):
        model.step(pin_low=False)
        low = min(low, model.debounce_counter)
    ck.check(low == 0,
             "sustained release: counter floors at 0 without wrapping (got %d)"
             % low)


def test_round_trip(model, ck):
    """A full press/release cycle returns to BYPASS: press past the threshold,
    release past RELEASE_THRESH to re-arm, then press again."""
    model.init(pin_low=False)
    for _ in range(model.pressed_thresh):
        model.step(pin_low=True)
    ck.check(model.effect_state == ENGAGED, "round trip: first press engages")

    for _ in range(model.release_thresh + 1):
        model.step(pin_low=False)
    ck.check(model.effect_state == ENGAGED,
             "round trip: releasing does not itself toggle")

    toggles = 0
    for _ in range(model.pressed_thresh):
        toggles += model.step(pin_low=True)
    ck.check(toggles == 1 and model.effect_state == BYPASS,
             "round trip: the re-armed second press returns to BYPASS")


def main():
    try:
        model = model_step_ffi.Model()
    except model_step_ffi.ModelFFIError as exc:
        sys.stderr.write("ERROR: %s\n" % exc)
        return 2

    config = parse_config_thresholds(CONFIG_HEADER)
    if config is None:
        return 2

    print("MODEL-FFI START: lib=%s" % model.lib_path)

    ck = Checker()
    test_thresholds(model, ck, config)
    test_init(model, ck)
    test_minimum_press_toggles(model, ck)
    test_lockout_holds(model, ck)
    test_counter_saturation(model, ck)
    test_round_trip(model, ck)

    verdict = "PASS" if ck.fails == 0 else "FAIL"
    print("\nMODEL-FFI %s: %d check(s) failed." % (verdict, ck.fails))
    return 0 if ck.fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
