
# Hardware Validation Log

Two kinds of hardware evidence exist for this firmware, and they are not the
same kind of claim. This file keeps them apart, because conflating them is how a
project talks itself into believing a design is qualified when it is only
popular.

**Field-use reports** (section 1) are builds by other people, reported publicly:
someone flashed a released image onto a part, put it in a pedal, and said it
worked. That is real evidence — the firmware has executed on real parts, in real
circuits, outside this repository — and it is why "this design has never touched
a chip" would be the wrong thing to say. It is also self-reported and
uncontrolled, and it retains none of the identity, procedure or measurement data
that would let anyone reproduce or audit it. The linked reports were not opened
or independently assessed as part of this repository's review.

**Controlled hardware qualification** (section 2) is a run this project
performed against a written procedure, with the exact source commit, image hash,
part, board, programmer, configuration bytes, instrument readings and acceptance
result retained here. **No part has one yet.** That is the whole `0.9.x` line,
uniformly: see the versioning note at the top of [CHANGELOG.md](CHANGELOG.md).
Completing it is the `1.x.y` hardware-validation pass, tracked in
[TODO.md](TODO.md) as `T3-hw-procedure`, `T3-hil` and `T3-pic12f675-bench`.

Section 1 does not substitute for section 2. A field report cannot close a
residual silicon-only risk, because it did not measure one — a device with a
destroyed factory oscillator trim, or an output sitting just under its input
buffer's threshold, plays fine and reports fine.


## 1. Field-use reports

Community builds, self-reported. A row means "this combination was built and
reported working" and nothing more: no acceptance criteria, no measured values,
no image identity beyond the firmware version the reporter named, and no
independent confirmation that the flashed bytes match a release image. Blank
rows are combinations with no known report, not combinations known to fail.

<!-- field-reports:start -->

| MCU       | Output Scheme   | Firmware Version | Reported by |
| :-------- | :-------------- | :--------------- | :---- |
| ATtiny13a | CD4053 Simple   | pre-v0.9.0       | [Build report](https://forum.pedalpcb.com/threads/custom-barber-ltd-sr-w-microcontroller-bypass.29615/) |
| ATtiny13a | CD4053 Muting   | v0.9.9           | [Quasi-IC](https://www.diystompboxes.com/smfforum/index.php?msg=1312340), [Build report](https://forum.pedalpcb.com/threads/dynamic-haircut-v2-0-barber-gain-changer.29479/post-393071) |
| ATtiny13a | TQ2-L2-5V Relay |                  |       |
| ATtiny45  | CD4053 Simple   |                  |       |
| ATtiny45  | CD4053 Muting   |                  |       |
| ATtiny45  | TQ2-L2-5V Relay |                  |       |
| ATtiny85  | CD4053 Simple   |                  |       |
| ATtiny85  | CD4053 Muting   |                  |       |
| ATtiny85  | TQ2-L2-5V Relay |                  |       |
| ATtiny202 | CD4053 Simple   |                  |       |
| ATtiny202 | CD4053 Muting   |                  |       |
| ATtiny202 | TQ2-L2-5V Relay |                  |       |
| PIC10F320 | CD4053 Simple   |                  |       |
| PIC10F320 | CD4053 Muting   | v0.9.7           | [Build report](https://forum.pedalpcb.com/threads/25-year-pollinator-one-control-silver-bee-hamishr-mod.30010/) |
| PIC10F320 | TQ2-L2-5V Relay |                  |       |
| PIC10F322 | CD4053 Simple   |                  |       |
| PIC10F322 | CD4053 Muting   |                  |       |
| PIC10F322 | TQ2-L2-5V Relay |                  |       |
| PIC12F675 | CD4053 Simple   |                  |       |
| PIC12F675 | CD4053 Muting   |                  |       |
| PIC12F675 | TQ2-L2-5V Relay |                  |       |

<!-- field-reports:end -->


## 2. Controlled hardware qualification

<!-- controlled-qualification:start -->

**No controlled hardware-qualification record exists for any part.**

A record is added here only when a run retained all of the following. The list
is the definition of the term as this project uses it: a run missing any field
is a field-use report, however careful, because a later reader cannot reproduce
it or bound what it did not cover.

- **Date** — the calendar date the bench run was performed.
- **Operator** — who performed it.
- **Source commit** — the full source SHA, and the release tag if the image came
  from one.
- **Image** — the exact file name flashed and its SHA-256, matched against the
  released image set.
- **Part** — MCU part number, package, and the device marking or lot code if it
  is legible.
- **Board** — schematic/PCB revision, which output stage is fitted, and the
  supply voltage measured at the MCU.
- **Programmer** — the programmer hardware and the exact tool version that drove
  it.
- **Configuration** — the fuse or CONFIG bytes written, and the values read back
  from the device afterwards.
- **Procedure** — the written steps executed, by reference, so the same run can
  be repeated.
- **Observations** — what was measured, with the instrument used and how the
  capture was retained. Numbers, not impressions.
- **Result** — PASS or FAIL against the acceptance criteria stated in the
  procedure, plus anything the run did not cover.

The procedure the **Procedure** field is meant to reference does not exist yet
either; writing it is `T3-hw-procedure`. Until then, no record can be complete,
which is the honest state of affairs rather than an accident of ordering.

<!-- controlled-qualification:end -->


## Outstanding controlled runs

### PIC12F675 programmer trim preservation

From `v0.9.10` every release bundles `flash-pic12f675.py`, and `FLASHING.md`
directs a downloaded PIC12F675 image to it rather than to a programmer. The
helper runs the write as a transaction and verifies the factory OSCCAL word and
CONFIG `BG<1:0>` field against two pre-write reads afterwards, so it DETECTS
damage. It cannot prevent it, and nothing in this repository yet establishes
that a real PICkit 3 with MPLAB X 6.20 preserves that trim across an erase.

Until a controlled run recorded above proves the following, treat a helper PASS
as "no damage was observed on this device", not as a validated programming path:

- the read/export command returns complete program, CONFIG, Device ID, revision,
  OSCCAL and BG data in the form the helper parses;
- the write command with calibration-memory programming disabled preserves both
  OSCCAL and BG, on an initial program and on a repeat program of the same part;
- `ipecmd` accepts the image argument in the descriptor-addressed form the
  helper issues (`-F/proc/self/fd/<n>`). That descriptor names a private sealed
  copy of the validated image bytes, not the retained evidence inode. If the
  tool infers the image format from a file extension this is where that shows
  up, and it shows up as a refusal to write rather than as a bad write;
- `ipecmd` accepts device-export arguments through the retained evidence
  directory (`-GF/proc/self/fd/<n>/<name>.hex`), so an evidence-parent rename
  cannot redirect a readback into another directory;
- programmed code and the non-BG CONFIG bits read back exactly as expected, and
  every program word the image does NOT supply reads back erased -- the helper
  now compares the whole device, so a writer whose `-M` leaves stale words
  outside the image publishes a FAIL;
- the documented externally powered arrangement and the release-from-reset
  behaviour are correct; and
- an interrupted PENDING transaction can be finalized read-only without a second
  write.

If MPLAB X 6.20 cannot enforce or report calibration-memory protection through
the supported CLI path, or either trim value changes, the helper does not become
a supported path by assertion and no automatic repair is to be added quietly: a
per-device trim-aware image or an explicit restoration transaction would be a new
design needing its own review, fail-closed binding and hardware validation.

The programmer-powered arrangement stays out of scope for the same reason. The
helper refuses `--power` values other than `external` because no voltage and
interface setup for a programmer-supplied supply has been retained here.


## Additional notes

  - For PIC flashing, I have a knock-off PICKit3 (amusingly labled "PCKit 3"): note that starting with MPLab 6.25, PICKit 3 support was removed; I had to download MPLab 6.20, which is the latest version that works with the PICKit 3
  - I used a `usbasp` programmer with a SOIC-8 clip to program the surface-mount ATtiny13a for my Quasi-IC module
  - I used a `usbtiny` programmer to program through-hole AVR classic chips

### On pin compatibility

Pin compatibility is a **board** property. It is not firmware compatibility, not
programming compatibility, and not an electrical equivalence.

  - The AVR Classic parts (ATtiny13a, ATtiny45, ATtiny85) share a pinout, so one
    board accepts any of the three. Each still needs **its own image and its own
    fuse bytes**: the ATtiny13a runs at 1.2 MHz (`lfuse 0x4a`, `hfuse 0xf9`) and
    the ATtiny45/85 at 1.0 MHz (`lfuse 0x62`, `hfuse 0xcc`). Swapping the chip
    without reprogramming both gives a device that runs with the wrong clock —
    wrong debounce window, wrong mute and relay pulse widths — and still appears
    to work.
  - The PIC10F32x parts (PIC10F320, PIC10F322) share a pinout, so one board
    accepts either. They are **not** the same build: the PIC10F320's 256-word
    flash forces the self-contained firmware of
    [docs/pic10f320_special_case.md](docs/pic10f320_special_case.md), each part
    has its own image, each image carries its own CONFIG word, and the
    programmer must be given the matching part name.
  - Supply range, per-pin drive and total device current are per-part datasheet
    limits. A shared pinout does not equalize them; check the datasheet for the
    part actually fitted.

Per-part flashing commands, with the correct image and fuse/CONFIG values for
each, are in [FLASHING.md](FLASHING.md).
