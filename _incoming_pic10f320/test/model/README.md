# Reference model (vendored)

These files are the **reference model** of the debounce algorithm — a verbatim
copy of the parent project's host- and formally-verified pure core:

| File | Vendored from `mcu-bypass-firmware` |
| --- | --- |
| `bypass_pure.c` | `src/bypass_pure.c` |
| `bypass_pure.h` | `src/bypass_pure.h` |
| `bypass_types.h` | `src/bypass_types.h` |

`bypass_config.h` here is NOT vendored: it is a minimal host-only header that
supplies just `RELEASE_THRESH` / `PRESSED_THRESH` for this model (the parent's
real `bypass_config.h` is laden with AVR-target detail).

## Why a copy

This project's firmware (`../../bypass_mcu_pic10f320.c`) inlines this algorithm
to fit the PIC10F320's 256-word flash, so there is no separable pure unit in the
firmware itself to test. Instead we test this vendored model directly (host unit
tests in `../host/`, CBMC + symbolic proofs in `../formal/`) and separately prove
the real firmware is behaviorally identical to it (`make test-equiv`).

## Provenance & sync

- Vendored from `mcu-bypass-firmware` @ commit `bf6a6c1`
  (`bf6a6c15071bdc56bc96de740eec83e8a87cd78b`) — the same commit the firmware is
  derived from (see the top-level `README.md`).
- This is a frozen copy. If the parent's pure core changes, re-copy these three
  files. The equivalence test guards against the firmware and this model drifting
  apart; re-syncing keeps the model current with the parent's verified core.
