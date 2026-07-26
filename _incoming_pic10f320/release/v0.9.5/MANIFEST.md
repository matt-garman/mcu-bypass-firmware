# Firmware release v0.9.5

Prebuilt, fully-validated PIC10F320 firmware images. Verify integrity with
`sha256sum -c SHA256SUMS`; reproduce from source per "Reproducing" below.

## Provenance

- **Version / tag:** v0.9.5
- **Source commit:** `331f90f7363d2d19016445667e2fb0a458df4651`
- **Built:** 2026-07-10T20:58:57Z by `matt` on `Linux 6.12.33-production+truenas x86_64`
- **Validation:** `make test-variants` + `make test-mutation` + `make test-target-variants` (real-HEX TRISA/SFR/SRAM fault recovery, firmware<->model ctx_ lock-step, and GPIO transition/pulse timing) + a 24.0-h *simulated-time* parallel libgpsim soak of every variant (see evidence/).

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
| `bypass_mcu_cd4053-simple_pic10f320.hex` | PIC10F320 | 2 MHz (INTOSC) | 219 words / 256 | CONFIG word embedded in HEX | `26531d3408a75297656d722699a1ffafdc47de376af6b4d2aa62b303c6713ca8` |
| `bypass_mcu_cd4053-mute_pic10f320.hex` | PIC10F320 | 2 MHz (INTOSC) | 240 words / 256 | CONFIG word embedded in HEX | `7709a3979b9103411b1f2e0c892d2291e1c232b5033344bd645ae289ac55649f` |
| `bypass_mcu_tq2-relay_pic10f320.hex` | PIC10F320 | 2 MHz (INTOSC) | 243 words / 256 | CONFIG word embedded in HEX | `b77e21221b8a94788781b2d1df6a66e0487317cb215d5d540c5582db2a47c4e2` |

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
git checkout v0.9.5
release_dir="$PWD/release/v0.9.5"
fresh="$(mktemp -d)"
# install the pinned toolchain (see TOOLCHAIN.adoc), then:
make clean
make all PIC_VARIANT=cd4053-simple
make all PIC_VARIANT=cd4053-mute
make all PIC_VARIANT=tq2-relay
cp build_pic/*.hex "$fresh"/
(cd "$fresh" && sha256sum -c "$release_dir/SHA256SUMS")
```
The private directory contains only images copied from the clean fresh build, so
this checks the new bytes rather than the committed release copies. Current and
future releases additionally use `scripts/verify-release-images.sh` to enforce
exact filename-set equality; tag-triggered CI runs that verifier on a clean runner.
