# PIC10F32x register identity for the shared gpsim CLI wrappers.
#
# SOURCED, never executed: no shebang, deliberately not executable, so it can
# never be mistaken for a scenario of its own -- the same rule that governs
# gpsim_wrapper_common.sh beside it.
#
# WHAT LIVES HERE is device identity only: which gpsim registers a snapshot is
# read from, which bits carry the footswitch and the status LED, and what to call
# them in a message. What must NOT move here is any scenario knowledge -- which
# checkpoints exist and what has to be true at each -- because that is the entire
# content of the wrappers.
#
# This is the wrappers' default identity, and it is correct for BOTH parts that
# use it (PIC10F322 and PIC10F320 name their registers and pins identically); a
# part whose identity differs points PIC_GPSIM_REGS at its own fragment. Unlike
# the PROC fallback next door -- where a wrong value silently simulates the wrong
# chip and still passes -- a wrong register name here yields no snapshot at all
# and gpsim_require_snapshots turns that into a hard failure, so this default
# cannot quietly mis-score another part's lane.

# The register a snapshot reads pin/input state from, and the one it reads output
# state from. Two distinct registers on this family: LATA is what the firmware
# DROVE, PORTA is what the pins READ, and keeping them apart is what lets this
# lane separate a driver fault from a pin fault.
GPSIM_PORT_REG=porta
GPSIM_PORT_LABEL=PORTA
GPSIM_LATCH_REG=lata
GPSIM_LATCH_LABEL=LATA

# Footswitch: RA3, high = released, low = pressed.
GPSIM_FOOTSW_MASK=0x8
GPSIM_FOOTSW_LABEL=RA3

# Status LED: RA0, high = effect ENGAGED, low = BYPASS.
GPSIM_LED_MASK=0x1
GPSIM_LED_LABEL=RA0

# Bits of the latch register the per-variant expectation covers. 0xFF here means
# "compare the whole register", which is what this lane has always done: LATA
# carries nothing but the four port latches, so there is nothing to mask off.
GPSIM_OUTPUT_MASK=0xFF
