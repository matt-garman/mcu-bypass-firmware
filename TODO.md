# Remaining work toward textbook reference quality

<!-- current-release:start -->
**Current release contract:** `v0.9.11`; seven release parts; 21 images; 18 soak combinations; six modular targets; four shell source files.

**Status (2026-08-29):** No nominal-path firmware correctness defect is
currently known. PIC10F320 remains the self-contained exception. This tree is
the `v0.9.11` *source* contract; the authoritative evidence for the release it
qualifies is retained under `release/v0.9.11/`, and that retained record --
not this file -- identifies the qualified source commit and measured results.

**Pre-tag transition:** `release/v0.9.11/` is created by the release cut and published with the signed `v0.9.11` tag, so the source tree that declares this contract does not contain it yet.

Open work is enumerated below.
<!-- current-release:end -->

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

The in-simulator pulse-width caveat is not a reason to re-pin, and is not
outstanding work. It was a property of the single-cycle sampling in
`test/avr/test_sim_attiny202.py` rather than of the pinned release, and it went
away when that tracer moved to the signal-hook pattern the upstream author
recommends: it now free-runs in millisecond budgets, timestamps every pin edge
from the hook, and asserts delivered pulse width alongside ordering, polarity,
exclusion and presence. The disassembly-based delay oracle remains the
authoritative *compiled* width either way, and is simulator-independent. So the
rewind reaches no timing assertion today; re-pinning retires the vendored
patches and the derived-work notice, not a measurement gap.

Dependencies: an upstream release containing the three fixes. Effort: about
1 hour. Risk: Low; this retires vendored third-party modifications and a
simulator-fidelity caveat rather than closing a firmware gap.

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

### T25-output-formal - Formally verify output-driver sequencing

Model the relay, mute, and CD4053 drivers as small state machines and prove that,
on the nominal fault-free path, relay coils are never simultaneously energized,
coils are commanded low after a pulse, and analog-switch controls never enter an
invalid combination. Existing scenario and target-I/O tests remain valuable but
do not exhaustively prove these sequence properties. Stub blocking delays as
timing events or no-ops when proving pin-order logic; keep absolute timing in its
existing image/runtime oracles.

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

**Implementation present on the F2 branch; provisioned measurement pending.**
`attiny202-test-stack-bound` now compiles the shell under all three immutable
production selectors, shares the Classic AVR `.su` parser, enforces 32 bytes per
frame, and has a toolchain-free 23-check regression. Keep this item open until a
pinned avr-gcc/ATtiny_DFP run records the actual maxima and the final resource
documentation is refreshed.

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
Low and completeness-focused: ATtiny202 has 128 bytes of SRAM with 5 bytes of
static data, while the ATtiny13A has half the SRAM and a tightest measured
33-byte stack high-water mark that still leaves 26 bytes free after static data.

### T25-pic320-thresholds - Optionally centralize PIC10F320 thresholds

As optional cleanup, consider including `bypass_config.h` and
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

### T25-name-contract-shim - Check overrides handed to a routing Make shim

Axis C of `test/test_makefile_name_contract.py` harvests a `NAME=value` only
where it follows a make word, and a make word is bare `make` or a `$(MAKE)`
style reference. Five gate invocations now enter the real Make graph through a
routing shim whose command word is a shell variable instead -- `"$fake_make"`
in `test/test_target_matrix.sh` and `test/test_target_lane_markers.sh`,
`"$matrix_lane_make"` in `test/test_pic_build.sh` -- so no make word occurs in
those lines and the overrides they carry are checked by no axis at all. Those
overrides are real: MAKE, PROJECT_MAKE, CC, HOSTCC, FW_BASE, STRICT_TOOLS and
five PIC12F675 names travel that way, and MAKE and PROJECT_MAKE reach axis C
from nowhere else in the tree. A rename would leave those five harnesses
passing inert overrides -- the exact defect class the gate exists to catch,
one level below where it currently looks.

Measured 2026-08-12, when scoping the harvest per command context closed a
false-positive class and revealed this as its cost: until then the five sites
were harvested only by accident, because a `$(command -v make)` path lookup
sitting in their environment prefixes anchored the line.

The obvious repair is the wrong one, and it was measured rather than guessed.
Widening the make word to accept a lowercase `$..._make` command word recovers
MAKE and PROJECT_MAKE and adds four false positives -- MUTATION_MAKE_LOG,
PIC_BASELINE_STALE_HEX, PIC_GPSIM_SELFTEST_LOG and TOOL_LOG, every one an
environment prefix for a child process -- so it buys two names at the price of
four the gate could then never check again. What the harvest actually needs is
command POSITION: the command word of a statement is its first word that is
not an assignment, and an override is an assignment after it. That is the
shell's own rule, it is already implemented for the prefix half in
`env_channel_names()`, and it recognizes any invocation of a Make command
without a name-shape heuristic.

Acceptance test: the five shim sites contribute their overrides again, the four
names above stay unharvested, and axis C's negative case (e) still rejects a
make word sitting inside an assignment's value.

Dependencies: none. Effort: 2-3 hours, most of it re-measuring the harvest diff
across the whole tree. Risk if deferred: Low -- each of those five harnesses
asserts on the argument list its shim was called with, so a severed override
there would most likely surface as a loud harness failure rather than silently.

### T25-cbmc-proof-count - Cross-check the dispatched CBMC proof count against the source

`test/test_strict_tools.sh` asserts that `test-cbmc` under `STRICT_TOOLS=1`
issues a fixed number of `cbmc` invocations, restating that number as a literal.
It has now drifted once: F2 added `prove_ctx_check_single_bit_detected` and
`prove_ctx_check_definition`, the Makefile's three proof lists grew to eleven
entries, and the assertion still said nine, so the gate went red on an addition
that was entirely correct.

The tempting repair is the wrong one. Deriving the expected count from
`CBMC_PROOFS`, `CBMC_PROOFS_LOOP` and `CBMC_PROOFS_DEEP` makes the assertion
self-fulfilling: a proof accidentally dropped from a dispatch list would lower
the expectation by exactly as much as it lowers the count, and the gate would
stay green while the proof stopped running. The literal is doing real pinning
work -- it is the only thing in the tree that would notice a silently
undispatched proof -- and that property must survive any rewrite.

What removes the drift without losing the pin is to derive the expectation from
the other side: `grep -c '^void prove_' test/formal/test_cbmc.c` counts the
proofs that are *defined*, the fake-`cbmc` log counts the proofs that are
*dispatched*, and asserting the two are equal catches both failure directions.
A proof defined but left out of a Makefile list fails as a coverage gap -- a
case the current literal cannot detect at all -- and a new proof added properly
to both sides needs no edit here. Today those numbers agree at eleven.

Acceptance test: adding a proof to `test/formal/test_cbmc.c` and to a dispatch
list keeps the gate green with no edit to the assertion; adding it to the source
only turns the gate red naming the undispatched proof; the existing
STRICT_TOOLS=1 negative cases are unaffected.

Dependencies: none. Effort: 30-45 minutes, most of it confirming the definition
scan cannot be fooled by a commented-out or conditionally compiled proof. Risk
if deferred: Low -- the literal is correct as of this writing and a future
mismatch fails loudly and names the count, exactly as it did this time.

---

## Tier 3 - platinum-grade hardening and silicon validation

### T3-nonblocking-actuation - Qualify any non-blocking actuation redesign

Retain the current blocking design unless a decision-quality spike discharges
this item. Do not trade self-health checks for a PIC10F322 timer ISR. Dated
historical evidence from 2026-08-05, using XC8 3.10 / DFP 1.9.189 against
`main@59d55e9` and `main@831d1d3`, found that the relay ISR exhausted the
planned PIC10F322 return-stack margin while check ablation freed flash rather
than stack; four direction-specific `_pre`/`_post` primitives compiled
materially better than a target-parameter pair; and a minimal PIC10F320
countdown form linked and passed resource/stack gates but was never functionally
or release-qualified. A 2026-08-06 FMEA at `main@cf29e12` established the safety
obligations below. These are historical conclusions, not current resource
values; remeasure every candidate against current source, tools, and gates.

Before any shipping conversion:

- Keep one shell-owned output state machine around direction-specific
  `hw_set_bypass_pre/post()` and `hw_set_engaged_pre/post()` primitives. Publish
  active before energizing an output, settle before publishing idle, make the
  target immutable while active, reject duplicate or wrong-state requests, and
  define exact launch/completion tick ordering. Serialize startup so no press
  can overlap, restart, reverse, or truncate the initial RESET pulse. Compile
  the simple CD4053 variant without deferred state.
- Validate exact phase-dependent outputs rather than suppressing sanity checks:
  RESET-only/LED-low for relay BYPASS, SET-only/LED-high for relay ENGAGE,
  runtime mute `(CTL1, CTL2)=(0,1)` with the target LED state, and a distinct
  all-low startup mute state. Never energize both relay coils or the wrong coil,
  and retain the normal actuation-less-than-release-lockout proof.
- Preserve the current fail-safe relay policy. Any direction, latch,
  pin-control, or state mismatch during an active phase must invoke
  target-specific physical output quiescence before the watchdog spin, then
  reset and resynchronize to BYPASS. Withhold watchdog pets throughout deferred
  actuation, but separately contain stalled/high and premature-zero progress.
  If complete containment does not fit, keep that target/variant blocking.
- Treat the tick source as safety-critical. Cover stopped, one-spurious,
  persistent false-fast, delayed, and coalesced ticks; prove progress before
  startup energizes a relay; and prevent repeated watchdog-length startup
  pulses. Derive per-target physical pulse lower/upper bounds from accepted
  hardware ticks, oscillator/WDT tolerance, service ordering, and active-path
  WCET. Every active path must service within one tick, and the relay maximum
  must be electrically and thermally safe.
- Protect the complete persisted protocol, not only its upper range. Test zero,
  high, every in-range value, every single-bit corruption, wrong target,
  legal-but-wrong context state, and write ordering. Extend the context
  transaction/check discipline or qualify an explicit constrained-target
  exception. Add a watchdog-independent end-of-serviced-tick observation point
  for context, phase, target, countdown, and exact pins, plus an independent
  output-state-machine model and built-image timing/abort/recovery checks.
- Add mutations for `N-1`/`N+1`, missing decrement or `_post`, early idle,
  wrong direction/target, duplicate request, active-sanity suppression,
  zero/high corruption, an illegal active watchdog pet, tick faults, and a
  removed or weakened abort. Kill every applicable mutant without deriving the
  oracle from production tables.
- Qualify the complete then-supported target/variant matrix. Preserve AVR
  ISR/main atomicity, each PIC polling model, PIC12F675 shadow and peripheral
  ownership, and PIC10F320's hand-maintained output surface and latch-check
  exception; convert PIC10F320 last. Retain exact spike sources, re-run all
  resource, stack, behavioral, fault, timing, formal, mutation, and release
  gates, and intentionally review every generated-image and release-identity
  change.
- Do not call simulator evidence hardware qualification. Before enabling a
  non-blocking relay target, retain a controlled record covering source/image
  identity, real tick/WDT cadence, minimum and worst-case coil pulse, physical
  abort, relay/driver/flyback/supply/PCB behavior, and the applicable
  temperature/voltage envelope. An unprovable generic upper bound requires a
  blocking fallback.

Dependencies: owner-authored firmware changes, complete pinned target
toolchains/simulators, an independent output-state-machine model, relay
electrical data, `T3-hw-procedure`, representative hardware, and retained
controlled evidence. Effort: High. Risk: High; an incomplete conversion can
create an unbounded relay-coil energy path or a permanent muted/output state
where the current blocking implementation is bounded.

### T3-hw-procedure - Document a hardware-validation procedure

Define a repeatable bench procedure for the primary ATtiny13A: observe output
pins, intentionally stop timer progress, and confirm watchdog recovery to BYPASS
within the allowed window. Include power-on glitches and BOD behavior. This is
the no-rig fallback for the HIL item because simavr cannot model ATtiny13A
watchdog system reset directly.

This is also the document that `HARDWARE_VALIDATION_LOG.md`'s **Procedure**
field has to reference. Until it exists, no controlled qualification record can
be complete for any part, so this item gates section 2 of that file rather than
only the ATtiny13A.

Dependencies: representative hardware and oscilloscope/logic analyzer. Effort:
about 2-3 hours. Risk: High verification value; closes a primary-part silicon
evidence gap.

### T3-pic12f675-bench - Graduate the PIC12F675 on silicon

The part is built, tested, formally verified, statically analyzed and
**release-supported from `v0.9.9`** here, and — like every other part in this
repository — has **no controlled hardware-qualification record**. That is the
`0.9.x` line: validated in software, with no bench run whose procedure,
configuration bytes and measurements are on file. (Some parts do have
self-reported field-use reports; this one does not. `HARDWARE_VALIDATION_LOG.md`
keeps the two apart and states what a controlled record must retain.) This item
is the PIC12F675's slice of the `1.x.y` hardware-validation pass, which closes
four open risks that are invisible to every lane this repository has. The
numbers are the original ones from the port assessment, kept because the
Makefile, the CI notes and the release documentation cite them; the four
statements below are now the definition rather than a summary of one:

- **1 - bandgap calibration bits (`BG<1:0>`) preserved on program.** They are
  factory-set per device and fix the BOR/POR trip voltages.
  `make pic12f675-program` enforces the build-side half -- the toolchain must
  leave the field erased -- and now requires a `pic12f675-preflight` baseline,
  an immediate matching pre-write read, and a retained matching post-write
  result. The programmer's own erase behavior still needs measuring on silicon.
- **2 - factory oscillator trim (flash word 0x3FF) preserved on program.**
  Losing it yields an untrimmed clock: wrong tick cadence, wrong coil-pulse
  widths, and a device that still appears to work. The guarded workflow now
  compares the complete word before/after and fails on a change; run it with a
  real PICkit, retain the generated JSON, then write the measured result into
  `release/README.md`'s flashing procedure.
- **8 - `ipecmd` actually runs against the part.** The pinned device pack lists
  the PIC12F675 with the same MPLAB hardware-tool set as the PIC10F322, but
  neither programmer binary is installed on any machine this repository is
  tested on, so the command shape is inherited and has never been executed.
- **9 - GP2's readback margin.** The port-follows-shadow guard re-reads `GPIO`
  against the SRAM shadow every tick, and GP2 is the one output whose input
  buffer is a Schmitt Trigger (VIH min 0.8*VDD) rather than TTL. On
  `cd4053_with_mute` with the real load attached, engage the effect and confirm
  GP2 reads above 0.8*VDD; record the margin, since it bounds the minimum
  fail-safe pulldown a builder may substitute. gpsim models pins ideally, so no
  lane here can see this one at all.

There are now two vehicles for the first three. The guarded
`pic12f675-preflight` / `pic12f675-program` bench workflow records a factory
baseline, requires it to match immediately before and after a write, and refuses
an image that would overwrite the calibration word; it drives a pk2cmd reader.
From `v0.9.10` the release-shipped `scripts/flash-pic12f675.py` runs the same
transaction against PICkit 3 and MPLAB X 6.20 `ipecmd` with no checkout, which
makes it the vehicle for item 8 as well as items 1 and 2 -- the properties its
bench run must prove are enumerated under "Outstanding controlled runs" in
`HARDWARE_VALIDATION_LOG.md`. What is missing in both cases is a retained result
from real silicon. The fourth (GP2) needs a meter on a built `cd4053_with_mute`
board. Record the measured OSCCAL/BG preservation result into
`release/README.md`'s flashing procedure once it exists.

Dependencies: a PIC12F675, a PICkit programmer, a meter, and a built board.
Effort: about half a day at the bench plus 1-2 hours to retain and review the
evidence. Risk: High; these four close here or nowhere. They do not block the
`0.9.x` software release (the part already ships), but they are the gate to the
`1.x.y` hardware-validated line — the same gate every other part must pass.

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
current 11-36-word margins. Do not substitute a fragile URL shortener. Firmware
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

### Split the monolithic Makefile

Do not split or template the Makefile merely because it is long.
Hardware-specific PIC divergence is intentional, while tests and scripts still
copy, mutate, grep, or parse only `Makefile`; production releases also reject
multiple loaded makefiles as an injection defense. A naive split could silently
weaken test coverage or violate the fail-closed release boundary.

Reconsider when a new independent MCU build lane is added, cross-lane edits or
merge conflicts become routine, or a reviewed fragment-set and provenance
interface has removed those costs. If pursued, first migrate every source-text,
sandbox, rebuild-dependency, and release consumer without splitting; then move
one lane at a time and prove fail-closed coverage, rebuild invalidation, release
identity and security, normalized Make-database semantics, and all affected
gates.

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
| T25-name-contract-shim | Check overrides handed to a routing Make shim | 2.5 | 2-3 h | Low |
| T25-cbmc-proof-count | Cross-check dispatched CBMC proof count against source | 2.5 | 30-45 min | Low |
| T3-nonblocking-actuation | Qualify non-blocking output actuation | 3 | High | High - hardware safety |
| T3-hw-procedure | Hardware-validation procedure | 3 | 2-3 h | High |
| T3-pic12f675-bench | Graduate the PIC12F675 on silicon | 3 | 0.5 d + 2 h | High - gates the part's 1.x.y hardware validation |
| T3-toolchain | Broader compiler/toolchain portability | 3 | Medium | Medium-High |
| T3-hil | Behavioral and register-introspection HIL | 3 | 5-8 d | High |
| T3-provenance | Optional embedded source URL | 3 | 1-2 h | Low |
| T3-pic320-program | `make pic10f320-program` target <!-- name-contract: exempt (documents an absent goal) --> | 3 | 1 h + bench | Low |
| T4-manufacturing-scope | Name manufacturing deliverables as out of scope | 4 | Small | Completeness |
| T4-spice | Footswitch-network SPICE modeling | 4 | 2 h | High for board design |
