# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
#
# sim_attiny202.py -- shared support library for the ATtiny202 (AVR-XT)
# dynamic-simulation harness, built on a PATCHED yasimavr (see
# scripts/fetch_yasimavr.sh and third_party/yasimavr/patches/). It is the
# yasimavr analogue of the shared plumbing in the PIC libgpsim drivers
# (test/pic/test_soak_pic.cc, test_fault_pic.cc): the three drivers
# test_sim_attiny202.py / test_soak_attiny202.py / test_fault_attiny202.py stay
# thin by leaning on the Sim class here.
#
# WHAT THIS EXERCISES (and what it does NOT):
#   yasimavr runs the REAL built firmware image (build_avr_xt/*.elf), modelling
#   the ATtiny202's TCB0 tick, the fuse-locked WDT (real reset + STATUS.LOCK),
#   RSTCTRL, and PORTA (both input sampling and output drive). That covers the
#   peripheral-register layer of the AVR-XT shell (bypass_mcu_avr_xt.c) that the
#   target-agnostic formal/host suites cannot reach. It does NOT re-verify the
#   pure debounce algorithm (bypass_pure.c) -- that keeps its full host +
#   model-check + symbolic + CBMC coverage independently.
#
# TIMING MODEL: the shell clocks the core at 2 MHz (16 MHz OSC / PDIV 8) and
# ticks on TCB0 every CCMP+1 = 2000 cycles = 1.000 ms. Debounce thresholds are
# PRESSED_THRESH = 8 ms and RELEASE_THRESH = 25 ms. The footswitch (PA7) is
# active-low with an internal pull-up: pressed = external Low, released =
# floating ('Z', pulled high). The status LED is PA1, driven High when the
# effect is engaged.
#
# FUSE PROGRAMMING: the firmware ELF carries no .fuse section, and yasimavr's
# WDT reads WDTCFG at reset to set the period + STATUS.LOCK. The shell's per-tick
# sanity gate (hw_critical_sfrs_intact) force-resets unless WDT.CTRLA == 0x06 and
# STATUS.LOCK is set, so the harness MUST program WDTCFG = 0x06 (the same byte
# `make attiny202-fuses` burns). The clean, self-contained way to do that -- with
# no edit to the installed yasimavr config -- is to build the device from a
# descriptor whose fuse factory-values we patch (see build_device below). This
# replaces the spike's YAML edit.

import os
import sys

try:
    from yasimavr.device_library.descriptors import DeviceDescriptor
    from yasimavr.device_library.builders._builders_arch_xt import XT_DeviceBuilder
    from yasimavr.device_library.builders import dev_tiny_0series as _tiny0_mod
    from yasimavr.lib import core as _core
except ImportError as exc:  # pragma: no cover - guarded so drivers can skip loud
    sys.stderr.write(
        "ERROR: could not import yasimavr (%s).\n"
        "Build the patched simulator first:  scripts/fetch_yasimavr.sh\n"
        "then run this driver with that venv's python "
        "(the Makefile's attiny202-sim/-soak/-fault targets do this for you).\n"
        % exc
    )
    raise

# --- device / firmware constants --------------------------------------------
F_CPU_HZ = 2_000_000            # 16 MHz OSC / PDIV 8 (matches the shell)
TICK_MS = 1                     # TCB0 period, CCMP+1 = 2000 cyc @ 2 MHz

PIN_FOOTSW = "PA7"              # active-low input, internal pull-up
PIN_LED = "PA1"                 # driven High when the effect is engaged

PRESSED_THRESH_MS = 8           # bypass_config PRESSED_THRESH (ticks == ms here)
RELEASE_THRESH_MS = 25          # bypass_config RELEASE_THRESH

# Fuse layout: WDTCFG is fuse index 0. 0x06 = PERIOD 256CLK, WINDOW OFF, LOCK.
WDTCFG_FUSE_INDEX = 0
WDTCFG_LOCKED = 0x06

# ATtiny202 register addresses (data space) the harness inspects.
REG_WDT_CTRLA = 0x0100
REG_WDT_STATUS = 0x0101
WDT_STATUS_LOCK_bm = 0x80       # STATUS.LOCK (bit 7)
REG_RSTCTRL_RSTFR = 0x0040
RSTFR_WDRF_bm = 0x08            # RSTFR.WDRF (watchdog reset flag)
REG_CLKCTRL_MCLKCTRLB = 0x0061  # expected 0x05 (PDIV 8, PEN)

# PC of the shell's force-reset spin (hw_force_wdt_reset: cli; for(;;){}). Two
# adjacent addresses observed depending on the entry path; treated as a range.
TRAP_PC_LO = 0x0190
TRAP_PC_HI = 0x0192


def resolve_elf(arg=None):
    """Resolve the firmware ELF path from an argument or $ATTINY202_ELF.

    Fails loud with an actionable message: a missing image must never let a
    driver silently pass (the Makefile builds `attiny202` as a prerequisite).
    """
    path = arg or os.environ.get("ATTINY202_ELF")
    if not path:
        sys.stderr.write("ERROR: no firmware ELF given (argv[1] or $ATTINY202_ELF).\n")
        sys.exit(2)
    if not os.path.isfile(path):
        sys.stderr.write("ERROR: firmware ELF not found: %s\n" % path)
        sys.exit(2)
    return path


class Sim:
    """A loaded, fuse-programmed ATtiny202 running a real firmware image.

    Wraps the yasimavr device + synchronous SimLoop + debug probe and exposes
    the footswitch/LED and the register reads the drivers need.
    """

    StateEnum = _core.Pin.StateEnum

    def __init__(self, elf_path, f_cpu=F_CPU_HZ, wdtcfg=WDTCFG_LOCKED):
        self.f_cpu = f_cpu

        # Build the device from a descriptor with a patched WDTCFG factory fuse
        # (see the module header). create_from_model returns a fresh descriptor,
        # so mutating it here does not leak into other Sim instances.
        desc = DeviceDescriptor.create_from_model("attiny202")
        fuses = list(desc.fuses["factory_values"])
        fuses[WDTCFG_FUSE_INDEX] = wdtcfg
        desc.fuses["factory_values"] = fuses
        self.dev = XT_DeviceBuilder.build_device(desc, _tiny0_mod.dev_tiny_0series)

        # The SimLoop constructor initialises the device; firmware must load
        # AFTER it exists (else "Device not ready").
        self.loop = _core.SimLoop(self.dev)
        fw = _core.Firmware.read_elf(elf_path)
        fw.frequency = f_cpu
        self.dev.load_firmware(fw)

        self.probe = _core.DeviceDebugProbe()
        self.probe.attach(self.dev)

        self.footsw = self.dev.find_pin(PIN_FOOTSW)
        self.led = self.dev.find_pin(PIN_LED)

        # Start with the footswitch released (floating -> pulled high) so the
        # power-on-pressed special case is not triggered unless a test asks.
        self.footsw.set_external_state("Z")

    # --- time --------------------------------------------------------------
    def cycles(self, milliseconds):
        return (self.f_cpu * milliseconds) // 1000

    def run_ms(self, milliseconds):
        """Advance simulated time by `milliseconds` (SimLoop.run takes a
        DURATION in cycles, not a target cycle count)."""
        self.loop.run(self.cycles(milliseconds))

    def run_ms_stepped(self, milliseconds, step_ms=1, on_step=None):
        """Advance in `step_ms` chunks, calling on_step(elapsed_ms) after each.

        Lets a driver sample state mid-run (SimLoop.run is otherwise atomic over
        its whole budget). Returns the total elapsed ms actually run."""
        elapsed = 0
        while elapsed < milliseconds:
            chunk = min(step_ms, milliseconds - elapsed)
            self.loop.run(self.cycles(chunk))
            elapsed += chunk
            if on_step is not None:
                on_step(elapsed)
        return elapsed

    # --- stimulus / observation -------------------------------------------
    def press(self):
        self.footsw.set_external_state("L")

    def release(self):
        self.footsw.set_external_state("Z")

    def led_on(self):
        return self.led.state() == self.StateEnum.High

    # --- registers / core --------------------------------------------------
    def read_ioreg(self, addr):
        return self.probe.read_ioreg(addr)

    def write_ioreg(self, addr, value):
        self.probe.write_ioreg(addr, value)

    def pc(self):
        return self.probe.read_pc()

    def state(self):
        return self.loop.state()

    def wdt_locked(self):
        return bool(self.read_ioreg(REG_WDT_STATUS) & WDT_STATUS_LOCK_bm)

    def in_trap_spin(self):
        return TRAP_PC_LO <= self.pc() <= TRAP_PC_HI

    def critical_sfrs_intact(self):
        """Mirror the shell's hw_critical_sfrs_intact for the SFRs the harness
        can cheaply read: clock prescaler + WDT config/lock still as programmed.
        Used by the functional driver as a sanity assertion and by the
        fault-injection driver as the value it deliberately breaks."""
        return (
            self.read_ioreg(REG_CLKCTRL_MCLKCTRLB) == 0x05
            and self.read_ioreg(REG_WDT_CTRLA) == WDTCFG_LOCKED
            and self.wdt_locked()
        )
