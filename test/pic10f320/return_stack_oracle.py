#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
"""Prove the PIC10F320 final-HEX hardware return-stack bound.

The oracle parses Intel HEX itself, reconstructs little-endian 14-bit program
words, and explores every reachable control-flow state from reset.  A state is
the pair (program counter, exact abstract hardware return stack), so CALL pushes
the address after the CALL and RETURN/RETLW pop that address.  The default bound
is the PIC10F320 architectural limit of eight entries.

Classic mid-range PIC14 control encodings used here (``x`` means operand bits):

    CALL    (word & 0x3800) == 0x2000    encoded target = word & 0x07ff
    GOTO    (word & 0x3800) == 0x2800    encoded target = word & 0x07ff
    BTFSC   (word & 0x3c00) == 0x1800    fall-through and skip successors
    BTFSS   (word & 0x3c00) == 0x1c00    fall-through and skip successors
    DECFSZ  (word & 0x3f00) == 0x0b00    fall-through and skip successors
    INCFSZ  (word & 0x3f00) == 0x0f00    fall-through and skip successors
    RETURN  word == 0x0008               pop exact return address
    RETLW   (word & 0x3c00) == 0x3400    pop exact return address

The decoder accepts only the classic 35-instruction ISA, including its legal
alias ranges: MOVLW is 0x3000..0x33ff and RETLW is 0x3400..0x37ff. Reserved words
fail closed instead of being assigned meanings from a different PIC14 ISA.
RETFIE (0x0009) is legal but rejected because asynchronous entry is outside the
regular direct-call model. Direct PCL writes and writes through classic INDF,
whose FSR-selected destination could be PCL, are rejected for the same reason.

The PIC10F320 architectural program counter is nine bits even though only 256
physical words are implemented. Traversal states, direct targets, sequential and
skip successors, and pushed/popped return addresses stay normalized to
0x000..0x1ff. Only instruction fetch aliases through the low eight bits into
physical words 0x00..0xff. `_word_at` remains strict about receiving a normalized
nine-bit architectural PC.

Interrupts would push asynchronously, outside this control-flow traversal.
Reset starts with GIE clear, so BCF INTCON,GIE and CLRF INTCON are safe; a
reachable BSF INTCON,GIE or any other whole-register write that could set GIE is
rejected.  Thus every possible hardware-stack push is represented explicitly.

Usage:
    return_stack_oracle.py [--limit N] IMAGE.hex [IMAGE.hex ...]
    return_stack_oracle.py --selftest
"""

import argparse
from collections import deque
import os
from pathlib import Path
import re
import stat
import sys
import tempfile


DEFAULT_STACK_LIMIT = 8
ARCH_PC_WORDS = 512
ARCH_PC_MASK = ARCH_PC_WORDS - 1
PHYSICAL_PROGRAM_WORDS = 256
PHYSICAL_PROGRAM_MASK = PHYSICAL_PROGRAM_WORDS - 1
MAX_HEX_BYTES = 1024 * 1024
MAX_CONTROL_STATES = 1_000_000

PCL = 0x02
INTCON = 0x0B
GIE_BIT = 7

_HEX_LINE = re.compile(r":[0-9A-Fa-f]+")

# Classic six-bit byte-oriented opcodes whose d bit selects W (0) or the file
# register (1). MOVWF and CLRF use separate seven-bit encodings below.
_DESTINATION_FILE_OPS = frozenset(
    (
        0x0200,  # SUBWF
        0x0300,  # DECF
        0x0400,  # IORWF
        0x0500,  # ANDWF
        0x0600,  # XORWF
        0x0700,  # ADDWF
        0x0800,  # MOVF
        0x0900,  # COMF
        0x0A00,  # INCF
        0x0B00,  # DECFSZ
        0x0C00,  # RRF
        0x0D00,  # RLF
        0x0E00,  # SWAPF
        0x0F00,  # INCFSZ
    )
)


class OracleError(Exception):
    """An image cannot be proved safe."""


class ImageError(OracleError):
    """The input file or Intel HEX representation is invalid."""


class FlowError(OracleError):
    """Reachable control flow violates the regular bounded-stack model."""

    def __init__(self, message, max_depth, max_witness, witness):
        super().__init__(message)
        self.max_depth = max_depth
        self.max_witness = max_witness
        self.witness = witness


class Analysis:
    """Successful traversal result."""

    def __init__(self, max_depth, witness, state_count):
        self.max_depth = max_depth
        self.witness = witness
        self.state_count = state_count


def _read_regular_file(path):
    """Read path while rejecting links, non-regular files, emptiness, and races."""
    try:
        before = os.lstat(path)
    except OSError as exc:
        raise ImageError("cannot stat image: %s" % exc) from exc
    if stat.S_ISLNK(before.st_mode):
        raise ImageError("image is a symbolic link")
    if not stat.S_ISREG(before.st_mode):
        raise ImageError("image is not a regular file")
    if before.st_size == 0:
        raise ImageError("image file is empty")
    if before.st_size > MAX_HEX_BYTES:
        raise ImageError("image exceeds %d-byte parser limit" % MAX_HEX_BYTES)

    flags = os.O_RDONLY
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        raise ImageError("cannot open image safely: %s" % exc) from exc

    try:
        opened = os.fstat(fd)
        if not stat.S_ISREG(opened.st_mode):
            raise ImageError("opened image is not a regular file")
        if (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino):
            raise ImageError("image changed between path check and open")
        chunks = []
        total = 0
        while True:
            chunk = os.read(fd, min(65536, MAX_HEX_BYTES + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > MAX_HEX_BYTES:
                raise ImageError("image exceeds %d-byte parser limit" % MAX_HEX_BYTES)
        after = os.fstat(fd)
    finally:
        os.close(fd)

    if total == 0:
        raise ImageError("image file is empty")
    unchanged_fields = (
        opened.st_dev == after.st_dev,
        opened.st_ino == after.st_ino,
        opened.st_size == after.st_size == total,
        opened.st_mtime_ns == after.st_mtime_ns,
        opened.st_ctime_ns == after.st_ctime_ns,
    )
    if not all(unchanged_fields):
        raise ImageError("image changed while it was being read")
    return b"".join(chunks)


def _parse_ihex_bytes(raw):
    """Return an absolute byte-address map from strict Intel HEX input."""
    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError as exc:
        raise ImageError("Intel HEX is not ASCII") from exc

    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    if not lines:
        raise ImageError("Intel HEX contains no records")

    memory = {}
    base = 0
    eof_seen = False
    start_kind = None
    data_bytes = 0

    for line_number, line in enumerate(lines, 1):
        if eof_seen:
            raise ImageError("record appears after EOF at line %d" % line_number)
        if line.endswith("\r"):
            line = line[:-1]
        if not line or "\r" in line or not _HEX_LINE.fullmatch(line):
            raise ImageError("malformed Intel HEX record at line %d" % line_number)
        encoded = line[1:]
        if len(encoded) < 10 or len(encoded) % 2:
            raise ImageError("malformed Intel HEX length at line %d" % line_number)
        try:
            record = bytes.fromhex(encoded)
        except ValueError as exc:
            raise ImageError("invalid hex digit at line %d" % line_number) from exc
        count = record[0]
        if len(record) != count + 5:
            raise ImageError("byte count mismatch at line %d" % line_number)
        if sum(record) & 0xFF:
            raise ImageError("checksum mismatch at line %d" % line_number)

        address = (record[1] << 8) | record[2]
        record_type = record[3]
        data = record[4:-1]

        if record_type == 0x00:
            if count == 0:
                raise ImageError("zero-length data record at line %d" % line_number)
            if address + count > 0x10000:
                raise ImageError("data record crosses a 64 KiB boundary at line %d" % line_number)
            absolute = base + address
            if absolute + count - 1 > 0xFFFFFFFF:
                raise ImageError("data address exceeds 32 bits at line %d" % line_number)
            for offset, value in enumerate(data):
                byte_address = absolute + offset
                if byte_address in memory:
                    raise ImageError("overlapping data at byte address 0x%08X" % byte_address)
                memory[byte_address] = value
            data_bytes += count
        elif record_type == 0x01:
            if count != 0 or address != 0 or data:
                raise ImageError("malformed EOF record at line %d" % line_number)
            eof_seen = True
        elif record_type == 0x02:
            if count != 2 or address != 0:
                raise ImageError("malformed extended-segment record at line %d" % line_number)
            base = int.from_bytes(data, "big") << 4
        elif record_type == 0x04:
            if count != 2 or address != 0:
                raise ImageError("malformed extended-linear record at line %d" % line_number)
            base = int.from_bytes(data, "big") << 16
        elif record_type in (0x03, 0x05):
            if count != 4 or address != 0:
                raise ImageError("malformed start-address record at line %d" % line_number)
            if start_kind is not None:
                raise ImageError("multiple start-address records are not allowed")
            start_kind = record_type
        else:
            raise ImageError("unsupported Intel HEX record type 0x%02X at line %d"
                             % (record_type, line_number))

    if not eof_seen:
        raise ImageError("Intel HEX EOF record is missing")
    if data_bytes == 0:
        raise ImageError("Intel HEX image contains no data bytes")
    return memory


def parse_ihex(path):
    """Securely read and strictly parse one Intel HEX file."""
    return _parse_ihex_bytes(_read_regular_file(path))


def _word_at(memory, pc):
    # All architectural successors are normalized before enqueue. A value outside
    # the 9-bit PC here is an oracle bug. Only fetch applies the physical alias.
    if not 0 <= pc < ARCH_PC_WORDS:
        raise ImageError("reachable PC 0x%03X is outside the 9-bit architectural range"
                         % pc)
    physical_pc = pc & PHYSICAL_PROGRAM_MASK
    byte_address = physical_pc * 2
    low = memory.get(byte_address)
    high = memory.get(byte_address + 1)
    if low is None or high is None:
        missing = []
        if low is None:
            missing.append("low")
        if high is None:
            missing.append("high")
        raise ImageError(
            "reachable instruction hole at architectural PC 0x%03X / physical word "
            "0x%02X (missing %s byte)" % (pc, physical_pc, "/".join(missing)))
    word = low | (high << 8)
    if word & 0xC000:
        raise ImageError("reachable word 0x%04X at PC 0x%03X is not a 14-bit instruction"
                         % (word, pc))
    return word


def _normalize_pc(pc):
    """Normalize a control-flow value to the PIC10F320's 9-bit PC."""
    return pc & ARCH_PC_MASK


def _file_write(word):
    """Return the direct seven-bit file destination, or None for no write."""
    opcode = word & 0x3F00
    if (word & 0x3F80) in (0x0080, 0x0180):  # MOVWF f, CLRF f
        return word & 0x7F
    if opcode in _DESTINATION_FILE_OPS and word & 0x0080:
        return word & 0x7F
    if (word & 0x3C00) in (0x1000, 0x1400):  # BCF f,b; BSF f,b
        return word & 0x7F
    return None


def _is_clrf(word, file_register):
    return (word & 0x3F80) == 0x0180 and (word & 0x7F) == file_register


def _is_bsf(word, file_register, bit):
    return ((word & 0x3C00) == 0x1400 and (word & 0x7F) == file_register
            and ((word >> 7) & 0x7) == bit)


def _intcon_write_preserves_disabled_gie(word):
    """True when a direct INTCON write cannot change a clear GIE bit to one."""
    if _is_clrf(word, INTCON):
        return True
    if (word & 0x3C00) == 0x1000:  # BCF of any INTCON bit
        return True
    if ((word & 0x3C00) == 0x1400  # BSF of any bit other than GIE
            and ((word >> 7) & 0x7) != GIE_BIT):
        return True
    # ANDWF cannot turn a clear bit into one; MOVF INTCON,F preserves it.
    return ((word & 0x3F00) in (0x0500, 0x0800) and word & 0x0080)


def _is_legal_instruction(word):
    """Return whether word is in the classic 35-instruction mid-range ISA."""
    if word in (0x0008, 0x0009, 0x0063, 0x0064):  # RETURN/RETFIE/SLEEP/CLRWDT
        return True
    if (word & 0x3F9F) == 0x0000:  # NOP, including documented don't-care aliases
        return True
    if (word & 0x3F80) in (0x0080, 0x0100, 0x0180):  # MOVWF/CLRW/CLRF
        return True
    if (word & 0x3F00) in _DESTINATION_FILE_OPS:
        return True
    if (word & 0x3000) == 0x1000:  # BCF/BSF/BTFSC/BTFSS
        return True
    if (word & 0x3800) in (0x2000, 0x2800):  # CALL/GOTO
        return True
    if (word & 0x3C00) in (0x3000, 0x3400):  # MOVLW/RETLW aliases
        return True
    if (word & 0x3E00) in (0x3C00, 0x3E00):  # SUBLW/ADDLW aliases
        return True
    if (word & 0x3F00) in (0x3800, 0x3900, 0x3A00):  # IORLW/ANDLW/XORLW
        return True
    return False


def _mnemonic(word):
    if word == 0x0008:
        return "RETURN"
    if word == 0x0009:
        return "RETFIE"
    if (word & 0x3800) == 0x2000:
        return "CALL"
    if (word & 0x3800) == 0x2800:
        return "GOTO"
    if (word & 0x3C00) == 0x1800:
        return "BTFSC"
    if (word & 0x3C00) == 0x1C00:
        return "BTFSS"
    if (word & 0x3F00) == 0x0B00:
        return "DECFSZ"
    if (word & 0x3F00) == 0x0F00:
        return "INCFSZ"
    if (word & 0x3C00) == 0x3400:
        return "RETLW"
    if (word & 0x3C00) == 0x3000:
        return "MOVLW"
    return "instruction 0x%04X" % word


def analyze(memory, limit=DEFAULT_STACK_LIMIT):
    """Traverse reachable control flow while carrying the exact return stack."""
    if isinstance(limit, bool) or not isinstance(limit, int) or limit <= 0:
        raise ValueError("return-stack limit must be a positive integer")

    initial_witness = ("reset@0x000",)
    queue = deque([(0, (), initial_witness)])
    seen = {(0, ())}
    max_depth = 0
    max_witness = initial_witness

    def fail(message, witness):
        raise FlowError(message, max_depth, max_witness, witness)

    def enqueue(pc, stack, witness):
        if not 0 <= pc < ARCH_PC_WORDS:
            raise AssertionError("successor PC was not normalized: %r" % (pc,))
        if any(not 0 <= return_pc < ARCH_PC_WORDS for return_pc in stack):
            raise AssertionError("return stack contains a non-normalized PC")
        state = (pc, stack)
        if state in seen:
            return
        if len(seen) >= MAX_CONTROL_STATES:
            fail("reachable control-flow state limit exceeded", witness)
        seen.add(state)
        queue.append((pc, stack, witness))

    while queue:
        pc, stack, witness = queue.popleft()
        try:
            word = _word_at(memory, pc)
        except ImageError as exc:
            fail(str(exc), witness + ("hole@0x%03X" % pc,))
        name = _mnemonic(word)
        at_instruction = witness + ("%s@0x%03X" % (name, pc),)

        if word == 0x0009:
            fail("reachable RETFIE is unsupported non-regular control flow",
                 at_instruction)
        if not _is_legal_instruction(word):
            fail("reachable word 0x%04X is not a legal classic PIC14 instruction"
                 % word, at_instruction)

        destination = _file_write(word)
        if destination == 0:
            fail("reachable write through classic INDF could target PCL or enable GIE",
                 at_instruction)
        if destination == PCL:
            fail("reachable computed PCL write", at_instruction)
        if destination == INTCON:
            if _is_bsf(word, INTCON, GIE_BIT):
                fail("reachable BSF INTCON,GIE could add asynchronous stack pushes",
                     at_instruction)
            if not _intcon_write_preserves_disabled_gie(word):
                fail("reachable INTCON write could enable GIE",
                     at_instruction)

        if word == 0x0008 or (word & 0x3C00) == 0x3400:
            if not stack:
                fail("reachable %s with an empty hardware return stack" % name,
                     at_instruction)
            return_pc = _normalize_pc(stack[-1])
            enqueue(return_pc, stack[:-1],
                    witness + ("%s@0x%03X -> 0x%03X (depth %d)"
                               % (name, pc, return_pc, len(stack) - 1),))
        elif (word & 0x3800) == 0x2000:
            target = _normalize_pc(word & 0x07FF)
            return_pc = _normalize_pc(pc + 1)
            if return_pc in stack:
                fail("reachable recursive CALL at PC 0x%03X" % pc, at_instruction)
            new_depth = len(stack) + 1
            call_witness = witness + (
                "CALL@0x%03X -> 0x%03X (return 0x%03X, depth %d)"
                % (pc, target, return_pc, new_depth),
            )
            if new_depth > limit:
                fail("return-stack depth %d exceeds architectural limit %d"
                     % (new_depth, limit), call_witness)
            if new_depth > max_depth:
                max_depth = new_depth
                max_witness = call_witness
            enqueue(target, stack + (return_pc,), call_witness)
        elif (word & 0x3800) == 0x2800:
            target = _normalize_pc(word & 0x07FF)
            enqueue(target, stack,
                    witness + ("GOTO@0x%03X -> 0x%03X" % (pc, target),))
        elif ((word & 0x3C00) in (0x1800, 0x1C00)
              or (word & 0x3F00) in (0x0B00, 0x0F00)):
            no_skip_pc = _normalize_pc(pc + 1)
            skip_pc = _normalize_pc(pc + 2)
            enqueue(no_skip_pc, stack,
                    witness + ("%s@0x%03X no-skip -> 0x%03X"
                               % (name, pc, no_skip_pc),))
            enqueue(skip_pc, stack,
                    witness + ("%s@0x%03X skip -> 0x%03X"
                               % (name, pc, skip_pc),))
        else:
            enqueue(_normalize_pc(pc + 1), stack, witness)

    return Analysis(max_depth, max_witness, len(seen))


def _format_witness(witness):
    return " -> ".join(witness)


def verify_images(paths, limit):
    failures = 0
    for path in paths:
        try:
            memory = parse_ihex(path)
            result = analyze(memory, limit)
        except FlowError as exc:
            failures += 1
            print("FAIL: %s: %s" % (path, exc), file=sys.stderr)
            print("  max depth before rejection: %d/%d" % (exc.max_depth, limit),
                  file=sys.stderr)
            print("  witness: %s" % _format_witness(exc.witness), file=sys.stderr)
        except (ImageError, OSError) as exc:
            failures += 1
            print("FAIL: %s: %s" % (path, exc), file=sys.stderr)
            print("  max depth: unavailable (image rejected before traversal)",
                  file=sys.stderr)
            print("  witness: input validation", file=sys.stderr)
        else:
            print("PASS: %s: max return-stack depth %d/%d (%d reachable states)"
                  % (path, result.max_depth, limit, result.state_count))
            print("  witness: %s" % _format_witness(result.witness))
    return 1 if failures else 0


# ---------------------------------------------------------------------------
# Deterministic host-only regression fixtures.  These use the same secure file
# reader, HEX parser, decoder, and traversal as real images.
# ---------------------------------------------------------------------------
def _record(address, record_type, data=b""):
    body = bytes((len(data), (address >> 8) & 0xFF, address & 0xFF, record_type)) + data
    checksum = (-sum(body)) & 0xFF
    return ":" + (body + bytes((checksum,))).hex().upper()


def _image_bytes(words, extra=None, eof=True):
    byte_map = {}
    for pc, word in words.items():
        byte_map[pc * 2] = word & 0xFF
        byte_map[pc * 2 + 1] = (word >> 8) & 0xFF
    if extra:
        byte_map.update(extra)

    records = []
    addresses = sorted(byte_map)
    index = 0
    while index < len(addresses):
        start = addresses[index]
        chunk = [byte_map[start]]
        index += 1
        while (index < len(addresses) and len(chunk) < 16
               and addresses[index] == start + len(chunk)
               and start + len(chunk) <= 0xFFFF):
            chunk.append(byte_map[addresses[index]])
            index += 1
        if start > 0xFFFF:
            raise ValueError("selftest emitter only supports 16-bit fixture addresses")
        records.append(_record(start, 0x00, bytes(chunk)))
    if eof:
        records.append(_record(0, 0x01))
    return ("\n".join(records) + "\n").encode("ascii")


def _call(target):
    return 0x2000 | target


def _goto(target):
    return 0x2800 | target


def _chain(depth):
    if depth == 0:
        return {0: _goto(0)}
    words = {0: _call(2), 1: _goto(1)}
    for level in range(1, depth + 1):
        pc = level * 2
        if level == depth:
            words[pc] = 0x0008
        else:
            words[pc] = _call(pc + 2)
            words[pc + 1] = 0x0008
    return words


class _SelftestChecker:
    def __init__(self):
        self.checks = 0
        self.failures = 0

    def check(self, condition, message):
        self.checks += 1
        if not condition:
            self.failures += 1
            print("[pic320-stack] FAIL: %s" % message, file=sys.stderr)
        else:
            print("[pic320-stack] OK:   %s" % message)


def selftest():
    checker = _SelftestChecker()
    with tempfile.TemporaryDirectory(prefix="pic320-return-stack-") as temporary:
        root = Path(temporary)

        def write(name, raw):
            path = root / name
            path.write_bytes(raw)
            return path

        def run_words(name, words, limit=DEFAULT_STACK_LIMIT, extra=None):
            path = write(name + ".hex", _image_bytes(words, extra=extra))
            return analyze(parse_ihex(path), limit)

        def expect_pass(name, words, depth, limit=DEFAULT_STACK_LIMIT, extra=None):
            try:
                result = run_words(name, words, limit=limit, extra=extra)
            except OracleError as exc:
                checker.check(False, "%s should pass, rejected: %s" % (name, exc))
                return
            checker.check(result.max_depth == depth,
                          "%s passes at depth %d (got %d)" % (name, depth, result.max_depth))

        def expect_flow_reject(name, words, fragment, limit=DEFAULT_STACK_LIMIT):
            try:
                run_words(name, words, limit=limit)
            except FlowError as exc:
                checker.check(fragment in str(exc),
                              "%s rejects with %r (%s)" % (name, fragment, exc))
            except OracleError as exc:
                checker.check(False, "%s rejected in the wrong layer: %s" % (name, exc))
            else:
                checker.check(False, "%s should be rejected" % name)

        def expect_image_reject(name, path, fragment):
            try:
                analyze(parse_ihex(path))
            except ImageError as exc:
                checker.check(fragment in str(exc),
                              "%s rejects with %r (%s)" % (name, fragment, exc))
            except OracleError as exc:
                checker.check(False, "%s rejected in the wrong layer: %s" % (name, exc))
            else:
                checker.check(False, "%s should be rejected" % name)

        def expect_path_pass(name, path, depth):
            try:
                result = analyze(parse_ihex(path))
            except OracleError as exc:
                checker.check(False, "%s should pass, rejected: %s" % (name, exc))
                return
            checker.check(result.max_depth == depth,
                          "%s passes at depth %d (got %d)"
                          % (name, depth, result.max_depth))

        def expect_path_flow_reject(name, path, fragment):
            try:
                analyze(parse_ihex(path))
            except FlowError as exc:
                checker.check(fragment in str(exc),
                              "%s rejects with %r (%s)" % (name, fragment, exc))
            except OracleError as exc:
                checker.check(False, "%s rejected in the wrong layer: %s" % (name, exc))
            else:
                checker.check(False, "%s should be rejected" % name)

        def expect_observation(name, words, predicate, detail):
            try:
                result = run_words(name, words)
            except OracleError as exc:
                checker.check(False, "%s should pass, rejected: %s" % (name, exc))
                return
            checker.check(predicate(result), "%s: %s" % (name, detail))

        for depth in (0, 1, 4, 8):
            expect_pass("passing-depth-%d" % depth, _chain(depth), depth)
        expect_flow_reject("failing-depth-9", _chain(9), "exceeds architectural limit")
        expect_pass("configured-limit-2", _chain(2), 2, limit=2)
        expect_flow_reject("configured-limit-1", _chain(2), "architectural limit 1", limit=1)

        expect_flow_reject("self-recursion", {0: _call(0), 1: _goto(1)}, "recursive CALL")
        expect_flow_reject(
            "mutual-recursion",
            {0: _call(2), 1: _goto(1), 2: _call(0), 3: 0x0008},
            "recursive CALL",
        )

        expect_observation(
            "call-target-bit8-preserved",
            {0: _call(0x102), 1: _goto(1), 2: 0x0008},
            lambda result: (result.max_depth == 1
                            and "CALL@0x000 -> 0x102" in _format_witness(result.witness)),
            "CALL target remains architectural 0x102 while fetching physical word 0x02",
        )
        expect_observation(
            "call-target-bits10-9-alias",
            {0: _call(0x702), 1: _goto(1), 2: 0x0008},
            lambda result: (result.max_depth == 1
                            and "CALL@0x000 -> 0x102" in _format_witness(result.witness)),
            "encoded 0x702 aliases to architectural 0x102, not 0x002",
        )
        expect_observation(
            "goto-target-bit8-preserved-bits10-9-alias",
            {0: _goto(0x701), 1: 0x0000, 2: _call(4),
             3: _goto(3), 4: 0x0008},
            lambda result: (result.max_depth == 1
                            and "GOTO@0x000 -> 0x101" in _format_witness(result.witness)
                            and "CALL@0x102 -> 0x004 (return 0x103"
                            in _format_witness(result.witness)),
            "GOTO reaches 0x101 and sequential execution preserves architectural bit 8",
        )
        expect_observation(
            "sequential-physical-alias-boundary",
            {0: _goto(0x0FF), 0xFF: 0x0000},
            lambda result: result.max_depth == 0 and result.state_count == 3,
            "0x0ff increments to state 0x100, whose fetch aliases physical word 0x00",
        )
        expect_observation(
            "skip-physical-alias-boundary",
            {0: _goto(0x0FF), 1: _goto(1), 0xFF: 0x1820},
            lambda result: result.max_depth == 0 and result.state_count == 5,
            "at 0x0ff no-skip reaches 0x100 and skip reaches 0x101",
        )
        expect_observation(
            "sequential-nine-bit-rollover",
            {0: _goto(0x1FF), 0xFF: 0x0000},
            lambda result: result.max_depth == 0 and result.state_count == 2,
            "architectural 0x1ff increments to 0x000",
        )
        expect_observation(
            "skip-nine-bit-rollover",
            {0: _goto(0x1FF), 1: _goto(1), 0xFF: 0x1820},
            lambda result: result.max_depth == 0 and result.state_count == 3,
            "at 0x1ff no-skip reaches 0x000 and skip reaches 0x001",
        )
        expect_observation(
            "call-return-address-preserves-bit8",
            {0: _goto(0x0FF), 1: 0x0008, 0xFF: _call(1)},
            lambda result: (result.max_depth == 1 and result.state_count == 4
                            and "CALL@0x0FF -> 0x001 (return 0x100"
                            in _format_witness(result.witness)),
            "CALL at 0x0ff pushes architectural return address 0x100",
        )
        expect_observation(
            "call-return-address-nine-bit-rollover",
            {0: _goto(0x1FF), 1: 0x0008, 0xFF: _call(1)},
            lambda result: (result.max_depth == 1 and result.state_count == 3
                            and "CALL@0x1FF -> 0x001 (return 0x000"
                            in _format_witness(result.witness)),
            "CALL at 0x1ff pushes rolled-over return address 0x000",
        )

        skip_cases = (
            ("btfsc-min", 0x1800),
            ("btfsc-max", 0x1BFF),
            ("btfss-min", 0x1C00),
            ("btfss-max", 0x1FFF),
            ("decfsz-d0-min", 0x0B00),
            ("decfsz-d0-max", 0x0B7F),
            ("decfsz-d1-min", 0x0B81),
            ("decfsz-d1-max", 0x0BFF),
            ("incfsz-d0-min", 0x0F00),
            ("incfsz-d0-max", 0x0F7F),
            ("incfsz-d1-min", 0x0F81),
            ("incfsz-d1-max", 0x0FFF),
        )
        for skip_name, opcode in skip_cases:
            skip_deeper_words = {
                0: opcode,
                1: _goto(1),
                2: _call(4),
                3: _goto(3),
                4: _call(6),
                5: 0x0008,
                6: _call(8),
                7: 0x0008,
                8: 0x0008,
            }
            expect_pass("%s-skip-edge-required" % skip_name,
                        skip_deeper_words, 3)
            no_skip_deeper_words = {
                0: opcode,
                1: _call(3),
                2: _goto(2),
                3: _call(5),
                4: 0x0008,
                5: _call(7),
                6: 0x0008,
                7: 0x0008,
            }
            expect_pass("%s-no-skip-edge-required" % skip_name,
                        no_skip_deeper_words, 3)

        expect_pass(
            "tail-goto",
            {0: _call(2), 1: _goto(1), 2: _goto(4), 3: 0x0000, 4: 0x0008},
            1,
        )
        expect_pass(
            "return",
            {0: _call(2), 1: _goto(1), 2: 0x0008},
            1,
        )
        expect_pass(
            "nested-return-lifo",
            {0: _call(4), 1: _call(10), 2: _goto(2),
             4: _call(6), 5: 0x0008, 6: 0x0008,
             10: _call(12), 11: 0x0008,
             12: _call(14), 13: 0x0008, 14: 0x0008},
            3,
        )
        expect_pass(
            "nested-retlw-lifo",
            {0: _call(4), 1: _call(10), 2: _goto(2),
             4: _call(6), 5: 0x35A5, 6: 0x3400,
             10: _call(12), 11: 0x365A,
             12: _call(14), 13: 0x37FF, 14: 0x34C3},
            3,
        )
        expect_pass(
            "retlw-alias-range",
            {0: _call(8), 1: _call(9), 2: _call(10), 3: _call(11),
             4: _goto(4), 5: 0x0000, 6: 0x0000, 7: 0x0000,
             8: 0x3400, 9: 0x35A5, 10: 0x365A, 11: 0x37FF},
            1,
        )
        expect_pass(
            "movlw-alias-range",
            {0: 0x3000, 1: 0x31A5, 2: 0x325A, 3: 0x33FF, 4: _goto(4)},
            0,
        )
        expect_pass(
            "classic-literal-aliases",
            {0: 0x3800, 1: 0x39A5, 2: 0x3A5A, 3: 0x3C00,
             4: 0x3DFF, 5: 0x3E00, 6: 0x3FFF, 7: _goto(7)},
            0,
        )
        expect_pass(
            "nop-and-clrw-aliases",
            {0: 0x0000, 1: 0x0020, 2: 0x0040, 3: 0x0060,
             4: 0x0100, 5: 0x017F, 6: _goto(6)},
            0,
        )
        expect_pass("sleep-and-clrwdt",
                    {0: 0x0063, 1: 0x0064, 2: _goto(2)}, 0)

        def independent_classic_legality(word):
            # Independently expressed as contiguous ranges from the 35-opcode
            # table, not in terms of the production decoder's masks or sets.
            fixed = (0x0000, 0x0008, 0x0009, 0x0020,
                     0x0040, 0x0060, 0x0063, 0x0064)
            return (word in fixed
                    or 0x0080 <= word <= 0x2FFF
                    or 0x3000 <= word <= 0x3AFF
                    or 0x3C00 <= word <= 0x3FFF)

        legality_mismatches = [
            word for word in range(0x4000)
            if _is_legal_instruction(word) != independent_classic_legality(word)
        ]
        checker.check(
            not legality_mismatches,
            "all 16,384 words match independent classic-ISA legality map%s"
            % ((" (first mismatch 0x%04X)" % legality_mismatches[0])
               if legality_mismatches else ""),
        )

        expect_flow_reject("empty-return", {0: 0x0008}, "empty hardware return stack")
        for alias in (0x3400, 0x35A5, 0x365A, 0x37FF):
            expect_flow_reject("empty-retlw-%04x" % alias, {0: alias},
                               "empty hardware return stack")
        expect_pass(
            "unreachable-call-and-config-ignored",
            {0: _goto(0), 10: _call(10)},
            0,
            extra={0x400E: 0x9E, 0x400F: 0x38},
        )

        expect_flow_reject("retfie", {0: 0x0009}, "RETFIE")
        for reserved in (0x0001, 0x000A, 0x000B, 0x0010, 0x0018, 0x3B00):
            expect_flow_reject("reserved-classic-word-%04x" % reserved,
                               {0: reserved}, "not a legal classic PIC14 instruction")
        # Independent literal inventory of every classic instruction class that
        # can write a file destination. The bool states whether this exact class
        # preserves a reset-clear GIE bit when directed to INTCON.
        destination_classes = (
            ("movwf",   0x0080, False),
            ("clrf",    0x0180, True),
            ("subwf-f", 0x0280, False),
            ("decf-f",  0x0380, False),
            ("iorwf-f", 0x0480, False),
            ("andwf-f", 0x0580, True),
            ("xorwf-f", 0x0680, False),
            ("addwf-f", 0x0780, False),
            ("movf-f",  0x0880, True),
            ("comf-f",  0x0980, False),
            ("incf-f",  0x0A80, False),
            ("decfsz-f", 0x0B80, False),
            ("rrf-f",   0x0C80, False),
            ("rlf-f",   0x0D80, False),
            ("swapf-f", 0x0E80, False),
            ("incfsz-f", 0x0F80, False),
            ("bcf-b0",  0x1000, True),
            ("bsf-b0",  0x1400, True),
        )
        for opcode_name, opcode, intcon_safe in destination_classes:
            expect_flow_reject("computed-pcl-%s" % opcode_name,
                               {0: opcode | PCL},
                               "computed PCL write")
            expect_flow_reject("classic-indf-%s" % opcode_name,
                               {0: opcode}, "classic INDF")
            intcon_word = opcode | INTCON
            if intcon_safe:
                expect_pass("intcon-safe-%s" % opcode_name,
                            {0: intcon_word, 1: _goto(1)}, 0)
            else:
                expect_flow_reject("intcon-dangerous-%s" % opcode_name,
                                   {0: intcon_word}, "could enable GIE")
        expect_flow_reject("intcon-dangerous-bsf-gie", {0: 0x178B},
                           "INTCON,GIE")
        expect_pass("intcon-safe-bcf-gie", {0: 0x138B, 1: _goto(1)}, 0)

        # Literal, precomputed Intel HEX: PC 0 GOTO 2; PC 2 CALL 4; PC 3
        # GOTO 3; PC 4 RETLW. The second record begins at byte address 4 and
        # each word is low-byte first, independently pinning both conventions.
        literal_hex = write(
            "literal-layout.hex",
            b":020000000228D4\n"
            b":0600040004200328A534CE\n"
            b":00000001FF\n",
        )
        try:
            literal_memory = parse_ihex(literal_hex)
            literal_result = analyze(literal_memory)
            literal_ok = (_word_at(literal_memory, 2) == 0x2004
                          and _word_at(literal_memory, 4) == 0x34A5
                          and literal_result.max_depth == 1)
        except OracleError:
            literal_ok = False
        checker.check(literal_ok,
                      "literal HEX pins little-endian words and byte-address scaling")

        valid = write("valid.hex", _image_bytes({0: _goto(0)}))
        malformed_raw = bytearray(_image_bytes({0: _goto(0)}))
        malformed_raw[10] = ord("0") if malformed_raw[10] != ord("0") else ord("1")
        malformed = write("malformed.hex", bytes(malformed_raw))
        expect_image_reject("malformed-checksum", malformed, "checksum mismatch")

        count_line = _record(0, 0x00, b"\x00\x28")
        bad_count = write(
            "bad-count.hex",
            (":" + "03" + count_line[3:] + "\n" + _record(0, 0x01) + "\n").encode("ascii"),
        )
        expect_image_reject("malformed-count", bad_count, "byte count mismatch")

        bad_type = write(
            "bad-record-type.hex",
            ("\n".join((_record(0, 0x06), _record(0, 0x01))) + "\n").encode("ascii"),
        )
        expect_image_reject("unsupported-record-type", bad_type,
                            "unsupported Intel HEX record type")

        after_eof = write(
            "after-eof.hex",
            ("\n".join((_record(0, 0x00, b"\x00\x28"),
                         _record(0, 0x01), _record(2, 0x00, b"\x00\x00")))
             + "\n").encode("ascii"),
        )
        expect_image_reject("record-after-eof", after_eof, "record appears after EOF")

        non_ascii = write("non-ascii.hex", b":00000001FF\n\xFF\n")
        expect_image_reject("non-ascii", non_ascii, "not ASCII")

        missing_eof = write("missing-eof.hex", _image_bytes({0: _goto(0)}, eof=False))
        expect_image_reject("missing-eof", missing_eof, "EOF record is missing")

        empty = write("empty.hex", b"")
        expect_image_reject("empty-file", empty, "file is empty")
        eof_only = write("eof-only.hex", (_record(0, 0x01) + "\n").encode("ascii"))
        expect_image_reject("empty-image", eof_only, "contains no data bytes")

        symlink = root / "symlink.hex"
        symlink.symlink_to(valid.name)
        expect_image_reject("symlink", symlink, "symbolic link")
        directory = root / "directory.hex"
        directory.mkdir()
        expect_image_reject("nonregular", directory, "not a regular file")

        overlap_raw = ("\n".join((
            _record(0, 0x00, b"\x00\x28"),
            _record(1, 0x00, b"\x28"),
            _record(0, 0x01),
        )) + "\n").encode("ascii")
        overlap = write("overlap.hex", overlap_raw)
        expect_image_reject("overlap", overlap, "overlapping data")

        expect_flow_reject("reachable-hole", {0: _goto(2)},
                           "reachable instruction hole")
        single_byte = write(
            "single-byte-program.hex",
            ("\n".join((_record(0, 0x00, b"\x00"), _record(0, 0x01)))
             + "\n").encode("ascii"),
        )
        expect_path_flow_reject("single-byte-program", single_byte,
                                "reachable instruction hole")
        expect_flow_reject("non-14-bit-word", {0: 0xC000},
                           "not a 14-bit instruction")

        extended = write(
            "extended-address.hex",
            ("\n".join((
                _record(0, 0x04, b"\x00\x01"),
                _record(0, 0x00, b"\xAA\x55"),
                _record(0, 0x04, b"\x00\x00"),
                _record(0, 0x00, b"\x00\x28"),
                _record(0, 0x01),
            )) + "\n").encode("ascii"),
        )
        expect_path_pass("unreachable-extended-address-data", extended, 0)
        bad_extended = write(
            "bad-extended-address.hex",
            ("\n".join((_record(0, 0x04, b"\x01"), _record(0, 0x01)))
             + "\n").encode("ascii"),
        )
        expect_image_reject("malformed-extended-address", bad_extended,
                            "malformed extended-linear record")
        missing = root / "missing.hex"
        expect_image_reject("missing-file", missing, "cannot stat image")

    print("[pic320-stack] selftest: %d checks, %d failures"
          % (checker.checks, checker.failures))
    return 1 if checker.failures else 0


def _positive_limit(text):
    try:
        value = int(text, 10)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("limit must be a positive decimal integer") from exc
    if value <= 0:
        raise argparse.ArgumentTypeError("limit must be a positive decimal integer")
    return value


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--limit", type=_positive_limit, default=DEFAULT_STACK_LIMIT,
                        help="architectural return-stack limit (default: %(default)s)")
    parser.add_argument("--selftest", action="store_true",
                        help="run deterministic dependency-free fixtures")
    parser.add_argument("images", metavar="IMAGE.hex", nargs="*")
    args = parser.parse_args(argv)
    if args.selftest:
        if args.images:
            parser.error("--selftest does not accept image paths")
        if args.limit != DEFAULT_STACK_LIMIT:
            parser.error("--selftest uses the architectural default limit")
        return selftest()
    if not args.images:
        parser.error("at least one IMAGE.hex is required")
    return verify_images(args.images, args.limit)


if __name__ == "__main__":
    sys.exit(main())
