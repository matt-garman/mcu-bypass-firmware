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

### The PIC shells (XC8 build)

Both PIC shells are a separate toolchain track from the AVR runs, each analyzed
by its own target: **`make pic-analyze-misra`** for the PIC10F322 and
**`make pic320-analyze-misra`** for the PIC10F320 (each with a companion
bug-finding pass, `make pic-analyze-cppcheck` / `make pic320-analyze-cppcheck`).
Neither is part of `make test`, because the XC8 toolchain / DFP headers may be
absent in CI; both skip cleanly when they are — which is exactly why the
zero-unwaived-findings claim below is only meaningful under `STRICT_TOOLS=1`,
where a skip becomes a hard failure. CI and the release script pass it.

| | PIC10F322 | PIC10F320 |
|---|---|---|
| Analyzer | `cppcheck` 2.13.0 + MISRA addon | same |
| Target model | `--platform=pic8-enhanced`, `--std=c11` | same |
| Compiler / headers | XC8 v3.10 + DFP (`proc/pic10f322.h`, `-D_10F322`) | XC8 v3.10 + DFP (`proc/pic10f320.h`, `-D_10F320`) |
| Build target | `make pic-analyze-misra` | `make pic320-analyze-misra` |
| Variants analyzed | one configuration | **all three output variants** — each compiles a different `#if defined(OUTPUT_*)` branch of the single inlined translation unit, so analyzing one would leave the other two unanalyzed |
| Supporting files | shared (`test/misra.json`, `test/misra_rules.txt`, `test/misra_suppressions.txt`) | same |

PIC-specific analysis notes:

- **SFR bitfield value-flow (`misra-config`).** cppcheck cannot fully
  value-flow-model the volatile SFR bitfield unions exposed by the Microchip
  headers (e.g. `PIR1bits.TMR2IF` read in the tick poll), so it emits a
  `misra-config` "unknown variable" diagnostic for them. This is a cppcheck
  modeling limitation on *adopted toolchain headers*, not a code defect. The
  PIC10F322 run suppresses it on the command line (`--suppress=misra-config`) —
  the analogue of how avr-libc is treated for the AVR run. The PIC10F320 run does
  **not**: it scopes the same waiver to one file through the suppressions list
  (D-4 below), which is the stricter treatment of the two.
- **Pinned configuration.** The PIC run forces `-D_10F322 -DBYPASS_MCU_PIC10F322`
  and `-U__AVR__ -UBYPASS_MCU_AVR_CLASSIC` with `--max-configs=1` so only the PIC
  branch of `bypass_output_common.h` is active. cppcheck still records the
  *unselected* AVR pin map's macros in its cross-configuration directive list, so
  Rule 2.5 fires on `bypass_pins_avr_classic.h` even here — covered by the
  existing D-2 waiver (see below).

## Compliance boundary

The compliance boundary is **this project's own source** — the per-MCU shells
(`bypass_mcu_avr_classic.c`, `bypass_mcu_avr_xt.c`, `bypass_mcu_pic10f322.c`,
`bypass_mcu_pic10f320.c`) and the `bypass_output_*` driver/header set. Note the
PIC10F320 shell is a *single self-contained translation unit* with the core and
the output stages hand-inlined (see `docs/pic10f320_special_case.md`), so for it
"the shell" and "the whole firmware" are the same file. The **avr-libc / avr-gcc** (AVR) and **XC8 / DFP** (PIC)
**system headers** are outside the boundary: they are adopted toolchain code, not
authored by this project, and are excluded from the analysis (by include-path
suppression in the Makefile). This is the standard treatment of library/toolchain
code under MISRA Directive 4.1's "adopted code" provisions.

## Deviations

Each is waived per-file in the suppressions list (not project-wide), so a new
occurrence in a *new* file still fails the gate and forces a conscious review.

**Per-target posture.** The AVR shells require D-1 (register access through
avr-libc's `_SFR_*` macros); the PIC shells do not, because XC8 exposes every
special function register through a volatile named-register and bitfield-union
model (`LATA |= …`, `PIR1bits.TMR2IF`) that does not trip those rules. The
PIC10F320 shell needs D-4, an analyzer limitation rather than a rule deviation.
D-2 and D-3 are cross-translation-unit artifacts and are target-independent.
This is a statement about each target's own source, not a ranking between
projects or parts.

### D-1 — Hardware register access

| | |
|---|---|
| **Rules** | 11.4 (pointer ↔ integer conversion, Advisory); 10.1 (inappropriate essential type, Required); 10.8 (composite-expression cast, Required) |
| **Files** | `bypass_mcu_avr_classic.c`, `bypass_output_cd4053_simple.c`, `bypass_output_cd4053_with_mute.c`, `bypass_output_tq2_l2_5v_relay.c`, `bypass_mcu_avr_xt.c` (avrxmega3 shell) |
| **Instances** | classic AVR: 11.4 ×28, 10.1 ×26, 10.8 ×6. ATtiny202 shell: 11.4 ×33, 10.8 ×4, 10.1 ×1 |

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
| **Files** | `bypass_pins_avr_classic.h`, `bypass_pins_pic10f322.h`, `bypass_pins_avr_xt.h`, `bypass_config.h` |
| **Instances** | AVR run: 16 (14 pin map + 2 `bypass_config.h`) plus the cross-config PIC and AVR-XT maps. PIC run: the PIC pin map plus the cross-config classic-AVR and AVR-XT maps (see below). |

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

**`bypass_pins_avr_xt.h` — the AVR-XT (ATtiny202) pin map**

The AVR-XT map is the third per-MCU pin map, and `bypass_output_common.h`
selects among the three with `#if/#elif`. Whichever build runs, the two
*unselected* maps are recorded in cppcheck's cross-configuration directive list
and their macros read "unused" — so the classic and PIC runs both flag Rule 2.5
on `bypass_pins_avr_xt.h`, exactly as they already do for each other's maps. Not
dead code: the AVR-XT map is the single source of truth for the ATtiny202 build.

### D-3 — Shared algorithm-type header

| | |
|---|---|
| **Rule** | 2.3 (unused type declaration, Advisory); 2.4 (unused tag declaration, Advisory) |
| **Files** | `bypass_types.h` |
| **Instances** | AVR run: 2.3 ×2, 2.4 ×2 (`pin_state_t`, `debounce_context_t`), reported once per output-driver TU. |

**Rationale.** `bypass_types.h` is the single source of truth for the
debounce/bypass algorithm's types: `program_state_t`, `effect_state_t`,
`pin_state_t`, and `debounce_context_t`. The hardware interface
(`bypass_hw_iface.h`) includes it because `hw_is_sanity_check_failed()` now takes
an `effect_state_t` argument (so the per-variant check can validate the settled
output latch against the current logical effect state). Every output-driver TU
therefore transitively sees the whole type set, but references only
`effect_state_t` — `pin_state_t` and `debounce_context_t` are used solely by the
core (`bypass_pure.c`) and the per-MCU shells. cppcheck analyzes each TU in
isolation and reports the unreferenced type (2.3) and its tag (2.4) as unused.

These are **not dead code** — each type is used by some translation unit. This is
the same single-source-of-truth situation as D-2 (shared header, per-TU subset),
applied to type/tag declarations rather than macros. Splitting the header so that
`effect_state_t` lives apart from `pin_state_t`/`debounce_context_t` would silence
the advisory but fragment the algorithm's cohesive type definitions across
several headers for no functional gain, so the shared header is kept and the
advisory is deviated.

**Scope control.** Waived per-file. A new unused type in another header still
fails the gate and must be reviewed.

### D-4 — PIC10F320 analyzer symbol resolution (`misra-config`, Rule 2.5)

**Rules:** `misra-config` (a cppcheck diagnostic, not a MISRA rule) and
**Rule 2.5** (a project shall not contain unused macro declarations).

**Scope:** `src/bypass_mcu_pic10f320.c` only — both entries are file-scoped.

**What happens.** The MISRA addon loses the device symbol table on this file
specifically. It therefore reports `misra-config` for `PIR1bits` / `TMR2IF` in
the 1 ms tick wait, and reports `TICK_PERIOD_MS` and `WDT_MIN_PERIOD_MS` as
unused macros.

**Why it is not a code defect.** The declarations are present and correct: the
*identical* statement against the *identical* DFP header analyses clean in
`src/bypass_mcu_pic10f322.c`. The cause was bisected to this file's heavy
in-function `static_assert` use — stripping those lines makes both diagnostics
vanish with every other flag unchanged. The two "unused" macros are consumed
**only inside `static_assert()` expressions**, which the addon cannot see here;
they are what enforce "1 ms tick + blocking actuation pulse < worst-case WDT
period" at compile time, so they are the opposite of dead.

**Why it is waived rather than fixed.** The alternative is removing the
compile-time assertions that make the timing contract checkable, which trades a
real guarantee for a clean analyzer run.

**Scope control, and why it is narrower than it looks.** The project this target
was merged from suppressed `misra-config` **globally**, via a cppcheck command
line flag. Adopting that would also blind the AVR shells and the PIC10F322 to
genuine unresolved-symbol problems. Both entries here are per-file instead, so
the merge *narrowed* the waiver rather than importing it — and real MISRA rule
findings in this file are still reported, verified by injecting a Rule 14.4
violation and confirming the lane fails.

**Note for anyone tightening this.** The PIC10F322 run still suppresses
`misra-config` globally on its command line (see "The PIC shells" above).
Bringing it to the PIC10F320's file-scoped treatment is a worthwhile follow-up;
it was left alone here because it is a change to a known-good, unrelated lane.

## Notes on specific constructs

Not deviations — intentional choices made *to stay* MISRA-clean. They are
recorded here because the source comments reference this document by name, and a
citation that leads nowhere is worse than no citation.

- **`DEBOUNCE_COUNTER_MAX` as `(255U)` rather than `<stdint.h>`'s `UINT8_MAX`**
  (`src/bypass_mcu_pic10f320.c:102-110`). By C integer-promotion rules a
  `uint8_t` promotes to signed `int`, so `UINT8_MAX` has type `int`; comparing it
  against the project's unsigned debounce thresholds would be an
  essential-type-category mix (Rule 10.4), and its expansion `0x7f*2+1` also
  trips Rule 12.1. A plain unsigned literal means the same value and avoids both.
- **Locals that "should" be `const` but are not.** Some locals initialised from a
  runtime call — the debounce counter, the program state — are deliberately not
  `const`-qualified: XC8 places `const`-qualified objects in program ROM and
  rejects a `const` local initialised from a non-compile-time constant. A
  required PIC/XC8 accommodation, not a MISRA deviation.

## Maintenance

When changing the firmware:

1. Run `make analyze-misra` for the AVR lanes, `make pic-analyze-misra` and
   `make pic320-analyze-misra` for the two PIC shells, and
   `make attiny202-analyze-misra` for the AVR-XT shell. If any fails, a finding
   is **not** covered by a deviation above. Pass `STRICT_TOOLS=1` when you need
   the result to *mean* something: without it, a missing cppcheck or absent XC8
   header makes the lane skip and exit 0.
2. Prefer to **fix** the finding (most essential-type and precedence issues are
   genuine and fixable — 12 such were fixed when this analysis was first
   established).
3. Only if the finding is genuinely unavoidable (e.g. a new register access in a
   new file under D-1), add a per-file entry to
   [`test/misra_suppressions.txt`](test/misra_suppressions.txt) **and** record it
   against the relevant deviation here. A suppression without a documented
   rationale is itself a compliance defect.
