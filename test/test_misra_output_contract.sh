#!/usr/bin/env bash
# Fail-closed regression for the five cppcheck MISRA recipes.
set -euo pipefail
# A bare `var=$(... grep ...)` that matches nothing takes this suite down with
# `set -e` and NO output: the failure has no diagnostic, and any guard on the
# next line never runs. Name the line instead of exiting mute. Deliberately no
# `set -E` -- without errtrace the trap is not inherited by the command
# substitution's subshell, so a failure is reported once rather than twice.
# This only reports; `set -e` still does the exiting, so control flow is unchanged.
# The `case $-` guard is required, not defensive: bash runs an ERR trap even
# inside a deliberate `set +e` block, and several suites use one around a
# command whose non-zero status IS the expected result (`make -q` returns 1).
# Without the guard those print a spurious FAIL that lands in retained
# release evidence, because test-long.summary.txt is built by grepping ^FAIL.
trap 'err_rc=$?; case $- in *e*) printf "FAIL: %s:%d exited %d with no diagnostic (a command substitution that matched nothing?)\n" "${BASH_SOURCE[0]}" "$LINENO" "$err_rc" >&2 ;; esac' ERR

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MAKEFILE="$ROOT/Makefile"
GATE="$ROOT/test/misra_output_gate.py"
work=$(mktemp -d "${TMPDIR:-/tmp}/test-misra-output.XXXXXX")
trap 'rm -rf "$work"' EXIT
checks=0

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

run_gate() {
	python3 "$GATE" --repo-root "$ROOT" --output "$1" --tool-status "$2"
}

expect_gate_pass() {
	local output=$1 status=$2
	run_gate "$output" "$status" >/dev/null 2>&1 \
		|| fail "output gate rejected clean/out-of-boundary fixture $output"
	checks=$((checks + 1))
}

expect_gate_fail() {
	local output=$1 status=$2 expected=$3 result
	if result=$(run_gate "$output" "$status" 2>&1); then
		fail "output gate accepted failing fixture $output"
	fi
	[[ "$result" == *"$expected"* ]] \
		|| fail "output gate failed for the wrong reason: $result"
	checks=$((checks + 1))
}

empty="$work/empty.out"
: > "$empty"
expect_gate_pass "$empty" 0

relative_header="$work/relative-header.out"
printf '%s\n' \
	'MCU_BYPASS_CPPCHECK|src/bypass_hw_iface.h|7|3|style|misra-c2012-14.4|synthetic required finding' \
	> "$relative_header"
expect_gate_fail "$relative_header" 0 "unwaived authored-firmware diagnostic"

absolute_header="$work/absolute-header.out"
printf 'MCU_BYPASS_CPPCHECK|%s|7|3|style|misra-c2012-14.4|synthetic required finding\n' \
	"$ROOT/src/bypass_hw_iface.h" > "$absolute_header"
expect_gate_fail "$absolute_header" 0 "unwaived authored-firmware diagnostic"

authored_c="$work/authored-c.out"
printf '%s\n' \
	'MCU_BYPASS_CPPCHECK|src/bypass_pure.c|8|2|style|misra-c2012-14.4|synthetic required finding' \
	> "$authored_c"
expect_gate_fail "$authored_c" 0 "unwaived authored-firmware diagnostic"

for path in /usr/include/stdint.h third_party/attiny_dfp/include/avr/io.h \
	test/bypass_config_host.h ../outside.h; do
	external="$work/external-$checks.out"
	printf 'MCU_BYPASS_CPPCHECK|%s|1|1|style|misra-c2012-14.4|adopted or non-firmware file\n' \
		"$path" > "$external"
	expect_gate_pass "$external" 0
done

malformed="$work/malformed.out"
printf '%s\n' 'MCU_BYPASS_CPPCHECK|src/bypass_hw_iface.h|not-a-line' > "$malformed"
expect_gate_fail "$malformed" 0 "unparseable cppcheck stderr"

unformatted="$work/unformatted.out"
printf '%s\n' '[src/bypass_hw_iface.h:7]: (style) synthetic [misra-c2012-14.4]' \
	> "$unformatted"
expect_gate_fail "$unformatted" 0 "unparseable cppcheck stderr"

pseudo_path="$work/pseudo-path.out"
printf '%s\n' \
	'MCU_BYPASS_CPPCHECK|<unknown>|0|0|style|misra-config|unattributed diagnostic' \
	> "$pseudo_path"
expect_gate_fail "$pseudo_path" 0 "diagnostic has an unattributed path"

expect_gate_fail "$empty" 2 "cppcheck exited with status 2"

rule_body() {
	local target=$1 file=$2
	awk -v wanted="$target" '
	$0 ~ ("^" wanted ":[^=]") { active = 1; seen_recipe = 0; next }
	active && /^\t/ { seen_recipe = 1; print; next }
	active && seen_recipe { exit }
	' "$file"
}

define_body() {
	local name=$1 file=$2
	awk -v wanted="$name" '
	$0 == "define " wanted || $0 == "override define " wanted { active = 1; next }
	active && $0 == "endef" { exit }
	active { print }
	' "$file"
}

targets=(
	analyze-misra
	attiny202-analyze-misra
	pic10f322-analyze-misra
	pic10f320-analyze-misra
	pic12f675-analyze-misra
)

runner=$(define_body run_misra_matrix_sh "$MAKEFILE")
[[ "$runner" == *'$(MISRA_OUTPUT_GATE)'* ]] \
	|| fail "shared MISRA matrix runner does not run the output gate"
[[ "$runner" == *'$(MISRA_DIAGNOSTIC_TEMPLATE)'* ]] \
	|| fail "shared MISRA matrix runner does not force the diagnostic template"
checks=$((checks + 2))

for target in "${targets[@]}"; do
	body=$(rule_body "$target" "$MAKEFILE")
	[[ "$body" == *'run_misra_matrix_sh'* ]] \
		|| fail "$target does not run the shared MISRA matrix runner"
	checks=$((checks + 1))
done

if grep -Eq -- '--suppress=misra-config' "$MAKEFILE"; then
	fail "Makefile retains an invocation-wide --suppress=misra-config"
fi
checks=$((checks + 1))

# Pin the complete committed misra-config policy: one exact source file per PIC
# shell, with no wildcard, directory, header, or fourth-file scope.
seen_322=0 seen_320=0 seen_675=0 config_suppressions=0
while IFS= read -r suppression; do
	case "$suppression" in
		misra-config:src/bypass_mcu_pic10f322.c) seen_322=1 ;;
		misra-config:src/bypass_mcu_pic10f320.c) seen_320=1 ;;
		misra-config:src/bypass_mcu_pic12f675.c) seen_675=1 ;;
		misra-config:*) fail "unreviewed or broad misra-config suppression: $suppression" ;;
		*) continue ;;
	esac
	config_suppressions=$((config_suppressions + 1))
done < "$ROOT/test/misra_suppressions.txt"
[ "$seen_322" -eq 1 ] || fail "missing file-scoped PIC10F322 misra-config accommodation"
[ "$seen_320" -eq 1 ] || fail "missing file-scoped PIC10F320 misra-config accommodation"
[ "$seen_675" -eq 1 ] || fail "missing file-scoped PIC12F675 misra-config accommodation"
[ "$config_suppressions" -eq 3 ] \
	|| fail "expected exactly 3 misra-config accommodations, found $config_suppressions"
checks=$((checks + 4))

# Prove the rule census itself can detect a severed parser invocation.
mutated_makefile="$work/Makefile"
awk '
/^(override )?define run_misra_matrix_sh$/ { in_runner = 1 }
in_runner && /\$\(MISRA_OUTPUT_GATE\)/ && !removed { removed = 1; next }
{ print }
in_runner && /^endef$/ { in_runner = 0 }
END { if (!removed) exit 2 }
' "$MAKEFILE" > "$mutated_makefile" \
	|| fail "could not construct the severed-gate Makefile fixture"
mutated_runner=$(define_body run_misra_matrix_sh "$mutated_makefile")
[[ "$mutated_runner" != *'$(MISRA_OUTPUT_GATE)'* ]] \
	|| fail "negative rule fixture still contains the output gate"
checks=$((checks + 1))

# Supply the header-presence guards without requiring any real device pack.
mkdir -p "$work/xt/include/avr" "$work/xc8" \
	"$work/dfp322/proc" "$work/dfp320/proc" "$work/dfp675/proc"
: > "$work/xt/include/avr/iotn202.h"
: > "$work/xc8/xc.h"
: > "$work/dfp322/proc/pic10f322.h"
: > "$work/dfp320/proc/pic10f320.h"
: > "$work/dfp675/proc/pic12f675.h"

fake_cppcheck="$work/fake-cppcheck"
fake_log="$work/cppcheck.log"
cat > "$fake_cppcheck" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_CPPCHECK_LOG:?}"

diagnostic_id=${FAKE_DIAGNOSTIC_ID:-misra-c2012-14.4}
diagnostic_path=${FAKE_DIAGNOSTIC_PATH:-src/bypass_hw_iface.h}
suppressions=
fail_selected=0
for arg in "$@"; do
	case "$arg" in
		--suppressions-list=*) suppressions=${arg#--suppressions-list=} ;;
	esac
	[ "$arg" != "${FAKE_FAIL_SOURCE:-}" ] || fail_selected=1
done

[ "$fail_selected" -eq 0 ] || exit "${FAKE_FAIL_STATUS:-2}"

if [ -n "$suppressions" ] && [ -f "$suppressions" ]; then
	while IFS= read -r suppression; do
		[ "$suppression" != "$diagnostic_id:$diagnostic_path" ] || exit 0
	done < "$suppressions"
fi

printf 'MCU_BYPASS_CPPCHECK|%s|7|3|style|%s|synthetic Required-rule header finding\n' \
	"$diagnostic_path" "$diagnostic_id" >&2
exit "${FAKE_CPPCHECK_STATUS:-0}"
EOF
chmod 750 "$fake_cppcheck"
: > "$fake_log"

empty_suppress="$work/empty-suppressions.txt"
matching_suppress="$work/matching-suppressions.txt"
wrong_suppress="$work/wrong-suppressions.txt"
: > "$empty_suppress"
printf '%s\n' 'misra-c2012-14.4:src/bypass_hw_iface.h' > "$matching_suppress"
printf '%s\n' 'misra-c2012-14.4:src/bypass_types.h' > "$wrong_suppress"

lane_args() {
	case "$1" in
		analyze-misra)
			LANE_ARGS=("VARIANTS=cd4053_simple")
			;;
		attiny202-analyze-misra)
			LANE_ARGS=("XT_DFP=$work/xt")
			;;
		pic10f322-analyze-misra)
			LANE_ARGS=("PIC_XC8_INCLUDE=$work/xc8" "PIC10F322_DFP_INCLUDE=$work/dfp322")
			;;
		pic10f320-analyze-misra)
			LANE_ARGS=("PIC10F320_XC8_INCLUDE=$work/xc8" "PIC10F320_DFP_INCLUDE=$work/dfp320")
			;;
		pic12f675-analyze-misra)
			LANE_ARGS=("PIC_XC8_INCLUDE=$work/xc8" "PIC12F675_DFP_INCLUDE=$work/dfp675")
			;;
		*) fail "unknown MISRA lane $1" ;;
	esac
}

run_make() {
	local target=$1 suppressions=$2
	shift 2
	(
		unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL VARIANTS
		while IFS='=' read -r name _; do
			case "$name" in _MAKE_SERIAL_CLASSIC_*) unset "$name" ;; esac
		done < <(env)
		FAKE_CPPCHECK_LOG="$fake_log" \
			make --no-print-directory -C "$ROOT" "$target" \
			"CPPCHECK=$fake_cppcheck" "MISRA_SUPPRESS=$suppressions" "$@"
	)
}

for target in "${targets[@]}"; do
	lane_args "$target"
	if output=$(run_make "$target" "$empty_suppress" "${LANE_ARGS[@]}" 2>&1); then
		fail "$target accepted a zero-exit Required-rule finding in an authored header"
	fi
	[[ "$output" == *"unwaived authored-firmware diagnostic"* ]] \
		|| fail "$target failed the header probe for the wrong reason: $output"
	checks=$((checks + 1))

	if ! output=$(run_make "$target" "$matching_suppress" "${LANE_ARGS[@]}" 2>&1); then
		fail "$target rejected the exact reviewed suppression: $output"
	fi
	[[ "$output" == *"clean (documented deviations waived"* ]] \
		|| fail "$target omitted its clean completion sentinel: $output"
	checks=$((checks + 1))
done

lane_args analyze-misra
if output=$(run_make analyze-misra "$wrong_suppress" "${LANE_ARGS[@]}" 2>&1); then
	fail "analyze-misra accepted a suppression for the right rule in the wrong header"
fi
[[ "$output" == *"unwaived authored-firmware diagnostic"* ]] \
	|| fail "wrong-file suppression failed for the wrong reason: $output"
checks=$((checks + 1))

# A failure in an early matrix row must survive later clean rows. The selected
# shell rows emit no diagnostic and exit 2; every later fake invocation exits 0.
# Only the retained tool status can make the shared output gate reject the lane.
export FAKE_FAIL_SOURCE=src/bypass_mcu_avr_classic.c
lane_args analyze-misra
if output=$(run_make analyze-misra "$matching_suppress" "${LANE_ARGS[@]}" 2>&1); then
	fail "analyze-misra lost an early matrix row's nonzero tool status"
fi
[[ "$output" == *"cppcheck exited with status 2"* ]] \
	|| fail "early MISRA row failure was rejected for the wrong reason: $output"
unset FAKE_FAIL_SOURCE
checks=$((checks + 1))

# Exercise the committed analyzer accommodations rather than only synthetic
# suppression files: the exact PIC shell is waived, the same ID in a header is
# not. The fake models cppcheck's suppression-list filtering before output.
export FAKE_DIAGNOSTIC_ID=misra-config
export FAKE_DIAGNOSTIC_PATH=src/bypass_mcu_pic10f322.c
lane_args pic10f322-analyze-misra
if ! output=$(run_make pic10f322-analyze-misra \
		"$ROOT/test/misra_suppressions.txt" "${LANE_ARGS[@]}" 2>&1); then
	fail "committed PIC10F322 misra-config accommodation did not match: $output"
fi
checks=$((checks + 1))

export FAKE_DIAGNOSTIC_PATH=src/bypass_hw_iface.h
if output=$(run_make pic10f322-analyze-misra \
		"$ROOT/test/misra_suppressions.txt" "${LANE_ARGS[@]}" 2>&1); then
	fail "committed misra-config policy suppressed an authored header"
fi
[[ "$output" == *"unwaived authored-firmware diagnostic"* ]] \
	|| fail "misra-config header scope failed for the wrong reason: $output"
unset FAKE_DIAGNOSTIC_ID FAKE_DIAGNOSTIC_PATH
checks=$((checks + 1))

invocations=0
while IFS= read -r argv; do
	invocations=$((invocations + 1))
	[[ "$argv" == *'--template=MCU_BYPASS_CPPCHECK|{file}|{line}|{column}|{severity}|{id}|{message}'* ]] \
		|| fail "MISRA invocation omitted or changed the diagnostic template: $argv"
	[[ "$argv" != *'--suppress=misra-config'* ]] \
		|| fail "MISRA invocation retained broad misra-config suppression: $argv"
done < "$fake_log"
[ "$invocations" -ge 15 ] \
	|| fail "fake cppcheck ran only $invocations times; expected all five lane probes"
checks=$((checks + 3))

printf 'MISRA authored-output contract: %d checks, 0 failures\n' "$checks"
