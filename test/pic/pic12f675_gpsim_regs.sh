# PIC12F675 register identity for the shared gpsim CLI wrappers.
#
# SOURCED, never executed: no shebang, deliberately not executable. See
# pic10f32x_gpsim_regs.sh beside it for what belongs in a fragment like this.
#
# THE ONE STRUCTURAL DIFFERENCE FROM THE 10F32x FRAGMENT. This part has no LATx.
# The shell keeps its output latch as a RAM shadow and writes through to GPIO,
# and GPIO reads the PHYSICAL PIN LEVELS -- so both the "port" and the "latch"
# snapshot come from the same register here.
#
# That trade is worth stating in both directions. This lane gains something: it
# observes the pin actually moving, not merely the value the firmware asked for,
# so a driven pin that never changes level is visible where a LATA read would
# have reported success. It also loses something: it can no longer separate "the
# firmware drove the wrong value" from "the pin did not follow", because there is
# only one observation. The shadow-versus-port divergence that distinguishes
# those two is a job for the libgpsim io lane, which can read the RAM shadow
# directly; this CLI lane deliberately does not pretend to cover it.
GPSIM_PORT_REG=gpio
GPSIM_PORT_LABEL=GPIO
GPSIM_LATCH_REG=gpio
GPSIM_LATCH_LABEL=GPIO

# Footswitch: GP5, high = released, low = pressed. GP5 rather than the 10F32x's
# RA3 because GP3 on this part is input-only AND has no weak pull-up, so it
# cannot serve a switch-to-ground footswitch at all.
GPSIM_FOOTSW_MASK=0x20
GPSIM_FOOTSW_LABEL=GP5

# Status LED: GP0, high = effect ENGAGED, low = BYPASS.
GPSIM_LED_MASK=0x1
GPSIM_LED_LABEL=GP0

# Bits of the register the per-variant expectation covers -- and here the mask is
# LOAD-BEARING rather than a formality. Because the snapshot register is GPIO,
# it also carries the footswitch bit and the two other input pins; comparing the
# whole register against a variant's expected output pattern would fail on every
# checkpoint where the switch happens to be released. GP0..GP2 are active
# outputs and parked-spare GP4 is a guarded output that must remain low.
GPSIM_OUTPUT_MASK=0x17
