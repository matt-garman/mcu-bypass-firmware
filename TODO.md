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

| Item                                         | Tier | Effort    | Impact                          |
|----------------------------------------------|------|-----------|---------------------------------|
| GitHub Actions CI (full variant/MCU matrix)  | 1    | 1–2 h     | Very high — credibility signal  |
| Design doc: resource-utilization section     | 1    | 1 h       | High — measured numbers exist   |
| Stale refs + editorial-note fix              | 1    | 15 min    | Medium — correctness of docs    |
| Design doc: datasheet citations              | 2    | 2 h       | High — completeness/rigor       |
| Minimum-tap-interval test                    | 2    | done      | Medium — closes traceability    |
| `-fstack-usage` static bound                 | 2    | done      | Medium — complements HWM test   |
| Flash-utilization budget assertion           | 2    | done      | Medium — resource budget        |
| AVR instruction-level fault injection        | 2.5  | 2–3 h     | High — extends fault coverage   |
| Extended lock-step with variant ctrl outputs | 2.5  | 2–4 h     | High — closes co-sim gap        |
| Power-on-pressed in simavr                   | 2.5  | 1–2 h     | Medium — simavr quirk workaround|
| Out-of-range counter recovery proof          | 2.5  | 30 min    | Medium — formal defense in depth|
| Formal verification of output drivers        | 2.5  | 3–4 h     | Medium — driver correctness     |
| Long-duration soak test                      | 2.5  | 1 h       | Medium — rare-edge-case stress  |
| ISR-timing-jitter stress test                | 2.5  | 1–2 h     | Low — confirms design property  |
| Golden-model vs model_step cross-validation  | 2.5  | 1–2 h     | Medium — fourth oracle path     |
| Clock drift fine-grained sweep               | 2.5  | 1 h       | Low — narrow but real edge case |
| Power-supply ramp-up simulation              | 2.5  | 2–3 h     | Medium — real-world robustness  |
| VCD waveform diff across output variants     | 2.5  | 1 h       | Low — visual/empirical artifact |
| Cross-compiler verification                  | 2.5  | 2 h       | Medium — compiler-safety net    |
| Hardware-validation procedure doc            | 3    | 2–3 h     | High — primary-part WDT gap     |
| KLEE in CI                                   | 3    | 2 h       | Nice-to-have                    |
| tinyAVR 2-Series (ATtiny202) support         | 3    | 2–4 days  | Nice-to-have; simavr gap        |
| Manufacturing artifacts (name as scope)      | 4    | —         | Completeness signal             |
