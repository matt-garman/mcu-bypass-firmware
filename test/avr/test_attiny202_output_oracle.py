#!/usr/bin/env python3
"""Host-only regression for the ATtiny202 target-output oracle."""

import contextlib
import importlib.util
import io
import os
from pathlib import Path
import sys
import types


# test_sim_attiny202 imports sim_attiny202 at module load. Its output-oracle
# helpers need only F_CPU_HZ, so a stub keeps this regression independent of the
# external yasimavr package while exercising the exact production checker code.
previous_sim_module = sys.modules.get("sim_attiny202")
sim_stub = types.ModuleType("sim_attiny202")
# Scale simulated cycles to milliseconds so orchestration tests stay fast. The
# production driver still uses 2 MHz from the real shared module.
sim_stub.F_CPU_HZ = 1_000
sys.modules["sim_attiny202"] = sim_stub

driver_path = Path(__file__).with_name("test_sim_attiny202.py")
spec = importlib.util.spec_from_file_location("attiny202_sim_driver", driver_path)
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)
driver.OUTPUT_TIMING_TOLERANCE_CYCLES = 0

checks = 0
failures = 0


def check(condition, message):
    global checks, failures
    checks += 1
    if not condition:
        failures += 1
        sys.stderr.write("FAIL: %s\n" % message)


def make_trace(name, transitions):
    trace = driver.OutputTrace(name)
    trace.configured = True
    trace.initial_state = 0
    trace.transitions = transitions
    return trace


def run_oracle(action):
    checker = driver.Checker()
    with contextlib.redirect_stdout(io.StringIO()), \
            contextlib.redirect_stderr(io.StringIO()):
        action(checker)
    return checker.fails


mute = make_trace("mute", [(100, 0x2), (105, 0x3)])
check(run_oracle(lambda ck: (
    driver.check_trace(ck, mute, [0x2, 0x3]),
    driver.check_pulse(ck, mute, 0x2, 5)
)) == 0, "valid 5 ms mute sequence must pass")

relay = make_trace("relay", [(200, 0x1), (212, 0x0)])
check(run_oracle(lambda ck: (
    driver.check_trace(ck, relay, [0x1, 0x0]),
    driver.check_pulse(ck, relay, 0x1, 12, relay_minimum=True)
)) == 0, "valid 12 ms relay sequence must pass")

wrong_sequence = make_trace("wrong sequence", [(100, 0x3)])
check(run_oracle(lambda ck: driver.check_trace(ck, wrong_sequence, [0x2, 0x3])) == 1,
      "wrong transition sequence must fail")

short_pulse = make_trace("short pulse", [(100, 0x2), (104, 0x3)])
check(run_oracle(lambda ck: driver.check_pulse(ck, short_pulse, 0x2, 5)) == 1,
      "short mute window must fail")

long_pulse = make_trace("long pulse", [(100, 0x2), (106, 0x3)])
check(run_oracle(lambda ck: driver.check_pulse(ck, long_pulse, 0x2, 5)) == 1,
      "long mute window must fail")

short_relay = make_trace("short relay", [(100, 0x1), (103, 0x0)])
check(run_oracle(lambda ck: driver.check_pulse(
    ck, short_relay, 0x1, 12, relay_minimum=True)) == 2,
    "short relay pulse must fail design timing and datasheet minimum")

missing_pulse = make_trace("missing pulse", [(100, 0x0)])
check(run_oracle(lambda ck: driver.check_pulse(ck, missing_pulse, 0x2, 5)) == 1,
      "missing pulse must fail")

for attribute, label in (
        ("stalled", "stalled simulator"),
        ("unsafe_before_config", "pre-configuration high"),
        ("invalid_after_config", "non-driven configured pin")):
    broken = make_trace(label, [])
    setattr(broken, attribute, True)
    check(run_oracle(lambda ck, broken=broken: driver.check_trace(ck, broken, [])) == 1,
          "%s must fail" % label)

unconfigured = driver.OutputTrace("unconfigured")
check(run_oracle(lambda ck: driver.check_trace(ck, unconfigured, [])) == 1,
      "trace that never drives PA2/PA3 must fail")


class ScriptedSim:
    def __init__(self):
        self.current_cycle = 0
        self.levels = {
            0: (None, None),
            1: (1, None),       # unsafe high before PA3 is configured
            2: (0, 0),
            3: (1, 0),
            4: (0, 0),
        }

    def control_levels(self):
        return self.levels.get(self.current_cycle, (0, 0))

    def cycle(self):
        return self.current_cycle

    def cycles(self, _milliseconds):
        return 5

    def run_cycles(self, cycles):
        self.current_cycle += cycles


scripted = driver.trace_outputs(ScriptedSim(), "scripted", 1)
check(scripted.unsafe_before_config, "one-cycle partial-drive high must be recorded")
check(scripted.initial_state == 0x0, "first complete driven state must be captured")
check([state for _cycle, state in scripted.transitions] == [0x1, 0x0],
      "one-cycle transitions must be captured in order")


scenario_variant = None
scenario_fault = None


class ControlSim:
    """Small deterministic stand-in that drives the production orchestration."""
    def __init__(self, _elf):
        self.current_cycle = 0
        self.state = 0x0
        self.events = {}
        self.engaged = False
        if scenario_variant == "relay":
            width = 3 if scenario_fault == "short_relay" else 12
            self.events[1] = 0x1
            self.events[1 + width] = 0x0

    def control_levels(self):
        return self.state & 0x1, (self.state >> 1) & 0x1

    def control_state(self):
        return self.state

    def cycle(self):
        return self.current_cycle

    def cycles(self, milliseconds):
        return milliseconds

    def run_cycles(self, cycles):
        for _unused in range(cycles):
            self.current_cycle += 1
            if self.current_cycle in self.events:
                self.state = self.events[self.current_cycle]

    def press(self):
        start = self.current_cycle + 8
        if not self.engaged:
            if scenario_variant == "cd4053":
                self.events[start] = 0x1
            elif scenario_variant == "mute":
                width = 6 if scenario_fault == "long_mute" else 5
                self.events[start] = 0x2
                self.events[start + width] = 0x3
            else:
                width = 3 if scenario_fault == "short_relay" else 12
                self.events[start] = 0x3 if scenario_fault == "relay_overlap" else 0x2
                self.events[start + width] = 0x0
            self.engaged = True
        else:
            if scenario_variant == "cd4053":
                self.events[start] = 0x0
            elif scenario_variant == "mute":
                width = 6 if scenario_fault == "long_mute" else 5
                self.events[start] = 0x2
                self.events[start + width] = 0x0
            else:
                width = 3 if scenario_fault == "short_relay" else 12
                self.events[start] = 0x1
                self.events[start + width] = 0x0
            self.engaged = False

    def release(self):
        pass


sim_stub.Sim = ControlSim


def run_control_orchestration(variant, fault=None):
    global scenario_variant, scenario_fault
    scenario_variant = variant
    scenario_fault = fault
    checker = driver.Checker()
    with contextlib.redirect_stdout(io.StringIO()), \
            contextlib.redirect_stderr(io.StringIO()):
        driver.test_control_outputs("fake.elf", variant, checker)
    return checker.fails


for variant in driver.VARIANTS:
    check(run_control_orchestration(variant) == 0,
          "%s production output orchestration must pass" % variant)
check(run_control_orchestration("mute", "long_mute") > 0,
      "orchestration must reject a long mute window")
check(run_control_orchestration("relay", "short_relay") > 0,
      "orchestration must reject a relay pulse below design/minimum")
check(run_control_orchestration("relay", "relay_overlap") > 0,
      "orchestration must reject simultaneous relay coils")

old_variant = os.environ.get("ATTINY202_VARIANT")
try:
    for variant in driver.VARIANTS:
        os.environ["ATTINY202_VARIANT"] = variant
        check(driver.resolve_variant() == variant, "variant %s must be accepted" % variant)
    os.environ["ATTINY202_VARIANT"] = "bogus"
    with contextlib.redirect_stderr(io.StringIO()):
        check(driver.resolve_variant() is None, "unknown variant must fail")
finally:
    if old_variant is None:
        os.environ.pop("ATTINY202_VARIANT", None)
    else:
        os.environ["ATTINY202_VARIANT"] = old_variant

if previous_sim_module is None:
    sys.modules.pop("sim_attiny202", None)
else:
    sys.modules["sim_attiny202"] = previous_sim_module

print("ATtiny202 output-oracle validation: %d checks, %d failures" %
      (checks, failures))
sys.exit(1 if failures else 0)
