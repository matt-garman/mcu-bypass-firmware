#!/usr/bin/env bash
# Host-only fake-tool proof that the source-checkout PIC10F32x programming goals
# cannot inherit a different writer, part, or image through GNU Make inputs.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-${HOME:?HOME is required when TMPDIR is unset}}/test-pic-program.XXXXXX")
trap 'rm -rf "$work"' EXIT
tools="$work/tools"
program_log="$work/program.log"
output="$work/make.log"
repo_lock_id=$(stat -Lc '%d:%i' "$ROOT")
checks=0

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

read -r -a MAKE_CMD <<<"${PROJECT_MAKE:-make}"
[ "${#MAKE_CMD[@]}" -gt 0 ] || fail "PROJECT_MAKE must name a Make command"

mkdir -p "$tools" "$work/build322" "$work/build320"

# Emit the minimum valid XC8-shaped image and sidecars consumed by the real
# build, Intel-HEX, flash-budget, and PIC10F320 return-stack gates.
cat > "$tools/xc8" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=
while [ "$#" -gt 0 ]; do
	if [ "$1" = -o ]; then out=$2; shift 2; else shift; fi
done
[ -n "$out" ] || exit 2
printf '%s\n' ':020000000028D6' ':02400E009E38DA' ':00000001FF' > "$out"
printf '_ctx_:\n ds 3\n' > "${out%.hex}.s"
printf '%s\n' '_ctx_ 0021 0023 BANK0 0' '_gpio_shadow_ 0020 0020 BANK0 0' \
	'%segments' > "${out%.hex}.sym"
printf 'Program space used 2Ah (42) of 400h words (4.1%%)\n'
printf 'Data space used 20h (32) of 40h bytes (50.0%%)\n'
EOF

cat > "$tools/programmer" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s' "\${0##*/}" >> "$program_log"
printf '\t%s' "\$@" >> "$program_log"
printf '\n' >> "$program_log"
EOF
chmod 755 "$tools/xc8" "$tools/programmer"
ln -s programmer "$tools/pk2cmd"
ln -s programmer "$tools/ipecmd"
ln -s programmer "$tools/custom-programmer"
ln -s programmer "$tools/inherited-programmer"

clean_env=(
	env -u MAKEFLAGS -u MFLAGS -u GNUMAKEFLAGS -u MAKEOVERRIDES
	-u MAKEFILES -u MAKELEVEL -u MAKE
	-u PIC10F322_PART -u PIC10F322_PROG -u PIC10F322_PROG_TOOL
	-u PIC10F322_PROG_HEX -u PIC10F322_PROG_CMD
	-u PIC10F320_PART -u PIC10F320_PROG -u PIC10F320_PROG_TOOL
	-u PIC10F320_PROG_HEX -u PIC10F320_PROG_CMD
)

make_args=(
	--no-print-directory -C "$ROOT"
	"PIC_CC=$tools/xc8"
	"PIC10F320_CC=$tools/xc8"
	"PIC10F322_BUILD_DIR=$work/build322"
	"PIC10F320_BUILD_DIR=$work/build320"
)

run_clean() {
	"${clean_env[@]}" TMPDIR="$work" PATH="$tools:$PATH" \
		PIC_PROGRAMMER_LOG="$program_log" \
		"${MAKE_CMD[@]}" "${make_args[@]}" "$@"
}

program_calls() {
	if [ -f "$program_log" ]; then wc -l < "$program_log"; else printf '0\n'; fi
}

check_clean_route() {
	local part=$1 goal=$2 selector=$3 build=$4 cmd_var=$5
	: > "$program_log"
	run_clean "$goal" "$selector=cd4053_simple" > "$output" 2>&1 \
		|| { sed -n '1,120p' "$output" >&2; fail "$goal failed with canonical fake tools"; }
	[ "$(program_calls)" -eq 1 ] \
		|| fail "$goal invoked $(program_calls) programmer commands instead of 1"
	grep -F -- "-P$part" "$program_log" >/dev/null \
		|| fail "$goal did not keep the canonical $part identity"
	local expected=pk2cmd actual
	expected+=$'\t'"-P$part"
	expected+=$'\t'"-F$build/bypass-${part,,}-cd4053_simple.hex"
	expected+=$'\t-M\t-Y\t-R'
	IFS= read -r actual < "$program_log"
	[ "$actual" = "$expected" ] \
		|| fail "$goal command was '$actual', expected '$expected'"
	checks=$((checks + 1))

	: > "$program_log"
	run_clean "$goal-custom" "$selector=cd4053_simple" \
		"${cmd_var%_CMD}=$tools/missing-default-programmer" \
		"$cmd_var=$tools/custom-programmer --custom $part" > "$output" 2>&1 \
		|| { sed -n '1,120p' "$output" >&2; fail "$goal-custom rejected an explicit command-line override"; }
	[ "$(program_calls)" -eq 1 ] \
		|| fail "$goal-custom invoked $(program_calls) programmer commands instead of 1"
	IFS= read -r actual < "$program_log"
	[ "$actual" = $'custom-programmer\t--custom\t'"$part" ] \
		|| fail "$goal-custom command was not the exact explicit custom command: $actual"
	checks=$((checks + 1))
}

expect_reject() {
	local label=$1 mode=$2 assignment=$3 goal=$4 selector=$5
	: > "$program_log"
	case "$mode" in
		command-line)
			if run_clean "$goal" "$selector=cd4053_simple" "$assignment" > "$output" 2>&1; then
				fail "$label was accepted"
			fi
			;;
		environment)
			if "${clean_env[@]}" "$assignment" TMPDIR="$work" PATH="$tools:$PATH" \
					PIC_PROGRAMMER_LOG="$program_log" \
					"${MAKE_CMD[@]}" "${make_args[@]}" "$goal" \
					"$selector=cd4053_simple" > "$output" 2>&1; then
				fail "$label was accepted"
			fi
			;;
		environment-e)
			if "${clean_env[@]}" "$assignment" TMPDIR="$work" PATH="$tools:$PATH" \
					PIC_PROGRAMMER_LOG="$program_log" \
					"${MAKE_CMD[@]}" -e "${make_args[@]}" "$goal" \
					"$selector=cd4053_simple" > "$output" 2>&1; then
				fail "$label was accepted"
			fi
			;;
		makeflags)
			if "${clean_env[@]}" "MAKEFLAGS=$assignment" TMPDIR="$work" PATH="$tools:$PATH" \
					PIC_PROGRAMMER_LOG="$program_log" \
					"${MAKE_CMD[@]}" "${make_args[@]}" "$goal" \
					"$selector=cd4053_simple" > "$output" 2>&1; then
				fail "$label was accepted"
			fi
			;;
		*) fail "unknown launch mode: $mode" ;;
	esac
	grep -F "$goal rejects programmer override(s):" "$output" >/dev/null \
		|| { sed -n '1,120p' "$output" >&2; fail "$label failed without the programmer-override diagnostic"; }
	[ "$(program_calls)" -eq 0 ] \
		|| fail "$label reached the fake programmer before rejection"
	checks=$((checks + 1))
}

expect_control_reject() {
	local label=$1 control=$2 goal=$3 selector=$4 prefix=$5
	: > "$program_log"
	case "$control" in
		eval)
			control="MAKEFLAGS=--eval=$goal:\ ${prefix}_PROG_CMD=$tools/inherited-programmer"
			;;
		makefiles)
			control="MAKEFILES=$work/injected.mk"
			;;
		*) fail "unknown Make control: $control" ;;
	esac
	if "${clean_env[@]}" "$control" TMPDIR="$work" PATH="$tools:$PATH" \
			PIC_PROGRAMMER_LOG="$program_log" \
			"${MAKE_CMD[@]}" "${make_args[@]}" "$goal" \
			"$selector=cd4053_simple" > "$output" 2>&1; then
		fail "$label was accepted"
	fi
	grep -F "$goal rejects inherited Make control:" "$output" >/dev/null \
		|| { sed -n '1,120p' "$output" >&2; fail "$label failed without the Make-control diagnostic"; }
	[ "$(program_calls)" -eq 0 ] \
		|| fail "$label reached the fake programmer before rejection"
	checks=$((checks + 1))
}

expect_guard_self_protected() {
	local goal=$1 selector=$2 prefix=$3
	: > "$program_log"
	if "${clean_env[@]}" \
			_pic_programmer_override_names= \
			"_${prefix}_PROGRAMMER_INPUTS=" \
			"_${prefix}_PROGRAMMER_OVERRIDES=" \
			"${prefix}_PROG_CMD=$tools/inherited-programmer" \
			TMPDIR="$work" PATH="$tools:$PATH" PIC_PROGRAMMER_LOG="$program_log" \
			"${MAKE_CMD[@]}" -e "${make_args[@]}" "$goal" \
			"$selector=cd4053_simple" > "$output" 2>&1; then
		fail "$goal accepted environment overrides of its guard internals"
	fi
	grep -F "$goal rejects programmer override(s):" "$output" >/dev/null \
		|| { sed -n '1,120p' "$output" >&2; fail "$goal guard internals were not immutable"; }
	[ "$(program_calls)" -eq 0 ] \
		|| fail "$goal guard-internal override reached the fake programmer"
	checks=$((checks + 1))
}

expect_goal_spoof_reject() {
	local goal=$1 selector=$2 prefix=$3
	: > "$program_log"
	if run_clean "$goal" "$selector=cd4053_simple" \
			"MAKECMDGOALS=$goal-custom" \
			"_MAKE_SERIAL_LOCK_HELD=$repo_lock_id" \
			"${prefix}_PROG_CMD=$tools/inherited-programmer" > "$output" 2>&1; then
		fail "$goal accepted a programmer override after its parse-time goal was spoofed"
	fi
	grep -F "$goal rejects programmer override(s):" "$output" >/dev/null \
		|| { sed -n '1,120p' "$output" >&2; fail "$goal did not enforce its recipe-time guard"; }
	[ "$(program_calls)" -eq 0 ] \
		|| fail "$goal goal-spoof attempt reached the fake programmer"
	checks=$((checks + 1))
}

expect_function_shadow_safe() {
	local goal=$1 selector=$2 part=$3 build=$4
	: > "$program_log"
	if "${clean_env[@]}" \
			'BASH_FUNC_pk2cmd%%=() { printf "function-shadow\n" >> "$PIC_PROGRAMMER_LOG"; }' \
			"BASH_FUNC_command%%=() { printf '%s\\n' '$tools/inherited-programmer'; }" \
			'BASH_FUNC_false%%=() { return 0; }' \
			TMPDIR="$work" PATH="$tools:$PATH" PIC_PROGRAMMER_LOG="$program_log" \
			"${MAKE_CMD[@]}" "${make_args[@]}" "$goal" \
			"$selector=cd4053_simple" > "$output" 2>&1; then
		[ "$(program_calls)" -eq 1 ] \
			|| fail "$goal function-shadow control did not make exactly one safe programmer call"
		local expected=pk2cmd actual
		expected+=$'\t'"-P$part"
		expected+=$'\t'"-F$build/bypass-${part,,}-cd4053_simple.hex"
		expected+=$'\t-M\t-Y\t-R'
		IFS= read -r actual < "$program_log"
		[ "$actual" = "$expected" ] \
			|| fail "$goal function-shadow command was '$actual', expected '$expected'"
	else
		[ "$(program_calls)" -eq 0 ] \
			|| fail "$goal invoked a writer before rejecting the inherited Bash function"
		grep -F "programmer 'pk2cmd' not found on PATH" "$output" >/dev/null \
			|| { sed -n '1,120p' "$output" >&2; fail "$goal rejected the function shadow for the wrong reason"; }
	fi
	checks=$((checks + 1))
}

check_part() {
	local part=$1 goal=$2 selector=$3 prefix=$4 build=$5
	local name value
	check_clean_route "$part" "$goal" "$selector" "$build" "${prefix}_PROG_CMD"

	for name in PART PROG PROG_TOOL PROG_HEX PROG_CMD; do
		case "$name" in
			PART) value=FOREIGN_PART ;;
			PROG) value="$tools/inherited-programmer" ;;
			PROG_TOOL) value=PK5 ;;
			PROG_HEX) value="$work/foreign.hex" ;;
			PROG_CMD) value="$tools/inherited-programmer" ;;
		esac
		for mode in command-line environment environment-e makeflags; do
			expect_reject "$goal with $mode ${prefix}_$name" "$mode" \
				"${prefix}_$name=$value" "$goal" "$selector"
		done
	done
	expect_control_reject "$goal with a target-specific eval" eval \
		"$goal" "$selector" "$prefix"
	expect_control_reject "$goal with a preloaded makefile" makefiles \
		"$goal" "$selector" "$prefix"
	expect_guard_self_protected "$goal" "$selector" "$prefix"
	expect_goal_spoof_reject "$goal" "$selector" "$prefix"
	expect_function_shadow_safe "$goal" "$selector" "$part" "$build"
}

cat > "$work/injected.mk" <<EOF
pic10f322-program: PIC10F322_PROG_CMD=$tools/inherited-programmer
pic10f320-program: PIC10F320_PROG_CMD=$tools/inherited-programmer
EOF

check_part PIC10F322 pic10f322-program VARIANT PIC10F322 "$work/build322"
check_part PIC10F320 pic10f320-program PIC10F320_VARIANT PIC10F320 "$work/build320"

printf 'PIC10F32x programming guard: %d checks, 0 failures\n' "$checks"
