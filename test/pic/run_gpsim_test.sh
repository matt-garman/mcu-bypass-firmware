#!/usr/bin/env bash
#
# Drive a PIC10F32x footswitch in gpsim and assert PORTA/LATA at five checkpoints
# (four settled + one mid-debounce tick-cadence check). The default companion
# script is test/pic/footswitch_toggle.stc; PIC_GPSIM_STC selects a chip-specific
# stimulus when instruction cadence differs. This wrapper runs it against a
# built HEX, parses the snapshots, and turns them into PASS/FAIL.
#
# Usage:
#   run_gpsim_test.sh <hexfile> [expected_engaged_lata_hex] [expected_bypass_lata_hex]
#
#   <hexfile>                 a built PIC HEX, for example
#                             build_pic10f322/bypass-pic10f322-cd4053_simple.hex
#   expected_engaged_lata_hex optional: the FULL LATA value when ENGAGED for this
#                             variant (cd4053_simple=0x3, cd4053_with_mute=0x7,
#                             tq2_l2_5v_relay=0x1). When
#                             given, it is asserted in addition to the universal
#                             LED-bit checks; when omitted, only the LED bit (RA0)
#                             and footswitch (RA3) behaviour is asserted.
#   expected_bypass_lata_hex  optional: the FULL LATA value in BYPASS for this
#                             variant. Defaults to 0x0, correct for every current
#                             variant: the CD4053 control pins settle LOW in
#                             bypass and relay coils settle low.
#
# Exit status: 0 = all checks passed (or gpsim not installed -> skipped); 1 = a
# check failed or gpsim/the HEX could not be run.
#
# Pins (src/bypass_pins_pic10f322.h): RA3 = footswitch (1=released, 0=pressed),
# RA0 = status LED (LATA bit0; 1=ENGAGED, 0=BYPASS).

set -u

HEX="${1:?usage: run_gpsim_test.sh <hexfile> [expected_engaged_lata_hex] [expected_bypass_lata_hex]}"
EXP_ENGAGED_LATA="${2:-}"
EXP_BYPASS_LATA="${3:-0x0}"

# Scaffolding shared with run_gpsim_power_on_pressed.sh. Checked before sourcing:
# `.` on a missing file returns non-zero but does NOT abort a script without
# `set -e`, so an unguarded source runs on with every helper undefined. Today
# `set -u` would stop it a few lines later on an unbound $PROC -- but only
# because the next line happens to use a variable this helper defines, which is
# an accident of line order, not a contract. Check explicitly, and say what is
# actually wrong instead of emitting "command not found" for gpsim_run.
COMMON="$(dirname "$0")/gpsim_wrapper_common.sh"
if [ ! -r "$COMMON" ]; then
	echo "FAIL: missing shared gpsim wrapper helper: $COMMON"
	exit 1
fi
# shellcheck source=test/pic/gpsim_wrapper_common.sh
. "$COMMON" || { echo "FAIL: could not source $COMMON"; exit 1; }

STC="${PIC_GPSIM_STC:-$(dirname "$0")/footswitch_toggle.stc}"

gpsim_run "$HEX" "$STC" "gpsim register-level test"

echo "gpsim register-level test: $HEX (proc $PROC)"

# Gather snapshots.
ib_porta=$(parse INIT_BYPASS porta);  ib_lata=$(parse INIT_BYPASS lata)
pe_porta=$(parse PRESS1_EARLY porta); pe_lata=$(parse PRESS1_EARLY lata)
p1_porta=$(parse PRESS1_LOW  porta); p1_lata=$(parse PRESS1_LOW lata)
en_porta=$(parse ENGAGED     porta);  en_lata=$(parse ENGAGED     lata)
ba_porta=$(parse BYPASS_AGAIN porta); ba_lata=$(parse BYPASS_AGAIN lata)

# Guard: did gpsim actually produce all the snapshots?
gpsim_require_snapshots "$ib_porta" "$ib_lata" "$pe_porta" "$pe_lata" \
	"$p1_porta" "$p1_lata" "$en_porta" "$en_lata" "$ba_porta" "$ba_lata"

note "INIT_BYPASS"  "porta=$ib_porta lata=$ib_lata"
note "PRESS1_EARLY" "porta=$pe_porta lata=$pe_lata"
note "PRESS1_LOW"   "porta=$p1_porta lata=$p1_lata"
note "ENGAGED"      "porta=$en_porta lata=$en_lata"
note "BYPASS_AGAIN" "porta=$ba_porta lata=$ba_lata"

# --- assertions ---
# 1. Power-on default is BYPASS: LED (RA0) off, footswitch (RA3) released.
[ "$(bit "$ib_lata" 0x1)"  = 0 ] && pass "INIT: LED off (bypass)"          || fail "INIT: LED (RA0) should be off, lata=$ib_lata"
[ $(( ib_lata )) -eq $(( EXP_BYPASS_LATA )) ] && pass "INIT: full LATA == $EXP_BYPASS_LATA (bypass control pins)" || fail "INIT: LATA should be $EXP_BYPASS_LATA in bypass, got $ib_lata"
[ "$(bit "$ib_porta" 0x8)" = 1 ] && pass "INIT: footswitch released (RA3=1)" || fail "INIT: RA3 should read released (high), porta=$ib_porta"

# 1b. Cadence check: ~6 ms into press #1, a correctly gated 1 ms loop is still
#     mid-debounce (it does not toggle until ~8 ms / 8 separated samples), so the
#     LED must remain off while RA3 reads pressed. A stuck TMR2IF/polling fault
#     free-runs and crosses the 8-sample threshold ~2 ms too early (~4.2 ms in).
[ "$(bit "$pe_porta" 0x8)" = 0 ] && pass "PRESS1_EARLY: footswitch pressed (RA3=0)" || fail "PRESS1_EARLY: RA3 should read pressed (low), porta=$pe_porta"
[ "$(bit "$pe_lata" 0x1)"  = 0 ] && pass "PRESS1_EARLY: LED still off (tick cadence intact)" || fail "PRESS1_EARLY: LED (RA0) on too early (~6 ms in), lata=$pe_lata"

# 2. During press #1 the footswitch reads as pressed (RA3 low) -> input path works.
[ "$(bit "$p1_porta" 0x8)" = 0 ] && pass "PRESS1: footswitch pressed (RA3=0)" || fail "PRESS1: RA3 should read pressed (low), porta=$p1_porta"

# 2b. The effect must toggle ON the press: this checkpoint is well past the ~8 ms
#     PRESSED_THRESH window, so a correct firmware has already latched ENGAGED
#     (LED on) while the switch is still held. This distinguishes "toggle on
#     press" (correct) from "toggle on release" -- e.g. an inverted footswitch
#     read -- which the settled ENGAGED / BYPASS_AGAIN checkpoints alone CANNOT
#     tell apart: the stimulus presses then releases, so both firmwares read
#     ENGAGED by the time those later checkpoints sample.
[ "$(bit "$p1_lata" 0x1)" = 1 ] && pass "PRESS1: LED on (toggled on the press)" || fail "PRESS1: LED (RA0) should be on mid-press (toggle-on-press), lata=$p1_lata"

# 3. After the momentary press #1, the effect LATCHES ENGAGED (LED on) even
#    though the footswitch is released again.
[ "$(bit "$en_lata" 0x1)"  = 1 ] && pass "ENGAGED: LED on (latched)"        || fail "ENGAGED: LED (RA0) should be on, lata=$en_lata"
[ "$(bit "$en_porta" 0x8)" = 1 ] && pass "ENGAGED: footswitch released (RA3=1)" || fail "ENGAGED: RA3 should read released (high), porta=$en_porta"
if [ -n "$EXP_ENGAGED_LATA" ]; then
    if [ $(( en_lata )) -eq $(( EXP_ENGAGED_LATA )) ]; then
        pass "ENGAGED: full LATA == $EXP_ENGAGED_LATA (variant control pins)"
    else
        fail "ENGAGED: LATA should be $EXP_ENGAGED_LATA for this variant, got $en_lata"
    fi
fi

# 4. A second momentary press toggles back to BYPASS (LED off) -> re-arm works.
#    By this checkpoint the switch has been released again, so RA3 reads high.
[ "$(bit "$ba_lata" 0x1)"  = 0 ] && pass "BYPASS_AGAIN: LED off (toggled back)"        || fail "BYPASS_AGAIN: LED (RA0) should be off, lata=$ba_lata"
[ $(( ba_lata )) -eq $(( EXP_BYPASS_LATA )) ] && pass "BYPASS_AGAIN: full LATA == $EXP_BYPASS_LATA (bypass control pins)" || fail "BYPASS_AGAIN: LATA should be $EXP_BYPASS_LATA in bypass, got $ba_lata"
[ "$(bit "$ba_porta" 0x8)" = 1 ] && pass "BYPASS_AGAIN: footswitch released (RA3=1)" || fail "BYPASS_AGAIN: RA3 should read released (high), porta=$ba_porta"

gpsim_verdict "$HEX"
