#!/usr/bin/env bash
set -euo pipefail

# Host-only proof that the authoritative per-variant TARGET aggregate is
# genuinely fail-closed: it must require each libgpsim lane's explicit PASS
# marker, never merely the lane's exit status.
#
# WHY THIS EXISTS
# ---------------
# Every lane underneath these aggregates -- pic10f32{2,0}-test-fault{,-target},
# -test-lockstep, -test-io -- exits 0 through the Makefile's $(SKIP) contract
# when XC8 / gpsim-dev / glib is absent. That is correct for them as standalone
# development commands; the aggregate above them is the gate. An aggregate that
# reads only exit status therefore reports "target lanes passed" having executed
# nothing.
#
# That is not hypothetical. pic10f320-test-target shipped as a bare prerequisite
# list plus an unconditional success echo, so on a host with XC8 but without
# gpsim-dev it printed a full green sweep across all three variants with zero
# checks run -- while the PIC10F322 aggregate, which already required the
# markers, failed loudly on the same host. STRICT_TOOLS=1 masked it in CI and
# release, which is exactly why it survived review: the hole was only reachable
# where a variant name gets typed by hand.
#
# WHAT MAKES THIS RUNNABLE IN `make test`
# ---------------------------------------
# A fake `make` stands in for the lanes, so the regression is tool-independent
# by construction -- it needs neither XC8 nor gpsim and cannot acquire a hidden
# dependency on either. The Makefile's serialization wrapper drives the real
# graph through $(MAKE_COMMAND) and passes MAKE= down untouched, so overriding
# MAKE reaches the aggregate's recipe and nothing else.
#
# Parameterized so ONE regression covers both PIC targets (merge plan §4: FOLD
# the shared-name harnesses rather than forking them). Defaults reproduce the
# PIC10F322 contract; the PIC10F320 lane re-invokes this script with the LM_*
# overrides in the Makefile recipe.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/test-target-lane-markers.XXXXXX")
trap 'rm -rf "$work"' EXIT
fake_make="$work/fake-make"
log="$work/make.log"
checks=0

LM_LABEL=${LM_LABEL:-PIC}
LM_TARGET=${LM_TARGET:-pic10f322-test-target}
LM_VARIANT_ARG=${LM_VARIANT_ARG:-PIC10F322_TARGET_VARIANT}
# A real supported output stage: this is passed to the REAL make (only the
# per-lane sub-invocations are faked), so `variant-selectors-valid` rejects a
# name no lane supports. It read `mute` until 2026-08-03 -- a pre-v0.9.8 stage
# token the rename left behind, inert only because nothing had ever checked it.
LM_VARIANT=${LM_VARIANT:-cd4053_with_mute}
LM_SUCCESS_MARKER=${LM_SUCCESS_MARKER:-target fault/lock-step/I-O PASS}
# Optional: an argument that must appear on EVERY lane invocation. The PIC10F320
# aggregate uses it to pin the build-variant threading, because its `pic10f320`
# prerequisite builds exactly one image (unlike the 322's `pic10f322`, which builds the
# whole matrix), so a lane invoked without it silently compiles against the wrong
# variant's HEX.
LM_REQUIRE_ARG=${LM_REQUIRE_ARG:-}

read -r -a MAKE_CMD <<<"${PROJECT_MAKE:-make}"
[ "${#MAKE_CMD[@]}" -gt 0 ] \
	|| { printf 'FAIL: PROJECT_MAKE must name a Make command\n' >&2; exit 1; }

fail() {
	printf 'FAIL: %s %s\n' "$LM_LABEL" "$*" >&2
	exit 1
}

# The stand-in lane runner. It classifies which lane it was asked for from its
# own argv -- the target name is the only argument that can carry "test-fault",
# "test-lockstep" or "test-io", and the per-lane *_VARIANT= assignments cannot --
# so one fake serves both chips without being told their target names.
cat > "$fake_make" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf 'CALL' >> "${FAKE_MAKE_LOG:?}"
printf ' <%s>' "$@" >> "$FAKE_MAKE_LOG"
printf '\n' >> "$FAKE_MAKE_LOG"

lane=unknown
for a in "$@"; do
	case "$a" in
		*test-fault*)    lane=fault ;;
		*test-lockstep*) lane=lockstep ;;
		*test-io*)       lane=io ;;
	esac
done
case "$lane" in
	fault)    marker='FAULT-INJECT PASS' ;;
	lockstep) marker='LOCK-STEP PASS' ;;
	io)       marker='TARGET-IO PASS' ;;
	*)  printf 'fake-make: could not classify a lane from: %s\n' "$*" >&2
	    exit 3 ;;
esac

if [ "$lane" = "${FAKE_MODE_LANE:-}" ]; then
	case "${FAKE_MODE:-ok}" in
		# The real thing: "<tool> not found; skipping" then $(SKIP) -> exit 0.
		skip)  printf 'gpsim-dev headers not at /nowhere; skipping (install gpsim-dev)\n'
		       exit 0 ;;
		# The harness ran and reported failure. Guards against a marker pattern
		# loose enough to match "FAULT-INJECT FAIL" as well as "... PASS".
		wrong) printf '%s: 7 checks, 3 failures\n' "${marker% PASS} FAIL"
		       exit 0 ;;
		# The harness died outright.
		die)   printf 'lane crashed\n' >&2
		       exit 1 ;;
	esac
fi

printf '%s: 42 checks, 0 failures\n' "$marker"
exit 0
EOF
chmod 750 "$fake_make"

run_aggregate() {
	local mode=$1 mode_lane=$2
	: > "$log"
	(
		# MAKE is unset so the override below is the only definition in play.
		# _MAKE_SERIAL_LOCK_HELD is deliberately NOT unset: it arrives in the
		# environment when this script runs inside `make test`, and dropping it
		# would make the nested invocation try to reacquire the worktree lock
		# this process already holds.
		unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL MAKE
		FAKE_MAKE_LOG="$log" FAKE_MODE="$mode" FAKE_MODE_LANE="$mode_lane" \
			"${MAKE_CMD[@]}" --no-print-directory -C "$ROOT" \
			MAKE="$fake_make" "$LM_VARIANT_ARG=$LM_VARIANT" "$LM_TARGET"
	)
}

# Every lane invocation must carry the selected variant, and -- where the caller
# asked for it -- the build-variant argument too.
assert_call_args() {
	local i=$1 call=$2
	[[ "$call" == *"=$LM_VARIANT>"* ]] \
		|| fail "lane call $i did not carry the selected variant '$LM_VARIANT': $call"
	if [ -n "$LM_REQUIRE_ARG" ]; then
		[[ "$call" == *"<$LM_REQUIRE_ARG>"* ]] \
			|| fail "lane call $i did not carry '$LM_REQUIRE_ARG': $call"
	fi
}

# All three lanes report their marker -> the aggregate accepts, in lane order.
expect_accept() {
	local output i
	if ! output=$(run_aggregate ok none 2>&1); then
		fail "aggregate rejected three passing lanes: $output"
	fi
	[[ "$output" == *"$LM_SUCCESS_MARKER"* ]] \
		|| fail "aggregate omitted its own success marker: $output"
	mapfile -t calls < "$log"
	[ "${#calls[@]}" -eq 3 ] \
		|| fail "aggregate ran ${#calls[@]} lanes, expected 3"
	local expect_order=(test-fault test-lockstep test-io)
	for i in "${!expect_order[@]}"; do
		[[ "${calls[$i]}" == *"${expect_order[$i]}"* ]] \
			|| fail "lane $i was not ${expect_order[$i]}: ${calls[$i]}"
		assert_call_args "$i" "${calls[$i]}"
	done
	checks=$((checks + 1))
}

# One lane misbehaves -> the aggregate must fail, must name the missing marker
# where one is expected, must NOT print its own success marker, and must stop at
# the offending lane rather than sweeping on.
expect_reject() {
	local mode=$1 mode_lane=$2 want_marker=$3 want_calls=$4 output
	if output=$(run_aggregate "$mode" "$mode_lane" 2>&1); then
		fail "aggregate accepted a '$mode' $mode_lane lane: $output"
	fi
	[[ "$output" != *"$LM_SUCCESS_MARKER"* ]] \
		|| fail "aggregate printed its success marker after a '$mode' $mode_lane lane"
	if [ -n "$want_marker" ]; then
		[[ "$output" == *"did not report '$want_marker'"* ]] \
			|| fail "aggregate did not name the missing '$want_marker' marker: $output"
	fi
	mapfile -t calls < "$log"
	[ "${#calls[@]}" -eq "$want_calls" ] \
		|| fail "aggregate ran ${#calls[@]} lanes before rejecting, expected $want_calls"
	checks=$((checks + 1))
}

expect_accept

# A skipped lane is the defect this file exists for -- once per lane, so the
# check cannot be present on the first and missing on the rest.
expect_reject skip fault    'FAULT-INJECT PASS' 1
expect_reject skip lockstep 'LOCK-STEP PASS'    2
expect_reject skip io       'TARGET-IO PASS'    3

# A lane that ran and FAILED while still exiting 0 must not satisfy the marker.
expect_reject wrong fault 'FAULT-INJECT PASS' 1

# ...and an outright nonzero lane still fails, marker check or not.
expect_reject die fault '' 1

printf '%s target-lane PASS-marker validation: %d checks, 0 failures\n' \
	"$LM_LABEL" "$checks"
