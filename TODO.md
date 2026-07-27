# Remaining work toward textbook reference quality

Status note: the firmware and test/validation suite have been meta-reviewed
several times (design doc, firmware implementation, golden-model accuracy, test
correctness, and additional verification opportunities). The firmware has no
known correctness defects; `make test` passes clean across all three output
variants and every supported MCU family. The reviews confirmed: (1) the design
meets its stated goals; (2) no bugs, race conditions, or footguns were found in
the firmware; (3) the golden model matches the firmware exactly via three
independent verification paths; and (4) all existing tests are correct and
meaningful. The items below are deferrable polish and credibility work — none
are bugs. Anything that *is* a bug gets fixed immediately, not parked here.

**Update (2026-07-10):** a subsequent external review of the multi-MCU build
did surface one real correctness defect — the TMUX4053 direct-drive (`_tmux`)
output variants drove the analog-switch control pin at the inverted MCU
polarity (BYPASS asserted at pin-high instead of the fail-safe pin-low), which
mis-switched the effect and, on the muted variant, transited the invalid
FXN+JOU-short state. Root cause: the polarity wrapper modeled the CD4053
MOSFET-inverter vs TMUX direct-drive electrical difference but not the swapped
analog throws, which cancel it. Fixed by driving one MCU polarity for both
boards and deleting the wrapper; the now-identical `_tmux` build variants were
dropped. Re-validated green. So the "no bugs found" claim above holds for the
firmware *as it now stands*, but the record should note that this one was found
and corrected here.

**Housekeeping note (2026-07-26):** this file was audited against the actual
test suite, Makefile targets, and CI. Completed work was removed rather than
kept as `— DONE` entries (git history and `CHANGELOG.md` are the record for
that), and items judged not worth doing were moved to "Considered and declined"
with their reasoning so they do not get re-proposed. Everything remaining below
was verified to still be open.

---

## Tier 2 — closes verification / traceability gaps

**Datasheet citations in the design doc.** The sleep-wakeup §7.3 cite lives in
`bypass_mcu_avr_classic.c`; the *design doc itself* currently cites no datasheet
sections at all (verified: zero datasheet references in
`DESIGN_DOCUMENTATION.adoc`). Each load-bearing decision should trace to a
page/section: WDT ~16 ms post-reset window; WDTON always-on; internal-RC ±10%;
Timer0 CTC formula; BOD level. The PIC shell's datasheet facts are already
recorded in `docs/phase2_pic_shell.md` §2 and can be cross-referenced rather
than duplicated.

---

## Tier 2.5 — additional software verification

These items were identified during a full meta-review of the firmware, design
doc, and test suite (2026-06-18) and re-verified as open on 2026-07-26. All
close residual verification gaps that can be addressed in software.

**Formal verification of output drivers.** The output drivers (relay, mute,
CD4053) contain blocking delays and multi-step pin sequences. They are tested by
scenario-based simulation tests but are not formally verified — `test_cbmc.c`
currently proves the pure core only. A state-machine model of each driver could
be proved to: (a) never leave both relay coils energized simultaneously;
(b) always park coils low after a pulse; (c) never enter an invalid
mute/engage/bypass pin combination. The drivers are small enough (~30–60 lines
each) that a CBMC proof or exhaustive state-space check is feasible. The main
obstacle is that the drivers call a blocking delay, which CBMC cannot
symbolically execute; the workaround is to stub the delay as a no-op and verify
the pin sequence logic in isolation.

**Formal verification of blocking-delay safety.** The relay and mute output
drivers call a busy-wait delay inside `hw_set_bypass_state()` /
`hw_set_engaged_state()`. During this window the main loop cannot pet the
watchdog, and on AVR the timer ISR continues firing and integrating the debounce
counter. The `static_assert` guards (`CD4053_MUTE_DELAY_MS < RELEASE_THRESH`,
`TQ2_L2_5V_PULSE_MS < RELEASE_THRESH`) already prove the delay is shorter than
the release lockout, preventing counter drain to zero during the block. A CBMC
proof would formalize the full safety argument: (a) the blocking delay is always
less than the WDT timeout (trivially true — 12 ms << 250 ms — but made explicit);
(b) the delay is always less than RELEASE_THRESH (already `static_assert`ed, but
CBMC would prove the inequality holds for any future config change that passes
the assert); (c) the relay coil pulse duration is within the TQ2-L2-5V datasheet
limits. Low effort (~1–2 h). Makes the blocking-delay safety argument explicit
rather than implicit. Note the PIC and AVR shells reach this window differently
(polled loop vs ISR-driven), so state which shell each clause covers.

**Golden-model vs `model_step` cross-validation.** The golden model
(`test_logic_host.c`) re-implements the algorithm independently; `model_step.h`
delegates to the real firmware's `bypass_pure.c`. Both produce identical results
for the same input stream (verified implicitly by the lock-step co-sim and the
model proofs), but no test drives the same random input sequence through *both*
oracles and asserts byte-for-byte agreement. A small test comparing
`model_step.step()` against `test_logic_host.c`'s `model_tick_isr()` +
`model_main_step()` over a long random stream would provide a fourth independent
verification path, catching any discrepancy between the hand-written oracle and
the compiled firmware logic. This also becomes materially more valuable in a
merged tree, where the independent-oracle and direct-core roles must be kept
distinct on purpose.

**Full-path symbolic execution (KLEE with bounded loops).** The existing KLEE
path in `test_symbolic.c` proves per-step (single-tick) invariants — the
inductive step that, combined with valid initial states, implies whole-program
correctness. Extending this to multi-step verification would prove
whole-trajectory properties directly: e.g. "no input sequence of length N can
cause more than 1 toggle," or "from any valid state, any input sequence of
length N returns to a valid state." This provides an independent argument to the
exhaustive BFS proof in `test_model_check.c`, discharged by a different engine.
The infrastructure already exists (`-DUSE_KLEE`, `klee_make_symbolic`, and the
`test-symbolic-klee` target now links the real shipping core); the extension adds
a harness function with a bounded loop (e.g. `--unwind 50`). Medium effort
(~2–4 h). High value as an independent whole-trajectory proof.

**KLEE in CI.** `test-symbolic-klee` and `test-klee-build` exist, and the latter
runs in the default `test` aggregate — but that only proves the KLEE path still
*compiles and links*. No CI job actually runs KLEE (verified: no `klee` reference
in `.github/workflows/ci.yml`). A job using the `klee/klee` Docker image would
prove the symbolic path is genuinely exercised. ~2 h.

Updated 2026-07-27: this is now a *packaging* task with a known-good recipe, not
an open question. KLEE 3.2 is installed locally under `/home/linuxbrew/.linuxbrew`
— where the Makefile's `KLEE*` defaults already point — and
`make test-symbolic-klee STRICT_TOOLS=1` runs clean against the shipping core
(5,918 instructions, 14 completed paths, 0 partially completed). The proof is
therefore reproducible on one host and watched on none, which is precisely the
gap a CI job closes. Pin the KLEE and matching-LLVM versions in `TOOLCHAIN.adoc`
when it lands, as every other tool here is pinned.

**Cross-compiler verification.** The AVR firmware is built with avr-gcc 7.3. A
different compiler (newer avr-gcc, or clang targeting AVR if viable) could
optimise differently, potentially altering register allocation, ISR
prologue/epilogue timing, or the volatile-access ordering the sanity checks rely
on. Building with an alternative compiler and running the full simulation suite
would catch compiler-specific behavioural changes. Classic firmware targets
already rebuild on request, but nothing *compares* behavioural results between
compiler versions. A `test-cross-compiler` target that builds with
`CC=avr-gcc-12` (if installed) and re-runs `test-sim` would close this gap. See
also the broader multi-compiler matrix in Tier 3, of which this is the narrow
first step.

**Compiler optimization sensitivity test.** The firmware is built at a single
optimization level (`-Os` for size). Other levels could theoretically alter
register allocation, ISR timing, or the volatile-access ordering the sanity
checks and the ISR/main handshake rely on. A `test-opt-sweep` target would build
each variant at each level, run the full simulation suite against each, and
assert identical behavioural results — catching a regression where a change
introduces optimization-sensitive behaviour (e.g. a missing `volatile` that
happens to work under `-Os`). The Makefile already supports `CFLAGS` overrides
and the harness is variant-agnostic. Low effort (~1 h), good coverage value.

**Stack depth cross-verification.** Stack usage is currently verified two ways:
`-fstack-usage` static per-function frame analysis (`test-stack-bound`, 32 B
ceiling) and runtime high-water measurement with a canary pattern
(`test_stack_high_water_mark`). A third independent method — disassembly-based
call-graph analysis — would cross-reference the other two and catch any case
where the compiler's report disagrees with the actual binary. Approach:
`avr-objdump -d` the ELF, extract the call graph (CALL/RCALL), compute maximum
call depth, sum the per-function frame sizes, compare against the dynamic
measurement. The firmware is small enough (a dozen functions, max depth ~4) for a
simple script. Medium effort (~2–3 h). Note XC8 does not support
`-fstack-usage`; its `--callgraph` output is the PIC equivalent if this is
extended there.

**Negative `static_assert` verification.** `init()` and the config headers
contain several `static_assert` guards enforcing critical constraints
(`RELEASE_THRESH > PRESSED_THRESH`, `PRESSED_THRESH > 0`, timer formula
consistency, pin-ordinal agreement). These are compile-time checks, implicitly
verified on every build — but no test confirms they *actually fire* when
violated. A meta-test would copy the source with a deliberately broken
constraint, attempt to compile, and assert the build fails with the expected
diagnostic. Mechanically similar to `run_mutation_tests.sh` but checking for
compile failure rather than test failure. Low effort (~30 min); closes the gap
where a refactor could weaken or remove a guard unnoticed.

**Clock drift fine-grained sweep.** `test_oscillator_drift_tolerance` checks only
the ±10% endpoints (drift factors 0.9 and 1.1). An exhaustive sweep in finer
increments (1% steps) would confirm no threshold change or off-by-one latency
lurks at any intermediate frequency. The concern is narrow but real: the
PRESSED_THRESH=8 tick boundary is calculated for the +10% worst case, and
intermediate frequencies could expose a rounding or tick-count edge case the
endpoints alone miss. Mechanically simple: loop over drift factors, reset sim,
measure latency, assert <10 ms.

**Stuck-switch long-duration test.** The design documents that a mechanically
stuck (permanently closed) switch leaves the firmware in RELEASE_DEBOUNCE_WAIT
indefinitely with no recovery — intentional. But no test drives the footswitch
permanently low for an extended duration and asserts exactly zero further
toggles. `test_long_hold_single_toggle` holds for 3–5 seconds; a multi-hour
golden-model run with a permanent low input would make this documented behaviour
an enforced guarantee. Mechanically trivial. Use the golden-model path for
duration — the simulator's real-time ratio makes hours impractical.

**WDT pet frequency measurement.** `test_watchdog_not_tripped_normally` confirms
the WDT does not fire during normal operation, but does not verify the *rate* at
which it is petted. During steady-state idle the pet should occur at
approximately 1 kHz (once per 1 ms tick, gated on AVR by the `timer_isr_called_`
handshake). Verifiable by counting pet-site executions over a known simulated
window (e.g. 95–105 over 100 ms). Catches a regression where the handshake is
broken in a way that still allows occasional pets. Applies to both the AVR
handshake and the PIC polled loop, with different expected counts — note the PIC
loses ticks during blocking actuation, so its expectation must budget for that.

**Interrupt-free window measurement.** During normal operation the AVR firmware
should never disable interrupts: `sei()` is called once at the end of `init()`
and never disabled in steady state. The only `cli()` calls are in `init()` and in
the forced-reset fault path. A simulation test would monitor the I-bit in SREG
across a representative workload (idle, press, toggle, release, repeated taps)
and assert it stays set outside `init()`. Catches a regression introducing a
`cli()` without a matching `sei()`, which could cause missed ticks or a WDT
timeout. Low effort (~1 h). Confirms a design invariant currently enforced only
by code inspection.

**Multi-press boundary-case regression tests.** Existing tests cover the
principal press-release scenarios well, but three boundary combinations are not
explicitly asserted: (a) two back-to-back PRESSED_THRESH-minus-one intervals
(total 14 ms > PRESSED_THRESH = 8 ms, but the counter never holds at threshold
long enough because each interval drops before the next rise) — must produce zero
toggles; (b) release-bounce landing exactly when the lockout counter is at 1 (a
single-tick press during drain raises the counter to 2, then drain resumes to 0)
— must delay re-arm by one tick but still re-arm correctly; (c) a
maximum-frequency tap train at exactly PRESSED_THRESH + RELEASE_THRESH intervals
(33 ms apart), the fastest clean press the algorithm can register, repeated 10–20
times to verify no drift or missed taps at the rate limit. These exercise the
integrator's saturating behaviour at the exact tick boundaries that matter. Add
to both the golden-model regression and the instruction-accurate firmware
confirmation. ~3–4 h total.

**Power-on-pressed simulation gap.** The simavr harness sets the footswitch IRQ
*before* the firmware starts (via `sim_reset(1)`), correctly exercising
`debounce_init_context(PIN_STATE_LOW)`. The known limitation: after a WDT reset,
simavr clears PINB to 0x00, inconsistent with the externally-driven IRQ level.
The golden model and model check both cover the power-on-pressed logic
exhaustively, so this is a simulator-fidelity gap rather than a coverage gap.
Closing it needs either a simavr patch preserving IRQ-driven input levels across
reset, or re-establishing the footswitch IRQ drive immediately after each reset —
option two is mechanically feasible in the harness, and the WDT-backstop test
already partially works around it.

**Power-supply ramp-up analysis.** The design assumes clean 5 V at power-on, but
real LDOs with large output capacitors can produce slow-rising VCC (tens of ms).
A slow ramp could let the MCU begin executing before the internal oscillator
stabilises or before the footswitch pull-up reaches a valid logic high. simavr
does not model voltage ramps, but the concern can be addressed indirectly:
(a) clock-prescale and GPIO setup are the first operations in `init()`, so verify
they complete correctly under a bogus initial register state (inject pre-init
register corruption before the firmware starts); (b) confirm by worst-case
analysis that the 64 ms SUT delay covers the LDO ramp (check the LP2950/AP7375
datasheet startup time against 64 ms). Item (b) is a documentation task and pairs
naturally with the Tier 2 datasheet-citation item.

**Standing expected-image-hash regression for PIC10F320.** The merge's
byte-identity gate (`docs/pic10f320_merge_plan.md` §6.13, decision D4) was
deliberately one-shot: it proved twice that the ported XC8 recipe emits the
child project's exact signed bytes, then retired because its baseline lived under
the deleted import prefix. The cost was named at the time and stands:
**nothing at the current tip watches emitted bytes.** The equivalence, lock-step
and actuation lanes assert *behaviour*, and merge-plan §14.2 records the class
they are blind to — the firmware's hardware-integrity checks, where a change is
invisible to every differential lane. Promotion is small and mechanical: check in
`test/pic10f320/expected_images.sha256`, wire it as a `pic320` / `pic320-test-build`
prerequisite, and require any change that moves the hashes to rebaseline it in
the same reviewed commit. The current values are recorded in
`docs/pic10f320_validation.md` §2 (run 2, re-confirmed by the run-3 comment sweep
and by every release manifest since).

Design note: the value is entirely in the *rebaselining discipline*, not the
hashes. A file that gets updated reflexively whenever it fails is worse than
nothing, because it converts a real signal into a chore. Only take this on with
the review rule attached.

Effort: ~1 h. Impact: Medium — restores the only gate that notices *any* change
to emitted bytes, including the defensive-layer class no differential lane sees.

---

## Tier 3 — platinum-level / nice-to-have

**Hardware-validation procedure.** The single largest residual verification gap
is structural: simavr cannot model the ATtiny13a watchdog system reset (only the
tinyx5 family), so the headline WDT-recovery guarantee on the *primary* part is
asserted by analogy, not direct simulation. Document a bench procedure: scope
PB1/PB2, artificially stop the ISR, confirm the device resets to BYPASS within
the WDT window; plus power-on glitch and BOD behaviour. Bridges to the HIL item
below, which is its automated realisation — keep this as the no-rig fallback.

**Inverted-copy (complemented) storage of the debounce context.** The main-loop
sanity gate detects *out-of-range* corruption of `ctx_` (`program_state >
RELEASE_DEBOUNCE_WAIT`, `effect_state > ENGAGED`, `debounce_counter >
RELEASE_THRESH`), but a single-event upset landing *in* range is invisible to it.
Concretely: (a) a `program_state` flip RELEASE_DEBOUNCE_WAIT→PRESS_DEBOUNCE_WAIT
while the lockout counter is still ≥ PRESSED_THRESH causes an **immediate
spurious toggle** — the worst case, audible; (b) an in-range `debounce_counter`
flip (e.g. 3→19, bit 4) can cross PRESSED_THRESH and likewise toggle without a
press; (c) an `effect_state` flip silently inverts the meaning of the next press
(it re-asserts the current physical state, so one press "does nothing"). The
classic hardening is complement storage: keep a second copy with all bits
inverted, update both at every write site, and have the per-tick sanity gate
verify `ctx_ == ~ctx_inv_` byte-wise, forcing the WDT reset (→ safe BYPASS) on
mismatch. Any single bit flip in either copy is then detected within one tick.

Design notes if picked up:
- Keep `bypass_pure.c` untouched — the shadow is shell-owned fault-detection
  mechanics, not algorithm; the pure core and its proofs stay as they are.
- AVR: the ISR writes `debounce_counter` every tick, so a naive 3-byte shadow
  check in main races the ISR (ISR fires between main reading a byte and its
  complement → false mismatch → spurious reset). Two clean options: shadow only
  the two main-loop-owned state bytes (no race by construction; still catches
  cases (a) and (c), and the counter is already range-checked and
  self-correcting); or a full shadow with pair-update in the ISR and a
  read-pair-retry in main (a mismatch is re-read once; only a *persistent*
  mismatch is corruption). Do NOT reach for cli/sei around the check — that would
  break the documented "no interrupts disabled in steady state" invariant.
- PIC10F322: single-threaded polled loop, so a full shadow is trivial — but watch
  the flash budget, which `make pic` gates. RAM cost is +2–3 bytes against ample
  free space on both parts.
- PIC10F320: almost certainly does not fit. Check against its budget before
  promising cross-target parity, and record the omission if it cannot be done.
- Tests: extend both fault-injection suites with an **in-range** flip case
  (simavr t85: flip `effect_state` 0↔1, expect WDT reset; gpsim: same via the
  ctx_ cases, which today deliberately inject only out-of-range values precisely
  because in-range flips are undetectable), plus a mutation ("shadow update
  removed at one write site") proving the suite catches a maintenance slip.

Effort: ~3–6 h incl. tests; firmware edits are the user's. Impact: Medium —
closes the last undetectable single-bit-corruption class in the global state
under the project's cosmic-ray/EMI threat model. This is genuinely platinum:
range checks + WDT already exceed typical practice for this device class, and the
next rung above complement storage (triple modular redundancy) is out of
proportion for a guitar pedal.

**Broader compiler & toolchain portability.** Motivated less by any single MCU
than by two project goals: lowering the barrier for others to adopt/contribute,
and surfacing latent defects that a single compiler can mask
(register-allocation, volatile-ordering, ISR prologue/epilogue, UB that happens
to "work" under one optimizer). Two strands:

- *Modern pure-FSF AVR toolchain.* Build and document a canonical open toolchain
  from stable upstream sources (`binutils` ≥ 2.41, `gcc` ≥ 13 avr target,
  `avr-libc` ≥ 2.2.0 from github.com/avrdudes/avr-libc). avr-libc 2.2.0 has
  **native ATtiny202 support** — no atpack at all — so this both modernizes the
  AVR story and removes the one Microchip-hosted dependency the current ATtiny202
  build accepts. Heavier (a from-source build plus a documented procedure) but
  100% FSF and reproducible; keep it as the escape hatch if the packaged 7.3.0
  toolchain ever blocks a modern device.
- *Multi-compiler CI matrix.* Generalize the narrow cross-compiler item in
  Tier 2.5 into a matrix building the firmware under several open toolchains
  (multiple avr-gcc versions; clang's AVR target where viable) and running the
  full behavioural suite against each, asserting identical results. Each added
  compiler is both an adoption on-ramp and an independent bug-detector.

Effort: Medium (mostly CI plumbing plus a documented from-source build). Impact:
Medium-High — adoption plus a genuine reliability net.

**Hardware-in-the-loop (HIL) validation rig with register-level introspection.**
The simavr (AVR Classic), libgpsim (PIC), and yasimavr (AVR-XT) suites prove the
shells in simulation, but two gaps remain:

- (a) **No cycle-accurate simulator for the AVR-XT target.** yasimavr runs real
  ATtiny202 firmware and is a genuine behavioural simulator, but it executes
  approximately one cycle per instruction with no multi-cycle timing model — so
  busy-wait pulse widths come out at roughly half their real duration, and
  absolute timing has to be recovered from a disassembly oracle rather than
  measured in the simulator. Instruction-level behaviour is covered; cycle-level
  timing is not.
- (b) **No existing test observes internal state on real silicon.** The suites
  assert I/O behaviour, not that the behaviour arises from the intended internal
  trajectory.

A HIL rig closes both: it re-hosts the behavioural suites on real parts and adds
register-level introspection, supporting a claim that the firmware matches its
formal model at the register level on real silicon — which most reference
firmware cannot make.

*On-chip debug reality (verified 2026-07-08).* All three families expose full
internal state (SRAM, registers, I/O) over an on-chip debug interface, but only
in **stop mode** — halt at a breakpoint, then read memory. None of these 8-bit
parts have data trace (continuous non-intrusive streaming while running; that is
a Cortex-M SWO/ITM feature), so internal state is snapshotted at breakpoints,
which perturbs timing. Per family:
- AVR Classic (t13a/x5): debugWIRE (1-wire, over RESET). Open-source host: Bloom
  (https://github.com/bloombloombloom/Bloom) → GDB remote-serial. Full
  SRAM/regs/IO when halted; HW breakpoints. Takes over RESET via the DWEN fuse.
- AVR-XT (ATtiny202): UPDI (1-wire, own pin). Open-source host: Bloom → GDB; its
  Insight view reads all data-space registers, GPIO, RAM/EEPROM and peripherals.
  The 8-pin budget is tight; MPLAB SNAP needs the R48 mod plus a UPDI pull-up.
- PIC10F32x: ICD via ICSP (2-wire). Weakest of the three — needs the bond-out
  debug header (AC244045) for full ICD, and there is no open-source host (MPLAB X
  only), ~1 HW breakpoint. (Ironic: best simulator, worst silicon debug.)

One cheap probe covers the whole fleet: MPLAB SNAP (~$20) speaks debugWIRE,
UPDI, and ICSP; Bloom drives it for the AVR sides and exposes a GDB server
scriptable from Python.

*Two-plane architecture.* Because the firmware is deterministic and tick-driven,
behaviour and internal state are validated over *identical* stimulus in two
passes:
1. Behavioural plane (real-time, non-intrusive): a dedicated driver MCU (an
   RP2040/Pico — PIO gives µs-precise edge generation plus timestamped capture)
   replays footswitch patterns and records LED/relay edges. This is the
   simulation behavioural suite re-hosted in hardware, and the home for the
   flaky/aging-switch models. The host orchestrates in Python and compares output
   timing against the golden model.
2. Introspection plane (stop-mode): SNAP + Bloom + GDB, scripted from Python —
   breakpoint at end-of-tick, dump the context, assert equality with the golden
   model's prediction for that tick. This is `model_step.h` lock-step lifted onto
   real silicon: same golden model, same comparison discipline, substrate changed
   from a simulator's memory to a chip's SRAM over a wire.

Run both planes over bit-identical stimulus; determinism guarantees plane 2
reproduces plane 1, so the internal-state proof and behavioural proof describe
the same run. State matching the model at every tick boundary is the "by design,
not by accident" evidence.

*Caveats to design in.*
- Stop-mode perturbs timing — it is a separate pass, never layered on the
  behavioural run.
- Software breakpoints rewrite flash (wear); prefer the limited HW breakpoints,
  or treat dev parts as consumable.
- Aging switches are partly analog (rising contact resistance, marginal or
  intermittent opens — exactly what the integrator exists to reject). Logic-level
  replay covers the debounce *logic*; testing the analog margin needs an analog
  stage (series MOSFET or digital pot) ahead of the input pin — a dedicated
  sub-tier.
- Prefer stop-mode introspection over a telemetry firmware build: telemetry is a
  different binary (observer effect) and the ATtiny202's 8 pins are nearly all
  spoken for. Stop-mode keeps the shipped binary un-instrumented.
- Determinism boundary: WDT/BOD async events and power-on/reset ramp timing are
  where the two passes could diverge; make the driver MCU the single source of
  truth for reset and input timing.

Effort: large — rough phasing: (1) behavioural plane on one AVR target with the
Pico driver plus Python orchestration (~1–2 days); (2) introspection plane via
Bloom/SNAP/GDB with the `model_step.h` comparator (~1–2 days); (3) aging/analog
switch sub-tier (~1 day plus hardware); (4) generalise across families (~1–2 days
each). Impact: High — enables a register-level "validated against the formal
model on real silicon" claim, and is the primary mitigation for the AVR-XT
cycle-timing gap. All test/rig plus docs work (no firmware-source changes), so it
is outside the firmware-edit-by-user constraint.

**Embedded provenance URL (firmware "comment" in flash).** Embed the project's
GitHub URL as a string constant in the firmware so that someone who reads the
image off an undocumented pedal's MCU and hex-dumps it can find the authoritative
source — the machine-code equivalent of a comment. Deferrable polish; not a bug.

Key constraints (so it actually works for the read-off-the-chip scenario):

- **Must land in a *programmed* (loadable) section**, i.e. end up in the `.hex`
  that gets flashed — not a metadata-only ELF section (`.comment`, `.note`),
  which exists only in the build-host `.elf` and is never written to silicon. On
  AVR that means `PROGMEM` (flash, never copied to RAM); on PIC/XC8 a
  program-memory `const`.
- **Must survive dead-stripping.** The AVR link line uses `-Wl,--gc-sections`, so
  an unreferenced string is collected. The clean modern fix
  `__attribute__((used, retain))` needs GCC 11+; the toolchain is **avr-gcc
  7.3.0**, where `retain` is unavailable and `used` alone does NOT survive
  link-time gc. Robust approach: force a zero-cost reference from `main`, e.g.
  ```c
  const char project_url[] PROGMEM = "github.com/matt-garman/mcu-bypass-firmware";
  /* in main(): keep --gc-sections from dropping the string (emits no real code) */
  __asm__ volatile("" :: "r" (project_url));
  ```
  For PIC, XC8 V3.10 places a `const char[]` in program memory; mark it
  `__attribute__((used))`.
- **Flash budget is the real constraint**, and it decides which parts can carry
  the string at all. On a 14-bit PIC core you cannot pack two characters into one
  word, so readable ASCII costs **one program word per character**. Gate the
  string behind a macro (e.g. `BYPASS_EMBED_URL`) so only parts with headroom
  carry it, and/or use a compact form (bare host/path, no scheme). Consider a
  recognizable leading marker so it is greppable in a dump.
- **PIC10F320 cannot carry a full URL** and likely never will: its three variants
  currently sit at 220/241/244 of 256 words, leaving 36/15/12 free against a
  ~48-character minimum for even a scheme-less repo URL. If the feature ships,
  scope it to the parts with real headroom rather than shortening the URL to
  something that rots. (A third-party shortener trades a space problem for a
  provenance-rot problem — the link dies if the service does.)
- **Verify it reached flash** (not just the ELF):
  ```
  avr-objcopy -O binary build_avr_classic/bypass_relay_t85.elf - | strings | grep github
  ```

Effort: ~1–2 h incl. the `BYPASS_EMBED_URL` Makefile wiring plus a
`strings`-based build check. Firmware source edit is the user's.

**Unified naming scheme across MCU targets and output stages.** Added 2026-07-26
as the deferred half of the PIC10F320 merge (`docs/pic10f320_merge_plan.md` §15).
That merge deliberately took the smallest-change option at every naming fork so
it would not also become a rename project. The debt is real, it is now
*visible in one tree* for the first time, and it should be paid deliberately
rather than drifting further. Four inconsistent axes:

- **Make target prefixes.** ATtiny13a/tinyx5 use bare or suffixed goals (`all`,
  `all13`, `all85`, `size45`); PIC10F322 uses `pic-`; ATtiny202 uses
  `attiny202-`; PIC10F320 adds `pic320-`. So `pic-` silently means "the PIC that
  got here first", which is exactly the near-name hazard the merge plan lists as
  residual risk 7.
- **Makefile variable prefixes.** Three idioms for "which chip": `MCU`,
  `PIC_TAG`/`PIC_*`, `XT_*`, plus the new `PIC320_*`. `PIC_FLASH_WORDS` is the
  cautionary case — a mis-scoped chip variable produces no compile error and no
  failing test, it produces a *passing* one (a 256-word image gated at 512).
- **Release image basenames.** Three conventions coexist: prefix `bypass_` vs
  `bypass_mcu_`; stage tokens `cd4053`/`mute`/`relay` vs
  `cd4053-simple`/`cd4053-mute`/`tq2-relay`; and a part suffix that is
  `_pic10f322`/`_pic10f320`/`_t45`/`_t85` — or *absent*, because a bare
  `bypass_cd4053.hex` is the ATtiny13a image. `bypass_mute_pic10f322.hex` and
  `bypass_mcu_cd4053-mute_pic10f320.hex` name the same output stage on two PIC
  chips. Note the bare-name convention is pre-existing debt, older than either
  PIC.
- **Output-stage vocabulary.** The parent's `VARIANTS` and the PIC10F320's
  variant list describe the same three output stages in different words.

Design notes if picked up:
- This is a **breaking rename of published artifact names**, so it belongs at a
  minor-version boundary with a redirect note in the release documentation and in
  the archived child repository's pointer. Decide first whether historical
  `release/vX/` directories are left alone (recommended — they are signed and
  their `SHA256SUMS` name the files) or reissued.
- `FW_BASE` is the mechanism for the image prefix; the stage tokens come from the
  variant lists. Both are already Makefile-owned, so the canonical product set
  built for the merge (`docs/pic10f320_merge_plan.md` §10) is the natural single
  point of change — do this *after* that set exists, not before.
- Renaming a Makefile variable is an **external interface change**, not an
  internal one: `scripts/make-release.sh` reads Makefile truth through
  `make -s print-<VAR>`. Grep `print-` across `scripts/` and
  `.github/workflows/` as part of any rename.
- Sequence it so the tree is never half-unified — one axis per commit, each with
  its consumers, rather than a sweeping rename that has to be reviewed all at
  once.
- The merge plan's §15 records which asymmetries were knowingly accepted; use it
  as the worklist rather than re-deriving them.

Effort: ~4–8 h, most of it consumer updates and release-documentation redirects
rather than the renames themselves. Impact: Medium — no behavioural change and no
new assurance, but it removes a class of silent-misconfiguration hazard that
grows with every added target, and it is the difference between "five targets in
one repository" and "four projects sharing a Makefile".

**`make program-pic320` convenience target.** Added 2026-07-27. The PIC10F322
has `make program-pic` (`Makefile:1282`, with `PIC_PROG=pk2cmd|ipecmd`,
`PIC_PROG_TOOL`, `PIC_PROG_CMD` overrides); the PIC10F320 has no equivalent, so
`release/README.md` and the generated `MANIFEST.md` print the bare
`pk2cmd -PPIC10F320 -F<image> -M -Y -R` instead. The merge recorded this as a
deliberate omission rather than shipping it unverified
(`docs/pic10f320_merge_plan.md` §15.10): it is ~15 lines modelled on the 322
recipe, but it is hardware-programming surface that **cannot be tested without a
programmer and a part on the bench**, and a wrong programmer invocation aimed at
the wrong device is worse than an honest absence.

Design notes if picked up: mirror `program-pic` exactly rather than inventing a
second idiom, add `PIC320_PROG*` variables under the §5.6 prefix rule (the whole
point of the separate pair is that one chip can be re-pinned without moving the
other), and update the `make help` Hardware block, `release/README.md:145` and
the manifest's flashing command in the same change. Verify against real silicon
before removing the "no convenience target yet" note — the note is currently
correct, and a target that has never driven a programmer is not an improvement
over a command the user can read.

Effort: ~1 h to write, plus bench time. Impact: Low — convenience only; the
documented `pk2cmd` invocation already works.

---

## Tier 4 — out of scope for firmware (name only)

A manufacturer adopting this reference design additionally needs: a professional
schematic (KiCad), a BOM with manufacturer part numbers and approved
substitutes, a hardware production test procedure, and an FMEA. These are outside
the firmware scope; naming them in the design doc as "out of scope / left to the
implementer" is itself evidence of thoroughness.

**Signal-integrity SPICE modeling of the footswitch input network.** Moved here
from Tier 2.5 (2026-07-26): this is hardware analysis, not firmware verification.
The design's EMI/RFI defense includes a hardware filter (TVS, ferrite, 1k series,
22nF to ground, 10k pull-up) with a time constant τ ≈ 18 µs. The firmware's 8 ms
integrator threshold is claimed to be ~80× the hardware filter corner, but that
ratio is an order-of-magnitude estimate, not a simulation. Before a PCB is
ordered, a SPICE transient analysis of the complete input network would verify
(a) that a 5 kV ESD pulse (IEC 61000-4-2 contact discharge) leaves the MCU pin
within absolute maximum ratings and the clamped pulse below Schmitt-trigger
VIL/VIH thresholds, and (b) that a GSM 900 MHz burst coupled onto a 10 cm
twisted pair leaves the filtered envelope above VIH for any burst shorter than
the integration window. Worth doing for whoever builds the board; it validates
the hardware assumptions the firmware relies on, but it is not firmware work and
should not gate firmware releases.

---

## Considered and declined

Recorded so these do not get re-proposed. None are refusals on grounds of
difficulty — each was judged to cost more than it returns *for this project*.

**Formal ISR/main interleaving model (TLA+ or SPIN).** Would formalize the
AVR ISR/main interleaving at the byte level, modeling each byte read/write as a
separate step, to prove all interleavings preserve the safety invariants — the
definitive treatment of the `ctx_` sharing that `test_model_check.c` covers only
at C-statement granularity. Declined as disproportionate: the existing
nondeterministic-scheduling proof plus lock-step co-simulation plus fault
injection already exceed what this device class receives, and the item's own
assessment was "overkill for a project of this size." Reconsider only if a
future shell shares a genuinely multi-byte object across an ISR boundary — the
PIC and AVR-XT shells deliberately do not.

**Property-based testing framework.** Would add rapidcheck-style generators with
biased distributions and automatic shrinking to supplement the hand-rolled
`xorshift32` fuzzing. Declined: the algorithm's state space is *already
exhaustively* proved by `test_model_check.c`'s BFS and by CBMC, so a smarter
random search cannot find a state those miss. It would add a dependency and a
maintenance surface to re-derive what is already proved by construction.

**ISR-timing-jitter stress test.** Would deliberately delay ISR servicing by
random cycle counts to confirm the debounce behaviour is insensitive to jitter.
Declined by its own reasoning: the firmware samples the pin once per
compare-match by design, so the test "would confirm an existing design property
rather than find a new bug." `test_clean_press_phase_jitter` already scatters
footswitch edges across the tick window, which covers the realistic case.

**Interrupt latency measurement in simavr.** Would measure compare-match-to-ISR
entry latency, ISR duration, and interrupt-disabled time per tick. Declined:
confirms an assumption (ISR overhead is negligible against a 1 ms tick at
1.2 MHz) that is not in doubt and whose violation would already surface as a
lock-step co-simulation divergence. The interrupt-free window item in Tier 2.5 is
retained because it guards an invariant a code change could actually break; this
one measures a constant.

**VCD waveform diff across output variants.** Would generate three VCDs from
identical stimulus and diff the LED edges to show variant-consistent behaviour.
Declined: the property is already asserted directly by the per-variant
behavioural tests, and the output is a documentation artifact rather than a gate.
`make trace` remains available for anyone who wants the waveform.

---

## Priority summary

| Item | Tier | Effort | Impact |
|---|---|---|---|
| Design doc: datasheet citations | 2 | 2 h | High — completeness/rigor |
| Formal verification of output drivers | 2.5 | 3–4 h | Medium — driver correctness |
| Formal verification of blocking-delay safety | 2.5 | 1–2 h | Medium — makes the argument explicit |
| Golden-model vs `model_step` cross-validation | 2.5 | 1–2 h | Medium — fourth oracle path |
| Full-path symbolic execution (KLEE) | 2.5 | 2–4 h | High — whole-trajectory proof |
| KLEE in CI | 2.5 | 2 h | Medium — proves the path actually runs |
| Cross-compiler verification | 2.5 | 2 h | Medium — compiler-safety net |
| Compiler optimization sensitivity test | 2.5 | 1 h | Medium — quick win |
| Stack depth cross-verification | 2.5 | 2–3 h | Medium — third independent bound |
| Negative `static_assert` verification | 2.5 | 30 min | Low — build-guard meta-test |
| Clock drift fine-grained sweep | 2.5 | 1 h | Low — narrow but real edge case |
| Stuck-switch long-duration test | 2.5 | 30 min | Medium — enforces documented behaviour |
| WDT pet frequency measurement | 2.5 | 1–2 h | Medium — catches handshake bugs |
| Interrupt-free window measurement | 2.5 | 1 h | Medium — confirms runtime invariant |
| Multi-press boundary cases | 2.5 | 3–4 h | Medium — tick-boundary edge cases |
| Power-on-pressed simulation gap | 2.5 | 1–2 h | Low — simulator fidelity, not coverage |
| Power-supply ramp-up analysis | 2.5 | 2–3 h | Medium — real-world robustness |
| PIC10F320 expected-image-hash regression | 2.5 | 1 h | Medium — restores the only gate watching emitted bytes |
| Hardware-validation procedure doc | 3 | 2–3 h | High — primary-part WDT gap |
| HIL rig: behavioural + register introspection | 3 | 5–8 d | High — silicon-level model validation |
| Inverted-copy (complemented) `ctx_` storage | 3 | 3–6 h | Medium — in-range SEU detection |
| Broader compiler & toolchain portability | 3 | Medium | Medium-High — adoption + reliability |
| Embedded provenance URL | 3 | 1–2 h | Low — provenance polish |
| Unified naming scheme across MCUs | 3 | 4–8 h | Medium — removes a silent-misconfig class |
| `make program-pic320` target | 3 | 1 h + bench | Low — convenience; `pk2cmd` documented |
| Manufacturing artifacts (name as scope) | 4 | — | Completeness signal |
| Signal-integrity SPICE modeling | 4 | 2 h | High for the board, not firmware work |
