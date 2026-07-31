# yasimavr third-party notice

This directory contains patches for [yasimavr](https://github.com/clesav/yasimavr),
a third-party AVR simulator. The full upstream source is not vendored here;
`scripts/fetch_yasimavr.sh` downloads the pinned source distribution, verifies
its hash, applies these patches, and builds a gitignored local environment.

## Upstream identity

- Package: `yasimavr` 0.1.6
- Upstream tag: `v0.1.6`
- Upstream commit: `b40a6b97fea1f1e1b831152c8e9ec365790578a4`
- PyPI source archive: `yasimavr-0.1.6.tar.gz`
- Source archive SHA-256:
  `3742dae364a8d65ff7d4180d00b40c0901656dafcea6e53e94db1127b7ec6285`
- Package author metadata: C. Savergne `<csavergne@yahoo.com>`

The affected upstream files carry these notices:

- `py/yasimavr/device_library/builders/dev_tiny_0series.py`:
  Copyright 2024-2025 Clement Savergne `<csavergne@yahoo.com>`
- `lib_arch_xt/src/arch_xt_wdt.cpp`:
  Copyright 2021-2026 Clement Savergne `<csavergne@yahoo.com>`

Copyright in yasimavr remains with Clement Savergne and any other upstream
contributors identified in the upstream source.

## License and modifications

The affected upstream files state that yasimavr may be redistributed and/or
modified under the GNU General Public License as published by the Free Software
Foundation, either version 3 or, at the recipient's option, any later version.
Accordingly, the patch files in `patches/` are distributed under
`GPL-3.0-or-later`, not under this repository's root MIT grant. A verbatim copy
of yasimavr's GPLv3 license file is provided as [`COPYING`](COPYING).

The patch set was prepared for mcu-bypass-firmware on 2026-07-09 and changes:

- `0001-tiny0-wdt-builder.patch`: add the WDT peripheral to the tinyAVR 0-series
  device builder.
- `0002-wdt-window-off-delay.patch`: make watchdog PERIOD/WINDOW code 0 produce
  zero delay and use an unsigned shift operand.

The comments at the top of each patch describe the reason and behavior of the
modification. Applying the patches produces a modified yasimavr work governed by
the same GPL terms. The MIT-licensed firmware, tests, build scripts, and other
independent project files remain under the root project license.
