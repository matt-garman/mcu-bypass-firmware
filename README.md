
# MCU Firmware for Switch Debounce and Electric Instrument Effects Switching

[![CI](https://github.com/matt-garman/mcu-bypass-firmware/actions/workflows/ci.yml/badge.svg)](https://github.com/matt-garman/mcu-bypass-firmware/actions/workflows/ci.yml)

## Overview

The firmware is intended to be used for electric instrument effects
(e.g. guitar effect pedals) bypass switching.  The firmware has the
following responsibilities:

  - Maintain state (engage/bypass)
  - Light or dark a status indicator LED
  - Respond to footswitch presses, _including debounce_
  - Control the actual signal switching mechanism
  - Recover gracefully (to the extent possible) from extreme/outlier situations

Fundamentally, the algorithm uses a saturating integrator to
debounce the footswitch and offer some EMI/RFI protection.

The firmware is bundled with an extensive test and validation suite.
The project's overall goal is to be reference-quality, suitable for
use in professional, touring-grade effects.

See the [Design Documentation](DESIGN_DOCUMENTATION.adoc) for the
complete firmware description and design details.

The source tree supports AVR and PIC microcontrollers; see the
Targets list below for supported hardware.  The current and
historical release contracts, including exact image inventories, are
maintained in [release/README.md](release/README.md).


## Targets

    1. AVR Classic
        - ATtiny13A
        - ATtiny45
        - ATtiny85
    2. AVR XT
        - ATtiny202
    3. PIC Enhanced Midrange
        - PIC10F320
        - PIC10F322
    4. PIC Classic Midrange
        - PIC12F675

The firmware uses a *pure* implementation of the debounce and
state-management algorithm (`src/bypass_pure.c`); it is hardware
independent and side-effect free.  This allows it to be
host-compiled, exhaustively tested, verified, and *formally
analyzed*, independently from the hardware implementation.

**Note:** the PIC10F320 is a special case, as it lacks sufficient
flash memory to use the pure debounce abstraction.  Its
implementation is inlined with its hardware-specific details.

Given a choice, the AVR parts are preferred.  See details in the
[Why AVR Classic](DESIGN_DOCUMENTATION.adoc#why-avr-classic) and
[Why ATtiny202](DESIGN_DOCUMENTATION.adoc#why-avr-xt) in the
[Design Documentation](DESIGN_DOCUMENTATION.adoc).



## Circuit-switching Hardware Support

The firmware supports multiple schemes for actual circuit switching.
These schemes are as follows:

  - Panasonic TQ-L2-5v mechanical relay ("true bypass")
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
  - Built-image simulator validation provides functional, fault-injection,
    lock-step, target-I/O, and soak coverage. Which layer establishes each
    property, for which target and over which substrate, is maintained in
    [test/README.md](test/README.md)
  - Mutation tests (deliberately break code to prove tests catch
    firmware errors)
  - Simulated fault-injection tests to verify WDT functioning

Every item above runs on a host or in a simulator.

A remaining validation step is a *controlled hardware
qualification*, i.e. a physical test bench run against a written
procedure that captures source/image identity, configuration bytes,
instrument readings and acceptance result(s).  However, the
firmwares are being deployed in the field, see
[HARDWARE_VALIDATION_LOG.md](HARDWARE_VALIDATION_LOG.md).

The project is using the `0.9.x` release versioning until all
firmwares have been validated on the bench; the `1.x.y` version is
reserved for that future state.


## Quickstart

### Flashing

For flashing only, it is not necessary to clone this repository or
obtain the complete toolchain.  Only the firmware images, hardware
programmer, and software flashing tool are needed.

  1. Prerequisites
      - A hardware programmer device
          - AVR Classic has many available programmers; "USBasp" and
            "USBtiny" are common and readily available
          - AVR XT uses UPDI (Unified Program and Debug Interface); for
            example, [Adafruit UPDI Friend](https://www.adafruit.com/product/5879)
          - PIC uses PICkit, of which there are multiple versions; this
            project used a PICkit 3 clone; MPLAB Snap appears to be a
            low-cost, modern programmer (but untested in this project)
      - The software flashing tool
          - `avrdude` for ATtiny devices
          - `ipecmd` for PIC devices (generally part of Microchip's MPLAB
            suite, be wary of MPLAB version compatibility with different
            PICkit versions)
  2. Decide which firmware image you need; there are 21 different
     firmware images, one for each combination of microcontroller and
     switching scheme.
  3. Download the latest release firmware for your MCU + switching
     scheme combination
  4. Write the firmware image to the device; see
     [FLASHING.md](FLASHING.md) for the exact command to use,
     **_as there are per-part unique options._**

**Note:** the PIC12F675 is a special case; it additionally
requires use of a dedicated Python script (`flash-pic12f675.py`,
available with the release images).


### Building from Source and Development

The number of supported devices results in a rather large
development toolchain.  Toolchain details are available in
[TOOLCHAIN.adoc](TOOLCHAIN.adoc).  All tools are free; many (but not
all) are open-source.

Once the toolchain is available, you should be able to build the
firmware from source via:


```
make
```

The Makefile has extensive options, see `make help`.  The makefile
has numerous recipes for (or runs scripts to):
  - build
  - program
  - validate
  - test

High-level source overview:
  - `bypass_mcu_*.c` - hardware "shells" for each MCU or MCU family; define `main()` and other hardware-specific details
  - `bypass_hw_iface.h` - the hardware "shell" interface (per-MCU definitions in `bypass_mcu_*.c`)
  - `bypass_output_*.[ch]` - defines the interface and routines for the different switching schemes (relay, x4053)
  - `bypass_pins_*.h` - defines per-MCU pin functions
  - `bypass_pure.[ch]` - the hardware-independent, no-side-effect debounce and state-management algorithm
  - `bypass_types.h` - custom data structures
  - `bypass_static_assert.h` - platform-independent `static_assert()` macro
  - `bypass_blocking_delay.h` - platform-independent `BYPASS_DELAY_MS()` macro
  - `bypass_compile_checks.h` - compile-time `static_assert()` checks
  - `bypass_config.h` - defines `RELEASE_THRESH` and `PRESSED_THRESH`, as well as some (compile-guarded) hardware-specific constants


## Documentation Details

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
| Current release contract: version, parts, images, soaks, topology | the one bounded declaration in [release/README.md](release/README.md) |
| Exact per-release source, image, resource, and qualification results | that release's own retained record under [release/](release) |
| Scoped design decisions and per-part safety records | the topic documents under [docs/](docs) |
| Historical implementation reasoning | Git history |
| Contributor and agent working rules | [AGENTS.md](AGENTS.md), which `CLAUDE.md` includes |
| Licensing terms | [LICENSE](LICENSE) |

### Document Lifecycle

Every durable documentation authority named in the map above has exactly one
label below. The label decides how it is edited and when it may be deleted;
publication as a hosted asset is a distribution fact, not a second lifecycle.

| Label | How it is treated | Where it lives |
|---|---|---|
| Live specification | Edited in place as the design changes; describes only the current state | `DESIGN_DOCUMENTATION.adoc`, `TOOLCHAIN.adoc`, `test/README.md` |
| Operator guidance | Written for someone outside the project who must act safely | `README.md`, `FLASHING.md` |
| Release policy and errata | Maintains the current release process, trust boundary, reproduction guidance, and historical safety notices | `release/README.md` |
| Compliance record | A standing claim held to an external standard | `MISRA_COMPLIANCE.md` |
| Hardware validation record | Accumulates field reports and controlled qualification records without conflating the two | `HARDWARE_VALIDATION_LOG.md` |
| Change record | Adds prospective and dated release entries; existing release sections remain historical accounts | `CHANGELOG.md` |
| Open-work register | Edited as work is opened, refined, or completed; it is not an archive of finished work | `TODO.md` |
| Decision/safety record | Explicitly scoped reasoning that stays useful after the work is finished | the topic documents under `docs/*.md` |
| Contributor policy | Maintained rules for people and coding agents working in this tree | `AGENTS.md`, `CLAUDE.md` |
| Legal terms | Preserved licensing authority for the project | `LICENSE` |
| Release result record | Source-bound provenance and observed evidence. The tag fixes the original bytes; a current-tree copy may differ only by the registered safety-amendment process in `release/README.md` | `release/<version>/QUALIFICATION`, `release/<version>/MANIFEST.md`, `release/<version>/README.md`, `release/<version>/evidence/*` |
| Release payload artifact | Firmware and required programming helpers; their signed byte identity is never corrected in place | `release/<version>/*.hex`, `release/<version>/flash-*.py` |
| Release authentication record | The checksum list and its detached signature; retained byte-for-byte | `release/<version>/SHA256SUMS`, `release/<version>/SHA256SUMS.asc` |

Branch-only work plans are not durable authorities. They carry the required
opening banner, coordinate one branch, and are deleted before release source
finalization; the release gate refuses any that survives.

### Documentation Standing Rules

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


