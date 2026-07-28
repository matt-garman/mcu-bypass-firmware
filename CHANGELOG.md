# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project stays on the `0.9.x` pre-1.0 series while the firmware and its
validation suite settle. The criterion for leaving it is explicit: **`1.x.y`
begins once these designs are validated on real hardware.** Everything shipped
so far is validated by simulation, formal proof and static analysis — thorough,
and not the same claim as "it has run on the part". Until that changes, new
work lands as `0.9.x` however large it is; the merge of a whole additional MCU
target planned for `0.9.6` rather than `0.10.0` is that rule applied, not an
oversight.

Per-release provenance (source commit, pinned toolchain, image hashes, flash
usage, and validation evidence) lives in `release/<version>/MANIFEST.md`; this
file is the human-readable summary of *what changed*.

> **On the PIC10F320's version history.** The PIC10F320 target was developed in a
> separate repository and merged into this one (see **Unreleased** below, planned
> for `0.9.6`). That
> project ran its own `v0.9.0`–`v0.9.5` series with **different content and
> different dates** from the identically numbered releases in this file — its
> `0.9.5` is dated 2026-07-10, this project's 2026-07-18. Those entries are
> therefore **not** back-filled here: doing so would collide two unrelated
> numbering lines and misreport each project's history as the other's. The child
> timeline remains reachable in full through the imported commit graph and the
> namespaced signed tags `pic10f320/v0.9.0` … `pic10f320/v0.9.5`. From the first
> unified release onward there is one timeline, with PIC10F320 changes recorded
> as a sub-lane inside each entry.

## [Unreleased]

### Added
- **PIC10F320 integrated as the planned fifth release target** — the first
  whose firmware does not compile the verified core but hand-inlines it, because
  256 words of flash cannot hold the shared-core architecture. Merged from a
  separate repository with its full history preserved. See
  [docs/pic10f320_special_case.md](docs/pic10f320_special_case.md) for what that
  difference does and does not buy, and `docs/pic10f320_merge_plan.md` for every
  decision taken.
- PIC10F320 validation lanes: firmware-to-core equivalence against
  `src/bypass_pure.c` itself (266,144 sequences, all 66 reachable model states),
  per-variant actuation-sequence checks, host fault injection, an exact-line
  firmware coverage gate, real-HEX lock-step, target fault injection, target I/O
  timing, CONFIG-word verification, cppcheck + MISRA across all three variants,
  and a libgpsim soak. The host subset needs only a C compiler and gcov, so it
  runs inside `make test` on every push.
- A dependency-free PIC10F320 final-HEX return-stack oracle now strictly parses
  Intel HEX and explores reachable classic mid-range PIC14 control flow with the
  exact abstract hardware stack. Its host fixtures are in `make test`; the
  fail-closed base `pic320` recipe checks every generated image before marking it
  complete, while `pic320-test-return-stack` rebuilds and rechecks the supported
  three-image matrix against the architectural eight-entry limit as part of
  `pic320-test`.
  Its state and return stack preserve the 9-bit architectural PC; instruction
  fetch alone aliases through the low eight bits to 256 physical words.
- The shared fake-tool PIC build regression now has a PIC10F320-only
  rebuild-trigger lane. Exact output-specific compiler logs prove identical
  `pic320` and host-test requests rebuild, and that changed/restored clock,
  output-variant and host flags reach the current invocation. Canonical target
  counts make activation fail closed; same-name target sentinels enforce
  `.PHONY`, and exact fake-binary execution counts enforce each host run recipe.
  This proves fresh triggering, not byte-for-byte XC8 reproducibility; the
  standing expected-image hash regression remains an open follow-up.
- A **canonical release product set** (`RELEASE_IMAGES` in the Makefile),
  enforced by the release script, the image verifier and its regression alike.
  Previously the committed directory, the `SHA256SUMS` entries and the fresh
  build were all derived by globbing, so three "independent" checks agreed
  perfectly on a release with an entire MCU missing. They no longer can.
- Three PIC10F320 full-duration soak combinations are required by the release
  pipeline, which will add PIC10F320 images as release assets beginning with the
  first successfully qualified unified release. Normal CI already publishes its
  separate development artifact.
- `make pic320-*` targets, `make help` entries for them, and a
  `docs/pic10f320_special_case.md` linked from the README, the design
  documentation, the release documentation and the generated release manifest.

### Changed
- The final-HEX return-stack oracle no longer hardcodes the device geometry.
  `--program-words` supplies the implemented program memory from the device
  pack's `ROMSIZE`, is validated as a power of two inside the 9-bit PC space
  (both supported parts declare `PCBITS=0x9`), and an image carrying program
  data above the declared size is now **rejected outright**. Under-declaring was
  the dangerous direction — the fetch alias would fold a high PC onto a
  different instruction and could report a *lower* depth than the truth — and it
  previously surfaced only as a confusing downstream error about a computed
  `PCL` write at an aliased address. Ten selftest checks pin the alias in both
  directions; the regression is now 149 checks.
- The strict-tools inventory now covers optional-tool recipes for **both** PIC
  chips, not just the two host analyzers it started with.
- MISRA documentation is now a per-target statement rather than a comparison
  against another project, and records deviation **D-4** (the PIC10F320
  analyzer symbol-resolution waiver) that the suppressions file already cited.
- The `pic` CI job covers both PIC parts; `scripts/ci-local.sh` mirrors it and
  documents that `--skip-pic` skips both chips.
- Simulator "known gaps" documentation is now shared PIC content covering both
  parts, rather than two per-repository copies that had already drifted.

### Fixed
- The ATtiny202 fault matrix now covers `PORTA.PINnCTRL.INVEN` on the LED,
  control/relay, parked-spare, and footswitch pins. The PA7 case preserves its
  pull-up while reversing input polarity, proving the firmware's exact PA7
  control check rather than the old pull-up-only predicate. Exact zero control
  checks similarly protect the four output pins, and the per-variant matrix
  expands from 17 injections / 18 results to 22 / 23.
- Qualification documentation now distinguishes historical phase evidence, the
  clean but non-publishable `4b28210` full-tool rehearsal, and the still-missing
  final-source production run. It no longer claims that corrected 74/74 mutation
  execution and real-image stack gating never occurred, and the release guide
  scopes the 12-soak/22-file `QUALIFICATION` contract to unified releases rather
  than directing `v0.9.0` through `v0.9.5` to files and targets they predate.
- Release publication now requires both cryptographic signatures promised by the
  trust model. CI verifies `SHA256SUMS.asc` and the exact remote annotated tag
  object against the checked-in public key and pinned full fingerprint before
  publishing; missing, empty, malformed, wrong-key, lightweight, unsigned,
  same-target-replaced, and moved tags all fail closed. Signing instructions pin
  the same key explicitly instead of relying on the operator's GPG default.
  Producer and verifier version validation now matches the workflow's optional
  hyphen-suffix trigger and rejects malformed or invalid Git tag names before a
  production qualification run.
- Mutation results now conserve an immutable 74-mutant inventory across six
  pinned categories: dispatched plus skipped must equal 74, and killed plus
  survived plus errored must equal dispatched. Inventory records, baseline Make
  commands, worker exits, sandbox setup, atomic result pairs, exact status/output
  grammar, and unexpected artifacts all fail closed instead of allowing a
  shortened or partially published run to report "all mutants killed."
- The PIC10F322 `pic` producer now requires the complete immutable output-variant
  matrix before invoking XC8, rejecting empty, duplicate, unsupported, and
  incomplete requests. Classic AVR and PIC10F322 entries in `RELEASE_IMAGES` now
  derive from that immutable set, so a `VARIANTS` override cannot weaken the
  independent release contract along with the requested build. Both PIC matrix
  requests are sanitized before recursive Make or shell expansion, and their
  HEX/assembly/symbol cleanup inventories cannot be disabled by command-line
  overrides.
- PIC builds now invalidate XC8's generated `.s` and `.sym` sidecars together
  with each HEX before compiling and remove the same complete product set after
  failure or interruption. The hardware-stack targets skip only when no current
  HEX exists; a current image without fresh, regular, nonempty assembly now fails
  instead of allowing stale evidence or an absent-tool skip.
- Tag CI now binds retained 24-hour qualification to Git history: the tagged
  release commit must be a single-parent, artifact-only child of the exact source
  commit named by `QUALIFICATION`. A scratch-repository regression rejects wrong
  parents, merge commits, mixed source/release changes, sibling-release changes,
  checkout drift, a snapshot differing from the tagged record, and a remote tag
  that moved before publication.
- Release qualification is now machine-verifiable before publication: an
  immutable 12-combination inventory, exact retained-evidence set, strict
  `QUALIFICATION` schema, and one identity/timing/counter-bearing `SOAK_RESULT`
  per log must agree. Tag CI verifies a private snapshot before installing tools
  and publishes the qualification record; PIC images are hash-pinned across soak
  compilation, execution, and staging just like validated AVR ELFs.
- Dry-run release artifacts cannot be staged under the repository's release tree,
  and tag CI requires an explicit production-mode manifest while independently
  rejecting the dry-run banner before any release can be published. The output
  path is revalidated immediately before staging, and tag-derived values reach
  privileged workflow shells through the environment rather than source-text
  interpolation.
- `pic320-variants` now requires the complete supported build matrix, and the
  canonical release set no longer shrinks with a `PIC320_VARIANTS_ALL` override.
- Release provenance now probes both selected XC8 compilers fail-closed and
  records target-qualified compiler paths and versions instead of attributing
  both PIC image families to `PIC_CC`.
- PIC host and real-target "all variants" aggregates now reject proper subsets
  of the supported matrix instead of running one variant and reporting that all
  variants passed.
- PIC gpsim validation now shares one exact pin-name resolver across all
  libgpsim harnesses and tests RA3 against substring decoys; fake CLI gpsim also
  rejects stimuli not attached exactly once to `ra3`.
- The host lock-step progress regression now compiles and stalls both PIC
  adapters. Dropping the byte-identical child script had accidentally retained
  only the PIC10F322 source path and left PIC10F320 stall handling untested.
- The shared fake-XC8 interruption regression now requires proof that SIGTERM
  reached each PIC build recipe; `pic320` exports its recipe PID so a missing
  variable can no longer masquerade as successful cleanup validation.
- `pic320-size` now fails closed on compiler, image-validation, and summary
  failures and removes every temporary XC8 artifact after success, failure, or
  interruption instead of suppressing the probe pipeline's exit status.
- The shared gpsim wrappers and both public PIC functional targets now honor
  `STRICT_TOOLS=1`; a missing simulator cannot become a successful strict run.
- Standalone PIC10F320 target and soak selectors now rebuild the selected
  variant instead of potentially consuming a stale image while rebuilding the
  default `PIC320_VARIANT`.
- `pic320-test-gpsim` now runs the forked PIC10F320 toggle stimulus instead of
  silently using the PIC10F322 cadence checkpoints through the shared wrapper.
- PIC10F320 mutation sandboxes now include the folded gpsim wrappers and stimuli,
  and the tool probe baselines every distinct kill command. A missing harness can
  no longer make the TMR2IF cadence mutant falsely count as killed.
- The mutation sandbox now mirrors every test source at any depth instead of
  four extensions one level down, restoring 18 PIC mutants that had been silently
  skipped: `test/pic/find_pin_exact.h` never reached the sandbox, and it is a
  prerequisite of both chips' soak binaries and all three target lanes. The
  sandbox validator requires that header, and the self-test proves the copy
  reaches three levels deep. The copy stays an extension allowlist by design —
  `test/` also holds build products, and mirroring them with preserved mtimes
  could make Make skip a rebuild and score a mutant against unmutated source.
- The shared PIC gpsim preflight no longer consults the git index outside a work
  tree, where `git ls-files` reports an empty mode that the guard read as a
  failure. This made `pic320-test-gpsim` unrunnable inside the mutation sandbox;
  the PIC10F322 lane had routed around the same obstacle, so only one chip was
  affected. The local executable-bit check is unchanged and still unconditional.
- Mutation skips now report whether a lane was disabled because a tool was
  absent or because its baseline FAILED, and the closing advice no longer tells
  the reader to install a toolchain that is already complete. With both sandbox
  gaps closed, `make test-mutation MUTATION_ALLOW_SKIP=0` completes all 74
  mutants — 74 killed, 0 survived, 0 errored, 0 skipped.
- The PIC10F320 real-HEX target aggregate now requires explicit fault-injection,
  lock-step, and target-I/O completion markers, so a skipped or incomplete lane
  cannot be reported as a successful CI/release gate.
- **`pic320` and `pic320-size` printed "skipping" and then built anyway.**
  `$(SKIP)` is `exit 0` in non-strict mode and exits only its own shell, so a
  guard on its own recipe line skipped nothing. An audit found no other instance
  in the Makefile.
- **The PIC10F320 build left a partial image set** when one variant failed; it
  now removes the whole set.
- The ported flash-budget comparison was weaker than this project's own and
  conflated "not over budget" with "the comparison tool failed".
- **`pic320-test-gpsim` had no gpsim probe at all**, so `make pic320-test
  STRICT_TOOLS=1` on a host without gpsim reported "all PIC10F320 pre-hardware
  checks complete" having run none of its six scenarios — the wrappers exit 0 on
  a missing simulator by design, and nothing above them looked. The port also
  dropped the `GPSIM=` passthrough, so that override was silently ignored on this
  chip and the lane tested whatever `gpsim` was on `PATH`. Both chips' lanes now
  share one preflight definition, and both are registered in the strict-tools
  inventory (18 → 22 checks) rather than excluded from it.
- `pic320-test-config` now skips cleanly when no image was built, instead of
  handing an unexpanded glob to the CONFIG checker and failing where the
  PIC10F322 lane skipped.

## [0.9.5] - 2026-07-18

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
- The PIC10F322 sanity gate now requires the complete TRISA direction state
  configured at startup (exact `0x08`), closing the gap where a spare RA2
  direction upset on the simple-CD4053 variant fell outside the required-subset
  check. Fault injection, shipping-source coverage, and mutation coverage now
  exercise the exact predicate on every variant.
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
- Long release runs now recheck the recorded source `HEAD` and worktree
  cleanliness after validation and immediately before creating the staging
  directory, refusing to attach artifacts or evidence to stale provenance. The
  dirty-tree exception is now restricted to non-publishable dry runs.
- Tap-timing documentation now scopes the 33 ms minimum to the pure model,
  ISR-driven AVR shells, and simple PIC variant, and records conservative polled
  PIC mute/relay qualification budgets of 38 ms/45 ms plus the pending-timer
  nuance that can shorten the ideal path by roughly one tick.
- Symbolic-test documentation now accurately scopes host/KLEE coverage to every
  invariant-valid state/input tuple and identifies CBMC as the separate proof of
  corrupt program-state handling, released-input recovery of out-of-range
  counters, and undefined behavior obligations.
- The optional KLEE target now compiles and links the symbolic harness with the
  shipping `src/bypass_pure.c` bitcode before execution, preventing unresolved
  core calls from masquerading as a proof of the real implementation.
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
>
> *(Historical note, added at the merge: that project is no longer separate — the
> PIC10F320 target now lives in this repository. This entry is preserved as
> written because it describes the state of the world at v0.9.2.)*

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

[Unreleased]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.5...HEAD
[0.9.5]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.4...v0.9.5
[0.9.4]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.3...v0.9.4
[0.9.3]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.2...v0.9.3
[0.9.2]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.1...v0.9.2
[0.9.1]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/matt-garman/mcu-bypass-firmware/releases/tag/v0.9.0
