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

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/test-gpsim-wrappers.XXXXXX")
trap 'rm -rf "$work"' EXIT
tools="$work/tools"
hex="$work/firmware.hex"
checks=0
unset FAKE_GPSIM_MODE FAKE_GPSIM_EXIT FAKE_GPSIM_MARKER FAKE_GPSIM_STC_LOG \
	FAKE_GPSIM_PROC_LOG FAKE_GPSIM_REGS_LOG FAKE_GPSIM_HEX_LOG \
	FAKE_GPSIM_FOOTSW_PIN FAKE_GPSIM_TOGGLE_LINES FAKE_GPSIM_PIC12F675_MATRIX \
	FAKE_GPSIM_PON_LINES PIC_GPSIM_REGS PIC_GPSIM_PON_STC \
	FAKE_TIMEOUT_MARKER GPSIM GPSIM_TIMEOUT_SECONDS PIC_GPSIM_PROC PIC_GPSIM_STC \
	MUTATION_INFRA_MARKER STRICT_TOOLS
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
image=
while [ "$#" -gt 0 ]; do
	case "$1" in
		-c)  script=$2; shift 2 ;;
		-p*) proc=${1#-p}; shift ;;
		-*)  shift ;;
		*)   image=$1; shift ;;
	esac
done
if [ ! -f "$script" ]; then
	printf 'gpsim command script not found: %s\n' "$script" >&2
	exit 65
fi
# The footswitch pin and the snapshot register names are per-PART, not fixed:
# the PIC10F32x parts attach to ra3 and report porta/lata, the PIC12F675
# attaches to gpio5 and has no LATx at all. Defaulted to the 10F32x spelling so
# every pre-existing check reads unchanged.
pin=${FAKE_GPSIM_FOOTSW_PIN:-ra3}
fsw_attach_count=$(awk '$1 == "attach" && $2 == "n1" && $3 == "fsw" { count++ } END { print count + 0 }' "$script")
pin_attach_count=$(awk -v pin="$pin" '$1 == "attach" && $2 == "n1" && $3 == "fsw" && $4 == pin && NF == 4 { count++ } END { print count + 0 }' "$script")
if [ "$fsw_attach_count" -ne 1 ] || [ "$pin_attach_count" -ne 1 ]; then
	printf 'invalid footswitch attachment: expected exactly one attach n1 fsw %s in %s\n' \
		"$pin" "$script" >&2
	exit 65
fi
# The canned snapshots are the PIC10F32x's (two registers, RA3/RA0 bit
# positions). A part whose register identity differs supplies its own block --
# that is what proves PIC_GPSIM_REGS actually reaches the parse, rather than the
# wrapper happening to find porta/lata regardless.
case "$script" in
	*power_on_pressed.stc)
		if [ -n "${FAKE_GPSIM_PON_LINES:-}" ]; then
			printf '%s\n' "$FAKE_GPSIM_PON_LINES"
		else
			printf '%s\n' \
				'===PON_HELD===' 'porta = 0x0' 'lata = 0x0' \
				'===PON_RELEASED===' 'porta = 0x8' 'lata = 0x0' \
				'===PON_ENGAGED===' 'porta = 0x9' 'lata = 0x1'
		fi
		;;
	*footswitch_toggle.stc)
		if [ -n "${FAKE_GPSIM_PIC12F675_MATRIX:-}" ]; then
			case "$image" in
				*-cd4053_simple_simcal.hex) engaged=0x23 ;;
				*-cd4053_with_mute_simcal.hex) engaged=0x27 ;;
				*-tq2_l2_5v_relay_simcal.hex) engaged=0x21 ;;
				*) printf 'unexpected PIC12F675 simulator image: %s\n' "$image" >&2; exit 65 ;;
			esac
			printf '%s\n' \
				'===INIT_BYPASS===' 'gpio = 0x20' \
				'===PRESS1_EARLY===' 'gpio = 0x0' \
				'===PRESS1_LOW===' 'gpio = 0x1' \
				'===ENGAGED===' "gpio = $engaged" \
				'===BYPASS_AGAIN===' 'gpio = 0x20'
		elif [ -n "${FAKE_GPSIM_TOGGLE_LINES:-}" ]; then
			printf '%s\n' "$FAKE_GPSIM_TOGGLE_LINES"
		else
			printf '%s\n' \
				'===INIT_BYPASS===' 'porta = 0x8' 'lata = 0x0' \
				'===PRESS1_EARLY===' 'porta = 0x0' 'lata = 0x0' \
				'===PRESS1_LOW===' 'porta = 0x5' 'lata = 0x5' \
				'===ENGAGED===' 'porta = 0x9' 'lata = 0x1' \
				'===BYPASS_AGAIN===' 'porta = 0x8' 'lata = 0x0'
		fi
		;;
	*)
		printf 'unexpected gpsim command script: %s\n' "$script" >&2
		exit 64
		;;
esac
[ -z "${FAKE_GPSIM_STC_LOG:-}" ] || printf '%s\n' "$script" >> "$FAKE_GPSIM_STC_LOG"
# Recorded together so every route log carries one entry per COMPLETED invocation
# and can be compared by index.
[ -z "${FAKE_GPSIM_PROC_LOG:-}" ] || printf '%s\n' "$proc" >> "$FAKE_GPSIM_PROC_LOG"
[ -z "${FAKE_GPSIM_REGS_LOG:-}" ] || printf '%s\n' "${PIC_GPSIM_REGS:-}" >> "$FAKE_GPSIM_REGS_LOG"
[ -z "${FAKE_GPSIM_HEX_LOG:-}" ] || printf '%s\n' "$image" >> "$FAKE_GPSIM_HEX_LOG"
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

	infra_marker="$work/$wrapper.mutation-infrastructure"
	rm -f "$infra_marker"
	if output=$(export FAKE_GPSIM_MODE=exit FAKE_GPSIM_EXIT=7 \
			MUTATION_INFRA_MARKER="$infra_marker"; "$wrapper" 2>&1); then
		printf 'FAIL: %s accepted nonzero gpsim exit\n' "$wrapper" >&2
		exit 1
	fi
	[[ "$output" == *"gpsim exited with status 7"* \
		&& "$output" == *"$expected_final"* \
		&& "$output" == *"FAKE_GPSIM_SNAPSHOTS_COMPLETE"* \
		&& ! -e "$infra_marker" ]] \
		|| { printf 'FAIL: %s reported the wrong nonzero-exit failure: %s\n' "$wrapper" "$output" >&2; exit 1; }
	checks=$((checks + 1))

	if output=$(export FAKE_GPSIM_MODE=sleep GPSIM_TIMEOUT_SECONDS=0.5 \
			MUTATION_INFRA_MARKER="$infra_marker"; "$wrapper" 2>&1); then
		printf 'FAIL: %s accepted a timed-out gpsim run\n' "$wrapper" >&2
		exit 1
	fi
	[[ "$output" == *"gpsim exited with status 137"* \
		&& "$output" == *"$expected_final"* \
		&& "$output" == *"FAKE_GPSIM_SNAPSHOTS_COMPLETE"* \
		&& -f "$infra_marker" ]] \
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
# forking them, so every check above already covers both chips. What is NOT
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
	unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL \
		PIC12F675_GPSIM_PROC PIC12F675_GPSIM_REGS \
		PIC12F675_GPSIM_TOGGLE_STC PIC12F675_GPSIM_PON_STC
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

# --- register-identity channel (PIC_GPSIM_REGS) -------------------------------
# The wrappers learn which registers to snapshot, which bits carry the footswitch
# and LED, and which output bits a variant expectation covers, from a sourced
# fragment. Three things have to hold, and none of them is visible from a passing
# PIC10F32x run -- that lane would pass just the same if the channel were dead,
# because its values ARE the defaults.

# 1. A fragment that cannot be read is a hard failure, not a silent fall back to
#    the default identity. Falling back would run another part's masks against
#    this part's registers, which is the one way in here to score a wrong pass.
for wrapper in run_toggle run_power_on; do
	if output=$(export PIC_GPSIM_REGS="$work/absent-regs.sh"; "$wrapper" 2>&1); then
		printf 'FAIL: %s accepted an unreadable register fragment\n' "$wrapper" >&2
		exit 1
	fi
	[[ "$output" == *"missing gpsim register identity fragment"* && "$output" != *"RESULT: PASS"* ]] \
		|| { printf 'FAIL: %s did not report the unreadable register fragment: %s\n' \
			"$wrapper" "$output" >&2; exit 1; }
	checks=$((checks + 1))
done

# 2. Environment values cannot complete an empty fragment. The identity channel
#    is deliberately one file rather than nine independent overrides, so every
#    required name must come from that file even when the caller exports a full,
#    internally consistent identity. Before the wrapper cleared these names, the
#    empty fragment below inherited the PIC10F32x defaults and both scenarios
#    passed outright.
empty_regs="$work/empty-regs.sh"
: > "$empty_regs"
for wrapper in run_toggle run_power_on; do
	if output=$(export PIC_GPSIM_REGS="$empty_regs" \
			GPSIM_PORT_REG=porta GPSIM_PORT_LABEL=PORTA \
			GPSIM_LATCH_REG=lata GPSIM_LATCH_LABEL=LATA \
			GPSIM_FOOTSW_MASK=0x8 GPSIM_FOOTSW_LABEL=RA3 \
			GPSIM_LED_MASK=0x1 GPSIM_LED_LABEL=RA0 \
			GPSIM_OUTPUT_MASK=0xFF; "$wrapper" 2>&1); then
		printf 'FAIL: %s completed an empty register fragment from inherited identity values\n' \
			"$wrapper" >&2
		exit 1
	fi
	[[ "$output" == *"does not define GPSIM_PORT_REG"* && "$output" != *"RESULT: PASS"* ]] \
		|| { printf 'FAIL: %s did not reject the empty inherited-identity fragment first: %s\n' \
			"$wrapper" "$output" >&2; exit 1; }
	checks=$((checks + 1))
done

# 3. A fragment that defines only SOME of the identity is refused, by name. This
#    is the partial-override hazard the single-file design exists to prevent: a
#    fragment carrying new register names but stale masks would read the right
#    register and test the wrong bit.
partial="$work/partial-regs.sh"
grep -v '^GPSIM_LED_MASK' "$ROOT/test/pic/pic12f675_gpsim_regs.sh" > "$partial"
for wrapper in run_toggle run_power_on; do
	if output=$(export PIC_GPSIM_REGS="$partial"; "$wrapper" 2>&1); then
		printf 'FAIL: %s accepted a fragment missing GPSIM_LED_MASK\n' "$wrapper" >&2
		exit 1
	fi
	[[ "$output" == *"does not define GPSIM_LED_MASK"* && "$output" != *"RESULT: PASS"* ]] \
		|| { printf 'FAIL: %s did not name the missing identity variable: %s\n' \
			"$wrapper" "$output" >&2; exit 1; }
	checks=$((checks + 1))
done

# 4. End-to-end routing through the REAL shipped PIC12F675 fragment and the REAL
#    PIC12F675 stimuli: a part with one register instead of two, the footswitch on
#    gpio5 instead of ra3, and an output mask that matters (GPIO carries the
#    footswitch bit, so an unmasked comparison would fail wherever the switch is
#    released). Fake gpsim asserts the stimulus attaches to gpio5, and emits only
#    `gpio` lines -- so a wrapper still reaching for porta/lata finds nothing and
#    fails on missing snapshots.
pic12f675_toggle=$'===INIT_BYPASS===\ngpio = 0x20\n===PRESS1_EARLY===\ngpio = 0x0\n===PRESS1_LOW===\ngpio = 0x1\n===ENGAGED===\ngpio = 0x21\n===BYPASS_AGAIN===\ngpio = 0x20'
pic12f675_gp4_high=$'===INIT_BYPASS===\ngpio = 0x20\n===PRESS1_EARLY===\ngpio = 0x0\n===PRESS1_LOW===\ngpio = 0x1\n===ENGAGED===\ngpio = 0x31\n===BYPASS_AGAIN===\ngpio = 0x20'
pic12f675_pon=$'===PON_HELD===\ngpio = 0x0\n===PON_RELEASED===\ngpio = 0x20\n===PON_ENGAGED===\ngpio = 0x21'
if ! output=$(
		export PIC_GPSIM_REGS="$ROOT/test/pic/pic12f675_gpsim_regs.sh"
		export PIC_GPSIM_STC="$ROOT/test/pic/pic12f675_footswitch_toggle.stc"
		export FAKE_GPSIM_FOOTSW_PIN=gpio5
		export FAKE_GPSIM_TOGGLE_LINES="$pic12f675_toggle"
		run_toggle 2>&1); then
	printf 'FAIL: toggle wrapper rejected the PIC12F675 identity: %s\n' "$output" >&2
	exit 1
fi
[[ "$output" == *"RESULT: PASS"* && "$output" == *"(GP5=1)"* && "$output" == *"full GPIO == 0x1"* ]] \
	|| { printf 'FAIL: toggle wrapper did not adopt the PIC12F675 labels/masks: %s\n' "$output" >&2; exit 1; }
checks=$((checks + 1))

if ! output=$(
		export PIC_GPSIM_REGS="$ROOT/test/pic/pic12f675_gpsim_regs.sh"
		export PIC_GPSIM_PON_STC="$ROOT/test/pic/pic12f675_power_on_pressed.stc"
		export FAKE_GPSIM_FOOTSW_PIN=gpio5
		export FAKE_GPSIM_PON_LINES="$pic12f675_pon"
		run_power_on 2>&1); then
	printf 'FAIL: power-on wrapper rejected the PIC12F675 identity: %s\n' "$output" >&2
	exit 1
fi
[[ "$output" == *"RESULT: PASS"* && "$output" == *"(GP5=0)"* ]] \
	|| { printf 'FAIL: power-on wrapper did not adopt the PIC12F675 labels: %s\n' "$output" >&2; exit 1; }
checks=$((checks + 1))

# 5. Exercise the PUBLIC PIC12F675 target and require its complete route to reach
#    fake gpsim. The direct checks above prove the shared wrappers READ the
#    register identity and two stimulus channels; this proves the Make recipe
#    WRITES all of them, along with the processor and complete image matrix. All
#    three simulator images are present, so the lane must make exactly six calls
#    in variant/scenario order.
#
#    The image name is load-bearing: this part cannot reach main() without the
#    factory calibration word, so the lane must consume *_simcal.hex from the
#    isolated simcal directory and never the shipping image beside it.
pic12f675_build="$work/build_pic12f675"
pic12f675_simcal="$pic12f675_build/simcal"
mkdir -p "$pic12f675_simcal"
pic12f675_hexes=(
	"$pic12f675_simcal/bypass-pic12f675-cd4053_simple_simcal.hex"
	"$pic12f675_simcal/bypass-pic12f675-cd4053_with_mute_simcal.hex"
	"$pic12f675_simcal/bypass-pic12f675-tq2_l2_5v_relay_simcal.hex"
)
pic12f675_extra="$pic12f675_simcal/unexpected_simcal.hex"
pic12f675_hidden_extra="$pic12f675_simcal/.unexpected_simcal.hex"

write_pic12f675_image() {
	# Minimal valid derived PIC12F675 image: CALL 0x3FF plus the injected
	# mid-scale RETLW calibration record. This is a matrix the real producer
	# could publish, even though fake gpsim does not parse its instructions.
	printf '%s\n' \
		':040000000028FF23B2' \
		':02400E009E38DA' \
		':0207FE00803445' \
		':00000001FF' > "$1"
}

write_pic12f675_matrix() {
	local mask=$1 i
	rm -rf "${pic12f675_hexes[@]}" "$pic12f675_extra" "$pic12f675_hidden_extra"
	for i in "${!pic12f675_hexes[@]}"; do
		if [ $((mask & (1 << i))) -ne 0 ]; then
			write_pic12f675_image "${pic12f675_hexes[$i]}"
		fi
	done
}

stc_log_675="$work/pic12f675.stc.log"
proc_log_675="$work/pic12f675.proc.log"
regs_log_675="$work/pic12f675.regs.log"
hex_log_675="$work/pic12f675.hex.log"

run_pic12f675_public() {
	(
		unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL \
			PIC12F675_GPSIM_PROC PIC12F675_GPSIM_REGS \
			PIC12F675_GPSIM_TOGGLE_STC PIC12F675_GPSIM_PON_STC
		FAKE_GPSIM_STC_LOG="$stc_log_675" FAKE_GPSIM_PROC_LOG="$proc_log_675" \
			FAKE_GPSIM_REGS_LOG="$regs_log_675" FAKE_GPSIM_HEX_LOG="$hex_log_675" \
			FAKE_GPSIM_MARKER="${route_marker_675:-}" \
			FAKE_GPSIM_FOOTSW_PIN=gpio5 FAKE_GPSIM_PIC12F675_MATRIX=1 \
			FAKE_GPSIM_PON_LINES="$pic12f675_pon" \
		_MAKE_SERIAL_LOCK_HELD="$repo_lock_id" "${MAKE_CMD[@]}" --no-print-directory \
			-C "$ROOT" --old-file=pic12f675-simcal pic12f675-test-gpsim STRICT_TOOLS= \
			PIC12F675_BUILD_DIR="$pic12f675_build" \
			GPSIM="$tools/gpsim" GPSIM_TIMEOUT_SECONDS=2
	)
}

write_pic12f675_matrix 7
: > "$stc_log_675"; : > "$proc_log_675"; : > "$regs_log_675"; : > "$hex_log_675"
if ! output=$(run_pic12f675_public 2>&1); then
	printf 'FAIL: pic12f675-test-gpsim rejected the fake-gpsim routing probe: %s\n' "$output" >&2
	exit 1
fi

mapfile -t routed_stc_675 < "$stc_log_675"
expected_stc_675=()
expected_hex_675=()
for pic12f675_hex in "${pic12f675_hexes[@]}"; do
	expected_stc_675+=(
		"$ROOT/test/pic/pic12f675_footswitch_toggle.stc"
		"$ROOT/test/pic/pic12f675_power_on_pressed.stc"
	)
	expected_hex_675+=("$pic12f675_hex" "$pic12f675_hex")
done
if [ "${#routed_stc_675[@]}" -ne 6 ]; then
	printf 'FAIL: pic12f675-test-gpsim routed the wrong stimuli or invocation count: %s\n' \
		"$(tr '\n' ' ' < "$stc_log_675")" >&2
	exit 1
fi
for i in "${!expected_stc_675[@]}"; do
	[ "${routed_stc_675[$i]}" = "${expected_stc_675[$i]}" ] \
		|| { printf 'FAIL: pic12f675-test-gpsim routed stimulus %d as %s, expected %s\n' \
			"$i" "${routed_stc_675[$i]}" "${expected_stc_675[$i]}" >&2; exit 1; }
done
checks=$((checks + 1))

[ p12f675 != "$wrapper_fallback" ] \
	|| { printf 'FAIL: the PIC12F675 processor equals the wrapper fallback (%s), so this probe cannot fail\n' \
		"$wrapper_fallback" >&2; exit 1; }
checks=$((checks + 1))
mapfile -t routed_proc_675 < "$proc_log_675"
if [ "${#routed_proc_675[@]}" -ne 6 ]; then
	printf 'FAIL: pic12f675-test-gpsim reached gpsim with the wrong processor or invocation count: %s\n' \
		"$(tr '\n' ' ' < "$proc_log_675")" >&2
	exit 1
fi
for routed in "${routed_proc_675[@]}"; do
	[ "$routed" = p12f675 ] \
		|| { printf 'FAIL: pic12f675-test-gpsim reached gpsim with processor %s\n' "$routed" >&2; exit 1; }
done
checks=$((checks + 1))

mapfile -t routed_regs_675 < "$regs_log_675"
if [ "${#routed_regs_675[@]}" -ne 6 ]; then
	printf 'FAIL: pic12f675-test-gpsim routed the wrong register identity or invocation count: %s\n' \
		"$(tr '\n' ' ' < "$regs_log_675")" >&2
	exit 1
fi
for routed in "${routed_regs_675[@]}"; do
	[ "$routed" = "$ROOT/test/pic/pic12f675_gpsim_regs.sh" ] \
		|| { printf 'FAIL: pic12f675-test-gpsim routed register identity %s\n' "$routed" >&2; exit 1; }
done
checks=$((checks + 1))

mapfile -t routed_hex_675 < "$hex_log_675"
if [ "${#routed_hex_675[@]}" -ne 6 ]; then
	printf 'FAIL: pic12f675-test-gpsim routed the wrong simulator image or invocation count: %s\n' \
		"$(tr '\n' ' ' < "$hex_log_675")" >&2
	exit 1
fi
for i in "${!expected_hex_675[@]}"; do
	[ "${routed_hex_675[$i]}" = "${expected_hex_675[$i]}" ] \
		|| { printf 'FAIL: pic12f675-test-gpsim routed image %d as %s, expected %s\n' \
			"$i" "${routed_hex_675[$i]}" "${expected_hex_675[$i]}" >&2; exit 1; }
done
checks=$((checks + 1))

# Every nonempty proper subset of the three images is a hard failure before
# gpsim is called. Exhausting masks 1..6 prevents a check that happens to reject
# only one missing basename or only the one-image case from claiming the matrix.
route_marker_675="$work/pic12f675.gpsim-called"
for mask in 1 2 3 4 5 6; do
	write_pic12f675_matrix "$mask"
	rm -f "$route_marker_675"
	if output=$(run_pic12f675_public 2>&1); then
		printf 'FAIL: pic12f675-test-gpsim accepted partial simulator-image mask %d\n' "$mask" >&2
		exit 1
	fi
	[[ "$output" == *"simulator image matrix is partial"* && ! -e "$route_marker_675" ]] \
		|| { printf 'FAIL: partial simulator-image mask %d produced the wrong result: %s\n' \
			"$mask" "$output" >&2; exit 1; }
	checks=$((checks + 1))
done

# The empty set remains the intentional no-XC8 skip, but it must not call gpsim.
write_pic12f675_matrix 0
rm -f "$route_marker_675"
if ! output=$(run_pic12f675_public 2>&1); then
	printf 'FAIL: pic12f675-test-gpsim rejected the empty simulator-image skip: %s\n' "$output" >&2
	exit 1
fi
[[ "$output" == *"no PIC12F675 simulator images"* && ! -e "$route_marker_675" ]] \
	|| { printf 'FAIL: empty PIC12F675 simulator-image set did not skip before gpsim: %s\n' "$output" >&2; exit 1; }
checks=$((checks + 1))

# Existing paths are not enough: each expected member must be nonempty, regular,
# and not a symlink, and no unregistered *_simcal.hex may join the exact set.
write_pic12f675_matrix 7
: > "${pic12f675_hexes[0]}"
rm -f "$route_marker_675"
if output=$(run_pic12f675_public 2>&1); then
	printf 'FAIL: pic12f675-test-gpsim accepted an empty simulator image\n' >&2
	exit 1
fi
[[ "$output" == *"simulator image is empty, a symlink, or not a regular file"* \
	&& ! -e "$route_marker_675" ]] \
	|| { printf 'FAIL: empty PIC12F675 simulator image produced the wrong result: %s\n' "$output" >&2; exit 1; }
checks=$((checks + 1))

write_pic12f675_matrix 7
rm -f "${pic12f675_hexes[0]}"
ln -s "${pic12f675_hexes[1]}" "${pic12f675_hexes[0]}"
rm -f "$route_marker_675"
if output=$(run_pic12f675_public 2>&1); then
	printf 'FAIL: pic12f675-test-gpsim accepted a symlink simulator image\n' >&2
	exit 1
fi
[[ "$output" == *"simulator image is empty, a symlink, or not a regular file"* \
	&& ! -e "$route_marker_675" ]] \
	|| { printf 'FAIL: symlink PIC12F675 simulator image produced the wrong result: %s\n' "$output" >&2; exit 1; }
checks=$((checks + 1))

write_pic12f675_matrix 7
write_pic12f675_image "$pic12f675_extra"
rm -f "$route_marker_675"
if output=$(run_pic12f675_public 2>&1); then
	printf 'FAIL: pic12f675-test-gpsim accepted an unexpected simulator image\n' >&2
	exit 1
fi
[[ "$output" == *"unexpected PIC12F675 simulator image outside the exact matrix"* \
	&& ! -e "$route_marker_675" ]] \
	|| { printf 'FAIL: unexpected PIC12F675 simulator image produced the wrong result: %s\n' "$output" >&2; exit 1; }
checks=$((checks + 1))

write_pic12f675_matrix 7
rm -f "${pic12f675_hexes[0]}"
mkdir "${pic12f675_hexes[0]}"
rm -f "$route_marker_675"
if output=$(run_pic12f675_public 2>&1); then
	printf 'FAIL: pic12f675-test-gpsim accepted a directory as a simulator image\n' >&2
	exit 1
fi
[[ "$output" == *"simulator image is empty, a symlink, or not a regular file"* \
	&& ! -e "$route_marker_675" ]] \
	|| { printf 'FAIL: directory PIC12F675 simulator image produced the wrong result: %s\n' "$output" >&2; exit 1; }
checks=$((checks + 1))

write_pic12f675_matrix 7
write_pic12f675_image "$pic12f675_hidden_extra"
rm -f "$route_marker_675"
if output=$(run_pic12f675_public 2>&1); then
	printf 'FAIL: pic12f675-test-gpsim accepted a hidden unexpected simulator image\n' >&2
	exit 1
fi
[[ "$output" == *"unexpected PIC12F675 simulator image outside the exact matrix"* \
	&& ! -e "$route_marker_675" ]] \
	|| { printf 'FAIL: hidden unexpected PIC12F675 simulator image produced the wrong result: %s\n' "$output" >&2; exit 1; }
checks=$((checks + 1))

# 6. The output mask is load-bearing, not decoration: with the PIC12F675 identity
#    the ENGAGED snapshot is 0x21 (LED plus the released footswitch bit) and the
#    variant expectation is 0x1. Drop the mask -- by borrowing the 10F32x
#    fragment's 0xFF -- and the same run must FAIL, which is what proves the
#    comparison is masked rather than accidentally equal.
unmasked="$work/unmasked-regs.sh"
sed 's/^GPSIM_OUTPUT_MASK=.*/GPSIM_OUTPUT_MASK=0xFF/' \
	"$ROOT/test/pic/pic12f675_gpsim_regs.sh" > "$unmasked"
if output=$(
		export PIC_GPSIM_REGS="$unmasked"
		export PIC_GPSIM_STC="$ROOT/test/pic/pic12f675_footswitch_toggle.stc"
		export FAKE_GPSIM_FOOTSW_PIN=gpio5
		export FAKE_GPSIM_TOGGLE_LINES="$pic12f675_toggle"
		run_toggle 2>&1); then
	printf 'FAIL: toggle wrapper passed with the output mask removed: %s\n' "$output" >&2
	exit 1
fi
[[ "$output" == *"GPIO should be 0x1 for this variant, got 0x21"* ]] \
	|| { printf 'FAIL: removing the output mask produced the wrong failure: %s\n' "$output" >&2; exit 1; }
checks=$((checks + 1))

# The PIC12F675 output mask must include parked GP4, not merely mask away GP5.
# Raise only GP4 in the settled ENGAGED snapshot: 0x17 catches it, while the
# stale pre-policy 0x07 mask would reduce 0x31 to the expected 0x1 and pass.
if output=$(
		export PIC_GPSIM_REGS="$ROOT/test/pic/pic12f675_gpsim_regs.sh"
		export PIC_GPSIM_STC="$ROOT/test/pic/pic12f675_footswitch_toggle.stc"
		export FAKE_GPSIM_FOOTSW_PIN=gpio5
		export FAKE_GPSIM_TOGGLE_LINES="$pic12f675_gp4_high"
		run_toggle 2>&1); then
	printf 'FAIL: toggle wrapper accepted parked GP4 high with the PIC12F675 output mask\n' >&2
	exit 1
fi
[[ "$output" == *"GPIO should be 0x1 for this variant, got 0x31"* ]] \
	|| { printf 'FAIL: parked-GP4 output-mask probe produced the wrong failure: %s\n' "$output" >&2; exit 1; }
checks=$((checks + 1))

# 7. The per-part power-on stimulus really is a separate channel from the toggle
#    one. Pointing PIC_GPSIM_STC at a power-on script must NOT redirect the
#    power-on wrapper, because a single "the stimulus" variable for two scenarios
#    is how a lane ends up running one script through the other's wrapper.
if ! output=$(
		export PIC_GPSIM_STC="$ROOT/test/pic/pic12f675_power_on_pressed.stc"
		run_power_on 2>&1); then
	printf 'FAIL: power-on wrapper followed PIC_GPSIM_STC: %s\n' "$output" >&2
	exit 1
fi
[[ "$output" == *"RESULT: PASS"* ]] \
	|| { printf 'FAIL: power-on wrapper did not keep its own stimulus: %s\n' "$output" >&2; exit 1; }
checks=$((checks + 1))

printf 'gpsim wrapper validation: %d checks, 0 failures\n' "$checks"
