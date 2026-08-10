#!/usr/bin/env bash
#
# Drive the PIC10F322 POWER-ON-PRESSED startup case in gpsim and assert the LED
# (RA0) / footswitch (RA3) at three settled checkpoints. Companion to
# run_gpsim_test.sh (the two-press toggle scenario); this one covers the startup
# branch where the footswitch is held CLOSED at power-on -- the device must come
# up in BYPASS and must NOT engage until a genuine release + a fresh press. The
# gpsim stimulus + register snapshots live in test/pic/power_on_pressed.stc; this
# wrapper runs it against a built HEX, parses the snapshots, and turns them into
# PASS/FAIL. It deliberately mirrors run_gpsim_test.sh's structure.
#
# Usage:
#   run_gpsim_power_on_pressed.sh <hexfile>
#
#   <hexfile>   a built PIC HEX, for example
#               build_pic10f322/bypass-pic10f322-cd4053_simple.hex. Only RA0/RA3
#               are asserted -- identical across all three variants -- so no
#               per-variant control-pin pattern is needed here.
#
# Exit status: 0 = all checks passed (or gpsim not installed -> skipped); 1 = a
# check failed or gpsim/the HEX could not be run.
#
# Pins (src/bypass_pins_pic10f322.h): RA3 = footswitch (1=released, 0=pressed),
# RA0 = status LED (LATA bit0; 1=ENGAGED, 0=BYPASS).

set -u

HEX="${1:?usage: run_gpsim_power_on_pressed.sh <hexfile>}"

# Scaffolding shared with run_gpsim_test.sh. Checked before sourcing: `.` on a
# missing file returns non-zero but does NOT abort a script without `set -e`, so
# an unguarded source runs on with every helper undefined. Today `set -u` would
# stop it a few lines later on an unbound $PROC -- but only because the next line
# happens to use a variable this helper defines, which is an accident of line
# order, not a contract. Check explicitly, and say what is actually wrong instead
# of emitting "command not found" for gpsim_run.
COMMON="$(dirname "$0")/gpsim_wrapper_common.sh"
if [ ! -r "$COMMON" ]; then
	echo "FAIL: missing shared gpsim wrapper helper: $COMMON"
	exit 1
fi
# shellcheck source=test/pic/gpsim_wrapper_common.sh
. "$COMMON" || { echo "FAIL: could not source $COMMON"; exit 1; }

# This scenario's stimulus IS byte-identical for the PIC10F320 and PIC10F322 --
# same pin name, same instruction cadence -- so those two lanes share it and the
# default below is all either needs. It stopped being universal with the
# PIC12F675, whose footswitch is a different pin and whose tick is a different
# number of cycles, so an override channel now exists for a part that needs its
# own. PIC_GPSIM_PON_STC is separate from run_gpsim_test.sh's PIC_GPSIM_STC on
# purpose: one variable naming "the stimulus" for two scenarios is how a lane
# ends up running the toggle script through the power-on wrapper, which would
# fail on missing snapshots rather than on anything real.
STC="${PIC_GPSIM_PON_STC:-$(dirname "$0")/power_on_pressed.stc}"

gpsim_run "$HEX" "$STC" "power-on-pressed gpsim test"

echo "gpsim power-on-pressed test: $HEX (proc $PROC)"

# Gather snapshots.
hd_porta=$(parse PON_HELD     "$GPSIM_PORT_REG");  hd_lata=$(parse PON_HELD     "$GPSIM_LATCH_REG")
rl_porta=$(parse PON_RELEASED "$GPSIM_PORT_REG");  rl_lata=$(parse PON_RELEASED "$GPSIM_LATCH_REG")
en_porta=$(parse PON_ENGAGED  "$GPSIM_PORT_REG");  en_lata=$(parse PON_ENGAGED  "$GPSIM_LATCH_REG")

# Guard: did gpsim actually produce all the snapshots?
gpsim_require_snapshots "$hd_porta" "$hd_lata" "$rl_porta" "$rl_lata" \
	"$en_porta" "$en_lata"

note "PON_HELD"     "$(snapshot "$hd_porta" "$hd_lata")"
note "PON_RELEASED" "$(snapshot "$rl_porta" "$rl_lata")"
note "PON_ENGAGED"  "$(snapshot "$en_porta" "$en_lata")"

# --- assertions ---
# Register names, bit masks and pin labels come from the part's identity fragment
# (see gpsim_wrapper_common.sh); only the scenario is written here.
#
# 1. Switch HELD at power-on: the device comes up BYPASS (LED off) and the held
#    switch does NOT spuriously engage; footswitch reads pressed. This is the
#    debounce_init_context(PIN_STATE_LOW) RELEASE-wait branch.
[ "$(bit "$hd_lata" "$GPSIM_LED_MASK")"  = 0 ] && pass "PON_HELD: LED off (held switch did not engage)" || fail "PON_HELD: LED ($GPSIM_LED_LABEL) should be off, $GPSIM_LATCH_REG=$hd_lata"
[ "$(bit "$hd_porta" "$GPSIM_FOOTSW_MASK")" = 0 ] && pass "PON_HELD: footswitch pressed ($GPSIM_FOOTSW_LABEL=0)"           || fail "PON_HELD: $GPSIM_FOOTSW_LABEL should read pressed (low), $GPSIM_PORT_REG=$hd_porta"

# 2. Releasing the power-on-held switch must NOT toggle: still BYPASS (LED off),
#    footswitch now released. The lockout simply drains and re-arms.
[ "$(bit "$rl_lata" "$GPSIM_LED_MASK")"  = 0 ] && pass "PON_RELEASED: still bypass (release did not toggle)" || fail "PON_RELEASED: LED ($GPSIM_LED_LABEL) should be off, $GPSIM_LATCH_REG=$rl_lata"
[ "$(bit "$rl_porta" "$GPSIM_FOOTSW_MASK")" = 1 ] && pass "PON_RELEASED: footswitch released ($GPSIM_FOOTSW_LABEL=1)"           || fail "PON_RELEASED: $GPSIM_FOOTSW_LABEL should read released (high), $GPSIM_PORT_REG=$rl_porta"

# 3. A fresh press AFTER release is the first real press -> toggles to ENGAGED
#    (LED on), and the effect latches on once the switch is released again.
[ "$(bit "$en_lata" "$GPSIM_LED_MASK")"  = 1 ] && pass "PON_ENGAGED: LED on (fresh press toggled, latched)" || fail "PON_ENGAGED: LED ($GPSIM_LED_LABEL) should be on, $GPSIM_LATCH_REG=$en_lata"
[ "$(bit "$en_porta" "$GPSIM_FOOTSW_MASK")" = 1 ] && pass "PON_ENGAGED: footswitch released ($GPSIM_FOOTSW_LABEL=1)"           || fail "PON_ENGAGED: $GPSIM_FOOTSW_LABEL should read released (high), $GPSIM_PORT_REG=$en_porta"

gpsim_verdict "$HEX"
