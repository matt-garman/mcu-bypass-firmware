#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/test-make-serialization.XXXXXX")
repo="$work/repo with spaces"
log="$work/events.log"
probe_dir="$repo/build_probe"
release_log="$work/release.log"
fakebin="$work/fakebin"
pids=()
checks=0

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

cleanup() {
	local pid
	for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
	for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
	rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

for command in flock timeout; do
	command -v "$command" >/dev/null 2>&1 \
		|| fail "$command is required for the serialization regression"
done
REAL_FLOCK=$(command -v flock)
read -r -a MAKE_CMD <<<"${PROJECT_MAKE:-make}"
[ "${#MAKE_CMD[@]}" -gt 0 ] \
	|| fail "PROJECT_MAKE must name a Make command"
command -v "${MAKE_CMD[0]}" >/dev/null 2>&1 \
	|| fail "Make command not found: ${MAKE_CMD[0]}"

mkdir -p "$repo/scripts"
cp "$ROOT/Makefile" "$repo/Makefile"
cp "$ROOT/scripts/make-release.sh" "$repo/scripts/make-release.sh"
cp "$ROOT/scripts/release-provenance.sh" "$repo/scripts/release-provenance.sh"
chmod +x "$repo/scripts/make-release.sh"
: > "$log"

run_make() {
	(
		unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL _MAKE_SERIAL_LOCK_HELD
		exec timeout 15 "${MAKE_CMD[@]}" --no-print-directory -C "$repo" "$@"
	)
}

run_probe() {
	local id=$1
	run_make -j3 test-make-lock-probe SERIAL_PROBE_DIR=build_probe \
		PROBE_ID="$id" PROBE_LOG="$log"
}

# Start one process and wait until it enters the protected recipe. Launch the
# others while its marker exists; without the outer lock they overlap and fail.
run_probe 1 &
pid1=$!
pids+=("$pid1")
i=0
while [ ! -d "$probe_dir/.make-lock-probe-active" ] && [ "$i" -lt 500 ]; do
	i=$((i + 1))
	sleep 0.01
done
[ -d "$probe_dir/.make-lock-probe-active" ] \
	|| fail "first Make probe never entered its recipe"

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
[ "$failed" -eq 0 ] || fail "concurrent Make invocation failed"

events=0
active=0
while read -r event id; do
	case "$event" in
		start)
			[ "$active" -eq 0 ] \
				|| fail "probe $id started while another was active"
			active=1
			;;
		end)
			[ "$active" -eq 1 ] \
				|| fail "probe $id ended without a matching start"
			active=0
			;;
		*) fail "malformed probe event: $event $id" ;;
	esac
	events=$((events + 1))
done < "$log"
[ "$events" -eq 6 ] && [ "$active" -eq 0 ] \
	|| fail "expected 6 balanced serialization events, got $events"
for id in 1 2 3; do
	[ "$(grep -c "^start $id$" "$log")" -eq 1 ] \
		&& [ "$(grep -c "^end $id$" "$log")" -eq 1 ] \
		|| fail "probe $id did not run exactly once"
done
checks=$((checks + 1))

# The wrapper forces the ordinary graph to -j1, but an explicitly reviewed
# recursive -j2 fan-out must still overlap its isolated probe prerequisites.
run_make test-make-safe-parallel-probe SERIAL_PROBE_DIR=build_probe >/dev/null \
	|| fail "reviewed recursive Make fan-out was not preserved"
checks=$((checks + 1))

# Query mode executes no recipes and therefore must not acquire/create the lock.
rm -f "$repo/.make.lock"
rm -rf "$probe_dir"
set +e
run_make -q print-VARIANTS >/dev/null 2>&1
query_rc=$?
set -e
[ "$query_rc" -eq 1 ] || fail "Make query returned $query_rc, expected 1"
[ ! -e "$repo/.make.lock" ] && [ ! -e "$probe_dir" ] \
	|| fail "Make query created lock/build artifacts"
checks=$((checks + 1))

# Dry-run may acquire the advisory lock but must not execute the protected probe.
rm -f "$repo/.make.lock"
run_make -n test-make-lock-probe SERIAL_PROBE_DIR=build_probe \
	PROBE_ID=dry PROBE_LOG="$log" >/dev/null \
	|| fail "Make dry-run failed"
[ ! -e "$probe_dir/.make-lock-probe-active" ] \
	|| fail "Make dry-run executed the probe recipe"
checks=$((checks + 1))

# Direct release-script execution must wait for the same lock before it even
# rejects an invalid argument. A wrapper signals exactly when the script invokes
# flock, while an explicit marker controls when the holder releases the lock.
lock_held="$work/release-lock-held"
release_unblock="$work/release-unblock"
lock_attempt="$work/release-lock-attempt"
mkdir -p "$fakebin"
printf '%s\n' \
	'#!/usr/bin/env bash' \
	'set -euo pipefail' \
	'[ "$1" = "$EXPECTED_LOCK" ] || { printf "wrong lock path: %s\\n" "$1" >&2; exit 97; }' \
	': > "$LOCK_ATTEMPT"' \
	'exec "$REAL_FLOCK" "$@"' \
	> "$fakebin/flock"
chmod +x "$fakebin/flock"
"$REAL_FLOCK" "$repo/.make.lock" bash -c \
	'touch "$1"; while [ ! -e "$2" ]; do sleep 0.01; done' \
	_ "$lock_held" "$release_unblock" &
holder_pid=$!
pids+=("$holder_pid")
i=0
while [ ! -e "$lock_held" ] && [ "$i" -lt 500 ]; do
	i=$((i + 1))
	sleep 0.01
done
[ -e "$lock_held" ] || fail "release lock holder did not start"
(
	unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL _MAKE_SERIAL_LOCK_HELD
	exec env PATH="$fakebin:$PATH" REAL_FLOCK="$REAL_FLOCK" \
		LOCK_ATTEMPT="$lock_attempt" EXPECTED_LOCK="$repo/.make.lock" timeout 15 \
		"$repo/scripts/make-release.sh" \
		--soak-duration-ms 0 v99.0.0
) >"$release_log" 2>&1 &
release_pid=$!
pids+=("$release_pid")
i=0
while [ ! -e "$lock_attempt" ] && [ "$i" -lt 500 ]; do
	i=$((i + 1))
	sleep 0.01
done
[ -e "$lock_attempt" ] \
	|| fail "direct release script never attempted to acquire the worktree lock"
kill -0 "$release_pid" 2>/dev/null \
	|| fail "direct release script did not wait for the worktree lock"
touch "$release_unblock"
wait "$holder_pid" || fail "release lock holder failed"
if wait "$release_pid"; then
	fail "direct release script accepted an invalid duration"
fi
grep -q "positive base-10 integer" "$release_log" \
	|| fail "direct release script failed for the wrong reason"
checks=$((checks + 1))

# `make release` already owns the lock. The inherited marker must let the script
# run without trying to reacquire it and deadlocking.
if output=$(run_make release VERSION=v99.0.0 \
		RELEASE_ARGS='--soak-duration-ms 0' 2>&1); then
	fail "Make-driven release accepted an invalid duration"
fi
[[ "$output" == *"positive base-10 integer"* ]] \
	|| fail "Make-driven release deadlocked or failed for the wrong reason: $output"
checks=$((checks + 1))

printf 'Make serialization validation: %d checks, 3 concurrent invocations, 0 overlaps\n' \
	"$checks"
