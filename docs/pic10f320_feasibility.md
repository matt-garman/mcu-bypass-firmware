# PIC10F320 feasibility — why the 320 is out of scope (and the 322 is not)

**Status:** decided — **PIC10F320 is NOT a supported target.** The firmware does
not fit its 256-word flash under the free-tier XC8 compiler, and no
correctness-preserving source change closes the gap. The PIC10F322 (512 words)
remains the supported PIC target, alongside the classic-AVR parts.

**Date / branch:** 2026-06-26, `pic10f32x_support`. All figures below were
measured with **XC8 v3.10 (free tier)** + **PIC10-12Fxxx DFP v1.9.189**, the
toolchain pinned in `TOOLCHAIN.adoc`.

> Scope note: 10F320 support was always a *nice-to-have* (see the Tier-3 item in
> `TODO.md`). The robustness abstractions discussed at the end of this document
> are *must-haves*. When the two conflicted, robustness won — which is the whole
> point of recording the analysis here.

---

## 1. The hard fact: the firmware is ~100 words too big for the 320

The PIC10F320 and PIC10F322 are the same silicon family — identical peripherals
(Timer2, WPUA/`nWPUEN`, WDTCON, OSCCON/HFINTOSC, TRISA/LATA/ANSELA), identical
CONFIG-word layout at `0x2007`, identical pin map. The **only** difference that
matters here is program-memory size:

| Device     | Flash       | RAM   |
|------------|-------------|-------|
| PIC10F320  | **256 words** | 64 B |
| PIC10F322  | 512 words   | 64 B |

So the firmware source needs **zero** changes to *target* the 320 — it simply
does not *fit*. Measured image sizes (free-tier XC8, `-O2`):

| Variant          | 10F322 (512 w) | 10F320 (256 w)        |
|------------------|----------------|-----------------------|
| cd4053-simple    | 356 w (69.5%)  | **link fails** (356 > 256) |
| cd4053-with-mute | 386 w (75.4%)  | **link fails** (386 > 256) |
| tq2 relay        | 381 w (74.4%)  | **link fails** (381 > 256) |

The 320 link aborts with hard `psect ... in class CODE` overflow errors. The
**smallest** variant (cd4053-simple, 356 words) is **100 words — 39% — over the
320's entire flash.** This is not a near-miss that tuning could recover; it is a
structural gap. (RAM is a non-issue: 34/64 B = 53%.)

---

## 2. Root cause: the free-tier XC8 optimizer is license-capped

The gap is a **toolchain-economics** fact, not a code-design flaw. Microchip's
free (unlicensed) XC8 caps the optimizer; the aggressive size optimizations
(`-Os` / the OCG passes) that would shrink the image are gated behind a PRO
license. Measured, same cd4053 source:

| Optimization | Image (words) | Notes |
|--------------|---------------|-------|
| `-O0`        | 397 | optimizer effectively off |
| `-O1`        | 356 | |
| `-O2`        | 356 | what we ship |
| `-Os`        | 356 | advisory (2051): *"the current license does not permit the selected optimization level, using optimization level 2"* |

The free tier's best is ~356 words for the leanest variant. A PRO license might
shave a further 15–40%, which *might* fit cd4053-simple (356 → ~250) but not
mute/relay (~270+). Relying on a paid compiler to *maybe* fit one of three
variants on a 256-word part — while abandoning the project's free-tier toolchain
stance — is not a trade worth making for a "nice-to-have" target.

### Where the 356 words go (cd4053, from the XC8 link map)

| Symbol                  | Words | |
|-------------------------|-------|---|
| `debounce_step`         | 92 | largest single function (struct-by-value return ABI) |
| `main`                  | 75 | |
| `debounce_init_context` | 21 | |
| `debounce_integrate`    | 20 | |
| (pure core subtotal)    | **~133 (37%)** | |
| `hw_*` helpers          | 2–14 each | |
| C runtime (cinit/clrtext/startup) | ~15 | |

The pure debounce core is the biggest consumer — almost entirely because
`debounce_step` returns a multi-field result struct *by value*, which the
compiler materialises and copies. That observation motivated several of the
ideas below.

### Why no free/open toolchain substitutes for the PRO optimizer

A natural follow-up: XC8 v3 has an LLVM/clang front-end, and LLVM is a powerful
open optimizer — so can a free tool do the `-Os`-equivalent work and hand the
result to XC8? **No.** The size-critical optimizations are PIC-architecture-specific
*back-end* passes that live only in Microchip's proprietary, license-gated code
generator, and there is no open substitute for them.

- **No open 8-bit PIC backend exists.** Upstream LLVM/clang has AVR, MSP430, etc.
  targets but **no 8-bit PIC target** (verified: `clang --print-targets` on the
  clang installed here lists none). XC8's clang front-end lowers C to LLVM IR, then
  hands that IR to Microchip's proprietary *Optimizing Code Generator* (OCG) for
  PIC codegen — so clang cannot emit PIC10F32x assembly at all, optimized or not.
- **The free tier already does the generic optimization.** The *IR-level mid-end*
  passes (inlining, dead-code elimination, GVN — the portable `-O2` work) run for
  free; that is exactly why the `always_inline` and packed-enum experiments below
  change nothing. What the license gates are the *machine-level* OCG passes that
  actually shrink 8-bit PIC code, and they are inherently PIC-specific:
  - **compiled-stack overlay** — the PIC has no data stack, so locals are statically
    overlaid via whole-program call-graph analysis;
  - **bank/page minimization** — eliminating redundant `BANKSEL` / `MOVLP` / `PCLATH`;
  - **procedural abstraction** — factoring repeated instruction sequences into shared
    subroutines (a large win on this ISA).
  A generic IR optimizer does not do these; they require a PIC-aware back end.
- **"Optimize elsewhere, finalize in XC8" cannot be assembled.** Even setting aside
  the missing backend, compiled-stack overlay is a *whole-program* decision, so XC8
  must own the entire back end — you cannot hand its linker independently-optimized
  objects and expect them to share the static-overlay/bank model. There is no
  intermediate hand-off point where a foreign tool could insert optimized code.
- **SDCC (the only open 8-bit-PIC compiler) is the wrong tool.** SDCC's `pic14`
  port targets these parts, but (a) its PIC codegen lacks the optimizations above
  and would almost certainly produce *larger* code than XC8's 356 words; (b) its
  enhanced-mid-range (PIC10F32x) device support is experimental; and (c) it is a
  separate ABI/runtime/CONFIG/intrinsic world, requiring a parallel toolchain *and*
  a forked firmware shell for one nice-to-have part. Net: more code, less device
  confidence, more maintenance — strictly worse.

So the `-Os` "equivalent" is not a portable pass any compiler can run; it is
architecture-specific back-end work that exists only in XC8 PRO. The remaining
levers are a paid/eval PRO license (and even then the estimate fits only
cd4053-simple, ~250 words, not mute/relay) or hand-written PIC assembly (which
discards the C portability *and* the formal-verification/host-test story that is
the project's entire value) — neither worth it for a nice-to-have target.

---

## 3. The size ideas that were considered — and why none close the gap

Three source-level ideas were proposed to shrink the image while keeping the
functional-core abstraction (`bypass_pure.c`). Each was **measured**, not
estimated. Summary (cd4053, free-tier XC8):

| Idea | 322 words | Δ | Fits 320? | Keeps robustness + verifiability? |
|------|-----------|---|-----------|-----------------------------------|
| Baseline (`-O2`)                        | 356 | —   | no | ✅ |
| **8-bit (packed) enums**                | 356 | 0   | no | ✅ but no gain |
| **Force-inline the core** (`always_inline`) | 356 | 0   | no | — (free tier ignores it) |
| Pointer-out-param `debounce_step`       | 344 | −12 | no | ✅ |
| **Bit-pack `context`+`result` structs** | 309 | −47 | **no (53 over)** | ❌ regresses SEU detection |
| Bit-pack + pointer-out (stacked)        | 315 | −41 | no | ❌ (and *worse* than bit-pack alone) |

The best correctness-preserving result is **309 words** — still **53 words over**
the 320's 256, with mute/relay worse (~334–339). **No combination fits.** The
ideas don't even compose (stacking the two best made it *bigger*), which is the
signature of having hit the floor of what source changes can do against a capped
optimizer.

### 3a. 8-bit / packed enums — 0 flash saved

On XC8 the `program_state_t` / `effect_state_t` enums compile to 16-bit `int`
(no `-fshort-enums` — XC8 v3.10 rejects that flag). The hypothesis was that
16-bit operations cost flash. They don't here: `__attribute__((packed))` *does*
work on XC8 v3.10 (drops the enums to 1 byte, `debounce_context_t` 5 → 3 B), but
the image stayed at **356 words** — the optimizer was already generating
identical code, and packing only shrank **RAM** (which is not constrained).

### 3b. Force-inlining the pure core — 0 flash saved

`debounce_step` is the largest function, so inlining it into `main` looked
promising (it would dissolve the struct-by-value return ABI). But marking the
core `static inline __attribute__((always_inline))` left the image at **356
words**, and the link map confirmed `debounce_step` *remained a standalone
function* — **the free tier silently ignored the attribute.** A preprocessor
macro would force textual inlining the compiler cannot skip, but (a) it would
sacrifice the formally-verifiable single-source-of-truth that is the entire
reason `bypass_pure.c` exists, and (b) the capped optimizer would likely retain
the struct-building cost anyway. High cost, low and uncertain payoff.

### 3c. Pointer-out-param — the only robustness-neutral win (−12 words)

Rewriting `debounce_step` to fill a `debounce_step_result_t *` instead of
returning by value saved **12 words** and keeps the function fully real,
host-compilable, and CBMC/model-checkable. It is the only micro-opt worth
considering *purely for 322 headroom* — but it does not help the 320, and it does
not compose with bit-packing (see 3d).

### 3d. Bit-packing the structs — biggest saving, but a robustness *regression*

Packing `debounce_context_t` into one byte (1-bit `program_state`, 1-bit
`effect_state`, 6-bit `debounce_counter`) and the result struct similarly — done
here with C bitfields, which keep `.field` syntax and are safer than hand-rolled
bit macros — saved the most: **−47 words (356 → 309)**. It is still **53 words
over** the 320, so it does not achieve the goal. And the saving is **inseparable
from a real robustness regression**:

```c
// main()'s outlier-corruption sanity checks become DEAD CODE when the
// state fields are 1 bit wide — a 1-bit field can never hold an out-of-range
// value, so these can never fire:
if ( (ctx_.program_state > RELEASE_DEBOUNCE_WAIT) ||   // 1-bit: never > 1
     (ctx_.effect_state  > ENGAGED) ||                 // 1-bit: never > 1
     ...
```

Under the project's cosmic-ray/EMI threat model these checks today catch a
corrupted enum (impossible value → forced WDT reset → recovery). Collapsing the
fields to exactly their valid width removes the ability to *represent* — and
therefore detect — that corruption. Worse, all three state variables then share
**one byte**, so any single bit-flip silently mutates the live state machine with
no detection. The saving cannot be decoupled from this: keeping the states as
full bytes to preserve the checks reduces the change to the packed-enum case
(§3a), which saves nothing.

Bit-packing would also drop the compile-time counter bound
(`DEBOUNCE_COUNTER_MAX`) from 255 to 63, tightening the allowable thresholds, and
would ripple through every formal-verification harness and host test built on the
shared `debounce_context_t`.

**Verdict:** trading a load-bearing SEU-resilience property for 47 words that
*still* don't fit the 320 is a clear no — at any target, not just the 320.

---

## 4. Decision

- **PIC10F320: not supported.** The 256-word flash cannot host the firmware under
  free-tier XC8, and the only source changes that would help enough either don't
  exist (the optimizer is capped) or sacrifice the robustness abstractions that
  are the project's reason for being.
- **PIC10F322: the supported PIC target** — all three variants fit with
  comfortable headroom (≤75%).
- **Keep `debounce_context_t`, the enum types, and the pure
  functional-core/imperative-shell split exactly as they are.** They were
  measured to be *not* the blocker, and the abstraction is the project's
  strongest correctness asset.
- The family naming (`bypass_mcu_pic10f32x.c`, `bypass_pins_pic10f32x.h`,
  `BYPASS_MCU_PIC10F32X`) is retained for convenience; "32x" denotes the register
  family, **not** a claim that the 320 is a buildable target.

---

## 5. Reproduce these numbers

From the repo root, with XC8 + the DFP installed at the `TOOLCHAIN.adoc` paths:

> **Historical snapshot (2026-06-26).** The commands below are the exact
> invocations used for the flash-fit measurement at that date. They predate the
> `pic10f32x` → `pic10f322` rename and the 16 MHz → 2 MHz clock change, so the
> macro (`BYPASS_MCU_PIC10F32X`), source name (`bypass_mcu_pic10f32x.c`), and
> `_XTAL_FREQ=16000000UL` no longer match the tree. For a current build use
> `make pic`; these are retained only to document how the 320-vs-322 fit was
> determined.

```sh
XC8=/opt/microchip/xc8/v3.10/bin/xc8-cc
DFP=/opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189/xc8

# 322 baseline (succeeds, prints "Program space used ... (356) of 512"):
"$XC8" -mcpu=10F322 -mdfp="$DFP" -std=c99 -O2 \
  -DBYPASS_MCU_PIC10F32X -D_XTAL_FREQ=16000000UL -DCD4053_SIMPLE \
  src/bypass_mcu_pic10f32x.c src/bypass_pure.c src/bypass_output_cd4053_simple.c \
  -o /tmp/cd4053_322.hex

# 320 attempt (FAILS to link — code does not fit 256 words):
"$XC8" -mcpu=10F320 -mdfp="$DFP" -std=c99 -O2 \
  -DBYPASS_MCU_PIC10F32X -D_XTAL_FREQ=16000000UL -DCD4053_SIMPLE \
  src/bypass_mcu_pic10f32x.c src/bypass_pure.c src/bypass_output_cd4053_simple.c \
  -o /tmp/cd4053_320.hex

# Show the license/optimization cap (advisory 2051 on -Os):
"$XC8" -mcpu=10F322 -mdfp="$DFP" -std=c99 -Os \
  -DBYPASS_MCU_PIC10F32X -D_XTAL_FREQ=16000000UL -DCD4053_SIMPLE \
  src/bypass_mcu_pic10f32x.c src/bypass_pure.c src/bypass_output_cd4053_simple.c \
  -o /tmp/os.hex
```

`make pic` builds and budget-checks all three variants for the 322 (the supported
PIC target).
