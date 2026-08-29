# PIC10F320 — the constrained target

<!-- current-release:start -->
**Current release contract:** `v0.9.11`; seven release parts; 21 images; 18 soak combinations; six modular targets; four shell source files.

**Status:** PIC10F320 is release-supported since `v0.9.6` and remains the
self-contained exception. `DESIGN_DOCUMENTATION.adoc#pic10f320-architecture` is
the normative statement of that difference; this document holds the assurance
comparison and the manual shared-surface checklist behind it, and execution
evidence, its exact scope, release history, and current qualification status
live in `docs/pic10f320_validation.md`.
<!-- current-release:end -->

**Read this if** you are choosing an MCU, reviewing the assurance argument, or
wondering why one firmware file looks unlike the rest of `src/`.

---

## 1. Why it is different: 256 words

The PIC10F320 has **256 words of program flash — exactly half the PIC10F322's
512**. Everything below follows from that one number.

The other six release targets use one modular architecture through four shell
source files. `src/bypass_mcu_avr_classic.c` serves ATtiny13a/45/85,
`src/bypass_mcu_avr_xt.c` serves ATtiny202, and
`src/bypass_mcu_pic10f322.c` serves PIC10F322, while
`src/bypass_mcu_pic12f675.c` serves PIC12F675. Each shell handles pins, timers,
and the watchdog and calls `src/bypass_pure.c`, the pure, side-effect-free
debounce core that the host, property, exhaustive, symbolic, and CBMC suites
verify. The same reviewed core implementation is compiled and linked directly
into all six modular shipping image sets; it is not a vendored copy or a
reimplementation.

That architecture does not fit in 256 words. This is measured, not assumed:
`docs/pic10f320_feasibility.md` records the full analysis — the modular firmware
overshoots by roughly 100 words under free-tier XC8, and no correctness-preserving
source change closes the gap.

So the PIC10F320's firmware, `src/bypass_mcu_pic10f320.c`, is a single
self-contained file. The saturating integrator and state machine are written
directly in `main()`, and debounce initialization is written directly in
`init()`. Its three output variants use source-local static functions selected
by `#if defined(OUTPUT_*)`, instead of linking the modular
`src/bypass_output_*.c` drivers.

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

The host equivalence and real-HEX lock-step lanes compare against
**`src/bypass_pure.c` itself** — the same file every modular target compiles into
its shipping image, not a vendored copy. That property is worth stating
explicitly because the predecessor project *did* vendor a copy. The remaining
lanes below provide orthogonal evidence about actuation, fault handling, source
coverage, emitted bytes, configuration, stack depth and analysis; they are not
described as core-equivalence comparisons.

| Lane | What it proves |
| --- | --- |
| **Firmware↔core equivalence** | The real firmware, host-compiled, must track the verified core tick-for-tick across the configured stimulus set and reachable model states; any divergence fails |
| **Actuation sequence** | Each variant's full settled `LATA` at every tick, plus the mute/relay *mid-actuation* pin sequencing and pulse width that a settled snapshot cannot see |
| **Host fault injection** | The defensive layer valid stimulus never reaches: corrupt a guarded SFR or the debounce context and the sanity gate must force a watchdog reset |
| **Firmware line coverage** | An *exact* property, not a percentage floor: every line of the shipping firmware is exercised except an enumerated, justified watchdog-reset path |
| **Expected image bytes** | The complete three-image matrix must exactly match the committed, reviewed SHA-256 baseline from the pinned XC8/DFP build; byte drift fails until an intentional rebaseline |
| **Real-HEX lock-step** | The actual emitted image, running in a simulated PIC10F320, must track the verified core for the configured sequence; any divergence fails |
| **Target fault injection** | The same defensive-layer argument on the real image in libgpsim: corrupting every guarded SFR/SRAM location and the required `TRISA` directions forces exactly one real watchdog reset |
| **Target I/O** | Exact `TRISA`, modeled `PORTA` following every `LATA` transition, each variant's complete startup/engage/bypass sequence, and mute/relay pulse widths measured from simulator cycles |
| **CONFIG word** | The emitted CONFIG word matches design intent — a wrong bit is invisible to every other test and would only bite on silicon |
| **Hardware return stack** | The 8-level return stack is bounded by two independent witnesses — the emitted assembly and the shipped HEX — because overflow is silent on this core |
| **Static analysis** | cppcheck + MISRA-C:2012 swept across all three output branches |
| **Soak** | 24-hour-equivalent libgpsim soak per output stage, as part of release qualification |
| **Mutation** | Deliberate firmware faults injected and required to be *killed* — proof the lanes above fail on broken code, not merely pass on correct code |

This table groups the evidence by what it contributes to the argument above. It
is deliberately not the run list: the **authoritative current inventory** — Make
target, substrate, per-lane mechanics and check counts — is *PIC10F320 target
validation layers* in `test/README.md`, and measured results live in
`docs/pic10f320_validation.md` §3. Keeping per-lane targets and counts in one
place is why this table carries neither; individual targets are still named in
the prose below where the argument turns on which lane covers what.

To run the set: `make pic10f320-test` covers the pre-hardware lanes and
`make pic10f320-test-target-variants` the fail-closed real-HEX aggregate across all
three variants. Both are release gates and run in the PIC CI job on pushes to
`main`, pull requests, scheduled runs and manual dispatches.

**What this does not do.** It does not make the architecture identical. A
behavioural equivalence argument, however thorough, is a different kind of
statement from "the verified code is the shipped code". The honest summary is:
*the PIC10F320's qualification design targets the same standard by a different
and more elaborate route.* That route was first exercised by historical runs and
a full-tool dry rehearsal, then completed by production qualification for
`v0.9.6`. What was run, at which commits, and what it returned is recorded in
`docs/pic10f320_validation.md`; the retained release record is
`release/v0.9.6/MANIFEST.md`.

## 4. One recorded omission: the output-latch match

The PIC10F322 shell checks two things about its pins that the PIC10F320 checks
only one of:

| Defensive check | PIC10F322 | PIC10F320 |
| --- | --- | --- |
| Required output pins are still outputs | yes | yes |
| **Exact** `TRISA` across all four implemented bits | yes | **yes** (ported 2026-07-26) |
| Full output-**latch** match against the expected mask | yes | **no — omitted, see below** |
| `ANSELA` integrity of the output pins | yes | yes |

Exact `TRISA` was ported because it turned out to cost **one word** per variant.
It also *subsumes* the older per-pin check, which is why it was nearly free — and
it closed a real blind spot, `cd4053_simple`'s spare RA2 pin, which the previous
per-variant mask did not cover.

The output-latch match **does not fit and is deliberately omitted**. Even in the
leanest formulation that preserves the check's meaning it overruns 256 words on
two of the three variants; only `cd4053_simple` would fit. Both options were priced
on the real toolchain before the decision was taken, and the per-variant word
counts are tabulated in `docs/pic10f320_validation.md` §4.

Taking the general latch-match guard on `cd4053_simple` alone was considered and
rejected. A partial version of that general defense would make the same class of
fault depend on the selected output stage. The relay-only coil guard described
below is different: it does not claim general latch integrity, and it exists
because a high relay-coil bit has a hardware-energy consequence, and a
relay-position consequence, that an LED or analog-control mismatch does not.

**What the omission means in practice.** The firmware still range-checks
`ctx_.effect_state` in the main-loop sanity gate before acting on it, and the
output lanes do observe the port register rather than the latch alone:
`pic10f320-test-actuation` asserts the full settled `LATA` at every tick on the
host, and `pic10f320-test-io` asserts each variant's exact `LATA` transition
sequence, the modeled `PORTA` levels that follow it, and the pulse widths
between edges on the emitted image. (`pic10f320-test-lockstep` compares `ctx_`,
not the output latch.) Every one of those catches firmware that *writes* the
wrong latch. All of them are host-compiled or simulated observations, though;
none is a bench measurement.

What is still missing is a different thing: the firmware's own in-line self-check that
its output latch still matches what its state says it should be — a defence
against a single-event upset in `LATA` *after* the firmware wrote it. On the
PIC10F322 that window is closed in firmware. `hw_output_state_intact()`
in `src/bypass_mcu_pic10f322.c` compares the exact latch against the expected mask
inside the per-tick sanity gate, so an upset forces a watchdog reset.

On the PIC10F320, the general gap remains for the LED and analog-switch control
bits: the trailing `CLRWDT()` does not turn their mismatch into a reset, and
their stable state is rewritten only by a debounced actuation. A wrong LED or
analog signal path can therefore persist until the next accepted press.

Before the `v0.9.8` rewrite, the same omission had a more severe relay-specific
consequence: a post-actuation upset that raised RA1 or RA2 could leave a coil
energized without bound while the otherwise healthy loop continued to pet the
watchdog. That unintended drive was not limited by the normal 12 ms pulse.

The relay variant has a narrower safety rule. `v0.9.8` gave it a loop-top
`set_relay_coils_low()` that corrected such an upset in place; `v0.9.10` replaces
that with the project-wide fail-safe policy
(`docs/relay_coil_fault_correction.md`), because a stray sub-4 ms pulse is only
*below* the TQ2-L2-5V guaranteed-actuation minimum, not proven harmless, so the
firmware cannot know whether the latching relay moved.

What the relay variant now buys, within its 256 words, is exactly the two coil
latch bits: `hw_output_pins_intact()` OR-folds `LATA & (RA1|RA2)` into its
exact-`TRISA` check under `#if defined(OUTPUT_TQ2_RELAY)`, at a cost of three
words and nothing at all on the CD4053 variants. An RA1 or RA2 upset therefore
escalates through `hw_force_wdt_reset()`, which drives both coils low before it
spins — in one constant-mask `LATA` write, so a fault that raised *both* bits
cannot leave the second coil driven while the first is cleared — and the recovery
re-runs `init()`, whose complete 12 ms RESET-coil actuation is what restores
agreement between logical state, LED and physical relay.

This is not an arbitrary-instruction-phase bound: the fault tests inject at the
trailing `CLRWDT` seam, from both a settled BYPASS and a settled ENGAGED start.
Host fault injection covers RESET, SET and both bits and requires the coils to be
idle where the reset spin was abandoned; the real-image fault lane writes `LATA`,
measures the recovery pulse on modeled `PORTA`, and requires the SET coil to stay
dark throughout it. Existing exact host and target-I/O traces require the
defensive low-to-low writes to add no normal-path edge.

So the coil guarantee is now at full parity with the modular shells. What remains
unequal is everything else: the PIC10F320 still has no general expected-mask
check, so a wrong LED or analog signal path can persist until the next accepted
press. That remaining distinction is why §6 still says to prefer another part
when the choice is yours. The external driver, flyback network, supply and PCB
are outside this generic firmware's definition; each adopter must validate the
bounded pulse and simultaneous-driver transient on the actual circuit.

## 5. Keeping it in step: the shared surface

Because the algorithm is written out by hand here, a change to the core does not
propagate to this target the way it does to every other one. The shared surface
is small, finite and auditable — this is all of it:

| Item | Core / driver source | PIC10F320 firmware |
| --- | --- | --- |
| Press threshold | `PRESSED_THRESH` in `src/bypass_config.h` | its own `#define PRESSED_THRESH` |
| Release/lock-out threshold | `RELEASE_THRESH` in `src/bypass_config.h` | its own `#define RELEASE_THRESH` |
| Saturating integrator | `debounce_integrate()` in `src/bypass_pure.c` | written directly in the `main()` loop |
| State machine | `debounce_step()` in `src/bypass_pure.c` | `switch` written directly in `main()` |
| Power-on init | `debounce_init_context()` in `src/bypass_pure.c` | written directly in `init()` |
| Output stages | `src/bypass_output_{cd4053_simple,cd4053_with_mute,tq2_l2_5v_relay}.c` | source-local static functions selected by `#if defined(OUTPUT_*)` |
| Analog-switch polarity | unified drive in the two CD4053 drivers (BYPASS = pin low, ENGAGE = high) | source-local `hw_x4053_ctl_high/low` helpers |

The pin map (RA3 footswitch, RA0 LED, RA1/RA2 control) and the CONFIG word are
PIC-local and shared with nothing.

**The sync is manual, but it is not merely documented — it is enforced.** This is
the one place where merging into this repository changed the assurance argument
rather than just relocating it. `pic10f320-test-equiv` compiles the *real* firmware
and the *real* `src/bypass_pure.c` into one host binary and steps them together,
taking its thresholds from `src/bypass_config.h` through the host shim. So a
change to the core that this firmware does not mirror produces a divergence, and
the divergence fails `make test`. The deliberate threshold-mismatch sensitivity
check and its result are recorded in `docs/pic10f320_validation.md` §3.

The predecessor project could not make that claim: it held a *vendored copy* of
the core pinned to an old commit, so the parent could advance freely and nothing
would notice. Treat the table above as the checklist for what to edit, not as
the mechanism that catches you forgetting.

Two gaps the equivalence lane does not cover, so the table still earns its keep:
the **output-stage** rows (covered instead by `pic10f320-test-actuation`, which
asserts each variant's settled and mid-actuation pin patterns) and anything that
changes only the *defensive* layer, which is compared by no automatic gate
against the PIC10F322 shell — §4 above is the current, deliberate divergence.

## 6. So: should you use it?

**Prefer another target when you can choose the part.** The AVR Classic parts,
ATtiny202 and PIC10F322 all compile the verified core directly. PIC10F322 is
pin-compatible with PIC10F320 in this design, has double the flash, and carries
the full defensive layer.

**Use the PIC10F320 when it is a hard requirement** — cost, existing inventory,
or an established board. It is a release-supported constrained target held to
the same robustness goal by the different route described above. Its prebuilt
images have shipped in unified releases since `v0.9.6`.

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
| MISRA-C:2012 status, suppression rationale and analyzer accommodations | `MISRA_COMPLIANCE.md` |
| How this target was merged in, and every decision made | `docs/pic10f320_merge_plan.md` |
