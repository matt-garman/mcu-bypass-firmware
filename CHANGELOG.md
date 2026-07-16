# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses a `0.9.x` pre-1.0 series while the firmware and its
validation suite settle; `1.0.0` is intended once the API/behaviour and the
release process are considered stable.

Per-release provenance (source commit, pinned toolchain, image hashes, flash
usage, and validation evidence) lives in `release/<version>/MANIFEST.md`; this
file is the human-readable summary of *what changed*.

## [Unreleased]

### Added
- Fail-closed ATtiny202 production-fuse verification for `WDTCFG`, `BODCFG`,
  `OSCCFG`, `SYSCFG0/1`, `APPEND`, and `BOOTEND`, including host regressions
  proving yasimavr receives the same complete Makefile-defined fuse set.
- ATtiny202 built-image target-output coverage for exact physical PA2/PA3
  startup/engage/bypass sequences, pulse presence and ordering, relay-coil
  exclusion, and low parked outputs, backed by a host-only oracle regression
  for positive and fail-closed trace paths.
- Fail-closed ATtiny202 fault execution now requires all 17 independently pinned
  injectable guards, zero skips, exact result counts, witnessed WDT resets,
  phase-swept ISR-handshake corruption, and a long healthy negative control.
- An ATtiny202 disassembly oracle now verifies absolute 5 ms mute and 12 ms
  relay pulse widths directly from each built image, independent of yasimavr's
  non-cycle-accurate delay execution.
- Host-only regressions now exercise PIC target-matrix validation and lock-step
  simulator stalls without requiring XC8 or libgpsim.

### Changed
- Complete Make and direct release-script invocations now hold one worktree-local
  lock, preventing independent processes from replacing shared firmware, test,
  coverage, or simulator artifacts while preserving explicitly isolated
  recursive test fan-out.
- Classic AVR, AVR-XT, and PIC10F322 sanity gates now verify the complete
  settled output latch against the logical effect state, including low-driven
  spare pins and inactive relay coils.
- Classic AVR and ATtiny202 sanity gates now require the complete GPIO direction
  state configured at startup, detecting footswitch pins becoming strong outputs
  and intended low-driven spare outputs becoming inputs.
- Routine push, scheduled, and manually dispatched CI now runs mutation testing
  in strict mode on the full PIC-toolchain runner; pull requests retain the
  faster non-mutation path.
- ATtiny202 is now explicitly classified as development-only/non-release. Its
  normal build and yasimavr CI lane remains available, while release images,
  reproduction, and long-soak qualification remain scoped to AVR Classic and
  PIC10F322.
- The full-tool ATtiny202 CI job now runs `make attiny202-test STRICT_TOOLS=1`,
  making its cppcheck and MISRA analysis mandatory alongside fuse, build, and
  flash-budget and pulse-width validation.
- PIC shipping-source coverage is now a required gate, and mutation coverage
  explicitly rejects the wrong unified x4053 BYPASS polarity.

### Fixed
- `scripts/ci-local.sh --skip-pic` now permits unavailable PIC mutants to skip
  during push-mode `test-long` while retaining `STRICT_TOOLS=1` for host/AVR
  gates; full local-CI runs explicitly keep mutation fail-closed.
- Missing CBMC or cppcheck now fails `test-cbmc` and `analyze-cppcheck` under
  `STRICT_TOOLS=1` instead of silently turning required CI analysis into a skip.
- Native Classic AVR and PIC soaks now require the liveness interval to fit
  within the total run, and short release rehearsals clamp and propagate that
  interval so a passing soak includes at least one responsiveness round-trip.
- PIC flash-budget acceptance now requires a positive decimal budget, compares
  arbitrarily long usage counts without fixed-width shell arithmetic, and
  rejects failed comparisons or missing percentage results.
- Release reproduction now rejects committed-as-fresh and duplicate fresh
  directories after physical-path resolution, then verifies `SHA256SUMS`,
  committed images, and fresh images from one immutable set of private snapshots.
- Historical `v0.9.0` through `v0.9.2` release documentation now prominently
  identifies the superseded `*_tmux*` images whose direct-drive polarity maps
  the absent/undriven-MCU pull-down state to ENGAGED instead of fail-safe
  BYPASS, and directs users to the unified images from `v0.9.3` or later.
- Classic AVR, ATtiny202, and PIC image generation now fails closed on missing,
  stale, partial, malformed, over-budget, or unverifiable output. Intel HEX
  structure, stack/flash/fuse evidence, workload rebuilds, model coverage, soak
  timing, and release image sets all have isolated negative-path regressions.
- gpsim wrappers reject non-positive or malformed timeout values before invoking
  the simulator and propagate process failures or kills even after valid
  snapshots, while libgpsim targets remove stale binaries before rebuilding.
- PIC target fault injection now verifies register identity, write-back,
  simulator progress, exact per-variant completion counts, and restoration of
  negative controls before reporting PASS.
- PIC target aggregates reject empty, duplicate, or unsupported variant matrices
  before execution, and PIC lock-step stalls abort immediately during settle,
  calibration, or completion instead of looping on a frozen cycle counter.

## [0.9.4] - 2026-07-11

### Added
- `make pic-test-lockstep`: a libgpsim PIC10F322 gate that runs the XC8-built
  HEX and compares live `_ctx_` SRAM against the shared pure-model state after
  each completed main-loop iteration.
- `make pic-test-io`: a libgpsim PIC10F322 GPIO/timing gate that checks real
  TRISA/ANSELA/LATA/PORTA transitions, relay coil exclusion, and analog-switch /
  relay pulse widths from the built HEX.
- `make pic-test-target-variants`: a fail-closed aggregate for the PIC
  target-level gates (`pic-test-fault`, `pic-test-lockstep`, and `pic-test-io`)
  across every PIC variant. Component targets may still skip cleanly on a local
  host without PIC tools; this aggregate requires every PASS marker.
- PIC gpsim register-level coverage now includes a mid-debounce `PRESS1_EARLY`
  sample and full BYPASS `LATA` assertions, catching a collapsed tick gate and
  checking all settled analog-switch control bits in both directions.
- Mutation coverage for exact `WPUA`, TMR2IF cadence, ANSELA output masks,
  muted-CD4053 startup ordering, mute-window duration, and relay pulse duration.

### Changed
- CI and release now run `make pic-test-target-variants STRICT_TOOLS=1`, so
  target-level PIC fault, lock-step, and GPIO/timing validation are required.
- Release creation runs mutation testing in strict mode so PIC mutants cannot
  disappear behind skipped target tooling.

### Fixed
- **PIC10F322 weak-pull-up validation now requires the exact RA3-only state.**
  Extra enabled `WPUA` bits on output pins are treated as configuration damage
  and force watchdog recovery.
- **Muted CD4053 startup no longer traverses ENGAGED before settling BYPASS.**
  The driver asserts the bypass-side control first, waits the mute window, then
  releases the second control line.
- Lock-step stimulus is applied at a fresh loop boundary, avoiding relay phase
  lag and startup phase skew.

## [0.9.3] - 2026-07-11

### Added
- ATtiny202 development support: an AVR-XT firmware shell, avrxmega3 build and
  flash-budget gate, cppcheck/MISRA analysis, UPDI programming targets, and
  pinned ATtiny_DFP acquisition.
- A yasimavr functional, fault-injection, and soak harness for ATtiny202, plus a
  dedicated CI lane. The spare PA6 pin is actively driven low.

### Changed
- Build, coverage, mutation, and release gates now fail closed when required
  tools, outputs, percentages, or exact release image sets are missing.
- Release reproduction uses fresh build outputs and validates complete image
  sets instead of relying on committed artifacts alone.

### Fixed
- **TMUX4053 control-pin polarity was inverted on the direct-drive variants.**
  The MCU now uses one fail-safe polarity (BYPASS = pin low) for both CD4053 and
  TMUX4053 boards; the TMUX board's swapped analog throws already compensate for
  the CD4053 board's MOSFET inversion.

### Removed
- The redundant `cd4053_tmux` and `mute_tmux` variants and the
  `BYPASS_X4053_DIRECT_DRIVE` flag. The supported release matrix is now three
  variants (`cd4053`, `mute`, and `relay`) per MCU.

## [0.9.2] - 2026-07-09

### Added
- Per-tick sanity gate now checks `ANSELA` on the PIC10F322: an SEU/EMI flip
  that re-selects an output pin as analog (dark LED / dead control pin, with the
  `TRISA` direction bit unchanged) now forces a watchdog reset. `ANSELA` is
  masked to `BYPASS_OUTPUT_DDR_MASK` (`RA0|RA1|RA2`) and added as a fifth term
  to `hw_critical_sfrs_intact()`.
- Fault-injection coverage for the new `ANSELA` gate term: three inject cases
  (`ANSELA.RA0/RA1/RA2`) in `test/pic/test_fault_pic.cc`, each independently
  proven to force a reset and to fail if the guard is removed.
- `test/README.md` "Known gaps" now records the two PIC properties gpsim cannot
  faithfully assert: WDT-timing / brown-out behaviour, and the TMR2 prescaler
  *select* clamp (gpsim models `T2CKPS = 0b11` as 1:16 instead of the
  datasheet's 1:64) — both are hardware-bench guarantees.
- `CHANGELOG.md`.
- TODO items for two Tier-3 robustness explorations: a hardware-in-the-loop
  validation rig and complemented (inverted-copy) `ctx_` storage.

### Changed
- **PIC10F322 core clock reduced from 16 MHz to 2 MHz** (HFINTOSC), roughly
  halving MCU supply current (~0.85 mA → ~0.43 mA at 5 V) for no change to the
  reliability architecture — the busy-wait tick, per-tick SEU/EMI sanity gate,
  and LFINTOSC-based watchdog are untouched. The 1 ms tick is re-derived on the
  1:4 Timer2 prescaler (`T2CON = 0x05`, `PR2 = 124`) to land exactly 1 ms; the
  `__delay_ms` pulse widths (which track `_XTAL_FREQ`) and the FOSC-independent
  watchdog margin are unchanged. Low power is not a project goal — this simply
  avoids spending ~4 mW where ~2 mW does the same job, and emits less
  high-frequency switching noise into the analog audio path.
- **Renamed the PIC shell `pic10f32x` → `pic10f322`.** This project targets the
  PIC10F322 specifically, so the family "32x" naming is retired:
  `src/bypass_mcu_pic10f32x.c` → `_pic10f322.c`, `bypass_pins_pic10f32x.h` →
  `_pic10f322.h` (include guards included), and the build macro
  `BYPASS_MCU_PIC10F32X` → `BYPASS_MCU_PIC10F322`; every build/test/doc
  reference follows.
- Made PIC `ctx_` fault injection deterministic: the driver now parks the core
  at the main-loop `CLRWDT` (located by opcode, not a hardcoded address) before
  injecting, so no variant can land in the integrate-before-gate window where
  the integrator would overwrite the injected field before the sanity gate reads
  it. (At 2 MHz the previous ms-based settle produced intermittent false
  passes.)
- Normalized every `src/` license header from the "All rights reserved /
  Licensed under the MIT License" three-liner to the self-describing
  `SPDX-License-Identifier: MIT` form already used by the test sources.
- Refreshed the stale Phase-2 design docs with "as-built (2 MHz)" banners
  pointing at the shipped firmware as the source of truth, and corrected the
  Timer2/oscillator bullets (including a `T2CKPS` register description that
  listed 1/4/16 and dropped the 1:64 code).

### Fixed
- **PIC10F322 1 ms system tick ran ~4× slow (~4 ms) on real silicon.** `init()`
  programmed Timer2 with `T2CON = 0x07` (`T2CKPS = 0b11` = 1:64) while intending
  the 1:16 prescale, stretching every debounce interval 4× (press-confirm
  ~8 ms → ~32 ms, release-lockout ~25 ms → ~100 ms). Every simulation-based test
  masked it because gpsim mis-models the `0b11` code as 1:16, and the host /
  equivalence layers count ticks rather than wall-clock time; the defect was
  caught by cross-checking the programmed register against the datasheet
  (DS40001585D, Register 17-1 / Figure 17-1). Now a true 1 ms tick. The
  behaviour was still serviceable — and not a safety regression, the watchdog
  margin was unaffected — but off-spec in the v0.9.0–v0.9.1 prebuilt images.

> These PIC10F322 changes bring the shell to parity with the sibling
> [pic10f320-bypass-firmware](https://github.com/matt-garman/pic10f320-bypass-firmware)
> child project, which landed the same TMR2 / 2 MHz / `ANSELA` work after the
> fork. The pure debounce core and the output drivers are unchanged; the AVR
> targets are unaffected.

## [0.9.1] - 2026-07-04

### Added
- **Per-tick configuration-SFR sanity gate on the PIC10F322 (SEU/EMI
  hardening).** Every main-loop tick now verifies the critical
  clock/watchdog/timer configuration registers (`OSCCON.IRCF`, `WDTCON.WDTPS`,
  `PR2`, `T2CON`); a corrupted value forces a watchdog reset that re-runs
  `init()`.
- `make pic-test-fault` (`test/pic/test_fault_pic.cc`): gpsim critical-SFR
  fault-injection test that corrupts each gate-guarded SFR — extended to the
  `nWPUEN` pull-up and the `ctx_` SRAM fields — and asserts recovery via a real
  watchdog reset. Wired into the release gate.

### Changed
- CI/build no longer degrades silently: a missing/misconfigured analyzer now
  fails loudly instead of skipping, and PIC fault injection is gated in CI.
- Refreshed the stale PIC TMR2 mutation pattern after the named-constant
  refactor so it kills again.
- Design-doc updates: TMUX4053 wiring and toolchain notes.

### Fixed
- Assorted documentation and comment typos.

## [0.9.0] - 2026-06-30

### Added
- Initial release: reference-quality footswitch **bypass firmware** (switch
  debounce → bypass/engage state → status LED) across three MCU families from
  one shared, formally-verified debounce core —
  - **ATtiny13a** (AVR classic, 1.2 MHz),
  - **ATtiny45 / ATtiny85** (AVR tinyx5, 1.0 MHz),
  - **PIC10F322** (16 MHz INTOSC).
- Functional-core / hardware-shell architecture: a pure, MCU-independent
  debounce core (`bypass_pure.c`) driven by thin per-MCU shells that apply the
  result to real hardware, so the same verified logic ships on every target.
- Five output variants per MCU: `cd4053`, `cd4053_tmux`, `mute`, `mute_tmux`,
  and `relay` (analog-switch, TMUX4053 direct-drive, muted, and TQ2-relay
  drives).
- Two-layer validation: a reference model plus a firmware↔model equivalence
  test that pins each shipping binary to the model tick-for-tick.
- Formal verification (bounded model check, symbolic single-step, and CBMC),
  a fault-injection harness with a firmware line-coverage gate, per-variant
  actuation-sequence checks, mutation testing, and a clean MISRA-C:2012 posture.
- Simulation soak testing: 24-hour parallel soaks of every variant × MCU —
  simavr for the AVR targets, gpsim / libgpsim for the PIC — plus a PIC
  CONFIG-word check.
- Reproducible, fully-validated prebuilt-firmware release pipeline: pinned
  toolchain, SHA256-checksummed images, per-release `MANIFEST.md` provenance and
  evidence, and a tag-triggered CI job that rebuilds on a clean runner and fails
  the release on any hash mismatch.

[Unreleased]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.4...HEAD
[0.9.4]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.3...v0.9.4
[0.9.3]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.2...v0.9.3
[0.9.2]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.1...v0.9.2
[0.9.1]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/matt-garman/mcu-bypass-firmware/releases/tag/v0.9.0
