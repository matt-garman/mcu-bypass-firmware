#!/usr/bin/env bash
#
# Drive the PIC10F322 footswitch in gpsim and assert PORTA/LATA at five
# checkpoints (four settled + one mid-debounce tick-cadence check). The companion
# script test/pic/footswitch_toggle.stc contains the gpsim stimulus + register
# snapshots; this wrapper runs it against a built HEX, parses the snapshots, and
# turns them into PASS/FAIL.
#
# Usage:
#   run_gpsim_test.sh <hexfile> [expected_engaged_lata_hex] [expected_bypass_lata_hex]
#
#   <hexfile>                 a built PIC HEX (build_pic/bypass_<v>_pic10f322.hex)
#   expected_engaged_lata_hex optional: the FULL LATA value when ENGAGED for this
#                             variant (cd4053=0x3, mute=0x7, relay=0x1). When
#                             given, it is asserted in addition to the universal
#                             LED-bit checks; when omitted, only the LED bit (RA0)
#                             and footswitch (RA3) behaviour is asserted.
#   expected_bypass_lata_hex  optional: the FULL LATA value in BYPASS for this
#                             variant. Defaults to 0x0, correct for every current
#                             variant: cd4053/mute control pins settle LOW in
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

GPSIM="${GPSIM:-gpsim}"
GPSIM_TIMEOUT_SECONDS="${GPSIM_TIMEOUT_SECONDS:-60}"
PROC="${PIC_GPSIM_PROC:-p10f322}"
STC="$(dirname "$0")/footswitch_toggle.stc"

if ! command -v "$GPSIM" >/dev/null 2>&1; then
    echo "gpsim not installed; skipping gpsim register-level test for $HEX"
    exit 0
fi
if [ ! -f "$HEX" ]; then
    echo "FAIL: hex not found: $HEX"
    exit 1
fi
if [ ! -f "$STC" ]; then
    echo "FAIL: gpsim script not found: $STC"
    exit 1
fi

if out=$(timeout -s KILL "$GPSIM_TIMEOUT_SECONDS" \
		"$GPSIM" -i -p"$PROC" "$HEX" -c "$STC" </dev/null 2>&1); then
	:
else
	rc=$?
	echo "FAIL: gpsim exited with status $rc for $HEX. Output was:"
	printf '%s\n' "$out"
	exit 1
fi

# Pull the value of register $2 at the checkpoint labelled $1 out of gpsim's
# output (lines look like "lata = 0x3", possibly behind a "**gpsim> " prompt).
parse() {
    printf '%s\n' "$out" | awk -v lbl="$1" -v reg="$2" '
        index($0, "===" lbl "===") { active = 1; next }
        active && index($0, "===")  { active = 0 }
        active && match($0, reg " = 0x[0-9a-fA-F]+") {
            s = substr($0, RSTART, RLENGTH); sub(reg " = ", "", s);
            print s; exit
        }
    '
}

fails=0
note() { printf '  %-14s %s\n' "$1" "$2"; }
fail() { echo "  FAIL: $1"; fails=$((fails + 1)); }
pass() { echo "  ok:   $1"; }

# Helper: bit test on a hex value. $1=hexval $2=bitmask(hex) -> echoes 1 if set.
bit() { echo $(( ( $1 & $2 ) != 0 )); }

echo "gpsim register-level test: $HEX (proc $PROC)"

# Gather snapshots.
ib_porta=$(parse INIT_BYPASS porta);  ib_lata=$(parse INIT_BYPASS lata)
pe_porta=$(parse PRESS1_EARLY porta); pe_lata=$(parse PRESS1_EARLY lata)
p1_porta=$(parse PRESS1_LOW  porta); p1_lata=$(parse PRESS1_LOW lata)
en_porta=$(parse ENGAGED     porta);  en_lata=$(parse ENGAGED     lata)
ba_porta=$(parse BYPASS_AGAIN porta); ba_lata=$(parse BYPASS_AGAIN lata)

# Guard: did gpsim actually produce all the snapshots?
if [ -z "$ib_lata" ] || [ -z "$pe_porta" ] || [ -z "$pe_lata" ] || \
   [ -z "$p1_porta" ] || [ -z "$p1_lata" ] || [ -z "$en_lata" ] || \
   [ -z "$ba_lata" ] || [ -z "$ba_porta" ]; then
    echo "FAIL: could not parse gpsim snapshots (gpsim run incomplete). Output was:"
    printf '%s\n' "$out"
    exit 1
fi

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

if [ "$fails" -ne 0 ]; then
    echo "RESULT: $fails check(s) FAILED for $HEX"
    exit 1
fi
echo "RESULT: PASS ($HEX)"
exit 0
