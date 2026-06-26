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
#   <hexfile>   a built PIC HEX (build_pic/bypass_<v>_pic10f322.hex). Only RA0/RA3
#               are asserted -- identical across all three variants -- so no
#               per-variant control-pin pattern is needed here.
#
# Exit status: 0 = all checks passed (or gpsim not installed -> skipped); 1 = a
# check failed or gpsim/the HEX could not be run.
#
# Pins (src/bypass_pins_pic10f32x.h): RA3 = footswitch (1=released, 0=pressed),
# RA0 = status LED (LATA bit0; 1=ENGAGED, 0=BYPASS).

set -u

HEX="${1:?usage: run_gpsim_power_on_pressed.sh <hexfile>}"

GPSIM="${GPSIM:-gpsim}"
PROC="${PIC_GPSIM_PROC:-p10f322}"
STC="$(dirname "$0")/power_on_pressed.stc"

if ! command -v "$GPSIM" >/dev/null 2>&1; then
    echo "gpsim not installed; skipping power-on-pressed gpsim test for $HEX"
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

out=$(timeout -s KILL 60 "$GPSIM" -i -p"$PROC" "$HEX" -c "$STC" </dev/null 2>&1)

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

echo "gpsim power-on-pressed test: $HEX (proc $PROC)"

# Gather snapshots.
hd_porta=$(parse PON_HELD     porta);  hd_lata=$(parse PON_HELD     lata)
rl_porta=$(parse PON_RELEASED porta);  rl_lata=$(parse PON_RELEASED lata)
en_porta=$(parse PON_ENGAGED  porta);  en_lata=$(parse PON_ENGAGED  lata)

# Guard: did gpsim actually produce all the snapshots?
if [ -z "$hd_lata" ] || [ -z "$rl_lata" ] || [ -z "$en_lata" ] || \
   [ -z "$hd_porta" ] || [ -z "$rl_porta" ] || [ -z "$en_porta" ]; then
    echo "FAIL: could not parse gpsim snapshots (gpsim run incomplete). Output was:"
    printf '%s\n' "$out"
    exit 1
fi

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

if [ "$fails" -ne 0 ]; then
    echo "RESULT: $fails check(s) FAILED for $HEX"
    exit 1
fi
echo "RESULT: PASS ($HEX)"
exit 0
