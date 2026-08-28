#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ASSERT="$ROOT/scripts/assert_pic_toolchain.sh"
work=$(mktemp -d "${TMPDIR:-$HOME}/test-pic-toolchain-assert.XXXXXX")
trap 'rm -rf "$work"' EXIT
bin="$work/bin"
dfp="$work/dfp"
inc="$work/gpsim"
checks=0

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

mkdir -p "$bin" "$dfp/pic/include/proc" "$inc"
for tool in xc8 gpsim cppcheck c++; do
	printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/$tool"
done
cat > "$bin/pkg-config" <<'EOF'
#!/usr/bin/env bash
[[ ${FAKE_GLIB_AVAILABLE:-1} == 1 && $* == '--exists glib-2.0' ]]
EOF
chmod 750 "$bin"/*
for device in pic10f322 pic10f320 pic12f675; do
	printf '/* fixture */\n' > "$dfp/pic/include/proc/$device.h"
done
printf '/* fixture */\n' > "$inc/sim_context.h"

base_args=(
	--pic-cc "$bin/xc8" --pic-dfp "$dfp"
	--pic10f320-cc "$bin/xc8" --pic10f320-dfp "$dfp"
	--gpsim gpsim --cppcheck cppcheck
	--pic-cxx c++ --pic-gpsim-inc "$inc"
	--pic10f320-cxx c++ --pic10f320-gpsim-inc "$inc"
)

run_assert() {
	PATH="$bin:$PATH" "$ASSERT" "${base_args[@]}" "$@"
}

expect_failure() {
	local label=$1 marker=$2; shift 2
	local output
	if output=$(PATH="$bin:$PATH" "$ASSERT" "$@" 2>&1); then
		fail "$label: assertion unexpectedly passed: $output"
	fi
	[[ $output == *"$marker"* ]] \
		|| fail "$label: wrong failure, expected '$marker': $output"
	checks=$((checks + 1))
}

output=$(run_assert) || fail "complete fixture was rejected: $output"
[[ $output == *"PIC toolchain present"* ]] || fail "success record is missing"
checks=$((checks + 1))

for device in pic10f322 pic10f320 pic12f675; do
	header="$dfp/pic/include/proc/$device.h"
	mv "$header" "$header.saved"
	expect_failure "missing $device header" "$device" "${base_args[@]}"
	mv "$header.saved" "$header"
done

: > "$inc/sim_context.h"
expect_failure "empty libgpsim header" "libgpsim header" "${base_args[@]}"
printf '/* fixture */\n' > "$inc/sim_context.h"
mv "$inc/sim_context.h" "$inc/real.h"
ln -s "$inc/real.h" "$inc/sim_context.h"
expect_failure "symlinked libgpsim header" "symlinked" "${base_args[@]}"
rm -f "$inc/sim_context.h"
mv "$inc/real.h" "$inc/sim_context.h"

FAKE_GLIB_AVAILABLE=0 expect_failure "missing GLib metadata" "glib-2.0" \
	"${base_args[@]}"
missing_gpsim_args=("${base_args[@]}")
missing_gpsim_args[9]=missing-gpsim
expect_failure "missing selected command" "gpsim command" \
	"${missing_gpsim_args[@]}"
expect_failure "duplicate option" "duplicate option" \
	"${base_args[@]}" --pic-cc "$bin/xc8"
expect_failure "unknown option" "usage:" "${base_args[@]}" --unknown value
expect_failure "incomplete request" "usage:" --pic-cc "$bin/xc8"

if output=$(PATH="$bin:$PATH" "$ASSERT" --github-actions \
		"${missing_gpsim_args[@]}" 2>&1); then
	fail "GitHub mode accepted a missing command: $output"
fi
[[ $output == *"::error::gpsim command"* ]] \
	|| fail "GitHub mode omitted its annotation: $output"
checks=$((checks + 1))

printf 'PIC toolchain assertion validation: %d checks, 0 failures\n' "$checks"
