# PIC10F320 — the constrained target

**Status:** supported, release-gated, and architecturally different from every
other target in this repository. This document is the single authoritative
statement of that difference. Other documents link here rather than restating
it; if you find a second explanation of the assurance caveat anywhere in this
project, that copy is the bug.

**Read this if** you are choosing an MCU, reviewing the assurance argument, or
wondering why one firmware file looks unlike the rest of `src/`.

---

## 1. Why it is different: 256 words

The PIC10F320 has **256 words of program flash — exactly half the PIC10F322's
512**. Everything below follows from that one number.

Every other target in this project is built the same way: a small hardware
shell (`src/bypass_mcu_*.c`) calls into `src/bypass_pure.c`, the pure,
side-effect-free debounce core that the host, property, exhaustive, symbolic and
CBMC suites all verify. The shell handles pins, timers and the watchdog; the
core decides. That separation is the reference architecture and it is what makes
the verification argument simple: **the code that is proven is the code that
ships**, in the same translation unit.

That architecture does not fit in 256 words. This is measured, not assumed:
`docs/pic10f320_feasibility.md` records the full analysis — the modular firmware
overshoots by roughly 100 words under free-tier XC8, and no correctness-preserving
source change closes the gap.

So the PIC10F320's firmware, `src/bypass_mcu_pic10f320.c`, is a single
self-contained file with the debounce algorithm **hand-inlined into `main()`**:
the saturating integrator, the state machine and the power-on initialisation are
written out in the main loop rather than called. The three output stages are
inlined the same way, as `#if defined(OUTPUT_*)` blocks, instead of linking
`src/bypass_output_*.c`.

## 2. The seam, stated plainly

Inlining by hand creates a **seam**: two expressions of the same algorithm that
a compiler is not keeping in step. On every other target that seam does not
exist, because there is only one expression of the algorithm and it is compiled
straight into the image.

This is the one trust assumption the PIC10F320 carries that the other targets do
not. It is heavily mitigated — the next section is entirely about how — but it
is **mitigated, not eliminated**, and this project would rather say so than
imply a parity it has not earned.

## 3. What closes the gap, and how far

Every one of these runs against **`src/bypass_pure.c` itself** — the same file
every other target compiles into its shipping image, not a vendored copy of it.
That property is worth stating explicitly, because the predecessor project *did*
vendor a copy, and "verified against a snapshot of the core" is a materially
weaker claim than "verified against the core".

| Lane | What it proves | Make target |
| --- | --- | --- |
| **Firmware↔core equivalence** | The real firmware, host-compiled, stepped tick-for-tick against the verified core on 266,144 stimulus sequences, covering all 66 reachable model states, with zero divergence | `pic320-test-equiv` |
| **Actuation sequence** | Each variant's full settled `LATA` at every tick, plus the mute/relay *mid-actuation* pin sequencing and pulse width that a settled snapshot cannot see | `pic320-test-actuation` |
| **Host fault injection** | The defensive layer valid stimulus never reaches: corrupt a guarded SFR or the debounce context and the sanity gate must force a watchdog reset | `pic320-test-fault-host` |
| **Firmware line coverage** | An *exact* property, not a percentage floor: every line of the shipping firmware is exercised except an enumerated, justified watchdog-reset path | `pic320-coverage-check-fw` |
| **Real-HEX lock-step** | The actual emitted image, running in a simulated PIC10F320, tracked against the verified core for 3,000 iterations per variant with zero divergence | `pic320-test-lockstep` |
| **Target fault injection** | The same defensive-layer argument on the real image in libgpsim: corrupting every guarded SFR/SRAM location and the required `TRISA` directions forces exactly one real watchdog reset | `pic320-test-fault-target` |
| **Target I/O** | Exact `TRISA`, physical `PORTA` following every `LATA` transition, each variant's complete startup/engage/bypass sequence, and mute/relay pulse widths measured from simulator cycles | `pic320-test-io` |
| **CONFIG word** | The emitted CONFIG word matches design intent — a wrong bit is invisible to every other test and would only bite on silicon | `pic320-test-config` |
| **Static analysis** | cppcheck + MISRA-C:2012, across all three output variants | `pic320-analyze` |
| **Soak** | 24-hour-equivalent libgpsim soak per output stage, as part of release qualification | `pic320-test-soak` |
| **Mutation** | Deliberate firmware faults injected and required to be *killed* — proof the lanes above fail on broken code, not merely pass on correct code | `test-mutation` |

`make pic320-test` runs the pre-hardware set; `make pic320-test-target-variants`
runs the fail-closed real-HEX aggregate across all three variants. Both are
release gates and both run in CI on every push.

**What this does not do.** It does not make the architecture identical. A
behavioural equivalence argument, however thorough, is a different kind of
statement from "the verified code is the shipped code". The honest summary is:
*the PIC10F320 is validated to the same standard by a different and more
elaborate route.*

## 4. One recorded omission: the output-latch match

The PIC10F322 shell checks two things about its pins that the PIC10F320 checks
only one of:

| Defensive check | PIC10F322 | PIC10F320 |
| --- | --- | --- |
| Required output pins are still outputs | yes | yes |
| **Exact** `TRISA` across all four implemented bits | yes | **yes** (ported 2026-07-26) |
| Full output-**latch** match against the expected mask | yes | **no — omitted, see below** |
| `ANSELA` integrity of the output pins | yes | yes |

Exact `TRISA` was ported because it turned out to cost **one word** per variant
(219→220, 240→241, 243→244 of 256). It also *subsumes* the older per-pin check,
which is why it was nearly free — and it closed a real blind spot, cd4053-simple's
spare RA2 pin, which the previous per-variant mask did not cover.

The output-latch match **does not fit and is deliberately omitted**. Measured
cost, in the leanest formulation that preserves the check's meaning:
cd4053-mute overshoots 256 words by **5**, tq2-relay by **3**. Only
cd4053-simple would fit, at 240/256.

Taking it on cd4053-simple alone was considered and rejected. A defensive layer
that differs *between variants of the same firmware* is worse than a uniform,
documented omission: the fault harness and the mutation topology would both need
per-variant expected counts, and this document would have to explain a three-way
split instead of one clean statement.

**What the omission means in practice.** The firmware still range-checks
`ctx_.effect_state` in the main-loop sanity gate before acting on it, and the
actuation, target-I/O and lock-step lanes all assert the *observed* output state
at every settled tick. What is missing is the firmware's own in-line
self-check that its output latch still matches what its state says it should be —
a defence against a single-event upset in `LATA` between one tick and the next.
On the PIC10F322 that window is closed in firmware; on the PIC10F320 it is
covered only by the watchdog and the next tick's write.

## 5. Keeping it in step: the shared surface

Because the algorithm is written out by hand here, a change to the core does not
propagate to this target the way it does to every other one. The shared surface
is small, finite and auditable — this is all of it:

| Item | Core / driver source | PIC10F320 firmware |
| --- | --- | --- |
| Press threshold | `PRESSED_THRESH` in `src/bypass_config.h` | its own `#define PRESSED_THRESH` |
| Release/lock-out threshold | `RELEASE_THRESH` in `src/bypass_config.h` | its own `#define RELEASE_THRESH` |
| Saturating integrator | `debounce_integrate()` in `src/bypass_pure.c` | inlined in the `main()` loop |
| State machine | `debounce_step()` in `src/bypass_pure.c` | inlined `switch` in `main()` |
| Power-on init | `debounce_init_context()` in `src/bypass_pure.c` | inlined in `init()` |
| Output stages | `src/bypass_output_{cd4053_simple,cd4053_with_mute,tq2_l2_5v_relay}.c` | inlined `#if defined(OUTPUT_*)` blocks |
| Analog-switch polarity | unified drive in the two CD4053 drivers (BYPASS = pin low, ENGAGE = high) | inlined `hw_x4053_ctl_high/low` |

The pin map (RA3 footswitch, RA0 LED, RA1/RA2 control) and the CONFIG word are
PIC-local and shared with nothing.

**The sync is manual, but it is not merely documented — it is enforced.** This is
the one place where merging into this repository changed the assurance argument
rather than just relocating it. `pic320-test-equiv` compiles the *real* firmware
and the *real* `src/bypass_pure.c` into one host binary and steps them together,
taking its thresholds from `src/bypass_config.h` through the host shim. So a
change to the core that this firmware does not mirror produces a divergence, and
the divergence fails `make test`. Verified by deliberately changing
`PRESSED_THRESH` from 8 to 9 in `src/bypass_config.h` alone:

```
equivalence: 511 sequences compared, 1 divergence(s)
make: *** [pic320-test-equiv] Error 1
```

The predecessor project could not make that claim: it held a *vendored copy* of
the core pinned to an old commit, so the parent could advance freely and nothing
would notice. Treat the table above as the checklist for what to edit, not as
the mechanism that catches you forgetting.

Two gaps the equivalence lane does not cover, so the table still earns its keep:
the **output-stage** rows (covered instead by `pic320-test-actuation`, which
asserts each variant's settled and mid-actuation pin patterns) and anything that
changes only the *defensive* layer, which is compared by no automatic gate
against the PIC10F322 shell — §4 above is the current, deliberate divergence.

## 6. So: should you use it?

**Prefer another target when you can choose the part.** The AVR Classic parts and
the PIC10F322 all compile the verified core directly, and the PIC10F322 is
pin-compatible with the PIC10F320 in this design, has double the flash, and
carries the full defensive layer.

**Use the PIC10F320 when it is a hard requirement** — cost, existing inventory,
or an established board. It is a supported, release-gated target held to the same
robustness goal by the different route described above, and its images ship in
every release with the same reproducibility guarantee as any other.

## 7. Where the rest of it lives

"One caveat" does not mean "one PIC10F320 document". The assurance comparison
lives here; the engineering detail stays where it belongs:

| Topic | Document |
| --- | --- |
| What was actually run, and what it returned | `docs/pic10f320_validation.md` |
| Why the modular architecture does not fit — the measurement | `docs/pic10f320_feasibility.md` |
| Pin map, CONFIG word, clock/timer/WDT, resource use | `DESIGN_DOCUMENTATION.adoc` |
| Toolchain versions, build commands, flash budget gate | `TOOLCHAIN.adoc` |
| Test-suite structure, per-lane rationale, simulator gaps | `test/README.md` |
| Flashing, image naming, release reproduction | `release/README.md` |
| MISRA-C:2012 status and the two documented deviations | `MISRA_COMPLIANCE.md` |
| How this target was merged in, and every decision made | `docs/pic10f320_merge_plan.md` |
