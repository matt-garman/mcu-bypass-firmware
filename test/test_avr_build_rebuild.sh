#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/test-avr-build.XXXXXX")
trap 'rm -rf "$work"' EXIT
repo="$work/repo"
tools="$work/tools"
cc_log="$work/cc.log"
objcopy_log="$work/objcopy.log"
checks=0
unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKEFILES
unset AVR_BUILD_DIR AVR_FW FW_BASE MCU F_CPU F_CPU_X5 CFLAGS CFLAGS_COMMON
unset AVR_REBUILD_PREREQ
unset TEST_OBJCOPY
unset FAKE_CC_MODE FAKE_OBJCOPY_MODE FAKE_READELF_MODE
mkdir -p "$repo/src" "$repo/test" "$repo/scripts" "$repo/build_avr_classic" "$tools"
cp "$ROOT/Makefile" "$repo/Makefile"
cp "$ROOT/scripts/validate-ihex.sh" "$repo/scripts/validate-ihex.sh"

cat > "$tools/cc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = --version ]; then printf 'fake avr-gcc 1\n'; exit 0; fi
out=
args=$*
while [ "$#" -gt 0 ]; do
	if [ "$1" = -o ]; then out=$2; shift 2; else shift; fi
done
[ -n "$out" ] || exit 0
printf '%s => %s\n' "$args" "$out" >> "$FAKE_CC_LOG"
case "${FAKE_CC_MODE:-pass}" in
	fail) printf 'partial ELF\n' > "$out"; exit 1 ;;
	empty) : > "$out" ;;
	malformed) printf 'not an ELF\n' > "$out" ;;
	*) printf 'fresh ELF\n' > "$out" ;;
esac
EOF

cat > "$tools/readelf" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do elf=$arg; done
grep -q -x 'fresh ELF' "$elf"
printf '  Machine:                           Atmel AVR 8-bit microcontroller\n'
if [ "${FAKE_READELF_MODE:-pass}" = wrong ]; then
	printf '  Flags:                             0x5, avr:5\n'
else
	printf '  Flags:                             0x19, avr:25, link-relax\n'
fi
EOF

cat > "$tools/objcopy" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do out=$arg; done
printf '%s %s\n' "$0" "$*" >> "$FAKE_OBJCOPY_LOG"
case "${FAKE_OBJCOPY_MODE:-pass}" in
	fail) printf 'partial HEX\n' > "$out"; exit 1 ;;
	empty) : > "$out" ;;
	malformed) printf ':0100000001FF\n:00000001FF\n' > "$out" ;;
	*) printf ':0100000001FE\n:00000001FF\n' > "$out" ;;
esac
EOF
chmod 750 "$tools/cc" "$tools/readelf" "$tools/objcopy" \
	"$repo/scripts/validate-ihex.sh"
cp "$tools/objcopy" "$tools/objcopy2"
cp "$tools/objcopy" "$tools/objcopy_fail"
cp "$tools/objcopy" "$tools/objcopy_empty"

files=(
	src/bypass_mcu_avr_classic.c src/bypass_pure.c src/bypass_pure.h
	src/bypass_config.h src/bypass_types.h src/bypass_hw_iface.h
	src/bypass_output_common.h src/bypass_pins_avr_classic.h
	src/bypass_blocking_delay.h src/bypass_static_assert.h
	src/bypass_compile_checks.h src/bypass_output_cd4053_simple.c
	src/bypass_output_cd4053_simple.h src/bypass_output_cd4053_with_mute.c
	src/bypass_output_cd4053_with_mute.h src/bypass_output_tq2_l2_5v_relay.c
	src/bypass_output_tq2_l2_5v_relay.h
)
for file in "${files[@]}"; do : > "$repo/$file"; done
cp "$repo/src/bypass_output_cd4053_simple.c" "$repo/src/alternate_driver.c"
: > "$cc_log"
: > "$objcopy_log"

run_make() {
	FAKE_CC_LOG="$cc_log" FAKE_OBJCOPY_LOG="$objcopy_log" \
	make --no-print-directory -C "$repo" "$@" \
		CC="$tools/cc" HOSTCC="$tools/cc" \
		OBJCOPY="${TEST_OBJCOPY-$tools/objcopy}" \
		READELF="$tools/readelf" \
		AVR_BUILD_DIR=build_avr_classic \
		AVR_FW=build_avr_classic/bypass FW_BASE=bypass MCU=attiny13a \
		VARIANTS="cd4053 mute relay"
}

cc_count() { grep -c -F "$1.tmp" "$cc_log" || true; }
objcopy_count() { grep -c -F "$1.tmp" "$objcopy_log" || true; }

t13=build_avr_classic/bypass_cd4053
x5=build_avr_classic/bypass_cd4053_t85

run_make "$t13.hex" >/dev/null
[[ "$(cc_count "$t13.elf")" -eq 1 && "$(objcopy_count "$t13.hex")" -eq 1 ]] \
	|| { printf 'FAIL: initial ATtiny13a build did not run once\n' >&2; exit 1; }
checks=$((checks + 1))
run_make "$t13.hex" >/dev/null
[[ "$(cc_count "$t13.elf")" -eq 2 && "$(objcopy_count "$t13.hex")" -eq 2 ]] \
	|| { printf 'FAIL: repeated configuration reused stale ATtiny13a artifacts\n' >&2; exit 1; }
checks=$((checks + 1))

run_make "$t13.hex" F_CPU=2400000UL >/dev/null
[[ "$(cc_count "$t13.elf")" -eq 3 ]] && grep -q -- '-DF_CPU=2400000UL' "$cc_log" \
	|| { printf 'FAIL: current F_CPU did not reach ATtiny13a compiler\n' >&2; exit 1; }
checks=$((checks + 1))
run_make "$t13.hex" F_CPU=2400000UL >/dev/null
[[ "$(cc_count "$t13.elf")" -eq 4 ]] \
	|| { printf 'FAIL: repeated F_CPU configuration reused a stale ELF\n' >&2; exit 1; }
checks=$((checks + 1))
run_make "$t13.hex" >/dev/null
[[ "$(cc_count "$t13.elf")" -eq 5 ]] \
	|| { printf 'FAIL: restoring default F_CPU did not rebuild\n' >&2; exit 1; }
checks=$((checks + 1))

touch "$repo/src/bypass_pure.h"
run_make "$t13.hex" AVR_REBUILD_PREREQ= >/dev/null
[[ "$(cc_count "$t13.elf")" -eq 6 ]] \
	|| { printf 'FAIL: bypass_pure.h change did not rebuild\n' >&2; exit 1; }
checks=$((checks + 1))
printf '\n# rebuild-regression touch\n' >> "$repo/Makefile"
run_make "$t13.hex" AVR_REBUILD_PREREQ= >/dev/null
[[ "$(cc_count "$t13.elf")" -eq 7 ]] \
	|| { printf 'FAIL: Makefile recipe/config change did not rebuild\n' >&2; exit 1; }
checks=$((checks + 1))

run_make "$t13.hex" CFLAGS=-DCUSTOM_CFLAGS >/dev/null
[[ "$(cc_count "$t13.elf")" -eq 8 ]] && grep -q -- '-DCUSTOM_CFLAGS' "$cc_log" \
	|| { printf 'FAIL: current CFLAGS did not reach compiler\n' >&2; exit 1; }
checks=$((checks + 1))
run_make "$t13.hex" CFLAGS=-DCUSTOM_CFLAGS macro_cd4053=CUSTOM_VARIANT >/dev/null
[[ "$(cc_count "$t13.elf")" -eq 9 ]] && grep -q -- '-DCUSTOM_VARIANT' "$cc_log" \
	|| { printf 'FAIL: current variant macro did not reach compiler\n' >&2; exit 1; }
checks=$((checks + 1))
(export TEST_OBJCOPY="$tools/objcopy2"; \
	run_make "$t13.hex" CFLAGS=-DCUSTOM_CFLAGS macro_cd4053=CUSTOM_VARIANT) >/dev/null
[[ "$(cc_count "$t13.elf")" -eq 10 && "$(objcopy_count "$t13.hex")" -eq 10 ]] \
	|| { printf 'FAIL: current objcopy command did not rebuild artifacts\n' >&2; exit 1; }
checks=$((checks + 1))

(export TEST_OBJCOPY="$tools/objcopy2"; \
	run_make "$t13.hex" CFLAGS=-DCUSTOM_CFLAGS macro_cd4053=CUSTOM_VARIANT \
		CORE_SRC=src/bypass_pure.c) >/dev/null
[[ "$(cc_count "$t13.elf")" -eq 11 ]] && grep -q -- 'src/bypass_pure.c' "$cc_log" \
	|| { printf 'FAIL: current CORE_SRC did not reach compiler\n' >&2; exit 1; }
checks=$((checks + 1))
(export TEST_OBJCOPY="$tools/objcopy2"; \
	run_make "$t13.hex" CFLAGS=-DCUSTOM_CFLAGS macro_cd4053=CUSTOM_VARIANT \
		CORE_SRC=src/bypass_pure.c src_cd4053=src/alternate_driver.c) >/dev/null
[[ "$(cc_count "$t13.elf")" -eq 12 ]] && grep -q -- 'src/alternate_driver.c' "$cc_log" \
	|| { printf 'FAIL: current driver source mapping did not reach compiler\n' >&2; exit 1; }
checks=$((checks + 1))
printf '\nprintf "objcopy replacement used\\n" >> "$FAKE_OBJCOPY_LOG"\n' >> "$tools/objcopy2"
(export TEST_OBJCOPY="$tools/objcopy2"; \
	run_make "$t13.hex" CFLAGS=-DCUSTOM_CFLAGS macro_cd4053=CUSTOM_VARIANT \
		CORE_SRC=src/bypass_pure.c src_cd4053=src/alternate_driver.c) >/dev/null
[[ "$(cc_count "$t13.elf")" -eq 13 ]] && grep -q 'objcopy replacement used' "$objcopy_log" \
	|| { printf 'FAIL: same-path objcopy replacement was not consumed\n' >&2; exit 1; }
checks=$((checks + 1))
printf '\nprintf "compiler replacement used\\n" >> "$FAKE_CC_LOG"\n' >> "$tools/cc"
(export TEST_OBJCOPY="$tools/objcopy2"; \
	run_make "$t13.hex" CFLAGS=-DCUSTOM_CFLAGS macro_cd4053=CUSTOM_VARIANT \
		CORE_SRC=src/bypass_pure.c src_cd4053=src/alternate_driver.c) >/dev/null
[[ "$(cc_count "$t13.elf")" -eq 14 ]] && grep -q 'compiler replacement used' "$cc_log" \
	|| { printf 'FAIL: same-path compiler replacement was not consumed\n' >&2; exit 1; }
checks=$((checks + 1))

run_make "$t13.hex" "CFLAGS=-DNAME='quoted value'" >/dev/null
[[ "$(cc_count "$t13.elf")" -eq 15 ]] && grep -q -- "-DNAME=quoted value" "$cc_log" \
	|| { printf 'FAIL: apostrophe-bearing flags did not reach compiler\n' >&2; exit 1; }
checks=$((checks + 1))

run_make "$x5.hex" >/dev/null
[[ "$(cc_count "$x5.elf")" -eq 1 ]] \
	|| { printf 'FAIL: initial tinyx5 build did not run once\n' >&2; exit 1; }
run_make "$x5.hex" >/dev/null
[[ "$(cc_count "$x5.elf")" -eq 2 ]] \
	|| { printf 'FAIL: repeated tinyx5 configuration reused a stale ELF\n' >&2; exit 1; }
run_make "$x5.hex" F_CPU_X5=2000000UL >/dev/null
[[ "$(cc_count "$x5.elf")" -eq 3 ]] && grep -q -- '-DF_CPU=2000000UL' "$cc_log" \
	|| { printf 'FAIL: current F_CPU_X5 did not reach compiler\n' >&2; exit 1; }
checks=$((checks + 3))

# A forced ELF rebuild must invalidate its paired HEX. A subsequent consumer
# phase can then regenerate HEX from that exact ELF without compiling again.
run_make "$t13.elf" >/dev/null
[[ -s "$repo/$t13.elf" && ! -e "$repo/$t13.hex" ]] \
	|| { printf 'FAIL: ELF rebuild did not invalidate its paired HEX\n' >&2; exit 1; }
checks=$((checks + 1))
validated_hash=$(sha256sum "$repo/$t13.elf")
validated_cc_count=$(cc_count "$t13.elf")
validated_objcopy_count=$(objcopy_count "$t13.hex")
# GNU Make deliberately omits --old-file from recursive MAKEFLAGS. This private
# sandbox call therefore identifies itself as an already-held graph so the
# wrapper does not consume and lose the option before the real build rules see
# it. The enclosing regression is the sandbox's sole owner.
repo_lock_id=$(stat -Lc '%d:%i' "$repo")
(
	export MAKEFLAGS=-B _MAKE_SERIAL_LOCK_HELD="$repo_lock_id"
	run_make --old-file="$t13.elf" "$t13.hex" AVR_REBUILD_PREREQ=
) >/dev/null
[[ "$(cc_count "$t13.elf")" -eq "$validated_cc_count" \
	&& "$(objcopy_count "$t13.hex")" -eq $((validated_objcopy_count + 1)) \
	&& "$(sha256sum "$repo/$t13.elf")" == "$validated_hash" \
	&& -s "$repo/$t13.hex" ]] \
	|| { printf 'FAIL: HEX regeneration recompiled or changed the validated ELF\n' >&2; exit 1; }
checks=$((checks + 1))
run_make "$t13.elf" AVR_REBUILD_PREREQ= >/dev/null
[[ "$(cc_count "$t13.elf")" -eq "$validated_cc_count" \
	&& "$(sha256sum "$repo/$t13.elf")" == "$validated_hash" \
	&& -s "$repo/$t13.hex" ]] \
	|| { printf 'FAIL: consumer-only ELF access invalidated publishable artifacts\n' >&2; exit 1; }
checks=$((checks + 1))

if (export FAKE_CC_MODE=fail; run_make "$t13.hex" F_CPU=3000000UL) >/dev/null 2>&1; then
	printf 'FAIL: compiler failure was accepted\n' >&2; exit 1
fi
shopt -s nullglob
temps=("$repo/$t13.elf".tmp.* "$repo/$t13.hex".tmp.*)
shopt -u nullglob
[[ ! -e "$repo/$t13.elf" && ! -e "$repo/$t13.hex" && "${#temps[@]}" -eq 0 ]] \
	|| { printf 'FAIL: compiler failure left stale or partial artifacts\n' >&2; exit 1; }
checks=$((checks + 1))
run_make "$t13.hex" F_CPU=3000000UL >/dev/null

if (export FAKE_CC_MODE=empty; run_make "$t13.hex" F_CPU=3050000UL) >/dev/null 2>&1; then
	printf 'FAIL: empty compiler output was accepted\n' >&2; exit 1
fi
[[ ! -e "$repo/$t13.elf" && ! -e "$repo/$t13.hex" ]] \
	|| { printf 'FAIL: empty compiler output left final artifacts\n' >&2; exit 1; }
checks=$((checks + 1))
run_make "$t13.hex" F_CPU=3050000UL >/dev/null

if (export FAKE_CC_MODE=malformed; run_make "$t13.hex" F_CPU=3075000UL) >/dev/null 2>&1; then
	printf 'FAIL: malformed compiler output was accepted\n' >&2; exit 1
fi
[[ ! -e "$repo/$t13.elf" && ! -e "$repo/$t13.hex" ]] \
	|| { printf 'FAIL: malformed compiler output left final artifacts\n' >&2; exit 1; }
checks=$((checks + 1))
run_make "$t13.hex" F_CPU=3075000UL >/dev/null

if (export FAKE_READELF_MODE=wrong; run_make "$t13.hex" F_CPU=3080000UL) >/dev/null 2>&1; then
	printf 'FAIL: wrong-architecture compiler output was accepted\n' >&2; exit 1
fi
[[ ! -e "$repo/$t13.elf" && ! -e "$repo/$t13.hex" ]] \
	|| { printf 'FAIL: wrong-architecture compiler output left final artifacts\n' >&2; exit 1; }
checks=$((checks + 1))
run_make "$t13.hex" F_CPU=3080000UL >/dev/null

if (export TEST_OBJCOPY="$tools/objcopy_fail" FAKE_OBJCOPY_MODE=fail; \
		run_make "$t13.hex" F_CPU=3100000UL) >/dev/null 2>&1; then
	printf 'FAIL: objcopy failure was accepted\n' >&2; exit 1
fi
shopt -s nullglob
temps=("$repo/$t13.hex".tmp.*)
shopt -u nullglob
[[ -s "$repo/$t13.elf" && ! -e "$repo/$t13.hex" && "${#temps[@]}" -eq 0 ]] \
	|| { printf 'FAIL: objcopy failure left stale or partial HEX\n' >&2; exit 1; }
checks=$((checks + 1))

if (export TEST_OBJCOPY="$tools/objcopy_empty" FAKE_OBJCOPY_MODE=empty; \
		run_make "$t13.hex" F_CPU=3200000UL) >/dev/null 2>&1; then
	printf 'FAIL: empty objcopy output was accepted\n' >&2; exit 1
fi
[[ -s "$repo/$t13.elf" && ! -e "$repo/$t13.hex" ]] \
	|| { printf 'FAIL: empty objcopy output left final HEX\n' >&2; exit 1; }
checks=$((checks + 1))

if (export FAKE_OBJCOPY_MODE=malformed; \
		run_make "$t13.hex" F_CPU=3250000UL) >/dev/null 2>&1; then
	printf 'FAIL: malformed objcopy output was accepted\n' >&2; exit 1
fi
[[ -s "$repo/$t13.elf" && ! -e "$repo/$t13.hex" ]] \
	|| { printf 'FAIL: malformed objcopy output left final HEX\n' >&2; exit 1; }
checks=$((checks + 1))

rm -rf "$repo/build_avr_classic"
mkdir -p "$repo/build_avr_classic"
: > "$cc_log"; : > "$objcopy_log"
(run_make "$t13.hex") >/dev/null & pid1=$!
(run_make "$x5.hex") >/dev/null & pid2=$!
wait "$pid1" && wait "$pid2" \
	|| { printf 'FAIL: concurrent classic builds interfered\n' >&2; exit 1; }
[[ -s "$repo/$t13.hex" && -s "$repo/$x5.hex" ]] \
	|| { printf 'FAIL: concurrent classic builds lost an artifact\n' >&2; exit 1; }
checks=$((checks + 1))

rm -f "$repo/$t13.hex"
mkdir "$repo/$t13.hex"
if run_make "$t13.elf" F_CPU=3300000UL >/dev/null 2>&1; then
	printf 'FAIL: unremovable stale HEX path was accepted\n' >&2; exit 1
fi
[[ -d "$repo/$t13.hex" && ! -e "$repo/$t13.elf" ]] \
	|| { printf 'FAIL: cleanup failure published an invalid artifact\n' >&2; exit 1; }
checks=$((checks + 1))

printf 'classic AVR rebuild validation: %d checks, 0 failures\n' "$checks"
