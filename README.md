
# MCU Firmware for Switch Debounce and Electric Instrument Effects Switching

[![CI](https://github.com/matt-garman/mcu-bypass-firmware/actions/workflows/ci.yml/badge.svg)](https://github.com/matt-garman/mcu-bypass-firmware/actions/workflows/ci.yml)

The source tree covers six release parts across three microcontroller core
generations: the "AVR Classic" parts (ATtiny13a, ATtiny45, ATtiny85), the AVR-XT
ATtiny202, and the Microchip PIC10F322 and PIC10F320. Release `v0.9.6` is the
first unified release covering all six: 18 prebuilt images qualified from the
final source, including ATtiny202 and PIC10F320 for the first time.

A seventh part, the Microchip PIC12F675, is present and fully gated in CI but
is **not release-supported** — see the table below.

## Targets

| Target | Status | Notes |
|---|---|---|
| ATtiny13a | release-supported | the primary/default target |
| ATtiny45 / ATtiny85 | release-supported | tinyx5 family |
| **ATtiny202 (AVR-XT)** | release-supported | first released in `v0.9.6`; 2 KB flash, SOIC-8 only (no DIP), UPDI programming |
| PIC10F322 | release-supported | 512 words |
| **PIC10F320** | release-supported | **first released here in `v0.9.6`; constrained exception: 256 words, so the debounce algorithm is implemented directly rather than by compiling the verified core — see [docs/pic10f320_special_case.md](docs/pic10f320_special_case.md)** |
| PIC12F675 | **staged — not release-supported** | classic mid-range: 1024 words, no `LATx` (the output latch is an SRAM shadow), 1.024 ms tick. Every pre-hardware lane the release parts have, plus a calibration contract they do not need, and all of it gated in CI, plus `pic12f675-program` for bench work — but no release images and **no hardware-bench validation yet**. See [docs/pic12f675_feasibility.md](docs/pic12f675_feasibility.md) |

Every release target except one compiles the verified core (`src/bypass_pure.c`)
directly into its shipping image. The release-supported PIC10F320 cannot — its
flash is half the PIC10F322's — so it carries an inlining seam that equivalence
and real-HEX lock-step against that same core, plus independent fault injection,
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
    fault-injection, lock-step, PA2/PA3 transition ordering, polarity,
    pulse-presence, and soak tests. A separate built-image disassembly oracle
    verifies the compiled 5 ms mute and 12 ms relay delay-body cycle counts. The
    PIC10F320's directly implemented algorithm is additionally compared with the
    verified core, tick for tick, by scoped host and real-image lock-step lanes
  - Mutation tests (deliberately break code to prove tests catch
    firmware errors)
  - Simulated fault-injection tests to verify WDT functioning


# Quickstart

Requires avrtools, assumes a USBtiny programmer, and a fresh
ATtiny13a chip (see `make help` for how to build/program other
MCUs):

If this existing worktree was used to build `v0.9.7` or earlier, after updating
run `make clean` once before the first new build. Custom PIC build-directory
variables were renamed too; if the old build used any custom build directory,
follow the cleanup override mapping under
[Renamed in v0.9.8](release/README.md#renamed-in-v098-v097-and-earlier-used-different-names).
Without that one-time clean, retired and current image names can coexist.

```
make
make attiny13a-program
```

To build and validate the PIC ports instead requires a host C compiler,
matching `gcov`, Python 3.7 or newer, and Bash for source coverage, plus the
Microchip XC8 compiler, PIC10-12Fxxx device pack, `gpsim`, and `gpsim-dev` for
the target-level gates:

```
make pic10f322                         # build all variants + 512-word flash-budget gate
make pic10f322-test                    # CONFIG, analysis, source coverage, and gpsim checks
make pic10f322-test-target-variants    # fail-closed libgpsim fault/lock-step/I/O gates
```

The PIC10F320 has its own lane, using the same toolchain (`pic10f320-*` targets,
`PIC10F320_*` variables):

```
make pic10f320-variants             # build all variants + flash-budget/return-stack gates
make pic10f320-test-build           # rebuild + enforce reviewed SHA-256 image baseline
make pic10f320-test-return-stack    # rebuild + recheck/report all three final HEX images
make pic10f320-test                 # host equivalence/actuation/fault/coverage,
                                 #   hashes, CONFIG, return stack, analysis/gpsim
make pic10f320-test-target-variants # fail-closed libgpsim fault/lock-step/I/O gates
```

The PIC12F675 has its own lane on the same XC8 installation (`pic12f675-*`
targets, `PIC12F675_*` variables, and the 322's `PIC_CC`/`PIC_DFP` pair):

```
make pic12f675                      # build all variants + 1024-word flash-budget gate
make pic12f675-test                 # CONFIG, analysis, source coverage, calibration
                                    #   contract, gpsim, and the 8-level stack bound
make pic12f675-test-target-variants # fail-closed libgpsim fault/lock-step/I/O gates
make pic12f675-preflight \
  PIC12F675_TRIM_EVIDENCE=pic12f675-baseline.json # read-only factory-trim capture
make pic12f675-program VARIANT=cd4053_simple \
  PIC12F675_TRIM_EVIDENCE=pic12f675-baseline.json \
  PIC12F675_BENCH_RESULT=pic12f675-program-result
# Renamed/path-qualified IPE executable:
make pic12f675-program VARIANT=tq2_l2_5v_relay \
  PIC12F675_PROG=/opt/microchip/ipe/ipecmd.sh PIC12F675_PROG_KIND=ipecmd \
  PIC12F675_READ_PROG=/usr/bin/pk2cmd \
  PIC12F675_TRIM_EVIDENCE=pic12f675-baseline.json \
  PIC12F675_BENCH_RESULT=pic12f675-ipe-result
```

Its simulator lanes run *derived* images: `make pic12f675-simcal` injects the
oscillator calibration word that a real device carries in its last program word
and that an erased simulator image does not, and `make pic12f675-test-calibration`
proves the injection leaves the shipping images byte-identical. That is why this
part has one aggregate lane the others do not.

The same asymmetry is why `make pic12f675-program` rebuilds the complete matrix,
derives one image only from validated `VARIANT`, and checks a private read-only
snapshot before writing it. A derived image carries a *fabricated* calibration
value, and putting one on a real device would overwrite that device's factory
oscillator trim irreversibly — and silently, since the part still runs
afterwards. The snapshot must leave that word unprogrammed, carry the intended
CONFIG, and retain one SHA-256 digest through every check; the programmer gets
that same snapshot through directly constructed argv. External image and
whole-command overrides are deliberately unsupported.

Programming also requires a baseline made by the read-only
`pic12f675-preflight` target. It records the exact reader binary/version and
device ID/revision plus word `0x3FF`, CONFIG, and `BG<1:0>`. The write target
repeats that read immediately before programming, refuses a mismatch, reads the
device again afterwards, and publishes an exclusive result containing the raw
transcripts, programmed-byte comparison, and before/after values. The
`PIC12F675_BENCH_RESULT` path is reserved as a new directory before the write;
`reservation.json` remains useful after interruption and `result.json` records
the final PASS/FAIL. A baseline is a one-device, pre-first-write record: the
immediate read must match its complete exported HEX as well as identity/trim, so
do not reuse it for another device or a later reflash. pk2cmd is the pinned
readback dialect. An
ipecmd write therefore needs `PIC12F675_READ_PROG` set to the pk2cmd reader used
for the baseline; no untested IPE read command is guessed. These records enable
the silicon check but do not replace it: the part remains staged until retained
real-hardware evidence passes.

These targets are independent of the AVR build. Individual optional-tool targets
generally skip cleanly if their primary compiler/simulator is absent. The
PIC10F320 exception is deliberate: every generated `pic10f320` image must pass the
Python return-stack oracle. `pic10f320-test-build` additionally requires the
complete rebuilt matrix to match the reviewed XC8/DFP SHA-256 baseline, and
`pic10f320-test-return-stack` rechecks all three images. These targets feed
`pic10f320-test` and fail closed if Python, the baseline, or an image is missing.
Host source coverage is mandatory when `pic10f322-test` runs. The target aggregates
are the authoritative simulator gates and fail closed on any missing/skipped
libgpsim layer.

To build and validate the ATtiny202 (AVR-XT) port (uses the open-source avr-gcc
toolchain plus the fetched-on-demand Microchip device files and a patched
`yasimavr` simulator built by `scripts/fetch_yasimavr.sh`):

```
make attiny202             # build all variants + 2 KB flash-budget gate
make attiny202-test        # all pre-hardware checks (fuses, budget, analysis, pulse widths)
make attiny202-sim         # yasimavr functional + PA2/PA3 transition/pulse-presence test
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
