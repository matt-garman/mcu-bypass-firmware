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
unset AVR_BUILD_DIR AVR_FW FW_BASE AVR_REBUILD_PREREQ VARIANTS MCU
unset XT_FUSE_WDTCFG XT_FUSE_BODCFG XT_FUSE_OSCCFG XT_FUSE_SYSCFG0
unset XT_FUSE_SYSCFG1 XT_FUSE_APPEND XT_FUSE_BOOTEND
unset FAKE_COMPILER_MODE
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
case "${FAKE_COMPILER_MODE:-pass}" in
	fail) printf 'partial compiler output\n' > "$out"; exit 1 ;;
	empty) : > "$out"; exit 0 ;;
esac
status=0
case "$out" in
	*test_fuses.tmp.*)
		for define in \
			-DT13_LFUSE=0x4a -DT13_HFUSE=0xf9 \
			-DT85_LFUSE=0x62 -DT85_HFUSE=0xcc \
			-DT202_WDTCFG=0x06 -DT202_BODCFG=0xE5 \
			-DT202_OSCCFG=0x01 -DT202_SYSCFG0=0xF6 \
			-DT202_SYSCFG1=0x07 -DT202_APPEND=0x00 \
			-DT202_BOOTEND=0x00; do
			case " $* " in *" $define "*) ;; *) status=1 ;; esac
		done
		;;
esac
printf '#!/bin/sh\nexit %d\n' "$status" > "$out"
chmod 750 "$out"
EOF
chmod 750 "$tools/cc"

cat > "$tools/size" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'Program: 512 bytes (50.0%% Full)\n'
EOF

cat > "$tools/readelf" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '  Machine: Atmel AVR 8-bit microcontroller\n'
printf '  Flags: 0x19, avr:25, link-relax\n'
EOF
chmod 750 "$tools/size" "$tools/readelf" "$repo/test/check_flash_budget.sh"

files=(
	test/host/test_logic_host.c test/avr/test_sim.c test/avr/test_fuses.c
	test/model_step.h
	test/bypass_config_host.h test/bypass_output_host.h
	src/bypass_config.h src/bypass_types.h src/bypass_hw_iface.h
	src/bypass_output_common.h src/bypass_pins_avr_classic.h
	src/bypass_blocking_delay.h src/bypass_static_assert.h
	src/bypass_compile_checks.h
	src/bypass_output_cd4053_with_mute.h
	src/bypass_output_tq2_l2_5v_relay.h src/bypass_mcu_avr_classic.c
	src/bypass_output_cd4053_simple.c src/bypass_output_cd4053_with_mute.c
	src/bypass_output_tq2_l2_5v_relay.c src/bypass_pure.c src/bypass_pure.h
)
for file in "${files[@]}"; do
	mkdir -p "$repo/${file%/*}"
	: > "$repo/$file"
done
cp "$ROOT/test/avr/attiny202_fuses.py" "$ROOT/test/avr/test_attiny202_fuses.py" \
	"$repo/test/avr/"
for image in bypass-attiny13a-cd4053_simple.elf bypass-attiny13a-cd4053_with_mute.elf bypass-attiny13a-tq2_l2_5v_relay.elf \
	bypass-attiny85-cd4053_simple.elf; do
	printf 'firmware ELF\n' > "$repo/build_avr_classic/$image"
done
: > "$log"

run_make() {
	FAKE_COMPILER_LOG="$log" make --no-print-directory -C "$repo" "$@" \
		CC="$tools/cc" HOSTCC="$tools/cc" SANITIZE= \
		SIZE="$tools/size" READELF="$tools/readelf" SIM_LIBS= AVR_BUILD_DIR=build_avr_classic \
		AVR_FW=build_avr_classic/bypass FW_BASE=bypass ATTINY13A_MCU=attiny13a \
		VARIANTS="cd4053_simple cd4053_with_mute tq2_l2_5v_relay"
}

compile_count() {
	local output=$1
	grep -c -- "-o $output" "$log" || true
}

run_make test-host HOST_DEFS=-DHOST_FAST=1 >/dev/null
[[ "$(compile_count test/host/test_logic_host)" -eq 1 ]] \
	|| { printf 'FAIL: initial host workload did not compile once\n' >&2; exit 1; }
checks=$((checks + 1))

run_make test-fuses >/dev/null
[[ "$(compile_count test/avr/test_fuses)" -eq 1 ]] \
	|| { printf 'FAIL: initial fuse configuration did not compile once\n' >&2; exit 1; }
checks=$((checks + 1))
if run_make test-fuses ATTINY13A_LFUSE=0x00 ATTINY13A_HFUSE=0x00 \
		TINYX5_LFUSE=0x00 TINYX5_HFUSE=0x00 \
		XT_FUSE_WDTCFG=0x00 XT_FUSE_BODCFG=0x00 \
		XT_FUSE_OSCCFG=0x00 XT_FUSE_SYSCFG0=0x00 \
		XT_FUSE_SYSCFG1=0x00 XT_FUSE_APPEND=0x01 \
		XT_FUSE_BOOTEND=0x01 >/dev/null 2>&1; then
	printf 'FAIL: unsafe fuse overrides reused a stale checker\n' >&2
	exit 1
fi
[[ "$(compile_count test/avr/test_fuses)" -eq 2 ]] \
	&& grep -q -- '-DT13_LFUSE=0x00' "$log" \
	&& grep -q -- '-DT13_HFUSE=0x00' "$log" \
	&& grep -q -- '-DT85_LFUSE=0x00' "$log" \
	&& grep -q -- '-DT85_HFUSE=0x00' "$log" \
	&& grep -q -- '-DT202_WDTCFG=0x00' "$log" \
	&& grep -q -- '-DT202_BODCFG=0x00' "$log" \
	&& grep -q -- '-DT202_OSCCFG=0x00' "$log" \
	&& grep -q -- '-DT202_SYSCFG0=0x00' "$log" \
	&& grep -q -- '-DT202_SYSCFG1=0x00' "$log" \
	&& grep -q -- '-DT202_APPEND=0x01' "$log" \
	&& grep -q -- '-DT202_BOOTEND=0x01' "$log" \
	|| { printf 'FAIL: current fuse overrides did not reach the checker compiler\n' >&2; exit 1; }
checks=$((checks + 1))
run_make test-fuses >/dev/null
[[ "$(compile_count test/avr/test_fuses)" -eq 3 ]] \
	|| { printf 'FAIL: restoring safe fuse values did not rebuild the checker\n' >&2; exit 1; }
checks=$((checks + 1))

if (export FAKE_COMPILER_MODE=fail; run_make test-fuses) >/dev/null 2>&1; then
	printf 'FAIL: fuse-checker compiler failure was accepted\n' >&2
	exit 1
fi
[[ ! -e "$repo/test/avr/test_fuses" ]] \
	|| { printf 'FAIL: compiler failure left a stale fuse checker\n' >&2; exit 1; }
shopt -s nullglob
fuse_temps=("$repo/test/avr/test_fuses".tmp.*)
shopt -u nullglob
[[ "${#fuse_temps[@]}" -eq 0 ]] \
	|| { printf 'FAIL: compiler failure left temporary fuse-checker output\n' >&2; exit 1; }
run_make test-fuses >/dev/null
[[ -x "$repo/test/avr/test_fuses" ]] \
	|| { printf 'FAIL: could not restore fuse checker before empty-output test\n' >&2; exit 1; }
if (export FAKE_COMPILER_MODE=empty; run_make test-fuses) >/dev/null 2>&1; then
	printf 'FAIL: empty fuse-checker compiler output was accepted\n' >&2
	exit 1
fi
[[ ! -e "$repo/test/avr/test_fuses" ]] \
	|| { printf 'FAIL: empty compiler output left a stale fuse checker\n' >&2; exit 1; }
shopt -s nullglob
fuse_temps=("$repo/test/avr/test_fuses".tmp.*)
shopt -u nullglob
[[ "${#fuse_temps[@]}" -eq 0 ]] \
	|| { printf 'FAIL: fuse-checker compiler failures left temporary output\n' >&2; exit 1; }
checks=$((checks + 2))
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

run_make test-sim-cd4053_simple-attiny13a SIM_DEFS=-DSIM_FAST=1 >/dev/null
[[ "$(compile_count test/avr/test_sim_cd4053_simple_attiny13a)" -eq 1 ]] \
	|| { printf 'FAIL: initial simulator workload did not compile once\n' >&2; exit 1; }
checks=$((checks + 1))
run_make test-sim-cd4053_simple-attiny13a SIM_DEFS= >/dev/null
[[ "$(compile_count test/avr/test_sim_cd4053_simple_attiny13a)" -eq 2 ]] \
	|| { printf 'FAIL: FAST-to-FULL simulator workload reused a stale binary\n' >&2; exit 1; }
checks=$((checks + 1))
run_make test-sim-cd4053_simple-attiny13a SIM_DEFS=-DSIM_CUSTOM=1 >/dev/null
[[ "$(compile_count test/avr/test_sim_cd4053_simple_attiny13a)" -eq 3 ]] \
	|| { printf 'FAIL: custom simulator workload reused a stale binary\n' >&2; exit 1; }
checks=$((checks + 1))
grep -q -- '-DSIM_CUSTOM=1' "$log" \
	|| { printf 'FAIL: custom simulator workload did not reach the compiler\n' >&2; exit 1; }
checks=$((checks + 1))

: > "$log"
run_make test-sim-attiny13a SIM_DEFS=-DRECURSIVE_SIM=1 >/dev/null
[[ "$(grep -c -- '-DRECURSIVE_SIM=1' "$log")" -eq 3 ]] \
	|| { printf 'FAIL: recursive simulator phase lost effective SIM_DEFS\n' >&2; exit 1; }
checks=$((checks + 1))
: > "$log"
run_make test-sim-attiny13a SIM_DEFS= >/dev/null
[[ "$(compile_count test/avr/test_sim_cd4053_simple_attiny13a)" -eq 1 ]] \
	|| { printf 'FAIL: recursive FULL simulator phase did not rebuild\n' >&2; exit 1; }
if grep -q -- '-DSIM_RANDOM_NOISE_DURATION_MS=' "$log"; then
	printf 'FAIL: recursive FULL simulator phase fell back to FAST definitions\n' >&2
	exit 1
fi
checks=$((checks + 1))

: > "$log"
(
	export MAKEFLAGS=-B
	run_make test-sim-attiny13a SIM_DEFS=-DFORCED_SIM=1
) >/dev/null
[[ "$(compile_count build_avr_classic/bypass-attiny13a-cd4053_simple.elf)" -eq 1 \
	&& "$(compile_count build_avr_classic/bypass-attiny13a-cd4053_with_mute.elf)" -eq 1 \
	&& "$(compile_count build_avr_classic/bypass-attiny13a-tq2_l2_5v_relay.elf)" -eq 1 ]] \
	|| { printf 'FAIL: inherited -B rebuilt ELFs after flash-budget validation\n' >&2; exit 1; }
checks=$((checks + 1))

: > "$log"
run_make -j2 test-sim-attiny13a test-flash-budget SIM_DEFS=-DCOALESCED_SIM=1 >/dev/null
[[ "$(compile_count build_avr_classic/bypass-attiny13a-cd4053_simple.elf)" -eq 1 \
	&& "$(compile_count build_avr_classic/bypass-attiny13a-cd4053_with_mute.elf)" -eq 1 \
	&& "$(compile_count build_avr_classic/bypass-attiny13a-tq2_l2_5v_relay.elf)" -eq 1 ]] \
	|| { printf 'FAIL: parallel simulator and flash gates rebuilt shared ELFs more than once\n' >&2; exit 1; }
checks=$((checks + 1))

: > "$log"
run_make -j2 test-sim-cd4053_simple-attiny85 test-fault-inject-cd4053_simple-attiny85 \
	SIM_DEFS=-DX5_SHARED=1 >/dev/null
[[ "$(compile_count test/avr/test_sim_cd4053_simple_attiny85)" -eq 1 ]] \
	|| { printf 'FAIL: shared tinyx5 binary compiled more than once per graph\n' >&2; exit 1; }
checks=$((checks + 1))
run_make test-sim-cd4053_simple-attiny85 SIM_DEFS= >/dev/null
[[ "$(compile_count test/avr/test_sim_cd4053_simple_attiny85)" -eq 2 ]] \
	|| { printf 'FAIL: tinyx5 FAST-to-FULL workload reused a stale binary\n' >&2; exit 1; }
checks=$((checks + 1))

: > "$log"
run_make test/avr/test_trace_cd4053_simple SIM_DEFS=-DTRACE_FAST=1 >/dev/null
run_make test/avr/test_trace_cd4053_simple SIM_DEFS= >/dev/null
[[ "$(compile_count test/avr/test_trace_cd4053_simple)" -eq 2 ]] \
	|| { printf 'FAIL: trace workload reused a stale binary\n' >&2; exit 1; }
checks=$((checks + 1))

# Shared prerequisites inherit a target-specific workload profile from their
# parent. Mixing FAST and FULL parents in one graph is ambiguous and must fail
# before either aggregate can print a misleading success banner.
for request in "test stress" "test-fast test-long"; do
	if output=$(run_make $request 2>&1); then
		printf 'FAIL: mixed workload profiles were accepted: %s\n' "$request" >&2
		exit 1
	fi
	case "$output" in
		*"request either a FAST test/test-fast profile or a FULL stress/test-long profile, not both"*) ;;
		*) printf 'FAIL: mixed workload profile produced the wrong diagnostic: %s\n' "$output" >&2
			exit 1 ;;
	esac
done
checks=$((checks + 2))

# Read Make's expanded target database so these assertions cover the actual
# aggregate prerequisites, not merely the variables they are intended to use.
# Question mode normally returns 1 for an out-of-date phony default goal; only a
# parse/database failure (status > 1) is an error here.
make_db="$work/make.db"
worktree_id=$(stat -Lc '%d:%i' "$repo")
set +e
run_make -pRrq _MAKE_SERIAL_LOCK_HELD="$worktree_id" > "$make_db" 2>/dev/null
make_db_status=$?
set -e
[ "$make_db_status" -le 1 ] \
	|| { printf 'FAIL: could not read Make target database\n' >&2; exit 1; }

aggregate_prereqs() {
	awk -v target="$1:" '
		$1 == target && index($0, "=") == 0 {
			for (i = 2; i <= NF; i++) print $i
		}' "$make_db"
}

aggregate_profile() {
	awk -v target="$1:" -v variable="$2" '
		$1 == target && $2 == variable && $3 == "=" { print $4 }
		' "$make_db"
}

fast_gates=$(aggregate_prereqs test | grep -v '^$' | sort)
stress_gates=$(aggregate_prereqs stress | grep -v '^$' | sort)
long_gates=$(aggregate_prereqs test-long | grep -v '^$' | sort)
for aggregate in test stress test-long; do
	gates=$(aggregate_prereqs "$aggregate")
	[ -n "$gates" ] \
		|| { printf 'FAIL: could not read %s prerequisites from Make\n' "$aggregate" >&2; exit 1; }
	if printf '%s\n' "$gates" | grep -Fxq clean-tests; then
		printf 'FAIL: %s reintroduced the parallel clean-tests race\n' "$aggregate" >&2
		exit 1
	fi
done
checks=$((checks + 7))

# Both FULL aggregates must select the empty in-source-default profiles. Pin the
# target-specific assignments as well as gate membership so `stress` cannot
# accidentally become a fast non-mutation alias.
for aggregate in stress test-long; do
	[ "$(aggregate_profile "$aggregate" HOST_DEFS)" = '$(FULL_HOST_DEFS)' ] \
		|| { printf 'FAIL: %s does not select FULL_HOST_DEFS\n' "$aggregate" >&2; exit 1; }
	[ "$(aggregate_profile "$aggregate" SIM_DEFS)" = '$(FULL_SIM_DEFS)' ] \
		|| { printf 'FAIL: %s does not select FULL_SIM_DEFS\n' "$aggregate" >&2; exit 1; }
done
checks=$((checks + 4))

# Stress is exactly the shared non-mutation inventory. test-long is that same
# inventory plus one full mutation gate, preserving release qualification while
# normal hosted stress avoids the duplicate run.
if ! diff_out=$(diff <(printf '%s\n' "$fast_gates") \
		<(printf '%s\n' "$stress_gates")); then
	printf 'FAIL: test and stress do not run the same base gates:\n%s\n' \
		"$diff_out" >&2
	exit 1
fi
long_without_mutation=$(printf '%s\n' "$long_gates" | grep -Fxv test-mutation)
if ! diff_out=$(diff <(printf '%s\n' "$fast_gates") \
		<(printf '%s\n' "$long_without_mutation")); then
	printf 'FAIL: test-long is not the base inventory plus mutation:\n%s\n' \
		"$diff_out" >&2
	exit 1
fi
[ "$(printf '%s\n' "$stress_gates" | grep -Fxc test-mutation || true)" -eq 0 ] \
	|| { printf 'FAIL: stress includes the full mutation gate\n' >&2; exit 1; }
[ "$(printf '%s\n' "$long_gates" | grep -Fxc test-mutation || true)" -eq 1 ] \
	|| { printf 'FAIL: test-long does not include exactly one full mutation gate\n' >&2; exit 1; }
[ "$(printf '%s\n' "$stress_gates" | grep -Fxc test-mutation-sandbox || true)" -eq 1 ] \
	|| { printf 'FAIL: stress lost the mutation-driver sandbox regression\n' >&2; exit 1; }
# Compute the reverse transitive closure as a separate assertion: no other Make
# target may acquire mutation indirectly and become a second CI route. Ignore
# Make's dot-prefixed special targets such as .PHONY, which list names rather
# than execution prerequisites.
mutation_ancestors=$(awk '
	$0 == "# Files" { in_files = 1; next }
	$0 == "# files hash-table stats:" { in_files = 0 }
	in_files && $0 !~ /^[[:space:]#]/ && $1 ~ /:$/ && $1 !~ /^\./ \
			&& index($0, "=") == 0 {
		target = $1
		sub(/:$/, "", target)
		for (i = 2; i <= NF; i++) {
			if ($i != "|") edge[target SUBSEP $i] = 1
		}
	}
	END {
		reaches["test-mutation"] = 1
		changed = 1
		while (changed) {
			changed = 0
			for (pair in edge) {
				split(pair, nodes, SUBSEP)
				if (reaches[nodes[2]] && !reaches[nodes[1]]) {
					reaches[nodes[1]] = 1
					changed = 1
				}
			}
		}
		for (target in reaches) {
			if (target != "test-mutation" && reaches[target]) print target
		}
	}' "$make_db" | sort)
[ "$mutation_ancestors" = test-long ] \
	|| { printf 'FAIL: Make targets other than test-long reach full mutation: %s\n' \
		"$mutation_ancestors" >&2; exit 1; }
checks=$((checks + 6))

# No gate may appear twice in any aggregate. Make would still run a phony
# prerequisite once, so a duplicate is not double execution; it is the
# fingerprint of a hand edit that can later remove only one copy.
for aggregate in test stress test-long; do
	dupes=$(aggregate_prereqs "$aggregate" | grep -v '^$' | sort | uniq -d)
	[ -z "$dupes" ] \
		|| { printf 'FAIL: %s lists a gate more than once: %s\n' \
			"$aggregate" "$(printf '%s' "$dupes" | tr '\n' ' ')" >&2; exit 1; }
done
checks=$((checks + 3))

# The two PIC shipping-source coverage gates are named explicitly because they
# are the ones that were reachable ONLY through standalone full-tool aggregates,
# and because they are the reason `make test` can catch a PIC host-oracle
# regression at all. Both need nothing beyond the host compiler, gcov and Bash
# that `test` already requires, so neither has an excuse to leave the inventory.
for gate in pic10f322-coverage-check-fw pic12f675-coverage-check-fw; do
	found=$(printf '%s\n' "$fast_gates" | grep -Fxc "$gate" || true)
	[ "$found" = 1 ] \
		|| { printf 'FAIL: %s appears %s times in the shared gate inventory, expected exactly 1\n' \
			"$gate" "$found" >&2; exit 1; }
done
checks=$((checks + 2))

outside="$work/external-build"
run_make test-sim-cd4053_simple-attiny13a AVR_BUILD_DIR="$outside" SIM_DEFS=-DISOLATED=1 >/dev/null
[ ! -e "$outside/bypass-attiny13a-cd4053_simple.elf" ] \
	|| { printf 'FAIL: regression escaped its isolated mini-tree build path\n' >&2; exit 1; }
checks=$((checks + 1))

printf 'workload rebuild validation: %d checks, 0 failures\n' "$checks"
