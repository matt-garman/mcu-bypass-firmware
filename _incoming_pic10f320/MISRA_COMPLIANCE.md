# MISRA-C:2012 compliance — PIC10F320 bypass firmware

This firmware targets MISRA-C:2012 conformance, checked mechanically by
`make analyze-misra` (cppcheck + the MISRA addon, `pic8-enhanced` platform). The
analysis runs against the single firmware translation unit,
`bypass_mcu_pic10f320.c`.

## Status: zero deviations

`make analyze-misra` passes with **no entries** in `test/misra_suppressions.txt`.

This is cleaner than the parent project (`mcu-bypass-firmware`), whose AVR shells
require documented deviations for integer-address register access (Rules 11.4,
10.1, 10.8 via avr-libc's `_SFR_*` macros). This firmware accesses every special
function register through XC8's volatile named-register and bitfield-union model
(e.g. `LATA |= ...`, `PIR1bits.TMR2IF`), which does not trip those rules.

Keep it this way: prefer fixing a finding over waiving it. Any genuinely
unavoidable future deviation must be added to `test/misra_suppressions.txt` as a
per-file `errorId:filename` entry **and** recorded here as a numbered `D-n` record
with its rationale. A suppression without a matching record here is a defect.

## Deviation records

None.

## Boundary

The XC8 and DFP system headers (`xc.h`, `pic.h`, `proc/pic10f320.h`, …) are
outside this project's compliance boundary — they are the adopted toolchain
library, analogous to avr-libc for the AVR build. Findings inside them are
suppressed by path on the cppcheck command line (see the `Makefile`), not in the
deviations file.

## Notes on specific constructs

A few intentional choices in the source exist to *stay* MISRA-clean; they are not
deviations, but are recorded here because the source comments reference this file:

- **`DEBOUNCE_COUNTER_MAX` as `(255U)` rather than `<stdint.h>`'s `UINT8_MAX`.**
  By C integer-promotion rules a `uint8_t` promotes to (signed) `int`, so
  `UINT8_MAX` has type `int`; comparing it against the project's unsigned debounce
  thresholds would be an essential-type-category mix (Rule 10.4), and its
  expansion `0x7f*2+1` also trips Rule 12.1. A plain unsigned literal means the
  same value and avoids both.
- **Local copies of would-be-`const` values.** Some locals initialized from a
  runtime call (e.g. the debounce counter, the program state) are not
  `const`-qualified, because XC8 places `const`-qualified objects in program ROM
  and rejects a `const` local initialized from a non-compile-time-constant. This
  is a required PIC/XC8 accommodation, not a MISRA deviation.
