# PIC10F320 validation record

**What this is:** the durable evidence that the PIC10F320 target is what it
claims to be. `docs/pic10f320_special_case.md` argues *why* this target needs a
different assurance route; this document records *what was actually run and what
it returned*, including historical evidence from retired migration gates and
the provenance behind their standing successors.

**Why it is separate from the merge plan.** `docs/pic10f320_merge_plan.md` is
process documentation — it will read as history soon and is long. The facts
below outlive it, and one of them (the byte-identity proof) came from a
deliberately one-shot gate whose original child-tree baseline was deleted. Its
reviewed successor digests now drive a standing gate, while the migration proof
and its provenance remain durable only here.

<!-- current-release:start -->
**Current release contract:** `v0.9.9`; seven release parts; 21 images; 18 soak combinations; six modular targets; four shell source files.

**Qualification status (2026-08-17):** PIC10F320 remains the self-contained
exception. The authoritative `QUALIFICATION`, manifest, image checksums, and
exact 34-file lane/soak evidence live under `release/v0.9.9/`; that retained
record, rather than this summary, identifies the qualified source commit and
measured results.
<!-- current-release:end -->

The preceding `v0.9.8` production record retains all 18 then-canonical images,
15 full-duration soak combinations, and the rename-identity evidence that pins
17 renamed images byte-identical while recording the intentional PIC10F320 relay
change under `release/v0.9.8/`.

The earlier `v0.9.7` production record identifies source commit `1d2fc877`,
all 18 then-canonical images, and 15 full-duration soak combinations under
`release/v0.9.7/`.

Release `v0.9.6`, the first unified release, qualified final source commit
`d3ba040`: all 18 canonical images
built, the required AVR-XT and PIC host/target aggregates passed, and all 15
release soak combinations completed their full 24-hour simulated durations. The
retained `QUALIFICATION`, manifest, image checksums and lane/soak evidence live
under `release/v0.9.6/`; artifact commit `4f4b085` is published under the unified
`v0.9.6` tag.

The earlier clean-tree, full-tool `--dry-run` at `4b28210` remains useful
historical routing evidence: it built the then-current 15-image set, passed five
release gates including the corrected 74/74 mutation run, and ran all 12
then-canonical soak combinations for 60 seconds. It was explicitly
non-publishable and predates the final production contract. Numeric results below
remain historical evidence at their recorded tips unless they explicitly cite
a retained production record or identify narrow change evidence. The `v0.9.8`
Run 4 results below were produced on 2026-08-06 from the exact firmware and tests
committed with this document. They remain useful narrow change evidence but do
not replace the retained clean-server, full-duration `v0.9.8` qualification.

---

## 1. Provenance: the firmware is the reviewed source, moved verbatim

`src/bypass_mcu_pic10f320.c` came from a separate repository via a non-squashed
`git subtree` import, so the full development history is reachable in this
repository's graph. The six original signed release tags are preserved under a
namespace:

```
pic10f320/v0.9.0   pic10f320/v0.9.1   pic10f320/v0.9.2
pic10f320/v0.9.3   pic10f320/v0.9.4   pic10f320/v0.9.5
```

The import commit is `a15d7b6`, importing child HEAD
`f58d2d57ef5a72637fbc032a3f3676f249409b68`. The move itself was a `git mv`, and
the moved file was confirmed byte-identical to the child original — a checked
fact, not a review claim.

Both historical release lines are signed with the same key,
`6184219C6670945D7174F2B0149F042FCC3D3AEC`; the unified `v0.9.6` release uses
that same signing identity, so there was no key transition.
The historical PIC10F320 binaries themselves were deliberately not copied into
this repository (their version numbers collide with this project's own line, and
the older ones contain retired `tmux4053-*` images); they remain downloadable
from the predecessor repository's release pages. Unified prebuilt PIC10F320
images begin with this repository's `v0.9.6` release.

**Querying that history.** The import is a merge commit, so ordinary
`git log --follow` stops at it: by default `git log` does not descend into a
merge's second parent, and `--follow`'s rename detection does not survive the
crossing. Use `-m`, which splits the merge and lets the walk continue:

```sh
git log -m --follow -- src/bypass_mcu_pic10f320.c
```

If a query still stops short, look the path up in two stages — this repository's
history down to the import, then the child's original path from the imported side:

```sh
git log --oneline -- src/bypass_mcu_pic10f320.c            # since the move
git log --oneline a15d7b6^2 -- bypass_mcu_pic10f320.c      # before it
```

Seamless single-command `--follow` would have required rewriting the imported
commits, which sacrifices their original object identity and invalidates the
signed tags above. That trade was declined deliberately.

## 2. Byte identity: the ported build recipe emits the same bytes

This historical evidence now supplies the reviewed baseline for the standing
`pic10f320-test-build` gate, so its provenance is recorded in full.

The concern the check existed to answer: the build recipe was *rewritten* during
the merge — new variable names, a different Makefile, a different flash-budget
implementation. A recipe port that silently changed optimisation level, `-mdfp`,
include order or CONFIG-word emission would pass every behavioural test in this
project, because those test behaviour, not emitted bytes.

**Run 1 — the migration proof.** All three variants built in the merged tree from
the relocated source, compared byte-for-byte against the child's *signed*
`release/v0.9.5/` images. **PASSED 3/3, byte-identical.**

```
26531d3408a75297656d722699a1ffafdc47de376af6b4d2aa62b303c6713ca8  bypass_mcu_cd4053-simple_pic10f320.hex
7709a3979b9103411b1f2e0c892d2291e1c232b5033344bd645ae289ac55649f  bypass_mcu_cd4053-mute_pic10f320.hex
b77e21221b8a94788781b2d1df6a66e0487317cb215d5d540c5582db2a47c4e2  bypass_mcu_tq2-relay_pic10f320.hex
```

**Run 2 — after the defensive-layer edit (§4 below), which deliberately
rebaselines.** Re-running the check against the *old* hashes failed on all three
variants, which is the intended outcome: a clean pass there would have proved the
check was blind. Against the new hashes, with the *hardened* build rule (budget
gate, Intel-HEX validation, cleanup traps), **PASSED 3/3** — additionally proving
that the hardening changed no emitted byte.

```
e48ed8e50e89a7f2c2e145603d16c25099925269ea0b29b31becc9c02eb2143f  bypass_mcu_cd4053-simple_pic10f320.hex
1cc2cbf6572a876b1a0a5d19e2e3179a41c7a46bd1b7419d2b5e72aa2aec27a7  bypass_mcu_cd4053-mute_pic10f320.hex
b30783d20e1ef088b3fa612cb7c41755b48ba1060395e01cf7360ea664d1e50f  bypass_mcu_tq2-relay_pic10f320.hex
```

**Run 3 — after the source-comment sweep.** The comment-only firmware edit was
re-checked against the run-2 hashes: **MATCH on all three**. Comments cannot
change codegen, but "cannot" and "did not" are different claims.

**Run 4 — the `v0.9.8` relay idle-latch safety correction.** The relay-only
`set_relay_coils_low()` call intentionally changes one image. A pinned XC8 V3.10
and DFP 1.9.189 build left both analog-switch images byte-identical to run 2/3 and
changed only the relay image:

```
e48ed8e50e89a7f2c2e145603d16c25099925269ea0b29b31becc9c02eb2143f  bypass-pic10f320-cd4053_simple.hex
1cc2cbf6572a876b1a0a5d19e2e3179a41c7a46bd1b7419d2b5e72aa2aec27a7  bypass-pic10f320-cd4053_with_mute.hex
00e1d3ac37ed1857f5e1b3047e921ac22bd9705a728f7c77c9c9daae31d34cd8  bypass-pic10f320-tq2_l2_5v_relay.hex
```

The relay grew from 244 to 245 words and retained its 4/8 return-stack maximum.
The exact host actuation trace remained 115 checks and the real-image target-I/O
trace remained 36 checks, with no added edge. At the deterministic trailing
`CLRWDT` injection seam, physical-output fault injection measured RESET, SET and
both-bit correction in 364-366 instruction cycles (0.728-0.732 ms at nominal
2 MHz), versus the emitted image's 12.024-12.036 ms intentional coil pulses. An
upset at an arbitrary idle phase has the more general bound of one actual timer
period plus the short two-pin rewrite, still far less per-channel energy than a
normal pulse. This does not prove that an accidental short pulse cannot
mechanically switch the relay, nor characterize the board-specific shared-supply
transient when both drivers are upset together.

R1 closes at the firmware boundary on that evidence. This project does not
specify the external coil-driver topology, power supply, flyback network or PCB,
so adopters must validate relay motion and the simultaneous-driver supply
transient against their hardware. That responsibility is not evidence for
leaving the firmware's former unbounded energy path open.

**Standing regression added after the merge audit.** The original gate was
deliberately retired as a one-shot migration check because its reference images
lived under the deleted import prefix. The reviewed run-4 digests above now live
in `test/pic10f320/expected_images.sha256`. `pic10f320-test-build` rebuilds
the complete immutable variant matrix and requires all three raw HEX files to
match; it runs through `pic10f320-test` in CI and release qualification. The
checker and manifest parser also run without XC8 inside `make test`.

The first two digests remain byte-for-byte the run-2 ones; the relay digest is
the intentional run-4 rebaseline. The older transcripts keep the names those
runs actually emitted, which is what makes them evidence rather than a
restatement.

The hash target intentionally remains separate from the per-variant `pic10f320`
build used by mutation tests. Otherwise every code-generating mutant would die
at the broad byte check before reaching the behavioural lane whose sensitivity
the mutation inventory is meant to prove. A hash change therefore fails normal
qualification while preserving mutation-test attribution. Rebaseline only with
an intentional, reviewed firmware/toolchain change in the same commit.

## 3. Historical verification results

Measured during the merge on XC8 V3.10 + PIC10-12Fxxx DFP 1.9.189, gpsim 0.32.1,
all three output variants unless noted. These results establish the implemented
lanes and historical baseline; the status note above distinguishes that
historical evidence from the current retained production record.

| Lane | Result |
| --- | --- |
| Build + 256-word budget | 220 / 241 / 244 words of 256; Intel-HEX validated |
| Expected image bytes | Three reviewed SHA-256 records; complete matrix enforced by `pic10f320-test-build` |
| Static analysis (cppcheck + MISRA-C:2012) | clean on all three variants, **zero unwaived findings** |
| CONFIG word | 45 checks, 0 failures — `0x389E` on all three |
| Firmware↔core equivalence | **266,144 sequences, 0 divergences**, 66/66 reachable model states |
| Actuation sequence | 108 / 113 / 115 checks, 0 failures |
| Host fault injection | **41 / 41 / 41** checks, 0 failures (uniform since §4) |
| Firmware line coverage | 80/84, 91/95, 95/99 executable lines; 4 allowed-uncovered fault-path lines, **0 disallowed** |
| Target fault injection (libgpsim) | **22 / 22 / 22** checks, 0 failures |
| Target I/O (libgpsim) | 25 / 26 / 36 checks, 0 failures |
| Real-HEX lock-step (libgpsim) | **3,005 checks per variant, 0 mismatches**, 66/66 states |
| CLI gpsim functional | PASS ×6 (toggle + power-on-held, all variants) |
| Fail-closed target aggregate | EXIT=0 |
| Soak (libgpsim) | PASS on all three |
| Hardware return-stack depth | **3 / 3 / 4 levels of 8** (cd4053-simple / cd4053-mute / tq2-relay), 2 held in reserve |
| Mutation | see §5 |

The narrow `v0.9.8` relay-correction rerun updated only the affected current
measurements: build use is 220 / 241 / **245** words; host fault injection is
41 / 41 / **59** checks; firmware coverage is 80/84, 91/95, **96/100**; and
target fault injection is 22 / 22 / **25** checks. The all-variant target
aggregate retained 3,005 lock-step checks per variant and target-I/O counts
25 / 26 / 36, all passing. Full release qualification remains separate from
this narrow change evidence.

The equivalence and lock-step rows carry the weight here, because both run
against `src/bypass_pure.c` itself rather than a vendored copy;
`docs/pic10f320_special_case.md` §3 states why that distinction is the crux of
the assurance argument. Two properties of those two rows are measurement facts,
so they are recorded here:

- **Lock-step is the emitted image**, not the source: the actual XC8 output
  running in a simulated PIC10F320, its live `_ctx_` SRAM compared to the model
  after every completed main-loop iteration.
- **The equivalence lane was sensitivity-checked**, not merely observed passing.
  Deliberately changing `PRESSED_THRESH` from 8 to 9 in
  `src/bypass_config.h` alone produced the expected failure:

  ```
  equivalence: 511 sequences compared, 1 divergence(s)
  make: *** [pic320-test-equiv] Error 1
  ```

### 3a. The hardware return stack, and why it needed its own gate

Added 2026-07-27. This is the one resource bound on this part that nothing
observed, and three things found while closing it are worth recording.

**It is not the AVR's stack question.** `test-stack-bound` bounds the AVR *data*
stack in bytes. The PIC14 core has no data stack at all — XC8 allocates locals
into a static, non-reentrant compiled-stack overlay — so that gate has nothing to
measure here. What this part has is a fixed **8-level hardware return stack**,
declared independently by XC8's own device data (`STACKDEPTH=8`) and the device
pack's `edc:hwstackdepth="8"`. The gate reads the budget from the pack rather
than hardcoding it.

**"Inlined, so it cannot recurse" would have been the wrong answer.** The
debounce logic is inlined into `main()`, but the *output stages* are not. The
relay variant reaches four levels:

```
_main -> _init -> _hw_set_bypass_state -> _set_relay_coils_low
      -> _hw_relay_reset_pin_set_low
```

Measured peak is 3 levels for the CD4053 variants and 4 for the relay — on
**both** PIC chips, whose figures are identical. Real headroom, but not zero and
not structural.

**XC8's own estimate is not a safe upper bound, and its overflow check is only a
warning.** XC8 prints `;; Hardware stack levels required when called: N` per
function; on the shipping tq2-relay image it reports **3** where the emitted
instruction stream contains a verified **4**-deep chain of real `fcall`s, each
confirmed against its enclosing psect. Synthetic chains reproduce correctly, so
this is a property of the real program rather than of the annotation format. The
gate therefore computes the depth itself from the instruction stream and uses
XC8's `callstack` directives — which *do* agree, at 4 — as a cross-check that
fails on disagreement. Separately, a deliberately 10-deep chain compiled for this
part yields `warning: (1393) possible hardware stack overflow detected` and
`xc8-cc` **still exits 0 and writes a HEX**. Overflow is otherwise undetectable
on this core: no `STKPTR`, no `TOSL`/`TOSH`, no `STKOVF` in `PCON`, and no CONFIG
`STVREN` bit, so the stack silently wraps and a return goes to the wrong address.
That is the fail-open `pic10f320-test-stack-bound` closes.

**Two witnesses, deliberately.** The gate above measures the *emitted assembly*
and enforces the policy budget (peak + reserve). §3b re-derives the same quantity
from the *shipped HEX* by a wholly different method. Both run in `pic10f320-test`,
and they agree — 3 / 3 / 4 entries for simple / mute / relay. A disagreement
between them would itself be the finding.

### 3b. Final-HEX hardware return-stack gate

`test/pic10f320/return_stack_oracle.py` is the second, independent witness on the
8-level bound, and the only one that measures the bytes that actually ship. Two
things about it are durable and belong here rather than with the mechanics.

**Why a second witness at all.** §3a establishes that XC8's own estimate is not
a safe upper bound and that its overflow check is only a warning. A gate built on
the compiler's listing would inherit both problems, so this one reads the emitted
HEX and reconstructs control flow itself, trusting neither the listing format nor
an external disassembler.

**Where it deliberately stops.** The proof is narrower than a general PIC
emulator and fails closed at that boundary rather than guessing: anything that
could create an unmodelled successor or an asynchronous push — reserved words,
`RETFIE`, computed PCL writes, data-dependent writes through `INDF`, any path
that could enable GIE — is rejected. That boundary is a design decision, not an
implementation detail, which is why it is recorded as evidence.

The decoder rules, the check inventory, the 9-bit PC/physical-fetch aliasing and
the build-time enforcement path are current mechanics, and live in
*PIC10F320 target validation layers* in `test/README.md`. One limit of that
enforcement belongs here rather than there: running the oracle inside every
build proves what the recipe produced, not that the file cannot be modified
afterwards. Release provenance and reproduction checks remain separate evidence.

As retrospective parser/decoder context only, the predecessor project's signed
`v0.9.5` images measure 3 / 3 / 4 entries for simple / mute / relay. Those files
predate the merged-tree exact-TRISA firmware change and are not current-image
qualification evidence. The three current-at-the-time images passed the oracle
inside the `4b28210` rehearsal, but its exact depth output was not retained in
the repository and it predates later build/release hardening. The `v0.9.6`
production run retained exact-final-source depths and witnesses in
`release/v0.9.6/evidence/pic320-test.log`: 3 / 3 / 4 entries, with at least two
of the eight hardware levels held in reserve for every variant.

### 3c. Rebuild-trigger regression

The PIC10F320-only arm of `test/test_pic_build.sh` closes merge-plan §6.12's
rebuild row, in the existing fresh `mktemp` repository rather than a second
sandbox. Its assertions, check counts and fail-closed activation are current
mechanics and live in `test/README.md`; what belongs in the record is the exact
scope of what it does and does not establish, because that is the part most
easily overread.

The evidence is narrowly **deterministic rebuild triggering and current-option
propagation**: identical requests reinvoke the compiler, and changed build
options reach the command actually run. Two deliberate design points make it
worth trusting — nothing rests on timestamps, and the fake linked tests log their
executed path so a removed binary-run recipe cannot pass on compile counts alone.

It is **not** byte-for-byte XC8 reproducibility, and it does not by itself
qualify exact-final-source PIC10F320 images. For a released version, its
production aggregates and retained release evidence own the qualification
claim.
`pic10f320-coverage-check-fw` is deliberately outside the probe altogether: every
invocation uses a new `mktemp` directory and requires fresh `.gcda`/`.gcov`
evidence, so it has no prior artifact a later request could reuse.

## 4. The defensive-layer decision, measured

The PIC10F322 shell carries two pin-integrity checks the PIC10F320 did not. Both
were priced before deciding, on the real toolchain:

| Configuration | cd4053-simple | cd4053-mute | tq2-relay | Fits 256? |
| --- | --- | --- | --- | --- |
| baseline (as imported) | 219 | 240 | 243 | — |
| **exact `TRISA` only, no-arg helper** | **220** | **241** | **244** | **all three (+1)** |
| exact `TRISA`, helper keeps its unused mask parameter | 221 | 242 | 245 | all three (+2) |
| exact `TRISA` + latch match, lean formulation | 240 | 261 | 259 | simple only |
| exact `TRISA` + latch match, faithful 322 shape | 258 | 279 | 282 | none |

**Exact `TRISA` was ported** — one word, because it *subsumes* the older
per-variant "required pins are still outputs" check, so the helper loses its
parameter and every call site shrinks. It closed a real blind spot:
cd4053-simple's spare RA2 pin, which the previous mask did not cover. The
host fault-check count went from 41/42/42 to a uniform 41/41/41, and the target
count to a uniform 22/22/22 — that uniformity *is* the assurance gain.

**The output-latch match was omitted**, and taking it on cd4053-simple alone was
considered and rejected: a defensive layer that differs between variants of one
firmware is worse than a uniform documented omission. See
`docs/pic10f320_special_case.md` §4 for what the omission means in practice.

`v0.9.8` adds a narrower relay-only safe-state rewrite rather than a partial
latch-match guard. Once per serviced iteration, before the sanity decision and
watchdog pet, both coil bits are forced low. RESET, SET and both-bit injections
must therefore clear in one iteration without a footswitch event or reset. This
does not detect or repair LED/analog-control latch mismatches and does not change
the general omission above. It costs one relay word: 245/256, with 11 free.

## 5. Mutation topology

The suite is only as good as its ability to *fail*. The first merge-time run
under `MUTATION_ALLOW_SKIP=0` reported **74 mutants, 74 killed, 0 survived, 0
errored, 0 skipped**, but a post-merge audit invalidated one result: the TMR2IF
mutant's sandbox omitted the shared gpsim wrapper, so infrastructure failure
rather than the cadence assertion killed it. After that wrapper was restored, a
later full run stopped at 56 killed with 18 PIC mutants skipped, exposing two
additional sandbox gaps. Repairing those two gaps restored all 18, after which
the corrected full-tool run and the `4b28210` release rehearsal both reported 74
killed / 0 survived / 0 errored / 0 skipped.

That corrected execution is historical rather than final-source production
evidence. The mutation driver has since gained immutable category counts,
conservation equations, checked workers and process groups, atomic exact result
records, and fail-closed infrastructure-status classification. Production must
rerun the complete pinned inventory through that current accounting contract.

The current category split, the pinned totals and the accounting equations are
live mechanics and live under *Mutation testing and skipped optional tools* in
`test/README.md`. One structural point is worth stating as evidence rather than
mechanics: **PIC10F320 mutants are split by what they need, not by what they
test.** The host-only majority rides with the unskippable core batch, and the
tool-dependent remainder sits behind a probe that first verifies the *unmutated*
tree genuinely passes. Without that split those mutants would "survive" on any
host lacking the PIC toolchain — a false pass, and the failure mode the whole
skip-accounting design exists to prevent.

Two cautions learned while building this set, recorded because both produce
misleading greens:

- **A mutant that fails to compile also makes `make <target>` exit non-zero**, so <!-- name-contract: exempt (<target> is generic) -->
  it scores as "killed". Confirm any new firmware mutant builds before accepting
  its kill.
- **A mutant built against a sandbox missing its harness dies for the wrong
  reason.** This is the defect that cost the 74→56 regression above. Both sandbox
  builders now share one allowlist walk (`test/scratch_tree.sh`), and the tool
  probe checks the required PIC10F320 helpers before authorizing any
  tool-dependent mutant, so a future omission fails loudly instead of shrinking
  the gate.

## 6. What is *not* validated here

Stated so nobody has to infer it:

- **The inlining seam remains a seam.** Everything above is a behavioural
  assurance package. The host equivalence and real-HEX lock-step lanes compare
  directly with `src/bypass_pure.c`; the other lanes provide orthogonal evidence.
  Together they are still not the same kind of statement as "the verified code
  is the shipped code", which is what every other target gets for free.
- **The standing expected-image gate is not universal compiler
  reproducibility.** `pic10f320-test-build` watches all three emitted images
  against the committed, reviewed SHA-256 baseline from the pinned XC8/DFP
  build, so byte drift fails qualification until an intentional rebaseline. The
  host fake-tool regression separately proves current commands run with current
  flags. Neither establishes that arbitrary XC8 versions or environments emit
  identical bytes.
- **The general output-latch integrity check is absent** (§4). The relay-only
  idle safe-state rewrite bounds settled-state coil-bit upsets; active-pulse,
  LED, and analog-control latch upsets remain outside that mitigation.
- **Hardware-bench properties are simulated, not proven**: WDT timing and
  brown-out behaviour, absolute tick period, and real-silicon pulse timing. These
  are shared with the PIC10F322 build, since both are validated in the same gpsim
  environment — see *Known gaps* in `test/README.md` for the full list, including
  gpsim's TMR2 prescaler-select clamp and the bug it once masked.

## 7. Reproducing any of this

```
make pic10f320-test                    # pre-hardware aggregate; each build stack-checks its final HEX
make pic10f320-test-return-stack       # fresh all-image stack recheck + depth witnesses
make pic10f320-test-target-variants    # fail-closed libgpsim fault/lock-step/I-O
make test-pic-build                    # host fake-tool image/rebuild regression
make test-mutation MUTATION_ALLOW_SKIP=0
make pic10f320-test-soak PIC10F320_SOAK_DURATION_MS=86400000
```

These are the `v0.9.8` goal and variable names. Evidence recorded above and under
`release/v0.9.7/` and earlier was produced by the same lanes under their previous
`pic320-*` / `PIC320_*` spellings; <!-- name-contract: exempt (redirect note) --> `release/README.md` carries the mapping, and
`git checkout` of an earlier tag gets that tree's names along with its Makefile.

Add `STRICT_TOOLS=1` for authoritative optional analyzer/simulator results.
Individual optional-tool lanes may otherwise skip, but the return-stack target
does not: missing Python or any image is a failure, and `pic10f320-test`
includes it.
