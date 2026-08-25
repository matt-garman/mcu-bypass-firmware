
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
| **PIC10F320** | release-supported | **first released here in `v0.9.6`; constrained exception: 256 words, so the debounce algorithm is implemented directly rather than by compiling the verified core — see [docs/pic10f320_special_case.md](docs/pic10f320_special_case.md)** |
| **PIC12F675** | release-supported | **first released here in `v0.9.9`; classic mid-range: 1024 words, no `LATx` (the output latch is an SRAM shadow), 1.024 ms tick. Every pre-hardware lane the release parts have, plus a calibration contract they do not — and, uniquely, guarded development and signed-release programming procedures that check and record factory OSCCAL/BG before and after writing, plus a release-shipped `flash-pic12f675.py` so a downloaded image can be programmed under the same transaction with no source checkout (see [FLASHING.md](FLASHING.md)). Real preservation remains hardware-unvalidated (see [release/README.md](release/README.md) and `make pic12f675-release-program`). See [docs/pic12f675_feasibility.md](docs/pic12f675_feasibility.md)** |

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
    for PIC10F322, PIC10F320, and PIC12F675 provide functional, fault-injection,
    lock-step, target-I/O, and soak tests; yasimavr for AVR-XT (ATtiny202) provides functional,
    fault-injection, lock-step, PA2/PA3 transition ordering, polarity,
    pulse-presence, and soak tests. A separate built-image disassembly oracle
    verifies the compiled 5 ms mute and 12 ms relay delay-body cycle counts. The
    PIC10F320's directly implemented algorithm is additionally compared with the
    verified core, tick for tick, by scoped host and real-image lock-step lanes.
    PIC12F675 additionally proves that its simulator-only calibration derivation
    leaves all three shipping images byte-identical
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


# Quickstart

Programming a downloaded release does not require the firmware development
toolchain or a repository checkout. Most targets require only the released HEX
and programmer CLI. PIC12F675 additionally requires Python 3 and the release's
flashing helper because its per-device factory calibration must be preserved and
verified. See [FLASHING.md](FLASHING.md) for the per-part `avrdude` and `ipecmd`
command templates and the PIC12F675 helper invocation, and
[HARDWARE_VALIDATION_LOG.md](HARDWARE_VALIDATION_LOG.md) for which combinations
builders have reported working and why a shared pinout does not make two parts
interchangeable to flash. The rest of this section is about building from
source.

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

`attiny13a-program` is one ordered transaction, and the order is deliberate: it
builds and validates the selected image first, then writes the fuses, then
flashes. Nothing reaches the chip until an image exists and passes Intel HEX
validation, so a failed build cannot leave a device carrying the design's
clock/watchdog/BOD fuses with no matching firmware. `attiny13a-fuses` and
`attiny13a-flash` remain available when you want exactly one of the two steps.

To build and validate the PIC ports instead requires a host C compiler (GCC 10
or newer, or Clang — see [TOOLCHAIN](TOOLCHAIN.adoc)), matching `gcov`, Python
3.7 or newer, and Bash for source coverage, plus the Microchip XC8 compiler,
PIC10-12Fxxx device pack, `gpsim`, and `gpsim-dev` for the target-level gates:

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
make pic12f675                      # build all variants + 1024-word flash/48-byte data gates
make pic12f675-test pic12f675-test-target-variants
                                    # one retained hash-qualified matrix across
                                    # CONFIG, analysis, coverage, calibration,
                                    # gpsim, stack, and all libgpsim variants
# Replace with the intended release tag containing pic12f675-release-program.
release_tag=vX.Y.Z &&
repo=$(git rev-parse --show-toplevel) &&
head_commit=$(git -C "$repo" rev-parse --verify "HEAD^{commit}") &&
tag_commit=$(git -C "$repo" rev-parse --verify \
  "refs/tags/$release_tag^{commit}") &&
worktree_status=$(git -C "$repo" status --porcelain=v1 --untracked-files=normal) &&
test "$head_commit" = "$tag_commit" && test -z "$worktree_status" &&
evidence_root=$(dirname "$repo") &&
baseline="$evidence_root/pic12f675-factory-baseline.json" &&
result="$evidence_root/pic12f675-program-result" &&
test ! -e "$baseline" && test ! -e "$result" &&
make -C "$repo" pic12f675-preflight \
  PIC12F675_READ_PROG=pk2cmd \
  PIC12F675_TRIM_EVIDENCE="$baseline" &&
make -C "$repo" pic12f675-release-program \
  VARIANT=cd4053_simple \
  PIC12F675_RELEASE_TAG="$release_tag" \
  PIC12F675_PROG=pk2cmd PIC12F675_PROG_KIND=pk2cmd \
  PIC12F675_READ_PROG=pk2cmd \
  PIC12F675_TRIM_EVIDENCE="$baseline" \
  PIC12F675_BENCH_RESULT="$result"
```

If an interruption leaves `reservation.json` but no `result.json`, the
transaction is **PENDING**. Keep physical custody of the same attached device;
do not write, reflash, capture a new baseline, or reuse the result path. From the
same source checkout, resolve it with the same release identity, variant, and
tool identities:

```sh
make -C "$repo" pic12f675-finalize \
  VARIANT=cd4053_simple \
  PIC12F675_RELEASE_TAG="$release_tag" \
  PIC12F675_PROG=pk2cmd PIC12F675_PROG_KIND=pk2cmd \
  PIC12F675_READ_PROG=pk2cmd \
  PIC12F675_TRIM_EVIDENCE="$baseline" \
  PIC12F675_BENCH_RESULT="$result"
```

Finalization never invokes writer arguments. It revalidates the selected release
identity, the reservation, and the separately retained image first, verifies the
reader version before a full-device read, and exclusively publishes the recovered
PASS/FAIL `result.json`. Private read attempts are retry-safe after interruption.
A FAIL is a resolved forensic record, not permission to retry the write. An
existing result is immutable.

`pic12f675-preflight` is read-only and device-specific; it does not take
`VARIANT`. Only run the program step after preflight succeeds, using the same
new baseline and a new result directory path. The parents of both paths must
already exist.

Transient full-device reads and the private programming build use `TMPDIR` when
set, otherwise `XDG_RUNTIME_DIR`, otherwise `HOME`. The selected root must
already exist, be owned by the current user, grant no group/other access, and
have only current-user- or root-owned, non-group/other-writable ancestors;
shared `/tmp` and `/var/tmp` roots are rejected. Its path may contain letters,
digits, spaces, `/`, `.`, `_`, and `-`. Success, failure, and handled-signal
paths remove those transient directories; only the explicitly requested
baseline and result paths are retained.

Run this workflow only from a clean checkout of the intended annotated release
tag with the pinned XC8/DFP toolchain. `pic12f675-release-program` verifies the
pinned tag and checksum signatures, validates the complete release image set,
and requires its private fresh build to match the selected signed digest. It
does not consume a downloaded release HEX. `pic12f675-program` remains an
explicit development/bench path and does not claim signed-release provenance.
No ipecmd hardware procedure is published yet. Its software-tested route needs
pk2cmd reads immediately before and after the IPE write, and no safe
dual-programmer attachment or handoff has been validated.

Its simulator lanes run *derived* images: `make pic12f675-simcal` injects the
oscillator calibration word that a real device carries in its last program word
and that an erased simulator image does not, and `make pic12f675-test-calibration`
proves the injection leaves the shipping images byte-identical. That is why this
part has one aggregate lane the others do not.

Request the two PIC12F675 aggregates in one Make invocation as shown above. Make
then builds one retained shipping/derived matrix and records SHA-256 for all six
images plus the six assembly/symbol sidecars consumed by the target lanes. It
promotes that record to the qualified manifest only after the discarded private
compiler build and calibration probes agree, then rechecks it after every
consumer. Every aggregate PASS names the same twelve-artifact identity. Release
qualification retains that JSON manifest and binds its digest, the final shipped
HEX bytes, and their `SHA256SUMS` entries into one verified evidence chain. Separate
invocations remain valid standalone qualifications, but necessarily create
separate retained matrices and therefore cannot be combined as one evidence set.

The same asymmetry is why both PIC12F675 programming goals rebuild the complete matrix,
derives one image only from validated `VARIANT`, and checks a private read-only
snapshot before writing it. A derived image carries a *fabricated* calibration
value, and putting one on a real device would overwrite that device's factory
oscillator trim irreversibly — and silently, since the part still runs
afterwards. The snapshot must leave that word unprogrammed, carry the intended
CONFIG, and retain one SHA-256 digest through every check; the programmer gets
that same snapshot through directly constructed argv. External image and
whole-command overrides are deliberately unsupported. The release goal adds the
signed-byte gate; the development/bench goal deliberately does not impersonate it.

Programming also requires a baseline made by the read-only
`pic12f675-preflight` target. It records the exact reader binary/version and
device ID/revision plus word `0x3FF`, CONFIG, and `BG<1:0>`. The write target
repeats that read immediately before programming, refuses a mismatch, reads the
device again afterwards, and publishes an exclusive result containing the raw
transcripts, programmed-byte comparison, and before/after values. The
`PIC12F675_BENCH_RESULT` path is reserved as a new directory before the write;
`reservation.json` remains useful after interruption and `result.json` records
the final PASS/FAIL. Until a PENDING reservation is finalized, keep the same
device under physical custody and prohibit another write or baseline. A baseline
is a one-device, pre-first-write record: the
immediate read must match its complete exported HEX as well as identity/trim, so
do not reuse it for another device or a later reflash. pk2cmd is the pinned
readback dialect. The software-tested ipecmd write route would require pk2cmd
reads immediately before and after the write, but no safe dual-programmer
attachment or handoff has been validated, so no ipecmd hardware procedure is
published. These records enable the silicon check but do not replace it: closing
§8 items 1 and 2 needs retained
real-hardware evidence, which is the `1.x.y` hardware-validation pass (TODO
`T3-pic12f675-bench`) that every part in this repository still awaits — not a
`0.9.x` release blocker for this one.

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
make attiny202             # build all variants + 2 KB flash/16-byte static-RAM gates
make attiny202-test        # pre-hardware checks (fuses, resources, stack, analysis, widths)
make attiny202-sim         # yasimavr functional + PA2/PA3 transition/pulse-presence test
make attiny202-fault       # fault-injection: corrupt a guarded SFR/state, assert recovery
make attiny202-lockstep    # ctx_-vs-verified-core co-simulation, every settled tick
make attiny202-soak        # long-duration liveness soak (XT_SOAK_DURATION_MS=)
make attiny202-test-target # the fail-closed aggregate release qualification runs
```

Programming is over UPDI rather than ISP. `make attiny202-program VARIANT=<v>
XT_UPDI_PORT=<port>` builds and validates the selected image, then writes the
seven AVR8X fuse bytes, then flashes — the same ordered transaction the AVR
Classic parts use, so a missing device pack or a failed build reaches no
programmer at all. It defaults to avrdude's `serialupdi`, which needs only a
USB-serial adapter and a series resistor.

These targets are also independent of the AVR Classic build and skip cleanly if
the device pack or the `yasimavr` venv is not present — everywhere except release
qualification, which runs them with `STRICT_TOOLS=1` so a missing simulator is a
hard failure rather than silent evidence of nothing.

See [TOOLCHAIN](TOOLCHAIN.adoc) for full environmental details.  
