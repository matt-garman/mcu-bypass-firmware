#!/usr/bin/env python3
"""Host-only regression for fail-closed ATtiny202 fault-run accounting."""

import ast
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
sim_stub.REG_PORTA_PIN1CTRL = 0x0411
sim_stub.REG_PORTA_PIN2CTRL = 0x0412
sim_stub.REG_PORTA_PIN3CTRL = 0x0413
sim_stub.REG_PORTA_PIN6CTRL = 0x0416
sim_stub.REG_PORTA_PIN7CTRL = 0x0417
sim_stub.PORT_PULLUPEN_bm = 0x08
sim_stub.PORT_INVEN_bm = 0x80
sim_stub.REG_PORTA_DIR = 0x0400
sim_stub.REG_PORTA_OUT = 0x0404
sim_stub.PORTA_DIR_EXPECTED = 0x4E
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


def function_body(source, signature):
    start = source.find(signature)
    check(source.count(signature) == 1,
          "%s must occur exactly once for the order oracle" % signature)
    if start < 0:
        return ""
    end = source.find("\n}", start)
    check(end >= 0, "%s must have a bounded function body" % signature)
    return source[start:end] if end >= 0 else ""


def check_order(body, operations, message):
    positions = [body.find(operation) for operation in operations]
    check(all(position >= 0 for position in positions) and
          positions == sorted(positions) and len(set(positions)) == len(positions),
          message)


def finalize(declared, results=25, injections=24, skips=0, expected=24):
    checker = driver.Checker(expected)
    checker.results = results
    checker.injections = injections
    checker.skips = skips
    with contextlib.redirect_stderr(io.StringIO()):
        checker.finalize(declared)
    return checker.fails


# The physical simulators prove the final pad state. Pin the reviewed write
# order independently so a later cleanup cannot activate a pull-up during the
# high-impedance interval or reconnect a stale high latch before it is cleared.
root = Path(__file__).parents[2]
avr_source = (root / "src/bypass_mcu_avr_xt.c").read_text(encoding="utf-8")
avr_quiesce = function_body(
    avr_source, "static void hw_emergency_outputs_quiesce(void) {")
check_order(avr_quiesce, (
    "PORTA.PIN2CTRL &= (uint8_t)PORT_INVEN_bm;",
    "PORTA.PIN3CTRL &= (uint8_t)PORT_INVEN_bm;",
    "PORTA.DIRCLR = coil_mask;",
    "PORTA.PIN2CTRL = 0U;",
    "PORTA.PIN3CTRL = 0U;",
    "hw_outputs_reassert_safe();",
    "PORTA.DIRSET = coil_mask;",
), "AVR-XT emergency order must remove pull-ups, disconnect drive, clear"
   " inversion/latches, then restore direction")

pic_source = (root / "src/bypass_mcu_pic12f675.c").read_text(encoding="utf-8")
pic_quiesce = function_body(
    pic_source, "static void hw_emergency_outputs_quiesce(void) {")
check_order(pic_quiesce, (
    "WPU &= (uint8_t)~coil_mask;",
    "TRISIO |= coil_mask;",
    "ADCON0 = ADCON0_ADC_OFF;",
    "ANSEL &= (uint8_t)~ANSEL_OUTPUT_MASK;",
    "CMCON = CMCON_COMPARATOR_OFF;",
    "hw_outputs_reassert_safe();",
    "TRISIO &= (uint8_t)~coil_mask;",
), "PIC12F675 emergency order must remove pull-ups, disconnect drive, restore"
   " GPIO ownership, clear latches, then restore direction")


class Probe:
    addr_ctx = 0x3F80
    addr_ctx_check = 0x3F84
    addr_ctx_check_fn = 0x0200
    addr_debounce_step_fn = 0x0300
    addr_timer_isr = 0x3F83


expected_cases = (
    ("CLKCTRL.MCLKCTRLB",      "reg", 0x0061, 0x00, "gate"),
    ("PORTA.PIN7CTRL(pullup)", "reg", 0x0417, 0x00, "gate"),
    ("PORTA.PIN1CTRL(INVEN)",  "reg", 0x0411, 0x80, "gate"),
    ("PORTA.PIN2CTRL(INVEN)",  "reg", 0x0412, 0x80, "gate"),
    ("PORTA.PIN3CTRL(INVEN)",  "reg", 0x0413, 0x80, "gate"),
    ("PORTA.PIN6CTRL(INVEN)",  "reg", 0x0416, 0x80, "gate"),
    ("PORTA.PIN7CTRL(INVEN)",  "reg", 0x0417, 0x88, "gate"),
    ("PORTA.DIR(outputs)",      "reg", 0x0400, 0x00, "gate"),
    ("PORTA.DIR(footswitch)",   "reg", 0x0400, 0xCE, "gate"),
    ("PORTA.DIR(spare PA6)",    "reg", 0x0400, 0x0E, "gate"),
    ("PORTA.OUT(PA1 LED)",      "reg", 0x0404, 0x02, "gate"),
    ("PORTA.OUT(PA2 control)",  "reg", 0x0404, 0x04, "gate"),
    ("PORTA.OUT(PA3 control)",  "reg", 0x0404, 0x08, "gate"),
    ("PORTA.OUT(PA6 spare)",    "reg", 0x0404, 0x40, "gate"),
    ("ctx_.program_state",     "ram", 0x3F80, 0xFF, "gate"),
    ("ctx_.effect_state",      "ram", 0x3F81, 0xFF, "gate"),
    ("ctx_.debounce_counter",  "ram", 0x3F82, 0xFF, "gate"),
    ("ctx_.debounce_counter(in-range F2 ISR)", "ram", 0x3F82, 0x10,
     "transaction_isr"),
    ("ctx_.debounce_counter(in-range F2 main)", "ram", 0x3F82, 0x10,
     "transaction_main"),
    ("timer_isr_called_",       "ram", 0x3F83, 0xFF, "retry_gate"),
    ("TCB0.CTRLB(mode)",       "reg",   0x0A41, 0x10,   "gate"),
    ("TCB0.CCMP(period)",      "reg16", 0x0A4C, 0x0FFF, "gate"),
    ("TCB0.CTRLA(tick)",       "reg", 0x0A40, 0x00, "live"),
    ("TCB0.INTCTRL(tick)",     "reg", 0x0A45, 0x00, "live"),
)
# CD4053 variants: PA2/PA3 are control lines -> gate/reset (the default list).
cases = driver._fault_cases(Probe(), is_relay=False)
check(tuple(cases) == expected_cases,
      "cd4053 fault kind/address/value/mechanism must match the independent contract")

# Relay variant: every coil-pin fault must leave physical PA2/PA3 quiescent
# before the reset spin. Existing INVEN and OUT cases are reclassified, and six
# relay-only cases pin PULLUPEN, one-bit direction, and combined register-state
# fixtures. The ENGAGED values carry the lit-LED bit because the driver injects
# absolutely. Active-pulse faults are outside this oracle.
expected_cases_relay = tuple(
    ("PORTA.OUT(PA2 RESET-coil)", "reg", 0x0404, 0x04, "resync")
        if c[0] == "PORTA.OUT(PA2 control)"
    else ("PORTA.OUT(PA3 SET-coil)", "reg", 0x0404, 0x08, "resync")
        if c[0] == "PORTA.OUT(PA3 control)"
    else (c[0], c[1], c[2], c[3], "resync")
        if c[0] in ("PORTA.PIN2CTRL(INVEN)", "PORTA.PIN3CTRL(INVEN)")
    else c
    for c in expected_cases
) + (
    ("PORTA.PIN2CTRL(PULLUPEN RESET-coil)", "reg", 0x0412, 0x08, "resync"),
    ("PORTA.PIN3CTRL(PULLUPEN SET-coil)", "reg", 0x0413, 0x08, "resync"),
    ("PORTA.DIR(PA2 RESET-coil input)", "reg", 0x0400, 0x4A, "resync"),
    ("PORTA.DIR(PA3 SET-coil input)", "reg", 0x0400, 0x46, "resync"),
    ("PORTA.PA2 RESET-coil(combined input/stale-OUT/PULLUPEN|INVEN)",
     "coil_state", 0x0412, 0x88, "resync"),
    ("PORTA.PA3 SET-coil(combined input/stale-OUT/PULLUPEN|INVEN)",
     "coil_state", 0x0413, 0x88, "resync"),
    ("PORTA.OUT(PA2 RESET-coil, ENGAGED)", "reg", 0x0404, 0x06, "resync_engaged"),
    ("PORTA.OUT(PA3 SET-coil, ENGAGED)",   "reg", 0x0404, 0x0A, "resync_engaged"),
)
cases_relay = driver._fault_cases(Probe(), is_relay=True)
check(tuple(cases_relay) == expected_cases_relay,
      "relay fault identities must pin every physical quiescence fixture and"
      " both settled-state OUT hazards")
check(len({case[0] for case in cases_relay})
      == driver.EXPECTED_FAULT_CASES_RELAY,
      "relay fault case names must be unique")
sim_path = Path(__file__).with_name("sim_attiny202.py")
expected_sim_constants = {
    "PORTA_DIR_EXPECTED": 0x4E,
    "REG_PORTA_PIN1CTRL": 0x0411,
    "REG_PORTA_PIN2CTRL": 0x0412,
    "REG_PORTA_PIN3CTRL": 0x0413,
    "REG_PORTA_PIN6CTRL": 0x0416,
    "REG_PORTA_PIN7CTRL": 0x0417,
    "PORT_PULLUPEN_bm": 0x08,
    "PORT_INVEN_bm": 0x80,
}
actual_sim_constants = {}
for node in ast.parse(sim_path.read_text(encoding="utf-8"), filename=str(sim_path)).body:
    if (isinstance(node, ast.Assign) and len(node.targets) == 1
            and isinstance(node.targets[0], ast.Name)
            and node.targets[0].id in expected_sim_constants):
        actual_sim_constants[node.targets[0].id] = ast.literal_eval(node.value)
check(actual_sim_constants == expected_sim_constants,
      "production simulator pin-control addresses/masks must match the datasheet")
check(len({case[0] for case in cases}) == driver.EXPECTED_FAULT_CASES_CD4053,
      "fault case names must be unique")
direction_values = {
    case[0]: case[3] for case in cases if case[0].startswith("PORTA.DIR(")
}
check((direction_values["PORTA.DIR(footswitch)"] & 0x0E) == 0x0E
      and (direction_values["PORTA.DIR(spare PA6)"] & 0x0E) == 0x0E,
      "exact-direction faults must preserve every caller-requested output bit")

check(driver.EXPECTED_FAULT_CASES_CD4053 == 24
      and driver.EXPECTED_FAULT_CASES_RELAY == 32,
      "driver must pin twenty-four CD4053 injections and thirty-two relay ones,"
      " each plus one negative control")
check(finalize(32, results=33, injections=32, expected=32) == 0,
      "complete thirty-two-injection relay run must pass")
check(finalize(26, results=27, injections=26, expected=32) == 3,
      "a relay run that silently dropped the six new coil-pin cases must fail"
      " every completion invariant")
check(finalize(24) == 0, "complete twenty-four-injection plus control run must pass")
check(finalize(23) == 1, "short declared case list must fail")
check(finalize(25) == 1, "long declared case list must fail")
check(finalize(24, results=24) == 1, "missing result must fail")
check(finalize(24, results=26) == 1, "extra result must fail")
check(finalize(24, injections=23) == 1, "missing successful injection must fail")
check(finalize(24, injections=25) == 1, "extra successful injection must fail")
check(finalize(24, skips=1) == 1, "any skipped injection must fail")
check(finalize(24, injections=0, skips=24) == 2,
      "all-skipped run must fail both injection and skip invariants")

checker = driver.Checker(driver.EXPECTED_FAULT_CASES_CD4053)
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
    checker = driver.Checker(driver.EXPECTED_FAULT_CASES_CD4053)
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
    checker = driver.Checker(driver.EXPECTED_FAULT_CASES_CD4053)
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


class LatchOnlyQuiesceSim:
    """Fake emergency path that clears OUT but leaves INVEN active."""

    def __init__(self):
        self.regs = {
            sim_stub.REG_PORTA_DIR: sim_stub.PORTA_DIR_EXPECTED,
            sim_stub.REG_PORTA_OUT: 0x00,
            sim_stub.REG_PORTA_PIN2CTRL: 0x00,
            sim_stub.REG_PORTA_PIN3CTRL: 0x00,
        }
        self.trapped = False

    def run_ms(self, _milliseconds):
        pass

    def in_force_reset(self):
        return self.trapped

    def read_ioreg(self, addr):
        return self.regs[addr]

    def write_ioreg(self, addr, value):
        self.regs[addr] = value

    def run_until_force_reset(self, _max_ms):
        # This is the implementation the physical-pin assertion must kill:
        # clearing only the latches leaves an inverted output physically High.
        self.regs[sim_stub.REG_PORTA_OUT] &= ~0x0C
        self.trapped = True
        return 1

    def control_levels(self):
        levels = []
        for mask, ctrl_addr in (
                (0x04, sim_stub.REG_PORTA_PIN2CTRL),
                (0x08, sim_stub.REG_PORTA_PIN3CTRL)):
            level = 1 if self.regs[sim_stub.REG_PORTA_OUT] & mask else 0
            if self.regs[ctrl_addr] & sim_stub.PORT_INVEN_bm:
                level ^= 1
            levels.append(level)
        return tuple(levels)


def run_latch_only_quiescence(pinctrl_addr):
    fake = LatchOnlyQuiesceSim()
    sim_stub.Sim = lambda _elf: fake
    checker = driver.Checker(driver.EXPECTED_FAULT_CASES_RELAY)
    name = ("PORTA.PIN2CTRL(INVEN)" if
            pinctrl_addr == sim_stub.REG_PORTA_PIN2CTRL else
            "PORTA.PIN3CTRL(INVEN)")
    with contextlib.redirect_stdout(io.StringIO()), \
            contextlib.redirect_stderr(io.StringIO()):
        driver._run_case("fake.elf", name, driver.REG, pinctrl_addr,
                         sim_stub.PORT_INVEN_bm, driver.RESYNC, checker)
    return checker, fake


for coil_addr, high_levels, coil_name in (
        (sim_stub.REG_PORTA_PIN2CTRL, (1, 0), "PA2 RESET-coil"),
        (sim_stub.REG_PORTA_PIN3CTRL, (0, 1), "PA3 SET-coil")):
    latch_only, latch_only_sim = run_latch_only_quiescence(coil_addr)
    check((latch_only_sim.read_ioreg(sim_stub.REG_PORTA_OUT) & 0x0C) == 0
          and latch_only_sim.control_levels() == high_levels,
          "%s host negative control must have OUT Low but its physical pin High"
          % coil_name)
    check(latch_only.fails == 1 and latch_only.injections == 1,
          "%s INVEN case must reject a latch-only emergency implementation"
          % coil_name)


class EdgeLog:
    def __init__(self):
        self.events = []

    def drain(self):
        events = self.events
        self.events = []
        return events


class TransactionSim:
    def __init__(self, safe):
        self.safe = safe
        self.addr_ctx = 0x3F80
        self.addr_ctx_check = 0x3F84
        self.addr_ctx_check_fn = 0x0200
        self.addr_debounce_step_fn = 0x0300
        self.ram = {
            0x3F80: 0x00, 0x3F81: 0x00, 0x3F82: 0x00, 0x3F84: 0xFF,
        }
        self.injected = False
        self.pc_target = None
        self.led = False
        self.control = 0
        self.edges = EdgeLog()

    def cycles(self, milliseconds):
        return milliseconds * 2_000

    def run_ms(self, _milliseconds):
        if not self.injected:
            return
        if self.safe:
            self.ram[0x3F82] = 0x00
            self.ram[0x3F84] = 0xFF
        else:
            self.ram[0x3F80] = 0x01
            self.ram[0x3F81] = 0x01
            self.ram[0x3F82] = 0x19
            self.ram[0x3F84] = 0xE6
            self.led = True
            self.control = 1
            self.edges.events.append((1, 2, 1))

    def in_force_reset(self):
        return False

    def run_until_sleep(self, _max_cycles):
        return True

    def run_until_pc(self, address, _max_cycles):
        self.pc_target = address
        return address in (self.addr_ctx_check_fn, self.addr_debounce_step_fn)

    def read_ram(self, addr, size):
        return bytes(self.ram.get(addr + offset, 0) for offset in range(size))

    def write_ram(self, addr, values):
        self.ram[addr] = values[0]
        self.injected = True

    def led_on(self):
        return self.led

    def control_state(self):
        return self.control

    def control_edges(self):
        return self.edges


def run_transaction_case(safe, mechanism):
    transaction_sim = TransactionSim(safe)
    sim_stub.Sim = lambda _elf: transaction_sim
    checker = driver.Checker(driver.EXPECTED_FAULT_CASES_CD4053)
    with contextlib.redirect_stdout(io.StringIO()), \
            contextlib.redirect_stderr(io.StringIO()):
        driver._run_case("fake.elf", "ctx transaction", driver.RAM, 0x3F82,
                         0x10, mechanism, checker)
    return checker, transaction_sim


for transaction_mechanism in (driver.TRANSACTION_ISR, driver.TRANSACTION_MAIN):
    transaction_safe, transaction_sim = run_transaction_case(
        True, transaction_mechanism)
    check(transaction_safe.fails == 0 and transaction_safe.injections == 1,
          "%s one-shot upset must pass when safely overwritten"
          % transaction_mechanism)
    expected_target = (transaction_sim.addr_ctx_check_fn
                       if transaction_mechanism == driver.TRANSACTION_ISR
                       else transaction_sim.addr_debounce_step_fn)
    check(transaction_sim.pc_target == expected_target,
          "%s must stop at its distinct transaction seam"
          % transaction_mechanism)
    transaction_laundered, _ = run_transaction_case(
        False, transaction_mechanism)
    check(transaction_laundered.fails == 1 and
          transaction_laundered.injections == 1,
          "%s one-shot upset must reject a phantom output/re-fold"
          % transaction_mechanism)


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
    checker = driver.Checker(driver.EXPECTED_FAULT_CASES_CD4053)
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
