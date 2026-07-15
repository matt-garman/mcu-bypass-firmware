#!/usr/bin/env python3
"""Host-only regression for fail-closed ATtiny202 fault-run accounting."""

import contextlib
import importlib.util
import io
import math
from pathlib import Path
import sys
import types


previous_sim_module = sys.modules.get("sim_attiny202")
sim_stub = types.ModuleType("sim_attiny202")
sim_stub.F_CPU_HZ = 2_000_000
sim_stub.REG_CLKCTRL_MCLKCTRLB = 0x0061
sim_stub.REG_PORTA_PIN7CTRL = 0x0417
sim_stub.REG_PORTA_DIR = 0x0400
sim_stub.REG_TCB0_CTRLA = 0x0A40
sim_stub.REG_TCB0_CTRLB = 0x0A41
sim_stub.REG_TCB0_INTCTRL = 0x0A45
sim_stub.REG_TCB0_CCMP_L = 0x0A4C
sim_stub.REG_GPR0 = 0x001C
sys.modules["sim_attiny202"] = sim_stub

driver_path = Path(__file__).with_name("test_fault_attiny202.py")
spec = importlib.util.spec_from_file_location("attiny202_fault_driver", driver_path)
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)

checks = 0
failures = 0


def check(condition, message):
    global checks, failures
    checks += 1
    if not condition:
        failures += 1
        sys.stderr.write("FAIL: %s\n" % message)


def finalize(declared, results=14, injections=13, skips=0):
    checker = driver.Checker()
    checker.results = results
    checker.injections = injections
    checker.skips = skips
    with contextlib.redirect_stderr(io.StringIO()):
        checker.finalize(declared)
    return checker.fails


class Probe:
    addr_ctx = 0x3F80
    addr_timer_isr = 0x3F83


expected_cases = (
    ("CLKCTRL.MCLKCTRLB",      "reg", 0x0061, 0x00, "gate"),
    ("PORTA.PIN7CTRL(pullup)", "reg", 0x0417, 0x00, "gate"),
    ("PORTA.DIR(outputs)",      "reg", 0x0400, 0x00, "gate"),
    ("PORTA.DIR(footswitch)",   "reg", 0x0400, 0xCE, "gate"),
    ("PORTA.DIR(spare PA6)",    "reg", 0x0400, 0x0E, "gate"),
    ("ctx_.program_state",     "ram", 0x3F80, 0xFF, "gate"),
    ("ctx_.effect_state",      "ram", 0x3F81, 0xFF, "gate"),
    ("ctx_.debounce_counter",  "ram", 0x3F82, 0xFF, "gate"),
    ("timer_isr_called_",       "ram", 0x3F83, 0xFF, "retry_gate"),
    ("TCB0.CTRLB(mode)",       "reg",   0x0A41, 0x10,   "gate"),
    ("TCB0.CCMP(period)",      "reg16", 0x0A4C, 0x0FFF, "gate"),
    ("TCB0.CTRLA(tick)",       "reg", 0x0A40, 0x00, "live"),
    ("TCB0.INTCTRL(tick)",     "reg", 0x0A45, 0x00, "live"),
)
cases = driver._fault_cases(Probe())
check(tuple(cases) == expected_cases,
      "fault kind/address/value/mechanism must match the independent contract")
check(len({case[0] for case in cases}) == driver.EXPECTED_FAULT_CASES,
      "fault case names must be unique")
direction_values = {
    case[0]: case[3] for case in cases if case[0].startswith("PORTA.DIR(")
}
check((direction_values["PORTA.DIR(footswitch)"] & 0x0E) == 0x0E
      and (direction_values["PORTA.DIR(spare PA6)"] & 0x0E) == 0x0E,
      "exact-direction faults must preserve every caller-requested output bit")

check(driver.EXPECTED_FAULT_CASES == 13 and driver.EXPECTED_TOTAL_RESULTS == 14,
      "driver must pin thirteen injections plus one negative control")
check(finalize(13) == 0, "complete thirteen-injection plus control run must pass")
check(finalize(12) == 1, "short declared case list must fail")
check(finalize(14) == 1, "long declared case list must fail")
check(finalize(13, results=13) == 1, "missing result must fail")
check(finalize(13, results=15) == 1, "extra result must fail")
check(finalize(13, injections=12) == 1, "missing successful injection must fail")
check(finalize(13, injections=14) == 1, "extra successful injection must fail")
check(finalize(13, skips=1) == 1, "any skipped injection must fail")
check(finalize(13, injections=0, skips=13) == 2,
      "all-skipped run must fail both injection and skip invariants")

checker = driver.Checker()
with contextlib.redirect_stdout(io.StringIO()), \
        contextlib.redirect_stderr(io.StringIO()):
    checker.result(True, "pass")
    checker.result(False, "fail")
    checker.result(True, "skip", skipped=True)
    checker.injected()
check(checker.results == 3, "result() must count pass, fail, and skip records")
check(checker.fails == 1, "failed behavioral result must increment failures")
check(checker.skips == 1, "skipped result must increment skips")
check(checker.injections == 1, "injected() must count successful write/readback")


class LiveSim:
    def __init__(self, witness_reset):
        self.witness_reset = witness_reset
        self.regs = {0x1234: 0x55, sim_stub.REG_GPR0: 0x00}
        self.addr_ctx = 0x3F80

    def run_ms(self, _milliseconds):
        if self.regs[0x1234] == 0x00:
            self.regs[0x1234] = 0x55
            if self.witness_reset:
                self.regs[sim_stub.REG_GPR0] = 0x00

    def in_force_reset(self):
        return False

    def read_ioreg(self, addr):
        return self.regs[addr]

    def write_ioreg(self, addr, value):
        self.regs[addr] = value


def run_live_case(witness_reset):
    sim_stub.Sim = lambda _elf: LiveSim(witness_reset)
    checker = driver.Checker()
    with contextlib.redirect_stdout(io.StringIO()), \
            contextlib.redirect_stderr(io.StringIO()):
        driver._run_case("fake.elf", "live", driver.REG, 0x1234, 0x00,
                         driver.LIVE, checker)
    return checker


live_reset = run_live_case(True)
check(live_reset.fails == 0 and live_reset.injections == 1,
      "LIVE case must pass when register restoration has a reset witness")
live_restore = run_live_case(False)
check(live_restore.fails == 1 and live_restore.injections == 1,
      "LIVE case must reject unrelated register restoration without reset witness")


class RetryGateSim:
    def __init__(self, catches):
        self.catches = catches
        self.ram = {0x3F83: 0x00}
        self.steps = 0
        self.addr_ctx = 0x3F80
        self.addr_timer_isr = 0x3F83

    def run_ms(self, _milliseconds):
        pass

    def in_force_reset(self):
        return self.catches and self.steps >= 3

    def read_ram(self, addr, size):
        return bytes([self.ram[addr]])[:size]

    def write_ram(self, addr, values):
        self.ram[addr] = values[0]

    def run_cycles(self, _cycles):
        self.steps += 1


def run_retry_gate(catches):
    sim_stub.Sim = lambda _elf: RetryGateSim(catches)
    checker = driver.Checker()
    with contextlib.redirect_stdout(io.StringIO()), \
            contextlib.redirect_stderr(io.StringIO()):
        driver._run_case("fake.elf", "timer flag", driver.RAM, 0x3F83, 0xFF,
                         driver.RETRY_GATE, checker)
    return checker


check(math.gcd(driver.RETRY_GATE_STEP_CYCLES, 2_000) == 1,
      "retry interval must sweep every timer phase")
retry_caught = run_retry_gate(True)
check(retry_caught.fails == 0 and retry_caught.injections == 1,
      "phase-swept handshake corruption must pass when the gate catches it")
retry_missed = run_retry_gate(False)
check(retry_missed.fails == 1 and retry_missed.injections == 1,
      "phase-swept handshake corruption must fail if never caught")


class NegativeSim:
    def __init__(self, mode):
        self.mode = mode
        self.regs = {sim_stub.REG_GPR0: 0x00}
        self.armed = False

    def run_ms(self, _milliseconds):
        if self.armed and self.mode == "reset":
            self.regs[sim_stub.REG_GPR0] = 0x00

    def read_ioreg(self, addr):
        return self.regs[addr]

    def write_ioreg(self, addr, value):
        self.regs[addr] = value
        self.armed = True

    def in_force_reset(self):
        return self.armed and self.mode == "trap"

    def is_done(self):
        return self.armed and self.mode == "done"


def run_negative(mode):
    sim_stub.Sim = lambda _elf: NegativeSim(mode)
    checker = driver.Checker()
    with contextlib.redirect_stdout(io.StringIO()), \
            contextlib.redirect_stderr(io.StringIO()):
        driver._run_negative_control("fake.elf", checker)
    return checker


check(driver.NEG_CONTROL_MS >= 500,
      "negative control must span at least two nominal watchdog periods")
check(run_negative("healthy").fails == 0,
      "healthy long negative control must pass")
check(run_negative("reset").fails == 1,
      "negative control must reject a cleared reset witness")
check(run_negative("trap").fails == 1,
      "negative control must reject a force-reset trap")
check(run_negative("done").fails == 1,
      "negative control must reject an unexplained simulator stop")

if previous_sim_module is None:
    sys.modules.pop("sim_attiny202", None)
else:
    sys.modules["sim_attiny202"] = previous_sim_module

print("ATtiny202 fault-oracle validation: %d checks, %d failures" %
      (checks, failures))
sys.exit(1 if failures else 0)
