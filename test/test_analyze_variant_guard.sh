#!/usr/bin/env bash
# Assert that every static-analysis target validates its variant request before
# analyzing anything.
#
# WHY THIS EXISTS. $(FW_SOURCES) maps $(VARIANTS) through src_<variant>, and an
# unrecognized variant name maps to NOTHING. A typo therefore does not fail the
# analyzers -- it SHRINKS their subject and they honestly report the smaller set
# clean. `VARIANTS="cd4053 mute relay"` (the pre-v0.9.8 stage vocabulary) leaves
# the two core files and zero of the three output drivers, so `make
# analyze-misra` checked no driver at all and exited 0.
#
# That is not hypothetical. MISRA_COMPLIANCE.md documented that exact command as
# the compliance procedure to run after changing the firmware, so for one
# release the gate whose entire value is being believed was the one analyzing
# nothing. The doc is fixed; this closes the class.
#
# TWO HALVES, because either alone leaves the same hole open. The behavioural
# half proves the guard fires on today's targets. The contract half proves it is
# still attached to every target that consumes $(FW_SOURCES) -- including ones
# added after this was written, which is the half a human otherwise has to
# remember. A guard that needs a human to remember to extend it has the same
# failure mode as the thing it guards.
#
# SCOPE, stated so the next reader does not over-trust it: the contract half
# covers targets that consume the caller-selected $(FW_SOURCES) Classic subject.
# Cppcheck/MISRA now use an immutable complete matrix, but the behavioural half
# still proves they reject invalid caller requests rather than ignore them.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MAKEFILE="$ROOT/Makefile"
GUARD=classic-variant-request-valid
SUPPORTED="cd4053_simple cd4053_with_mute tq2_l2_5v_relay"
RETIRED="cd4053 mute relay"
checks=0

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Every target that consumes $(FW_SOURCES), tagged with whether its prerequisite
# list names the guard. Walks rules rather than grepping lines because a target
# can consume the sources from its recipe alone, which no line-keyed harvest
# would associate with a target at all.
harvest() {
	awk '
	function flush() {
		if (target != "" && (prereqs body) ~ /\$\(FW_SOURCES\)/)
			printf "%s\t%s\n", target,
				(prereqs ~ /classic-variant-request-valid/) ? "guarded" : "UNGUARDED"
		target = ""; prereqs = ""; body = ""
	}
	# A rule head: "name: prereqs". Excludes := / ::= / += assignments and the
	# uppercase variable definitions (FW_SOURCES itself is one).
	/^[a-z][a-zA-Z0-9_.+-]*[ \t]*:[^=]/ {
		flush()
		target = $0; sub(/[ \t]*:.*/, "", target)
		prereqs = substr($0, index($0, ":") + 1)
		next
	}
	/^\t/ { if (target != "") body = body "\n" $0; next }
	/^[ \t]*$/ { next }
	{ flush() }
	END { flush() }
	' "$1" | sort -u
}

# ---------------------------------------------------------------------------
# Contract half: every $(FW_SOURCES) consumer names the guard.
# ---------------------------------------------------------------------------
mapfile -t consumers < <(harvest "$MAKEFILE")

# The harvest must find something. A walk that quietly stops matching is the
# same class of defect this gate exists to catch, and it would otherwise pass by
# inspecting an empty set.
[ "${#consumers[@]}" -ge 2 ] \
	|| fail "harvest found ${#consumers[@]} \$(FW_SOURCES) consumers, expected at least 2 -- the rule walk has stopped matching"
checks=$((checks + 1))

unguarded=()
for row in "${consumers[@]}"; do
	[[ "$row" == *$'\t'guarded ]] || unguarded+=("${row%%$'\t'*}")
done
[ "${#unguarded[@]}" -eq 0 ] \
	|| fail "these targets analyze \$(FW_SOURCES) without $GUARD, so a mistyped VARIANTS= silently shrinks what they analyze: ${unguarded[*]}"
checks=$((checks + 1))

# Negative case for the harvest itself: strip the guard from one target and the
# contract half must report exactly that target.
scratch=$(mktemp -d "${TMPDIR:-/tmp}/test-analyze-guard.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
# Positional-independent on purpose: a fixture pinned to "the guard is the FIRST
# prerequisite" fails the day another one is added, reporting a spelling change
# as a missing guard.
sed "s/^\(analyze-deep:.*\)$GUARD /\1/" "$MAKEFILE" > "$scratch/Makefile"
cmp -s "$MAKEFILE" "$scratch/Makefile" \
	&& fail "negative fixture changed nothing -- the analyze-deep guard is not spelled as this test expects"
mapfile -t mutated < <(harvest "$scratch/Makefile")
found=
for row in "${mutated[@]}"; do
	[[ "$row" == "analyze-deep"$'\t'UNGUARDED ]] && found=1
done
[ -n "$found" ] || fail "harvest did not report an unguarded analyze-deep -- the contract check cannot fail"
checks=$((checks + 1))

# ---------------------------------------------------------------------------
# Behavioural half: the guard rejects, and rejects BEFORE analyzing.
# ---------------------------------------------------------------------------
#
# The serialization wrapper re-execs make under flock and hands the inner
# invocation its request's verdict through the ENVIRONMENT, because it also
# sanitizes VARIANTS on the way down -- by the time the inner make runs, the
# unrecognized names are gone and only the inherited flags still remember they
# were typed. Correct for the wrapper's own recursion; wrong for an independent
# nested make started by a test, which would inherit `make test`'s verdict
# ("clean") and apply it to a request that make never saw. Left set, every
# rejection below turns into an acceptance and this gate quietly measures
# nothing.
#
# Harvested rather than hardcoded, in the same spirit as the guard itself: a
# rename must not leave this clearing names nothing sets. _MAKE_SERIAL_LOCK_HELD
# is deliberately NOT cleared -- it is what lets a nested make skip the flock the
# outer `make test` is already holding, and clearing it deadlocks.
mapfile -t WRAPPER_VERDICT < <(
	grep -oE '_MAKE_SERIAL_CLASSIC_[A-Z0-9_]+' "$MAKEFILE" \
		| grep -v '_COMPUTED$' | sort -u
)
[ "${#WRAPPER_VERDICT[@]}" -eq 3 ] \
	|| fail "expected 3 classic-lane wrapper verdict variables, found ${#WRAPPER_VERDICT[@]}: ${WRAPPER_VERDICT[*]-none}"
checks=$((checks + 1))

# PIN the condition rather than inherit it, so a standalone run and a `make
# test` run exercise the same thing. Held lock: the wrapper is skipped, which is
# what `make test` does to its children and is also required -- taking the
# worktree lock is what an outer `make test` is already doing, and every
# invocation below is read-only (a rejection builds nothing; the acceptances
# resolve the guard target alone), so there is nothing to serialize. Verdict
# inherited: this is the environment that made the naive version of this test
# measure nothing at all.
#
# Read through print-VAR, which the Makefile name-contract gate holds to the
# Makefile's real vocabulary, so this cannot drift to a variable that stopped
# existing.
LOCK_ID=$(
	unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL
	make -s -C "$ROOT" print-_MAKE_SERIAL_WORKTREE_ID
)
[ -n "$LOCK_ID" ] \
	|| fail "print-_MAKE_SERIAL_WORKTREE_ID was empty -- cannot pin the lock-held condition"
export _MAKE_SERIAL_LOCK_HELD="$LOCK_ID"
for v in "${WRAPPER_VERDICT[@]}"; do export "$v=0"; done
checks=$((checks + 1))

# The control that keeps the clearing from being a no-op assertion: WITHOUT it,
# make really does honour the inherited verdict and accept a request it should
# reject. A poison make ignores would prove nothing, and this test would pass
# just as happily with the clearing deleted.
if ! (
	unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL VARIANTS
	make --no-print-directory -C "$ROOT" "$GUARD" VARIANTS="$RETIRED" >/dev/null 2>&1
); then
	fail "inherited-verdict control did not reproduce: $GUARD rejected VARIANTS=\"$RETIRED\" even with ${WRAPPER_VERDICT[*]} set to 0, so clearing them proves nothing"
fi
checks=$((checks + 1))

run_make() {
	local goal=$1
	shift
	(
		unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL VARIANTS "${WRAPPER_VERDICT[@]}"
		make --no-print-directory -C "$ROOT" "$goal" "$@" 2>&1
	)
}

expect_reject() {
	local goal=$1 variants=$2 expected=$3 output
	if output=$(run_make "$goal" "VARIANTS=$variants"); then
		fail "$goal accepted VARIANTS=$(printf '%q' "$variants")"
	fi
	[[ "$output" == *"$expected"* ]] \
		|| fail "$goal rejected VARIANTS=$(printf '%q' "$variants") for the wrong reason: $output"
	# The whole point is that the request never reaches an analyzer: a partial
	# analysis that stops early still prints findings a reader could mistake for
	# a verdict over the full matrix.
	[[ "$output" != *"Checking src/"* && "$output" != *"clang-tidy:"* \
		&& "$output" != *"clang --analyze"* ]] \
		|| fail "$goal analyzed sources before rejecting VARIANTS=$(printf '%q' "$variants"): $output"
	checks=$((checks + 1))
}

# The defect itself, on every analysis target: the retired stage vocabulary
# names three real output stages and maps to no driver source at all.
for goal in analyze-tidy analyze-cppcheck analyze-deep analyze-misra analyze-misra-report; do
	expect_reject "$goal" "$RETIRED" "VARIANTS contains unsupported names"
done

# The other two malformed requests. One target is enough: all five share the one
# guard target, which the contract half above proves.
expect_reject analyze-misra "" "VARIANTS must not be empty"
expect_reject analyze-misra "cd4053_simple cd4053_simple" \
	"VARIANTS must not contain duplicate names"

# A partial name is not close enough to be accepted.
expect_reject analyze-misra "cd4053_simple relay" "VARIANTS contains unsupported names"

# ---------------------------------------------------------------------------
# The guard must not become a full-matrix demand. Analyzing one driver is a
# normal development request, and the build targets accept the same subsets.
# Without this, tightening the guard to demand the whole matrix -- an easy and
# plausible "improvement" -- would pass every check above.
# ---------------------------------------------------------------------------
read -r -a accepted <<<"$SUPPORTED"
accepted+=("cd4053_simple tq2_l2_5v_relay" "$SUPPORTED")
for variants in "${accepted[@]}"; do
	run_make "$GUARD" "VARIANTS=$variants" >/dev/null \
		|| fail "$GUARD rejected the recognized request VARIANTS=$(printf '%q' "$variants")"
	checks=$((checks + 1))
done

# A valid clang analysis must pair every source with an output selector. Without
# this, the shell's exact-one guard and the drivers' identity guards reject the
# analysis configuration before either analyzer can inspect the source.
fake_analyzer="$scratch/fake-analyzer"
analyzer_log="$scratch/analyzer.log"
cat > "$fake_analyzer" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source=
selector=
for arg in "$@"; do
	case "$arg" in
		src/*.c) source=$arg ;;
		-DCD4053_SIMPLE|-DCD4053_WITH_MUTE|-DTQ2_L2_5V_RELAY) selector=$arg ;;
	esac
done
printf '%s\t%s\n' "$source" "$selector" >> "${FAKE_ANALYZER_LOG:?}"
EOF
chmod 750 "$fake_analyzer"

expected_analysis=$'src/bypass_mcu_avr_classic.c\t-DCD4053_SIMPLE\nsrc/bypass_output_cd4053_simple.c\t-DCD4053_SIMPLE\nsrc/bypass_output_cd4053_with_mute.c\t-DCD4053_WITH_MUTE\nsrc/bypass_output_tq2_l2_5v_relay.c\t-DTQ2_L2_5V_RELAY\nsrc/bypass_pure.c\t-DCD4053_SIMPLE'
export FAKE_ANALYZER_LOG=$analyzer_log
for spec in "analyze-tidy ANALYZE_CMD" "analyze-deep CLANG"; do
	read -r goal tool_var <<<"$spec"
	: > "$analyzer_log"
	run_make "$goal" "VARIANTS=$SUPPORTED" "$tool_var=$fake_analyzer" >/dev/null \
		|| fail "$goal rejected the valid full selector matrix"
	actual_analysis=$(sort "$analyzer_log")
	[ "$actual_analysis" = "$expected_analysis" ] \
		|| fail "$goal did not pair each source with its required selector; got: $actual_analysis"
	checks=$((checks + 1))
done

printf 'analyze variant-request guard: %d checks, 0 failures\n' "$checks"
