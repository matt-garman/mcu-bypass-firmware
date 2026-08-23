#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/test-pic10f320-coverage-archive.XXXXXX")
archive="$work/archive"
tools="$work/tools"
cc_log="$work/cc.log"
checks=0
read -r -a MAKE_CMD <<<"${PROJECT_MAKE:-make}"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

cleanup() { rm -rf "$work"; }
trap cleanup EXIT HUP INT TERM

[ "${#MAKE_CMD[@]}" -gt 0 ] || fail "PROJECT_MAKE must name a Make command"
command -v "${MAKE_CMD[0]}" >/dev/null 2>&1 \
	|| fail "Make command not found: ${MAKE_CMD[0]}"
command -v tar >/dev/null 2>&1 || fail "tar is required"
mkdir -p "$archive" "$tools"

# Use the same byte/mode transport as a published source archive. Overlay the
# working Makefile so this regression can validate an uncommitted fix; after the
# fix is committed, the bytes are identical to the archived copy.
#
# host_compiler_version.sh rides along for the same reason and must: it backs
# the host-compiler-valid prerequisite the overlaid Makefile gives every
# *-coverage-check-fw target, so an uncommitted change to that pair would
# otherwise fail here as a missing interpreter rather than as itself. -p keeps
# the executable mode `git archive` would have carried.
if command -v git >/dev/null 2>&1 \
		&& git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	git -C "$ROOT" archive --format=tar HEAD | tar -xf - -C "$archive"
	cp "$ROOT/Makefile" "$archive/Makefile"
	cp -p "$ROOT/test/host_compiler_version.sh" \
		"$archive/test/host_compiler_version.sh"
else
	# Running `make test` from an extracted archive must remain possible too.
	mkdir -p "$archive/test/pic10f320/fault"
	cp -p "$ROOT/Makefile" "$archive/Makefile"
	cp -p "$ROOT/test/host_compiler_version.sh" \
		"$archive/test/host_compiler_version.sh"
	cp -p "$ROOT/test/pic10f320/fault/check_fw_coverage.sh" \
		"$archive/test/pic10f320/fault/check_fw_coverage.sh"
fi
[ ! -e "$archive/.git" ] || fail "archive fixture unexpectedly contains Git metadata"
gate="$archive/test/pic10f320/fault/check_fw_coverage.sh"
[ -x "$gate" ] || fail "git archive did not preserve the coverage gate's executable mode"
checks=$((checks + 1))

cat > "$tools/fake-cc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'CALL' >> "${FAKE_CC_LOG:?}"
printf ' <%s>' "$@" >> "$FAKE_CC_LOG"
printf '\n' >> "$FAKE_CC_LOG"
out=
while [ "$#" -gt 0 ]; do
	if [ "$1" = -o ]; then
		shift
		out=${1:?missing output after -o}
	fi
	shift
done
[ -n "$out" ] || { printf 'fake compiler received no -o\n' >&2; exit 64; }
mkdir -p "$(dirname "$out")"
case "$out" in
	*.o) : > "$out" ;;
	*)
		printf 'profile\n' > "$(dirname "$out")/fw_fault_cov.gcda"
		cat > "$out" <<'SCRIPT'
#!/bin/sh
exit 0
SCRIPT
		chmod 750 "$out"
		;;
esac
EOF

cat > "$tools/fake-gcov" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat > bypass_mcu_pic10f320.c.gcov <<'GCOV'
        -:    0:Source:src/bypass_mcu_pic10f320.c
        1:    1:int main(void) { return 0; }
GCOV
printf 'File generated\n'
EOF
chmod 750 "$tools/fake-cc" "$tools/fake-gcov"

run_gate() {
	env PATH="$tools:$PATH" FAKE_CC_LOG="$cc_log" \
		"${MAKE_CMD[@]}" --no-print-directory -C "$archive" \
			PIC10F320_HOST_CC="$tools/fake-cc" GCOV="$tools/fake-gcov" \
			pic10f320-coverage-check-fw
}

: > "$cc_log"
if ! output=$(run_gate 2>&1); then
	fail "executable archive gate was rejected: $output; compiler calls: $(<"$cc_log")"
fi
[[ "$output" == *"OK: every firmware line is covered"* ]] \
	|| fail "archive coverage target did not reach its real gate: $output"
[ -s "$cc_log" ] || fail "archive coverage target never invoked its compiler"
checks=$((checks + 1))

chmod -x "$gate"
: > "$cc_log"
if output=$(run_gate 2>&1); then
	fail "archive coverage target accepted a non-executable local gate"
fi
[[ "$output" == *"lacks its local exec bit"* ]] \
	|| fail "non-executable archive gate failed for the wrong reason: $output"
[ ! -s "$cc_log" ] || fail "non-executable archive gate reached compilation"
chmod +x "$gate"
checks=$((checks + 1))

cat > "$tools/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1-} ${2-}" in
	"rev-parse --is-inside-work-tree") printf 'true\n' ;;
	"ls-files --stage") printf '100644 0000000000000000000000000000000000000000 0\t%s\n' "${@: -1}" ;;
	*) printf 'unexpected fake git invocation: %s\n' "$*" >&2; exit 65 ;;
esac
EOF
chmod 750 "$tools/git"
: > "$cc_log"
if output=$(run_gate 2>&1); then
	fail "worktree coverage target accepted non-executable index mode"
fi
[[ "$output" == *"is not mode 100755 in git"* ]] \
	|| fail "bad index mode failed for the wrong reason: $output"
[ ! -s "$cc_log" ] || fail "bad index mode reached compilation"
checks=$((checks + 1))

printf 'PIC10F320 source-archive coverage validation: %d checks, 0 failures\n' "$checks"
