# Flashing quick reference

Command templates for putting a **released** image on a chip. Needs only a
programmer and its CLI — no build toolchain, no clone of this repository.

Images: <https://github.com/matt-garman/mcu-bypass-firmware/releases>, named
`bypass-<mcu>-<variant>.hex`.

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


## PIC12F675 — same command, plus factory calibration

Programming is the `-PPIC12F675` form of the command above. The extra care is a
per-chip factory trim that a bulk erase destroys:

- **OSCCAL** — the last program word, `0x3FF`, holds `RETLW <cal>` (`0x34xx`),
  which the XC8 startup code calls. Lose it and the INTOSC is untrimmed: wrong
  tick cadence and wrong relay/mute pulse widths, on a chip that still looks
  like it works.
- **BG<1:0>** — bandgap trim in CONFIG `0x2007`, bits 13:12; sets the BOD/POR
  trip points.

Neither is in the shipping HEX — its last data record ends at word `0x3FE`, and
its CONFIG record (`:02400E00CC31`, i.e. `0x31CC`) leaves BG erased. Whether
`ipecmd` preserves them across its erase is **not verified on hardware here**,
so capture them before the first write.

```
# 1. archive the virgin device BEFORE anything else
java -jar "$IPECMD" -TPPK3 -PPIC12F675 -GFfactory-12f675-<id>.hex

# 2. record the two factory values from that file
#    OSCCAL: the record covering byte address 0x07FE (word 0x3FF),
#            little-endian -> expect 0x34xx, i.e. RETLW <cal>
#    BG:     the ':02400E00' CONFIG record, bits 13:12 of the word

# 3. program
java -jar "$IPECMD" -TPPK3 -PPIC12F675 \
  -Fbypass-pic12f675-cd4053_simple.hex -M -Y -OL -W5

# 4. read back and compare those same two values
java -jar "$IPECMD" -TPPK3 -PPIC12F675 -GFafter-12f675-<id>.hex
```

In MPLAB IPE leave **"allow ... to program calibration memory" OFF** — that
setting is what lets a write clobber `0x3FF`.

If step 4 shows `0x3FF` erased to `0x3FFF`, the trim is gone: reprogram that one
word as `RETLW <saved cal>` (turn the calibration-memory setting on, then back
off), or recalibrate against a known reference. Either way, record the result —
it is what closes `docs/pic12f675_feasibility.md` §8 items 1-2.

This repository also has a guarded, evidence-recording version of the whole
transaction (`make pic12f675-preflight`, then `make pic12f675-release-program`),
but it needs the full toolchain and a **pk2cmd** reader. See
[release/README.md](release/README.md).
