#!/usr/bin/env bash
set -euo pipefail

# Host-only source contract for the per-part watchdog note the libgpsim
# fault-injection harness prints into retained evidence (v0.9.9-polish T1/T4).
#
# WHY THIS EXISTS. The shared core header once HARDCODED the PIC10F32x note
# (`gpsim WDT@WDTPS=0x08 ~1.057s ... 256ms silicon`) and printed it for EVERY
# part. The PIC12F675 has no WDTCON: its prescaler is OPTION_REG, and at 0x0C
# (1:16) gpsim models ~288 ms with a 160 ms datasheet floor. The wrong note
# therefore reached the retained v0.9.9 PIC12F675 fault evidence. Nothing louder
# caught it because the fault VERDICT never depends on the period -- the gate
# asserts a recovery reset within a deliberately generous window -- so only an
# evidence-accuracy check closes it.
# name-contract: exempt (PIC_FAULT_WDT_NOTE below is a C macro, not a make var)
# The fix makes the note a per-adapter `PIC_FAULT_WDT_NOTE`, `#error`-guarded in
# the core exactly like the other required adapter defines. This regression pins
# that contract: the core must consume the macro (not bake a period into the
# banner), each adapter must define it, and each note must carry its own part's
# facts and not the other part's. It needs no toolchain -- it reads source only,
# so it runs in `make test` on any host, while the real per-part text is emitted
# for real whenever the gpsim `*-test-target-variants` fault lanes run.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CORE="$ROOT/test/pic/test_fault_pic_core.h"
ADAPT_32X="$ROOT/test/pic/test_fault_pic.cc"       # PIC10F320 + PIC10F322
ADAPT_675="$ROOT/test/pic/test_fault_pic12f675.cc" # PIC12F675
# The PIC10F320 fault lane compiles a hand-maintained VENDORED copy that
# includes the same shared core header -- so it must carry the note too, or the
# core's #error breaks the 320 build. That drift is exactly the vendored-copy
# divergence only a gpsim-equipped host would otherwise catch.
ADAPT_320="$ROOT/test/pic10f320/gpsim/test_fault_pic.cc" # PIC10F320 (vendored)
checks=0

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { checks=$((checks + 1)); }

# require the whole regex present / absent in a file
present() { grep -q -- "$2" "$1" || fail "$3"; ok; }
absent()  { ! grep -q -- "$2" "$1" || fail "$3"; ok; }
# -F variants for literals that contain regex metacharacters
presentF() { grep -qF -- "$2" "$1" || fail "$3"; ok; }
absentF()  { ! grep -qF -- "$2" "$1" || fail "$3"; ok; }

for f in "$CORE" "$ADAPT_32X" "$ADAPT_675" "$ADAPT_320"; do
	[ -f "$f" ] || fail "missing source file: $f"
	ok
done

# --- core header: consumes the macro, refuses an adapter that omits it --------
# The banner prints the note via %s, so no period literal can be baked in for
# all parts again.
presentF "$CORE" '"  %s\n"' \
	"core banner no longer prints the watchdog note via %s"
present "$CORE" 'PIC_FAULT_WDT_NOTE' \
	"core header no longer references PIC_FAULT_WDT_NOTE"
present "$CORE" '#  error "PIC_FAULT_WDT_NOTE must be defined by the part adapter"' \
	"core header lost the #error guard requiring PIC_FAULT_WDT_NOTE"
# The exact old baked banner must be gone from the core -- it belongs to the
# 10F32x adapter now, and only there.
absentF "$CORE" '~1.057s -- recovery reset, not 256ms silicon' \
	"core header still bakes the PIC10F32x watchdog note into the banner"

# --- PIC10F32x adapters (canonical + vendored 320): own note, 32x facts -------
# Both the shared test/pic adapter and the 320's vendored copy must carry the
# 32x note; the vendored one shares the core header, so a missing define breaks
# its build under the #error guard.
check_32x_note() {  # $1=adapter file  $2=label
	present  "$1" '#define PIC_FAULT_WDT_NOTE' "$2 does not define PIC_FAULT_WDT_NOTE"
	presentF "$1" 'WDTPS=0x08'    "$2 note dropped its WDTCON.WDTPS=0x08 fact"
	presentF "$1" '1.057'         "$2 note dropped its ~1.057 s modeled period"
	presentF "$1" '256ms silicon' "$2 note dropped its 256 ms silicon caveat"
	absentF  "$1" '288'           "$2 note wrongly carries the PIC12F675 ~288 ms period"
}
check_32x_note "$ADAPT_32X" "PIC10F32x adapter (test/pic)"
check_32x_note "$ADAPT_320" "PIC10F320 vendored adapter"

# --- PIC12F675 adapter: its own note, with the 12F675 facts, NOT the 32x ones -
present "$ADAPT_675" '#define PIC_FAULT_WDT_NOTE' \
	"PIC12F675 fault adapter does not define PIC_FAULT_WDT_NOTE"
presentF "$ADAPT_675" '288ms' \
	"PIC12F675 note dropped its ~288 ms modeled period"
presentF "$ADAPT_675" '160ms' \
	"PIC12F675 note dropped its 160 ms silicon floor"
presentF "$ADAPT_675" 'OPTION_REG=0x0C' \
	"PIC12F675 note dropped the OPTION_REG=0x0C prescaler fact"
# The 12F675 must not repeat the 10F32x's (wrong-for-it) facts.
absentF "$ADAPT_675" 'WDTPS' \
	"PIC12F675 note wrongly claims a WDTCON.WDTPS the part does not have"
absentF "$ADAPT_675" '256ms silicon' \
	"PIC12F675 note wrongly carries the PIC10F32x 256 ms silicon caveat"

printf 'fault-inject watchdog-note contract: %d checks, 0 failures\n' "$checks"
