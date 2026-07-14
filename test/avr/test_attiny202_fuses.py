#!/usr/bin/env python3
"""Host regression for fail-closed ATtiny202 simulator fuse configuration."""

import os
import sys

import attiny202_fuses as F


EXPECTED = {
    "WDTCFG": 0x06,
    "BODCFG": 0xE5,
    "OSCCFG": 0x01,
    "SYSCFG0": 0xF6,
    "SYSCFG1": 0x07,
    "APPEND": 0x00,
    "BOOTEND": 0x00,
}
EXPECTED_SPECS = (
    ("WDTCFG", 0),
    ("BODCFG", 1),
    ("OSCCFG", 2),
    ("SYSCFG0", 5),
    ("SYSCFG1", 6),
    ("APPEND", 7),
    ("BOOTEND", 8),
)

checks = 0
failures = 0


def check(condition, message):
    global checks, failures
    checks += 1
    if not condition:
        failures += 1
        sys.stderr.write("FAIL: %s\n" % message)


def expect_config_error(action, message):
    try:
        action()
    except F.FuseConfigError:
        check(True, message)
    else:
        check(False, message)


values = F.read_fuses(os.environ)
check(F.FUSE_SPECS == EXPECTED_SPECS,
      "fuse names and indices must match the independent ATtiny202 map")
check(len({index for _name, index in F.FUSE_SPECS}) == len(F.FUSE_SPECS),
      "each configured fuse must have a unique simulator index")
for name, expected in EXPECTED.items():
    check(values.get(name) == expected,
          "%s must be the production value 0x%02X" % (name, expected))

factory = [0xAA] * 11
patched = F.apply_factory_values(factory, values)
check(factory == [0xAA] * 11, "factory fuse input must not be modified in place")
for name, index in EXPECTED_SPECS:
    check(patched[index] == EXPECTED[name],
          "%s must be written to fuse index %d" % (name, index))
for index in (3, 4, 9, 10):
    check(patched[index] == 0xAA, "unconfigured fuse index %d must be preserved" % index)

for name, _index in F.FUSE_SPECS:
    env = dict(os.environ)
    del env["ATTINY202_FUSE_" + name]
    expect_config_error(lambda env=env: F.read_fuses(env),
                        "missing %s must fail" % name)

for raw in ("", "0x", "-1", "256", "0x100", " 0x06", "0x06 ", "junk"):
    env = dict(os.environ)
    env["ATTINY202_FUSE_WDTCFG"] = raw
    expect_config_error(lambda env=env: F.read_fuses(env),
                        "invalid fuse text %r must fail" % raw)

expect_config_error(lambda: F.apply_factory_values([0xAA] * 8, values),
                    "truncated yasimavr fuse array must fail")
expect_config_error(lambda: F.apply_factory_values(None, values),
                    "non-iterable yasimavr fuse values must fail")
incomplete = dict(values)
del incomplete["BOOTEND"]
expect_config_error(lambda: F.apply_factory_values([0xAA] * 11, incomplete),
                    "incomplete fuse map must fail")

print("ATtiny202 simulator fuse validation: %d checks, %d failures" %
      (checks, failures))
sys.exit(1 if failures else 0)
