#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/test-gpsim-wrappers.XXXXXX")
trap 'rm -rf "$work"' EXIT
tools="$work/tools"
hex="$work/firmware.hex"
checks=0
unset FAKE_GPSIM_MODE FAKE_GPSIM_EXIT FAKE_GPSIM_MARKER FAKE_GPSIM_STC_LOG \
	FAKE_GPSIM_PROC_LOG \
	FAKE_TIMEOUT_MARKER GPSIM GPSIM_TIMEOUT_SECONDS PIC_GPSIM_PROC PIC_GPSIM_STC \
	STRICT_TOOLS
mkdir -p "$tools"
printf ':00000001FF\n' > "$hex"
REAL_TIMEOUT=$(command -v timeout)
read -r -a MAKE_CMD <<<"${PROJECT_MAKE:-make}"
[ "${#MAKE_CMD[@]}" -gt 0 ] \
	|| { printf 'FAIL: PROJECT_MAKE must name a Make command\n' >&2; exit 1; }

cat > "$tools/timeout" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ -z "${FAKE_TIMEOUT_MARKER:-}" ] || : > "$FAKE_TIMEOUT_MARKER"
exec "$REAL_TIMEOUT" "$@"
EOF

cat > "$tools/gpsim" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
script=
proc=
while [ "$#" -gt 0 ]; do
	case "$1" in
		-c)  script=$2; shift 2 ;;
		-p*) proc=${1#-p}; shift ;;
		*)   shift ;;
	esac
done
if [ ! -f "$script" ]; then
	printf 'gpsim command script not found: %s\n' "$script" >&2
	exit 65
fi
fsw_attach_count=$(awk '$1 == "attach" && $2 == "n1" && $3 == "fsw" { count++ } END { print count + 0 }' "$script")
ra3_attach_count=$(awk '$1 == "attach" && $2 == "n1" && $3 == "fsw" && $4 == "ra3" && NF == 4 { count++ } END { print count + 0 }' "$script")
if [ "$fsw_attach_count" -ne 1 ] || [ "$ra3_attach_count" -ne 1 ]; then
	printf 'invalid footswitch attachment: expected exactly one attach n1 fsw ra3 in %s\n' \
		"$script" >&2
	exit 65
fi
case "$script" in
	*power_on_pressed.stc)
		printf '%s\n' \
			'===PON_HELD===' 'porta = 0x0' 'lata = 0x0' \
			'===PON_RELEASED===' 'porta = 0x8' 'lata = 0x0' \
			'===PON_ENGAGED===' 'porta = 0x9' 'lata = 0x1'
		;;
	*footswitch_toggle.stc)
		printf '%s\n' \
			'===INIT_BYPASS===' 'porta = 0x8' 'lata = 0x0' \
			'===PRESS1_EARLY===' 'porta = 0x0' 'lata = 0x0' \
			'===PRESS1_LOW===' 'porta = 0x5' 'lata = 0x5' \
			'===ENGAGED===' 'porta = 0x9' 'lata = 0x1' \
			'===BYPASS_AGAIN===' 'porta = 0x8' 'lata = 0x0'
		;;
	*)
		printf 'unexpected gpsim command script: %s\n' "$script" >&2
		exit 64
		;;
esac
[ -z "${FAKE_GPSIM_STC_LOG:-}" ] || printf '%s\n' "$script" >> "$FAKE_GPSIM_STC_LOG"
# Recorded beside the stimulus so both logs carry one entry per COMPLETED
# invocation and can be compared by index.
[ -z "${FAKE_GPSIM_PROC_LOG:-}" ] || printf '%s\n' "$proc" >> "$FAKE_GPSIM_PROC_LOG"
[ -z "${FAKE_GPSIM_MARKER:-}" ] || : > "$FAKE_GPSIM_MARKER"
printf 'FAKE_GPSIM_SNAPSHOTS_COMPLETE\n'
case "${FAKE_GPSIM_MODE:-pass}" in
	exit) exit "${FAKE_GPSIM_EXIT:-7}" ;;
	sleep) sleep 5 ;;
esac
EOF
chmod 750 "$tools/timeout" "$tools/gpsim"

run_toggle() {
	PATH="$tools:$PATH" REAL_TIMEOUT="$REAL_TIMEOUT" \
		GPSIM="${GPSIM:-$tools/gpsim}" \
		GPSIM_TIMEOUT_SECONDS="${GPSIM_TIMEOUT_SECONDS:-2}" \
		"$ROOT/test/pic/run_gpsim_test.sh" "$hex" 0x1
}

run_power_on() {
	PATH="$tools:$PATH" REAL_TIMEOUT="$REAL_TIMEOUT" \
		GPSIM="${GPSIM:-$tools/gpsim}" \
		GPSIM_TIMEOUT_SECONDS="${GPSIM_TIMEOUT_SECONDS:-2}" \
		"$ROOT/test/pic/run_gpsim_power_on_pressed.sh" "$hex"
}

for wrapper in run_toggle run_power_on; do
	case "$wrapper" in
		run_toggle) expected_final='===BYPASS_AGAIN===' ;;
		*) expected_final='===PON_ENGAGED===' ;;
	esac
	"$wrapper" >/dev/null \
		|| { printf 'FAIL: %s rejected successful gpsim output\n' "$wrapper" >&2; exit 1; }
	checks=$((checks + 1))
	GPSIM_TIMEOUT_SECONDS=00.5 "$wrapper" >/dev/null \
		|| { printf 'FAIL: %s rejected a padded positive decimal timeout\n' "$wrapper" >&2; exit 1; }
	checks=$((checks + 1))

	if output=$(export FAKE_GPSIM_MODE=exit FAKE_GPSIM_EXIT=7; "$wrapper" 2>&1); then
		printf 'FAIL: %s accepted nonzero gpsim exit\n' "$wrapper" >&2
		exit 1
	fi
	[[ "$output" == *"gpsim exited with status 7"* \
		&& "$output" == *"$expected_final"* \
		&& "$output" == *"FAKE_GPSIM_SNAPSHOTS_COMPLETE"* ]] \
		|| { printf 'FAIL: %s reported the wrong nonzero-exit failure: %s\n' "$wrapper" "$output" >&2; exit 1; }
	checks=$((checks + 1))

	if output=$(export FAKE_GPSIM_MODE=sleep GPSIM_TIMEOUT_SECONDS=0.5; "$wrapper" 2>&1); then
		printf 'FAIL: %s accepted a timed-out gpsim run\n' "$wrapper" >&2
		exit 1
	fi
	[[ "$output" == *"gpsim exited with status 137"* \
		&& "$output" == *"$expected_final"* \
		&& "$output" == *"FAKE_GPSIM_SNAPSHOTS_COMPLETE"* ]] \
		|| { printf 'FAIL: %s reported the wrong timeout failure: %s\n' "$wrapper" "$output" >&2; exit 1; }
	checks=$((checks + 1))

	for invalid_timeout in 0 00.000 malformed -1 .5 1. 1e2; do
		gpsim_marker="$work/$wrapper.gpsim-called"
		timeout_marker="$work/$wrapper.timeout-called"
		rm -f "$gpsim_marker" "$timeout_marker"
		if output=$(export GPSIM_TIMEOUT_SECONDS="$invalid_timeout" \
				FAKE_GPSIM_MARKER="$gpsim_marker" \
				FAKE_TIMEOUT_MARKER="$timeout_marker"; "$wrapper" 2>&1); then
			printf 'FAIL: %s accepted invalid timeout %s\n' \
				"$wrapper" "$invalid_timeout" >&2
			exit 1
		fi
		[[ "$output" == *"GPSIM_TIMEOUT_SECONDS must be a positive decimal number"* ]] \
			|| { printf 'FAIL: %s reported the wrong invalid-timeout failure: %s\n' "$wrapper" "$output" >&2; exit 1; }
		[[ ! -e "$gpsim_marker" && ! -e "$timeout_marker" ]] \
			|| { printf 'FAIL: %s invoked timeout/gpsim for invalid timeout %s\n' "$wrapper" "$invalid_timeout" >&2; exit 1; }
		checks=$((checks + 1))
	done

	if output=$(export GPSIM="$tools/missing-gpsim" \
			GPSIM_TIMEOUT_SECONDS=0; "$wrapper" 2>&1); then
		printf 'FAIL: %s skipped an invalid timeout with gpsim absent\n' "$wrapper" >&2
		exit 1
	fi
	[[ "$output" == *"GPSIM_TIMEOUT_SECONDS must be a positive decimal number"* \
		&& "$output" != *"gpsim not installed"* ]] \
		|| { printf 'FAIL: %s validated gpsim before its timeout: %s\n' "$wrapper" "$output" >&2; exit 1; }
	checks=$((checks + 1))

	output=$(export GPSIM="$tools/missing-gpsim" GPSIM_TIMEOUT_SECONDS=2 \
		STRICT_TOOLS=; "$wrapper" 2>&1) \
		|| { printf 'FAIL: %s did not skip missing gpsim by default: %s\n' \
			"$wrapper" "$output" >&2; exit 1; }
	[[ "$output" == *"gpsim not installed"* && "$output" != *"STRICT_TOOLS=1:"* ]] \
		|| { printf 'FAIL: %s reported the wrong missing-gpsim skip: %s\n' \
			"$wrapper" "$output" >&2; exit 1; }
	checks=$((checks + 1))

	if output=$(export GPSIM="$tools/missing-gpsim" GPSIM_TIMEOUT_SECONDS=2 \
			STRICT_TOOLS=1; "$wrapper" 2>&1); then
		printf 'FAIL: %s accepted missing gpsim under STRICT_TOOLS=1\n' "$wrapper" >&2
		exit 1
	fi
	[[ "$output" == *"gpsim not installed"* && "$output" == *"::error::STRICT_TOOLS=1:"* ]] \
		|| { printf 'FAIL: %s reported the wrong strict missing-gpsim failure: %s\n' \
			"$wrapper" "$output" >&2; exit 1; }
	checks=$((checks + 1))
done

# Both wrappers source test/pic/gpsim_wrapper_common.sh for their scaffolding.
# `.` on a missing file returns non-zero but does NOT abort a script that is not
# under `set -e`, so each wrapper checks the file is readable first and dies with
# a specific message. Without that check the wrappers still exit non-zero today,
# but only because `set -u` trips over an unbound $PROC a few lines on -- an
# accident of line order, and one that reports "unbound variable" rather than the
# real problem. Pin the explicit guard by running each wrapper from a directory
# holding the wrapper and the stimuli but NOT the shared helper.
for wrapper_script in run_gpsim_test.sh run_gpsim_power_on_pressed.sh; do
	orphan="$work/orphan-$wrapper_script"
	mkdir -p "$orphan"
	cp "$ROOT/test/pic/$wrapper_script" "$orphan/"
	cp "$ROOT/test/pic/footswitch_toggle.stc" "$ROOT/test/pic/power_on_pressed.stc" "$orphan/"
	if output=$(PATH="$tools:$PATH" REAL_TIMEOUT="$REAL_TIMEOUT" \
			GPSIM="$tools/gpsim" GPSIM_TIMEOUT_SECONDS=2 \
			"$orphan/$wrapper_script" "$hex" 0x1 2>&1); then
		printf 'FAIL: %s passed without its shared helper\n' "$wrapper_script" >&2
		exit 1
	fi
	[[ "$output" == *"missing shared gpsim wrapper helper"* && "$output" != *"RESULT: PASS"* ]] \
		|| { printf 'FAIL: %s did not report the missing shared helper: %s\n' \
			"$wrapper_script" "$output" >&2; exit 1; }
	checks=$((checks + 1))
done

# Same-basename malformed stimuli used to receive canned passing snapshots
# because fake gpsim inspected only the filename. Require an exact ra3 token,
# not merely another pin or a name containing ra3 as a prefix.
for bad_pin in ra2 ra30; do
	bad_dir="$work/bad-$bad_pin"
	mkdir -p "$bad_dir"
	printf 'node n1\nattach n1 fsw %s\n' "$bad_pin" > "$bad_dir/footswitch_toggle.stc"
	if output=$(export PIC_GPSIM_STC="$bad_dir/footswitch_toggle.stc"; run_toggle 2>&1); then
		printf 'FAIL: toggle wrapper accepted footswitch attachment %s\n' "$bad_pin" >&2
		exit 1
	fi
	[[ "$output" == *"gpsim exited with status 65"* \
		&& "$output" == *"expected exactly one attach n1 fsw ra3"* ]] \
		|| { printf 'FAIL: wrong %s attachment produced the wrong failure: %s\n' \
			"$bad_pin" "$output" >&2; exit 1; }
	checks=$((checks + 1))
done

# The public Make target must validate configuration before its optional-tool
# skip. --old-file avoids building PIC images in this host-only regression.
repo_lock_id=$(stat -Lc '%d:%i' "$ROOT")
if output=$(
	unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL
	_MAKE_SERIAL_LOCK_HELD="$repo_lock_id" "${MAKE_CMD[@]}" --no-print-directory \
		-C "$ROOT" --old-file=pic10f322 pic10f322-test-gpsim STRICT_TOOLS= \
		GPSIM="$tools/missing-gpsim" GPSIM_TIMEOUT_SECONDS=0 2>&1
); then
	printf 'FAIL: pic10f322-test-gpsim skipped an invalid timeout\n' >&2
	exit 1
fi
[[ "$output" == *"GPSIM_TIMEOUT_SECONDS must be a positive decimal number"* \
	&& "$output" != *"gpsim not installed"* ]] \
	|| { printf 'FAIL: pic10f322-test-gpsim validated gpsim before its timeout: %s\n' "$output" >&2; exit 1; }
checks=$((checks + 1))

if output=$(
	unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL
	_MAKE_SERIAL_LOCK_HELD="$repo_lock_id" "${MAKE_CMD[@]}" --no-print-directory \
		-C "$ROOT" --old-file=pic10f322 pic10f322-test-gpsim STRICT_TOOLS=1 \
		GPSIM="$tools/missing-gpsim" GPSIM_TIMEOUT_SECONDS=2 2>&1
); then
	printf 'FAIL: pic10f322-test-gpsim accepted missing gpsim under STRICT_TOOLS=1\n' >&2
	exit 1
fi
[[ "$output" == *"gpsim not installed"* && "$output" == *"::error::STRICT_TOOLS=1:"* ]] \
	|| { printf 'FAIL: pic10f322-test-gpsim reported the wrong strict missing-gpsim failure: %s\n' "$output" >&2; exit 1; }
checks=$((checks + 1))

# Same for the PIC10F320 lane's public target. The wrappers themselves are
# SHARED -- the PIC10F320 merge folded onto these exact scripts rather than
# forking them (§4), so every check above already covers both chips. What is NOT
# otherwise covered is the mechanism that makes sharing possible:
# pic10f320-test-gpsim must override both PIC_GPSIM_PROC and the toggle stimulus,
# and must still validate its timeout before the optional-tool skip.
if output=$(
	unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL
	_MAKE_SERIAL_LOCK_HELD="$repo_lock_id" "${MAKE_CMD[@]}" --no-print-directory \
		-C "$ROOT" --old-file=pic10f320 pic10f320-test-gpsim STRICT_TOOLS= \
		GPSIM="$tools/missing-gpsim" GPSIM_TIMEOUT_SECONDS=0 2>&1
); then
	printf 'FAIL: pic10f320-test-gpsim skipped an invalid timeout\n' >&2
	exit 1
fi
[[ "$output" == *"GPSIM_TIMEOUT_SECONDS must be a positive decimal number"* \
	&& "$output" != *"gpsim not installed"* ]] \
	|| { printf 'FAIL: pic10f320-test-gpsim validated gpsim before its timeout: %s\n' "$output" >&2; exit 1; }
checks=$((checks + 1))

if output=$(
	unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL
	_MAKE_SERIAL_LOCK_HELD="$repo_lock_id" "${MAKE_CMD[@]}" --no-print-directory \
		-C "$ROOT" --old-file=pic10f320 pic10f320-test-gpsim STRICT_TOOLS=1 \
		GPSIM="$tools/missing-gpsim" GPSIM_TIMEOUT_SECONDS=2 2>&1
); then
	printf 'FAIL: pic10f320-test-gpsim accepted missing gpsim under STRICT_TOOLS=1\n' >&2
	exit 1
fi
[[ "$output" == *"gpsim not installed"* && "$output" == *"::error::STRICT_TOOLS=1:"* ]] \
	|| { printf 'FAIL: pic10f320-test-gpsim reported the wrong strict missing-gpsim failure: %s\n' "$output" >&2; exit 1; }
checks=$((checks + 1))

# The SHARED wrappers honour PIC_GPSIM_PROC. Checked BEHAVIOURALLY, by recording
# the -p argument the wrapper actually hands gpsim -- not by grepping the source,
# which a rename would slip past (a substring grep for PIC_GPSIM_PROC still
# matches PIC_GPSIM_PROC_RENAMED).
#
# This half proves only that the wrapper READS the variable. It cannot see
# whether the Makefile's lanes still WRITE it, and that gap was not theoretical:
# v0.9.8 renamed this read to PIC10F322_GPSIM_PROC and left all four Makefile
# writers spelling PIC_GPSIM_PROC, so pic10f320-test-gpsim simulated a PIC10F322
# and passed. Setting the variable here directly is what kept this check green
# through that. The public-target probes below close it from the other end.
cat > "$tools/proc-recording-gpsim" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for a in "$@"; do
	case "$a" in -p*) printf '%s\n' "${a#-p}" >> "${FAKE_PROC_LOG:?}" ;; esac
done
exit 1   # fail fast: we only care about the argv, not a full simulation
EOF
chmod 750 "$tools/proc-recording-gpsim"
# The wrapper refuses a missing image before it ever calls gpsim, so give it a
# file to find; its contents are irrelevant because the fake exits immediately.
: > "$work/probe.hex"
for probe_proc in p10f320 p10f322; do
	proc_log="$work/proc.$probe_proc"
	: > "$proc_log"
	(
		export GPSIM="$tools/proc-recording-gpsim" GPSIM_TIMEOUT_SECONDS=5 \
			FAKE_PROC_LOG="$proc_log" PIC_GPSIM_PROC="$probe_proc"
		"$ROOT/test/pic/run_gpsim_test.sh" "$work/probe.hex" 0x1 >/dev/null 2>&1 || true
	)
	grep -qx "$probe_proc" "$proc_log" \
		|| { printf 'FAIL: run_gpsim_test.sh did not pass -p%s to gpsim (saw: %s)\n' \
			"$probe_proc" "$(tr '\n' ' ' < "$proc_log")" >&2; exit 1; }
	checks=$((checks + 1))
done

# Exercise the PUBLIC PIC10F320 target and record both the stimulus and the
# processor handed to gpsim. The toggle stimulus is chip-specific because its
# cadence checkpoint differs; power-on-pressed is byte-identical and remains
# shared under test/pic/.
#
# The PROCESSOR assertion is the half the wrapper-level probe above cannot make.
# Nothing is overridden here: the lane is asked for its default behaviour and
# must reach gpsim with p10f320. That is non-vacuous BECAUSE the shared
# wrapper's fallback is p10f322 -- sever the Makefile's PIC_GPSIM_PROC= prefix
# and this reports p10f322 rather than passing on a default that happens to be
# right, which is exactly how the v0.9.8 regression survived.
pic10f320_build="$work/build_pic10f320"
mkdir -p "$pic10f320_build"
: > "$pic10f320_build/bypass-pic10f320-tq2_l2_5v_relay.hex"
stc_log="$work/pic10f320.stc.log"
proc_log="$work/pic10f320.proc.log"
: > "$stc_log"; : > "$proc_log"
if ! output=$(
	unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL
	FAKE_GPSIM_STC_LOG="$stc_log" FAKE_GPSIM_PROC_LOG="$proc_log" \
	_MAKE_SERIAL_LOCK_HELD="$repo_lock_id" "${MAKE_CMD[@]}" --no-print-directory \
		-C "$ROOT" --old-file=pic10f320 pic10f320-test-gpsim STRICT_TOOLS= \
		PIC10F320_VARIANT=tq2_l2_5v_relay PIC10F320_BUILD_DIR="$pic10f320_build" \
		GPSIM="$tools/gpsim" GPSIM_TIMEOUT_SECONDS=2 2>&1
); then
	printf 'FAIL: pic10f320-test-gpsim rejected the fake-gpsim routing probe: %s\n' "$output" >&2
	exit 1
fi
mapfile -t routed_stc < "$stc_log"
if [ "${#routed_stc[@]}" -ne 2 ] \
		|| [ "${routed_stc[0]:-}" != "$ROOT/test/pic10f320/gpsim/footswitch_toggle.stc" ] \
		|| [ "${routed_stc[1]:-}" != "test/pic/power_on_pressed.stc" ]; then
	printf 'FAIL: pic10f320-test-gpsim routed the wrong stimuli: %s\n' \
		"$(tr '\n' ' ' < "$stc_log")" >&2
	exit 1
fi
checks=$((checks + 1))

expected_320_proc=$(
	unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL
	_MAKE_SERIAL_LOCK_HELD="$repo_lock_id" "${MAKE_CMD[@]}" -s --no-print-directory \
		-C "$ROOT" print-PIC10F320_GPSIM_PROC
)
[ -n "$expected_320_proc" ] \
	|| { printf 'FAIL: PIC10F320_GPSIM_PROC is empty; the probe has nothing to assert\n' >&2; exit 1; }
# Both probes are only as strong as the distance between the value they expect
# and the value the wrapper produces on its own, so read that fallback rather
# than restating it -- and fail if it cannot be read at all. An extraction that
# quietly returns nothing turns both guards below into comparisons against the
# empty string, which is the same silent pass they exist to prevent.
wrapper_fallback=$(sed -n 's/^PROC="${PIC_GPSIM_PROC:-\(.*\)}"$/\1/p' \
	"$ROOT/test/pic/gpsim_wrapper_common.sh")
[ -n "$wrapper_fallback" ] \
	|| { printf 'FAIL: could not read the shared wrapper PIC_GPSIM_PROC fallback; the pattern has rotted\n' >&2; exit 1; }
checks=$((checks + 1))
[ "$expected_320_proc" != "$wrapper_fallback" ] \
	|| { printf 'FAIL: PIC10F320_GPSIM_PROC equals the wrapper fallback (%s), so this probe cannot fail\n' \
		"$wrapper_fallback" >&2; exit 1; }
checks=$((checks + 1))
mapfile -t routed_proc < "$proc_log"
if [ "${#routed_proc[@]}" -ne 2 ] \
		|| [ "${routed_proc[0]:-}" != "$expected_320_proc" ] \
		|| [ "${routed_proc[1]:-}" != "$expected_320_proc" ]; then
	printf 'FAIL: pic10f320-test-gpsim reached gpsim with the wrong processor: expected %s twice, saw: %s\n' \
		"$expected_320_proc" "$(tr '\n' ' ' < "$proc_log")" >&2
	printf '      the lane is simulating the wrong part; check the PIC_GPSIM_PROC= prefixes in the Makefile recipe\n' >&2
	exit 1
fi
checks=$((checks + 1))

# The same end-to-end claim for the PIC10F322 lane, which needs a probe VALUE to
# be testable at all: its correct processor IS the shared wrapper's fallback, so
# a severed PIC_GPSIM_PROC= prefix produces the right answer for the wrong
# reason and no default-behaviour check can tell the two apart. Handing the lane
# a value that is neither part's makes the link carry something only the
# Makefile could have supplied. Setting it on the make command line does not
# short-circuit the check: make exports command-line variables to the recipe's
# environment, but under the name PIC10F322_GPSIM_PROC, which the wrapper does
# not read -- the only route to PIC_GPSIM_PROC is the recipe's own prefix.
#
# Only the relay image is created, so the other two output stages take the
# documented "XC8 absent" skip and the lane makes exactly two gpsim calls, as
# the PIC10F320 probe above does. The fake's canned snapshots are the relay
# stage's.
pic10f322_build="$work/build_pic10f322"
mkdir -p "$pic10f322_build"
: > "$pic10f322_build/bypass-pic10f322-tq2_l2_5v_relay.hex"
proc_log_322="$work/pic10f322.proc.log"
: > "$proc_log_322"
probe_322_proc=p10f322-probe
[ "$probe_322_proc" != "$wrapper_fallback" ] \
	|| { printf 'FAIL: the PIC10F322 probe value equals the wrapper fallback (%s), so this probe cannot fail\n' \
		"$wrapper_fallback" >&2; exit 1; }
checks=$((checks + 1))
if ! output=$(
	unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL
	FAKE_GPSIM_PROC_LOG="$proc_log_322" \
	_MAKE_SERIAL_LOCK_HELD="$repo_lock_id" "${MAKE_CMD[@]}" --no-print-directory \
		-C "$ROOT" --old-file=pic10f322 pic10f322-test-gpsim STRICT_TOOLS= \
		PIC10F322_BUILD_DIR="$pic10f322_build" \
		PIC10F322_GPSIM_PROC="$probe_322_proc" \
		GPSIM="$tools/gpsim" GPSIM_TIMEOUT_SECONDS=2 2>&1
); then
	printf 'FAIL: pic10f322-test-gpsim rejected the fake-gpsim processor probe: %s\n' "$output" >&2
	exit 1
fi
mapfile -t routed_proc_322 < "$proc_log_322"
if [ "${#routed_proc_322[@]}" -ne 2 ] \
		|| [ "${routed_proc_322[0]:-}" != "$probe_322_proc" ] \
		|| [ "${routed_proc_322[1]:-}" != "$probe_322_proc" ]; then
	printf 'FAIL: pic10f322-test-gpsim did not carry PIC10F322_GPSIM_PROC through to gpsim: expected %s twice, saw: %s\n' \
		"$probe_322_proc" "$(tr '\n' ' ' < "$proc_log_322")" >&2
	printf '      check the PIC_GPSIM_PROC= prefixes in the pic10f322-test-gpsim recipe\n' >&2
	exit 1
fi
checks=$((checks + 1))

printf 'gpsim wrapper validation: %d checks, 0 failures\n' "$checks"
