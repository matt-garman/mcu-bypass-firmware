#!/usr/bin/env bash
set -euo pipefail

# The mutation-policy probe reads STRICT_TOOLS and MUTATION_ALLOW_SKIP from its
# environment (see test/mutation_policy.sh). This regression drives both knobs
# explicitly on each make command line, so strip any ambient values inherited
# from an interactive shell or an enclosing `make` invocation. Otherwise a
# leaked MUTATION_ALLOW_SKIP is honored ahead of STRICT_TOOLS and masks the
# defaulting that the final checks assert.
#
# A plain env-var unset is not enough: when this suite runs under an enclosing
# `make test-long ... MUTATION_ALLOW_SKIP=0` (as scripts/make-release.sh does),
# that command-line override is re-applied to every child `make` through
# MAKEFLAGS/MAKEOVERRIDES, so the default-behavior probes below would inherit
# MUTATION_ALLOW_SKIP=0 and report 0 where they must observe the unset default.
# Clear the make override channels too; the probes always pass the variables
# they care about explicitly.
unset MUTATION_ALLOW_SKIP STRICT_TOOLS MAKEFLAGS MAKEOVERRIDES MFLAGS GNUMAKEFLAGS

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CI_LOCAL="$ROOT/scripts/ci-local.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/test-ci-local-routing.XXXXXX")
trap 'rm -rf "$work"' EXIT
fakebin="$work/bin"
log="$work/make.log"
checks=0
REAL_MAKE=$(command -v make)

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

mkdir -p "$fakebin" "$work/dfp/pic/include/proc" "$work/gpsim-inc"
: > "$work/dfp/pic/include/proc/pic10f322.h"
: > "$work/gpsim-inc/sim_context.h"

cat > "$fakebin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -eq 2 ] && [ "$1" = rev-parse ] && [ "$2" = --show-toplevel ]; then
	printf '%s\n' "${FAKE_REPO_ROOT:?}"
	exit 0
fi
printf 'unexpected fake git invocation: %s\n' "$*" >&2
exit 64
EOF

cat > "$fakebin/make" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'STRICT_TOOLS=%s' "${STRICT_TOOLS-}" >> "${FAKE_MAKE_LOG:?}"
for arg in "$@"; do printf '\t%s' "$arg" >> "$FAKE_MAKE_LOG"; done
printf '\n' >> "$FAKE_MAKE_LOG"

if [ "${1:-}" = test-long ]; then
	requested=
	for arg in "$@"; do
		case "$arg" in MUTATION_ALLOW_SKIP=*) requested=${arg#*=} ;; esac
	done
	[ -n "$requested" ] \
		|| { printf 'test-long omitted MUTATION_ALLOW_SKIP\n' >&2; exit 65; }
	resolved=$("${REAL_MAKE:?}" -s --no-print-directory -C "${FAKE_REPO_ROOT:?}" \
		_test-mutation-policy-probe STRICT_TOOLS="${STRICT_TOOLS-}" \
		MUTATION_ALLOW_SKIP="$requested" 2>/dev/null)
	[ "$resolved" = "$requested" ] \
		|| { printf 'mutation policy resolved incorrectly: %s\n' "$resolved" >&2; exit 66; }
fi
EOF

for tool in gpsim cppcheck pkg-config; do
	cat > "$fakebin/$tool" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
done
cat > "$work/xc8" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 750 "$fakebin/git" "$fakebin/make" "$fakebin/gpsim" \
	"$fakebin/cppcheck" "$fakebin/pkg-config" "$work/xc8"

run_ci() {
	: > "$log"
	env PATH="$fakebin:$PATH" FAKE_REPO_ROOT="$ROOT" FAKE_MAKE_LOG="$log" \
		REAL_MAKE="$REAL_MAKE" \
		PIC_CC="$work/xc8" PIC_DFP="$work/dfp" \
		PIC_SOAK_GPSIM_INC="$work/gpsim-inc" \
		"$CI_LOCAL" --no-clean --skip-attiny202 "$@" 2>&1
}

if ! output=$(run_ci --skip-pic); then
	fail "push --skip-pic failed: $output"
fi
mapfile -t lines <<<"$output"
mapfile -t calls < "$log"
[ "${#calls[@]}" -eq 2 ] \
	|| fail "push --skip-pic executed ${#calls[@]} Make commands, expected 2"
[ "${calls[0]}" = $'STRICT_TOOLS=1\tall13\tall85\tall45' ] \
	|| fail "push --skip-pic routed the build matrix incorrectly: ${calls[0]}"
[ "${calls[1]}" = $'STRICT_TOOLS=1\ttest-long\tMUTATION_ALLOW_SKIP=1' ] \
	|| fail "push --skip-pic did not allow only the partial mutation run: ${calls[1]}"
[[ "${lines[*]}" == *"PIC job was skipped"* ]] \
	|| fail "push --skip-pic omitted its non-CI warning"
checks=$((checks + 1))

if ! output=$(run_ci); then
	fail "full push routing failed: $output"
fi
mapfile -t lines <<<"$output"
mapfile -t calls < "$log"
[ "${#calls[@]}" -eq 4 ] \
	|| fail "full push executed ${#calls[@]} Make commands, expected 4"
[ "${calls[0]}" = $'STRICT_TOOLS=1\tpic-test' ] \
	&& [ "${calls[1]}" = $'STRICT_TOOLS=1\tpic-test-target-variants' ] \
	|| fail "full push omitted or reordered the PIC gates"
[ "${calls[2]}" = $'STRICT_TOOLS=1\tall13\tall85\tall45' ] \
	|| fail "full push routed the build matrix incorrectly: ${calls[2]}"
[ "${calls[3]}" = $'STRICT_TOOLS=1\ttest-long\tMUTATION_ALLOW_SKIP=0' ] \
	|| fail "full push did not keep mutation fail-closed: ${calls[3]}"
checks=$((checks + 1))

if ! output=$(run_ci --pr --skip-pic); then
	fail "PR --skip-pic routing failed: $output"
fi
mapfile -t lines <<<"$output"
mapfile -t calls < "$log"
[ "${#calls[@]}" -eq 2 ] \
	|| fail "PR --skip-pic executed ${#calls[@]} Make commands, expected 2"
[ "${calls[0]}" = $'STRICT_TOOLS=1\tall13\tall85\tall45' ] \
	&& [ "${calls[1]}" = $'STRICT_TOOLS=1\ttest' ] \
	|| fail "PR --skip-pic did not route the strict non-mutation suite"
[[ "${calls[1]}" != *"MUTATION_ALLOW_SKIP"* ]] \
	|| fail "PR mode unexpectedly configured mutation testing"
checks=$((checks + 1))

resolved=$("$REAL_MAKE" -s --no-print-directory -C "$ROOT" \
	_test-mutation-policy-probe STRICT_TOOLS= 2>/dev/null)
[ "$resolved" = 1 ] \
	|| fail "non-strict mutation policy did not default to partial: $resolved"
resolved=$("$REAL_MAKE" -s --no-print-directory -C "$ROOT" \
	_test-mutation-policy-probe STRICT_TOOLS=1 2>/dev/null)
[ "$resolved" = 0 ] \
	|| fail "strict mutation policy did not default to fail-closed: $resolved"
if output=$("$REAL_MAKE" -s --no-print-directory -C "$ROOT" \
		_test-mutation-policy-probe MUTATION_ALLOW_SKIP=invalid 2>&1); then
	fail "mutation policy accepted an invalid explicit value"
fi
[[ "$output" == *"MUTATION_ALLOW_SKIP must be 0 or 1"* ]] \
	|| fail "mutation policy produced the wrong invalid-value diagnostic: $output"
checks=$((checks + 1))

printf 'ci-local routing validation: %d checks, 0 failures\n' "$checks"
