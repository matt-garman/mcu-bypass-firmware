# Relay coil fault correction (correct-in-place model)

## Summary

At every serviced loop top, each relay-capable build commands both coils low
*before* its sanity gate. A one-shot writable coil-state upset already present
when that operation executes -- including the deterministic settled seams used
by the fault tests -- is cleared before the following gate, without changing the
logical effect state or requiring reset.

This is not an all-instruction-phase guarantee. An upset arising after the
re-assert but before the current gate may instead remain observable and be
escalated on PIC10F322, PIC12F675, AVR classic, and AVR-XT. PIC10F320 has no
general output-latch integrity check; its rule is correction-only for the relay
coil bits.

The correction guarantee also excludes the complete actuation sequence, from
the routine's pre-pulse clear through its post-pulse clear, especially the 12 ms
blocking delay. An upset there can shorten the intended pulse or energize the
inactive or both coils. The normal post-pulse clear commands both coil outputs
low if execution completes, but missed or spurious relay actuation, audio
disruption, and an external output path that does not accept that command remain
residual risks.

PIC10F320 gained its relay-only loop-top re-assert in `f78d168` and first shipped
it in v0.9.8. The four modular shells gained the shared-interface equivalent in
`93f637b`; that cross-shell change first ships in v0.9.10.

## Why correct-in-place, not de-energize-then-reset

- **It is a no-op on the nominal path.** Every actuation already ends in
  `set_relay_coils_low()`, and nothing drives a coil high between actuations, so
  the re-assert only does anything once an upset has set a coil bit. It is
  redundant in normal operation and load-bearing only under fault.
- **It corrects before escalation at the tested seam.** A fault already present
  when the loop-top operation runs is cleared before the following gate. A
  mismatch that remains observable reaches the architecture's existing sanity
  response. Only PIC12F675 compares physical GPIO against independent shadow
  intent; the other shells do not claim universal detection of an external
  stuck pin. PIC10F320 does not independently detect general stable-`LATA`
  mismatches at all.
- **It bounds the characterized settled-state pulses.** At the deterministic
  post-gate injection seams, the next re-assert is nominally ~1 ms away (1.024 ms
  on PIC12F675), below the relay's specified 4 ms minimum pulse for guaranteed
  actuation. That specification does not prove a shorter pulse is mechanically
  harmless, and the tests do not sweep every instruction phase. During the
  legitimate actuation sequence, loop-top correction is unavailable and
  unintended relay motion remains possible.
- **The coil is the only output that needs it.** The relay coil is the one
  output with a continuous-energization / spurious-actuation hazard. The LED and
  the CD4053 control lines have no such hazard, so correction is coil-only (with
  the PIC12F675 caveat below). On the modular shells their observable latch
  upsets retain the reset behavior; PIC10F320 retains its documented broader
  latch-integrity gap.

The trade-off accepted deliberately: a transient coil upset corrected by the
loop-top operation is **silent** (no reset, no count). That is the intended
minimum-disruption behaviour on parts with no telemetry.

## Mechanism

`bypass_hw_iface.h` declares one operation:

```c
void hw_outputs_reassert_safe(void);
```

Each output driver implements it:

| Driver | Body | Rationale |
| --- | --- | --- |
| `bypass_output_tq2_l2_5v_relay.c` | `set_relay_coils_low();` | drive both coils to their de-energized idle |
| `bypass_output_cd4053_simple.c` | *(no-op)* | control level tracks the effect state; no fixed safe idle to re-assert |
| `bypass_output_cd4053_with_mute.c` | *(no-op)* | same |

Each modular shell calls it at the top of every serviced iteration, immediately
before the sanity gate (`bypass_mcu_pic10f322.c`, `bypass_mcu_pic12f675.c` right
after `hw_wait_for_tick()`; `bypass_mcu_avr_classic.c`, `bypass_mcu_avr_xt.c` as
the first statement of the main loop). The call is unconditional — the linked
driver decides whether it does anything — so no shell carries a per-variant
`#if`. PIC10F320 retains its separate inline
`#if defined(OUTPUT_TQ2_RELAY)` implementation.

These loop-top calls are not serviced anywhere inside `hw_set_bypass_state()` or
`hw_set_engaged_state()`. The shared driver clears both coils, energizes one,
blocks for 12 ms, and only then clears both again.

## Per-architecture behaviour

The following scope describes what one loop-top re-assert writes; it applies when
the injected state reaches that operation before a sanity check. It does not
describe faults elsewhere in the actuation sequence. The correction is
**coil-only** on every part except PIC12F675, and the difference follows from
each part's output-write primitive:

| Part | Relay coil-clear operation | Correction scope |
| --- | --- | --- |
| PIC10F320 | two `LATA` single-pin clears | coil-only |
| PIC10F322 | one masked `LATA` read-modify-write | coil-only |
| AVR classic (ATtiny13a/45/85) | one masked `PORTB` read-modify-write | coil-only |
| AVR-XT (ATtiny202) | one mask write to `PORTA.OUTCLR` | coil-only |
| **PIC12F675** | **clear both shadow bits, then write the whole `GPIO` byte once** | **coil + whole-port refresh** |

### PIC12F675 whole-port refresh (inescapable, and safe)

The classic mid-range core has **no `LATx` register**. To avoid the classic
read-modify-write-on-pins defect, the shell keeps an SRAM `gpio_shadow_` and
writes `GPIO = gpio_shadow_` — the *entire* port byte — on every output change.
So re-asserting the coils necessarily **refreshes the whole physical port from
the shadow** each tick. Consequences on the relay variant:

The relay driver uses the masked-clear interface for every pre-pulse,
post-pulse, and settled-state clear. On PIC12F675 the implementation removes both
coil bits from `gpio_shadow_` before its single `GPIO = gpio_shadow_` assignment.
This ordering is load-bearing: two sequential single-pin clears could replay the
other coil's corrupt shadow bit onto the physical port before the second clear.

- A one-shot modeled **coil** upset in the shadow or GPIO readback is rewritten.
- A one-shot modeled GPIO upset on the LED or parked spare is also rewritten,
  because the whole-port write re-drives every output bit from the shadow.
- A non-coil **shadow** (intent) upset still resets — the shadow is authoritative
  and its corruption is a genuine fault.
- A settled-state physical-port mismatch that remains observable after refresh
  is caught deterministically by the shell's unique port-follows-shadow check →
  reset. A stuck-low coil during actuation can prevent motion and then match the
  expected settled-low state; it is not covered by that check.

This whole-port refresh is **not optional**: rewriting modeled GPIO state from
the authoritative shadow requires a whole-byte port write, and on this
architecture that write refreshes every output pin. A persistent external
mismatch is not "corrected" by the test; if it remains readable after refresh at
a settled check, PIC12F675's port-follows-shadow clause resets. Active-pulse
stuck-low behavior remains outside that check.

Fault posture at the reviewed pre-gate injection seam, PIC12F675 relay variant:

```
shadow.GP1 / shadow.GP2 (coil intent)      -> corrected, no reset
GPIO.GP1 / GPIO.GP2      (coil port)        -> corrected, no reset
GPIO.GP0 / GPIO.GP4      (LED / spare port) -> corrected, no reset  (whole-port refresh)
shadow.GP0 / shadow.GP4  (LED / spare intent) -> RESET
settled persistent observable mismatch      -> RESET (port-follows-shadow)
active-pulse coil stuck low                 -> may evade the settled check
SFRs / pull-up / context corruption         -> RESET
```

On PIC10F322, AVR classic and AVR-XT only writable coil state is re-driven. Other
observable output-latch mismatches retain their existing reset behavior; these
shells do not independently compare physical pins with intent. PIC10F320 is the
exception: it re-drives relay coil bits but does not detect general stable-`LATA`
mismatches, so non-coil output-latch upsets may persist until the next accepted
actuation.

## Test coverage

The correction cases below inject at reviewed, deterministic settled seams. The
PIC LATx cases directly delimit one completed iteration, while PIC12F675 derives
first-gate correction from its port-follows-shadow check. The AVR cases verify
final low state and no reset inside multi-tick observation windows; source
ordering locates the re-assert, but those harnesses do not timestamp the edge or
sweep injection phase.

| Substrate | Harness | Coil correction assertion |
| --- | --- | --- |
| PIC10F320 (host) | `test/pic10f320/fault/test_fault.c` | RESET, SET, and both latch bits are low after the next completed iteration; 41/41/59 exact checks |
| PIC10F320 (gpsim) | `test/pic10f320/gpsim/test_fault_pic.cc` | `inject_relay_correction_case` writes `LATA` and observes modeled `PORTA` follow it low within one iteration; 22/22/25 exact checks |
| PIC10F322 (gpsim) | `test/pic/test_fault_pic.cc` | `inject_relay_correction_case` — coil high then low within one iteration, `reset_delta == 0` |
| PIC12F675 (gpsim) | `test/pic/test_fault_pic12f675.cc` | coil + all-port cases as `inject_case(..., expected_resets=0)`; at the tested seam an uncleared mismatch would trip port-follows-shadow at the first gate |
| AVR classic (simavr) | `test/avr/test_sim.c` `inject_coil_correction` | inject coil latch high while asleep; assert latch re-driven low, no reset, LED still lit, still running |
| AVR-XT (yasimavr) | `test/avr/test_fault_attiny202.py` `CORRECT` mechanism | inject `PORTA.OUT` coil high; assert `OUTCLR` re-clears it with no force-reset |

Deleting the loop-top re-assert (or its coil clear) is killed behaviorally on
every substrate. PIC10F322, PIC12F675, AVR classic, and AVR-XT let the uncleared
state reach their existing sanity response, violating the no-reset result.
PIC10F320 has no general latch guard, so its explicit final-low correction
assertion fails without requiring a reset.

The PIC shipping-source host harness separately characterizes the excluded
active-pulse window in the shared production relay driver. For both SET and
RESET it injects active-coil-low and inactive-coil-high faults at 1, 6, and
11 ms into the 12 ms delay. They do not cover the instruction boundaries between
the pre-clear, coil assertion, delay, and post-clear. PIC10F322 observes its LATA
state; PIC12F675 observes independent SRAM-shadow intent and modeled
GPIO/readback. The harness records the actual injection offset and counts every
modeled post-injection millisecond, not merely the requested case. All 12 cases per device
show no correction during the remaining blocking interval and a final modeled
low state; the inactive-high cases make the post-pulse clear load-bearing on
PIC10F322. These are residual-risk characterizations, not evidence that an
external output accepts the write or that the relay cannot move.

Three additional PIC12F675 shipping-source cases start with RESET, SET, or both
coil shadow bits high while both modeled GPIO coil bits are low. Each requires
exactly one modeled whole-port write, no intermediate high GPIO write, final low
modeled coil state, and the expected all-port refresh. A mutation that restores
the former sequential whole-port writes is killed by this matrix.

## Test-harness note: faithful footswitch on the AVR classic (simavr)

The classic-AVR harness accounts for a **simavr fidelity gap**, not a firmware
behavior. The masked clear is a full-`PORTB` read-modify-write, so the relay shell
re-writes `PORTB` every tick. simavr, left alone, lets that write
(which re-asserts PB0's internal pull-up) override the externally driven
footswitch level, so presses
stopped registering. On real hardware this cannot happen — a footswitch closed to
ground overrides the weak internal pull-up, and re-writing an already-enabled
pull-up is a no-op.

The harness drives the footswitch as a **persistent external pull** via
simavr's `AVR_IOCTL_IOPORT_SET_EXTERNAL`, <!-- name-contract: exempt (AVR_IOCTL_IOPORT_SET_EXTERNAL is a simavr C macro, not a make variable) --> plus an immediate `avr_raise_irq` for
zero-latency edges (`footsw_set` in `test/avr/test_sim.c`). The external pull
survives PORT writes (the switch beats the pull-up, as on hardware); the raise
avoids the one-tick input latency the persistent-pull-alone path introduced. The
AVR-XT (yasimavr) already models this faithfully (`set_external_state`), and the
PIC gpsim/shadow harnesses were never affected.

## Related

- `CHANGELOG.md` and commits `f78d168`, `93f637b`, and `712589c` record the
  introduction and masked-clear refinement history.
- `docs/phase2_pic_shell.md` — the PIC Model-B polled-loop design the PIC shells
  share.
- `src/bypass_mcu_pic12f675.c` header comment — the GPIO-shadow rationale.
