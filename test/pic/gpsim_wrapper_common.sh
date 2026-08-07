# Shared scaffolding for the gpsim CLI wrappers -- run_gpsim_test.sh (two-press
# toggle) and run_gpsim_power_on_pressed.sh (footswitch held at power-on). Both
# chips route through these same two wrappers; see test/test_gpsim_wrappers.sh.
#
# SOURCED, never executed: it has no shebang and is deliberately not executable,
# so it can never be mistaken for a third scenario. Each wrapper checks that this
# file is readable before sourcing it and dies if it is not -- a `.` of a missing
# file returns non-zero but does NOT abort a script that is not running under
# `set -e`, which is exactly the fail-open this project treats as a defect.
#
# What lives here is scaffolding only: tool discovery, the STRICT_TOOLS
# skip-vs-fail contract, input validation, the gpsim invocation, snapshot
# extraction and the verdict. What must NOT move here is any scenario knowledge
# -- which checkpoints exist and what has to be true at each -- because that is
# the entire content of the two tests, and duplicating a checkpoint list is how
# two "different" tests quietly become one.

GPSIM="${GPSIM:-gpsim}"
GPSIM_TIMEOUT_SECONDS="${GPSIM_TIMEOUT_SECONDS:-60}"
# The processor the SHARED wrappers hand gpsim. PIC_GPSIM_PROC carries no part
# in its name on purpose: it is the channel each lane passes its OWN part's
# value through (PIC10F322_GPSIM_PROC / PIC10F320_GPSIM_PROC), exactly as the
# naming rule beside the PIC variables in the Makefile states. Spelling it for
# one part severs the other lane silently, because the fallback below is that
# one part -- so the PIC10F320 lanes go on passing while simulating a PIC10F322.
PROC="${PIC_GPSIM_PROC:-p10f322}"

fails=0
note() { printf '  %-14s %s\n' "$1" "$2"; }
fail() { echo "  FAIL: $1"; fails=$((fails + 1)); }
pass() { echo "  ok:   $1"; }

# Bit test on a hex value. $1=hexval $2=bitmask(hex) -> echoes 1 if set.
bit() { echo $(( ( $1 & $2 ) != 0 )); }

# gpsim_run <hexfile> <stcfile> <what>
#
# Validate the environment, then run gpsim and leave its combined output in the
# global $out for parse() to read.
#
# Ordering is load-bearing and is asserted by test/test_gpsim_wrappers.sh: the
# timeout is validated BEFORE gpsim is looked up, so a misconfigured timeout is
# reported as a configuration error rather than silently absorbed by the
# missing-tool skip on a host without gpsim.
#
# This function does not return on failure -- it exits, so callers need not
# check a status. With gpsim absent it exits 0 (a clean skip) unless
# STRICT_TOOLS is set, in which case the same condition is a hard failure.
gpsim_run() {
	local hex="$1" stc="$2" what="$3"

	if ! [[ "$GPSIM_TIMEOUT_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] \
			|| ! [[ "$GPSIM_TIMEOUT_SECONDS" =~ [1-9] ]]; then
		echo "FAIL: GPSIM_TIMEOUT_SECONDS must be a positive decimal number of seconds"
		exit 1
	fi
	if ! command -v "$GPSIM" >/dev/null 2>&1; then
		echo "gpsim not installed; skipping $what for $hex"
		if [ -n "${STRICT_TOOLS:-}" ]; then
			echo "::error::STRICT_TOOLS=1: gpsim is required and must not be skipped"
			exit 1
		fi
		exit 0
	fi
	if [ ! -f "$hex" ]; then
		echo "FAIL: hex not found: $hex"
		exit 1
	fi
	if [ ! -f "$stc" ]; then
		echo "FAIL: gpsim script not found: $stc"
		exit 1
	fi

	if out=$(timeout -s KILL "$GPSIM_TIMEOUT_SECONDS" \
			"$GPSIM" -i -p"$PROC" "$hex" -c "$stc" </dev/null 2>&1); then
		:
	else
		local rc=$?
		# Mutation Make routes can collapse every failed recipe to status 2. Leave
		# an out-of-band witness so the outer mutation runner still classifies an
		# inner timeout/tool-launch failure as infrastructure, never as a kill.
		case "$rc" in
			124|125|126|127|137)
				[ -z "${MUTATION_INFRA_MARKER:-}" ] \
					|| : > "$MUTATION_INFRA_MARKER"
				;;
		esac
		echo "FAIL: gpsim exited with status $rc for $hex. Output was:"
		printf '%s\n' "$out"
		exit 1
	fi
}

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

# gpsim_require_snapshots <snapshot>...
#
# Every snapshot parse() produced must be non-empty. An empty one means gpsim
# stopped early or the stimulus never reached that checkpoint -- a run that must
# NOT be scored, since absent snapshots would otherwise read as passing bit
# tests against the empty string.
gpsim_require_snapshots() {
	local v
	for v in "$@"; do
		if [ -z "$v" ]; then
			echo "FAIL: could not parse gpsim snapshots (gpsim run incomplete). Output was:"
			printf '%s\n' "$out"
			exit 1
		fi
	done
}

# gpsim_verdict <hexfile> -- final PASS/FAIL line; exits with the verdict.
gpsim_verdict() {
	if [ "$fails" -ne 0 ]; then
		echo "RESULT: $fails check(s) FAILED for $1"
		exit 1
	fi
	echo "RESULT: PASS ($1)"
	exit 0
}
