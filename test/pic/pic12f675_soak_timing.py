#!/usr/bin/env python3
"""Derive PIC12F675 soak holds from constants consumed by the firmware."""

import argparse
import pathlib
import re
import sys


VARIANTS = (
    "cd4053_simple",
    "cd4053_with_mute",
    "tq2_l2_5v_relay",
)


def decimal_constant(text, what):
    match = re.fullmatch(r"([0-9]+)[uUlL]*", text.strip())
    if not match:
        raise ValueError("{} must be a decimal integer constant: {}".format(
            what, text))
    return int(match.group(1), 10)


def source_define(path, name):
    pattern = re.compile(
        r"^\s*#\s*define\s+{}\s+\(\s*([0-9]+[uUlL]*)\s*\)\s*$".format(
            re.escape(name)))
    matches = []
    with path.open(encoding="ascii") as stream:
        for line in stream:
            match = pattern.match(line)
            if match:
                matches.append(decimal_constant(match.group(1), name))
    if len(matches) != 1:
        raise ValueError("{} must define {} exactly once (found {})".format(
            path, name, len(matches)))
    return matches[0]


def source_hex_define(path, name):
    pattern = re.compile(
        r"^\s*#\s*define\s+{}\s+\(\s*(0[xX][0-9A-Fa-f]+)[uUlL]*\s*\)\s*$".format(
            re.escape(name)))
    matches = []
    with path.open(encoding="ascii") as stream:
        for line in stream:
            match = pattern.match(line)
            if match:
                matches.append(int(match.group(1), 16))
    if len(matches) != 1:
        raise ValueError("{} must define {} exactly once (found {})".format(
            path, name, len(matches)))
    return matches[0]


def derive(root, variant, fosc_text, expected_fosc_text):
    fosc_hz = decimal_constant(fosc_text, "FOSC")
    expected_fosc_hz = decimal_constant(expected_fosc_text, "expected FOSC")
    if fosc_hz != expected_fosc_hz:
        raise ValueError("FOSC {} does not match PIC12F675 design clock {}".format(
            fosc_hz, expected_fosc_hz))
    shell = root / "src/bypass_mcu_pic12f675.c"
    subticks = source_define(shell, "TMR0_SUBTICKS_PER_TICK")
    option = source_hex_define(shell, "OPTION_REG_CONFIG")
    if option & 0x20:
        raise ValueError("OPTION_REG_CONFIG does not clock TMR0 from FOSC/4")
    if not option & 0x08:
        raise ValueError("OPTION_REG_CONFIG assigns the prescaler to TMR0")
    pressed = source_define(root / "src/bypass_config.h", "PRESSED_THRESH")
    released = source_define(root / "src/bypass_config.h", "RELEASE_THRESH")
    mute_ms = source_define(
        root / "src/bypass_output_cd4053_with_mute.h",
        "CD4053_MUTE_DELAY_MS")
    relay_ms = source_define(
        root / "src/bypass_output_tq2_l2_5v_relay.h",
        "TQ2_L2_5V_PULSE_MS")

    # TMR0 is an 8-bit counter clocked at FOSC/4 with no prescaler.
    tick_numerator = subticks * 256 * 4 * 1000000
    if fosc_hz == 0 or tick_numerator % fosc_hz != 0:
        raise ValueError("PIC12F675 tick is not an integral number of microseconds")
    tick_us = tick_numerator // fosc_hz
    blocks = {
        "cd4053_simple": 0,
        "cd4053_with_mute": mute_ms,
        "tq2_l2_5v_relay": relay_ms,
    }
    block_ms = blocks[variant]

    def hold_ms(threshold):
        return (threshold * tick_us + 999) // 1000 + block_ms + 10

    return {
        "fosc_hz": fosc_hz,
        "subticks": subticks,
        "option": option,
        "tick_us": tick_us,
        "block_ms": block_ms,
        "pressed": pressed,
        "released": released,
        "press_hold_ms": hold_ms(pressed),
        "release_hold_ms": hold_ms(released),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=pathlib.Path)
    parser.add_argument("--variant", required=True, choices=VARIANTS)
    parser.add_argument("--fosc-hz", required=True)
    parser.add_argument("--expected-fosc-hz", default="4000000UL")
    parser.add_argument("--format", choices=("defines", "record"), required=True)
    args = parser.parse_args()

    values = derive(args.root.resolve(), args.variant, args.fosc_hz,
                    args.expected_fosc_hz)
    if args.format == "defines":
        print("-DSOAK_TICK_US={}u -DSOAK_ACTUATION_BLOCK_MS={}u".format(
            values["tick_us"], values["block_ms"]))
    else:
        print("PIC12F675_SOAK_TIMING format=1 variant={} fosc_hz={} "
              "option_reg=0x{:02X} subticks={} tick_us={} actuation_block_ms={} pressed_ticks={} "
              "release_ticks={} press_hold_ms={} release_hold_ms={}".format(
                  args.variant, values["fosc_hz"], values["option"],
                  values["subticks"], values["tick_us"], values["block_ms"], values["pressed"],
                  values["released"], values["press_hold_ms"],
                  values["release_hold_ms"]))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        print("FAIL: {}".format(error), file=sys.stderr)
        raise SystemExit(1)
