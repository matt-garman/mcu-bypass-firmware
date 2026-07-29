# Test suite layout

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

```
test/
  bypass_config_host.h      shared: firmware config (RELEASE_THRESH, …) for host builds
  bypass_output_host.h      shared: output-driver host shim
  model_step.h              shared: delegates to the real bypass_pure.c logic
  misra.json                shared: cppcheck MISRA addon config
  misra_rules.txt           shared: MISRA rule paraphrases
  misra_suppressions.txt    shared: documented per-file MISRA deviations
  mutation_policy.sh        shared: strict/partial mutation policy resolver
  mutation_accounting.sh    shared: mutation inventory/result accounting helpers
  run_mutation_tests.sh     shared: mutation-testing driver (make test-mutation)
  soak_timing_config.h      shared: native soak timing bounds
  check_flash_budget.sh     shared: exact flash-budget checker
  check_stack_depth_pic.sh  shared: PIC hardware return-stack depth gate
  test_attiny202_build.sh   shared: fail-closed AVR-XT build checks
  test_avr_build_rebuild.sh shared: classic AVR rebuild/partial-output checks
  test_ci_local_routing.sh  shared: local-CI skip-option command routing
  test_workflow_syntax.sh   shared: GitHub workflow YAML + ci-local job-map checks
  test_flash_budget.sh      shared: fail-closed flash measurement checks
  test_gpsim_wrappers.sh    shared: fail-closed gpsim wrapper checks
  test_klee_build.sh        shared: linked KLEE bitcode build regression
  test_lockstep_progress.sh shared: PIC libgpsim lock-step progress checks
  test_make_serialization.sh shared: worktree Make/release lock regression
  test_pic_build.sh         shared: PIC image/size/rebuild-trigger checks
  test_pic_rebuild.sh       shared: PIC soak rebuild determinism
  test_release_images.sh    shared: isolated exact release artifact verification
  test_release_provenance.sh shared: source/compiler/output release-provenance regression
  test_release_qualification.sh shared: release soak/evidence publication contract
  test_release_history.sh     shared: release history + pinned-signature binding
  test_soak_timing.sh       shared: soak input boundaries (make test-soak-timing)
  test_stack_bound.sh       shared: fail-closed stack evidence checks
  test_stack_depth_pic.sh   shared: PIC return-stack gate regression
  test_strict_tools.sh      shared: skip/strict policy for host + both PIC chips
  test_target_lane_markers.sh shared: PIC aggregate PASS-marker regression
  test_target_matrix.sh     shared: fail-closed PIC variant-matrix regression
  test_workload_rebuild.sh  shared: workload/fuse rebuild checks

  host/    MCU-independent golden-model tests, compiled and run natively.
           test_logic_host.c

  formal/  MCU-independent formal verification (proofs / exhaustive enumeration).
           test_cbmc.c          CBMC harnesses        (make test-cbmc)
           test_model_check.c   exhaustive BFS model  (make test-model-check)
           test_symbolic.c      KLEE / host enumerator (make test-symbolic[-klee])

  avr/     ATtiny-specific tests: the real firmware ELF in simavr, plus fuses.
           attiny202_smoke.c    AVR-XT peripheral compile/link smoke image
           test_sim.c           simavr integration    (make test-sim-<variant>)
           test_soak.c          long-duration soak    (make test-soak)
           test_fuses.c         all-target fuse bytes (make test-fuses)
           attiny202_fuses.py   fail-closed simulator fuse configuration
           test_attiny202_fuses.py  simulator-fuse host regression
           sim_attiny202.py     shared yasimavr device/pin support
           test_sim_attiny202.py   functional + PA2/PA3 transition/timing checks
           test_attiny202_output_oracle.py  host regression for output checks
           test_attiny202_fault_oracle.py   host fault-run accounting regression
            test_fault_attiny202.py  critical-SFR/state/pin-polarity fault injection
           test_soak_attiny202.py  long-duration liveness soak
           test_lockstep_attiny202.py  ctx_-vs-golden-model co-simulation
                                                        (make attiny202-lockstep)
           test_attiny202_delay_oracle.py  compiled-image pulse-width oracle
           model_step_ffi.c/.py  ctypes bridge letting the Python drivers call
                                 the SHIPPING pure core through model_step.h,
                                 so no part of the algorithm is re-implemented
                                 in Python
           test_model_ffi.py    host gate for that bridge, with independent
                                hard-coded algorithm expectations
                                                        (make test-attiny202-model-ffi)

  pic/     PIC10F322-specific tests plus shared PIC gpsim harness code.
             fw_coverage/         real PIC source via host SFR mock + gcov
                                                        (make pic-coverage-check-fw)
            test_config_pic.c    CONFIG-word check     (make pic-test-config)
            *.stc + run_gpsim_*  register-level gpsim  (make pic-test-gpsim)
            find_pin_exact.h     shared exact gpsim pin-name lookup
            test_fault_pic.cc    PIC10F322 fault adapter (make pic-test-fault)
            test_lockstep_pic.cc PIC10F322 HEX/model lock-step adapter
                                                        (make pic-test-lockstep)
            test_io_pic.cc       PIC10F322 GPIO/pulse-timing adapter
                                                        (make pic-test-io)
            test_{fault,lockstep,io}_pic_core.h
                                  shared libgpsim harness implementations
            test_soak_pic.cc     libgpsim soak         (make pic-test-soak)
                                  shared with the PIC10F320 lane

  pic10f320/  PIC10F320-specific tests. Separate from pic/ because this target's
               firmware is a single hand-inlined translation unit rather than a
               shell over the shared core, requiring dedicated host harnesses and
               thin target-simulator adapters (docs/pic10f320_special_case.md).
            equiv/     fw_harness.c   the real firmware #included, host-compiled
                       test_equiv.c   tick-for-tick vs src/bypass_pure.c
                                                       (make pic320-test-equiv)
                       xc.h           mock <xc.h>: SFR accesses become host storage
            actuation/ test_actuation.c  settled + mid-actuation LATA per variant
                                                       (make pic320-test-actuation)
            fault/     fw_fault_harness.{c,h}  fault-injection API over the firmware
                       test_fault.c            defensive-layer driver
                                                       (make pic320-test-fault-host)
                       check_fw_coverage.sh    exact-line firmware coverage gate
                                                       (make pic320-coverage-check-fw)
            gpsim/     test_fault_pic.cc     libgpsim fault adapter
                                                         (make pic320-test-fault-target)
                         test_lockstep_pic.cc  libgpsim lock-step adapter
                                                         (make pic320-test-lockstep)
                         test_io_pic.cc        libgpsim GPIO/timing adapter
                                                         (make pic320-test-io)
                        footswitch_toggle.stc gpsim stimulus
              return_stack_oracle.py  strict final-HEX control-flow/return-stack
                                      proof + fixtures
                               (make test-pic320-return-stack-oracle;
                                make pic320-test-return-stack for real images)
              check_expected_images.py  strict SHA-256 manifest/image checker
              expected_images.sha256    reviewed XC8/DFP three-image baseline
                               (make test-pic320-expected-images;
                                make pic320-test-build for real images)
```

The PIC10F320 lane reuses, rather than forks, everything it can: the CONFIG-word
checker (`pic/test_config_pic.c`, parameterised on `PIC_DEVICE_NAME`), both gpsim
CLI wrappers, the soak driver (`pic/test_soak_pic.cc`), the three libgpsim harness
cores, and — most importantly — `src/bypass_pure.c` itself. Thin per-part adapters
keep processor/image defaults and output-macro vocabularies explicit. The fault
adapters additionally pin each part's program-space limit, independent expected
check count, and output-latch policy: PIC10F322 runs three LATA injections that
PIC10F320 deliberately omits because its firmware has no latch-integrity guard.

Build artifacts (compiled binaries, `*.bc`) are written next to their sources in
each subdirectory and are git-ignored; see `.gitignore`. KLEE output directories
are produced at the `test/` root. The `-fstack-usage` `stack_*` evidence uses a
private temporary directory and is removed after each gate run.

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


## ATtiny202 (AVR-XT) target validation layers

The AVR-XT lane needs two inputs a normal AVR machine does not have: Microchip's
ATtiny_DFP device files to *build* the image (packaged avr-gcc 7.3.0 predates the
part) and a patched `yasimavr` venv to *run* it (neither simavr nor QEMU models
the AVR8X core). Both are fetched on demand and version pinned, and every
`attiny202-*` target skips cleanly without them — which is correct for local
development and fatal for a gate, so CI and release qualification use
`STRICT_TOOLS=1` to turn each skip into a hard failure.

The split mirrors the PIC lanes: **the host-only rows below are members of
`make test`** and run everywhere; the simulator rows need the fetched inputs.

| layer | target | what it proves | substrate |
|---|---|---|---|
| Image generation | `test-attiny202-build` | Missing, partial, or malformed avr-gcc output cannot become an ATtiny202 image; the flash budget is enforced per variant. | host fake-compiler regression |
| Fuse configuration | `test-fuses` | All seven AVR8X fuse bytes match design intent, and the simulator's descriptor is patched to those exact production values rather than falling back to defaults. | host parser |
| Golden-model bridge | `test-attiny202-model-ffi` | The ctypes bridge reaches the shipping pure core and behaves correctly at the `>=` press-threshold boundary, both saturation bounds, the lock-out, and a full round trip — independent hard-coded expectations, not another comparison against the model. | host |
| Output-sequence oracle | `test-attiny202-output-oracle` | The PA2/PA3 transition, ordering and pulse-presence checker itself is correct. | host |
| Fault accounting oracle | `test-attiny202-fault-oracle` | The fault driver's run accounting cannot silently under-count injections. | host |
| Coil-pulse width | `attiny202-delay-oracle` | Absolute relay (12 ms) and mute (5 ms) pulse widths, recovered from the disassembled `_delay_ms` loop in the built image, match design and clear the 4 ms datasheet minimum. | host, over real image |
| Static analysis | `attiny202-analyze` | cppcheck + MISRA pass over the AVR-XT shell with real DFP/avr-libc headers. | host tools |
| Register-level functional | `attiny202-sim` | The real image toggles on debounced press, boots dark with the WDT locked and `PORTA.DIR` exact, stays stable at idle, handles a switch held through power-on, and drives the correct PA2/PA3 sequence per variant. | yasimavr |
| Fault recovery | `attiny202-fault` | 22 guarded SFR/latch/state/pin-polarity corruptions each produce the correct response — the sanity gate's force-reset path, or a witnessed watchdog reset for the tick timer itself. Includes an independent `INVEN` injection on all five bonded application pins, which `OUT` readback alone cannot see. Zero skips, exact completion accounting over 23 results. | yasimavr |
| Firmware/model lock-step | `attiny202-lockstep` | `ctx_` in simulated SRAM equals the shipping core's state after **every settled tick**, over both boot scenarios, plus LED and settled control-line agreement. Catches a shell defect on the tick it happens rather than as a wrong output later. | yasimavr + host core via ctypes |
| Liveness soak | `attiny202-soak` | Over a long run the watchdog never resets the device (GPR0 reset witness), the sanity gate never force-resets, and a periodic 2-press round-trip still toggles. Emits the shared `SOAK_RESULT` release contract. | yasimavr |
| Fail-closed aggregate | `attiny202-test-target` | sim + fault + lock-step across every variant, with no skip permitted. This is what release qualification runs. | yasimavr |

Mutation coverage for this lane is described under "Mutation testing" below; it
is gated on the same two inputs and by the same probe discipline as the PIC ones.

### Known gaps (AVR-XT — hardware-bench only)

These are properties of the AVR-XT *environment*, not of the firmware, and are
ultimately validated on a real part at the bench.

- **yasimavr is not cycle-accurate.** It charges roughly one cycle per
  instruction with no multi-cycle timing model, so a busy-wait `_delay_ms` loop
  runs at about half its real duration (a 12 ms coil pulse traces as ~6 ms). This
  is why `attiny202-sim` asserts pulse *ordering, polarity, exclusion and
  presence* but never wall-clock width, and why absolute width is recovered
  separately from the disassembled image by `attiny202-delay-oracle`. TCB0 tick
  timing is unaffected, so the debounce, LED and lock-step results stay accurate.
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
- **No stack bound for the shell.** `make test-stack-bound` covers the pure core
  and all three output drivers, which this build shares unchanged, but not
  `bypass_mcu_avr_xt.c` itself.
- **UPDI programming is untested on silicon.** The `attiny202-program` recipe and
  its fuse writes have not been exercised against a real part.


## PIC10F322 target validation layers

Real-tool PIC targets are intentionally outside the default AVR `make test` path:
XC8, the PIC10-12Fxxx DFP, gpsim, and libgpsim may be absent on a normal AVR
development machine. The fake-XC8 `test-pic-build` regression is host-only and
is included in `make test`; targets needing external PIC tools may skip cleanly.
The host source-coverage gate requires Bash, a host C compiler, and matching
gcov. CI/release use `STRICT_TOOLS=1` plus the fail-closed aggregate described
below so a green gate means every PIC layer actually ran.

| layer | target | what it proves | substrate |
|---|---|---|---|
| Image generation | `test-pic-build` | Missing, partial, malformed, or non-regular XC8 output cannot become a PIC firmware image; malformed/zero budgets, huge usage counts, and arithmetic-tool failures are rejected. The PIC10F322 producer requires its immutable complete matrix. Same-stem `.s`/`.sym` are invalidated with the HEX, and a current HEX without fresh assembly fails the stack target rather than skipping. | host fake-XC8 regression |
| CONFIG word | `pic-test-config` | The XC8-emitted CONFIG word matches the documented oscillator/WDT/BOR/MCLR/LVP design intent. | host parser over HEX |
| Static analysis | `pic-analyze` | cppcheck + MISRA pass over the PIC shell with real XC8/DFP register headers. | host tools |
| Shipping-source coverage | `pic-coverage-check-fw` | Every executable line in the real PIC shell, shared pure core, and all three output drivers is host-executed except the documented non-returning reset path. | host gcov with PIC SFR mock |
| Register-level functional | `pic-test-gpsim` | Real HEX toggles on press, handles power-on-held switch, keeps settled LATA/PORTA expectations, and includes the mid-debounce `PRESS1_EARLY` tick-cadence check. | gpsim CLI |
| gpsim process gate | `test-gpsim-wrappers` | Both functional wrappers require a positive decimal timeout, reject nonzero or killed gpsim runs even after complete snapshots, prove routed stimuli contain one exact `attach n1 fsw ra3`, and fail rather than skip missing gpsim under `STRICT_TOOLS=1`. | Bash + fake gpsim |
| Fault recovery | `pic-test-fault` | Runtime direction, settled-output-latch, configuration, pull-up, and `ctx_` corruptions produce the variant-appropriate WDT recovery response. | libgpsim |
| HEX/model lock-step | `pic-test-lockstep` | Live `_ctx_` SRAM from the XC8-built instruction stream matches the shared pure model after every completed main-loop iteration. | libgpsim |
| Lock-step progress regression | `test-lockstep-progress` | Both chip-specific adapters bind the exact RA3 pin despite substring decoys and abort simulator stalls during settle, calibration, or completion immediately. | host C++ + fake gpsim API |
| Target I/O timing | `pic-test-io` | TRISA/ANSELA/LATA/PORTA transitions, relay coil exclusion, and mute/relay pulse widths match the design. | libgpsim |
| Fail-closed aggregate | `pic-test-target-variants` | Requires the complete supported matrix — empty, duplicate, unsupported, and incomplete requests are all rejected — then runs fault recovery, lock-step, and target-I/O for every PIC variant and requires each PASS sentinel. | Makefile wrapper |
| Aggregate regression | `test-target-matrix` | Proves complete matrices run exactly once per variant, that empty, duplicate, unsupported, and incomplete matrices fail before any target invocation, and that both PIC target aggregates require explicit fault, lock-step, and I/O completion markers. | Bash + fake recursive Make |
| Aggregate fail-closed regression | `test-target-lane-markers` | Proves the per-variant aggregate requires each lane's explicit `PASS` marker, not just its exit status: a skipped, crashed, or failing-but-zero-exit lane is rejected and the aggregate's own success line is withheld. Covers both PIC chips. | Bash + fake recursive Make |
| Hardware return-stack depth | `pic-test-stack-bound`, `pic320-test-stack-bound` | Bounds the **8-level hardware return stack** — the PIC counterpart of the AVR's byte-valued `test-stack-bound`, and a different quantity: the PIC14 core has no data stack, and hardware-stack overflow on this part is silent (no `STKPTR`, no `STKOVF`, no overflow reset). Computes the deepest call chain from the freshly generated instruction stream, cross-checks it against XC8's own `callstack` directives, and rejects missing/current-image assembly, recursion, indirect calls, and an over-budget build. Every variant, both chips. | XC8-generated `.s` + awk |
| Stack-depth gate regression | `test-stack-bound-pic-regression` | Proves that gate rejects each way the analysis can be wrong — over budget, recursion, an overflowing build, the two oracles disagreeing, an unresolvable or indirect call, no entry point, and a device pack declaring no depth. Synthetic fixtures, so it needs no toolchain. | Bash + awk |
| Soak rebuild determinism | `test-pic-build-rebuild` | Both chips' soak binaries compile their workload sizing in as `-D` flags, so their file rules must be *unconditionally* out of date. Asserts a changed duration recompiles with the new value, and that an identical rerun recompiles too — the signature of `FORCE`, as opposed to a rebuild that merely followed a timestamp. | Bash + fake c++ |

| Soak timing contract | `test-soak-timing` | Native Classic AVR/PIC soaks require the liveness interval within the total duration; short release rehearsals clamp it so every passing run completes a responsiveness round-trip. | host C/C++ compilers + release CLI |
| Release qualification contract | `test-release-qualification` | Publication requires clean production metadata, the exact canonical 28-file evidence set, and one identity-, duration-, and counter-bearing result for each of 15 release soak combinations. | Bash + synthetic retained evidence |
| Release history/signature contract | `test-release-history` | The tag event must peel to an artifact-only, single-parent child of the exact qualified source. `SHA256SUMS.asc` and the exact remote annotated tag must verify against the pinned full-fingerprint key in an isolated keyring; altered bytes, missing/malformed/wrong-key signatures, lightweight/unsigned/same-target-replaced tags, and moved tags are rejected immediately before publication. | Bash + GnuPG + scratch Git repositories |

`pic-test-gpsim` now samples one non-settled point, `PRESS1_EARLY`, roughly
6 ms (3,000 instruction cycles) after the first press edge. A correct 1 ms tick
has not yet accumulated the eight separated pressed samples needed to toggle, so
the LED must still be off.
This catches a collapsed tick gate, for example if `TMR2IF` stopped being cleared
and the main loop free-ran through the debounce threshold. The same wrapper also
asserts full BYPASS `LATA` at startup and after the second press, so analog-switch
control pins are checked in both settled directions, not just the LED bit.

`pic-test-target-variants` is the gate to use when a PIC result must be
authoritative. The component libgpsim targets remain useful standalone commands,
but they are allowed to skip for missing tools; the aggregate turns any skip or
missing PASS marker into a failure. It also requires the complete supported
variant matrix before starting its first target, so an empty, malformed, or
incomplete matrix cannot report an all-variants PASS or leave a partial run.

Debounce thresholds define a 33-sample pure-model minimum between press onsets.
That is also the nominal 33 ms physical minimum on ISR-driven AVR targets and the
simple polled PIC variant. PIC mute and relay actuation blocks the polling loop
for 5 ms and 12 ms after a toggle, so qualification uses conservative 38 ms and
45 ms physical budgets. A latched TMR2 flag normally preserves one pending
post-block sample, making the ideal path roughly one tick shorter; the PIC soak
deliberately adds the full active variant block to every liveness window.

`pic-test-fault` first requires exact startup `WPUA=0x08` and `TRISA=0x08`, then
injects every guarded direction, settled-output-latch, SFR, and SRAM fault at the
behaviorally identified main-loop `CLRWDT`, including every RA0..RA2 direction
flip (the exact-TRISA gate covers the simple variant's spare RA2). Register
identity, injection readback, and the expected per-variant check count are all
fail-closed test invariants.


## PIC10F320 target validation layers

The PIC10F320 is the one target whose verified core is *hand-inlined* into the
firmware instead of compiled in, so it carries validation layers no other target
needs. `docs/pic10f320_special_case.md` is the authoritative statement of why;
this section is what the test suite does about it.

The split that matters here: **the first four layers need only a host C compiler
and gcov**, so they are members of `make test` and run on every push regardless
of whether XC8 is installed. The return-stack oracle and expected-image
checker's dependency-free Python 3 selftests are there too. The real-image
layers need the PIC toolchain and behave
like the PIC10F322 layers above, except that the expected-image and return-stack
targets are always fail-closed rather than skip-clean.

| layer | target | what it proves | substrate |
|---|---|---|---|
| Firmware↔core equivalence | `pic320-test-equiv` | The real firmware, host-compiled, stepped tick-for-tick against `src/bypass_pure.c` over 266,144 stimulus sequences, visiting all 66 reachable model states, with zero divergence. This is the layer that closes the inlining seam. | host C |
| Actuation sequence | `pic320-test-actuation` | Each variant's full *settled* `LATA` at every tick, plus the mute/relay *mid-actuation* sequencing and pulse width that a settled snapshot cannot see. | host C |
| Host fault injection | `pic320-test-fault-host` | Corrupting a guarded SFR or the debounce context forces the sanity gate to take the watchdog-reset path — the defensive layer valid stimulus never reaches. | host C |
| Shipping-source coverage | `pic320-coverage-check-fw` | An **exact** property, not a percentage floor: every line of the real firmware is host-executed except an enumerated, justified watchdog-reset path. Run per variant, because the three output stages give 84 / 95 / 99 executable lines. | host gcov with the mock `xc.h` |
| All-variant host aggregate | `pic320-test-host-variants` | The four layers above across all three variants, with the complete supported matrix required first. **This is the member of `make test`.** | Makefile wrapper |
| Return-stack oracle regression | `test-pic320-return-stack-oracle` | 149 deterministic checks: passing depths through 8, recursion/depth-9 rejection, independently required skip edges and operand boundaries, classic alias ranges, all 16,384 legality decisions, every destination writer against PCL/INDF/INTCON, 9-bit PC/physical-fetch aliasing, literal HEX layout, and fail-closed parser/file cases. Includes ten device-geometry checks: `--program-words` is validated as a power of two inside the 9-bit PC space, and fixtures whose verdict *differs* between the 256- and 512-word geometries pin the fetch alias in both directions — an image with code above word `0x0FF` is rejected when 256 words are declared, and one that relies on the fold is rejected when 512 are. **This is also a member of `make test`.** | dependency-free Python 3 |
| Image generation | `test-pic-build` | 36 PIC10F322 and 75 PIC10F320 checks. Both runs prove missing-XC8 skips remove the complete product matrix despite attempted inventory overrides, stale assembly/symbol sidecars cannot survive a current-HEX-only build, and shell syntax in matrix text is rejected without execution. The 322 run additionally rejects recursively self-whitelisting GNU Make input; the 320 run covers selector rebuilds, deletion of reachable-RETFIE and depth-9 images despite attempted oracle/limit overrides, exact per-output XC8/host-compiler rebuild invocations with current clock/variant/host flags, and matching/mismatching/malformed/missing expected-image gate inputs. | host fake-XC8/fake-CC regression |
| Expected image bytes | `test-pic320-expected-images`; `pic320-test-build` | The dependency-free checker pins exact manifest grammar and fail-closed file handling in `make test`; the full-tool target rebuilds the immutable three-variant matrix and compares each raw HEX file with the reviewed XC8 V3.10 / DFP 1.9.189 SHA-256 baseline. Kept out of mutation kill targets so a broad byte mismatch cannot mask a weak behavioural oracle. | Python 3; pinned XC8/DFP for the real-image comparison |
| CONFIG word | `pic320-test-config` | The emitted CONFIG word matches design intent, over every built image. Uses the shared checker with a device-accurate label. | host parser over HEX |
| Hardware return stack | every `pic320` build; `pic320-test-return-stack` | The base build strictly parses and traverses its final HEX before marking that image complete, so gpsim/target/soak/release rebuilds use the same fail-closed gate. The explicit target rebuilds the supported matrix and rechecks all three together, reporting each maximum and witness. | dependency-free Python 3 over final HEX |
| Static analysis | `pic320-analyze` | cppcheck + MISRA over the shell, **swept across all three variants** — each compiles a different `#if defined(OUTPUT_*)` branch, so one run would leave two thirds unanalyzed. | host tools |
| Register-level functional | `pic320-test-gpsim` | Real HEX toggles on press and handles a power-on-held switch via the shared wrappers, with the processor and chip-specific toggle-cadence stimulus overridden. | gpsim CLI |
| Fault recovery | `pic320-test-fault-target` | The host fault argument re-made on the real emitted image: every guarded SFR/SRAM location and the required `TRISA` directions, 22 checks per variant. | libgpsim |
| HEX/model lock-step | `pic320-test-lockstep` | Live `_ctx_` SRAM from the XC8-built instruction stream matches `src/bypass_pure.c` after every completed main-loop iteration — 3,005 checks per variant, 66/66 states. | libgpsim |
| Target I/O timing | `pic320-test-io` | Exact `TRISA`, physical `PORTA` following every `LATA` transition, each variant's complete transition sequence, and mute/relay pulse widths from simulator cycles. | libgpsim |
| Fail-closed aggregate | `pic320-test-target-variants` | Rejects any matrix other than the complete supported set, then requires fault, lock-step and target-I/O PASS sentinels for every variant. | Makefile wrapper |
| Pre-hardware aggregate | `pic320-test` | The single target CI and the release script invoke: the host aggregate, expected-image hash, CONFIG and return-stack proof over all images, and analysis + gpsim per variant. | Makefile wrapper |
| Soak | `pic320-test-soak` | Long-duration libgpsim soak per output stage; three combos at full duration are part of release qualification. | libgpsim |

The shared stale-sidecar and matrix cases run in both parameterized
`test-pic-build` invocations; the PIC10F320 rebuild cases run only in the second.
The script itself requires
`PB_REBUILD_REQUIRED=1` for canonical `PB_TARGET=pic320` and enforces exactly 75
final checks; canonical `PB_TARGET=pic` enforces 36. A missing or misspelled
rebuild-arm assignment therefore fails instead of reporting a 61-check subset as
green.

In a fresh temporary repository the arm proves that identical requests reinvoke
the compiler for `pic320`, `pic320-test-equiv`, `pic320-test-actuation`, and
`pic320-test-fault-host`. After each initial request it creates a regular
same-name file in the sandbox root before repeating, so removing the target's
`.PHONY` declaration makes Make skip the recipe and fails the exact invocation
count. Every fake linked host test also logs its executed path; execution counts
must advance with compile/link counts, catching a removed binary-run recipe.
Variant/clock/host-flag changes and restorations are checked against the latest
applicable command, not any historical log entry. This is deterministic
**rebuild triggering with the current flags**, not byte-for-byte XC8
reproducibility. Byte identity is enforced separately by `pic320-test-build`.
The coverage lane needs no stable-output probe: every request
uses a new `mktemp` directory and requires fresh `.gcda` and `.gcov` evidence
before that directory is removed.

Note what `pic320-test-equiv` and `pic320-test-lockstep` run *against*. Both
compile and link `src/bypass_pure.c` — the same file every other target compiles
into its shipping image, not a vendored snapshot of it. The project this target
was merged from could only manage the weaker claim, because it held a pinned
copy; that copy is gone.

`return_stack_oracle.py` does not consume a compiler listing or trust a
disassembler. It requires a nonempty, non-symlink regular file; validates every
Intel HEX count, checksum, record type, address, overlap and unique EOF; then
forms PIC14 words little-endian. CONFIG and other unreachable data are ignored,
but an absent byte on a reachable instruction is a hard failure. Its documented
classic mid-range masks cover direct `CALL`/`GOTO`, all four required skip
opcodes, `RETURN`, and the full `RETLW` alias range. The full classic
35-instruction legality check also recognizes `MOVLW` at `0x3000..0x33ff` as
fall-through. Reachable `RETFIE`, direct PCL writes, writes through classic
`INDF` whose FSR-selected destination could be PCL, and writes that could enable
`INTCON.GIE` are rejected rather than guessed.

PIC10F320 control state has a 9-bit architectural PC. The oracle normalizes upper
direct-target bits, sequential and skip successors, pushed return PCs, and popped
return PCs into `0x000..0x1ff`; only instruction fetch aliases through the low
eight bits into the 256 implemented physical words. Its fetch helper remains
strict about receiving normalized architectural PCs. Every successful `pic320`
recipe runs that oracle before setting its completion flag, inside the existing
cleanup trap. The explicit
`pic320-test-return-stack` target is still valuable: it rebuilds and rechecks the
whole immutable supported matrix in one reported invocation. This is execution-
time enforcement, not a claim that a later staged/copied artifact cannot be
modified; release provenance and reproduction checks remain separate controls.


## Mutation testing and skipped optional tools

`make test-mutation` includes PIC mutants whose kill targets need XC8, gpsim, and
libgpsim, plus ATtiny202 mutants whose kill targets need the vendored ATtiny_DFP
and the patched yasimavr venv. A local host without those tools may run an
explicitly partial mutation suite with `MUTATION_ALLOW_SKIP=1`; that is the
non-strict default so development on one substrate stays practical.
`STRICT_TOOLS=1` changes the default to fail closed, and full-tool CI also pins
`MUTATION_ALLOW_SKIP=0`. An explicit `MUTATION_ALLOW_SKIP` value takes
precedence: `ci-local.sh --skip-pic` retains strict host/AVR gates but
deliberately passes `1` for its partial mutation run. The summary counts PIC and
ATtiny202 skips separately, so a partial run always says which substrate went
unexercised rather than reporting one anonymous number.

The PIC mutation set includes target-level faults for the new coverage: collapsed
TMR2IF cadence, exact-TRISA predicate removal, output-latch mask narrowing,
exact WPUA pull-up state, ANSELA mask narrowing, muted-CD4053 startup
reassertion, mute-window shortening, and relay pulse shortening.

**PIC10F320 mutants are split by what they NEED, not by what they test.** 27 of
them are killed by the host lanes and require only a C compiler, so they ride
with the unskippable core batch; 9 need XC8 + gpsim + libgpsim and sit behind
their own tool probe, which first verifies every distinct kill command against
the *unmutated* tree. Without that split they would "survive" on any host lacking
the PIC toolchain; without the per-command baselines, a broken gpsim or soak
harness could make them die for an infrastructure reason and falsely count as
killed. Skip accounting is wired through the same policy resolver, so a partial
run cannot be mistaken for full PIC10F320 coverage.

The driver independently pins the seven mutation categories at **23 core/AVR +
19 AVR-XT + 27 PIC10F320 host + 9 PIC10F320 tool + 6 PIC gpsim + 1 PIC soak + 8
PIC target = 93**. It rejects category drift before probing, then requires
dispatched + skipped = 93 and killed + survived + errored = dispatched. Every
worker status is checked; result status/output pairs are atomically published
and accepted only with exact text grammar and no missing, hidden, or extra
artifacts.

One further note on the driver, learned the hard way: its sandbox tree copy has
to reach `test/pic10f320/{equiv,actuation,fault,gpsim}/` and the folded `.sh` and
`.stc` assets under `test/pic/`. The probe checks those shared helpers before it
can enable the tool-dependent PIC10F320 mutants. The host-only
`test-mutation-sandbox` regression exercises the same copy routine in `make test`,
including the wrappers' executable mode, and covers inventory, conservation,
record/command parsing, atomic publication, checker-status classification, and
result grammar in 30 checks.

**The ATtiny202 lane is gated the same way, with one extra hazard.** `XT_DFP` and
`YASIMAVR_VENV` both default to paths *relative* to the tree, which is exactly
wrong inside a `mktemp` sandbox: `make -C "$work"` would resolve them under
`$work`, find nothing, and every `attiny202-*` target would skip cleanly with
status 0 — scored as a survivor for every mutant in the lane. The driver
therefore passes both in as absolute paths, sharing the read-only toolchain while
keeping sources sandboxed, and the probe refuses to enable the lane unless both
resolve *and* each distinct kill target passes on the unmutated sandbox.

Its mutants are mapped by what the fault actually perturbs: an inverted LED or
control pin to `attiny202-sim`, a dropped `ctx_` write-back to
`attiny202-lockstep`, a defeated SFR/direction/pull-up guard to
`attiny202-fault`, a missing WDT pet or broken ISR handshake to
`attiny202-soak`, and a shortened coil pulse to `attiny202-delay-oracle` — the
AVR-XT's only route to an absolute pulse width, since yasimavr's flat
instruction timing cannot measure a busy-wait loop.


## Known gaps (PIC — hardware-bench only)

These are properties of the PIC builds that the gpsim-based simulation cannot
faithfully assert; they are ultimately validated on a real chip at the bench.

They apply to **both PIC targets — PIC10F322 and PIC10F320 — equally**, because
they are properties of the shared gpsim environment rather than of either
firmware: same TMR2, same datasheet family, same simulator. Neither chip's lanes
are more or less exposed than the other's, and a gap closed here is closed for
both. (Before the PIC10F320 merge these notes lived in two places, one per
repository, and drifted; this is the single copy.)

- **WDT-timing / brown-out behaviour** is not simulated. gpsim's WDT calibration
  differs from silicon — at the firmware's `WDTPS = 0x08` gpsim's period is
  ~1.06 s versus the silicon ~256 ms — and gpsim has no analog BOR model.
  `make pic-test-config` proves `WDTE`/`BOREN` are *enabled*; their real-time
  behaviour is a bench concern. `make pic-test-soak` exercises WDT *liveness* and
  periodic responsiveness at scale, but asserts nothing about WDT *timing* (it
  uses the WDT only as a qualitative liveness signal — see
  `test/pic/test_soak_pic.cc`). This is distinct from the **1 ms TMR2 tick
  cadence**: gpsim models the tick for the firmware's *current* prescale
  (`T2CKPS = 0b01` = 1:4 at 2 MHz), which the `PRESS1_EARLY` checkpoint exercises,
  but the *absolute* tick period on silicon is itself a bench-only guarantee (next
  bullet).
- **TMR2 prescaler *select* is not faithfully modelled by gpsim.** gpsim clamps
  `T2CKPS = 0b11` to a 1:16 prescale instead of the datasheet's 1:64
  (`0b00`/`0b01`/`0b10` → `1:1`/`1:4`/`1:16` are modelled correctly; only the top
  code is wrong). The firmware uses `0b01` (1:4 at 2 MHz), which gpsim gets right,
  so the current build's 1 ms tick *is* faithfully simulated — but gpsim cannot
  independently catch a wrong prescale *select*, because a `0b11` (1:64 → 4 ms)
  config still reads as 1 ms in the sim. This is exactly what let an earlier
  `T2CON = 0x07` (`0b11`) slip through on both builds: the firmware intended 1:16
  but selected 1:64, and gpsim's clamp masked the resulting 4×-slow tick until it
  was caught by cross-checking the programmed register value against the datasheet
  (fixed here in *PIC10F322: correct TMR2 tick prescaler…*, commit `f7d872e`; the
  child fixed the same line first). The host equivalence / model layers are
  tick-*counted*, so they are period-agnostic by construction and cannot catch it
  either. As with WDT timing, the *absolute* 1 ms tick period on silicon is a
  hardware-bench guarantee.
- **Real-silicon pulse timing remains bench-only.** The target-I/O gate measures
  the XC8-generated busy-wait duration in gpsim instruction cycles, so it
  verifies the programmed delays (the CD4053 mute window and the TQ2 relay coil
  pulse) at nominal configured FOSC and nothing more. It cannot validate
  HFINTOSC tolerance over voltage and temperature, output rise/fall time,
  relay-coil current, or analog-switch mute settling on physical hardware. This
  bullet was carried only by the PIC10F320 project before the merge; it is
  equally true of the PIC10F322 build, whose blocking actuations are measured
  the same way.
