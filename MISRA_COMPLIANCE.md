# MISRA-C:2012 Compliance Summary

This firmware is checked against the **MISRA-C:2012** guidelines for the C
language subset used in critical and embedded systems. This document records
the compliance boundary, analysis method, and every project finding suppression
with its classification and rationale.

The intended posture is *compliant with documented deviations and analyzer
accommodations*. D-1 contains the actual MISRA deviations required by authored
AVR hardware-access code. D-2 and D-3 suppress advisory findings that are false
at project scope but arise when cppcheck examines one translation unit or
preprocessor configuration at a time. D-4 contains PIC analyzer accommodations,
including a cppcheck diagnostic that is not a MISRA rule. The PIC10F322 and
PIC12F675 shells require no MISRA-rule deviation of their own, but their
`misra-config` accommodations are now file-scoped there — see "Suppression
review" below. Every file-based suppression is explicit in
[`test/misra_suppressions.txt`](test/misra_suppressions.txt) and mapped to one
of those records below.

> **Note on rule wording.** The official MISRA rule texts are copyrighted by the
> MISRA Consortium and are not reproduced here. The summaries below are our own
> paraphrases for orientation only; consult the published MISRA-C:2012 standard
> for the authoritative text, rationale, exceptions, and amplification.

## How it is checked

### Classic AVR and shared modular source

| | |
|---|---|
| Analyzer | `cppcheck` 2.13.0, MISRA addon (`misra.py`) |
| Target model | `--platform=avr8`, `--std=c11` |
| Compiler / headers | `avr-gcc` 7.3.0 (avr-libc register definitions) |
| Build target | `make analyze-misra` |
| Report target | `make analyze-misra-report` |
| Direct source inputs | Classic AVR shell, `bypass_pure.c`, and the three `bypass_output_*.c` drivers |
| Supporting files | [`test/misra.json`](test/misra.json) (addon config), [`test/misra_rules.txt`](test/misra_rules.txt) (rule-text paraphrases), [`test/misra_suppressions.txt`](test/misra_suppressions.txt) (project finding suppressions) |

With the canonical default variant set, `make analyze-misra` invokes cppcheck
separately on five translation units: `bypass_mcu_avr_classic.c`,
`bypass_pure.c`, and all three output drivers. The mute and relay drivers each
receive their own selector; the simple driver, shell, and core receive the
caller-selected `VARIANT` selector (`CD4053_SIMPLE` by default). The target
gates on findings not covered by the documented suppression records below. It
does not trust cppcheck's process status alone: captured diagnostics are forced
through a machine-readable template and `test/misra_output_gate.py` independently
fails every record attributed to an authored C file or header. It is part of the
`analyze` aggregate and therefore of `make test`. A caller can narrow `VARIANTS`,
so full driver coverage requires
an invocation whose `VARIANTS` contains all three supported variants.

`make analyze-misra-report` runs the same Classic/shared source list without the
project suppression file, exposing that lane's waived findings. It retains the
command-line exclusions for adopted toolchain headers and is **not** a
project-wide report: it does not run the AVR-XT, PIC10F322, PIC10F320, or
PIC12F675 implementation files. Those lanes currently have no report-only
companions.

### Additional MCU implementation files

| | AVR-XT (ATtiny202) | PIC10F322 | PIC10F320 | PIC12F675 |
|---|---|---|---|---|
| Direct source input | `bypass_mcu_avr_xt.c` only | `bypass_mcu_pic10f322.c` only | `bypass_mcu_pic10f320.c` only | `bypass_mcu_pic12f675.c` only |
| Target model | `--platform=avr8`, `--std=c11` | `--platform=pic8-enhanced`, `--std=c11` | same | `--platform=pic8`, `--std=c11` |
| Adopted headers | avr-libc + ATtiny DFP | XC8 v3.10 + `proc/pic10f322.h` | XC8 v3.10 + `proc/pic10f320.h` | XC8 v3.10 + `proc/pic12f675.h` |
| Direct MISRA target | `make attiny202-analyze-misra` | `make pic10f322-analyze-misra` | `make pic10f320-analyze-misra` | `make pic12f675-analyze-misra` |
| Direct target coverage | AVR-XT shell | PIC10F322 shell | one selected `PIC10F320_VARIANT` branch | PIC12F675 shell |
| Canonical coverage | one shell configuration | one shell configuration | `make pic10f320-test STRICT_TOOLS=1` sweeps all three output branches | one shell configuration |
| Project suppressions consumed | three (D-1) | one (D-4) | two (D-4) | one (D-4) |

These targets do not re-run `bypass_pure.c` or the modular output-driver
translation units under each MCU target model; those shared C files are direct
inputs only to the Classic/shared lane above. PIC10F320 is self-contained, so
sweeping its three preprocessor branches covers its entire authored firmware
translation unit. The optional-tool lanes can skip when tools or device headers
are absent; CI and release qualification use `STRICT_TOOLS=1` so those skips fail.

PIC-specific analysis notes:

- **SFR bitfield value-flow (`misra-config`).** cppcheck cannot fully
  value-flow-model the volatile SFR bitfield unions exposed by the Microchip
  headers (e.g. `PIR1bits.TMR2IF` read in the tick poll), so it emits a
  `misra-config` "unknown variable" diagnostic at the authored read site. This
  is a cppcheck modeling limitation in its treatment of adopted toolchain
  declarations, not a code defect. Each affected PIC lane scopes that diagnostic
  to its one shell through the suppression list (D-4 below); a `misra-config`
  record in any other authored source or header fails.
- **Pinned configuration.** PIC10F322 and PIC12F675 force their device and shell
  selectors and undefine the AVR selectors with `--max-configs=1`, so only the
  intended PIC branch of `bypass_output_common.h` is active. PIC10F320 similarly
  forces its device and one selected `OUTPUT_*` branch, swept by its canonical
  aggregate. cppcheck still records
  *unselected* pin-map directives, so Rule 2.5 can fire on those inactive maps —
  covered as D-2 analyzer artifacts below. There are now four such maps; the
  PIC12F675's joined them when that shell landed.

## Compliance boundary

The compliance boundary is **this project's authored firmware source**:

- Nine C files: the five MCU implementation files
  (`bypass_mcu_avr_classic.c`, `bypass_mcu_avr_xt.c`,
  `bypass_mcu_pic10f322.c`, `bypass_mcu_pic10f320.c`,
  `bypass_mcu_pic12f675.c`), the shared `bypass_pure.c` core, and the three
  `bypass_output_*.c` drivers.
- Fifteen headers: `bypass_config.h`, `bypass_types.h`, `bypass_pure.h`,
  `bypass_hw_iface.h`, `bypass_output_common.h`, `bypass_blocking_delay.h`,
  `bypass_static_assert.h`, `bypass_compile_checks.h`, the four
  `bypass_pins_*.h` maps, and the three `bypass_output_*.h` headers.

Cppcheck receives C files as its direct inputs; authored headers are analyzed
only when parsed through an include path from those inputs. The Makefile's
`FW_HEADERS`, `XT_HEADERS`, `PIC10F322_HEADERS`, and `PIC12F675_HEADERS` are
rebuild dependency lists, not additional analyzer source arguments. In
particular,
`bypass_output_cd4053_simple.h` is in the authored boundary but is not currently
included by an analyzed C file, and the modular driver files are not re-analyzed
under the AVR-XT or PIC target models. Those are explicit coverage limits, not
claims that the files are outside the boundary.

The PIC10F320 implementation is one self-contained C file: its debounce
algorithm is written directly in `main()` and its output variants are
source-local functions selected by preprocessor branches (see
`docs/pic10f320_special_case.md`). It includes no project-authored header.

The **avr-libc / avr-gcc**, **ATtiny DFP**, **XC8 / PIC DFP**, and C-library
headers are adopted toolchain code outside the compliance boundary. Cppcheck
parses those headers as needed to analyze project code, but Makefile path
suppressions exclude findings located in the adopted headers from the compliance
result. This is the standard treatment of library/toolchain code under MISRA
Directive 4.1's adopted-code provisions.

## Suppression records

The suppression file uses `rule-or-diagnostic:file` granularity, not a
project-wide wildcard. A matching finding in a new source file or header
therefore fails the gate. Cppcheck 2.13.0 does not enforce that policy for
included headers through `--error-exitcode`, so every gating recipe captures a
fixed `MCU_BYPASS_CPPCHECK|...` record and passes it to
`test/misra_output_gate.py`. The parser lexically normalizes relative and
absolute paths against the repository root and treats exactly `src/**/*.c` and
`src/**/*.h` as authored firmware; adopted headers, `third_party/`, and test code
remain outside that boundary. Malformed captured output and nonzero analyzer
status fail closed rather than becoming an empty diagnostic set.

The other side of file granularity remains important: another finding with the
same ID in an already-listed file is also suppressed, so maintenance must review
the unsuppressed Classic/shared report rather than treating a green gate as a
complete inventory diff. The other MCU lanes always apply the suppression file
and have no report targets; reviewing their suppressed findings requires a
direct reproduction of the expanded cppcheck command. Use `make -n` to obtain it
from the target recipe, then remove `--suppressions-list=...`.

**Per-target posture.** D-1 is the actual deviation family and applies to AVR
hardware-facing code that uses avr-libc register definitions. PIC register
access does not produce that finding family. D-2 and D-3 record cppcheck
artifacts for declarations that are used elsewhere in the project; they are not
source-level noncompliance. D-4 records PIC analyzer accommodations, not actual
MISRA deviations.

### Suppression review

Reviewed 2026-08-10, when the PIC12F675 shell joined the boundary, and hardened
2026-08-11. The review method was to re-run each lane against a *modified*
suppression file and record what changed, rather than to read the list and
assume.

**Two shells need no MISRA-rule deviation.** `make pic10f322-analyze-misra` and
`make pic12f675-analyze-misra` each consume only one file-scoped `misra-config`
analyzer accommodation. The reason is structural and worth stating: the PIC
shells write SFRs as plain identifiers (`GPIO = gpio_shadow_;`), where avr-libc's
`_SFR_*` macros expand an integer address to a volatile pointer — which is what
produces the whole D-1 family. A PIC shell cannot inherit that deviation, so the
PIC12F675 arrived adding no MISRA-rule suppression.

The measured per-lane dependence is in the table above. Dropping the three
`bypass_mcu_avr_xt.c` entries fails the AVR-XT lane; dropping the two
`bypass_mcu_pic10f320.c` entries fails the PIC10F320 lane; dropping the nine
Classic/driver `.c` entries fails the Classic lane with 30 findings.

**The measured header-gating defect is now closed.** With cppcheck 2.13.0,
`--error-exitcode` is set only by findings located in the file passed on the
command line. Findings located in an included **header** are printed but do not
fail the lane. Measured both ways: dropping `misra-c2012-2.3:src/bypass_types.h`
or `misra-c2012-2.5:src/bypass_pins_avr_xt.h` leaves `make analyze-misra` green,
while dropping `misra-c2012-11.4:src/bypass_mcu_avr_classic.c` fails it. So every
D-2 and D-3 entry formerly suppressed *output*, not a process failure.

All five recipes now force structured output through the repository parser
independently of cppcheck's status. `make test-misra-output-contract` emits a
zero-exit synthetic Rule 14.4 finding at `src/bypass_hw_iface.h` through every
recipe and requires all five to fail; an exact
`misra-c2012-14.4:src/bypass_hw_iface.h` fixture restores success, while the same
rule scoped to another header does not. Direct parser probes cover authored C,
relative and absolute header paths, adopted/system/test paths, malformed records,
unattributed pseudo-paths, and nonzero tool status. It pins exactly three
file-scoped `misra-config` accommodations and proves the ID remains failing in an
authored header. The regression also removes one parser call from a scratch
Makefile and requires the five-rule census to detect the severed gate.

### D-1 — Hardware register access

| | |
|---|---|
| **Rules** | 11.4 (pointer ↔ integer conversion, Advisory); 10.1 (inappropriate essential type, Required); 10.8 (composite-expression cast, Required) |
| **Suppression scope** | Rules 11.4/10.1: Classic shell, three modular drivers, and AVR-XT shell. Rule 10.8: Classic and AVR-XT shells. The exact `rule:file` entries in `test/misra_suppressions.txt` are authoritative. |
| **Current inventory** | Run `make analyze-misra-report` for findings emitted by the Classic/shared lane; counts are not frozen here because source edits move them. The AVR-XT lane has no report-only companion. |

**Rationale.** Direct manipulation of AVR I/O registers is unavoidable in
bare-metal firmware, and avr-libc exposes every register through the `_SFR_*`
macros, which expand to a dereference of an integer address cast to a
`volatile`-qualified pointer. The observed hardware-access and bit-manipulation
idioms produce three finding families:

- **Rule 11.4** fires on integer-to-pointer conversions expanded by avr-libc
  register macros, e.g.

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
the underlying integer-to-pointer conversion and bit arithmetic. Register
accesses occur throughout the hardware-facing shell paths, including
initialization, pin helpers, timer/watchdog handling, and runtime sanity checks;
the pure debounce core contains none. These rules are widely deviated for this
reason in professional embedded MISRA projects.

**Scope control.** Waived per-file. A register access introduced in a new
translation unit will not be silently covered — it must be reviewed and the file
added explicitly. Another finding with an already-suppressed rule ID in an
already-listed file is covered by the same entry and must be noticed through
unsuppressed-report review.

### D-2 — Analyzer artifact: shared macros

| | |
|---|---|
| **Rule** | 2.5 (unused macro definition, Advisory) |
| **Suppression scope** | `bypass_pins_avr_classic.h`, `bypass_pins_pic10f322.h`, `bypass_pins_avr_xt.h`, `bypass_pins_pic12f675.h`, `bypass_config.h` |
| **Classification** | Per-translation-unit / cross-configuration analyzer artifact, not a project-level unused-macro deviation |

**Rationale.** Each pin-map header is the single source of truth for one MCU.
The modular shells consume the active map, including variant control macros in
compile-time pin assertions. Individual output-driver translation units use only
their variant-specific subset, so cppcheck can report declarations consumed by
another translation unit as unused. It can also retain directives from the three
inactive pin-map branches selected through `bypass_output_common.h`, producing
findings against maps that are not active in the current target configuration.

`bypass_config.h` has the same split. The shared core and four modular shells
consume the debounce thresholds; the mute and relay drivers consume
`RELEASE_THRESH` in timing assertions but not `PRESSED_THRESH`. A driver-only
analysis can therefore report the latter as unused even though other project
translation units consume it.

These declarations are used across the complete build matrix and are not dead
code. Centralizing them prevents target pinouts and timing thresholds from
diverging between source files. The header-scoped Rule 2.5 suppressions do,
however, cover any Rule 2.5 finding attributed to those headers, so changes to
them require unsuppressed report review.

### D-3 — Analyzer artifact: shared algorithm types

| | |
|---|---|
| **Rule** | 2.3 (unused type declaration, Advisory); 2.4 (unused tag declaration, Advisory) |
| **Suppression scope** | `bypass_types.h` |
| **Classification** | Per-translation-unit analyzer artifact, not project-level unused declarations |

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

These are **not dead code**: each type is used by the core or an MCU shell, so
Rules 2.3/2.4 are satisfied at project scope. Splitting the header so that
`effect_state_t` lives apart from `pin_state_t`/`debounce_context_t` would silence
the TU-local findings but fragment the cohesive algorithm types for no functional
gain. A finding in another header still fails; another 2.3/2.4 finding attributed
to `bypass_types.h` is covered and must be caught by report review.

### D-4 — PIC analyzer accommodations (`misra-config`, Rule 2.5)

**Finding IDs:** `misra-config` (a cppcheck diagnostic, not a MISRA rule) and
**Rule 2.5** (unused macro definition, Advisory).

**Suppression scope:** `misra-config` is file-scoped separately to
`src/bypass_mcu_pic10f322.c`, `src/bypass_mcu_pic10f320.c`, and
`src/bypass_mcu_pic12f675.c`. Rule 2.5 is scoped only to
`src/bypass_mcu_pic10f320.c`. Each entry covers every finding with that ID
attributed to its named file.

**What happens.** The MISRA addon cannot resolve volatile SFR bitfields at the
PIC10F322 and PIC12F675 tick-poll read sites. On PIC10F320 it loses the device
symbol table more broadly: it reports `misra-config` for `PIR1bits` / `TMR2IF`
in the 1 ms tick wait, and reports `TICK_PERIOD_MS` and `WDT_MIN_PERIOD_MS` as
unused macros.

**Why it is not a code defect.** The declarations are present and correct: the
PIC SFR declarations are supplied by the selected DFP and compile under XC8. The
additional PIC10F320 loss was bisected to that file's heavy in-function
`static_assert` use — stripping those lines makes both diagnostics vanish with
every other flag unchanged. The two "unused" macros are consumed
**only inside `static_assert()` expressions**, which the addon cannot see here;
they are what enforce "1 ms tick + blocking actuation pulse < worst-case WDT
period" at compile time, so they are the opposite of dead.

**Why it is waived rather than fixed.** The SFRs are valid adopted-header
declarations and compile with the target compiler; changing clear device-register
accesses to satisfy an addon's incomplete symbol model would not improve the
firmware. For PIC10F320's Rule 2.5 records, the alternative is removing the
compile-time assertions that make the timing contract checkable, which trades a
real guarantee for a clean analyzer run.

**Scope control.** The former PIC10F322 and PIC12F675 invocation-wide
`--suppress=misra-config` flags are gone. A diagnostic with that ID is waived
only when cppcheck attributes it to one of the three explicitly named PIC shell
files; the output gate fails the same diagnostic in another authored source or
header. All other MISRA rule IDs remain visible. The Rule 2.5 entry necessarily
also covers a future genuine Rule 2.5 finding in the PIC10F320 file, so changes
to its macro set require an unsuppressed inventory review.

## Notes on specific constructs

Not deviations — intentional choices made *to stay* MISRA-clean. They are
recorded here because the source comments reference this document by name, and a
citation that leads nowhere is worse than no citation.

- **`DEBOUNCE_COUNTER_MAX` as `(255U)` rather than `<stdint.h>`'s `UINT8_MAX`**
  in `src/bypass_mcu_pic10f320.c`. By C integer-promotion rules a
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

1. Run all current direct C-input lanes, keeping the Classic driver matrix and
   PIC10F320 branch sweep explicit:

   ```sh
   make analyze-misra VARIANTS="cd4053_simple cd4053_with_mute tq2_l2_5v_relay" STRICT_TOOLS=1
   make attiny202-analyze-misra STRICT_TOOLS=1
   make pic10f322-analyze-misra STRICT_TOOLS=1
   for v in cd4053_simple cd4053_with_mute tq2_l2_5v_relay; do
       make pic10f320-analyze-misra PIC10F320_VARIANT="$v" STRICT_TOOLS=1 || exit 1
   done
   make pic12f675-analyze-misra STRICT_TOOLS=1
   ```

   Confirm the Classic and AVR-XT runs resolved their intended avr-gcc/avr-libc
   include paths; those path discoveries are not completeness gates. The PIC
   lanes explicitly guard their XC8/DFP headers.
2. Run
   `make analyze-misra-report VARIANTS="cd4053_simple cd4053_with_mute tq2_l2_5v_relay" STRICT_TOOLS=1`
   to inspect the unsuppressed Classic/shared inventory. It does not report the
   other four MCU implementation files. When their suppression scope changes,
   use `make -n` to obtain the target's expanded cppcheck command and re-run it
   without `--suppressions-list=...`. An ordinary successful target discards
   suppressed findings and cannot serve as that review.
3. Prefer to **fix** the finding (most essential-type and precedence issues are
   genuine and fixable — 12 such were fixed when this analysis was first
   established).
4. Only if the finding is genuinely unavoidable (e.g. a new register access in a
   new file under D-1), add a per-file entry to
   [`test/misra_suppressions.txt`](test/misra_suppressions.txt) **and** record it
   in the relevant classified record here. A suppression without a documented
   rationale is itself a compliance defect; a suppression in an already-listed
   file still requires review because `rule:file` is broader than one instance.
