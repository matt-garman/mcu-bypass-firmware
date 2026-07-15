#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
#
# test_fault_attiny202.py -- ATtiny202 (AVR-XT) critical-SFR / latch / state
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
# Usage:   make attiny202-fault  (supplies the ELF and required production fuses)
# Exit:    0 = PASS, 1 = a case failed, 2 = bad invocation / missing image.
# Completeness: exactly 17 independently pinned injections plus one long healthy
# negative control must finish; any rejected/re-latched injection is a failure.

import sys

import sim_attiny202 as S

SETTLE_MS = 40           # run to steady state before injecting
GATE_MS = 8              # a few ticks: the gate runs every 1 ms tick
LIVE_MS = 650            # > 2x the ~250 ms WDT period, plus injection-phase slack
NEG_CONTROL_MS = 650     # >2x WDT period: healthy firmware must keep petting it
LIVE_STEP_MS = 5
RETRY_GATE_MS = 50
RETRY_GATE_STEP_CYCLES = 137  # coprime with the 2,000-cycle tick
EXPECTED_FAULT_CASES = 17
EXPECTED_TOTAL_RESULTS = EXPECTED_FAULT_CASES + 1  # injections + negative control
RESET_SENTINEL = 0xA5

REG = "reg"              # I/O register        (write_ioreg, one byte)
REG16 = "reg16"          # 16-bit I/O register  (write_ioreg low then high)
RAM = "ram"              # SRAM byte     (write_ram, addr resolved per variant)
GATE = "gate"            # expected mechanism: per-tick sanity gate
LIVE = "live"            # expected mechanism: WDT liveness (or the gate)
RETRY_GATE = "retry_gate"  # phase-swept reinjection for ISR-rewritten state


def _fault_cases(sim):
    """(name, kind, addr, corrupt_value, mechanism) for each injectable guard.

    SRAM addresses come from the resolved symbols on `sim`; I/O addresses are the
    datasheet constants in sim_attiny202. Each corrupt_value unambiguously
    violates what the firmware expects.

    GATE-case corrupt values MUST KEEP THE 1 ms TICK ALIVE. The per-tick gate
    only runs when the TCB0 CAPT interrupt wakes the CPU from IDLE sleep, so a
    corruption that also stops the tick would never let the gate run -- it would
    be caught only by the WDT, ~256 ms later. Hence TCB0.CTRLB is corrupted by
    setting CCMPEN (0x10) while leaving CNTMODE at INT (not e.g. PWM8/0x07, which
    disrupts the tick), and TCB0.CCMP is set to 0x0FFF (a valid running period
    != the expected 1999, not 0x0000, which is degenerate). Corruptions that
    genuinely KILL the tick are the TCB0.CTRLA/INTCTRL LIVE cases below, where
    the WDT is the correct (and only possible) catcher."""
    return [
        # --- caught by the per-tick sanity gate (tick stays alive) ---
        ("CLKCTRL.MCLKCTRLB",     REG,   S.REG_CLKCTRL_MCLKCTRLB, 0x00,   GATE),
        ("PORTA.PIN7CTRL(pullup)", REG,  S.REG_PORTA_PIN7CTRL,    0x00,   GATE),
        ("PORTA.DIR(outputs)",     REG,  S.REG_PORTA_DIR,         0x00,   GATE),
        ("PORTA.DIR(footswitch)",  REG,  S.REG_PORTA_DIR,         0xCE,   GATE),
        ("PORTA.DIR(spare PA6)",   REG,  S.REG_PORTA_DIR,         0x0E,   GATE),
        ("PORTA.OUT(PA1 LED)",     REG,  S.REG_PORTA_OUT,         0x02,   GATE),
        ("PORTA.OUT(PA2 control)", REG,  S.REG_PORTA_OUT,         0x04,   GATE),
        ("PORTA.OUT(PA3 control)", REG,  S.REG_PORTA_OUT,         0x08,   GATE),
        ("PORTA.OUT(PA6 spare)",   REG,  S.REG_PORTA_OUT,         0x40,   GATE),
        ("ctx_.program_state",    RAM,   sim.addr_ctx + 0,        0xFF,   GATE),
        ("ctx_.effect_state",     RAM,   sim.addr_ctx + 1,        0xFF,   GATE),
        ("ctx_.debounce_counter", RAM,   sim.addr_ctx + 2,        0xFF,   GATE),
        ("timer_isr_called_",      RAM,  sim.addr_timer_isr,      0xFF,   RETRY_GATE),
        ("TCB0.CTRLB(mode)",      REG,   S.REG_TCB0_CTRLB,        0x10,   GATE),
        ("TCB0.CCMP(period)",     REG16, S.REG_TCB0_CCMP_L,       0x0FFF, GATE),
        # --- caught by WDT liveness (disabling the tick kills the wake source) ---
        ("TCB0.CTRLA(tick)",      REG,   S.REG_TCB0_CTRLA,        0x00,   LIVE),
        ("TCB0.INTCTRL(tick)",    REG,   S.REG_TCB0_INTCTRL,      0x00,   LIVE),
    ]


class Checker:
    def __init__(self):
        self.fails = 0
        self.skips = 0
        self.results = 0
        self.injections = 0

    def result(self, ok, msg, skipped=False):
        self.results += 1
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

    def injected(self):
        self.injections += 1

    def _completion_failure(self, msg):
        self.fails += 1
        sys.stderr.write("[fault] FAIL  %s\n" % msg)

    def finalize(self, declared_cases):
        if declared_cases != EXPECTED_FAULT_CASES:
            self._completion_failure(
                "fault case list has %d entries; expected exactly %d"
                % (declared_cases, EXPECTED_FAULT_CASES)
            )
        if self.results != EXPECTED_TOTAL_RESULTS:
            self._completion_failure(
                "recorded %d result(s); expected exactly %d"
                % (self.results, EXPECTED_TOTAL_RESULTS)
            )
        if self.injections != EXPECTED_FAULT_CASES:
            self._completion_failure(
                "completed %d injectable fault(s); expected exactly %d"
                % (self.injections, EXPECTED_FAULT_CASES)
            )
        if self.skips != 0:
            self._completion_failure(
                "%d fault injection(s) skipped; authoritative execution must be complete"
                % self.skips
            )


def _inject(sim, kind, addr, value):
    """Write the corrupt value and confirm it stuck. Returns False when the
    write was rejected or re-latched (hardware-locked or double-buffered
    registers) -- such faults cannot be injected in the simulator."""
    if kind == REG:
        sim.write_ioreg(addr, value)
        return sim.read_ioreg(addr) == value
    if kind == REG16:
        # TCB0.CCMP is a 16-bit register accessed through the AVR temp-register
        # protocol: a write to the low byte loads the temp, and only the
        # high-byte write commits {high:temp}; a read of the low byte latches the
        # high byte into the temp, which the high-byte read then returns. So a
        # single-byte poke never commits (it leaves the healthy value), and both
        # halves must be accessed low-then-high. Inject both bytes and confirm
        # the committed 16-bit word by reading them back in the same order.
        sim.write_ioreg(addr, value & 0xFF)
        sim.write_ioreg(addr + 1, (value >> 8) & 0xFF)
        lo = sim.read_ioreg(addr)
        hi = sim.read_ioreg(addr + 1)
        return ((hi << 8) | lo) == value
    sim.write_ram(addr, [value])
    return sim.read_ram(addr, 1)[0] == value


def _run_case(elf, name, kind, addr, corrupt, mech, ck):
    sim = S.Sim(elf)
    sim.run_ms(SETTLE_MS)
    if sim.in_force_reset():
        ck.result(False, "%s: device already force-reset before injection" % name)
        return

    healthy = (sim.read_ioreg(addr) if kind in (REG, REG16)
               else sim.read_ram(addr, 1)[0])
    if mech == LIVE:
        sim.write_ioreg(S.REG_GPR0, RESET_SENTINEL)
        if sim.read_ioreg(S.REG_GPR0) != RESET_SENTINEL:
            ck.result(False, "%s: could not arm reset witness" % name)
            return
    if not _inject(sim, kind, addr, corrupt):
        ck.result(True, "%s: not injectable in sim (write rejected/re-latched)"
                        % name, skipped=True)
        return
    ck.injected()

    if mech == RETRY_GATE:
        elapsed_cycles = 0
        max_cycles = S.F_CPU_HZ * RETRY_GATE_MS // 1000
        while elapsed_cycles < max_cycles:
            if sim.in_force_reset():
                ck.result(True, "%s repeatedly corrupted -> gate forced reset"
                                % name)
                return
            if not _inject(sim, kind, addr, corrupt):
                ck.result(True, "%s: reinjection was rejected/re-latched"
                                % name, skipped=True)
                return
            sim.run_cycles(RETRY_GATE_STEP_CYCLES)
            elapsed_cycles += RETRY_GATE_STEP_CYCLES
        ck.result(False, "%s repeatedly corrupted -> NOT caught within %d ms"
                         % (name, RETRY_GATE_MS))
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
            reset_seen = sim.read_ioreg(S.REG_GPR0) != RESET_SENTINEL
            ck.result(reset_seen,
                      "%s corrupted -> register restored%s (+%d ms)"
                      % (name,
                         " by witnessed WDT reset" if reset_seen
                         else " WITHOUT reset witness",
                         elapsed))
            return
        sim.run_ms(LIVE_STEP_MS)
        elapsed += LIVE_STEP_MS
    ck.result(False, "%s corrupted -> NOT caught within %d ms" % (name, LIVE_MS))


def _run_negative_control(elf, ck):
    # No corruption: stay healthy for >2 watchdog periods. The reset witness
    # proves the WDT is being petted rather than repeatedly resetting a firmware
    # image that happens to look healthy again after each reboot.
    sim = S.Sim(elf)
    sim.run_ms(SETTLE_MS)
    sim.write_ioreg(S.REG_GPR0, RESET_SENTINEL)
    if sim.read_ioreg(S.REG_GPR0) != RESET_SENTINEL:
        ck.result(False, "no corruption: could not arm reset witness")
        return

    elapsed = 0
    failure = None
    while elapsed < NEG_CONTROL_MS:
        sim.run_ms(LIVE_STEP_MS)
        elapsed += LIVE_STEP_MS
        if sim.in_force_reset():
            failure = "entered force-reset spin at +%d ms" % elapsed
            break
        if sim.read_ioreg(S.REG_GPR0) != RESET_SENTINEL:
            failure = "reset witness cleared at +%d ms" % elapsed
            break
        if sim.is_done():
            failure = "simulator stopped at +%d ms" % elapsed
            break
    ck.result(failure is None,
              "no corruption -> healthy for %d ms%s"
              % (NEG_CONTROL_MS, "" if failure is None else " (" + failure + ")"))


def main(argv):
    elf = S.resolve_elf(argv[1] if len(argv) > 1 else None)
    print("FAULT START: fw=%s  F_CPU=%d Hz" % (elf, S.F_CPU_HZ))

    ck = Checker()
    probe = S.Sim(elf)                 # one instance just to resolve the case list
    cases = _fault_cases(probe)
    for name, kind, addr, corrupt, mech in cases:
        _run_case(elf, name, kind, addr, corrupt, mech, ck)
    _run_negative_control(elf, ck)
    ck.finalize(len(cases))

    verdict = "PASS" if ck.fails == 0 else "FAIL"
    print("\nFAULT %s: %d failed, %d skipped, %d/%d injections, %d/%d results."
          % (verdict, ck.fails, ck.skips,
             ck.injections, EXPECTED_FAULT_CASES,
             ck.results, EXPECTED_TOTAL_RESULTS))
    return 0 if ck.fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
