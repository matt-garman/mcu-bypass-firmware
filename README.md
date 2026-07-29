
# MCU Firmware for Switch Debounce and Electric Instrument Effects Switching

[![CI](https://github.com/matt-garman/mcu-bypass-firmware/actions/workflows/ci.yml/badge.svg)](https://github.com/matt-garman/mcu-bypass-firmware/actions/workflows/ci.yml)

The source tree covers six release parts across three microcontroller core
generations: the "AVR Classic" parts (ATtiny13a, ATtiny45, ATtiny85), the AVR-XT
ATtiny202, and the Microchip PIC10F322 and PIC10F320. Published releases through
`v0.9.5` predate both the PIC10F320 merge and the ATtiny202 promotion; the first
unified release covering all six remains pending production qualification on the
final source (a prior full-tool dry rehearsal passed but is not publishable).

## Targets

| Target | Status | Notes |
|---|---|---|
| ATtiny13a | release-supported | the primary/default target |
| ATtiny45 / ATtiny85 | release-supported | tinyx5 family |
| **ATtiny202 (AVR-XT)** | release-supported | **first release pending**; 2 KB flash, SOIC-8 only (no DIP), UPDI programming |
| PIC10F322 | release-supported | 512 words |
| **PIC10F320** | integrated release candidate | **first unified release pending; constrained exception: 256 words, so the verified core is hand-inlined rather than compiled in — see [docs/pic10f320_special_case.md](docs/pic10f320_special_case.md)** |

Every release target except one compiles the verified core (`src/bypass_pure.c`)
directly into its shipping image. The integrated PIC10F320 candidate cannot — its
flash is half the PIC10F322's — so it carries an inlining seam that
equivalence, real-HEX lock-step and fault injection against that same core
mitigate but do not eliminate. Prefer another part when the choice is yours;
the caveat document explains the trade in full, and
[docs/pic10f320_validation.md](docs/pic10f320_validation.md) records what was
actually run and what it returned.

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
    for PIC10F322 provide functional, fault-injection, lock-step, target-I/O,
    and soak tests; yasimavr for AVR-XT (ATtiny202) provides functional,
    fault-injection, physical target-output timing, and soak tests. The
    PIC10F320 additionally proves its hand-inlined firmware equivalent to the
    verified core, tick for tick, on the host and on the real emitted image
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

To build and validate the PIC ports instead requires a host C compiler,
matching `gcov`, Python 3, and Bash for source coverage, plus the Microchip XC8
compiler, PIC10-12Fxxx device pack, `gpsim`, and `gpsim-dev` for the target-level
gates:

```
make pic                         # build all variants + 512-word flash-budget gate
make pic-test                    # CONFIG, analysis, source coverage, and gpsim checks
make pic-test-target-variants    # fail-closed libgpsim fault/lock-step/I/O gates
```

The PIC10F320 has its own lane, using the same toolchain (`pic320-*` targets,
`PIC320_*` variables):

```
make pic320-variants             # build all variants + flash-budget/return-stack gates
make pic320-test-return-stack    # rebuild + recheck/report all three final HEX images
make pic320-test                 # host equivalence/actuation/fault/coverage,
                                 #   CONFIG, return stack, analysis, gpsim, all variants
make pic320-test-target-variants # fail-closed libgpsim fault/lock-step/I/O gates
```

These targets are independent of the AVR build. Individual optional-tool targets
generally skip cleanly if their primary compiler/simulator is absent. The
PIC10F320 exception is deliberate: every generated `pic320` image must pass the
Python return-stack oracle, and `pic320-test-return-stack` (therefore
`pic320-test`) fails closed if Python or any rebuilt image is missing. Host source
coverage is mandatory when `pic-test` runs. The target aggregates are the
authoritative simulator gates and fail closed on any missing/skipped libgpsim
layer.

To build and validate the ATtiny202 (AVR-XT) port (uses the open-source avr-gcc
toolchain plus the fetched-on-demand Microchip device files and a patched
`yasimavr` simulator built by `scripts/fetch_yasimavr.sh`):

```
make attiny202             # build all variants + 2 KB flash-budget gate
make attiny202-test        # all pre-hardware checks (fuses, budget, analysis, pulse widths)
make attiny202-sim         # yasimavr functional + PA2/PA3 transition/timing test
make attiny202-fault       # fault-injection: corrupt a guarded SFR/state, assert recovery
make attiny202-lockstep    # ctx_-vs-verified-core co-simulation, every settled tick
make attiny202-soak        # long-duration liveness soak (XT_SOAK_DURATION_MS=)
make attiny202-test-target # the fail-closed aggregate release qualification runs
```

Programming is over UPDI rather than ISP. `make attiny202-program VARIANT=<v>
XT_UPDI_PORT=<port>` writes the seven AVR8X fuse bytes and the flash image; it
defaults to avrdude's `serialupdi`, which needs only a USB-serial adapter and a
series resistor.

These targets are also independent of the AVR Classic build and skip cleanly if
the device pack or the `yasimavr` venv is not present — everywhere except release
qualification, which runs them with `STRICT_TOOLS=1` so a missing simulator is a
hard failure rather than silent evidence of nothing.

See [TOOLCHAIN](TOOLCHAIN.adoc) for full environmental details.  
