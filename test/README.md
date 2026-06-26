# Test suite layout

Test *programs* are grouped by **execution substrate** — what each one runs on
and what it needs to build. Shared shims and analysis config stay at the `test/`
root because every substrate consumes them (the Makefile puts `test/` on the
include path with `-Itest`, so the test programs reference these by bare name
regardless of which subdirectory they live in).

```
test/
  bypass_config_host.h      shared: firmware config (RELEASE_THRESH, …) for host builds
  bypass_output_host.h      shared: output-driver host shim
  model_step.h              shared: delegates to the real bypass_pure.c logic
  misra.json                shared: cppcheck MISRA addon config
  misra_rules.txt           shared: MISRA rule paraphrases
  misra_suppressions.txt    shared: documented per-file MISRA deviations
  run_mutation_tests.sh     shared: mutation-testing driver (make test-mutation)

  host/    MCU-independent golden-model tests, compiled and run natively.
           test_logic_host.c

  formal/  MCU-independent formal verification (proofs / exhaustive enumeration).
           test_cbmc.c          CBMC harnesses        (make test-cbmc)
           test_model_check.c   exhaustive BFS model  (make test-model-check)
           test_symbolic.c      KLEE / host enumerator (make test-symbolic)

  avr/     ATtiny-specific tests: the real firmware ELF in simavr, plus fuses.
           test_sim.c           simavr integration    (make test-sim-<variant>)
           test_soak.c          long-duration soak    (make test-soak)
           test_fuses.c         fuse-byte validation  (make test-fuses)

  pic/     PIC10F32x-specific tests (gpsim).
           test_config_pic.c    CONFIG-word check     (make pic-test-config)
           *.stc + run_gpsim_*  register-level gpsim  (make pic-test-gpsim)
           test_soak_pic.cc     libgpsim soak         (make pic-test-soak)
```

Build artifacts (compiled binaries, `*.bc`) are written next to their sources in
each subdirectory and are git-ignored; see `.gitignore`. The `-fstack-usage`
`stack_*` files, the KLEE output directories, and `.toolchain.sig` are produced
at the `test/` root.
