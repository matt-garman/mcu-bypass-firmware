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
  check_pic_data_budget.sh  shared: exact XC8 Data-space budget checker
  check_stack_usage.sh      shared: GCC -fstack-usage record/frame checker
  check_stack_depth_pic.sh  shared: PIC hardware return-stack depth gate
  python_version.py         shared: Python 3.7+ host-gate prerequisite
  host_compiler_version.sh  shared: GCC 10+/Clang host-gate prerequisite
  test_attiny202_build.sh   shared: fail-closed AVR-XT build checks
  test_avr_build_rebuild.sh shared: classic AVR rebuild/partial-output checks
  test_avr_program_order.sh shared: AVR *-program build/validate-then-fuse-then-
                                    flash transaction order (fake programmer)
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
  test_resource_tables.py   shared: current resource documents agree and their
                                    arithmetic/derived claims recompute; the
                                    release-only strict mode additionally
                                    requires all 21 images plus retained
                                    RAM/stack evidence bound to source HEAD
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
                                      their inputs are broken; near-bound
                                      fixtures additionally pin the watchdog
                                      pet-to-pet budget to its exact millisecond,
                                      convert wall-time ISR duty independently,
                                      prove ISR/tick/loop terms are load-bearing,
                                      and reject the former mixed formula
  test_pic_build.sh         shared: named PIC image/size/rebuild profiles
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
  test_strict_tools.sh      shared: skip/strict policy for host + all three PIC parts
  test_supply_chain.sh      shared: external download/cache/action pin checks
  test_target_lane_markers.sh shared: PIC aggregate fail-closed result regression
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
                                (includes the pet-budget check: the longest
                                 wdr-to-wdr interval measured on the real image
                                 must fit the compile-time watchdog budget)
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
           test_attiny202_delay_oracle.py  compiled delay widths + tick-ISR
                                          instruction ceiling; host parser tests
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
                                  built HEX, mask it, compare against intent;
                                  its single-image programming mode emits one
                                  exact image/word-bound PASS record
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
                                  but with no output-latch SFR the simulation can
                                  compare SRAM intent with modeled GPIO/readback
                                  state, which the 32x lanes cannot express
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
                                   the pins. Relay cases also attach directly to
                                   physical GP1/GP2 nodes and cover the complete
                                   single-bit comparator-mode neighborhood, so
                                   low GPIO intent cannot masquerade as a
                                   de-energized pad. CD4053 lanes retain the
                                   representative mode-110 guard case. The relay
                                   lane runs all three modes one bit from
                                   comparator-off through full escalation: 011
                                   and 101 route COUT to the GP2 pad and must
                                   drive it High and reject a latch-only clear,
                                   while 110 must leave GP2 under GPIO.
                                   Parked GP4 is injected through its direction,
                                   shadow, pin and ANS3 guard paths
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
            pic12f675_matrix_evidence.py
                                  stages and re-verifies one retained shipping/
                                   simcal matrix plus consumed .s/.sym sidecars,
                                   exclusively promoting the qualified manifest
                                   only after reproducibility checks; aggregate
                                   PASS records expose all twelve artifact hashes
            pic12f675_trim_evidence.py
                                  independently parses pk2cmd device exports and
                                  exclusively publishes strict baseline/result
                                  JSON with raw tool transcripts and OSCCAL,
                                  CONFIG, BG, Device ID/revision, executable and
                                  image identities (make pic12f675-preflight;
                                  make pic12f675-program or
                                  make pic12f675-release-program; recover PENDING
                                  evidence with make pic12f675-finalize)
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
check count, and output-latch guard SCOPE: PIC10F322 runs reset-producing LATA
injections because it has a general latch-integrity guard. PIC10F320 omits that
general guard and guards only the two relay coil latch bits. The RESPONSE no
longer differs between them -- an energized coil resets on every part -- so both
relay adapters run the same five `inject_relay_resync_case()` cases, which
require de-energization before the reset spin and a measured full-width
RESET-coil actuation after the recovery, delivered from both a settled BYPASS and
a settled ENGAGED start. PIC12F675 adds one
`inject_parked_output_resync_case()` on top: with no `LATx`, its escalation
publishes the whole output shadow in one write, so parked GP4's pad is required
Low at the watchdog spin alongside the coils.

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
| Image generation | `test-attiny202-build` | Missing, partial, or malformed avr-gcc output cannot become an ATtiny202 image; exactly one valid `Program:` and `Data:` record is required, with 2048-byte flash and 16-of-128-byte static-RAM limits enforced per variant. | host fake-compiler regression |
| Shell stack frames | `attiny202-test-stack-bound`; `test-stack-bound-regression` | The real AVR-XT shell is compiled once per immutable production variant with shipping flags plus `-fstack-usage`; every fresh static frame must fit 32 bytes. The host regression pins exact routing and rejects missing, malformed, dynamic, stale, extra, and oversized evidence without requiring the DFP. | avr-gcc + ATtiny_DFP; host fake compiler |
| Fuse configuration | `test-fuses` | All seven AVR8X fuse bytes match design intent, and the simulator's descriptor is patched to those exact production values rather than falling back to defaults. | host parser |
| Golden-model bridge | `test-attiny202-model-ffi` | The ctypes bridge reaches the shipping pure core and behaves correctly at the `>=` press-threshold boundary, both saturation bounds, the lock-out, and a full round trip — independent hard-coded expectations, not another comparison against the model. | host |
| Output-sequence oracle | `test-attiny202-output-oracle` | The PA2/PA3 transition, ordering and pulse-presence checker itself is correct. | host |
| Fault accounting oracle | `test-attiny202-fault-oracle` | The fault driver's run accounting cannot silently under-count injections, latch-only physical-pin handling is rejected, and the reviewed AVR-XT/PIC12F675 emergency register-write order is pinned. | host |
| Coil-pulse width / ISR ceiling | `attiny202-delay-oracle` | Compiled relay (12 ms) and mute (5 ms) delay-body cycle counts, recovered from the disassembled `_delay_ms` loop in the built image, match design and clear the 4 ms datasheet minimum. The sole `reti` handler and its complete direct call tree stay at or below the reviewed 84-instruction ceiling; recursion, unresolved or indirect transfers, and cyclic intrafunction control flow fail closed, while acyclic branches to earlier shared epilogues remain countable. Four cycles per instruction plus a 16-cycle interrupt-entry/vector allowance bounds the complete response at 352 of 2000 tick cycles, below 25% duty. Timer-ISR preemption makes the edge-to-edge pin-high interval slightly longer. Every recognized loop candidate must provide a decodable 16-bit seed; no candidate can be dropped as missing evidence. | host, over real image |
| Static analysis | `attiny202-analyze` | cppcheck + MISRA pass over the AVR-XT shell with real DFP/avr-libc headers. | host tools |
| Register-level functional | `attiny202-sim` | The real image toggles on debounced press, boots dark with the WDT locked and `PORTA.DIR` exact, stays stable at idle, handles a switch held through power-on, and drives the correct PA2/PA3 sequence per variant. | yasimavr |
| Fault response | `attiny202-fault` | 24 selected SFR/latch/state/pin-polarity corruptions (32 on the relay variant) each produce the correct response: the sanity gate's force-reset path, a witnessed watchdog reset for the tick timer itself, safe overwrite at the ISR/main persisted-context transaction seams, or relay-coil escalation with modeled PA2/PA3 pin levels low and OUT/DIR/PINnCTRL canonical before the spin. Relay fixtures cover both coils' INVEN, pull-up, direction, combined stale-register state, and OUT faults from BYPASS and ENGAGED. Zero skips, exact completion accounting over 25 (33) results. | yasimavr |
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
  is billed exactly 1 cycle.

  No timing or pulse-width assertion advances that way any more. The output tracer used to
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
  bug. The fault driver has one deliberate non-timing exception: its persisted-
  context transaction probe uses `run(1)` only to expose every instruction PC
  and stop at an exact function-entry seam. Its bound is an instruction-step
  count, and all behavioral/output observations run afterward in normal
  millisecond budgets; no timing claim is derived from those steps.
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
- **No complete AVR-XT call-depth bound.** `attiny202-test-stack-bound` now
  constrains every AVR-XT shell frame, while `test-stack-bound` covers the shared
  core and drivers. Like any `-fstack-usage` gate, these are per-function frame
  limits rather than a whole call-chain/interrupt high-water measurement.
- **UPDI programming is untested on silicon.** The `attiny202-program` recipe and
  its fuse writes have not been exercised against a real part.


## PIC12F675 shipping-source coverage

`make pic12f675-coverage-check-fw` host-compiles the real
`bypass_mcu_pic12f675.c`, shared pure core, and all three unmodified output
drivers under gcov. It needs only Bash, a host C compiler (GCC 10 or
newer, or Clang), and matching gcov; XC8, the device pack, and gpsim are not
involved. **This is a member of `make test`**, which is why the absence of a PIC
toolchain does not exempt a PIC12F675 change from this oracle.

The shared coverage harness selects a PIC12F675 mock `<xc.h>` that preserves the
classic-PIC distinctions the firmware depends on: GPIO intent and physical pin
levels are separate, externally driven GP5 survives whole-port writes,
`OPTION_REG`/`nGPPU` and `ADCON0`/`ADON` share their respective backing bytes,
and each `T0IF` access supplies the next of the four polled TMR0 subticks. Runtime
checks pin the implementation-defined host bitfield layout before it can count
as firmware evidence.

On PIC12F675 every output variant runs an exact 86-check base predicate, fault,
happy-path, and post-check transaction matrix. The relay variant runs 105
checks: four coil-escalation cases each add a de-energization assertion on top of
their reset assertion, 12 active-pulse cases characterize active-low and
inactive-high faults at 1, 6, and 11 ms in both SET and RESET, and three
shadow-order cases require RESET, SET, or both coil bits to clear before one
whole-port write with no intermediate high modeled-GPIO write. The relay
variant's parked-GP4 shadow case adds no check and changes no total: it reads the
modeled pin where the harness escapes the watchdog spin -- the escalation's one
whole-port write must not publish a corrupt GP4 intent bit to the pad -- folded
into the single check the CD4053 arms already spend there. The same
shared-driver pulse matrix raises the PIC10F322 relay count from its 53-check
base plus two coil-escalation assertions to 67.
The active-pulse cases record and check the actual modeled injection offset,
count every post-injection millisecond, require the injected state to persist
through that interval, and require the modeled outputs to finish low. They
explicitly do not claim that an external output accepts the command or that
mechanical actuation or audio disruption is prevented. The coverage oracle then
requires every executable line in all five
shipping sources except one exact, documented defense-in-depth call: invalid
context is caught by the main-loop range gate before `debounce_step()` can
return `res.fault`. The live sanity-gate call to `hw_force_wdt_reset()` is a
positive coverage requirement, so the allowance cannot hide a harness that
never enters the real reset path.

Both requirements are anchored to the *source text* of the constructs they
name, never to line numbers, and locating an anchor is itself fail-closed: text
that matches zero records, or several, fails the gate rather than silently
checking nothing. The two `hw_force_wdt_reset()` call sites are identical text,
so they are separated by file order under a requirement that exactly two exist
-- the allowance covers the res.fault one alone and cannot slide onto the live
one.

## PIC target validation layers

Real-tool PIC targets are intentionally outside the default AVR `make test` path:
XC8, the PIC10-12Fxxx DFP, gpsim, and libgpsim may be absent on a normal AVR
development machine. The fake-XC8 `test-pic-build` regression is host-only and
is included in `make test`; targets needing external PIC tools may skip cleanly.
The host source-coverage gate requires Bash, a host C compiler (GCC 10 or
newer, or Clang -- `host-compiler-valid` is a prerequisite of all three
`*-coverage-check-fw` targets), and matching gcov. CI/release use `STRICT_TOOLS=1` plus the fail-closed aggregate described
below so a green gate means every PIC layer actually ran.

The line that decides membership is the **tool contract, not the part**. All
three `*-coverage-check-fw` gates need only that host compiler, gcov and Bash,
so all three are members of `make test` and `make test-long` and run on every
push whether or not a PIC toolchain is installed: `pic10f320-coverage-check-fw`
through the `pic10f320-test-host-variants` wrapper, and
`pic10f322-coverage-check-fw` and `pic12f675-coverage-check-fw` directly in the
shared gate inventory. The two direct members cost about 8 s and 12 s.

This is a correction, not a convenience. Both were previously reachable only
through the standalone `pic10f322-test` / `pic12f675-test` aggregates, whose
*other* lanes do need XC8 and gpsim -- and `pic12f675-test` skips its whole
matrix when XC8 has qualified nothing, so on an AVR-only host the PIC12F675
coverage gate did not run at all despite needing nothing XC8 provides. A stale
host fault oracle, a compile configuration that was not the shipping one, and a
`check_fw_coverage.sh` anchor matching zero lines all coexisted with a green
`make test` for the length of a polish branch as a result. The standalone
aggregates still run both gates, so nothing was moved out of them.

| layer | target | what it proves | substrate |
|---|---|---|---|
| Image generation | `test-pic-build` | Missing, partial, malformed, or non-regular XC8 output cannot become a PIC firmware image; malformed/zero budgets, huge usage counts, and arithmetic-tool failures are rejected. The PIC10F322 and PIC12F675 producers require immutable complete matrices. PIC12F675 additionally proves exact simulator derivation, complete-set cleanup/consumption, and variant-bound hardware programming through a digest-checked private snapshot. Its fake programmer pins read-only baseline capture, immediate pre-write identity/trim comparison, exact pk2cmd/ipecmd write argv, post-write OSCCAL/BG comparison, retained pass/fail records, and refusal of a device export that relocates addresses. Same-stem `.s`/`.sym` are invalidated with the HEX, and a current HEX without fresh assembly fails the stack target rather than skipping. | host fake-XC8 regression |
| XC8 strict parsers | `test-xc8-helpers` | The shared program-space parser accepts one internally consistent XC8 record and rejects missing, malformed, duplicate, mixed, zero, over-capacity, contradictory, and percentage-mismatched transcripts. The shared context resolver requires one non-symlink assembly/symbol pair, exactly one `_ctx_: ds 3` allocation, and exactly one hexadecimal `_ctx_` address. | dependency-free Bash/awk fixtures |
| PIC toolchain assertion | `test-pic-toolchain-assert` | The helper shared by hosted and local CI requires both selected XC8/DFP pairs, all three device headers, gpsim, both selected C++/libgpsim surfaces, GLib metadata, and cppcheck. Empty/symlinked headers and incomplete, duplicate, or unknown requests fail closed; GitHub mode emits annotations. | dependency-free fake toolchain |
| CONFIG word | `pic10f322-test-config` | The XC8-emitted CONFIG word matches the documented oscillator/WDT/BOR/MCLR/LVP design intent. | host parser over HEX |
| Static analysis | `pic10f322-analyze` | cppcheck + MISRA pass over the PIC shell with real XC8/DFP register headers. | host tools |
| Shipping-source coverage | `pic10f322-coverage-check-fw` | Every executable line in the real PIC shell, shared pure core, and all three output drivers is host-executed except the documented non-returning reset path. Compiled with `BYPASS_CTX_CHECK`, because that is what ships. **This is a member of `make test`.** | host gcov with PIC SFR mock |
| Register-level functional | `pic10f322-test-gpsim` | Real HEX toggles on press, handles power-on-held switch, keeps settled LATA/PORTA expectations, and includes the mid-debounce `PRESS1_EARLY` tick-cadence check. | gpsim CLI |
| gpsim process gate | `test-gpsim-wrappers` | Both functional wrappers require a positive decimal timeout, reject nonzero or killed gpsim runs even after complete snapshots, prove routed stimuli contain one exact footswitch attachment, and fail rather than skip missing gpsim under `STRICT_TOOLS=1`. All three public lanes are additionally probed end-to-end: each must reach gpsim with its own part's processor, so a severed `PIC_GPSIM_PROC=` cannot leave a lane simulating another chip. The PIC12F675 route exhausts all six nonempty partial simulator-image subsets and rejects empty, symlinked, or unexpected members before gpsim runs. | Bash + fake gpsim |
| Fault response | `pic10f322-test-fault` | Runtime direction, settled-output-latch, configuration, pull-up, and `ctx_` corruptions all produce WDT recovery; the relay variant additionally requires both coils de-energized before the spin — in one output write, sampled every instruction — and a measured full-width RESET-coil actuation after it. | libgpsim |
| HEX/model lock-step | `pic10f322-test-lockstep` | Live `_ctx_` SRAM from the XC8-built instruction stream matches the shared pure model after every completed main-loop iteration. | libgpsim |
| PIC simulator progress regression | `test-lockstep-progress` | All three chip routes bind their exact footswitch pin despite substring decoys and abort lock-step stalls during settle, calibration, or completion immediately. The same fake-gpsim API wedges every PIC soak adapter after startup and requires bounded failure, one short-duration result, exact advanced-cycle/time evidence, and no full-duration claim. | host C++ + fake gpsim API |
| Target I/O timing | `pic10f322-test-io` | TRISA/ANSELA/LATA/PORTA transitions, relay coil exclusion, and mute/relay pulse widths match the design. | libgpsim |
| Fail-closed aggregate | `pic10f322-test-target-variants` | Requires the complete supported matrix — empty, duplicate, unsupported, and incomplete requests are all rejected — then runs fault recovery, lock-step, and target-I/O for every PIC variant and requires each PASS sentinel. | Makefile wrapper |
| Aggregate regression | `test-target-matrix` | Proves complete matrices run exactly once per variant, that empty, duplicate, unsupported, and incomplete matrices fail before any target invocation, and that all three PIC target aggregates require explicit fault, lock-step, and I/O completion markers. | Bash + fake recursive Make |
| Aggregate fail-closed regression | `test-target-lane-markers` | Proves the PIC10F32x aggregates require each lane's explicit `PASS` marker and exercises every PIC12F675 variant-specific count-map branch against one reviewed count table. The PIC12F675 aggregate requires exactly one canonical terminal machine-result record: duplicate, malformed, diagnostic-only, wrong-device/lane/variant, zero-check, nonzero-failure, contradictory and trailing-output records are rejected. A skipped, crashed, or failing-but-zero-exit lane withholds aggregate success. | Bash + fake recursive Make |
| PIC target result producer | `test-pic-target-result-records` | Compiles the shared result emitter for all three PIC12F675 variants and pins the canonical fault/lock-step/I-O records: 38/3005/25 for `cd4053_simple`, 38/3005/26 for `cd4053_with_mute`, and 43/3005/36 for `tq2_l2_5v_relay`. This row is not hand-maintained: the gate reads these three triples back out of it and requires them to equal `pic12f675_target_count_table()`, the one reviewed oracle the Makefile count map and the adapters are also checked against. It also requires each production core to emit its lane record exactly once, outside nested preprocessor conditions. | C++17 host test + Python source contract |
| Fault-evidence watchdog note | `test-fault-wdt-note-contract` | Each libgpsim fault adapter supplies its own `PIC_FAULT_WDT_NOTE`, and the core's exact multiline banner call must pass that macro as the `%s` argument. Required per-part facts must occur inside the macro definition, not merely in comments or elsewhere in the adapter; negative fixtures pin both exclusions and reject a wrong banner argument. The core still `#error`s if an adapter omits the note, and neither part's facts may leak into the other's. | Python structural source contract | <!-- name-contract: exempt (PIC_FAULT_WDT_NOTE is a C macro, not a make variable) -->
| Hardware return-stack depth | `pic10f322-test-stack-bound`, `pic10f320-test-stack-bound`, `pic12f675-test-stack-bound` | Bounds the **8-level hardware return stack** — the PIC counterpart of the AVR's byte-valued `test-stack-bound`, and a different quantity: the PIC14 core has no data stack, and hardware-stack overflow on these parts is silent (no `STKPTR`, no `STKOVF`, no overflow reset). Computes the deepest call chain from the freshly generated instruction stream, cross-checks it against XC8's own `callstack` directives, and rejects missing/current-image assembly, recursion, indirect calls, and an over-budget build. Every variant, all three PIC targets. | XC8-generated `.s` + awk |
| Stack-depth gate regression | `test-stack-bound-pic-regression` | Proves that gate rejects each way the analysis can be wrong — over budget, recursion, an overflowing build, the two oracles disagreeing, every unresolvable direct-call spelling/opcode, an indirect call, malformed function-psect ownership, no entry point, and a device pack declaring no depth — and that it still *accepts* the psect scaffolding XC8 really emits, including the mid-body re-selection that follows every inline-asm escape. Fixtures reproduce the full declaration/marker/re-selection sequence, so a rule that cannot read a real image fails here first. Synthetic, so it needs no toolchain. | Bash + awk |
| Soak rebuild determinism | `test-pic-build-rebuild` | All three chips' soak binaries compile their workload sizing in as `-D` flags, so their file rules must be *unconditionally* out of date. Asserts a changed duration recompiles with the new value, and that an identical rerun recompiles too. The PIC12F675 arm additionally starts with no build tree, produces the complete shipping/simulator/symbol matrix through the direct binary target, and requires its symbol-derived shadow-address definition plus derived tick/block definitions in the fake C++ argv. | Bash + fake XC8/injector/c++ |
| Soak timing/liveness contract | `test-soak-timing` | Native Classic AVR/PIC soaks require the liveness interval within the total duration; short release rehearsals clamp it so every passing run completes a responsiveness round-trip. PIC12F675 timing is derived from the shell's four TMR0 subticks, 4 MHz FOSC, shared debounce thresholds, and output-header 0/5/12 ms blocks; the gate pins its 1024 us tick and 19/24/31 ms press plus 36/41/48 ms release holds. A rapid PIC retrigger fixture proves multi-ms holds are sampled every millisecond, and a fake AVR-XT simulator resets during the final round-trip hold to prove the witness is checked before verdict. | host C/C++ compilers + Python + release CLI + fake simulator |
| Soak watchdog witness | `test-soak-reset-witness` | The Classic AVR soak's `watchdog_failures` counter is release evidence, so a real watchdog reset must be able to reach it. Builds the soak driver twice against the same healthy ATtiny85 image — untouched, and with a fixture that disables the timer interrupt mid-run — and requires the first to pass with `watchdog_failures=0` and the second to fail with a nonzero one. The control half is what stops a permanently broken soak from satisfying the failing half on its own. | simavr + host C compiler |
| Release image reproduction | `test-release-images` | Committed images, `SHA256SUMS`, and fresh builds must each exactly match Makefile `RELEASE_IMAGES` before byte reproduction is accepted. Production pins the repository Makefile and ignores inherited `RELEASE_EXPECTED_IMAGES`, GNU Make flags, variable assignments, environment precedence, and injected makefiles; synthetic empty, malformed, duplicate and incomplete canonical sets run the unchanged verifier beside a test-only Makefile. The canonical set is itself held to `RELEASE_IDENTITY_IMAGES`, the Makefile's `override` pin: a canonical set wider or narrower than the pin, or an empty pin, is rejected, while a pin declaring the same members in another order is not drift. The real Makefile is then held to the reviewed seven-part, 21-image, 18-soak identity -- the pin and the canonical set are computed from disjoint inputs and must agree, the pinned variables move under neither a command-line assignment nor an inherited export, and a release goal is refused at parse time under `FW_BASE`, `TINYX5`, a `mmcu_<n>` entry, any MCU tag, any die or clock selector, or an abbreviated variant set. Both channels are exercised separately because they are not equivalent: a command line beats a plain `=` assignment, the environment cannot, and every per-part MCU tag and die selector is `?=` and therefore moves from an export alone. Relocated build directories, relocated tool paths and a single-target `VARIANT` selection still reach the release recipe. | Bash + synthetic image trees |
| Release qualification contract | `test-release-qualification` | Publication requires clean production metadata, the exact canonical 35-file evidence set, source-bound hashed resource evidence, one complete PIC12F675 matrix shared by both aggregate PASS sets and bound to the released HEX/checksums, and one identity-, duration-, and counter-bearing result for each of 18 release soak combinations. The rendered PIC12F675 recovery guidance is additionally held to the same published-finalization contract as the static documentation. The rendered validation prose is held to its substrate claim in both directions: the signed `MANIFEST.md` is published verbatim as the release body, so its simulator output lanes must be called modeled-pin checks and may not claim physical output evidence. The regression also preserves the historical 28-file/15-soak boundary for v0.9.6-v0.9.8. | Bash + Python + synthetic retained evidence |
| Release preflight contract | `test-release-preflight` | The real release step 0 reaches its final executable-version probe without cleaning, building, staging, or changing tracked/nonignored worktree content. A versioned run first requires one nonempty dated changelog section, exact comparison links, and bounded current-release declarations that agree with the canonical image/soak inventory and seven-part/four-shell topology; malformed bounds, stale exact fields, and prefix/superset values fail before release scratch creation while historical prose outside the bounds remains valid. A bounded declaration may not claim retained evidence the tree does not contain: naming the version under release is permitted only alongside the exact pre-tag transition line, naming any other absent release directory fails even behind that line, a present one passes, the line is read through the same blockquote strip as the contract line, and prose outside the bounds stays unconstrained. Synthetic selected tools and nonempty pack/header fixtures prove avr-libc, simavr/libelf, both gpsim lanes, analysis paths, complete yasimavr imports, safe Make argument routing, and absolute-venv routing fail closed. Focused copy-boundary fixtures additionally prove classic-AVR source and staged-byte mutations cannot reach checksum acceptance. Each image-defining compiler pin is proved separately against its own selector (`CC`, `PIC_CC`, `PIC10F320_CC`): a neighbouring version is rejected before any scratch tree with a diagnostic naming the selected tool, the observed banner, the expected version and the corrective action, a compiler that reports no version at all fails the provenance probe first, and a distributor packaging blob in an otherwise pinned banner is still accepted. Every published PIC12F675 finalization command is held to the identity of the transaction it recovers: the release tag is required after a `pic12f675-release-program` command and refused after a `pic12f675-program` one, each other reserved identity is required with the same value the preceding command reserved, an unanchored or deleted recovery example fails, a prose mention of the goal is not treated as a published command, a newly added document publishing the command is discovered rather than enumerated, shipped `release/<version>/` directories are excluded, and the generated documentation is checked by the same oracle. The PIC12F675 flashing contract then holds four publishers to one story: `README.md`, `FLASHING.md`, `release/README.md` and the generated per-release guidance must each name the release-shipped helper, the two entry points must carry the exact downloaded-release claim, the `FLASHING.md` heading must say the part is not a raw write target, and the Makefile must bind the helper as a release artifact. No current `.md` or `.adoc` may publish a raw writer command for this part, discovered rather than enumerated: a writer is recognized by the basename of any token, so an install path, a `sudo` prefix, a `$IPECMD` variable and `ipecmd.sh` are the same command, and `-MP` or `-E` is as destructive as `-M`; the sweep covers fenced blocks, AsciiDoc listing blocks, indented blocks and inline code spans, while a read-only `-GF` export, the helper's own invocation, another part's one-liner and prose naming the retired form in order to forbid it all stay publishable. No current document may still say this part has no no-compiler path either -- the three superseded sentences are named exactly, matched case-insensitively, so that a past-tense record of how they were retired is not itself a violation. The helper's published status is held to one story as well: every publisher and the generated guidance must carry the exact published/software-tested/not-hardware-qualified sentence, and no current `.md` or `.adoc` may deny that any ipecmd procedure has been published, in any of that denial's spellings and whether or not the tool name sits in a code span -- while a denial scoped to the Make route, and the accurate statement that no ipecmd hardware procedure is QUALIFIED, both stay sayable. A preserved design document is held to its own implementation updates: a body that records one forces the status banner to name that version and forbids it denying implementation, and the two build-before-hardware statements must each acknowledge the release that repaired them rather than being deleted. Hardware evidence is held to its classification: `HARDWARE_VALIDATION_LOG.md` must carry both bounded sections in order with no part row outside them, section 2 must define every field a controlled record retains and then either declare that no record exists or hold records carrying all of those fields, the pin-compatibility qualification must name both families and both of image and fuse/CONFIG, and no durable `.md`/`.adoc`/`Makefile` may assert the conflated "run on silicon" idiom or the retired unqualified interchangeability sentence. Naming a retired phrase is not using it, so code spans and quoted spans are blanked before matching and only the surviving prose counts -- a bare assertion sharing a line with an unrelated quotation is still caught. Shipped `release/<version>/` artifacts and root-level working documents that declare themselves branch-only are pruned outright, so the same wording in an undeclared root-level document, or in a `docs/` journal that carries the declaration, is still held to the contract. After staging, the same declarations are re-validated against the inventory actually staged -- images counted as files and soak combinations as machine records, so a build log sharing the soak naming cannot pad the count -- and that check is pinned to run after the staged-qualification verifier and before the commit/tag hand-off. Release staging governs the whole root-level document set rather than one name pattern: the durable documents ship, a root-level Markdown document that declares itself a branch-only working document in its opening blockquote is refused as one whatever it is named and in either spelling of the banner, any other root-level Markdown document is refused as outside the durable set -- one carrying a historical working-document name without the declaration and one declaring itself below the opening blockquote both included -- while a root-level non-Markdown file is not governed at all, a durable file still naming either historical branch-only family is refused so no reference dangles after deletion, the live tree is held to the same durable set so the allowlist cannot drift unnoticed, and a failed document or reference scan is a policy failure rather than an empty result. Ahead of all of it, the run's selected release identity is compared field by field with the pinned declaration and recorded on success: a command-line `FW_BASE`, an inherited `PIC12F675_TAG` or `PIC10F322_CHIP`, a reduced tinyx5 membership and an abbreviated `VARIANTS` each stop the run before the tool preconditions, naming the drifted field, its pinned and selected values, and the Make origin it arrived on, and leaving no scratch directory or output path behind; a relocated build directory changes no identity and still reaches the terminal success record. Before any of those Makefile queries, direct orchestration rejects inherited ignore-errors, dry-run, question, and touch modes from `MAKEFLAGS`, `MFLAGS`, or `GNUMAKEFLAGS`; the outer `release` and `release-preflight` goals independently reject short, long, compact, and inherited ignore-errors forms at parse time, before their recipe can start. | Bash + synthetic selected toolchain + base host utilities |
| Release provenance contract | `test-release-provenance` | Final images are rechecked immediately before staging, including a final classic-AVR HEX digest regenerated from the validated ELFs and a post-copy comparison that dominates `SHA256SUMS`. Tag CI snapshots clean-build image paths, requires four-way reproduction against the committed files, checksums, and canonical Makefile set, then freezes the exact image/helper/metadata inventory before later gates run. The publication shell rechecks the remote tag, inventory digest, detached checksum signature, strict checksums, and inventory again immediately before `gh`; synthetic additions, mutations, missing helpers, and failed checks cannot reach publication. The exact version-token comparison behind the three image-defining compiler pins is exercised directly over accepted and drifted banner forms, and the pins themselves are required to carry their own selected tool and to run before the preflight exit and the clean build. Publication kind is proved against a recording `gh` stub: a bare `vX.Y.Z` publishes ordinarily, every accepted suffix adds `--prerelease` exactly once, and malformed shapes abort before `gh`. `test-workflow-syntax` independently parses the YAML command ordering and version grammar. | Bash + Python + isolated release fixtures |
| Release history/signature/publication contract | `test-release-history` | The tag event must peel to an artifact-only, single-parent child of the exact qualified source. `SHA256SUMS.asc` and the exact remote annotated tag must verify against the pinned full-fingerprint key in an isolated keyring; altered bytes, missing/malformed/wrong-key signatures, lightweight/unsigned/same-target-replaced tags, and moved tags are rejected immediately before publication. The frozen publication oracle additionally binds an exact expected asset set to descriptor-read file identities, sizes, and SHA-256 digests; all HEX/metadata mutation classes plus additions, removals, renames, empty files, hidden/unsafe names, symlinks, FIFOs, directories, inventory tampering, and creation-order drift fail closed. A release commit that also restates a bounded current-release declaration is rejected exactly as a source-path change is: source finalization is an earlier, separate commit so the wording a tag carries is the wording that was qualified. | Bash + Python + GnuPG + scratch Git repositories |
| PIC12F675 flashing helper | `test-pic12f675-flash-helper` | The release-shipped `scripts/flash-pic12f675.py` is driven against a stateful fake `ipecmd` whose device memory persists across invocations and which records every argument vector it receives. The accepted transaction is exactly version probe, baseline read, immediate re-read, durable reservation, one write, final read -- the recorded vectors carry a witness flag saying whether `reservation.json` existed when the tool was entered, the write consumes a pinned descriptor rather than a replaceable pathname, and it requests no programmer-supplied power. Every fail-closed precondition is driven individually and each asserts that no `-M` vector was ever constructed: an image absent from or mismatching the signed `SHA256SUMS`, a missing manifest or detached signature, a malformed or duplicated checksum entry, an unreleased basename, a symlinked image, an image that programs word `0x3FF` or writes EEPROM, a user ID or the device ID word, an unreviewed CONFIG word or none at all, overlapping records, a bad checksum, a missing or trailing EOF record, an unsupported record type, a far linear-address segment, an empty program set, a different part, tool or power arrangement, an absent or non-executable `ipecmd`, MPLAB X 6.25, 5.50 or an unrecognizable banner, an existing, symlinked or parentless evidence path, a failed, empty, malformed or identity-less baseline read, a device with no factory calibration word, and a device that changed between the two pre-write reads. Each way a writer can destroy this part -- erased OSCCAL, rewritten OSCCAL, erased BG, a corrupted word, a silent no-op, a reported failure, a swapped device, a failed or empty readback -- produces a published `FAIL` after exactly one write, never a `PASS`. A genuine `SIGKILL` at each boundary -- after the second read, between the write and the readback, and inside a finalization -- leaves a real PENDING or unreserved directory, which finalization resolves read-only and retry-safely into per-attempt files, refusing a different programmer or Java runtime, a drifted tool version, a tampered retained image, a symlinked evidence path, an already-published result and an unreserved directory. Three further families are driven the same way. The RUNNING helper must be bound by the selected bundle's signed `SHA256SUMS` wherever it lives, so an edited off-bundle copy, a renamed copy and a copy the release never published are each refused -- binding on directory instead let all three reach a write. Both supported invocations are exercised end to end, including `java -jar ipecmd.jar` against a fake runtime the reservation pins. And the tool must still be the tool at the instant it is used: the fake moves its own pathname on cue, and a programmer replaced behind its name or edited in place between the pre-write read and the write stops the transaction with zero writer invocations. Full-device exports are held to being complete and self-consistent -- an export that omits program memory or reports one address with two values is refused before the write on both pre-write reads, and recorded as a named failure after it. Three more families were added when the third review re-opened P1. The post-write comparison covers the WHOLE device rather than the addresses the image supplies: every word the image omits must read back erased, `verified_program_words` must equal the part's 1023 program words on all three shipping variants (which supply 495, 521 and 523 of them), and a writer that skips its bulk erase -- writing every requested word correctly and preserving both trim values while leaving one stale instruction where the image never reaches -- publishes a `FAIL` naming that word. A corruption at the LAST word the image represents is injected beside the one at word zero. The pinned object must also be the one that runs: `test/pic/flash_hook.py` loads the helper as a module and replaces the `ipecmd` executable, the Java runtime, the jar, the retained `image.hex` (with one that programs the calibration word) and the evidence directory's own pathname INSIDE the window between the helper's final identity proof and the child that consumes them, and each case reads back out of the device model what the writer actually executed and opened, and asserts the replacement really landed. And publication is all-or-nothing: the parent-directory flush, the result write, the result flush, the atomic no-replace install and the directory flush after it are each failed and each `SIGKILL`ed, and every outcome must be one complete immutable `result.json` or a `PENDING` transaction a read-only finalization still resolves without a second write -- never a truncated record under the final name. `PIC12F675_FLASH_IMAGES=build` removes the gate's fallback to the previous release's HEXes; release qualification sets it, `make test` does not. | Bash + Python + stateful fake programmer |
| yasimavr venv fetch safety | `test-fetch-yasimavr` | Caller-selected destinations are canonicalized and cannot name roots, symlinks, files, or unstamped directories. Offline fake tools prove failed builds preserve the old owned venv and only a fully verified sibling tree is renamed into place. | Bash + synthetic toolchain |
| External supply-chain integrity | `test-supply-chain` | XC8 and PIC DFP bytes must match reviewed hashes before `sudo`; installation must produce all three required PIC device headers; restored ATtiny_DFP files are re-hashed; yasimavr dependencies are wheel/hash-locked and built without dependency resolution; both workflows use one installer and hash-sensitive cache keys. The XC8/DFP cache manifest is produced by three separately status-checked stages, so a scan, ordering or hashing failure is reported by name instead of being masked by the stage after it: each is failed independently, in both the installer and the restored-cache verifier, and neither may record nor accept a partial or empty inventory. Eight fixture files whose names carry spaces, both quote characters, a backslash, shell metacharacters, a leading dash, UTF-8 and an embedded newline must be inventoried, compared, and caught when tampered with. TOOLCHAIN.adoc's yasimavr prerequisites are held to the fetcher: any pip-bootstrap mechanism its prose describes must exist in the script (code spans blanked, so naming the retired `get-pip.py` fallback is not promising it), and both must name `python3-venv` as the pip source. | Bash + synthetic downloads/toolchains |

R6's release-input coverage spans the image and preflight rows above. The real
Makefile rejects direct source/flag assignments for all five build families,
ordinary and `-e` environment precedence for release validation controls,
assignment-bearing `MAKEFLAGS`/`GNUMAKEFLAGS`, `--eval`, dollar-bearing values,
noncanonical/injected makefiles, and a lock marker without its inherited locked
descriptor before the release recipe. The direct script cases require the same
failures before selected-tool probes or scratch creation. Source-mutated image
and soak inventories prove duplicate detection and exact 21/18 cardinality
precede set equality; relocated tool and build paths remain accepted, including
the separately preflighted and recorded `PIC12F675_PYTHON` selector.

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
`scripts/ci-local.sh`. `test-workflow-syntax` independently pins all six required
PIC aggregate goals, their five command groupings, strict/tool arguments,
enabled state, uniqueness, and the four downstream `needs: pic` edges.

`pic12f675-test-target-variants` is the same gate for that part, built from the
same two regressions above, and `pic12f675-test` is its pre-hardware aggregate:
CONFIG decode, static analysis, shipping-source coverage, the calibration
contract, the gpsim CLI lane, and the hardware return-stack bound. Both share
`_pic12f675-qualify-matrix` when requested in one Make graph. The qualifier
stages one shipping/simcal hash record, compares all shipping images and sidecars
with a discarded private compiler build, and uses the calibration contract's
private probes to reject injector nondeterminism. Only then does it exclusively
promote the final qualified manifest. Consumers suppress their phony producer
prerequisites and re-verify the retained manifest after every lane.
The pre-hardware, per-variant target, and all-variant target PASS records therefore
name one identical twelve-artifact SHA-256 record. Release staging retains that
JSON manifest, prevents soak-harness compilation from rebuilding the qualified
matrix, and verifies the final three shipped HEX files and `SHA256SUMS` entries
against the retained identity.

Debounce thresholds define a 33-sample pure-model minimum between press onsets.
That is also the nominal 33 ms physical minimum on ISR-driven AVR targets and the
simple polled PIC10F32x variant. PIC10F32x mute and relay actuation block the polling loop
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
| Host fault injection | `pic10f320-test-fault-host` | Corrupting a guarded SFR or the debounce context forces the sanity gate to take the watchdog-reset path. The relay variant additionally injects settled-state RESET, SET, and both coil-latch bits and requires the same escalation with both coils already de-energized where the reset spin was abandoned, *and* de-energized in one `LATA` write — the mock routes every firmware `LATA` access through the harness, so a clear that shed the two coil bits separately would be caught with one still driven: 41 / 41 / 62 checks. | host C |
| Shipping-source coverage | `pic10f320-coverage-check-fw` | An **exact** property, not a percentage floor: every line of the real firmware is host-executed except an enumerated, justified watchdog-reset path. Run per variant, because the three output stages give 84 / 95 / 99 executable lines. | host gcov with the mock `xc.h` |
| All-variant host aggregate | `pic10f320-test-host-variants` | The four layers above across all three variants, with the complete supported matrix required first. **This is the member of `make test`.** | Makefile wrapper |
| Return-stack oracle regression | `test-pic10f320-return-stack-oracle` | 149 deterministic checks: passing depths through 8, recursion/depth-9 rejection, independently required skip edges and operand boundaries, classic alias ranges, all 16,384 legality decisions, every destination writer against PCL/INDF/INTCON, 9-bit PC/physical-fetch aliasing, literal HEX layout, and fail-closed parser/file cases. Includes ten device-geometry checks: `--program-words` is validated as a power of two inside the 9-bit PC space, and fixtures whose verdict *differs* between the 256- and 512-word geometries pin the fetch alias in both directions — an image with code above word `0x0FF` is rejected when 256 words are declared, and one that relies on the fold is rejected when 512 are. **This is also a member of `make test`.** | dependency-free Python 3 |
| Image generation | `test-pic-build` | 47 PIC10F322, 91 PIC10F320, and 167 PIC12F675 checks. All three runs prove missing-XC8 skips remove the complete product matrix despite attempted inventory overrides, stale assembly/symbol sidecars cannot survive a current-HEX-only build, malformed/duplicate/ambiguous program-space transcripts remove the complete matrix, and missing/symlinked/non-executable/replaced canonical parsers fail closed. The 322 run additionally rejects recursively self-whitelisting GNU Make input; the 320 run covers selector rebuilds, strict size-summary parsing, deletion of reachable-RETFIE and depth-9 images despite attempted oracle/limit overrides, exact per-output XC8/host-compiler rebuild invocations with current clock/variant/host flags, and matching/mismatching/malformed/missing expected-image gate inputs. The 675 run additionally requires one exact, internally consistent XC8 Data-space record per variant, enforces the 48-of-64-byte policy, rejects malformed/duplicate/over-limit evidence and gate replacement, and proves late failure removes the complete matrix. It also covers exact simulator-image publication, retained aggregate matrix hashing, compiler/injector nondeterminism rejection, post-consumer verification, selected-variant/private-snapshot programming, signed-release tag/checksum/set binding, tracked-source and byte-drift rejection, worktree-local release-evidence refusal, read-only trim baseline capture, required/malformed/unreservable evidence rejection, immediate pre-write comparison, a freshly private-compiled CONFIG checker immune to the ignored repository executable, exact image/word record enforcement against no-op/near-match/wrong-image checkers, unsafe FOSC/WDTE/MCLRE/BOREN/BG fixtures, and whole-word-only drift, exact pk2cmd/ipecmd write argv, post-read programmed-byte/CONFIG verification, no-op/failed/interrupted-writer rejection, retry-safe read-only PENDING-transaction finalization bound to every reserved identity and a separately retained image, refusal of both an omitted and a substituted release identity before any device read, pre-read version validation, immutable and self-healing recovered PASS/FAIL evidence with full safety-oracle replay across trim/CONFIG/device/program-byte and malformed-read cases, retained OSCCAL/BG pass/fail evidence, acceptance of a zero-base extended-address record and refusal of a relocating one, external image/command refusal, overlap and path-replacement rejection, CLI, target-I/O, lock-step, fault-injection, soak, failed-producer cleanup, signal cleanup, and zero-image skip/strict checks including Python-probe ordering. | host fake-XC8/fake-CC regression |
| Expected image bytes | `test-pic10f320-expected-images`; `pic10f320-test-build` | The dependency-free checker pins exact manifest grammar and fail-closed file handling in `make test`; the full-tool target rebuilds the immutable three-variant matrix and compares each raw HEX file with the reviewed XC8 V3.10 / DFP 1.9.189 SHA-256 baseline. Kept out of mutation kill targets so a broad byte mismatch cannot mask a weak behavioural oracle. | Python 3; pinned XC8/DFP for the real-image comparison |
| CONFIG word | `pic10f320-test-config` | The emitted CONFIG word matches design intent, over every built image. Uses the shared checker with a device-accurate label. | host parser over HEX |
| Hardware return stack | every `pic10f320` build; `pic10f320-test-return-stack` | The base build strictly parses and traverses its final HEX before marking that image complete, so gpsim/target/soak/release rebuilds use the same fail-closed gate. The explicit target rebuilds the supported matrix and rechecks all three together, reporting each maximum and witness. | dependency-free Python 3 over final HEX |
| Static analysis | `pic10f320-analyze` | cppcheck + MISRA over the shell, **swept across all three variants** — each compiles a different `#if defined(OUTPUT_*)` branch, so one run would leave two thirds unanalyzed. | host tools |
| Register-level functional | `pic10f320-test-gpsim` | Real HEX toggles on press and handles a power-on-held switch via the shared wrappers, with the processor and chip-specific toggle-cadence stimulus overridden. | gpsim CLI |
| Fault response | `pic10f320-test-fault-target` | The host fault argument re-made on the real emitted image: every guarded SFR/SRAM location and required `TRISA` direction, plus a negative control proving the documented unguarded RA0 LED latch does *not* reset, plus relay-only RESET, SET, and both-coil `LATA` injections at the reviewed trailing-`CLRWDT` seam, from both BYPASS and ENGAGED. Each coil case must de-energize both coils *in one write* — the wait for de-energization samples every instruction, so a latch or modeled port that shed its coil bits across more than one step fails — force exactly one reset, and be followed by a recovery RESET-coil pulse of at least the datasheet minimum with SET dark: 24 / 24 / 29 checks. | libgpsim |
| HEX/model lock-step | `pic10f320-test-lockstep` | Live `_ctx_` SRAM from the XC8-built instruction stream matches `src/bypass_pure.c` after every completed main-loop iteration — 3,005 checks per variant, 66/66 states. | libgpsim |
| Target I/O timing | `pic10f320-test-io` | Exact `TRISA`, modeled `PORTA` following every `LATA` transition, each variant's complete transition sequence, and mute/relay pulse widths from simulator cycles. | libgpsim |
| Fail-closed aggregate | `pic10f320-test-target-variants` | Rejects any matrix other than the complete supported set, then requires fault, lock-step and target-I/O PASS sentinels for every variant. | Makefile wrapper |
| Pre-hardware aggregate | `pic10f320-test` | The single target CI and the release script invoke: the host aggregate, expected-image hash, CONFIG and return-stack proof over all images, and analysis + gpsim per variant. | Makefile wrapper |
| Soak | `pic10f320-test-soak` | Long-duration libgpsim soak per output stage; three combos at full duration are part of release qualification. | libgpsim |

The shared stale-sidecar and matrix cases run in the script-owned `pic10f322`,
`pic10f320`, and `pic12f675` profiles; the PIC10F320 rebuild cases run only in
its profile. Make requests the complete named set while the script independently
requires each profile exactly once and rejects empty, unknown, duplicate, or
incomplete requests. The profiles retain exact 47, 91, and 167 final-check
contracts respectively, so an incomplete profile or a missing rebuild/matrix
arm fails instead of reporting a smaller subset as green.

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
non-strict default so development on one substrate stays practical. Selective
partial runs use `MUTATION_ALLOW_SKIP=PIC`, `ATtiny202`, or the canonical combined
value `PIC,ATtiny202`.
`STRICT_TOOLS=1` changes the default to fail closed, and full-tool CI also pins
`MUTATION_ALLOW_SKIP=0`. An explicit `MUTATION_ALLOW_SKIP` value takes
precedence: `ci-local.sh --skip-pic` authorizes only PIC mutation skips, while
`--skip-attiny202` authorizes only ATtiny202 skips; combining the flags authorizes
both. Thus skipping one toolchain cannot hide loss of the other substrate. The
summary counts PIC and ATtiny202 skips separately, so a partial run always says
which substrate went unexercised rather than reporting one anonymous number.

Normal hosted CI runs mutation exactly once on push, schedule, and manual
dispatch: the fully provisioned `pic` job invokes `make test-mutation` with
`STRICT_TOOLS=1 MUTATION_ALLOW_SKIP=0`. After that job passes, `make stress`
runs every shared gate with the FULL workload definitions but does not repeat
the full mutation driver. `make test-long` remains the FULL-plus-mutation
aggregate used by release qualification and by `ci-local.sh`, where one process
combines the hosted verify, stress, and mutation responsibilities.

The PIC mutation set includes target-level faults for the new coverage: collapsed
TMR2IF cadence, exact-TRISA predicate removal, output-latch mask narrowing,
exact WPUA pull-up state, ANSELA mask narrowing, muted-CD4053 startup
reassertion, mute-window shortening, relay pulse shortening, and removal or
one-coil weakening of the PIC10F320 relay coil guard and its fail-safe
de-energization.

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

**PIC12F675's target-tool mutants are one table, not three, and are chosen for
what this part has that the 10F32x parts do not.** All 23 need XC8 plus gpsim or
libgpsim plus the derived simulator images, so there is nothing useful to split
within that table. The core/host table separately carries the F2 transaction-seam
relay masked-clear-order and relay parked-GP4-canonicalization mutants because
shipping-source coverage can kill those three shell faults without XC8. Copying the 322's target list would mostly have re-proved
the shared pure core, so the set targets the SRAM output shadow (a severed
write-back, each of shadow-versus-expected and port-versus-shadow independently
turned into a tautology, and physical divergence the 322 cannot express because
its port and latch are two views of one register),
the software sub-tick counter that stands in for the period register this part
lacks, the comparator and OSCCAL-trim guards that have no 322 counterpart, and
ANSEL's off-by-one mapping (GPIO bit 4 selects ANS3). Dedicated rows additionally
pin T0IF re-arming, exact OPTION_REG comparison, ADC-on rejection, global pull-up
enable across its two redundant guards, and the program-state and lockout-counter
write-backs. Kill targets are assigned
by what each fault actually perturbs and that assignment is load-bearing: moved
to the gpsim CLI lane, the defeated comparator guard survives.

PIC12F675 kill credit is also stricter than an ordinary nonzero Make status.
Every row names an exact gpsim assertion, fault injection, lock-step divergence,
target-I/O minimum, or soak reset signature. A failed XC8 compile, timeout,
missing completion record, or checker failure without that named signature is an
error rather than a kill. Tool absence may still produce an explicitly partial
run; a failed unmutated simulator-image or kill-target baseline may not.

**PIC10F320 mutants are split by what they NEED, not by what they test.** 30 of
them are killed by the host lanes and require only a C compiler, so they ride
with the unskippable core batch; 12 need XC8 + gpsim + libgpsim and sit behind
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

The driver independently pins the eight mutation categories at **32 core/host +
23 AVR-XT + 30 PIC10F320 host + 12 PIC10F320 tool + 6 PIC gpsim + 1 PIC soak + 10
PIC target + 23 PIC12F675 = 137**. It rejects category drift before probing, then
requires dispatched + skipped = 137 and killed + survived + errored = dispatched. Every
worker status is checked; result status/output pairs are atomically published
and accepted only with exact text grammar and no missing, hidden, or extra
artifacts.

One further note on the driver, learned the hard way: its sandbox tree copy has
to reach `test/pic10f320/{equiv,actuation,fault,gpsim}/` and the folded `.sh` and
`.stc` assets under `test/pic/`. The probe checks those shared helpers before it
can enable the tool-dependent PIC10F320 mutants. The host-only
`test-mutation-sandbox` regression exercises the same copy routine in `make test`,
including the wrappers' executable mode, and covers inventory, conservation,
record/command parsing, atomic publication, checker-status classification,
PIC12F675 behavioral signatures, source substitutions and baseline reasons, and
result grammar in 133 checks. A complete named behavioral verdict takes
precedence over incidental compiler-shaped text elsewhere in the checker log;
an actual compile failure cannot produce that complete three-variant record and
remains an error whose summary includes the first compiler diagnostic instead
of discarding it with the sandbox. `MUTATION_TIMEOUT_S` defaults only when unset and
accepts `0.001..86400` seconds with at most three fractional digits; zero,
negative, empty, malformed, under-resolution, and over-limit values fail before
any Make or tool probe. Every bounded checker owns a registered process session,
so normal return and interrupted-run cleanup reach nested timeout groups as well
as Make, compiler, and simulator descendants. The regression interrupts both a
nested-timeout session with a TERM-ignoring descendant and an unregistered
launch-gap worker, then proves their PIDs and process groups disappear. Cleanup
reads procfs ownership tokens directly and silently skips processes whose
`environ` is protected by ptrace policy, rather than trusting permissive procfs
mode bits and printing a false permission diagnostic. It also
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
AVR-XT's tightest absolute-width witness, because it recovers the *compiled*
width from the disassembled image instead of timing a trace, which makes it
simulator-independent. As described under "Known gaps" above, the output tracer
no longer single-steps: it free-runs in millisecond budgets and timestamps pin
edges from a signal hook, so it asserts delivered width as well as ordering,
polarity, exclusion and presence, and the pinned yasimavr's `SimLoop.run(n)`
cycle rewind reaches no timing assertion. The one deliberate `run(1)` caller
left is the fault driver's non-timing transaction-seam probe, whose bound is an
instruction-step count and from which no timing claim is derived.


## Known gaps (PIC — hardware-bench only)

### PIC10F32x hardware gaps

These are properties of the PIC10F322/PIC10F320 builds that their shared
gpsim-based simulation cannot faithfully assert; they are ultimately validated
on real chips at the bench.

They apply to **both PIC10F32x targets — PIC10F322 and PIC10F320 — equally**, because
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

### PIC12F675 hardware gaps

PIC12F675 has distinct silicon-only risks rather than the PIC10F32x TMR2/family
details above. Its guarded programming workflow detects and records OSCCAL and
`BG<1:0>` changes but cannot prove that a real programmer preserves either; the
pk2cmd/ipecmd hardware routes remain unvalidated. Simulator lanes qualify its
1.024 ms TMR0 cadence, qualitative WDT reset/liveness, and nominal output pulse
widths; real WDT timing, analog BOD behavior, and the loaded-board GP2
Schmitt-trigger readback margin require measurement. These are §8 items 1, 2, 8,
and 9 in `docs/pic12f675_feasibility.md`, tracked for the `1.x.y` hardware pass.
As on PIC10F32x, target-I/O cycle measurements do not replace real-silicon pulse
or peripheral-load measurements.
