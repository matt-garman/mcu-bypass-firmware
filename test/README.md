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
  misra_output_gate.py      shared: fail-closed authored source/header diagnostic parser
  mutation_policy.sh        shared: strict/partial mutation policy resolver
  mutation_accounting.sh    shared: mutation inventory/result accounting helpers
  run_mutation_tests.sh     shared: mutation-testing driver (make test-mutation)
  scratch_tree.sh           shared: throwaway repo-copy builder for sandbox harnesses
  soak_timing_config.h      shared: native soak timing bounds
  check_flash_budget.sh     shared: exact flash-budget checker
  check_stack_depth_pic.sh  shared: PIC hardware return-stack depth gate
  python_version.py         shared: Python 3.7+ host-gate prerequisite
  test_attiny202_build.sh   shared: fail-closed AVR-XT build checks
  test_avr_build_rebuild.sh shared: classic AVR rebuild/partial-output checks
  test_ci_local_routing.sh  shared: local-CI skip-option command routing
  test_workflow_syntax.sh   shared: GitHub workflow YAML + ci-local job-map and
                                    per-part PIC lane checks
  test_flash_budget.sh      shared: fail-closed flash measurement checks
  test_fetch_yasimavr.sh    shared: safe yasimavr venv fetch/rebuild checks
  test_gpsim_wrappers.sh    shared: fail-closed gpsim wrapper checks
  test_klee_build.sh        shared: linked KLEE bitcode build regression
  test_lockstep_progress.sh shared: PIC libgpsim lock-step progress checks
  test_make_serialization.sh shared: worktree Make/release lock regression
  test_misra_output_contract.sh shared: all-lane fake-cppcheck/header gate regression
  test_makefile_name_contract.py shared: every make goal/variable a file or doc
                                     names is one the Makefile really defines,
                                     and every NAME=value a recipe sets for a
                                     child is one that child still reads;
                                     checked from the moment a file exists
                                     rather than from the commit after
  test_todo_index.py        shared: TODO.md's priority summary and its open
                                    sections index each other both ways, with
                                    each ID's tier prefix agreeing with the tier
                                    it is filed under
  test_pinout_alignment.py  shared: every ASCII package-pinout diagram draws
                                    a square box -- each row's walls in the
                                    columns the corner rows put them in
  test_analyze_variant_guard.sh shared: analyze-* targets reject a bad VARIANTS=
                                     instead of silently analyzing less
  test_variant_selector_guard.py shared: every lane rejects a bad single-variant
                                     selector instead of reporting a missing tool
  test_clean_contract.sh    shared: clean/clean-tests remove everything the
                                     Makefile knows how to build
  test_fuse_injection_contract.py shared: every fuse byte the Makefile burns is
                                     the byte the -D-injected checker verifies;
                                     stdout alone carries queried values while
                                     stderr is retained as diagnostic context
  test_variant_map_contract.sh shared: every per-variant map is guard-registered
  test_static_assert_guards.sh shared: every modular shell has an anchored,
                                     uncommented direct include of the shared
                                     checks, whose guards fail the build when
                                     their inputs are broken
  test_pic_build.sh         shared: PIC image/size/rebuild-trigger checks
  test_pic10f320_coverage_archive.sh shared: coverage-gate source-archive mode checks
  test_pic_rebuild.sh       shared: PIC soak rebuild determinism
  test_release_images.sh    shared: isolated exact release artifact verification
  test_release_provenance.sh shared: source/compiler/output release-provenance regression
  test_release_qualification.sh shared: release soak/evidence publication contract
  test_release_history.sh     shared: release history + pinned-signature binding
  test_soak_reset_witness.sh shared: Classic AVR soak watchdog-witness proof
                                     (make test-soak-reset-witness)
  test_soak_timing.sh       shared: soak input boundaries (make test-soak-timing)
  test_stack_bound.sh       shared: fail-closed stack evidence checks
  test_stack_depth_pic.sh   shared: PIC return-stack gate regression
  test_strict_tools.sh      shared: skip/strict policy for host + both PIC chips
  test_supply_chain.sh      shared: external download/cache/action pin checks
  test_target_lane_markers.sh shared: PIC aggregate PASS-marker regression
  test_target_matrix.sh     shared: fail-closed PIC/AVR-XT target-matrix regression
  test_workload_rebuild.sh  shared: workload/fuse rebuild checks

  host/    MCU-independent golden-model tests, compiled and run natively.
           test_logic_host.c

  formal/  MCU-independent formal verification (proofs / exhaustive enumeration).
           test_cbmc.c          CBMC harnesses        (make test-cbmc)
           test_model_check.c   exhaustive BFS model  (make test-model-check)
           test_symbolic.c      KLEE / host enumerator (make test-symbolic[-klee])

  avr/     ATtiny-specific tests: the real firmware ELF in simavr, plus fuses.
           attiny202_smoke.c    AVR-XT peripheral compile/link smoke image
           test_sim.c           simavr integration    (make test-sim-<variant>-attiny13a)
           test_soak.c          long-duration soak    (make test-soak)
           test_fuses.c         all-target fuse bytes (make test-fuses)
           attiny202_fuses.py   fail-closed simulator fuse configuration
           test_attiny202_fuses.py  simulator-fuse host regression
           sim_attiny202.py     shared yasimavr device/pin support
           test_sim_attiny202.py   functional + PA2/PA3 transition/pulse-presence checks
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

  pic/     PIC10F322 and PIC12F675 tests plus shared PIC harness code. Both
           parts are a shell over the shared pure core, so their adapters sit
           beside the mechanism they share rather than in per-part trees.
            fw_coverage/         real PIC source via per-device host SFR mocks +
                                  gcov (make pic10f322-coverage-check-fw;
                                        make pic12f675-coverage-check-fw)
            test_config_pic_core.h  CONFIG-word mechanism: locate the word in a
                                  built HEX, mask it, compare against intent
            test_config_pic.c    PIC10F32x adapter     (make pic10f322-test-config)
            pic10f32x_config.h   PIC10F32x decode table (shared by 322 and 320:
                                  same address, layout and expected word)
            test_config_pic12f675.c  PIC12F675 adapter (make pic12f675-test-config)
            pic12f675_config.h   PIC12F675 decode table -- shares the CONFIG
                                  address with the 32x and no other bit; adds
                                  CPD and the BG factory-calibration bits
            *.stc + run_gpsim_*  register-level gpsim  (make pic10f322-test-gpsim)
            pic12f675_footswitch_toggle.stc, pic12f675_power_on_pressed.stc
                                  the same two scenarios re-derived for the
                                  PIC12F675: gpio5 stimulus, 1024-cycle tick, and
                                  they run the DERIVED *_simcal.hex
                                                        (make pic12f675-test-gpsim)
            gpsim_wrapper_common.sh
                                  scaffolding both run_gpsim_* wrappers source
                                  (sourced, not executable)
            pic10f32x_gpsim_regs.sh, pic12f675_gpsim_regs.sh
                                  per-part register identity the wrappers source
                                  via PIC_GPSIM_REGS: which registers a snapshot
                                  reads, which bits are footswitch/LED, and which
                                  output bits a variant expectation covers. One
                                  file per part so a lane cannot set half of it
                                  (sourced, not executable)
            find_pin_exact.h     shared exact gpsim pin-name lookup
            gpsim_bootstrap.h    shared libgpsim bring-up: core init, image
                                  load, footswitch stimulus, footsw_set()
            soak_sampling.h      per-ms observation for multi-ms soak holds
            test_fault_pic.cc    PIC10F322 fault adapter (make pic10f322-test-fault)
            test_lockstep_pic.cc PIC10F322 HEX/model lock-step adapter
                                                        (make pic10f322-test-lockstep)
            test_io_pic.cc       PIC10F322 GPIO/pulse-timing adapter
                                                        (make pic10f322-test-io)
            test_io_pic12f675.cc PIC12F675 GPIO/pulse-timing adapter. Same core,
                                  but with no output-latch SFR the comparison is
                                  the SRAM shadow against the physical pins --
                                  firmware intent against reality, which the
                                  32x lanes cannot express
                                                        (make pic12f675-test-io)
            test_lockstep_pic12f675.cc
                                  PIC12F675 HEX/model lock-step adapter. Same
                                  core and same reference model; what it adds is
                                  a 1024-word CLRWDT scan, because this part's
                                  loop CLRWDT sits above the bound the core used
                                  to hard-code
                                                  (make pic12f675-test-lockstep)
            test_fault_pic12f675.cc
                                  PIC12F675 fault adapter. Its per-part output
                                  policy injects into BOTH the SRAM shadow and
                                  the pins: with the shadow left correct, only
                                  "the port still follows it" can explain the
                                  reset. Parked GP4 is injected through its
                                  direction, shadow, pin and ANS3 guard paths
                                                     (make pic12f675-test-fault)
            test_{fault,lockstep,io,soak}_pic_core.h
                                  shared libgpsim harness implementations,
                                  device-parameterised: a part adapter supplies
                                  the register map and injection matrix below
            pic10f32x_regs.h     PIC10F32x register identity (PIC_REG_* names, <!-- name-contract: exempt (C macro family, not a make variable) -->
                                  addresses and masks) for both 32x adapters
            pic10f32x_fault_matrix.h
                                  PIC10F32x fault-injection matrix (PIC_FAULT_*), <!-- name-contract: exempt (C macro family, not a make variable) -->
                                  deliberately separate from identity: guard
                                  POLICY is per-family, not per-register
            pic12f675_regs.h     PIC12F675 register identity. Not the 32x map
                                  renumbered: bank 1 is a different address, the
                                  output "latch" is an SRAM shadow whose address
                                  the Makefile lifts from the build's .sym (so
                                  the latch entries exist only for the lanes that
                                  compare it), and the port may trail that shadow
                                  by a bounded number of trace samples. Also the
                                  one place the footswitch pin name is written,
                                  so every 675 harness attaches to gpio5
            pic12f675_fault_matrix.h
                                  PIC12F675 fault-injection matrix, split from
                                  identity for the same reason as the 32x pair.
                                  Names the locations this part guards that the
                                  32x cannot, and the two OPTION_REG bits it
                                  deliberately leaves alone because starving the
                                  tick would produce the same reset count as the
                                  gate firing. Its OSCCAL case flips implemented
                                  CAL0 (bit 2), never the read-zero low bits
            inject_calibration_word.py
                                  derives a simulator-runnable image by injecting
                                  the oscillator calibration word the factory
                                  programs; never touches the shipping HEX. The
                                  producer publishes all three variants as one
                                  exact regular-file matrix and removes the whole
                                  expected set after any failed derivation
                             (make pic12f675-test-calibration;
                              make pic12f675-simcal for the derived images)
            pic12f675_trim_evidence.py
                                  independently parses pk2cmd device exports and
                                  exclusively publishes strict baseline/result
                                  JSON with raw tool transcripts and OSCCAL,
                                  CONFIG, BG, Device ID/revision, executable and
                                  image identities (make pic12f675-preflight;
                                  make pic12f675-program)
            test_soak_pic.cc     PIC10F32x libgpsim soak adapter -- ONE file for
                                  two parts, which is why this lane carries no
                                  per-part default anywhere: a fallback would be
                                  correct for one caller and silently wrong for
                                  the other
                                                        (make pic10f322-test-soak
                                                         make pic10f320-test-soak)
            test_soak_pic12f675.cc
                                  PIC12F675 soak adapter. Reads the LED out of
                                  the SRAM shadow, since this part has no output
                                  latch to read, and states the 1.024 ms tick the
                                  core converts every hold through -- the
                                  thresholds are counted in ticks and the soak
                                  advances in milliseconds
                                                      (make pic12f675-test-soak)

  pic10f320/  PIC10F320-specific tests. Separate from pic/ because this target's
               firmware is a single hand-inlined translation unit rather than a
               shell over the shared core, requiring dedicated host harnesses and
               thin target-simulator adapters (docs/pic10f320_special_case.md).
            equiv/     fw_harness.c   the real firmware #included, host-compiled
                       test_equiv.c   tick-for-tick vs src/bypass_pure.c
                                                       (make pic10f320-test-equiv)
                       xc.h           mock <xc.h>: SFR accesses become host storage
            actuation/ test_actuation.c  settled + mid-actuation LATA per variant
                                                       (make pic10f320-test-actuation)
            fault/     fw_fault_harness.{c,h}  fault-injection API over the firmware
                       test_fault.c            defensive-layer driver
                                                       (make pic10f320-test-fault-host)
                       check_fw_coverage.sh    exact-line firmware coverage gate
                                                       (make pic10f320-coverage-check-fw)
            gpsim/     test_fault_pic.cc     libgpsim fault adapter
                                                       (make pic10f320-test-fault-target)
                       test_lockstep_pic.cc  libgpsim lock-step adapter
                                                       (make pic10f320-test-lockstep)
                       test_io_pic.cc        libgpsim GPIO/timing adapter
                                                       (make pic10f320-test-io)
                       footswitch_toggle.stc gpsim stimulus
            return_stack_oracle.py  strict final-HEX control-flow/return-stack
                                    proof + fixtures
                             (make test-pic10f320-return-stack-oracle;
                              make pic10f320-test-return-stack for real images)
            check_expected_images.py  strict SHA-256 manifest/image checker
            expected_images.sha256    reviewed XC8/DFP three-image baseline
                             (make test-pic10f320-expected-images;
                              make pic10f320-test-build for real images)
```

The PIC10F320 lane reuses, rather than forks, everything it can: the CONFIG-word
checker (`pic/test_config_pic.c`, parameterised on `PIC_DEVICE_NAME`), <!-- name-contract: exempt (C macro, not a make variable) --> both gpsim
CLI wrappers, the soak adapter (`pic/test_soak_pic.cc`), all four libgpsim harness
cores, and — most importantly — `src/bypass_pure.c` itself. Thin per-part adapters
keep processor/image defaults and output-macro vocabularies explicit. The fault
adapters additionally pin each part's program-space limit, independent expected
check count, and output-latch policy: PIC10F322 runs three reset-producing LATA
injections because it has a general latch-integrity guard. PIC10F320 omits that
general guard; its relay adapter instead runs three no-reset coil-latch cases
that require the safe idle state to be restored within one serviced iteration.

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
| Coil-pulse width | `attiny202-delay-oracle` | Compiled relay (12 ms) and mute (5 ms) delay-body cycle counts, recovered from the disassembled `_delay_ms` loop in the built image, match design and clear the 4 ms datasheet minimum. Timer-ISR preemption makes the edge-to-edge pin-high interval slightly longer. Every recognized loop candidate must provide a decodable 16-bit seed; no candidate can be dropped as missing evidence. | host, over real image |
| Static analysis | `attiny202-analyze` | cppcheck + MISRA pass over the AVR-XT shell with real DFP/avr-libc headers. | host tools |
| Register-level functional | `attiny202-sim` | The real image toggles on debounced press, boots dark with the WDT locked and `PORTA.DIR` exact, stays stable at idle, handles a switch held through power-on, and drives the correct PA2/PA3 sequence per variant. | yasimavr |
| Fault recovery | `attiny202-fault` | 22 guarded SFR/latch/state/pin-polarity corruptions each produce the correct response — the sanity gate's force-reset path, or a witnessed watchdog reset for the tick timer itself. Includes an independent `INVEN` injection on all five bonded application pins, which `OUT` readback alone cannot see. Zero skips, exact completion accounting over 23 results. | yasimavr |
| Firmware/model lock-step | `attiny202-lockstep` | `ctx_` in simulated SRAM equals the shipping core's state after **every settled tick**, over both boot scenarios, plus LED and settled control-line agreement. Catches a shell defect on the tick it happens rather than as a wrong output later. | yasimavr + host core via ctypes |
<!-- name-contract: exempt (SOAK_RESULT is the driver's stdout token, not a make variable) -->
| Liveness soak | `attiny202-soak` | Over a long run the watchdog never resets the device (GPR0 reset witness), the sanity gate never force-resets, and a periodic 2-press round-trip still toggles. Emits the shared `SOAK_RESULT` release contract. | yasimavr |
| Fail-closed aggregate | `attiny202-test-target` | sim + fault + lock-step across every variant, with no skip permitted. This is what release qualification runs. | yasimavr |

Mutation coverage for this lane is described under "Mutation testing" below; it
is gated on the same two inputs and by the same probe discipline as the PIC ones.

### Known gaps (AVR-XT — hardware-bench only)

These are properties of the AVR-XT *environment*, not of the firmware, and are
ultimately validated on a real part at the bench.

- **The pinned yasimavr loses cycles when stepped in tiny budgets.** Its
  `SimLoop.run(n)` pins the cycle counter to `first_cycle + n` on return, which
  *rewinds* it whenever the last instruction overshoots — so a caller loses up to
  one instruction's worth of cycles per call, and at `run(1)` every instruction
  is billed exactly 1 cycle.

  Nothing in the suite advances that way any more. The output tracer used to
  sample pin state one cycle at a time, which made a busy-wait `_delay_ms` loop
  trace at about half its real duration (a 12 ms coil pulse as ~6 ms); it now
  free-runs in millisecond budgets and timestamps pin edges from a signal hook,
  the pattern yasimavr's author recommends. So `attiny202-sim` asserts pulse
  *ordering, polarity, exclusion, presence* **and** delivered width. Tick timing
  was never affected: the TCB0 period is counted by the peripheral, not by
  summing instruction cycles, and the debounce and LED tests advance in budgets
  of 2000 cycles (1 ms), where the loss costs under 0.2%. The lock-step driver's
  32–256-cycle edge probes are coarser than the loss by a wide enough margin
  that they cannot step over a ~176-cycle awake window.

  Delivered width and design width are separate claims, and both are checked.
  `attiny202-delay-oracle` recovers the *compiled* width from the disassembled
  image — a compile-time property, so reading it from the image is
  simulator-independent and tighter than any trace. The traced width is a few
  percent longer, because the 1 ms tick ISR preempts the busy loop, and that
  overhead is visible only in the trace.

  The defect is reported upstream and confirmed, with a fix pending release.
  Earlier revisions of this note attributed the halving to a "flat one cycle per
  instruction" core with no multi-cycle timing model — that diagnosis was wrong,
  and was itself an artifact of measuring by single-stepping through the same
  bug.
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


## PIC12F675 shipping-source coverage

`make pic12f675-coverage-check-fw` host-compiles the real
`bypass_mcu_pic12f675.c`, shared pure core, and all three unmodified output
drivers under gcov. It needs only Bash, a host C compiler, and matching gcov;
XC8, the device pack, and gpsim are not involved.

The shared coverage harness selects a PIC12F675 mock `<xc.h>` that preserves the
classic-PIC distinctions the firmware depends on: GPIO intent and physical pin
levels are separate, externally driven GP5 survives whole-port writes,
`OPTION_REG`/`nGPPU` and `ADCON0`/`ADON` share their respective backing bytes,
and each `T0IF` access supplies the next of the four polled TMR0 subticks. Runtime
checks pin the implementation-defined host bitfield layout before it can count
as firmware evidence.

Every output variant runs an exact 85-check predicate, fault, and happy-path
matrix. The coverage oracle then requires every executable line in all five
shipping sources except one exact, documented defense-in-depth call: invalid
context is caught by the main-loop range gate before `debounce_step()` can
return `res.fault`. The live sanity-gate call to `hw_force_wdt_reset()` is a
positive coverage requirement, so the allowance cannot hide a harness that
never enters the real reset path.

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
| Image generation | `test-pic-build` | Missing, partial, malformed, or non-regular XC8 output cannot become a PIC firmware image; malformed/zero budgets, huge usage counts, and arithmetic-tool failures are rejected. The PIC10F322 and PIC12F675 producers require immutable complete matrices. PIC12F675 additionally proves exact simulator derivation, complete-set cleanup/consumption, and variant-bound hardware programming through a digest-checked private snapshot. Its fake programmer pins read-only baseline capture, immediate pre-write identity/trim comparison, exact pk2cmd/ipecmd write argv, post-write OSCCAL/BG comparison, and retained pass/fail records. Same-stem `.s`/`.sym` are invalidated with the HEX, and a current HEX without fresh assembly fails the stack target rather than skipping. | host fake-XC8 regression |
| CONFIG word | `pic10f322-test-config` | The XC8-emitted CONFIG word matches the documented oscillator/WDT/BOR/MCLR/LVP design intent. | host parser over HEX |
| Static analysis | `pic10f322-analyze` | cppcheck + MISRA pass over the PIC shell with real XC8/DFP register headers. | host tools |
| Shipping-source coverage | `pic10f322-coverage-check-fw` | Every executable line in the real PIC shell, shared pure core, and all three output drivers is host-executed except the documented non-returning reset path. | host gcov with PIC SFR mock |
| Register-level functional | `pic10f322-test-gpsim` | Real HEX toggles on press, handles power-on-held switch, keeps settled LATA/PORTA expectations, and includes the mid-debounce `PRESS1_EARLY` tick-cadence check. | gpsim CLI |
| gpsim process gate | `test-gpsim-wrappers` | Both functional wrappers require a positive decimal timeout, reject nonzero or killed gpsim runs even after complete snapshots, prove routed stimuli contain one exact footswitch attachment, and fail rather than skip missing gpsim under `STRICT_TOOLS=1`. All three public lanes are additionally probed end-to-end: each must reach gpsim with its own part's processor, so a severed `PIC_GPSIM_PROC=` cannot leave a lane simulating another chip. The PIC12F675 route exhausts all six nonempty partial simulator-image subsets and rejects empty, symlinked, or unexpected members before gpsim runs. | Bash + fake gpsim |
| Fault recovery | `pic10f322-test-fault` | Runtime direction, settled-output-latch, configuration, pull-up, and `ctx_` corruptions produce the variant-appropriate WDT recovery response. | libgpsim |
| HEX/model lock-step | `pic10f322-test-lockstep` | Live `_ctx_` SRAM from the XC8-built instruction stream matches the shared pure model after every completed main-loop iteration. | libgpsim |
| Lock-step progress regression | `test-lockstep-progress` | Both chip-specific adapters bind the exact RA3 pin despite substring decoys and abort simulator stalls during settle, calibration, or completion immediately. | host C++ + fake gpsim API |
| Target I/O timing | `pic10f322-test-io` | TRISA/ANSELA/LATA/PORTA transitions, relay coil exclusion, and mute/relay pulse widths match the design. | libgpsim |
| Fail-closed aggregate | `pic10f322-test-target-variants` | Requires the complete supported matrix — empty, duplicate, unsupported, and incomplete requests are all rejected — then runs fault recovery, lock-step, and target-I/O for every PIC variant and requires each PASS sentinel. | Makefile wrapper |
| Aggregate regression | `test-target-matrix` | Proves complete matrices run exactly once per variant, that empty, duplicate, unsupported, and incomplete matrices fail before any target invocation, and that all three PIC target aggregates require explicit fault, lock-step, and I/O completion markers. | Bash + fake recursive Make |
| Aggregate fail-closed regression | `test-target-lane-markers` | Proves the per-variant aggregate requires each lane's explicit `PASS` marker, not just its exit status: a skipped, crashed, or failing-but-zero-exit lane is rejected and the aggregate's own success line is withheld. Covers all three PIC chips. | Bash + fake recursive Make |
| Hardware return-stack depth | `pic10f322-test-stack-bound`, `pic10f320-test-stack-bound` | Bounds the **8-level hardware return stack** — the PIC counterpart of the AVR's byte-valued `test-stack-bound`, and a different quantity: the PIC14 core has no data stack, and hardware-stack overflow on this part is silent (no `STKPTR`, no `STKOVF`, no overflow reset). Computes the deepest call chain from the freshly generated instruction stream, cross-checks it against XC8's own `callstack` directives, and rejects missing/current-image assembly, recursion, indirect calls, and an over-budget build. Every variant, both chips. | XC8-generated `.s` + awk |
| Stack-depth gate regression | `test-stack-bound-pic-regression` | Proves that gate rejects each way the analysis can be wrong — over budget, recursion, an overflowing build, the two oracles disagreeing, every unresolvable direct-call spelling/opcode, an indirect call, malformed function-psect ownership, no entry point, and a device pack declaring no depth — and that it still *accepts* the psect scaffolding XC8 really emits, including the mid-body re-selection that follows every inline-asm escape. Fixtures reproduce the full declaration/marker/re-selection sequence, so a rule that cannot read a real image fails here first. Synthetic, so it needs no toolchain. | Bash + awk |
| Soak rebuild determinism | `test-pic-build-rebuild` | All three chips' soak binaries compile their workload sizing in as `-D` flags, so their file rules must be *unconditionally* out of date. Asserts a changed duration recompiles with the new value, and that an identical rerun recompiles too — the signature of `FORCE`, as opposed to a rebuild that merely followed a timestamp. Populates its scratch repository with the shared `test/scratch_tree.sh` walk, then blanks each named prerequisite: contents cannot matter to a staleness decision, and a prerequisite that has been renamed or dropped is reported instead of silently shrinking the fixture. | Bash + fake c++ |
| Soak timing/liveness contract | `test-soak-timing` | Native Classic AVR/PIC soaks require the liveness interval within the total duration; short release rehearsals clamp it so every passing run completes a responsiveness round-trip. A rapid PIC retrigger fixture proves multi-ms holds are sampled every millisecond, and a fake AVR-XT simulator resets during the final round-trip hold to prove the witness is checked before verdict. | host C/C++ compilers + release CLI + fake simulator |
| Soak watchdog witness | `test-soak-reset-witness` | The Classic AVR soak's `watchdog_failures` counter is release evidence, so a real watchdog reset must be able to reach it. Builds the soak driver twice against the same healthy ATtiny85 image — untouched, and with a fixture that disables the timer interrupt mid-run — and requires the first to pass with `watchdog_failures=0` and the second to fail with a nonzero one. The control half is what stops a permanently broken soak from satisfying the failing half on its own. | simavr + host C compiler |
| Release image reproduction | `test-release-images` | Committed images, `SHA256SUMS`, and fresh builds must each exactly match Makefile `RELEASE_IMAGES` before byte reproduction is accepted. Production pins the repository Makefile and ignores inherited `RELEASE_EXPECTED_IMAGES`, GNU Make flags, variable assignments, environment precedence, and injected makefiles; synthetic empty, malformed, duplicate and incomplete canonical sets run the unchanged verifier beside a test-only Makefile. | Bash + synthetic image trees |
| Release qualification contract | `test-release-qualification` | Publication requires clean production metadata, the exact canonical 28-file evidence set, and one identity-, duration-, and counter-bearing result for each of 15 release soak combinations. | Bash + synthetic retained evidence |
| Release preflight contract | `test-release-preflight` | The real release step 0 reaches its final executable-version probe without cleaning, building, staging, or changing tracked/nonignored worktree content. Synthetic selected tools and nonempty pack/header fixtures prove avr-libc, simavr/libelf, both gpsim lanes, analysis paths, complete yasimavr imports, safe Make argument routing, and absolute-venv routing fail closed. Focused copy-boundary fixtures additionally prove classic-AVR source and staged-byte mutations cannot reach checksum acceptance. | Bash + synthetic selected toolchain + base host utilities |
| Release provenance contract | `test-release-provenance` | Final images are rechecked immediately before staging, including a final classic-AVR HEX digest regenerated from the validated ELFs and a post-copy comparison that dominates `SHA256SUMS`. Exact rename/change evidence compares against baseline checksum bytes whose detached signature first verifies against the pinned release key. Modified manifests and missing, empty, symlinked, malformed, or wrong-key signatures fail before any baseline hash is parsed. Tag CI independently regenerates applicable evidence from its clean-build image paths, requires a byte-identical committed report, and publishes the digest-rechecked frozen copy. | Bash + GnuPG + isolated release fixtures |
| Release history/signature contract | `test-release-history` | The tag event must peel to an artifact-only, single-parent child of the exact qualified source. `SHA256SUMS.asc` and the exact remote annotated tag must verify against the pinned full-fingerprint key in an isolated keyring; altered bytes, missing/malformed/wrong-key signatures, lightweight/unsigned/same-target-replaced tags, and moved tags are rejected immediately before publication. | Bash + GnuPG + scratch Git repositories |
| yasimavr venv fetch safety | `test-fetch-yasimavr` | Caller-selected destinations are canonicalized and cannot name roots, symlinks, files, or unstamped directories. Offline fake tools prove failed builds preserve the old owned venv and only a fully verified sibling tree is renamed into place. | Bash + synthetic toolchain |
| External supply-chain integrity | `test-supply-chain` | XC8 and PIC DFP bytes must match reviewed hashes before `sudo`; restored ATtiny_DFP files are re-hashed; yasimavr dependencies are wheel/hash-locked and built without dependency resolution; both workflows use one installer and hash-sensitive cache keys. | Bash + synthetic downloads/toolchains |

`pic10f322-test-gpsim` now samples one non-settled point, `PRESS1_EARLY`, roughly
6 ms (3,000 instruction cycles) after the first press edge. A correct 1 ms tick
has not yet accumulated the eight separated pressed samples needed to toggle, so
the LED must still be off.
This catches a collapsed tick gate, for example if `TMR2IF` stopped being cleared
and the main loop free-ran through the debounce threshold. The same wrapper also
asserts full BYPASS `LATA` at startup and after the second press, so analog-switch
control pins are checked in both settled directions, not just the LED bit.

`pic10f322-test-target-variants` is the gate to use when a PIC result must be
authoritative. The component libgpsim targets remain useful standalone commands,
but they are allowed to skip for missing tools; the aggregate turns any skip or
missing PASS marker into a failure. It also requires the complete supported
variant matrix before starting its first target, so an empty, malformed, or
incomplete matrix cannot report an all-variants PASS or leave a partial run.

Both of this part's aggregates run in CI's shared `pic` job and in
`scripts/ci-local.sh`, and `test-workflow-syntax` compares the two files'
per-part lane sets in both directions — the job-list check above is at job
granularity, and one job now carries three parts, so a part could otherwise be
dropped from either side with every other gate green.

`pic12f675-test-target-variants` is the same gate for that part, built from the
same two regressions above, and `pic12f675-test` is its pre-hardware aggregate:
CONFIG decode, static analysis, shipping-source coverage, the calibration
contract, the gpsim CLI lane, and the hardware return-stack bound. The
calibration contract is listed there rather than left to the lanes, which all
depend on `pic12f675-simcal` and so *produce* the derived images no matter what.
What no lane checks is that producing them left the shipping images untouched --
the one property whose failure would ship a HEX different from the one the
simulator lanes qualified, and one no other part can have, because no other part
derives anything.

Debounce thresholds define a 33-sample pure-model minimum between press onsets.
That is also the nominal 33 ms physical minimum on ISR-driven AVR targets and the
simple polled PIC variant. PIC mute and relay actuation blocks the polling loop
for 5 ms and 12 ms after a toggle, so qualification uses conservative 38 ms and
45 ms physical budgets. A latched TMR2 flag normally preserves one pending
post-block sample, making the ideal path roughly one tick shorter; the PIC soak
deliberately adds the full active variant block to every liveness window.

Those figures are *samples converted at one sample per millisecond*, which holds
only where the tick is 1.000 ms. The PIC12F675 tick is 1.024 ms, so the same
thresholds are 8.19 ms and 25.6 ms and the three budgets become roughly 34, 39
and 46 ms. The soak does not carry those numbers as constants: its adapter states
the part's tick period and the shared core converts each threshold to
milliseconds, rounding up, before adding the block and the slack. The blocking
actuation itself does *not* scale -- a coil pulse and a mute delay are wall-clock
waits, not tick counts -- so it is added in milliseconds on every part.

`pic10f322-test-fault` first requires exact startup `WPUA=0x08` and `TRISA=0x08`, then
injects every guarded direction, settled-output-latch, SFR, and SRAM fault at the
behaviorally identified main-loop `CLRWDT`, including every RA0..RA2 direction
flip (the exact-TRISA gate covers the simple variant's spare RA2). Register
identity, injection readback, and the expected per-variant check count are all
fail-closed test invariants.


## PIC10F320 target validation layers

The PIC10F320 is the one target whose verified core is *hand-inlined* into the
firmware instead of compiled in, so it carries validation layers no other target
needs. Three documents divide this target between them, and each owns one thing:
`docs/pic10f320_special_case.md` is the authoritative statement of *why* the
target needs a different assurance route, `docs/pic10f320_validation.md` records
*what was actually run and what it returned*, and this section is the current
inventory — targets, substrates, mechanics and check counts. Counts and command
lists are kept here alone so the other two cannot go stale against the suite.

The split that matters here: **the first four layers need only a host C compiler
and gcov**, so they are members of `make test` and run on every push regardless
of whether XC8 is installed. The return-stack oracle and expected-image
checker's dependency-free Python 3 selftests are there too. The real-image
layers need the PIC toolchain and behave
like the PIC10F322 layers above, except that the expected-image and return-stack
targets are always fail-closed rather than skip-clean.

| layer | target | what it proves | substrate |
|---|---|---|---|
| Firmware↔core equivalence | `pic10f320-test-equiv` | The real firmware, host-compiled, stepped tick-for-tick against `src/bypass_pure.c` over 266,144 stimulus sequences, visiting all 66 reachable model states, with zero divergence. This is the layer that closes the inlining seam. | host C |
| Actuation sequence | `pic10f320-test-actuation` | Each variant's full *settled* `LATA` at every tick, plus the mute/relay *mid-actuation* sequencing and pulse width that a settled snapshot cannot see. | host C |
| Host fault injection | `pic10f320-test-fault-host` | Corrupting a guarded SFR or the debounce context forces the sanity gate to take the watchdog-reset path. The relay variant additionally injects RESET, SET, and both coil-latch bits and requires correction within one completed iteration without a press or reset: 41 / 41 / 59 checks. | host C |
| Shipping-source coverage | `pic10f320-coverage-check-fw` | An **exact** property, not a percentage floor: every line of the real firmware is host-executed except an enumerated, justified watchdog-reset path. Run per variant, because the three output stages give 84 / 95 / 100 executable lines. | host gcov with the mock `xc.h` |
| All-variant host aggregate | `pic10f320-test-host-variants` | The four layers above across all three variants, with the complete supported matrix required first. **This is the member of `make test`.** | Makefile wrapper |
| Return-stack oracle regression | `test-pic10f320-return-stack-oracle` | 149 deterministic checks: passing depths through 8, recursion/depth-9 rejection, independently required skip edges and operand boundaries, classic alias ranges, all 16,384 legality decisions, every destination writer against PCL/INDF/INTCON, 9-bit PC/physical-fetch aliasing, literal HEX layout, and fail-closed parser/file cases. Includes ten device-geometry checks: `--program-words` is validated as a power of two inside the 9-bit PC space, and fixtures whose verdict *differs* between the 256- and 512-word geometries pin the fetch alias in both directions — an image with code above word `0x0FF` is rejected when 256 words are declared, and one that relies on the fold is rejected when 512 are. **This is also a member of `make test`.** | dependency-free Python 3 |
| Image generation | `test-pic-build` | 36 PIC10F322, 75 PIC10F320, and 81 PIC12F675 checks. All three runs prove missing-XC8 skips remove the complete product matrix despite attempted inventory overrides, stale assembly/symbol sidecars cannot survive a current-HEX-only build, and shell syntax in matrix text is rejected without execution. The 322 run additionally rejects recursively self-whitelisting GNU Make input; the 320 run covers selector rebuilds, deletion of reachable-RETFIE and depth-9 images despite attempted oracle/limit overrides, exact per-output XC8/host-compiler rebuild invocations with current clock/variant/host flags, and matching/mismatching/malformed/missing expected-image gate inputs. The 675 run adds exact simulator-image publication, calibration consumers, selected-variant/private-snapshot programming, read-only trim baseline capture, required/malformed/unreservable evidence rejection, immediate pre-write comparison, exact pk2cmd/ipecmd write argv, post-read programmed-byte/CONFIG verification, no-op/failed/interrupted-writer rejection, retained OSCCAL/BG pass/fail evidence, external image/command refusal, overlap and path-replacement rejection, CLI, target-I/O, lock-step, fault-injection, soak, failed-producer cleanup, signal cleanup, and zero-image skip/strict checks. | host fake-XC8/fake-CC regression |
| Expected image bytes | `test-pic10f320-expected-images`; `pic10f320-test-build` | The dependency-free checker pins exact manifest grammar and fail-closed file handling in `make test`; the full-tool target rebuilds the immutable three-variant matrix and compares each raw HEX file with the reviewed XC8 V3.10 / DFP 1.9.189 SHA-256 baseline. Kept out of mutation kill targets so a broad byte mismatch cannot mask a weak behavioural oracle. | Python 3; pinned XC8/DFP for the real-image comparison |
| CONFIG word | `pic10f320-test-config` | The emitted CONFIG word matches design intent, over every built image. Uses the shared checker with a device-accurate label. | host parser over HEX |
| Hardware return stack | every `pic10f320` build; `pic10f320-test-return-stack` | The base build strictly parses and traverses its final HEX before marking that image complete, so gpsim/target/soak/release rebuilds use the same fail-closed gate. The explicit target rebuilds the supported matrix and rechecks all three together, reporting each maximum and witness. | dependency-free Python 3 over final HEX |
| Static analysis | `pic10f320-analyze` | cppcheck + MISRA over the shell, **swept across all three variants** — each compiles a different `#if defined(OUTPUT_*)` branch, so one run would leave two thirds unanalyzed. | host tools |
| Register-level functional | `pic10f320-test-gpsim` | Real HEX toggles on press and handles a power-on-held switch via the shared wrappers, with the processor and chip-specific toggle-cadence stimulus overridden. | gpsim CLI |
| Fault recovery | `pic10f320-test-fault-target` | The host fault argument re-made on the real emitted image: every guarded SFR/SRAM location and required `TRISA` direction, plus relay-only RESET, SET, and both-coil physical `PORTA` correction within one serviced iteration and without reset: 22 / 22 / 25 checks. | libgpsim |
| HEX/model lock-step | `pic10f320-test-lockstep` | Live `_ctx_` SRAM from the XC8-built instruction stream matches `src/bypass_pure.c` after every completed main-loop iteration — 3,005 checks per variant, 66/66 states. | libgpsim |
| Target I/O timing | `pic10f320-test-io` | Exact `TRISA`, physical `PORTA` following every `LATA` transition, each variant's complete transition sequence, and mute/relay pulse widths from simulator cycles. | libgpsim |
| Fail-closed aggregate | `pic10f320-test-target-variants` | Rejects any matrix other than the complete supported set, then requires fault, lock-step and target-I/O PASS sentinels for every variant. | Makefile wrapper |
| Pre-hardware aggregate | `pic10f320-test` | The single target CI and the release script invoke: the host aggregate, expected-image hash, CONFIG and return-stack proof over all images, and analysis + gpsim per variant. | Makefile wrapper |
| Soak | `pic10f320-test-soak` | Long-duration libgpsim soak per output stage; three combos at full duration are part of release qualification. | libgpsim |

The shared stale-sidecar and matrix cases run in all three parameterized
`test-pic-build` invocations; the PIC10F320 rebuild cases run only in the second.
The script itself requires
`PB_REBUILD_REQUIRED=1` for canonical `PB_TARGET=pic10f320` and enforces exactly 75
final checks; canonical `PB_TARGET=pic10f322` enforces 36 and
`PB_TARGET=pic12f675` enforces 67. A missing or misspelled rebuild/matrix arm
assignment therefore fails instead of reporting a smaller subset as green.

In a fresh temporary repository the arm proves that identical requests reinvoke
the compiler for `pic10f320`, `pic10f320-test-equiv`, `pic10f320-test-actuation`, and
`pic10f320-test-fault-host`. After each initial request it creates a regular
same-name file in the sandbox root before repeating, so removing the target's
`.PHONY` declaration makes Make skip the recipe and fails the exact invocation
count. Every fake linked host test also logs its executed path; execution counts
must advance with compile/link counts, catching a removed binary-run recipe.
Variant/clock/host-flag changes and restorations are checked against the latest
applicable command, not any historical log entry, and the unqualified shared
equivalence harness must be recompiled with the current output macro after both
variant transitions. This is deterministic
**rebuild triggering with the current flags**, not byte-for-byte XC8
reproducibility. Byte identity is enforced separately by `pic10f320-test-build`.
The coverage lane needs no stable-output probe: every request
uses a new `mktemp` directory and requires fresh `.gcda` and `.gcov` evidence
before that directory is removed.

Note what `pic10f320-test-equiv` and `pic10f320-test-lockstep` run *against*. Both
compile and link `src/bypass_pure.c` — the same file every other target compiles
into its shipping image, not a vendored snapshot of it. That is the property the
whole layer stack rests on; `docs/pic10f320_special_case.md` §3 argues why.

`return_stack_oracle.py` does not consume a compiler listing or trust a
disassembler. It requires a nonempty, non-symlink regular file; validates every
Intel HEX count, checksum, record type, address, overlap and unique EOF; then
forms PIC14 words little-endian. CONFIG and other unreachable data are ignored,
but an absent byte on a reachable instruction is a hard failure, as is a return
taken with an empty stack. Its command-line depth default is eight and the
Makefile limit is immutably eight. Its documented
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
strict about receiving normalized architectural PCs. Every successful `pic10f320`
recipe runs that oracle before setting its completion flag, inside the existing
cleanup trap. The explicit
`pic10f320-test-return-stack` target is still valuable: it rebuilds and rechecks the
whole immutable supported matrix in one reported invocation. This is execution-
time enforcement, not a claim that a later staged/copied artifact cannot be
modified; release provenance and reproduction checks remain separate controls.


## MISRA output contract

`make test-misra-output-contract` closes a cppcheck 2.13.0 status gap: a
diagnostic attributed to an included header is printed without affecting
`--error-exitcode`. Every MISRA recipe therefore requests one strict record
format and passes its captured stderr to `misra_output_gate.py`, which normalizes
paths and fails unwaived diagnostics in authored `src/*.c` and `src/*.h` files.
Malformed stderr and nonzero tool status fail as infrastructure defects; adopted
toolchain, `third_party/`, and test paths remain outside the firmware compliance
boundary. Unattributed pseudo-path diagnostics also fail because they have not
been shown to belong to adopted code.

The host-only regression exercises the parser directly and then drives the
Classic/shared, AVR-XT, PIC10F322, PIC10F320, and PIC12F675 recipes with fake
device-pack headers and fake cppcheck. Its zero-exit Required-rule finding in an
authored header must fail all five lanes. An exact `rule:file` suppression must
restore success, while a right-rule/wrong-header suppression must not. A rule
census and severed-call fixture keep every recipe attached to the parser, and
the fake argv log rejects any return of invocation-wide `misra-config`
suppression. The committed suppression inventory is pinned to exactly the three
PIC shell source paths, and a `misra-config` record in an authored header remains
failing.

## Mutation testing and skipped optional tools

`make test-mutation` includes PIC mutants whose kill targets need XC8, gpsim, and
libgpsim, plus ATtiny202 mutants whose kill targets need the vendored ATtiny_DFP
and the patched yasimavr venv. A local host without those tools may run an
explicitly partial mutation suite with `MUTATION_ALLOW_SKIP=1`; that is the
non-strict default so development on one substrate stays practical.
`STRICT_TOOLS=1` changes the default to fail closed, and full-tool CI also pins
`MUTATION_ALLOW_SKIP=0`. An explicit `MUTATION_ALLOW_SKIP` value takes
precedence: `ci-local.sh --skip-pic` retains strict host/AVR gates but
deliberately passes `1` for its partial mutation run, as does
`--skip-attiny202`; specifying either or both target-toolchain skips must not
make the intentionally partial `test-long` fail closed. The summary counts PIC
and ATtiny202 skips separately, so a partial run always says which substrate
went unexercised rather than reporting one anonymous number.

The PIC mutation set includes target-level faults for the new coverage: collapsed
TMR2IF cadence, exact-TRISA predicate removal, output-latch mask narrowing,
exact WPUA pull-up state, ANSELA mask narrowing, muted-CD4053 startup
reassertion, mute-window shortening, relay pulse shortening, and removal or
one-coil weakening of the PIC10F320 relay idle safe-state rewrite.

**Which lane owns the Classic AVR watchdog matters, and is easy to get wrong.**
The two long-standing watchdog-handshake mutants both run on `test-sim-cd4053_simple-attiny13a`,
which is the ATtiny13a build — and simavr 1.6 does not model the ATtiny13a WDT
system reset at all, so no assertion on that lane can witness one. They are
still killed, but not by the watchdog: deleting the `hw_wdt_pet()` call site
leaves the function unused and fails the build under
`-Werror=unused-function`, and breaking the ISR handshake stops the debounce
state machine so the functional, noise-count and lock-step assertions all fail.
The behavioural watchdog fault therefore has its own mutant, which empties
`hw_wdt_pet()` at its definition (so the call site remains and the build stays
clean) and runs a short `test-soak` on the ATtiny85, where simavr *does* model
the reset. The soak's reset witness records it in `watchdog_failures`. This
gives the Classic AVR the soak-lane mutant the PIC and ATtiny202 families
already had.

**PIC12F675 mutants are one table, not three, and are chosen for what this part
has that the 10F32x parts do not.** All 14 need XC8 plus gpsim or libgpsim plus
the derived simulator images, so there is no host-only lane for them to fall
back to and nothing to split. Copying the 322's list would mostly have re-proved
the shared pure core, so the set targets the SRAM output shadow (a severed
write-back, each of shadow-versus-expected and port-versus-shadow independently
turned into a tautology, and physical divergence the 322 cannot express because
its port and latch are two views of one register),
the software sub-tick counter that stands in for the period register this part
lacks, the comparator and OSCCAL-trim guards that have no 322 counterpart, and
ANSEL's off-by-one mapping (GPIO bit 4 selects ANS3). Kill targets are assigned
by what each fault actually perturbs and that assignment is load-bearing: moved
to the gpsim CLI lane, the defeated comparator guard survives.

**PIC10F320 mutants are split by what they NEED, not by what they test.** 29 of
them are killed by the host lanes and require only a C compiler, so they ride
with the unskippable core batch; 11 need XC8 + gpsim + libgpsim and sit behind
their own tool probe, which first verifies every distinct kill command against
the *unmutated* tree. Without that split they would "survive" on any host lacking
the PIC toolchain; without the per-command baselines, a broken gpsim or soak
harness could make them die for an infrastructure reason and falsely count as
killed. Skip accounting is wired through the same policy resolver, so a partial
run cannot be mistaken for full PIC10F320 coverage.

These counts are pinned here and nowhere else; how the inventory reached its
current shape — the merge-time 74-mutant run, the audit that invalidated one
kill, and the sandbox gaps that briefly cut it to 56 — is recorded in
`docs/pic10f320_validation.md` §5.

The driver independently pins the eight mutation categories at **24 core/AVR +
19 AVR-XT + 29 PIC10F320 host + 11 PIC10F320 tool + 6 PIC gpsim + 1 PIC soak + 8
PIC target + 14 PIC12F675 = 112**. It rejects category drift before probing, then
requires dispatched + skipped = 112 and killed + survived + errored = dispatched. Every
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
result grammar in 62 checks. `MUTATION_TIMEOUT_S` defaults only when unset and
accepts `0.001..86400` seconds with at most three fractional digits; zero,
negative, empty, malformed, under-resolution, and over-limit values fail before
any Make or tool probe. Every bounded checker owns a registered process session,
so normal return and interrupted-run cleanup reach nested timeout groups as well
as Make, compiler, and simulator descendants. The regression interrupts both a
nested-timeout session with a TERM-ignoring descendant and an unregistered
launch-gap worker, then proves their PIDs and process groups disappear. It also
makes a failed PIC10F322 baseline build
leave an apparently usable HEX, then proves the probe reports `baseline FAILED`
without invoking gpsim or enabling mutants; ordinary nonzero checker statuses
can count as kills only after a successful baseline admits the lane.

That copy routine is **`test/scratch_tree.sh`**, shared with the other harness
that builds a throwaway repository and runs Make inside it,
`test/test_pic_rebuild.sh`. The two used to learn about a new file by different
means — this extension allowlist walk versus a hand-enumerated prerequisite list
— and one prerequisite added to the PIC soak rules broke each of them in turn.
The walk is now the single mechanism, so a new substrate, a nested harness, or a
target that gains a prerequisite needs no edit in either. Two properties of the
walk are load-bearing and documented at length in the file: it stays an
**allowlist** (a wholesale `cp -a test/` would drag in build products, and `cp -a`
preserves mtimes, so a stale binary copied in newer than its source makes Make
skip the rebuild and score a mutant against unmutated code), and it must never
require a **Git repository**, because these sandboxes have no `.git`.

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
AVR-XT's only route to an absolute pulse width. As described under "Known gaps"
above, the output tracer calls `SimLoop.run(1)`; the pinned yasimavr rewinds any
instruction overshoot on return, effectively billing every traced instruction
one cycle even though its core models multi-cycle instructions.


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
  `make pic10f322-test-config` proves `WDTE`/`BOREN` are *enabled*; their real-time
  behaviour is a bench concern. `make pic10f322-test-soak` exercises WDT *liveness* and
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
