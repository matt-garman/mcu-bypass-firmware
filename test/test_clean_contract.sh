#!/usr/bin/env bash
# Assert that `make clean` removes every file the Makefile knows how to build.
#
# WHY THIS EXISTS. `clean` names its artifacts as a hand-written list, and an
# `rm -f` of a path that does not exist is a SUCCESSFUL `rm -f`. So a list that
# has drifted away from the rules that produce the files does not fail, does not
# warn, and leaves the tree exactly as dirty as having no `clean` at all.
#
# That is not hypothetical. The v0.9.8 MCU-field rename moved the classic-AVR
# simulation binaries from `test_sim_<v>` / `test_sim_<v>_t<n>` to
# `test_sim_<v>_attiny13a` / `_attiny<n>`, and neither `clean` nor `clean-tests`
# followed. Every path they named had stopped existing and all nine binaries
# actually built survived both targets, through a full release, silently.
#
# `clean-tests` is the sharper half. Its stated job is to drop binaries so the
# next run rebuilds them at the currently selected workload sizing (FAST vs
# FULL); a `clean-tests` that removes nothing means a `make test-long` could run
# FAST workloads while reporting the exhaustive suite. Today the affected rules
# all carry FORCE, so the sizing is reapplied anyway and the drift cost nothing
# but leftover files -- an accident, not a design. This gate is what makes it a
# guarantee.
#
# THE ORACLE is `make -rRn --print-data-base`: every explicit, non-phony target
# under test/ that is not a tracked source file is something the Makefile builds.
# Reading Make's own inventory is the whole point -- the families that matter
# here (`test_sim_<variant>_attiny<n>`) exist only after $(eval $(call ...))
# expansion, so a textual harvest of rule heads would not see them, and a second
# hand-written list would just be a third copy of the spelling to drift.
#
# SCOPE, stated so the next reader does not over-trust it: build products under
# test/ only. Everything else this project builds lands in a build directory
# that `clean` removes with `rm -rf`, where the same class cannot bite -- a
# directory either is or is not removed. The inventory is also taken at the
# DEFAULT parameters, so it carries one AVR soak combination rather than all
# six; check 4 covers the rest of that family by construction.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
checks=0

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Inventory items `clean-tests` deliberately does NOT remove, with the reason.
# Patterns, not names, because these families are parameterized. Every one must
# still match something (check 6), so an exemption expires rather than
# accumulating once the thing it excuses is gone.
#
#   test/pic/*      target-lane drivers whose recipes `rm -f` the binary and
#                   recompile unconditionally on every run, so no stale binary
#                   can survive into a differently-sized run. (The PIC10F320
#                   copies that DO have sizing compiled in are removed by
#                   clean-tests' own PIC section.)
#   test_soak_*     `test-soak` is phony and recompiles before every run, for
#                   exactly the same reason.
CLEAN_TESTS_EXEMPT=(
	'test/pic/*'
	'test/avr/test_soak_*'
)

# ---------------------------------------------------------------- inventory --

# Explicit, non-phony file targets under test/ that git does not track.
inventory() {
	make -rRn --print-data-base 2>/dev/null | awk '
	/^# Files/       { sec = 1; next }
	/^# Finished/    { sec = 0; next }
	sec != 1         { next }
	/^[#\t ]/        { if (target != "" && $0 ~ /Phony target/) phony[target] = 1; next }
	/^[^:=]+:(=)?/ {
		target = $0
		sub(/[ \t]*:.*/, "", target)
		if (target ~ /^test\// && target !~ /[ \t]/) order[++n] = target
		next
	}
	END { for (i = 1; i <= n; i++) if (!(order[i] in phony)) print order[i] }
	' | sort -u | comm -23 - <(git ls-files | sort -u)
}

# Every word removed by a target's recipe. `make -n` reaches the real rules
# through the serialization wrapper (its recipe names $(MAKE), which Make runs
# even under -n), and inherits _MAKE_SERIAL_LOCK_HELD when nested inside `make
# test` so it does not deadlock on the lock the outer make already holds.
removed_by() {
	make -n "$1" 2>/dev/null | awk '
	/^[ \t]*rm -[rf]*f/ { inrm = 1 }
	inrm {
		line = $0
		cont = (line ~ /\\[ \t]*$/)
		sub(/\\[ \t]*$/, "", line)
		sub(/^[ \t]*rm -[rf]*f/, "", line)
		n = split(line, w, /[ \t]+/)
		for (i = 1; i <= n; i++) if (w[i] != "") print w[i]
		if (!cont) inrm = 0
	}
	' | sort -u
}

# Members of $1 (newline-separated) that no pattern in $2 covers. Glob-aware:
# `clean` legitimately removes `test/stack_*.o` by pattern.
uncovered() {
	local -n _items=$1
	local -n _patterns=$2
	local item pat hit
	for item in "${_items[@]}"; do
		hit=0
		for pat in "${_patterns[@]}"; do
			# shellcheck disable=SC2053  # glob match is the point
			if [[ "$item" == $pat ]]; then hit=1; break; fi
		done
		[ "$hit" -eq 1 ] || printf '%s\n' "$item"
	done
}

mapfile -t INVENTORY < <(inventory)
mapfile -t CLEAN_REMOVES < <(removed_by clean)
mapfile -t CLEANTESTS_REMOVES < <(removed_by clean-tests)

# ------------------------------------------------------------------- floors --
#
# A harvest that quietly stops matching is the same defect class this gate
# exists to catch, and it would otherwise pass by comparing two empty sets.
# These floors are deliberately well below the current counts (22 / 52 / 12).

[ "${#INVENTORY[@]}" -ge 15 ] \
	|| fail "inventory found only ${#INVENTORY[@]} build products under test/; expected >= 15 -- the data-base parse has stopped matching"
checks=$((checks + 1))

[ "${#CLEAN_REMOVES[@]}" -ge 30 ] \
	|| fail "\`make -n clean\` yielded only ${#CLEAN_REMOVES[@]} removed paths; expected >= 30 -- the recipe parse has stopped matching"
checks=$((checks + 1))

[ "${#CLEANTESTS_REMOVES[@]}" -ge 8 ] \
	|| fail "\`make -n clean-tests\` yielded only ${#CLEANTESTS_REMOVES[@]} removed paths; expected >= 8 -- the recipe parse has stopped matching"
checks=$((checks + 1))

# The generated per-variant, per-MCU simulation family is the one that drifted,
# so require it by name rather than trusting the floor above to notice.
sim_count=$(printf '%s\n' "${INVENTORY[@]}" | grep -c '^test/avr/test_sim_.*_attiny' || true)
[ "$sim_count" -ge 9 ] \
	|| fail "inventory carries $sim_count generated test_sim_<variant>_attiny<n> binaries; expected >= 9 (3 variants x 3 MCUs)"
checks=$((checks + 1))

# ---------------------------------------------------------- the contract, 1 --

mapfile -t missing < <(uncovered INVENTORY CLEAN_REMOVES)
if [ "${#missing[@]}" -gt 0 ]; then
	{
		printf 'FAIL: `make clean` does not remove %d file(s) the Makefile builds:\n' "${#missing[@]}"
		printf '      %s\n' "${missing[@]}"
		printf '\n'
		printf 'An `rm -f` of a path that does not exist succeeds, so a stale name in\n'
		printf "clean's list is silent: nothing fails and the real artifacts stay.\n"
	} >&2
	exit 1
fi
checks=$((checks + 1))

# ---------------------------------------------------------- the contract, 2 --
#
# clean-tests has a deliberately narrower scope than clean, so its gap is
# checked against the declared exemptions rather than required to be empty. A
# NEW build product therefore forces a decision -- remove it, or say why not.

mapfile -t not_in_cleantests < <(uncovered INVENTORY CLEANTESTS_REMOVES)
mapfile -t undeclared < <(uncovered not_in_cleantests CLEAN_TESTS_EXEMPT)
if [ "${#undeclared[@]}" -gt 0 ]; then
	{
		printf 'FAIL: `make clean-tests` leaves %d build product(s) behind that no\n' "${#undeclared[@]}"
		printf '      exemption in CLEAN_TESTS_EXEMPT accounts for:\n'
		printf '      %s\n' "${undeclared[@]}"
		printf '\n'
		printf 'clean-tests exists so the next run rebuilds at the currently selected\n'
		printf 'workload sizing. Either remove these too, or record why they cannot go\n'
		printf 'stale (recipe recompiles unconditionally, FORCE prerequisite, ...).\n'
	} >&2
	exit 1
fi
checks=$((checks + 1))

# Exemptions expire: each must still suppress something real.
for pat in "${CLEAN_TESTS_EXEMPT[@]}"; do
	hit=0
	for item in "${not_in_cleantests[@]}"; do
		# shellcheck disable=SC2053
		if [[ "$item" == $pat ]]; then hit=1; break; fi
	done
	[ "$hit" -eq 1 ] \
		|| fail "CLEAN_TESTS_EXEMPT pattern '$pat' suppresses nothing -- delete it"
done
checks=$((checks + 1))

# ------------------------------------------------------------ negative case --
#
# Reproduce the original defect and require the contract check to fail on it:
# restore the pre-v0.9.8 spellings of the AVR simulation binaries and every
# generated one must come back as missing. Done textually rather than by editing
# a Makefile copy on purpose -- the serialization wrapper re-execs $(MAKE)
# WITHOUT -f, so a `make -f <copy>` run would silently read the real Makefile
# back and the negative case would prove nothing.
variants=$(make -s print-VARIANTS)
tinyx5=$(make -s print-TINYX5)
[ -n "$variants" ] && [ -n "$tinyx5" ] \
	|| fail "negative case: could not read VARIANTS/TINYX5 from the Makefile"

pre_rename=()
for item in "${CLEAN_REMOVES[@]}"; do
	case "$item" in
		test/avr/test_sim_*|test/avr/test_trace_*) ;;   # dropped; re-added below
		*) pre_rename+=("$item") ;;
	esac
done
for v in $variants; do
	pre_rename+=("test/avr/test_sim_$v" "test/avr/test_trace_$v")
	for n in $tinyx5; do pre_rename+=("test/avr/test_sim_${v}_t$n"); done
done

mapfile -t neg_missing < <(uncovered INVENTORY pre_rename)
neg_count=$(printf '%s\n' "${neg_missing[@]}" | grep -c '^test/avr/test_sim_.*_attiny' || true)
[ "$neg_count" -eq "$sim_count" ] \
	|| fail "negative case: the pre-v0.9.8 clean list left $neg_count of $sim_count generated simulation binaries unremoved; expected all of them"
checks=$((checks + 1))

# ...and the control: the CURRENT list must not be failing for some unrelated
# reason. Without this, a gate whose comparison is broken passes the negative
# case for free.
[ "${#missing[@]}" -eq 0 ] \
	|| fail "negative-case control: the current clean list should cover the inventory"
checks=$((checks + 1))

printf 'clean contract: %d checks, 0 failures (%d build products, %d removed by clean, %d by clean-tests)\n' \
	"$checks" "${#INVENTORY[@]}" "${#CLEAN_REMOVES[@]}" "${#CLEANTESTS_REMOVES[@]}"
