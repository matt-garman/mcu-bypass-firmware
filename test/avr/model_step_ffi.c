// SPDX-License-Identifier: MIT
// Copyright (c) Matthew Garman
//
// model_step_ffi.c -- flat C-ABI surface over the shared golden model
// (test/model_step.h) so the Python simulation drivers can call it via ctypes.
//
// WHY THIS EXISTS
// ---------------
// The AVR-Classic lock-step co-simulation (test/avr/test_sim.c) and the PIC one
// (test/pic/test_lockstep_pic.cc) are C/C++, so they `#include "model_step.h"`
// and call step() directly -- which delegates to the SHIPPING pure core
// (src/bypass_pure.c). The AVR-XT harness is Python, because yasimavr is a
// Python-first simulator, and Python cannot include a C header.
//
// The tempting shortcut -- re-implement the debounce algorithm in Python -- is
// exactly the maintenance hazard model_step.h's own header warns about and was
// written to eliminate. A Python copy would have to be kept byte-identical to
// the firmware by hand, and would silently agree with a mutated firmware
// only until someone forgot to update it.
//
// So instead this file compiles AGAINST the same model_step.h and links the
// same src/bypass_pure.c the firmware ships, exposing four plain C functions
// with a ctypes-friendly signature. The AVR-XT lock-step driver therefore
// compares its firmware against the identical golden model as its peers, with
// no second implementation of anything.
//
// Everything crossing the boundary is uint8_t: no structs, no enums, no
// padding or ABI questions. State is passed by pointer and updated in place.
//
// BUILD: `make attiny202-lockstep` builds this into a shared object via the
// XT_LOCKSTEP_FFI_LIB rule (HOSTCC, the same PURE_HOST_CFLAGS shim the model
// checker and symbolic test use). It is a HOST library -- never cross-compiled,
// never linked into a firmware image.

#include <stdint.h>

#include "model_step.h" // step(), state_t, step_result_t -> src/bypass_pure.c
#include "bypass_pure.h" // debounce_init_context()

// ABI generation. The Python loader asserts this matches what it expects, so a
// stale shared object left in a build directory fails loud instead of being
// called with the wrong signature. Bump on any signature change below.
#define BYPASS_MODEL_FFI_ABI 1U

uint8_t bypass_model_abi(void);
uint8_t bypass_model_pressed_thresh(void);
uint8_t bypass_model_release_thresh(void);
void    bypass_model_init(uint8_t   pin_low,
                          uint8_t * program_state,
                          uint8_t * effect_state,
                          uint8_t * debounce_counter);
uint8_t bypass_model_step(uint8_t * program_state,
                          uint8_t * effect_state,
                          uint8_t * debounce_counter,
                          uint8_t   pin_low);

uint8_t bypass_model_abi(void) {
    return (uint8_t)BYPASS_MODEL_FFI_ABI;
}

// The firmware's own debounce thresholds, read through bypass_config_host.h
// from the single source of truth in src/bypass_config.h. Exported so the
// Python drivers can assert their own timing constants against the firmware
// rather than carrying an independent copy.
uint8_t bypass_model_pressed_thresh(void) {
    return (uint8_t)PRESSED_THRESH;
}

uint8_t bypass_model_release_thresh(void) {
    return (uint8_t)RELEASE_THRESH;
}

// Power-on / post-reset state, delegated to the firmware's OWN
// debounce_init_context() -- the same call the AVR-XT shell's init() makes.
// pin_low != 0 means the footswitch reads LOW at reset (held down), which
// selects the lock-out branch the shell relies on to ignore a stuck switch.
void bypass_model_init(uint8_t   pin_low,
                       uint8_t * program_state,
                       uint8_t * effect_state,
                       uint8_t * debounce_counter) {
    pin_state_t const pin =
        (0U != pin_low) ? PIN_STATE_LOW : PIN_STATE_HIGH;
    debounce_context_t const ctx = debounce_init_context(pin);

    *program_state    = (uint8_t)ctx.program_state;
    *effect_state     = (uint8_t)ctx.effect_state;
    *debounce_counter = ctx.debounce_counter;
}

// One 1 ms tick: the ISR's saturating integrator followed by one main-loop
// state-machine pass, exactly as model_step.h's step() defines it and exactly
// what bypass_mcu_avr_xt.c's TCB0_INT_vect + main() do per tick.
//
// Returns 1 if the effect state toggled during this tick, else 0.
uint8_t bypass_model_step(uint8_t * program_state,
                          uint8_t * effect_state,
                          uint8_t * debounce_counter,
                          uint8_t   pin_low) {
    state_t s;
    s.program_state    = *program_state;
    s.effect_state     = *effect_state;
    s.debounce_counter = *debounce_counter;

    step_result_t const r = step(s, (0U != pin_low) ? 1 : 0);

    *program_state    = r.next.program_state;
    *effect_state     = r.next.effect_state;
    *debounce_counter = r.next.debounce_counter;

    return (uint8_t)((0 != r.toggled) ? 1U : 0U);
}
