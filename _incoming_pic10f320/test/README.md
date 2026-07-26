# Validation suite — PIC10F320 bypass firmware

This project is the single-file PIC10F320 sibling of
`mcu-bypass-firmware`; it reaches the same robustness level by a different
validation strategy (see the top-level `README.md`). The parent factors
its debounce logic into a *pure*, host- and formally-verified core
(`bypass_pure.c`); this firmware inlines that logic into `main()` to fit the
PIC10F320's 256-word flash, so there is no separable pure unit *inside the
firmware* to test directly. The firmware supports three output variants
(`cd4053-simple`, `cd4053-mute`, `tq2-relay`)
via one `OUTPUT_*` macro (the two `cd4053-*` images drive their analog-switch
control pins with a single unified polarity that is correct for both the CD4053
and the pin-compatible logic-level TMUX4053 board); pick the one under test with
`make PIC_VARIANT=...` (default `cd4053-simple`), or sweep all three with
`make test-variants`.

To get as close to the parent as possible anyway, validation here is built in
**two layers**:

1. **Reference model** (`model/`): a verbatim copy of the parent's verified pure
   core. We run the full host + formal suite against it.
2. **Equivalence**: we prove the *real firmware* behaves identically to that
   model, tick for tick, by running the actual compiled firmware logic on the
   host (`equiv/`) and in gpsim. So the model's host/formal guarantees transfer
   to the shipping code, and the firmware is never validated only "by assertion."
3. **Fault injection** (`fault/`): the model is hardware-free, so it has no
   notion of the firmware's *defensive* layer — the per-tick SEU/EMI sanity gate,
   the pull-up / output-pin checks, and `hw_force_wdt_reset()`. Valid stimulus
   never trips those, so the equivalence layer can't reach them. This layer runs
   the real firmware on the host and *injects* corrupted state to prove the fault
   path fires (and that valid states don't). It also backs the **firmware**
   coverage gate.

Everything runs from the top-level `Makefile`. Optional analyzer/simulator
targets may skip cleanly when their tools are absent, but build and coverage
gates fail on missing/malformed output. Mutation testing requires all mutants by
default; `MUTATION_ALLOW_SKIP=1` is an explicit report-only concession for a
tool-limited development host and is never used by CI or release validation.
The Makefile serializes complete invocations with a worktree-local `flock` and
disables internal parallel recipes because XC8 intermediates, host objects,
coverage data, and simulator logs are intentionally shared. Concurrent commands
wait rather than cross-linking variants or replacing an executing test binary.

## Validation layers and CI gates

| Layer | Target | What it proves | Tool |
| --- | --- | --- | --- |
| Build + flash budget | `all` | Compiles the selected variant for the PIC10F320 and fits in 256 words (219 / 240 / 243 for cd4053-simple / -mute / tq2-relay). | XC8 |
| Image generation | `test-pic-build` | Missing, partial, malformed, symlinked, over-budget, or interrupted XC8 output cannot be accepted; failed output files and symlinks are removed. | host fake-XC8 regression |
| Release reproduction | `test-release-images` | Committed, checksummed, and freshly built image sets must have exact filenames and byte-identical contents without reusing the committed directory as fresh evidence. | host filesystem regression |
| Build serialization | `test-build-serialization` | Independent Make processes sharing one worktree execute their build/test recipes one at a time. | `flock` + host shell regression |
| Bug-finding analysis | `analyze-cppcheck` | No cppcheck findings. | cppcheck (`pic8-enhanced`) |
| MISRA-C:2012 | `analyze-misra` | Zero MISRA deviations (`../MISRA_COMPLIANCE.md`). | cppcheck + MISRA addon |
| CONFIG word | `test-config` | The CONFIG word XC8 emitted matches design intent (`0x389E`). | host `gcc` |
| **Model: unit/property/fuzz** | `test-host` | The model satisfies the reliability properties over directed + fuzz + Monte-Carlo inputs. | host `gcc` |
| **Model: exhaustive state space** | `test-model-check` | All invariants hold over every reachable state (BFS) + the fault path. | host `gcc` |
| **Model: symbolic single-step** | `test-symbolic` | The per-step transition relation holds over the full input domain. | host `gcc` |
| **Model: bounded model checking** | `test-cbmc` | Same invariants via a SAT/SMT engine, plus freedom from UB (overflow/conversion/bounds). | cbmc |
| **Firmware ↔ model equivalence** | `test-equiv` | The *real firmware* reproduces the model's exact status-LED (RA0) trace **and** internal debounce state (`program_state`/`effect_state`/`debounce_counter`) tick-for-tick over 262k exhaustive + thousands of random stimuli, and the stimulus visits every reachable model state. | host `gcc` |
| **Firmware actuation sequence** | `test-actuation` | The *real firmware*'s full per-variant control-pin pattern (RA1/RA2) is correct at every *settled* tick; every distinct startup `LATA` transition is legal (analog-switch variants remain continuously in BYPASS, while relay emits exactly one RESET pulse); and the blocking mute/relay drivers assert the right pins + pulse width *during* each actuation. | host `gcc` |
| **Firmware fault injection** | `test-fault` | The *real firmware* starts from the PIC's `WPUA=0x0F` reset value but initializes and preserves the exact RA3-only `0x08` mask; its defensive layer detects missing or extra pull-up latches plus the other injected SFR/state corruptions and forces a watchdog reset (and valid states do not). | host `gcc` |
| **Firmware fault recovery on a simulated core** | `test-fault-gpsim` | The *real built HEX* initializes `WPUA` and `TRISA` to exact `0x08`, then recovers from corruption of required output directions, guarded SFRs, and `ctx_` SRAM via **exactly one** watchdog reset. RA2 is required for mute/relay and a write-back-verified no-reset control for simple. Register identity, SRAM layout, and fault injection are fail-closed. | libgpsim |
| **Firmware ↔ model lock-step on a simulated core** | `test-lockstep-gpsim` | The *real built HEX* reproduces the model's internal debounce state (`program_state`/`effect_state`/`debounce_counter`) at **every main-loop iteration** in gpsim — pinning the XC8 *codegen*, not just the firmware C that `test-equiv` runs on the host. Directed + random stimulus visits every reachable model state. The silicon-level companion to `test-equiv`. | libgpsim + model |
| Lock-step progress regression | `test-lockstep-progress` | Simulator stalls during settle, calibration, or completion abort immediately; the completion loop cannot spin forever on a frozen cycle counter. | host C++ + fake gpsim API |
| **Built-HEX GPIO transitions and timing** | `test-io-gpsim` | The XC8-built instruction stream keeps exact `TRISA=0x08`, drives physical `PORTA[2:0]` equal to `LATA[2:0]`, follows each complete legal startup/engage/bypass transition sequence, never energizes both relay coils, and holds mute/coil pulse states for the expected simulator-cycle duration. | libgpsim |
| **Firmware on a simulated core** | `test-gpsim` | The real built HEX behaves correctly on a simulated PIC10F320, including the variant's full BYPASS and ENGAGED control-pin pattern (two scenarios). | gpsim |
| gpsim wrapper fail-closed checks | `test-gpsim-wrappers` | Complete snapshots cannot hide a nonzero gpsim exit or timeout in either functional wrapper. | Bash + fake gpsim |
| Target-matrix fail-closed checks | `test-target-matrix` | Valid matrices run once per variant; empty, duplicate, and unsupported matrices fail before any target invocation. | Bash + fake recursive Make |
| Soak timing contract | `test-soak-timing` | Native soak timing macros reject non-integral, non-positive, and overflowing values; real release CLI durations cannot be shorter than 24 simulated hours. | host C/C++ compilers + Bash |
| Model coverage gate | `coverage-check` | Model line coverage ≥ 95% (host + formal combined; currently 100%). | gcov |
| Firmware coverage gate | `coverage-check-fw` | Every *firmware* line is covered on the host except the allow-listed watchdog-reset fault path. | gcov |

`make test` runs the non-libgpsim rows for the selected variant;
`make test-variants` repeats that suite for all three. Regular CI then runs
`make test-target-variants`, a fail-closed aggregate that requires
`FAULT-INJECT PASS`, `LOCK-STEP PASS`, and `TARGET-IO PASS` for every variant.
The three individual libgpsim targets remain skip-clean for ad-hoc development,
but the aggregate rejects a skip or incomplete run. It validates the complete
matrix before execution so empty, duplicate, or unsupported names cannot produce
an all-variants PASS or a misleading partial run. Standalone:
`make test-mutation`, `make test-soak` (the long-run libgpsim soak), and
`make test-symbolic-klee` (the symbolic step check under KLEE, if installed).

## The equivalence test (`equiv/`)

This is the centrepiece that ties the firmware to the verified model. A mock
`<xc.h>` (`equiv/xc.h`) replaces the device SFRs with host storage and turns
`CLRWDT()` into a per-tick hook, so the **actual** `bypass_mcu_pic10f320.c` runs
on the host one main-loop iteration per simulated tick. `fw_harness.c` captures,
per tick, both its status-LED bit (`LATA` RA0) — the one output that means the same
thing for every variant (high iff ENGAGED) — **and** the firmware's
live internal debounce state (`program_state`, `effect_state`, `debounce_counter`).
`test_equiv.c` compares **both** against the model for the same footswitch stimulus,
tick for tick — exhaustively for all length-18 patterns (both power-on states) and
over thousands of randomized longer sequences. (A capacity self-check fails loudly if
the harness's internal-state buffer is ever shorter than the longest stimulus, so no
tick silently falls back to LED-only.) It also **gates state coverage**: it BFS-enumerates the model's
reachable states and asserts the stimulus drove the model through every one (so
the random sampling leaves no reachable state unverified). The variant-specific
RA1/RA2 control pins are asserted separately on the simulated core by `test-gpsim`.

It also **auto-guards against threshold drift**: the firmware defines its
`PRESSED_THRESH`/`RELEASE_THRESH` inline and the model defines its own
(`model/bypass_config.h`); if they ever disagree, the traces diverge and this
test fails. (Verified with a deliberate-mismatch negative control.)

## The actuation-sequence test (`actuation/`)

The equivalence test compares RA0 (the status LED) and the firmware's internal
debounce state — but not the physical per-variant control pins (RA1/RA2), the
lines that actually switch the audio (the LED bit and the `ctx_` fields don't
capture them). This layer closes that on two fronts, both by reusing the
equivalence firmware harness.

**Settled control pins (every variant, every tick).** The harness's per-tick hook
samples `LATA` at the *end* of each main-loop iteration, after `hw_set_*_state()`
(and any blocking `__delay_ms` pulse) has fully completed — so that sample is
always the **settled** output. The test asserts the full per-variant pattern there,
not just RA0: `cd4053-simple` ENGAGED `0x3` / BYPASS `0x0`, `cd4053-mute` `0x7` /
`0x0`, `tq2-relay` `0x1` / `0x0`. This is the host-side analogue of the gpsim
full-`LATA` check, and it is the **only** host coverage of `cd4053-simple`'s CD4053
control pin (RA1): that variant has no blocking pulse, so the mid-pulse path below
never sees it, and before this check a mis-routed RA1 there survived the entire
host suite (caught only on the simulated core — confirmed by mutation).

**Mid-actuation transient (blocking variants only).** For `cd4053-mute` and
`tq2-relay`, each actuation asserts the mute / energises a relay coil, calls
`__delay_ms()`, then releases it — and the *transient* mid-pulse output is exactly
what the settled host sample and checkpoint-based `test-gpsim` cannot see. A
swapped relay set/reset coil (the
relay latches backwards, inverting the audio path relative to the LED) or a
defeated mute window settles to the **same** pin state, so it passes the settled
checks; only a snapshot *during* the pulse catches it. The mock `<xc.h>` routes
`__delay_ms()` through a hook so `fw_harness.c` snapshots `LATA` at the instant of
every actuation. Driving one full round trip (power-on bypass → engage → bypass),
the test asserts the exact mid-actuation pin pattern **and** the pulse width:

- **cd4053-mute**: engage muted-mid `LATA=0x5` (LED+CTL2 high, CTL1 held low),
  bypass muted-mid `0x4`, 5 ms mute window;
- **tq2-relay**: engage pulses the SET coil (`0x5` = LED+RA2), bypass pulses the
  RESET coil (`0x2` = RA1), 12 ms coil pulse (the power-on init bypass pulse is
  captured and asserted too);
- **cd4053-simple**: no blocking actuation, so *zero* mid-pulse snapshots (its
  control pin is covered by the settled check above).

**Complete startup transition trace.** The mock exposes `LATA` as an assignable
lvalue through an observation function, so the harness records every distinct
value produced by consecutive firmware writes, including transitions too short
for the delay and end-of-tick snapshots. The analog-switch hardware already
starts at the pulled-down `LATA=0x0` BYPASS state, so both analog variants must
remain continuously at `0x0` throughout initialization. The relay variant must
produce exactly `0x2 -> 0x0`: one RESET-coil pulse followed by both coils low.
This prevents the muted variant from traversing INVALID or ENGAGED routing before
its nominal startup mute snapshot.

The pin map and per-variant output stages are hand-written here (PIC-local, not
shared with the parent), so a transcription error in them is the same class of
inlining bug `test-equiv` catches for the debounce core — and between the two
layers above, every variant's control pins are now pinned on the host, settled and
(where they exist) mid-pulse. RA0 (the LED) and the internal debounce state remain
the equivalence test's job.

## The fault-injection test (`fault/`)

The equivalence test only ever presents *valid* footswitch stimulus, so the
firmware's defensive layer — the per-tick SEU/EMI sanity gate in `main()`, the
`hw_footswitch_pullup_intact()` / `hw_is_sanity_check_failed()` checks, and
`hw_force_wdt_reset()` — is never reached by it (a check that only fires on
*corrupted* state is invisible to valid stimulus). Mutation testing confirmed the
gap: that whole layer could be disabled and the rest of the suite stayed green.

`fault/fw_fault_harness.c` reuses the equivalence mock `<xc.h>` and `#include`s
the real firmware, so it can drive `main()` and corrupt the firmware's live state
between ticks. `test_fault.c` then asserts:

- **predicate probes** — the static sanity predicates return the right verdict
  for both good and SEU-corrupted SFRs (e.g. a `TRISA` bit flipped from output to
  input for RA0, RA1, or RA2, a cleared RA3 `WPUA` latch, any RA0–RA2 pull-up
  latch unexpectedly set, or `nWPUEN` set). The host SFR model starts at the
  PIC10F320's real `WPUA=0x0F` reset value and requires `init()` to replace it
  with the exact RA3-only mask `0x08`;
- **fault injection** — after one clean iteration, an out-of-range
  `program_state`/`effect_state` or a critical-SFR flip makes the next iteration
  force a watchdog reset, while valid states (including a valid ENGAGED state) do
  *not*.

The fault harness is run **once per output variant** (`test-fault-variants`)
because the pin map differs: RA1 is always load-bearing (LED/CD4053/RESET), and
RA2 is load-bearing only for `cd4053-mute`/`tq2-relay`.  On
`cd4053-simple` an SEU that flips RA2 back to input is
therefore a negative-control case (no reset), while on the mute/relay variants it
must force a reset. This also exercises the variant-specific sanity-check pin
masks end-to-end.

Observing the reset is the trick: `hw_force_wdt_reset()` clears `GIE` and spins
forever (on silicon the watchdog then resets the MCU). The harness arms a short
real-time timer; if the firmware enters that spin, a `SIGALRM` handler
`siglongjmp()`s back out — so "the run had to be timed out" *is* the
reset-fired signal (robust at any optimisation level, since the firmware's only
spin point is that function). This layer also drives the firmware's normal
toggle lines, so it backs the `coverage-check-fw` gate.

On the host, that reset is *inferred* from the spin (the mock has no real
watchdog). `make test-fault-gpsim` (`pic/test_fault_pic.cc`, part of regular CI
through `test-target-variants`) closes that gap on a simulated core: it first
requires the built HEX to initialize `WPUA` and `TRISA` to exact `0x08`, then
injects direction faults into required output pins and the same corruption into
the enumerated guarded SFRs (`OSCCON.IRCF`,
`WDTCON.WDTPS`, `PR2`, `T2CON`, `ANSELA`, missing/extra `WPUA` latches,
`OPTION_REG.nWPUEN`) and `ctx_` SRAM fields of
the **real built HEX** and asserts the firmware recovers via **exactly one**
watchdog reset — real reset-vectoring through `0x000`, with a no-injection
control asserting none. For the simple variant, RA2 direction corruption is a
write-back-verified negative control because only RA0/RA1 are load-bearing at
runtime; mute and relay must reset on RA2 corruption. "Exactly one" (not "≥ 1")
also catches a reset-*loop*.
It reuses the soak's non-halting notify-break-at-`0x000` machinery and inverts
the verdict (soak: a reset is a failure; here: exactly one reset is the pass). It
proves the reset *happens*, not its *timing* — WDT timing stays bench-only (see
*Known gaps*).

## Built-HEX target I/O (`pic/test_io_pic.cc`)

The host actuation test proves the source called the right output helpers and
requested the right delays. `make test-io-gpsim` independently checks what XC8
actually emitted. It advances the simulated core one instruction cycle at a time
through startup and a complete engage/re-arm/bypass round trip, recording every
distinct `LATA[2:0]` state and its cycle timestamp.

The check requires exact `TRISA=0x08`, digital output pins, and physical
`PORTA[2:0] == LATA[2:0]` throughout the traced runtime. Per variant it asserts:

- **cd4053-simple:** startup unchanged; engage `0x1 -> 0x3`; bypass `0x2 -> 0x0`.
- **cd4053-mute:** startup unchanged; engage `0x1 -> 0x5 -> 0x7`; bypass
  `0x6 -> 0x4 -> 0x0`, with each mute state held for 5 ms worth of instruction
  cycles.
- **tq2-relay:** startup RESET `0x2 -> 0x0`; engage SET
  `0x1 -> 0x5 -> 0x1`; bypass RESET `0x0 -> 0x2 -> 0x0`, with each coil pulse
  held near 12 ms and never both coils high.

This catches generated-code sequencing, glitch, and gross delay errors. It does
not measure physical oscillator tolerance or analog edge timing on a real board.

## gpsim functional scenarios

The closest thing to real silicon: the actual instruction stream, asserting
register state at settled checkpoints. Pins: RA3 = footswitch (1=released,
0=pressed), RA0 = LED, RA1/RA2 = the variant's control output(s). The ENGAGED
`LATA` pattern the wrapper checks is variant-specific — cd4053-simple `0x3`,
cd4053-mute `0x7`, tq2-relay `0x1` — passed as `PIC_ENGAGED_LATA`; the universal
RA0 (LED) checks hold for every variant. The settled BYPASS checkpoints assert
the **full** `LATA == 0x0` (all control pins low), the symmetric counterpart to
the ENGAGED full-`LATA` check.

- **`pic/footswitch_toggle.stc`**: power-on BYPASS → momentary press toggles +
  latches ENGAGED → second press toggles back. (toggle-on-press, latching, re-arm.)
  This scenario also carries the one **non-settled** checkpoint, `PRESS1_EARLY`
  (~3.5 ms into the first press): the LED must still be **off**, because the
  debounce demands `PRESSED_THRESH` *separated* 1 ms samples (~8 ms) before it may
  toggle. This **pins that the tick actually *gates* the loop** — the single firmware
  behaviour the host harnesses cannot observe, since they force `TMR2IF=1` so the tick
  poll never actually waits. A firmware whose tick stopped gating (free-running poll)
  crosses the threshold within microseconds of the press edge and lights the LED here;
  gpsim is its sole oracle (see the tick-gating mutant under *Mutation testing*). It is
  a one-sided *too-fast* guard: it does **not** fix the tick's absolute period (a
  slower-than-1 ms tick keeps the LED off here too), and it runs in gpsim's own timer,
  so the real 1 ms period stays a bench-only guarantee (see *Known gaps*).
- **`pic/power_on_pressed.stc`**: a switch held CLOSED at power-on must come up
  BYPASS and not engage until a genuine release + fresh press.

## Mutation testing (`make test-mutation`)

Confirms the suite has teeth: it injects deliberate faults into the firmware and
the model on a throwaway copy and checks each is detected. Firmware logic mutants
are killed by `test-equiv` / `test-gpsim`; firmware *defensive*-layer mutants by
host and built-HEX fault injection; control transition/pulse mutants by host
actuation and the target aggregate; and a removed main-loop WDT pet by a short
libgpsim soak. Model mutants are killed by `test-host` / `test-model-check`. Not
part of `make test` (it rebuilds per mutant). The full-tool gate requires all 42
mutants (36 firmware + 6 model) to run and be killed.

`make test-mutation` is fail-closed: the gpsim tick-gating, libgpsim target, and
short-soak WDT-liveness mutants must run, and any skipped mutant fails the target.
On a development host without the full XC8/gpsim/libgpsim stack,
`make test-mutation MUTATION_ALLOW_SKIP=1` runs the host-evaluable subset and
labels the result `PARTIAL`; CI, local-CI reproduction, and release validation
always leave the override at its strict default `0`.

Almost every original firmware mutant is killed by a **host** target (the
LED-invert and footswitch-polarity mutants diverge on RA0, so they target `test-equiv`,
which — unlike `test-gpsim` — is never skipped when gpsim is absent), with gpsim a
redundant second oracle. The simulated-core set now deliberately includes the
**tick-gating** mutant (the `TMR2IF` clear removed, so the 1 ms
poll never re-blocks and the loop free-runs): tick *gating* is unobservable on the
host by construction — the host harnesses force `TMR2IF=1` — so gpsim's mid-debounce
`PRESS1_EARLY` checkpoint is its **sole** killer. That is the correct division of
labour: whether the tick gates the loop is a simulated-core concern, and this is the
test that pins it. Seven built-image target mutants separately prove the physical
fault/transition/pulse oracles fail on their intended regressions, and a removed
main-loop `CLRWDT()` is killed only after the soak runs beyond one modeled WDT
period. (The tick's absolute *period* is a separate, bench-only matter —
gpsim's TMR2 prescaler model is not faithful across all settings; see *Known gaps*.)

## Why CONFIG-word verification matters

A wrong `#pragma config` bit is invisible to every other test and would only bite
on real silicon: WDTE=OFF defeats the fault-recovery watchdog; MCLRE=ON turns RA3
(the footswitch) into MCLR; BOREN=OFF removes brown-out protection.
`test-config` parses the exact CONFIG word out of the built HEX and asserts the
full design intent. The PIC10F320 and PIC10F322 CONFIG words are bit-for-bit
identical in layout, so this decoder is shared with the parent.

## Known gaps (hardware-bench only — shared with the parent's PIC build)

- **WDT-timing / brown-out behaviour** is not simulated here (gpsim's WDT
  calibration differs from silicon and it has no analog BOR model). The CONFIG
  check proves WDTE/BOREN are *enabled*; their real-time behaviour is a
  hardware-bench concern — and one the parent's PIC10F322 build shares, since it is
  validated in the same gpsim environment, so this is not a gap *relative to the
  parent*. The `make test-soak` long-run gpsim soak (ported from
  the parent's `test_soak_pic.cc`) exercises WDT *liveness* and periodic
  responsiveness at scale, but still asserts nothing about WDT *timing* (it uses
  the WDT only as a qualitative liveness signal — see the note in
  `pic/test_soak_pic.cc`). Note this is distinct from the **1 ms TMR2 tick
  cadence**: gpsim models the tick for the firmware's *current* prescale
  (`T2CKPS = 0b01` = 1:4 at 2 MHz), which the `PRESS1_EARLY` checkpoint exercises (see
  *gpsim functional scenarios*) — but gpsim's TMR2 prescaler model is **not**
  faithful across all settings (next bullet), so the *absolute* tick period on
  silicon is itself a bench-only guarantee.
- **Real-silicon pulse timing remains bench-only.** The target-I/O gate measures
  the XC8-generated busy-wait duration in gpsim instruction cycles and therefore
  verifies the programmed 5/12 ms delays at nominal configured FOSC. It cannot
  validate HFINTOSC tolerance, output rise/fall time, relay-coil current, or
  analog-switch mute settling on physical hardware.
- **TMR2 prescaler *select* is not faithfully modelled by gpsim.** gpsim clamps
  `T2CKPS = 0b11` to a 1:16 prescale instead of the datasheet's 1:64
  (`0b00`/`0b01`/`0b10` → `1:1`/`1:4`/`1:16` are modelled correctly; only the top
  code is wrong). The firmware uses `0b01` (1:4, at 2 MHz), which gpsim gets right, so
  the current build's 1 ms tick *is* faithfully simulated — but gpsim cannot
  independently catch a wrong prescale *select*, because a `0b11` (1:64 → 4 ms)
  config still reads as 1 ms in the sim. This is exactly what let an earlier
  `T2CON = 0x07` (`0b11`) slip through: the firmware intended 1:16 but selected
  1:64, and gpsim's clamp masked the resulting 4×-slow tick until it was caught by
  cross-checking the programmed register value against the datasheet (fixed in
  *firmware: correct TMR2 tick prescaler (T2CKPS 0b11 → 0b10)*). The host
  equivalence / lock-step layers are tick-*counted*, so they are period-agnostic
  by construction and cannot catch it either. As with WDT timing, the absolute
  tick period is a hardware-bench concern — shared with the parent's PIC build
  (same TMR2, same datasheet).
- **KLEE symbolic execution** is now wired as the optional, skip-clean
  `make test-symbolic-klee` target (`test_symbolic.c` supports `-DUSE_KLEE`); it
  is not part of `make test`, since the exhaustive host enumeration
  (`test-symbolic`) and CBMC already cover the same input domain.

## Toolchain

XC8 v3.10 + PIC10-12Fxxx DFP; cppcheck 2.13 + MISRA addon (`misra.py`) + python3;
gpsim 0.32.1 plus gpsim-dev/libglib2.0-dev (native `p10f320` support); cbmc; host
`gcc`/`g++` + `gcov`. Override
paths via the `Makefile` variables (`PIC_CC`, `PIC_DFP`, `CPPCHECK`, `GPSIM`,
`CBMC`, `HOST_CC`).
