# PIC10F320 validation record

**What this is:** the durable evidence that the PIC10F320 target is what it
claims to be. `docs/pic10f320_special_case.md` argues *why* this target needs a
different assurance route; this document records *what was actually run and what
it returned*, including two pieces of evidence produced by gates that no longer
exist.

**Why it is separate from the merge plan.** `docs/pic10f320_merge_plan.md` is
process documentation — it will read as history soon and is long. The facts
below outlive it, and one of them (the byte-identity proof) came from a
deliberately one-shot gate whose baseline was deleted, so if it is not written
down here it is not written down anywhere durable.

**Current qualification status (2026-07-27): pending.** The last complete
merged-tree toolchain run was recorded at `0536615`, before this repair branch's
test/release hardening. The branch audit proved one reported mutation kill was
caused by a missing sandbox harness, invalidating the run's 74/74 tally. The
corrected host and fake-tool regressions pass, but this host lacks XC8,
gpsim/libgpsim, and the other release tools. A fresh fail-closed full-tool run,
including 74/74 mutation testing and release rehearsal, is required before the
first unified release. Numeric results below are historical evidence at their
recorded merge-time tips, not a current-tip release attestation. The new
dependency-free return-stack oracle selftest passes on this host, but XC8 is not
available to produce current-tip images, so no current real-image stack depths
are claimed here.

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
`6184219C6670945D7174F2B0149F042FCC3D3AEC`; the planned unified release uses that
same signing identity, so there is no intended key transition.
The historical PIC10F320 binaries themselves were deliberately not copied into
this repository (their version numbers collide with this project's own line, and
the older ones contain retired `tmux4053-*` images); they remain downloadable
from the predecessor repository's release pages. Prebuilt images are planned to
start with the first successfully qualified unified release (`v0.9.6` is the
current candidate); no such release exists yet.

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

This is the evidence with no live gate behind it, so it is recorded in full.

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

**The gate is retired, deliberately.** It was a one-shot *migration* check, and
its reference — the child's committed release images — was deleted with the
import prefix. A gate whose baseline has disappeared is worse than no gate. The
cost is stated plainly: **nothing at the current tip watches emitted bytes**
across a source change; the equivalence and lock-step lanes assert behaviour.
Promoting this to a standing expected-image-hash regression is one file plus one
`pic320` prerequisite if that trade is ever judged wrong.

## 3. Historical verification results

Measured during the merge on XC8 V3.10 + PIC10-12Fxxx DFP 1.9.189, gpsim 0.32.1,
all three output variants unless noted. These results establish the implemented
lanes and historical baseline; the status note above governs release readiness.

| Lane | Result |
| --- | --- |
| Build + 256-word budget | 220 / 241 / 244 words of 256; Intel-HEX validated |
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
| Mutation | see §5 |

Two of these deserve emphasis:

- **Equivalence and lock-step both run against `src/bypass_pure.c` itself** — the
  same file every other target compiles into its shipping image, linked into the
  test binary. The predecessor project could only compare against a *vendored
  copy* pinned to an old commit. That copy no longer exists anywhere in this
  repository.
- **Lock-step is the emitted image**, not the source: the actual XC8 output
  running in a simulated PIC10F320, its live `_ctx_` SRAM compared to the model
  after every completed main-loop iteration.

### 3a. Final-HEX hardware return-stack gate

`test/pic10f320/return_stack_oracle.py` closes the previously open gate-
implementation gap for the 8-level hardware return-stack bound without relying
on XC8's listing format or an external disassembler. It strictly validates Intel
HEX, reconstructs the PIC10F320's little-endian 14-bit words, and traverses
reachable control flow from reset with the exact abstract return-address stack.
Every direct `CALL` pushes, `RETURN` and every classic `RETLW` alias pop, and all
four skip instructions fork along both independently tested edges. The classic
`MOVLW` aliases all fall through. Control states and return addresses preserve
the 9-bit architectural PC (`0x000..0x1ff`); only instruction fetch aliases
through the low eight bits into the 256 implemented physical words. Reachable
holes and empty returns fail.

The proof is deliberately narrower than a general PIC emulator and fails closed
at that boundary: reserved/non-classic words, `RETFIE`, computed PCL writes,
data-dependent writes through classic `INDF`, and any path that could enable GIE
are rejected because they can create an unmodelled successor or asynchronous
push. The command-line default is eight and the Makefile limit is immutably
eight. `test-pic320-return-stack-oracle` runs 139 deterministic checks in
`make test` and `test-long`, including an exhaustive independent legality map,
every destination-writer class, operand-boundary skip cases, wrap behavior,
nested LIFO returns, and a literal precomputed HEX layout fixture.

Every `pic320` build invokes the immutable oracle before setting
`image_complete=1`, inside the existing cleanup trap. This covers later
gpsim/target/soak/release rebuilds as well as direct builds; Python, oracle, or
analysis failure deletes that generated image. `pic320-test-return-stack` remains
the complete-matrix reporting target: it depends on fresh `pic320-variants`,
expands all three image names from the immutable supported set, then rechecks all
three together as part of `pic320-test`. This is not a claim that a file cannot
be modified after a successful recipe; release provenance and reproduction
checks remain separate evidence.

The fake-XC8 build regression reports 28 PIC10F322 checks and 68 PIC10F320
checks. The 320-specific cases prove the base build deletes structurally valid
reachable-RETFIE and depth-9 images, and that nonempty successful-oracle and
limit-99 command-line overrides cannot bypass the immutable Makefile settings.

As retrospective parser/decoder context only, the predecessor project's signed
`v0.9.5` images measure 3 / 3 / 4 entries for simple / mute / relay. Those files
predate the merged-tree exact-TRISA firmware change and are not current-image
qualification evidence. Current-tip real-image results remain pending for the
reason in the status block above.

### 3b. Rebuild-trigger regression

The PIC10F320-only arm of `test/test_pic_build.sh` closes merge-plan §6.12's
rebuild row in the existing fresh `mktemp` repository rather than creating a
second sandbox. Its fake XC8 and host compiler log every command by exact output
name. Assertions count only invocations for that output and inspect the latest
applicable command, so an old matching flag cannot mask stale reuse.

Activation and accounting fail closed: canonical `PB_TARGET=pic320` requires
`PB_REBUILD_REQUIRED=1` and exactly 68 checks at exit, while canonical
`PB_TARGET=pic` requires exactly 28. Removing or misspelling the Makefile's
PIC10F320 rebuild-arm assignment cannot leave a green 54-check run.

The regression proves all of the following without timestamps:

- an identical repeated `pic320` request invokes XC8 again;
- changing and restoring `PIC320_XTAL` each invoke XC8 with the current clock;
- every object and linked output of `pic320-test-equiv` rebuilds on an identical
  repeat, on a variant change and restoration, and on a
  `PIC320_HOST_CFLAGS` change and restoration;
- the unqualified shared equivalence harness is compiled with the current output
  macro after both variant transitions; and
- every object and linked output of `pic320-test-actuation` and
  `pic320-test-fault-host` rebuilds on identical repeats.

`pic320-coverage-check-fw` is deliberately outside this stable-output probe. It
creates a unique `mktemp` work directory on every invocation, requires fresh
`.gcda` and `.gcov` files before passing, and removes the directory on exit; it
has no prior binary or profile that a later request can reuse.

The fake host compiler writes nonempty objects and executable success stubs for
the linked tests. Those stubs append their invoked path to a fresh execution log,
and every equivalence, actuation, and fault-host stage requires the exact current
execution count as well as exact compile/link counts. After each target's first
successful request, the regression creates a same-name regular file at the
sandbox root before the identical repeat. Correct `.PHONY` declarations force
the recipe to rerun; removing one leaves compiler and execution counts unchanged
and fails the existing check. No assertion relies on timestamps.

This evidence is narrowly **deterministic rebuild triggering and current-option
propagation**. It does not compare generated bytes, does not establish
byte-for-byte reproducibility of real XC8, and does not qualify current-tip real
PIC10F320 images. The standing expected-image-hash TODO remains open, and the
current qualification status at the top of this record is unchanged.

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

## 5. Mutation topology

The suite is only as good as its ability to *fail*. The merge-time run under
`MUTATION_ALLOW_SKIP=0` reported **74 mutants, 74 killed, 0 survived, 0 errored,
0 skipped**, but a post-merge audit invalidated one result: the TMR2IF mutant's
sandbox omitted the shared gpsim wrapper, so infrastructure failure rather than
the cadence assertion killed it. The driver now copies the folded `.sh`/`.stc`
assets and baselines every distinct PIC10F320 kill command. A fresh full-tool
74/74 run is required before release; until then the old tally is historical,
not current evidence.

Mutants are split by what they **need**, not by what they test: 27 require only a
host C compiler and ride with the unskippable core batch; 9 require XC8 + gpsim +
libgpsim and sit behind a tool probe that first verifies the *unmutated* tree
genuinely passes. Without that split they would "survive" on any host lacking the
PIC toolchain — a false pass.

Two cautions learned while building this set, recorded because both produce
misleading greens:

- **A mutant that fails to compile also makes `make <target>` exit non-zero**, so
  it scores as "killed". Confirm any new firmware mutant builds before accepting
  its kill.
- **A mutant built against a sandbox missing its harness dies for the wrong
  reason.** The driver's tree copy must reach both
  `test/pic10f320/{equiv,actuation,fault,gpsim}/` and the folded wrappers and
  stimuli under `test/pic/`. The tool probe now checks those files before
  authorizing any PIC10F320 tool-dependent mutant.

## 6. What is *not* validated here

Stated so nobody has to infer it:

- **The inlining seam remains a seam.** Everything above is a behavioural
  equivalence argument. It is not the same kind of statement as "the verified
  code is the shipped code", which is what every other target gets for free.
- **Emitted bytes are no longer watched** across source changes (§2).
- **Rebuild triggering is not compiler reproducibility.** The host fake-tool
  regression proves current commands run with current flags; it cannot establish
  that real XC8 emits identical bytes across runs or environments.
- **The output-latch integrity check is absent** (§4).
- **A current-tip real-image return-stack result is not yet recorded.** The gate
  and its synthetic fail-closed fixtures are implemented, but this host cannot
  rebuild the three images without XC8. This is pending qualification evidence,
  not an unimplemented bound.
- **Hardware-bench properties are simulated, not proven**: WDT timing and
  brown-out behaviour, absolute tick period, and real-silicon pulse timing. These
  are shared with the PIC10F322 build, since both are validated in the same gpsim
  environment — see *Known gaps* in `test/README.md` for the full list, including
  gpsim's TMR2 prescaler-select clamp and the bug it once masked.

## 7. Reproducing any of this

```
make pic320-test                    # all lanes; each build stack-checks its final HEX
make pic320-test-return-stack       # fresh all-image stack recheck + depth witnesses
make pic320-test-target-variants    # fail-closed libgpsim fault/lock-step/I-O
make test-pic-build                 # host fake-tool image/rebuild regression
make test-mutation MUTATION_ALLOW_SKIP=0
make pic320-test-soak PIC320_SOAK_DURATION_MS=86400000
```

Add `STRICT_TOOLS=1` for authoritative optional analyzer/simulator results.
Individual optional-tool lanes may otherwise skip, but the return-stack target
does not: missing Python or any image is a failure, and `pic320-test` includes it.
