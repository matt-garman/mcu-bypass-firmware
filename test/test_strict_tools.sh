#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/test-strict-tools.XXXXXX")
trap 'rm -rf "$work"' EXIT
checks=0

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

read -r -a MAKE_CMD <<<"${PROJECT_MAKE:-make}"
[ "${#MAKE_CMD[@]}" -gt 0 ] || fail "PROJECT_MAKE must name a Make command"
command -v "${MAKE_CMD[0]}" >/dev/null 2>&1 \
	|| fail "Make command not found: ${MAKE_CMD[0]}"

run_make() {
	(
		unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL MAKE STRICT_TOOLS CBMC CPPCHECK
		[ -z "${FAKE_TOOL_LOG:-}" ] || export FAKE_TOOL_LOG
		"${MAKE_CMD[@]}" --no-print-directory -C "$ROOT" "$@"
	)
}

expect_missing_skip() {
	local target=$1 assignment=$2 reason=$3 output
	output=$(run_make "$target" STRICT_TOOLS= "$assignment" 2>&1) \
		|| fail "$target did not skip a missing tool by default: $output"
	[[ "$output" == *"$reason"* && "$output" != *"STRICT_TOOLS=1:"* ]] \
		|| fail "$target produced the wrong default-skip diagnostic: $output"
	checks=$((checks + 1))
}

expect_missing_strict_failure() {
	local target=$1 assignment=$2 reason=$3 output
	if output=$(run_make "$target" STRICT_TOOLS=1 "$assignment" 2>&1); then
		fail "$target accepted a missing tool under STRICT_TOOLS=1"
	fi
	[[ "$output" == *"$reason"* && "$output" == *"STRICT_TOOLS=1:"* ]] \
		|| fail "$target produced the wrong strict failure: $output"
	checks=$((checks + 1))
}

missing_cbmc="$work/missing-cbmc"
missing_cppcheck="$work/missing-cppcheck"
expect_missing_skip test-cbmc "CBMC=$missing_cbmc" "cbmc not installed"
expect_missing_strict_failure test-cbmc "CBMC=$missing_cbmc" "cbmc not installed"
expect_missing_skip analyze-cppcheck "CPPCHECK=$missing_cppcheck" "cppcheck not installed"
expect_missing_strict_failure analyze-cppcheck "CPPCHECK=$missing_cppcheck" "cppcheck not installed"

fake_cbmc="$work/fake-cbmc"
fake_cppcheck="$work/fake-cppcheck"
cbmc_log="$work/cbmc.log"
cppcheck_log="$work/cppcheck.log"
cat > "$fake_cbmc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_TOOL_LOG:?}"
EOF
cat > "$fake_cppcheck" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_TOOL_LOG:?}"
EOF
chmod 750 "$fake_cbmc" "$fake_cppcheck"

: > "$cbmc_log"
if ! output=$(FAKE_TOOL_LOG="$cbmc_log" run_make test-cbmc STRICT_TOOLS=1 \
		"CBMC=$fake_cbmc" 2>&1); then
	fail "test-cbmc rejected an available tool under STRICT_TOOLS=1: $output"
fi
[ "$(wc -l < "$cbmc_log")" -eq 9 ] \
	|| fail "test-cbmc did not execute all 9 proof commands"
[[ "$output" == *"all debounce-core proofs SUCCESSFUL"* ]] \
	|| fail "test-cbmc omitted its completion sentinel"
checks=$((checks + 1))

: > "$cppcheck_log"
if ! output=$(FAKE_TOOL_LOG="$cppcheck_log" run_make analyze-cppcheck \
		STRICT_TOOLS=1 "CPPCHECK=$fake_cppcheck" 2>&1); then
	fail "analyze-cppcheck rejected an available tool under STRICT_TOOLS=1: $output"
fi
[ "$(wc -l < "$cppcheck_log")" -eq 1 ] \
	|| fail "analyze-cppcheck did not execute exactly one analyzer command"
[[ "$output" == *"cppcheck: $fake_cppcheck"* ]] \
	|| fail "analyze-cppcheck omitted its execution diagnostic"
checks=$((checks + 1))

printf 'strict host-analysis tool validation: %d checks, 0 failures\n' "$checks"
