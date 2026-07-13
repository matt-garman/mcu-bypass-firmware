#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/test-workload-rebuild.XXXXXX")
trap 'rm -rf "$work"' EXIT
repo="$work/repo"
tools="$work/tools"
log="$work/compiler.log"
checks=0
unset HOST_DEFS SIM_DEFS MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKEFILES SIZE
unset AVR_BUILD_DIR AVR_FW FW_BASE TOOLCHAIN_STAMP TOOLCHAIN_SIG VARIANTS MCU
mkdir -p "$repo/test/host" "$repo/test/avr" "$repo/src" \
	"$repo/build_avr_classic" "$tools"
cp "$ROOT/Makefile" "$repo/Makefile"
cp "$ROOT/test/check_flash_budget.sh" "$repo/test/check_flash_budget.sh"

cat > "$tools/cc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = --version ]; then printf 'fake compiler 1\n'; exit 0; fi
out=
for arg in "$@"; do
	if [ "$arg" = -o ]; then want_out=1; continue; fi
	if [ "${want_out:-0}" = 1 ]; then out=$arg; want_out=0; fi
done
[ -n "$out" ] || exit 0
printf '%s\n' "$*" >> "$FAKE_COMPILER_LOG"
mkdir -p "$(dirname "$out")"
printf '#!/bin/sh\nexit 0\n' > "$out"
chmod 750 "$out"
EOF
chmod 750 "$tools/cc"

cat > "$tools/size" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'Program: 512 bytes (50.0%% Full)\n'
EOF
chmod 750 "$tools/size" "$repo/test/check_flash_budget.sh"

files=(
	test/host/test_logic_host.c test/avr/test_sim.c test/model_step.h
	test/bypass_config_host.h test/bypass_output_host.h
	src/bypass_config.h src/bypass_types.h src/bypass_hw_iface.h
	src/bypass_output_common.h src/bypass_pins_avr_classic.h
	src/bypass_blocking_delay.h src/bypass_static_assert.h
	src/bypass_compile_checks.h src/bypass_output_cd4053_simple.h
	src/bypass_output_cd4053_with_mute.h
	src/bypass_output_tq2_l2_5v_relay.h src/bypass_mcu_avr_classic.c
	src/bypass_output_cd4053_simple.c src/bypass_output_cd4053_with_mute.c
	src/bypass_output_tq2_l2_5v_relay.c src/bypass_pure.c src/bypass_pure.h
)
for file in "${files[@]}"; do
	mkdir -p "$repo/${file%/*}"
	: > "$repo/$file"
done
printf 'test\n' > "$repo/test/.toolchain.sig"
for image in bypass_cd4053.elf bypass_mute.elf bypass_relay.elf \
	bypass_cd4053_t85.elf; do
	printf 'firmware ELF\n' > "$repo/build_avr_classic/$image"
done
: > "$log"

run_make() {
	FAKE_COMPILER_LOG="$log" make --no-print-directory -C "$repo" "$@" \
		CC="$tools/cc" HOSTCC="$tools/cc" SANITIZE= \
		SIZE="$tools/size" SIM_LIBS= TOOLCHAIN_SIG=test \
		TOOLCHAIN_STAMP=test/.toolchain.sig AVR_BUILD_DIR=build_avr_classic \
		AVR_FW=build_avr_classic/bypass FW_BASE=bypass MCU=attiny13a \
		VARIANTS="cd4053 mute relay"
}

compile_count() {
	local output=$1
	grep -c -- "-o $output" "$log" || true
}

run_make test-host HOST_DEFS=-DHOST_FAST=1 >/dev/null
[[ "$(compile_count test/host/test_logic_host)" -eq 1 ]] \
	|| { printf 'FAIL: initial host workload did not compile once\n' >&2; exit 1; }
checks=$((checks + 1))
run_make test-host HOST_DEFS= >/dev/null
[[ "$(compile_count test/host/test_logic_host)" -eq 2 ]] \
	|| { printf 'FAIL: FAST-to-FULL host workload reused a stale binary\n' >&2; exit 1; }
checks=$((checks + 1))
run_make test-host HOST_DEFS=-DHOST_CUSTOM=1 >/dev/null
[[ "$(compile_count test/host/test_logic_host)" -eq 3 ]] \
	|| { printf 'FAIL: custom host workload reused a stale binary\n' >&2; exit 1; }
checks=$((checks + 1))
grep -q -- '-DHOST_CUSTOM=1' "$log" \
	|| { printf 'FAIL: custom host workload did not reach the compiler\n' >&2; exit 1; }
checks=$((checks + 1))

run_make test-sim-cd4053 SIM_DEFS=-DSIM_FAST=1 >/dev/null
[[ "$(compile_count test/avr/test_sim_cd4053)" -eq 1 ]] \
	|| { printf 'FAIL: initial simulator workload did not compile once\n' >&2; exit 1; }
checks=$((checks + 1))
run_make test-sim-cd4053 SIM_DEFS= >/dev/null
[[ "$(compile_count test/avr/test_sim_cd4053)" -eq 2 ]] \
	|| { printf 'FAIL: FAST-to-FULL simulator workload reused a stale binary\n' >&2; exit 1; }
checks=$((checks + 1))
run_make test-sim-cd4053 SIM_DEFS=-DSIM_CUSTOM=1 >/dev/null
[[ "$(compile_count test/avr/test_sim_cd4053)" -eq 3 ]] \
	|| { printf 'FAIL: custom simulator workload reused a stale binary\n' >&2; exit 1; }
checks=$((checks + 1))
grep -q -- '-DSIM_CUSTOM=1' "$log" \
	|| { printf 'FAIL: custom simulator workload did not reach the compiler\n' >&2; exit 1; }
checks=$((checks + 1))

: > "$log"
run_make test-sim SIM_DEFS=-DRECURSIVE_SIM=1 >/dev/null
[[ "$(grep -c -- '-DRECURSIVE_SIM=1' "$log")" -eq 3 ]] \
	|| { printf 'FAIL: recursive simulator phase lost effective SIM_DEFS\n' >&2; exit 1; }
checks=$((checks + 1))
: > "$log"
run_make test-sim SIM_DEFS= >/dev/null
[[ "$(compile_count test/avr/test_sim_cd4053)" -eq 1 ]] \
	|| { printf 'FAIL: recursive FULL simulator phase did not rebuild\n' >&2; exit 1; }
if grep -q -- '-DSIM_RANDOM_NOISE_DURATION_MS=' "$log"; then
	printf 'FAIL: recursive FULL simulator phase fell back to FAST definitions\n' >&2
	exit 1
fi
checks=$((checks + 1))

: > "$log"
run_make -j2 test-sim-cd4053-t85 test-fault-inject-cd4053-t85 \
	SIM_DEFS=-DX5_SHARED=1 >/dev/null
[[ "$(compile_count test/avr/test_sim_cd4053_t85)" -eq 1 ]] \
	|| { printf 'FAIL: shared tinyx5 binary compiled more than once per graph\n' >&2; exit 1; }
checks=$((checks + 1))
run_make test-sim-cd4053-t85 SIM_DEFS= >/dev/null
[[ "$(compile_count test/avr/test_sim_cd4053_t85)" -eq 2 ]] \
	|| { printf 'FAIL: tinyx5 FAST-to-FULL workload reused a stale binary\n' >&2; exit 1; }
checks=$((checks + 1))

: > "$log"
run_make test/avr/test_trace_cd4053 SIM_DEFS=-DTRACE_FAST=1 >/dev/null
run_make test/avr/test_trace_cd4053 SIM_DEFS= >/dev/null
[[ "$(compile_count test/avr/test_trace_cd4053)" -eq 2 ]] \
	|| { printf 'FAIL: trace workload reused a stale binary\n' >&2; exit 1; }
checks=$((checks + 1))

if grep -Eq '^test-long:.*(^|[[:space:]])clean-tests([[:space:]]|$$)' "$repo/Makefile"; then
	printf 'FAIL: test-long reintroduced the parallel clean-tests race\n' >&2
	exit 1
fi
checks=$((checks + 1))

outside="$work/external-build"
run_make test-sim-cd4053 AVR_BUILD_DIR="$outside" SIM_DEFS=-DISOLATED=1 >/dev/null
[ ! -e "$outside/bypass_cd4053.elf" ] \
	|| { printf 'FAIL: regression escaped its isolated mini-tree build path\n' >&2; exit 1; }
checks=$((checks + 1))

printf 'workload rebuild validation: %d checks, 0 failures\n' "$checks"
