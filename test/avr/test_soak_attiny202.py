#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
#
# test_soak_attiny202.py -- ATtiny202 (AVR-XT) long-duration soak on a patched
# yasimavr. The AVR-XT analogue of the AVR-classic soak (test/avr/test_soak.c)
# and the PIC libgpsim soak (test/pic/test_soak_pic.cc): drive the REAL built
# image for a long stretch of SIMULATED time and assert two liveness properties
# hold the entire way -- (1) the watchdog never resets the device (the shell
# keeps petting it) and the sanity gate never force-resets, and (2) the firmware
# stays responsive (a periodic 2-press round-trip still toggles the LED and
# returns it to its starting state). The mirror image of the fault test: here a
# reset is a FAILURE.
#
# Failures are NON-FATAL and logged; the run continues the full duration and
# reports a cumulative count (parity with the PIC/AVR soaks) -- except a
# force-reset spin, which halts the simulator (SimLoop.State.Done) and cannot be
# run past, so that is reported and ends the run.
#
# RESET WITNESS: yasimavr clears the general-purpose register GPR0 on any device
# reset and the firmware never writes it, so a 0xAA sentinel placed there after
# the power-on settle stays 0xAA unless a reset (watchdog timeout or otherwise)
# re-inits the device. Each liveness sample checks it, counts any clear as an
# unexpected reset, and re-arms. (RSTFR is unusable -- the shell clears it at
# boot.) The run uses SimLoop fast mode so simulated time advances as fast as the
# host allows (~200x real time), not throttled to the 2 MHz clock.
#
# SOAK CLOCK: the duration and the liveness schedule are measured on a soak clock
# that advances with the noise/idle stepping but NOT with the time a liveness
# round-trip itself consumes. That is the AVR-classic soak's semantics (its loop
# counter `t` advances one per stimulus millisecond while soak_liveness_check()
# runs "outside" it), and matching it is what makes the liveness-check count come
# out at exactly duration/interval. Scheduling on raw simulated time instead
# would let each round-trip's ~120 ms eat into the schedule -- harmless over an
# hour, but at the release's 24 h it silently drops the last two or three checks
# and the exact release contract below would reject an otherwise perfect run.
# Failure messages still timestamp with true simulated time.
#
# RELEASE CONTRACT: on completion this prints one `SOAK_RESULT format=1 ...`
# record, byte-identical in shape to the ones test/avr/test_soak.c and
# test/pic/test_soak_pic.cc emit, plus a `SOAK PASS: <duration> ms ...` line.
# scripts/make-release.sh matches BOTH exactly before it will accept this
# combination's evidence, so the three substrates' soaks are interchangeable to
# the release orchestrator rather than each needing bespoke parsing.
#
# Config via environment (the Makefile passes these from XT_SOAK_* variables):
#   ATTINY202_SOAK_DURATION_MS          total simulated time      (default 1 h)
#   ATTINY202_SOAK_LIVENESS_INTERVAL_MS between responsiveness checks (default 60 s)
#   ATTINY202_SOAK_PROGRESS_INTERVAL_MS between progress lines     (default 10 min)
#   ATTINY202_SOAK_COMBINATION_NAME     name bound into SOAK_RESULT (default attiny202)
#
# Usage:   make attiny202-soak  (supplies the ELF and required production fuses)
# Exit:    0 = PASS, 1 = one or more liveness failures, 2 = bad invocation.

import os
import sys
import time

import sim_attiny202 as S

SETTLE_MS = 50
SENTINEL = 0xAA
# Press/release holds: comfortably past the debounce thresholds. Unlike the PIC
# soak, no blocking-actuation term is needed -- the AVR-XT integrates in the TCB0
# ISR, which keeps counting through a relay/mute actuation, so no ticks are stolen.
PRESS_HOLD_MS = 20
RELEASE_HOLD_MS = 40
# Advance granularity: check the reset witness at least this often (sim ms).
CHECK_CHUNK_MS = 1000


def _env_ms(name, default, maximum):
    raw = os.environ.get(name, str(default))
    if not raw or any(ch < "0" or ch > "9" for ch in raw):
        raise ValueError("%s must be a positive base-10 integer" % name)
    value = int(raw)
    if value < 1 or value > maximum:
        raise ValueError("%s must be in [1, %d]" % (name, maximum))
    return value


def _env_name(name, default):
    """Combination label bound into the SOAK_RESULT record.

    Kept to the same character class the release orchestrator's exact-match
    comparison can round-trip safely: a stray space would split the record's
    key=value fields and turn a passing soak into an unparseable one."""
    raw = os.environ.get(name, default)
    if not raw or any(ch not in
                      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
                      "0123456789_-" for ch in raw):
        raise ValueError("%s must be non-empty [A-Za-z0-9_-]" % name)
    return raw


class Soak:
    def __init__(self, elf, combination):
        self.sim = S.Sim(elf)
        self.sim.loop.set_fast_mode(True)
        self.combination = combination
        self.checks = 0
        self.liveness_checks = 0
        self.failures = 0
        self.resets = 0
        self.liveness_fails = 0
        # Soak-clock bookkeeping (see the header): raw simulated ms at the point
        # the timed run begins, and the simulated ms consumed by liveness
        # round-trips, which the schedule must not be charged for.
        self.clock_base_ms = 0
        self.liveness_ms_consumed = 0

    # --- reporting ---------------------------------------------------------
    def _elapsed_ms(self):
        return (self.sim.loop.cycle() * 1000) // self.sim.f_cpu

    def _clock_ms(self):
        """Soak time: simulated ms since the run began, excluding the time the
        liveness round-trips themselves consumed."""
        return self._elapsed_ms() - self.clock_base_ms - self.liveness_ms_consumed

    def _fail(self, msg):
        self.failures += 1
        sys.stderr.write("SOAK FAIL [%.4f h]: %s\n"
                         % (self._elapsed_ms() / 3600000.0, msg))
        sys.stderr.flush()

    # --- reset witness -----------------------------------------------------
    def _arm(self):
        self.sim.write_ioreg(S.REG_GPR0, SENTINEL)

    def _check_reset(self):
        self.checks += 1
        if self.sim.read_ioreg(S.REG_GPR0) != SENTINEL:
            self.resets += 1
            self._fail("unexpected device reset (witness cleared; cumulative: %d)"
                       % self.resets)
            self._arm()          # re-arm to catch further resets

    # --- responsiveness ----------------------------------------------------
    def _press_release(self):
        self.sim.press()
        self.sim.run_ms(PRESS_HOLD_MS)
        self.sim.release()
        self.sim.run_ms(RELEASE_HOLD_MS)

    def _liveness_check(self):
        # Two press/release cycles: the LED must toggle away from its start state
        # and back. Proves the debounce path is still alive and the effect still
        # engages/disengages.
        #
        # The simulated time this consumes is billed to liveness_ms_consumed, not
        # to the soak clock, so the schedule stays on its nominal grid.
        started = self._elapsed_ms()
        self.checks += 1
        self.liveness_checks += 1
        led0 = self.sim.led_on()
        self._press_release()
        after1 = self.sim.led_on()
        self._press_release()
        after2 = self.sim.led_on()
        self.liveness_ms_consumed += self._elapsed_ms() - started
        if not (after1 == (not led0) and after2 == led0):
            self.liveness_fails += 1
            self._fail("responsiveness: LED %d ->(press)-> %d ->(press)-> %d "
                       "(want %d,%d,%d)"
                       % (led0, after1, after2, led0, (not led0), led0))

    # --- main loop ---------------------------------------------------------
    def run(self, duration_ms, liveness_ms, progress_ms):
        wall0 = time.time()
        self.sim.run_ms(SETTLE_MS)
        if self.sim.is_done():
            self._fail("device force-reset during power-on settle")
            return self._verdict(duration_ms, liveness_ms, wall0)
        self._arm()
        # The power-on settle is bring-up, not soak time: start the clock here so
        # the schedule below runs on a clean nominal grid.
        self.clock_base_ms = self._elapsed_ms()

        next_live = liveness_ms
        next_prog = progress_ms
        while self._clock_ms() < duration_ms:
            target = min(next_live, next_prog, duration_ms)
            while self._clock_ms() < target:
                step = min(CHECK_CHUNK_MS, target - self._clock_ms())
                self.sim.run_ms(step)
                if self.sim.is_done():
                    # The shell force-reset (sanity-gate trap). The simulator
                    # halts here and cannot be run past -- report and stop.
                    self._fail("shell entered force-reset spin (State.Done @ trap)")
                    return self._verdict(duration_ms, liveness_ms, wall0)
                self._check_reset()

            now = self._clock_ms()
            if now >= next_live:
                self._liveness_check()
                next_live += liveness_ms
            if now >= next_prog:
                self._progress(now, wall0)
                next_prog += progress_ms

        return self._verdict(duration_ms, liveness_ms, wall0)

    def _progress(self, now_ms, wall0):
        print("SOAK [%.2f/%.2f h] checks=%d fails=%d resets=%d  (%.1fs wall)"
              % (now_ms / 3600000.0, self._dur_h, self.checks, self.failures,
                 self.resets, time.time() - wall0))
        sys.stdout.flush()

    def _verdict(self, duration_ms, liveness_ms, wall0):
        ok = self.failures == 0
        # Human summary. The leading "SOAK PASS: <duration> ms " is load-bearing:
        # the release orchestrator greps for exactly that prefix, as it does for
        # both peer soaks.
        print("\nSOAK %s: %d ms (%.2f h) simulated. resets=%d liveness_fails=%d "
              "checks=%d witness_checks=%d in %.1fs wall."
              % ("PASS" if ok else "FAIL", duration_ms, duration_ms / 3600000.0,
                 self.resets, self.liveness_fails, self.liveness_checks,
                 self.checks - self.liveness_checks, time.time() - wall0))
        # Machine record -- the shared release contract. `checks` is the LIVENESS
        # check count (what the peers report and what the orchestrator derives
        # independently as duration/interval), not this driver's finer-grained
        # reset-witness sampling, which is reported separately above.
        print("SOAK_RESULT format=1 status=%s combination=%s duration_ms=%d"
              " liveness_interval_ms=%d checks=%d failures=%d"
              " watchdog_failures=%d liveness_failures=%d"
              % ("pass" if ok else "fail", self.combination, duration_ms,
                 liveness_ms, self.liveness_checks, self.failures,
                 self.resets, self.liveness_fails))
        sys.stdout.flush()
        return 0 if ok else 1


def main(argv):
    try:
        duration = _env_ms("ATTINY202_SOAK_DURATION_MS", 3600000,
                           0xFFFFFFFE)                                  # 1 h
        liveness = _env_ms("ATTINY202_SOAK_LIVENESS_INTERVAL_MS", 60000,
                           0xFFFFFFFF)                                  # 60 s
        progress = _env_ms("ATTINY202_SOAK_PROGRESS_INTERVAL_MS", 600000,
                           0xFFFFFFFF)                                  # 10 min
        combination = _env_name("ATTINY202_SOAK_COMBINATION_NAME", "attiny202")
    except ValueError as exc:
        sys.stderr.write("FATAL: %s\n" % exc)
        return 2

    # The peers static_assert this; here it is a runtime guard with the same
    # intent -- an interval longer than the run would report zero liveness checks
    # against an expected count the orchestrator derives as duration/interval.
    if liveness > duration:
        sys.stderr.write("FATAL: ATTINY202_SOAK_LIVENESS_INTERVAL_MS (%d) must "
                         "not exceed ATTINY202_SOAK_DURATION_MS (%d)\n"
                         % (liveness, duration))
        return 2

    elf = S.resolve_elf(argv[1] if len(argv) > 1 else None)

    print("SOAK START: fw=%s  combination=%s  F_CPU=%d Hz  duration=%.2f h  "
          "liveness=%ds  progress=%ds"
          % (elf, combination, S.F_CPU_HZ, duration / 3600000.0,
             liveness // 1000, progress // 1000))
    soak = Soak(elf, combination)
    soak._dur_h = duration / 3600000.0
    return soak.run(duration, liveness, progress)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
