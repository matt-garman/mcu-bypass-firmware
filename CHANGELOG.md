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

### Fixed
- **TMUX4053 control-pin polarity was inverted on the direct-drive variants.**
  The `cd4053_tmux` / `mute_tmux` images drove the analog-switch control pin at
  the opposite MCU level from the design intent — BYPASS asserted at pin-high
  instead of the fail-safe pin-low — which switched the effect the wrong way and,
  on the muted variant, transited the invalid FXN+JOU-short state instead of
  stepping around it. Root cause: `bypass_output_x4053_polarity.h` modeled the
  CD4053-MOSFET-inverter vs TMUX-direct-drive electrical difference but not the
  TMUX board's swapped analog throws, which already cancel it. The MCU now drives
  a single polarity (BYPASS = pin low) that serves both the CD4053 and TMUX4053
  boards. CD4053 builds are unaffected (already correct).

### Removed
- The separate `cd4053_tmux` and `mute_tmux` build variants and the
  `BYPASS_X4053_DIRECT_DRIVE` compile flag. With the polarity corrected, the
  TMUX images are byte-identical to their `cd4053` / `mute` bases, so a single
  image now covers both the CD4053 and TMUX4053 hardware; the redundant variants
  were dropped. The supported matrix is now three variants (`cd4053`, `mute`,
  `relay`) per MCU.

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

[Unreleased]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.2...HEAD
[0.9.2]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.1...v0.9.2
[0.9.1]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/matt-garman/mcu-bypass-firmware/releases/tag/v0.9.0
