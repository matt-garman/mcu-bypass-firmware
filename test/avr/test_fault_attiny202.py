#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
#
# test_fault_attiny202.py -- ATtiny202 (AVR-XT) critical-SFR / state
# fault-injection test on a patched yasimavr. The AVR-XT analogue of the PIC
# libgpsim fault test (test/pic/test_fault_pic.cc / pic-test-fault) and the AVR
# simavr inject_config_sfr cases (test/avr/test_sim.c): corrupt a value the shell
# guards and assert the firmware CATCHES it and forces recovery. It is the mirror
# image of the soak test -- there a reset is a FAILURE, here it is the PASS.
#
# The shell has TWO independent protection mechanisms, and a corruption is caught
# by whichever applies, so each case asserts the appropriate signal:
#
#   GATE  -- config/state the per-tick sanity gate re-reads while the tick is
#            still alive to wake the CPU (clock prescaler, footswitch pull-up,
#            the debounce context). Corruption -> the gate diverts to the
#            force-reset spin, which yasimavr reports as the CPU halting
#            (SimLoop.State.Done) parked on the 0xCFFF jump-to-self. Fast (~1 ms,
#            the next tick).
#
#   LIVE  -- the tick timer itself (TCB0). Disabling it removes the CPU's wake
#            source, so the sanity gate can no longer run; the watchdog instead
#            catches the lost liveness and resets after its ~250 ms period, which
#            re-runs init() and restores the register. (Depending on whether the
#            CPU was awake at the instant of injection, a TCB0 corruption may
#            instead be caught immediately by the gate -- so a LIVE case passes on
#            EITHER signal.)
#
# yasimavr cannot show the watchdog completing the reset OUT OF the force-reset
# spin: an interrupts-off infinite loop is a terminal halt (State.Done) and the
# loop stops before the ~250 ms WDT fires. That last step is a hardware
# guarantee, out of the simulator's scope; the GATE signal above asserts the
# firmware behaviour that leads into it. (The LIVE path resets from SLEEP, which
# the simulator DOES advance through, so there the reset is directly observed.)
#
# Usage:   python3 test_fault_attiny202.py <firmware.elf>
# Exit:    0 = PASS, 1 = a case failed, 2 = bad invocation / missing image.

import sys

import sim_attiny202 as S

SETTLE_MS = 40           # run to steady state before injecting
GATE_MS = 8              # a few ticks: the gate runs every 1 ms tick
LIVE_MS = 650            # > 2x the ~250 ms WDT period, plus injection-phase slack
NEG_CONTROL_MS = 60      # no-corruption window (< WDT period; must stay healthy)
LIVE_STEP_MS = 5

REG = "reg"              # I/O register  (write_ioreg)
RAM = "ram"              # SRAM byte     (write_ram, addr resolved per variant)
GATE = "gate"            # expected mechanism: per-tick sanity gate
LIVE = "live"            # expected mechanism: WDT liveness (or the gate)


def _fault_cases(sim):
    """(name, kind, addr, corrupt_value, mechanism) for each guarded value.

    SRAM addresses come from the resolved symbols on `sim`; I/O addresses are the
    datasheet constants in sim_attiny202. Each corrupt_value unambiguously
    violates what the firmware expects."""
    return [
        # --- caught by the per-tick sanity gate (tick stays alive) ---
        ("CLKCTRL.MCLKCTRLB",     REG, S.REG_CLKCTRL_MCLKCTRLB, 0x00, GATE),
        ("PORTA.PIN7CTRL(pullup)", REG, S.REG_PORTA_PIN7CTRL,   0x00, GATE),
        ("ctx_.program_state",    RAM, sim.addr_ctx + 0,        0xFF, GATE),
        ("ctx_.effect_state",     RAM, sim.addr_ctx + 1,        0xFF, GATE),
        ("ctx_.debounce_counter", RAM, sim.addr_ctx + 2,        0xFF, GATE),
        # --- caught by WDT liveness (disabling the tick kills the wake source) ---
        ("TCB0.CTRLA(tick)",      REG, S.REG_TCB0_CTRLA,        0x00, LIVE),
        ("TCB0.INTCTRL(tick)",    REG, S.REG_TCB0_INTCTRL,      0x00, LIVE),
    ]


class Checker:
    def __init__(self):
        self.fails = 0
        self.skips = 0

    def result(self, ok, msg, skipped=False):
        if skipped:
            self.skips += 1
            tag = "SKIP"
            stream = sys.stdout
        elif ok:
            tag = "OK  "
            stream = sys.stdout
        else:
            tag = "FAIL"
            stream = sys.stderr
            self.fails += 1
        stream.write("[fault] %s  %s\n" % (tag, msg))
        stream.flush()


def _inject(sim, kind, addr, value):
    """Write the corrupt value and confirm it stuck. Returns False when the
    write was rejected or re-latched (hardware-locked or double-buffered
    registers) -- such faults cannot be injected in the simulator."""
    if kind == REG:
        sim.write_ioreg(addr, value)
        return sim.read_ioreg(addr) == value
    sim.write_ram(addr, [value])
    return sim.read_ram(addr, 1)[0] == value


def _run_case(elf, name, kind, addr, corrupt, mech, ck):
    sim = S.Sim(elf)
    sim.run_ms(SETTLE_MS)
    if sim.in_force_reset():
        ck.result(False, "%s: device already force-reset before injection" % name)
        return

    healthy = sim.read_ioreg(addr) if kind == REG else sim.read_ram(addr, 1)[0]
    if not _inject(sim, kind, addr, corrupt):
        ck.result(True, "%s: not injectable in sim (write rejected/re-latched)"
                        % name, skipped=True)
        return

    if mech == GATE:
        at = sim.run_until_force_reset(GATE_MS)
        ck.result(at is not None,
                  "%s corrupted -> gate forced reset%s" % (name,
                  (" (+%d ms)" % at) if at is not None
                  else " NOT detected within %d ms" % GATE_MS))
        return

    # LIVE: caught by the gate (fast Done@trap) OR by the WDT (reset restores the
    # register from SLEEP). Step until either is observed or the window elapses.
    elapsed = 0
    while elapsed < LIVE_MS:
        if sim.in_force_reset():
            ck.result(True, "%s corrupted -> gate forced reset (+%d ms)"
                            % (name, elapsed))
            return
        if sim.read_ioreg(addr) == healthy and healthy != corrupt:
            ck.result(True, "%s corrupted -> WDT reset recovered device (+%d ms)"
                            % (name, elapsed))
            return
        sim.run_ms(LIVE_STEP_MS)
        elapsed += LIVE_STEP_MS
    ck.result(False, "%s corrupted -> NOT caught within %d ms" % (name, LIVE_MS))


def _run_negative_control(elf, ck):
    # No corruption: the firmware must stay healthy -- no force-reset spin over a
    # window shorter than the WDT period. Proves the detectors are not trivially
    # always-true and the gate does not false-trip.
    sim = S.Sim(elf)
    sim.run_ms(SETTLE_MS)
    at = sim.run_until_force_reset(NEG_CONTROL_MS)
    ck.result(at is None,
              "no corruption -> stays healthy over %d ms%s"
              % (NEG_CONTROL_MS, "" if at is None else " (spurious reset at +%d ms!)" % at))


def main(argv):
    elf = S.resolve_elf(argv[1] if len(argv) > 1 else None)
    print("FAULT START: fw=%s  F_CPU=%d Hz" % (elf, S.F_CPU_HZ))

    ck = Checker()
    probe = S.Sim(elf)                 # one instance just to resolve the case list
    for name, kind, addr, corrupt, mech in _fault_cases(probe):
        _run_case(elf, name, kind, addr, corrupt, mech, ck)
    _run_negative_control(elf, ck)

    verdict = "PASS" if ck.fails == 0 else "FAIL"
    print("\nFAULT %s: %d failed, %d skipped." % (verdict, ck.fails, ck.skips))
    return 0 if ck.fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
