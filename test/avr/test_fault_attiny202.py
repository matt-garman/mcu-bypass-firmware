#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
#
# test_fault_attiny202.py -- ATtiny202 (AVR-XT) critical-SFR / latch / state
# fault-injection test on a patched yasimavr. The AVR-XT analogue of the PIC
# libgpsim fault test (test/pic/test_fault_pic.cc / pic10f322-test-fault) and the AVR
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
# Completeness: exactly 24 CD4053 or 32 relay independently pinned injections
# plus one long healthy negative control must finish; any rejected/re-latched
# injection is a failure.

import sys

import sim_attiny202 as S

SETTLE_MS = 40           # run to steady state before injecting
GATE_MS = 8              # a few ticks: the gate runs every 1 ms tick
LIVE_MS = 650            # > 2x the ~250 ms WDT period, plus injection-phase slack
NEG_CONTROL_MS = 650     # >2x WDT period: healthy firmware must keep petting it
LIVE_STEP_MS = 5
RETRY_GATE_MS = 50
RETRY_GATE_STEP_CYCLES = 137  # coprime with the 2,000-cycle tick
# One debounced toggle: the press must outlast PRESSED_THRESH (8 ticks) plus the
# 12 ms blocking actuation, and the release must outlast RELEASE_THRESH (25).
ENGAGE_PRESS_MS = 40
ENGAGE_RELEASE_MS = 80
TRANSACTION_MAX_STEPS = 4_000  # exact-PC search; deliberately not a time budget
# The relay variant carries eight extra cases: six physical-pin configuration
# faults plus delivery of both coil-OUT faults in settled ENGAGED as well as
# BYPASS, covering both directions of the desynchronization hazard.
EXPECTED_FAULT_CASES_CD4053 = 24
EXPECTED_FAULT_CASES_RELAY = 32
RESET_SENTINEL = 0xA5
# Panasonic TQ2-L2-5V minimum coil pulse for guaranteed actuation; the shell
# drives 12 ms. Used only in diagnostics here -- see the RESYNC note below for
# why this substrate cannot measure the recovery pulse.
TQ2_L2_5V_MIN_PULSE_MS = 4

REG = "reg"              # I/O register        (write_ioreg, one byte)
REG16 = "reg16"          # 16-bit I/O register  (write_ioreg low then high)
COIL_STATE = "coil_state"  # relay pin input + stale OUT high + PINnCTRL upset
RAM = "ram"              # SRAM byte     (write_ram, addr resolved per variant)
GATE = "gate"            # expected mechanism: per-tick sanity gate
LIVE = "live"            # expected mechanism: WDT liveness (or the gate)
RETRY_GATE = "retry_gate"  # phase-swept reinjection for ISR-rewritten state
RESYNC = "resync"        # relay coil fault: gate resets, coils de-energized first
RESYNC_ENGAGED = "resync_engaged"  # same, delivered in a settled ENGAGED state
TRANSACTION_ISR = "transaction_isr"    # one post-check persisted-context upset
TRANSACTION_MAIN = "transaction_main"  # one post-check persisted-context upset


def _fault_cases(sim, is_relay):
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
        ("PORTA.PIN1CTRL(INVEN)",  REG,  S.REG_PORTA_PIN1CTRL,    S.PORT_INVEN_bm, GATE),
        ("PORTA.PIN2CTRL(INVEN)",  REG,  S.REG_PORTA_PIN2CTRL,    S.PORT_INVEN_bm,
         RESYNC if is_relay else GATE),
        ("PORTA.PIN3CTRL(INVEN)",  REG,  S.REG_PORTA_PIN3CTRL,    S.PORT_INVEN_bm,
         RESYNC if is_relay else GATE),
        ("PORTA.PIN6CTRL(INVEN)",  REG,  S.REG_PORTA_PIN6CTRL,    S.PORT_INVEN_bm, GATE),
        ("PORTA.PIN7CTRL(INVEN)",  REG,  S.REG_PORTA_PIN7CTRL,
         S.PORT_PULLUPEN_bm | S.PORT_INVEN_bm, GATE),
        ("PORTA.DIR(outputs)",     REG,  S.REG_PORTA_DIR,         0x00,   GATE),
        ("PORTA.DIR(footswitch)",  REG,  S.REG_PORTA_DIR,         0xCE,   GATE),
        ("PORTA.DIR(spare PA6)",   REG,  S.REG_PORTA_DIR,         0x0E,   GATE),
        ("PORTA.OUT(PA1 LED)",     REG,  S.REG_PORTA_OUT,         0x02,   GATE),
        # Relay settled-state case: PA2/PA3 are the coils. An energized coil is
        # a FAULT -- a pulse below the TQ2-L2-5V 4 ms minimum is not proven
        # mechanically harmless, so the firmware cannot know whether the
        # latching relay moved -- and the gate escalates it exactly like any
        # other PORTA.OUT mismatch, after hw_force_wdt_reset() has driven both
        # coils low (see docs/relay_coil_fault_correction.md). This does not
        # inject during the 12 ms pulse; that window is excluded by design.
        # CD4053: PA2/PA3 are control lines, so their upsets reset via the gate
        # with nothing coil-specific to add.
        ("PORTA.OUT(PA2 %s)" % ("RESET-coil" if is_relay else "control"),
                                   REG,  S.REG_PORTA_OUT,         0x04,
                                   RESYNC if is_relay else GATE),
        ("PORTA.OUT(PA3 %s)" % ("SET-coil" if is_relay else "control"),
                                   REG,  S.REG_PORTA_OUT,         0x08,
                                   RESYNC if is_relay else GATE),
        ("PORTA.OUT(PA6 spare)",   REG,  S.REG_PORTA_OUT,         0x40,   GATE),
        ("ctx_.program_state",    RAM,   sim.addr_ctx + 0,        0xFF,   GATE),
        ("ctx_.effect_state",     RAM,   sim.addr_ctx + 1,        0xFF,   GATE),
        ("ctx_.debounce_counter", RAM,   sim.addr_ctx + 2,        0xFF,   GATE),
        # F2 context-SEU: an IN-RANGE flip (0x10 = 16, PRESSED_THRESH <= 16 <=
        # RELEASE_THRESH) the range gate cannot see -- `debounce_counter >
        # RELEASE_THRESH` stays false, so the pre-F2 shell would phantom-toggle.
        # Stop at two transaction seams after their healthy by-value arguments
        # have been captured, then flip persisted bit 4 exactly once. The ISR
        # case covers check-to-integrate; the main case covers check-to-step and
        # publication. Both must finish from the local snapshot.
        ("ctx_.debounce_counter(in-range F2 ISR)", RAM, sim.addr_ctx + 2,
         0x10, TRANSACTION_ISR),
        ("ctx_.debounce_counter(in-range F2 main)", RAM, sim.addr_ctx + 2,
         0x10, TRANSACTION_MAIN),
        ("timer_isr_called_",      RAM,  sim.addr_timer_isr,      0xFF,   RETRY_GATE),
        ("TCB0.CTRLB(mode)",      REG,   S.REG_TCB0_CTRLB,        0x10,   GATE),
        ("TCB0.CCMP(period)",     REG16, S.REG_TCB0_CCMP_L,       0x0FFF, GATE),
        # --- caught by WDT liveness (disabling the tick kills the wake source) ---
        ("TCB0.CTRLA(tick)",      REG,   S.REG_TCB0_CTRLA,        0x00,   LIVE),
        ("TCB0.INTCTRL(tick)",    REG,   S.REG_TCB0_INTCTRL,      0x00,   LIVE),
    ] + ([
        # Relay-only physical-pin faults. PULLUPEN and a one-bit DIR upset each
        # exercise a distinct register state the emergency path must
        # canonicalize.
        # The combined fixtures model a plausible multi-register stale state:
        # first make one pin an input, then leave its OUT latch High and enable
        # PULLUPEN|INVEN. The emergency path must canonicalize the pin itself,
        # not merely clear its OUT latch.
        ("PORTA.PIN2CTRL(PULLUPEN RESET-coil)", REG, S.REG_PORTA_PIN2CTRL,
         S.PORT_PULLUPEN_bm, RESYNC),
        ("PORTA.PIN3CTRL(PULLUPEN SET-coil)", REG, S.REG_PORTA_PIN3CTRL,
         S.PORT_PULLUPEN_bm, RESYNC),
        ("PORTA.DIR(PA2 RESET-coil input)", REG, S.REG_PORTA_DIR,
         S.PORTA_DIR_EXPECTED & ~0x04, RESYNC),
        ("PORTA.DIR(PA3 SET-coil input)", REG, S.REG_PORTA_DIR,
         S.PORTA_DIR_EXPECTED & ~0x08, RESYNC),
        ("PORTA.PA2 RESET-coil(combined input/stale-OUT/PULLUPEN|INVEN)",
         COIL_STATE, S.REG_PORTA_PIN2CTRL,
         S.PORT_PULLUPEN_bm | S.PORT_INVEN_bm, RESYNC),
        ("PORTA.PA3 SET-coil(combined input/stale-OUT/PULLUPEN|INVEN)",
         COIL_STATE, S.REG_PORTA_PIN3CTRL,
         S.PORT_PULLUPEN_bm | S.PORT_INVEN_bm, RESYNC),
        # The same two coil faults delivered while the shell believes it is
        # ENGAGED. That is the other direction of the desynchronization hazard:
        # an unintended RESET pulse can knock a latching relay to BYPASS while
        # the firmware and the LED still say ENGAGED.
        #
        # _inject() writes the corrupt value ABSOLUTELY, so these two carry the
        # lit-LED bit (PA1, 0x02) alongside the coil bit. Without it the
        # injection would also darken the LED and stop being a pure coil fault
        # -- and the post-escalation assertion would no longer show that the
        # de-energization touched the coils and nothing else.
        ("PORTA.OUT(PA2 RESET-coil, ENGAGED)", REG, S.REG_PORTA_OUT, 0x02 | 0x04,
         RESYNC_ENGAGED),
        ("PORTA.OUT(PA3 SET-coil, ENGAGED)",   REG, S.REG_PORTA_OUT, 0x02 | 0x08,
         RESYNC_ENGAGED),
    ] if is_relay else [])


class Checker:
    def __init__(self, expected_cases):
        self.expected_cases = expected_cases
        self.expected_results = expected_cases + 1  # injections + negative control
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
        if declared_cases != self.expected_cases:
            self._completion_failure(
                "fault case list has %d entries; expected exactly %d"
                % (declared_cases, self.expected_cases)
            )
        if self.results != self.expected_results:
            self._completion_failure(
                "recorded %d result(s); expected exactly %d"
                % (self.results, self.expected_results)
            )
        if self.injections != self.expected_cases:
            self._completion_failure(
                "completed %d injectable fault(s); expected exactly %d"
                % (self.injections, self.expected_cases)
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
    if kind == COIL_STATE:
        coil_mask = (0x04 if addr == S.REG_PORTA_PIN2CTRL else
                     0x08 if addr == S.REG_PORTA_PIN3CTRL else 0x00)
        if coil_mask == 0:
            return False
        direction = sim.read_ioreg(S.REG_PORTA_DIR) & ~coil_mask
        out = sim.read_ioreg(S.REG_PORTA_OUT) | coil_mask
        # Release the pin before making the stale OUT latch High, so fixture
        # construction itself does not fabricate an output pulse.
        sim.write_ioreg(S.REG_PORTA_DIR, direction)
        sim.write_ioreg(S.REG_PORTA_OUT, out)
        sim.write_ioreg(addr, value)
        return (sim.read_ioreg(S.REG_PORTA_DIR) == direction and
                sim.read_ioreg(S.REG_PORTA_OUT) == out and
                sim.read_ioreg(addr) == value)
    sim.write_ram(addr, [value])
    return sim.read_ram(addr, 1)[0] == value


def _run_case(elf, name, kind, addr, corrupt, mech, ck):
    sim = S.Sim(elf)
    sim.run_ms(SETTLE_MS)
    if sim.in_force_reset():
        ck.result(False, "%s: device already force-reset before injection" % name)
        return

    if mech == RESYNC_ENGAGED:
        # One debounced press and release, then confirm via the LED that the
        # shell really is ENGAGED -- injecting into an unknown state would test
        # the case the name does not claim.
        sim.press()
        sim.run_ms(ENGAGE_PRESS_MS)
        sim.release()
        sim.run_ms(ENGAGE_RELEASE_MS)
        if not sim.led_on():
            ck.result(False, "%s: shell did not reach ENGAGED before injection"
                             % name)
            return

    if mech in (TRANSACTION_ISR, TRANSACTION_MAIN):
        before_ctx = bytes(sim.read_ram(sim.addr_ctx, 3))
        before_check = sim.read_ram(sim.addr_ctx_check, 1)[0]
        before_led = sim.led_on()
        before_control = sim.control_state()
        edges = sim.control_edges()
        edges.drain()
        if before_ctx != bytes((0, 0, 0)) or before_check != 0xFF:
            ck.result(False, "%s: context/check not canonical before injection" % name)
            return
        if not sim.run_until_sleep(sim.cycles(2)):
            ck.result(False, "%s: device did not settle in IDLE" % name)
            return
        target = (sim.addr_ctx_check_fn if mech == TRANSACTION_ISR
                  else sim.addr_debounce_step_fn)
        if not sim.run_until_pc(target, TRANSACTION_MAX_STEPS):
            ck.result(False, "%s: transaction seam was not reached" % name)
            return
        if not _inject(sim, kind, addr, corrupt):
            ck.result(True, "%s: injection was rejected/re-latched" % name,
                      skipped=True)
            return
        ck.injected()
        sim.run_ms(GATE_MS)
        after_ctx = bytes(sim.read_ram(sim.addr_ctx, 3))
        after_check = sim.read_ram(sim.addr_ctx_check, 1)[0]
        control_events = edges.drain()
        safe = (not sim.in_force_reset() and
                after_ctx == bytes((0, 0, 0)) and after_check == 0xFF and
                sim.led_on() == before_led and
                sim.control_state() == before_control and not control_events)
        ck.result(safe,
                  "%s corrupted once after check capture -> %s"
                  % (name, "safely overwritten, no output"
                     if safe else "context/output changed or fault persisted"))
        return

    healthy = (sim.read_ioreg(addr) if kind in (REG, REG16, COIL_STATE)
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

    if mech in (RESYNC, RESYNC_ENGAGED):
        # The gate escalates the coil-pin fault, and hw_force_wdt_reset() makes
        # BOTH physical pins driven Low before it spins. Assert the physical
        # pins and every register that determines that state; OUT alone cannot
        # detect an inverted, pulled-up or input-direction coil pin.
        #
        # What this substrate CANNOT show is the other half of the electrical
        # contract -- the recovery RESET-coil pulse. yasimavr treats the
        # interrupts-off spin as a terminal halt (see
        # sim_attiny202.in_force_reset), so the
        # ~250 ms WDT never completes the reset in the model. The gpsim PIC
        # lanes measure that pulse on real images; the simavr tinyx5 lane
        # measures it on a classic AVR. No simulator speaks to relay mechanics;
        # physical convergence remains conditional on the documented hardware.
        at = sim.run_until_force_reset(GATE_MS)
        if at is None:
            ck.result(False, "%s corrupted -> gate did NOT force reset within %d ms"
                             % (name, GATE_MS))
            return
        levels = sim.control_levels()
        out = sim.read_ioreg(S.REG_PORTA_OUT)
        direction = sim.read_ioreg(S.REG_PORTA_DIR)
        pin2ctrl = sim.read_ioreg(S.REG_PORTA_PIN2CTRL)
        pin3ctrl = sim.read_ioreg(S.REG_PORTA_PIN3CTRL)
        led_expected = 0x02 if mech == RESYNC_ENGAGED else 0x00
        quiescent = (levels == (0, 0) and out == led_expected and
                     direction == S.PORTA_DIR_EXPECTED and
                     pin2ctrl == 0 and pin3ctrl == 0)
        ck.result(quiescent,
                  "%s corrupted -> gate forced reset (+%d ms) with %s"
                  " (physical=%s, OUT=0x%02x, DIR=0x%02x,"
                  " PIN2CTRL=0x%02x, PIN3CTRL=0x%02x)"
                  % (name, at,
                     "both coils physically quiescent" if quiescent
                     else "NON-QUIESCENT coil state",
                     levels, out, direction, pin2ctrl, pin3ctrl))
        return

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
    is_relay = "tq2_l2_5v_relay" in elf
    print("FAULT START: fw=%s  F_CPU=%d Hz  variant=%s"
          % (elf, S.F_CPU_HZ, "relay" if is_relay else "cd4053"))

    ck = Checker(EXPECTED_FAULT_CASES_RELAY if is_relay
                 else EXPECTED_FAULT_CASES_CD4053)
    probe = S.Sim(elf)                 # one instance just to resolve the case list
    cases = _fault_cases(probe, is_relay)
    for name, kind, addr, corrupt, mech in cases:
        _run_case(elf, name, kind, addr, corrupt, mech, ck)
    _run_negative_control(elf, ck)
    ck.finalize(len(cases))

    verdict = "PASS" if ck.fails == 0 else "FAIL"
    print("\nFAULT %s: %d failed, %d skipped, %d/%d injections, %d/%d results."
          % (verdict, ck.fails, ck.skips,
             ck.injections, ck.expected_cases,
             ck.results, ck.expected_results))
    return 0 if ck.fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
