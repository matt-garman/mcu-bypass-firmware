# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
#
# model_step_ffi.py -- ctypes binding for the golden-model shared object built
# from test/avr/model_step_ffi.c.
#
# This is the Python half of the bridge described in that file's header: it lets
# the AVR-XT (ATtiny202) lock-step driver step the SHIPPING pure debounce core
# (src/bypass_pure.c, through test/model_step.h) tick for tick against the real
# firmware running in yasimavr -- with no re-implementation of the algorithm in
# Python to drift out of sync.
#
# Everything here fails LOUD. A missing, stale or ABI-mismatched shared object
# raises rather than falling back to anything, because a lock-step test that
# quietly compares the firmware to nothing is worse than no test at all.

import ctypes
import os

# Bump in lockstep with BYPASS_MODEL_FFI_ABI in model_step_ffi.c.
EXPECTED_ABI = 1

# Where the Makefile's XT_LOCKSTEP_FFI_LIB rule puts the library. Used only when
# $BYPASS_MODEL_FFI is unset (i.e. someone ran the driver by hand).
DEFAULT_LIB = os.path.join("build_avr_xt", "libbypass_model.so")


class ModelFFIError(RuntimeError):
    """The golden-model shared object is missing, unusable or the wrong ABI."""


def _resolve_lib_path():
    path = os.environ.get("BYPASS_MODEL_FFI") or DEFAULT_LIB
    if os.path.isfile(path):
        return path
    raise ModelFFIError(
        "golden-model shared object not found: %s\n"
        "  Build it with:  make attiny202-lockstep\n"
        "  (or set $BYPASS_MODEL_FFI to an existing libbypass_model.so)" % path
    )


class Model:
    """The firmware's own debounce core, callable a tick at a time.

    Holds the three bytes of debounce_context_t -- the exact state the AVR-XT
    shell keeps in its `ctx_` global -- so a driver can compare them against
    the simulated firmware's SRAM after every settled tick.
    """

    def __init__(self, lib_path=None):
        self.lib_path = lib_path or _resolve_lib_path()
        try:
            lib = ctypes.CDLL(os.path.abspath(self.lib_path))
        except OSError as exc:
            raise ModelFFIError(
                "could not load %s (%s)" % (self.lib_path, exc)
            ) from exc

        u8 = ctypes.c_uint8
        u8p = ctypes.POINTER(ctypes.c_uint8)

        try:
            lib.bypass_model_abi.restype = u8
            lib.bypass_model_abi.argtypes = []
            lib.bypass_model_pressed_thresh.restype = u8
            lib.bypass_model_pressed_thresh.argtypes = []
            lib.bypass_model_release_thresh.restype = u8
            lib.bypass_model_release_thresh.argtypes = []
            lib.bypass_model_init.restype = None
            lib.bypass_model_init.argtypes = [u8, u8p, u8p, u8p]
            lib.bypass_model_step.restype = u8
            lib.bypass_model_step.argtypes = [u8p, u8p, u8p, u8]
        except AttributeError as exc:
            raise ModelFFIError(
                "%s does not export the expected golden-model symbols (%s); "
                "it is stale -- rebuild with `make attiny202-lockstep`"
                % (self.lib_path, exc)
            ) from exc

        abi = int(lib.bypass_model_abi())
        if abi != EXPECTED_ABI:
            raise ModelFFIError(
                "%s has ABI %d, this loader expects %d -- rebuild it "
                "(`make attiny202-lockstep`)" % (self.lib_path, abi, EXPECTED_ABI)
            )

        self._lib = lib
        # Firmware truth, read out of src/bypass_config.h via the C shim rather
        # than duplicated here.
        self.pressed_thresh = int(lib.bypass_model_pressed_thresh())
        self.release_thresh = int(lib.bypass_model_release_thresh())

        self._ps = ctypes.c_uint8(0)
        self._es = ctypes.c_uint8(0)
        self._dc = ctypes.c_uint8(0)

    # --- state ------------------------------------------------------------
    @property
    def program_state(self):
        return int(self._ps.value)

    @property
    def effect_state(self):
        return int(self._es.value)

    @property
    def debounce_counter(self):
        return int(self._dc.value)

    def context(self):
        """The three context bytes in the shell's `ctx_` struct order."""
        return (self.program_state, self.effect_state, self.debounce_counter)

    # --- stepping ---------------------------------------------------------
    def init(self, pin_low):
        """Reset to the firmware's own power-on state for this pin level."""
        self._lib.bypass_model_init(
            ctypes.c_uint8(1 if pin_low else 0),
            ctypes.byref(self._ps),
            ctypes.byref(self._es),
            ctypes.byref(self._dc),
        )

    def step(self, pin_low):
        """Advance one 1 ms tick. Returns True if the effect state toggled."""
        toggled = self._lib.bypass_model_step(
            ctypes.byref(self._ps),
            ctypes.byref(self._es),
            ctypes.byref(self._dc),
            ctypes.c_uint8(1 if pin_low else 0),
        )
        return bool(toggled)
