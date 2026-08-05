# Non-blocking output schemes — feasibility

**Status:** feasibility assessment. Nothing here is implemented; no `src/` change
has been made or is proposed for merge. It records what was measured on the real
toolchain, what a redesign would have to do rather than copy, and what remains
unpriced — so the decision to start (or not start) can be taken on evidence.

**What this document establishes:**

1. The PIC10F322 **cannot afford the AVR's ISR concurrency model**, and the
   binding resource is **not flash** — it is the 8-level hardware return stack.
   The relay variant lands at 6 levels used against a budget of 8 with a 2-level
   reserve: **zero spare**. Measured (§2.3).
2. The self-health checks cost **132 words**, about 26% of the part, and the ISR
   needs only 2 — so there is ample room to trade. But the checks buy **flash and
   nothing else**: the relay's deep call chain is entirely output-driver code and
   contains no check at all, so ablating every one of them leaves the stack
   unchanged (§2.4). Trading them is paying in the wrong currency.
3. **Non-blocking actuation reaches the same goal from the other side.** Instead
   of letting a second execution context run *through* a blocking delay, it
   removes the blocking delay. It needs no ISR, no extra stack level, no +38
   words, and no checks surrendered — and it delivers uniform timing on *every*
   platform including the AVR, not just parity between two of them (§3).
4. The API shape this needs is **already the shape of the drivers**. Both
   blocking drivers are exactly `pre-action; one delay; post-action` — verified
   against the source, not assumed (§3.1).
5. It is **not free**, and the largest cost lands on the very checks §2 was
   trying to protect: a deliberate transient window appears in which the output
   latches match neither BYPASS nor ENGAGED, and `hw_is_sanity_check_failed()`
   must learn about it (§5.1). That cost is **unmeasured** and is the first thing
   a spike should price.

**Date / branch:** 2026-08-05, `main` @ `59d55e9`.

**Toolchain used for every figure below** — the versions pinned in
`TOOLCHAIN.adoc`, with no additions:

| Tool | Version | Where |
|---|---|---|
| XC8 (free tier) | v3.10 | `/opt/microchip/xc8/v3.10/bin/xc8-cc` |
| Device pack | PIC10-12Fxxx DFP v1.9.189 | `/opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189/xc8` |

> Scope note: the ISR figures come from a **throwaway spike** written outside the
> repository — an ISR-converted copy of the shipping `src/bypass_mcu_pic10f322.c`,
> plus a macro-ablatable copy of each shell used to price the checks one at a
> time. Neither is proposed code and neither is checked in. §8 lists the exact
> edits behind every number.

---

## 1. Where this came from

The AVR and PIC designs differ in a way that is easy to state: the AVR is loosely
multi-threaded. Its 1 ms timer ISR integrates the footswitch while `main()` does
everything else, so when `main()` blocks for a 12 ms relay coil pulse, debouncing
keeps running underneath it. The PIC shells are Model B — a single polled loop
(`docs/phase2_pic_shell.md` §1) — so the same 12 ms pulse stops the debounce
integrator dead.

The consequence is real but small: on the relay variant the re-arm window
stretches by the pulse width. `RELEASE_THRESH` is 25 ticks, so ~25 ms becomes
~37 ms before the footswitch can be pressed again. The toggle itself is
unaffected, because it has already happened — the effect switches on the press,
and the coil pulse fires afterwards. Nothing audible changes.

What *does* change is uniformity. The project's value proposition is
reference-quality firmware whose behaviour is the same everywhere, and "the same
everywhere except the PIC parts, during actuation, on two of three variants" is a
caveat with a maintenance cost attached. The question that opened this
investigation was therefore whether the PIC10F322 could simply run the AVR's
model — and, when it turned out not to, whether the self-health checks could be
thinned to make room.

The answer to the second question is the interesting one, and it is *no* — but
not for the reason anyone expected.

---

## 2. The measurement: what stops the PIC10F322

### 2.1 What the self-health checks cost

Each check in the main-loop guard was ablated individually, via a macro-switched
copy of the shell, and the image re-linked. Measured on `cd4053_with_mute`
(baselines: 471 words polled, 509 words with an ISR):

| Check | Frees (polled) | Frees (ISR) |
|---|---|---|
| `ctx_.program_state > RELEASE_DEBOUNCE_WAIT` | 4 | 4 |
| `ctx_.debounce_counter > RELEASE_THRESH` | 4 | 4 |
| `ctx_.effect_state > ENGAGED` | 4 | 4 |
| `timer_isr_called_` handshake range | — (absent) | 4 |
| `hw_footswitch_pullup_intact()` | 24 | 24 |
| `hw_is_sanity_check_failed()` → `hw_output_state_intact()` | 54 | 54 |
| `hw_critical_sfrs_intact()` | 42 | 42 |
| **Total (shipping shell)** | **132** | — |

132 words is 25.8% of the part. The intuition that flash growth has been driven
by checks, and that there is slack to reclaim, is correct and then some.

### 2.2 What the ISR costs in flash

| Variant | Polled (shipping) | ISR | Δ |
|---|---|---|---|
| `cd4053_simple` | 445 (86.9%) | 483 (94.3%) | +38 |
| `cd4053_with_mute` | 471 (92.0%) | 509 (99.4%) | +38 |
| `tq2_l2_5v_relay` | 473 (92.4%) | does not link | — |
| RAM (all variants) | 34 B (53.1%) | 43 B (67.2%) | +9 |

The relay failure is worth stating precisely, because "misses by two words" is
the linker's message but not the whole mechanism:

```
error: (1347) can't find 0x2 words (0x2 withtotal) for psect "text18"
in class "CODE" (largest unused contiguous range 0x1)
```

This is **fragmentation at 511 of 512 words**, not a 514-word program. The image
needs two *contiguous* words and the largest free run is one — the ISR vector at
0x0004 splits the code space. (511 is an inference: four independent ablations
that each free 4 words all land at 507, and the linker never reports a total for
a build that fails. The exact figure does not affect any conclusion below.)

Any single ablation from §2.1 buys the relay build. The cheapest is one range
check, at 4 words, landing at 507/512:

| Ablation | Result |
|---|---|
| any one of the four range checks | 507 words — links |
| `hw_footswitch_pullup_intact()` | 487 words — links |
| `hw_critical_sfrs_intact()` | 469 words — links |
| `hw_is_sanity_check_failed()` | 457 words — links |

So on the flash axis the trade is not merely possible, it is overwhelming.

### 2.3 What the ISR costs on the return stack

This is the axis that decides the question. Both oracles of
`test/check_stack_depth_pic.sh` — the longest chain in the emitted instruction
stream, and XC8's own `callstack` directives — agree on every row:

| Build | main tree | ISR tree | Used | + reserve 2 | Spare |
|---|---|---|---|---|---|
| polled `cd4053_simple` *(shipping)* | 3 | — | 3 | 5 | 3 |
| polled `cd4053_with_mute` *(shipping)* | 3 | — | 3 | 5 | 3 |
| polled `tq2_l2_5v_relay` *(shipping)* | 4 | — | 4 | 6 | 2 |
| ISR `cd4053_simple` | 3 | 2 | 5 | 7 | 1 |
| ISR `cd4053_with_mute` | 3 | 2 | 5 | 7 | 1 |
| **ISR `tq2_l2_5v_relay`** | 4 | 2 | **6** | **8** | **0** |

The trees sum rather than max, because an interrupt can arrive at the deepest
point of the main tree; the ISR tree also carries the return address the hardware
pushes on entry. The device pack declares `STACKDEPTH=8` and the overflow is
silent on this core — no STKPTR, no STKOVF, no stack-overflow reset — so the
2-level reserve is what stands between a bench debugger and an undetectable
wrong-return.

### 2.4 Why trading checks does not solve it

The relay variant's 4-level main chain is:

```
_main -> _init -> _hw_set_bypass_state -> _set_relay_coils_low -> _hw_pin_set_low
```

Every edge is output-driver code reached from `init()`. **Not one self-health
check appears in it.** Ablating all 132 words from §2.1 leaves this chain at 4
levels and the ISR relay build at 6 used, 0 spare.

Nor can the chain be flattened cheaply. `hw_pin_set_low()` is the hardware
abstraction boundary; the driver cannot write `LATA` directly without breaking
the portability contract it shares with the AVR, and XC8's free tier has no
link-time optimization to inline across that boundary on its own.

So the honest summary of the ISR option on the PIC10F322 is: it costs 511 of 512
words and 8 of 8 stack levels on the variant that most needs it, and the currency
available to pay with buys only one of those two. There is also an irony worth
recording — `cd4053_simple` is the one variant with comfortable room (483 words,
1 stack level spare) and it is the one variant that never blocks, so it gains
nothing from an ISR at all. **The variants that need the concurrency are exactly
the ones that cannot afford it.**

---

## 3. The alternative: remove the blocking delay instead

The ISR model lets a second execution context keep running *through* a blocking
delay. The other way to reach the same place is to stop blocking.

Drive the coil pulse and the mute gap as a tick-counted state in the existing
polled loop. The loop already runs once per millisecond on every platform; an
actuation that takes 12 ms becomes a countdown of 12 iterations rather than 12 ms
spent inside `__delay_ms()`.

### 3.1 Both blocking drivers already have the right shape

This is the part that makes the redesign tractable, and it is verified against
the source rather than assumed. Every actuation in both blocking drivers is
`pre-action; exactly one delay; post-action`, with the delay always in the middle:

| Driver / target | pre | delay | post |
|---|---|---|---|
| relay → BYPASS | coils low, LED low, RESET high | 12 ms | coils low |
| relay → ENGAGED | coils low, LED high, SET high | 12 ms | coils low |
| mute → BYPASS | LED low, CTL1 low | 5 ms | CTL2 low |
| mute → ENGAGED | CTL1/CTL2 low, LED high, CTL2 high | 5 ms | CTL1 high |
| `cd4053_simple` → either | everything | — | — |

There is no driver with two delays, none with a delay at the start or end, and
none whose delay length depends on runtime state.

### 3.2 The interface

A `_pre` / `_post` split maps directly onto that table. One refinement: pass the
target state rather than splitting the API by it, because the mute driver's
*post* action genuinely differs between the two directions (`CTL2` low versus
`CTL1` high). That keeps the interface at two functions instead of four:

```c
void hw_actuation_begin(effect_state_t target);
void hw_actuation_end(effect_state_t target);
```

The duration is already a per-driver compile-time constant
(`TQ2_L2_5V_PULSE_MS` = 12, `CD4053_MUTE_DELAY_MS` = 5, and 0 for
`cd4053_simple`), so it can be exposed as a macro — `BYPASS_ACTUATION_TICKS` —
with no runtime query to pay for.

### 3.3 What the shell takes on

One byte of state and a countdown in the existing loop:

```c
static uint8_t actuation_ticks_;   /* 0 == idle */
```

On a toggle, call `hw_actuation_begin(target)` and load the counter (or, when the
count is zero, call `hw_actuation_end()` immediately and stay idle). On each
subsequent tick, decrement, and call `hw_actuation_end(target)` on reaching zero.
The `cd4053_simple` variant degenerates to today's behaviour exactly.

Note this replaces a *blocking* dependency with a *state* dependency, which is
the trade being proposed: the loop gets slightly more complex so that its timing
gets simpler.

---

## 4. The simplification case

The reason to take this seriously is not the relay variant. It is that a pile of
existing complexity exists only to accommodate blocking, and would be deleted:

- **`src/bypass_blocking_delay.h` disappears entirely.** That header exists only
  to paper over avr-libc's `_delay_ms()` versus XC8's `__delay_ms()`. Deleting a
  portability shim is a real reduction in surface, not a relocation of it.
- **The tick-stealing divergence goes away.** `docs/phase2_pic_shell.md` §5
  documents it as accepted behaviour; it stops existing rather than staying
  documented.
- **The soak harness stops needing per-variant timing.** `pic_soak_block_*` in
  the Makefile (0 / 5 / 12) and the `SOAK_PRESS_HOLD_MS = PRESSED_THRESH +
  SOAK_ACTUATION_BLOCK_MS + 10` arithmetic in `test/pic/test_soak_pic.cc` exist
  purely to widen the stimulus windows by the block length. Both collapse to one
  variant-independent number.
- **Both watchdogs could tighten.** The PIC's ~256 ms (`WDTPS` 1:8192) and the
  AVR's `WDTO_250MS` are both sized for a worst-case pet-to-pet window dominated
  by the coil pulse — ~14 ms on the PIC (1 ms tick + 12 ms pulse; the PIC pets at
  the end of the loop body) and ~13 ms on the AVR (which pets before actuating).
  Non-blocking collapses that window to roughly one tick, which would permit a
  materially shorter watchdog period on both families. **That is a reliability
  improvement, not a cleanup** — it is the strongest argument in this document.

The interface gets wider (two functions where there was one call site) and the
conceptual model gets narrower (one timing story instead of two). That is usually
the right direction, and the intuition that a more complex API can be a
project-level simplification is, in this case, correct.

---

## 5. The costs

### 5.1 The sanity checks gain a transient state — unpriced

This is the real cost, and it lands squarely on §2's subject matter.

`hw_is_sanity_check_failed(effect_state)` asserts that the output latches match
the logical state, and that assertion holds today *because* actuation completes
inside a single call — there is no observable moment where the pins disagree with
the state. Non-blocking actuation deliberately creates one: for 12 ticks the
relay coils are energized, matching neither the BYPASS latch pattern nor the
ENGAGED one.

The check must therefore learn a third, transient expectation, or be suppressed
across the window. Either costs flash on a part where §2 established there is
none to spare, and "suppressed" is the option that quietly weakens exactly the
SEU/EMI detection the project treats as a first-class requirement.

**This is unmeasured.** It is the first thing a spike should price, because it
determines whether this proposal is a clean win or merely relocates the squeeze.

### 5.2 A second toggle can now land mid-actuation — and provably does not

Today the blocked loop makes this impossible by construction. Non-blocking makes
it expressible, so it must be shown unreachable rather than assumed.

It is unreachable, with margin. After a toggle the debounce enters release-wait
and needs `RELEASE_THRESH` (25) high samples followed by `PRESSED_THRESH` (8) low
samples before it can toggle again: 33 ticks minimum, against a 12-tick pulse.

Both drivers already carry the guarding assertion:

```c
static_assert(TQ2_L2_5V_PULSE_MS < RELEASE_THRESH, ...);
static_assert(CD4053_MUTE_DELAY_MS < RELEASE_THRESH, ...);
```

Those assertions do not become obsolete under the redesign — they get *promoted*.
Their justification changes from "the block must not steal too many ticks from
the release budget" to "no toggle can land inside an actuation window". Same
constraint, stronger reason, and it should be re-commented rather than reused
silently.

### 5.3 The drivers are shared, so the AVR moves too

`src/bypass_output_*.c` is common to both families. Changing the driver interface
re-baselines the AVR simavr lock-step tests, the mutation lanes, and any formal
lane that models actuation. That is what the suite is for, but it is the bulk of
the work — the driver edit itself is small.

This also means the change cannot be scoped to "the PIC problem". It is a
project-wide interface change, which is an argument both for it (uniformity is
the goal) and for doing it deliberately rather than incrementally.

---

## 6. Related finding: the stack gate could not measure an ISR build

Discovered while taking the §2.3 measurements, and **fixed in the same commit as
this document**.

`test/check_stack_depth_pic.sh` built its call graph from targets matching:

```awk
/^[ \t]+(fcall|call|lcall|pcall)[ \t]+_/
```

XC8 names the copies it makes of a non-reentrant function reachable from two call
graphs `i1_<name>` / `i2_<name>` (advisory 1510) — with no leading underscore.
Those appear the moment an ISR shares a helper with `main()`, which is exactly
what an ISR shell does. The edge into the duplicate was dropped, leaving it with
no callers, and the root-versus-entry cross-check rejected the build with:

```
FAIL: i1_hw_read_footswitch is never called but XC8 does not list it as an
entry point
```

Three things are worth recording about this:

- **It never affected shipping firmware.** There is no `__interrupt` handler in
  either PIC shell and no `GIE = 1` anywhere, so XC8 never emitted a duplicate.
  Every call target inside a function psect in all three built images starts with
  `_`, and all three measure correctly (3 / 3 / 4 levels).
- **It failed closed, structurally.** A dropped edge always leaves an uncalled
  function that is not an XC8 entry point, and that check runs before any depth
  is reported — so the failure mode was a confusing error, never a silent
  under-count. The bad direction was not available.
- **The gate's analysis was already right.** It sums the reset and interrupt
  trees and adds the hardware-pushed return address, and `test_stack_depth_pic.sh`
  case 11 already covered ISR summing. That case passed because its synthetic
  helper is spelled `_ihelp`; only the lexer had not been told what real XC8
  emits.

The fix admits `i[0-9]+_` and is deliberately no broader — startup code calls
runtime helpers such as `clear_ram0` from outside any function psect, and the
leading-underscore requirement is what keeps those from parsing as calls. A
future unrecognized prefix still fails closed by the same mechanism. Regression
case 12 in `test/test_stack_depth_pic.sh` uses the name XC8 actually emits, and
fails against the pre-fix gate.

---

## 7. Recommendation

**Do not trade self-health checks for an ISR on the PIC10F322.** The purchase
price is a 511/512-word image with 0 of 8 stack levels spare on the relay
variant — both resources at 100% — to remove a timing difference that is not
observable. For firmware whose stated goal is textbook-grade reference quality,
that is the wrong place to spend the last of two budgets at once. Dropping the
`ctx_` range checks specifically is backwards under an ISR, since `ctx_` becomes
state shared across two execution contexts and is *more* exposed, not less.

**If uniform timing is worth pursuing, non-blocking actuation is the better
instrument.** It attacks the divergence at its source, benefits every platform
rather than reconciling two, deletes more than it adds (§4), and leaves the
self-health checks intact.

**The next step is a spike, not an implementation.** Specifically: build the
transient-state sanity check from §5.1 on the PIC10F322 relay variant and measure
it. If the actuating-state check fits inside the ~40 words that non-blocking
actuation frees by deleting `BYPASS_DELAY_MS` and its call sites, this is a clean
win on all three variants. If it does not, the proposal trades one flash squeeze
for another and should be reconsidered on the AVR first, where there is room to
prove the design before porting it back.

Note also that the PIC12F675 assessment
(`docs/pic12f675_feasibility.md` §4.3) is unaffected as to flash but **not** as
to the stack — see §9.

---

## 8. Reproducing the figures

Every number above came from the pinned XC8 in the toolchain table, invoked as
the Makefile invokes it:

```
xc8-cc -mcpu=10F322 -mdfp=<DFP> -std=c99 -O2 \
       -DBYPASS_MCU_PIC10F322 -D_XTAL_FREQ=2000000UL -D<VARIANT_MACRO> \
       <shell>.c bypass_pure.c <driver>.c -o <out>.hex
```

- **§2.1 ablation** — a copy of each shell with the guard rewritten as
  `if (CHK_PS || CHK_DC || CHK_ES || CHK_HS || CHK_PU || CHK_DRV || CHK_SFR)`,
  each macro expanding either to its original expression or to `0` under
  `-DABL_<name>`. Verified to reproduce the shipping figures exactly (445 / 473
  polled, 483 ISR) with no `-DABL_*` defined, before any ablation was trusted.
- **§2.2 / §2.3 ISR shell** — the shipping `bypass_mcu_pic10f322.c` with five
  edits: enable `TMR2IE`/`PEIE`/`GIE` in `hw_tick_timer_start()`; add a
  `__interrupt()` handler that clears `TMR2IF`, sets a handshake flag and calls
  `debounce_integrate()`; make `ctx_` and the flag `volatile`; replace the
  `hw_wait_for_tick()` call with the AVR's `if (1U != timer_isr_called_)
  { continue; }` handshake; and snapshot `ctx_` before `debounce_step()`.
- **§2.3 stack depths** — `test/check_stack_depth_pic.sh <asm> 8 2 <label>`
  against the generated `.s`, using the fixed gate from §6.
- **Stack depth of both parts** — `STACKDEPTH=8` in
  `<DFP>/xc8/pic/dat/ini/{10f322,12f675}.ini`, corroborated by
  `hwstackdepth="8"` in the corresponding `edc/PIC*.PIC`.

---

## 9. Corrections this implies for other documents

Recorded, **not applied** — each belongs to the document that owns the claim.

| Document | Claim | Correction |
|---|---|---|
| `pic12f675_feasibility.md` §4.3 | The PIC12F675's flash headroom makes the ISR model affordable. | True **for flash only**. Both parts declare `STACKDEPTH=8`, so the 12F675's flash advantage does not extend to the return stack. The relay-variant stack cost measured in §2.3 (6 used, 0 spare) has no reason to be smaller there and must be measured before the ISR model is called affordable on that part. |
| `pic12f675_feasibility.md` §4.3 | The PIC10F322 relay ISR build "misses by two words". | Accurate as the linker's message, but the mechanism is fragmentation at 511/512 with a largest contiguous free run of 1 word (§2.2), not a program 2 words too large. |
| `phase2_pic_shell.md` §1 | Model B is justified by three reasons. | There is a fourth, now measured: on the relay variant the ISR alternative does not fit the part — and would exhaust the return-stack reserve even if it did. |
| `phase2_pic_shell.md` §5 | The tick-stealing divergence from the AVR is accepted behaviour. | Still accurate. Worth a forward reference to this document, which proposes removing the divergence rather than accepting it. |
