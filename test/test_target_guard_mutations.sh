#!/usr/bin/env bash
# Prove selected TARGET-LOCAL compile-time guards fire -- under each target's
# own toolchain, its own pin map, and its own watchdog floor.
#
# WHY THIS EXISTS. test/test_static_assert_guards.sh proves the mechanism: break
# one input to a guard, the build must fail with that guard's own message. But it
# compiles the classic-AVR lane only, with avr-gcc, and says so. Four MCU shells
# sit outside it -- bypass_mcu_avr_xt.c, bypass_mcu_pic10f322.c,
# bypass_mcu_pic12f675.c and bypass_mcu_pic10f320.c -- and they hold 53 of the
# firmware's 81 static_assert guards. This file exercises selected predicates
# from their pin, clock, layout, threshold and timing-budget families.
#
# Those target-local predicates cannot be proven with a shared compile. A pin
# assert reads _PORTA_RA3_POSN out of the Microchip device pack, PIN7_bp out of
# <avr/io.h>; a clock assert reads the -D_XTAL_FREQ or -DF_CPU that only that
# part's build passes; a watchdog assert compares against that part's own
# de-rated floor, which differs by part (128 ms on the ATtiny202, 160 ms on all
# three PICs) over a tick and a duty that also differ. Compiling one of them with
# some other part's toolchain does not approximate the check -- it evaluates a
# different expression, or does not preprocess at all.
#
# Until this file existed the census in test_static_assert_guards.sh was the only
# check over those 53 declarations. The census still records only per-file
# counts: this mutation roster does not detect arbitrary weakening of an
# unmutated predicate, and must not be represented as semantic coverage of all
# 53 guards.
#
# HOW. The same discipline as the classic-AVR file, so the two read alike:
# copy src/ to a throwaway tree, break ONE input, compile with the flags the real
# build uses, and require the failure to carry the guard's OWN message. The
# firmware is never modified; the mutations break thresholds, pin ordinals, clock
# constants and watchdog floors, never a static_assert line, because a mutation
# that edited the assert would prove only that the compiler implements it.
#
# The flags come from the Makefile via print-<VAR> rather than being restated
# here: a guard proven under flags nobody ships is not proven, and the same
# print-<VAR> vocabulary is itself held in place by the name-contract gate.
#
# WHAT A ROW CAN CLAIM. Four outcomes, because the honest answer is not always
# "a dedicated guard rejects this":
#   ASSERT:<msg>  the build must fail on a static assertion carrying <msg>.
#   ERROR:<msg>   the build must fail on a #error carrying <msg> -- the pin-map
#                 and F_CPU selectors are preprocessor conditionals, not asserts.
#   CLEAN         the build must SUCCEED. Paired with an ASSERT row one millisecond
#                 away, this is what makes an exact watchdog bound a bound rather
#                 than an inequality that happens to hold.
#   UNGUARDED     the build succeeds today and SHOULD NOT. Each such row names a
#                 configuration the firmware currently accepts in silence and
#                 records it here rather than leaving it undiscovered; see the
#                 section at the bottom.
#   INCIDENTAL    the build fails today, but not on any guard of ours.
#
# SCOPE. Compile-only (-c). These guards all live in translation-unit scope and
# fire in the front end; linking would add nothing and would drag in each part's
# link-time budget gates, which the per-part build targets already own.
set -euo pipefail

usage() {
	printf 'usage: %s <avr-xt|pic>\n' "${0##*/}" >&2
	printf '  avr-xt  the ATtiny202 shell under avr-gcc + the vendored ATtiny_DFP\n' >&2
	printf '  pic     the PIC10F322, PIC10F320 and PIC12F675 shells under XC8\n' >&2
}

[ "$#" -eq 1 ] || { usage; exit 1; }
LANE=$1
case "$LANE" in
	avr-xt|pic) ;;
	*) printf 'FAIL: unknown lane: %s\n' "$LANE" >&2; usage; exit 1 ;;
esac

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# Overridable ONLY so this file's own failure modes can be exercised against a
# doctored copy of src/ -- a deleted guard, a reworded message, a reindented
# #define, a weakened inequality -- without editing the firmware to test the
# thing that watches the firmware. The Make targets never set it.
SRC=${TARGET_GUARD_SRC:-$ROOT/src}
checks=0
rows=0

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/test-target-guards.XXXXXX")
trap 'rm -rf "$work"' EXIT

# A pristine copy per fixture, so one broken threshold can never leak into the
# next compile.
plant() {
	local tree=$1
	rm -rf "$tree"
	mkdir -p "$tree"
	cp "$SRC"/*.c "$SRC"/*.h "$tree/"
}

read_var() {
	(
		unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL
		make -s --no-print-directory -C "$ROOT" "$@"
	)
}

# The three shipping output variants and the -D macro each one compiles under,
# read from the Makefile that owns the mapping. Restating either here would let
# a fourth variant arrive with no target-toolchain coverage and nothing to say so.
read -r -a VARIANTS <<<"$(read_var print-CLASSIC_VARIANTS_SUPPORTED)"
[ "${#VARIANTS[@]}" -eq 3 ] \
	|| fail "expected three shipping output variants, the Makefile reports ${#VARIANTS[@]}: ${VARIANTS[*]} -- a new variant needs rows below before this file can pass"
checks=$((checks + 1))
# Each lookup is a Make invocation, so resolve them once here rather than per
# fixture row.
declare -A VARIANT_MACRO=()
for v in "${VARIANTS[@]}"; do
	VARIANT_MACRO[$v]=$(read_var "print-macro_$v")
	[ -n "${VARIANT_MACRO[$v]}" ] \
		|| fail "the Makefile has no output macro for variant $v"
	checks=$((checks + 1))
done

# --------------------------------------------------------------------------
# Compile configurations.
# --------------------------------------------------------------------------
# A configuration is one part plus one output variant: the compiler, the exact
# production flag set, and the directory the compiler must run in.
#
# The working directory is not incidental. XT_FW_CFLAGS carries -B/-I paths
# RELATIVE to the repo root (the vendored device pack), so that lane must compile
# from the root; XC8 scatters intermediates beside its output, so the PIC lanes
# compile inside the throwaway tree exactly as the Makefile's own PIC recipes cd
# into their build directory. Getting this backwards does not fail loudly -- it
# either cannot find the device specs, or it litters the worktree.
CONFIG_CC=""
CONFIG_FLAGS=""
CONFIG_CWD=""
resolve_config() {
	local part=$1 variant=$2 macro
	case "$part" in
		avr_xt)
			CONFIG_CC=$XT_CC
			CONFIG_FLAGS="$XT_FLAGS -D${VARIANT_MACRO[$variant]}"
			CONFIG_CWD=$ROOT
			;;
		pic10f322)
			CONFIG_CC=$PIC_CC
			CONFIG_FLAGS="$PIC10F322_FLAGS -D${VARIANT_MACRO[$variant]}"
			CONFIG_CWD=TREE
			;;
		pic12f675)
			CONFIG_CC=$PIC_CC
			CONFIG_FLAGS="$PIC12F675_FLAGS -D${VARIANT_MACRO[$variant]}"
			CONFIG_CWD=TREE
			;;
		pic10f320)
			# Self-contained lane: its output macro is spelled OUTPUT_* and is
			# already inside the flags the Makefile composes per variant, so the
			# variant is a Make assignment here rather than an extra -D.
			CONFIG_CC=$PIC_CC
			CONFIG_FLAGS=${PIC10F320_FLAGS[$variant]}
			CONFIG_CWD=TREE
			;;
		*) fail "unknown part in a fixture row: $part" ;;
	esac
	[ -n "$CONFIG_FLAGS" ] \
		|| fail "the Makefile reported no compile flags for $part/$variant"
}

if [ "$LANE" = avr-xt ]; then
	XT_CC=$(read_var print-CC)
	XT_FLAGS=$(read_var print-XT_FW_CFLAGS)
	[ -n "$XT_CC" ] && [ -n "$XT_FLAGS" ] \
		|| fail "print-CC / print-XT_FW_CFLAGS came back empty -- cannot compile anything"
	[[ "$XT_FLAGS" == *-fshort-enums* ]] \
		|| fail "XT_FW_CFLAGS no longer carries -fshort-enums; the enum-size row below cannot be exercised as written"
	checks=$((checks + 1))
	PARTS_IN_LANE="avr_xt"
else
	PIC_CC=$(read_var print-PIC_CC)
	PIC10F322_FLAGS=$(read_var print-PIC10F322_CFLAGS)
	PIC12F675_FLAGS=$(read_var print-PIC12F675_CFLAGS)
	[ -n "$PIC_CC" ] && [ -n "$PIC10F322_FLAGS" ] && [ -n "$PIC12F675_FLAGS" ] \
		|| fail "print-PIC_CC / print-PIC10F322_CFLAGS / print-PIC12F675_CFLAGS came back empty -- cannot compile anything"
	checks=$((checks + 1))
	declare -A PIC10F320_FLAGS=()
	for v in "${VARIANTS[@]}"; do
		PIC10F320_FLAGS[$v]=$(read_var print-PIC10F320_CFLAGS "PIC10F320_VARIANT=$v")
		[ -n "${PIC10F320_FLAGS[$v]}" ] \
			|| fail "the Makefile reported no PIC10F320 flags for variant $v"
		checks=$((checks + 1))
	done
	PARTS_IN_LANE="pic10f322 pic12f675 pic10f320"
fi

compile() {
	local tree=$1 tu=$2 cwd=$3
	shift 3
	[ "$cwd" = TREE ] && cwd=$tree
	(
		cd "$cwd" || exit 1
		# Unquoted on purpose: the flag string is a command line read from the
		# Makefile, and word splitting is what turns it back into arguments.
		# shellcheck disable=SC2086
		"$CONFIG_CC" $CONFIG_FLAGS -I"$tree" -c "$tree/$tu" -o "$tree/guard-probe.o" 2>&1
	)
}

# XC8 announces every _Static_assert it accepted on its own line. That is noise
# in front of a real diagnostic, and it is removed before any message match so a
# missing guard can never be papered over by the notes of its siblings.
strip_notes() { grep -v '^default: StaticAssert$' || true; }

# --------------------------------------------------------------------------
# Fixtures.
# --------------------------------------------------------------------------
# label | part:variant | flag edits | source edits | translation unit | outcome
#
# flag edits: '-', or ';'-joined 'drop:<literal>' / 'add:<literal>'. A drop must
#   find what it removes, so a renamed flag fails loudly instead of quietly
#   mutating nothing.
# source edits: '-', or ';'-joined '<file>@@<sed script>'. Each must change its
#   file, for the same reason.
# outcome: CLEAN | UNGUARDED | INCIDENTAL | ASSERT:<msg>[&&<msg>...] | ERROR:<msg>
FIXTURES=(
	# --- AVR-XT: pins, enum width, tick constant, clock, part identity --------
	"xt pin ordinal|avr_xt:cd4053_simple|-|bypass_pins_avr_xt.h@@s/^#define FOOTSW_PIN (7U)/#define FOOTSW_PIN (4U)/|bypass_mcu_avr_xt.c|ASSERT:FOOTSW_PIN must be PA7"
	"xt relay pin ordinal|avr_xt:tq2_l2_5v_relay|-|bypass_pins_avr_xt.h@@s/^#define RELAY_SET_PIN   (3U)/#define RELAY_SET_PIN   (1U)/|bypass_mcu_avr_xt.c|ASSERT:RELAY_SET_PIN must be PA3"
	# One broken flag must trip the WHOLE enum family, so deleting one of the
	# three cannot hide behind the two still firing.
	"xt enum width flag|avr_xt:cd4053_simple|drop:-fshort-enums|-|bypass_mcu_avr_xt.c|ASSERT:sizeof(effect_state_t) != 1, use -fshort-enums&&sizeof(program_state_t) != 1&&sizeof(timer_isr_called_t) != 1"
	# TCB0_CCMP_1MS is derived from F_CPU, so the realistic regression is the
	# derivation, not a literal: halve the divisor and the 1 ms tick becomes 2 ms.
	"xt tick derivation|avr_xt:cd4053_simple|-|bypass_config.h@@s,((F_CPU / 1000UL) - 1UL),((F_CPU / 2000UL) - 1UL),|bypass_mcu_avr_xt.c|ASSERT:TCB0_CCMP_1MS/F_CPU mismatch"
	"xt wrong clock|avr_xt:cd4053_simple|drop:-DF_CPU=2000000UL;add:-DF_CPU=1000000UL|-|bypass_mcu_avr_xt.c|ERROR:F_CPU must be 2000000 for the ATtiny202"
	"xt loses its backend selector|avr_xt:cd4053_simple|drop:-DBYPASS_MCU_AVR_XT|-|bypass_mcu_avr_xt.c|ERROR:exactly one modular MCU backend selector must be defined"
	"xt rejects two backend selectors|avr_xt:cd4053_simple|add:-DBYPASS_MCU_PIC10F322|-|bypass_mcu_avr_xt.c|ERROR:exactly one modular MCU backend selector must be defined"

	# --- PIC10F322: pins, clock, part identity -------------------------------
	"322 pin ordinal|pic10f322:cd4053_simple|-|bypass_pins_pic10f322.h@@s/^#define FOOTSW_PIN      (3U)/#define FOOTSW_PIN      (2U)/|bypass_mcu_pic10f322.c|ASSERT:FOOTSW_PIN must be RA3"
	"322 relay pin ordinal|pic10f322:tq2_l2_5v_relay|-|bypass_pins_pic10f322.h@@s/^#define RELAY_SET_PIN   (2U)/#define RELAY_SET_PIN   (0U)/|bypass_mcu_pic10f322.c|ASSERT:RELAY_SET_PIN must be RA2"
	"322 wrong clock|pic10f322:cd4053_simple|drop:-D_XTAL_FREQ=2000000UL;add:-D_XTAL_FREQ=4000000UL|-|bypass_mcu_pic10f322.c|ASSERT:_XTAL_FREQ must be 2 MHz"
	"322 loses its backend selector|pic10f322:cd4053_simple|drop:-DBYPASS_MCU_PIC10F322|-|bypass_mcu_pic10f322.c|ERROR:exactly one modular MCU backend selector must be defined"
	"322 rejects two backend selectors|pic10f322:cd4053_simple|add:-DBYPASS_MCU_PIC12F675|-|bypass_mcu_pic10f322.c|ERROR:exactly one modular MCU backend selector must be defined"

	# --- PIC12F675: pins, the GP3/GP4 spare-pin family, clock, part identity --
	# GP3 is input-only AND has no weak pull-up on this part, which is exactly why
	# its map differs from the PIC10F322's. Moving the footswitch onto it must
	# trip the identity guard AND the pull-up guard: one message alone would mean
	# the other had been deleted.
	"675 footswitch onto GP3|pic12f675:cd4053_simple|-|bypass_pins_pic12f675.h@@s/^#define FOOTSW_PIN      (5U)/#define FOOTSW_PIN      (3U)/|bypass_mcu_pic12f675.c|ASSERT:FOOTSW_PIN must be GP5&&FOOTSW_PIN must have an implemented weak pull-up (GP3 does not)"
	"675 footswitch onto an output|pic12f675:cd4053_simple|-|bypass_pins_pic12f675.h@@s/^#define FOOTSW_PIN      (5U)/#define FOOTSW_PIN      (1U)/|bypass_mcu_pic12f675.c|ASSERT:FOOTSW_PIN must be GP5&&FOOTSW_PIN must not be one of the output pins"
	"675 spare input pin|pic12f675:cd4053_simple|-|bypass_pins_pic12f675.h@@s/^#define SPARE_INPUT_PIN  (3U)/#define SPARE_INPUT_PIN  (1U)/|bypass_mcu_pic12f675.c|ASSERT:SPARE_INPUT_PIN must be input-only GP3&&SPARE_INPUT_PIN must use the external pull-up because GP3 has no WPU&&SPARE_INPUT_PIN must remain an input"
	"675 spare output pin|pic12f675:cd4053_simple|-|bypass_pins_pic12f675.h@@s/^#define SPARE_OUTPUT_PIN (4U)/#define SPARE_OUTPUT_PIN (3U)/|bypass_mcu_pic12f675.c|ASSERT:SPARE_OUTPUT_PIN must be GP4&&SPARE_OUTPUT_PIN must be a guarded low-driven output"
	"675 wrong clock|pic12f675:cd4053_simple|drop:-D_XTAL_FREQ=4000000UL;add:-D_XTAL_FREQ=2000000UL|-|bypass_mcu_pic12f675.c|ASSERT:_XTAL_FREQ must be 4 MHz"
	"675 loses its backend selector|pic12f675:cd4053_simple|drop:-DBYPASS_MCU_PIC12F675|-|bypass_mcu_pic12f675.c|ERROR:exactly one modular MCU backend selector must be defined"

	# --- PIC10F320: the deliberately self-contained shell --------------------
	# This shell carries its OWN copy of the five shared threshold invariants and
	# its own pin map rather than including bypass_compile_checks.h. That
	# duplication is deliberate (it is a 256-word part), and this is where it is
	# proven live: no other lane compiles this copy at all, so a defused guard
	# here is invisible everywhere else in the suite.
	#
	# Self-contained means self-contained: it does not include bypass_config.h
	# either, so it carries its own RELEASE_THRESH and the mutation has to be
	# made in place. Breaking the shared header instead changes a file this
	# translation unit never reads, and the fixture would compile clean while
	# looking like it had done something.
	"320 duplicate threshold invariants|pic10f320:cd4053_simple|-|bypass_mcu_pic10f320.c@@s/^#define RELEASE_THRESH  (25U)/#define RELEASE_THRESH  (8U)/|bypass_mcu_pic10f320.c|ASSERT:RELEASE_THRESH <= PRESSED_THRESH"
	"320 pin ordinal|pic10f320:cd4053_simple|-|bypass_mcu_pic10f320.c@@s/^#define FOOTSW_PIN      (3U)/#define FOOTSW_PIN      (2U)/|bypass_mcu_pic10f320.c|ASSERT:FOOTSW_PIN must be RA3"
	"320 wrong clock|pic10f320:cd4053_simple|drop:-D_XTAL_FREQ=2000000UL;add:-D_XTAL_FREQ=4000000UL|-|bypass_mcu_pic10f320.c|ASSERT:_XTAL_FREQ must be 2 MHz"
	# Branch-local pin guards: each lives inside one output arm, so each needs its
	# own variant to be reached at all. Compiling the wrong arm would score a
	# deleted guard as a pass.
	"320 branch-local cd4053 pin|pic10f320:cd4053_simple|-|bypass_mcu_pic10f320.c@@s/^#  define CD4053_PIN      (1U)/#  define CD4053_PIN      (2U)/|bypass_mcu_pic10f320.c|ASSERT:CD4053_PIN must be RA1"
	"320 branch-local mute pin|pic10f320:cd4053_with_mute|-|bypass_mcu_pic10f320.c@@s/^#  define CD4053_CTL2     (2U)/#  define CD4053_CTL2     (0U)/|bypass_mcu_pic10f320.c|ASSERT:CD4053_CTL2 must be RA2"
	"320 branch-local relay pin|pic10f320:tq2_l2_5v_relay|-|bypass_mcu_pic10f320.c@@s/^#  define RELAY_SET_PIN   (2U)/#  define RELAY_SET_PIN   (0U)/|bypass_mcu_pic10f320.c|ASSERT:RELAY_SET_PIN must be RA2"
	"320 no output scheme|pic10f320:cd4053_simple|drop:-DOUTPUT_CD4053_SIMPLE|-|bypass_mcu_pic10f320.c|ERROR:output scheme not defined"
)

# --------------------------------------------------------------------------
# Watchdog pet-to-pet budgets, per part, at the exact millisecond.
# --------------------------------------------------------------------------
# WDT_PET_TO_PET_MAX_MS(blocking) = blocking + ceil(blocking*p/(100-p)) + tick +
# loop work, compared against that part's de-rated watchdog floor. Every term on
# the left is a per-part constant, so the bound is a different number on every
# part and can only be checked on the part:
#
#   part        tick loop  p   cd4053  mute  relay   shipped floor
#   avr_xt        1    1   25       2     9     18       128 ms
#   pic10f322     1    1    0       2     7     14       160 ms
#   pic12f675     2    2    0       4     9     16       160 ms
#   pic10f320     1    1    0       2     7     14       160 ms
#
# Each budget below is pinned by a PAIR: the floor set to the budget must be
# REJECTED (the guard is `<`, so equality is not enough margin), and the floor one
# millisecond higher must COMPILE. One row alone proves nothing -- a guard that
# had reverted to a weaker inequality still fails at an absurd floor, and a term
# that was added but never reachable still passes an absurd floor. The pair is
# what distinguishes them, and a drift of one millisecond in any term breaks it.
#
#   part | variant | floor #define text | TU | budget
BUDGETS=(
	"avr_xt|cd4053_simple|bypass_pins_avr_xt.h@@#define WDT_MIN_PERIOD_MS (128U)|bypass_output_cd4053_simple.c|2|cd4053"
	"avr_xt|cd4053_with_mute|bypass_pins_avr_xt.h@@#define WDT_MIN_PERIOD_MS (128U)|bypass_output_cd4053_with_mute.c|9|mute"
	"avr_xt|tq2_l2_5v_relay|bypass_pins_avr_xt.h@@#define WDT_MIN_PERIOD_MS (128U)|bypass_output_tq2_l2_5v_relay.c|18|relay"
	"pic10f322|cd4053_simple|bypass_pins_pic10f322.h@@#define WDT_MIN_PERIOD_MS (160U)|bypass_output_cd4053_simple.c|2|cd4053"
	"pic10f322|cd4053_with_mute|bypass_pins_pic10f322.h@@#define WDT_MIN_PERIOD_MS (160U)|bypass_output_cd4053_with_mute.c|7|mute"
	"pic10f322|tq2_l2_5v_relay|bypass_pins_pic10f322.h@@#define WDT_MIN_PERIOD_MS (160U)|bypass_output_tq2_l2_5v_relay.c|14|relay"
	"pic12f675|cd4053_simple|bypass_pins_pic12f675.h@@#define WDT_MIN_PERIOD_MS (160U)|bypass_output_cd4053_simple.c|4|cd4053"
	"pic12f675|cd4053_with_mute|bypass_pins_pic12f675.h@@#define WDT_MIN_PERIOD_MS (160U)|bypass_output_cd4053_with_mute.c|9|mute"
	"pic12f675|tq2_l2_5v_relay|bypass_pins_pic12f675.h@@#define WDT_MIN_PERIOD_MS (160U)|bypass_output_tq2_l2_5v_relay.c|16|relay"
	# The 320's budget guards are branch-local inside its own shell, not in a
	# driver translation unit, and its floor is defined in the shell too.
	"pic10f320|cd4053_simple|bypass_mcu_pic10f320.c@@#define WDT_MIN_PERIOD_MS   (160U)|bypass_mcu_pic10f320.c|2|cd4053"
	"pic10f320|cd4053_with_mute|bypass_mcu_pic10f320.c@@#define WDT_MIN_PERIOD_MS   (160U)|bypass_mcu_pic10f320.c|7|mute"
	"pic10f320|tq2_l2_5v_relay|bypass_mcu_pic10f320.c@@#define WDT_MIN_PERIOD_MS   (160U)|bypass_mcu_pic10f320.c|14|relay"
)

# --------------------------------------------------------------------------
# Invalid configurations handed off to source guards.
# --------------------------------------------------------------------------
# New gaps first land here as UNGUARDED or INCIDENTAL rows, which fail when their
# missing guard is added. Converted ASSERT or ERROR rows stay here as proof that
# the new diagnostic is load-bearing.
#
# When a guard here starts firing, do not delete the row -- change UNGUARDED or
# INCIDENTAL to ASSERT:<message> or ERROR:<message>, proving the new guard is
# load-bearing.
GUARD_HANDOFF_FIXTURES=(
	"xt shell rejects two output selectors|avr_xt:cd4053_simple|add:-DTQ2_L2_5V_RELAY|-|bypass_mcu_avr_xt.c|ASSERT:exactly one modular output selector must be defined"
	"xt shell rejects no output selector|avr_xt:cd4053_simple|drop:-DCD4053_SIMPLE|-|bypass_mcu_avr_xt.c|ASSERT:exactly one modular output selector must be defined"
	"xt simple driver rejects a foreign selector|avr_xt:cd4053_simple|drop:-DCD4053_SIMPLE;add:-DTQ2_L2_5V_RELAY|-|bypass_output_cd4053_simple.c|ERROR:bypass_output_cd4053_simple.c requires CD4053_SIMPLE"
	"xt mute driver rejects a foreign selector|avr_xt:cd4053_with_mute|drop:-DCD4053_WITH_MUTE;add:-DCD4053_SIMPLE|-|bypass_output_cd4053_with_mute.c|ERROR:bypass_output_cd4053_with_mute.c requires CD4053_WITH_MUTE"
	"xt relay driver rejects a foreign selector|avr_xt:tq2_l2_5v_relay|drop:-DTQ2_L2_5V_RELAY;add:-DCD4053_SIMPLE|-|bypass_output_tq2_l2_5v_relay.c|ERROR:bypass_output_tq2_l2_5v_relay.c requires TQ2_L2_5V_RELAY"
	"322 shell rejects two output selectors|pic10f322:cd4053_simple|add:-DTQ2_L2_5V_RELAY|-|bypass_mcu_pic10f322.c|ASSERT:exactly one modular output selector must be defined"
	"322 shell rejects no output selector|pic10f322:cd4053_simple|drop:-DCD4053_SIMPLE|-|bypass_mcu_pic10f322.c|ASSERT:exactly one modular output selector must be defined"
	"322 relay driver rejects a foreign selector|pic10f322:tq2_l2_5v_relay|drop:-DTQ2_L2_5V_RELAY;add:-DCD4053_SIMPLE|-|bypass_output_tq2_l2_5v_relay.c|ERROR:bypass_output_tq2_l2_5v_relay.c requires TQ2_L2_5V_RELAY"
	"675 relay driver rejects a foreign selector|pic12f675:tq2_l2_5v_relay|drop:-DTQ2_L2_5V_RELAY;add:-DCD4053_SIMPLE|-|bypass_output_tq2_l2_5v_relay.c|ERROR:bypass_output_tq2_l2_5v_relay.c requires TQ2_L2_5V_RELAY"
	# This used to fail incidentally when two selection idioms chose different
	# arms. Keep the invalid configuration and require its deliberate diagnostic.
	"320 rejects two output schemes deliberately|pic10f320:cd4053_simple|add:-DOUTPUT_TQ2_RELAY|-|bypass_mcu_pic10f320.c|ASSERT:PIC10F320 output selectors are mutually exclusive"
)

row_in_lane() {
	local part=${1%%:*}
	[[ " $PARTS_IN_LANE " == *" $part "* ]]
}

apply_flag_edits() {
	local spec=$1 edit op text
	[ "$spec" = - ] && return 0
	local -a ops
	IFS=';' read -r -a ops <<<"$spec"
	for edit in "${ops[@]}"; do
		op=${edit%%:*}
		text=${edit#*:}
		case "$op" in
			drop)
				[[ "$CONFIG_FLAGS" == *"$text"* ]] \
					|| fail "cannot remove $text from the production flags -- it is not there, so this fixture is not testing what it names"
				CONFIG_FLAGS=${CONFIG_FLAGS//$text/}
				;;
			add) CONFIG_FLAGS="$CONFIG_FLAGS $text" ;;
			*) fail "unknown flag edit: $edit" ;;
		esac
	done
}

apply_source_edits() {
	local tree=$1 spec=$2 label=$3 edit file script before after
	[ "$spec" = - ] && return 0
	local -a edits
	IFS=';' read -r -a edits <<<"$spec"
	for edit in "${edits[@]}"; do
		file=${edit%%@@*}
		script=${edit#*@@}
		[ -f "$tree/$file" ] || fail "fixture '$label' names a source file that does not exist: $file"
		before=$(sha256sum "$tree/$file" | cut -d' ' -f1)
		sed -i "$script" "$tree/$file"
		after=$(sha256sum "$tree/$file" | cut -d' ' -f1)
		[ "$before" != "$after" ] \
			|| fail "fixture '$label' changed nothing in $file -- its pattern no longer matches the source, so it would have scored as a pass without touching the guard"
		checks=$((checks + 1))
	done
}

# Every compile below is attributable only if the SAME configuration and
# translation unit build clean unmutated. Collected from the rows themselves
# rather than restated, so a new row cannot arrive without its control.
declare -a CONTROLS_DONE=()
control_for() {
	local config=$1 tu=$2 key="$config|$tu" done_key tree out
	for done_key in "${CONTROLS_DONE[@]:-}"; do
		[ "$done_key" = "$key" ] && return 0
	done
	CONTROLS_DONE+=("$key")
	tree="$work/control"
	plant "$tree"
	resolve_config "${config%%:*}" "${config#*:}"
	if ! out=$(compile "$tree" "$tu" "$CONFIG_CWD" | strip_notes); then
		fail "the UNMUTATED $tu does not compile for $config, so nothing below can be attributed to a mutation: $out"
	fi
	checks=$((checks + 1))
}

assert_outcome() {
	local label=$1 outcome=$2 built=$3 out=$4 want reported
	# `|| true`: a compile that failed for some OTHER reason has no assertion text
	# at all, and that is exactly the case this summary exists to report.
	reported=$(printf '%s' "$out" | grep -oE 'static assertion failed[^\n]*' | sort -u | tr '\n' ' ' || true)
	case "$outcome" in
		CLEAN)
			[ "$built" -eq 1 ] \
				|| fail "fixture '$label' was expected to COMPILE CLEAN but failed; the budget is stricter than this file says, so its paired rejection row proves nothing about the term it names: $out"
			;;
		UNGUARDED)
			[ "$built" -eq 1 ] \
				|| fail "fixture '$label' no longer compiles. If a guard was just added for it, that is good news: replace UNGUARDED on this row with ASSERT:<the guard's message> so the row proves the new guard is load-bearing. Output: $out"
			;;
		INCIDENTAL)
			[ "$built" -eq 0 ] \
				|| fail "fixture '$label' now COMPILES; the accidental rejection this row records has gone away and nothing has replaced it"
			[[ "$out" != *"static assertion failed"* ]] \
				|| fail "fixture '$label' is now rejected by a static assertion. Replace INCIDENTAL on this row with ASSERT:<its message>: the rejection is deliberate now and should be proven as such. Output: $out"
			;;
		ASSERT:*)
			[ "$built" -eq 0 ] \
				|| fail "fixture '$label' compiled CLEAN -- the guard for \"${outcome#ASSERT:}\" does not fire when its invariant is violated"
			[[ "$out" == *"static assertion failed"* ]] \
				|| fail "fixture '$label' failed to build, but not on a static assertion: $out"
			local -a wants
			IFS='&' read -r -a wants <<<"${outcome#ASSERT:}"
			for want in "${wants[@]}"; do
				[ -n "$want" ] || continue
				[[ "$out" == *"$want"* ]] \
					|| fail "fixture '$label' did not trip the guard for \"$want\"; it reported: $reported"
			done
			;;
		ERROR:*)
			want=${outcome#ERROR:}
			[ "$built" -eq 0 ] \
				|| fail "fixture '$label' compiled CLEAN -- the #error for \"$want\" does not fire when its condition is violated"
			[[ "$out" == *"$want"* ]] \
				|| fail "fixture '$label' failed to build, but not with \"$want\": $out"
			;;
		*) fail "fixture '$label' declares an unknown outcome: $outcome" ;;
	esac
	checks=$((checks + 1))
}

run_fixture() {
	local label=$1 config=$2 flagedits=$3 srcedits=$4 tu=$5 outcome=$6
	local tree out built
	row_in_lane "$config" || return 0
	control_for "$config" "$tu"
	tree="$work/fixture"
	plant "$tree"
	resolve_config "${config%%:*}" "${config#*:}"
	apply_flag_edits "$flagedits"
	apply_source_edits "$tree" "$srcedits" "$label"
	out=$(compile "$tree" "$tu" "$CONFIG_CWD" | strip_notes) && built=1 || built=0
	assert_outcome "$label" "$outcome" "$built" "$out"
	rows=$((rows + 1))
}

for row in "${FIXTURES[@]}" "${GUARD_HANDOFF_FIXTURES[@]}"; do
	IFS='|' read -r f_label f_config f_flags f_src f_tu f_outcome <<<"$row"
	run_fixture "$f_label" "$f_config" "$f_flags" "$f_src" "$f_tu" "$f_outcome"
done

budget_pairs=0
for row in "${BUDGETS[@]}"; do
	IFS='|' read -r b_part b_variant b_floor b_tu b_budget b_name <<<"$row"
	[[ " $PARTS_IN_LANE " == *" $b_part "* ]] || continue
	floor_file=${b_floor%%@@*}
	floor_text=${b_floor#*@@}
	shipped=${floor_text##*\(}
	shipped=${shipped%U)}
	[ "$b_budget" -lt "$shipped" ] \
		|| fail "$b_part/$b_name: this file claims a $b_budget ms pet-to-pet budget against a shipped floor of $shipped ms, which leaves no margin -- the shipped configuration itself would not build"
	checks=$((checks + 1))
	# Equality must be rejected and one millisecond more must be accepted. Two
	# rows, one bound.
	run_fixture "$b_part $b_name budget is rejected at a ${b_budget} ms floor" \
		"$b_part:$b_variant" - \
		"$floor_file@@s/^${floor_text//\//\\/}/${floor_text%%\(*}($b_budget"'U)/' \
		"$b_tu" \
		"ASSERT:$b_name: worst-case wall-clock WDT pet-to-pet interval must stay"
	run_fixture "$b_part $b_name budget clears at a $((b_budget + 1)) ms floor" \
		"$b_part:$b_variant" - \
		"$floor_file@@s/^${floor_text//\//\\/}/${floor_text%%\(*}($((b_budget + 1))"'U)/' \
		"$b_tu" \
		CLEAN
	budget_pairs=$((budget_pairs + 1))
done

printf 'target compile-guard mutations (%s): %d checks, 0 failures (%d fixtures over %d compile configurations, %d exact watchdog bounds)\n' \
	"$LANE" "$checks" "$rows" "${#CONTROLS_DONE[@]}" "$budget_pairs"
