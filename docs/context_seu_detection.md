# In-range debounce-context SEU detection (F2)

> **Implementation spec / design record.** The firmware edits below are authored
> by the repository owner. Test, Makefile, and mutation scaffolding follow the
> firmware, prepared under the owner's guidance (as with F1). Measured numbers
> come from throwaway scratch builds; no repository firmware was modified to
> produce them.

## Summary

Every shell's per-tick sanity gate rejects only **out-of-range** context
(`program_state > RELEASE_DEBOUNCE_WAIT`, `effect_state > ENGAGED`,
`debounce_counter > RELEASE_THRESH`). An **in-range** single-bit SEU/EMI upset
slips through. The dangerous case is `debounce_counter`: with
`RELEASE_THRESH = 25`, `PRESSED_THRESH = 8`, an idle counter of `0` whose bit 3
or bit 4 flips becomes `8` or `16` — both `<= 25` (passes the range gate) and
`>= PRESSED_THRESH` — so `debounce_step()` toggles the effect on the next tick.
That is a **phantom bypass/engage switch with no footswitch press**, invisible to
every existing guard.

F2 adds a **complemented XOR-fold** shadow of the debounce context, maintained
alongside the persisted context and verified once per tick, immediately before
that tick's integrate. Any single-bit flip of any context member — or of the
shadow byte itself — diverges from the fold and forces a watchdog reset. The
fold arithmetic lives in the **pure core** (`bypass_pure.c`), so it is
host-compiled and CBMC/unit-testable in isolation; only the shadow's *storage*,
the *reset*, and the AVR *ISR/main atomicity* stay in the shells, because those
are inherently stateful/hardware concerns the stateless pure core cannot own.

## Decisions (2026-08-17)

| Question | Decision | Rationale |
| --- | --- | --- |
| Representation | Complemented XOR-fold: one byte `= ~(program_state ^ effect_state ^ debounce_counter)` | Detects every single-bit flip in any member or the shadow — identical detection to per-member complement under the single-event threat model — at one byte and one check instead of three. The complement makes the all-zeros stuck-at case non-trivial. |
| Location of the math | Pure function `debounce_ctx_check_word()` in `bypass_pure.c` | Host- and CBMC-testable single source of truth. |
| Storage / recovery / atomicity | Shell | The pure core is stateless (takes `ctx` by value, returns a result); it cannot own the SRAM byte that dwells between ticks, nor reset the MCU. It already signals faults via `res.fault`. |
| Recovery action | `hw_force_wdt_reset()` — reset, **not** restore | When value and shadow disagree, neither is known-good, so there is no safe value to restore to (unlike F1's coil, which has a known idle). |
| Member scope | All three members | The fold covers the whole context uniformly. |
| Enablement | Compile-time opt-in macro `BYPASS_CTX_CHECK` | Makes the per-part decision explicit and lets the mutation harness build a feature-off baseline. |
| Part scope | **PIC12F675, AVR classic, AVR-XT, PIC10F322** | Every part that links the pure core and has flash room. |
| **PIC10F320 excluded** | Capacity limit | 320 does not link `bypass_pure.c` at all (self-contained inlined logic), and even the cheapest fold overflows its 256-word flash on the relay variant. Its range-only gate stays; the exclusion is documented and tested. |

## The pure-core addition

`bypass_pure.h` — declare (place after `debounce_step`'s declaration):

```c
// F2: complemented XOR-fold over the persisted debounce context, for
// in-range single-event-upset detection.  The shell stores the returned word
// alongside its context, re-derives it after every legitimate mutation, and
// forces recovery when a later tick's re-derivation no longer matches the
// stored word.  Pure and host/CBMC-testable.
uint8_t debounce_ctx_check_word(debounce_context_t const ctx);
```

`bypass_pure.c` — define:

```c
uint8_t debounce_ctx_check_word(debounce_context_t const ctx) {
    return (uint8_t)~(uint8_t)(
            (uint8_t)ctx.program_state
          ^ (uint8_t)ctx.effect_state
          ^ ctx.debounce_counter);
}
```

By **value**, not by pointer: on the PIC the FSR pointer dereference is costlier
than a 3-byte struct copy — the by-pointer form overflowed PIC10F322 in
measurement. `static inline` gives no benefit (XC8 at `-O2` does not inline it).
The function is always compiled into `bypass_pure.c` (so the host suite always
exercises it) and is referenced by the shells only under `BYPASS_CTX_CHECK`.

## Shell wiring — PIC polled shells (`pic10f322`, `pic12f675`)

These two are structurally identical (single-owner polled loop, no ISR). The
unifying rule is: **check the shadow immediately before this tick's integrate;
re-derive it immediately after all of this tick's mutations.** In the polled
loop both happen in `main()`.

**Flash margin note (PIC10F322):** the relay variant lands at 507/512 words —
**5 free**. To stay within that, follow the shape below exactly. In particular
fold the new check into the existing `if (...)` OR chain as its **first term**
(not a separate `if`); a separate branch costs extra words 322 does not have.

1. Storage — after `static debounce_context_t ctx_;`:

   ```c
   #if defined(BYPASS_CTX_CHECK)
   // F2 complemented XOR-fold shadow of ctx_ (see debounce_ctx_check_word()).
   static uint8_t ctx_check_;
   #endif
   ```

2. `init()` — seed the shadow right after `ctx_ = debounce_init_context(...)`:

   ```c
   #if defined(BYPASS_CTX_CHECK)
       ctx_check_ = debounce_ctx_check_word(ctx_);
   #endif
   ```

3. Sanity gate — add the check as the **first** term of the existing OR chain
   (before `hw_wait_for_tick()`'s integrate that follows the gate):

   ```c
           if (
   #if defined(BYPASS_CTX_CHECK)
                   (ctx_check_ != debounce_ctx_check_word(ctx_)) ||
   #endif
                   (ctx_.program_state > RELEASE_DEBOUNCE_WAIT) ||
                   (ctx_.debounce_counter > RELEASE_THRESH) ||
                   /* ...existing terms unchanged... */
                   (0U == hw_critical_sfrs_intact())
              ) {
               hw_force_wdt_reset();
           }
   ```

   Putting the guarded term first avoids a dangling trailing `||` when the macro
   is off.

4. Re-derive — after the state machine is applied for this tick (right after the
   `if (res.reload_lockout)` block, before the `res.fault`/`res.toggled`
   handling):

   ```c
   #if defined(BYPASS_CTX_CHECK)
           ctx_check_ = debounce_ctx_check_word(ctx_);
   #endif
   ```

The gate runs before the integrate, so it validates the value that dwelled since
the previous tick. The re-derivation runs after integrate + `debounce_step`, so
the shadow tracks every legitimate change. Between them the shadow is briefly
stale, but no check runs there.

## Shell wiring — AVR ISR shells (`avr_classic`, `avr_xt`)

The AVR shells keep the integrator **in the timer ISR** (deliberately — the
relay's 12 ms block would otherwise starve main-loop sampling). This changes
where the check must live and is the reason the AVR wiring is more involved than
the PIC's:

- The ISR reads-modifies-writes `debounce_counter` every tick. If the shadow
  were re-derived unconditionally after the integrate, a dwell-time SEU on the
  counter would be folded in and **blessed** — F2 defeated. So the check must
  run **at the top of the ISR, before the integrate**, on the value that
  dwelled.
- `main()` legitimately changes `program_state`/`effect_state` (and the lockout
  counter) after `debounce_step()`. That makes the shadow stale until re-derived;
  if the ISR fired mid-update it would see a half-applied legitimate change as
  corruption. So `main()`'s apply-and-re-derive must be **atomic** w.r.t. the
  ISR.

Both AVR shells have ample flash and RAM for this (+2 SRAM bytes). Use the
"ISR sets a fault flag, main acts" handshake already used for `timer_isr_called_`,
so every reset still originates in `main()`.

1. Include (top of file, near `<avr/interrupt.h>`):

   ```c
   #include <util/atomic.h>   // ATOMIC_BLOCK(ATOMIC_RESTORESTATE)
   ```

2. Storage — alongside `ctx_` (both `volatile`, shared with the ISR):

   ```c
   #if defined(BYPASS_CTX_CHECK)
   static volatile uint8_t ctx_check_;   // complemented XOR-fold shadow of ctx_
   static volatile uint8_t ctx_fault_;   // set by the ISR, consumed by main's gate
   #endif
   ```

3. `init()` — seed the shadow after `ctx_ = debounce_init_context(...)` (interrupts
   are still off here, so no atomic block is needed):

   ```c
   #if defined(BYPASS_CTX_CHECK)
       ctx_check_ = debounce_ctx_check_word(ctx_);
       ctx_fault_ = 0U;
   #endif
   ```

4. Timer ISR — check the dwelled context **before** integrating; on mismatch
   raise the fault flag and skip this tick's integrate/re-derive (so nothing acts
   on known-bad data); otherwise integrate and re-derive:

   ```c
   ISR(TIM0_COMPA_vect) {              // TCB0_INT_vect on avr_xt
       timer_isr_called_ = TIMER_ISR_CALLED;
   #if defined(BYPASS_CTX_CHECK)
       if (ctx_check_ != debounce_ctx_check_word(ctx_)) {
           ctx_fault_ = 1U;
           return;                     // main's gate forces recovery next tick
       }
   #endif
       ctx_.debounce_counter = debounce_integrate(
               hw_read_footswitch(),
               ctx_.debounce_counter);
   #if defined(BYPASS_CTX_CHECK)
       ctx_check_ = debounce_ctx_check_word(ctx_);
   #endif
   }
   ```

5. `main()` gate — consume the flag (a single-byte volatile read is atomic on
   AVR, so no atomic block is needed here). Place it as the first check, before
   the existing range gate:

   ```c
   #if defined(BYPASS_CTX_CHECK)
           if (ctx_fault_ != 0U) {
               hw_force_wdt_reset();
           }
   #endif
           if ( (ctx_.program_state > RELEASE_DEBOUNCE_WAIT) ||
                /* ...existing range gate unchanged... */ ) {
               hw_force_wdt_reset();
           }
   ```

6. `main()` service block — wrap the apply-and-re-derive in one atomic block so
   the ISR cannot observe a half-applied legitimate change:

   ```c
           if (TIMER_ISR_CALLED == timer_isr_called_) {
               timer_isr_called_ = TIMER_ISR_NOT_CALLED;
               hw_wdt_pet();

               debounce_step_result_t const res = debounce_step(ctx_);

   #if defined(BYPASS_CTX_CHECK)
               ATOMIC_BLOCK(ATOMIC_RESTORESTATE) {
                   ctx_.program_state = res.program_state;
                   ctx_.effect_state  = res.effect_state;
                   if (res.reload_lockout) {
                       ctx_.debounce_counter = res.lockout_value;
                   }
                   ctx_check_ = debounce_ctx_check_word(ctx_);
               }
   #else
               ctx_.program_state = res.program_state;
               ctx_.effect_state  = res.effect_state;
               if (res.reload_lockout) {
                   ctx_.debounce_counter = res.lockout_value;
               }
   #endif

               if (res.fault) { hw_force_wdt_reset(); }
               else if (res.toggled) { /* ...unchanged... */ }
               else { /* ...unchanged... */ }
           }
   ```

The ISR's top-of-ISR check and the PIC's gate check are the same principle —
"validate the dwelled context immediately before integrating it" — placed
wherever the integrate happens (main on PIC, ISR on AVR).

## PIC10F320 — excluded, and why that is safe

PIC10F320 is the self-contained special-case shell: it does not link
`bypass_pure.c`, inlining its own `debounce_integrate`/`debounce_step` to fit
256 words. Its relay variant already sits at 245/256 (11 free), and even the
one-byte XOR-fold overflows the device (linker: `can't find words for psect ...
CODE`). So 320 keeps its existing range-only gate and does **not** define
`BYPASS_CTX_CHECK`. This is recorded as a per-target capacity difference (per the
review's "document and test per-target differences rather than silently weaken
one target"), and a focused test asserts the 320 images never reference the F2
symbol. Mixing the feature onto only 320's lighter `cd4053_simple` variant
(36 free) was considered and rejected: per-variant-within-a-part inconsistency is
worse than a clean part-level line.

## Enablement (Makefile, mine, under owner guidance)

Add `-DBYPASS_CTX_CHECK` to the CFLAGS of the four enabled parts only:
`PIC10F322_CFLAGS`, `PIC12F675_CFLAGS`, and the AVR classic + AVR-XT flag sets.
Do **not** add it to `PIC10F320_CFLAGS`. `bypass_pure.c` always compiles the pure
function regardless (the host suite links it unconditionally).

## Measured flash / RAM budget (XC8 v3.10 `-O2`, worst-case relay variant)

| Part | Budget | Baseline | With F2 | Free | Notes |
| --- | --- | --- | --- | --- | --- |
| PIC10F322 relay | 512 w | 476 | **507** | **5** | at the edge — the shape above is required |
| PIC10F322 mute | 512 w | 473 | 504 | 8 | |
| PIC10F322 simple | 512 w | 447 | 478 | 34 | |
| PIC12F675 (all) | 1024 w | ~526 | ~557 | ~467 | comfortable |
| AVR classic (tiny13a) | 1024 B | 760 B | fits | >100 B under ceiling | +2 SRAM bytes |
| AVR-XT (tiny202) | 2048 B | — | fits | ample | +2 SRAM bytes |
| PIC10F320 | 256 w | 245 | **overflow** | — | **excluded** |

The `+31`-word PIC figure is implementation-shape-specific. **The owner must
rebuild PIC10F322 immediately after implementing** and confirm relay is still
`<= 512`; if it comes in heavier than the prototype, we trim the shape or
revisit 322 (its pre-blessed fallback is an in-shell inline-macro version at
14 free, or deferral).

## Test & mutation plan (mine, after the firmware lands)

- **Host/CBMC (`debounce_ctx_check_word`)**: unit-test the fold value and the
  complement; prove that flipping any single bit of any member changes the
  returned word (single-bit detection). This is the payoff of putting the math in
  the pure core.
- **gpsim (`pic10f322`, `pic12f675`)**: add an **in-range** injection case
  alongside the existing out-of-range `0xFF` case — flip `debounce_counter`
  `0 -> 0x10` (bit 4; `16 <= RELEASE_THRESH`, so it passes the range gate) and
  assert a reset via the new fold term. The Makefile extracts the `ctx_check_`
  SRAM address from the `.sym`, as it already does for `CTX_ADDR`.
- **simavr (`avr_classic`) / yasimavr (`attiny202`)**: inject an in-range counter
  flip and assert the ISR-side check forces recovery; confirm no false reset in a
  clean soak (the atomicity is correct).
- **Mutation** (`test/run_mutation_tests.sh`): delete the check (in-range flip
  survives -> phantom toggle, no reset -> killed by the new in-range test); delete
  a re-derivation (init / ISR / main -> false reset in normal operation -> killed
  by the clean soak/sim); weaken the comparison -> killed. Update expected counts.
- **320 exclusion**: assert the PIC10F320 images do not reference
  `debounce_ctx_check_word` and that `BYPASS_CTX_CHECK` is undefined there.
- **Budgets**: re-verify flash (322 at the edge), RAM, stack, and MISRA for every
  enabled part/variant (F2 acceptance criterion 5).

## Acceptance-criteria mapping (F2 in `v0.9.9-polish.md`)

1. In-range single-bit flips of `program_state`, `effect_state`, and
   `debounce_counter` force recovery before an unintended output transition —
   the fold covers all three; the check runs before the integrate/step that could
   act on them.
2. Every legitimate update maintains the redundant representation — re-derivation
   after init, after the PIC loop's mutations, and (AVR) in the ISR after
   integrate and in `main()`'s atomic apply.
3. AVR ISR/main interleavings cannot produce a false mismatch — the ISR is the
   sole counter+shadow writer per tick (check-then-integrate-then-re-derive with
   early-out), and `main()`'s apply+re-derive is atomic.
4. Mutation kills a missing update and a weakened comparison — see the mutation
   plan.
5. Flash, RAM, stack, MISRA, and qualification stay within budget — measured;
   322 is the binding case at 5 free and must be re-verified on landing.

## Related

- `CHANGELOG.md` / Git history — the durable record of this work. The
  `TODO.md` `T3-ctx-complement` task that tracked it was removed on completion,
  per that file's "completed work is removed" convention.
- `v0.9.9-polish.md` F2 / F3 — the review items; F3 carries the "cover
  `debounce_counter` and equivalently exposed members, not the fail-safe
  single-byte guards" constraint, satisfied here by folding exactly the three
  context members.
- `docs/relay_coil_fault_correction.md` — F1, the sibling fault-hardening item
  (correct-in-place vs. this detect-and-reset).
