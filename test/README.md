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
  run_mutation_tests.sh     shared: mutation-testing driver (make test-mutation)
  soak_timing_config.h      shared: native soak timing bounds
  check_flash_budget.sh     shared: exact flash-budget checker
  test_attiny202_build.sh   shared: fail-closed AVR-XT build checks
  test_avr_build_rebuild.sh shared: classic AVR rebuild/partial-output checks
  test_flash_budget.sh      shared: fail-closed flash measurement checks
  test_gpsim_wrappers.sh    shared: fail-closed gpsim wrapper checks
  test_make_serialization.sh shared: worktree Make/release lock regression
  test_pic_build.sh         shared: fail-closed PIC image-generation checks
  test_release_images.sh    shared: isolated exact release artifact verification
  test_soak_timing.sh       shared: soak input boundaries (make test-soak-timing)
  test_stack_bound.sh       shared: fail-closed stack evidence checks
  test_workload_rebuild.sh  shared: workload/fuse rebuild checks

  host/    MCU-independent golden-model tests, compiled and run natively.
           test_logic_host.c

  formal/  MCU-independent formal verification (proofs / exhaustive enumeration).
           test_cbmc.c          CBMC harnesses        (make test-cbmc)
           test_model_check.c   exhaustive BFS model  (make test-model-check)
           test_symbolic.c      KLEE / host enumerator (make test-symbolic)

  avr/     ATtiny-specific tests: the real firmware ELF in simavr, plus fuses.
           test_sim.c           simavr integration    (make test-sim-<variant>)
           test_soak.c          long-duration soak    (make test-soak)
           test_fuses.c         all-target fuse bytes (make test-fuses)
           attiny202_fuses.py   fail-closed simulator fuse configuration
           test_attiny202_fuses.py  simulator-fuse host regression
           sim_attiny202.py     shared yasimavr device/pin support
           test_sim_attiny202.py   functional + PA2/PA3 transition/timing checks
           test_attiny202_output_oracle.py  host regression for output checks
           test_attiny202_fault_oracle.py   host fault-run accounting regression
           test_fault_attiny202.py critical-SFR/state fault injection
           test_soak_attiny202.py  long-duration liveness soak

  pic/     PIC10F322-specific host and gpsim tests.
             fw_coverage/         real PIC source via host SFR mock + gcov
                                                        (make pic-coverage-check-fw)
            test_config_pic.c    CONFIG-word check     (make pic-test-config)
            *.stc + run_gpsim_*  register-level gpsim  (make pic-test-gpsim)
            test_fault_pic.cc    libgpsim fault-inject (make pic-test-fault)
            test_lockstep_pic.cc libgpsim HEX/model ctx lock-step
                                                       (make pic-test-lockstep)
            test_io_pic.cc       libgpsim GPIO/pulse timing
                                                       (make pic-test-io)
            test_soak_pic.cc     libgpsim soak         (make pic-test-soak)
```

Build artifacts (compiled binaries, `*.bc`) are written next to their sources in
each subdirectory and are git-ignored; see `.gitignore`. KLEE output directories
are produced at the `test/` root. The `-fstack-usage` `stack_*` evidence uses a
private temporary directory and is removed after each gate run.


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
| Image generation | `test-pic-build` | Missing, partial, malformed, or non-regular XC8 output cannot become a PIC firmware image; malformed/zero budgets, huge usage counts, and arithmetic-tool failures are rejected. | host fake-XC8 regression |
| CONFIG word | `pic-test-config` | The XC8-emitted CONFIG word matches the documented oscillator/WDT/BOR/MCLR/LVP design intent. | host parser over HEX |
| Static analysis | `pic-analyze` | cppcheck + MISRA pass over the PIC shell with real XC8/DFP register headers. | host tools |
| Shipping-source coverage | `pic-coverage-check-fw` | Every executable line in the real PIC shell, shared pure core, and all three output drivers is host-executed except the documented non-returning reset path. | host gcov with PIC SFR mock |
| Register-level functional | `pic-test-gpsim` | Real HEX toggles on press, handles power-on-held switch, keeps settled LATA/PORTA expectations, and includes the mid-debounce `PRESS1_EARLY` tick-cadence check. | gpsim CLI |
| gpsim process gate | `test-gpsim-wrappers` | Both functional wrappers require a positive decimal timeout and reject nonzero or killed gpsim runs even after complete snapshots. | Bash + fake gpsim |
| Fault recovery | `pic-test-fault` | Runtime direction, settled-output-latch, configuration, pull-up, and `ctx_` corruptions produce the variant-appropriate WDT recovery response. | libgpsim |
| HEX/model lock-step | `pic-test-lockstep` | Live `_ctx_` SRAM from the XC8-built instruction stream matches the shared pure model after every completed main-loop iteration. | libgpsim |
| Lock-step progress regression | `test-lockstep-progress` | Simulator stalls during settle, calibration, or completion abort immediately; the completion loop cannot spin forever on a frozen cycle counter. | host C++ + fake gpsim API |
| Target I/O timing | `pic-test-io` | TRISA/ANSELA/LATA/PORTA transitions, relay coil exclusion, and mute/relay pulse widths match the design. | libgpsim |
| Fail-closed aggregate | `pic-test-target-variants` | Rejects empty, duplicate, or unsupported matrices, then runs fault recovery, lock-step, and target-I/O for every selected PIC variant and requires each PASS sentinel. | Makefile wrapper |
| Aggregate regression | `test-target-matrix` | Proves valid matrices run exactly once per variant and invalid matrices fail before any target invocation. | Bash + fake recursive Make |
| Soak timing contract | `test-soak-timing` | Native Classic AVR/PIC soaks require the liveness interval within the total duration; short release rehearsals clamp it so every passing run completes a responsiveness round-trip. | host C/C++ compilers + release CLI |

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
missing PASS marker into a failure. It also validates the complete variant matrix
before starting its first target, so an empty or malformed matrix cannot report
an all-variants PASS or leave a misleading partial run.

`pic-test-fault` first requires exact startup `WPUA=0x08` and `TRISA=0x08`, then
injects every guarded direction, settled-output-latch, SFR, and SRAM fault at the
behaviorally identified main-loop `CLRWDT`. Register identity, injection
readback, the expected per-variant check count, and restoration after the simple
variant's spare-RA2 negative control are all fail-closed test invariants.


## Mutation testing and skipped PIC tools

`make test-mutation` includes PIC mutants whose kill targets need XC8, gpsim, and
libgpsim. A local host without those tools may run an explicitly partial mutation
suite with `MUTATION_ALLOW_SKIP=1`; that is the non-strict default so AVR-only
development stays practical. In strict/full-tool contexts, including
`STRICT_TOOLS=1` or `MUTATION_ALLOW_SKIP=0`, skipped PIC mutants fail the run.

The PIC mutation set includes target-level faults for the new coverage: collapsed
TMR2IF cadence, output-direction guard removal, output-latch mask narrowing,
exact WPUA pull-up state, ANSELA mask narrowing, muted-CD4053 startup
reassertion, mute-window shortening, and relay pulse shortening.


## Known gaps (PIC — hardware-bench only)

These are properties of the **PIC10F322** build that the gpsim-based simulation
cannot faithfully assert; they are ultimately validated on a real chip at the
bench. The sibling **pic10f320-bypass-firmware** child project shares them (same
TMR2, same datasheet, same gpsim environment) and carries the mirror note.

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
