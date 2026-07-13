#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/test-pic-build.XXXXXX")
trap 'rm -rf "$work"' EXIT
repo="$work/repo"
tools="$work/tools"
hex="$repo/build_pic/bypass_cd4053_pic10f322.hex"
checks=0
unset FAKE_XC8_MODE FAKE_XC8_FAIL_NAME MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKEFILES
mkdir -p "$repo/src" "$repo/scripts" "$repo/build_pic" "$tools"
cp "$ROOT/Makefile" "$repo/Makefile"
cp "$ROOT/scripts/validate-ihex.sh" "$repo/scripts/validate-ihex.sh"

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
printf 'Program space used (42)\n'
mode=${FAKE_XC8_MODE:-pass}
if [ -n "${FAKE_XC8_FAIL_NAME:-}" ] && [ "$out" = "$FAKE_XC8_FAIL_NAME" ]; then
	mode=fail
fi
case "$mode" in
	fail) printf 'partial image\n' > "$out"; exit 1 ;;
	missing) : ;;
	empty) : > "$out" ;;
	signal)
		write_valid_hex > "$out"
		kill -TERM "${PIC_RECIPE_PID:?}"
		;;
	bad-checksum) printf ':0100000001FF\n:00000001FF\n' > "$out" ;;
	eof-only) printf ':00000001FF\n' > "$out" ;;
	trailing) printf ':0100000001FE\n:00000001FF\ntrailing garbage\n' > "$out" ;;
	symlink)
		write_valid_hex > valid.hex
		ln -s valid.hex "$out"
		;;
	*) write_valid_hex > "$out" ;;
esac
EOF
chmod 750 "$tools/xc8" "$repo/scripts/validate-ihex.sh"

files=(
	src/bypass_mcu_pic10f322.c src/bypass_pure.c
	src/bypass_config.h src/bypass_types.h src/bypass_hw_iface.h
	src/bypass_output_common.h src/bypass_pins_pic10f322.h
	src/bypass_blocking_delay.h src/bypass_static_assert.h
	src/bypass_compile_checks.h src/bypass_output_cd4053_simple.c
	src/bypass_output_cd4053_with_mute.c src/bypass_output_tq2_l2_5v_relay.c
	src/bypass_output_cd4053_simple.h src/bypass_output_cd4053_with_mute.h
	src/bypass_output_tq2_l2_5v_relay.h
)
for file in "${files[@]}"; do : > "$repo/$file"; done

run_make() {
	make --no-print-directory -C "$repo" pic \
		CC=true HOSTCC=true PIC_CC="$tools/xc8" PIC_BUILD_DIR=build_pic \
		FW_BASE=bypass PIC_TAG=pic10f322 PIC_FLASH_WORDS=512 \
		VARIANTS=cd4053 STRICT_TOOLS=1 "$@"
}

run_make >/dev/null
"$repo/scripts/validate-ihex.sh" "$hex"
checks=$((checks + 1))

for mode in fail missing empty bad-checksum eof-only trailing symlink; do
	printf 'stale image\n' > "$hex"
	if (export FAKE_XC8_MODE="$mode"; run_make) >/dev/null 2>&1; then
		printf 'FAIL: XC8 mode %s was accepted\n' "$mode" >&2
		exit 1
	fi
	[[ ! -e "$hex" && ! -L "$hex" ]] \
		|| { printf 'FAIL: XC8 mode %s left a stale or invalid image\n' "$mode" >&2; exit 1; }
	checks=$((checks + 1))
done

printf 'stale image\n' > "$hex"
if (export FAKE_XC8_MODE=signal; run_make) >/dev/null 2>&1; then
	printf 'FAIL: interrupted PIC build exited successfully\n' >&2
	exit 1
fi
[[ ! -e "$hex" ]] \
	|| { printf 'FAIL: interrupted PIC build left a partial image\n' >&2; exit 1; }
checks=$((checks + 1))

printf 'stale image\n' > "$hex"
if run_make IHEX_VALIDATOR="$repo/scripts/missing-validator" >/dev/null 2>&1; then
	printf 'FAIL: missing Intel HEX validator was accepted\n' >&2
	exit 1
fi
[[ ! -e "$hex" ]] \
	|| { printf 'FAIL: missing validator left a stale PIC image\n' >&2; exit 1; }
checks=$((checks + 1))

if run_make "VARIANTS=" >/dev/null 2>&1; then
	printf 'FAIL: empty PIC variant matrix was accepted\n' >&2
	exit 1
fi
checks=$((checks + 1))

if (export FAKE_XC8_FAIL_NAME=bypass_relay_pic10f322.hex; \
		run_make "VARIANTS=cd4053 mute relay") >/dev/null 2>&1; then
	printf 'FAIL: late PIC variant compiler failure was accepted\n' >&2
	exit 1
fi
for image in bypass_cd4053_pic10f322.hex bypass_mute_pic10f322.hex \
		bypass_relay_pic10f322.hex; do
	[[ ! -e "$repo/build_pic/$image" ]] \
		|| { printf 'FAIL: late variant failure left partial PIC image matrix\n' >&2; exit 1; }
done
checks=$((checks + 1))

printf 'PIC build validation: %d checks, 0 failures\n' "$checks"
