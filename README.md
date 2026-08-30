
# MCU Firmware for Switch Debounce and Electric Instrument Effects Switching

[![CI](https://github.com/matt-garman/mcu-bypass-firmware/actions/workflows/ci.yml/badge.svg)](https://github.com/matt-garman/mcu-bypass-firmware/actions/workflows/ci.yml)

The source tree covers seven release parts across four microcontroller core
generations: the "AVR Classic" parts (ATtiny13a, ATtiny45, ATtiny85), AVR-XT
ATtiny202, enhanced mid-range PIC10F322/PIC10F320, and classic mid-range
PIC12F675. Release `v0.9.6` was the first unified release, covering the first six
parts with 18 prebuilt images. PIC12F675 is release-supported from `v0.9.9`,
raising the canonical set to 21 images; see the table below.

## Targets

| Target | Status | Notes |
|---|---|---|
| ATtiny13a | release-supported | the primary/default target |
| ATtiny45 / ATtiny85 | release-supported | tinyx5 family |
| **ATtiny202 (AVR-XT)** | release-supported | first released in `v0.9.6`; 2 KB flash, SOIC-8 only (no DIP), UPDI programming |
| PIC10F322 | release-supported | 512 words |
| **PIC10F320** | release-supported | **first released here in `v0.9.6`; constrained exception: 256 words, so the debounce algorithm is implemented directly rather than by compiling the verified core — see "PIC10F320: the constrained target" in [DESIGN_DOCUMENTATION.adoc](DESIGN_DOCUMENTATION.adoc#pic10f320-architecture)** |
| **PIC12F675** | release-supported | **first released here in `v0.9.9`; classic mid-range: 1024 words, no `LATx` (the output latch is an SRAM shadow), 1.024 ms tick. Every pre-hardware lane the release parts have, plus a calibration contract they do not — and, uniquely, guarded development and signed-release programming procedures that check and record factory OSCCAL/BG before and after writing, plus a release-shipped `flash-pic12f675.py` so a downloaded image can be programmed under the same transaction with no source checkout (see [FLASHING.md](FLASHING.md)). Real preservation remains hardware-unvalidated (see [release/README.md](release/README.md) and `make pic12f675-release-program`). See [DESIGN_DOCUMENTATION.adoc](DESIGN_DOCUMENTATION.adoc)** |

Every release target except one compiles the verified core (`src/bypass_pure.c`)
directly into its shipping image. The release-supported PIC10F320 cannot — its
flash is half the PIC10F322's — so it carries an inlining seam that equivalence
and real-HEX lock-step against that same core, plus independent fault injection,
mitigate but do not eliminate. Prefer another part when the choice is yours;
[DESIGN_DOCUMENTATION.adoc](DESIGN_DOCUMENTATION.adoc#pic10f320-architecture)
explains the trade in full, and the retained record under `release/<version>/`
identifies the qualified source commit and what its gates returned.

The firmware is intended to be used for electric instrument
effects (e.g. guitar effect pedals) bypass switching.  The firmware
has four responsibilities:

  - Maintain state (engage/bypass)
  - Light or dark a status indicator LED
  - Respond to footswitch presses, _including debounce_
  - Control the actual signal switching mechanism

Fundamentally, the algorithm uses a saturating integrator to debounce the
footswitch and offer some EMI/RFI protection.

The firmware is bundled with an extensive test and validation suite.
The project's overall goal is to be reference-quality, suitable for
use in professional, touring-grade effects.

See the [Design Documentation](DESIGN_DOCUMENTATION.adoc) for the complete
firmware description and design details.


## Circuit-switching Hardware Support

The firmware currently supports circuit-switching via:

  - Panasonic TQ-L2-5v mechanical relay
  - CD4053 or TMUX4053 electrical analog switches, two variants:
    - Simple scheme using only two DPDT switches
    - Fancier scheme using all three DPDT switches with a 5ms mute

See the [Design Documentation](DESIGN_DOCUMENTATION.adoc) for the control line
specifics.  Note that it should be possible to use other analog switches (e.g.
DG413) or relays (e.g. Kemet EC2-3TNU).


## Testing and Validation Features


  - [MISRA-C](https://en.wikipedia.org/wiki/MISRA_C):2012 checked;
    compliant with documented deviations (see
    [MISRA_COMPLIANCE.md](MISRA_COMPLIANCE.md))
  - [CBMC](https://www.cprover.org/cbmc/) formal analysis
  - Provable correctness via formal state analysis
  - Core debounce algorithm written as pure functionality, thus
    host-compilable for exhaustive fuzz testing
  - Built-image simulator validation: simavr for AVR Classic and gpsim/libgpsim
    for PIC10F322, PIC10F320, and PIC12F675 provide functional, fault-injection,
    lock-step, target-I/O, and soak tests; yasimavr does the same for the AVR-XT
    ATtiny202, plus its PA2/PA3 transition ordering. Which layer establishes
    which property, over which substrate, is [test/README.md](test/README.md)
  - Mutation tests (deliberately break code to prove tests catch
    firmware errors)
  - Simulated fault-injection tests to verify WDT functioning

Every item above runs on a host or in a simulator. **No part has completed
controlled hardware qualification** — a bench run against a written procedure
whose source/image identity, configuration bytes, instrument readings and
acceptance result are retained. That is what the `1.x.y` line adds, and it is
the criterion for leaving `0.9.x`. Released images *have* been flashed onto real
parts and reported working by builders;
[HARDWARE_VALIDATION_LOG.md](HARDWARE_VALIDATION_LOG.md) records those field-use
reports, keeps them separate from qualification records, and states what a
qualification record must retain.


## Documentation map

Each fact in this project has exactly one live owner. A document may link to
another authority, but it does not restate that authority's mutable data —
counts, measurements, versions, or inventories. If keeping one fact true would
mean editing two documents, the fact is in the wrong place.

| Topic | Sole live authority |
|---|---|
| Product overview, target selection, and this map | `README.md` |
| Normative firmware and hardware design | [DESIGN_DOCUMENTATION.adoc](DESIGN_DOCUMENTATION.adoc) |
| General operator flashing safety and workflow | [FLASHING.md](FLASHING.md) |
| Exact programming commands for one release | the generated `MANIFEST.md` in that release's own directory |
| Toolchain requirements and pins | [TOOLCHAIN.adoc](TOOLCHAIN.adoc), plus the executable pin definitions the build enforces |
| MISRA scope, deviations, and maintenance | [MISRA_COMPLIANCE.md](MISRA_COMPLIANCE.md) |
| Test layers, substrates, and aggregate entry points | [test/README.md](test/README.md) |
| Test implementation detail, fixtures, and check counts | the executable tests themselves |
| Target, variant, and resource policy | the Makefile's canonical target and variant maps, which the per-variant recipes are derived from |
| Hardware field reports and controlled qualification records | [HARDWARE_VALIDATION_LOG.md](HARDWARE_VALIDATION_LOG.md) |
| Open work | [TODO.md](TODO.md) |
| User-visible change history | [CHANGELOG.md](CHANGELOG.md) |
| Current development status | the `[Unreleased]` section of [CHANGELOG.md](CHANGELOG.md) |
| Release process, trust model, errata, and reproduction | [release/README.md](release/README.md) |
| Exact per-release source, image, resource, and qualification results | that release's own retained record under [release/](release) |
| Scoped design decisions and per-part safety records | the topic documents under [docs/](docs) |
| Historical implementation reasoning | Git history |
| Contributor and agent working rules | [AGENTS.md](AGENTS.md), which `CLAUDE.md` includes |

### Document lifecycle

Every durable document is exactly one of the following, and the label decides
how it is edited and when it may be deleted.

| Label | How it is treated | Where it lives |
|---|---|---|
| Live specification | Edited in place as the design changes; describes only the current state | `DESIGN_DOCUMENTATION.adoc`, `TOOLCHAIN.adoc`, `test/README.md` |
| Operator guidance | Written for someone outside the project who must act safely | `README.md`, `FLASHING.md` |
| Compliance record | A standing claim held to an external standard | `MISRA_COMPLIANCE.md` |
| Decision/safety record | Explicitly scoped reasoning that stays useful after the work is finished | the topic documents under `docs/` |
| Release evidence | Source-bound results retained for one release, never edited after its tag | each `release/<version>/` record |
| Historical release artifact | A published release's shipped files, preserved exactly as published | each `release/<version>/` bundle |
| Branch-only work plan | Coordinates work on one branch and is deleted before release source finalization; the release gate refuses any that survives | root-level working documents |

### Standing rules

- **Git history is the archive.** A completed plan or work journal is deleted
  from the branch tip once its durable conclusions have been moved into the
  document that owns them. Retaining the journal beside the specification it
  fed produces two accounts of the same subject, one of which stops being
  true.
- **Current measurements belong to CI output or retained release evidence**,
  not to development prose. A number that changes when the code changes has no
  stable owner in a hand-edited document.
- **Generated human views are not independently maintained.** Where a document
  is rendered from canonical data — per-release programming guidance, resource
  tables, release manifests — the generator and its input are the authority.
  Correct the input, never the rendered copy.


## Quickstart

Programming a downloaded release does not require the firmware development
toolchain or a repository checkout. Most targets require only the released HEX
and programmer CLI. PIC12F675 additionally requires Python 3 and the release's
flashing helper because its per-device factory calibration must be preserved and
verified. The helper's `ipecmd` route is published and software-tested, but it is
not hardware-qualified. See [FLASHING.md](FLASHING.md) for the per-part
`avrdude` and `ipecmd` command templates and the PIC12F675 helper invocation,
and [HARDWARE_VALIDATION_LOG.md](HARDWARE_VALIDATION_LOG.md) for which
combinations builders have reported working and why a shared pinout does not
make two parts interchangeable to flash. The rest of this section is about
building from source.

Upgrading a worktree last used to build `v0.9.7` or earlier: run `make clean`
once before the first new build, or retired and current image names will
coexist. If that build set a custom PIC build directory, its variable was
renamed too; the override mapping is under
[Renamed in v0.9.8](release/README.md#renamed-in-v098-v097-and-earlier-used-different-names).

Requires avrtools, assumes a USBtiny programmer, and a fresh
ATtiny13a chip (see `make help` for how to build/program other
MCUs):

```
make
make attiny13a-program
```

`attiny13a-program` is one ordered transaction, and the order is deliberate: it
builds and validates the selected image first, then writes the fuses, then
flashes. Nothing reaches the chip until an image exists and passes Intel HEX
validation, so a failed build cannot leave a device carrying the design's
clock/watchdog/BOD fuses with no matching firmware. `attiny13a-fuses` and
`attiny13a-flash` remain available when you want exactly one of the two steps.

The PIC and AVR-XT ports build and validate through their own lanes,
independent of the AVR Classic build. All of them need a host C compiler (GCC 10
or newer, or Clang — see [TOOLCHAIN](TOOLCHAIN.adoc)), matching `gcov`, Python
3.7 or newer, and Bash. Beyond that, the `pic10f322-*`, `pic10f320-*` and
`pic12f675-*` lanes need the Microchip XC8 compiler, the PIC10-12Fxxx device
pack, `gpsim` and `gpsim-dev`; the `attiny202-*` lane needs avr-gcc plus the
fetched-on-demand Microchip device files and the patched `yasimavr` that
`scripts/fetch_yasimavr.sh` builds. Each lane has a build goal, a pre-hardware
aggregate, and a fail-closed target aggregate:

```
make pic10f322 && make pic10f322-test pic10f322-test-target-variants
make pic10f320-variants && make pic10f320-test pic10f320-test-target-variants
make pic12f675 && make pic12f675-test pic12f675-test-target-variants
make attiny202 && make attiny202-test attiny202-test-target
```

`make help` lists every goal and the variables that select its behavior.
[test/README.md](test/README.md) says what each aggregate establishes, which
lanes fail closed rather than skipping when a tool is absent, and why the two
PIC12F675 aggregates belong in one Make invocation rather than two.

Programming an ATtiny202 is over UPDI rather than ISP. `make attiny202-program
VARIANT=<v> XT_UPDI_PORT=<port>` is the same ordered transaction the AVR Classic
parts use, and defaults to avrdude's `serialupdi`, which needs only a USB-serial
adapter and a series resistor.

> **PIC12F675 is not a raw write target.** A bulk erase destroys the per-device
> factory oscillator trim and bandgap calibration that no image can supply, and
> a part that has lost either still appears to run. Programming one is a guarded
> transaction rather than a command, and each route has exactly one home:
> [FLASHING.md](FLASHING.md) carries the downloaded-release route through
> `flash-pic12f675.py`, and [release/README.md](release/README.md) carries the
> development and release-provenance route, including how to resolve an
> interrupted transaction. Never hand a PIC12F675 image to a programmer
> directly, and never program a simulator-derived image onto a real device: the
> calibration word such an image carries is fabricated.

See [TOOLCHAIN](TOOLCHAIN.adoc) for full environmental details.  
