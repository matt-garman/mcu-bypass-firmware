#!/usr/bin/env python3
"""Axis C of the Makefile name contract: every `NAME=value` handed to make must
name a variable the Makefile actually knows.

THE DEFECT CLASS. A make override that names no existing variable is legal and
silent. `make test-soak SOAK_DURATION_MS=2000` defines a make variable called
SOAK_DURATION_MS; if the recipe reads $(AVR_SOAK_DURATION_MS), the override is
inert and the default applies, with no error and no diagnostic. In v0.9.8 that
left the classic-AVR WDT mutant asking for 2 s of simulated soak and silently
getting the 24 h default -- 43,200x. A local run sat in that one mutant for over
ten hours before it was killed by hand; both CI jobs reaching the row declared no
timeout and would have been cancelled at GitHub's six-hour limit having reported
nothing. Four separate guards missed it, each for a different reason.

THE ORACLE is `make origins NAMES="..."`, which reports $(origin) per name in one
invocation. Non-emptiness is NOT usable: XT_SOAK_COMBINATION_NAME and
AVR_STACK_BUILD_DIR are defined-but-empty by design, so only $(origin) separates
"never defined" (undefined) from "deliberately empty" (file).

WHERE OVERRIDES LIVE -- three sources, and the third is the one that matters.

  1. Shell and YAML lines invoking make, across test/, scripts/ and .github/.
     Backslash continuations are joined FIRST. This is not optional: in
     test/test_avr_build_rebuild.sh the `make` sits on one line and its
     overrides five continued lines below, and there are ZERO physical lines in
     this repo containing both `make` and `MCU=`. A physical-line harvest -- the
     first version of this sweep -- reported those three inert overrides as
     clean.

  2. The Makefile's own comments, because a comment recommending a dead override
     is how a person is told to do the thing that silently does nothing. Until
     v0.9.8 the soak override block recommended exactly the spelling that had
     just broken the harness.

  3. THE MUTATION TABLES in test/run_mutation_tests.sh, whose third
     tab-separated field is a make command line stored as DATA. These rows
     contain no `make` token at all, so sources 1 and 2 cannot see them -- and
     the v0.9.8 defect above was in one of these rows. A gate scoped to
     "lines invoking make" would not have caught the defect it exists to
     prevent. That is the whole reason this source is enumerated separately.

SCOPE, stated so the next reader does not over-trust it: this checks names
passed to make. It does not check names a document merely mentions in prose
(that is axis B/D, still open in TODO.md), and it cannot know that a name
reaching make is meant for make rather than for a script reading the
environment -- hence ENV_ALLOWLIST below, which must stay short and justified.
"""

import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Names that legitimately travel to a child process's ENVIRONMENT through a make
# command line, and are read by a script rather than by the Makefile. Nothing in
# the Makefile can infer these, so they are listed. Keep this short: every entry
# is a name this gate cannot check, so a wrong one is a permanent blind spot.
# It has exactly one member, and that is a result rather than a coincidence.
# The prototype sweep recorded in TODO.md needed at least seven, all of them
# fake-tool shim parameters (FAKE_CC_LOG, FAKE_OBJCOPY_LOG, ...) plus the env
# set handed to make-release.sh. Harvesting only what follows the make word
# retires every one of them: they are environment prefixes, so they were never
# claims about the Makefile's vocabulary in the first place. The allowlist got
# shorter by fixing the harvest rather than by growing exemptions, which is the
# direction it should always move.
#
# MUTATION_ALLOW_SKIP survives because it genuinely is passed after the make
# word (`make test-long MUTATION_ALLOW_SKIP=1`). Make exports command-line
# variables to recipe child processes, so it reaches test/mutation_policy.sh
# through the environment; the Makefile itself neither defines nor reads it
# (verified: zero occurrences). Nothing in the Makefile can infer that.
ENV_ALLOWLIST = {
    "MUTATION_ALLOW_SKIP",
}

# A make command word: bare `make`, or a $(MAKE)/$MUTATION_MAKE style reference.
# The boundaries matter more than they look. `make-release.sh` must NOT count as
# a make invocation -- it is a shell script whose name merely starts with
# "make", and treating it as one drags in every NAME= on the same line
# (RELEASE=, REPO_URL=, EXPECTED_LOCK=, LOCK_ATTEMPT=, REAL_FLOCK=). That was a
# real false-positive class in the prototype sweep.
MAKE_WORD = re.compile(
    r"(?<![-\w./])make(?![-\w./])"          # bare `make`, not make-release.sh
    r"|\$[({]?[A-Z_]*MAKE[)}]?"             # $(MAKE), $MUTATION_MAKE, ${MAKE}
)

# NAME=  -- the lookbehind rejects `-DNAME=` (a compiler macro, deliberately NOT
# renamed alongside the make variables) and `$NAME=`.
ASSIGN = re.compile(r"(?<![-\w./$])([A-Za-z_][A-Za-z0-9_]*)=")

# A mutation table row: a quoted string of >=4 tab-separated fields whose third
# field is the make command.
MUTATION_ROW = re.compile(r'^"([^"]*)"')


def logical_lines(text):
    """Yield (start_line_number, joined_line), joining backslash continuations."""
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        start = i
        buf = lines[i]
        while buf.rstrip().endswith("\\") and i + 1 < len(lines):
            i += 1
            buf = buf.rstrip()[:-1] + " " + lines[i]
        yield start + 1, buf
        i += 1


def assignments_in(fragment):
    """NAME= tokens in a fragment, minus shell locals capturing command output.

    `XT_N=$(make -s print-...)`, `REAL_MAKE=$(command -v make)` and
    `MUTATION_MAKE="${MUTATION_MAKE:-make}"` are shell variables assigned FROM a
    command or a parameter expansion, not overrides passed TO one. They are
    distinguished by their value opening a substitution.
    """
    out = []
    for m in ASSIGN.finditer(fragment):
        after = fragment[m.end():m.end() + 3]
        if after.startswith(("$(", "`", '"${', "${", '"$(')):
            continue
        out.append(m.group(1))
    return out


def assignments_passed_to_make(line):
    """NAME= tokens that reach make as OVERRIDES, i.e. after the make word.

    Position is what separates the two meanings, and it is not a nicety:

        FAKE_CC_LOG=x make foo BAR=1

    BAR is a make override -- make defines a variable called BAR. FAKE_CC_LOG is
    an ENVIRONMENT assignment for make's child processes, read here by a fake
    compiler shim on PATH; the Makefile neither defines nor wants it. Harvesting
    the prefix position would report every fake-tool parameter in the rebuild
    gates as a severed override and force a long allowlist of names this gate
    then could not check at all.

    So: only what follows the make word is a claim about the Makefile's
    vocabulary.
    """
    m = MAKE_WORD.search(line)
    if not m:
        return []
    tail = line[m.end():]
    # Overrides are ARGUMENTS to make, so they end where the make command does.
    # Anything past a shell separator or redirection belongs to a different
    # statement -- `make ... >/dev/null 2>&1; rc=$?` assigns a shell local, and
    # `$(MAKE) ... || { rc=1; break; }` assigns one in a failure branch. Both
    # read as overrides without this, and both are lowercase shell variables the
    # Makefile has never heard of, so they would be reported as severed forever.
    tail = re.split(r"[;|&<>]|\|\||&&", tail, maxsplit=1)[0]
    return assignments_in(tail)


def harvest():
    """Return {name: [locations]} for every NAME= handed to make."""
    files = subprocess.run(
        ["git", "ls-files", "test/", "scripts/", ".github/", "Makefile"],
        cwd=ROOT, capture_output=True, text=True, check=True,
    ).stdout.split()

    found = {}

    def record(name, where):
        found.setdefault(name, []).append(where)

    for rel in files:
        path = os.path.join(ROOT, rel)
        try:
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
        except (OSError, UnicodeDecodeError):
            continue

        # Sources 1 and 2: anything invoking make, comments included.
        #
        # The Makefile is harvested by PHYSICAL line rather than joined. A
        # recipe is a multi-line shell script, so joining its continuations
        # turns the whole body into one "line invoking make" and every shell
        # local in it (rc=, marker=, target=) reads as an override. Shell and
        # YAML files are joined, because there a continued line genuinely is one
        # command -- which is the case that hid three inert overrides in v0.9.8.
        is_makefile = rel == "Makefile"
        lines = ([(i, l) for i, l in enumerate(text.split("\n"), 1)]
                 if is_makefile else logical_lines(text))
        for lineno, line in lines:
            # Comments are harvested in the MAKEFILE only. That is where an
            # override is documented to a reader -- `# Override: make
            # test-flash-budget ATTINY13A_FLASH_BUDGET=80` -- so a stale one
            # there actively misinstructs, which is the axis-D failure that hit
            # the SOAK_* block in v0.9.8. A shell or YAML comment is ordinary
            # prose: run_mutation_tests.sh documents its dispatch as "make
            # target (kind=make)", where `kind=` is a description of a variable
            # in that script, not an override anyone is being told to pass.
            # Harvesting those trades a real check for recurring false
            # positives on generic words.
            if not is_makefile and line.lstrip().startswith("#"):
                continue
            for name in assignments_passed_to_make(line):
                record(name, f"{rel}:{lineno}")

        # Source 3: mutation table rows, whose 3rd field is a make command.
        if rel == "test/run_mutation_tests.sh":
            for lineno, line in enumerate(text.split("\n"), 1):
                m = MUTATION_ROW.match(line)
                if not m:
                    continue
                fields = m.group(1).split("\t")
                if len(fields) < 4:
                    continue
                for name in assignments_in(fields[2]):
                    record(name, f"{rel}:{lineno} (mutation row)")

    return found


def dereferenced_names():
    """Names the Makefile READS, i.e. $(NAME) or ${NAME} anywhere in it.

    $(origin) reports a command-line-only input as `undefined`, because it is
    genuinely never defined in the file -- it is *consumed*. `make release
    VERSION=v1.0.0` is the documented interface and Makefile:4898 reads
    $(VERSION), but querying origin without supplying it says undefined. Judged
    on origin alone, the Makefile's own usage line would be reported as severed.

    So the contract is: a name must be DEFINED or CONSUMED. A name that is
    neither is what severance actually looks like -- nothing sets it, nothing
    reads it, and the override does nothing at all.
    """
    with open(os.path.join(ROOT, "Makefile"), encoding="utf-8") as fh:
        text = fh.read()
    return set(re.findall(r"\$[({]([A-Za-z_][A-Za-z0-9_]*)[)}]", text))


def origins(names):
    """{name: $(origin name)} via one make invocation."""
    if not names:
        return {}
    proc = subprocess.run(
        ["make", "-s", "origins", "NAMES=" + " ".join(sorted(names))],
        cwd=ROOT, capture_output=True, text=True,
    )
    if proc.returncode != 0:
        sys.exit("FAIL: `make origins` failed:\n" + proc.stderr.strip())
    result = {}
    for line in proc.stdout.splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2:
            result[parts[0]] = parts[1].strip()
    return result


def main():
    checks = 0
    found = harvest()
    checked = {n: locs for n, locs in found.items() if n not in ENV_ALLOWLIST}

    # The harvest must find something, and must find the sources separately. A
    # regex that quietly stops matching is the same defect class this gate
    # exists to catch, and it would otherwise pass by checking an empty set.
    if not found:
        sys.exit("FAIL: harvested no make overrides at all -- the regex has stopped matching")
    checks += 1

    from_rows = [n for n, locs in found.items() if any("mutation row" in l for l in locs)]
    if not from_rows:
        sys.exit(
            "FAIL: harvested no overrides from the mutation tables. That source "
            "carries the v0.9.8 defect this gate exists to prevent; if the table "
            "format changed, fix the parser rather than dropping the source."
        )
    checks += 1

    if len(checked) < 10:
        sys.exit(f"FAIL: harvested only {len(checked)} checkable overrides; expected >= 10")
    checks += 1

    # Every allowlist entry must still be reached by the harvest. An entry that
    # nothing produces is a name this gate has permanently stopped checking, for
    # a reason that no longer exists -- and if that name is later passed as a
    # real override, the exemption silently covers it. Exemptions must expire.
    stale_exemptions = sorted(ENV_ALLOWLIST - set(found))
    if stale_exemptions:
        sys.exit(
            "FAIL: ENV_ALLOWLIST exempts name(s) the harvest no longer finds: "
            + ", ".join(stale_exemptions)
            + "\nRemove them; an exemption nothing reaches is a permanent blind spot."
        )
    checks += 1

    # The contract: defined OR consumed.
    org = origins(checked)
    consumed = dereferenced_names()
    severed = sorted(
        n for n in checked
        if org.get(n, "undefined") == "undefined" and n not in consumed
    )
    if severed:
        lines = ["FAIL: make override(s) name variables this Makefile neither defines nor reads:"]
        for name in severed:
            lines.append(f"  {name}")
            for loc in sorted(set(checked[name]))[:4]:
                lines.append(f"      {loc}")
        lines.append("")
        lines.append("A make override naming no existing variable is legal and silent:")
        lines.append("the value is ignored and the Makefile default applies.")
        sys.exit("\n".join(lines))
    checks += 1

    # NEGATIVE CASES, per the house pattern.
    #
    # (a) a bogus name must be rejected...
    if origins({"MCU_BYPASS_DEFINITELY_NOT_A_VARIABLE"}).get(
        "MCU_BYPASS_DEFINITELY_NOT_A_VARIABLE"
    ) != "undefined":
        sys.exit("FAIL: negative case -- the origin oracle did not report a bogus name as undefined")
    checks += 1

    # (b) ...and a name that IS defined but deliberately EMPTY must be accepted,
    # because a non-emptiness test here would produce false failures.
    for name in ("XT_SOAK_COMBINATION_NAME", "AVR_STACK_BUILD_DIR"):
        if origins({name}).get(name) == "undefined":
            sys.exit(
                f"FAIL: negative case -- {name} is defined-but-empty by design and "
                "must not read as undefined; the oracle has regressed to a value test"
            )
    checks += 1

    # (c) the continuation join must work, since a physical-line harvest is what
    # let three inert overrides through in the first place.
    joined = list(logical_lines("make foo \\\n    BAR=1\n"))
    if "BAR=1" not in joined[0][1] or joined[0][0] != 1:
        sys.exit("FAIL: negative case -- backslash continuations are no longer joined")
    if assignments_passed_to_make(joined[0][1]) != ["BAR"]:
        sys.exit("FAIL: negative case -- a continued override is not harvested as one")
    checks += 1

    # (d) and make-release.sh must not read as a make invocation.
    if MAKE_WORD.search("scripts/make-release.sh --soak-duration-ms 0"):
        sys.exit("FAIL: negative case -- `make-release.sh` is being treated as a make invocation")
    checks += 1

    print(f"Makefile name contract (axis C): {checks} checks, "
          f"{len(checked)} overrides verified, 0 failures")


if __name__ == "__main__":
    main()
