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
ib_porta=$(parse INIT_BYPASS "$GPSIM_PORT_REG");  ib_lata=$(parse INIT_BYPASS "$GPSIM_LATCH_REG")
pe_porta=$(parse PRESS1_EARLY "$GPSIM_PORT_REG"); pe_lata=$(parse PRESS1_EARLY "$GPSIM_LATCH_REG")
p1_porta=$(parse PRESS1_LOW  "$GPSIM_PORT_REG"); p1_lata=$(parse PRESS1_LOW "$GPSIM_LATCH_REG")
en_porta=$(parse ENGAGED     "$GPSIM_PORT_REG");  en_lata=$(parse ENGAGED     "$GPSIM_LATCH_REG")
ba_porta=$(parse BYPASS_AGAIN "$GPSIM_PORT_REG"); ba_lata=$(parse BYPASS_AGAIN "$GPSIM_LATCH_REG")

# Guard: did gpsim actually produce all the snapshots?
gpsim_require_snapshots "$ib_porta" "$ib_lata" "$pe_porta" "$pe_lata" \
	"$p1_porta" "$p1_lata" "$en_porta" "$en_lata" "$ba_porta" "$ba_lata"

note "INIT_BYPASS"  "$(snapshot "$ib_porta" "$ib_lata")"
note "PRESS1_EARLY" "$(snapshot "$pe_porta" "$pe_lata")"
note "PRESS1_LOW"   "$(snapshot "$p1_porta" "$p1_lata")"
note "ENGAGED"      "$(snapshot "$en_porta" "$en_lata")"
note "BYPASS_AGAIN" "$(snapshot "$ba_porta" "$ba_lata")"

# --- assertions ---
# Register names, bit masks and pin labels all come from the part's identity
# fragment (see gpsim_wrapper_common.sh); only the scenario is written here.
#
# 1. Power-on default is BYPASS: LED off, footswitch released.
[ "$(bit "$ib_lata" "$GPSIM_LED_MASK")"  = 0 ] && pass "INIT: LED off (bypass)"          || fail "INIT: LED ($GPSIM_LED_LABEL) should be off, $GPSIM_LATCH_REG=$ib_lata"
[ $(( ib_lata & GPSIM_OUTPUT_MASK )) -eq $(( EXP_BYPASS_LATA )) ] && pass "INIT: full $GPSIM_LATCH_LABEL == $EXP_BYPASS_LATA (bypass control pins)" || fail "INIT: $GPSIM_LATCH_LABEL should be $EXP_BYPASS_LATA in bypass, got $ib_lata"
[ "$(bit "$ib_porta" "$GPSIM_FOOTSW_MASK")" = 1 ] && pass "INIT: footswitch released ($GPSIM_FOOTSW_LABEL=1)" || fail "INIT: $GPSIM_FOOTSW_LABEL should read released (high), $GPSIM_PORT_REG=$ib_porta"

# 1b. Cadence check: partway into press #1, a correctly gated tick loop is still
#     mid-debounce (it does not toggle until PRESSED_THRESH separated samples
#     have accumulated), so the LED must remain off while the switch reads
#     pressed. A stuck tick-flag/polling fault free-runs and crosses the
#     threshold within a few hundred instruction cycles of the edge -- far
#     earlier than this checkpoint. Each part's stimulus places the checkpoint
#     between those two instants; see the .stc for its arithmetic.
[ "$(bit "$pe_porta" "$GPSIM_FOOTSW_MASK")" = 0 ] && pass "PRESS1_EARLY: footswitch pressed ($GPSIM_FOOTSW_LABEL=0)" || fail "PRESS1_EARLY: $GPSIM_FOOTSW_LABEL should read pressed (low), $GPSIM_PORT_REG=$pe_porta"
[ "$(bit "$pe_lata" "$GPSIM_LED_MASK")"  = 0 ] && pass "PRESS1_EARLY: LED still off (tick cadence intact)" || fail "PRESS1_EARLY: LED ($GPSIM_LED_LABEL) on too early, $GPSIM_LATCH_REG=$pe_lata"

# 2. During press #1 the footswitch reads as pressed -> input path works.
[ "$(bit "$p1_porta" "$GPSIM_FOOTSW_MASK")" = 0 ] && pass "PRESS1: footswitch pressed ($GPSIM_FOOTSW_LABEL=0)" || fail "PRESS1: $GPSIM_FOOTSW_LABEL should read pressed (low), $GPSIM_PORT_REG=$p1_porta"

# 2b. The effect must toggle ON the press: this checkpoint is well past the
#     PRESSED_THRESH window, so a correct firmware has already latched ENGAGED
#     (LED on) while the switch is still held. This distinguishes "toggle on
#     press" (correct) from "toggle on release" -- e.g. an inverted footswitch
#     read -- which the settled ENGAGED / BYPASS_AGAIN checkpoints alone CANNOT
#     tell apart: the stimulus presses then releases, so both firmwares read
#     ENGAGED by the time those later checkpoints sample.
#     Only the LED BIT is asserted here, never the full output pattern: the mute
#     and relay variants are mid-actuation at this instant and have not reached
#     their settled pattern yet.
[ "$(bit "$p1_lata" "$GPSIM_LED_MASK")" = 1 ] && pass "PRESS1: LED on (toggled on the press)" || fail "PRESS1: LED ($GPSIM_LED_LABEL) should be on mid-press (toggle-on-press), $GPSIM_LATCH_REG=$p1_lata"

# 3. After the momentary press #1, the effect LATCHES ENGAGED (LED on) even
#    though the footswitch is released again.
[ "$(bit "$en_lata" "$GPSIM_LED_MASK")"  = 1 ] && pass "ENGAGED: LED on (latched)"        || fail "ENGAGED: LED ($GPSIM_LED_LABEL) should be on, $GPSIM_LATCH_REG=$en_lata"
[ "$(bit "$en_porta" "$GPSIM_FOOTSW_MASK")" = 1 ] && pass "ENGAGED: footswitch released ($GPSIM_FOOTSW_LABEL=1)" || fail "ENGAGED: $GPSIM_FOOTSW_LABEL should read released (high), $GPSIM_PORT_REG=$en_porta"
if [ -n "$EXP_ENGAGED_LATA" ]; then
    if [ $(( en_lata & GPSIM_OUTPUT_MASK )) -eq $(( EXP_ENGAGED_LATA )) ]; then
        pass "ENGAGED: full $GPSIM_LATCH_LABEL == $EXP_ENGAGED_LATA (variant control pins)"
    else
        fail "ENGAGED: $GPSIM_LATCH_LABEL should be $EXP_ENGAGED_LATA for this variant, got $en_lata"
    fi
fi

# 4. A second momentary press toggles back to BYPASS (LED off) -> re-arm works.
#    By this checkpoint the switch has been released again.
[ "$(bit "$ba_lata" "$GPSIM_LED_MASK")"  = 0 ] && pass "BYPASS_AGAIN: LED off (toggled back)"        || fail "BYPASS_AGAIN: LED ($GPSIM_LED_LABEL) should be off, $GPSIM_LATCH_REG=$ba_lata"
[ $(( ba_lata & GPSIM_OUTPUT_MASK )) -eq $(( EXP_BYPASS_LATA )) ] && pass "BYPASS_AGAIN: full $GPSIM_LATCH_LABEL == $EXP_BYPASS_LATA (bypass control pins)" || fail "BYPASS_AGAIN: $GPSIM_LATCH_LABEL should be $EXP_BYPASS_LATA in bypass, got $ba_lata"
[ "$(bit "$ba_porta" "$GPSIM_FOOTSW_MASK")" = 1 ] && pass "BYPASS_AGAIN: footswitch released ($GPSIM_FOOTSW_LABEL=1)" || fail "BYPASS_AGAIN: $GPSIM_FOOTSW_LABEL should read released (high), $GPSIM_PORT_REG=$ba_porta"

gpsim_verdict "$HEX"
