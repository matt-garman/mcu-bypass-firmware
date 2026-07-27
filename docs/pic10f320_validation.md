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

Both release lines — that project's `v0.9.0`–`v0.9.5` and this one's — are signed
with the same key, `6184219C6670945D7174F2B0149F042FCC3D3AEC`, so verifying a
pre-merge PIC10F320 image and verifying a current one trust the same signature.
The historical PIC10F320 binaries themselves were deliberately not copied into
this repository (their version numbers collide with this project's own line, and
the older ones contain retired `tmux4053-*` images); they remain downloadable
from the predecessor repository's release pages, and prebuilt PIC10F320 images
ship here from `v0.9.6` onward.

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

## 3. The verification lanes, and what each returned

Measured on XC8 V3.10 + PIC10-12Fxxx DFP 1.9.189, gpsim 0.32.1, all three output
variants unless noted.

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

The suite is only as good as its ability to *fail*. Final tally under
`MUTATION_ALLOW_SKIP=0`: **74 mutants, 74 killed, 0 survived, 0 errored,
0 skipped.**

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
- **A mutant built against a sandbox missing its own harness dies for the wrong
  reason** — an *error*, not a kill. The driver's tree copy must reach
  `test/pic10f320/{equiv,actuation,fault,gpsim}/` and carry `.stc` and `.sh`
  files.

## 6. What is *not* validated here

Stated so nobody has to infer it:

- **The inlining seam remains a seam.** Everything above is a behavioural
  equivalence argument. It is not the same kind of statement as "the verified
  code is the shipped code", which is what every other target gets for free.
- **Emitted bytes are no longer watched** across source changes (§2).
- **The output-latch integrity check is absent** (§4).
- **Hardware-bench properties are simulated, not proven**: WDT timing and
  brown-out behaviour, absolute tick period, and real-silicon pulse timing. These
  are shared with the PIC10F322 build, since both are validated in the same gpsim
  environment — see *Known gaps* in `test/README.md` for the full list, including
  gpsim's TMR2 prescaler-select clamp and the bug it once masked.

## 7. Reproducing any of this

```
make pic320-test                    # build+budget, CONFIG, analysis, gpsim, host lanes
make pic320-test-target-variants    # fail-closed libgpsim fault/lock-step/I-O
make test-mutation MUTATION_ALLOW_SKIP=0
make pic320-test-soak PIC320_SOAK_DURATION_MS=86400000
```

Add `STRICT_TOOLS=1` to any of these. Without it a missing tool makes the lane
skip and exit 0, and a skipped lane must never be read as a passing one.
