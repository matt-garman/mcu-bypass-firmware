#!/usr/bin/env bash
# Assert that the firmware's compile-time guards actually FIRE when the thing
# they guard is violated.
#
# WHY THIS EXISTS. The `static_assert`s in the config headers and MCU shells are
# checked on every build, but only in the sense that they do not fire. Nothing
# in the suite proves they *would*. A guard that is still enforcing an invariant
# and a guard that has been quietly defused look exactly alike from the outside:
# both are silent, and every build stays green. Reorder a header so the
# constants arrive after the check, drop an `#include`, weaken `>` to `>=`,
# comment one out during a debugging session -- the build does not notice, and
# neither does any test. This is the same silent-severance class as the Makefile
# name contract, in C rather than in make.
#
# HOW. Copy src/ to a throwaway tree, break ONE input to a guard, compile, and
# require the build to fail with THAT guard's own message. Mechanically the
# mutation harness's idea (test/run_mutation_tests.sh) applied to compile
# failure rather than test failure.
#
# The inputs are broken, never the guards. A mutation that edited the
# `static_assert` line itself would prove only that the compiler implements
# `static_assert`. Breaking a threshold, a pin ordinal, a timer constant or a
# build flag is what a real regression looks like, and the guard's job is to
# catch it there.
#
# THREE THINGS THAT MUST HOLD or the whole exercise proves nothing, each checked
# below rather than assumed:
#   1. the UNMUTATED tree compiles clean -- otherwise every "it failed" below is
#      measuring something else;
#   2. each mutation actually CHANGES its file -- a sed that silently stops
#      matching (an indent change is enough; `TIMER0_OCR0A_1MS` is defined with
#      leading whitespace inside an #if, and the first draft of this file missed
#      it) turns a mutation into a second copy of the control;
#   3. the failure carries the guard's OWN message -- a mutant that fails to
#      compile for an unrelated reason would otherwise score as a pass.
#
# SCOPE, stated so the next reader does not over-trust it: guard mutations compile
# the classic-AVR lane only, with avr-gcc. The shared invariants in
# bypass_compile_checks.h are MCU-neutral and reach every modular shell through a
# direct include. That include topology and its negative fixtures are checked
# below without target tools; the AVR-XT and PIC shell-local pin/timer guards are
# NOT compiled here and would need their own toolchains.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# Overridable ONLY so this file's own failure modes can be exercised against a
# doctored copy of src/ -- removing a guard, rewording its message, reindenting
# a #define out from under a mutation -- without editing the firmware to test
# the thing that watches the firmware. The Make target never sets it.
SRC=${STATIC_ASSERT_SRC:-$ROOT/src}
checks=0

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/test-static-assert.XXXXXX")
trap 'rm -rf "$work"' EXIT

# A pristine copy per check, so one doctored include or compile mutation can
# never leak into the next.
plant() {
	local tree=$1
	rm -rf "$tree"
	mkdir -p "$tree"
	cp "$SRC"/*.c "$SRC"/*.h "$tree/"
}

# Read the real build's compiler and flags rather than restating them: a guard
# proven under flags nobody ships is not proven. print-<VAR> is itself held to
# the Makefile's vocabulary by the name-contract gate.
read_var() {
	(
		unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL
		make -s -C "$ROOT" "print-$1"
	)
}
CC=$(read_var CC)
CFLAGS=$(read_var CFLAGS)
[ -n "$CC" ] && [ -n "$CFLAGS" ] \
	|| fail "print-CC / print-CFLAGS came back empty -- cannot compile anything"
[[ "$CFLAGS" == *-fshort-enums* ]] \
	|| fail "CFLAGS no longer carries -fshort-enums; the enum-size guards below cannot be exercised as written"
checks=$((checks + 1))

# ---------------------------------------------------------------------------
# The shared invariants must actually be shared.
# ---------------------------------------------------------------------------
# bypass_compile_checks.h exists so the threshold contract "lives in ONE place
# and cannot drift between shells". That is a claim about which files include
# it, and nothing enforced it. A shell that stops including it keeps building.
#
# bypass_mcu_pic10f320.c is listed as carrying its OWN copy of the five
# invariants (and its own DEBOUNCE_COUNTER_MAX) rather than including the shared
# header -- recorded here so the divergence is visible and counted, not so it is
# blessed. A fifth shell that does neither fails this check.
SHELLS_WITH_OWN_COPY="bypass_mcu_pic10f320.c"
# "Active" here is deliberately lexical: the # is the first non-whitespace
# token and the direct include consumes the complete line. Proving reach through
# conditional preprocessing belongs to each real target toolchain; the release
# server runs semantic negative compiles for AVR-XT and PIC10F322.
ACTIVE_SHARED_INCLUDE_RE='^[[:space:]]*#[[:space:]]*include[[:space:]]+"bypass_compile_checks[.]h"[[:space:]]*$'
find_shells_missing_shared_checks() {
	local source_root=$1 shell base
	local -a shells=("$source_root"/bypass_mcu_*.c)
	ACTIVE_SHARED_CHECK_SHELLS=()
	MISSING_SHARED_CHECK_SHELLS=()
	[ -e "${shells[0]}" ] \
		|| fail "no MCU shells found under $source_root"
	for shell in "${shells[@]}"; do
		base=${shell##*/}
		if grep -Eq -- "$ACTIVE_SHARED_INCLUDE_RE" "$shell"; then
			ACTIVE_SHARED_CHECK_SHELLS+=("$base")
			continue
		fi
		[[ " $SHELLS_WITH_OWN_COPY " == *" $base "* ]] && continue
		MISSING_SHARED_CHECK_SHELLS+=("$base")
	done
}

find_shells_missing_shared_checks "$SRC"
[ "${#MISSING_SHARED_CHECK_SHELLS[@]}" -eq 0 ] \
	|| fail "these MCU shells neither actively include bypass_compile_checks.h nor are recorded as carrying their own copy, so the threshold contract does not reach them: ${MISSING_SHARED_CHECK_SHELLS[*]}"
checks=$((checks + 1))

# The lexical contract must reject the exact false-positive that prompted this
# gate hardening. Exercise every modular shell independently against the same
# function used above; requiring the exact basename prevents one unrelated
# missing include from satisfying every case. Derive this list from the active
# direct includes classified above so a new modular shell cannot silently miss
# the negative fixture while still passing the positive topology sweep.
SHARED_CHECK_SHELLS=("${ACTIVE_SHARED_CHECK_SHELLS[@]}")
[ "${#SHARED_CHECK_SHELLS[@]}" -gt 0 ] \
	|| fail "no MCU shell actively includes bypass_compile_checks.h"
for base in "${SHARED_CHECK_SHELLS[@]}"; do
	tree="$work/include-$base"
	plant "$tree"
	before=$(sha256sum "$tree/$base" | cut -d' ' -f1)
	sed -i -E \
		's@^([[:space:]]*)#[[:space:]]*include[[:space:]]+"bypass_compile_checks[.]h"[[:space:]]*$@\1// #include "bypass_compile_checks.h"@' \
		"$tree/$base"
	after=$(sha256sum "$tree/$base" | cut -d' ' -f1)
	[ "$before" != "$after" ] \
		|| fail "commented-include fixture changed nothing in $base"
	checks=$((checks + 1))

	find_shells_missing_shared_checks "$tree"
	if [ "${#MISSING_SHARED_CHECK_SHELLS[@]}" -ne 1 ] \
			|| [ "${MISSING_SHARED_CHECK_SHELLS[0]:-}" != "$base" ]; then
		fail "commenting the shared compile-check include in $base reported the wrong missing shells: ${MISSING_SHARED_CHECK_SHELLS[*]:-none}"
	fi
	checks=$((checks + 1))
done

# ---------------------------------------------------------------------------
# Guard census: pinned so a DELETED guard is caught even where no mutation
# reaches it.
# ---------------------------------------------------------------------------
# The mutations below prove that a guard fires. They cannot prove that every
# guard is still present: several sit in families sharing one diagnostic (three
# enum-size asserts all say "use -fshort-enums", seven pin asserts all fail the
# same build), so deleting one leaves its siblings to trip the mutation and the
# deletion scores as a pass. That is not hypothetical -- it is how the first
# version of this file behaved, and removing `sizeof(effect_state_t)` alone went
# unnoticed.
#
# Counting is the cheap complement: a mutation proves the mechanism works, the
# census proves nothing has quietly left. Adding a guard fails this too, on
# purpose -- someone then decides whether the new one needs a mutation.
#
# On bypass_compile_checks.h's five: four are reachable. PRESSED_THRESH <
# DEBOUNCE_COUNTER_MAX cannot fire while RELEASE_THRESH < DEBOUNCE_COUNTER_MAX
# and RELEASE_THRESH > PRESSED_THRESH both hold, so it is defence in depth
# against a future edit to those two rather than a guard this file can trip.
GUARD_CENSUS=(
	"bypass_compile_checks.h 5"
	"bypass_mcu_avr_classic.c 17"
	"bypass_output_cd4053_with_mute.c 1"
	"bypass_output_tq2_l2_5v_relay.c 1"
)
guards=0
for row in "${GUARD_CENSUS[@]}"; do
	read -r file want <<<"$row"
	# `|| true`: grep -c exits 1 on a count of zero, and zero is precisely the
	# case this census exists to report. Without it, set -e kills the script
	# before the message -- a silent exit where the loudest failure belongs.
	got=$(grep -cE '^[[:space:]]*static_assert\(' "$SRC/$file" || true)
	[ "$got" -eq "$want" ] \
		|| fail "$file declares $got static_assert guards, expected $want -- if one was removed, say why; if one was added, decide whether it needs a mutation below, then update this census"
	guards=$((guards + got))
	checks=$((checks + 1))
done

# ---------------------------------------------------------------------------
# Mutations.
# ---------------------------------------------------------------------------
# label | file to break | sed script | TU to compile | -D variant | expected message
#
# An empty file/sed pair means the build FLAGS are mutated instead, which is how
# -fshort-enums is exercised: dropping it is the realistic regression, and it is
# not something any edit to src/ can express.
MUTATIONS=(
	"threshold order|bypass_config.h|s/^#define RELEASE_THRESH (25U)/#define RELEASE_THRESH (8U)/|bypass_mcu_avr_classic.c|CD4053_SIMPLE|RELEASE_THRESH <= PRESSED_THRESH"
	"release floor|bypass_config.h|s/^#define RELEASE_THRESH (25U)/#define RELEASE_THRESH (0U)/|bypass_mcu_avr_classic.c|CD4053_SIMPLE|RELEASE_THRESH <= 0"
	"release ceiling|bypass_config.h|s/^#define RELEASE_THRESH (25U)/#define RELEASE_THRESH (255U)/|bypass_mcu_avr_classic.c|CD4053_SIMPLE|RELEASE_THRESH >= UINT8_MAX"
	"pressed floor|bypass_config.h|s/^#define PRESSED_THRESH (8U)/#define PRESSED_THRESH (0U)/|bypass_mcu_avr_classic.c|CD4053_SIMPLE|PRESSED_THRESH <= 0"
	"timer formula|bypass_config.h|s/^#      define TIMER0_OCR0A_1MS (149U)$/#      define TIMER0_OCR0A_1MS (150U)/|bypass_mcu_avr_classic.c|CD4053_SIMPLE|OCR0A/F_CPU mismatch"
	"pin ordinal|bypass_pins_avr_classic.h|s/^#define FOOTSW_PIN (0U)/#define FOOTSW_PIN (4U)/|bypass_mcu_avr_classic.c|CD4053_SIMPLE|FOOTSW_PIN must be PB0"
	"mute delay budget|bypass_output_cd4053_with_mute.h|s/^#define CD4053_MUTE_DELAY_MS (5U)/#define CD4053_MUTE_DELAY_MS (25U)/|bypass_output_cd4053_with_mute.c|CD4053_WITH_MUTE|mute delay must be shorter than RELEASE_THRESH"
	"relay pulse budget|bypass_output_tq2_l2_5v_relay.h|s/^#define TQ2_L2_5V_PULSE_MS (12U)/#define TQ2_L2_5V_PULSE_MS (25U)/|bypass_output_tq2_l2_5v_relay.c|TQ2_L2_5V_RELAY|relay coil pulse must be shorter than RELEASE_THRESH"
	"enum width flag||-fshort-enums|bypass_mcu_avr_classic.c|CD4053_SIMPLE|sizeof(effect_state_t) != 1, use -fshort-enums&&sizeof(program_state_t) != 1&&sizeof(timer_isr_called_t) != 1"
)

compile() {
	local tree=$1 tu=$2 macro=$3 flags=$4
	$CC $flags "-D$macro" -I"$tree" -c "$tree/$tu" -o "$tree/out.o" 2>&1
}

# Control, one per compile configuration used below. Without this every
# "the build failed" result would be unattributable.
for spec in "bypass_mcu_avr_classic.c CD4053_SIMPLE" \
	"bypass_output_cd4053_with_mute.c CD4053_WITH_MUTE" \
	"bypass_output_tq2_l2_5v_relay.c TQ2_L2_5V_RELAY"; do
	read -r tu macro <<<"$spec"
	plant "$work/control"
	if ! out=$(compile "$work/control" "$tu" "$macro" "$CFLAGS"); then
		fail "the UNMUTATED $tu does not compile, so nothing below can be attributed to a mutation: $out"
	fi
	checks=$((checks + 1))
done

for row in "${MUTATIONS[@]}"; do
	IFS='|' read -r label file script tu macro expected <<<"$row"
	tree="$work/mutant"
	plant "$tree"
	flags=$CFLAGS

	if [ -n "$file" ]; then
		before=$(sha256sum "$tree/$file" | cut -d' ' -f1)
		sed -i "$script" "$tree/$file"
		after=$(sha256sum "$tree/$file" | cut -d' ' -f1)
		[ "$before" != "$after" ] \
			|| fail "mutation '$label' changed nothing in $file -- its pattern no longer matches the source, so it would have scored as a pass without touching the guard"
	else
		# Flag mutation: remove the named flag, and prove it was there to remove.
		[[ "$flags" == *"$script"* ]] \
			|| fail "mutation '$label' cannot remove $script from CFLAGS -- it is not there"
		flags=${flags//$script/}
	fi
	checks=$((checks + 1))

	if out=$(compile "$tree" "$tu" "$macro" "$flags"); then
		fail "mutation '$label' compiled CLEAN -- the guard for \"$expected\" does not fire when its invariant is violated"
	fi
	[[ "$out" == *"static assertion failed"* ]] \
		|| fail "mutation '$label' failed to build, but not on a static assertion: $out"
	# `&&`-joined when one broken input must trip a WHOLE family, so that
	# deleting a sibling cannot hide behind the one still firing.
	IFS='&' read -r -a wants <<<"${expected//&&/&}"
	for want in "${wants[@]}"; do
		[[ "$out" == *"$want"* ]] \
			|| fail "mutation '$label' did not trip the guard for \"$want\"; it reported: $(printf '%s' "$out" | grep -oE 'static assertion failed: "[^"]*"' | sort -u | tr '\n' ' ')"
	done
	checks=$((checks + 1))
done

printf 'static_assert guards: %d checks, 0 failures (%d guards counted, %d mutations proven to trip one)\n' \
	"$checks" "$guards" "${#MUTATIONS[@]}"
