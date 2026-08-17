# Splitting the Makefile — deferred decision record

**Status:** analysis only. **No change is proposed and none is recommended
now.** This file exists so the question does not have to be re-analysed from
scratch the next time someone opens the Makefile and reacts to its size. It
records what was measured, where the real seams are, what a split would cost in
*this* repository specifically, and the conditions under which revisiting would
be justified.

Measured at `c81e6a9` (2026-08-12), branch `pic12f675-support`, GNU Make 4.3.

**Decision reaffirmed for `v0.9.9-polish` (2026-08-17):** the repository owner
explicitly chose to accept the localized P-series additions in the monolithic
Makefile rather than sequence a split first. After P1, P2, and the pending P3
change, the file is 7,798 lines. Those additions extend the existing PIC12F675 and
release sections; they do not remove the fourteen-consumer migration cost in
section 3 or change the split ordering in section 4. The split therefore remains
deliberately deferred under the revisit triggers in section 7.

**What this document establishes:**

1. **The headline number overstates the problem.** 7337 lines is 2446 full-line
   comments plus 385 blanks plus ~4500 lines of code. A third of the file is
   design rationale, which is deliverable under this project's goals, not bloat.
   Splitting redistributes it; it does not reduce it (§1).
2. **The seams are real and already drawn.** The `# ====` banners partition the
   file cleanly, and the five per-MCU sections — ~4650 lines — are close to
   independent (§2).
3. **The cost is not the split; it is the fourteen consumers that hardcode
   `$ROOT/Makefile` as a single file** (§3). Some of them would fail loudly
   after a split. Others would go green while checking a fraction of what they
   check today (§3.2). The second class is the reason this is not a free
   refactor.
4. **GNU Make is still the right tool** and none of the alternatives repay their
   cost here (§5).
5. **What is actually straining is duplication across the three PIC parts, not
   Make** — but the recipes diverge for real hardware reasons, so templating
   them would trade duplication for a leaky abstraction. Only the identical
   declaration blocks are clean candidates (§6).
6. If it is ever done, **the ordering matters more than the split**, and there
   is already a strong equivalence oracle in the tree to verify it with (§4).

---

## 1. What 7337 lines actually is

```
total lines          7337
full-line comments   2446   (33%)
blank                 385
------------------------------
Makefile code        ~4506
```

This project's stated aim is textbook-grade, reference-quality firmware where
the supporting material carries the assurance argument. Under that aim the 2446
comment lines are part of the product. A split moves them into smaller files; it
does not make them go away, and it does not by itself make any single decision
easier to find.

So the question is not "is 7337 too many lines" but "are there ~4500 lines of
*code* with seams worth cutting along". There are — see §2 — but the honest
size of the prize is smaller than the line count suggests.

## 2. Where the seams are

The existing `# ============` banners already partition the file:

| Section | Approx. lines |
|---|---|
| Header — serialization wrapper, variant validation, tool discovery | 670 |
| BUILD — AVR classic matrix (ATtiny13a + tinyx5) | 241 |
| BUILD — PIC10F322 | 948 |
| BUILD — ATtiny202 (AVR-XT) | 679 |
| CLEAN / FLASH / FUSES | 120 |
| TESTS | 1076 |
| STATIC ANALYSIS & COVERAGE | 288 |
| PIC10F320 | 1112 |
| PIC12F675 | 1668 |
| INTROSPECTION / RELEASE / HELP | 530 |

The five per-MCU sections total ~4650 lines, are roughly independent of one
another, and are where essentially all recent churn lands. A `mk/pic12f675.mk`
would make a lane's blast radius visible in `git diff --stat` and in review.

`include` is semantically transparent in GNU Make: target resolution, variable
scope and `--print-data-base` are unaffected by which file a rule was read from.
There is no technical obstacle to the split itself.

### 2.1 What must not be split

- **The header block and the trailing `else` branch.** The entire body sits
  inside one `ifeq ($(_MAKE_SERIAL_LOCK_HELD),$(_MAKE_SERIAL_WORKTREE_ID))`.
  The flock re-exec, the `override`-based variant sanitising, and the
  empty/duplicate/unknown request plumbing are a single interlocking mechanism.
- **`TEST_GATES_EARLY` / `TEST_GATES_LATE`.** That list is the release gate
  manifest. Scattering it across fragments makes "what does `make test`
  actually run?" unanswerable by reading one file — which is precisely the
  property the list exists to provide.

### 2.2 A constraint the Makefile already records

The comment beside `origin-%` states that the introspection rules must live
next to `print-%` *in this file*, because `_make-serialized-invocation`
intercepts goals it does not recognise, so an invocation fails before a rule
added by an **outer** makefile is reached.

That rules out the outer-wrapper pattern (a small `Makefile` that includes a
large `mk/main.mk` and adds rules around it). The inner-include direction — this
Makefile including `mk/*.mk` fragments — is unaffected. Anyone reaching for the
wrapper shape should read that comment first; the failure it describes has
already been paid for once.

## 3. The real cost: fourteen sites treat the Makefile as one file

This is the finding that governs the decision.

### 3.1 Sites that copy it into a sandbox and run Make there

- `test/scratch_tree.sh:61` — `cp "$root/Makefile" "$dst/"`. This one feeds
  **both** the mutation runner (`test/run_mutation_tests.sh:741`) and
  `test/test_pic_rebuild.sh:56`, which have converged on it.
- `test/test_klee_build.sh:25`
- `test/test_avr_build_rebuild.sh:19` (and appends to the copy at :131)
- `test/test_make_serialization.sh:39`
- `test/test_workload_rebuild.sh:18`
- `test/test_pic_build.sh:112`
- `test/test_pic10f320_coverage_archive.sh:32,36`

### 3.2 Sites that read or transform its text as the source of truth

- `test/test_makefile_name_contract.py:464,506,1619` — three separate harvests
  (`$(NAME)` references, `NAME=` environment channels, recipe writes), plus
  `rel == "Makefile"` scoping at :411 and :1062.
- `test/test_variant_selector_guard.py:78`
- `test/test_fuse_injection_contract.py:294`
- `test/test_soak_reset_witness.sh:57`
- `test/test_variant_map_contract.sh:91-94` — copies, appends a bogus entry,
  re-harvests.
- `test/test_analyze_variant_guard.sh:94-97` — `sed`s a guard out of the
  `analyze-misra:` line, then `cmp -s` to prove the mutation landed.
- `test/test_misra_output_contract.sh:133-142` — `awk`s the output gate out of
  the `analyze-misra` recipe.

### 3.3 Loud failures are fine; the silent ones are the problem

Splitting these into two classes is what makes the risk concrete.

**Would fail loudly** (and are therefore harmless):
`test_misra_output_contract.sh`, whose awk ends `END { if (!removed) exit 2 }`;
`test_analyze_variant_guard.sh`, whose `cmp -s` asserts the sed changed
something; and any sandbox build that cannot find a target it needs.

**Would silently check less** — this is the hazard:

- `test_soak_reset_witness.sh:57` is a *negative* grep: `if grep -q --
  '-DSOAK_SELFTEST' "$ROOT/Makefile"; then fail`. Move a recipe into a fragment
  and the grep goes false, so the assertion passes vacuously. The check inverts
  from "no recipe defines the self-test hook" to "no recipe in this one file
  does".
- `test_makefile_name_contract.py` harvests names from one file and asserts each
  is defined or consumed. After a split each harvest shrinks; the contract still
  passes, over a smaller vocabulary. The same shape applies to
  `test_variant_selector_guard.py`, `test_fuse_injection_contract.py`, and the
  positive half of `test_variant_map_contract.sh`.
- A sandbox missing `mk/` does not necessarily error. The mutation probe scores
  a failed baseline as a **skip**, so the gate quietly shrinks and the summary
  blames an absent toolchain. That exact failure has already cost this project
  18 silently unenforced mutants once.

The through-line: this is silent under-coverage in the machinery whose whole
purpose is to prevent silent under-coverage. That is why the split is not a
mechanical refactor, and why the sequencing in §4 puts the safety net first.

## 4. If it is ever done, the ordering

1. **Name the file set first; split nothing.** `MAKEFILE_LIST` is currently
   unused in this Makefile and is the natural single source of truth, exposed
   through the existing `print-%` introspection. Convert all fourteen
   consumers in §3 to ask Make for the list instead of hardcoding the path. All
   gates stay green — this is a no-op commit, and it is worth doing on its own
   merits even if no split ever follows, because it removes a hardcoded
   assumption from fourteen places.
2. **Move one section as a canary: PIC12F675.** It was the largest (1668 lines)
   and most recently churned section at the original measurement. It is now a
   release-supported target, so the earlier reduced-publication-blast-radius
   rationale no longer applies: a split must preserve and reverify its release
   semantics in addition to the make-database equivalence check below.
3. **Verify with `make -rRn --print-data-base`.** Before and after must be
   identical modulo file/line attribution. `test/test_clean_contract.sh:65`
   already uses that oracle, so it is known to work in this tree. It is a
   stronger equivalence check than re-running the gates.
4. Remaining MCU sections, one per commit, each verified the same way.

## 5. Is GNU Make still the right tool?

**Yes.** Make is not what is straining.

What the file actually does:

- **A real dependency graph** producing 21 release images across five
  cross-toolchains, with incremental rebuild. Make's home turf.
- **A task runner** for ~90 phony gates that mostly shell out to `test/*.sh` and
  `test/*.py`. Make's weakest use — but the heavy logic has already been moved
  out; what remains in the recipes is skip-guards, tool discovery and argument
  marshalling.
- **A declarative data source.** `print-%` / `origin-%` / `origins` let
  `scripts/make-release.sh` and the CI workflows read canonical names, fuse
  bytes and build directories from the Makefile rather than a drifting copy.
  Unusual, and genuinely effective.
- **Global serialisation** via the flock re-exec.

Alternatives, and why each costs more than it returns:

- **CMake / Meson** — both model one toolchain per build tree. This project has
  five exotic ones (XC8, avr-gcc 7.3, yasimavr, gpsim, CBMC, KLEE). The result
  is five build trees plus a driver, and the `print-%` single-source-of-truth
  interface is lost.
- **Bazel / Buck** — hermeticity is genuinely attractive for reproducible
  release images, but it means hand-writing rules for XC8, gpsim, yasimavr and
  CBMC. Not proportionate.
- **just / Taskfile** — good task runners with no dependency graph. Make would
  still be needed for the compile graph, so the result is two tools.
- **Python / Invoke** — real data structures and testability, tempting given
  that this project already tests its build system. But it replaces a
  decades-hardened dependency engine with ~4000 lines of bespoke code that is
  now the project's own to get right. For a codebase whose first priority is
  correctness, that is the wrong direction.

## 6. What is actually straining: PIC duplication

The three PIC parts have near-identical target *vocabularies* — roughly fifteen
parallel names each (`-analyze`, `-analyze-cppcheck`, `-analyze-misra`,
`-coverage-check-fw`, `-test-config`, `-test-gpsim`, `-test-soak`, `-test-io`,
`-test-lockstep`, `-test-target`, …) written out longhand across ~3700 lines.
The technique for collapsing that is already in-house: `VARIANT_BUILD_T13`,
`VARIANT_BUILD_X5`, `MCU_X5_BUILD_TARGETS`, `MCU_X5_FLASH_TARGETS`,
`VARIANT_SIM_T13` and `VARIANT_SIM_X5` are all `$(eval $(call ...))` templates.

**It should not be applied to the PIC recipes.** Comparing
`pic10f322-test-soak` against `pic12f675-test-soak`: the skip-guard skeleton is
~70% identical, but the 12F675 arm additionally runs the simcal matrix check and
resolves `_gpio_shadow_` from the `.sym` — because that part has no output-latch
SFR, so the shadow *is* the latch. That is not incidental divergence; it is the
part being genuinely different. A template covering it needs escape hatches, and
a leaky template reads worse than the duplication it replaces.

The clean candidates are the **declaration** blocks. These four are byte-identical
across all three parts (`Makefile:1458-1461`, `:5056-5059`, `:5787-5791`):

```make
PIC*_SOAK_DURATION_MS          ?= 3600000
PIC*_SOAK_LIVENESS_INTERVAL_MS ?= 60000
PIC*_SOAK_PROGRESS_INTERVAL_MS ?= 3600000
PIC*_SOAK_COMBINATION_NAME     ?= standalone
```

while `_SRC`, `_BIN`, `_HEX`, `_SYM` and `_COMPILE` legitimately diverge per
part. Factoring the identical knobs is defensible; factoring the rest is not.

## 7. Conclusion and revisit triggers

The effort-and-risk versus benefit trade does not currently favour acting. The
Makefile is large but organised, the sections are banner-delimited and
navigable, and the fourteen consumers in §3 mean a split is a multi-commit change to
the test infrastructure — not a mechanical file move. **Deferred, deliberately.**

Revisit if any of these becomes true:

- **A sixth MCU family is added.** Each new part has cost 700–1700 lines; the
  per-MCU sections would then be past ~6000 lines on their own, and the
  per-section independence argument in §2 gets much stronger.
- **The per-MCU sections stop being independent** — i.e. a change to one part's
  lane starts routinely requiring edits inside another part's section. That is
  the signal that the banners have stopped describing real boundaries.
- **Merge conflicts in the Makefile become routine** across concurrent lane
  branches. Today the lanes are developed largely in sequence, which is why the
  monolith has not hurt.
- **Step 1 of §4 gets done for its own sake.** Once `MAKEFILE_LIST` is the
  single source of truth for the file set, the dominant cost in §3 is already
  paid and the remaining split is much cheaper — at which point the trade may
  flip on its own.

Not a trigger: the line count alone. See §1.
