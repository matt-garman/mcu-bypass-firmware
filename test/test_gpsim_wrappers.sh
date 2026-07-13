#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/test-gpsim-wrappers.XXXXXX")
trap 'rm -rf "$work"' EXIT
tools="$work/tools"
hex="$work/firmware.hex"
checks=0
unset FAKE_GPSIM_MODE FAKE_GPSIM_EXIT GPSIM GPSIM_TIMEOUT_SECONDS PIC_GPSIM_PROC
mkdir -p "$tools"
printf ':00000001FF\n' > "$hex"

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
	*)
		printf '%s\n' \
			'===INIT_BYPASS===' 'porta = 0x8' 'lata = 0x0' \
			'===PRESS1_EARLY===' 'porta = 0x0' 'lata = 0x0' \
			'===PRESS1_LOW===' 'porta = 0x5' 'lata = 0x5' \
			'===ENGAGED===' 'porta = 0x9' 'lata = 0x1' \
			'===BYPASS_AGAIN===' 'porta = 0x8' 'lata = 0x0'
		;;
esac
printf 'FAKE_GPSIM_SNAPSHOTS_COMPLETE\n'
case "${FAKE_GPSIM_MODE:-pass}" in
	exit) exit "${FAKE_GPSIM_EXIT:-7}" ;;
	sleep) sleep 5 ;;
esac
EOF
chmod 750 "$tools/gpsim"

run_toggle() {
	GPSIM="$tools/gpsim" GPSIM_TIMEOUT_SECONDS="${GPSIM_TIMEOUT_SECONDS:-2}" \
		"$ROOT/test/pic/run_gpsim_test.sh" "$hex" 0x1
}

run_power_on() {
	GPSIM="$tools/gpsim" GPSIM_TIMEOUT_SECONDS="${GPSIM_TIMEOUT_SECONDS:-2}" \
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
done

printf 'gpsim wrapper validation: %d checks, 0 failures\n' "$checks"
