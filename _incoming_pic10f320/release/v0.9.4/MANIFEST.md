# Firmware release v0.9.4

Prebuilt, fully-validated PIC10F320 firmware images. Verify integrity with
`sha256sum -c SHA256SUMS`; reproduce from source per "Reproducing" below.

## Provenance

- **Version / tag:** v0.9.4
- **Source commit:** `80bbef1bb90bcaa9254e065899b393f229b80384`
- **Built:** 2026-07-10T18:17:29Z by `matt` on `Linux 6.12.33-production+truenas x86_64`
- **Validation:** `make test-variants` + `make test-mutation` + per-variant `make test-fault-gpsim` (silicon-level fault-recovery on the real HEX) + per-variant `make test-lockstep-gpsim` (firmware<->model ctx_ lock-step on the real HEX) + a 24.0-h *simulated-time* parallel libgpsim soak of every variant (see evidence/).

## Toolchain

| tool | version |
|---|---|
| XC8 | Microchip MPLAB XC8 C Compiler V3.10 |
| PIC DFP | /opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189/xc8 |
| gpsim | gpsim-0.32.1 # (Mar 31 2024) |
| host cc | cc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0 |
| host c++ | c++ (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0 |
| cppcheck | Cppcheck 2.13.0 |
| cbmc | 5.95.1 (cbmc-5.95.1) |
| python3 | Python 3.14.5 |

## Images

| image | MCU | clock | flash used | config | sha256 |
|---|---|---|---|---|---|
| `bypass_mcu_cd4053-simple_pic10f320.hex` | PIC10F320 | 2 MHz (INTOSC) | 217 words / 256 | CONFIG word embedded in HEX | `c11ff56a87485dbc280405f7e3b40ceea48c8c518ad458819f5b08a88a0f3a13` |
| `bypass_mcu_cd4053-mute_pic10f320.hex` | PIC10F320 | 2 MHz (INTOSC) | 240 words / 256 | CONFIG word embedded in HEX | `18f30e6ec2257f5db788065937b0ad8e346d8ec9a28edbc800c65859d964ec26` |
| `bypass_mcu_tq2-relay_pic10f320.hex` | PIC10F320 | 2 MHz (INTOSC) | 241 words / 256 | CONFIG word embedded in HEX | `aff31bca82839ba28d0b631813354c5e714068f736ae784e026bd965ea541e4e` |

## Flashing

The PIC10F320 CONFIG word is embedded in the HEX, so writing the HEX
configures the device -- there is no separate fuse step.

```
# bypass_mcu_cd4053-mute_pic10f320.hex
pk2cmd -PPIC10F320 -Fbypass_mcu_cd4053-mute_pic10f320.hex -M -Y -R

# bypass_mcu_cd4053-simple_pic10f320.hex
pk2cmd -PPIC10F320 -Fbypass_mcu_cd4053-simple_pic10f320.hex -M -Y -R

# bypass_mcu_tq2-relay_pic10f320.hex
pk2cmd -PPIC10F320 -Fbypass_mcu_tq2-relay_pic10f320.hex -M -Y -R

```

## Soak evidence

| variant | result |
|---|---|
| cd4053-simple | SOAK PASS: 24.00 h simulated. wdt_resets=0 liveness_fails=0 checks=1440 |
| cd4053-mute | SOAK PASS: 24.00 h simulated. wdt_resets=0 liveness_fails=0 checks=1440 |
| tq2-relay | SOAK PASS: 24.00 h simulated. wdt_resets=0 liveness_fails=0 checks=1440 |

## Reproducing these images

```
git checkout v0.9.4
# install the pinned toolchain (see TOOLCHAIN.adoc), then build every variant:
make clean
make all PIC_VARIANT=cd4053-simple
make all PIC_VARIANT=cd4053-mute
make all PIC_VARIANT=tq2-relay
sha256sum -c release/v0.9.4/SHA256SUMS
```
The tag-triggered CI (.github/workflows/release.yml) performs exactly this
check on a clean runner and fails the release on any mismatch.
