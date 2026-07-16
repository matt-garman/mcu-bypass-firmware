#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/test-klee-build.XXXXXX")
trap 'rm -rf "$work"' EXIT
repo="$work/repo"
tools="$work/tools"
log="$work/tools.log"
klee_marker="$work/klee-ran"
checks=0

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

read -r -a MAKE_CMD <<<"${PROJECT_MAKE:-make}"
[ "${#MAKE_CMD[@]}" -gt 0 ] || fail "PROJECT_MAKE must name a Make command"
command -v "${MAKE_CMD[0]}" >/dev/null 2>&1 \
	|| fail "Make command not found: ${MAKE_CMD[0]}"

mkdir -p "$repo/src" "$repo/test/formal" "$repo/test/klee" "$repo/tools" \
	"$repo/test/simavr" "$tools"
cp "$ROOT/Makefile" "$repo/Makefile"
cp "$ROOT/src/bypass_pure.c" "$repo/src/bypass_pure.c"
cp "$ROOT/test/formal/test_symbolic.c" "$repo/test/formal/test_symbolic.c"

cat > "$tools/clang" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source_file=
output=
emit=0
compile=0
debug=0
opt=0
force_include=0
use_klee=0
klee_inc=0
simavr_inc=0
test_inc=0
while [ "$#" -gt 0 ]; do
	case "$1" in
		*.c) source_file=$1; shift ;;
		-o) output=$2; shift 2 ;;
		-emit-llvm) emit=1; shift ;;
		-c) compile=1; shift ;;
		-g) debug=1; shift ;;
		-O0) opt=1; shift ;;
		-DUSE_KLEE) use_klee=1; shift ;;
		-Itest/klee) klee_inc=1; shift ;;
		-Itest/simavr) simavr_inc=1; shift ;;
		-Itest) test_inc=1; shift ;;
		-include)
			[ "$2" = test/bypass_config_host.h ] || exit 71
			force_include=1; shift 2
			;;
		*) shift ;;
	esac
done
[ -n "$source_file" ] && [ -n "$output" ] \
	&& [ "$emit" -eq 1 ] && [ "$compile" -eq 1 ] \
	&& [ "$debug" -eq 1 ] && [ "$opt" -eq 1 ] && [ "$force_include" -eq 1 ] \
	&& [ "$use_klee" -eq 1 ] && [ "$klee_inc" -eq 1 ] \
	&& [ "$simavr_inc" -eq 1 ] && [ "$test_inc" -eq 1 ] \
	|| exit 72
printf 'clang %s -> %s\n' "$source_file" "$output" >> "${FAKE_TOOL_LOG:?}"
if [ "$source_file" = "${FAKE_CLANG_FAIL_SOURCE:-}" ]; then exit 73; fi
mkdir -p "$(dirname "$output")"
case "$source_file" in
	test/formal/test_symbolic.c)
		printf '%s\n' 'module:harness' 'requires:debounce_integrate,debounce_step' > "$output"
		;;
	src/bypass_pure.c)
		printf '%s\n' 'module:pure-core' 'defines:debounce_integrate,debounce_step' > "$output"
		;;
	*) exit 74 ;;
esac
EOF

cat > "$tools/llvm-link" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
inputs=()
output=
while [ "$#" -gt 0 ]; do
	case "$1" in
		-o) output=$2; shift 2 ;;
		*) inputs+=("$1"); shift ;;
	esac
done
[ "${#inputs[@]}" -eq 2 ] && [ -n "$output" ] || exit 75
[ "${inputs[0]}" = test/formal/test_symbolic.bc ] \
	&& [ "${inputs[1]}" = test/formal/bypass_pure_klee.bc ] || exit 76
printf 'llvm-link %s %s -> %s\n' "${inputs[0]}" "${inputs[1]}" "$output" \
	>> "${FAKE_TOOL_LOG:?}"
[ "${FAKE_LINK_FAIL:-0}" -eq 0 ] || exit 77
grep -q '^module:harness$' "${inputs[0]}" || exit 78
grep -q '^module:pure-core$' "${inputs[1]}" || exit 79
cat "${inputs[@]}" > "$output"
EOF

cat > "$tools/klee" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 2 ] && [ "$1" = --exit-on-error ] \
	&& [ "$2" = formal/test_symbolic_klee.bc ] || exit 80
printf 'klee %s\n' "$2" >> "${FAKE_TOOL_LOG:?}"
[ "${FAKE_KLEE_FAIL:-0}" -eq 0 ] || exit 81
grep -q '^module:harness$' "$2" || exit 82
grep -q '^module:pure-core$' "$2" || exit 83
grep -q '^defines:debounce_integrate,debounce_step$' "$2" || exit 84
mkdir klee-out-0
ln -s klee-out-0 klee-last
: > "${FAKE_KLEE_MARKER:?}"
EOF
chmod 750 "$tools/clang" "$tools/llvm-link" "$tools/klee"
ln -s "$tools/klee" "$repo/tools/klee"

run_make() {
	(
		unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL MAKE
		export FAKE_TOOL_LOG="$log" FAKE_KLEE_MARKER="$klee_marker"
		export FAKE_CLANG_FAIL_SOURCE="${FAKE_CLANG_FAIL_SOURCE:-}"
		export FAKE_LINK_FAIL="${FAKE_LINK_FAIL:-0}"
		export FAKE_KLEE_FAIL="${FAKE_KLEE_FAIL:-0}"
		"${MAKE_CMD[@]}" --no-print-directory -C "$repo" test-symbolic-klee \
			KLEE=tools/klee KLEE_CLANG="$tools/clang" \
			KLEE_LLVMLINK="$tools/llvm-link" KLEE_INC=test/klee \
			SIMAVR_INC=test/simavr "$@"
	)
}

: > "$log"
printf 'stale\n' > "$repo/test/formal/test_symbolic_klee.bc"
run_make >/dev/null || fail "linked KLEE build rejected valid fake tools"
mapfile -t events < "$log"
[ "${#events[@]}" -eq 4 ] \
	&& [ "${events[0]}" = 'clang test/formal/test_symbolic.c -> test/formal/test_symbolic.bc' ] \
	&& [ "${events[1]}" = 'clang src/bypass_pure.c -> test/formal/bypass_pure_klee.bc' ] \
	&& [ "${events[2]}" = 'llvm-link test/formal/test_symbolic.bc test/formal/bypass_pure_klee.bc -> test/formal/test_symbolic_klee.bc' ] \
	&& [ "${events[3]}" = 'klee formal/test_symbolic_klee.bc' ] \
	|| fail "KLEE tools ran in the wrong order: ${events[*]}"
[ -f "$klee_marker" ] || fail "KLEE did not execute the linked module"
[ -d "$repo/test/klee-out-0" ] && [ -L "$repo/test/klee-last" ] \
	&& [ ! -e "$repo/klee-out-0" ] && [ ! -e "$repo/klee-last" ] \
	|| fail "KLEE runtime output was not isolated under test/"
checks=$((checks + 1))

: > "$log"
rm -f "$klee_marker"
output=$(run_make KLEE_LLVMLINK="$tools/missing-llvm-link" 2>&1) \
	|| fail "missing llvm-link did not skip cleanly: $output"
[[ "$output" == *"matching clang/llvm-link"* ]] \
	|| fail "missing llvm-link produced the wrong diagnostic: $output"
[ ! -s "$log" ] && [ ! -e "$klee_marker" ] \
	|| fail "missing llvm-link still invoked the KLEE toolchain"
for artifact in test/formal/test_symbolic.bc test/formal/bypass_pure_klee.bc \
		test/formal/test_symbolic_klee.bc test/klee-out-0 test/klee-last; do
	[ ! -e "$repo/$artifact" ] && [ ! -L "$repo/$artifact" ] \
		|| fail "missing-tool skip retained stale KLEE artifact: $artifact"
done
checks=$((checks + 1))

: > "$log"
rm -f "$klee_marker"
if output=$(FAKE_CLANG_FAIL_SOURCE=src/bypass_pure.c run_make 2>&1); then
	fail "pure-core bitcode compilation failure was accepted"
fi
[ ! -e "$klee_marker" ] && [ ! -e "$repo/test/formal/test_symbolic_klee.bc" ] \
	|| fail "pure-core compile failure reached KLEE or retained stale linked bitcode"
[ "$(wc -l < "$log")" -eq 2 ] \
	|| fail "pure-core compile failure did not stop before llvm-link"
checks=$((checks + 1))

: > "$log"
rm -f "$klee_marker"
if output=$(FAKE_LINK_FAIL=1 run_make 2>&1); then
	fail "bitcode link failure was accepted"
fi
[ ! -e "$klee_marker" ] && [ ! -e "$repo/test/formal/test_symbolic_klee.bc" ] \
	|| fail "link failure reached KLEE or retained stale linked bitcode"
[ "$(wc -l < "$log")" -eq 3 ] \
	|| fail "link failure did not stop before KLEE"
checks=$((checks + 1))

: > "$log"
rm -f "$klee_marker"
if output=$(FAKE_KLEE_FAIL=1 run_make 2>&1); then
	fail "KLEE process failure was accepted"
fi
[ ! -e "$klee_marker" ] && [ "$(wc -l < "$log")" -eq 4 ] \
	|| fail "KLEE failure was not propagated after the linked build"
checks=$((checks + 1))

: > "$log"
rm -f "$repo/test/formal/test_symbolic.bc" \
	"$repo/test/formal/bypass_pure_klee.bc" \
	"$repo/test/formal/test_symbolic_klee.bc"
mkdir "$repo/test/formal/test_symbolic.bc"
if output=$(run_make 2>&1); then
	fail "unremovable stale bitcode was accepted"
fi
[ ! -s "$log" ] && [ ! -e "$klee_marker" ] \
	|| fail "cleanup failure still invoked the KLEE toolchain"
checks=$((checks + 1))

printf 'KLEE bitcode build validation: %d checks, 0 failures\n' "$checks"
