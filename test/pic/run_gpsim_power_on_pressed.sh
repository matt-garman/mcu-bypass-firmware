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
#   <hexfile>   a built PIC HEX (build_pic10f322/bypass_<v>_pic10f322.hex). Only RA0/RA3
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

# Unlike run_gpsim_test.sh there is deliberately no PIC_GPSIM_STC override here:
# the two-press toggle needs a chip-specific stimulus because its mid-debounce
# cadence checkpoint depends on instruction timing, whereas this scenario's
# stimulus is byte-identical for the PIC10F320 and PIC10F322 and is therefore
# shared. PIC10F322_GPSIM_PROC is still honoured (via the shared helper), so the same
# stimulus runs on either chip. See the pic10f320-test-gpsim recipe in the Makefile,
# which asserts this routing, and test/test_gpsim_wrappers.sh, which checks it
# behaviourally.
STC="$(dirname "$0")/power_on_pressed.stc"

gpsim_run "$HEX" "$STC" "power-on-pressed gpsim test"

echo "gpsim power-on-pressed test: $HEX (proc $PROC)"

# Gather snapshots.
hd_porta=$(parse PON_HELD     porta);  hd_lata=$(parse PON_HELD     lata)
rl_porta=$(parse PON_RELEASED porta);  rl_lata=$(parse PON_RELEASED lata)
en_porta=$(parse PON_ENGAGED  porta);  en_lata=$(parse PON_ENGAGED  lata)

# Guard: did gpsim actually produce all the snapshots?
gpsim_require_snapshots "$hd_porta" "$hd_lata" "$rl_porta" "$rl_lata" \
	"$en_porta" "$en_lata"

note "PON_HELD"     "porta=$hd_porta lata=$hd_lata"
note "PON_RELEASED" "porta=$rl_porta lata=$rl_lata"
note "PON_ENGAGED"  "porta=$en_porta lata=$en_lata"

# --- assertions ---
# 1. Switch HELD at power-on: the device comes up BYPASS (LED off) and the held
#    switch does NOT spuriously engage; footswitch reads pressed (RA3 low). This
#    is the debounce_init_context(PIN_STATE_LOW) RELEASE-wait branch.
[ "$(bit "$hd_lata" 0x1)"  = 0 ] && pass "PON_HELD: LED off (held switch did not engage)" || fail "PON_HELD: LED (RA0) should be off, lata=$hd_lata"
[ "$(bit "$hd_porta" 0x8)" = 0 ] && pass "PON_HELD: footswitch pressed (RA3=0)"           || fail "PON_HELD: RA3 should read pressed (low), porta=$hd_porta"

# 2. Releasing the power-on-held switch must NOT toggle: still BYPASS (LED off),
#    footswitch now released (RA3 high). The lockout simply drains and re-arms.
[ "$(bit "$rl_lata" 0x1)"  = 0 ] && pass "PON_RELEASED: still bypass (release did not toggle)" || fail "PON_RELEASED: LED (RA0) should be off, lata=$rl_lata"
[ "$(bit "$rl_porta" 0x8)" = 1 ] && pass "PON_RELEASED: footswitch released (RA3=1)"           || fail "PON_RELEASED: RA3 should read released (high), porta=$rl_porta"

# 3. A fresh press AFTER release is the first real press -> toggles to ENGAGED
#    (LED on), and the effect latches on once the switch is released again.
[ "$(bit "$en_lata" 0x1)"  = 1 ] && pass "PON_ENGAGED: LED on (fresh press toggled, latched)" || fail "PON_ENGAGED: LED (RA0) should be on, lata=$en_lata"
[ "$(bit "$en_porta" 0x8)" = 1 ] && pass "PON_ENGAGED: footswitch released (RA3=1)"           || fail "PON_ENGAGED: RA3 should read released (high), porta=$en_porta"

gpsim_verdict "$HEX"
