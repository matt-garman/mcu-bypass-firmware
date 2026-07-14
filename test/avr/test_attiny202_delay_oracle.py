#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
#
# test_attiny202_delay_oracle.py -- verify the ABSOLUTE width of the ATtiny202
# coil-pulse blocking delays directly from the COMPILED IMAGE.
#
# WHY THIS EXISTS (and why the width is NOT checked in the yasimavr harness)
# -------------------------------------------------------------------------
# The relay SET/RESET pulse (12 ms) and the muted-x4053 mute window (5 ms) are
# avr-libc _delay_ms() busy loops (src/bypass_blocking_delay.h). Their duration
# is therefore a pure function of the CPU CYCLE COUNT baked into the image at
# compile time -- expected_ms * F_CPU cycles.
#
# The yasimavr dynamic harness (test_sim_attiny202.py) CANNOT measure that width
# faithfully: yasimavr 0.1.6 is a functional/logic simulator whose AVR core
# charges a flat ~1 cycle per instruction. It does not reproduce the real
# multi-cycle instruction timing of the AVR-XT -- on silicon SBIW is 2 cycles
# and a taken BRNE is 2 cycles (the _delay_ms loop body is 4 cycles/iter), but
# yasimavr executes each as 1 cycle (2 cycles/iter). So every busy-delay runs at
# ~HALF its true wall-clock length in the simulator: a 12 ms pulse traces as
# ~6 ms, a 5 ms mute as ~2.56 ms. (Observed at the instruction level: single-
# stepping the loop shows sbiw -> +1 cyc, brne -> +1 cyc; see the project memory
# note "yasimavr-flat-instruction-timing".) This is a simulator-fidelity limit,
# NOT a firmware defect: the built ELF is correct for real 2 MHz silicon.
#
# yasimavr's TCB0-tick model is independent of instruction timing, so the
# debounce thresholds and LED/state sequencing it checks stay accurate; only the
# raw-cycle busy-delay width is unobservable there. The harness therefore keeps
# the STRUCTURAL pulse checks (a complete pulse of the right polarity, correct
# ordering, coil exclusion) and delegates the ABSOLUTE WIDTH to this oracle,
# which reads the truth straight from the disassembled _delay_ms loop.
#
# WHAT IT CHECKS
#   For each built variant image it disassembles the flash (avr-objdump -d),
#   finds every avr-libc _delay_ms busy loop, recovers its 16-bit iteration
#   count, converts that to milliseconds at F_CPU, and asserts the per-variant
#   expected set of pulse widths (and the relay's 4 ms datasheet minimum):
#       cd4053 (simple x4053): no coil pulse  -> zero delay loops
#       mute   (muted x4053) : two 5 ms mute windows  (engage + bypass paths)
#       relay  (TQ2-L2-5V)   : two 12 ms coil pulses  (engage + bypass paths)
#
# MODES
#   test_attiny202_delay_oracle.py <elf> [<elf> ...]   verify real built images
#   test_attiny202_delay_oracle.py --selftest          host-only parser
#                                                       regression (no ELF/DFP;
#                                                       runs in `make test`)
#
# Exit: 0 = PASS, 1 = a check failed, 2 = bad invocation / tool missing.

import os
import re
import shutil
import subprocess
import sys

# --- device / timing constants (match the shell + the yasimavr harness) ------
F_CPU_HZ = 2_000_000          # 16 MHz OSC / PDIV 8 (see sim_attiny202.F_CPU_HZ)
DELAY_LOOP_CYCLES = 4         # avr-libc _delay_ms body: SBIW(2) + taken BRNE(2)
RELAY_MIN_MS = 4              # TQ2-L2-5V coil-set datasheet minimum

# The absolute width is deterministic (compile-time), so the tolerance only has
# to absorb avr-libc's few-cycle loop-setup/remainder rounding, not simulator
# jitter. One loop iteration is 4 cycles = 2 us here, so +/-0.10 ms is ~50
# iterations of slack -- generous, yet ~1000x tighter than a cycle-accurate ISS
# would give and far inside any physically meaningful margin.
WIDTH_TOLERANCE_MS = 0.10

VARIANTS = ("cd4053", "mute", "relay")

# Expected coil-pulse widths per variant, in milliseconds. Each variant drives
# the pulse on BOTH the engage and the bypass path, so a non-empty set lists the
# design width twice. cd4053 (simple) has no blocking pulse at all.
EXPECTED_WIDTHS_MS = {
    "cd4053": [],
    "mute": [5, 5],
    "relay": [12, 12],
}
# Variants whose pulses must also clear a datasheet minimum coil-energise time.
RELAY_MINIMUM_VARIANTS = ("relay",)

# avr-libc compiles _delay_ms() to a 4-cycle busy loop:
#     ldi  rL, <lo>          ; low  byte of the 16-bit iteration count
#     ldi  rH, <hi>          ; high byte
#   L: sbiw rL, 0x01         ; decrement the count word
#     brne L                 ; loop until zero  (target == the sbiw)
# The `sbiw rL, 0x01` + `brne`-to-self pair is a precise signature: the only
# other back-branches in the image (bss clear, the polled main loop) neither
# decrement a word by one nor branch straight back onto an sbiw. We match that
# pair, then read the count from the two immediately preceding `ldi`s into the
# same low/high register.
_SBIW_RE = re.compile(
    r"^\s*([0-9a-f]+):\s+[0-9a-f ]+\s+sbiw\s+r(\d+),\s*0x0*1\b", re.I)
# The branch displacement in objdump's `.-4` form is relative to the FOLLOWING
# instruction, so we do not recompute it -- we read objdump's own resolved
# absolute target from the trailing `; 0xNNN` comment, which is unambiguous.
_BRNE_RE = re.compile(
    r"^\s*([0-9a-f]+):\s+[0-9a-f ]+\s+brne\s+\.[+-]\d+\s*;\s*0x([0-9a-f]+)", re.I)
_LDI_RE = re.compile(
    r"^\s*[0-9a-f]+:\s+[0-9a-f ]+\s+ldi\s+r(\d+),\s*0x([0-9a-f]+)", re.I)


def _ldi_value(line, want_reg):
    """Return the immediate an `ldi rWANT, 0xNN` line loads, or None."""
    m = _LDI_RE.match(line)
    if not m:
        return None
    if int(m.group(1)) != want_reg:
        return None
    return int(m.group(2), 16)


def parse_delay_loops(objdump_text):
    """Recover the iteration count of every avr-libc _delay_ms busy loop.

    Returns a list of 16-bit iteration counts, one per delay loop, in the order
    they appear in the disassembly. Pure text function so it is exercised both
    against real images and against synthetic snippets in --selftest.
    """
    lines = objdump_text.splitlines()
    counts = []
    for i, line in enumerate(lines):
        sbiw = _SBIW_RE.match(line)
        if not sbiw:
            continue
        sbiw_addr = int(sbiw.group(1), 16)
        low_reg = int(sbiw.group(2))          # sbiw addresses the low register
        high_reg = low_reg + 1

        # The next instruction must be a BRNE back onto this sbiw.
        if i + 1 >= len(lines):
            continue
        brne = _BRNE_RE.match(lines[i + 1])
        if not brne:
            continue
        if int(brne.group(2), 16) != sbiw_addr:
            continue                          # branches elsewhere: not a delay

        # Walk back over the two `ldi`s that seed the count register pair. They
        # are emitted immediately above the loop but tolerate an intervening
        # unrelated instruction or two.
        lo = hi = None
        for j in range(i - 1, max(-1, i - 6), -1):
            if lo is None:
                lo = _ldi_value(lines[j], low_reg)
                if lo is not None:
                    continue
            if hi is None:
                hi = _ldi_value(lines[j], high_reg)
            if lo is not None and hi is not None:
                break
        if lo is None or hi is None:
            sys.stderr.write(
                "WARN: _delay_ms loop at 0x%X missing its ldi seed(s)\n"
                % sbiw_addr)
            continue
        counts.append((hi << 8) | lo)
    return counts


def loop_ms(count, f_cpu=F_CPU_HZ):
    """Convert a _delay_ms loop iteration count to milliseconds at f_cpu."""
    return count * DELAY_LOOP_CYCLES * 1000.0 / f_cpu


class Checker:
    def __init__(self):
        self.fails = 0
        self.checks = 0

    def check(self, ok, msg):
        self.checks += 1
        status = "OK  " if ok else "FAIL"
        stream = sys.stdout if ok else sys.stderr
        stream.write("[delay] %s  %s\n" % (status, msg))
        stream.flush()
        if not ok:
            self.fails += 1
        return ok


def _match_widths(measured_ms, expected_ms):
    """Greedily pair each expected width with a measured one within tolerance.

    Returns (matched_ok, leftover_measured). matched_ok is True only if every
    expected width found a distinct partner AND no measured pulse is left over
    (an extra, unexpected delay is a failure too).
    """
    remaining = list(measured_ms)
    for want in expected_ms:
        hit = None
        for idx, got in enumerate(remaining):
            if abs(got - want) <= WIDTH_TOLERANCE_MS:
                hit = idx
                break
        if hit is None:
            return False, remaining
        remaining.pop(hit)
    return len(remaining) == 0, remaining


def check_variant(ck, variant, counts):
    """Assert the disassembled delay loops match the variant's design timing."""
    measured = sorted(loop_ms(c) for c in counts)
    expected = EXPECTED_WIDTHS_MS[variant]

    matched, leftover = _match_widths(measured, expected)
    pretty = ", ".join("%.3f ms" % m for m in measured) or "(none)"
    ck.check(
        matched,
        "%s: coil-pulse widths [%s] == design %s (+/-%.2f ms)"
        % (variant, pretty, expected or "(none)", WIDTH_TOLERANCE_MS))

    if variant in RELAY_MINIMUM_VARIANTS:
        ck.check(
            bool(measured) and all(m >= RELAY_MIN_MS for m in measured),
            "%s: every coil pulse >= %d ms datasheet minimum (%s)"
            % (variant, RELAY_MIN_MS, pretty))


def variant_of(elf_path):
    """Map an image path (bypass_<variant>_attiny202.elf) to its variant."""
    base = os.path.basename(elf_path)
    for variant in VARIANTS:
        if ("_%s_" % variant) in base:
            return variant
    return None


def disassemble(elf_path):
    objdump = os.environ.get("OBJDUMP", "avr-objdump")
    if shutil.which(objdump) is None:
        sys.stderr.write("ERROR: %s not found (install binutils-avr).\n" % objdump)
        sys.exit(2)
    try:
        return subprocess.check_output(
            [objdump, "-d", elf_path], text=True, stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError as exc:
        sys.stderr.write("ERROR: %s -d %s failed:\n%s\n"
                         % (objdump, elf_path, exc.output))
        sys.exit(2)


def verify_images(elf_paths):
    ck = Checker()
    for elf in elf_paths:
        if not os.path.isfile(elf):
            ck.check(False, "image not found: %s" % elf)
            continue
        variant = variant_of(elf)
        if variant is None:
            ck.check(False, "cannot map %s to a known variant" % elf)
            continue
        counts = parse_delay_loops(disassemble(elf))
        check_variant(ck, variant, counts)
    if not elf_paths:
        ck.check(False, "no ATtiny202 images given to verify")
    print("[delay] %d checks, %d failures" % (ck.checks, ck.fails))
    return 1 if ck.fails else 0


# ----------------------------------------------------------------------------
# Host-only parser regression (no ELF, no DFP). Runs in `make test` so a
# codegen/parse drift or a broken width assertion is caught even where the
# ATtiny_DFP is absent and no image can be built.
# ----------------------------------------------------------------------------
def _synthetic(loops):
    """Build a minimal objdump-style snippet with the given loops.

    `loops` is a list of (low_reg, count) pairs. Emits the exact avr-libc
    ldi/ldi/sbiw/brne shape plus decoy back-branches that must NOT be parsed as
    delays (a bss-style clear and a plain conditional branch).
    """
    out = [
        "0000004a <.do_clear_bss_start>:",
        "  48:\t11 92\tst\tX+, r1",
        "  4e:\te1 f7\tbrne\t.-8      ; 0x48 <.do_clear_bss_loop>",
    ]
    addr = 0x300
    for low_reg, count in loops:
        hi, lo = (count >> 8) & 0xFF, count & 0xFF
        out.append("%4x:\t8f e6\tldi\tr%d, 0x%02X" % (addr, low_reg, lo))
        out.append("%4x:\t97 e1\tldi\tr%d, 0x%02X" % (addr + 2, low_reg + 1, hi))
        out.append("%4x:\t01 97\tsbiw\tr%d, 0x01\t; 1" % (addr + 4, low_reg))
        out.append("%4x:\tf1 f7\tbrne\t.-4      ; 0x%x" % (addr + 6, addr + 4))
        addr += 0x20
    # A decoy: a brne that does NOT target its preceding sbiw.
    out.append("%4x:\t01 97\tsbiw\tr24, 0x01\t; 1" % addr)
    out.append("%4x:\td1 f6\tbrne\t.-72     ; 0x%x" % (addr + 2, addr - 0x40))
    return "\n".join(out)


def selftest():
    ck = Checker()

    # Iteration counts for the real design widths at 2 MHz: ms * F_CPU / 1000 / 4.
    n5 = int(round(5 * F_CPU_HZ / 1000 / DELAY_LOOP_CYCLES))    # 2500
    n12 = int(round(12 * F_CPU_HZ / 1000 / DELAY_LOOP_CYCLES))  # 6000

    # Parser: recovers exactly the delay loops, ignoring the decoys.
    counts = parse_delay_loops(_synthetic([(24, n12), (24, n5)]))
    ck.check(counts == [n12, n5],
             "parser recovers delay counts, skips decoys (got %r)" % counts)

    # Conversion round-trips to the design width.
    ck.check(abs(loop_ms(n12) - 12) <= WIDTH_TOLERANCE_MS, "6000-iter loop == 12 ms")
    ck.check(abs(loop_ms(n5) - 5) <= WIDTH_TOLERANCE_MS, "2500-iter loop == 5 ms")

    # A high register other than r24 (e.g. sbiw r26) still parses.
    ck.check(parse_delay_loops(_synthetic([(26, n5)])) == [n5],
             "parser handles a non-r24 count register")

    # Per-variant acceptance: correct images pass, and the exact avr-libc count
    # actually emitted (off-by-one from rounding) is inside tolerance.
    def counts_for(widths):
        return [int(round(w * F_CPU_HZ / 1000 / DELAY_LOOP_CYCLES)) for w in widths]

    ck.check(_variant_fails("cd4053", []) == 0, "cd4053 with no loops passes")
    ck.check(_variant_fails("mute", counts_for([5, 5])) == 0, "mute with two 5 ms passes")
    ck.check(_variant_fails("relay", [5999, 5999]) == 0,
             "relay with avr-libc's real 5999-iter loops passes")

    # Fail-closed: wrong count, missing pulse, extra pulse, sub-minimum relay.
    ck.check(_variant_fails("relay", counts_for([12, 6])) > 0,
             "relay with a half-width pulse (the yasimavr artifact) fails")
    ck.check(_variant_fails("relay", counts_for([12])) > 0,
             "relay missing a pulse fails")
    ck.check(_variant_fails("mute", counts_for([5, 5, 5])) > 0,
             "mute with an extra unexpected pulse fails")
    ck.check(_variant_fails("cd4053", counts_for([5])) > 0,
             "simple cd4053 with any coil pulse fails")
    # A relay pulse below the 4 ms datasheet minimum trips both width and minimum.
    ck.check(_variant_fails("relay", counts_for([3, 3])) >= 2,
             "sub-minimum relay pulse fails design width AND datasheet minimum")

    print("[delay] selftest: %d checks, %d failures" % (ck.checks, ck.fails))
    return 1 if ck.fails else 0


def _variant_fails(variant, counts):
    """Run check_variant on a silent Checker; return the failure count."""
    import contextlib
    import io
    ck = Checker()
    with contextlib.redirect_stdout(io.StringIO()), \
            contextlib.redirect_stderr(io.StringIO()):
        check_variant(ck, variant, counts)
    return ck.fails


def main(argv):
    if len(argv) >= 2 and argv[1] == "--selftest":
        return selftest()
    if len(argv) < 2:
        sys.stderr.write(
            "usage: %s <image.elf> [<image.elf> ...] | --selftest\n" % argv[0])
        return 2
    return verify_images(argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
