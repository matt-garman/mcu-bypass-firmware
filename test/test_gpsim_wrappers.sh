#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/test-gpsim-wrappers.XXXXXX")
trap 'rm -rf "$work"' EXIT
tools="$work/tools"
hex="$work/firmware.hex"
checks=0
unset FAKE_GPSIM_MODE FAKE_GPSIM_EXIT FAKE_GPSIM_MARKER FAKE_TIMEOUT_MARKER \
	GPSIM GPSIM_TIMEOUT_SECONDS PIC_GPSIM_PROC
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
while [ "$#" -gt 0 ]; do
	if [ "$1" = -c ]; then script=$2; shift 2; else shift; fi
done
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
done

# The public Make target must validate configuration before its optional-tool
# skip. --old-file avoids building PIC images in this host-only regression.
repo_lock_id=$(stat -Lc '%d:%i' "$ROOT")
if output=$(
	unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL
	_MAKE_SERIAL_LOCK_HELD="$repo_lock_id" "${MAKE_CMD[@]}" --no-print-directory \
		-C "$ROOT" --old-file=pic pic-test-gpsim STRICT_TOOLS= \
		GPSIM="$tools/missing-gpsim" GPSIM_TIMEOUT_SECONDS=0 2>&1
); then
	printf 'FAIL: pic-test-gpsim skipped an invalid timeout\n' >&2
	exit 1
fi
[[ "$output" == *"GPSIM_TIMEOUT_SECONDS must be a positive decimal number"* \
	&& "$output" != *"gpsim not installed"* ]] \
	|| { printf 'FAIL: pic-test-gpsim validated gpsim before its timeout: %s\n' "$output" >&2; exit 1; }
checks=$((checks + 1))

printf 'gpsim wrapper validation: %d checks, 0 failures\n' "$checks"
