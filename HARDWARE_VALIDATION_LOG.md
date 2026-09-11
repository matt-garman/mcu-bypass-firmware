
# Hardware Validation Log

Two kinds of hardware evidence exist for this firmware:

**Field-use reports** (section 1) are builds by other people, reported publicly:
someone flashed a released image onto a part, put it in a pedal, and said it
worked. That is real evidence - the firmware has executed on real parts, in real
circuits, outside this repository - and it is why "this design has never touched
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
| ATtiny202 | TMUX4053 Simple |                  |       |
| ATtiny202 | TMUX4053 Muting |                  |       |
| ATtiny202 | TQ2-L2-5V Relay |                  |       |
| PIC10F320 | CD4053 Simple   |                  |       |
| PIC10F320 | CD4053 Muting   | v0.9.7           | [Build report](https://forum.pedalpcb.com/threads/25-year-pollinator-one-control-silver-bee-hamishr-mod.30010/) |
| PIC10F320 | TQ2-L2-5V Relay |                  |       |
| PIC10F322 | CD4053 Simple   |                  |       |
| PIC10F322 | CD4053 Muting   |                  | [Build report](https://forum.pedalpcb.com/threads/plague-doctor-custom-proco-fat-rat.30299/)      |
| PIC10F322 | TQ2-L2-5V Relay |                  |       |
| PIC12F675 | CD4053 Simple   |                  |       |
| PIC12F675 | CD4053 Muting   | v0.9.13          | [Build report](https://forum.pedalpcb.com/threads/warp-south-custom-greer-lightspeed-southland.30298/)      |
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
as "no damage was observed on this device", not as a validated programming path.
The bench run of 2026-09-07 below is not that run, but it did settle several of
these, and disproved two outright; each is marked with what it now rests on.

- **CORRECTED.** The read/export command returns complete program, CONFIG,
  OSCCAL and BG data in the form the helper parses, and a revision -- but NO
  numeric Device ID. `ipecmd` prints none for this part under any option, `-I`
  included, and the export carries no DEVID word at 0x2006 either. The helper
  records `device_id_source: unavailable` and proceeds on the part name, the
  revision and a full word-for-word comparison of the two pre-write reads.
  *Observed 2026-09-07.*
- The write command with calibration-memory programming disabled preserves both
  OSCCAL and BG. *Initial program on a blank part: observed 2026-09-07. Repeat
  program of the same part: still outstanding, and it is the more interesting
  half.*
- **CORRECTED.** `ipecmd` does NOT accept the image argument as a sealed-copy
  descriptor. `-F/proc/self/fd/<n>` naming a memfd fails with `Hex file not
  found.` and programs nothing: a JVM canonicalises the pathname it is given,
  and a memfd canonicalises to `/memfd:<name> (deleted)`, which does not exist.
  The helper now hands the writer the retained `image.hex` under the evidence
  directory's descriptor, which the same run proved `ipecmd` does accept. This
  showed up as a refusal to write rather than a bad write, as predicted.
  *Observed 2026-09-07.*
- `ipecmd` accepts device-export arguments through the retained evidence
  directory (`-GF/proc/self/fd/<n>/<name>.hex`), so an evidence-parent rename
  cannot redirect a readback into another directory. *Observed 2026-09-07.*
- programmed code and the non-BG CONFIG bits read back exactly as expected, and
  every program word the image does NOT supply reads back erased -- the helper
  now compares the whole device, so a writer whose `-M` leaves stale words
  outside the image publishes a FAIL. *Observed 2026-09-07, but on a part that
  was already blank, so the erased-word half of this cannot distinguish "the
  erase worked" from "there was nothing to erase". A second program of the same
  part, now carrying 574 words, is what would.*
- the documented externally powered arrangement and the release-from-reset
  behaviour are correct; *external power observed 2026-09-07. Release-from-reset
  is NOT covered: nothing in that run executed the programmed firmware.* and
- an interrupted PENDING transaction can be finalized read-only without a second
  write. *Still outstanding.*

If MPLAB X 6.20 cannot enforce or report calibration-memory protection through
the supported CLI path, or either trim value changes, the helper does not become
a supported path by assertion and no automatic repair is to be added quietly: a
per-device trim-aware image or an explicit restoration transaction would be a new
design needing its own review, fail-closed binding and hardware validation.

The programmer-powered arrangement is now constructible but still unqualified.
`--power tool` adds `-W` so the PICkit 3 supplies Vdd, because a bare part on a
breadboard cannot be read without it; `external` remains the default and the
only arrangement any run here has exercised. No voltage or interface setup for a
programmer-supplied supply has been retained, and the tool cannot choose a
voltage in any case -- every VDD/VPP option `ipecmd` 6.20 exposes is marked
*Applicable only for PM3*, so `-W` requests nominal Vdd and nothing else.

The inherited command shape has now been executed, and it was wrong in four
places. The pinned device pack registers the PIC12F675 with the same MPLAB
hardware-tool set as the PIC10F322 this project already programs — an identical
`hwtools` file list in the pack's `.pdsc`, and both parts named in every
`sdm*.xml` that names either — and that was the whole basis for the command
shape, because no programmer is installed on any machine this repository's test
suite runs on. Pack registration turned out to be evidence that the part is
listed and nothing more: the version pin, the `-P` spelling, the target-power
option and the image argument each had to be corrected against a real tool
before a single word was written. What that shape is worth is now a matter of
record rather than inference.

### PIC12F675 bench run, 2026-09-07

Not a controlled qualification, and it must not be read as one: no written
procedure exists to execute (`T3-hw-procedure`), the helper was locally modified
so its release checksum binding was bypassed, the part sat on a breadboard with
no board or output stage fitted, and nothing was measured with an instrument.
What it is, is the first execution of the shipped programming path against real
silicon, with the evidence retained.

- **Date** — 2026-09-07 (transaction `created_utc` 2026-09-08T02:57:44Z).
- **Part** — PIC12F675, breadboard, externally powered. Device revision `0xB`;
  no numeric device ID is obtainable, see above.
- **Programmer** — PICkit 3, firmware suite 01.56.09, driven by MPLAB X 6.20
  `ipecmd.jar`, device pack `PIC10-12Fxxx_DFP,1.9.189`.
- **Image** — `bypass-pic12f675-cd4053_with_mute.hex`, SHA-256
  `655fd28fe8075389ab571218393c0cececf215d4a4a8aac5fa85452863e16c45`.
- **Helper** — SHA-256 `328258b14aafc65c43817e51d286f91b6470a22a299389ab9dc0c08c77f28301`,
  locally modified; this is deliberately NOT a released helper's digest.
- **Result** — helper `status=PASS`, `failures=[]`, `result.json` SHA-256
  `e1d5b2789f40e4384359f55bfe9e1de6bbca2431a2d1b0515cfd1e55c8afee8d`.

Re-derived from the retained exports independently of the helper's own
arithmetic: all 574 program words the image supplies were programmed exactly;
all 449 words it does not supply read back erased; the readback covered
1024/1024 words; OSCCAL at 0x3FF was `0x3424` (`RETLW 0x24`) before and after and
is still a valid `RETLW`; and CONFIG read back `0x11CC`, which is exactly
`(image 0x31CC & ~BG) | (factory BG 0x1000)`. The transcript records
`Device Erased...` before `Programming/Verify complete`, so the trim survived a
real bulk erase.

What it does not establish: anything about a released helper (this one was
modified), anything about a repeat program of an already-programmed part,
anything about the erase on a part that had something to erase, and anything at
all about the programmed firmware running — no output stage was fitted and
nothing was powered up afterwards.

### PIC12F675 GP2 readback margin

This one needs a meter rather than a programmer, and it is the only outstanding
item whose subject is the board rather than the tool.

Having no output latch, the PIC12F675 shell keeps an SRAM output shadow and
re-reads `GPIO` against it every 1.024 ms tick. That makes the guard depend on
the output pins' *input* thresholds, and GP2 is the only output in this design
whose input buffer is a Schmitt Trigger (VIH min 0.8·VDD) rather than TTL (VIH
min 2.0 V). A pin driving its load correctly but landing between the two reads
back low, the integrity check fires, and the part resets — permanently, because
the condition is static. The thresholds and the reference-board margin are in
[DESIGN_DOCUMENTATION.adoc](DESIGN_DOCUMENTATION.adoc); gpsim models pins
ideally, so no lane in this repository can see the condition at all.

**The run:** on a built `cd4053_with_mute` board with the real load attached,
engage the effect and measure GP2 against VDD. Record the measured level, the
supply, and which of the two board options is fitted, since the CD4053 and
TMUX4053 boards load the pin differently. Confirm the level exceeds 0.8·VDD and
record the margin: that margin is what bounds the minimum fail-safe pulldown a
builder may substitute, which is the only part of the load a builder chooses.
The requirement itself is stated in `src/bypass_pins_pic12f675.h` alongside the
GP3 and GP4 pin policies.


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
    flash forces the self-contained firmware described in
    [DESIGN_DOCUMENTATION.adoc](DESIGN_DOCUMENTATION.adoc#pic10f320-architecture),
    each part has its own image, each image carries its own CONFIG word, and the
    programmer must be given the matching part name.
  - Supply range, per-pin drive and total device current are per-part datasheet
    limits. A shared pinout does not equalize them; check the datasheet for the
    part actually fitted.

Per-part flashing commands, with the correct image and fuse/CONFIG values for
each, are in [FLASHING.md](FLASHING.md).
