# Flashing quick reference

Command templates for putting a **released** image on a chip. Programming a
downloaded release does not require the firmware development toolchain or a
repository checkout. Most targets require only the released HEX and programmer
CLI. PIC12F675 additionally requires Python 3 and the release's flashing helper
because its per-device factory calibration must be preserved and verified.

Images: <https://github.com/matt-garman/mcu-bypass-firmware/releases>, named
`bypass-<mcu>-<variant>.hex`. Download `SHA256SUMS` and `SHA256SUMS.asc`
alongside them and verify the signature before programming anything.

Variants: `cd4053_simple`, `cd4053_with_mute`, `tq2_l2_5v_relay`.

Which combinations have been flashed and reported working by builders is
recorded in [HARDWARE_VALIDATION_LOG.md](HARDWARE_VALIDATION_LOG.md). Those are
self-reported field-use reports, not controlled qualification: no part in this
repository has completed a controlled hardware-qualification run, and the same
file says what one would have to retain.


## AVR classic — ATtiny13a / ATtiny45 / ATtiny85

ISP, via `avrdude`. Fuses are separate from flash and only need writing once
per chip.

```
avrdude -c <prog> -p <part> \
  -U lfuse:w:<lfuse>:m -U hfuse:w:<hfuse>:m \
  -U flash:w:bypass-<mcu>-<variant>.hex:i
```

| MCU       | `-p`  | lfuse  | hfuse  | clock   |
| :-------- | :---- | :----- | :----- | :------ |
| ATtiny13a | `t13` | `0x4a` | `0xf9` | 1.2 MHz |
| ATtiny45  | `t45` | `0x62` | `0xcc` | 1.0 MHz |
| ATtiny85  | `t85` | `0x62` | `0xcc` | 1.0 MHz |

`hfuse` sets the design's 4.3 V brown-out level. Neither fuse touches RSTDISBL
or DWEN, so ISP access survives.

`-c <prog>`: `usbtiny` (USBtinyISP), `usbasp` (USBasp and clones), `avrisp2`
(AVRISP mkII), `stk500v1` (Arduino as ISP — add `-P <port> -b 19200`).

### Examples

```
# ATtiny13a, muting CD4053, through-hole, USBtiny
avrdude -c usbtiny -p t13 -U lfuse:w:0x4a:m -U hfuse:w:0xf9:m \
  -U flash:w:bypass-attiny13a-cd4053_with_mute.hex:i

# same chip, SOIC-8 clip on a USBasp
avrdude -c usbasp -p t13 -U lfuse:w:0x4a:m -U hfuse:w:0xf9:m \
  -U flash:w:bypass-attiny13a-cd4053_with_mute.hex:i

# ATtiny85, relay
avrdude -c usbtiny -p t85 -U lfuse:w:0x62:m -U hfuse:w:0xcc:m \
  -U flash:w:bypass-attiny85-tq2_l2_5v_relay.hex:i

# reflash only — fuses already correct on this chip
avrdude -c usbtiny -p t13 -U flash:w:bypass-attiny13a-tq2_l2_5v_relay.hex:i

# read the chip's current fuses before changing anything
avrdude -c usbtiny -p t13 -U lfuse:r:-:h -U hfuse:r:-:h
```

If a 1.2 MHz ATtiny13a stops answering ISP, slow the clock: add `-B 32`
(USBasp: or fit its slow-SCK jumper).


## AVR-XT — ATtiny202

UPDI, not ISP: needs a UPDI adapter (USB-serial with ~4.7 kΩ in series between
TX and RX, tied to the UPDI pin). USBtiny and USBasp cannot do UPDI. Seven fuse
bytes, same once-per-chip rule.

```
avrdude -c serialupdi -P /dev/ttyUSB0 -p t202 \
  -U wdtcfg:w:0x06:m -U bodcfg:w:0xE5:m -U osccfg:w:0x01:m \
  -U syscfg0:w:0xF6:m -U syscfg1:w:0x07:m \
  -U append:w:0x00:m -U bootend:w:0x00:m \
  -U flash:w:bypass-attiny202-cd4053_simple.hex:i
```

`syscfg0=0xF6` fuse-locks the watchdog on and keeps UPDI enabled — write it
exactly.


## PIC10F320 / PIC10F322 — PICkit 3 + `ipecmd`

CONFIG rides inside the HEX (XC8 `#pragma config`), so there is no fuse step:
one command programs code and configuration together.

MPLAB X 6.25 dropped PICkit 3 support — use 6.20 or earlier.

```
IPECMD=/opt/microchip/mplabx/v6.20/mplab_platform/mplab_ipe/ipecmd.jar

java -jar "$IPECMD" -TPPK3 -P<part> -F<hex> -M -Y -OL -W5
```

Windows: run
`"C:\Program Files\Microchip\MPLABX\v6.20\mplab_platform\mplab_ipe\ipecmd.exe"`
directly with the same flags (`/` also works in place of `-`).

| flag     | meaning |
| :------- | :------ |
| `-TPPK3` | tool is a PICkit 3 (`PK4`, `PK5` for newer kits) |
| `-P`     | part, e.g. `PIC10F322` |
| `-F`     | hex file |
| `-M`     | program the whole device (program memory + configuration) |
| `-Y`     | verify afterwards |
| `-OL`    | release from reset when done, so the chip runs immediately |
| `-W5`    | **PICkit sources 5 V to the target.** Omit it when the board has its own supply. |

### Examples

```
# PIC10F320, muting CD4053, powered by the PICkit
java -jar "$IPECMD" -TPPK3 -PPIC10F320 \
  -Fbypass-pic10f320-cd4053_with_mute.hex -M -Y -OL -W5

# PIC10F322, relay, board externally powered
java -jar "$IPECMD" -TPPK3 -PPIC10F322 \
  -Fbypass-pic10f322-tq2_l2_5v_relay.hex -M -Y -OL
```

PICkit 2 equivalent: `pk2cmd -PPIC10F322 -F<hex> -M -Y -R` (add `-T` to power
the target).

If `ipecmd` rejects the part name, drop the prefix (`-P10F322`) — Microchip's
CLI readme documents the short form.

`-W5`, `-OL` and the `PIC…`-prefixed part spelling come from Microchip's CLI
documentation and community usage, not from a session logged in this
repository. Confirm them on the first PICkit 3 run and correct this file.


## PIC12F675 — not a raw write target

**Do not pass a PIC12F675 release HEX to `ipecmd` or `pk2cmd` directly.** Pass
it to the release's flashing helper, `flash-pic12f675.py`, which ships in the
same release bundle and is covered by the same signed `SHA256SUMS`.

The helper binds itself by NAME AND BYTES, not by location. It requires its own
bytes to appear in the selected bundle's `SHA256SUMS` under its released name, so
a copy that was edited, renamed, or never published by this release is refused
before the device is touched: the tool and the image it writes are covered by one
signature, or neither of them is. Where the copy happens to live is not checked —
a byte-identical `flash-pic12f675.py` run from anywhere is the released tool, and
one sitting inside the bundle with a single byte changed is not.

This part is the one target where a correct HEX plus a writer is *not*
sufficient, because two per-device factory-trimmed values live in memory the
programmer erases:

- **OSCCAL** — the last program word, `0x3FF`, holds `RETLW <cal>` (`0x34xx`),
  which the XC8 startup code calls. Lose it and the INTOSC is untrimmed: wrong
  tick cadence and wrong relay/mute pulse widths, on a chip that still looks
  like it works.
- **BG<1:0>** — bandgap trim in CONFIG `0x2007`, bits 13:12; sets the BOD/POR
  trip points.

Neither is in the shipping HEX — its last data record ends at word `0x3FE`, and
its CONFIG record (`:02400E00CC31`, i.e. `0x31CC`) leaves BG erased. So the
values on your specific chip are the only copy there is, and the write is a
transaction rather than a command.

### Programming

Needs Python 3, the downloaded release bundle, and MPLAB X 6.20 `ipecmd`. The
helper's `ipecmd` route is published and software-tested, but it is not
hardware-qualified.
**Power the board externally** — external power is the only arrangement this
helper supports, programmer-supplied Vdd is refused, and the documented external
arrangement itself still awaits controlled hardware validation. Choose a NEW
evidence directory per device; the helper creates it and refuses a path that
already exists.

```sh
IPECMD=/opt/microchip/mplabx/v6.20/mplab_platform/mplab_ipe/ipecmd.jar

python3 flash-pic12f675.py program \
  --image bypass-pic12f675-cd4053_simple.hex \
  --ipecmd "$IPECMD" \
  --evidence-dir ./pic12f675-device-001
```

It reads the device, reads it again to prove nothing moved, writes a durable
`reservation.json`, performs exactly one write, then reads the whole device back
and publishes one immutable `result.json` with `PASS` or a detailed `FAIL`. Every
image, checksum, tool-version, trim and path check happens **before** an
erase/program argument is constructed, so a refusal never reaches the device.
The complete factory export is retained either way, so the only copy of this
chip's trim is not lost if the first attempt goes badly.

Both pre-write reads must return a **complete** full-device export that agrees
with itself. A reader that omits part of program memory, or reports one address
with two different values, is refused rather than trusted: the retained baseline
is the only copy of what was on the chip, and an incomplete one would be
incomplete for exactly the memory the next command erases. The `ipecmd` you name
is also pinned by content, and re-checked immediately before every command it is
given, so a tool replaced or edited part-way through a transaction stops it
instead of running.

A `FAIL` is a forensic record, not permission to retry — keep the evidence
directory and that device together.

### If it is interrupted

An evidence directory with `reservation.json` and no `result.json` is
**PENDING**. Keep physical custody of the same device. Do not write, reflash, or
reuse the directory. Resolve it read-only — this mode never constructs a write
argument:

```sh
python3 flash-pic12f675.py finalize \
  --evidence-dir ./pic12f675-device-001 \
  --ipecmd "$IPECMD"
```

### What a PASS does and does not mean

It means no trim damage was **observed** on that device. It is not proof that
PICkit 3 / MPLAB X 6.20 preserves calibration across an erase: that preservation
is **not yet validated on hardware here**, and the helper detects damage after
the write rather than preventing it. See
[HARDWARE_VALIDATION_LOG.md](HARDWARE_VALIDATION_LOG.md) for the controlled bench
run that has to be retained before this path can be called qualified.

In MPLAB IPE leave **"allow ... to program calibration memory" OFF** — that
setting is what lets a write clobber `0x3FF`.

### Building from source instead

The repository also has a guarded, evidence-recording transaction for
developers (`make pic12f675-preflight`, then `make pic12f675-release-program`).
It rebuilds the image privately and binds it to a signed tag, so it needs the
full toolchain, a source checkout, and a **pk2cmd** reader. That is the
development and release-provenance path, not a requirement for flashing
downloaded release bytes. See [release/README.md](release/README.md).
