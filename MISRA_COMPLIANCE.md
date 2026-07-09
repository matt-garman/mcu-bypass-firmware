# MISRA-C:2012 Compliance Summary

This firmware is checked against the **MISRA-C:2012** guidelines for the C
language subset used in critical and embedded systems. This document records
the compliance posture, the analysis method, and every deviation — each MISRA
rule the project knowingly does not satisfy, with its justification.

The intent is a *compliant-with-documented-deviations* posture: the analysis
runs clean except for a small, explicitly enumerated set of deviations that are
inherent to bare-metal AVR programming, each justified below and waived through
a per-file entry in [`test/misra_suppressions.txt`](test/misra_suppressions.txt).

> **Note on rule wording.** The official MISRA rule texts are copyrighted by the
> MISRA Consortium and are not reproduced here. The summaries below are our own
> paraphrases for orientation only; consult the published MISRA-C:2012 standard
> for the authoritative text, rationale, exceptions, and amplification.

## How it is checked

| | |
|---|---|
| Analyzer | `cppcheck` 2.13.0, MISRA addon (`misra.py`) |
| Target model | `--platform=avr8`, `--std=c11` |
| Compiler / headers | `avr-gcc` 7.3.0 (avr-libc register definitions) |
| Build target | `make analyze-misra` |
| Supporting files | [`test/misra.json`](test/misra.json) (addon config), [`test/misra_rules.txt`](test/misra_rules.txt) (rule-text paraphrases), [`test/misra_suppressions.txt`](test/misra_suppressions.txt) (deviation waivers) |

`make analyze-misra` runs the addon over every firmware translation unit — the
hardware-agnostic core plus each output-driver variant — and **gates** on any
finding not covered by a documented deviation below. It is part of the `analyze`
aggregate and therefore of `make test`.

To review the *full* inventory including the waived deviations (e.g. when
maintaining this document), run `make analyze-misra-report`.

### The PIC shell (XC8 build)

The PIC10F322 shell (`bypass_mcu_pic10f322.c`) is a separate toolchain track and
is analyzed by its own target, **`make pic-analyze-misra`** (with a companion
bug-finding pass, `make pic-analyze-cppcheck`). It is *not* part of `make test`
because the XC8 toolchain / DFP headers may be absent in CI; it skips cleanly
when they are.

| | |
|---|---|
| Analyzer | `cppcheck` 2.13.0, MISRA addon (`misra.py`) |
| Target model | `--platform=pic8-enhanced`, `--std=c11` |
| Compiler / headers | XC8 v3.10 + PIC10-12Fxxx DFP register definitions (`proc/pic10f322.h`, selected by `-D_10F322`) |
| Build target | `make pic-analyze-misra` |
| Supporting files | shared with the AVR run (`test/misra.json`, `test/misra_rules.txt`, `test/misra_suppressions.txt`) |

Two PIC-specific analysis notes:

- **SFR bitfield value-flow (`misra-config`).** cppcheck cannot fully
  value-flow-model the volatile SFR bitfield unions exposed by the Microchip
  headers (e.g. `PIR1bits.TMR2IF` read in the tick poll), so it emits a
  `misra-config` "unknown variable" diagnostic for them. This is a cppcheck
  modeling limitation on *adopted toolchain headers*, not a code defect, and is
  suppressed on the command line (`--suppress=misra-config`) — the analogue of
  how avr-libc is treated for the AVR run.
- **Pinned configuration.** The PIC run forces `-D_10F322 -DBYPASS_MCU_PIC10F322`
  and `-U__AVR__ -UBYPASS_MCU_AVR_CLASSIC` with `--max-configs=1` so only the PIC
  branch of `bypass_output_common.h` is active. cppcheck still records the
  *unselected* AVR pin map's macros in its cross-configuration directive list, so
  Rule 2.5 fires on `bypass_pins_avr_classic.h` even here — covered by the
  existing D-2 waiver (see below).

## Compliance boundary

The compliance boundary is **this project's own source** — the per-MCU shells
(`bypass_mcu_avr_classic.c`, `bypass_mcu_pic10f322.c`) and the `bypass_output_*`
driver/header set. The **avr-libc / avr-gcc** (AVR) and **XC8 / DFP** (PIC)
**system headers** are outside the boundary: they are adopted toolchain code, not
authored by this project, and are excluded from the analysis (by include-path
suppression in the Makefile). This is the standard treatment of library/toolchain
code under MISRA Directive 4.1's "adopted code" provisions.

## Deviations

All deviations fall into two classes. Each is waived per-file in the
suppressions list (not project-wide), so a new occurrence in a *new* file still
fails the gate and forces a conscious review.

### D-1 — Hardware register access

| | |
|---|---|
| **Rules** | 11.4 (pointer ↔ integer conversion, Advisory); 10.1 (inappropriate essential type, Required); 10.8 (composite-expression cast, Required) |
| **Files** | `bypass_mcu_avr_classic.c`, `bypass_output_cd4053_simple.c`, `bypass_output_cd4053_with_mute.c`, `bypass_output_tq2_l2_5v_relay.c`, `bypass_mcu_avr_xt.c` (avrxmega3 shell) |
| **Instances** | classic AVR: 11.4 ×28, 10.1 ×26, 10.8 ×6. ATtiny202 shell: 11.4 ×29, 10.8 ×4, 10.1 ×1 |

**Rationale.** Direct manipulation of AVR I/O registers is unavoidable in
bare-metal firmware, and avr-libc exposes every register through the `_SFR_*`
macros, which expand to a dereference of an integer address cast to a
`volatile`-qualified pointer. This makes three rules structurally unsatisfiable
for any register access:

- **Rule 11.4** fires on the integer-to-pointer conversion inside every register
  read or write, e.g.

  ```c
  ADCSRA = 0;                 // _SFR_IO8(0x06) -> *(volatile uint8_t *)(0x26)
  TCCR0A = (1 << WGM01);
  ```

- **Rule 10.1** fires on the bit-manipulation idioms used in register
  read-modify-write, e.g.

  ```c
  PORTB |=  (1 << LED_PIN);
  PORTB &= (uint8_t)~(1 << LED_PIN);
  ```

- **Rule 10.8** fires on the `(uint8_t)` casts of those composite bit
  expressions, which are themselves present *to keep the result in `uint8_t`*
  and silence `-Wconversion`.

The AVR8X (ATtiny202) headers model registers differently from classic AVR —
peripheral configurations are `enum` group-config constants (e.g.
`TCB_CLKSEL_CLKDIV1_gc`) and bit masks are plain-`int` macros (e.g.
`WDT_LOCK_bm`) — which would additionally trip **Rule 10.4** (mismatched
essential types) when those are combined with the `uint8_t` register fields. The
`bypass_mcu_avr_xt.c` shell **avoids** this by casting each register constant to
`uint8_t` at its use site (and its pin `static_assert`s cast `(unsigned)PINn_bp`,
mirroring the classic shell's `(unsigned)PBx`), so it deviates the **same three
rules** as the classic shell and introduces no new one.

There is no portable, register-correct way to express these operations without
the underlying integer-to-pointer conversion and bit arithmetic. The accesses
are confined to the pin-helper functions and `init()`; the debounce algorithm
itself contains no such code. These rules are widely deviated for this exact
reason in professional embedded MISRA projects.

**Scope control.** Waived per-file. A register access introduced in a new
translation unit will not be silently covered — it must be reviewed and the file
added here explicitly.

### D-2 — Cross-translation-unit shared macros

| | |
|---|---|
| **Rule** | 2.5 (unused macro definition, Advisory) |
| **Files** | `bypass_pins_avr_classic.h`, `bypass_pins_pic10f322.h`, `bypass_config.h` |
| **Instances** | AVR run: 16 (14 pin map + 2 `bypass_config.h`). PIC run: the PIC pin map plus the cross-config AVR pin map (see below). |

**Rationale.** Several macros are defined in shared headers that are included
by multiple translation units, but are only *used* by a subset of them. cppcheck
analyzes each TU independently and reports a macro as "unused" whenever the TU
includes its defining header but does not reference it. These are **not dead
code** — they are single-source definitions that avoid duplication and keep the
shared invariant in one place.

Two groups of macros fall under this deviation:

**`bypass_pins_avr_classic.h` — the per-MCU pin map**

```c
#define FOOTSW_PIN (0U)              // core only
#define LED_PIN    (1U)              // core + every driver
#define CD4053_PIN (2U)              // cd4053-simple driver only
#define RELAY_RESET_PIN (2U)         // relay driver only
#define RELAY_SET_PIN   (3U)         // relay driver only
#define CD4053_CTL1 (2U)             // mute driver only
#define CD4053_CTL2 (3U)             // mute driver only
#define BYPASS_OUTPUT_DDR_MASK (...) // every driver's hw_init_output_pins()
```

This header is the single source of truth for the classic-AVR pinout across all
three output variants. A given translation unit references only the pins it
needs — the **core** uses `FOOTSW_PIN`/`LED_PIN`; each **driver** uses its own
variant's control pins plus the shared output mask — so cppcheck, analyzing one
TU at a time, reports the rest as "unused". They are **not dead code**: every
macro is used by some build. Centralizing them keeps the classic-AVR pinout in
one place rather than duplicating it across the variant headers.

**`bypass_config.h` — threshold macros `PRESSED_THRESH` and `RELEASE_THRESH`**

```c
#define PRESSED_THRESH  (8U)
#define RELEASE_THRESH  (25U)
```

These are consumed by `bypass_pure.c` (debounce logic) and `bypass_mcu_avr_classic.c`
(lockout reload), but `bypass_config.h` is also included by the output-driver
TUs for their `static_assert` guards on the timing constants. Those TUs do not
use the threshold macros directly, so cppcheck reports them as unused when
analyzing a driver TU in isolation.

**`bypass_pins_pic10f322.h` — the PIC10F322 pin map**

The PIC pin map is the exact PIC analogue of the classic-AVR one, and Rule 2.5
fires on it in the PIC MISRA run (`make pic-analyze-misra`) for the same reason:
the PIC shell uses `FOOTSW_PIN`/`LED_PIN`, while each output variant references
only its own control pins, so the rest read as "unused" when one TU is analyzed
in isolation. Additionally, because `bypass_output_common.h` selects the pin map
with a `#if/#elif`, the *unselected* `bypass_pins_avr_classic.h` is still
recorded in cppcheck's cross-configuration directive list, so its macros are
reported "unused" in the PIC run too — already waived by the AVR pin map's
entry. None of these are dead code: every macro is used by some build of some
MCU.

## Maintenance

When changing the firmware:

1. Run `make analyze-misra`. If it fails, a finding is **not** covered by a
   deviation above.
2. Prefer to **fix** the finding (most essential-type and precedence issues are
   genuine and fixable — 12 such were fixed when this analysis was first
   established).
3. Only if the finding is genuinely unavoidable (e.g. a new register access in a
   new file under D-1), add a per-file entry to
   [`test/misra_suppressions.txt`](test/misra_suppressions.txt) **and** record it
   against the relevant deviation here. A suppression without a documented
   rationale is itself a compliance defect.
