#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/test-pic-build.XXXXXX")
trap 'rm -rf "$work"' EXIT
repo="$work/repo"
tools="$work/tools"
hex="$repo/build_pic/bypass_mcu_cd4053-simple_pic10f320.hex"
checks=0
unset FAKE_XC8_MODE FAKE_XC8_SIGNAL_MARKER MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKEFILES
mkdir -p "$repo/scripts" "$repo/test" "$repo/build_pic" "$tools"
cp "$ROOT/Makefile" "$repo/Makefile"
cp "$ROOT/scripts/validate-ihex.sh" "$repo/scripts/validate-ihex.sh"
printf '/* fake-XC8 fixture */\n' > "$repo/bypass_mcu_pic10f320.c"

cat > "$tools/xc8" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
write_valid_hex() {
	printf '%s\n' \
		':02000000FA29DB' \
		':1000D6008B136C2807140800640008000730A92059' \
		':02400E009E38DA' \
		':00000001FF'
}
out=
while [ "$#" -gt 0 ]; do
	if [ "$1" = -o ]; then out=$2; shift 2; else shift; fi
done
[ -n "$out" ] || exit 2
mode=${FAKE_XC8_MODE:-pass}
case "$mode" in
	no-summary) ;;
	over-budget) printf 'Program space used (257)\n' ;;
	huge-count) printf 'Program space used (9999999999999999999999999999999999999999)\n' ;;
	*) printf 'Program space used (42)\n' ;;
esac
case "$mode" in
	fail) printf 'partial image\n' > "$out"; exit 1 ;;
	missing) : ;;
	empty) : > "$out" ;;
	signal)
		write_valid_hex > "$out"
		builtin kill -TERM "${PIC_RECIPE_PID:?}"
		printf 'delivered\n' > "${FAKE_XC8_SIGNAL_MARKER:?}"
		sleep 1
		;;
	bad-checksum) printf ':0100000001FF\n:00000001FF\n' > "$out" ;;
	eof-only) printf ':00000001FF\n' > "$out" ;;
	trailing) printf ':0100000001FE\n:00000001FF\ntrailing garbage\n' > "$out" ;;
	symlink)
		write_valid_hex > valid.hex
		ln -s valid.hex "$out"
		;;
	directory) mkdir "$out" ;;
	*) write_valid_hex > "$out" ;;
esac
EOF
chmod 750 "$tools/xc8" "$repo/scripts/validate-ihex.sh"
printf '#!/usr/bin/env sh\nexit 2\n' > "$tools/failing-awk"
printf '#!/usr/bin/env sh\nexit 0\n' > "$tools/empty-awk"
chmod 750 "$tools/failing-awk" "$tools/empty-awk"

run_all() {
	make --no-print-directory -C "$repo" all PIC_CC="$tools/xc8" \
		BUILD_DIR=build_pic FW_BASE=bypass_mcu PIC_TAG=pic10f320 \
		PIC_VARIANT=cd4053-simple PIC_FLASH_WORDS=256 \
		IHEX_VALIDATOR="$repo/scripts/validate-ihex.sh" AWK=awk "$@"
}

run_size() {
	make --no-print-directory -C "$repo" size PIC_CC="$tools/xc8" \
		BUILD_DIR=build_pic FW_BASE=bypass_mcu PIC_TAG=pic10f320 \
		PIC_VARIANT=cd4053-simple PIC_FLASH_WORDS=256 \
		IHEX_VALIDATOR="$repo/scripts/validate-ihex.sh" AWK=awk "$@"
}

expect_mode_rejected() {
	local runner=$1 mode=$2
	printf 'stale image\n' > "$hex"
	if (export FAKE_XC8_MODE="$mode"; "$runner") >/dev/null 2>&1; then
		printf 'FAIL: %s accepted XC8 mode %s\n' "$runner" "$mode" >&2
		exit 1
	fi
	[[ ! -e "$hex" && ! -L "$hex" ]] \
		|| { printf 'FAIL: %s mode %s left a stale or invalid image\n' "$runner" "$mode" >&2; exit 1; }
	checks=$((checks + 1))
}

expect_signal_rejected() {
	local runner=$1 marker="$work/$1.signal-delivered"
	rm -f "$marker"
	printf 'stale image\n' > "$hex"
	if (export FAKE_XC8_MODE=signal FAKE_XC8_SIGNAL_MARKER="$marker"; "$runner") >/dev/null 2>&1; then
		printf 'FAIL: interrupted %s exited successfully\n' "$runner" >&2
		exit 1
	fi
	[[ -f "$marker" ]] \
		|| { printf 'FAIL: %s signal fixture did not deliver SIGTERM\n' "$runner" >&2; exit 1; }
	[[ ! -e "$hex" && ! -L "$hex" ]] \
		|| { printf 'FAIL: interrupted %s left a partial image\n' "$runner" >&2; exit 1; }
	checks=$((checks + 1))
}

expect_override_rejected() {
	local runner=$1 label=$2
	shift 2
	printf 'stale image\n' > "$hex"
	if "$runner" "$@" >/dev/null 2>&1; then
		printf 'FAIL: %s accepted %s\n' "$runner" "$label" >&2
		exit 1
	fi
	[[ ! -e "$hex" && ! -L "$hex" ]] \
		|| { printf 'FAIL: %s %s left a stale image\n' "$runner" "$label" >&2; exit 1; }
	checks=$((checks + 1))
}

for runner in run_all run_size; do
	"$runner" >/dev/null
	"$repo/scripts/validate-ihex.sh" "$hex"
	checks=$((checks + 1))

	for mode in fail missing empty bad-checksum eof-only trailing symlink directory no-summary; do
		expect_mode_rejected "$runner" "$mode"
	done
	expect_signal_rejected "$runner"
	expect_override_rejected "$runner" "a missing validator" \
		IHEX_VALIDATOR="$repo/scripts/missing-validator"
	expect_override_rejected "$runner" "missing XC8" PIC_CC="$tools/missing-xc8"
done

expect_mode_rejected run_all over-budget
expect_mode_rejected run_all huge-count
expect_override_rejected run_all "a malformed flash budget" PIC_FLASH_WORDS=malformed
expect_override_rejected run_all "a zero flash budget" PIC_FLASH_WORDS=0
expect_override_rejected run_all "a failed budget comparison" \
	PIC_FLASH_WORDS=41 AWK="$tools/failing-awk"
expect_override_rejected run_all "a failed percentage calculation" \
	AWK="$tools/failing-awk"
expect_override_rejected run_all "an empty percentage result" \
	AWK="$tools/empty-awk"

printf 'PIC build validation: %d checks, 0 failures\n' "$checks"
