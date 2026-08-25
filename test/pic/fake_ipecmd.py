#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
"""Stateful fake MPLAB X ipecmd for the PIC12F675 flashing-helper regression.

Real silicon is the one thing this repository cannot put in CI, so the helper's
transaction ORDER and its fail-closed preconditions are proved against a
programmer model instead: a device whose memory persists across invocations, a
recorded argument vector for every call, and one fault knob per way a real
PICkit 3 write can damage a device.

The model is deliberately literal about the thing that matters -- word 0x3FF and
CONFIG BG<1:0> survive a program unless a fault says otherwise -- because the
helper's whole purpose is detecting when they do not.
"""

import json
import os
import signal
import sys


CAL_WORD_ADDR = 0x3FF
CONFIG_WORD_ADDR = 0x2007
DEVICE_ID_WORD_ADDR = 0x2006
BG_MASK = 0x3000
FLASH_WORDS = 0x400
ERASED = 0x3FFF

BANNER = "Microchip MPLAB X IPE v%s"


def state_path():
    path = os.environ.get("FAKE_IPE_STATE")
    if not path:
        sys.stderr.write("fake ipecmd: FAKE_IPE_STATE is unset\n")
        sys.exit(90)
    return path


def load_state():
    path = state_path()
    if not os.path.exists(path):
        # A virgin device: erased program memory, a factory RETLW at 0x3FF, and
        # a CONFIG word whose BG<1:0> field carries the factory bandgap trim.
        state = {
            "words": {str(CAL_WORD_ADDR): 0x3434,
                      str(CONFIG_WORD_ADDR): (ERASED & ~BG_MASK) | 0x2000,
                      str(DEVICE_ID_WORD_ADDR): 0x0FC0},
            "reads": 0,
            "programs": 0,
        }
        for word in range(FLASH_WORDS - 1):
            state["words"][str(word)] = ERASED
        save_state(state)
        return state
    with open(path) as handle:
        return json.load(handle)


def save_state(state):
    with open(state_path(), "w") as handle:
        json.dump(state, handle)


def record_invocation(argv):
    """Append this call's argument vector to the order oracle.

    Each line is prefixed with whether FAKE_IPE_WITNESS existed AT THE MOMENT
    the tool was entered. Pointed at reservation.json, that is what proves the
    durable reservation precedes the write rather than merely accompanying it.
    """
    path = os.environ.get("FAKE_IPE_LOG")
    if not path:
        return
    witness = os.environ.get("FAKE_IPE_WITNESS")
    present = "1" if witness and os.path.exists(witness) else "0"
    with open(path, "a") as handle:
        handle.write("witness=%s\t%s\n" % (present, "\t".join(argv)))


def faults():
    raw = os.environ.get("FAKE_IPE_FAULTS", "")
    parsed = {}
    for item in raw.split(","):
        item = item.strip()
        if not item:
            continue
        name, _, value = item.partition(":")
        parsed[name] = value
    return parsed


def emit_hex(words):
    """Render the device image the way a reader exports it: byte addresses,
    little-endian 14-bit words, 16 bytes per record."""
    memory = {}
    for key, word in words.items():
        address = int(key) * 2
        memory[address] = word & 0xFF
        memory[address + 1] = (word >> 8) & 0xFF
    lines = []
    addresses = sorted(memory)
    index = 0
    while index < len(addresses):
        start = addresses[index]
        payload = []
        while index < len(addresses) and len(payload) < 16 \
                and addresses[index] == start + len(payload):
            payload.append(memory[addresses[index]])
            index += 1
        record = [len(payload), (start >> 8) & 0xFF, start & 0xFF, 0x00] + payload
        record.append((-sum(record)) & 0xFF)
        lines.append(":" + "".join("%02X" % b for b in record))
    lines.append(":00000001FF")
    return "\n".join(lines) + "\n"


def do_read(export_path, state, fault):
    index = state["reads"]
    state["reads"] = index + 1
    version = fault.get("version", "6.20")

    if fault.get("drift") == str(index):
        # The device moved between two reads the helper requires to be equal.
        state["words"]["16"] = 0x0000

    lines = [BANNER % version, "Connecting to MPLAB PICkit 3...",
             "Target voltage detected"]
    if fault.get("noid") != str(index):
        # Reported from device memory, so a fault that swaps the part is
        # observable the way it would be on a bench: in the transcript.
        lines.append("Device ID = 0x%04X" % state["words"][str(DEVICE_ID_WORD_ADDR)])
        lines.append("Revision = 0x000A")
    lines.append("Device Name = PIC12F675")

    if fault.get("readfail") == str(index):
        lines.append("Failed to get Device ID")
        save_state(state)
        sys.stdout.write("\n".join(lines) + "\n")
        return 1

    if fault.get("noexport") != str(index):
        content = emit_hex(state["words"])
        if fault.get("badexport") == str(index):
            content = "this is not intel hex\n"
        elif fault.get("noosccal") == str(index):
            words = dict(state["words"])
            words.pop(str(CAL_WORD_ADDR), None)
            content = emit_hex(words)
        with open(export_path, "w") as handle:
            handle.write(content)
        lines.append("Read complete")
    save_state(state)
    sys.stdout.write("\n".join(lines) + "\n")
    interrupt(fault, "read%d" % index)
    return 0


def interrupt(fault, phase):
    """Kill the helper mid-transaction, the way a pulled cable or a Ctrl-C does.

    A genuine SIGKILL is the only honest way to produce a PENDING evidence
    directory: anything the helper could catch would let it tidy up, and the
    whole point of PENDING is that it cannot.
    """
    if fault.get("killparent") == phase:
        sys.stdout.flush()
        os.kill(os.getppid(), signal.SIGKILL)


def parse_image(path):
    words = {}
    with open(path) as handle:
        memory = {}
        base = 0
        for line in handle:
            line = line.strip()
            if not line.startswith(":"):
                continue
            record = bytes.fromhex(line[1:])
            rtype = record[3]
            offset = (record[1] << 8) | record[2]
            payload = record[4:-1]
            if rtype == 0x00:
                for i, value in enumerate(payload):
                    memory[base + offset + i] = value
            elif rtype == 0x04:
                base = ((payload[0] << 8) | payload[1]) << 16
    for address in sorted(memory):
        if address % 2 or address + 1 not in memory:
            continue
        words[address // 2] = memory[address] | (memory[address + 1] << 8)
    return words


def do_program(image_path, state, fault):
    state["programs"] = state["programs"] + 1
    version = fault.get("version", "6.20")
    lines = [BANNER % version, "Connecting to MPLAB PICkit 3...",
             "Device Name = PIC12F675", "Device ID = 0x0FC0", "Revision = 0x000A",
             "Erasing...", "Programming...", "Verifying..."]

    if fault.get("programfail") is not None:
        lines.append("Programming failed")
        save_state(state)
        sys.stdout.write("\n".join(lines) + "\n")
        return 1

    if fault.get("noprogram") is None:
        image = parse_image(image_path)
        preserved_cal = state["words"][str(CAL_WORD_ADDR)]
        preserved_bg = state["words"][str(CONFIG_WORD_ADDR)] & BG_MASK
        for word in range(FLASH_WORDS - 1):
            state["words"][str(word)] = ERASED
        for address, value in image.items():
            if address == CONFIG_WORD_ADDR:
                continue
            state["words"][str(address)] = value
        if CONFIG_WORD_ADDR in image:
            state["words"][str(CONFIG_WORD_ADDR)] = \
                (image[CONFIG_WORD_ADDR] & ~BG_MASK) | preserved_bg
        state["words"][str(CAL_WORD_ADDR)] = preserved_cal
        if fault.get("eraseosccal") is not None:
            state["words"][str(CAL_WORD_ADDR)] = ERASED
        if fault.get("wrongosccal") is not None:
            state["words"][str(CAL_WORD_ADDR)] = 0x3400 | 0x55
        if fault.get("erasebg") is not None:
            state["words"][str(CONFIG_WORD_ADDR)] |= BG_MASK
        if fault.get("corrupt") is not None:
            # Word 0 is inside every shipping image, so the corruption lands
            # on a byte the post-write comparison actually covers.
            state["words"]["0"] = (state["words"].get("0", ERASED) ^ 0x0001) & 0x3FFF
        if fault.get("newdevice") is not None:
            state["words"][str(DEVICE_ID_WORD_ADDR)] = 0x0FC2
    lines.append("Programming/Verify complete")
    save_state(state)
    sys.stdout.write("\n".join(lines) + "\n")
    interrupt(fault, "program")
    return 0


def main(argv):
    record_invocation(argv)
    fault = faults()
    version = fault.get("version", "6.20")

    if "-?" in argv:
        if fault.get("noversion") is not None:
            sys.stdout.write("usage: ipecmd [options]\n")
        else:
            sys.stdout.write(BANNER % version + "\nusage: ipecmd [options]\n")
        return 0

    export_path = None
    image_path = None
    program = False
    for arg in argv:
        if arg.startswith("-GF"):
            export_path = arg[3:]
        elif arg.startswith("-F"):
            image_path = arg[2:]
        elif arg == "-M":
            program = True

    state = load_state()
    if export_path is not None:
        return do_read(export_path, state, fault)
    if image_path is not None and program:
        return do_program(image_path, state, fault)
    sys.stderr.write("fake ipecmd: unsupported argument vector: %r\n" % (argv,))
    return 91


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
