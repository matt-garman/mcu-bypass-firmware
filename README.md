
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

Given a choice, the AVR parts are preferred.  The AVR Classic parts
are mature (legacy, but still current-production), low-cost,
available in through-hole and SMD; and the tooling is open source.
AVR XT is a newer MCU architecture and SMD-only, but otherwise has
similar benefits.  See details in the
[Why AVR Classic](DESIGN_DOCUMENTATION.adoc#why-avr-classic) and
[Why ATtiny202](DESIGN_DOCUMENTATION.adoc#why-avr-xt) in the
[Design Documentation](DESIGN_DOCUMENTATION.adoc).



## Circuit-switching Hardware Support

The firmware supports multiple schemes for actual circuit switching.
These schemes are as follows:

  - Panasonic TQ2-L2-5V mechanical relay ("true bypass")
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

<!-- qualification-status:start -->
A remaining validation step is a *controlled hardware
qualification*, i.e. a physical test bench run against a written
procedure that captures source/image identity, configuration bytes,
instrument readings and acceptance result(s).  However, the
firmwares are being deployed in the field, see
[HARDWARE_VALIDATION_LOG.md](HARDWARE_VALIDATION_LOG.md).
<!-- qualification-status:end -->

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
  2. Decide which firmware image you need; there is one for each
     combination of microcontroller and switching scheme.
  3. Download the latest release firmware for your MCU + switching
     scheme combination
  4. Write the firmware image to the device; see
     [FLASHING.md](FLASHING.md) for the exact command to use,
     **_as there are per-part unique options._**

<!-- pic12f675-helper-required:start -->
**Note:** the PIC12F675 is a special case. Writing a released image to it
additionally requires Python 3 and the release's dedicated helper script
(`flash-pic12f675.py`, available with the release images), because the part's
per-device factory calibration must be preserved and verified rather than
overwritten by a raw programmer write.
<!-- pic12f675-helper-required:end -->

<!-- pic12f675-helper-status:start -->
That helper's `ipecmd` route is published and software-tested, but it is not
hardware-qualified, and the board must be externally powered.
[FLASHING.md](FLASHING.md) carries the full transaction and everything it
requires.
<!-- pic12f675-helper-status:end -->


### Building from Source and Development

The number of supported devices results in a rather large
development toolchain.  Toolchain details are available in
[TOOLCHAIN.adoc](TOOLCHAIN.adoc).  All tools are free; many (but not
all) are open-source.

Every lane needs a host C compiler (GCC 10 or newer, or Clang), a
matching `gcov`, Python 3.7 or newer, and Bash.  The per-part lanes
add their own: `pic10f322-*`, `pic10f320-*` and `pic12f675-*` need the
Microchip XC8 compiler, the PIC10-12Fxxx device pack, `gpsim` and
`gpsim-dev`; `attiny202-*` needs avr-gcc plus the fetched-on-demand
Microchip device files and the patched `yasimavr` that
`scripts/fetch_yasimavr.sh` builds.

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

How this project's documentation is owned, edited, retired, and enforced --
the authority map, the document lifecycle, the standing rules, and what the
release gates hold to -- is in [GOVERNANCE.md](GOVERNANCE.md).
