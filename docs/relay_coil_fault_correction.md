# Relay coil fault policy (fail-safe resynchronization)

## Policy

**An unexpectedly energized relay coil is a fault. The firmware de-energizes
both coils immediately, then forces watchdog recovery, so that logical state,
LED state and physical relay position are driven back into agreement.**

This replaces the correct-in-place model that shipped on PIC10F320 in v0.9.8 and
on the four modular shells in `93f637b`. Nothing is re-driven ahead of a sanity
gate any more, and the loop-top re-assert is gone. Each forced-reset path now
clears the relay driver's latch intent before the watchdog spin; AVR-XT and
PIC12F675 first neutralize MCU-specific pin-control hazards that can prevent a
low latch from reaching the package pin.

Selected and recorded by the repository owner before v0.9.10.

### Why

The old model cleared an energized coil silently and let the loop continue. The
intended pulse was bounded to roughly one tick at the tested settled seams,
which is below the Panasonic TQ2-L2-5V **4 ms minimum pulse for guaranteed
actuation** — but "below the guaranteed-actuation minimum" is not "proven
mechanically harmless". No datasheet parameter, and no simulation, says what a
1 ms pulse does to a particular relay at a particular voltage, temperature and
armature position.

So the firmware cannot know whether the latching relay moved. If it did, silent
clearing leaves the physical audio route disagreeing with the effect state and
the LED, permanently, with nothing in the system able to notice or repair it.
That is the single failure this policy exists to remove:

| | correct in place (old) | fail-safe resynchronization (now) |
| --- | --- | --- |
| coil de-energized | yes, ≤ 1 tick | yes, ≤ 1 tick |
| logical/physical convergence if the pulse DID actuate | never | guaranteed by the recovery |
| disruption when it did NOT actuate | none | ~0.26 s dropout, returns to BYPASS |
| firmware has to know whether the relay moved | yes (it cannot) | no |

The old model minimized disruption on the assumption the pulse was harmless.
The new model gives that up — a cosmic-ray-class coil upset now costs an audible
interruption and a return to BYPASS — in exchange for never depending on an
assumption the project cannot substantiate. For a bypass switch whose entire
purpose is that the audio path matches what the player sees, that is the
conservative trade.

The alternative disposition — retaining silent correction — would have required
the release to accept possible permanent logical/physical desynchronization and
to add hardware characterization across representative relays, supply voltage,
temperature and pulse phase. Testing samples cannot turn a below-minimum pulse
into a datasheet guarantee, so that path was not taken.

### Cost

The F1 baseline measured all variants before and after the original latch-level
resynchronization change:

| Part | Relay variant | Other variants |
| --- | --- | --- |
| PIC10F322 | 493 → 493 words of 512 | unchanged (476, 502) |
| PIC10F320 | 245 → 248 words of 256 | unchanged (220, 241) |
| PIC12F675 | 563 → 563 words of 1024 | unchanged (546, 572) |
| ATtiny13A | 864 → 868 B of 1024 | +4 B each |
| ATtiny202 | 994 → 998 B of 2048 | +4 B each |

Those are historical F1 deltas, not current occupancy. The AVR-XT and PIC12F675
relay images were remeasured after the emergency physical-pin path landed, and
both grew again; the current figure for every image is in
`DESIGN_DOCUMENTATION.adoc`'s Resource Utilization tables, which are measured
from the final `v0.9.10` candidate build and checked against it by
`make test-resource-tables` rather than projected from the deltas here.

It is nearly free because the escalation **reuses the sanity gate that already
compares the complete output latch**. Only PIC10F320, which cannot afford that
general comparison, pays anything: three words for a coil-only `LATA` term.

The 320 then gave those back and more. Making its coil clear one masked write
(below) removed two per-bit helpers that had no other caller, so the shipping
relay image is **242** words of 256 -- three fewer than before this policy was
adopted at all -- and its worst-case return-stack depth dropped from 4 to 3 of 8.

## Mechanism

### The two halves

The contract has two halves, and the tests assert them separately because
final-low coils are *not* recovery:

1. **De-energization.** `hw_force_wdt_reset()` runs its emergency output path
   *before* it disables interrupts and spins, so a fault cannot hold a coil
   energized for the watchdog period. The implementation clears both coils in
   one masked output write on **every** shell: the four modular ones reach it
   through the relay driver's
   `hw_pin_mask_set_low()`, and PIC10F320, which links no driver, writes the same
   constant mask itself. A per-bit clear of RESET and then SET would settle
   identically and differ in the transient: with both coil bits high, the second
   coil stays driven for the whole of the first write, on the one path whose
   purpose is to stop driving them. That is asserted rather than assumed - see
   *The PIC10F320 exception* below. On AVR-XT and PIC12F675 the masked clear is
   deliberately sequenced between shell-specific pin teardown and safe
   output-direction restoration.
2. **Resynchronization.** The watchdog reset re-runs `init()`, whose
   `hw_set_bypass_state()` drives a complete 12 ms RESET-coil actuation
   (`TQ2_L2_5V_PULSE_MS`, 3× the datasheet minimum). *That* is what puts the
   physical relay back in agreement with the logical state and the LED. The
   device comes up in BYPASS with the LED dark.

### Physical-pin emergency paths

The ordinary relay driver can clear output intent, but it cannot know whether an
MCU peripheral has taken ownership of the pad or whether an output-polarity bit
has inverted the meaning of that intent. The two affected shells therefore wrap
the shared clear:

- **AVR-XT:** clear each coil pin's pull-up and input-sense fields while
  preserving its current inversion, disconnect both output drivers, clear the
  remaining `PINnCTRL` inversion, clear both `PORTA.OUT` latch bits, then restore
  output direction. This prevents a pull-up from becoming active during the
  high-impedance interval and prevents a stale latch from being exposed while
  polarity is restored.
- **PIC12F675:** clear the coil weak-pull-up latches, make both coil pins inputs,
  disable the ADC/analog selections/comparator, clear the SRAM shadow and write
  GPIO once, then restore output direction. In particular, comparator modes 011
  and 101 route `COUT` onto GP2; GPIO writes cannot force that pad low until
  `CMCON` returns ownership to GPIO.

The PIC12F675 comparator scope is the complete single-bit neighborhood of the
required off mode. DS41190G Figure 6-2 names three of the eight modes "with
Output", and Section 6.4 confirms `COUT` reaches the GP2 pad in exactly those
three -- `001`, `011` and `101`. Mode `110` is "Multiplexed Input with Internal
Reference": it has no output stage and cannot take GP2. Of the three modes one
bit from off, therefore:

| `CM<2:0>` | One-bit transition from `111` | Figure 6-2 mode | GP2 owner | Relay fixture |
| --- | --- | --- | --- | --- |
| `011` | clear CM2 | Comparator with Output and Internal Reference | `COUT` | physical GP2 must be driven High by `COUT`, survive a latch-only clear, then be de-energized at the spin |
| `101` | clear CM1 | Multiplexed Input with Internal Reference and Output | `COUT` | physical GP2 must be driven High by `COUT`, survive a latch-only clear, then be de-energized at the spin |
| `110` | clear CM0 | Multiplexed Input with Internal Reference | GPIO | physical GP2 must remain at the settled-low GPIO level |

All three continue into the firmware gate and escalation. Modes `011` and `101`
are the reachable modes that can energize the GP2 relay coil, and they carry the
complete hazard: `COUT` physically drives the pad High while the firmware's
shadow and expected state both say BYPASS, the superseded latch-only clear
cannot pull it down, and only `hw_emergency_outputs_quiesce()` returning
ownership to GPIO does -- after which the ordinary de-energization, single
watchdog reset and recovery `RESET`-coil pulse are asserted as usual. Mode `110`
makes the converse claim: the comparator is genuinely enabled and still does not
own GP2.

Two simulator limits bound what these cases may claim. gpsim's `p12f675` model
does not read the CIN+ pad -- its modeled `COUT` is a pure function of `CM<2:0>`
regardless of the voltage on GP0 -- so no fixture here asserts anything about
the analog input, and none drives it. And the mode must be installed through
`Register::put()`: gpsim's port registers override `put_value()`, but `CMCON`
overrides only `put()`, so a `put_value()` to `CMCON` updates the register image
without ever engaging the peripheral.

The brief input intervals rely on the board's fail-safe pull-downs. These paths
are bounded responses to detected register-state faults; they do not claim to
survive arbitrary CPU, bus, or package failure.

### Detection, per shell

| Shell | What the gate compares | Coil coverage |
| --- | --- | --- |
| `bypass_mcu_pic10f322.c` | complete `LATA` output latch vs. expected | full |
| `bypass_mcu_avr_classic.c` | complete `PORTB` output latch vs. expected | full |
| `bypass_mcu_avr_xt.c` | complete `PORTA.OUT` latch vs. expected | full |
| `bypass_mcu_pic12f675.c` | shadow vs. expected **and** port-follows-shadow | full, both views |
| `bypass_mcu_pic10f320.c` | exact `TRISA`, plus the two `LATA` coil bits | **coil-only (see below)** |

The four modular shells needed no new detection code: an energized coil is an
output-latch mismatch, which `hw_is_sanity_check_failed()` already rejects.

**PIC12F675** gains rather than loses here. Its port-follows-shadow clause is
unique in the project — it compares intent against reality, catching a driver,
pin or bus fault the other parts cannot see at all — and the old loop-top
whole-port refresh *pre-empted* it at exactly the settled seam where it was
supposed to bite. With the refresh gone, the clause is load-bearing: a coil bit
that appears on the port without the shadow asking for it now escalates, and so
does a non-coil port divergence that used to be silently rewritten.

### The PIC10F320 exception

PIC10F320 has 256 words and no room for the modular shells' complete
output-latch comparison; that gap was accepted when the part was added and is
unchanged. What the relay variant does buy is the one part of the latch that
carries a physical hazard: `hw_output_pins_intact()` OR-folds
`LATA & (RELAY_RESET | RELAY_SET)` into its exact-`TRISA` check, under
`#if defined(OUTPUT_TQ2_RELAY)` so the CD4053 variants pay nothing (`LATA` is
volatile — a masked-by-zero read would still be emitted). `hw_force_wdt_reset()`
calls `set_relay_coils_low()` directly, since this shell links no output driver.

That direct call is a single constant-mask `LATA` write, matching half 1 above.
It cleared the two bits separately until `v0.9.10`; folding them into one write
freed six program words and a return-stack level on the part with the least of
both (`docs/pic10f320_validation.md`, run 6). Both fault lanes now observe the
**write sequence** and not only the settled result: injecting both coil latches
and finding one still driven after the clear began fails the host lane
(`partial_clear_coils`) and the gpsim lane (instruction-granular sampling of
`LATA` and modeled `PORTA`). With only one coil energized there is nothing for
either to see — a per-bit clear would delay the useful de-energization by one
write without passing through a distinct state — so the both-coils injection is
where the contract is pinned.

So the 320 has **full parity on the coil guarantee**, in the transient as well as
the settled state, and retains its documented gap elsewhere: an LED or spare output-latch upset still goes undetected on that
part until the next accepted actuation rewrites it. That exception is now
*asserted*, not merely described — its gpsim adapter injects the RA0 LED latch
and requires **no** reset, so the gap cannot widen unnoticed (the coil cases
would fail) and cannot silently close either (this case would fail, forcing the
documentation to be updated alongside the firmware).

## Exclusions

These are properties of the design, not gaps in the tests, and they are
unchanged by this policy.

- **The blocking actuation sequence.** From the pre-pulse clear through the
  12 ms delay to the post-pulse clear, no sanity gate runs. An upset there can
  shorten the intended pulse or energize the inactive coil or both coils. The
  normal post-pulse clear commands both coils low if execution completes, but
  missed or spurious relay actuation, audio disruption, and an external output
  path that does not accept that command remain residual risks. This window is
  *characterized* by the shipping-source host harness (below), not guarded.
- **Instruction phase.** The fault tests inject at reviewed, deterministic
  settled seams. They do not sweep every instruction boundary.
- **Detection latency.** An upset arriving just after a gate stays energized
  until the next gate — one tick, 1 ms (1.024 ms on PIC12F675). That is the same
  exposure the old loop-top re-assert had, and it is bounded by the tick, not by
  the watchdog period.
- **A stuck external pin.** Only PIC12F675 compares physical port against
  independent shadow intent. The other shells guard writable state; they do not
  claim to detect an output that refuses to follow it.
- **Relay mechanics.** No simulator models an armature. Every measurement below
  is of the *electrical pulse the firmware drives*. Whether a given relay,
  at a given voltage and temperature, moves for a below-minimum pulse — or fails
  to move for an above-minimum one — is a bench question, and the project's
  `1.x.y` hardware-validation pass is where it belongs.

## Test coverage

Five independent harnesses across eight part/substrate rows. Each names which
half of the contract it can prove on its substrate, and none of them claims the
other.

| Substrate | Harness | De-energization | Resynchronization |
| --- | --- | --- | --- |
| PIC10F322 (gpsim) | `test/pic/test_fault_pic.cc` → `inject_relay_resync_case` | cycle-timed, ≤ 3 ms | RESET-coil pulse measured on modeled `PORTA`, ≥ 4 ms, SET dark, settles BYPASS |
| PIC10F320 (gpsim) | `test/pic10f320/gpsim/test_fault_pic.cc` (same case) | same | same |
| PIC12F675 (gpsim) | `test/pic/test_fault_pic12f675.cc` (same case) | direct modeled GP1/GP2 node voltage at the watchdog spin, including comparator-owned GP2 | same |
| AVR classic, tinyx5 (simavr) | `test/avr/test_sim.c` → `inject_coil_resync` | `PORTB` coil bits low after the gate | edge-timed RESET-coil pulse ≥ 4 ms, SET never driven, LED dark |
| AVR classic, ATtiny13A (simavr) | same | same | **not observable**: simavr has no WDT system-reset model for this part, so the case asserts a permanent `cli()`+spin wedge with the coils held idle |
| ATtiny202 (yasimavr) | `test/avr/test_fault_attiny202.py` → `RESYNC` | physical PA2/PA3 low plus canonical OUT/DIR/PINnCTRL at the spin | **not observable**: yasimavr treats the interrupts-off spin as a terminal halt, so the WDT never completes the reset in the model |
| PIC10F322 / PIC12F675 host source | `test/pic/fw_coverage/test_fw_coverage.c` → `expect_coil_fault_escalates` | all outputs settled low after the run | not claimed (the mock elides `__delay_ms` and aborts the spin on a timer) |
| PIC10F320 host source | `test/pic10f320/fault/test_fault.c` → `expect_relay_coil_fault_escalates` | coil latch sampled where the spin was abandoned | not claimed, for the same reason |

The directional coil-output cases cover both settled-state hazards: BYPASS with
an unintended SET (the relay may move to ENGAGED while the firmware believes
BYPASS) and ENGAGED with an unintended RESET (the mirror). Both must converge on
BYPASS. Pin-configuration fixtures use the one settled state needed to isolate
their register and physical-pad mechanism.

Measured recovery pulses at the reviewed seam, against a 12 ms design pulse:
10.8 ms (PIC10F322), 11.2 ms (PIC10F320), 11.3 ms (PIC12F675). The shortfall is
the harness's 1 ms reset-detection step, not the firmware's. The tinyx5 case
times the same pulse from pin edges and requires only that it clear the 4 ms
minimum; the separate width oracle, which measures the *design* pulse rather
than a recovery, reports 13.5 ms on the classic AVR, where the 1 ms tick ISR
preempts the busy-wait.

### Mutation resistance

Both policy directions are killed, verified on PIC10F322:

- **Remove the de-energize from `hw_force_wdt_reset()`** → de-energization
  latency never observed, and in the SET-coil cases the injected coil is still
  driven when the recovery begins.
- **Restore the old silent correction** → no reset, no recovery pulse, and the
  ENGAGED cases can no longer even reach the state they claim to test.
- **Weaken the PIC10F320 coil guard to one bit** → the unguarded coil is never
  detected and stays energized for the whole observation window.

The physical-pin extensions add independent negative controls:

- **Reduce the AVR-XT emergency path to `PORTA.OUT` clearing** -> an `INVEN`
  fixture leaves physical PA2 or PA3 high even though the latch reads low.
- **Reduce the PIC12F675 emergency path to shadow/GPIO clearing** -> the
  high-`COUT` fixture leaves physical GP2 high at the watchdog spin even though
  the SRAM coil intent is low.

The AVR-XT matrix also exercises each coil's pull-up, one-bit direction upset,
and a combined input/stale-OUT/PULLUPEN+INVEN state. The PIC12F675 relay matrix
covers all three comparator modes one bit away from off (`110`, `101`, `011`);
modes `011` and `101`, the reachable modes that own GP2, are run through full
escalation with the pad physically driven High by `COUT`. These are modeled electrical pin checks, not
relay-mechanical or bench evidence.

One consequence worth naming: because the recovery pulse is now measured, a
mutant that shortens the *design* pulse below the datasheet minimum is caught by
the fault lane as well as by the target-I/O minimum check. The PIC aggregates
are fail-closed and run fault before io, so that mutant's verdict now comes from
the fault lane — the mutation harness's `resync:minimum-pulse` signature says
so. The io minimum check still runs, and still passes, on every clean run.

### The excluded window, characterized

`test_relay_pulse_fault_window()` in the PIC shipping-source host harness injects
active-coil-low and inactive-coil-high faults at 1, 6 and 11 ms into the 12 ms
delay, for both SET and RESET: 12 cases per device. It records the actual
injection offset and counts every modeled post-injection millisecond. All cases
show no correction during the remaining blocking interval and a final modeled low
state; the inactive-high cases make the post-pulse clear load-bearing on
PIC10F322. These are residual-risk characterizations. They are not evidence that
an external output accepts the write, and not evidence that the relay cannot
move.

### PIC12F675 whole-port write

The classic mid-range core has **no `LATx` register**, so the shell keeps an SRAM
`gpio_shadow_` and writes `GPIO = gpio_shadow_` — the entire port byte — on every
output change. The relay driver's masked clear therefore removes both coil bits
from the shadow before its single `GPIO = gpio_shadow_` assignment. That ordering
is load-bearing and unchanged by this policy: two sequential single-pin clears
could replay the other coil's corrupt shadow bit onto the physical port between
them. `test_relay_reassert_atomic_clear()` requires exactly one whole-port write
with no intermediate high, and kills a mutation back to the sequential form.

## Test-harness note: faithful footswitch on the AVR classic (simavr)

The classic-AVR harness accounts for a **simavr fidelity gap**, not a firmware
behavior. The masked clear is a full-`PORTB` read-modify-write, so it re-asserts
PB0's internal pull-up. simavr, left alone, lets that write override the
externally driven footswitch level, so presses stopped registering. On real
hardware this cannot happen — a footswitch closed to ground overrides the weak
internal pull-up, and re-writing an already-enabled pull-up is a no-op.

The harness drives the footswitch as a **persistent external pull** via simavr's
`AVR_IOCTL_IOPORT_SET_EXTERNAL`, <!-- name-contract: exempt (AVR_IOCTL_IOPORT_SET_EXTERNAL is a simavr C macro, not a make variable) --> plus an immediate `avr_raise_irq`
for zero-latency edges (`footsw_set` in `test/avr/test_sim.c`). The external pull
survives PORT writes (the switch beats the pull-up, as on hardware); the raise
avoids the one-tick input latency the persistent-pull-alone path introduced. The
AVR-XT (yasimavr) already models this faithfully (`set_external_state`), and the
PIC gpsim/shadow harnesses were never affected.

## Related

- `CHANGELOG.md` and commits `f78d168`, `93f637b`, `712589c` record the
  correct-in-place model this policy replaces.
- `docs/context_seu_detection.md` — the sibling fault-hardening item (F2).
- `docs/phase2_pic_shell.md` — the PIC Model-B polled-loop design the PIC shells
  share.
- `src/bypass_mcu_pic12f675.c` header comment — the GPIO-shadow rationale.
- `src/bypass_hw_iface.h` — the `hw_outputs_reassert_safe()` contract.

> Filename note: this file is still `relay_coil_fault_correction.md` because a
> rename would touch every reference to it in the tree for no behavioural gain.
> Its subject is the relay coil fault *policy*, of which correct-in-place was the
> earlier answer.
