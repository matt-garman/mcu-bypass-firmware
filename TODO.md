# Remaining work toward textbook reference quality

**Status (2026-08-08):** No nominal-path firmware correctness defect is
currently known. Release `v0.9.8` closes the PIC10F320 relay idle-latch gap;
bounded relay fault-abort hardening below remains open. Its authoritative
full-toolchain, target, stack, mutation, soak and final-image evidence is retained
under `release/v0.9.8/`. The PIC10F320 relay image is the one intentional binary
change from `v0.9.7`; rename-identity evidence pins the other 17 images as
byte-identical.

This file contains open actions only. Completed work is removed rather than
kept as implementation journals; Git history and `CHANGELOG.md` are the record.
Ideas judged not worth pursuing remain under **Considered and declined** so they
are not repeatedly re-proposed. Every identified item before that section is
open and actionable as of the date above.

---

## Tier 2 - closes verification and traceability gaps

### T2-avr-citations - Complete the AVR datasheet citations

Add exact vendor-document revisions and load-bearing section, table, register,
or parameter references to `DESIGN_DOCUMENTATION.adoc` for:

- ATtiny13A/45/85 BOD fuse levels;
- ATtiny202 `BODCFG` `LVL=BODLEVEL7`;
- the post-reset watchdog window;
- `WDTON` always-on fuse semantics;
- internal-RC tolerance; and
- the Timer0 CTC divisor derivation.

`test/avr/test_fuses.c` already identifies the relevant datasheets and fuse
sections; the gap is precise design-document traceability, not a complete
absence of AVR references. Cross-check fuse encodings against the values the
Makefile injects and burns, and do not guess section numbers. This was deferred
from `v0.9.8`; complete it as post-release reference-grade traceability work.

Dependencies: exact AVR vendor datasheets. Effort: about 1 hour with the source
documents open. Risk if deferred: incomplete reference-grade traceability, not
a known firmware defect.

---

## Tier 2.5 - additional software verification

### T25-yasimavr-repin - Re-pin yasimavr and retire the vendored patches

Both vendored patches are fixed upstream, as is the `SimLoop.run(n)` cycle
rewind, but no release carries any of them. yasimavr 0.1.6 of 2026-06-10 is
still both the newest GitHub release and the newest PyPI version, and the
`VERSION` file on upstream `main` still reads `0.1.6`:

- `0001-tiny0-wdt-builder`, issue 145, fixed upstream in `f40b72c` on 2026-07-28;
- `0002-wdt-window-off-delay`, issue 146, fixed upstream in `aeaac8a` on
  2026-07-29;
- the `SimLoop.run(n)` cycle rewind, issue 147, fixed upstream in `7d09002` on
  2026-08-04.

When a release containing them exists, update `YASIMAVR_VER` and
`YASIMAVR_SDIST_SHA256` in `scripts/fetch_yasimavr.sh`, delete both patch files,
retire the known-limitation text, and reduce the derived-work discussion in
`third_party/yasimavr/README.md` to a plain upstream-identity notice, because
the project would then no longer distribute a modified work. Confirm that
`test/test_supply_chain.sh` and the CI simulator cache key, which both key on
the patch set, still fail closed once `patches/` is empty.

Patch removal is already evidenced. Upstream `main` at `7d09002`, built
unpatched with the fetch script's exact hash-locked, no-index pip invocation,
runs the functional, fault-injection, soak and lockstep ATtiny202 drivers green
on every variant, so the bump is expected to be a pin change rather than a
harness change.

Do not pin a bare upstream commit as an interim step. That trades the PyPI
source-archive hash for a generated GitHub archive whose bytes are not
guaranteed stable, and adopts unreleased upstream changes that no release has
qualified. If it ever becomes necessary, pin the Git commit and verify it with
`git rev-parse`, which is content-addressed, rather than hashing a generated
archive.

The in-simulator pulse-width caveat is no longer a reason to re-pin. It is a
property of the single-cycle sampling in `test/avr/test_sim_attiny202.py` rather
than of the pinned release, and it disappears when that tracer moves to the
signal-hook pattern the upstream author recommends. The disassembly-based delay
oracle remains authoritative either way.

Dependencies: an upstream release containing the three fixes. Effort: about
1 hour. Risk: Low; this retires vendored third-party modifications and a
simulator-fidelity caveat rather than closing a firmware gap.

### T25-misra-header-gate - Make header-located MISRA findings fail their lane

With cppcheck 2.13.0, `--error-exitcode` is set only by findings located in the
file passed on the command line; a finding located in an included header is
printed and then ignored. Measured during the 2026-08-10 suppression review:
dropping `misra-c2012-11.4:src/bypass_mcu_avr_classic.c` fails
`make analyze-misra` with 30 findings, while dropping
`misra-c2012-2.3:src/bypass_types.h` or
`misra-c2012-2.5:src/bypass_pins_avr_xt.h` leaves it green.

Consequence: every D-2 and D-3 entry currently suppresses output rather than a
failure, and a new Rule 2.5 or 2.3 artifact appearing in a NEW authored header
would not fail any lane. The suppression file's stated scope contract -- "a
matching finding in a new file therefore fails the gate" -- holds only for `.c`
files today.

Options, cheapest first: post-process the captured cppcheck output and fail on
any `misra-c2012-*` line whose path is inside `src/`, which needs no cppcheck
change and reuses the `$out` capture every MISRA recipe already makes; or pass
each authored header through a lane of its own; or re-pin cppcheck if a later
version gates header findings natively. The first keeps the suppression list as
the single place a finding is waived, which is the property worth preserving.

Whichever is chosen, the acceptance test is a negative probe: introduce an
unused macro in an authored header, confirm the lane fails, then confirm a
matching suppression entry makes it pass again.

Dependencies: none. Effort: Low-Medium. Risk if deferred: Low -- the affected
findings are advisory analyzer artifacts that are false at project scope, and
the authored `.c` files (where the real deviations live) are gated correctly.

### T25-pic322-hex-stack - Extend the final-HEX stack oracle to PIC10F322

The PIC10F320 oracle decodes every reachable word in the shipped HEX and is
independent of XC8 assembly annotations. Its device geometry is already
parameterized, but the PIC10F322 startup emits a `clear_ram0` loop using
`CLRF INDF`; the oracle correctly rejects it because an unconstrained FSR could
write `PCL` or `INTCON`.

Add a sound interprocedural abstract domain for both FSR and W so the startup
clear range can be proved not to reach control-flow or interrupt SFRs. An
approximate analysis that can under-report depth is unacceptable; retain the
fail-closed rejection until the proof is sound. The assembly stack gate remains
the policy-budget witness, while this oracle remains an architectural-limit
cross-check.

Dependencies: PIC baseline instruction semantics and XC8 startup behavior.
Effort: High. Risk if deferred: Low-Medium because the existing assembly gate
already bounds PIC10F322 stack use; this would add a second independent witness.

### T25-relay-fault-abort - De-energize relay coils on detected faults

Classic AVR, AVR-XT, and PIC10F322 validate stable output-latch state, but a
detected relay-coil upset can remain physically driven while the fault handler
waits for watchdog reset. Add a relay-aware abort step that clears both coil
drivers before entering the reset wait, then prove the physical outputs become
inactive immediately without creating a normal-path edge or weakening the
watchdog backstop. Keep this separate from PIC10F320 idle re-drive: that target's
current gap is non-detection, while this item shortens an already bounded fault.
Firmware edits must be made by the owner.

Dependencies: per-shell fault-handler ordering and target fault-injection
visibility. Effort: Medium including host/target faults and deletion/one-coil
mutations. Risk: Medium-High under the SEU/EMI model because watchdog reset
bounds the current interval but does not remove drive immediately.

### T25-output-formal - Formally verify output-driver sequencing

Model the relay, mute, and CD4053 drivers as small state machines and prove that
relay coils are never simultaneously energized, coils are parked low after a
pulse, and analog-switch controls never enter an invalid combination. Existing
scenario and target-I/O tests remain valuable but do not exhaustively prove
these sequence properties. Stub blocking delays as timing events or no-ops when
proving pin-order logic; keep absolute timing in its existing image/runtime
oracles.

Dependencies: a driver harness that preserves each target's pin semantics.
Effort: about 3-4 hours. Risk: Medium; closes a formal-coverage gap in safety-
relevant output sequencing.

### T25-delay-formal - Complete the blocking-delay safety argument

Current static assertions and image/runtime pulse-width checks already enforce
the configured release-threshold and generated-delay bounds. Add only the
missing compositional proof: each shell's scheduling behavior during a block,
the shortest watchdog period, the retained/coalesced timer-sample assumptions,
and the relay datasheet pulse limit must imply safe re-arm and actuation timing.
Do not duplicate existing assertions merely to label them formal.

Dependencies: explicit AVR ISR and PIC polling models plus vendor timing limits.
Effort: about 1-2 hours. Risk: Medium; the implementation has gates, but the
cross-layer argument is not discharged by one proof.

### T25-golden-cross - Cross-validate the independent model and direct core

Drive the hand-written model in `test/host/test_logic_host.c` and the
`model_step.h` adapter to `bypass_pure.c` with the same deterministic random
streams, then compare state and outputs after every step. This keeps the
independent-oracle and direct-shipping-core roles distinct while detecting drift
between them without relying on a simulator shell.

Dependencies: a small common trace adapter. Effort: about 1-2 hours. Risk:
Medium; current lanes establish related equivalence indirectly, not through a
single explicit oracle-to-oracle comparison.

### T25-klee-path - Add bounded full-path KLEE verification

Extend the single-step inductive harness with explicit bounded trajectories from
valid initial states. Prove state validity and carefully specified press/release
properties over a chosen horizon; do not claim a toggle bound without also
constraining the admissible input sequence. Keep loop bounds in the harness and
use KLEE's normal search/time controls rather than CBMC-specific unwind options.

Dependencies: a tractable bound and path-conservation checks. Effort: about 2-4
hours. Risk: High assurance value, but no known behavior gap; this adds an
independent whole-trajectory proof beside BFS and CBMC.

### T25-klee-ci - Execute KLEE in CI

CI currently runs `test-klee-build`, which proves only that the two-module KLEE
recipe compiles and links. Add a job that executes
`make test-symbolic-klee STRICT_TOOLS=1` with the already documented KLEE 3.2
and LLVM 16.0.6 pairing. First make the target or CI wrapper fail closed on
missing tools, timeout, and partial/incomplete paths; `STRICT_TOOLS=1` does not
currently strengthen the target's missing-KLEE success path by itself.

Dependencies: a reproducible CI environment for the pinned KLEE/LLVM pair.
Effort: about 2 hours. Risk: Medium; the proof runs locally but is not watched by
hosted CI.

### T25-cross-compiler - Add a narrow alternate-AVR-compiler lane

Build the Classic AVR firmware with a supported newer avr-gcc, run all variants
through the instruction-accurate simulation suite, and compare behavior with the
pinned avr-gcc 7.3 build. Preserve device, frequency, ABI, and linker flags so
the lane varies the compiler rather than the firmware contract.

Dependencies: a second AVR compiler and simulator-compatible images. Effort:
about 2 hours. Risk: Medium; catches compiler-sensitive UB, volatile ordering,
or ISR code-generation changes.

### T25-opt-sweep - Sweep compiler optimization levels

Build and simulate every Classic AVR variant at selected optimization levels,
asserting the same behavioral results and reviewing timing/size changes. Vary
`CFLAGS_COMMON` or add a dedicated optimization variable; do not replace the
complete `CFLAGS`, which would drop required MCU and frequency flags.

Dependencies: enough flash headroom at each selected level. Effort: about 1
hour. Risk: Medium; a quick check for optimization-sensitive behavior.

### T25-stack-cross - Add an AVR disassembly stack-depth cross-check

Use `avr-objdump` to recover the actual CALL/RCALL graph, combine it with frame
sizes, and compare the computed maximum with both `-fstack-usage` analysis and
the runtime canary high-water measurement. Reject unresolved or indirect edges
rather than silently lowering the bound.

Dependencies: a sound treatment of interrupts, recursion, indirect control
flow, and compiler-generated helpers. Effort: about 2-3 hours. Risk: Medium;
adds a third independent witness for the Classic AVR stack bound.

### T25-avr-xt-stack - Bound AVR-XT shell stack frames

Add an ATtiny202-specific `-fstack-usage` lane for
`src/bypass_mcu_avr_xt.c`. The existing `test-stack-bound` gate compiles the
Classic AVR shell plus the shared core and output drivers under Classic
`CFLAGS`; sharing those other translation units does not measure frames owned
by the AVR-XT shell.

Compile with the shipping `XT_FW_CFLAGS` contract: `-DF_CPU=$(XT_F_CPU)`,
`-DBYPASS_MCU_AVR_XT`, `-mmcu=$(XT_MCU)`, `-B $(XT_SPEC_DIR)`,
`-I $(XT_INC)`, and `$(CFLAGS_COMMON)`, plus each production variant selector.
Require the `XT_DFP` path inputs represented by `XT_SPEC_FILE` and
`XT_IO_HEADER`; those Makefile sentinels establish presence, while the canonical
SHA-verified provenance comes from `scripts/fetch_attiny_dfp.sh`. Give the lane
its own target and add it to the DFP-aware `attiny202-test` aggregate, not the
default `make test` path. Follow the normal optional-tool policy locally while
failing closed when release validation invokes that aggregate with
`STRICT_TOOLS=1`.

Require exactly the expected fresh object and `.su` reports, reject missing,
empty, malformed, dynamic, or unexpected report/artifact files, and fail any
frame above a reviewed AVR-XT ceiling. Pin function-record identities only if
that stronger contract is deliberately chosen and regression-tested. Reuse or
factor the existing parser/regression behavior rather than creating a weaker
second format. State explicitly that `-fstack-usage` bounds individual frames,
not complete call depth. Once measured, update the stale gap notes in
`DESIGN_DOCUMENTATION.adoc` and `test/README.md` with the retained result.

Dependencies: pinned avr-gcc plus the fetched, SHA-verified ATtiny_DFP device
specs and headers. Effort: about 2-3 hours including negative regressions. Risk:
Low and completeness-focused: ATtiny202 has 128 bytes of SRAM with only 4 bytes
of static data, while the ATtiny13A has half the SRAM and a measured 31-byte
whole-program peak that still leaves about 29 bytes free.

### T25-pic320-thresholds - Optionally centralize PIC10F320 thresholds

After `v0.9.8`, consider including `bypass_config.h` and
`bypass_compile_checks.h` from the self-contained PIC10F320 translation unit,
then remove its duplicate thresholds, counter maximum, and five invariant
assertions. This leaves the inlined algorithm and single-TU architecture intact.

A pinned-toolchain scratch build measured all three images byte-identical and
the equivalence lane unchanged, but acceptance still requires the full matrix,
expected-image check, and removal of the now-unneeded
`SHELLS_WITH_OWN_COPY` exception. The firmware edit must be made by the owner.

Dependencies: full PIC10F320 toolchain and target validation. Effort: about 20
minutes plus reruns. Risk: Low; optional simplification, not a correctness fix.

### T25-clock-sweep - Add a fine-grained oscillator-drift sweep

Sweep the arithmetic drift factor used to interpret fixed tick counts between
the documented tolerance endpoints (for example, in 1% increments) and assert
the wall-clock press/release latency budgets. Do not describe this as changing
the simulated oscillator unless the harness is extended to do so. Endpoint
tests already cover the extreme factors, so this is an independent monotonicity
and rounding cross-check rather than evidence of a known intermediate-frequency
defect.

Dependencies: parameterized drift-factor arithmetic, or explicit simulator
clock control if true oscillator variation is later desired. Effort: about 1
hour. Risk: Low.

### T25-wdt-rate - Measure watchdog pet frequency

Count watchdog-pet executions over fixed steady-state and actuation windows.
Assert the AVR ISR/main handshake produces the expected roughly 1 kHz idle rate,
and define a separate PIC expectation that accounts for coalesced samples during
blocking outputs. Existing tests prove the watchdog does not fire; they do not
pin the healthy pet cadence.

Dependencies: simulator hooks that observe the pet site without perturbing it.
Effort: about 1-2 hours. Risk: Medium; detects handshake degradation that still
pets often enough to avoid reset.

### T25-irq-window - Measure the steady-state interrupt-enabled invariant

Monitor the AVR SREG I-bit through idle, press, toggle, release, and repeated-tap
workloads. Outside initialization and the forced-reset path it must stay set.
This catches an unmatched or newly introduced `cli()` that code inspection
currently guards only informally.

Dependencies: instruction-accurate SREG observation. Effort: about 1 hour.
Risk: Medium; an interrupt-disabled window can lose ticks or trigger the
watchdog.

### T25-multipress - Cover residual multi-press boundaries

Add the remaining exact-boundary cases: release bounce when the lockout counter
is one followed by a one-tick re-press, with the exact delayed re-arm asserted;
and a 10-20-tap train at the minimum clean interval
`PRESSED_THRESH + RELEASE_THRESH`, with no drift or missed toggles. Existing
tests already cover sub-threshold oscillation and the basic minimum double-tap,
so do not restate those as gaps. Run both the independent model and an
instruction-accurate firmware confirmation.

Dependencies: deterministic tick-phase control. Effort: about 3-4 hours. Risk:
Medium; exact rate-limit and counter-drain behavior.

### T25-poweron-sim - Repair power-on-pressed simulator fidelity

The simavr harness drives the switch low before initial execution, but simavr
clears PINB during watchdog reset instead of preserving the externally driven
IRQ level. Either patch that reset behavior or re-establish the external drive
immediately after each reset, then cover power-on-held and watchdog-reset-held
trajectories. The golden model and model checker already cover the logic; this
is an image-simulator fidelity gap.

Dependencies: a reset hook or simulator fix that does not hide real reset
behavior. Effort: about 1-2 hours. Risk: Low.

### T25-power-ramp - Analyze slow power-supply ramp-up

Verify initialization remains fail-safe from plausible reset-register states,
and compare the documented 64 ms startup delay with worst-case LP2950/AP7375
ramp, oscillator-start, BOD, and footswitch pull-up behavior. Simulation cannot
model the analog ramp directly, so pair fault-style pre-init register tests with
a datasheet-backed timing analysis.

Dependencies: regulator and MCU electrical data. Effort: about 2-3 hours. Risk:
Medium; real-board startup assumptions are not represented by digital
simulation alone.

---

## Tier 3 - platinum-grade hardening and silicon validation

### T3-hw-procedure - Document a hardware-validation procedure

Define a repeatable bench procedure for the primary ATtiny13A: observe output
pins, intentionally stop timer progress, and confirm watchdog recovery to BYPASS
within the allowed window. Include power-on glitches and BOD behavior. This is
the no-rig fallback for the HIL item because simavr cannot model ATtiny13A
watchdog system reset directly.

Dependencies: representative hardware and oscilloscope/logic analyzer. Effort:
about 2-3 hours. Risk: High verification value; closes a primary-part silicon
evidence gap.

### T3-ctx-complement - Add complemented debounce-context storage

Range checks cannot detect an in-range bit flip in `program_state`,
`effect_state`, or `debounce_counter`. Evaluate a complemented shell-owned
shadow that is updated at every write and checked each tick, forcing watchdog
recovery on mismatch while leaving `bypass_pure.c` unchanged.

On AVR, avoid false mismatches when the ISR updates the counter: either shadow
only main-owned state bytes or use pair update plus retry. Do not disable
interrupts around the check. PIC10F322 can use a full shadow if it fits;
PIC10F320 likely cannot and any omission must be explicit. Add in-range fault
injections and a mutation that removes one shadow update. Firmware edits must be
made by the owner.

Dependencies: per-target flash/RAM budgets and race-safe ownership design.
Effort: about 3-6 hours including tests. Risk: Medium; closes undetected
single-bit corruption under the project's SEU/EMI model.

### T3-toolchain - Broaden compiler and toolchain portability

Document a modern reproducible FSF AVR toolchain (binutils 2.41+, GCC 13+ AVR,
and avr-libc 2.2+ with native ATtiny202 support), then generalize the narrow
cross-compiler lane into a behavioral matrix across viable avr-gcc versions and
clang AVR support. This provides both an adoption path and an independent check
for compiler-sensitive defects.

Dependencies: reproducible compiler builds and simulator compatibility. Effort:
Medium. Risk/impact: Medium-High for long-term maintainability and reliability.

### T3-hil - Build a behavioral and register-introspection HIL rig

Re-host representative simulator stimuli on real parts with a deterministic
driver/capture MCU, then run a separate stop-mode introspection pass that compares
tick-boundary SRAM/register state with the model. Keep timing and introspection
as separate runs because debugWIRE, UPDI, and PIC ICD halt the target and perturb
timing. Replay bit-identical stimuli in both planes so the behavioral and
internal-state evidence describe the same deterministic trajectory; explicitly
control reset timing and treat WDT/BOD asynchronous events as a replay boundary.

A practical path is an RP2040 behavioral plane plus SNAP/Bloom/GDB for AVR;
PIC10F32x introspection requires the appropriate debug header and MPLAB tooling.
Add analog switch-aging stimuli only after the digital behavior plane is stable.

Dependencies: real target boards, probes, family-specific debug access, and
Python orchestration. Effort: about 5-8 days across families. Risk/impact: High;
this is the strongest route to model agreement and timing evidence on silicon.

### T3-provenance - Embed an optional source-provenance URL

Add an opt-in source URL string to programmed flash, not an ELF-only metadata
section, and prove it survives dead stripping and appears in each enabled HEX.
Use `PROGMEM` plus an explicit retained reference on the avr-gcc 7.3 path, and
the appropriate XC8 program-memory form on PIC. Inspect the generated image to
measure any address-materialization or other retention cost rather than assuming
the reference is free.

Gate the feature per target: readable ASCII costs roughly one PIC program word
per character, so PIC10F320 cannot carry the full repository URL within its
current 12-36-word margins. Do not substitute a fragile URL shortener. Firmware
edits must be made by the owner.

Dependencies: per-image flash budgets and final-HEX string verification.
Effort: about 1-2 hours. Risk: Low; provenance polish only.

### T3-pic320-program - Add `make pic10f320-program` convenience target <!-- name-contract: exempt (documents an absent goal) -->

Mirror the existing PIC10F322 programmer interface with separately namespaced
`PIC10F320_PROG*` variables, update help and release flashing instructions, and
validate the exact command against a real programmer and part before removing
the current manual `pk2cmd` guidance. Do not add an untested hardware-programming
surface merely for symmetry.

Dependencies: programmer and PIC10F320 hardware. Effort: about 1 hour plus bench
time. Risk: Low; the documented direct command already provides the function.

---

## Tier 4 - outside firmware scope but actionable

### T4-manufacturing-scope - Name manufacturing deliverables as out of scope

Add a concise design-document statement that a production adopter still needs a
professional schematic, BOM with approved substitutions, hardware production
test procedure, and FMEA. Naming these as implementer responsibilities prevents
the firmware assurance package from being mistaken for a complete manufacturing
package.

Dependencies: none. Effort: Small. Risk: completeness and expectation-setting,
not firmware behavior.

### T4-spice - Model the footswitch input network in SPICE

Before a board design is qualified, simulate the TVS, ferrite, series resistor,
capacitor, pull-up, wiring, and MCU input under representative ESD and coupled-RF
stimuli. Verify pin absolute maxima and Schmitt thresholds, and compare the
filtered disturbance with the firmware integration window. Define the test
level, source/coupling model, RF frequency, wiring geometry, and pass thresholds
before calling the result reproducible; the existing candidate cases are a 5 kV
IEC 61000-4-2 contact discharge and a 900 MHz burst coupled to a 10 cm switch
lead. This validates a hardware assumption; it must not gate firmware-only
releases.

Dependencies: selected board components, parasitics, and credible source models.
Effort: about 2 hours for an initial model. Risk/impact: High for board design,
outside firmware scope.

---

## Considered and declined

Recorded so these do not get re-proposed. Each was judged to cost more than it
returns for this project; reconsider only if its stated trigger appears.

### Run PIC10F320 firmware on PIC10F322 hardware

The native PIC10F320 image is expected to execute on PIC10F322, but it omits the
PIC10F322 firmware's stronger stable-output-latch defense. Maintaining a third
cross-device profile would primarily validate an intentionally inferior choice.
Reconsider only for a concrete universal-image, component-substitution, or
manufacturing-SKU requirement.

### Model ISR/main interleavings in TLA+ or SPIN

The nondeterministic scheduling proof, lock-step simulation, and fault injection
already exceed the value of a separate byte-level formal model for the current
single-byte shared state. Reconsider if a future shell shares a genuinely
multi-byte object across an ISR boundary.

### Add a property-based testing framework

The algorithm's state space is already exhaustively covered by BFS and CBMC.
Generator/shrinker dependencies would not reach states those proofs miss.

### Stress random ISR timing jitter

The design samples once per compare match, and clean-press phase jitter already
varies input edges across the tick. Artificial service delay would mostly
reconfirm that design rather than expose a distinct state-space gap.

### Measure simavr interrupt latency

ISR entry and duration are negligible against a 1 ms tick, and a material error
would surface in lock-step behavior. The retained interrupt-enabled invariant is
more likely to detect a maintenance regression.

### Diff VCD waveforms across output variants

Per-variant tests already assert the relevant LED behavior directly. VCDs remain
available for diagnosis but add documentation output rather than a new gate.

---

## Priority summary

The stable ID in each row matches exactly one open section above.

| ID | Item | Tier | Effort | Impact |
|---|---|---:|---:|---|
| T2-avr-citations | AVR datasheet citations | 2 | 1 h | High - traceability |
| T25-yasimavr-repin | Re-pin yasimavr and retire vendored patches | 2.5 | 1 h | Low |
| T25-pic322-hex-stack | Extend final-HEX stack oracle to PIC10F322 | 2.5 | High | Low-Medium |
| T25-relay-fault-abort | De-energize relay coils on detected faults | 2.5 | Medium | Medium-High |
| T25-output-formal | Formal output-driver sequencing | 2.5 | 3-4 h | Medium |
| T25-delay-formal | Blocking-delay safety argument | 2.5 | 1-2 h | Medium |
| T25-golden-cross | Independent-model/direct-core cross-validation | 2.5 | 1-2 h | Medium |
| T25-klee-path | Bounded full-path KLEE proof | 2.5 | 2-4 h | High assurance value |
| T25-klee-ci | Execute KLEE in CI | 2.5 | 2 h | Medium |
| T25-cross-compiler | Narrow alternate-AVR-compiler lane | 2.5 | 2 h | Medium |
| T25-opt-sweep | Compiler optimization sweep | 2.5 | 1 h | Medium |
| T25-stack-cross | AVR disassembly stack cross-check | 2.5 | 2-3 h | Medium |
| T25-avr-xt-stack | AVR-XT shell stack-frame bound | 2.5 | 2-3 h | Low - completeness |
| T25-pic320-thresholds | Optionally centralize PIC10F320 thresholds | 2.5 | 20 min + reruns | Low |
| T25-clock-sweep | Fine-grained oscillator-drift sweep | 2.5 | 1 h | Low |
| T25-wdt-rate | Watchdog pet-frequency measurement | 2.5 | 1-2 h | Medium |
| T25-irq-window | Interrupt-enabled invariant measurement | 2.5 | 1 h | Medium |
| T25-multipress | Residual multi-press boundaries | 2.5 | 3-4 h | Medium |
| T25-poweron-sim | Power-on-pressed simulator fidelity | 2.5 | 1-2 h | Low |
| T25-power-ramp | Power-supply ramp analysis | 2.5 | 2-3 h | Medium |
| T3-hw-procedure | Hardware-validation procedure | 3 | 2-3 h | High |
| T3-ctx-complement | Complemented debounce-context storage | 3 | 3-6 h | Medium |
| T3-toolchain | Broader compiler/toolchain portability | 3 | Medium | Medium-High |
| T3-hil | Behavioral and register-introspection HIL | 3 | 5-8 d | High |
| T3-provenance | Optional embedded source URL | 3 | 1-2 h | Low |
| T3-pic320-program | `make pic10f320-program` target <!-- name-contract: exempt (documents an absent goal) --> | 3 | 1 h + bench | Low |
| T4-manufacturing-scope | Name manufacturing deliverables as out of scope | 4 | Small | Completeness |
| T4-spice | Footswitch-network SPICE modeling | 4 | 2 h | High for board design |
