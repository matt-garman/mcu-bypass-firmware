#!/usr/bin/env python3
"""Every fuse byte the Makefile injects reaches the checker, and reaches it intact.

THE DEFECT CLASS. `-D<MACRO>=$(VARIABLE)` is a name contract whose two halves
nothing joins: the Makefile spells the macro on the compile line, the C file
spells it again in an `#ifndef`. The four Makefile name-contract axes
deliberately do not cover it -- the C macro names are the firmware's and the
tests' own interface and were NOT renamed alongside the Make variables in
v0.9.8 -- so a macro renamed on either side severs in silence whenever the C
side carries a default.

test/avr/test_fuses.c carried one for all eleven bytes, and TEN of the eleven
defaults were exactly the current values. Compiling with the real -D set minus
-DT85_LFUSE printed "fuse checks: 46 checks, 0 failures" and exited 0: the one
gate standing between a fat-fingered fuse edit and a bench session, passing
without reading the Makefile at all. Only T13_LFUSE failed, and only because its
default had gone stale. The defaults are gone (2026-08-03) -- this keeps them
gone, and checks the rest of the trip.

WHAT IS CHECKED, in the order a value travels:

  BURNED == INJECTED   the variables the avrdude recipes write to silicon are
                       exactly the variables the checker is compiled with. A
                       checker verifying a byte no flash target burns is
                       decoration, and it would look identical from inside.
  INJECTED == GUARDED  compile line and C file name the same macros; each
                       `#error` names the variable the Makefile really pairs it
                       with; no injected macro has an in-source default.
  GUARDED == PRINTED   every injected macro reaches the program's output, one
                       for one, so a byte cannot be injected and then ignored.
  VALUE                each printed byte equals `make -s print-<VARIABLE>`.

The last link is the only one that catches a VALUE drift as well as a name one,
and it is not redundant with the checker's own assertions: T13_LFUSE bit 6
(EESAVE) is read by no assertion in that file, so an lfuse disagreeing with the
Makefile in that bit alone passes every check the checker makes. The negative
case below builds exactly that binary and requires this gate to catch it.

HERMETIC ON PURPOSE. All three binaries here are built into a scratch directory
from the compile line `make -n` prints -- the real command, not a reconstruction
-- and never from test/avr/test_fuses in the tree. So a stale checker cannot
make this gate fail, and this gate's negative cases cannot disturb the tree's.

SCOPE, stated so the next reader does not over-trust it. This covers the eleven
fuse bytes. The Makefile passes many other -D macros, most of them workload
knobs where an in-source default is correct behaviour (SIM_*, MODEL_FUZZ_*);
classifying the rest into "default is meaningful" and "must be injected" is an
open TODO item, and a severed -DSOAK_DURATION_MS is the one with teeth. A second
hand-written copy of these eleven names lives in test/test_workload_rebuild.sh's
fake compiler; it is left alone because it fails CLOSED -- a name it does not
recognize makes that fake compiler exit 1.
"""

import os
import re
import shlex
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARGET = "test/avr/test_fuses"
SOURCE = os.path.join(ROOT, TARGET + ".c")

# A floor, so a harvest that quietly stops matching cannot pass by checking a
# handful. Lower it deliberately if a part is genuinely retired.
FLOOR = 11


def fail(msg):
    sys.exit(f"FAIL: {msg}")


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def run_make(*args):
    """Run make from ROOT.

    _MAKE_SERIAL_LOCK_HELD is inherited on purpose: it is what lets a nested
    make skip the worktree lock the outer `make test` already holds, and
    clearing it deadlocks.
    """
    proc = subprocess.run(["make", "--no-print-directory", "-C", ROOT, *args],
                          capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr


def injected(text):
    """{macro: variable} from the Makefile's compile line for the checker."""
    m = re.search(r"^" + re.escape(TARGET) + r":[^\n]*\n((?:\t[^\n]*\n)+)",
                  text, re.M)
    if not m:
        fail(f"no `{TARGET}:` build rule in the Makefile -- the fuse checker's "
             "compile line has moved or been deleted")
    pairs = {}
    for macro, var in re.findall(r"-D([A-Za-z_]\w*)=\$\(([A-Za-z_]\w*)\)", m.group(1)):
        if macro in pairs and pairs[macro] != var:
            fail(f"-D{macro} is injected from two different variables "
                 f"({pairs[macro]}, {var})")
        pairs[macro] = var
    return pairs


def burned(text):
    """{variable} written to silicon by an avrdude `-U <mem>:w:$(VAR):m` recipe.

    `:m` is what makes this the fuse set: flash images are written `:i`, and
    readback recipes use `:r:`, so neither is picked up here.
    """
    return set(re.findall(r"-U\s+\w+:w:\$\$?\(([A-Za-z_]\w*)\):m", text))


def guards(text):
    """{macro: variable-named-in-its-#error} for every fail-closed guard."""
    out = {}
    for m in re.finditer(r"^#ifndef\s+(\w+)\s*\n#\s*error\s+\"([^\"]*)\"", text, re.M):
        macro, message = m.group(1), m.group(2)
        named = re.search(r"-D" + re.escape(macro) + r"=\$\((\w+)\)", message)
        out[macro] = named.group(1) if named else None
    return out


def compile_command():
    """The real, expanded compile line, as argv without the -o pair."""
    rc, out = run_make("-n", TARGET)
    if rc != 0:
        fail(f"`make -n {TARGET}` failed:\n{out.strip()[:2000]}")
    # `[^;]*` rather than `.*?`: the recipe opens with `if ! rm -f ...;` and a
    # non-greedy dot-all match starts there and swallows the whole preamble.
    # The compile command itself contains no `;`, so this anchors on it.
    m = re.search(r"if ! ([^;]*?)\s+-o \"\$tmp\";", out, re.S)
    if not m:
        fail(f"could not find the compile command in `make -n {TARGET}` output -- "
             "the build rule's shape has changed")
    return shlex.split(re.sub(r"\\\n\s*", " ", m.group(1)))


def build(argv, out, drop=None, substitute=None):
    """Compile with one macro dropped or one value replaced. -> (rc, output)"""
    cmd = []
    for token in argv:
        if drop and token.startswith(f"-D{drop}="):
            continue
        if substitute and token.startswith(f"-D{substitute[0]}="):
            token = f"-D{substitute[0]}={substitute[1]}"
        cmd.append(token)
    proc = subprocess.run(cmd + ["-o", out], cwd=ROOT,
                          capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr


def printed(binary):
    """{(digits, FIELD): byte} parsed from the checker's own output.

    Keyed by the digits in the part label ("ATtiny13a" -> "13") so the macro
    prefixes (T13_, T85_, T202_) map onto it by derivation rather than by a
    hand-written table that could itself drift.
    """
    proc = subprocess.run([binary], capture_output=True, text=True)
    values = {}
    for line in proc.stdout.split("\n"):
        m = re.match(r"^\s+([A-Za-z0-9]+):\s*(\S.*)$", line)
        if not m:
            continue
        digits = "".join(ch for ch in m.group(1) if ch.isdigit())
        for field, value in re.findall(r"(\w+)=((?:0x)?[0-9a-fA-F]+)", m.group(2)):
            values[(digits, field.upper())] = int(value, 16)
    return proc.returncode, values, proc.stdout


def key_of(macro):
    """T202_SYSCFG0 -> ("202", "SYSCFG0")."""
    prefix, _, field = macro.partition("_")
    return "".join(ch for ch in prefix if ch.isdigit()), field.upper()


def mismatches(pairs, expected, values):
    """[(macro, expected, actual)] for every byte that did not survive the trip."""
    out = []
    for macro in sorted(pairs):
        actual = values.get(key_of(macro))
        if actual != expected[macro]:
            out.append((macro, expected[macro], actual))
    return out


def main():
    makefile = read(os.path.join(ROOT, "Makefile"))
    source = read(SOURCE)
    checks = 0

    # ------------------------------------------------------------- inventory --
    pairs = injected(makefile)
    if len(pairs) < FLOOR:
        fail(f"the compile line injects only {len(pairs)} fuse macro(s); expected "
             f">= {FLOOR} -- the -D harvest has stopped matching")
    checks += 1

    # The checker must verify the bytes that are actually burned, not a set that
    # merely overlaps them.
    written = burned(makefile)
    if written != set(pairs.values()):
        only_burned = sorted(written - set(pairs.values()))
        only_checked = sorted(set(pairs.values()) - written)
        lines = ["FAIL: the fuse bytes burned to silicon and the fuse bytes the "
                 "checker verifies are not the same set:"]
        if only_burned:
            lines.append("      burned but never checked: " + ", ".join(only_burned))
        if only_checked:
            lines.append("      checked but never burned: " + ", ".join(only_checked))
        sys.exit("\n".join(lines))
    checks += 1

    # ------------------------------------------------------------- guarded ----
    # Reported together, because a macro renamed on ONE side -- the likeliest way
    # this gate ever fires -- populates both lists, and reading either alone
    # sends you looking for a macro that was never added or never deleted.
    guarded = guards(source)
    missing = sorted(set(pairs) - set(guarded))
    orphan = sorted(set(guarded) - set(pairs))
    if missing or orphan:
        rel = os.path.relpath(SOURCE, ROOT)
        lines = [f"FAIL: the compile line and {rel} do not name the same fuse macros:"]
        if missing:
            lines.append("      injected by the Makefile, no `#ifndef ... #error` "
                         "guard in the source: " + ", ".join(missing))
        if orphan:
            lines.append("      required by the source, never injected: "
                         + ", ".join(orphan))
        if missing and orphan:
            lines += ["",
                      "      Both lists are non-empty, which is exactly what a macro renamed",
                      "      on one side looks like. Pair them up before assuming either is"
                      " new."]
        sys.exit("\n".join(lines))
    checks += 2

    # Each guard documents where its byte comes from; that documentation is
    # checkable, so it is checked rather than trusted.
    wrong = [f"{m}: source names {guarded[m] or 'no variable at all'}, "
             f"Makefile injects {pairs[m]}"
             for m in sorted(pairs) if guarded[m] != pairs[m]]
    if wrong:
        fail("an #error names the wrong source variable: " + "; ".join(wrong))
    checks += 1

    # THE defect, in its recurring form: a default silently restores itself and
    # the macro stops being required.
    defaulted = sorted(m for m in pairs
                       if re.search(r"^#\s*define\s+" + re.escape(m) + r"\b",
                                    source, re.M))
    if defaulted:
        fail("injected macro(s) have an in-source default again, so a rename on "
             "either side would fall back instead of failing: " + ", ".join(defaulted))
    checks += 1

    # ------------------------------------------------------- Makefile values --
    names = [pairs[m] for m in sorted(pairs)]
    rc, out = run_make("-s", *[f"print-{v}" for v in names])
    lines = out.strip().split("\n")
    if rc != 0 or len(lines) != len(names):
        fail(f"could not read the fuse variables through print-<VAR>:\n{out.strip()[:2000]}")
    expected = {}
    for macro, value in zip(sorted(pairs), lines):
        value = value.strip()
        if not re.fullmatch(r"0[xX][0-9a-fA-F]{1,2}", value):
            fail(f"{pairs[macro]} does not expand to a fuse byte: {value!r}")
        expected[macro] = int(value, 16)
    checks += 1

    with tempfile.TemporaryDirectory(prefix="fuse-contract.") as scratch:
        argv = compile_command()
        if not any(t.startswith("-DT") for t in argv):
            fail("the harvested compile command carries no -D fuse macros; "
                 f"`make -n {TARGET}` was parsed wrongly")
        checks += 1

        # ------------------------------------------------------- round trip --
        good = os.path.join(scratch, "fuses")
        rc, out = build(argv, good)
        if rc != 0:
            fail(f"the real compile line does not build the checker:\n{out.strip()[:2000]}")
        checks += 1

        rc, values, stdout = printed(good)
        if rc != 0:
            fail(f"the checker built from the real compile line fails:\n{stdout.strip()[:2000]}")
        checks += 1

        # One printed value per injected macro, and no printed value unclaimed:
        # a byte injected but never printed is a byte nothing downstream can see.
        unclaimed = sorted(set(values) - {key_of(m) for m in pairs})
        if unclaimed:
            fail("the checker prints fuse byte(s) the Makefile does not inject: "
                 + ", ".join(f"{p}:{f}" for p, f in unclaimed))
        checks += 1

        drifted = mismatches(pairs, expected, values)
        if drifted:
            report = ["FAIL: fuse byte(s) did not survive the trip from the Makefile "
                      "into the compiled checker:"]
            report += [f"      {m}: Makefile has 0x{e:02x}, the binary reports "
                       + ("nothing" if a is None else f"0x{a:02x}")
                       for m, e, a in drifted]
            sys.exit("\n".join(report))
        checks += 1

        # ---------------------------------------------------- negative cases --
        # A. The original defect: drop one -D from the real compile line. Before
        #    2026-08-03 this built and printed "46 checks, 0 failures"; it must
        #    now fail the compile, naming the macro.
        victim = sorted(pairs)[0]
        rc, out = build(argv, os.path.join(scratch, "missing"), drop=victim)
        if rc == 0:
            fail(f"the checker still builds without -D{victim} -- an in-source "
                 "default has come back and a renamed macro would sever silently")
        if victim not in out:
            fail(f"dropping -D{victim} failed the build without naming the macro:\n"
                 f"{out.strip()[:1000]}")
        checks += 1

        # B. A value that drifts between the Makefile and the binary must be
        #    caught. Bit 6 is chosen because it is EESAVE in the ATtiny13a low
        #    fuse, which no assertion in the checker reads -- so the perturbed
        #    binary exits 0 and only the round-trip above can see it. If the
        #    checker is ever strengthened to catch every bit, the loop below
        #    simply settles on a perturbation it does catch; the claim being
        #    proved here is about THIS gate, not about that one.
        tested, blind = [], None
        for macro in sorted(pairs):
            path = os.path.join(scratch, "drift")
            rc, out = build(argv, path, substitute=(macro, f"0x{expected[macro] ^ 0x40:02x}"))
            if rc != 0:
                continue
            rc, values, _ = printed(path)
            found = [m for m, _, _ in mismatches(pairs, expected, values)]
            if found != [macro]:
                fail(f"a drifted {macro} was not reported as the only mismatch: {found}")
            tested.append(macro)
            if rc == 0:
                blind = macro
                break
        if not tested:
            fail("no perturbed fuse byte could be built, so the value-drift "
                 "negative case did not run at all")
        checks += 1

    drift = (f"{blind} drift caught unseen by the checker itself" if blind
             else f"{len(tested)} drift(s) caught, all also seen by the checker")
    print(f"fuse injection contract: {checks} checks, 0 failures "
          f"({len(pairs)} bytes injected and burned, round-tripped through the "
          f"compiled checker; {drift})")


if __name__ == "__main__":
    main()
