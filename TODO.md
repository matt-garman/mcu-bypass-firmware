# Remaining work toward textbook reference quality

Status note (2026-06-18): the firmware and test/validation suite have been
meta-reviewed (design doc, firmware implementation, golden-model accuracy,
test correctness, and additional verification opportunities). The firmware has
no known correctness defects; `make test` passes clean across all three output
variants and both MCU families (ATtiny13a and tinyx5), with 100% golden-model
line coverage. The meta-review confirmed: (1) the design meets its stated goals,
(2) no bugs, race conditions, or footguns were found in the firmware, (3) the
golden model matches the firmware exactly via three independent verification
paths, (4) all existing tests are correct and meaningful, and (5) identified
seven additional pre-hardware verification opportunities (added as Tier 2.5).
The items below are deferrable polish and credibility work — none are bugs.
Anything that *is* a bug gets fixed immediately, not parked here.
A second meta-review (same date) confirmed the earlier findings, found no new
correctness defects, and identified three more pre-hardware verification
opportunities — the boot-loop, WDT re-arm window, and footswitch-glitch regression
items added below.
A third meta-review (same date, third pass) re-confirmed all prior findings,
found no new correctness defects, and identified three additional pre-hardware
verification not yet in the TODO: signal-integrity SPICE modeling, multi-seed
Monte Carlo fuzzing, and multi-press edge-case regression tests (marked "NEW" below).

Completed since the previous revision (kept here only as a record; safe to
delete): README.md; design doc renamed to `DESIGN_DOCUMENTATION.adoc`; timer
formula `static_assert`; `__attribute__((OS_main))`; MISRA-C:2012 analysis +
`MISRA_COMPLIANCE.md` + `make analyze-misra` gate; KLEE support
(`make test-symbolic-klee`, `test_symbolic.c -DUSE_KLEE`).

---

## Tier 1 — high impact, low effort (do first)

**No CI/CD pipeline.** Still the most conspicuous gap for a project making
Boss-grade verification claims: a green "build passing" badge proves the suite
is reproducible off the developer's machine. Note this is now bigger than the
original "6-line apt + make test" estimate — to be honest it must exercise the
real matrix: all three variants × {ATtiny13a, tinyx5}, plus the analysis gates
(clang-tidy, cppcheck, MISRA). simavr is in Ubuntu 24.04's default repos. KLEE
can be a separate optional job (see Tier 3).

**Design-doc resource-utilization section.** The suite now *measures* the
numbers; they belong in the design doc as a resource table. Measured today:
ATtiny13a cd4053 ≈ 470 B flash (~46% of 1 KB), 8 B peak stack, 56 B SRAM margin
(64 B total); tinyx5 relay ≈ 524 B flash, 10 B peak stack, 246 B margin (256 B
total). For an engineer evaluating this as a reference base, headroom is a key
parameter. Pull flash from `avr-size` and stack from the HWM test output.

**Fix stale references / editorial note.** (a) This file and any prose still
referencing `attiny13_bypass.md` / `attiny13_bypass.c` must point at
`DESIGN_DOCUMENTATION.adoc` / `bypass_core.c` + drivers. (b) `DESIGN_
DOCUMENTATION.adoc` line ~464 still reads like an authoring note ("It shows the
counter climbing to 7…"); reword as a normal lead-in. Both are trivial.

---

## Tier 2 — closes verification / traceability gaps

**Datasheet citations in the design doc.** The sleep-wakeup §7.3 cite lives in
`bypass_core.c`; the *design doc itself* currently cites no datasheet sections.
Each load-bearing decision should trace to a page/section: WDT ~16 ms post-reset
window; WDTON always-on; internal-RC ±10%; Timer0 CTC formula; BOD level.

**Minimum-tap-interval regression test.** ~~Done~~ — `test_minimum_tap_interval()` in
`test/test_logic_host.c`: drives two presses exactly `PRESSED_THRESH + RELEASE_THRESH = 33 ms`
apart and asserts both register; includes a boundary guard (one tick short on release
must keep the second press locked out). Wired into `make test`.

**`-fstack-usage` static bound.** ~~Done~~ — `make test-stack-bound` compiles every
firmware TU with `-fstack-usage`, prints all per-function frames, and fails if any
frame exceeds `STACK_MAX_FRAME` (default 32 B). Observed frames: ISR 19 B,
`debounce_step` 10 B, all others ≤ 2 B. Wired into `make test`.

**Flash-utilization budget assertion.** ~~Done~~ — `make test-flash-budget` runs
`avr-size` on each ATtiny13a variant ELF and fails if Program bytes exceed
`FLASH_T13_BUDGET`% of 1 KB (default 90% = 921 B). Current usage: cd4053 612 B
(59.8%), mute 660 B (64.5%), relay 652 B (63.7%). Wired into `make test`.

---

## Tier 2.5 — additional software verification (pre-hardware)

These items were identified during a full meta-review of the firmware, design
doc, and test suite (2026-06-18). All close residual verification gaps that can
be addressed in software before physical hardware testing begins.

**AVR instruction-level fault injection.** The existing fault-injection suite
corrupts individual SRAM globals (`program_state_`, `effect_state_`,
`timer_isr_called_`) and I/O registers (DDRB, PORTB, TIMSK). A more powerful
approach: corrupt *arbitrary* SRAM bytes (stack, unused RAM, BSS padding) and
verify the firmware's sanity-check + WDT-recovery path still fires. simavr
supports writing to any SRAM address via `avr_core_watch_write()`, so this is
mechanically straightforward. Specific scenarios: (a) corrupt the stack pointer
and verify the firmware doesn't silently survive with a broken call chain; (b)
corrupt a byte in the unused SRAM region and verify no side effect (defense in
depth); (c) corrupt `ctx_` at a struct offset that doesn't correspond to a
named field (padding, though `-fshort-enums` + `static_assert` make this
unlikely). This extends the existing `test_fault_inject_*` family in
`test_sim.c`.

**Extended lock-step co-sim with variant-specific control outputs.** The
`test_lockstep_cosim()` test compares firmware internal state against the golden
model every tick, and verifies the LED tracks `effect_state`. For the CD4053
simple variant it also checks PB2. Extending this to the relay and mute variants
would close a coverage gap: currently the relay pulse timing and mute window are
only verified by dedicated single-scenario tests (`test_control_relay_pulse`,
`test_control_mute_sequence`), not by the exhaustive random-input co-sim. A
lock-step extension would verify that across thousands of random ticks, PB2/PB3
*always* end up in the correct steady state (both low for bypass, both high for
engaged, coils parked low for relay) after any toggle. Requires modeling the
variant's pin behavior in the lock-step oracle (a small state machine for relay
coil pulses / mute sequencing, or simply checking steady-state levels after a
settle window).

**Power-on-pressed in simavr.** The simavr harness sets the footswitch IRQ
*before* the firmware starts (via `sim_reset(1)`), which correctly exercises
`debounce_init_context(PIN_STATE_LOW)`. However, the simavr test for this case
(`test_power_on_pressed`) has a known limitation: after a WDT reset, simavr
clears PINB to 0x00, which is inconsistent with the externally-driven IRQ
level. The golden model and model-check both cover the power-on-pressed logic
exhaustively. Closing the simavr gap would require either (a) a simavr patch to
preserve IRQ-driven input levels across reset, or (b) re-establishing the
footswitch IRQ drive immediately after each simavr reset. Option (b) is
mechanically feasible in the test harness; the WDT-backstop test already
partially works around this.

**Formal verification of out-of-range counter recovery.** The model check and
CBMC proofs assume `debounce_counter` is always in `[0, RELEASE_THRESH]`. CBMC's
`prove_integrate()` already proves the *closure* property for in-range inputs
(`dc <= RELEASE_THRESH` implies `out <= RELEASE_THRESH`). An additional proof
that a *corrupted* counter above `RELEASE_THRESH` is safely brought back into
range by repeated integrator steps would verify defense in depth against an SEU
that flips the counter to an out-of-range value. This is a small extension to
`test_cbmc.c`: a new harness with `dc` unconstrained over the full `uint8_t`
range, proving that after N "released" steps the counter returns to `[0,
RELEASE_THRESH]`. (The integrator already handles this correctly — it simply
decrements any counter > 0 — but the formal proof would make this an explicit
guarantee rather than an implicit one.)

**Formal verification of output drivers.** The output drivers (relay, mute,
CD4053) contain blocking delays and multi-step pin sequences. They are tested by
scenario-based simavr tests but are not formally verified. A state-machine model
of each driver could be proved to: (a) never leave both relay coils energized
simultaneously; (b) always park coils low after a pulse; (c) never enter an
invalid mute/engage/bypass pin combination. The drivers are small enough
(~30-60 lines each) that a CBMC proof or exhaustive state-space check is
feasible. The main obstacle is that the drivers call `_delay_ms()` (a busy-wait
loop), which CBMC cannot symbolically execute; the workaround is to stub
`_delay_ms()` as a no-op and verify the pin sequence logic in isolation.

**Long-duration soak test.** A 24-hour simulated soak test with random input
patterns would stress the firmware's WDT handshake and sanity-check paths at a
timescale the current tests don't reach. Mechanically trivial: a `make
test-soak` target with `SIM_RANDOM_NOISE_DURATION_MS=86400000u` (or
configurable). The existing test infrastructure supports arbitrary duration
overrides. The value is in catching extremely rare state drift or WDT-pet
timing edge cases that the current 5-60s runs cannot exercise. Caveat: at
simavr's real-time ratio, 24 hours of simulated time may take many hours of
wall-clock time; a shorter but still multi-minute soak (e.g., 10 minutes
simulated = 600000 ms) is a practical compromise for CI, with the full soak
available for pre-release validation.

**ISR-timing-jitter stress test.** On real hardware, the timer ISR latency can
vary (e.g., if `cli()` is held across the compare-match point during a toggle
that calls `hw_force_wdt_reset()`). The existing `test_clean_press_phase_jitter`
partially addresses this by scattering footswitch edges across the 1ms tick
window. A more aggressive version would: (a) deliberately delay ISR servicing
by random cycle counts (possible via simavr cycle-level control in
`run_cycles()`); (b) verify that the firmware's debounce behavior is insensitive
to ISR jitter — the counter increments by exactly 1 per tick regardless of when
within the tick the ISR fires. The firmware is designed for this (the ISR
samples the pin once per compare-match), so the test would confirm an existing
design property rather than find a new bug.

**Golden-model vs model_step cross-validation.** The golden model
(`test_logic_host.c`) re-implements the algorithm independently; `model_step.h`
delegates to the real firmware's `bypass_pure.c`. Both produce identical results
for the same input stream (verified implicitly by the lock-step co-sim and the
model proofs), but no test drives the same random input sequence through *both*
oracles and asserts byte-for-byte agreement. A small test (or assertion block
added to an existing test) that compares `model_step.step()` output against
`test_logic_host.c`'s `model_tick_isr()`+`model_main_step()` for a long random
stream would provide a fourth independent verification path, catching any subtle
discrepancy between the hand-written golden oracle and the compiled firmware
logic that the current tests could theoretically miss if both relied on the same
underlying `bypass_pure.c` functions.

**Clock drift fine-grained sweep.** The existing `test_oscillator_drift_tolerance`
checks the ±10% endpoints (drift factors 0.9 and 1.1). An exhaustive sweep
across the full ±10% range in finer increments (e.g., 1% steps, drift factors
0.90, 0.91, …, 1.10) would confirm that no threshold change or off-by-one-latency
lurks at any intermediate frequency. The concern is narrow but real: the
PRESSED_THRESH=8 tick boundary is calculated for the +10% worst case, but
intermediate frequencies could expose a rounding or tick-count edge case in the
ISR timing that the endpoints alone don't exercise. Mechanically simple: loop
over drift factors, reset sim, measure latency, assert <10ms.

**Power-supply ramp-up simulation.** The design assumes clean 5V at power-on, but
real LDOs with large output capacitors can produce slow-rising VCC (tens of ms to
reach full voltage). A slow ramp could cause the MCU to begin code execution
before the internal oscillator stabilises, or before the footswitch's external
pull-up reaches a valid logic high. simavr does not natively model voltage ramps,
but the concern can be tested indirectly: (a) clock-prescale and GPIO setup are
the first operations in `init()`, so verify these complete correctly under a
bogus initial register state (inject pre-init register corruption via simavr's
data array before the firmware starts); (b) confirm the 64ms SUT delay is
sufficient for the LDO ramp by worst-case analysis (check the LP2950/AP7375
datasheet startup time against 64ms). Item (b) is a documentation/analysis task.

**VCD waveform diff across output variants.** The simavr trace target
(`make trace`) currently produces a VCD for one variant at a time. A scripted
comparison of the same footswitch input sequence across all three variants
(CD4053, mute, relay) would: (a) confirm the LED (PB1) timing is byte-identical
across variants; (b) verify that the mute and relay delays only add their fixed
extra latency to PB2/PB3 transitions without perturbing the debounce state
machine; (c) produce a visual artifact suitable for inclusion in the design
documentation as empirical proof of variant-consistent behaviour. Requires
generating three VCDs from the same input script and diffing the PB1 edges.

**Cross-compiler verification.** The firmware is built with avr-gcc 7.3. A
different AVR compiler (newer avr-gcc, or clang targeting AVR if available)
could optimise differently, potentially altering register allocation, ISR
prologue/epilogue timing, or the volatile-access ordering that the sanity checks
rely on. Building the firmware with an alternative compiler and running the full
simavr suite would catch compiler-specific behavioural changes. The Makefile's
existing `TOOLCHAIN_STAMP` already triggers a rebuild on compiler change, but
does not *compare* the behavioural results between compiler versions; adding a
`test-cross-compiler` target that builds with `CC=avr-gcc-12` (if installed)
and re-runs `test-sim` would close this gap.

**Stuck-switch long-duration test.** The design documents that a mechanically
stuck (permanently closed) switch results in the firmware sitting in
RELEASE_DEBOUNCE_WAIT indefinitely with no recovery — this is intentional.
However, no test explicitly drives the footswitch permanently low for an
extended simulated duration (hours) and asserts exactly zero toggles occur.
The existing `test_long_hold_single_toggle` holds for 3-5 seconds; a
multi-hour simavr run (or a golden-model run, which is much faster) with a
permanent low input would make this documented behavior an explicit, enforced
guarantee. Mechanically trivial: `drive(&m, 1, 3600000)` and assert
`toggle_count == 1` (the one toggle from the initial press). The golden-model
path is preferred for duration since simavr real-time ratio makes hours of
simulated time impractical.

**WDT pet frequency measurement.** The existing `test_watchdog_not_tripped_normally`
confirms the WDT does *not* fire during normal operation, but does not verify
the *rate* at which `wdt_reset()` is called. A more precise assertion: during
steady-state idle operation, `wdt_reset()` should be called at approximately
1 kHz (once per 1ms tick, gated by the `timer_isr_called_` handshake). This
could be verified in the simavr harness by counting the number of times the
main loop reaches the `wdt_reset()` call site over a known simulated time
window (e.g., count over 100ms, assert 95-105 calls). Requires either a
breakpoint hook on the `wdt_reset()` instruction sequence or a cycle-count
measurement between consecutive WDT resets via the WDT register model. Catches
a regression where the `timer_isr_called_` handshake is broken in a way that
still allows occasional WDT pets (e.g., if the flag is cleared but the
`wdt_reset()` is skipped on some iterations).

**Negative static_assert verification.** The `init()` function contains several
`static_assert` guards that enforce critical configuration constraints (e.g.,
`RELEASE_THRESH > PRESSED_THRESH`, `PRESSED_THRESH > 0`, timer formula
consistency). These are compile-time checks, so they are implicitly verified
every time the firmware builds — but there is no test that confirms they
*actually fire* when violated. A meta-test would: (a) create a throwaway copy
of the source with a deliberately broken constraint (e.g., swap the threshold
values in `bypass_config.h`); (b) attempt to compile; (c) assert the
compilation fails with the expected `static_assert` diagnostic. This is
analogous to the mutation testing approach but targets build-time guards
rather than runtime behavior. Mechanically similar to `run_mutation_tests.sh`
but checking for compile failure instead of test failure. Low effort (~30 min)
and closes the gap where a future refactor could accidentally weaken or remove
a `static_assert` without anyone noticing.

**Boot-loop verification test.** The firmware is designed to handle a
WDT-reset-triggered reboot gracefully: `init()` is called on every reset, and
its first actions are `wdt_reset()` followed by `wdt_enable(WDTO_250MS)`. In
theory, if a persistent fault condition survives the reset (e.g., a corrupted
fuse, a physically shorted pin, an SEU that flips a register to the same bad
value every boot), the firmware would boot-loop — reset, re-init, hit the
sanity check, force another reset — harmlessly. However, no test explicitly
simulates a boot-loop scenario to confirm the device does not enter an
undefined state during repeated rapid resets. A simavr test would: (a) inject
a persistent fault (e.g., corrupt `program_state_` to 0xFF in the reset path,
which cannot be fixed by re-init); (b) let the WDT fire and the firmware
reset; (c) verify the LED returns to dark (re-init to BYPASS) after each
reset; (d) repeat for several cycles and confirm consistent BYPASS recovery
each time. Requires the tinyx5 build (simavr models WDT reset). Low effort
(~30 min). Closes the gap where a fault that survives reset could cause
undefined behavior rather than a clean, bounded boot-loop.

**WDT re-arm timing window measurement.** After a watchdog-triggered reset on
AVR, the WDT runs with a ~16ms timeout (prescaler reset to its shortest
setting) until software explicitly reconfigures it. The firmware's `init()` is
designed to call `wdt_reset()` then `wdt_enable(WDTO_250MS)` within the first
few dozen instructions — comfortably within the ~16ms window even at 1.0-1.2
MHz with the loose WDT oscillator tolerance. However, no test measures the
actual cycle count between these two calls to confirm the window is
comfortable. A simavr test would: (a) set a breakpoint or cycle counter at the
first instruction of `init()`; (b) measure cycles to the `wdt_enable()` call;
(c) assert the elapsed cycles are well under the worst-case post-reset WDT
window (allowing for the WDT oscillator's loose tolerance, the window could be
as low as ~7ms — so the test should assert << 7ms, ideally < 1ms). Low effort
(~30 min). Closes the safety-margin gap for the WDT-reset-recovery path.

**Footswitch-pin glitch regression test (simavr quirk).** The simavr harness's
`run_one_tick_settled()` re-drives the footswitch pin on every `avr_run()`
call to work around a known simavr modeling quirk: when the firmware does a
read-modify-write of PORTB (to drive the LED or a control pin), simavr
re-evaluates the IRQ-driven INPUT pin PB0 back to its pull-up level, dropping
an externally-driven "pressed" (low) state. On real hardware, writing
PB1/PB2/PB3 cannot disturb the PB0 switch input. The re-drive workaround is
documented and correct, but no test *explicitly* verifies the scenario it
prevents: a dedicated test would: (a) assert the footswitch pin LOW (pressed);
(b) trigger a toggle so the firmware performs PORTB writes during the
relay/mute delay; (c) measure the debounce counter immediately after the
toggle and confirm it is not spuriously decremented (which would happen if the
workaround were removed — simavr would feed the integrator "released" samples
during the blocking delay). This is a meta-test: it verifies the test harness
itself is not masking a real firmware bug. Low effort (~30 min). Prevents a
future refactor from removing the re-drive workaround without detection.

**Compiler optimization sensitivity test.** The firmware is currently built
with a single optimization level (`-Os` for size). Different optimization
levels (`-O0`, `-O1`, `-O2`, `-O3`) could theoretically alter register
allocation, ISR prologue/epilogue timing, or the volatile-access ordering that
the sanity checks and ISR/main handshake rely on. A `test-opt-sweep` Makefile
target would build each variant with each optimization level, run the full
simavr test suite against each build, and assert identical behavioral results.
This catches a regression where a future code change introduces
optimization-sensitive behavior (e.g., a missing `volatile` that happens to
work under `-Os` but breaks under `-O2`). Mechanically simple: the Makefile
already supports `CFLAGS` overrides and the simavr harness is variant-agnostic.
Low effort (~1 h). Quick win with good coverage value.

**Interrupt latency measurement in simavr.** The design assumes the Timer0
compare-match ISR fires promptly and the footswitch pin is sampled within the
same 1ms tick. No test currently measures the actual cycle count between the
Timer0 compare-match event and the first ISR instruction, or between the ISR
and the main-loop's consumption of the integrated counter. A simavr test would
use cycle-accurate timing to measure: (a) ISR entry latency (compare-match to
first ISR instruction); (b) ISR execution duration (entry to `reti`); (c) total
interrupt-disabled time per tick. These measurements confirm the ISR overhead
is negligible relative to the 1ms tick period (1200 cycles at 1.2 MHz), so
timing accuracy is not compromised. Low effort (~1–2 h). Confirms a design
assumption that is currently unmeasured.

**Formal verification of `_delay_ms()` blocking safety.** The relay and mute
output drivers call `_delay_ms()` (a busy-wait loop) inside
`hw_set_bypass_state()` / `hw_set_engaged_state()`. During this blocking
window, the main loop cannot pet the watchdog, and the timer ISR continues
firing and integrating the debounce counter. The `static_assert` guards
(`CD4053_MUTE_DELAY_MS < RELEASE_THRESH`,
`TQ2_L2_5V_PULSE_MS < RELEASE_THRESH`) already prove the delay is shorter than
the release lockout, preventing counter drain to zero during the block. A CBMC
proof would formalize the full safety argument: (a) the blocking delay
duration is always less than the WDT timeout (trivially true: 12 ms << 250 ms,
but made explicit); (b) the delay is always less than RELEASE_THRESH (already
static_asserted, but CBMC would prove the inequality holds for any future
config change that passes the static_assert); (c) the relay coil pulse duration
is within the TQ2-L2-5V datasheet limits. Implemented as a new CBMC harness in
`test_cbmc.c` with `_delay_ms()` stubbed as a no-op. Low effort (~1–2 h).
Makes the blocking-delay safety argument explicit rather than implicit.

**Interrupt-free window measurement.** During normal operation, the firmware
should never disable interrupts: the timer ISR and main loop both run with
interrupts enabled (`sei()` is called once at the end of `init()` and never
disabled during steady state). The only `cli()` calls are in `init()` (once,
before interrupts are enabled) and in `hw_force_wdt_reset()` (fault-only path).
A simavr test would verify this property at runtime: monitor the global
interrupt-enable flag (I-bit in SREG) throughout a representative workload
(idle, press, toggle, release, repeated taps) and assert it remains set at all
times outside `init()`. This catches a regression where a future code change
inadvertently introduces a `cli()` without a matching `sei()`, which could
cause missed timer ticks or a WDT timeout. Low effort (~1 h). Confirms a
design invariant that is currently only enforced by code inspection.

**Stack depth cross-verification.** The firmware's stack usage is currently
verified by two independent methods: (1) `-fstack-usage` static per-function
frame analysis (Makefile `test-stack-bound` target, 32 B ceiling), and (2)
simavr runtime high-water mark measurement with a 0xAA canary pattern
(`test_stack_high_water_mark`). A third independent method — disassembly-based
call-graph analysis — would cross-reference the other two and catch any case
where the compiler's stack usage report disagrees with the actual binary. The
approach: `avr-objdump -d` the firmware ELF, extract the call graph (CALL/RCALL
instructions), compute the maximum call depth, and sum the per-function frame
sizes from the `-fstack-usage` output. Compare the resulting static bound
against the simavr dynamic measurement. The firmware is small enough (a dozen
functions, max depth ~4) that this can be done with a simple script. Medium
effort (~2–3 h). Closes the gap where a compiler bug or inline assembly could
make the actual binary's stack usage diverge from the compiler's report.

**Full-path symbolic execution (KLEE with bounded loops).** The existing KLEE
path in `test_symbolic.c` proves per-step (single-tick) invariants — the
inductive step that, combined with valid initial states, implies whole-program
correctness. Extending this to multi-step verification would prove
whole-trajectory properties directly: e.g., "no input sequence of length N can
cause more than 1 toggle," or "from any valid state, any input sequence of
length N returns to a valid state." This provides an independent argument to
the exhaustive BFS proof in `test_model_check.c`, discharged by a different
engine (KLEE's symbolic execution vs. explicit BFS). The infrastructure
already exists (`-DUSE_KLEE`, `klee_make_symbolic`); the extension adds a new
harness function with a bounded loop (e.g., `--unwind 50`) that steps the
firmware's `debounce_integrate()` + `debounce_step()` N times with symbolic
inputs and asserts the trajectory property. Medium effort (~2–4 h). High value
as an independent whole-trajectory proof.

**Property-based testing framework.** The existing fuzz tests use a hand-rolled
`xorshift32` PRNG with uniform random inputs. A property-based testing
framework (e.g., rapidcheck for C/C++, or a custom generator) could generate
more sophisticated input distributions biased toward edge cases — e.g.,
"presses that reach exactly PRESSED_THRESH-1 then bounce," "sustained noise
with random duty cycles," "presses with exponentially distributed hold times"
— and automatically shrink failing cases to minimal reproductions. The current
tests would be retained; the property-based tests would supplement them with
more targeted input generation. The value is in finding edge cases that uniform
random fuzzing is statistically unlikely to hit (e.g., a bug that only
manifests when the counter reaches exactly PRESSED_THRESH-1 for 3 consecutive
ticks, then drops to 0 for 2 ticks, then rises again). Medium effort (~2–4 h).
Requires adding a C property-based testing library or writing custom generators.

**Formal ISR/main interleaving model (TLA+ or SPIN).** The `test_model_check.c`
nondeterministic scheduling proof verifies invariants I1–I3 hold when main
runs 0, 1, or 2 times per ISR tick. However, this C-level model cannot express
sub-byte interleavings — e.g., the ISR writing `debounce_counter` (a `uint8_t`
on AVR, hence atomic) while main reads the `ctx_` struct (3 bytes, non-atomic
read on 8-bit AVR). A TLA+ or SPIN model would formalize the ISR/main
interleaving at the byte level, modeling each byte read/write as a separate
step, and verify that all possible interleavings preserve the safety
invariants. This would be the definitive proof that the race conditions in the
`ctx_` struct sharing (documented in `bypass_core.c` lines 284–286 and
analyzed in the firmware review) are truly benign. The state space is tiny (3
bytes + 1 handshake byte + 2 program states), so the model check completes in
milliseconds. High value as a formal concurrency-safety argument. Medium-high
effort (~4–8 h). Overkill for a project of this size, but would be the
strongest possible verification of the ISR/main interaction.

**Signal-integrity SPICE modeling of the footswitch input network.** (NEW — from third review pass)
The design's EMI/RFI defense includes a hardware filter (TVS, ferrite, 1k series, 22nF to ground, 10k pull-up) with a time constant τ ≈ 18 µs. The firmware's 8 ms integrator threshold is claimed to be ~80× the hardware filter corner, but this ratio is based on an order-of-magnitude estimate, not a SPICE simulation. Before the first PCB is ordered, run a SPICE transient analysis of the complete input network with: (a) a 5 kV ESD pulse (IEC 61000-4-2 contact discharge model) to verify the MCU pin stays within absolute maximum ratings and the clamped pulse does not exceed Schmitt-trigger VIL/VIH thresholds; (b) a GSM 900 MHz burst-coupled interference source on a 10 cm twisted-pair cable to verify the filtered envelope stays above VIH (does not falsely register as a press) for any burst shorter than the firmware's integration window. This is the last pre-hardware design-check gap before the board can be considered EMI-hardened by design rather than by hope. Low effort if the user already has a SPICE deck; ~2 h if starting from a schematic capture. High value as it validates the hardware assumptions the firmware relies on.

**Multi-seed Monte Carlo random-noise fuzzing.** (NEW — from third review pass)
The existing random-noise tests (`test_random_noise_resilience`, `test_fuzz_random_patterns`) use a single fixed seed (0xDEADBEEF) and assert an exact toggle count for that seed. This provides a strong regression lock but does not prove the firmware is correct for ALL random seeds. A seed-dependence bug (statistically unlikely but mathematically possible) would pass the fixed-seed test and only manifest in the field. A pre-hardware Monte Carlo campaign: run the random-noise stream with 100 different seeds (or a configurable number), and for each seed verify (a) the toggle count stays within the physical maximum ceiling (`duration / (PRESSED_THRESH + RELEASE_THRESH) + 1`), (b) the lock-step co-sim produces zero mismatches against the golden model, and (c) the final effect state is consistent with the toggle-count parity. Any seed that violates these invariants triggers a regression. Mechanically trivial: a script loops over seeds and re-runs `test_sim.c` or `test_logic_host.c` with each. Low effort (~1 h) and provides statistical confidence that the fixed-seed lock is not hiding a seed-dependent anomaly.

**Multi-press boundary-case regression tests.** (NEW — from third review pass)
The existing tests cover the principle press-release scenarios well, but three specific boundary combinations are not explicitly asserted: (a) two back-to-back PRESSED_THRESH-minus-one intervals (total 2×(PRESSED_THRESH−1) = 14 ms > PRESSED_THRESH = 8 ms, but the counter never holds at threshold long enough because each interval drops before the next rise) — must produce zero toggles; (b) release-bounce that lands exactly when the lockout counter is at 1 (a single-tick press during drain raises counter to 2, then drain resumes to 0) — must delay re-arm by one tick but still re-arm correctly; (c) the maximum-frequency tap train at exactly PRESSED_THRESH + RELEASE_THRESH intervals (33 ms apart) — the fastest clean press the algorithm can theoretically register, repeated 10–20 presses to verify no drift or missed taps at the rate limit. These three scenarios exercise the integrator's saturating behavior at the exact tick boundaries that matter. Add them to both `test_logic_host.c` (fast golden-model regression) and `test_sim.c` (instruction-accurated firmware confirmation). Low effort (~1 h per scenario; 3–4 h total).

---

## Tier 3 — platinum-level / nice-to-have

**Hardware-validation procedure.** The single largest residual verification gap
is structural: simavr cannot model the ATtiny13a watchdog system reset (only the
tinyx5 family), so the headline WDT-recovery guarantee on the *primary* part is
asserted by analogy, not direct simulation. Document a bench procedure: scope
PB1/PB2, artificially stop the ISR, confirm the device resets to BYPASS within
the WDT window; plus power-on glitch and BOD behavior. Bridges to the
manufacturing item below.

**KLEE in CI.** `test_symbolic.c` already supports `-DUSE_KLEE` and there is a
`test-symbolic-klee` target; a CI job (klee/klee Docker image) would prove the
symbolic path is actually exercised, not merely compilable.

**tinyAVR 2-Series (ATtiny202) support.** The ATtiny202 is the natural
next-generation successor to the ATtiny13a: 8-pin SOT-23 or DFN-8, 2 KB flash,
256 B SRAM, capable at 3.3 V/5 V. However it is based on the AVR8X architecture
(tinyAVR 2-Series), a complete peripheral redesign — the ISA is
backward-compatible but virtually every register differs: GPIO is
`PORTA.DIR`/`PORTA.OUT`/`PORTA.IN` instead of `DDRB`/`PORTB`/`PINB`; the timer
is TCA0/TCB0 (different ISR vectors, different CTC setup); the WDT uses
`WDT.CTRLA`; the clock prescaler is `CLKCTRL.MCLKCTRLB`; sleep is
`SLPCTRL.CTRLA`. Programming uses UPDI (not ISP/SPI), requiring a different
avrdude programmer. Fuse bytes are a completely different layout
(`FUSE.WDTCFG`, `FUSE.BODCFG`, etc.).

The algorithm (`bypass_pure.c`) and all host-side tests are already fully
portable. The output abstraction (`bypass_hw_iface.h`) is partially complete —
effect state switching is already behind the interface — but the following
remain in `bypass_core.c` as classic-AVR code not yet abstracted: timer setup
and ISR vector, WDT arm/reset/clear, clock prescaler, ADC/analog-comparator
disable, power gating, sleep, interrupt controller setup, and footswitch pin
reading. The output drivers also use `DDRB` directly in `hw_init_ddrb_setup()`
and `hw_is_sanity_check_failed()`.

The clean implementation path is: (1) extend `bypass_hw_iface.h` with
primitives for footswitch read, pin direction, WDT reset, idle sleep, and MCU
init; (2) extract the classic-AVR implementations of those into a new
`bypass_mcu_attiny13a.c` (separating the currently monolithic `bypass_core.c`);
(3) update the output drivers to call `hw_pin_set_output(pin)` instead of
writing `DDRB` directly; (4) write `bypass_mcu_attiny202.c` implementing the
same interface with AVR8X registers; (5) add `attiny202` to the Makefile
(trivial given the existing template structure); (6) add ATtiny202 fuse config
and extend `test_fuses.c`.

The significant open gap is **simavr**: its AVR8X/tinyAVR-2-Series support is
limited to nonexistent, so the fault-injection and lock-step co-simulation tests
cannot automatically extend to ATtiny202. Options are: accept that the ATtiny202
build is validated by static analysis + CBMC + model check + real hardware (no
simulation layer); or evaluate QEMU's AVR plugin, which has a better AVR8X
trajectory.

---

## Tier 4 — out of scope for firmware (name only)

A manufacturer adopting this reference design additionally needs: a professional
schematic (KiCad), a BOM with manufacturer part numbers and approved
substitutes, a hardware production test procedure, and an FMEA. These are
outside the firmware scope; naming them in the design doc as "out of scope /
left to the implementer" is itself evidence of thoroughness.

---

## Priority summary

| Item                                            | Tier | Effort    | Impact                          |
|-------------------------------------------------|------|-----------|---------------------------------|
| GitHub Actions CI (full variant/MCU matrix)     | 1    | 1–2 h     | Very high — credibility signal  |
| Design doc: resource-utilization section        | 1    | 1 h       | High — measured numbers exist   |
| Stale refs + editorial-note fix                 | 1    | 15 min    | Medium — correctness of docs    |
| Design doc: datasheet citations                 | 2    | 2 h       | High — completeness/rigor       |
| Minimum-tap-interval test                       | 2    | done      | Medium — closes traceability    |
| `-fstack-usage` static bound                    | 2    | done      | Medium — complements HWM test   |
| Flash-utilization budget assertion              | 2    | done      | Medium — resource budget        |
| AVR instruction-level fault injection           | 2.5  | 2–3 h     | High — extends fault coverage   |
| Extended lock-step with variant ctrl outputs    | 2.5  | 2–4 h     | High — closes co-sim gap        |
| Power-on-pressed in simavr                      | 2.5  | 1–2 h     | Medium — simavr quirk workaround|
| Out-of-range counter recovery proof             | 2.5  | 30 min    | Medium — formal defense in depth|
| Formal verification of output drivers           | 2.5  | 3–4 h     | Medium — driver correctness     |
| Long-duration soak test                         | 2.5  | 1 h       | Medium — rare-edge-case stress  |
| ISR-timing-jitter stress test                   | 2.5  | 1–2 h     | Low — confirms design property  |
| Golden-model vs model_step cross-validation     | 2.5  | 1–2 h     | Medium — fourth oracle path     |
| Clock drift fine-grained sweep                  | 2.5  | 1 h       | Low — narrow but real edge case |
| Power-supply ramp-up simulation                 | 2.5  | 2–3 h     | Medium — real-world robustness  |
| VCD waveform diff across output variants        | 2.5  | 1 h       | Low — visual/empirical artifact |
| Cross-compiler verification                     | 2.5  | 2 h       | Medium — compiler-safety net    |
| Stuck-switch long-duration test                 | 2.5  | 30 min    | Medium — enforces documented    |
| WDT pet frequency measurement                   | 2.5  | 1–2 h     | Medium — catches handshake bugs |
| Negative static_assert verification             | 2.5  | 30 min    | Low — build-guard meta-test     |
| Boot-loop verification test                     | 2.5  | 30 min    | Medium — bounded recovery under persistent fault |
| WDT re-arm timing window measurement            | 2.5  | 30 min    | Medium — safety-margin for WDT-reset path |
| Footswitch-pin glitch regression test           | 2.5  | 30 min    | Low — test-harness meta-test    |
| Compiler optimization sensitivity test          | 2.5  | 1 h       | Medium — quick win, catches opt-sensitive bugs |
| Interrupt latency measurement in simavr         | 2.5  | 1–2 h     | Low — confirms design assumption |
| Formal verification of `_delay_ms()` safety     | 2.5  | 1–2 h     | Medium — makes blocking-delay argument explicit |
| Interrupt-free window measurement               | 2.5  | 1 h       | Medium — confirms runtime invariant |
| Stack depth cross-verification                  | 2.5  | 2–3 h     | Medium — third independent stack bound |
| Full-path symbolic execution (KLEE)             | 2.5  | 2–4 h     | High — independent whole-trajectory proof |
| Property-based testing framework                | 2.5  | 2–4 h     | Medium — targeted edge-case generation |
| Formal ISR/main interleaving model (TLA+/SPIN)  | 2.5  | 4–8 h     | High — definitive concurrency-safety proof |
| Signal-integrity SPICE modeling                 | 2.5  | 2 h       | High — validates hardware assumptions before PCB |
| Multi-seed Monte Carlo fuzzing                  | 2.5  | 1 h       | Medium — statistical confidence beyond fixed-seed lock |
| Multi-press boundary cases                      | 2.5  | 3–4 h     | Medium — tick-boundary edge cases at rate limit |
| Hardware-validation procedure doc               | 3    | 2–3 h     | High — primary-part WDT gap     |
| KLEE in CI                                      | 3    | 2 h       | Nice-to-have                    |
| tinyAVR 2-Series (ATtiny202) support            | 3    | 2–4 days  | Nice-to-have; simavr gap        |
| Manufacturing artifacts (name as scope)         | 4    | —         | Completeness signal             |
