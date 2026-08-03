#!/usr/bin/env python3
"""Every single-variant selector is validated before the lane that reads it runs.

THE DEFECT CLASS. `VARIANTS` is a list and has been guarded since 0.9.4
(`classic-variant-request-valid`). The variables that select exactly ONE output
stage -- PIC10F322_SOAK_VARIANT, PIC10F320_IO_VARIANT, AVR_SOAK_VARIANT and the
rest -- had no guard at all, and an unrecognized value in one of those does not
fail. It composes a path to a file nobody builds, and the lane reports the
absence as a MISSING TOOLCHAIN:

    $ make pic10f322-test-soak PIC10F322_SOAK_VARIANT=relay
    no build_pic10f322/bypass-pic10f322-relay.hex (XC8 absent?); skipping ...
    $ echo $?
    0

XC8 was installed. The request was a typo carrying the pre-v0.9.8 stage
vocabulary, and both the operator and the suite were told something else
entirely. STRICT_TOOLS=1 (CI, release) converts the skip into a failure with the
same wrong diagnosis, so it moves the cost rather than removing it.

This is the same defect the v0.9.8 analyzers had -- an unrecognized VARIANTS
name shrank the subject and the analyzer honestly reported the smaller set clean
-- and the same shape as the PIC10F322 soak driver that had not compiled for a
release: it "degraded to a skip, not a failure". A skip is the dangerous
outcome precisely because it is indistinguishable from an honest one.

TWO HALVES, because either alone leaves the hole open.

  BEHAVIOURAL: the guard actually rejects the three malformed shapes (unknown,
  empty, more-than-one), and a real lane rejects BEFORE it builds or skips.
  Rejecting late is not equivalent -- a lane that skips first never discovers
  the typo, and one that builds first has already spent the build.

  CONTRACT: the guard is still attached to every rule that consumes a selector,
  including rules written after this file. A guard a human has to remember to
  extend has the failure mode it exists to prevent.

THE CONTRACT HALF NEEDS A TRANSITIVE CLOSURE, and that is the whole difficulty.
Almost no rule mentions a selector directly: pic10f322-test-soak reads
$(PIC10F322_SOAK_HEX), which is composed from PIC10F322_SOAK_VARIANT three
definitions away. A harvest keyed on the selector names alone finds 17 of the 29
rules that actually depend on one -- and the twelve it misses include every
PIC10F320 lane. So the closure is computed first (a variable belongs if its
definition names anything already in the set, iterated to a fixed point), and
rules are matched against the closure.

SCOPE, stated so the next reader does not over-trust it. This checks Makefile
rules. A selector consumed only inside a shell script or a Python driver that
Make invokes is not visible here; those receive their value through the
environment and validate it themselves where it matters. XT_SIM_VARIANT is
deliberately outside the table: empty means "every supported variant" for that
lane, so it is a list-or-empty selector, and it already validates itself in each
of its four recipes.
"""

import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUARD = "variant-selectors-valid"

# Rules that reference a selector but must NOT be guarded, with the reason.
# Every entry must still be reached by the harvest (checked below), so an
# exemption expires rather than accumulating.
#
#   help   prints the selector names as documentation. `make help` has to work
#          when the request is malformed -- that is when a reader needs it most.
EXEMPT = {"help"}


def fail(msg):
    sys.exit(f"FAIL: {msg}")


def read_makefile():
    with open(os.path.join(ROOT, "Makefile"), encoding="utf-8") as fh:
        return fh.read()


def join_continuations(text):
    """Join backslash continuations, keeping one entry per logical line.

    Not optional, and the reason is recorded because the first draft of this
    file got it wrong in exactly the way axis C of the name contract did:
    `test-soak-reset-witness` carries its prerequisites on a continued line, so
    a physical-line harvest classified it as not consuming a selector at all --
    a rule that DOES consume one, reported clean.
    """
    out, buf, start = [], None, 0
    for lineno, line in enumerate(text.split("\n"), 1):
        if buf is None:
            buf, start = line, lineno
        else:
            buf += " " + line.lstrip()
        if buf.rstrip().endswith("\\"):
            buf = buf.rstrip()[:-1]
            continue
        out.append((start, buf))
        buf = None
    if buf is not None:
        out.append((start, buf))
    return out


def selector_table(text):
    """{selector: supported-set variable} from the Makefile's own table."""
    m = re.search(r"^VARIANT_SELECTORS = ((?:.*\\\n)*.*)$", text, re.M)
    if not m:
        fail("no VARIANT_SELECTORS table in the Makefile -- the guard's inventory "
             "has moved or been deleted")
    table = {}
    for entry in m.group(1).replace("\\\n", " ").split():
        if ":" not in entry:
            fail(f"VARIANT_SELECTORS entry '{entry}' is not <selector>:<supported-set>")
        sel, sup = entry.split(":", 1)
        table[sel] = sup
    return table


def closure_of(text, seeds):
    """Selectors plus every variable composed from one, to a fixed point."""
    defs = {}
    for m in re.finditer(
            r"^(?:override\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*[:?+]?=(.*(?:\\\n.*)*)$",
            text, re.M):
        defs.setdefault(m.group(1), []).append(m.group(2))

    members = set(seeds)
    for _ in range(20):
        grew = False
        for name, bodies in defs.items():
            if name in members:
                continue
            if any(re.search(r"\$[({]" + re.escape(s) + r"[)}]", body)
                   for body in bodies for s in members):
                members.add(name)
                grew = True
        if not grew:
            return members
    fail("the selector closure did not converge in 20 passes")


def harvest(text, members):
    """[(target, guarded, lineno)] for every rule that consumes a member."""
    ref = re.compile(r"\$\$?[({](" +
                     "|".join(re.escape(m) for m in sorted(members, key=len, reverse=True)) +
                     r")[)}]")
    head = re.compile(r"^([A-Za-z_$][^:=\n]*?):(?!=)(.*)$")

    rules, cur = [], None
    for lineno, line in join_continuations(text):
        if line.startswith("\t"):
            if cur:
                cur[3].append(line)
            continue
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        m = head.match(line)
        cur = [m.group(1).strip(), m.group(2), lineno, []] if m else None
        if cur:
            rules.append(cur)

    out = []
    for target, prereqs, lineno, body in rules:
        if ref.search(prereqs + "\n" + "\n".join(body)):
            out.append((target, GUARD in prereqs, lineno))
    return out


def run_make(*args, env=None):
    """Run make from ROOT. _MAKE_SERIAL_LOCK_HELD is inherited on purpose: it is
    what lets a nested make skip the worktree lock the outer `make test` already
    holds, and clearing it deadlocks."""
    proc = subprocess.run(["make", "--no-print-directory", "-C", ROOT, *args],
                          capture_output=True, text=True,
                          env={**os.environ, **(env or {})})
    return proc.returncode, proc.stdout + proc.stderr


def main():
    text = read_makefile()
    checks = 0

    # ------------------------------------------------------------- inventory --
    table = selector_table(text)

    # A floor, so a table that silently halves cannot pass by checking a handful.
    # Lower it deliberately if a lane is genuinely retired.
    if len(table) < 12:
        fail(f"VARIANT_SELECTORS lists only {len(table)} selectors; expected >= 12")
    checks += 1

    # Both sides of every entry must be names Make actually knows. A selector
    # whose supported-set variable is undefined validates against an EMPTY set,
    # which rejects every value including the correct one -- and a selector that
    # no longer exists is checked but never read.
    names = sorted(set(table) | set(table.values()))
    rc, out = run_make("-s", "origins", f"NAMES={' '.join(names)}")
    if rc != 0:
        fail(f"`make origins` failed:\n{out.strip()[:2000]}")
    origins = dict(line.split() for line in out.split("\n") if len(line.split()) == 2)
    undefined = [n for n in names if origins.get(n, "undefined") == "undefined"]
    if undefined:
        fail("VARIANT_SELECTORS names variables the Makefile does not define: "
             + ", ".join(undefined))
    checks += 1

    for sel, sup in sorted(table.items()):
        rc, out = run_make("-s", f"print-{sup}")
        if not out.strip():
            fail(f"{sel}'s supported set {sup} expands empty -- the guard would "
                 "reject every value, including the right one")
    checks += 1

    # -------------------------------------------------------------- contract --
    members = closure_of(text, table)
    if len(members) <= len(table):
        fail("the selector closure found no derived variables at all; the "
             "definition parse has stopped matching")
    checks += 1

    rules = harvest(text, members)
    if len(rules) < 20:
        fail(f"harvested only {len(rules)} rules consuming a selector; expected "
             ">= 20 -- the rule parse has stopped matching")
    checks += 1

    unguarded = sorted(t for t, guarded, _ in rules if not guarded and t not in EXEMPT)
    if unguarded:
        by_line = {t: ln for t, _, ln in rules}
        lines = [f"FAIL: {len(unguarded)} rule(s) consume a single-variant selector "
                 f"without depending on `{GUARD}`:"]
        lines += [f"      Makefile:{by_line[t]}  {t}" for t in unguarded]
        lines += ["",
                  "An unrecognized selector value composes a path to a file nothing",
                  "builds, and the lane reports that as a missing toolchain and skips.",
                  f"Add `{GUARD}` as the FIRST prerequisite (order-only, `| {GUARD}`,",
                  "for a file target, so a phony prerequisite cannot make it look",
                  "perpetually out of date)."]
        sys.exit("\n".join(lines))
    checks += 1

    # Exemptions expire.
    harvested_targets = {t for t, _, _ in rules}
    stale = sorted(EXEMPT - harvested_targets)
    if stale:
        fail("EXEMPT names rule(s) the harvest no longer reaches: " + ", ".join(stale))
    checks += 1

    # NEGATIVE CASE for the harvest itself: a rule that consumes a selector and
    # does not name the guard must be reported. Without this the contract check
    # could pass by harvesting nothing at all.
    bogus = text + (f"\n_bogus-unguarded-lane:\n\t@echo $(PIC10F322_SOAK_HEX)\n")
    neg = [t for t, guarded, _ in harvest(bogus, closure_of(bogus, table))
           if not guarded]
    if "_bogus-unguarded-lane" not in neg:
        fail("negative case: an unguarded selector consumer was not detected")
    checks += 1

    # ------------------------------------------------------------ behavioural --
    rc, out = run_make(GUARD)
    if rc != 0:
        fail(f"the guard rejects the DEFAULT configuration:\n{out.strip()[:2000]}")
    checks += 1

    malformed = [
        ("unknown", "PIC10F322_SOAK_VARIANT=relay", "is not supported"),
        ("empty", "AVR_SOAK_CHIP=", "is empty"),
        ("more than one", "VARIANT=cd4053_simple tq2_l2_5v_relay",
         "names more than one value"),
        # The retired spelling. AVR_SOAK_CHIP took a bare chip number until
        # v0.9.8 moved it to the full part name, and a command line carrying the
        # old one must be told so rather than composing bypass-attiny-cd4053...
        # from a value the family's internal indexing still recognizes.
        ("retired spelling", "AVR_SOAK_CHIP=85", "is not supported"),
    ]
    for label, override, expected in malformed:
        rc, out = run_make(GUARD, override)
        if rc == 0:
            fail(f"the guard accepted a {label} selector request ({override})")
        if expected not in out:
            fail(f"the guard rejected the {label} request without saying why "
                 f"(expected {expected!r}):\n{out.strip()[:1000]}")
        checks += 1

    # A recognized value must still pass, or the guard is just breaking things.
    rc, out = run_make(GUARD, "PIC10F322_SOAK_VARIANT=cd4053_with_mute",
                       "PIC10F320_TARGET_VARIANT=tq2_l2_5v_relay",
                       "AVR_SOAK_CHIP=attiny45")
    if rc != 0:
        fail(f"the guard rejected a valid non-default request:\n{out.strip()[:2000]}")
    checks += 1

    # END TO END, on the lane that carried the defect: it must fail, name the
    # selector, and never reach the skip that used to be the only thing said.
    rc, out = run_make("pic10f322-test-soak", "PIC10F322_SOAK_VARIANT=relay")
    if rc == 0:
        fail("pic10f322-test-soak accepted PIC10F322_SOAK_VARIANT=relay")
    if "PIC10F322_SOAK_VARIANT=relay is not supported" not in out:
        fail(f"pic10f322-test-soak failed without naming the bad selector:\n"
             f"{out.strip()[:1000]}")
    if "XC8 absent" in out or "skipping PIC soak" in out:
        fail("pic10f322-test-soak still reports a typo'd selector as a missing "
             f"toolchain:\n{out.strip()[:1000]}")
    checks += 1

    print(f"variant selector guard: {checks} checks, 0 failures "
          f"({len(table)} selectors, {len(members) - len(table)} derived variables, "
          f"{len(rules)} consuming rules)")


if __name__ == "__main__":
    main()
