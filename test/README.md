# Test suite layout

This document is an **assurance map**. It says which validation layers exist,
what property each one establishes, which substrate can honestly establish it,
and where a layer's guarantee stops. It is deliberately not a mirror of the
suite's implementation: exact fixture inventories, per-lane check counts, and
fake-tool mechanics belong to the executable tests, which are their only
authority. The few exact figures kept here are reviewed release-scope oracles
and are identified as such where they appear.

Test *programs* are grouped by **execution substrate** — what each one runs on
and what it needs to build. Shared shims and analysis config stay at the `test/`
root because every substrate consumes them (the Makefile puts `test/` on the
include path with `-Itest`, so the test programs reference these by bare name
regardless of which subdirectory they live in).

Complete Make and direct release-script invocations hold one worktree-local
`flock` because firmware images, host binaries, coverage data, and simulator
logs are shared. Independent commands wait rather than replacing artifacts used
by another process. The ordinary graph is serial, while reviewed recursive
fan-out targets retain parallelism for isolated per-variant outputs.

## Directory layout

```
test/                 shared shims, host-substrate regressions, analysis config
  host/               MCU-independent golden-model tests, compiled and run natively
  formal/             MCU-independent proofs and exhaustive enumeration
  avr/                Classic AVR (simavr) and ATtiny202 (yasimavr) tests
  pic/                PIC10F322 and PIC12F675 tests plus the shared PIC harness
  pic10f320/          PIC10F320-specific tests (hand-inlined firmware)
```

Everything at the `test/` root falls into one of these roles:

- **Host build shims** every substrate compiles against: `bypass_config_host.h`,
  `bypass_output_host.h`, `model_step.h`, `soak_timing_config.h`,
  `watchdog_budget_compile.c`.
- **Static-analysis configuration**: `misra.json`, `misra_rules.txt`,
  `misra_suppressions.txt` (each deviation maps to a `MISRA_COMPLIANCE.md`
  record), and the fail-closed diagnostic parser `misra_output_gate.py`.
- **Host prerequisite gates** run before anything else: `python_version.py`,
  `host_compiler_version.sh` (GCC 10 or newer, or Clang).
- **Budget and evidence checkers** invoked by build recipes rather than only by
  tests: `check_flash_budget.sh`, `check_pic_data_budget.sh`,
  `check_pic_context_layout.sh`, `check_stack_usage.sh`,
  `check_stack_depth_pic.sh`, `parse_xc8_program_space.sh`.
- **Mutation machinery**: `run_mutation_tests.sh` with its policy resolver,
  accounting helpers, and the shared throwaway-repo builder `scratch_tree.sh`.
- **Structural source contracts** that read the repository itself rather than a
  built image: `source_contract.py` and the `test_*.py` gates built on it.
- **Host-substrate regressions**, one `test_*.sh` or `test_*.py` per aggregate or
  per mechanism, each named after the target it proves.

The substrate directories hold the adapters that cannot be shared:

- `host/` is the independent golden model: it re-implements the documented
  algorithm rather than including the firmware, taking only the thresholds from
  the firmware config through the host shim so it cannot silently drift from the
  real constants.
- `formal/` compiles and links `src/bypass_pure.c` itself — the same file the
  shipping images compile, never a vendored snapshot.
- `avr/` holds the simavr integration, soak and fuse tests, the yasimavr
  ATtiny202 drivers, and `model_step_ffi.*`, a ctypes bridge that lets the
  Python drivers call the shipping pure core so no part of the algorithm is
  re-implemented in Python.
- `pic/` holds both polled-PIC parts because they are shells over the same pure
  core: device-parameterised libgpsim harness cores
  (`test_{fault,lockstep,io,soak}_pic_core.h`), per-part register identity
  (`pic10f32x_regs.h`, `pic12f675_regs.h`), per-part fault matrices kept
  separate from identity because guard *policy* is per-family rather than
  per-register, gpsim CLI wrappers and stimuli, the shared CONFIG-word checker,
  the PIC12F675 calibration-word injector and evidence publishers, and
  `pic12f675_target_counts.sh` — the one reviewed count table the Makefile count
  map, the adapters, and the result producers are all checked against.
- `pic10f320/` is separate because this target's firmware is a single
  hand-inlined translation unit rather than a shell over the shared core, so it
  needs dedicated host harnesses (`equiv/`, `actuation/`, `fault/`) and thin
  target-simulator adapters (`gpsim/`), plus its own return-stack oracle and
  expected-image manifest. "PIC10F320: the constrained target" in
  `DESIGN_DOCUMENTATION.adoc` states why.

The PIC10F320 lane reuses rather than forks everything it can: the shared
CONFIG-word checker, both gpsim CLI wrappers, the shared soak adapter, all four
libgpsim harness cores, and — most importantly — `src/bypass_pure.c` itself.
Thin per-part adapters keep processor/image defaults, output-macro vocabularies,
and each part's guard scope explicit; the guard scopes genuinely differ, so the
adapters state them rather than inheriting a family default.

Build artifacts (compiled binaries, `*.bc`) are written next to their sources in
each subdirectory and are git-ignored; see `.gitignore`. KLEE output directories
are produced at the `test/` root. The `-fstack-usage` `stack_*` evidence uses a
private temporary directory and is removed after each gate run.

## Which lanes run where: the tool contract, not the part

A lane's membership in `make test` is decided by **what it needs, not by which
part it validates**:

- A lane that needs only Bash, Python 3, a host C/C++ compiler and gcov is a
  member of `make test` and runs on every push, whatever toolchains are
  installed. That includes all three `*-coverage-check-fw` shipping-source
  coverage gates and every fake-tool build regression.
- A lane that needs XC8, the PIC device packs, gpsim/libgpsim, Microchip's
  ATtiny_DFP, or the patched `yasimavr` venv skips cleanly when its input is
  absent, which is correct for local development on one substrate.
- A clean skip is fatal in a gate, so CI and release qualification set
  `STRICT_TOOLS=1`, which turns every such skip into a hard failure, and then
  enter through the fail-closed aggregates below, which additionally require
  each lane's explicit completion marker.

Membership by tool contract is a correction, not a convenience: while the
PIC10F322 and PIC12F675 coverage gates were reachable only through aggregates
whose *other* lanes needed XC8 and gpsim, a stale host fault oracle, a
non-shipping compile configuration, and a coverage anchor matching zero lines
all coexisted with a green `make test`. The standalone aggregates still run both
gates, so nothing was moved out of them.

`make test-symbolic-klee` compiles `test_symbolic.c` and the shipping
`src/bypass_pure.c` into separate LLVM bitcode modules, links them with the LLVM
version matching KLEE, and executes only the linked module. The host-only
`test-klee-build` regression pins that two-module flow without requiring KLEE.

The host enumerator and KLEE prove the same complete invariant-valid Cartesian
product: both program states, both effect states, every counter from 0 through
`RELEASE_THRESH`, and both input levels. This includes valid tuples unreachable
from power-on, but deliberately excludes corrupt program-state values and
counters above `RELEASE_THRESH`. CBMC's C2x harness proves fault handling for an
invalid program state; C7 proves integrator contraction and released-input
recovery for an out-of-range counter.

## Classic AVR target validation layers

The ATtiny13A/ATtiny85 lanes run the real firmware ELF in simavr and need no
fetched inputs, so every row below except the long-duration soak is an ordinary
member of `make test`. The soak runs in the mutation lane that needs it and at
full duration in release qualification.

| layer | target | what it proves | substrate |
|---|---|---|---|
| Golden model | `test-host` | The pure core's behaviour against an independently written host model. | host C |
| Formal | `test-cbmc`, `test-model-check`, `test-symbolic[-klee]` | Bounded proof, exhaustive state enumeration, and symbolic execution of the shared core over the invariant-valid state space described above. | CBMC, host BFS, KLEE |
| Register-level functional | `test-sim-attiny13a`, `test-sim-tinyx5` | The real image toggles on debounced press, holds its idle state, handles a switch held through power-on, and drives each variant's output sequence, per variant and per chip. Includes the pet-budget check: the longest measured `wdr`-to-`wdr` interval on the real image must fit the compile-time watchdog budget. | simavr |
| Fault response | `test-fault-inject` | Corrupted MCU state is caught by the sanity gate and recovered through a watchdog reset, run on the tinyx5 family because that is where simavr models the WDT system reset. | simavr |
| Fuse configuration | `test-fuses` | Every target's fuse bytes match design intent. | host parser |
| Liveness soak | `test-soak` | A long run on the ATtiny85, where simavr models the WDT system reset, never resets the device and stays responsive. | simavr |
| Soak watchdog witness | `test-soak-reset-witness` | The soak's `watchdog_failures` counter is release evidence, so a real reset must be able to reach it. The same healthy image is built twice — untouched, and with the tick interrupt disabled mid-run — and the pass/fail pair must come out that way round. The control half is what stops a permanently broken soak from satisfying the failing half on its own. | simavr + host C |
| Static frame bound | `test-stack-bound` | Every fresh `-fstack-usage` frame in the shared core and drivers fits its reviewed byte budget. This is a per-function frame limit, not a whole call-chain high-water measurement. | avr-gcc + host checker |
| Flash budget | `test-flash-budget`; `test-flash-budget-regression` | Every Classic AVR variant's measured image size stays inside its configured percentage of the part's flash, and the complete variant matrix is required before any measurement is accepted. The fake-size regression proves missing, malformed, and partial measurements fail rather than passing unmeasured. | avr-size; host fake tool |

### Simulator fidelity: the classic-AVR footswitch

One harness workaround here answers a **simavr fidelity gap**, not a firmware
behavior. The relay coil clear is a full-`PORTB` read-modify-write, so it
re-asserts PB0's internal pull-up. simavr, left alone, lets that write override
the externally driven footswitch level, and presses stop registering. On real
hardware this cannot happen: a footswitch closed to ground overrides the weak
internal pull-up, and re-writing an already-enabled pull-up is a no-op.

`footsw_set` in `test/avr/test_sim.c` therefore drives the footswitch as a
persistent external pull through simavr's
<!-- name-contract: exempt (AVR_IOCTL_IOPORT_SET_EXTERNAL is a simavr C macro, not a make variable) -->
`AVR_IOCTL_IOPORT_SET_EXTERNAL`, plus an immediate `avr_raise_irq` for
zero-latency edges. The external pull survives PORT writes -- the switch beats
the pull-up, as on hardware -- and the raise avoids the one-tick input latency
the persistent-pull-alone path introduced. The AVR-XT (yasimavr) already models
this faithfully (`set_external_state`), and the PIC gpsim and shadow harnesses
were never affected.

## ATtiny202 (AVR-XT) target validation layers

The AVR-XT lane needs two inputs a normal AVR machine does not have: Microchip's
ATtiny_DFP device files to *build* the image (packaged avr-gcc 7.3.0 predates the
part) and a patched `yasimavr` venv to *run* it (neither simavr nor QEMU models
the AVR8X core). Both are fetched on demand and version pinned, and every
`attiny202-*` target skips cleanly without them.

The split mirrors the PIC lanes: **the host-only rows below are members of
`make test`** and run everywhere; the simulator rows need the fetched inputs.

| layer | target | what it proves | substrate |
|---|---|---|---|
| Image generation | `test-attiny202-build` | Missing, partial, or malformed avr-gcc output cannot become an ATtiny202 image; exactly one valid `Program:` and `Data:` record is required, with the 2048-byte flash and 16-of-128-byte static-RAM limits enforced per variant, and each supported variant pinned to its exact selector/driver pair. | host fake-compiler regression |
| Shell stack frames | `attiny202-test-stack-bound`; `test-stack-bound-regression` | The real AVR-XT shell is compiled once per immutable production variant with shipping flags plus `-fstack-usage`, and every fresh static frame must fit 32 bytes. The host regression pins the routing and rejects missing, malformed, dynamic, stale, extra, and oversized evidence without requiring the DFP. | avr-gcc + ATtiny_DFP; host fake compiler |
| Fuse configuration | `test-fuses` | All seven AVR8X fuse bytes match design intent, and the simulator's descriptor is patched to those exact production values rather than falling back to defaults. | host parser |
| Golden-model bridge | `test-attiny202-model-ffi` | The ctypes bridge reaches the shipping pure core and behaves correctly at the `>=` press-threshold boundary, both saturation bounds, the lock-out, and a full round trip — against independent hard-coded expectations, not another comparison with the model. | host |
| Output-sequence oracle | `test-attiny202-output-oracle` | The PA2/PA3 transition, ordering and pulse-presence checker is itself correct. | host |
| Fault accounting oracle | `test-attiny202-fault-oracle` | The fault driver's run accounting cannot silently under-count injections, latch-only physical-pin handling is rejected, and the reviewed AVR-XT/PIC12F675 emergency register-write order is pinned. | host |
| Coil-pulse width / ISR ceiling | `attiny202-delay-oracle` | The relay and mute delay widths *compiled into the image*, recovered from the disassembled `_delay_ms` loop, match design and clear the datasheet minimum. The sole `reti` handler and its complete direct call tree stay within the reviewed instruction ceiling, bounding the ISR's duty cycle below 25% of the tick; recursion, unresolved or indirect transfers, and cyclic control flow fail closed. | host, over real image |
| Static analysis | `attiny202-analyze` | cppcheck + MISRA run the reviewed AVR-XT rows with real DFP/avr-libc headers: both shell branches, the pure core, and every matching-selector driver. | host tools |
| Register-level functional | `attiny202-sim` | The real image toggles on debounced press, boots dark with the WDT locked and `PORTA.DIR` exact, stays stable at idle, handles a switch held through power-on, and drives the correct PA2/PA3 sequence per variant, including delivered pulse width. | yasimavr |
| Fault response | `attiny202-fault` | Every injected SFR, latch, state and pin-polarity corruption produces the correct response: the sanity gate's force-reset path, a witnessed watchdog reset for the tick timer itself, safe overwrite at the ISR/main persisted-context transaction seams, or relay-coil escalation with modeled PA2/PA3 levels low and OUT/DIR/PINnCTRL canonical before the spin. Zero skips, with exact completion accounting over the whole matrix. | yasimavr |
| Firmware/model lock-step | `attiny202-lockstep` | `ctx_` in simulated SRAM equals the shipping core's state after **every settled tick**, over both boot scenarios, plus LED and settled control-line agreement. Catches a shell defect on the tick it happens rather than as a wrong output later. | yasimavr + host core via ctypes |
<!-- name-contract: exempt (SOAK_RESULT is the driver's stdout token, not a make variable) -->
| Liveness soak | `attiny202-soak` | Over a long run the watchdog never resets the device (GPR0 reset witness), the sanity gate never force-resets, and a periodic 2-press round-trip still toggles. Emits the shared `SOAK_RESULT` release contract. | yasimavr |
| Fail-closed aggregate | `attiny202-test-target` | sim + fault + lock-step across every variant, with no skip permitted. Hosted CI, local CI, and release qualification all use this entry point. | yasimavr |

Mutation coverage for this lane is described under "Mutation testing" below; it
is gated on the same two inputs and by the same probe discipline as the PIC ones.

### Known gaps (AVR-XT — hardware-bench only)

These are properties of the AVR-XT *environment*, not of the firmware, and are
ultimately validated on a real part at the bench.

- **The pinned yasimavr loses cycles when stepped in tiny budgets.** Its
  `SimLoop.run(n)` pins the cycle counter to `first_cycle + n` on return, which
  *rewinds* it whenever the last instruction overshoots — so a caller loses up to
  one instruction's worth of cycles per call, and at `run(1)` every instruction
  is billed exactly 1 cycle. The defect is reported upstream and confirmed, with
  a fix pending release.

  No timing or pulse-width assertion advances that way any more. The output
  tracer free-runs in millisecond budgets and timestamps pin edges from a signal
  hook, the pattern yasimavr's author recommends, so `attiny202-sim` asserts
  pulse *ordering, polarity, exclusion, presence* **and** delivered width. Tick
  timing was never affected: the TCB0 period is counted by the peripheral, not by
  summing instruction cycles, and the debounce and LED tests advance in 1 ms
  budgets where the loss costs under 0.2%. The lock-step driver's edge probes are
  coarser than the loss by a wide enough margin that they cannot step over an
  awake window.

  Delivered width and design width are separate claims, and both are checked.
  `attiny202-delay-oracle` recovers the *compiled* width from the disassembled
  image — a compile-time property, so it is simulator-independent and tighter
  than any trace. The traced width is a few percent longer because the 1 ms tick
  ISR preempts the busy loop, and that overhead is visible only in the trace.

  The fault driver has one deliberate non-timing exception: its persisted-context
  transaction probe uses `run(1)` only to expose every instruction PC and stop at
  an exact function-entry seam. Its bound is an instruction-step count, and all
  behavioural and output observations run afterwards in normal millisecond
  budgets, so no timing claim is derived from those steps.
- **The force-reset spin cannot be observed completing.** The shell's
  unrecoverable path is `cli; for(;;){}`, and yasimavr treats an interrupts-off
  infinite loop as a terminal halt, stopping before the ~256 ms watchdog would
  fire. The fault test therefore asserts the gate *entering* that path (halted
  with PC at the `rjmp .-0` signature); the watchdog physically completing it is
  a hardware guarantee. The liveness-path reset out of sleep *is* observed
  directly.
- **The simulator is patched.** Two upstream yasimavr bugs block this firmware —
  the tinyAVR 0-series builder omits the WDT peripheral entirely, and
  `ArchXT_WDT` maps `WINDOW=OFF` to a 4-clock window, resetting a correctly-petted
  watchdog. Both are carried as vendored patches (reported upstream), so AVR-XT
  dynamic evidence rests on a project-local build rather than a stock tool. The
  functional test doubles as the in-harness regression for the second bug.
- **No complete AVR-XT call-depth bound.** `attiny202-test-stack-bound`
  constrains every AVR-XT shell frame and `test-stack-bound` covers the shared
  core and drivers, but like any `-fstack-usage` gate these are per-function
  frame limits rather than a whole call-chain/interrupt high-water measurement.
- **UPDI programming is untested on silicon.** The `attiny202-program` recipe and
  its fuse writes have not been exercised against a real part.

## Shipping-source coverage (all three PIC parts)

`pic10f322-coverage-check-fw`, `pic12f675-coverage-check-fw`, and
`pic10f320-coverage-check-fw` host-compile the *real* firmware source under
gcov with a per-device mock `<xc.h>`. For the two shell targets that is the PIC
shell, the shared pure core, and all three unmodified output drivers; for the
hand-inlined PIC10F320 it is the single firmware translation unit. They need only Bash, a host C compiler
(GCC 10 or newer, or Clang) and matching gcov, so **all three are members of
`make test`**: the absence of a PIC toolchain does not exempt a PIC change from
this oracle.

The property is **exact**, not a percentage floor: every executable line must be
host-executed except an enumerated, documented allowance. Each allowance is
anchored to the *source text* of the construct it names rather than to a line
number, and locating an anchor is itself fail-closed — text that matches zero
records, or several, fails the gate instead of silently checking nothing. The
live sanity-gate call to `hw_force_wdt_reset()` is a *positive* coverage
requirement, so an allowance cannot hide a harness that never enters the real
reset path. Compilation uses the shipping configuration (including
`BYPASS_CTX_CHECK`), because that is what ships.

The mocks preserve the distinctions the firmware depends on rather than
flattening them. The PIC12F675 mock keeps GPIO intent and physical pin levels
separate, lets an externally driven GP5 survive whole-port writes, shares the
backing bytes that `OPTION_REG`/`nGPPU` and `ADCON0`/`ADON` really share, and
supplies the polled TMR0 subticks in order; runtime checks pin the
implementation-defined host bitfield layout before any of it counts as firmware
evidence. The PIC10F320 lane runs its gate per variant, because the three output
stages compile different numbers of executable lines.

The PIC10F322 and PIC12F675 matrices share an output-driver pulse matrix whose
active-pulse cases record the modeled injection offset, count every post-injection millisecond,
require the injected state to persist through that interval, and require the
modeled outputs to finish low. They explicitly do not claim that an external
output accepts the command, or that mechanical actuation or audio disruption is
prevented.

## PIC target validation layers (PIC10F322 and PIC12F675)

Real-tool PIC lanes are intentionally outside the default AVR `make test` path:
XC8, the PIC10-12Fxxx DFP, gpsim, and libgpsim may be absent on a normal AVR
development machine. The fake-XC8 build regression and the source-coverage gates
are host-only and are included in `make test`; lanes needing external PIC tools
may skip cleanly unless `STRICT_TOOLS=1` is set.

Where a row names one part's target, the other part has the matching target with
the same property and a per-part adapter.

| layer | target | what it proves | substrate |
|---|---|---|---|
| Image generation | `test-pic-build` | Missing, partial, malformed, or non-regular XC8 output cannot become a PIC image; malformed budgets, impossible usage counts, and failed arithmetic tools are rejected; and a skip removes the *complete* product matrix rather than leaving part of it. Each part's producer is required to publish an immutable complete matrix, and stale assembly/symbol sidecars cannot survive a current-HEX-only build. | host fake-XC8 regression |
| XC8 strict parsers | `test-xc8-helpers` | The shared program-space parser accepts one internally consistent XC8 record and rejects missing, malformed, duplicate, mixed, zero, over-capacity, contradictory, and percentage-mismatched transcripts. The shared context resolver requires one non-symlink assembly/symbol pair and exactly one `_ctx_` allocation of the linker's real symbol-table shape, resolved into data memory. | dependency-free Bash/awk fixtures |
| PIC toolchain assertion | `test-pic-toolchain-assert` | The helper shared by hosted and local CI requires both selected XC8/DFP pairs, all three device headers, gpsim, both libgpsim surfaces, GLib metadata, and cppcheck; empty, symlinked, incomplete, duplicate, or unknown requests fail closed. | dependency-free fake toolchain |
| CONFIG word | `pic10f322-test-config`, `pic12f675-test-config` | The XC8-emitted CONFIG word matches the documented oscillator/WDT/BOR/MCLR/LVP intent, per built image. The PIC12F675 table additionally covers CPD and the factory calibration bits it must not disturb. | host parser over HEX |
| Static analysis | `pic10f322-analyze`, `pic12f675-analyze` | cppcheck + MISRA run the reviewed rows for each part with real XC8/DFP headers: shell, pure core, and every matching-selector driver. | host tools |
| Shipping-source coverage | `pic10f322-coverage-check-fw`, `pic12f675-coverage-check-fw` | The exact-line property described above. **Members of `make test`.** | host gcov with PIC SFR mock |
| Register-level functional | `pic10f322-test-gpsim`, `pic12f675-test-gpsim` | The real HEX toggles on press, handles a switch held through power-on, keeps its settled output expectations, and hits the mid-debounce tick-cadence checkpoint. The PIC12F675 scenarios are re-derived for its own stimulus pin and tick, and run the *derived* calibrated image. | gpsim CLI |
| gpsim process gate | `test-gpsim-wrappers` | Both functional wrappers require a positive decimal timeout, reject nonzero or killed gpsim runs even after a complete snapshot, prove a routed stimulus contains exactly one footswitch attachment, and fail rather than skip under `STRICT_TOOLS=1`. Each public lane is probed end-to-end so a severed processor selection cannot leave it simulating another chip. | Bash + fake gpsim |
| Fault response | `pic10f322-test-fault`, `pic12f675-test-fault` | Every guarded direction, output-latch, configuration, pull-up and `ctx_` corruption produces the designed watchdog recovery, injected at the behaviourally identified main-loop `CLRWDT`. Relay variants additionally require both coils de-energized *in one output write* — sampled every instruction, so a two-step clear fails — before the reset spin, and a measured full-width RESET-coil actuation after it, from both a settled BYPASS and a settled ENGAGED start. PIC12F675 also injects through physical pin nodes and its comparator-mode neighborhood, so low GPIO intent cannot masquerade as a de-energized pad, and requires parked GP4 low at the spin. Register identity, injection readback, and the expected per-variant check count are fail-closed test invariants. | libgpsim |
| HEX/model lock-step | `pic10f322-test-lockstep`, `pic12f675-test-lockstep` | Live `_ctx_` SRAM from the XC8-built instruction stream matches the shared pure model after every completed main-loop iteration. The PIC12F675 adapter adds a CLRWDT scan wide enough for this part's loop placement. | libgpsim |
| Target I/O timing | `pic10f322-test-io`, `pic12f675-test-io` | Direction, analog-select, latch and port transitions, relay coil exclusion, and mute/relay pulse widths match the design, measured in simulator cycles. Having no output-latch SFR, the PIC12F675 lane can compare SRAM intent against modeled port state, which the 32x lanes cannot express. | libgpsim |
| Simulator progress regression | `test-lockstep-progress` | Every chip route binds its exact footswitch pin despite substring decoys and aborts a stalled lock-step immediately; a wedged soak must fail bounded, with actual advanced-cycle evidence and no full-duration claim. | host C++ + fake gpsim API |
| Calibration-image derivation | `pic12f675-test-calibration` | The simulator-runnable image is derived by injecting the oscillator calibration word the factory programs, never by touching the shipping HEX; the producer publishes the complete variant matrix as regular files and removes the whole expected set after any failed derivation. | Python + fake XC8 |
| Soak | `pic10f322-test-soak`, `pic12f675-test-soak` | Long-duration libgpsim liveness per output stage, sampled every millisecond so multi-ms holds cannot be stepped over. The PIC12F675 adapter reads the LED from the SRAM shadow, since this part has no output latch to read. | libgpsim |
| Fail-closed aggregate | `pic10f322-test-target-variants`, `pic12f675-test-target-variants` | The complete supported matrix is required first — empty, duplicate, unsupported and incomplete requests are all rejected — then fault, lock-step and target-I/O run for every variant and each must leave its explicit PASS sentinel. | Makefile wrapper |
| Aggregate regression | `test-target-matrix`, `test-target-lane-markers` | Complete matrices run exactly once per variant; empty, duplicate, unsupported and incomplete ones fail before any target invocation. A skipped, crashed, or failing-but-zero-exit lane withholds aggregate success, and the PIC12F675 aggregate requires exactly one canonical terminal machine-result record. | Bash + fake recursive Make |
| Target result producers | `test-pic-target-result-records` | The shared result emitter is compiled for every PIC12F675 variant and must emit its lane record exactly once, outside nested preprocessor conditions, with the counts held by `test/pic/pic12f675_target_counts.sh` — the one reviewed oracle the Makefile count map and the adapters are also checked against. | C++17 host test + Python source contract |
| Fault-evidence watchdog note | `test-fault-wdt-note-contract` | Each libgpsim fault adapter supplies its own per-part watchdog note, and the core's banner call must pass it; required per-part facts must occur inside the macro definition rather than merely in comments, and neither part's facts may leak into the other's. | Python structural source contract |
| Hardware return-stack depth | `pic10f322-test-stack-bound`, `pic10f320-test-stack-bound`, `pic12f675-test-stack-bound` | Bounds the **8-level hardware return stack** — the PIC counterpart of the AVR's byte-valued `test-stack-bound`, and a different quantity: the PIC14 core has no data stack, and hardware-stack overflow on these parts is silent (no `STKPTR`, no `STKOVF`, no overflow reset). The deepest call chain is computed from the freshly generated instruction stream and cross-checked against XC8's own `callstack` directives; missing or stale assembly, recursion, indirect calls, and an over-budget build are rejected. Every variant, all three PIC targets. | XC8-generated `.s` + awk |
| Stack-depth gate regression | `test-stack-bound-pic-regression` | The gate rejects each way the analysis can be wrong — over budget, recursion, an overflowing build, the two oracles disagreeing, unresolvable direct calls, an indirect call, malformed psect ownership, no entry point, a device pack declaring no depth — while still *accepting* the psect scaffolding XC8 really emits. Synthetic, so it needs no toolchain. | Bash + awk |
| Soak rebuild determinism | `test-pic-build-rebuild` | Soak binaries compile their workload sizing in as `-D` flags, so their rules must be unconditionally out of date: a changed duration and an identical rerun must both recompile, with each part's selected image and independently maintained block values reaching the compiler. | Bash + fake XC8/injector/c++ |
| Soak timing/liveness contract | `test-soak-timing` | Native Classic AVR and PIC soaks require the liveness interval to fit inside the total duration, and short release rehearsals are clamped so every passing run completes a responsiveness round-trip. Each part's independent Make timing map must agree with the test-owned values and the firmware constants, with missing, duplicate and malformed values rejected. | host compilers + Python + release CLI |

The build-regression profiles are script-owned and requested by name: Make asks
for the complete named set while the script independently requires each profile
exactly once and rejects empty, unknown, duplicate, or incomplete requests. Each
profile retains an exact final-check contract — 48 PIC10F322, 102 PIC10F320, and
168 PIC12F675 checks — so an incomplete profile or a missing rebuild arm fails
instead of reporting a smaller subset as green.

**A `.stc` checkpoint placed before a stimulus' first transition must keep
asserting the pin.** A PIC12F675 port spike once saw a stimulus declared
`initial_state 1` read *low* at such a checkpoint, while the same firmware with
no stimulus attached read the pin high through the internal pull-up. The spike
tree was not retained, so no root cause is claimed. What replaced the
explanation is a standing check:
`test/pic/pic12f675_footswitch_toggle.stc` declares `initial_state 1`, attaches
to `gpio5`, and breaks at cycle 23040 — 2,560 cycles *before* its first listed
transition at 25600 — where `test/pic/run_gpsim_test.sh` asserts `GP5 == 1`
outright on all three variants. The checkpoint sits inside the disputed window
rather than dodging it, so if the behaviour ever returns the failure is that
assertion going red rather than a silently relocated checkpoint. The libgpsim
harnesses drive through `set_Vth` with a low `Zth` and would not reach this at
all; it is a CLI-lane rule.

## PIC10F320 target validation layers

The PIC10F320 is the one target whose verified core is *hand-inlined* into the
firmware instead of compiled in, so it carries validation layers no other target
needs. "PIC10F320: the constrained target" in `DESIGN_DOCUMENTATION.adoc` states
*why* the target needs a different assurance route and what that route does and
does not establish; the retained record under `release/<version>/` holds what
was run and what it returned for a released version; this section is the current
layer inventory.

The first four layers need only a host C compiler and gcov, so they are members
of `make test` and run on every push whether or not XC8 is installed, as are the
dependency-free Python selftests of the return-stack oracle and the
expected-image checker. The real-image layers behave like the PIC10F322 lanes
above, except that the expected-image and return-stack targets are always
fail-closed rather than skip-clean.

| layer | target | what it proves | substrate |
|---|---|---|---|
| Firmware↔core equivalence | `pic10f320-test-equiv` | The real firmware, host-compiled, stepped tick-for-tick against `src/bypass_pure.c` over the complete reachable model state space with zero divergence. This is the layer that closes the inlining seam. | host C |
| Actuation sequence | `pic10f320-test-actuation` | Each variant's full *settled* `LATA` at every tick, plus the mute/relay mid-actuation sequencing and pulse width that a settled snapshot cannot see. | host C |
| Host fault injection | `pic10f320-test-fault-host` | Corrupting a guarded SFR or the debounce context forces the sanity gate onto the watchdog-reset path. The relay variant additionally injects each coil-latch bit and requires both coils de-energized *in one `LATA` write* — the mock routes every firmware `LATA` access through the harness, so a clear that shed the coil bits separately is caught with one still driven. | host C |
| Shipping-source coverage | `pic10f320-coverage-check-fw` | The exact-line coverage property, run per variant because the three output stages compile different numbers of executable lines. | host gcov with the mock `xc.h` |
| All-variant host aggregate | `pic10f320-test-host-variants` | The four layers above across all three variants, with the complete supported matrix required first. **This is the member of `make test`.** | Makefile wrapper |
| Return-stack oracle regression | `test-pic10f320-return-stack-oracle` | The oracle's own decisions: passing depths through 8, recursion and depth-9 rejection, skip edges and operand boundaries, every legality decision in the classic instruction space, destination writers against PCL/INDF/INTCON, 9-bit PC and physical-fetch aliasing, literal HEX layout, and fail-closed parser and file handling. Device geometry is part of the contract: fixtures whose verdict *differs* between the 256- and 512-word geometries pin the fetch alias in both directions. | dependency-free Python 3 |
| Expected image bytes | `test-pic10f320-expected-images`; `pic10f320-test-build` | The dependency-free checker pins the manifest grammar and fail-closed file handling in `make test`; the full-tool target rebuilds the immutable three-variant matrix and compares each raw HEX with the reviewed XC8/DFP SHA-256 baseline. Kept out of mutation kill targets so a broad byte mismatch cannot mask a weak behavioural oracle. | Python 3; pinned XC8/DFP for the real comparison |
| CONFIG word | `pic10f320-test-config` | The emitted CONFIG word matches design intent over every built image, through the shared checker with a device-accurate label. | host parser over HEX |
| Hardware return stack | every `pic10f320` build; `pic10f320-test-return-stack` | The base build strictly parses and traverses its final HEX before marking the image complete, so gpsim, target, soak and release rebuilds all inherit the same fail-closed gate. The explicit target rebuilds the supported matrix and rechecks all three together, reporting each maximum and witness. | dependency-free Python 3 over final HEX |
| Static analysis | `pic10f320-analyze` | One invocation runs cppcheck + MISRA over all three explicit shell rows, each selecting a different source branch. | host tools |
| Register-level functional | `pic10f320-test-gpsim` | The real HEX toggles on press and handles a power-on-held switch, through the shared wrappers with this chip's processor and toggle-cadence stimulus. | gpsim CLI |
| Fault response | `pic10f320-test-fault-target` | The host fault argument re-made on the real emitted image: every guarded SFR/SRAM location and required `TRISA` direction, plus a negative control proving the documented *unguarded* RA0 LED latch does not reset, plus the relay coil injections at the reviewed trailing-`CLRWDT` seam from both BYPASS and ENGAGED, each requiring de-energization in one write, exactly one reset, and a recovery RESET-coil pulse of at least the datasheet minimum. | libgpsim |
| HEX/model lock-step | `pic10f320-test-lockstep` | Live `_ctx_` SRAM from the XC8-built instruction stream matches `src/bypass_pure.c` after every completed main-loop iteration, over the complete reachable state space. | libgpsim |
| Target I/O timing | `pic10f320-test-io` | Exact `TRISA`, modeled `PORTA` following every `LATA` transition, each variant's complete transition sequence, and mute/relay pulse widths from simulator cycles. | libgpsim |
| Fail-closed aggregate | `pic10f320-test-target-variants` | Rejects any matrix other than the complete supported set, then requires fault, lock-step and target-I/O PASS sentinels for every variant. | Makefile wrapper |
| Pre-hardware aggregate | `pic10f320-test` | The single target CI and the release script invoke: the host aggregate, expected-image hash, CONFIG and return-stack proof over all images, one complete analysis matrix, and gpsim per variant. | Makefile wrapper |
| Soak | `pic10f320-test-soak` | Long-duration libgpsim soak per output stage; three combinations at full duration are part of release qualification. | libgpsim |

Note what `pic10f320-test-equiv` and `pic10f320-test-lockstep` run *against*.
Both compile and link `src/bypass_pure.c` — the same file every other target
compiles into its shipping image, not a vendored snapshot of it. That is the
property the whole layer stack rests on; "PIC10F320: the constrained target" in
`DESIGN_DOCUMENTATION.adoc` argues why.

`return_stack_oracle.py` does not consume a compiler listing or trust a
disassembler. It requires a nonempty, non-symlink regular file, validates every
Intel HEX record and address, forms PIC14 words, and then walks control flow:
CONFIG and other unreachable data are ignored, but an absent byte on a reachable
instruction is a hard failure, as is a return taken with an empty stack.
Reachable `RETFIE`, direct PCL writes, writes through `INDF` whose FSR-selected
destination could be PCL, and writes that could enable `INTCON.GIE` are rejected
rather than guessed. The depth limit is immutably eight. PIC10F320 control state
has a 9-bit architectural PC, so the oracle normalizes direct targets,
sequential and skip successors, and pushed and popped return PCs into the
architectural space, and only instruction *fetch* aliases into the implemented
physical words. This is execution-time enforcement, not a claim that a later
staged or copied artifact cannot be modified; release provenance and
reproduction checks remain separate controls.

## Release and supply-chain gates

These lanes validate the release machinery itself rather than a firmware image.
They are host-only fake-tool regressions unless stated otherwise, so they run in
`make test`.

| layer | target | what it proves | substrate |
|---|---|---|---|
| Release image reproduction | `test-release-images` | Committed images, `SHA256SUMS`, and fresh builds must each match the Makefile's canonical image set before byte reproduction is accepted. Production pins the repository Makefile and ignores inherited overrides, Make flags, command-line assignments, environment precedence, and injected makefiles. The canonical set is itself held to an `override` identity pin computed from disjoint inputs: a set wider or narrower than the pin, or an empty pin, is rejected, while the same members in another order are not drift. | Bash + synthetic Makefiles |
| Release provenance contract | `test-release-provenance` | Final images are rechecked immediately before staging, including a HEX digest regenerated from the validated ELFs and a post-copy comparison that dominates `SHA256SUMS`. Tag CI snapshots clean-build image paths, requires four-way reproduction against the committed files, checksums and canonical set, then freezes the image/helper/metadata inventory before later gates run. The publication shell rechecks the remote tag, inventory digest, detached signature and strict checksums immediately before publishing, so synthetic additions, mutations, missing helpers and failed checks cannot reach it. | Bash + fake git/gh |
| Release qualification contract | `test-release-qualification` | Publication requires clean production metadata, the exact canonical 35-file evidence set, source-bound hashed resource evidence, one complete PIC12F675 image matrix bound to the released HEX and checksums, and one identity-, duration- and counter-bearing result for each of 18 release soak combinations. Both publishable modes are told apart: `production` keeps its 24-hour floor and `express` its 1-hour floor, and each is rejected if it carries the other's manifest banner or none at all, so the recorded mode and the human-readable document can never disagree. The rendered validation prose is held to its substrate claim in both directions: the signed `MANIFEST.md` is published verbatim as the release body, so its simulator lanes must be called modeled-pin checks and may not claim physical output evidence. The regression also preserves the historical 28-file/15-soak boundary for v0.9.6-v0.9.8. | Bash + Python + synthetic retained evidence |
| Release preflight contract | `test-release-preflight` | The real release step 0 reaches its final executable-version probe without cleaning, building, staging, or changing tracked worktree content. A versioned run first requires one nonempty dated changelog section, exact comparison links, and one bounded current-release declaration -- in `release/README.md` and nowhere else -- that agrees with the canonical image/soak inventory and part/shell topology; malformed bounds and stale exact fields fail before release scratch is created, while historical prose outside the bounds stays valid. A second declaration in any other current document is refused by name, including one that happens to agree; shipped release directories and declared branch-only working documents are not copies to maintain and are exempt. A bounded declaration may not claim retained evidence the tree does not contain. The gate's own baseline is hermetic: inherited build-input names are cleared once before the first case, so a caller that exports one cannot turn the clean-configuration control into a refusal. | Bash + fake toolchain |
| Release history and signature | `test-release-history` | The tag event must peel to an artifact-only, single-parent child of the exact qualified source. `SHA256SUMS.asc` and the remote annotated tag must verify against the pinned full-fingerprint key in an isolated keyring; altered bytes, missing or wrong-key signatures, lightweight, unsigned, replaced and moved tags are rejected immediately before publication. The frozen publication oracle binds an exact expected asset set to descriptor-read identities, sizes and digests, so every mutation, addition, removal, rename, unsafe name, symlink and ordering drift fails closed. | scratch Git + fake gh |
| Published release immutability | `test-published-release-immutability` | A published release is what its recipients already hold, so the copy under `release/` is the same object rather than a draft of it. Every release's own `SHA256SUMS` is re-verified, so offline integrity is checked rather than assumed from having held once. The 361 published files no release signs -- the evidence logs, `QUALIFICATION`, the manifests and the detached signatures themselves, none of them rebuildable from source -- are held to `published_release_digests.txt`, an ordinary `sha256sum -c` file so the central claim reproduces with coreutils alone. The two lists must partition each directory exactly, so a file added to a published release is covered by one or the other and never by neither, and no image can drop out of the signed list into the merely-recorded one. Where the clone has tags, each tag tree is compared directly: an edit that updates both of this tree's lists to agree with itself is still caught. The one amendment ever made to a published release, the v0.9.0-v0.9.2 TMUX polarity errata, is registered with its reason, the markers that must survive in it, the anchor it sends the reader to, and the check that it touched no file any verifier reads. | Python + Git tags where present |
| PIC12F675 flashing helper | `test-pic12f675-flash-helper` | The release-shipped `scripts/flash-pic12f675.py` is driven against a stateful fake programmer whose device memory persists across invocations. The accepted transaction is exactly version probe, baseline read, immediate re-read, durable reservation, one write, final read, and every fail-closed precondition is driven individually and must reach no write vector at all: an image absent from or mismatching the signed checksums, a missing manifest or signature, an unreleased or symlinked image, an image that would program the calibration word or write EEPROM, and a device whose identity or trim does not match its baseline. | Python + stateful fake programmer |
| yasimavr venv fetch safety | `test-fetch-yasimavr` | Caller-selected destinations are canonicalized and cannot name roots, symlinks, files, or unstamped directories. Offline fake tools prove a failed build preserves the old owned venv and that only a fully verified sibling tree is renamed into place. | Bash + synthetic toolchain |
| External supply-chain integrity | `test-supply-chain` | XC8 and PIC DFP bytes must match reviewed hashes before any privileged install, installation must produce all three required device headers, restored ATtiny_DFP files are re-hashed, yasimavr dependencies are wheel- and hash-locked and built without dependency resolution, and both workflows use one installer with hash-sensitive cache keys. The cache manifest is produced by separately status-checked stages, so a scan, ordering or hashing failure is reported by name instead of being masked by the stage after it, and hostile filenames must survive inventory, comparison and tamper detection. | Bash + fixtures |

The release-input coverage of the image and preflight rows extends to Make
itself: the real Makefile rejects direct source and flag assignments for every
build family, ordinary and `-e` environment precedence for release validation
controls, assignment-bearing `MAKEFLAGS`/`GNUMAKEFLAGS`, `--eval`, dollar-bearing
values, noncanonical or injected makefiles, and a lock marker without its
inherited locked descriptor, before the release recipe runs.

## Release test-long evidence

The complete `make test-long` transcript is transient diagnostic output and is
not part of the retained release inventory. The release producer writes
`test-long.summary.txt` only after the aggregate succeeds, with one exact
`TEST_LONG_RESULT` record naming the qualified source, `test-long`, strict tools,
and the no-skip mutation policy. The qualification verifier rejects a missing,
duplicate, failed, or wrong-source record. Tag CI reruns the aggregate
independently, but its hosted job log is not treated as durable release evidence.

## Repository and structural contracts

These gates read the repository — Makefile, documents, workflows, sources —
rather than a built image. They need no toolchain and are members of `make test`.

| target | what it proves |
|---|---|
| `test-makefile-name-contract` | Every make goal and variable a file or document names is one the Makefile really defines, and every variable assignment a recipe passes to a child is one that child still reads. Checked from the moment a file exists rather than from the commit after. |
| `test-todo-index` | `TODO.md`'s priority summary and its open sections index each other both ways, with each ID's tier prefix agreeing with the tier it is filed under. |
| `test-resource-tables` | Every image the tree has already built measures at or below the reviewed ceiling its own build gate enforces, and no reviewed ceiling is wider than the silicon it bounds. The ceilings are read from the Makefile that declares them, so no document has to restate a measurement to keep this gate honest. The release-only strict mode additionally requires the complete released image set plus retained RAM and stack evidence, with every record checked against its own arithmetic and against the limit it reports, bound to the source HEAD. |
| `test-pinout-alignment` | Every ASCII package-pinout diagram draws a square box: each row's walls sit in the columns the corner rows put them in. |
| `test-static-assert-guards` | Every modular shell carries an anchored, uncommented direct include of the shared compile-time checks, and those guards fail the build when their inputs are broken. Near-bound fixtures pin the watchdog pet-to-pet budget to its exact millisecond, convert wall-time ISR duty independently, prove the ISR, tick and loop terms are all load-bearing, and reject the former mixed formula. Its census counts every guard in every MCU shell, including the ones only a target toolchain can compile, so a deleted guard is reported on a host that has no XC8. |
| `test-attiny202-guard-mutations` | The ATtiny202 shell's own pin ordinals, enum widths, tick derivation, clock and watchdog budget fail the build when broken -- under avr-gcc with the vendored device pack, because the pin asserts read `<avr/io.h>` and the budget is computed from that part's floor, tick and ISR duty. Losing the part selector is caught rather than silently taken for a classic AVR. |
| `test-pic-guard-mutations` | The same proof for the PIC10F322, PIC12F675 and self-contained PIC10F320 shells under XC8: pin ordinals against the device pack, the GP3/GP4 spare-pin family, `_XTAL_FREQ`, the PIC10F320's duplicated threshold invariants and branch-local pin guards, and each part's watchdog budget pinned to its exact millisecond. Configurations the firmware still accepts in silence are recorded here too, so the guard that closes one has to be proven load-bearing when it lands. |
| `test-deliberate-duplication` | The register of duplications that are second opinions rather than untidiness, and the structural witness for each: the self-contained PIC10F320 shell reaches no header this tree owns, every part states its own pin ordinals and its own four watchdog terms as literals, each shell owns its main loop, the AVR shells stay interrupt-driven and the PIC shells polled, the clock is only ever tested by the firmware and never supplied by it, the PIC harnesses keep their register facts literal, both PIC return-stack witnesses read different artifacts, and every verification layer is still wired to a subject of its own. Lexical, so it reports a fold on any host. |
| `test-fuse-injection-contract` | Every fuse byte the Makefile burns is the byte the `-D`-injected checker verifies; stdout alone carries queried values, while stderr is retained as diagnostic context. |
| `test-variant-map-contract` | Every per-variant map is guard-registered, so a new variant cannot be half-declared. |
| `test-variant-selector-guard` | Every lane rejects a bad single-variant selector instead of reporting a missing tool. |
| `test-analyze-variant-guard` | The `analyze-*` targets reject a bad `VARIANTS=` request instead of silently analyzing less. |
| `test-clean-contract` | `clean` and `clean-tests` remove everything the Makefile knows how to build. |
| `test-workflow-syntax` | The GitHub workflow YAML parses, and its job map and per-part PIC lanes agree with `ci-local`. |
| `test-ci-local-routing` | Local CI routes each skip option to the commands it claims to run. |
| `test-build-serialization` | Independent top-level Make and release invocations sharing one worktree cannot enter the shared critical section concurrently. |
| `test-strict-tools` | The skip-versus-strict policy holds for the host lanes and all three PIC parts, so `STRICT_TOOLS=1` really converts every clean skip into a failure. |
| `test-avr-program-order` | Every AVR `*-program` goal builds and validates its image before the first programmer invocation, then writes fuses before flash. |
| `test-avr-build-rebuild` | Modular-header dependencies and Classic AVR configuration changes invalidate what they must. |
| `test-workload-rebuild` | Workload and fuse changes retrigger the builds that depend on them. |
| `test-pic10f320-coverage-archive` | The PIC10F320 coverage gate still runs from an extracted source archive with no Git index, where file modes rather than the index decide what is executable. |

## Static analysis matrix

Cppcheck and MISRA execute the same reviewed semantic rows. The rows are
declared as immutable `ANALYSIS_*_ROWS` tuples in the Makefile — a tuple is
`source:selector` — deliberately without expanding the caller-overridable build
maps, so analysis identity cannot move under a development compile override.
Modular profiles include the shell, the pure core, and every matching-selector
driver; AVR-XT and PIC12F675 add a second shell row for their relay-only
emergency path. The analyzer platform stays profile-specific: `avr8`,
`pic8-enhanced`, or `pic8`.

`make test-analysis-matrix` drives every public plain and MISRA target through a
fake cppcheck with synthetic device-pack headers and records argument
boundaries. Its test-owned oracle requires each reviewed invocation exactly once,
with one shipping source, one selector, one platform, C11 analyzer mode, the
correct target defines, and the MISRA template, addon and suppression arguments
only in MISRA mode. Negative fixtures remove and duplicate rows, swap platform
and standard policy, and mix selectors or sources. This complements the output
gate below: the matrix test proves *what ran*, while the output contract proves
*how findings fail*.

## MISRA output contract

`make test-misra-output-contract` closes a cppcheck 2.13.0 status gap: a
diagnostic attributed to an included header is printed without affecting
`--error-exitcode`. Every MISRA recipe therefore requests one strict record
format and passes its captured stderr to `misra_output_gate.py`, which
normalizes paths and fails unwaived diagnostics in authored `src/*.c` and
`src/*.h` files. Malformed stderr and nonzero tool status fail as infrastructure
defects; adopted toolchain, `third_party/`, and test paths remain outside the
firmware compliance boundary. Unattributed pseudo-path diagnostics also fail,
because they have not been shown to belong to adopted code.

The host-only regression exercises the parser directly and then drives every
lane's recipe with fake device-pack headers and a fake cppcheck. A zero-exit
Required-rule finding in an authored header must fail all of them; an exact
`rule:file` suppression must restore success while a right-rule/wrong-header
suppression must not; and a rule census and severed-call fixture keep every
recipe attached to the parser. Invocation-wide `misra-config` suppression is
rejected, and the committed suppression inventory is pinned to the PIC shell
source paths it is scoped to.

## Mutation testing and skipped optional tools

`make test-mutation` includes PIC mutants whose kill targets need XC8, gpsim and
libgpsim, plus ATtiny202 mutants whose kill targets need the vendored ATtiny_DFP
and the patched yasimavr venv. A local host without those tools may run an
explicitly partial suite with `MUTATION_ALLOW_SKIP=1`; that is the non-strict
default so development on one substrate stays practical. Selective partial runs
use `MUTATION_ALLOW_SKIP=PIC`, `ATtiny202`, or the canonical combined value
`PIC,ATtiny202`. `STRICT_TOOLS=1` changes the default to fail closed, and
full-tool CI also pins `MUTATION_ALLOW_SKIP=0`. An explicit value takes
precedence: `ci-local.sh --skip-pic` authorizes only PIC mutation skips and
`--skip-attiny202` only ATtiny202 skips, so skipping one toolchain cannot hide
loss of the other substrate. The summary counts each substrate's skips
separately, so a partial run always says which substrate went unexercised rather
than reporting one anonymous number.

Normal hosted CI runs mutation exactly once on push, schedule and manual
dispatch: the fully provisioned PIC job invokes `make test-mutation` with
`STRICT_TOOLS=1 MUTATION_ALLOW_SKIP=0`. After it passes, `make stress` runs every
shared gate with the FULL workload definitions but does not repeat the mutation
driver. `make test-long` remains the FULL-plus-mutation aggregate used by release
qualification and by `ci-local.sh`.

Mutants are grouped by **what a kill needs, not by what the fault is about**.
Host-killable mutants ride with the unskippable core batch; tool-dependent ones
sit behind their own probe, which first verifies every distinct kill command
against the *unmutated* tree. Without that split the tool-dependent mutants would
"survive" on any host lacking the toolchain; without the per-command baselines, a
broken simulator could make them die for an infrastructure reason and falsely
count as killed. Skip accounting runs through the same policy resolver, so a
partial run cannot be mistaken for full coverage.

Kill credit is stricter than an ordinary nonzero Make status. Each row names the
exact assertion, injection, divergence, timing minimum or reset signature that
must appear. A failed compile, timeout, missing completion record, or checker
failure without that named signature is an *error*, not a kill. Tool absence may
still produce an explicitly partial run; a failed unmutated baseline may not.

Kill targets are assigned by what each fault actually perturbs, and that
assignment is load-bearing — a defeated PIC12F675 comparator guard survives if
it is moved to the gpsim CLI lane. The same reasoning maps an inverted LED or
control pin to `attiny202-sim`, a dropped `ctx_` write-back to
`attiny202-lockstep`, a defeated SFR, direction or pull-up guard to
`attiny202-fault`, a missing WDT pet or broken ISR handshake to `attiny202-soak`,
and a shortened coil pulse to `attiny202-delay-oracle`, the AVR-XT's tightest
absolute-width witness because it recovers the compiled width from the image
rather than timing a trace. The PIC12F675 set likewise targets what that part has
and the 10F32x parts do not: the SRAM output shadow, the software sub-tick
counter standing in for the period register it lacks, the comparator and
OSCCAL-trim guards, and ANSEL's off-by-one mapping.

**Which lane owns the Classic AVR watchdog matters, and is easy to get wrong.**
The two long-standing watchdog-handshake mutants both run on an ATtiny13a build,
and simavr 1.6 does not model the ATtiny13a WDT system reset at all, so no
assertion on that lane can witness one. They are still killed, but not by the
watchdog: deleting the `hw_wdt_pet()` call site leaves the function unused and
fails the build under `-Werror=unused-function`, and breaking the ISR handshake
stops the debounce state machine so the functional, noise-count and lock-step
assertions all fail. The behavioural watchdog fault therefore has its own mutant,
which empties `hw_wdt_pet()` at its definition — so the call site remains and the
build stays clean — and runs a short `test-soak` on the ATtiny85, where simavr
*does* model the reset and the soak's reset witness records it.

The driver independently pins its mutation category inventory before probing,
rejects category drift, and then requires dispatched + skipped to equal that
inventory and killed + survived + errored to equal dispatched. Every worker
status is checked; results are atomically published and accepted only with exact
text grammar and no missing, hidden, or extra artifacts. Bounded checkers own
registered process sessions, so both normal and interrupted-run cleanup reach
nested timeout groups as well as Make, compiler and simulator descendants. The
host-only `test-mutation-sandbox` regression exercises all of that in `make
test`: inventory and conservation, record and command parsing, atomic
publication, checker-status classification, behavioural signatures, source
substitutions, baseline reasons, timeout validation, and process cleanup.

One further note on the driver, learned the hard way: its sandbox tree copy is
`test/scratch_tree.sh`, shared with `test/test_pic_rebuild.sh`. The two used to
learn about a new file by different means — an extension allowlist walk versus a
hand-enumerated prerequisite list — and one prerequisite added to the PIC soak
rules broke each of them in turn. The walk is now the single mechanism, so a new
substrate, a nested harness, or a target that gains a prerequisite needs no edit
in either. Two properties of the walk are load-bearing and documented at length
in the file: it stays an **allowlist** (a wholesale `cp -a test/` would drag in
build products, and `cp -a` preserves mtimes, so a stale binary copied in newer
than its source makes Make skip the rebuild and score a mutant against unmutated
code), and it must never require a **Git repository**, because these sandboxes
have no `.git`.

**The ATtiny202 lane carries one extra hazard.** `XT_DFP` and `YASIMAVR_VENV`
both default to paths *relative* to the tree, which is exactly wrong inside a
sandbox: `make -C "$work"` would resolve them under the sandbox, find nothing,
and every `attiny202-*` target would skip cleanly with status 0 — scored as a
survivor for every mutant in the lane. The driver therefore passes both in as
absolute paths, sharing the read-only toolchain while keeping sources sandboxed,
and the probe refuses to enable the lane unless both resolve *and* each distinct
kill target passes on the unmutated sandbox.

## Known gaps (PIC — hardware-bench only)

### PIC10F32x hardware gaps

These are properties of the PIC10F322/PIC10F320 builds that their shared
gpsim-based simulation cannot faithfully assert; they are ultimately validated
on real chips at the bench.

They apply to **both PIC10F32x targets — PIC10F322 and PIC10F320 — equally**,
because they are properties of the shared gpsim environment rather than of
either firmware: same TMR2, same datasheet family, same simulator. Neither
chip's lanes are more or less exposed than the other's, and a gap closed here is
closed for both.

- **WDT-timing / brown-out behaviour** is not simulated. gpsim's WDT calibration
  differs from silicon — at the firmware's `WDTPS = 0x08` gpsim's period is
  ~1.06 s versus the silicon ~256 ms — and gpsim has no analog BOR model.
  `make pic10f322-test-config` proves `WDTE`/`BOREN` are *enabled*; their
  real-time behaviour is a bench concern. `make pic10f322-test-soak` exercises
  WDT *liveness* and periodic responsiveness at scale, but asserts nothing about
  WDT *timing* — it uses the WDT only as a qualitative liveness signal. This is
  distinct from the **1 ms TMR2 tick cadence**: gpsim models the tick for the
  firmware's *current* prescale (`T2CKPS = 0b01` = 1:4 at 2 MHz), which the
  mid-debounce checkpoint exercises, but the *absolute* tick period on silicon is
  itself a bench-only guarantee (next bullet).
- **TMR2 prescaler *select* is not faithfully modelled by gpsim.** gpsim clamps
  `T2CKPS = 0b11` to a 1:16 prescale instead of the datasheet's 1:64
  (`0b00`/`0b01`/`0b10` → `1:1`/`1:4`/`1:16` are modelled correctly; only the top
  code is wrong). The firmware uses `0b01` (1:4 at 2 MHz), which gpsim gets right,
  so the current build's 1 ms tick *is* faithfully simulated — but gpsim cannot
  independently catch a wrong prescale *select*, because a `0b11` (1:64 → 4 ms)
  configuration still reads as 1 ms in the sim. This is exactly what let an
  earlier 1:64 selection slip through on both builds until it was caught by
  cross-checking the programmed register value against the datasheet. The host
  equivalence and model layers are tick-*counted*, so they are period-agnostic by
  construction and cannot catch it either. As with WDT timing, the *absolute*
  1 ms tick period on silicon is a hardware-bench guarantee.
- **Real-silicon pulse timing remains bench-only.** The target-I/O gate measures
  the XC8-generated busy-wait duration in gpsim instruction cycles, so it
  verifies the programmed delays (the CD4053 mute window and the TQ2 relay coil
  pulse) at nominal configured FOSC and nothing more. It cannot validate
  HFINTOSC tolerance over voltage and temperature, output rise/fall time,
  relay-coil current, or analog-switch mute settling on physical hardware.

### PIC12F675 hardware gaps

PIC12F675 has distinct silicon-only risks rather than the PIC10F32x TMR2/family
details above. Its guarded programming workflow detects and records OSCCAL and
`BG<1:0>` changes but cannot prove that a real programmer preserves either; the
pk2cmd and ipecmd hardware routes remain unvalidated on silicon. Simulator lanes
qualify its 1.024 ms TMR0 cadence, qualitative WDT reset and liveness, and
nominal output pulse widths; real WDT timing, analog BOD behaviour, and the
loaded-board GP2 Schmitt-trigger readback margin require measurement. These are
items 1, 2, 8 and 9 of `TODO.md` `T3-pic12f675-bench`, tracked for the
`1.x.y` hardware pass. As on PIC10F32x, target-I/O cycle measurements do not
replace real-silicon pulse or peripheral-load measurements.
