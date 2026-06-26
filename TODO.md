# Remaining work toward textbook reference quality

Status note: the firmware and test/validation suite have been meta-reviewed
several times (design doc, firmware implementation, golden-model accuracy, test
correctness, and additional verification opportunities). The firmware has no
known correctness defects; `make test` passes clean across all three output
variants and both MCU families (ATtiny13a and tinyx5), with 99.35% golden-model
line coverage. The reviews confirmed: (1) the design meets its stated goals;
(2) no bugs, race conditions, or footguns were found in the firmware; (3) the
golden model matches the firmware exactly via three independent verification
paths; and (4) all existing tests are correct and meaningful. The items below
are deferrable polish and credibility work — none are bugs. Anything that *is* a
bug gets fixed immediately, not parked here.

---

## PIC branch meta-review (2026-06-25, `pic10f32x_support`)

A pre-merge meta-review of the PIC10F322 shell (`bypass_mcu_pic10f32x.c`) and the
hardware-abstraction refactor on this branch found **no correctness defects** —
the PIC tick/WDT timing, the TRISA/LATA output logic, the footswitch read, and
every variant's engaged/bypass register pattern check out against the gpsim
expectations. The items below are quality-parity and robustness-consistency gaps
relative to the mature AVR Classic path. The CI item is the one worth closing at
(or before) merge; the rest are deferrable polish, consistent with the
no-bugs-parked-here rule above.

**STATUS — DONE.** All five items below were completed on branch
`pic10f32x_support` (2026-06-25): the CI gate in the `ci:` commits (the PIC
job plus the AVR re-enable, with the temporary branch push-trigger reverted
to `[main]`); items 1, 2, and 4 in `pic: nWPUEN pull-up + early WDT pet;
gpsim power-on coverage`; and item 3 in `refactor: hoist shared compile-time
threshold contract to a header`. Each item is tagged `— DONE` below, and
retained for traceability rather than deleted.

**PIC firmware has no CI / automated gate (highest — DONE).** `make test` (the gating
CI job) is AVR-only; the PIC build, CONFIG-word check, MISRA, and gpsim test all
live under the standalone `make pic-test` target, which CI never invokes (`grep`
for pic/xc8/gpsim in `.github/workflows/ci.yml` → nothing). Result: a regression
in `bypass_mcu_pic10f32x.c`, the PIC pin map, or a `#pragma config` line is
caught only if a developer locally has XC8 + the DFP + gpsim and remembers to run
it. The AVR shell, by contrast, is gated on every push (analyze + host +
model-check + symbolic + CBMC + simavr + coverage). Add a `pic` CI job that
installs XC8 + the PIC10-12Fxxx DFP + gpsim and runs `make pic-test` (YAML sketch
drafted 2026-06-25). Critical subtlety: the `pic-test` sub-targets *skip cleanly*
when a tool/header is absent, so the CI job MUST assert the toolchain is present
(fail loud) — otherwise a broken XC8 install would turn the gate green silently.
Effort: ~2–4 h (mostly XC8-in-CI plumbing). Impact: High — brings the PIC path
under the same continuous protection as AVR.

**PIC footswitch pull-up integrity check is weaker than the AVR's (firmware — DONE).**
`hw_footswitch_pullup_intact()` (`bypass_mcu_pic10f32x.c` ~L134) checks only the
per-pin `WPUA[FOOTSW_PIN]` latch, but the PIC weak pull-up has a two-part enable:
the per-pin `WPUA` bit *and* the global active-low `OPTION_REGbits.nWPUEN`. An
SEU/EMI event that flips `nWPUEN` to 1 disables the footswitch pull-up while this
sanity check still passes. The AVR analogue (`bypass_mcu_avr_classic.c:140`)
checks the single bit that *is* its pull-up enable, so it is complete. For
parity, the PIC check should also assert `0U == OPTION_REGbits.nWPUEN`. Firmware
edit (user). Effort: ~15 min. Impact: Medium — restores SEU-detection symmetry
under the project's stated cosmic-ray/EMI threat model.

**PIC `init()` has no early WDT handling, and why that is safe is undocumented
(firmware/doc — DONE).** The AVR makes re-arming the WDT its first init action and
documents the post-WDRF ~16 ms reset-loop hazard that motivates it
(`bypass_mcu_avr_classic.c:149-175`). The PIC `init()` has no `CLRWDT()` at all —
the first pet is in the loop, after the ~12 ms `hw_set_bypass_state()` pulse.
This appears safe (the PIC POR/reset WDT default of 1:65536 ≈ 2 s far exceeds
init + the pulse, and the PIC lacks the AVR's short-post-reset hazard), but that
reasoning is nowhere in the code. Either add a comment to the PIC shell
explaining why no early pet is needed, or add a belt-and-suspenders `CLRWDT()` at
the top of `init()` mirroring the AVR. Confirm the PIC10F322 WDTCON POR default
against datasheet DS40001585 while doing so. Firmware/doc edit (user). Effort:
~30 min. Impact: Low-Medium — closes a doc/parity gap on a load-bearing
fault-recovery path.

**Hoist the duplicated MCU-neutral compile-time contract into a shared header
(redundancy — DONE).** `DEBOUNCE_COUNTER_MAX (255U)` plus its ~10-line MISRA rationale,
and the five MCU-neutral threshold `static_assert`s (`RELEASE_THRESH <
DEBOUNCE_COUNTER_MAX`, `> 0`, `> PRESSED_THRESH`, and the two `PRESSED_THRESH`
bounds) are copy-pasted verbatim into both shells (`bypass_mcu_avr_classic.c`
L53-62/L262-266 and `bypass_mcu_pic10f32x.c` L64-69/L216-220). Beyond the
duplication this is a drift risk: someone could tighten the invariant in one
shell and not the other. Move them into one shared header (a new
`bypass_compile_checks.h`, or fold into `bypass_config.h`/`bypass_pure.h`)
included by both shells. The genuinely MCU-specific asserts (the `-fshort-enums`
size checks, the `PBx`/`_PORTA_RAx_POSN` pin pinning, the `F_CPU`/`_XTAL_FREQ`
checks) stay per-shell. Leave the per-shell HW helpers (`hw_force_wdt_reset`,
`hw_read_footswitch`, the fault/toggle dispatch) duplicated — the two main loops
differ structurally (ISR vs polled) and per-shell clarity beats DRY for a
reference design. Firmware edit (user). Effort: ~30–45 min. Impact: Medium —
removes verbatim duplication and a drift risk.

**PIC functional-test rigor is below the AVR's (test, tooling-constrained — DONE).**
The AVR has simavr lock-step (`model_step.h` converging on real code) plus fault
injection and mutation; the PIC has a 4-checkpoint gpsim functional test
(`test/pic/footswitch_toggle.stc`). The shared pure core is fully covered by the
host/formal/mutation suites, so the PIC-specific exposure is only shell wiring —
which gpsim does exercise — and there is no lock-step model for gpsim, so this is
a tooling constraint, not an oversight. To narrow the gap cheaply, extend the
gpsim scenario to (a) cover the power-on-pressed startup case (exercises the
`debounce_init_context` RELEASE-wait branch) and (b) assert `porta` at the
`BYPASS_AGAIN` checkpoint. Test edit. Effort: ~1 h. Impact: Low-Medium.

---

## Tier 2 — closes verification / traceability gaps

**Datasheet citations in the design doc.** The sleep-wakeup §7.3 cite lives in
`bypass_mcu_avr_classic.c`; the *design doc itself* currently cites no datasheet sections.
Each load-bearing decision should trace to a page/section: WDT ~16 ms post-reset
window; WDTON always-on; internal-RC ±10%; Timer0 CTC formula; BOD level.

---

## Tier 2.5 — additional software verification (pre-hardware)

These items were identified during a full meta-review of the firmware, design
doc, and test suite (2026-06-18). All close residual verification gaps that can
be addressed in software before physical hardware testing begins.

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
`ctx_` struct sharing (documented in `bypass_mcu_avr_classic.c` lines 284–286 and
analyzed in the firmware review) are truly benign. The state space is tiny (3
bytes + 1 handshake byte + 2 program states), so the model check completes in
milliseconds. High value as a formal concurrency-safety argument. Medium-high
effort (~4–8 h). Overkill for a project of this size, but would be the
strongest possible verification of the ISR/main interaction.

**Signal-integrity SPICE modeling of the footswitch input network.** (NEW — from third review pass)
The design's EMI/RFI defense includes a hardware filter (TVS, ferrite, 1k series, 22nF to ground, 10k pull-up) with a time constant τ ≈ 18 µs. The firmware's 8 ms integrator threshold is claimed to be ~80× the hardware filter corner, but this ratio is based on an order-of-magnitude estimate, not a SPICE simulation. Before the first PCB is ordered, run a SPICE transient analysis of the complete input network with: (a) a 5 kV ESD pulse (IEC 61000-4-2 contact discharge model) to verify the MCU pin stays within absolute maximum ratings and the clamped pulse does not exceed Schmitt-trigger VIL/VIH thresholds; (b) a GSM 900 MHz burst-coupled interference source on a 10 cm twisted-pair cable to verify the filtered envelope stays above VIH (does not falsely register as a press) for any burst shorter than the firmware's integration window. This is the last pre-hardware design-check gap before the board can be considered EMI-hardened by design rather than by hope. Low effort if the user already has a SPICE deck; ~2 h if starting from a schematic capture. High value as it validates the hardware assumptions the firmware relies on.

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
remain in `bypass_mcu_avr_classic.c` as classic-AVR code not yet abstracted: timer setup
and ISR vector, WDT arm/reset/clear, clock prescaler, ADC/analog-comparator
disable, power gating, sleep, interrupt controller setup, and footswitch pin
reading. The output drivers also use `DDRB` directly in `hw_init_ddrb_setup()`
and `hw_is_sanity_check_failed()`.

The clean implementation path is: (1) extend `bypass_hw_iface.h` with
primitives for footswitch read, pin direction, WDT reset, idle sleep, and MCU
init; (2) move the classic-AVR implementations of those behind that interface
within `bypass_mcu_avr_classic.c` (the shell, already renamed from the former
`bypass_core.c`), separating the still-inline register code from the portable
main loop; (3) update the output drivers to call `hw_pin_set_output(pin)`
instead of writing `DDRB` directly; (4) write `bypass_mcu_avr_xt.c` implementing
the same interface with AVR8X registers; (5) add `attiny202` to the Makefile
(trivial given the existing template structure); (6) add ATtiny202 fuse config
and extend `test_fuses.c`.

The significant open gap is **simavr**: its AVR8X/tinyAVR-2-Series support is
limited to nonexistent, so the fault-injection and lock-step co-simulation tests
cannot automatically extend to ATtiny202. Options are: accept that the ATtiny202
build is validated by static analysis + CBMC + model check + real hardware (no
simulation layer); or evaluate QEMU's AVR plugin, which has a better AVR8X
trajectory.

**PIC MCU family support (PIC10F320/PIC10F322).** These are 8-pin, 256–512 word
flash enhanced mid-range PICs targeted at low-power embedded control — a natural
companion to the ATtiny13a for this application. The debounce algorithm
(`bypass_pure.c`) and all host-side tests (model check, CBMC, logic host) are
already fully portable. The hardware shell, build system, programmer integration,
and simulation layer all need new PIC-specific implementations. Six sequential
phases:

*Phase 0 — toolchain and simulator feasibility gate (completed: ~2 h).* gpsim
0.32.1 (Ubuntu/Debian: `apt install gpsim`) has confirmed working support for
both PIC10F320 and PIC10F322: both appear in the processor list, the device
loads and executes instructions, and all key peripherals are accessible by name —
`porta` (0x05), `trisa` (0x06), `tmr0` (0x01), `intcon` (0x0B), `option_reg`
(0x0E), `wdtcon` (0x30), `iocap`/`iocan`/`iocaf` (0x1A–0x1C). A `SetProcessor
ByType FIXME` warning appears on load but is benign. No gpsim C development
headers are installed with the package, so simulation tests will use gpsim's
built-in script/command interface (`.stc` files or piped CLI commands) rather
than a C embedding API analogous to simavr; this means the simulation layer will
be real but shallower than the AVR suite (no lock-step co-simulation in the same
style, no cycle-accurate fault injection). For the compiler: Microchip XC8 free
tier, Linux `.run` installer from Microchip.com (requires a free account); the
free tier's optimization restrictions are inconsequential for this firmware's
size. For the programmer: `pk2cmd` (open-source Linux binary) for PICkit 2;
PICkit 3/4 on Linux uses `ipecmd.sh`, the headless CLI that ships inside the
MPLAB X installer package — MPLAB X IDE itself need not be launched.

*Phase 1 — hardware abstraction refactor (~1–2 days, shared with ATtiny202).*
This is a prerequisite for both PIC and the ATtiny202 entry above. The firmware
currently has two abstraction gaps: (a) `bypass_mcu_avr_classic.c` contains AVR-specific
timer setup, WDT arm/reset, clock prescaler, sleep invocation, interrupt
controller init, and footswitch pin read as inline classic-AVR register writes;
(b) the output drivers (`bypass_output_cd4053_simple.c`,
`bypass_output_tq2_l2_5v_relay.c`, `bypass_output_cd4053_with_mute.c`) write
`DDRB` directly in `hw_init_ddrb_setup()` and `hw_is_sanity_check_failed()`.
Close both gaps: extend `bypass_hw_iface.h` with primitives for footswitch read,
pin direction setup, WDT arm/reset/pet, sleep invocation, and MCU init; factor
the classic-AVR register code behind that interface within
`bypass_mcu_avr_classic.c` (the shell already renamed from `bypass_core.c`);
update the output drivers to use the abstracted pin direction calls. All existing
tests must pass unchanged — this is a restructuring, not a behavioral change.

*Phase 2 — PIC hardware shell (~1–2 days).* Write `bypass_mcu_pic10f32x.c`
implementing `bypass_hw_iface.h` for PIC10F322. Key architectural differences
from AVR: GPIO uses `TRISA`/`PORTA` instead of `DDRB`/`PORTB`; there is no
SLEEP_IDLE equivalent (the main oscillator stops during SLEEP), so the main loop
switches to a WDT-periodic-wakeup pattern — sample, debounce, update outputs,
CLRWDT, SLEEP; WDT wakes every ~1 ms via the internal LFINTOSC (31 kHz),
independent of the main oscillator. This is architecturally cleaner than the
AVR design: the WDT serves both roles (periodic waker when sleeping, fault-reset
watchdog when stuck awake) without the `timer_isr_called_` handshake flag. The
tradeoff is timing precision: LFINTOSC has ±10–15% variation with temperature
and voltage, so the 1 ms tick becomes 0.85–1.15 ms in practice — inconsequential
for switch debouncing. XC8 compiler differences: interrupt syntax is
`void __interrupt() isr(void)` instead of AVR's `ISR()` macro; delays use
`__delay_ms()` from `<xc.h>` instead of `_delay_ms()`. CONFIG bits (the PIC
equivalent of AVR fuse bytes) are embedded in the HEX file by XC8 via
`#pragma config` in source: enable the WDT as a fault watchdog (`WDTE = ON`),
set `MCLRE` off (RA3 is the footswitch), enable brownout reset. Pin assignment
for PIC10F322 (only four I/O: RA0–RA2 bidirectional, RA3 input-only / MCLR):
the footswitch goes on the input-only RA3 (MCLR disabled), freeing RA0–RA2 as
outputs. All three variants fit — the relay variant uses all four pins exactly
(footswitch + LED + two coils, no spare); cd4053-simple and mute have room.
PIC10F322 (512 words) is the recommended primary target; PIC10F320 (256 words)
is tight for the relay variant. (Detailed Model-B plan — 1 ms tick from TMR2,
WDT as a ~256 ms fault watchdog — in `docs/phase2_pic_shell.md`.)

*Phase 3 — build system (~4–8 h).* Add XC8 toolchain variables to the Makefile:
`PIC_CC = xc8-cc`, `--chip=10F322` device flag, output format flags. Add new
build targets: `pic10f322_cd4053`, `pic10f322_mute`, `pic10f322_relay`, plus a
`program-pic` target using `pk2cmd`/`ipecmd`. Add resource utilization reporting
(`xc8-cc --summary`). Add a flash-budget assertion analogous to
`test-flash-budget`: PIC10F322 has 512 words (1024 bytes) of program memory;
verify each variant fits with comfortable headroom. Note that XC8 free-tier
optimization produces larger code than an optimizing compiler; measure actual
usage before committing to the budget ceiling.

*Phase 4 — CONFIG bits validation and static analysis (~2–4 h).* PIC CONFIG bits
are embedded in the generated HEX file by XC8's `#pragma config` directives.
Write a `test_config_pic.c` analogous to `test_fuses.c` that parses the HEX
file and verifies the CONFIG word values match the intended settings (WDT enabled,
WDTPS correct, BOD voltage, MCLR config, code-protect off). The existing
`make analyze-misra` and `make analyze-cppcheck` targets operate on C source and
apply to PIC code without modification; however, XC8 has known MISRA deviations
(implicit static storage class for locals under the free tier, non-standard
interrupt declaration syntax) that need to be documented and suppressed
appropriately in `MISRA_COMPLIANCE.md`. XC8 does not support `-fstack-usage`
(a GCC-specific flag); the stack bound test needs an alternate approach — XC8's
`--callgraph` output provides per-function frame sizes for a similar static bound.

*Phase 5 — simulation (~1–2 weeks).* gpsim 0.32.1 has the required peripheral
models (confirmed in Phase 0), so this phase is implementation work rather than
a feasibility question. The interface difference from simavr is significant:
gpsim exposes a command/script interface (`.stc` files or piped CLI input)
rather than a C embedding API, and no development headers are available in the
Ubuntu/Debian package. The practical approach is gpsim script files that load
the firmware HEX, drive the footswitch pin via `stimulus`/`node` commands,
step the simulation forward, and assert register state via `reg()` reads — all
orchestrated by a shell script called from the Makefile as a new
`test-sim-pic10f322` target. This produces a meaningful simulation layer
(real firmware executing, GPIO state verified, WDT behavior observable) but
without the cycle-accurate lock-step co-simulation and fault injection that the
simavr C harness provides for AVR. To close that gap partially: the WDT-based
main-loop architecture lends itself to a coarser but still meaningful
co-simulation — drive the gpsim stimulus for N press/release cycles, compare
the final `porta` state to the golden model's prediction via a shell-level
assertion. Fault injection is feasible via gpsim's `reg()` write command
(corrupt `porta` or internal state between stimulus events and verify recovery)
though at a coarser granularity than simavr's `avr_core_watch_write()`.

*Phase 6 — documentation (~2–4 h).* Update `TOOLCHAIN.adoc` with a PIC section
(XC8 installation steps, `pk2cmd`/`ipecmd` setup, gpsim). Extend the
resource-utilization table in `DESIGN_DOCUMENTATION.adoc` with PIC10F322 flash
and RAM numbers per variant. Add XC8-specific MISRA notes to
`MISRA_COMPLIANCE.md`. Update `README.md`'s supported-MCU list.

Total effort: ~1 week of focused work for phases 1–4 and 6; another 1–2 weeks
for phase 5 depending on how deeply the gpsim scripting layer is developed.
Phase 1 (the hardware abstraction refactor) is shared with ATtiny202 and should
be done once to unblock both.

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
| PIC: add CI gate (`make pic-test`)              | done | 2–4 h     | High — PIC under same CI as AVR |
| PIC: pull-up check incl. `nWPUEN`               | done | 15 min    | Medium — SEU-detection parity   |
| PIC: document/early WDT in `init()`             | done | 30 min    | Low-Med — fault-path parity     |
| Hoist shared compile-time checks (both shells)  | done | 30–45 min | Medium — de-dup + drift risk    |
| PIC: extend gpsim scenario coverage             | done | 1 h       | Low-Med — shell-wiring coverage |
| Design doc: datasheet citations                 | 2    | 2 h       | High — completeness/rigor       |
| Power-on-pressed in simavr                      | 2.5  | 1–2 h     | Medium — simavr quirk workaround|
| Formal verification of output drivers           | 2.5  | 3–4 h     | Medium — driver correctness     |
| ISR-timing-jitter stress test                   | 2.5  | 1–2 h     | Low — confirms design property  |
| Golden-model vs model_step cross-validation     | 2.5  | 1–2 h     | Medium — fourth oracle path     |
| Clock drift fine-grained sweep                  | 2.5  | 1 h       | Low — narrow but real edge case |
| Power-supply ramp-up simulation                 | 2.5  | 2–3 h     | Medium — real-world robustness  |
| VCD waveform diff across output variants        | 2.5  | 1 h       | Low — visual/empirical artifact |
| Cross-compiler verification                     | 2.5  | 2 h       | Medium — compiler-safety net    |
| Stuck-switch long-duration test                 | 2.5  | 30 min    | Medium — enforces documented    |
| WDT pet frequency measurement                   | 2.5  | 1–2 h     | Medium — catches handshake bugs |
| Negative static_assert verification             | 2.5  | 30 min    | Low — build-guard meta-test     |
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
| Multi-press boundary cases                      | 2.5  | 3–4 h     | Medium — tick-boundary edge cases at rate limit |
| Hardware-validation procedure doc               | 3    | 2–3 h     | High — primary-part WDT gap     |
| KLEE in CI                                      | 3    | 2 h       | Nice-to-have                    |
| tinyAVR 2-Series (ATtiny202) support            | 3    | 2–4 days  | Nice-to-have; simavr gap        |
| PIC10F320/322 support                           | 3    | 2–4 weeks | Nice-to-have; gpsim confirmed   |
| Manufacturing artifacts (name as scope)         | 4    | —         | Completeness signal             |

(The five rows marked `done` above are the 2026-06-25 PIC branch meta-review
batch — all completed on branch `pic10f32x_support`; see that section for the
per-item detail. They are kept here for traceability rather than deleted.)
