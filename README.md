
# MCU Firmware for Switch Debounce and Electric Instrument Effects Switching

[![CI](https://github.com/matt-garman/mcu-bypass-firmware/actions/workflows/ci.yml/badge.svg)](https://github.com/matt-garman/mcu-bypass-firmware/actions/workflows/ci.yml)

**NOTE:** for PIC10F320 support, see the child project
[pic10f320-bypass-firmware](https://github.com/matt-garman/pic10f320-bypass-firmware).
This project's release-supported targets are PIC10F322 and AVR Classic. It also
contains a development-only ATtiny202 port that is built and exercised in
normal CI but is not included in prebuilt releases. This is the preferred
project unless the PIC10F320 is a hard requirement.

The release-supported firmware covers two microcontroller families: the
"AVR Classic" parts (ATtiny13a, ATtiny45, ATtiny85) and the Microchip
PIC10F322. The development-only AVR-XT lane currently targets ATtiny202.
A shared, hardware-independent debounce core and the output drivers are
common to all targets; only a small per-MCU hardware shell differs. The
firmware is intended to be used for electric instrument
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
    for PIC10F322 provide functional, fault-injection, lock-step, target-I/O,
    and soak tests; yasimavr for AVR-XT (ATtiny202) provides functional,
    fault-injection, physical target-output timing, and soak tests
  - Mutation tests (deliberately break code to prove tests catch
    firmware errors)
  - Simulated fault-injection tests to verify WDT functioning


# Quickstart

Requires avrtools, assumes a USBtiny programmer, and a fresh
ATtiny13a chip (see `make help` for how to build/program other
MCUs):

```
make
make program
```

To build and validate the PIC10F322 port instead requires a host C compiler,
matching `gcov`, and Bash for source coverage, plus the Microchip XC8 compiler,
PIC10-12Fxxx device pack, `gpsim`, and `gpsim-dev` for the target-level gates:

```
make pic                         # build all variants + 512-word flash-budget gate
make pic-test                    # CONFIG, analysis, source coverage, and gpsim checks
make pic-test-target-variants    # fail-closed libgpsim fault/lock-step/I/O gates
```

These targets are independent of the AVR build. External PIC tool targets skip
cleanly if XC8/gpsim are not installed; host source coverage is mandatory when
`pic-test` runs. The target aggregate is the authoritative simulator gate and
fails closed on any missing/skipped libgpsim layer.

To build and validate the development-only ATtiny202 (AVR-XT) port (uses the
open-source avr-gcc toolchain plus the fetched-on-demand Microchip device files
and a patched `yasimavr` simulator built by `scripts/fetch_yasimavr.sh`):

```
make attiny202        # build all variants + 2 KB flash-budget gate
make attiny202-sim    # yasimavr functional + PA2/PA3 transition/timing test
make attiny202-fault  # fault-injection: corrupt a guarded SFR/state, assert recovery
make attiny202-soak   # long-duration liveness soak (XT_SOAK_DURATION_MS=)
```

These targets are also independent of the AVR build and skip cleanly if the
device pack or the `yasimavr` venv is not present. Normal CI builds and runs
the dynamic gates for this lane, but ATtiny202 images and long-soak evidence are
not part of the release product set or release qualification.

See [TOOLCHAIN](TOOLCHAIN.adoc) for full environmental details.  
