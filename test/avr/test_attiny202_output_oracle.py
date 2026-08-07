#!/usr/bin/env python3
"""Host-only regression for the ATtiny202 target-output oracle.

Covers the trace checks the yasimavr harness performs -- transition
sequence/polarity, safe startup, coil exclusion, complete-pulse presence, and
the DELIVERED pulse width the signal-hook tracer measures from exact transition
cycles. It also covers the folding rule that edges sharing a cycle are one
state change, not an intermediate state.

The ABSOLUTE design width stays owned by test_attiny202_delay_oracle.py, which
reads the compiled _delay_ms loop count out of the image independently of any
simulator; its own --selftest exercises that logic. The band checked here is a
cross-check that also captures tick-ISR preemption, which a compile-time count
cannot show. See check_pulse_width in test_sim_attiny202.py.
"""

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


# The stubbed F_CPU_HZ above makes one simulated cycle one millisecond, so a
# trace's cycle numbers read directly as milliseconds here.
MUTE_MS = driver.design_pulse_ms("cd4053_with_mute")
COIL_MS = driver.design_pulse_ms("tq2_l2_5v_relay")
check((MUTE_MS, COIL_MS) == (5, 12),
      "design pulse widths must come from the delay oracle's table")

mute = make_trace("cd4053_with_mute", [(100, 0x2), (105, 0x3)])
check(run_oracle(lambda ck: (
    driver.check_trace(ck, mute, [0x2, 0x3]),
    driver.check_pulse_width(ck, mute, 0x2, MUTE_MS)
)) == 0, "valid mute sequence with a complete pulse must pass")

relay = make_trace("tq2_l2_5v_relay", [(200, 0x1), (212, 0x0)])
check(run_oracle(lambda ck: (
    driver.check_trace(ck, relay, [0x1, 0x0]),
    driver.check_pulse_width(ck, relay, 0x1, COIL_MS)
)) == 0, "valid relay sequence with a complete pulse must pass")

wrong_sequence = make_trace("wrong sequence", [(100, 0x3)])
check(run_oracle(lambda ck: driver.check_trace(ck, wrong_sequence, [0x2, 0x3])) == 1,
      "wrong transition sequence must fail")

# check_pulse_width asserts a COMPLETE pulse (an edge in AND an edge out) before
# it judges any width. A lone entering edge with no exit, or the pulse state
# never appearing at all, must fail on completeness alone -- exactly once, not
# twice, because an unmeasurable pulse must not also be reported as mis-timed.
incomplete_pulse = make_trace("incomplete pulse", [(100, 0x2)])
check(run_oracle(lambda ck: driver.check_pulse_width(ck, incomplete_pulse, 0x2, MUTE_MS)) == 1,
      "pulse with no trailing edge must fail")

missing_pulse = make_trace("missing pulse", [(100, 0x0)])
check(run_oracle(lambda ck: driver.check_pulse_width(ck, missing_pulse, 0x2, MUTE_MS)) == 1,
      "missing pulse must fail")

# Width band: the tick ISR stretches a delivered pulse a few percent above the
# compiled loop, so the band accepts that but must reject a pulse that is short,
# or long enough to mean something other than preemption.
preempted = make_trace("preempted relay coil", [(200, 0x1), (212 + 1, 0x0)])
check(run_oracle(lambda ck: driver.check_pulse_width(ck, preempted, 0x1, COIL_MS)) == 0,
      "a pulse stretched by tick-ISR preemption must pass")

short_pulse = make_trace("short relay coil", [(200, 0x1), (206, 0x0)])
check(run_oracle(lambda ck: driver.check_pulse_width(ck, short_pulse, 0x1, COIL_MS)) == 1,
      "a half-width coil pulse must fail")

long_pulse = make_trace("long mute window", [(100, 0x2), (110, 0x3)])
check(run_oracle(lambda ck: driver.check_pulse_width(ck, long_pulse, 0x2, MUTE_MS)) == 1,
      "a double-width mute window must fail")

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


class FakeRecorder:
    """Stand-in for sim_attiny202.PinEdgeRecorder: a drainable edge queue.

    Entries are (cycle, pin index, driven level or None), exactly what the
    production recorder yields after mapping Pin.StateEnum to a level.
    """
    def __init__(self, events=()):
        self.events = list(events)

    def append(self, cycle, index, level):
        self.events.append((cycle, index, level))

    def drain(self):
        events, self.events = self.events, []
        return events


class ScriptedSim:
    """Replays a fixed edge stream through the production folding logic."""
    def __init__(self):
        self.current_cycle = 0
        self.recorder = FakeRecorder([
            (1, 0, 1),              # PA2 driven high while PA3 still floats
            (2, 0, 0), (2, 1, 0),   # one instruction drives both low: one cycle
            (3, 0, 1),
            (4, 0, 0),
        ])

    def control_levels(self):
        return (None, None)         # neither pin driven at the segment start

    def control_edges(self):
        return self.recorder

    def cycle(self):
        return self.current_cycle

    def is_done(self):
        return False

    def run_ms(self, _milliseconds):
        self.current_cycle += 5


scripted = driver.trace_outputs(ScriptedSim(), "scripted", 1)
check(scripted.unsafe_before_config, "one-cycle partial-drive high must be recorded")
check(scripted.initial_state == 0x0, "first complete driven state must be captured")
check([state for _cycle, state in scripted.transitions] == [0x1, 0x0],
      "one-cycle transitions must be captured in order")


class SwapSim:
    """One instruction moves the drive from PA2 to PA3: two edges, one cycle.

    Judged edge by edge this looks like a moment with both relay coils high --
    the exact false alarm folding a whole cycle exists to prevent. The hardware
    never presented that state; a single PORT write changed both bits at once.
    """
    def __init__(self):
        self.current_cycle = 0
        self.recorder = FakeRecorder([(3, 1, 1), (3, 0, 0)])

    def control_levels(self):
        return (1, 0)               # starts driven at state 0x1

    def control_edges(self):
        return self.recorder

    def cycle(self):
        return self.current_cycle

    def is_done(self):
        return False

    def run_ms(self, _milliseconds):
        self.current_cycle += 5


swapped = driver.trace_outputs(SwapSim(), "swapped", 1)
check([state for _cycle, state in swapped.transitions] == [0x2],
      "edges sharing a cycle must fold into one state change")
check(not swapped.saw_both_high,
      "folding must not fabricate an intermediate both-coils-high state")


scenario_variant = None
scenario_fault = None


class ControlSim:
    """Small deterministic stand-in that drives the production orchestration.

    Scheduled state changes are expanded into per-pin edges as simulated time
    advances, which is the shape the production tracer consumes. A change of
    both pins therefore lands as two edges on one cycle, the same as a single
    PORT write on the real part.
    """
    def __init__(self, _elf):
        self.current_cycle = 0
        self.state = 0x0
        self.events = {}
        self.recorder = FakeRecorder()
        self.engaged = False
        if scenario_variant == "tq2_l2_5v_relay":
            self.events[1] = 0x1
            self.events[1 + COIL_MS] = 0x0

    def control_levels(self):
        return self.state & 0x1, (self.state >> 1) & 0x1

    def control_state(self):
        return self.state

    def control_edges(self):
        return self.recorder

    def cycle(self):
        return self.current_cycle

    def is_done(self):
        return False

    def run_ms(self, milliseconds):
        for _unused in range(milliseconds):
            self.current_cycle += 1
            new_state = self.events.get(self.current_cycle)
            if new_state is None or new_state == self.state:
                continue
            for index in range(2):
                level = (new_state >> index) & 0x1
                if level != ((self.state >> index) & 0x1):
                    self.recorder.append(self.current_cycle, index, level)
            self.state = new_state

    def press(self):
        start = self.current_cycle + 8
        # relay_short drives a coil pulse well under its design width -- a
        # timing fault the harness must reject.
        coil_ms = 6 if scenario_fault == "relay_short" else COIL_MS
        if not self.engaged:
            if scenario_variant == "cd4053_simple":
                self.events[start] = 0x1
            elif scenario_variant == "cd4053_with_mute":
                self.events[start] = 0x2
                self.events[start + MUTE_MS] = 0x3
            else:
                # relay_overlap drives both coils high at once -- a coil-exclusion
                # fault the harness must reject.
                self.events[start] = 0x3 if scenario_fault == "relay_overlap" else 0x2
                self.events[start + coil_ms] = 0x0
            self.engaged = True
        else:
            if scenario_variant == "cd4053_simple":
                self.events[start] = 0x0
            elif scenario_variant == "cd4053_with_mute":
                self.events[start] = 0x2
                self.events[start + MUTE_MS] = 0x0
            else:
                self.events[start] = 0x1
                self.events[start + coil_ms] = 0x0
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
# Coil exclusion and delivered pulse width are both properties yasimavr
# observes, so both are harness checks. The compiled design width remains
# test_attiny202_delay_oracle.py's, and its --selftest asserts those fail-closed
# paths from the loop count; these two prove the orchestration itself rejects a
# fault end to end.
check(run_control_orchestration("tq2_l2_5v_relay", "relay_overlap") > 0,
      "orchestration must reject simultaneous relay coils")
check(run_control_orchestration("tq2_l2_5v_relay", "relay_short") > 0,
      "orchestration must reject an under-width coil pulse")

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
