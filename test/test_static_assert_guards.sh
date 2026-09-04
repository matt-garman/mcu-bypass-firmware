#!/usr/bin/env bash
# Assert that selected compile-time guards actually FIRE when the thing they
# guard is violated, and census every guard so additions or deletions are loud.
#
# WHY THIS EXISTS. The `static_assert`s in the config headers and MCU shells are
# checked on every build, but only in the sense that they do not fire. Without a
# negative fixture, a guard that is still enforcing an invariant and a guard
# that has been quietly defused look exactly alike from the outside:
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
# SCOPE, stated so the next reader does not over-trust it: mutations cover
# selected high-consequence predicates, not every static assertion. The census
# catches a changed per-file count, but cannot detect an existing predicate
# replaced by unconditional truth. Guard mutations here compile the classic-AVR
# lane only, with avr-gcc. The shared invariants in
# bypass_compile_checks.h are MCU-neutral and reach every modular shell through a
# direct include. That include topology and its negative fixtures are checked
# below without target tools; the AVR-XT and PIC shell-local pin, clock and
# watchdog guards need their own toolchains and are mutated in
# test/test_target_guard_mutations.sh, which skips when those toolchains are
# absent. The census below spans EVERY shell either way, because counting needs
# no compiler and a deleted guard should not wait on an optional lane.
set -euo pipefail
# A bare `var=$(... grep ...)` that matches nothing takes this suite down with
# `set -e` and NO output: the failure has no diagnostic, and any guard on the
# next line never runs. Name the line instead of exiting mute. Deliberately no
# `set -E` -- without errtrace the trap is not inherited by the command
# substitution's subshell, so a failure is reported once rather than twice.
# This only reports; `set -e` still does the exiting, so control flow is unchanged.
# The `case $-` guard is required, not defensive: bash runs an ERR trap even
# inside a deliberate `set +e` block, and several suites use one around a
# command whose non-zero status IS the expected result (`make -q` returns 1).
# Without the guard those print a spurious FAIL that lands in retained
# release evidence, because test-long.summary.txt is built by grepping ^FAIL.
trap 'err_rc=$?; case $- in *e*) printf "FAIL: %s:%d exited %d with no diagnostic (a command substitution that matched nothing?)\n" "${BASH_SOURCE[0]}" "$LINENO" "$err_rc" >&2 ;; esac' ERR

mixed_control_child=0
case ${1:-} in
	"") ;;
	--mixed-control-child) mixed_control_child=1 ;;
	*) printf 'FAIL: unknown argument: %s\n' "$1" >&2; exit 1 ;;
esac
[ "$#" -le 1 ] || { printf 'FAIL: too many arguments\n' >&2; exit 1; }

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

# CFLAGS is the Classic production configuration and therefore carries its
# backend selector. The map-only watchdog fixture substitutes each modular
# backend in turn, so preserve every other production flag while removing that
# one selector before a row adds its own.
BUDGET_CFLAGS=${CFLAGS//-DBYPASS_MCU_AVR_CLASSIC/}
[ "$BUDGET_CFLAGS" != "$CFLAGS" ] \
	|| fail "CFLAGS no longer carries the Classic backend selector required by the production guard lane"
[[ "$BUDGET_CFLAGS" != *-DBYPASS_MCU_* ]] \
	|| fail "budget-fixture flags still carry a modular backend selector: $BUDGET_CFLAGS"
checks=$((checks + 1))

# Calculate the duty conversion independently of the firmware macros. `duty`
# is the ISR-owned fraction of wall time, so foreground delay work receives the
# denominator 100-duty. Quotient plus nonzero remainder is an upward-rounded
# division without the overflow-prone numerator+denominator-1 idiom.
watchdog_budget_ms() {
	local blocking=$1 duty=$2 tick=$3 loop=$4 denominator numerator overhead
	[ "$duty" -lt 100 ] || fail "independent watchdog calculation received invalid duty $duty"
	denominator=$((100 - duty))
	numerator=$((blocking * duty))
	overhead=$((numerator / denominator + (numerator % denominator != 0)))
	printf '%d\n' "$((blocking + overhead + tick + loop))"
}

check_watchdog_budget() {
	local label=$1 blocking=$2 duty=$3 tick=$4 loop=$5 expected=$6 actual
	actual=$(watchdog_budget_ms "$blocking" "$duty" "$tick" "$loop")
	[ "$actual" -eq "$expected" ] \
		|| fail "$label independently calculated $actual ms, expected $expected ms"
	checks=$((checks + 1))
}

check_watchdog_budget "25% duty relay" 12 25 1 1 18
check_watchdog_budget "25% duty mute" 5 25 1 1 9
check_watchdog_budget "25% duty simple" 0 25 1 1 2
check_watchdog_budget "zero-duty PIC10 relay" 12 0 1 1 14
check_watchdog_budget "largest supported arithmetic domain" 254 99 2 2 25404

# PIC10F320 is intentionally self-contained. Its duplicate must remain exactly
# the same checked conversion as the modular header; zero duty would otherwise
# hide a stale mixed formula from every ordinary PIC boundary.
budget_formula() {
	sed -n \
		'/^#if (WDT_ISR_STRETCH_PCT >= 100U)$/,/^      + (uint32_t)WDT_LOOP_WORK_MS )$/p' \
		"$1"
}
shared_budget=$(budget_formula "$SRC/bypass_output_common.h")
pic10f320_budget=$(budget_formula "$SRC/bypass_mcu_pic10f320.c")
[ -n "$shared_budget" ] \
	|| fail "could not extract the shared watchdog duty conversion"
checks=$((checks + 1))
[ "$pic10f320_budget" = "$shared_budget" ] \
	|| fail "PIC10F320's self-contained watchdog duty conversion drifted from bypass_output_common.h"
checks=$((checks + 1))
if [ "$mixed_control_child" -eq 0 ]; then
	[[ "$shared_budget" == *'((uint32_t)100U - (uint32_t)WDT_ISR_STRETCH_PCT)'* ]] \
		|| fail "watchdog denominator must convert each subtraction operand to uint32_t"
	checks=$((checks + 1))
	[[ "$shared_budget" != *'(uint32_t)WDT_FOREGROUND_SHARE_PCT'* ]] \
		|| fail "watchdog formula casts the composite denominator, violating MISRA Rule 10.8"
	checks=$((checks + 1))
fi

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
# conditional preprocessing belongs to each real target toolchain, which is what
# test/test_target_guard_mutations.sh does for the AVR-XT and the three PICs.
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
# Counting is the cheap structural complement: a mutation proves its selected
# predicate works, while the census proves only that the per-file number of
# guard declarations has not changed. Adding a guard fails this too, on purpose
# -- someone then decides whether the new one needs a mutation, and in which
# file: the classic-AVR mutations are below, the target-toolchain ones are in
# test/test_target_guard_mutations.sh. The census is not semantic coverage of
# predicates that have no mutation.
#
# EVERY shell is counted, not only the ones this file compiles. The four target
# shells hold 53 of the 81 guards; their mutations live behind optional
# toolchains, and a census that skipped with them would leave the majority of
# the firmware's compile-time invariants protected by nothing on a machine
# without XC8.
#
# Of bypass_compile_checks.h's five threshold guards, four are reachable.
# PRESSED_THRESH < DEBOUNCE_COUNTER_MAX cannot fire while RELEASE_THRESH <
# DEBOUNCE_COUNTER_MAX and RELEASE_THRESH > PRESSED_THRESH both hold, so it is
# defence in depth against a future edit to those two rather than a guard this
# file can trip.
GUARD_CENSUS=(
	"bypass_compile_checks.h 6"
	"bypass_mcu_avr_classic.c 17"
	"bypass_mcu_avr_xt.c 11"
	"bypass_mcu_pic10f320.c 19"
	"bypass_mcu_pic10f322.c 8"
	"bypass_mcu_pic12f675.c 15"
	"bypass_output_cd4053_simple.c 1"
	"bypass_output_cd4053_with_mute.c 2"
	"bypass_output_tq2_l2_5v_relay.c 2"
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
	# The watchdog pet-to-pet guards (WDT_PET_TO_PET_MAX_MS(pulse) <
	# WDT_MIN_PERIOD_MS). These mutate the FLOOR, not the pulse: on every shipped
	# part RELEASE_THRESH (25) < the WDT floor (100-160), so a pulse grown past the
	# floor trips the RELEASE_THRESH guard FIRST and can never isolate this one.
	# Dropping the floor below the budget while the pulse stays < RELEASE_THRESH
	# fires ONLY the margin guard, which is what a prescaler/tick regression looks
	# like. avr-classic's is the floor the standalone driver compile resolves
	# (BYPASS_MCU_AVR_CLASSIC -> bypass_pins_avr_classic.h). A floor of 5 is the
	# far-from-bound case; the near-bound cases that prove the overhead terms are
	# in NEARBOUND below.
	"relay WDT floor|bypass_pins_avr_classic.h|s/^#define WDT_MIN_PERIOD_MS (100U)/#define WDT_MIN_PERIOD_MS (5U)/|bypass_output_tq2_l2_5v_relay.c|TQ2_L2_5V_RELAY|relay: worst-case wall-clock WDT pet-to-pet interval must stay"
	"mute WDT floor|bypass_pins_avr_classic.h|s/^#define WDT_MIN_PERIOD_MS (100U)/#define WDT_MIN_PERIOD_MS (5U)/|bypass_output_cd4053_with_mute.c|CD4053_WITH_MUTE|mute: worst-case wall-clock WDT pet-to-pet interval must stay"
	"cd4053 WDT floor|bypass_pins_avr_classic.h|s/^#define WDT_MIN_PERIOD_MS (100U)/#define WDT_MIN_PERIOD_MS (1U)/|bypass_output_cd4053_simple.c|CD4053_SIMPLE|cd4053: worst-case wall-clock WDT pet-to-pet interval must stay"
	"enum width flag||-fshort-enums|bypass_mcu_avr_classic.c|CD4053_SIMPLE|sizeof(effect_state_t) != 1, use -fshort-enums&&sizeof(program_state_t) != 1&&sizeof(timer_isr_called_t) != 1"
)

compile() {
	local tree=$1 tu=$2 macro=$3 flags=$4
	$CC $flags "-D$macro" -I"$tree" -c "$tree/$tu" -o "$tree/out.o" 2>&1
}

compile_budget_fixture() {
	local tree=$1 map_define=$2 relay=$3 mute=$4 simple=$5 probe=$6 expected=$7
	$CC $BUDGET_CFLAGS "$map_define" -I"$tree" \
		-DTEST_RELAY_BUDGET_MS="$relay" \
		-DTEST_MUTE_BUDGET_MS="$mute" \
		-DTEST_SIMPLE_BUDGET_MS="$simple" \
		-DTEST_PROBE_BLOCKING_MS="$probe" \
		-DTEST_PROBE_BUDGET_MS="$expected" \
		-c "$ROOT/test/watchdog_budget_compile.c" -o "$tree/budget.o" 2>&1
}

# Control, one per compile configuration used below. Without this every
# "the build failed" result would be unattributable.
for spec in "bypass_mcu_avr_classic.c CD4053_SIMPLE" \
	"bypass_output_cd4053_simple.c CD4053_SIMPLE" \
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

# Compile the production macro itself with every real map. This complements the
# independent shell calculation above: neither copy can validate the other by
# construction, and the PIC maps prove zero duty adds no spurious stretch.
for spec in \
	"AVR-Classic -DBYPASS_MCU_AVR_CLASSIC 18 9 2 12 18" \
	"AVR-XT -DBYPASS_MCU_AVR_XT 18 9 2 12 18" \
	"PIC10F322 -DBYPASS_MCU_PIC10F322 14 7 2 12 14" \
	"PIC12F675 -DBYPASS_MCU_PIC12F675 16 9 4 12 16"; do
	read -r label map_define relay mute simple probe expected <<<"$spec"
	tree="$work/budget-map-$label"
	plant "$tree"
	if ! out=$(compile_budget_fixture "$tree" "$map_define" \
			"$relay" "$mute" "$simple" "$probe" "$expected"); then
		fail "$label production watchdog budgets differ from the independent exact values: $out"
	fi
	checks=$((checks + 1))
done

# Exercise the largest combined supported integer domain through the production
# macro, not only through Bash arithmetic: B<=254, p<=99, tick/work<=2.
tree="$work/budget-domain-max"
plant "$tree"
sed -i \
	's/^#define WDT_ISR_STRETCH_PCT (25U)/#define WDT_ISR_STRETCH_PCT (99U)/; s/^#define TICK_PERIOD_MS    (1U)/#define TICK_PERIOD_MS    (2U)/; s/^#define WDT_LOOP_WORK_MS  (1U)/#define WDT_LOOP_WORK_MS  (2U)/' \
	"$tree/bypass_pins_avr_classic.h"
if ! out=$(compile_budget_fixture "$tree" -DBYPASS_MCU_AVR_CLASSIC \
		1204 504 4 254 25404); then
	fail "production watchdog arithmetic failed its maximum-domain probe: $out"
fi
checks=$((checks + 1))

# At 100% no foreground share remains; values above it are invalid too. Pin both
# comparisons so weakening >= to == cannot admit wrapped denominators. The
# fallback denominator must prevent either case from adding divide-by-zero noise.
for duty in 100 101; do
	tree="$work/duty-domain-$duty"
	plant "$tree"
	before=$(sha256sum "$tree/bypass_pins_avr_classic.h" | cut -d' ' -f1)
	sed -i \
		"s/^#define WDT_ISR_STRETCH_PCT (25U)/#define WDT_ISR_STRETCH_PCT (${duty}U)/" \
		"$tree/bypass_pins_avr_classic.h"
	after=$(sha256sum "$tree/bypass_pins_avr_classic.h" | cut -d' ' -f1)
	[ "$before" != "$after" ] \
		|| fail "invalid-duty $duty fixture changed nothing in bypass_pins_avr_classic.h"
	checks=$((checks + 1))
	if out=$(compile "$tree" bypass_output_tq2_l2_5v_relay.c TQ2_L2_5V_RELAY "$CFLAGS"); then
		fail "$duty% wall-time ISR duty compiled clean despite leaving no valid foreground share"
	fi
	checks=$((checks + 1))
	[[ "$out" == *"WDT_ISR_STRETCH_PCT must be below 100: it is wall-time ISR duty"* ]] \
		|| fail "$duty% duty missed its dedicated compile guard: $out"
	checks=$((checks + 1))
	[[ "$out" != *"division by zero"* ]] \
		|| fail "$duty% duty reached division by zero instead of only its dedicated guard: $out"
	checks=$((checks + 1))
done

# ---------------------------------------------------------------------------
# Near-bound watchdog budget.
# ---------------------------------------------------------------------------
# The mutations above prove the pet-to-pet guard fires when the watchdog floor
# collapses to something obviously impossible (5 ms). That is the easy half. It
# would go on passing if the guard were still the old
# `TICK_PERIOD_MS + pulse < WDT_MIN_PERIOD_MS`, because a 5 ms floor is below
# that sum too -- so it cannot tell the weaker inequality from the stronger one,
# and cannot say whether the ISR-preemption and loop-work terms are doing any
# work at all.
#
# These fixtures do. Each pins the floor to a value inside the gap between the
# two inequalities and asserts the exact outcome, FIRES or CLEAN. The pair of
# outcomes on one fixture is the argument: a floor the OLD guard would have
# accepted must fail now, and must go back to compiling the moment the term
# under test is zeroed. A guard that had quietly reverted to counting only the
# tick and the pulse fails the FIRES half; a term that had been added but was
# never reachable (dead arithmetic, a lost parenthesis) fails the CLEAN half.
#
# Budget on the classic-AVR map these compiles resolve, with the shipped
# TICK_PERIOD_MS=1, WDT_LOOP_WORK_MS=1 and WDT_ISR_STRETCH_PCT=25. The
# percentage is wall-time ISR duty, so additive stretch is p/(100-p):
#   relay  (12 ms pulse): 12 + ceil(12*25/75)=4 + 1 + 1 = 18   (old guard: 13)
#   mute   ( 5 ms pulse):  5 + ceil( 5*25/75)=2 + 1 + 1 =  9   (old guard:  6)
#   cd4053 (no blocking):  0 +                 0 + 1 + 1 =  2   (old guard:  1)
# The exact-boundary rows (18/19, 9/10, 2/3) pin those numbers: equality with
# the watchdog floor is rejected, and a drift of even 1 ms breaks one pair.
#
# Row format, deliberately not the MUTATIONS format above: a fixture needs more
# than one edit, and its expected outcome is sometimes a clean compile.
#   label | file@@sed[;file@@sed...] | TU | -D variant | FIRES:<message> or CLEAN
NEARBOUND=(
	"relay near-bound floor|bypass_pins_avr_classic.h@@s/^#define WDT_MIN_PERIOD_MS (100U)/#define WDT_MIN_PERIOD_MS (15U)/|bypass_output_tq2_l2_5v_relay.c|TQ2_L2_5V_RELAY|FIRES:relay: worst-case wall-clock WDT pet-to-pet interval must stay"
	"relay preemption term is load-bearing|bypass_pins_avr_classic.h@@s/^#define WDT_MIN_PERIOD_MS (100U)/#define WDT_MIN_PERIOD_MS (15U)/;bypass_pins_avr_classic.h@@s/^#define WDT_ISR_STRETCH_PCT (25U)/#define WDT_ISR_STRETCH_PCT (0U)/|bypass_output_tq2_l2_5v_relay.c|TQ2_L2_5V_RELAY|CLEAN"
	"relay exact bound fires at 18|bypass_pins_avr_classic.h@@s/^#define WDT_MIN_PERIOD_MS (100U)/#define WDT_MIN_PERIOD_MS (18U)/|bypass_output_tq2_l2_5v_relay.c|TQ2_L2_5V_RELAY|FIRES:relay: worst-case wall-clock WDT pet-to-pet interval must stay"
	"relay exact bound clears at 19|bypass_pins_avr_classic.h@@s/^#define WDT_MIN_PERIOD_MS (100U)/#define WDT_MIN_PERIOD_MS (19U)/|bypass_output_tq2_l2_5v_relay.c|TQ2_L2_5V_RELAY|CLEAN"
	"relay loop-work term is load-bearing|bypass_pins_avr_classic.h@@s/^#define WDT_MIN_PERIOD_MS (100U)/#define WDT_MIN_PERIOD_MS (18U)/;bypass_pins_avr_classic.h@@s/^#define WDT_LOOP_WORK_MS  (1U)/#define WDT_LOOP_WORK_MS  (0U)/|bypass_output_tq2_l2_5v_relay.c|TQ2_L2_5V_RELAY|CLEAN"
	"relay tick term is load-bearing|bypass_pins_avr_classic.h@@s/^#define WDT_MIN_PERIOD_MS (100U)/#define WDT_MIN_PERIOD_MS (18U)/;bypass_pins_avr_classic.h@@s/^#define TICK_PERIOD_MS    (1U)/#define TICK_PERIOD_MS    (0U)/|bypass_output_tq2_l2_5v_relay.c|TQ2_L2_5V_RELAY|CLEAN"
	"mute near-bound floor|bypass_pins_avr_classic.h@@s/^#define WDT_MIN_PERIOD_MS (100U)/#define WDT_MIN_PERIOD_MS (8U)/|bypass_output_cd4053_with_mute.c|CD4053_WITH_MUTE|FIRES:mute: worst-case wall-clock WDT pet-to-pet interval must stay"
	"mute preemption term is load-bearing|bypass_pins_avr_classic.h@@s/^#define WDT_MIN_PERIOD_MS (100U)/#define WDT_MIN_PERIOD_MS (8U)/;bypass_pins_avr_classic.h@@s/^#define WDT_ISR_STRETCH_PCT (25U)/#define WDT_ISR_STRETCH_PCT (0U)/|bypass_output_cd4053_with_mute.c|CD4053_WITH_MUTE|CLEAN"
	"mute exact bound fires at 9|bypass_pins_avr_classic.h@@s/^#define WDT_MIN_PERIOD_MS (100U)/#define WDT_MIN_PERIOD_MS (9U)/|bypass_output_cd4053_with_mute.c|CD4053_WITH_MUTE|FIRES:mute: worst-case wall-clock WDT pet-to-pet interval must stay"
	"mute exact bound clears at 10|bypass_pins_avr_classic.h@@s/^#define WDT_MIN_PERIOD_MS (100U)/#define WDT_MIN_PERIOD_MS (10U)/|bypass_output_cd4053_with_mute.c|CD4053_WITH_MUTE|CLEAN"
	"mute tick term is load-bearing|bypass_pins_avr_classic.h@@s/^#define WDT_MIN_PERIOD_MS (100U)/#define WDT_MIN_PERIOD_MS (9U)/;bypass_pins_avr_classic.h@@s/^#define TICK_PERIOD_MS    (1U)/#define TICK_PERIOD_MS    (0U)/|bypass_output_cd4053_with_mute.c|CD4053_WITH_MUTE|CLEAN"
	"mute loop-work term is load-bearing|bypass_pins_avr_classic.h@@s/^#define WDT_MIN_PERIOD_MS (100U)/#define WDT_MIN_PERIOD_MS (9U)/;bypass_pins_avr_classic.h@@s/^#define WDT_LOOP_WORK_MS  (1U)/#define WDT_LOOP_WORK_MS  (0U)/|bypass_output_cd4053_with_mute.c|CD4053_WITH_MUTE|CLEAN"
	"cd4053 exact bound fires at 2|bypass_pins_avr_classic.h@@s/^#define WDT_MIN_PERIOD_MS (100U)/#define WDT_MIN_PERIOD_MS (2U)/|bypass_output_cd4053_simple.c|CD4053_SIMPLE|FIRES:cd4053: worst-case wall-clock WDT pet-to-pet interval must stay"
	"cd4053 exact bound clears at 3|bypass_pins_avr_classic.h@@s/^#define WDT_MIN_PERIOD_MS (100U)/#define WDT_MIN_PERIOD_MS (3U)/|bypass_output_cd4053_simple.c|CD4053_SIMPLE|CLEAN"
	"cd4053 tick term is load-bearing|bypass_pins_avr_classic.h@@s/^#define WDT_MIN_PERIOD_MS (100U)/#define WDT_MIN_PERIOD_MS (2U)/;bypass_pins_avr_classic.h@@s/^#define TICK_PERIOD_MS    (1U)/#define TICK_PERIOD_MS    (0U)/|bypass_output_cd4053_simple.c|CD4053_SIMPLE|CLEAN"
	"cd4053 loop-work term is load-bearing|bypass_pins_avr_classic.h@@s/^#define WDT_MIN_PERIOD_MS (100U)/#define WDT_MIN_PERIOD_MS (2U)/;bypass_pins_avr_classic.h@@s/^#define WDT_LOOP_WORK_MS  (1U)/#define WDT_LOOP_WORK_MS  (0U)/|bypass_output_cd4053_simple.c|CD4053_SIMPLE|CLEAN"
)

for row in "${NEARBOUND[@]}"; do
	IFS='|' read -r label sedlist tu macro outcome <<<"$row"
	tree="$work/nearbound"
	plant "$tree"

	IFS=';' read -r -a edits <<<"$sedlist"
	for e in "${edits[@]}"; do
		file=${e%%@@*}
		script=${e#*@@}
		before=$(sha256sum "$tree/$file" | cut -d' ' -f1)
		sed -i "$script" "$tree/$file"
		after=$(sha256sum "$tree/$file" | cut -d' ' -f1)
		[ "$before" != "$after" ] \
			|| fail "near-bound fixture '$label' changed nothing in $file -- its pattern no longer matches, so the fixture is not testing what it names"
		checks=$((checks + 1))
	done

	out=$(compile "$tree" "$tu" "$macro" "$CFLAGS") && built=1 || built=0
	if [ "$outcome" = CLEAN ]; then
		[ "$built" -eq 1 ] \
			|| fail "near-bound fixture '$label' was expected to COMPILE CLEAN but failed; the budget is stricter than this file says, so the paired FIRES row proves nothing about the term it names: $out"
	else
		want=${outcome#FIRES:}
		[ "$built" -eq 0 ] \
			|| fail "near-bound fixture '$label' compiled CLEAN -- the pet-to-pet guard does not fire at a floor the OLD tick+pulse inequality would have accepted, so the wall-clock overhead terms are not load-bearing"
		[[ "$out" == *"static assertion failed"* ]] \
			|| fail "near-bound fixture '$label' failed to build, but not on a static assertion: $out"
		[[ "$out" == *"$want"* ]] \
			|| fail "near-bound fixture '$label' did not trip the guard for \"$want\"; it reported: $(printf '%s' "$out" | grep -oE 'static assertion failed: "[^"]*"' | sort -u | tr '\n' ' ')"
	fi
	checks=$((checks + 1))
done

# Restore the exact mixed-definition defect in both deliberately duplicated
# formulas, then run this complete suite against that source. Production-floor
# controls still compile, but the hard-coded 18 ms AVR-Classic map oracle must
# reject the tree because the old ceil(blocking*p/100) arithmetic yields 17 ms.
if [ "$mixed_control_child" -eq 0 ]; then
	tree="$work/mixed-duty-formula"
	plant "$tree"
	for file in bypass_output_common.h bypass_mcu_pic10f320.c; do
		line='    ((uint32_t)100U - (uint32_t)WDT_ISR_STRETCH_PCT)'
		[ "$(grep -Fxc "$line" "$tree/$file")" -eq 1 ] \
			|| fail "mixed-formula control cannot find exactly one duty denominator in $file"
		sed -i \
			's/^    ((uint32_t)100U - (uint32_t)WDT_ISR_STRETCH_PCT)$/    ((uint32_t)100U)/' \
			"$tree/$file"
		grep -Fxq '    ((uint32_t)100U)' "$tree/$file" \
			|| fail "mixed-formula control did not restore the old denominator in $file"
		checks=$((checks + 2))
	done
	log="$work/mixed-duty-formula.log"
	if STATIC_ASSERT_SRC="$tree" \
			bash "$ROOT/test/test_static_assert_guards.sh" --mixed-control-child \
			>"$log" 2>&1; then
		fail "the complete exact-bound suite accepted the restored mixed duty/stretch formula"
	fi
	checks=$((checks + 1))
	grep -Fq "AVR-Classic production watchdog budgets differ from the independent exact values" "$log" \
		|| fail "the mixed formula failed for the wrong reason; expected the 18 ms AVR-Classic map oracle: $(tr '\n' ' ' <"$log")"
	checks=$((checks + 1))
fi

printf 'static_assert guards: %d checks, 0 failures (%d guards counted, %d mutations proven to trip one, %d near-bound watchdog fixtures)\n' \
	"$checks" "$guards" "${#MUTATIONS[@]}" "${#NEARBOUND[@]}"
