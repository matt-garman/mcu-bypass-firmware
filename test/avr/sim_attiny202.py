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
# FUSE PROGRAMMING: the firmware ELF carries no .fuse section. The Makefile
# therefore passes all seven production XT_FUSE_* bytes as required environment
# variables. attiny202_fuses.py validates them and patches a private copy of the
# yasimavr descriptor's factory values before reset. Missing, malformed,
# incomplete, or out-of-range configuration fails instead of silently falling
# back to simulator defaults.

import os
import subprocess
import sys

import attiny202_fuses as Fuse

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
PIN_CTL1 = "PA2"                # x4053 CTL1 / relay RESET
PIN_CTL2 = "PA3"                # x4053 CTL2 / relay SET

PRESSED_THRESH_MS = 8           # bypass_config PRESSED_THRESH (ticks == ms here)
RELEASE_THRESH_MS = 25          # bypass_config RELEASE_THRESH

# Production values are required from the Makefile for every driver. Keep the
# WDTCFG alias used by functional assertions and critical_sfrs_intact().
FUSE_VALUES = Fuse.read_fuses(os.environ)
WDTCFG_LOCKED = FUSE_VALUES["WDTCFG"]

# ATtiny202 register addresses (data space) the harness inspects.
REG_WDT_CTRLA = 0x0100
REG_WDT_STATUS = 0x0101
WDT_STATUS_LOCK_bm = 0x80       # STATUS.LOCK (bit 7)
REG_RSTCTRL_RSTFR = 0x0040
RSTFR_WDRF_bm = 0x08            # RSTFR.WDRF (watchdog reset flag)
REG_CLKCTRL_MCLKCTRLB = 0x0061  # expected 0x05 (PDIV 8, PEN)

# TCB0 (tick timer) and PORTA registers the shell's sanity gate guards.
REG_TCB0_CTRLA = 0x0A40
REG_TCB0_CTRLB = 0x0A41
REG_TCB0_INTCTRL = 0x0A45
REG_TCB0_CCMP_L = 0x0A4C
REG_TCB0_CCMP_H = 0x0A4D
REG_PORTA_DIR = 0x0400
REG_PORTA_OUT = 0x0404
PORTA_DIR_EXPECTED = 0x4E       # PA1|PA2|PA3|PA6 outputs; PA0/PA4/PA5/PA7 inputs
REG_PORTA_PIN1CTRL = 0x0411
REG_PORTA_PIN2CTRL = 0x0412
REG_PORTA_PIN3CTRL = 0x0413
REG_PORTA_PIN6CTRL = 0x0416
REG_PORTA_PIN7CTRL = 0x0417
PORT_PULLUPEN_bm = 0x08
PORT_INVEN_bm = 0x80

# General-purpose I/O register GPR0 (0x001C). The firmware never touches the GPRs,
# so a sentinel written here survives normal operation and is cleared to 0 only by
# a device reset -- the soak's reset witness.
REG_GPR0 = 0x001C

# SRAM lives at 0x3F80.. in the unified data space; ELF data VMAs are 0x800000 |
# offset (avr-nm reports e.g. 0x00803F80). The debug probe addresses SRAM by the
# low 16 bits (0x3F80), so mask off the 0x800000 data flag.
DATA_ADDR_MASK = 0xFFFF

# The shell's force-reset spin is `cli; for(;;){}`. hw_force_wdt_reset is static
# and gets INLINED (no symbol to resolve), but the empty infinite loop always
# compiles to a single AVR `rjmp .-0` -- jump-to-self, opcode 0xCFFF. That opcode
# is a robust, variant-independent signature for "the CPU is parked in the
# force-reset spin": the firmware emits no other jump-to-self.
TRAP_OPCODE = 0xCFFF


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


NM = os.environ.get("AVR_NM", "avr-nm")

# --- pin state ---------------------------------------------------------------
StateEnum = _core.Pin.StateEnum


def level_of_state(state):
    """Map a Pin.StateEnum value to a driven level of 0 or 1, else None.

    None means "not driven High or Low": floating, pulled, analog, shorted or
    error. Shared by the polled Sim.control_levels() and by PinEdgeRecorder, so
    the sampled and the event-driven views of a pin cannot drift apart on what
    counts as driven.
    """
    if state == StateEnum.Low:
        return 0
    if state == StateEnum.High:
        return 1
    return None


class PinEdgeRecorder:
    """An exact transition log for a set of pins, captured as the edges happen.

    This is the pattern yasimavr's author recommends for observing a GPIO
    transition at better than sampling resolution: a CallableSignalHook
    connected to Pin.signal(), filtered to the signal id of interest, while the
    simulation free-runs. Upstream's examples/mega328_blink is the reference.

    It replaces stepping the simulator one cycle at a time and re-reading
    pin.state(). That cost tens of thousands of SimLoop.run(1) calls per traced
    segment and, because 0.1.6 rewinds its cycle counter when a run() budget is
    overshot, billed every instruction exactly one cycle -- which halved every
    width measured inside a trace. Free-running in millisecond budgets and
    timestamping the edges themselves measures the real widths.

    Filtered on StateChange rather than DigitalChange deliberately: a
    StateChange payload is the full Pin.StateEnum, so a pin that is not driven
    at all stays distinguishable from one driven Low. DigitalChange collapses
    both to 0, and does not fire at all when the shell first takes a floating
    pin Low -- which is exactly the safe-startup edge the output tracer has to
    see.
    """

    def __init__(self, sim, pins):
        self._sim = sim
        self._events = []
        # yasimavr does not take ownership of a hook, so these Python objects
        # must outlive the connection or the signal calls into freed memory.
        self._hooks = []
        for index, pin in enumerate(pins):
            hook = _core.CallableSignalHook(self._make_callback(index))
            pin.signal().connect(hook)
            self._hooks.append(hook)

    def _make_callback(self, index):
        def callback(sigdata, hooktag):
            # This must never raise. An exception escaping into the C++ signal
            # dispatcher aborts the whole process through std::terminate, with
            # no Python traceback to explain it -- so check the signal id AND
            # the payload type before reading a value out of the payload.
            if sigdata.sigid != _core.Wire.SignalId.StateChange:
                return
            data = sigdata.data
            if data.type() != _core.vardata_t.Type.Uinteger:
                return
            self._events.append(
                (self._sim.cycle(), index, level_of_state(data.as_uint())))
        return callback

    def drain(self):
        """Return the edges recorded since the last drain, and forget them.

        Each entry is (cycle, pin index, driven level or None), oldest first.
        Pins changed by one instruction share a cycle, so a caller that
        reconstructs a combined state must fold a whole cycle's worth of edges
        before judging it -- otherwise a single write fabricates an
        intermediate state the hardware never presented.
        """
        events = self._events
        self._events = []
        return events


def _read_symbols(elf_path):
    """Return [(addr, name), ...] from `avr-nm -n`, sorted by address.

    avr-nm ships with binutils-avr, which built the ELF, so it is always present
    when there is an image to simulate. Raises with an actionable message if it
    is missing -- the harness self-adjusts to each variant's SRAM symbol
    addresses (ctx_, timer_isr_called_) rather than hard-coding them, the same
    discipline the PIC fault test uses reading _ctx_ from the .sym."""
    try:
        out = subprocess.check_output([NM, "-n", elf_path],
                                      text=True, stderr=subprocess.DEVNULL)
    except OSError as exc:
        sys.stderr.write("ERROR: could not run '%s' to resolve firmware symbols "
                         "(%s). Install binutils-avr or set AVR_NM.\n" % (NM, exc))
        sys.exit(2)
    except subprocess.CalledProcessError as exc:
        sys.stderr.write("ERROR: '%s -n %s' failed (%s).\n" % (NM, elf_path, exc))
        sys.exit(2)

    syms = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) != 3:
            continue
        addr_s, _kind, name = parts
        try:
            syms.append((int(addr_s, 16), name))
        except ValueError:
            continue
    syms.sort(key=lambda t: t[0])
    return syms


def _symbol_addr(syms, name):
    for addr, n in syms:
        if n == name:
            return addr
    sys.stderr.write("ERROR: symbol '%s' not found in the firmware image.\n" % name)
    sys.exit(2)


class Sim:
    """A loaded, fuse-programmed ATtiny202 running a real firmware image.

    Wraps the yasimavr device + synchronous SimLoop + debug probe and exposes
    the footswitch/LED and the register reads the drivers need.
    """

    StateEnum = StateEnum

    def __init__(self, elf_path, f_cpu=F_CPU_HZ):
        self.f_cpu = f_cpu
        self.elf_path = elf_path
        self._control_edges = None

        # Resolve per-variant SRAM addresses from the ELF (avr-nm) so the harness
        # never hard-codes them: the debounce context + the ISR handshake flag.
        # (The force-reset trap needs no symbol -- it is found by its 0xCFFF
        # jump-to-self opcode; hw_force_wdt_reset is static and inlined.)
        syms = _read_symbols(elf_path)
        self.addr_ctx = _symbol_addr(syms, "ctx_") & DATA_ADDR_MASK
        self.addr_ctx_check = _symbol_addr(syms, "ctx_check_") & DATA_ADDR_MASK
        self.addr_timer_isr = _symbol_addr(syms, "timer_isr_called_") & DATA_ADDR_MASK
        self.addr_ctx_check_fn = _symbol_addr(syms, "debounce_ctx_check_word")
        self.addr_debounce_step_fn = _symbol_addr(syms, "debounce_step")

        # Build the device from a descriptor with every production fuse applied
        # (see the module header). create_from_model returns a fresh descriptor;
        # apply_factory_values also copies its list, so no Sim instance can leak
        # fuse changes into another.
        desc = DeviceDescriptor.create_from_model("attiny202")
        desc.fuses["factory_values"] = Fuse.apply_factory_values(
            desc.fuses["factory_values"], FUSE_VALUES
        )
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
        self.ctl1 = self.dev.find_pin(PIN_CTL1)
        self.ctl2 = self.dev.find_pin(PIN_CTL2)

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

    def run_cycles(self, cycles):
        """Advance by an exact cycle count for output-transition tracing."""
        self.loop.run(cycles)

    def run_until_sleep(self, max_cycles, stride=8):
        """Stop once the device reaches IDLE sleep, within a cycle budget."""
        spent = 0
        while spent < max_cycles:
            if self.dev.state() == _core.Device.State.Sleeping:
                return True
            step = min(stride, max_cycles - spent)
            self.loop.run(step)
            spent += step
            if self.is_done():
                return False
        return self.dev.state() == _core.Device.State.Sleeping

    def run_until_pc(self, address, max_steps):
        """Stop before `address`, using instruction steps rather than timing."""
        steps = 0
        while steps < max_steps:
            if self.pc() == address:
                return True
            # yasimavr 0.1.6's run(1) rewinds cycle overshoot. That is unsuitable
            # for timing, but it exposes every instruction PC and this helper
            # intentionally measures only a bounded instruction count.
            self.loop.run(1)
            steps += 1
            if self.is_done():
                return False
        return self.pc() == address

    def cycle(self):
        return self.loop.cycle()

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

    def control_levels(self):
        """Physical PA2/PA3 levels as 0/1; a non-driven level is None."""
        return level_of_state(self.ctl1.state()), level_of_state(self.ctl2.state())

    def control_edges(self):
        """Return the PA2/PA3 edge recorder, attaching its hooks on first use.

        Lazy on purpose. Only the functional driver traces output transitions;
        the soak and fault drivers never ask, so they neither pay for the hook
        callbacks nor accumulate an event list across a multi-hour run.
        """
        if self._control_edges is None:
            self._control_edges = PinEdgeRecorder(self, (self.ctl1, self.ctl2))
        return self._control_edges

    def control_state(self):
        """Physical PA2/PA3 levels as bit0/bit1, or None if not both driven."""
        ctl1, ctl2 = self.control_levels()
        if ctl1 is None or ctl2 is None:
            return None
        return ctl1 | (ctl2 << 1)

    # --- registers / core --------------------------------------------------
    def read_ioreg(self, addr):
        return self.probe.read_ioreg(addr)

    def write_ioreg(self, addr, value):
        self.probe.write_ioreg(addr, value)

    def pc(self):
        return self.probe.read_pc()

    def state(self):
        return self.loop.state()

    def is_done(self):
        return self.state() == _core.SimLoop.State.Done

    def wdt_locked(self):
        return bool(self.read_ioreg(REG_WDT_STATUS) & WDT_STATUS_LOCK_bm)

    def in_trap_spin(self):
        """The CPU is parked in the force-reset spin: the instruction at PC is
        the `rjmp .-0` jump-to-self (opcode 0xCFFF)."""
        w = self.probe.read_flash(self.pc(), 2)
        return (w[0] | (w[1] << 8)) == TRAP_OPCODE

    # --- SRAM (debounce context / ISR flag) --------------------------------
    def read_ram(self, addr, size=1):
        return self.probe.read_data(addr, size)

    def write_ram(self, addr, values):
        self.probe.write_data(addr, bytes(values))

    # --- fault injection ---------------------------------------------------
    # yasimavr treats the interrupts-off force-reset spin as a terminal halt:
    # the device reaches SimLoop.State.Done and the loop stops before the ~250 ms
    # WDT would fire, so the harness cannot observe the WDT completing the reset
    # (a hardware guarantee). Instead the deterministic, in-sim signal that the
    # per-tick sanity gate CAUGHT a corruption is: the device halts (Done) with
    # its PC inside hw_force_wdt_reset. That is what a fault case asserts.
    def in_force_reset(self):
        return self.is_done() and self.in_trap_spin()

    def run_until_force_reset(self, max_ms, step_ms=1):
        """Advance in small steps until the shell enters the force-reset spin
        (Done @ hw_force_wdt_reset) or max_ms elapses. Returns the elapsed ms at
        which it was detected, or None if it never happened."""
        elapsed = 0
        if self.in_force_reset():
            return elapsed
        while elapsed < max_ms:
            self.loop.run(self.cycles(step_ms))
            elapsed += step_ms
            if self.in_force_reset():
                return elapsed
        return None

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
