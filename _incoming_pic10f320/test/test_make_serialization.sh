#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/test-make-serialization.XXXXXX")
repo="$work/repo"
log="$work/events.log"
pids=()
cleanup() {
	local pid
	for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
	for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
	rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$repo"
cp "$ROOT/Makefile" "$repo/Makefile"
: > "$log"
MAKE_CMD=${PROJECT_MAKE:-make}

run_probe() {
	local id=$1
	(
		unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL _MAKE_SERIAL_LOCK_HELD
		exec timeout 15 "$MAKE_CMD" --no-print-directory -C "$repo" test-make-lock-probe \
			BUILD_DIR=build_pic PROBE_ID="$id" PROBE_LOG="$log"
	)
}

# Start one process and wait until it enters the protected recipe. Launching the
# others while its marker exists deterministically overlaps without the lock.
run_probe 1 &
pid1=$!
pids+=("$pid1")
for _ in $(seq 1 500); do
	[ -d "$repo/build_pic/.make-lock-probe-active" ] && break
	sleep 0.01
done
[ -d "$repo/build_pic/.make-lock-probe-active" ] \
	|| { printf 'FAIL: first Make probe never entered its recipe\n' >&2; exit 1; }

run_probe 2 &
pid2=$!
pids+=("$pid2")
run_probe 3 &
pid3=$!
pids+=("$pid3")
failed=0
wait "$pid1" || failed=1
wait "$pid2" || failed=1
wait "$pid3" || failed=1
[ "$failed" -eq 0 ] || { printf 'FAIL: concurrent Make invocation failed\n' >&2; exit 1; }

events=0
active=0
while read -r event id; do
	case "$event" in
		start)
			[ "$active" -eq 0 ] \
				|| { printf 'FAIL: probe %s started while another was active\n' "$id" >&2; exit 1; }
			active=1
			;;
		end)
			[ "$active" -eq 1 ] \
				|| { printf 'FAIL: probe %s ended without a matching start\n' "$id" >&2; exit 1; }
			active=0
			;;
		*)
			printf 'FAIL: malformed probe event: %s %s\n' "$event" "$id" >&2
			exit 1
			;;
	esac
	events=$((events + 1))
done < "$log"

[ "$events" -eq 6 ] && [ "$active" -eq 0 ] \
	|| { printf 'FAIL: expected 6 balanced serialization events, got %d\n' "$events" >&2; exit 1; }
for id in 1 2 3; do
	[ "$(grep -c "^start $id$" "$log")" -eq 1 ] \
		&& [ "$(grep -c "^end $id$" "$log")" -eq 1 ] \
		|| { printf 'FAIL: probe %s did not run exactly once\n' "$id" >&2; exit 1; }
done

printf 'Make serialization validation: 3 concurrent invocations, 0 overlaps\n'
