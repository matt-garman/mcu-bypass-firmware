#!/usr/bin/env bash
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

# Host-only proof that the authoritative per-variant TARGET aggregate is
# genuinely fail-closed. PIC10F32x requires each lane's PASS marker; PIC12F675
# requires one exact terminal machine record, never merely exit status.
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
# A routing `make` executable enters the real graph, preserves its own argv[0]
# as GNU Make's immutable recursive command, and intercepts only component-lane
# submakes. The regression therefore needs neither XC8 nor gpsim, while
# MAKE=/PROJECT_MAKE= command-line values cannot bypass the aggregate.
#
# Named profiles keep each target's lane contract beside this consumer rather
# than assembling hybrid LM_* bundles in Make.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly -a LM_REQUIRED_PROFILES=(pic10f322 pic10f320 pic12f675)
readonly -a LM_CANONICAL_VARIANTS=(
	cd4053_simple
	cd4053_with_mute
	tq2_l2_5v_relay
)
readonly LM_REPRESENTATIVE_VARIANT=cd4053_with_mute

lm_validate_profile_request() {
	local name required
	local -a missing=()
	local -A known=() seen=()
	[ "$#" -gt 0 ] \
		|| { printf 'FAIL: target-lane profile request must not be empty\n' >&2; return 2; }
	for required in "${LM_REQUIRED_PROFILES[@]}"; do known[$required]=1; done
	for name in "$@"; do
		[ -n "$name" ] \
			|| { printf 'FAIL: target-lane profile request contains an empty name\n' >&2; return 2; }
		[ -n "${known[$name]+yes}" ] \
			|| { printf 'FAIL: target-lane profile request contains unknown name: %s\n' "$name" >&2; return 2; }
		[ -z "${seen[$name]+yes}" ] \
			|| { printf 'FAIL: target-lane profile request contains duplicate name: %s\n' "$name" >&2; return 2; }
		seen[$name]=1
	done
	for required in "${LM_REQUIRED_PROFILES[@]}"; do
		[ -n "${seen[$required]+yes}" ] || missing+=("$required")
	done
	[ "${#missing[@]}" -eq 0 ] \
		|| { printf 'FAIL: target-lane profile request is incomplete; missing: %s\n' \
			"${missing[*]}" >&2; return 2; }
}

lm_expect_profile_reject() {
	local label=$1
	shift
	if lm_validate_profile_request "$@" >/dev/null 2>&1; then
		printf 'FAIL: target-lane profile validator accepted %s request\n' "$label" >&2
		exit 1
	fi
}

if [ "${1:-}" != --run-profile ]; then
	lm_validate_profile_request "$@" || exit
	lm_expect_profile_reject empty
	lm_expect_profile_reject explicit-empty "${LM_REQUIRED_PROFILES[@]}" ""
	lm_expect_profile_reject unknown "${LM_REQUIRED_PROFILES[@]}" unknown
	lm_expect_profile_reject duplicate "${LM_REQUIRED_PROFILES[@]}" pic10f322
	lm_expect_profile_reject incomplete pic10f322 pic10f320
	for profile in "${LM_REQUIRED_PROFILES[@]}"; do
		if [ "$profile" = pic12f675 ]; then
			for variant in "${LM_CANONICAL_VARIANTS[@]}"; do
				"$0" --run-profile "$profile" "$variant"
			done
		else
			"$0" --run-profile "$profile"
		fi
	done
	printf 'target-lane profile request validation: 5 checks, 0 failures\n'
	exit 0
fi

[ "$#" -ge 2 ] && [ -n "$2" ] \
	|| { printf 'FAIL: internal target-lane profile worker request is malformed\n' >&2; exit 2; }
readonly LM_PROFILE=$2
shift 2

# A real supported output stage: this is passed to the REAL make (only the
# per-lane sub-invocations are faked), so `variant-selectors-valid` rejects a
# name no lane supports. It read `mute` until 2026-08-03 -- a pre-v0.9.8 stage
# token the rename left behind, inert only because nothing had ever checked it.
LM_VARIANT=$LM_REPRESENTATIVE_VARIANT
LM_SUCCESS_MARKER='target fault/lock-step/I-O PASS'
LM_REQUIRE_ARG=
LM_EXACT_RESULTS=0
LM_PIC12F675=0
case "$LM_PROFILE" in
	pic10f322)
		[ "$#" -eq 0 ] \
			|| { printf 'FAIL: PIC10F322 target-lane profile takes no variant argument\n' >&2; exit 2; }
		LM_LABEL=PIC
		LM_TARGET=pic10f322-test-target
		LM_VARIANT_ARG=PIC10F322_TARGET_VARIANT
		;;
	pic10f320)
		[ "$#" -eq 0 ] \
			|| { printf 'FAIL: PIC10F320 target-lane profile takes no variant argument\n' >&2; exit 2; }
		LM_LABEL=PIC10F320
		LM_TARGET=pic10f320-test-target
		LM_VARIANT_ARG=PIC10F320_TARGET_VARIANT
		LM_REQUIRE_ARG="PIC10F320_VARIANT=$LM_VARIANT"
		;;
	pic12f675)
		[ "$#" -eq 1 ] && [ -n "$1" ] \
			|| { printf 'FAIL: PIC12F675 target-lane profile requires one variant\n' >&2; exit 2; }
		case " ${LM_CANONICAL_VARIANTS[*]} " in
			*" $1 "*) ;;
			*) printf 'FAIL: PIC12F675 target-lane profile has unknown variant: %s\n' "$1" >&2; exit 2 ;;
		esac
		LM_LABEL=PIC12F675
		LM_TARGET=pic12f675-test-target
		LM_VARIANT_ARG=PIC12F675_TARGET_VARIANT
		LM_VARIANT=$1
		LM_EXACT_RESULTS=1
		LM_PIC12F675=1
		;;
	*) printf 'FAIL: unknown internal target-lane profile: %s\n' "$LM_PROFILE" >&2; exit 2 ;;
esac
for value in "$LM_LABEL" "$LM_TARGET" "$LM_VARIANT_ARG" "$LM_VARIANT" \
		"$LM_SUCCESS_MARKER"; do
	[ -n "$value" ] || { printf 'FAIL: incomplete internal target-lane profile: %s\n' "$LM_PROFILE" >&2; exit 2; }
done
for value in "$LM_EXACT_RESULTS" "$LM_PIC12F675"; do
	[[ "$value" =~ ^[01]$ ]] \
		|| { printf 'FAIL: invalid boolean in target-lane profile: %s\n' "$LM_PROFILE" >&2; exit 2; }
done

test_temp_root=${TMPDIR:-${XDG_RUNTIME_DIR:-${HOME:?HOME is required when TMPDIR and XDG_RUNTIME_DIR are unset}}}
work=$(mktemp -d -- "$test_temp_root/test-target-lane-markers.XXXXXX")
trap 'rm -rf "$work"' EXIT
. "$ROOT/test/pic/pic12f675_target_counts.sh"
fake_make="$work/fake-make"
log="$work/make.log"
checks=0
# Optional: an argument that must appear on EVERY lane invocation. The PIC10F320
# aggregate uses it to pin the build-variant threading, because its `pic10f320`
# prerequisite builds exactly one image (unlike the 322's `pic10f322`, which builds the
# whole matrix), so a lane invoked without it silently compiles against the wrong
# variant's HEX.

fail() {
	printf 'FAIL: %s %s\n' "$LM_LABEL" "$*" >&2
	exit 1
}

read -r -a MAKE_CMD <<<"${PROJECT_MAKE:-make}"
[ "${#MAKE_CMD[@]}" -gt 0 ] \
	|| { printf 'FAIL: PROJECT_MAKE must name a Make command\n' >&2; exit 1; }
real_make=$(command -v make)
matrix_contract_args=()
expected_matrix_record=
fake_fault_checks=38
fake_lockstep_checks=3005
fake_io_checks=26
if [ "$LM_PIC12F675" -eq 1 ]; then
	read -r fake_fault_checks fake_lockstep_checks fake_io_checks \
		< <(pic12f675_target_counts "$LM_VARIANT") \
		|| fail "no canonical result counts for variant '$LM_VARIANT'"
	matrix_dir="$work/pic12f675-matrix"
	mkdir -p "$matrix_dir/simcal"
	for variant in "${LM_CANONICAL_VARIANTS[@]}"; do
		stem="bypass-pic12f675-$variant"
		printf 'shipping %s\n' "$variant" > "$matrix_dir/$stem.hex"
		printf 'assembly %s\n' "$variant" > "$matrix_dir/$stem.s"
		printf 'symbols %s\n' "$variant" > "$matrix_dir/$stem.sym"
		printf 'simcal %s\n' "$variant" > "$matrix_dir/simcal/${stem}_simcal.hex"
	done
	expected_matrix_record=$(python3 "$ROOT/test/pic/pic12f675_matrix_evidence.py" record \
		--build-dir "$matrix_dir" --fw-base bypass --tag pic12f675)
	matrix_contract_args=(--old-file=_pic12f675-qualify-matrix \
		"PIC12F675_BUILD_DIR=$matrix_dir")
fi

# The stand-in lane runner. It classifies which lane it was asked for from its
# own argv -- the target name is the only argument that can carry "test-fault",
# "test-lockstep" or "test-io", and the per-lane *_VARIANT= assignments cannot --
# so one fake serves both chips without being told their target names.
cat > "$fake_make" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
if [ "${LM_ENTER_REAL_MAKE:-0}" -eq 1 ]; then
	export LM_ENTER_REAL_MAKE=0
	exec -a "$0" "${REAL_PROJECT_MAKE:?}" "$@"
fi

lane=unknown
for a in "$@"; do
	case "$a" in
		*test-fault*)    lane=fault ;;
		*test-lockstep*) lane=lockstep ;;
		*test-io*)       lane=io ;;
	esac
done
if [ "$lane" = unknown ]; then
	exec -a "$0" "${REAL_PROJECT_MAKE:?}" "$@"
fi
printf 'CALL' >> "${FAKE_MAKE_LOG:?}"
printf ' <%s>' "$@" >> "$FAKE_MAKE_LOG"
printf '\n' >> "$FAKE_MAKE_LOG"
case "$lane" in
	fault)    marker='FAULT-INJECT PASS'; lane_name=fault; checks=${FAKE_FAULT_CHECKS:?} ;;
	lockstep) marker='LOCK-STEP PASS'; lane_name=lockstep; checks=${FAKE_LOCKSTEP_CHECKS:?} ;;
	io)       marker='TARGET-IO PASS'; lane_name=io; checks=${FAKE_IO_CHECKS:?} ;;
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

printf '%s: %s checks, 0 failures\n' "$marker" "$checks"
if [ "${FAKE_EXACT_RESULTS:-0}" -eq 1 ]; then
	record="PIC_TARGET_RESULT format=1 device=pic12f675 lane=$lane_name variant=${FAKE_VARIANT:?} status=pass checks=$checks failures=0"
	if [ "$lane" = "${FAKE_MODE_LANE:-}" ]; then
		case "${FAKE_MODE:-ok}" in
			diagnostic) printf 'diagnostic mentions %s\n' "$record"; exit 0 ;;
			duplicate) printf '%s\n%s\n' "$record" "$record"; exit 0 ;;
			duplicate-marker) printf '%s: %s checks, 0 failures\n%s\n' "$marker" "$checks" "$record"; exit 0 ;;
			malformed) printf '%s extra=field\n' "$record"; exit 0 ;;
			nonzero-failures)
				printf 'PIC_TARGET_RESULT format=1 device=pic12f675 lane=%s variant=%s status=pass checks=%s failures=1\n' \
					"$lane_name" "$FAKE_VARIANT" "$checks"
				exit 0
				;;
			wrong-variant) printf '%s\n' "${record/variant=$FAKE_VARIANT/variant=unknown}"; exit 0 ;;
			wrong-device) printf '%s\n' "${record/device=pic12f675/device=pic12f676}"; exit 0 ;;
			wrong-lane) printf '%s\n' "${record/lane=$lane_name/lane=other}"; exit 0 ;;
			zero-checks) printf '%s\n' "${record/checks=$checks/checks=0}"; exit 0 ;;
			contradict)
				printf '%s: %s checks, 1 failures\n%s\n' "${marker% PASS} FAIL" "$checks" "$record"
				exit 0
				;;
			trailing) printf '%s\ntrailing diagnostic\n' "$record"; exit 0 ;;
		esac
	fi
	printf '%s\n' "$record"
fi
exit 0
EOF
chmod 750 "$fake_make"

run_aggregate() {
	local mode=$1 mode_lane=$2
	local tmpdir=${3:-}
	: > "$log"
	(
		# MAKE is unset so the override below is the only definition in play.
		# _MAKE_SERIAL_LOCK_HELD is deliberately NOT unset: it arrives in the
		# environment when this script runs inside `make test`, and dropping it
		# would make the nested invocation try to reacquire the worktree lock
		# this process already holds.
		unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL MAKE
		if [ -n "$tmpdir" ]; then export TMPDIR="$tmpdir"; fi
		REAL_PROJECT_MAKE="$real_make" LM_ENTER_REAL_MAKE=1 \
		FAKE_MAKE_LOG="$log" FAKE_MODE="$mode" FAKE_MODE_LANE="$mode_lane" \
		FAKE_EXACT_RESULTS="$LM_EXACT_RESULTS" \
		FAKE_VARIANT="$LM_VARIANT" \
		FAKE_FAULT_CHECKS="$fake_fault_checks" \
		FAKE_LOCKSTEP_CHECKS="$fake_lockstep_checks" \
		FAKE_IO_CHECKS="$fake_io_checks" \
			"$fake_make" --no-print-directory -C "$ROOT" \
			MAKE="$fake_make" PROJECT_MAKE=true "${matrix_contract_args[@]}" \
			"$LM_VARIANT_ARG=$LM_VARIANT" "$LM_TARGET"
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
	if [ "$LM_PIC12F675" -eq 1 ]; then
		[[ "$call" == *"<--old-file=pic12f675-simcal>"* ]] \
			|| fail "lane call $i did not suppress simulator-image production: $call"
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
	if [ -n "$expected_matrix_record" ]; then
		[[ "$output" == *"$expected_matrix_record"* ]] \
			|| fail "aggregate success omitted its retained hash record: $output"
	fi
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
		if [ "$LM_PIC12F675" -eq 1 ]; then
			[[ "$output" == *"did not report one exact terminal result"* ]] \
				|| fail "aggregate did not report the strict result failure: $output"
		else
			[[ "$output" == *"did not report '$want_marker'"* ]] \
				|| fail "aggregate did not name the missing '$want_marker' marker: $output"
		fi
	fi
	mapfile -t calls < "$log"
	[ "${#calls[@]}" -eq "$want_calls" ] \
		|| fail "aggregate ran ${#calls[@]} lanes before rejecting, expected $want_calls"
	checks=$((checks + 1))
}

expect_accept

if [ "$LM_PIC12F675" -eq 1 ]; then
	spaced_tmp="$work/tmp with spaces"
	mkdir "$spaced_tmp"
	if ! output=$(run_aggregate ok none "$spaced_tmp" 2>&1); then
		fail "aggregate rejected a valid TMPDIR containing spaces: $output"
	fi
	checks=$((checks + 1))
fi

# A skipped lane is the defect this file exists for -- once per lane, so the
# check cannot be present on the first and missing on the rest.
expect_reject skip fault    'FAULT-INJECT PASS' 1
expect_reject skip lockstep 'LOCK-STEP PASS'    2
expect_reject skip io       'TARGET-IO PASS'    3

# A lane that ran and FAILED while still exiting 0 must not satisfy the marker.
expect_reject wrong fault 'FAULT-INJECT PASS' 1

# ...and an outright nonzero lane still fails, marker check or not.
expect_reject die fault '' 1

if [ "$LM_PIC12F675" -eq 1 ]; then
	# Exit-zero output must still be one exact, variant-bound, terminal PASS
	# record with the canonical check count and no contradictory failure.
	expect_reject diagnostic       fault 'strict-result' 1
	expect_reject duplicate        fault 'strict-result' 1
	expect_reject duplicate-marker fault 'strict-result' 1
	expect_reject malformed        fault 'strict-result' 1
	expect_reject nonzero-failures fault 'strict-result' 1
	expect_reject wrong-variant    fault 'strict-result' 1
	expect_reject wrong-device     fault 'strict-result' 1
	expect_reject wrong-lane       fault 'strict-result' 1
	expect_reject zero-checks      fault 'strict-result' 1
	expect_reject contradict       fault 'strict-result' 1
	expect_reject trailing         fault 'strict-result' 1
fi

printf '%s target-lane result validation: %d checks, 0 failures\n' \
	"$LM_LABEL" "$checks"
