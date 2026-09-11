#!/usr/bin/env bash
# Exercise the real release step 0 without starting a release, plus the
# source-loaded helper that binds final classic-AVR HEX bytes across staging.
# Every external selected release input is supplied by a throwaway fake
# toolchain; base host utilities and Make variable queries remain real. The
# preflight must reach the last version probe, execute no build goal, create no
# output directory, and leave tracked/nonignored worktree content unchanged on
# every tested path.
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
RELEASE="$ROOT/scripts/make-release.sh"
SOAK_LIB="$ROOT/scripts/release-soak.sh"
RENDER="$ROOT/scripts/release-documentation.sh"
MUTATION="$ROOT/test/run_mutation_tests.sh"
lock_id=$(stat -Lc '%d:%i' "$ROOT") || { printf 'FAIL: could not identify the worktree lock\n' >&2; exit 1; }
if [ "${_MAKE_SERIAL_LOCK_HELD:-}" != "$lock_id" ]; then
	exec flock --no-fork "$ROOT/.make.lock" env _MAKE_SERIAL_LOCK_HELD="$lock_id" "$0" "$@"
fi
REAL_MAKE=$(command -v make) || { printf 'FAIL: make is required\n' >&2; exit 1; }
REAL_PYTHON=$(command -v python3) || { printf 'FAIL: python3 is required\n' >&2; exit 1; }
REAL_GIT=$(command -v git) || { printf 'FAIL: git is required\n' >&2; exit 1; }
REAL_AWK=$(command -v awk) || { printf 'FAIL: awk is required\n' >&2; exit 1; }
REAL_BASH=$(command -v bash) || { printf 'FAIL: bash is required\n' >&2; exit 1; }
REAL_DIRNAME=$(command -v dirname) || { printf 'FAIL: dirname is required\n' >&2; exit 1; }
REAL_STAT=$(command -v stat) || { printf 'FAIL: stat is required\n' >&2; exit 1; }
REAL_CP=$(command -v cp) || { printf 'FAIL: cp is required\n' >&2; exit 1; }
REAL_MKTEMP=$(command -v mktemp) || { printf 'FAIL: mktemp is required\n' >&2; exit 1; }
REAL_CC=$(command -v "${HOSTCC:-cc}") || { printf 'FAIL: a host C compiler is required\n' >&2; exit 1; }

# This gate's positive control is "a clean release configuration passes", and
# that assertion means nothing in a dirty environment. The Makefile refuses a
# release goal under ANY environment-origin name in the project's build-input
# vocabulary that is not a supported release input -- and this script inherits
# whatever its caller exported. Two callers export such names as a matter of
# course: `make` puts every command-line variable in its recipes' environment
# (release CI runs `make test-long STRICT_TOOLS=1 ... PIC12F675_FLASH_IMAGES=build`),
# and a workflow-level `env:` reaches every step in the job.
#
# Clearing a hand-maintained list of those names drifted twice -- once when
# PIC12F675_FLASH_IMAGES was added to the release workflow, and again when an
# ATTINY_DFP_VER job env failed v0.9.10's release run on a name the Makefile
# never reads. So ask the Makefile for its own vocabulary and clear every match
# once, here, before any case runs. A case that deliberately inherits an
# override sets it at call time, after this, and is unaffected.
#
# --no-print-directory is required (a `w` inherited through MAKEFLAGS beats -s),
# and this runs before the scrub so _MAKE_SERIAL_LOCK_HELD is still exported --
# the serialization wrapper must see the lock this script already holds rather
# than block on it. CC=: keeps the parse-time compiler probes quiet where the
# cross toolchain is absent; the queried value does not depend on it.
release_input_patterns=$("$REAL_MAKE" -s --no-print-directory -C "$ROOT" CC=: \
	print-RELEASE_ENVIRONMENT_INPUT_PATTERNS) \
	|| { printf 'FAIL: could not read the release environment-input vocabulary\n' >&2; exit 1; }
[ -n "$release_input_patterns" ] \
	|| { printf 'FAIL: release environment-input vocabulary is empty\n' >&2; exit 1; }
while IFS= read -r inherited_name; do
	for input_pattern in $release_input_patterns; do
		# GNU Make's % stem is the shell's *; every pattern is one word.
		case "$inherited_name" in
			${input_pattern//%/\*}) unset "$inherited_name"; break ;;
		esac
	done
done < <(compgen -e || true)
unset inherited_name input_pattern
# shellcheck source=scripts/release-provenance.sh
source "$ROOT/scripts/release-provenance.sh"
# shellcheck source=scripts/release-soak.sh
source "$SOAK_LIB"
# shellcheck source=scripts/release-documentation.sh
source "$RENDER"
if ! declare -F release_hash_classic_avr_images >/dev/null \
		|| ! declare -F release_stage_classic_avr_images >/dev/null; then
	printf 'FAIL: classic-AVR release binding helpers are missing\n' >&2
	exit 1
fi
declare -F release_validate_current_documentation >/dev/null \
	|| { printf 'FAIL: release documentation validator is missing\n' >&2; exit 1; }
declare -F release_validate_staged_documentation >/dev/null \
	|| { printf 'FAIL: staged release documentation validator is missing\n' >&2; exit 1; }
declare -F release_validate_development_state >/dev/null \
	|| { printf 'FAIL: development-state documentation validator is missing\n' >&2; exit 1; }
declare -F release_validate_hardware_claims >/dev/null \
	|| { printf 'FAIL: hardware evidence classifier is missing\n' >&2; exit 1; }
declare -F release_validate_pic12f675_flashing_helper >/dev/null \
	|| { printf 'FAIL: PIC12F675 flashing-helper contract is missing\n' >&2; exit 1; }
declare -F release_current_contract_version >/dev/null \
	|| { printf 'FAIL: current-contract version reader is missing\n' >&2; exit 1; }
declare -F release_validate_current_fact_rules >/dev/null \
	|| { printf 'FAIL: current-fact rule scanner is missing\n' >&2; exit 1; }
declare -F release_validate_topology_ownership >/dev/null \
	|| { printf 'FAIL: release topology ownership scanner is missing\n' >&2; exit 1; }
declare -F release_topology_counts >/dev/null \
	|| { printf 'FAIL: release topology count derivation is missing\n' >&2; exit 1; }
declare -F release_require_main_branch >/dev/null \
	|| { printf 'FAIL: release main-branch validator is missing\n' >&2; exit 1; }
# Every live-tree assertion below is held to the version release/README.md
# declares, never to a version written here. A literal goes stale silently: the
# checked-in tree keeps passing a contract check aimed at a release two cuts
# ago, which is the same defect class as a fixture that hardcodes the newest
# published version and stops moving with it.
live_contract_version=$(release_current_contract_version "$ROOT") \
	|| { printf 'FAIL: could not read the declared current release contract version\n' >&2; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/test-release-preflight.XXXXXX")
fakebin="$work/bin"
bootstrap_bin="$work/bootstrap-bin"
toolchain="$work/toolchain"
make_log="$work/make.log"
tool_log="$work/tool.log"
output="$work/output.log"
preflight_output="$ROOT/release/v0.0.0-preflight"
OUTPUT_PATH_OWNED=0
checks=0

# Diagnostics go to the shell's ORIGINAL stderr, not to whatever stderr is in
# force where fail() is called. Most cases invoke the release through
# `run_preflight >"$output" 2>&1`, so a fail() raised INSIDE run_preflight --
# the worktree-mutation and forbidden-invocation guards -- would otherwise be
# written into a scratch log under $work that cleanup() then deletes, and the
# gate would exit 1 with no output at all. That is exactly what a concurrent
# edit to a tracked file looks like while this suite runs.
exec {REAL_STDERR}>&2
fail() {
	printf 'FAIL: %s\n' "$*" >&"$REAL_STDERR"
	exit 1
}

cleanup() {
	rm -rf "$work"
	if [ "${OUTPUT_PATH_OWNED:-0}" -eq 1 ]; then
		rm -rf -- "$preflight_output"
	fi
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$fakebin" "$bootstrap_bin" \
	"$toolchain/simavr" \
	"$toolchain/pic10f322/pic/include/proc" \
	"$toolchain/pic10f320/pic/include/proc" \
	"$toolchain/xc8-322-include" \
	"$toolchain/xc8-320-include" \
	"$toolchain/pic10f322-gpsim" \
	"$toolchain/pic10f320-gpsim" \
	"$toolchain/attiny-dfp/gcc/dev/attiny202/device-specs" \
	"$toolchain/attiny-dfp/gcc/dev/attiny202/avrxmega3/short-calls" \
	"$toolchain/attiny-dfp/include/avr" \
	"$toolchain/yasimavr/bin"
for fixture in \
	"$toolchain/simavr/sim_avr.h" \
	"$toolchain/simavr/sim_elf.h" \
	"$toolchain/simavr/sim_irq.h" \
	"$toolchain/simavr/sim_vcd_file.h" \
	"$toolchain/simavr/avr_ioport.h" \
	"$toolchain/pic10f322/pic/include/proc/pic10f322.h" \
	"$toolchain/pic10f320/pic/include/proc/pic10f320.h" \
	"$toolchain/pic10f322/pic/include/proc/pic12f675.h" \
	"$toolchain/xc8-322-include/xc.h" \
	"$toolchain/xc8-320-include/xc.h" \
	"$toolchain/pic10f322.ini" \
	"$toolchain/pic10f320.ini" \
	"$toolchain/pic12f675.ini" \
	"$toolchain/attiny-dfp/gcc/dev/attiny202/device-specs/specs-attiny202" \
	"$toolchain/attiny-dfp/gcc/dev/attiny202/avrxmega3/short-calls/crtattiny202.o" \
	"$toolchain/attiny-dfp/gcc/dev/attiny202/avrxmega3/short-calls/libattiny202.a" \
	"$toolchain/attiny-dfp/include/avr/iotn202.h"; do
	printf 'synthetic preflight fixture\n' > "$fixture"
done
for gpsim_inc in "$toolchain/pic10f322-gpsim" "$toolchain/pic10f320-gpsim"; do
	for gpsim_header in interface.h sim_context.h processor.h pic-processor.h modules.h ioports.h stimuli.h \
			gpsim_time.h breakpoints.h trigger.h registers.h; do
		printf 'synthetic preflight fixture\n' > "$gpsim_inc/$gpsim_header"
	done
done
: > "$make_log"
: > "$tool_log"

cat > "$fakebin/fake-tool" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
	printf 'fake release tool 1.0\n'
fi
if [[ " $* " == *" -mmcu=attiny13a "* ]] && [[ " $* " == *" -E "* ]]; then
	[ "${TEST_AVR_LIBC_FAIL:-0}" -eq 0 ] || exit 81
fi
if [[ " $* " == *" -lsimavr "* ]]; then
	[ "${TEST_SIMAVR_LINK_FAIL:-0}" -eq 0 ] || exit 82
fi
if [[ " $* " == *" -lgpsim "* ]]; then
	[ "${TEST_GPSIM_LINK_FAIL:-0}" -eq 0 ] || exit 83
fi
exit 0
EOF

# Dedicated fake avr-gcc that reports the pinned 7.3.0 version. make-release.sh
# HARD FAILS at preflight on avr-gcc drift (the image-defining compiler), so the
# happy path needs a compliant version banner -- mirroring the xc8-322/320 fakes
# that report V3.10. It still carries fake-tool's avr-libc preprocess probe
# (-mmcu=attiny13a -E) so header-missing injection still works.
#
# Written by a generator because the version pin needs SEVERAL of these: one
# compliant, and one per drifted banner form. Forking the body per banner would
# let a drifted copy fall out of step with the capability probes above and fail
# a pin test for the wrong reason -- these must reach the pin and fail only
# there. The banner argument is the whole first line, or empty for a compiler
# that prints no version at all.
write_avr_gcc_fake() {
	local path=$1 banner=$2
	{
		printf '%s\n' '#!/usr/bin/env bash'
		printf '%s\n' 'if [ "${1:-}" = --version ]; then'
		if [ -n "$banner" ]; then
			printf '\tprintf %s\n' "'${banner}\\n'"
			printf '\tprintf %s\n' "'Copyright (C) 2017 Free Software Foundation, Inc.\\n'"
		else
			printf '\t%s\n' ':'   # a compiler that answers --version with nothing
		fi
		printf '%s\n' 'fi'
		printf '%s\n' 'if [[ " $* " == *" -mmcu=attiny13a "* ]] && [[ " $* " == *" -E "* ]]; then'
		printf '\t%s\n' '[ "${TEST_AVR_LIBC_FAIL:-0}" -eq 0 ] || exit 81'
		printf '%s\n' 'fi'
		printf '%s\n' 'exit 0'
	} > "$path"
	chmod 750 "$path"
}
write_avr_gcc_fake "$fakebin/fake-avr-gcc" 'avr-gcc (GCC) 7.3.0'

cat > "$fakebin/fake-awk" <<'EOF'
#!/usr/bin/env bash
[ "${TEST_AWK_FAIL:-0}" -eq 0 ] || exit 84
exec "${REAL_AWK:?}" "$@"
EOF

cat > "$fakebin/mktemp" <<'EOF'
#!/usr/bin/env bash
if [ -n "${TEST_MKTEMP_MARKER:-}" ]; then
	printf 'mktemp reached\n' > "$TEST_MKTEMP_MARKER"
fi
exec "${REAL_MKTEMP:?}" "$@"
EOF

# The test process owns the real worktree lock. Injection checks use this shim
# to exercise the outer serialization recipe and its recursive Make without
# deadlocking on that already-held lock.
cat > "$fakebin/flock" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -n ] && [ "$#" -eq 2 ]; then exit 0; fi
if [ "${1:-}" = --no-fork ]; then shift; fi
[ "$#" -ge 2 ] || exit 90
shift
exec "$@"
EOF

# Same reasoning as write_avr_gcc_fake: the XC8 pin needs one compliant banner
# and several drifted ones, and they must differ ONLY in that banner.
write_xc8_fake() {
	local path=$1 banner=$2
	{
		printf '%s\n' '#!/usr/bin/env bash'
		if [ -n "$banner" ]; then
			printf 'printf %s\n' "'${banner}\\n'"
		fi
		printf '%s\n' 'exit 0'
	} > "$path"
	chmod 750 "$path"
}
write_xc8_fake "$toolchain/xc8-322" 'Microchip MPLAB XC8 C Compiler V3.10'
write_xc8_fake "$toolchain/xc8-320" 'Microchip MPLAB XC8 C Compiler V3.10'

cat > "$toolchain/yasimavr/bin/python" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -c ] && [[ "${2:-}" == *'DeviceDescriptor'* ]] \
		&& [[ "${2:-}" == *'XT_DeviceBuilder'* ]] && [[ "${2:-}" == *'dev_tiny_0series'* ]] \
		&& [[ "${2:-}" == *'yasimavr.lib import core'* ]]; then
	[ "${TEST_YASIMAVR_IMPORT_FAIL:-0}" -eq 0 ] || exit 85
	printf 'yasimavr-import\n' >> "${TOOL_LOG:?}"
	exit 0
fi
printf 'unexpected yasimavr interpreter arguments: %s\n' "$*" >&2
exit 9
EOF

# The venv's build stamp, which is how the release identifies WHICH yasimavr it
# ran: a version string alone does not distinguish a patched build from an
# unpatched one, and the vendored patches are what the ATtiny202 soak depends
# on. scripts/fetch_yasimavr.sh writes this; the fake toolchain carries one so
# the provenance read has something to find.
printf '0.1.6 %s %s' \
	'1111111111111111111111111111111111111111111111111111111111111111' \
	'2222222222222222222222222222222222222222222222222222222222222222' \
	> "$toolchain/yasimavr/.yasimavr.stamp"

cat > "$fakebin/python3" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "${FAKE_REPO_ROOT:?}/test/python_version.py" ]; then
	printf 'python-minimum-check\n' >> "${TOOL_LOG:?}"
	if [ "${TEST_PYTHON_TOO_OLD:-0}" -eq 1 ]; then
		printf '%s\n' 'FAIL: Python 3.7 or newer is required by the repository host gates; found Python 3.6.8 at /fake/python3. Upgrade Python and ensure `python3` selects the newer interpreter.' >&2
		exit 1
	fi
	exit 0
fi
if [ "${1:-}" = -c ] && [ "${2:-}" = "import yaml" ]; then
	[ "${TEST_PYYAML_FAIL:-0}" -eq 0 ] || exit 1
	printf 'yaml-import\n' >> "${TOOL_LOG:?}"
	exit 0
fi
if [ "${1:-}" = --version ]; then
	printf 'python-version\n' >> "${TOOL_LOG:?}"
fi
exec "${REAL_PYTHON:?}" "$@"
EOF

cat > "$fakebin/gpg" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
	--list-secret-keys) exit 1 ;;
	--version) printf 'gpg fake 1.0\n'; exit 0 ;;
	*) exit 0 ;;
esac
EOF

cat > "$fakebin/git" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = rev-parse ] && [ "${2:-}" = --show-toplevel ] \
		&& [ -n "${TEST_RELEASE_REPO_ROOT:-}" ]; then
	printf '%s\n' "$TEST_RELEASE_REPO_ROOT"
	exit 0
fi
if [ "${TEST_GIT_STATUS_FAIL:-0}" -eq 1 ] && [ "${1:-}" = status ]; then
	exit 71
fi
if [ "${TEST_GIT_CLEAN:-0}" -eq 1 ] && [ "${1:-}" = status ]; then
	exit 0
fi
if [ "${1:-}" = rev-parse ] && [ "${2:-}" = -q ] \
		&& [ "${TEST_GIT_LOCAL_TAG_FAIL:-0}" -eq 1 ]; then
	exit 74
fi
if [ "${1:-}" = remote ] && [ "${2:-}" = get-url ] && [ "${3:-}" = origin ]; then
	[ "${TEST_GIT_REMOTE_CONFIG_FAIL:-0}" -eq 0 ] || exit 73
	[ "${TEST_GIT_NO_ORIGIN:-0}" -eq 0 ] || exit 2
	printf 'https://invalid.example/preflight.git\n'
	exit 0
fi
if [ "${1:-}" = ls-remote ]; then
	[ "${TEST_GIT_REMOTE_FAIL:-0}" -eq 0 ] || exit 72
	exit 2
fi
case "${1:-}" in
	check-ref-format|rev-parse|status) exec "${REAL_GIT:?}" "$@" ;;
	*) printf 'forbidden Git invocation: %s\n' "$*" >> "${TOOL_LOG:?}"; exit 96 ;;
esac
EOF

cat > "$fakebin/pkg-config" <<'EOF'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
	--exists:glib-2.0) exit 0 ;;
	--cflags:glib-2.0) printf '%s\n' '-I/fake/glib'; exit 0 ;;
	*) exit 1 ;;
esac
EOF

for tool in avr-nm avr-objdump pic-cxx-322 pic-cxx-320; do
	cp "$fakebin/fake-tool" "$fakebin/$tool"
done
cp "$toolchain/xc8-322" "$fakebin/xc8-322-path"
chmod 750 "$fakebin"/* "$toolchain/xc8-322" "$toolchain/xc8-320" \
	"$toolchain/yasimavr/bin/python"

# The release script asks Make only for print-<VAR> values before preflight exits.
# Delegate those reads to the real Makefile with a complete synthetic toolchain;
# reject any build/clean goal so a misplaced exit cannot score as a pass.
#
# --no-print-directory is part of the accepted QUERY SHAPE, not merely tolerated
# in it, and requiring it here is the point: -s alone loses to a -w inherited
# through MAKEFLAGS, so a release invoked one Make deep would read every value
# back wrapped in "Entering/Leaving directory" banners and stage them into the
# MANIFEST. Pinning the flag in the shape means dropping it fails this gate
# instead of corrupting a release.
cat > "$fakebin/make" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 3 ] && [ "$1" = -s ] && [ "$2" = --no-print-directory ] || {
	printf 'forbidden non-query Make invocation: %s\n' "$*" >> "${MAKE_LOG:?}"
	exit 97
}
case "$3" in
	# origin-<VAR> is the introspection companion of print-<VAR>, declared beside
	# it and equally read-only. The release identity guard resolves it -- and only
	# on the path where it is already refusing to start -- to say whether a moved
	# variable arrived on a command line or through an inherited export.
	print-*|origin-*) goal=$3 ;;
	*)
		printf 'forbidden non-query Make invocation: %s\n' "$*" >> "${MAKE_LOG:?}"
		exit 97
		;;
esac
printf '%s\n' "$goal" >> "${MAKE_LOG:?}"
make_output=$("${REAL_MAKE:?}" --no-print-directory -s -C "${FAKE_REPO_ROOT:?}" \
	CC="${TEST_CC:-fake-avr-gcc}" OBJCOPY=fake-tool SIZE=fake-tool HOSTCC=fake-tool \
	OBJDUMP="${TEST_OBJDUMP:-fake-tool}" READELF=fake-tool \
	IHEX_VALIDATOR="${TEST_IHEX_VALIDATOR:-${FAKE_BIN:?}/fake-tool}" AWK="${FAKE_BIN:?}/fake-awk" \
	CLANG=fake-tool CLANG_TIDY=fake-tool CPPCHECK=fake-tool CBMC=fake-tool \
	GCOV=fake-tool GPSIM=fake-tool \
	PIC_CC="${TEST_PIC_CC:-${FAKE_TOOLCHAIN:?}/xc8-322}" \
	PIC10F320_CC="${TEST_PIC10F320_CC:-${FAKE_TOOLCHAIN:?}/xc8-320}" \
	PIC_DFP="${FAKE_TOOLCHAIN:?}/pic10f322" \
	PIC10F320_DFP="${FAKE_TOOLCHAIN:?}/pic10f320" \
	PIC_XC8_INCLUDE="${FAKE_TOOLCHAIN:?}/xc8-322-include" \
	PIC10F320_XC8_INCLUDE="${FAKE_TOOLCHAIN:?}/xc8-320-include" \
	PIC10F322_DFP_INCLUDE="${TEST_PIC10F322_DFP_INCLUDE:-${FAKE_TOOLCHAIN:?}/pic10f322/pic/include}" \
	PIC10F320_DFP_INCLUDE="${TEST_PIC10F320_DFP_INCLUDE:-${FAKE_TOOLCHAIN:?}/pic10f320/pic/include}" \
	PIC10F322_DEVICE_INI="${FAKE_TOOLCHAIN:?}/pic10f322.ini" \
	PIC10F320_DEVICE_INI="${FAKE_TOOLCHAIN:?}/pic10f320.ini" \
	PIC12F675_DFP_INCLUDE="${TEST_PIC12F675_DFP_INCLUDE:-${FAKE_TOOLCHAIN:?}/pic10f322/pic/include}" \
	PIC12F675_DEVICE_INI="${FAKE_TOOLCHAIN:?}/pic12f675.ini" \
	PIC10F320_HOST_CC=fake-tool \
	SIMAVR_INC="${FAKE_TOOLCHAIN:?}/simavr" \
	XT_DFP="${FAKE_TOOLCHAIN:?}/attiny-dfp" \
	YASIMAVR_VENV="${TEST_YASIMAVR_VENV:-${FAKE_TOOLCHAIN:?}/yasimavr}" \
	PIC_SOAK_CXX="${TEST_PIC_SOAK_CXX:-pic-cxx-322}" \
	PIC10F320_SOAK_CXX="${TEST_PIC10F320_SOAK_CXX:-pic-cxx-320}" \
	PIC_SOAK_GPSIM_INC="${FAKE_TOOLCHAIN:?}/pic10f322-gpsim" \
	PIC10F320_SOAK_GPSIM_INC="${FAKE_TOOLCHAIN:?}/pic10f320-gpsim" \
	ANALYZE_CMD="${TEST_ANALYZE_CMD:-fake-tool --checks=fake}" \
	${TEST_EXTRA_MAKE_VAR:+"$TEST_EXTRA_MAKE_VAR"} \
	"$goal")
case "$goal" in
	print-RELEASE_IMAGES)
		if [ "${TEST_DUPLICATE_RELEASE_IMAGES:-0}" -eq 1 ]; then
			printf '%s %s\n' "$make_output" "${make_output%% *}"
		else
			printf '%s\n' "$make_output"
		fi
		;;
	print-RELEASE_SOAK_NAMES)
		if [ "${TEST_DUPLICATE_RELEASE_SOAKS:-0}" -eq 1 ]; then
			printf '%s %s\n' "$make_output" "${make_output%% *}"
		else
			printf '%s\n' "$make_output"
		fi
		;;
	*) printf '%s\n' "$make_output" ;;
esac
EOF
chmod 750 "$fakebin/make"

[ ! -e "$preflight_output" ] \
	|| fail "reserved preflight output fixture already exists: $preflight_output"
OUTPUT_PATH_OWNED=1

run_preflight() {
	local status_before status_after output_existed_before output_existed_after rc
	local release_makeflags=${TEST_RELEASE_MAKEFLAGS-}
	local release_mflags=${TEST_RELEASE_MFLAGS-}
	local release_gnumakeflags=${TEST_RELEASE_GNUMAKEFLAGS-}
	status_before=$(tree_snapshot) || fail "could not snapshot the working tree"
	[ -e "$preflight_output" ] && output_existed_before=1 || output_existed_before=0
	if (
		# VERSION and RELEASE_ARGS are how the Makefile hands a release its
		# arguments (`export VERSION RELEASE_ARGS`), and make-release.sh reads
		# both from the environment when no positional version is given. That
		# export is global, so under `make release VERSION=vX.Y.Z` every recipe
		# -- including the one running this gate -- inherits it, and a
		# `run_preflight` with no version would silently exercise the
		# *versioned* path instead. Clearing the names here keeps each case
		# testing the argument vector it actually passes. None of these names
		# is in the project's build-input vocabulary, so the whole-environment
		# scrub above does not cover them and they are listed by hand; every
		# caller-exported build input the scrub DOES cover has been cleared
		# before the first case runs, which is why no such name appears here.
		unset VERSION RELEASE_ARGS MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKEOVERRIDES MAKELEVEL
		[ -z "$release_makeflags" ] || export MAKEFLAGS="$release_makeflags"
		[ -z "$release_mflags" ] || export MFLAGS="$release_mflags"
		[ -z "$release_gnumakeflags" ] || export GNUMAKEFLAGS="$release_gnumakeflags"
		export PATH="$fakebin:$PATH"
		export TMPDIR="$work"
		export REAL_MAKE REAL_PYTHON REAL_GIT REAL_AWK REAL_MKTEMP
		export FAKE_REPO_ROOT="$ROOT" FAKE_TOOLCHAIN="$toolchain"
		export FAKE_BIN="$fakebin"
		export MAKE_LOG="$make_log" TOOL_LOG="$tool_log"
		export _MAKE_SERIAL_LOCK_HELD="$lock_id"
		"$RELEASE" --preflight "$@"
	); then
		rc=0
	else
		rc=$?
	fi
	status_after=$(tree_snapshot) || fail "could not resnapshot the working tree"
	[ -e "$preflight_output" ] && output_existed_after=1 || output_existed_after=0
	[ "$status_after" = "$status_before" ] \
		|| fail "preflight changed tracked/nonignored worktree content"
	[ "$output_existed_after" -eq "$output_existed_before" ] \
		|| fail "preflight changed the prospective output path"
	if grep -Fq 'forbidden non-query Make invocation' "$make_log"; then
		fail "preflight reached a build or clean Make goal"
	fi
	if grep -Fq 'forbidden Git invocation' "$tool_log"; then
		fail "preflight attempted a non-read-only Git operation"
	fi
	return "$rc"
}

tree_snapshot() {
	local rel mode digest target
	while IFS= read -r -d '' rel; do
		# A tracked path is legitimately absent while its deletion is still
		# unstaged -- `git ls-files -c` lists what the index holds, not what
		# the disk does. Record the absence rather than failing the snapshot:
		# the entry still appears on both sides, so a file this preflight run
		# deletes is still caught by the comparison.
		if [ ! -e "$ROOT/$rel" ] && [ ! -L "$ROOT/$rel" ]; then
			printf 'X %q\n' "$rel"
			continue
		fi
		mode=$(stat -c '%a' "$ROOT/$rel") || return 1
		if [ -L "$ROOT/$rel" ]; then
			target=$(readlink "$ROOT/$rel") || return 1
			printf 'L %q %s %q\n' "$rel" "$mode" "$target"
		elif [ -f "$ROOT/$rel" ]; then
			digest=$(sha256sum "$ROOT/$rel") || return 1
			printf 'F %q %s %s\n' "$rel" "$mode" "${digest%% *}"
		fi
	done < <(git -C "$ROOT" ls-files -co --exclude-standard -z | sort -z)
}

assert_no_release_scratch() {
	local -a leftovers
	shopt -s nullglob
	leftovers=("$work"/mcu-release.*)
	shopt -u nullglob
	[ "${#leftovers[@]}" -eq 0 ] \
		|| fail "preflight leaked release scratch: ${leftovers[*]}"
}

# Git and Make are consumed before section 0 can aggregate the selected release
# toolchain. Run the real script under a minimal PATH so each absence is observed
# by its bootstrap check, not by a shell error or a later print-<VAR> query.
ln -s "$REAL_DIRNAME" "$bootstrap_bin/dirname"
ln -s "$REAL_STAT" "$bootstrap_bin/stat"
if (
	unset VERSION RELEASE_ARGS   # inherited release config; see run_preflight
	export PATH="$bootstrap_bin" _MAKE_SERIAL_LOCK_HELD="$lock_id"
	"$REAL_BASH" "$RELEASE" --preflight
) >"$output" 2>&1; then
	fail "release preflight accepted missing Git"
fi
grep -Fq 'Git is required to validate release tags and repository provenance' "$output" \
	|| fail "missing Git failed without its bootstrap prerequisite diagnostic"
[ ! -s "$make_log" ] \
	|| fail "missing-Git bootstrap path reached a Makefile query"
checks=$((checks + 1))

ln -s "$REAL_GIT" "$bootstrap_bin/git"
if (
	unset VERSION RELEASE_ARGS   # inherited release config; see run_preflight
	export PATH="$bootstrap_bin" _MAKE_SERIAL_LOCK_HELD="$lock_id"
	"$REAL_BASH" "$RELEASE" --preflight
) >"$output" 2>&1; then
	fail "release preflight accepted missing Make"
fi
grep -Fq 'GNU Make is required to read release configuration (print-<VAR>)' "$output" \
	|| fail "missing Make failed without its bootstrap prerequisite diagnostic"
[ ! -s "$make_log" ] \
	|| fail "missing-Make bootstrap path reached a Makefile query"
checks=$((checks + 1))

run_preflight >"$output" 2>&1 \
	|| fail "valid preflight failed: $(<"$output")"
grep -Fq 'preflight passed: this host can start a release.' "$output" \
	|| fail "preflight exited without its terminal success record"
grep -Fq 'no release version supplied; tag availability was not checked.' "$output" \
	|| fail "versionless preflight did not state its tag-check scope"
grep -Fxq 'python-version' "$tool_log" \
	|| fail "preflight exited before the final executable-version probe"
grep -Fxq 'python-minimum-check' "$tool_log" \
	|| fail "preflight did not enforce the host Python minimum"
grep -Fxq 'yasimavr-import' "$tool_log" \
	|| fail "preflight did not execute a live yasimavr import"
grep -Fxq 'yaml-import' "$tool_log" \
	|| fail "preflight did not execute a live PyYAML import"
[ ! -e "$preflight_output" ] \
	|| fail "preflight created its prospective release output directory"
query_count=$(wc -l < "$make_log")
[ "$query_count" -eq 98 ] \
	|| fail "preflight made $query_count Makefile queries, expected 98"
assert_no_release_scratch
checks=$((checks + 1))

# Versionless preflight remains a host-capability probe. Supplying a production
# version additionally exercises the actual checked-in documentation contract.
current_release_version=$(_release_current_block "$ROOT/release/README.md" \
	| awk '{ sub(/^>[[:space:]]*/, ""); print }' \
	| sed -n 's/^\*\*Current release contract:\*\* `\(v[0-9][^`]*\)`;.*/\1/p') \
	|| fail "could not read the current release version"
[[ "$current_release_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] \
	|| fail "current release declaration has no valid version"
run_preflight "$current_release_version" >"$output" 2>&1 \
	|| fail "valid versioned preflight failed: $(<"$output")"
assert_no_release_scratch
checks=$((checks + 1))

# --------------------------------------------------------------------------
# The production release identity is pinned, and a run that does not match it
# stops before it can consume anything.
#
# This is the SECOND enforcement point. The Makefile refuses a `make release`
# goal at parse time, but make-release.sh is also run directly -- CI and the
# documented recipe both do -- so it re-derives the comparison for its own
# account, from the pinned RELEASE_IDENTITY_PINNED table against the values it
# actually selected. Preflight is checked too: a capability probe answered for
# the wrong release answers the wrong question.
#
# The two channels differ, and both are exercised. A command line reaches the
# script's print-<VAR> queries through MAKEOVERRIDES; the environment cannot
# move a plain `=` assignment but wins every `?=`, which is how all four
# per-part MCU tags are declared. The second case is the one nobody types.
run_preflight >"$output" 2>&1 \
	|| fail "valid preflight failed before the identity check: $(<"$output")"
grep -Fq 'production release identity matches the pinned declaration:' "$output" \
	|| fail "preflight did not record the release identity it verified"
grep -Fq '21 images, 18 soak combinations' "$output" \
	|| fail "preflight recorded a release identity other than the reviewed 21/18 set"
assert_no_release_scratch
checks=$((checks + 1))

expect_identity_refusal() {   # usage: <label> <named variable> <origin phrase>
	local label=$1 named=$2 origin=$3
	grep -Fq 'refusing to run a release under an overridden production identity' "$output" \
		|| fail "$label was not refused by the release identity guard: $(<"$output")"
	grep -Fq "$named:" "$output" \
		|| fail "$label did not name $named in its diagnostic: $(<"$output")"
	grep -Fq "Make origin: $origin" "$output" \
		|| fail "$label did not report $named with Make origin '$origin': $(<"$output")"
	if grep -Fq 'production release identity matches the pinned declaration:' "$output"; then
		fail "$label recorded a matching identity as well as a refusal"
	fi
	if grep -Fq 'all required release tools' "$output"; then
		fail "$label reached the tool preconditions before failing"
	fi
	[ ! -e "$preflight_output" ] \
		|| fail "$label created the prospective release output directory"
	assert_no_release_scratch
	checks=$((checks + 1))
}

if TEST_EXTRA_MAKE_VAR=FW_BASE=hijacked run_preflight >"$output" 2>&1; then
	fail "preflight accepted a command-line FW_BASE override"
fi
expect_identity_refusal "a command-line FW_BASE override" FW_BASE 'command line'

if PIC12F675_TAG=pic12f629 run_preflight >"$output" 2>&1; then
	fail "preflight accepted an inherited PIC12F675_TAG override"
fi
expect_identity_refusal "an inherited PIC12F675_TAG override" PIC12F675_TAG environment

if TEST_EXTRA_MAKE_VAR=VARIANTS=cd4053_simple run_preflight >"$output" 2>&1; then
	fail "preflight accepted an abbreviated command-line VARIANTS override"
fi
# VARIANTS and PIC10F320_VARIANTS_ALL are re-declared by the Makefile with
# `override` after filtering the caller's request to supported names, so
# $(origin) reports the re-declaration rather than the channel. That is what the
# diagnostic's closing note is for; what matters here is that the abbreviated
# request is caught at all.
expect_identity_refusal "an abbreviated VARIANTS override" VARIANTS override

if TEST_EXTRA_MAKE_VAR=TINYX5=85 run_preflight >"$output" 2>&1; then
	fail "preflight accepted a reduced tinyx5 membership"
fi
expect_identity_refusal "a reduced tinyx5 membership" TINYX5 'command line'

# A die selector moves no image NAME at all: the release would stage twenty-one
# canonically named images, three of which were compiled for another chip.
if PIC10F322_CHIP=10F320 run_preflight >"$output" 2>&1; then
	fail "preflight accepted an inherited PIC10F322_CHIP override"
fi
expect_identity_refusal "an inherited PIC10F322_CHIP override" PIC10F322_CHIP environment

# R6: source/flag bundles are development inputs, never production release
# inputs. The first Make query rejects effective direct/inherited overrides and
# injected makefiles; duplicate inventories then fail in the script's pure-Bash
# configuration phase. Every case precedes selected-tool probes and scratch.
expect_configuration_refusal() { # usage: <label> <name> <diagnostic>
	local label=$1 name=$2 diagnostic=$3
	grep -Fq -- "$diagnostic" "$output" \
		|| fail "$label was refused for the wrong reason: $(<"$output")"
	grep -Fq -- "$name" "$output" \
		|| fail "$label did not name $name in its diagnostic: $(<"$output")"
	if grep -Fq 'all required release tools' "$output"; then
		fail "$label reached the tool preconditions before failing"
	fi
	[ ! -s "$tool_log" ] \
		|| fail "$label executed a selected release tool before failing: $(<"$tool_log")"
	[ ! -e "$preflight_output" ] \
		|| fail "$label created the prospective release output directory"
	assert_no_release_scratch
	checks=$((checks + 1))
}

: > "$tool_log"
if TEST_EXTRA_MAKE_VAR=CFLAGS=-DINJECTED_CLASSIC_FLAGS \
		run_preflight >"$output" 2>&1; then
	fail "preflight accepted a command-line CFLAGS override"
fi
expect_configuration_refusal "a command-line CFLAGS override" CFLAGS \
	'unsupported release overrides'

: > "$tool_log"
if TEST_EXTRA_MAKE_VAR=XT_CORE_SRC=/dev/null run_preflight >"$output" 2>&1; then
	fail "preflight accepted a command-line XT_CORE_SRC override"
fi
expect_configuration_refusal "a command-line XT_CORE_SRC override" XT_CORE_SRC \
	'unsupported release overrides'

: > "$tool_log"
if TEST_RELEASE_MAKEFLAGS=-e PIC10F322_CFLAGS=-DINHERITED_322_FLAGS \
		run_preflight >"$output" 2>&1; then
	fail "preflight accepted an inherited PIC10F322_CFLAGS override"
fi
expect_configuration_refusal "an inherited PIC10F322_CFLAGS override" \
	PIC10F322_CFLAGS 'unsupported release overrides'

: > "$tool_log"
if TEST_RELEASE_GNUMAKEFLAGS=PIC10F320_SRC=/dev/null run_preflight >"$output" 2>&1; then
	fail "preflight accepted a GNUMAKEFLAGS PIC10F320_SRC override"
fi
expect_configuration_refusal "a GNUMAKEFLAGS PIC10F320_SRC override" \
	PIC10F320_SRC 'unsupported release overrides'

: > "$tool_log"
if SANITIZE= run_preflight >"$output" 2>&1; then
	fail "preflight accepted an ordinary inherited SANITIZE override"
fi
expect_configuration_refusal "an ordinary inherited SANITIZE override" SANITIZE \
	'unsupported release overrides'

: > "$tool_log"
if TEST_RELEASE_MAKEFLAGS='--eval=override\ SANITIZE\ :=' \
		run_preflight >"$output" 2>&1; then
	fail "preflight accepted inherited GNU Make --eval"
fi
expect_configuration_refusal "inherited GNU Make --eval" --eval \
	'GNU Make --eval/-f/--file/--makefile options are not supported'

: > "$tool_log"
if TEST_RELEASE_MAKEFLAGS="-f $work/not-a-release-makefile" \
		run_preflight >"$output" 2>&1; then
	fail "preflight accepted an inherited GNU Make -f option"
fi
expect_configuration_refusal "an inherited GNU Make -f option" -f \
	'GNU Make --eval/-f/--file/--makefile options are not supported'

# A failing nested recipe really does become a zero-status Make under `-i`.
# Prove that premise, then require the production script to stop the same flag
# before its first configuration query can inherit it.
ignore_errors_probe="$work/ignore-errors-probe.mk"
printf '.PHONY: failing-gate\nfailing-gate:\n\t@false\n' > "$ignore_errors_probe"
if env -u MAKEFLAGS -u MFLAGS -u GNUMAKEFLAGS \
		"$REAL_MAKE" -s -f "$ignore_errors_probe" failing-gate >/dev/null 2>&1; then
	fail "failing nested-gate probe succeeded without ignore-errors"
fi
if ! env MAKEFLAGS=i MFLAGS= GNUMAKEFLAGS= \
		"$REAL_MAKE" -s -f "$ignore_errors_probe" failing-gate >/dev/null 2>&1; then
	fail "GNU Make ignore-errors probe did not convert a failed nested gate to success"
fi
checks=$((checks + 1))

expect_recipe_semantic_refusal() { # usage: <label> <channel> <value> <mode>
	local label=$1 channel=$2 value=$3 mode=$4
	: > "$make_log"
	: > "$tool_log"
	case "$channel" in
		MAKEFLAGS)
			if TEST_RELEASE_MAKEFLAGS="$value" run_preflight >"$output" 2>&1; then
				fail "$label was accepted by direct release preflight"
			fi
			;;
		MFLAGS)
			if TEST_RELEASE_MFLAGS="$value" run_preflight >"$output" 2>&1; then
				fail "$label was accepted by direct release preflight"
			fi
			;;
		GNUMAKEFLAGS)
			if TEST_RELEASE_GNUMAKEFLAGS="$value" run_preflight >"$output" 2>&1; then
				fail "$label was accepted by direct release preflight"
			fi
			;;
		*) fail "unknown recipe-semantic flag channel: $channel" ;;
	esac
	expect_configuration_refusal "$label" "$channel" \
		"GNU Make recipe-semantic option $mode"
	[ ! -s "$make_log" ] \
		|| fail "$label reached a Makefile query before rejection: $(<"$make_log")"
}

# Compact, short and long ignore-errors forms cover all three inherited flag
# channels. Dry-run/question/touch are direct-script hazards: unlike an outer
# `make -n`, they would propagate into the script's later production Makes and
# can accept a complete but stale output tree without executing current recipes.
semantic_stale_root="$work/semantic-stale"
semantic_stale_avr="$semantic_stale_root/avr"
semantic_stale_xt="$semantic_stale_root/xt"
semantic_stale_pic322="$semantic_stale_root/pic322"
semantic_stale_pic320="$semantic_stale_root/pic320"
semantic_stale_pic675="$semantic_stale_root/pic675"
mkdir -p "$semantic_stale_avr" "$semantic_stale_xt" \
	"$semantic_stale_pic322" "$semantic_stale_pic320" "$semantic_stale_pic675"
for variant in cd4053_simple cd4053_with_mute tq2_l2_5v_relay; do
	for part in attiny13a attiny85 attiny45; do
		printf 'stale image\n' > "$semantic_stale_avr/bypass-$part-$variant.hex"
	done
	printf 'stale image\n' > "$semantic_stale_xt/bypass-attiny202-$variant.hex"
	printf 'stale image\n' > "$semantic_stale_pic322/bypass-pic10f322-$variant.hex"
	printf 'stale image\n' > "$semantic_stale_pic320/bypass-pic10f320-$variant.hex"
	printf 'stale image\n' > "$semantic_stale_pic675/bypass-pic12f675-$variant.hex"
done
semantic_stale_images=("$semantic_stale_avr"/*.hex "$semantic_stale_xt"/*.hex \
	"$semantic_stale_pic322"/*.hex "$semantic_stale_pic320"/*.hex \
	"$semantic_stale_pic675"/*.hex)
[ "${#semantic_stale_images[@]}" -eq 21 ] \
	|| fail "recipe-semantic fixture is not a complete 21-image stale tree"
export AVR_BUILD_DIR="$semantic_stale_avr" XT_BUILD_DIR="$semantic_stale_xt" \
	PIC10F322_BUILD_DIR="$semantic_stale_pic322" \
	PIC10F320_BUILD_DIR="$semantic_stale_pic320" \
	PIC12F675_BUILD_DIR="$semantic_stale_pic675"
checks=$((checks + 1))

expect_recipe_semantic_refusal "compact MAKEFLAGS ignore-errors" MAKEFLAGS i \
	'-i/--ignore-errors'
expect_recipe_semantic_refusal "short MAKEFLAGS ignore-errors" MAKEFLAGS -i \
	'-i/--ignore-errors'
expect_recipe_semantic_refusal "long MAKEFLAGS ignore-errors" MAKEFLAGS \
	--ignore-errors '-i/--ignore-errors'
expect_recipe_semantic_refusal "MFLAGS ignore-errors" MFLAGS -i \
	'-i/--ignore-errors'
expect_recipe_semantic_refusal "GNUMAKEFLAGS ignore-errors" GNUMAKEFLAGS \
	--ignore-errors '-i/--ignore-errors'
expect_recipe_semantic_refusal "compact direct-script dry-run" MAKEFLAGS n \
	'-n/--dry-run'
expect_recipe_semantic_refusal "long direct-script dry-run" MAKEFLAGS --dry-run \
	'-n/--dry-run'
expect_recipe_semantic_refusal "direct-script just-print alias" MAKEFLAGS \
	--just-print '-n/--dry-run'
expect_recipe_semantic_refusal "direct-script recon alias" MAKEFLAGS --recon \
	'-n/--dry-run'
expect_recipe_semantic_refusal "direct-script question mode" MAKEFLAGS q \
	'-q/--question'
expect_recipe_semantic_refusal "long direct-script question mode" MAKEFLAGS \
	--question '-q/--question'
expect_recipe_semantic_refusal "direct-script touch mode" MAKEFLAGS t \
	'-t/--touch'
expect_recipe_semantic_refusal "long direct-script touch mode" MAKEFLAGS --touch \
	'-t/--touch'
unset AVR_BUILD_DIR XT_BUILD_DIR PIC10F322_BUILD_DIR PIC10F320_BUILD_DIR \
	PIC12F675_BUILD_DIR

: > "$tool_log"
if GPSIM_TIMEOUT_SECONDS=1 run_preflight >"$output" 2>&1; then
	fail "preflight accepted an inherited GPSIM_TIMEOUT_SECONDS override"
fi
expect_configuration_refusal "an inherited GPSIM_TIMEOUT_SECONDS override" \
	GPSIM_TIMEOUT_SECONDS 'not a supported production release override'

# GPSIM_TIMEOUT_SECONDS above is a name the Makefile declares, so the script's
# own inventory refuses it by name. ATTINY_DFP_VER is not declared anywhere in
# the Makefile -- it selects which ATtiny device pack scripts/fetch_attiny_dfp.sh
# vendors -- so the refusal has to come from the Makefile's parse-time guard on
# the environment vocabulary instead, and it names a different diagnostic. Both
# halves matter: an unreviewed build-input selector in the environment is what
# the guard is for whether or not Make reads it, and a release workflow that
# exported one is what failed v0.9.10. Pinning it keeps the refusal a tested
# property rather than an accident of which names CI happens to export.
: > "$tool_log"
if ATTINY_DFP_VER=9.9.999 run_preflight >"$output" 2>&1; then
	fail "preflight accepted an inherited ATTINY_DFP_VER override"
fi
expect_configuration_refusal "an inherited ATTINY_DFP_VER override" \
	ATTINY_DFP_VER \
	'refusing production release configuration under unsupported release overrides'

injected_release_makefile="$work/injected-release.mk"
printf 'override CFLAGS := -DINJECTED_MAKEFILE_FLAGS\n' \
	> "$injected_release_makefile"
: > "$tool_log"
if MAKEFILES="$injected_release_makefile" run_preflight >"$output" 2>&1; then
	fail "preflight accepted an injected release makefile"
fi
expect_configuration_refusal "an injected release makefile" MAKEFILES \
	'MAKEFILES injection'

: > "$tool_log"
if TEST_DUPLICATE_RELEASE_IMAGES=1 run_preflight >"$output" 2>&1; then
	fail "preflight accepted duplicate RELEASE_IMAGES"
fi
expect_configuration_refusal "duplicate canonical images" RELEASE_IMAGES \
	'contains duplicate entries'

: > "$tool_log"
if TEST_DUPLICATE_RELEASE_SOAKS=1 run_preflight >"$output" 2>&1; then
	fail "preflight accepted duplicate RELEASE_SOAK_NAMES"
fi
expect_configuration_refusal "duplicate canonical soaks" RELEASE_SOAK_NAMES \
	'contains duplicate entries'

# The serialization marker is not a capability token. Spawn with close_fds so
# the real lock descriptor held by this test's parent Make is absent; the script
# must reject the marker before its first Make query.
: > "$tool_log"
if marker_output_text=$("$REAL_PYTHON" -c '
import os
import subprocess
import sys

env = {
    "PATH": sys.argv[3],
    "HOME": os.environ["HOME"],
    "TMPDIR": os.environ.get("TMPDIR", os.environ["HOME"]),
    "_MAKE_SERIAL_LOCK_HELD": sys.argv[2],
}
result = subprocess.run(
    [sys.argv[1], "--preflight"],
    env=env,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    text=True,
    close_fds=True,
    check=False,
)
sys.stdout.write(result.stdout)
raise SystemExit(result.returncode)
' "$RELEASE" "$lock_id" "$fakebin:$PATH" 2>&1); then
	fail "preflight accepted a serialization marker without an inherited lock descriptor"
fi
printf '%s\n' "$marker_output_text" > "$output"
expect_configuration_refusal "a serialization marker without its lock" \
	_MAKE_SERIAL_LOCK_HELD 'has no inherited lock descriptor'

# Build directories are not identity, and the whole fake toolchain this gate
# runs on is itself a pile of tool-path overrides -- so a legitimate relocation
# must still reach the end of preflight.
TEST_EXTRA_MAKE_VAR=AVR_BUILD_DIR=relocated-avr run_preflight >"$output" 2>&1 \
	|| fail "preflight rejected a relocated build directory: $(<"$output")"
grep -Fq 'production release identity matches the pinned declaration:' "$output" \
	|| fail "a relocated build directory changed the verified release identity"
grep -Fq 'preflight passed: this host can start a release.' "$output" \
	|| fail "preflight with a relocated build directory did not reach its success record"
assert_no_release_scratch
checks=$((checks + 1))

documentation_root="$work/documentation-root"
write_documentation_fixture() {
	local declaration_version=$1 image_count=$2 soak_count=$3
	local modular_targets=$4 shell_files=$5 changelog_release=${6:-1.2.3}
	local release_entry=${7:-- Finalized release documentation.}
	local unreleased_heading=${8:-'## [Unreleased]'}
	local declaration
	declaration="**Current release contract:** \`$declaration_version\`; seven release parts; $image_count images; $soak_count soak combinations; $modular_targets modular targets; $shell_files shell source files."
	rm -rf "$documentation_root"
	mkdir -p "$documentation_root/release" "$documentation_root/docs"
	cat > "$documentation_root/CHANGELOG.md" <<EOF
# Changelog

$unreleased_heading

## [$changelog_release] - 2026-08-17

### Fixed

$release_entry

## [1.2.2] - 2026-08-16

### Fixed

- Prior release.

[Unreleased]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v1.2.3...HEAD
[1.2.3]: https://github.com/matt-garman/mcu-bypass-firmware/compare/v1.2.2...v1.2.3
[1.2.2]: https://github.com/matt-garman/mcu-bypass-firmware/releases/tag/v1.2.2
EOF
	cat > "$documentation_root/release/README.md" <<EOF
<!-- current-release:start -->
$declaration
<!-- current-release:end -->
EOF
	# Present, durable, and deliberately carrying no declaration of its own:
	# TODO.md held a second copy of the contract until the declaration was made
	# singular, so the fixture keeps it here as the document the duplicate-block
	# scan must find nothing in.
	printf '%s\n' '# Remaining work' 'Open actions only.' \
		> "$documentation_root/TODO.md"
}

assert_documentation_rejected() {
	local description=$1
	if release_validate_current_documentation "$documentation_root" v1.2.3 21 18 \
			>"$output" 2>&1; then
		fail "documentation validator accepted $description"
	fi
	grep -Fq 'release documentation:' "$output" \
		|| fail "$description failed without a documentation diagnostic"
	checks=$((checks + 1))
}

write_documentation_fixture v1.2.3 21 18 six four
release_validate_current_documentation "$documentation_root" v1.2.3 21 18 \
	|| fail "documentation validator rejected a finalized fixture"
checks=$((checks + 1))

release_validate_current_documentation "$documentation_root" v1.2.3 21 18 \
	0 \
	|| fail "documentation validator rejected an independently dated finalized heading"
checks=$((checks + 1))

sed -i 's/^## \[1\.2\.3\] - 2026-08-17$/## [1.2.3] - Unreleased/' \
	"$documentation_root/CHANGELOG.md"
release_validate_current_documentation "$documentation_root" v1.2.3 21 18 \
	1 \
	|| fail "documentation preflight rejected an explicit Unreleased draft"
checks=$((checks + 1))
if release_validate_current_documentation "$documentation_root" v1.2.3 21 18 \
		0 >"$output" 2>&1; then
	fail "production documentation validation accepted an Unreleased draft"
fi
grep -Fq 'is still Unreleased' "$output" \
	|| fail "Unreleased production refusal lacked its exact diagnostic"
checks=$((checks + 1))

write_documentation_fixture v1.2.3 21 18 six four 1.2.4
assert_documentation_rejected 'a missing requested-version changelog section'

write_documentation_fixture v1.2.3 21 18 six four 1.2.3 \
	'- Finalized release documentation.' '## [Draft]'
assert_documentation_rejected 'a missing Unreleased heading'

write_documentation_fixture v1.2.3 21 18 six four 1.2.3 \
	'Finalized release documentation.'
assert_documentation_rejected 'an empty requested-version changelog section'

write_documentation_fixture v1.2.30 21 18 six four
assert_documentation_rejected 'a prefix-matching stale current-release version'

write_documentation_fixture v1.2.3 121 18 six four
assert_documentation_rejected 'a superset stale current-release image count'

write_documentation_fixture v1.2.3 21 118 six four
assert_documentation_rejected 'a superset stale current-release soak count'

write_documentation_fixture v1.2.3 21 18 five four
assert_documentation_rejected 'a stale modular-target count'

write_documentation_fixture v1.2.3 21 18 six fourteen
assert_documentation_rejected 'a stale modular-shell count'

write_documentation_fixture v1.2.3 21 18 six four
cat >> "$documentation_root/release/README.md" <<'EOF'
<!-- current-release:start -->
duplicate block
<!-- current-release:end -->
EOF
assert_documentation_rejected 'duplicate current-release markers'

# Explicitly historical prose outside the bounded block must remain permitted.
write_documentation_fixture v1.2.3 21 18 six four
printf '%s\n' 'Historical v1.0.0 release: five targets, 15 images, 12 soaks.' \
	>> "$documentation_root/release/README.md"
release_validate_current_documentation "$documentation_root" v1.2.3 21 18 \
	|| fail "documentation validator treated historical prose as current status"
checks=$((checks + 1))

# D3: a bounded declaration states the SOURCE contract, so it must not claim
# retained evidence this tree does not contain. The version being released is the
# one exception -- a qualified source commit provably cannot carry its own
# release directory, because verify-release-history.sh rejects a release whose
# source commit already contains release/<version>/QUALIFICATION -- and naming it
# during that window is permitted only alongside the exact transition line that
# discloses it.
transition_line='**Pre-tag transition:** `release/v1.2.3/` is created by the release cut and published with the signed `v1.2.3` tag, so the source tree that declares this contract does not contain it yet.'

declare_in_block() {
	# The two `local` statements are separate on purpose. Bash expands every
	# word of a `local` assignment list BEFORE creating any of the names, so
	# `local document=$1 target=".../$document"` reads whatever `document` the
	# CALLER happens to have in scope, not the argument just passed. That is not
	# hypothetical: while the fixture wrote its declaration through a
	# `for document in ...` loop, this helper silently edited the loop's last
	# value and ignored its own first argument entirely.
	local document=$1 line=$2
	local target="$documentation_root/$document"
	awk -v line="$line" '
		$0 == "<!-- current-release:end -->" { print line }
		{ print }
	' "$target" > "$target.new" || fail "could not extend $document"
	mv "$target.new" "$target"
}

write_documentation_fixture v1.2.3 21 18 six four
declare_in_block release/README.md 'Evidence is retained under `release/v1.2.3/`.'
assert_documentation_rejected 'an undisclosed claim on the not-yet-staged release directory'

write_documentation_fixture v1.2.3 21 18 six four
declare_in_block release/README.md 'Evidence is retained under `release/v1.2.3/`.'
declare_in_block release/README.md "$transition_line"
release_validate_current_documentation "$documentation_root" v1.2.3 21 18 \
	|| fail "documentation validator rejected a disclosed pre-tag transition"
checks=$((checks + 1))

# The disclosure covers ONLY the version being released. Any other release
# directory a block names is evidence claimed to be retained now, so an abandoned
# or postponed cut cannot leave the claim standing behind the transition line.
write_documentation_fixture v1.2.3 21 18 six four
declare_in_block release/README.md 'Evidence is retained under `release/v1.2.2/`.'
declare_in_block release/README.md "$transition_line"
assert_documentation_rejected 'a bounded claim on a release directory that does not exist'

write_documentation_fixture v1.2.3 21 18 six four
mkdir -p "$documentation_root/release/v1.2.2"
declare_in_block release/README.md 'Evidence is retained under `release/v1.2.2/`.'
release_validate_current_documentation "$documentation_root" v1.2.3 21 18 \
	|| fail "documentation validator rejected a present retained-evidence directory"
checks=$((checks + 1))

# Historical prose outside the bounds stays unconstrained, as it is for every
# other field of the declaration.
write_documentation_fixture v1.2.3 21 18 six four
printf '%s\n' 'The abandoned `release/v9.9.9/` cut was never published.' \
	>> "$documentation_root/release/README.md"
release_validate_current_documentation "$documentation_root" v1.2.3 21 18 \
	|| fail "documentation validator treated prose outside the bounds as a declaration"
checks=$((checks + 1))

# The declaration is singular. Four documents carried it once, then two, and
# every copy passed this validator because it was compared with the same
# canonical counts -- so the duplication was invisible here and expensive
# everywhere else. A bounded block in any other current document now fails, and
# the diagnostic names it.
write_documentation_fixture v1.2.3 21 18 six four
cat >> "$documentation_root/TODO.md" <<'EOF'
<!-- current-release:start -->
**Current release contract:** `v1.2.3`; seven release parts; 21 images; 18 soak combinations; six modular targets; four shell source files.
<!-- current-release:end -->
EOF
assert_documentation_rejected 'a second document declaring the release contract'
grep -Fq 'TODO.md' "$output" \
	|| fail "the duplicate-declaration refusal did not name the offending document"
checks=$((checks + 1))

# ... and an EXACT copy fails just as an inconsistent one does. A second copy
# that happens to agree today is the copy that silently disagrees next release;
# there is nothing left for this gate to catch once both are compared against
# the canonical counts, which is why the count is what it checks.
grep -Fq 'seven release parts' "$documentation_root/TODO.md" \
	|| fail "the duplicate-declaration fixture did not restate the contract verbatim"
checks=$((checks + 1))

# Two kinds of document legitimately carry a declaration that is not the live
# one. A shipped release directory records the contract current when it was
# published...
write_documentation_fixture v1.2.3 21 18 six four
mkdir -p "$documentation_root/release/v1.2.2"
cat > "$documentation_root/release/v1.2.2/MANIFEST.md" <<'EOF'
<!-- current-release:start -->
**Current release contract:** `v1.2.2`; seven release parts; 20 images; 17 soak combinations; six modular targets; four shell source files.
<!-- current-release:end -->
EOF
release_validate_current_documentation "$documentation_root" v1.2.3 21 18 \
	|| fail "documentation validator read a shipped release directory as a live declaration"
checks=$((checks + 1))

# ... and a root-level working document quotes the markers while describing
# them, and is deleted before release source finalization.
write_documentation_fixture v1.2.3 21 18 six four
cat > "$documentation_root/v1.2.3-notes.md" <<'EOF'
# Release notes work plan

> **Branch-only working document.** Deleted before release source
> finalization.

The declaration this branch is retiring reads:

<!-- current-release:start -->
**Current release contract:** `v1.2.2`; seven release parts; 20 images; 17 soak combinations; six modular targets; four shell source files.
<!-- current-release:end -->
EOF
release_validate_current_documentation "$documentation_root" v1.2.3 21 18 \
	|| fail "documentation validator read a branch-only working document as a live declaration"
checks=$((checks + 1))
rm -f "$documentation_root/v1.2.3-notes.md"

# release/README.md carries its block as a blockquote, so the transition line
# must be read through the same `> ` strip as the contract line.
write_documentation_fixture v1.2.3 21 18 six four
declare_in_block release/README.md '> Evidence is retained under `release/v1.2.3/`.'
declare_in_block release/README.md "> $transition_line"
release_validate_current_documentation "$documentation_root" v1.2.3 21 18 \
	|| fail "documentation validator did not read a blockquoted transition line"
checks=$((checks + 1))

# D4: the same declaration, held continuously rather than on release day.
#
# release_validate_current_documentation is reached only through
# make-release.sh, which supplies both the version being cut and the canonical
# counts. So the single authority for the release contract -- the one bounded
# block every other document was reduced to pointing at -- was verified on
# release day and by nothing in between: between releases it could name any
# version, any counts, and any retained record.
#
# release_validate_development_state closes that by taking the two inputs from
# the two places that cannot be edited to agree with the declaration -- the
# version from the declaration itself, the counts from the Makefile that builds
# the images -- and then reconciling the declared version with the retained
# record the tree can actually show.
assert_development_state_rejected() {
	local description=$1 expected=$2
	if release_validate_development_state "$documentation_root" 21 18 \
			>"$output" 2>&1; then
		fail "development-state gate accepted $description"
	fi
	grep -Fq 'release documentation:' "$output" \
		|| fail "$description failed without a documentation diagnostic"
	grep -Fq "$expected" "$output" \
		|| fail "$description was rejected without its diagnostic: $(<"$output")"
	checks=$((checks + 1))
}

# Released: the declared version's retained record is present, so the tree owes
# no disclosure and the declaration stands on its own.
write_documentation_fixture v1.2.3 21 18 six four
mkdir -p "$documentation_root/release/v1.2.3"
printf '%s\n' 'format=7' > "$documentation_root/release/v1.2.3/QUALIFICATION"
release_validate_development_state "$documentation_root" 21 18 \
	|| fail "development-state gate rejected a released tree"
checks=$((checks + 1))

# Empty and symlinked placeholders are not retained release evidence. In both
# cases the tree remains pre-tag and owes the transition disclosure.
write_documentation_fixture v1.2.3 21 18 six four
mkdir -p "$documentation_root/release/v1.2.3"
: > "$documentation_root/release/v1.2.3/QUALIFICATION"
assert_development_state_rejected 'an empty retained record read as a published release' \
	'must carry the exact pre-tag transition line'

write_documentation_fixture v1.2.3 21 18 six four
mkdir -p "$documentation_root/release/v1.2.3"
printf '%s\n' 'format=7' > "$documentation_root/real-qualification"
ln -s ../../real-qualification "$documentation_root/release/v1.2.3/QUALIFICATION"
assert_development_state_rejected 'a symlinked retained record read as a published release' \
	'must carry the exact pre-tag transition line'

# Pre-tag: source finalization has declared v1.2.3 and the artifact commit that
# creates release/v1.2.3/ has not happened yet. Undisclosed, that is a tree
# telling a reader a release exists whose evidence it does not contain -- and
# the old rule saw it only if the block happened to name the directory.
write_documentation_fixture v1.2.3 21 18 six four
assert_development_state_rejected 'an undisclosed pre-tag window' \
	'must carry the exact pre-tag transition line'

# Disclosed, the same tree is the intended state.
write_documentation_fixture v1.2.3 21 18 six four
declare_in_block release/README.md "$transition_line"
release_validate_development_state "$documentation_root" 21 18 \
	|| fail "development-state gate rejected a disclosed pre-tag window"
checks=$((checks + 1))

# A directory an aborted cut left behind is not the release.
# verify-release-history.sh reads release/<version>/QUALIFICATION as "this tree
# already contains the release", so the disclosure is owed until that file
# exists, not until the directory does.
write_documentation_fixture v1.2.3 21 18 six four
mkdir -p "$documentation_root/release/v1.2.3"
assert_development_state_rejected 'a half-staged directory read as a published release' \
	'must carry the exact pre-tag transition line'

# The counts are the Makefile's, so a declaration cannot pass by agreeing with
# itself -- which is exactly what a gate given the declaration's own numbers
# would do.
write_documentation_fixture v1.2.3 20 18 six four
mkdir -p "$documentation_root/release/v1.2.3"
: > "$documentation_root/release/v1.2.3/QUALIFICATION"
assert_development_state_rejected 'a declared image count the build does not produce' \
	'must contain the exact current release contract'

# The version is the declaration's, so an abandoned or postponed finalization
# commit that leaves a version standing which the rest of the tree cannot
# substantiate fails here rather than at the next release.
write_documentation_fixture v1.2.4 21 18 six four
assert_development_state_rejected 'a declared version with no changelog section' \
	'[1.2.4] section'

# A block that declares no contract, or two, has no single version to reconcile
# and is refused before any state question is asked.
write_documentation_fixture v1.2.3 21 18 six four
sed -i 's/^\*\*Current release contract:\*\*/**Release contract:**/' \
	"$documentation_root/release/README.md"
assert_development_state_rejected 'a block declaring no release contract' \
	'exactly one current release contract version; found 0'

write_documentation_fixture v1.2.3 21 18 six four
declare_in_block release/README.md '**Current release contract:** `v1.2.2`; seven release parts; 21 images; 18 soak combinations; six modular targets; four shell source files.'
assert_development_state_rejected 'a block declaring two release contracts' \
	'exactly one current release contract version; found 2'

# The live tree, held to the same gate. print-RELEASE_IMAGES and
# print-RELEASE_SOAK_NAMES are release configuration queries the Makefile
# exempts from parse-time toolchain discovery, so this reads the canonical sets
# on a host with no cross compiler; CC=: keeps that true if the exemption ever
# narrows.
live_release_images=$("$REAL_MAKE" -s --no-print-directory -C "$ROOT" CC=: \
	print-RELEASE_IMAGES) \
	|| fail "could not read the canonical release image set"
live_release_soaks=$("$REAL_MAKE" -s --no-print-directory -C "$ROOT" CC=: \
	print-RELEASE_SOAK_NAMES) \
	|| fail "could not read the canonical release soak set"
read -r -a live_images <<<"$live_release_images"
read -r -a live_soaks <<<"$live_release_soaks"
[ "${#live_images[@]}" -gt 0 ] && [ "${#live_soaks[@]}" -gt 0 ] \
	|| fail "the canonical release image/soak sets are empty"
release_validate_development_state "$ROOT" \
	"${#live_images[@]}" "${#live_soaks[@]}" >"$output" 2>&1 \
	|| fail "the live tree's release declaration does not match its state: $(<"$output")"
checks=$((checks + 1))

# D3: after staging, the same declarations are held to the inventory that was
# actually staged rather than to the canonical set the Makefile predicted. This
# is the last documentation check before the artifact commit and the tag.
staged_root="$work/staged-release"
write_staged_fixture() {
	local images=$1 soaks=$2 i
	rm -rf "$staged_root"
	mkdir -p "$staged_root/evidence"
	for ((i = 1; i <= images; i++)); do
		printf ':00000001FF\n' > "$staged_root/image-$i.hex"
	done
	for ((i = 1; i <= soaks; i++)); do
		printf 'SOAK_RESULT format=1 status=pass combination=c%d\n' "$i" \
			> "$staged_root/evidence/soak-c$i.log"
	done
	# evidence/ also retains logs that are not soak records. A name-based count
	# would fold this one in; a record-based count must not.
	printf 'building soak binaries\n' > "$staged_root/evidence/soak-build.log"
}

assert_staged_rejected() {
	local description=$1 expected=$2
	if release_validate_staged_documentation "$documentation_root" "$staged_root" \
			v1.2.3 >"$output" 2>&1; then
		fail "staged documentation validator accepted $description"
	fi
	grep -Fq "$expected" "$output" \
		|| fail "$description failed without naming the staged inventory: $(<"$output")"
	checks=$((checks + 1))
}

write_documentation_fixture v1.2.3 21 18 six four
declare_in_block release/README.md 'Evidence is retained under `release/v1.2.3/`.'
declare_in_block release/README.md "$transition_line"
write_staged_fixture 21 18
release_validate_staged_documentation "$documentation_root" "$staged_root" v1.2.3 \
	|| fail "staged documentation validator rejected a matching inventory"
checks=$((checks + 1))

write_staged_fixture 20 18
assert_staged_rejected 'a staging that is one image short' '20 images'

write_staged_fixture 21 17
assert_staged_rejected 'a staging that is one soak combination short' '17 soak combinations'

write_staged_fixture 21 18
rm -rf "$staged_root/evidence"
assert_staged_rejected 'a staging that retains no evidence' 'retains no evidence/'

write_staged_fixture 21 18
rm -f "$staged_root"/*.hex
assert_staged_rejected 'a staging that contains no images' 'contains no images'

# H1: the actual release-staging path must refuse a tree that still CONTAINS or
# still REFERENCES a branch-only working document -- one that declares itself in
# its opening blockquote, or any other root-level document outside the durable
# set. This gate is deliberately OUTSIDE
# release_validate_current_documentation -- the versioned preflight above
# legitimately validates the live working branch, where such a document still
# exists during branch work -- and runs only on the real release-staging path
# (make-release.sh, after the preflight exit). Exercised here as a unit against
# throwaway trees.
branch_doc_root="$work/branch-only-doc"
# A working document is recognized by the banner it carries, in the words its
# human readers are shown, rather than by its name. Both spellings the
# convention has used declare the same thing.
write_branch_doc() {
	local name=$1 spelling=${2:-Branch-only} bold=${3:-'**'}
	{
		printf '# %s\n\n' "${name%.*}"
		printf '> %s%s working document.%s Deleted before the merge to main.\n' \
			"$bold" "$spelling" "$bold"
	} > "$branch_doc_root/$name"
}

assert_branch_doc_gate_rejects() {
	local description=$1 expected=${2-}
	if release_reject_branch_only_documents "$branch_doc_root" >"$output" 2>&1; then
		fail "branch-only-document gate accepted $description"
	fi
	grep -Fq 'release documentation:' "$output" \
		|| fail "$description was rejected without a diagnostic"
	[ -z "$expected" ] || grep -Fq -- "$expected" "$output" \
		|| fail "$description was rejected without naming the offender: $(cat "$output")"
	checks=$((checks + 1))
}

rm -rf "$branch_doc_root"; mkdir -p "$branch_doc_root/docs"
# A clean tree passes.
release_reject_branch_only_documents "$branch_doc_root" \
	|| fail "branch-only-document gate rejected a clean release tree"
checks=$((checks + 1))

# Every durable root-level document ships, in either markup this project writes
# documents in, and a root-level file in neither is not a document this gate
# governs at all.
for durable_doc in AGENTS.md CHANGELOG.md CLAUDE.md FLASHING.md \
	HARDWARE_VALIDATION_LOG.md MISRA_COMPLIANCE.md README.md TODO.md \
	DESIGN_DOCUMENTATION.adoc TOOLCHAIN.adoc; do
	: > "$branch_doc_root/$durable_doc"
done
: > "$branch_doc_root/commit_msg.txt"
release_reject_branch_only_documents "$branch_doc_root" \
	|| fail "branch-only-document gate rejected the durable root-level document set"
checks=$((checks + 1))

# A declared root-level working document present -> rejected, and named.
write_branch_doc v1.2.3-polish.md
assert_branch_doc_gate_rejects 'a tree containing a declared root-level v*-polish.md' \
	'v1.2.3-polish.md'
rm -f "$branch_doc_root/v1.2.3-polish.md"

# ... and so is a pre-release fix list, whose name the polish pattern could not
# see, and a third document neither name family anticipates. That progression is
# the defect these cases pin: one name pattern per working document is a
# blocklist, and the next document's name is never in it, so the declaration is
# what the gate reads.
write_branch_doc pre-v1.2.3-fixes.md
assert_branch_doc_gate_rejects 'a tree containing a declared root-level pre-v*-fixes.md' \
	'pre-v1.2.3-fixes.md'
rm -f "$branch_doc_root/pre-v1.2.3-fixes.md"

write_branch_doc post-v1.2.3-bloat-reduction.md Branch-scoped
assert_branch_doc_gate_rejects 'a declared working document outside both historical name families' \
	'branch-only working document(s) must be deleted before release: post-v1.2.3-bloat-reduction.md'
rm -f "$branch_doc_root/post-v1.2.3-bloat-reduction.md"

# ... and so is one written in the project's OTHER documentation markup. This is
# the same defect one dimension over from the name families above: the walk read
# `*.md` only, so a root-level AsciiDoc working document reached a release
# unseen -- while five of the live-tree sweeps, which have always walked both
# markups, were already reading it as durable prose.
write_branch_doc port-notes.adoc Branch-only '*'
assert_branch_doc_gate_rejects 'a declared root-level AsciiDoc working document' \
	'branch-only working document(s) must be deleted before release: port-notes.adoc'
rm -f "$branch_doc_root/port-notes.adoc"

# Neither emphasis spelling is selected by extension. `**bold**` is what a
# Markdown author writes and `*bold*` what an AsciiDoc author writes; both
# render in either file, so a document is not talked out of its own declaration
# by the emphasis its author reached for.
write_branch_doc port-notes.adoc Branch-scoped
assert_branch_doc_gate_rejects 'an AsciiDoc working document declared in Markdown emphasis' \
	'branch-only working document(s) must be deleted before release: port-notes.adoc'
rm -f "$branch_doc_root/port-notes.adoc"

write_branch_doc merge-plan.md Branch-only '*'
assert_branch_doc_gate_rejects 'a Markdown working document declared in AsciiDoc emphasis' \
	'branch-only working document(s) must be deleted before release: merge-plan.md'
rm -f "$branch_doc_root/merge-plan.md"

# An UNDECLARED root-level AsciiDoc document is allowlist drift, exactly as its
# Markdown twin below is, and refused with the same corrective action.
: > "$branch_doc_root/stray.adoc"
assert_branch_doc_gate_rejects 'a root-level AsciiDoc document outside the durable set' \
	'outside the durable root-document set'
rm -f "$branch_doc_root/stray.adoc"

# An UNDECLARED root-level document is refused too, as allowlist drift: the
# declaration never decides acceptance, only which corrective action the release
# is refused with. A working document that forgets its banner fails closed.
: > "$branch_doc_root/merge-notes.md"
assert_branch_doc_gate_rejects 'a tree containing a root-level document outside the durable set' \
	'outside the durable root-document set'
rm -f "$branch_doc_root/merge-notes.md"

# ... including one carrying a working document's NAME but no declaration, which
# is the same fail-closed path and not the branch-only one.
: > "$branch_doc_root/v1.2.3-polish.md"
assert_branch_doc_gate_rejects 'an undeclared root-level v*-polish.md' \
	'outside the durable root-document set'
rm -f "$branch_doc_root/v1.2.3-polish.md"

# ... and so is a document that merely MENTIONS the phrase below its opening
# blockquote. CHANGELOG.md and test/README.md both describe this convention at
# length; describing it is not declaring it, so the banner is read only where a
# declaration belongs.
{
	printf '# Late notes\n\n'
	branch_doc_filler=0
	while [ "$branch_doc_filler" -lt 30 ]; do
		printf 'Filler line %d.\n' "$branch_doc_filler"
		branch_doc_filler=$((branch_doc_filler + 1))
	done
	printf '\n> **Branch-only working document.** Too far down to declare it.\n'
} > "$branch_doc_root/late-banner.md"
assert_branch_doc_gate_rejects 'a declaration below the opening blockquote' \
	'outside the durable root-document set'
rm -f "$branch_doc_root/late-banner.md"

# THE BOUND, PINNED DELIBERATELY. A root-level file in neither markup is not a
# document this gate governs, even carrying the banner. That is why the walk
# names two extensions instead of reading every root-level file: this tree keeps
# a lock file and editor backups at its root, and a gate that failed on those
# would be switched off. The bound moves when the project starts writing
# documents in a third markup, which someone decides once -- unlike a working
# document's name, which a branch invents afresh every time.
printf '> **Branch-only working document.** Not a markup this project writes.\n' \
	> "$branch_doc_root/scratch.txt"
release_reject_branch_only_documents "$branch_doc_root" \
	|| fail "branch-only-document gate governed a root-level file in neither markup"
checks=$((checks + 1))
rm -f "$branch_doc_root/scratch.txt"

# A durable file naming such a document -> rejected (the reference would dangle
# once the document is deleted), for both branch-only families.
printf 'See `v1.2.3-polish.md` item F1 for context.\n' > "$branch_doc_root/docs/notes.md"
assert_branch_doc_gate_rejects 'a durable reference to a branch-only v*-polish.md' \
	'docs/notes.md'
printf 'See `pre-v1.2.3-fixes.md` item G1 for context.\n' > "$branch_doc_root/docs/notes.md"
assert_branch_doc_gate_rejects 'a durable reference to a branch-only pre-v*-fixes.md' \
	'docs/notes.md'
rm -f "$branch_doc_root/docs/notes.md"

# ... and the tree passes again once every violation is gone.
release_reject_branch_only_documents "$branch_doc_root" \
	|| fail "branch-only-document gate rejected a tree after the violations were removed"
checks=$((checks + 1))

# Against the LIVE repository the gate may fail only for a branch-only working
# document the current branch legitimately carries and has declared -- never
# because a root-level document this project actually ships is missing from the
# durable set. That pins the allowlist to the real tree instead of letting it
# drift until the release-staging path is the first thing to notice, and it is
# why the declaration is a banner the document carries rather than a name
# pattern this file would have to be taught one working document at a time.
release_reject_branch_only_documents "$ROOT" >"$output" 2>&1 || true
! grep -Fq 'outside the durable root-document set' "$output" \
	|| fail "the durable root-document set has drifted from the live tree: $(cat "$output")"
checks=$((checks + 1))

# Discovery failures are policy failures, not an empty result set.
if gate_diagnostic=$(find() { return 73; }; release_reject_branch_only_documents "$branch_doc_root" 2>&1); then
	fail "branch-only-document gate accepted a failed document scan"
fi
[[ "$gate_diagnostic" == *"could not scan for branch-only working documents"* ]] \
	|| fail "failed branch-document scan produced the wrong diagnostic: $gate_diagnostic"
checks=$((checks + 1))
if gate_diagnostic=$(grep() { return 74; }; release_reject_branch_only_documents "$branch_doc_root" 2>&1); then
	fail "branch-only-document gate accepted a failed reference scan"
fi
[[ "$gate_diagnostic" == *"could not scan for branch-only working-document references"* ]] \
	|| fail "failed branch-reference scan produced the wrong diagnostic: $gate_diagnostic"
checks=$((checks + 1))

# Production staging is branch-bound independently of the polish-document
# heuristic. The helper accepts only the exact local main ref and fails closed
# for both another branch and detached HEAD.
branch_root="$work/release-branch"
mkdir "$branch_root"
"$REAL_GIT" -C "$branch_root" init -q
"$REAL_GIT" -C "$branch_root" symbolic-ref HEAD refs/heads/main
"$REAL_GIT" -C "$branch_root" -c user.name='Release Branch Test' \
	-c user.email='release-branch@example.invalid' \
	-c commit.gpgsign=false commit --allow-empty -qm fixture
release_require_main_branch "$branch_root" \
	|| fail "main-branch validator rejected refs/heads/main"
"$REAL_GIT" -C "$branch_root" symbolic-ref HEAD refs/heads/v1.2.3-polish
if release_require_main_branch "$branch_root" >"$output" 2>&1; then
	fail "main-branch validator accepted a polish branch"
fi
grep -Fq 'production release requires refs/heads/main' "$output" \
	|| fail "non-main branch failed without its production-release diagnostic"
"$REAL_GIT" -C "$branch_root" symbolic-ref HEAD refs/heads/main
"$REAL_GIT" -C "$branch_root" checkout -q --detach
if release_require_main_branch "$branch_root" >"$output" 2>&1; then
	fail "main-branch validator accepted detached HEAD"
fi
grep -Fq 'HEAD is detached or unreadable' "$output" \
	|| fail "detached HEAD failed without its production-release diagnostic"
checks=$((checks + 1))

# Wiring: make-release.sh must invoke the gate on the REAL release path -- after
# the `--preflight` capability probe exits -- so the preflight (which runs
# against the live polish branch, where the document still exists) is unaffected
# while a real release is gated. Pin the ordering, since placing it in the
# preflight path instead would silently break every versioned preflight probe.
release_script="$ROOT/scripts/make-release.sh"
preflight_exit_line=$(grep -n 'preflight passed: this host can start a release' \
	"$release_script" | head -1 | cut -d: -f1)
gate_call_line=$(grep -Fn 'release_reject_branch_only_documents "$REPO_ROOT"' \
	"$release_script" | head -1 | cut -d: -f1)
main_call_line=$(grep -Fn 'release_require_main_branch "$REPO_ROOT"' \
	"$release_script" | head -1 | cut -d: -f1 || true)
[ -n "$preflight_exit_line" ] && [ -n "$main_call_line" ] && [ -n "$gate_call_line" ] \
	|| fail "could not locate the preflight exit and production release gates in make-release.sh"
[ "$main_call_line" -gt "$preflight_exit_line" ] \
	|| fail "main-branch gate must run AFTER the preflight exit (gate at line $main_call_line, preflight exit at line $preflight_exit_line)"
[ "$gate_call_line" -gt "$preflight_exit_line" ] \
	|| fail "branch-only-document gate must run AFTER the preflight exit (gate at line $gate_call_line, preflight exit at line $preflight_exit_line)"
checks=$((checks + 1))

# D3: the staged-inventory check is the mirror image -- it can only run once a
# release directory exists, so pin it after the qualification verifier and before
# the hand-off that tells the human to commit and tag. Placing it in step 0 would
# make it a duplicate of the pre-build check against the Makefile and would leave
# the staged bytes unbound to the declarations.
qualification_call_line=$(grep -Fn 'scripts/verify-release-qualification.sh "${qualification_args[@]}"' \
	"$release_script" | head -1 | cut -d: -f1)
staged_call_line=$(grep -Fn 'release_validate_staged_documentation "$REPO_ROOT" "$OUTPUT_DIR" "$VERSION"' \
	"$release_script" | head -1 | cut -d: -f1)
handoff_line=$(grep -Fn 'staged -- next steps (run by hand)' \
	"$release_script" | head -1 | cut -d: -f1 || true)
[ -n "$qualification_call_line" ] && [ -n "$staged_call_line" ] && [ -n "$handoff_line" ] \
	|| fail "could not locate the staging, staged-documentation and hand-off steps in make-release.sh"
[ "$staged_call_line" -gt "$qualification_call_line" ] \
	|| fail "staged-documentation check must run AFTER staging is verified (check at line $staged_call_line, qualification at line $qualification_call_line)"
[ "$staged_call_line" -lt "$handoff_line" ] \
	|| fail "staged-documentation check must run BEFORE the commit/tag hand-off (check at line $staged_call_line, hand-off at line $handoff_line)"
checks=$((checks + 1))

# The prospective release is not immutable until its post-signature registry
# block exists. Pin the human handoff order because these commands deliberately
# run after the script stops: sign, generate, verify, stage both paths, commit,
# then tag.
sign_line=$(grep -Fn 'gpg --local-user $RELEASE_SIGNING_FINGERPRINT --armor --detach-sign $OUTPUT_DIR/SHA256SUMS' \
	"$release_script" | head -1 | cut -d: -f1)
record_line=$(grep -Fn './test/test_published_release_immutability.py --print-record $VERSION >> test/published_release_digests.txt' \
	"$release_script" | head -1 | cut -d: -f1)
immutability_line=$(grep -Fxn '  ./test/test_published_release_immutability.py' \
	"$release_script" | head -1 | cut -d: -f1)
artifact_add_line=$(grep -Fn 'git add $OUTPUT_DIR test/published_release_digests.txt' \
	"$release_script" | head -1 | cut -d: -f1)
artifact_commit_line=$(grep -Fn 'git commit -F $OUTPUT_DIR/commit_msg.txt' \
	"$release_script" | head -1 | cut -d: -f1)
# The handoff ends at the PROOF, not at the tag. scripts/make-release.sh
# qualified the source tree; the tree a tag names is the one that contains the
# release directory and the registry append, and no gate has read it when this
# script stops. v0.9.12 was lost in exactly that window.
proof_line=$(grep -Fn './scripts/verify-release-artifact-commit.sh $VERSION' \
	"$release_script" | head -1 | cut -d: -f1)
for handoff_step in "$sign_line" "$record_line" "$immutability_line" \
		"$artifact_add_line" "$artifact_commit_line" "$proof_line"; do
	[[ "$handoff_step" =~ ^[0-9]+$ ]] \
		|| fail "could not locate every publication-registration handoff command"
done
[ "$sign_line" -lt "$record_line" ] \
	&& [ "$record_line" -lt "$immutability_line" ] \
	&& [ "$immutability_line" -lt "$artifact_add_line" ] \
	&& [ "$artifact_add_line" -lt "$artifact_commit_line" ] \
	&& [ "$artifact_commit_line" -lt "$proof_line" ] \
	|| fail "release handoff does not sign, register, verify, stage, commit and prove in order"
checks=$((checks + 1))

# The source-provenance check bounds what a rewritten HEAD costs, and it is one
# `git rev-parse`. Until v0.9.14's first attempt it ran only after the soak: 18
# combinations soaked for 24 hours, all 18 PASS, and the release was then refused
# because HEAD no longer named the commit the run had bound itself to. The commit
# had been amended 83 seconds in, message only, so the tree was byte-identical and
# every hour of that soak had validated exactly the right bytes.
#
# All three call sites are pinned. Dropping either early one restores a day-long
# failure that a minute-long one already covered; dropping the last one removes
# the only check that can see a rewrite made DURING the soak, which is the case
# the early ones cannot reach.
mapfile -t provenance_lines < <(grep -Fn 'release_source_is_unchanged "$GIT_SHA" "$DRY_RUN"' \
	"$release_script" | cut -d: -f1)
validation_section_line=$(grep -Fn 'section "2. validation:' \
	"$release_script" | head -1 | cut -d: -f1)
soak_section_line=$(grep -Fn 'section "3. soak (all release combos' \
	"$release_script" | head -1 | cut -d: -f1)
soak_launch_line=$(grep -Fn 'launching $NCOMBOS soak combos' \
	"$release_script" | head -1 | cut -d: -f1)
soak_done_line=$(grep -Fn 'ok "all $NCOMBOS soak combos passed' \
	"$release_script" | head -1 | cut -d: -f1)
for boundary in "$validation_section_line" "$soak_section_line" \
		"$soak_launch_line" "$soak_done_line"; do
	[[ "$boundary" =~ ^[0-9]+$ ]] \
		|| fail "could not locate every validation and soak phase boundary in make-release.sh"
done
[ "${#provenance_lines[@]}" -eq 3 ] \
	|| fail "make-release.sh must check the source provenance three times -- before validation, before the soak, and after it -- but ${#provenance_lines[@]} call site(s) are present"
[ "${provenance_lines[0]}" -gt "$validation_section_line" ] \
	&& [ "${provenance_lines[0]}" -lt "$soak_section_line" ] \
	|| fail "the first source-provenance check must run at the start of the validation phase (found at line ${provenance_lines[0]})"
[ "${provenance_lines[1]}" -gt "$soak_section_line" ] \
	&& [ "${provenance_lines[1]}" -lt "$soak_launch_line" ] \
	|| fail "a source-provenance check must run at the start of the soak phase, BEFORE any combination is launched (found at line ${provenance_lines[1]}, launch at $soak_launch_line)"
[ "${provenance_lines[2]}" -gt "$soak_done_line" ] \
	|| fail "the authoritative source-provenance check must still run after the soak (found at line ${provenance_lines[2]})"
checks=$((checks + 1))

# The refusal is structural or it is advice. An operator can only paste a tag
# command that some file prints, so exactly one file may print one: the proof,
# which prints it after the gates pass and not before. A tag recipe restored to
# make-release.sh would let a run that never proved itself hand one over.
! grep -Fq 'git tag -s -u $RELEASE_SIGNING_FINGERPRINT $VERSION' "$release_script" \
	|| fail "make-release.sh prints a signed-tag command; only scripts/verify-release-artifact-commit.sh may print one, and only after its gates pass"
grep -Fq 'git tag -s -u $RELEASE_SIGNING_FINGERPRINT $VERSION' \
	"$ROOT/scripts/verify-release-artifact-commit.sh" \
	|| fail "scripts/verify-release-artifact-commit.sh does not print the signed-tag command, so nothing does"
checks=$((checks + 2))

# R3: release/README.md is the maintained owner of the source-checkout
# transaction, and a PUBLISHED PIC12F675 finalization command must carry the
# identity of the transaction it recovers. `make pic12f675-finalize` passes the
# CALLER-selected identity to the recovery oracle, which compares it against what
# the reservation recorded -- so a signed-release example missing
# PIC12F675_RELEASE_TAG rejects the transaction it claims to recover, and a
# development example carrying one
# rejects a reservation that holds no release identity. Both directions are
# checked, in both the static and the generated documentation.
finalization_root="$work/finalization-docs"

# $1 path, $2 programming goal, then the finalize command's arguments. The
# terminating PIC12F675_PART is neither a goal nor a required identity, so any
# required argument can be dropped without leaving a dangling continuation.
write_finalization_doc() {
	local path=$1 program_goal=$2 arg
	shift 2
	mkdir -p "$(dirname "$path")"
	{
		printf '%s\n' 'Guarded transaction:' '' '```sh'
		printf '%s\n' "make -C \"\$repo\" $program_goal \\" \
			'  VARIANT=cd4053_simple \'
		[ "$program_goal" = pic12f675-program ] \
			|| printf '%s\n' '  PIC12F675_RELEASE_TAG="$release_tag" \'
		printf '%s\n' '  PIC12F675_PROG=pk2cmd PIC12F675_PROG_KIND=pk2cmd \' \
			'  PIC12F675_READ_PROG=pk2cmd \' \
			'  PIC12F675_TRIM_EVIDENCE="$baseline" \' \
			'  PIC12F675_BENCH_RESULT="$result"' \
			'```' '' 'Recovery of a PENDING transaction:' '' '```sh' \
			'make -C "$repo" pic12f675-finalize \'
		for arg in "$@"; do
			printf '  %s \\\n' "$arg"
		done
		printf '%s\n' '  PIC12F675_PART=PIC12F675' '```'
	} > "$path"
}

FINALIZE_RELEASE_ARGS=(
	'VARIANT=cd4053_simple'
	'PIC12F675_RELEASE_TAG="$release_tag"'
	'PIC12F675_PROG=pk2cmd PIC12F675_PROG_KIND=pk2cmd'
	'PIC12F675_READ_PROG=pk2cmd'
	'PIC12F675_TRIM_EVIDENCE="$baseline"'
	'PIC12F675_BENCH_RESULT="$result"'
)

# Both anchors valid; individual cases then spoil exactly one of them.
write_finalization_fixture() {
	rm -rf "$finalization_root"
	write_finalization_doc "$finalization_root/README.md" \
		pic12f675-release-program "${FINALIZE_RELEASE_ARGS[@]}"
	write_finalization_doc "$finalization_root/release/README.md" \
		pic12f675-release-program "${FINALIZE_RELEASE_ARGS[@]}"
	printf '%s\n' \
		'PIC12F675 tool facts defer to link:release/README.md#flash-a-chip[release policy].' \
		> "$finalization_root/TOOLCHAIN.adoc"
}

assert_finalization_accepts() {
	local description=$1
	release_validate_pic12f675_finalization "$finalization_root" v1.2.3 >"$output" 2>&1 \
		|| fail "finalization contract rejected $description: $(<"$output")"
	checks=$((checks + 1))
}

assert_finalization_rejects() {
	local description=$1 expected=$2
	if release_validate_pic12f675_finalization "$finalization_root" v1.2.3 \
			>"$output" 2>&1; then
		fail "finalization contract accepted $description"
	fi
	grep -Fq 'release documentation:' "$output" \
		|| fail "$description was rejected without a documentation diagnostic"
	grep -Fq "$expected" "$output" \
		|| fail "$description was rejected for the wrong reason: $(<"$output")"
	checks=$((checks + 1))
}

write_finalization_fixture
assert_finalization_accepts 'a correctly published signed-release recovery'

write_finalization_fixture
printf '%s\n' 'PIC12F675 tool facts only.' > "$finalization_root/TOOLCHAIN.adoc"
assert_finalization_rejects 'a toolchain guide that drops the transaction owner link' \
	'TOOLCHAIN.adoc does not link to release/README.md as the PIC12F675 source-checkout transaction owner'

write_finalization_fixture
printf '%s\n' 'Run pic12f675-preflight before the first write.' \
	>> "$finalization_root/TOOLCHAIN.adoc"
assert_finalization_rejects 'a toolchain guide that republishes transaction details' \
	'TOOLCHAIN.adoc restates PIC12F675 source-checkout transaction details owned by release/README.md'

# The exact pre-v0.9.10 defect, in each anchor independently.
write_finalization_fixture
write_finalization_doc "$finalization_root/README.md" pic12f675-release-program \
	'VARIANT=cd4053_simple' \
	'PIC12F675_PROG=pk2cmd PIC12F675_PROG_KIND=pk2cmd' \
	'PIC12F675_READ_PROG=pk2cmd' \
	'PIC12F675_TRIM_EVIDENCE="$baseline"' \
	'PIC12F675_BENCH_RESULT="$result"'
assert_finalization_rejects 'README.md finalizing a signed release without its tag' \
	'README.md finalizes a pic12f675-release-program transaction without PIC12F675_RELEASE_TAG'

write_finalization_fixture
write_finalization_doc "$finalization_root/release/README.md" pic12f675-release-program \
	'VARIANT=cd4053_simple' \
	'PIC12F675_PROG=pk2cmd PIC12F675_PROG_KIND=pk2cmd' \
	'PIC12F675_READ_PROG=pk2cmd' \
	'PIC12F675_TRIM_EVIDENCE="$baseline"' \
	'PIC12F675_BENCH_RESULT="$result"'
assert_finalization_rejects 'release/README.md finalizing a signed release without its tag' \
	'release/README.md finalizes a pic12f675-release-program transaction without PIC12F675_RELEASE_TAG'

# The opposite direction: a development reservation records no release identity,
# so passing one is equally wrong. This is why the rule is anchored to the
# preceding programming goal instead of simply requiring the tag everywhere.
write_finalization_fixture
write_finalization_doc "$finalization_root/README.md" pic12f675-program \
	"${FINALIZE_RELEASE_ARGS[@]}"
assert_finalization_rejects 'a development transaction finalized with a release tag' \
	'README.md finalizes a pic12f675-program transaction with PIC12F675_RELEASE_TAG'

# ... and the same development pair without the tag is correct.
write_finalization_fixture
write_finalization_doc "$finalization_root/README.md" pic12f675-program \
	'VARIANT=cd4053_simple' \
	'PIC12F675_PROG=pk2cmd PIC12F675_PROG_KIND=pk2cmd' \
	'PIC12F675_READ_PROG=pk2cmd' \
	'PIC12F675_TRIM_EVIDENCE="$baseline"' \
	'PIC12F675_BENCH_RESULT="$result"'
assert_finalization_accepts 'a development transaction finalized without a release tag'

# Every reserved identity is required, not just the release tag.
# PIC12F675_PROG and PIC12F675_PROG_KIND share one published line, so dropping
# either removes both and the scan must report both -- word-level parsing, not
# line-level.
for dropped in VARIANT PIC12F675_PROG PIC12F675_PROG_KIND PIC12F675_READ_PROG \
		PIC12F675_TRIM_EVIDENCE PIC12F675_BENCH_RESULT; do
	write_finalization_fixture
	finalize_args=()
	for finalize_arg in "${FINALIZE_RELEASE_ARGS[@]}"; do
		case "$finalize_arg" in
			"$dropped"=*|*" $dropped"=*) continue ;;
		esac
		finalize_args+=("$finalize_arg")
	done
	write_finalization_doc "$finalization_root/README.md" \
		pic12f675-release-program "${finalize_args[@]}"
	assert_finalization_rejects "a recovery command missing $dropped" \
		"README.md publishes a pic12f675-finalize command without $dropped"
done

# Naming the right variables is not enough: a published recovery that points at
# a different variant or a different result path cannot resolve the transaction
# it follows, which is the same failure as omitting the argument outright.
write_finalization_fixture
write_finalization_doc "$finalization_root/README.md" pic12f675-release-program \
	'VARIANT=cd4053_with_mute' \
	'PIC12F675_RELEASE_TAG="$release_tag"' \
	'PIC12F675_PROG=pk2cmd PIC12F675_PROG_KIND=pk2cmd' \
	'PIC12F675_READ_PROG=pk2cmd' \
	'PIC12F675_TRIM_EVIDENCE="$baseline"' \
	'PIC12F675_BENCH_RESULT="$result"'
assert_finalization_rejects 'a recovery command selecting a different variant' \
	'README.md recovers with VARIANT=cd4053_with_mute but the transaction it follows reserved cd4053_simple'

write_finalization_fixture
write_finalization_doc "$finalization_root/README.md" pic12f675-release-program \
	'VARIANT=cd4053_simple' \
	'PIC12F675_RELEASE_TAG="$release_tag"' \
	'PIC12F675_PROG=pk2cmd PIC12F675_PROG_KIND=pk2cmd' \
	'PIC12F675_READ_PROG=pk2cmd' \
	'PIC12F675_TRIM_EVIDENCE="$baseline"' \
	'PIC12F675_BENCH_RESULT="$other_result"'
assert_finalization_rejects 'a recovery command naming a different result directory' \
	'README.md recovers with PIC12F675_BENCH_RESULT=$other_result but the transaction it follows reserved $result'

# An unanchored example cannot be checked against a reservation at all, so it is
# rejected rather than silently accepted in whichever mode the scan happens to
# be in.
write_finalization_fixture
{
	printf '%s\n' 'Recovery:' '' '```sh' 'make -C "$repo" pic12f675-finalize \'
	printf '  %s \\\n' "${FINALIZE_RELEASE_ARGS[@]}"
	printf '%s\n' '  PIC12F675_PART=PIC12F675' '```'
} > "$finalization_root/README.md"
assert_finalization_rejects 'a recovery example with no transaction to recover' \
	'README.md publishes a pic12f675-finalize command with no preceding'

# Deleting the recovery instructions outright is a failure too: release/README.md
# is the sole live home of the transaction and is scanned whether or not
# discovery finds a command in it.
write_finalization_fixture
printf '%s\n' 'Programming is documented elsewhere.' \
	> "$finalization_root/release/README.md"
assert_finalization_rejects 'the named document dropping its recovery instructions' \
	'release/README.md publishes no pic12f675-finalize command'

# An unnamed document is not scanned for a recovery it never had -- README.md
# now points at both routes without restating either -- but keeping the
# PROGRAMMING command while dropping the recovery is still caught, because
# discovery keys on either half of the pair rather than on the recovery alone.
write_finalization_fixture
printf '%s\n' 'Programming is documented elsewhere.' > "$finalization_root/README.md"
assert_finalization_accepts 'an unnamed document that publishes neither half'

write_finalization_fixture
{
	printf '%s\n' 'Guarded transaction:' '' '```sh' \
		'make -C "$repo" pic12f675-release-program \' \
		'  VARIANT=cd4053_simple \' \
		'  PIC12F675_RELEASE_TAG="$release_tag" \' \
		'  PIC12F675_PROG=pk2cmd PIC12F675_PROG_KIND=pk2cmd \' \
		'  PIC12F675_READ_PROG=pk2cmd \' \
		'  PIC12F675_TRIM_EVIDENCE="$baseline" \' \
		'  PIC12F675_BENCH_RESULT="$result"' '```'
} > "$finalization_root/README.md"
assert_finalization_rejects 'an unnamed document publishing a transaction with no recovery' \
	'README.md publishes no pic12f675-finalize command'

# Prose that merely names the goal is not a published command. test/README.md
# names all three goals this way, so treating a mention as a command would fail
# the live tree.
write_finalization_fixture
printf '%s\n' '' 'Recover retained evidence with make pic12f675-finalize as shown above.' \
	>> "$finalization_root/README.md"
mkdir -p "$finalization_root/test"
# Both shapes the live test/README.md uses inside its layout block: a wrapped
# cell whose line happens to begin with `make`, and a goal named mid-sentence
# with punctuation attached.
printf '%s\n' 'Layout:' '' '```' '     evidence (make pic12f675-program or' \
	'     make pic12f675-release-program; recover PENDING' \
	'     evidence with make pic12f675-finalize)' '```' \
	> "$finalization_root/test/README.md"
assert_finalization_accepts 'prose that names the finalization goal without publishing it'

# Drift-proofing: a NEW document that publishes the command is discovered and
# held to the same rule, without being named anywhere.
write_finalization_fixture
write_finalization_doc "$finalization_root/docs/programming.md" pic12f675-release-program \
	'VARIANT=cd4053_simple' \
	'PIC12F675_PROG=pk2cmd PIC12F675_PROG_KIND=pk2cmd' \
	'PIC12F675_READ_PROG=pk2cmd' \
	'PIC12F675_TRIM_EVIDENCE="$baseline"' \
	'PIC12F675_BENCH_RESULT="$result"'
assert_finalization_rejects 'a newly added document publishing a defective recovery' \
	'docs/programming.md finalizes a pic12f675-release-program transaction without PIC12F675_RELEASE_TAG'

# Shipped release directories are immutable artifacts of past releases:
# release/v0.9.9/MANIFEST.md legitimately publishes the older unsigned
# pic12f675-program transaction and must not be rewritten to satisfy a contract
# introduced later.
write_finalization_fixture
write_finalization_doc "$finalization_root/release/v0.9.9/MANIFEST.md" \
	pic12f675-release-program 'VARIANT=cd4053_simple'
assert_finalization_accepts 'a shipped release directory holding older guidance'

# The generated per-release documentation is held to the same rule by the same
# oracle, so the static and generated instructions cannot drift apart -- which is
# precisely how the defect survived: the generated document carried the argument
# while both static examples did not.
write_finalization_fixture
if (
	release_render_pic12f675_flashing() {
		printf '%s\n' '```sh' 'make -C "$repo" pic12f675-release-program \' \
			'  VARIANT=cd4053_simple \' \
			"  PIC12F675_RELEASE_TAG=$1" \
			'```' '' '```sh' 'make -C "$repo" pic12f675-finalize \' \
			'  VARIANT=cd4053_simple \' \
			'  PIC12F675_PROG=pk2cmd PIC12F675_PROG_KIND=pk2cmd \' \
			'  PIC12F675_READ_PROG=pk2cmd \' \
			'  PIC12F675_TRIM_EVIDENCE="$baseline" \' \
			'  PIC12F675_BENCH_RESULT="$result"' '```'
	}
	release_validate_pic12f675_finalization "$finalization_root" v1.2.3
) >"$output" 2>&1; then
	fail "finalization contract accepted generated documentation missing the release tag"
fi
grep -Fq 'generated release documentation finalizes a pic12f675-release-program transaction without PIC12F675_RELEASE_TAG' \
	"$output" \
	|| fail "defective generated documentation was rejected for the wrong reason: $(<"$output")"
checks=$((checks + 1))

# `make help` is the other place the scope of PIC12F675_RELEASE_TAG is published,
# and it claimed the variable was programming-only while read-only finalization
# consumed it. Pin both halves: the retired claim is gone, and the finalize entry
# names the variable it needs.
makefile_help=$(awk '/^help:/ { capture=1 } capture { print } capture && /^$/ { exit }' \
	"$ROOT/Makefile")
if grep -Fq 'PIC12F675_RELEASE_TAG=vX.Y.Z (pic12f675-release-program only)' "$ROOT/Makefile"; then
	fail "make help still describes PIC12F675_RELEASE_TAG as release-program-only"
fi
grep -Fq 'PIC12F675_RELEASE_TAG' <<<"$makefile_help" \
	|| fail "make help no longer documents PIC12F675_RELEASE_TAG"
awk '/^\t@echo "  pic12f675-finalize/ { capture=1 }
	capture && /PIC12F675_RELEASE_TAG/ { found=1 }
	capture && /^\t@echo "  [a-z]/ && !/pic12f675-finalize/ { exit }
	END { exit !found }' "$ROOT/Makefile" \
	|| fail "the make help entry for pic12f675-finalize does not name PIC12F675_RELEASE_TAG"
checks=$((checks + 1))

# A failed discovery scan is a policy failure, not an empty result set: the two
# named documents would still be checked and a drifted third would pass unseen.
write_finalization_fixture
if (find() { return 73; }; \
		release_validate_pic12f675_finalization "$finalization_root" v1.2.3) \
		>"$output" 2>&1; then
	fail "finalization contract accepted a failed document scan"
fi
grep -Fq 'could not scan for published finalization commands' "$output" \
	|| fail "a failed finalization scan produced the wrong diagnostic: $(<"$output")"
checks=$((checks + 1))

# Argument guards: a caller mistake must not pass vacuously.
write_finalization_fixture
finalization_rc=0
release_validate_pic12f675_finalization "$finalization_root" >"$output" 2>&1 \
	|| finalization_rc=$?
[ "$finalization_rc" -eq 2 ] \
	|| fail "finalization contract accepted a missing version argument"
finalization_rc=0
release_validate_pic12f675_finalization_document "$finalization_root/README.md" \
	>"$output" 2>&1 || finalization_rc=$?
[ "$finalization_rc" -eq 2 ] \
	|| fail "per-document finalization contract accepted a missing label"
if release_validate_pic12f675_finalization "$finalization_root" 1.2.3 >"$output" 2>&1; then
	fail "finalization contract accepted a version that is not vX.Y.Z"
fi
grep -Fq 'requested version is not vX.Y.Z: 1.2.3' "$output" \
	|| fail "a malformed version was rejected without its diagnostic"
if release_validate_pic12f675_finalization_document \
		"$finalization_root/missing.md" 'missing.md' >"$output" 2>&1; then
	fail "per-document finalization contract accepted a missing document"
fi
grep -Fq 'finalization document is not a regular nonempty file: missing.md' "$output" \
	|| fail "a missing document was rejected without its diagnostic"
checks=$((checks + 1))

# The live checked-in tree must satisfy the contract, including the generated
# documentation this repository would render today. This is the check that
# actually pins README.md and release/README.md.
release_validate_pic12f675_finalization "$ROOT" "$live_contract_version" \
	>"$output" 2>&1 \
	|| fail "the checked-in tree fails the PIC12F675 finalization contract at $live_contract_version: $(<"$output")"
checks=$((checks + 1))

# --- hardware-evidence classification ----------------------------------------
# Field use and controlled qualification are different claims, and conflating
# them is what HARDWARE_VALIDATION_LOG.md said before v0.9.10: a table of forum
# build reports under the heading "which firmware has been flashed-to and tested
# on actual hardware", while four other documents said no part had ever run on a
# chip. The validator pins the split; these cases pin the validator, because a
# checker for a documentation contract is exactly the kind of code that can pass
# vacuously and never be noticed.
#
# The fixture root holds a COPY of the real log, so each case starts from the
# shipped document and spoils one property of it. The scan walks the whole
# fixture root, so a second file can be added to a case to test the
# cross-document half without touching the live tree.
hardware_root="$work/hardware-claims"
declare -F release_validate_hardware_claims >/dev/null \
	|| fail "hardware evidence classifier is missing"

write_hardware_fixture() {
	rm -rf "$hardware_root"
	mkdir -p "$hardware_root/docs"
	cp "$ROOT/HARDWARE_VALIDATION_LOG.md" "$hardware_root/HARDWARE_VALIDATION_LOG.md"
}

assert_hardware_accepts() {
	local description=$1
	release_validate_hardware_claims "$hardware_root" >"$output" 2>&1 \
		|| fail "hardware evidence contract rejected $description: $(<"$output")"
	checks=$((checks + 1))
}

assert_hardware_rejects() {
	local description=$1 expected=$2
	if release_validate_hardware_claims "$hardware_root" >"$output" 2>&1; then
		fail "hardware evidence contract accepted $description"
	fi
	grep -Fq 'release documentation:' "$output" \
		|| fail "$description was rejected without a documentation diagnostic"
	grep -Fq "$expected" "$output" \
		|| fail "$description was rejected for the wrong reason: $(<"$output")"
	checks=$((checks + 1))
}

write_hardware_fixture
assert_hardware_accepts 'the shipped hardware validation log'

# 1. STRUCTURE. A part row written outside both bounded sections is a hardware
# claim with no classification at all, which is the pre-v0.9.10 defect in its
# purest form -- a table that says a combination works and never says on what
# evidence.
write_hardware_fixture
printf '| ATtiny85 | CD4053 Simple | v0.9.10 | qualified on the bench |\n' \
	>> "$hardware_root/HARDWARE_VALIDATION_LOG.md"
assert_hardware_rejects 'a part row outside both sections' \
	'a part row sits outside both sections and is therefore unclassified'

write_hardware_fixture
"$REAL_AWK" '{ print } $0 == "<!-- field-reports:end -->" && !done {
		print ""; print "<!-- field-reports:start -->"
		print "<!-- field-reports:end -->"; done=1 }' \
	"$ROOT/HARDWARE_VALIDATION_LOG.md" > "$hardware_root/HARDWARE_VALIDATION_LOG.md"
assert_hardware_rejects 'a duplicated section marker' \
	'field-reports:start is duplicated or nested'

# 2. RECORD CONTRACT. The field list IS the definition of the term; dropping one
# field silently widens what may be called a controlled record.
write_hardware_fixture
"$REAL_AWK" '!/^- \*\*Operator\*\*/' "$ROOT/HARDWARE_VALIDATION_LOG.md" \
	> "$hardware_root/HARDWARE_VALIDATION_LOG.md"
assert_hardware_rejects 'a dropped record-field definition' \
	'does not define the required record field: Operator'

# The declaration and a record cannot both stand: one of them is false.
write_hardware_fixture
"$REAL_AWK" '$0 == "<!-- controlled-qualification:end -->" {
		print "### ATtiny13a / CD4053 Muting / 2026-09-01"; print ""
		print "Worked great on my board."; print "" } { print }' \
	"$ROOT/HARDWARE_VALIDATION_LOG.md" > "$hardware_root/HARDWARE_VALIDATION_LOG.md"
assert_hardware_rejects 'a record standing under the no-record declaration' \
	'declares that no record exists while carrying one'

# The case this contract exists for: the first record anyone writes. A build
# report promoted to a qualification heading carries a date and a verdict and
# none of the identity or measurement data, and must be named field by field.
write_hardware_fixture
"$REAL_AWK" '
	/^\*\*No controlled hardware-qualification record exists for any part\.\*\*$/ {
		print "Records follow."; next }
	$0 == "<!-- controlled-qualification:end -->" {
		print "### ATtiny13a / CD4053 Muting / 2026-09-01"; print ""
		print "- **Date** - 2026-09-01"; print "- **Operator** - a builder"
		print "- **Result** - PASS"; print "" } { print }' \
	"$ROOT/HARDWARE_VALIDATION_LOG.md" > "$hardware_root/HARDWARE_VALIDATION_LOG.md"
assert_hardware_rejects 'a field report wearing a qualification heading' \
	'record "ATtiny13a / CD4053 Muting / 2026-09-01" omits the required field: Image'
release_validate_hardware_claims "$hardware_root" >"$output" 2>&1 || true
for field in 'Source commit' Part Board Programmer Configuration Procedure \
		Observations; do
	grep -Fq "omits the required field: $field" "$output" \
		|| fail "an incomplete record was not diagnosed for its missing $field field"
done
checks=$((checks + 1))

# Removing the declaration without adding a record leaves section 2 saying
# nothing, which reads as "not applicable" rather than "not done".
write_hardware_fixture
"$REAL_AWK" '
	/^\*\*No controlled hardware-qualification record exists for any part\.\*\*$/ { next }
	{ print }' \
	"$ROOT/HARDWARE_VALIDATION_LOG.md" > "$hardware_root/HARDWARE_VALIDATION_LOG.md"
assert_hardware_rejects 'a section 2 that neither declares nor records' \
	'neither declares that no record exists nor carries one'

# Pin compatibility is a board property. The retired note asserted it as
# firmware and programming interchangeability, which is false for both families.
write_hardware_fixture
"$REAL_AWK" '{ sub(/^### On pin compatibility$/, "### Notes"); print }' \
	"$ROOT/HARDWARE_VALIDATION_LOG.md" > "$hardware_root/HARDWARE_VALIDATION_LOG.md"
assert_hardware_rejects 'a removed pin-compatibility qualification' \
	'has no nonempty "On pin compatibility" section'

# 3. VOCABULARY, across every durable document rather than only this one. The
# idiom is the thing that cannot be true and false at once, so its reappearance
# anywhere means the two claims have been folded back together.
write_hardware_fixture
printf '# Notes\n\nLike every part here it has not run on silicon.\n' \
	> "$hardware_root/docs/drifted.md"
assert_hardware_rejects 'the conflated idiom in another document' \
	'still use the conflated "run on silicon" idiom'

write_hardware_fixture
printf 'The PIC10F32x parts have the same pinout and can be used interchangeably\n' \
	> "$hardware_root/docs/drifted.adoc"
assert_hardware_rejects 'the retired interchangeability sentence' \
	'restate the retired unqualified interchangeability sentence'

# NAMING the retired wording is not USING it, and the distinction has to hold or
# the contract cannot be described anywhere -- CHANGELOG.md, test/README.md and
# the validator's own comments all quote both retired forms in order to retire
# them. Code spans and quoted spans are blanked before matching; a bare
# assertion sharing a line with an unrelated quotation is still caught.
write_hardware_fixture
{
	printf 'The retired "run on silicon" idiom is gone, and so is the `run on a part`\n'
	printf 'form. The old note said they "have the same pinout and can be used\n'
	printf 'interchangeably", which was never true of the images or the fuses.\n'
} > "$hardware_root/docs/history.md"
assert_hardware_accepts 'quoted mentions of both retired forms'

write_hardware_fixture
printf 'We used to say "something else"; it has not run on silicon.\n' \
	> "$hardware_root/docs/drifted.md"
assert_hardware_rejects 'a bare assertion sharing a line with a quotation' \
	'still use the conflated'

# Shipped release directories are immutable artifacts of past releases and
# branch-only working documents quote retired wording in order to retire it.
# Both must be pruned, or this contract cannot be introduced at all. The working
# documents are pruned by their declaration, so a name from no known family is
# pruned on the same terms as one from either.
write_hardware_fixture
mkdir -p "$hardware_root/release/v0.9.9"
printf 'None of these designs has run on silicon.\n' \
	> "$hardware_root/release/v0.9.9/MANIFEST.md"
for hardware_branch_doc in pre-v9.9.9-fixes.md v9.9.9-polish.md notes-on-bloat.md; do
	{
		printf '# %s\n\n' "${hardware_branch_doc%.md}"
		printf '> **Branch-only working document.** Deleted before the merge.\n\n'
		printf 'The old wording said it had never run on a device.\n'
	} > "$hardware_root/$hardware_branch_doc"
done
assert_hardware_accepts 'shipped release artifacts and branch-only working documents'

# An UNDECLARED root-level document is durable prose and is held to the
# vocabulary, so the exemption is the declaration rather than the location. So
# is a docs/ journal that declares itself: it ships until it is deleted.
write_hardware_fixture
printf 'None of these designs has run on silicon.\n' > "$hardware_root/notes.md"
assert_hardware_rejects 'an undeclared root-level document' 'still use the conflated'

write_hardware_fixture
{
	printf '> **Branch-only working document.** Not at root level.\n\n'
	printf 'None of these designs has run on silicon.\n'
} > "$hardware_root/docs/journal.md"
assert_hardware_rejects 'a declaration inside a docs/ journal' 'still use the conflated'

# Argument and input guards: a caller mistake must not pass vacuously.
write_hardware_fixture
hardware_rc=0
release_validate_hardware_claims >"$output" 2>&1 || hardware_rc=$?
[ "$hardware_rc" -eq 2 ] \
	|| fail "hardware evidence contract accepted a missing repository argument"
rm -f "$hardware_root/HARDWARE_VALIDATION_LOG.md"
assert_hardware_rejects 'a missing hardware validation log' \
	'HARDWARE_VALIDATION_LOG.md is not a regular nonempty file'

# The live checked-in tree must satisfy the contract. This is the check that
# actually pins README.md, CHANGELOG.md, DESIGN_DOCUMENTATION.adoc, TODO.md, the
# Makefile and every document under docs/.
release_validate_hardware_claims "$ROOT" >"$output" 2>&1 \
	|| fail "the checked-in tree fails the hardware evidence contract: $(<"$output")"
checks=$((checks + 1))

# --- bounded claims ----------------------------------------------------------
# The contract above keeps field use from being read as qualification. This one
# keeps everything the project has NOT established from being quietly dropped,
# and it exists because an audit of the seven claim boundaries this branch was
# supposed to preserve found three of them enforced by nothing at all: the root
# README's qualification denial, PIC10F320's two recorded omissions, and what
# reproducing an image proves. Each was deleted from a scratch clone in turn and
# the complete suite stayed green, which is the same shape of defect as a
# document that is the sole home of a policy -- correct today, and silently
# removable.
#
# The fixture root holds COPIES of the four real documents, so each case starts
# from the shipped text and spoils one property of it.
boundaries_root="$work/claim-boundaries"
declare -F release_validate_claim_boundaries >/dev/null \
	|| fail "bounded-claim validator is missing"

write_boundaries_fixture() {
	rm -rf "$boundaries_root"
	mkdir -p "$boundaries_root/release"
	cp "$ROOT/README.md" "$boundaries_root/README.md"
	cp "$ROOT/DESIGN_DOCUMENTATION.adoc" "$boundaries_root/DESIGN_DOCUMENTATION.adoc"
	cp "$ROOT/TOOLCHAIN.adoc" "$boundaries_root/TOOLCHAIN.adoc"
	cp "$ROOT/release/README.md" "$boundaries_root/release/README.md"
	cp "$ROOT/HARDWARE_VALIDATION_LOG.md" "$boundaries_root/HARDWARE_VALIDATION_LOG.md"
}

# Delete whichever line carries a bounded claim's anchor, which is how a
# consolidation loses one: not by contradicting it, by not carrying it over.
drop_claim_line() {
	local document=$1 anchor=$2 kept="$boundaries_root/.kept"
	"$REAL_AWK" -v needle="$anchor" 'index($0, needle) { next } { print }' \
		"$boundaries_root/$document" > "$kept" \
		|| fail "could not spoil $document"
	mv "$kept" "$boundaries_root/$document"
}

# Delete a fenced claim block outright, fence and all. This is the spoiling that
# matters now: what is forbidden is LOSING a claim, and this is what losing one
# looks like in a diff.
drop_claim_block_at() {
	local root=$1 document=$2 marker=$3
	# Two statements: `local` expands every argument before it assigns any of
	# them, so `kept` cannot be written in terms of `root` on the same line.
	local kept="$root/.kept"
	"$REAL_AWK" -v marker="$marker" '
		{ line=$0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", line) }
		line == "<!-- " marker ":start -->" || line == "// " marker ":start" { inside=1; next }
		line == "<!-- " marker ":end -->" || line == "// " marker ":end" { inside=0; next }
		inside { next }
		{ print }
	' "$root/$document" > "$kept" \
		|| fail "could not drop the $marker block from $document"
	mv "$kept" "$root/$document"
}

drop_claim_block() {
	drop_claim_block_at "$boundaries_root" "$1" "$2"
}

# Replace a fenced block's body, keeping the fence: what an editor does when
# rewriting prose. Passing an empty body empties the block.
reword_claim_block_at() {
	local root=$1 document=$2 marker=$3 body=$4
	local kept="$root/.kept"
	"$REAL_AWK" -v marker="$marker" -v body="$body" '
		{ line=$0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", line) }
		line == "<!-- " marker ":start -->" || line == "// " marker ":start" {
			print; if (body != "") print body; inside=1; next
		}
		line == "<!-- " marker ":end -->" || line == "// " marker ":end" {
			inside=0; print; next
		}
		inside { next }
		{ print }
	' "$root/$document" > "$kept" \
		|| fail "could not reword the $marker block in $document"
	mv "$kept" "$root/$document"
}

reword_claim_block() {
	reword_claim_block_at "$boundaries_root" "$1" "$2" "$3"
}

assert_boundaries_accepts() {
	local description=$1
	release_validate_claim_boundaries "$boundaries_root" >"$output" 2>&1 \
		|| fail "bounded-claim contract rejected $description: $(<"$output")"
	checks=$((checks + 1))
}

assert_boundaries_rejects() {
	local description=$1 expected=$2
	if release_validate_claim_boundaries "$boundaries_root" >"$output" 2>&1; then
		fail "bounded-claim contract accepted $description"
	fi
	grep -Fq 'release documentation:' "$output" \
		|| fail "$description was rejected without a documentation diagnostic"
	grep -Fq "$expected" "$output" \
		|| fail "$description was rejected for the wrong reason: $(<"$output")"
	checks=$((checks + 1))
}

# The current-fact rules are a SEPARATE validator, and deliberately so: they
# police prose that restates a fact release/README.md owns, ages out of true, or
# pins itself to a moment. Every one is a real drift this project has had, and
# none of them is a defect in a release -- so they run here, on every commit,
# and make-release.sh does not call them. Keeping their cases beside the claim
# boundaries keeps the two contracts readable together while the gate that can
# stop a release stays the smaller one.
assert_current_facts_rejects() {
	local description=$1 expected=$2
	if release_validate_current_fact_rules "$boundaries_root" >"$output" 2>&1; then
		fail "current-fact contract accepted $description"
	fi
	grep -Fq 'release documentation:' "$output" \
		|| fail "$description was rejected without a documentation diagnostic"
	grep -Fq "$expected" "$output" \
		|| fail "$description was rejected for the wrong reason: $(<"$output")"
	checks=$((checks + 1))
}

# A current-fact violation must NOT reach the validator the release path calls.
# If it ever does, the split has collapsed and design prose can stop a release
# again.
assert_boundaries_ignores() {
	local description=$1
	release_validate_claim_boundaries "$boundaries_root" >"$output" 2>&1 \
		|| fail "the release-path claim contract rejected $description, which is a current-fact rule and not its concern: $(<"$output")"
	checks=$((checks + 1))
}

write_boundaries_fixture
assert_boundaries_accepts 'the shipped documents'
release_validate_current_fact_rules "$boundaries_root" >"$output" 2>&1 \
	|| fail "the current-fact contract rejected the shipped documents: $(<"$output")"
checks=$((checks + 1))

# 1. PRESENCE. Each claim is fenced in the document that owns it, and the fence
#    is deleted, emptied, unbalanced, gutted -- and rewritten.
#
#    The last of those is the point. Until this branch every claim here was
#    pinned as an exact sentence, which made a rewording and a deletion fail
#    identically. That taught an author the offence was touching the prose, when
#    the actual offence is losing the claim. Each claim below therefore carries
#    a REWRITE case that must be ACCEPTED alongside the spoilings that must be
#    rejected; if an accept case ever starts failing, the gate has quietly gone
#    back to pinning prose and this contract has stopped meaning what it says.

# The root README is where a reader arrives, and its denial was the one the log's
# sentinel did not cover.
write_boundaries_fixture
drop_claim_block README.md qualification-status
assert_boundaries_rejects 'a README with no qualification-status block' \
	'README.md must carry exactly one well-formed qualification-status block'

write_boundaries_fixture
reword_claim_block README.md qualification-status ''
assert_boundaries_rejects 'a README whose qualification-status block was emptied' \
	'README.md has an empty qualification-status block'

# An unbalanced fence is not a lesser fault than a missing one. It is how a
# block stops bounding anything while still looking fenced in review.
write_boundaries_fixture
drop_claim_line README.md '<!-- qualification-status:end -->'
assert_boundaries_rejects 'a README whose qualification-status fence never closes' \
	'README.md must carry exactly one well-formed qualification-status block'

# The claim inverted. No amount of rewording licenses this one.
write_boundaries_fixture
reword_claim_block README.md qualification-status \
	'Every part has completed controlled hardware qualification: a bench run against a written procedure whose source/image identity, configuration bytes, instrument readings and acceptance results are retained. See [HARDWARE_VALIDATION_LOG.md](HARDWARE_VALIDATION_LOG.md).'
assert_boundaries_rejects 'a README that turns the qualification denial into a claim' \
	"README.md's qualification-status block no longer states"

# The denial kept, the definition dropped. "Not qualified yet", with no statement
# of what qualification would have required, is a weaker commitment wearing the
# same words -- and it is the shape the pre-v0.9.10 conflation actually took.
write_boundaries_fixture
reword_claim_block README.md qualification-status \
	'No part has been through this yet; see [HARDWARE_VALIDATION_LOG.md](HARDWARE_VALIDATION_LOG.md).'
assert_boundaries_rejects 'a README that keeps the denial but drops what qualification means' \
	"README.md's qualification-status block no longer states"

# The block must also keep pointing at the record that owns the underlying fact,
# which is a structural requirement rather than a wording one.
write_boundaries_fixture
reword_claim_block README.md qualification-status \
	'No part has completed a controlled hardware qualification yet: a bench run against a written procedure whose source/image identity, configuration bytes, instrument readings and acceptance results are retained.'
assert_boundaries_rejects 'a README qualification denial that cites no validation record' \
	'nothing in it says HARDWARE_VALIDATION_LOG'

# ACCEPTED: the same commitment, another voice, different emphasis, different
# sentence order, different wrapping.
write_boundaries_fixture
reword_claim_block README.md qualification-status \
	'Nothing here has been through a controlled hardware qualification yet. By that I mean a real bench run, against a written procedure, where the source and image identity, the configuration bytes, the instrument readings and the acceptance results all get retained afterwards. What has happened instead is field use, logged in [HARDWARE_VALIDATION_LOG.md](HARDWARE_VALIDATION_LOG.md).'
assert_boundaries_accepts 'a README qualification denial rewritten in another voice'

# PIC10F320 ships a general defence its 256 words could not hold. Both halves of
# that record are fenced: what was not ported, and the restatement in the
# "what this package does not establish" list a reader is pointed to.
write_boundaries_fixture
drop_claim_block DESIGN_DOCUMENTATION.adoc pic10f320-recorded-omission
assert_boundaries_rejects 'a design document that drops the PIC10F320 latch omission' \
	'DESIGN_DOCUMENTATION.adoc must carry exactly one well-formed pic10f320-recorded-omission block'

# The capacity reason is the whole justification. Without it the omission reads
# as an oversight somebody should simply fix.
write_boundaries_fixture
reword_claim_block DESIGN_DOCUMENTATION.adoc pic10f320-recorded-omission \
	'The exact-TRISA direction check was ported here; the general output-latch match was not, for reasons of taste on the three variants.'
assert_boundaries_rejects 'a design document that drops why the latch check was omitted' \
	"DESIGN_DOCUMENTATION.adoc's pic10f320-recorded-omission block no longer states"

# ACCEPTED: the same record, rewritten.
write_boundaries_fixture
reword_claim_block DESIGN_DOCUMENTATION.adoc pic10f320-recorded-omission \
	'I ported the exact-TRISA direction check, which costs one word per variant. I did not port the general output-latch match: every formulation of it that keeps its meaning blows past 256 words on two of the three variants, and a partial version is worse than none.'
assert_boundaries_accepts 'a rewritten PIC10F320 omission record'

# The equivalence argument is a behavioural argument. Losing it turns a
# hand-inlined part's assurance case into a byte-identity claim it never made.
write_boundaries_fixture
drop_claim_block DESIGN_DOCUMENTATION.adoc pic10f320-assurance-seam
assert_boundaries_rejects 'a design document that drops the inlining-seam limit' \
	'DESIGN_DOCUMENTATION.adoc must carry exactly one well-formed pic10f320-assurance-seam block'

write_boundaries_fixture
reword_claim_block DESIGN_DOCUMENTATION.adoc pic10f320-assurance-seam \
	'The verified code is the shipped code, and the general output-latch check is absent as above; the hardware-bench properties are simulated.'
assert_boundaries_rejects 'a design document that closes the inlining seam by assertion' \
	"DESIGN_DOCUMENTATION.adoc's pic10f320-assurance-seam block no longer states"

# Reproducing an image proves the bytes match the tested source. It does not
# qualify the firmware, and this block is the only thing standing between the
# two claims for a reader of the release documentation.
write_boundaries_fixture
drop_claim_block release/README.md image-attestation
assert_boundaries_rejects 'release documentation that drops what reproduction proves' \
	'release/README.md must carry exactly one well-formed image-attestation block'

# Retaining a known-unsafe image for reproducibility is not endorsing it.
write_boundaries_fixture
drop_claim_block release/README.md historical-images
assert_boundaries_rejects 'release documentation that drops the retention limit' \
	'release/README.md must carry exactly one well-formed historical-images block'

# ACCEPTED: the retention limit, rewritten.
write_boundaries_fixture
reword_claim_block release/README.md historical-images \
	'They stay published purely so the historical record stays whole and every past release still reproduces; nothing about keeping them is an endorsement, and their integrity is all that is retained.'
assert_boundaries_accepts 'a rewritten retention limit'

# The PIC10F320 exists as a hand-inlined single file for exactly one reason,
# and that reason is a measured overrun. A reader who loses it is left with an
# unexplained departure from every other target's architecture.
write_boundaries_fixture
drop_claim_block DESIGN_DOCUMENTATION.adoc pic10f320-flash-overrun
assert_boundaries_rejects 'a design document that drops why the PIC10F320 is hand-inlined' \
	'DESIGN_DOCUMENTATION.adoc must carry exactly one well-formed pic10f320-flash-overrun block'

# The direction is the claim. A block naming the architecture, the ceiling and
# the measurement, but no longer saying the one overran the other, has inverted
# the record while keeping every noun in it.
write_boundaries_fixture
reword_claim_block DESIGN_DOCUMENTATION.adoc pic10f320-flash-overrun \
	'The modular firmware for this part was measured at 256 words for the simple, mute and relay variants, so the modular architecture was kept.'
assert_boundaries_rejects 'a design document whose PIC10F320 sizing record no longer overruns' \
	"DESIGN_DOCUMENTATION.adoc's pic10f320-flash-overrun block no longer states"

# ACCEPTED: the same overrun, another voice, and a different member of the
# does-not-fit family than the shipped prose leans on.
write_boundaries_fixture
reword_claim_block DESIGN_DOCUMENTATION.adoc pic10f320-flash-overrun \
	'I did not guess at this. The modular firmware simply does not fit: I built all three variants, each came out roughly a hundred words too large for the 256 this part has, and the linker refused outright rather than missing narrowly.'
assert_boundaries_accepts 'a rewritten PIC10F320 overrun record'

# A3 retired the last exact-sentence pin in this project. It existed because a
# measurement had been placed in durable design prose and binding its
# provenance was the mitigation; the rule's own remedy is that the measurement
# leaves. These two keep the mitigation from creeping back in its place --
# nothing in this document is dated, and nothing in it is pinned to a revision,
# because git already records both.
write_boundaries_fixture
printf '\nMeasured 2026-06-26 with the pinned toolchain, the shell built at 356 words.\n' \
	>> "$boundaries_root/DESIGN_DOCUMENTATION.adoc"
assert_current_facts_rejects 'a design guide dating its own prose' \
	'DESIGN_DOCUMENTATION.adoc binds durable design prose to a date or a source revision'
assert_boundaries_ignores 'a design guide dating its own prose'

write_boundaries_fixture
printf '\nThat was established at source commit `0b44c0d` on the pinned toolchain.\n' \
	>> "$boundaries_root/DESIGN_DOCUMENTATION.adoc"
assert_current_facts_rejects 'a design guide pinning its own prose to a revision' \
	'DESIGN_DOCUMENTATION.adoc binds durable design prose to a date or a source revision'
assert_boundaries_ignores 'a design guide pinning its own prose to a revision'

# 2. CURRENT FACTS. Stable design/tool behavior remains in these documents;
# changing release topology and source-dependent results do not.
write_boundaries_fixture
printf '\nThe firmware has eight MCU release targets.\n' \
	>> "$boundaries_root/DESIGN_DOCUMENTATION.adoc"
assert_current_facts_rejects 'a design guide restating the current target count' \
	'DESIGN_DOCUMENTATION.adoc restates current release topology outside release/README.md'
assert_boundaries_ignores 'a design guide restating the current target count'

write_boundaries_fixture
printf '\nA release is the eight-part, 24-image, 20-soak-combination product set.\n' \
	>> "$boundaries_root/TOOLCHAIN.adoc"
assert_current_facts_rejects 'a toolchain guide restating the current product shape' \
	'TOOLCHAIN.adoc restates current release topology outside release/README.md'

write_boundaries_fixture
printf '\n.Table Measured worst pet-to-pet interval, real image in simavr\n' \
	>> "$boundaries_root/DESIGN_DOCUMENTATION.adoc"
assert_current_facts_rejects 'an unbound live-image watchdog measurement' \
	'DESIGN_DOCUMENTATION.adoc carries an unbound source-dependent measurement'

write_boundaries_fixture
printf '\nThe per-tick sanity work is only ~211 instruction cycles.\n' \
	>> "$boundaries_root/DESIGN_DOCUMENTATION.adoc"
assert_current_facts_rejects 'an unbound PIC loop-cycle measurement' \
	'DESIGN_DOCUMENTATION.adoc carries an unbound source-dependent measurement'

write_boundaries_fixture
printf '\nMeasured on one source, -O0 used more words than -O2.\n' \
	>> "$boundaries_root/TOOLCHAIN.adoc"
assert_current_facts_rejects 'an unbound compiler optimization comparison' \
	'TOOLCHAIN.adoc carries an unbound source-dependent measurement'

# 3. ABSENCE. The claim the sentinel forbids, in each way it can arrive.
write_boundaries_fixture
printf '\nEvery release ships hardware-qualified firmware.\n' \
	>> "$boundaries_root/README.md"
assert_boundaries_rejects 'a document attributing qualification to the firmware' \
	'durable file(s) attribute controlled qualification or hardware validation'

# The banned form is two words, and a wrapped document splits it across the line
# break a line-oriented scan would read as two innocent lines. This case is the
# reason the scan flows the document first.
write_boundaries_fixture
printf '\nEvery release ships hardware-validated\nfirmware for every board.\n' \
	>> "$boundaries_root/README.md"
assert_boundaries_rejects 'an attributed claim split across a line break' \
	'durable file(s) attribute controlled qualification or hardware validation'

# NAMING the banned wording is not USING it: this file, CHANGELOG.md and the
# branch working documents all have to write it down in order to retire it.
write_boundaries_fixture
printf '\nNever describe a release as `hardware-qualified firmware`.\n' \
	>> "$boundaries_root/README.md"
assert_boundaries_accepts 'the banned wording inside a code span'

write_boundaries_fixture
printf '> **Branch-only working document.**\n\nShips hardware-validated firmware.\n' \
	> "$boundaries_root/NOTES.md"
assert_boundaries_accepts 'a root-level branch-only working document'

# The ban is conditional, not permanent. When a part completes controlled
# qualification the sentinel goes, and the same sentence becomes true and
# sayable in the commit that records the run. A ban that outlived its premise
# would make the project unable to state its own first qualification result.
write_boundaries_fixture
drop_claim_line HARDWARE_VALIDATION_LOG.md '**No controlled hardware-qualification record exists for any part.**'
printf '\nThe ATtiny85 is now a hardware-qualified part.\n' \
	>> "$boundaries_root/README.md"
assert_boundaries_accepts 'an attributed claim once the sentinel is gone'

write_boundaries_fixture
rm -f "$boundaries_root/DESIGN_DOCUMENTATION.adoc"
assert_boundaries_rejects 'a missing claim-owning document' \
	'document owning a bounded claim is not a regular nonempty file: DESIGN_DOCUMENTATION.adoc'

boundaries_rc=0
release_validate_claim_boundaries >"$output" 2>&1 || boundaries_rc=$?
[ "$boundaries_rc" -eq 2 ] \
	|| fail "bounded-claim contract accepted a missing repository argument"
checks=$((checks + 1))

# The live checked-in tree must satisfy the contract.
release_validate_claim_boundaries "$ROOT" >"$output" 2>&1 \
	|| fail "the checked-in tree fails the bounded-claim contract: $(<"$output")"
checks=$((checks + 1))

current_facts_rc=0
release_validate_current_fact_rules >"$output" 2>&1 || current_facts_rc=$?
[ "$current_facts_rc" -eq 2 ] \
	|| fail "current-fact contract accepted a missing repository argument"
checks=$((checks + 1))

# The live checked-in tree must satisfy the current-fact rules too. This is the
# assertion that replaces their release-time enforcement: the rules did not get
# weaker, they stopped being able to stop a release.
release_validate_current_fact_rules "$ROOT" >"$output" 2>&1 \
	|| fail "the checked-in tree fails the current-fact contract: $(<"$output")"
checks=$((checks + 1))

# ...and the release path must NOT call it. The whole point of the split is
# that a drifted sentence in a design document cannot stop a release, so a
# future edit that "restores" this call for symmetry has to fail here rather
# than be discovered by an operator who set a day aside.
! grep -Fq 'release_validate_current_fact_rules' "$RELEASE" \
	|| fail "make-release.sh calls the current-fact scanner; design prose can stop a release again"
checks=$((checks + 1))

# The claim boundaries, by contrast, stay on the release path: they guard
# statements a release must not publish more strongly than its evidence.
grep -Fq 'release_validate_claim_boundaries "$REPO_ROOT"' "$RELEASE" \
	|| fail "make-release.sh no longer validates the bounded claims before a release"
checks=$((checks + 1))

# --- release topology: one owner, and the numbers are derived ---------------
#
# The rule the project states -- each fact has exactly one live owner -- was
# enforced for release topology by hand-written denylist patterns naming two
# documents. README.md was not one of them, and "21 different firmware images"
# sat in the file a reader arrives at until an audit found it. A denylist
# refuses the spellings someone thought of.
#
# So the numbers are derived from the canonical sets the build uses, and the
# rule is stated over the derived values. The cases below prove three separate
# things: that the derivation reaches the real Makefile and the real source
# tree, that the patterns move when the numbers move rather than matching a
# literal, and that the two exemptions are load-bearing rather than decorative.
topology_root="$work/topology"
declare -F release_validate_topology_ownership >/dev/null \
	|| fail "topology-ownership validator is missing"
declare -F release_topology_counts >/dev/null \
	|| fail "topology count derivation is missing"

topology_rc=0
release_validate_topology_ownership >"$output" 2>&1 || topology_rc=$?
[ "$topology_rc" -eq 2 ] \
	|| fail "topology contract accepted a call with no arguments"
checks=$((checks + 1))

write_topology_fixture() {
	rm -rf "$topology_root"
	mkdir -p "$topology_root/release" "$topology_root/docs"
	cat > "$topology_root/release/README.md" <<'EOF'
# Releases

<!-- current-release:start -->
> **Current release contract:** `v1.2.3`; seven release parts; 21 images; 18 soak combinations; six modular targets; four shell source files.
<!-- current-release:end -->
EOF
	printf '%s\n' '# Product' '' 'Pick the image that matches your part.' \
		> "$topology_root/README.md"
	printf '%s\n' '# A decision record' '' 'Nothing numeric here.' \
		> "$topology_root/docs/note.md"
}

assert_topology_accepts() {
	local description=$1
	release_validate_topology_ownership "$topology_root" 7 21 18 6 4 \
			>"$output" 2>&1 \
		|| fail "topology contract rejected $description: $(<"$output")"
	checks=$((checks + 1))
}

assert_topology_rejects() {
	local description=$1 expected=$2
	if release_validate_topology_ownership "$topology_root" 7 21 18 6 4 \
			>"$output" 2>&1; then
		fail "topology contract accepted $description"
	fi
	grep -Fq 'release documentation:' "$output" \
		|| fail "$description was rejected without a documentation diagnostic"
	grep -Fq "$expected" "$output" \
		|| fail "$description was rejected for the wrong reason: $(<"$output")"
	checks=$((checks + 1))
}

write_topology_fixture
assert_topology_accepts 'a tree whose only topology statement is the declaration'

# PRESENCE. The declaration must state every derived number. The three topology
# words in the contract line are still literals in the renderer, so this is the
# check that holds them to the sets the build uses: adding a part has to fail
# here rather than ship a declaration that quietly undercounts.
write_topology_fixture
sed -i 's/seven release parts/five release parts/' "$topology_root/release/README.md"
assert_topology_rejects 'a declaration that understates the part count' \
	'does not state the release part count (7)'

write_topology_fixture
sed -i 's/four shell source files/three shell source files/' "$topology_root/release/README.md"
assert_topology_rejects 'a declaration that understates the shell source count' \
	'does not state the shell source file count (4)'

# Deleting the fence is not a way past the presence half, and the failure names
# the marker rather than the sentence.
write_topology_fixture
sed -i '/current-release:end/d' "$topology_root/release/README.md"
assert_topology_rejects 'a declaration whose fence is unclosed' \
	'no bounded current-release declaration'

# ABSENCE, and the defect that motivated the rule: the README's own restatement.
write_topology_fixture
printf '\nThere are 21 different firmware images.\n' >> "$topology_root/README.md"
assert_topology_rejects 'the README restating the image count' \
	'README.md restates the release image count (21)'

# The same claim in the table form a resource table drifts in. The scan reads
# both directions for exactly this: a row names the thing and then carries the
# number, and nothing about that is prose.
write_topology_fixture
printf '\n| Published images | 21 |\n' >> "$topology_root/docs/note.md"
assert_topology_rejects 'a table row carrying the image count' \
	'docs/note.md restates the release image count (21)'

# Each of the five is held, not only the two the release path already compares.
write_topology_fixture
printf '\nThe firmware is built from four modular shells.\n' >> "$topology_root/docs/note.md"
assert_topology_rejects 'a restated shell source count' \
	'docs/note.md restates the shell source file count (4)'

write_topology_fixture
printf '\nSix modular targets share the core.\n' >> "$topology_root/docs/note.md"
assert_topology_rejects 'a restated modular target count' \
	'docs/note.md restates the modular target count (6)'

write_topology_fixture
printf '\nThe soak covers 18 soak combinations.\n' >> "$topology_root/docs/note.md"
assert_topology_rejects 'a restated soak-combination count' \
	'docs/note.md restates the release soak-combination count (18)'

# THE NUMBERS ARE NOT TYPED. This is the case that separates this rule from the
# denylist it replaces: the same sentence is invisible while the derived count
# is 7 and is caught the moment it is 9. A hand-written pattern cannot do that,
# and a gate that passed only because 7 was spelled into it would pass here too.
write_topology_fixture
printf '\nThe design spans nine release parts.\n' >> "$topology_root/docs/note.md"
assert_topology_accepts 'a count this tree does not have'
if release_validate_topology_ownership "$topology_root" 9 21 18 6 4 \
		>"$output" 2>&1; then
	fail "topology contract accepted a restatement of the count it was given"
fi
grep -Fq 'docs/note.md restates the release part count (9)' "$output" \
	|| fail "the topology patterns did not follow the derived count: $(<"$output")"
checks=$((checks + 1))

# A number that qualifies no topology noun is some other number. An eight-level
# return stack, a GCC floor and an instruction budget all pass through, which is
# what makes a bare digit decidable at all.
write_topology_fixture
cat >> "$topology_root/docs/note.md" <<'EOF'

The PIC hardware return stack is 8 levels deep, the toolchain floor is GCC 7,
and the reviewed ceiling is 21 instruction cycles across 18 ticks with 4 words
spare and 6 bytes of RAM unused.
EOF
assert_topology_accepts 'numbers that qualify no topology noun'

# Naming the form in a code span is describing it, not restating it. Without
# this escape neither this file, GOVERNANCE.md nor test/README.md could say what
# the rule refuses -- the trap the ipecmd denial fell into when the enforcement
# register was first published.
write_topology_fixture
printf '\nA document may not write `21 images` outside the declaration.\n' \
	>> "$topology_root/docs/note.md"
assert_topology_accepts 'the banned form named in a code span'

# The two documents that are not scanned, and why neither is a second copy.
write_topology_fixture
printf '# Changelog\n\n## [1.2.2]\n\n- Reached 21 images and 18 soak combinations.\n' \
	> "$topology_root/CHANGELOG.md"
assert_topology_accepts 'a changelog section stating the topology of its own release'

write_topology_fixture
printf '\nThe v1.2.2 set was six targets and 18 images.\n' \
	>> "$topology_root/release/README.md"
assert_topology_accepts 'the owning document describing a past release'

# A branch-only working document quotes the numbers while describing them, and
# is deleted before release source finalization.
write_topology_fixture
cat > "$topology_root/topology-notes.md" <<'EOF'
# Topology notes

> **Branch-only working document.** Deleted before release source
> finalization.

The declaration this branch is checking reads 21 images and 18 soak
combinations.
EOF
assert_topology_accepts 'a declared branch-only working document'
rm -f "$topology_root/topology-notes.md"

# ... and so does its AsciiDoc twin. This is the half of the markup fix the
# release gate cannot demonstrate: the sweeps walk both markups and always have,
# so before the detector learned the second one, a root-level AsciiDoc working
# document was held to the very bans a working document exists to be exempt
# from -- and could not have quoted the numbers it was written to discuss.
write_topology_fixture
cat > "$topology_root/topology-notes.adoc" <<'EOF'
= Topology notes

> *Branch-only working document.* Deleted before release source
> finalization.

The declaration this branch is checking reads 21 images and 18 soak
combinations.
EOF
assert_topology_accepts 'a declared branch-only AsciiDoc working document'
rm -f "$topology_root/topology-notes.adoc"

# AN EXEMPTION IS A FENCE, NOT A NAME. The register names a document and a
# marker; the marker has to exist in that document. A declared region that has
# been deleted fails, and every restatement it was covering fails with it --
# so an exemption cannot be widened by removing the thing that bounds it.
write_topology_fixture
mkdir -p "$topology_root/docs"
cat > "$topology_root/docs/release_proportionality.md" <<'EOF'
# Proportionality

<!-- release-topology-comparison:start -->
| | v0.9.9 | v0.9.13 |
|---|---:|---:|
| Published images | 21 | 21 |
<!-- release-topology-comparison:end -->
EOF
assert_topology_accepts 'a registered exemption inside its own fence'
sed -i '/release-topology-comparison/d' "$topology_root/docs/release_proportionality.md"
assert_topology_rejects 'a registered exemption whose fence has been deleted' \
	'declares the exempt region release-topology-comparison, which is absent or malformed'

# A walk that reads nothing is indistinguishable from a clean tree, which is the
# failure this whole rule is written against. A scan root holding only the two
# documents the rule does not read has nothing left to check, and says so.
write_topology_fixture
rm -f "$topology_root/README.md" "$topology_root/docs/note.md"
assert_topology_rejects 'a scan that read no documents' \
	'the topology scan read no documents'

# The derivation reaches the real Makefile and the real shipping source, and the
# live tree satisfies the rule against its own numbers. Both halves matter: a
# derivation that silently produced nothing would make every pattern vacuous.
topology_counts=$(release_topology_counts "$ROOT") \
	|| fail "could not derive the release topology counts from the live tree"
read -r live_parts live_images live_soaks live_modular live_shells \
	<<<"$topology_counts"
for count in "$live_parts" "$live_images" "$live_soaks" "$live_modular" \
		"$live_shells"; do
	[[ "$count" =~ ^[1-9][0-9]*$ ]] \
		|| fail "derived topology count is not a positive integer: $topology_counts"
done
checks=$((checks + 1))
canonical_images=$("$REAL_MAKE" --no-print-directory -s -C "$ROOT" \
	print-RELEASE_IMAGES) \
	|| fail "could not read the canonical release image set"
[ "$live_images" -eq "$(printf '%s' "$canonical_images" | wc -w)" ] \
	|| fail "the derived image count does not match the canonical release set"
checks=$((checks + 1))
release_validate_topology_ownership "$ROOT" "$live_parts" "$live_images" \
	"$live_soaks" "$live_modular" "$live_shells" >"$output" 2>&1 \
	|| fail "the checked-in tree fails the topology-ownership contract: $(<"$output")"
checks=$((checks + 1))

# ...and the release path must not call it. A restated number in a design
# document is a documentation defect; a release is the most expensive moment
# available at which to discover one. Same split, same reason, as the
# current-fact rules above.
! grep -Fq 'release_validate_topology_ownership' "$RELEASE" \
	|| fail "make-release.sh calls the topology scanner; a restated number can stop a release"
checks=$((checks + 1))

# --- soak reuse --------------------------------------------------------------
# release_reuse_soak_attestation turns "another release declares my key" into
# evidence, or refuses. Its accepting path cannot be exercised here: it requires
# a release directory carrying a SOAK_KEY under a valid detached signature, and
# this suite has no signing key. The first real exercise is the first release
# cut after one that recorded a key. What IS testable is that it refuses
# everything short of that, against the real signed releases this tree retains.
declare -F release_reuse_soak_attestation >/dev/null \
	|| fail "the soak-reuse function is missing"
checks=$((checks + 1))

reuse_scratch="$work/soak-reuse"
mkdir -p "$reuse_scratch"
reuse_rc=0
release_reuse_soak_attestation >"$output" 2>&1 || reuse_rc=$?
[ "$reuse_rc" -eq 2 ] \
	|| fail "soak reuse accepted a call with no arguments"
checks=$((checks + 1))

if release_reuse_soak_attestation "$work/no-such-release" deadbeef 1 \
		"$reuse_scratch" attiny85_cd4053_simple >"$output" 2>&1; then
	fail "soak reuse accepted a release directory that does not exist"
fi
grep -Fq 'is missing, empty, or not a regular file' "$output" \
	|| fail "an absent release was refused without its diagnostic: $(<"$output")"
checks=$((checks + 1))

# Every release published before the key existed is a release with nothing to
# reuse, and must be refused as such rather than treated as an empty match.
reuse_legacy=$(ls -d "$ROOT"/release/v*/ | tail -1)
reuse_legacy=${reuse_legacy%/}
if [ ! -f "$reuse_legacy/SOAK_KEY" ]; then
	if release_reuse_soak_attestation "$reuse_legacy" \
			0000000000000000000000000000000000000000000000000000000000000000 \
			1 "$reuse_scratch" attiny85_cd4053_simple >"$output" 2>&1; then
		fail "soak reuse accepted a release that carries no soak key"
	fi
	grep -Fq 'SOAK_KEY is missing, empty, or not a regular file' "$output" \
		|| fail "a release with no soak key was refused without its diagnostic: $(<"$output")"
	checks=$((checks + 1))
fi

# The soak role is sealed like every other retained transcript, so an adopted
# log is bound by its payload digest rather than by its byte size. Before that,
# a substituted body of identical length carrying an identical SOAK_RESULT
# satisfied every check reuse made.
grep -Fq 'carries no payload seal' "$ROOT/scripts/release-provenance.sh" \
	|| fail "soak reuse does not require an adopted log to carry a payload seal"
grep -Fq 'does not hash to the payload digest its seal states' \
	"$ROOT/scripts/release-provenance.sh" \
	|| fail "soak reuse does not rehash an adopted log against its seal"
checks=$((checks + 1))

# Sealing is the run's own act, so a reused soak must NOT be resealed: the seal
# the attested release wrote is the binding this release stands on.
grep -Fq 'adopted soak transcripts keep the seals' "$RELEASE" \
	|| fail "make-release.sh reseals adopted soak transcripts"
checks=$((checks + 1))

# Nothing may be adopted by a refused reuse.
[ -z "$(ls -A "$reuse_scratch")" ] \
	|| fail "a refused soak reuse left adopted logs behind: $(ls -A "$reuse_scratch")"
checks=$((checks + 1))

# The release path must offer the flag, and must never reuse silently.
grep -Fq -- '--reuse-soak)' "$RELEASE" \
	|| fail "make-release.sh does not accept --reuse-soak"
grep -Fq 'SOAK_SOURCE=this-run' "$RELEASE" \
	|| fail "make-release.sh does not default soak provenance to this run"
checks=$((checks + 1))

# --- the soak record ---------------------------------------------------------
# What a release requires instead of running a soak of its own: one record, at a
# fixed path, keyed on the images it covers. These exercise the three functions
# that write it, read it back, and decide whether it already answers the
# question -- the accepting path included, which soak reuse could never test
# here because it needed a signature this suite has no key for.
for soak_fn in release_soak_require_host release_soak_assemble \
		release_soak_input_key release_soak_record_read \
		release_soak_record_attests release_soak_record_write; do
	declare -F "$soak_fn" >/dev/null \
		|| fail "the soak library does not define $soak_fn"
done
checks=$((checks + 1))

# The library takes its output and failure vocabulary from the orchestrator that
# sources it. Supply the same three here, scoped to this section, so the record
# functions can be exercised without one.
die() { printf 'FATAL %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*" >&2; }
ok()  { printf 'OK   %s\n' "$*" >&2; }

record_rc=0
release_soak_record_read >"$output" 2>&1 || record_rc=$?
[ "$record_rc" -eq 2 ] || fail "the soak record reader accepted a call with no arguments"
record_rc=0
release_soak_record_attests "$work/nothing" deadbeef >"$output" 2>&1 || record_rc=$?
[ "$record_rc" -eq 2 ] || fail "the soak record test accepted two arguments"
record_rc=0
release_soak_record_write "$work/nothing" >"$output" 2>&1 || record_rc=$?
[ "$record_rc" -eq 2 ] || fail "the soak record writer accepted one argument"
checks=$((checks + 1))

# A record is a directory of files a release stages verbatim, so the fixture is
# built the way the producer builds it rather than by hand-writing an index.
record_work="$work/soak-record"
record_evid="$record_work/evidence"
mkdir -p "$record_evid"
record_commit=$(printf 'a%.0s' {1..40})
record_names=(attiny85_cd4053_simple pic12f675_tq2_l2_5v_relay)
record_bases=(soak-build.log)
for record_name in "${record_names[@]}"; do
	record_bases+=("soak-$record_name.log")
done
declare -A RELEASE_EVIDENCE_ROLE=([soak-build.log]=build)
for record_name in "${record_names[@]}"; do
	RELEASE_EVIDENCE_ROLE[soak-$record_name.log]=soak
done
for record_base in "${record_bases[@]}"; do
	printf 'transcript body for %s\n' "$record_base" >"$record_evid/$record_base"
	printf 'EVIDENCE_RESULT format=2 status=pass role=soak evidence=%s lines=1 payload_sha256=%064d source_commit=%s\n' \
		"$record_base" 0 "$record_commit" >>"$record_evid/$record_base"
done
record_payload="$record_work/payload"
printf 'SOAK_KEY format=2\nliveness_interval_ms=60000\n' >"$record_payload"
record_key=$(sha256sum -- "$record_payload") || fail "could not hash the record fixture payload"
record_key=${record_key%% *}
write_record_key() {   # usage: write_record_key <duration ms>
	{
		cat -- "$record_payload"
		printf 'SOAK_KEY_RESULT format=2 status=pass combinations=%d drivers=1 harnesses=6 duration_ms=%s inputs_sha256=%s source_commit=%s\n' \
			"${#record_names[@]}" "$1" "$record_key" "$record_commit"
	} >"$record_work/SOAK_KEY" || fail "could not write the record fixture key"
}
write_record_key 86400000

SOAK_NAMES=("${record_names[@]}")
record_dir="$record_work/soak"
release_soak_record_write "$record_dir" "$record_work/SOAK_KEY" "$record_evid" \
	"$record_commit" >"$output" 2>&1 \
	|| fail "the soak record writer refused a complete soak: $(<"$output")"
for record_base in "$RELEASE_SOAK_RECORD_KEY" "$RELEASE_SOAK_RECORD_INDEX" \
		"${record_bases[@]}"; do
	[ -f "$record_dir/$record_base" ] && [ ! -L "$record_dir/$record_base" ] \
		&& [ -s "$record_dir/$record_base" ] \
		|| fail "the soak record is missing $record_base"
done
[ ! -e "$record_dir.staging" ] \
	|| fail "the soak record writer left its staging directory behind"
checks=$((checks + 1))

# The index is the release's evidence index in the same format, so a reader that
# can check one can check the other.
grep -q "^EVIDENCE_INDEX format=2 source_commit=$record_commit\$" \
	"$record_dir/$RELEASE_SOAK_RECORD_INDEX" \
	|| fail "the soak record index carries no source-bound header"
grep -q "^EVIDENCE_INDEX_RESULT format=2 status=pass members=${#record_bases[@]} source_commit=$record_commit\$" \
	"$record_dir/$RELEASE_SOAK_RECORD_INDEX" \
	|| fail "the soak record index does not conclude with its member count"
record_rows=$(grep -c $'\t' "$record_dir/$RELEASE_SOAK_RECORD_INDEX") \
	|| fail "could not count soak record index rows"
[ "$record_rows" -eq "${#record_bases[@]}" ] \
	|| fail "the soak record index lists $record_rows members, not ${#record_bases[@]}"
grep -q $'^soak-build.log\tbuild\t' "$record_dir/$RELEASE_SOAK_RECORD_INDEX" \
	|| fail "the soak record index does not carry the build transcript under its declared role"
checks=$((checks + 1))

# Read back exactly what was declared, and answer the one question a release
# asks: are these the images, and were they soaked for long enough?
record_fields=$(release_soak_record_read "$record_dir") \
	|| fail "the soak record just written does not read back"
[ "$(printf '%s' "$record_fields" | cut -f1)" = "$record_key" ] \
	|| fail "the soak record reports a different key than it was written with"
[ "$(printf '%s' "$record_fields" | cut -f2)" = 86400000 ] \
	|| fail "the soak record reports a different duration than it was written with"
[ "$(printf '%s' "$record_fields" | cut -f3)" = "$record_commit" ] \
	|| fail "the soak record reports a different commit than it was written with"
release_soak_record_attests "$record_dir" "$record_key" 86400000 \
	|| fail "the soak record does not attest the inputs and duration it was written with"
release_soak_record_attests "$record_dir" "$record_key" 3600000 \
	|| fail "a 24-hour soak does not subsume a shorter requirement"
! release_soak_record_attests "$record_dir" "$record_key" 172800000 \
	|| fail "a 24-hour soak attested a 48-hour requirement"
! release_soak_record_attests "$record_dir" \
	0000000000000000000000000000000000000000000000000000000000000000 1 \
	|| fail "the soak record attested inputs it does not name"
! release_soak_record_attests "$work/no-such-record" "$record_key" 1 \
	|| fail "an absent soak record attested something"
checks=$((checks + 1))

# A record that has been damaged is not a record. Each of these is the whole
# difference between "soak first" and a release standing on nothing.
record_broken="$record_work/broken"
rm -rf "$record_broken"; cp -R "$record_dir" "$record_broken"
grep -v '^SOAK_KEY_RESULT ' "$record_dir/$RELEASE_SOAK_RECORD_KEY" \
	>"$record_broken/$RELEASE_SOAK_RECORD_KEY"
! release_soak_record_read "$record_broken" >/dev/null 2>&1 \
	|| fail "a record with no result line read back as valid"
cp -- "$record_dir/$RELEASE_SOAK_RECORD_KEY" "$record_broken/$RELEASE_SOAK_RECORD_KEY"
printf 'trailing junk\n' >>"$record_broken/$RELEASE_SOAK_RECORD_KEY"
! release_soak_record_read "$record_broken" >/dev/null 2>&1 \
	|| fail "a record whose result line is not last read back as valid"
sed 's/inputs_sha256=[0-9a-f]*/inputs_sha256=nothex/' \
	"$record_dir/$RELEASE_SOAK_RECORD_KEY" >"$record_broken/$RELEASE_SOAK_RECORD_KEY"
! release_soak_record_read "$record_broken" >/dev/null 2>&1 \
	|| fail "a record with a malformed key read back as valid"
sed 's/duration_ms=[0-9]*/duration_ms=0/' \
	"$record_dir/$RELEASE_SOAK_RECORD_KEY" >"$record_broken/$RELEASE_SOAK_RECORD_KEY"
! release_soak_record_read "$record_broken" >/dev/null 2>&1 \
	|| fail "a record claiming a zero-length soak read back as valid"
checks=$((checks + 1))

# An unsealed transcript must not reach the record. The writer aborts through
# the host's die, so the attempt is made where an exit cannot take this suite
# with it, and the previous record must survive untouched.
cp -- "$record_dir/$RELEASE_SOAK_RECORD_KEY" "$record_work/previous-key"
printf 'unsealed body\n' >"$record_evid/soak-build.log"
if (
	die() { printf 'FATAL %s\n' "$*" >&2; exit 1; }
	release_soak_record_write "$record_dir" "$record_work/SOAK_KEY" \
		"$record_evid" "$record_commit"
) >"$output" 2>&1; then
	fail "the soak record writer accepted a transcript carrying no evidence result"
fi
grep -Fq 'carries no evidence result' "$output" \
	|| fail "an unsealed transcript was refused without its diagnostic: $(<"$output")"
cmp -s "$record_work/previous-key" "$record_dir/$RELEASE_SOAK_RECORD_KEY" \
	|| fail "a refused record write damaged the record already in place"
checks=$((checks + 1))

# Overwritten in place, with git history as the archive: a second write replaces
# the first outright rather than accumulating beside it.
printf 'transcript body for soak-build.log\n' >"$record_evid/soak-build.log"
printf 'EVIDENCE_RESULT format=2 status=pass role=build evidence=soak-build.log lines=1 payload_sha256=%064d source_commit=%s\n' \
	0 "$record_commit" >>"$record_evid/soak-build.log"
printf 'stale member\n' >"$record_dir/soak-attiny202_cd4053_simple.log"
write_record_key 3600000
release_soak_record_write "$record_dir" "$record_work/SOAK_KEY" "$record_evid" \
	"$record_commit" >"$output" 2>&1 \
	|| fail "the soak record writer refused to overwrite an existing record: $(<"$output")"
[ ! -e "$record_dir/soak-attiny202_cd4053_simple.log" ] \
	|| fail "overwriting the soak record left a member of the previous one behind"
[ "$(release_soak_record_read "$record_dir" | cut -f2)" = 3600000 ] \
	|| fail "overwriting the soak record did not replace its attested duration"
unset RELEASE_EVIDENCE_ROLE SOAK_NAMES
unset -f die log ok
checks=$((checks + 1))

# --- the soak as its own goal ------------------------------------------------
# The producer is a mode of this script and a goal of its own, and it must never
# be able to masquerade as a release: it takes no version, stages nothing, and
# contradicts every other mode.
grep -Fq -- '--soak)               SOAK_ONLY=1; shift ;;' "$RELEASE" \
	|| fail "make-release.sh does not accept --soak"
# Every refusal below is decided in argument parsing, before the first Make
# query, tool probe or scratch directory, so the script is invoked directly
# rather than through the preflight harness -- which would prepend a --preflight
# of its own and report the wrong contradiction.
run_soak_args() {
	(
		unset VERSION RELEASE_ARGS MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKEOVERRIDES MAKELEVEL
		export TMPDIR="$work"
		export _MAKE_SERIAL_LOCK_HELD="$lock_id"
		"$RELEASE" "$@"
	)
}
for soak_conflict in --preflight --dry-run --express --reuse-soak; do
	if run_soak_args --soak "$soak_conflict" >"$output" 2>&1; then
		fail "the soak accepted the contradictory mode $soak_conflict"
	fi
	grep -Fq -- "--soak and $soak_conflict are mutually exclusive" "$output" \
		|| fail "--soak/$soak_conflict conflict failed for the wrong reason: $(<"$output")"
done
if run_soak_args --soak v1.2.3 >"$output" 2>&1; then
	fail "the soak accepted a release version"
fi
grep -Fq 'a soak record attests images, not a release' "$output" \
	|| fail "a versioned soak was refused without its diagnostic: $(<"$output")"
checks=$((checks + 1))

# The record is written before the shipped images are regenerated and before any
# staging, and that ordering is the contract: a soak must be unable to reach the
# phase that produces a release.
soak_record_line=$(grep -Fn 'release_soak_record_write "$SOAK_RECORD_DIR"' "$RELEASE" \
	| head -1 | cut -d: -f1)
regenerate_line=$(grep -Fn 'regenerating classic AVR HEX from the validated ELFs' "$RELEASE" \
	| head -1 | cut -d: -f1)
[ -n "$soak_record_line" ] && [ -n "$regenerate_line" ] \
	|| fail "could not locate the soak record write and the final image regeneration"
[ "$soak_record_line" -lt "$regenerate_line" ] \
	|| fail "the soak record is written after the release's final image regeneration"
grep -Fq 'RELEASE_MODE=soak' "$RELEASE" \
	|| fail "the soak does not record a mode of its own"
grep -Fq 'production|express|dry-run|soak)' "$ROOT/scripts/release-provenance.sh" \
	|| fail "the release output-path guard does not know the soak mode"
checks=$((checks + 1))

# The goal exists, is phony against the directory of the same name, and carries
# the same production-identity guards every other release goal does.
grep -Eq '^\.PHONY:.*[[:space:]]soak([[:space:]]|$)' "$ROOT/Makefile" \
	|| fail "the Makefile does not declare soak phony"
# Asked for from the clean environment an operator actually has: this gate runs
# inside a Make recipe, and the release guards correctly refuse the MAKE and
# lock variables that recipe exports around it.
soak_goal_recipe=$(env -i PATH="$PATH" HOME="$HOME" TMPDIR="$work" \
	make -s --no-print-directory -C "$ROOT" -n soak 2>&1) \
	|| fail "make -n soak failed: $soak_goal_recipe"
printf '%s\n' "$soak_goal_recipe" | grep -Fq -- 'make-release.sh --soak' \
	|| fail "the soak goal does not run the release script in soak mode: $soak_goal_recipe"
checks=$((checks + 1))

# --- the staging rehearsal ---------------------------------------------------
# The programming-command table and the per-image facts are functions of the
# image set, the Makefile and pre-soak resource evidence; none reads a soak
# result. They used to be evaluated in the staging phase, a day after their last
# input stopped changing, which is how v0.9.12 died in staging after a full soak
# had been paid for. They now run twice: once before the soak against the built
# images, discarding the output, and once for real at staging, which requires
# the two command tables to be byte-identical.
#
# Position is the contract, so position is what is asserted. A later edit that
# moves this material back after the soak reopens exactly the window it was
# moved out of, and does so silently.
soak_section_line=$(grep -Fn 'section "3. soak' "$RELEASE" | head -1 | cut -d: -f1)
stage_section_line=$(grep -Fn 'section "4. stage' "$RELEASE" | head -1 | cut -d: -f1)
flash_check_line=$(grep -Fn 'check_flash_commands() {' "$RELEASE" | head -1 | cut -d: -f1)
img_row_line=$(grep -Fn 'img_row() {' "$RELEASE" | head -1 | cut -d: -f1)
rehearsal_line=$(grep -Fn 'rehearsing the staged programming commands' "$RELEASE" \
	| head -1 | cut -d: -f1)
for rehearsal_step in "$soak_section_line" "$stage_section_line" \
		"$flash_check_line" "$img_row_line" "$rehearsal_line"; do
	[[ "$rehearsal_step" =~ ^[0-9]+$ ]] \
		|| fail "could not locate the staging rehearsal and the phases around it"
done
[ "$flash_check_line" -lt "$rehearsal_line" ] \
	&& [ "$img_row_line" -lt "$rehearsal_line" ] \
	&& [ "$rehearsal_line" -lt "$soak_section_line" ] \
	&& [ "$soak_section_line" -lt "$stage_section_line" ] \
	|| fail "the staged programming commands are not rehearsed before the soak"
checks=$((checks + 1))

# The rehearsal is only worth its seconds if staging is held to it.
grep -Fq 'cmp -s "$FLASHCMDS" "$REHEARSAL_FLASHCMDS"' "$RELEASE" \
	|| fail "staging does not require the published commands to match the rehearsed ones"
checks=$((checks + 1))

# Both call sites must be able to write somewhere other than the staged tree, or
# the rehearsal could not run before the staging directory exists.
grep -Fq 'FLASHCMDS="$WORK/flashcmds.txt"' "$RELEASE" \
	|| fail "make-release.sh does not carry a redirectable command-table path"
grep -Fq 'IMAGE_SUMS_FILE="$OUTPUT_DIR/SHA256SUMS"' "$RELEASE" \
	|| fail "make-release.sh does not carry a redirectable image-digest source"
checks=$((checks + 1))

# The required non-image artifacts are a property of the tree, so a helper that
# cannot be staged is a defect that was true before the build started. The
# staging loop is a function taking a destination, and the rehearsal runs it
# against the throwaway directory.
grep -Fq 'stage_release_helpers "$REHEARSAL_DIR"' "$RELEASE" \
	|| fail "make-release.sh does not rehearse staging the required release artifacts"
grep -Fq 'stage_release_helpers "$OUTPUT_DIR"' "$RELEASE" \
	|| fail "make-release.sh does not stage the required release artifacts for real"
checks=$((checks + 1))

# The toolchain record is written from captures taken in phase 0 and has never
# depended on a soak result -- yet it ran after the soak, which is what cost
# v0.9.12 its first attempt. Position is the fix, so position is asserted.
toolchain_write_line=$(grep -Fn '} > "$EVID/toolchain.txt"' "$RELEASE" | head -1 | cut -d: -f1)
[[ "$toolchain_write_line" =~ ^[0-9]+$ ]] \
	|| fail "could not locate the toolchain evidence record"
[ "$toolchain_write_line" -lt "$soak_section_line" ] \
	|| fail "the toolchain evidence record is still written after the soak"
checks=$((checks + 1))

# ---------------------------------------------------------------------------
# The PIC12F675 flashing contract.
#
# This part is the one target where "download the HEX and run your programmer"
# is wrong advice, because a bulk erase destroys per-device trim the image
# cannot supply. From v0.9.10 the answer is the helper the release bundles, and
# the raw command sequence is retired everywhere.
#
# The defect this pins already occurred in the opposite direction and the suite
# stayed green through it: README.md and release/README.md prohibited a raw
# writer while FLASHING.md published one, because only the GENERATED per-release
# guidance was contract-tested. So every case below spoils one property of a
# COPY of the shipped documents, and the last one runs against the live tree.
# ---------------------------------------------------------------------------
flashing_root="$work/pic12f675-flashing"
declare -F release_validate_pic12f675_flashing_helper >/dev/null \
	|| fail "PIC12F675 flashing-helper contract is missing"

write_flashing_fixture() {
	rm -rf "$flashing_root"
	mkdir -p "$flashing_root/scripts" "$flashing_root/release" "$flashing_root/docs"
	cp "$ROOT/FLASHING.md" "$flashing_root/FLASHING.md"
	cp "$ROOT/README.md" "$flashing_root/README.md"
	cp "$ROOT/release/README.md" "$flashing_root/release/README.md"
	cp "$ROOT/scripts/flash-pic12f675.py" "$flashing_root/scripts/flash-pic12f675.py"
	chmod 0755 "$flashing_root/scripts/flash-pic12f675.py"
	# Only the artifact binding is read out of the Makefile, so the fixture
	# carries that one line rather than a copy of an 8,000-line file.
	printf 'override RELEASE_HELPER_MAP := flash-pic12f675.py=scripts/flash-pic12f675.py\n' \
		> "$flashing_root/Makefile"
}

assert_flashing_accepts() {
	local description=$1
	release_validate_pic12f675_flashing_helper "$flashing_root" v1.2.3 >"$output" 2>&1 \
		|| fail "PIC12F675 flashing contract rejected $description: $(<"$output")"
	checks=$((checks + 1))
}

assert_flashing_rejects() {
	local description=$1 expected=$2
	if release_validate_pic12f675_flashing_helper "$flashing_root" v1.2.3 \
			>"$output" 2>&1; then
		fail "PIC12F675 flashing contract accepted $description"
	fi
	grep -Fq 'release documentation:' "$output" \
		|| fail "$description was rejected without a documentation diagnostic"
	grep -Fq "$expected" "$output" \
		|| fail "$description was rejected for the wrong reason: $(<"$output")"
	checks=$((checks + 1))
}

write_flashing_fixture
assert_flashing_accepts 'the shipped flashing documents'

# 1. The tool itself. Instructions that name a helper the release does not carry
#    are worse than no instructions: they read as safe and cannot be followed.
write_flashing_fixture
rm "$flashing_root/scripts/flash-pic12f675.py"
assert_flashing_rejects 'a missing flashing helper' \
	'PIC12F675 flashing helper is missing or not a regular file'

write_flashing_fixture
chmod 0644 "$flashing_root/scripts/flash-pic12f675.py"
assert_flashing_rejects 'a non-executable flashing helper' \
	'flashing helper is not executable'

write_flashing_fixture
printf 'override RELEASE_HELPER_MAP :=\n' > "$flashing_root/Makefile"
assert_flashing_rejects 'a helper that no release bundles' \
	'does not bind flash-pic12f675.py to scripts/flash-pic12f675.py'

# 2. Each publisher names the helper.
for missing_doc in FLASHING.md README.md release/README.md; do
	write_flashing_fixture
	"$REAL_AWK" '{ gsub(/flash-pic12f675\.py/, "some-other-tool.py"); print }' \
		"$ROOT/$missing_doc" > "$flashing_root/$missing_doc"
	assert_flashing_rejects "$missing_doc without the helper" \
		"$missing_doc does not name the release-shipped PIC12F675 flashing helper"
done

# 3. The reason the helper exists, in the two entry-point documents. "Typically"
#    and "needs no toolchain at all" are the escape clauses this replaces. The
#    claim is fenced and held to its terms, so the wording is the author's; what
#    may not go missing is the part, the interpreter, the helper, and the reason
#    -- that a per-device factory calibration must be preserved and verified.
for claim_doc in FLASHING.md README.md; do
	write_flashing_fixture
	"$REAL_AWK" '{ gsub(/factory calibration/, "factory settings"); print }' \
		"$ROOT/$claim_doc" > "$flashing_root/$claim_doc"
	assert_flashing_rejects "$claim_doc without the reason the helper is required" \
		"$claim_doc's pic12f675-helper-required block no longer states"
	write_flashing_fixture
	drop_claim_block_at "$flashing_root" "$claim_doc" pic12f675-helper-required
	assert_flashing_rejects "$claim_doc with no pic12f675-helper-required block" \
		"$claim_doc must carry exactly one well-formed pic12f675-helper-required block"
done

write_flashing_fixture
printf '\nNeeds only a programmer and its CLI.\n' >> "$flashing_root/FLASHING.md"
assert_flashing_rejects 'a reinstated universal claim' \
	'still publishes the retired universal claim'

# 4. The heading a reader skimming for this part actually lands on.
write_flashing_fixture
"$REAL_AWK" '{ sub(/^## PIC12F675 .*$/, "## PIC12F675"); print }' \
	"$ROOT/FLASHING.md" > "$flashing_root/FLASHING.md"
assert_flashing_rejects 'a heading that no longer states the rule' \
	'PIC12F675 heading does not state that it is not a raw write target'

# 5. The raw writer itself -- the exact block v0.9.9 published, restored.
write_flashing_fixture
{
	printf '\n## Restored raw block\n\n'
	printf '```\n'
	printf 'java -jar "$IPECMD" -TPPK3 -PPIC12F675 \\\n'
	printf '  -Fbypass-pic12f675-cd4053_simple.hex -M -Y -OL -W5\n'
	printf '```\n'
} >> "$flashing_root/FLASHING.md"
assert_flashing_rejects 'the restored raw ipecmd write' \
	'FLASHING.md publishes a raw PIC12F675 writer command'

write_flashing_fixture
{
	printf '\n## Restored raw block\n\n'
	printf '```\n'
	printf 'pk2cmd -PPIC12F675 -Fbypass-pic12f675-cd4053_simple.hex -M -Y -R\n'
	printf '```\n'
} >> "$flashing_root/release/README.md"
assert_flashing_rejects 'the restored raw pk2cmd write' \
	'release/README.md publishes a raw PIC12F675 writer command'

# A NEW document is covered the day it is written, not the day someone
# remembers to add it to a list.
write_flashing_fixture
{
	printf '# Field notes\n\n'
	printf '```\n'
	printf 'ipecmd -TPPK3 -PPIC12F675 -Fimage.hex -M -Y -OL\n'
	printf '```\n'
} > "$flashing_root/docs/field_notes.md"
assert_flashing_rejects 'a raw write in a newly written document' \
	'docs/field_notes.md publishes a raw PIC12F675 writer command'

# Reading a device is how an operator ARCHIVES its trim, and stays publishable.
# So does the helper invocation, which merely passes an ipecmd path.
write_flashing_fixture
{
	printf '# Field notes\n\n'
	printf '```\n'
	printf 'java -jar "$IPECMD" -TPPK3 -PPIC12F675 -GFfactory-12f675.hex\n'
	printf '```\n\n'
	printf '```sh\n'
	printf 'python3 flash-pic12f675.py program --image bypass-pic12f675-cd4053_simple.hex \\\n'
	printf '  --ipecmd /opt/mplabx/v6.20/ipecmd.jar --evidence-dir ./device-001\n'
	printf '```\n'
} > "$flashing_root/docs/field_notes.md"
assert_flashing_accepts 'a read-only export and the helper invocation'

# The forms the first-word-plus-bare-M rule did not see. Each is a way an
# operator would really write the same destructive command, and each one used to
# pass: the writer named by an install path or behind sudo or a variable, the
# `-MP`/`-E` selectors instead of a bare `-M`, and the three command CONTEXTS
# that are not a fenced Markdown block.
flashing_raw_case() {
	local description=$1 name=$2
	shift 2
	write_flashing_fixture
	printf '%s\n' "$@" > "$flashing_root/$name"
	assert_flashing_rejects "$description" \
		"$name publishes a raw PIC12F675 writer command"
}

flashing_raw_case 'a writer named by its full install path' docs/field_notes.md \
	'# Field notes' '' '```sh' \
	'/opt/microchip/mplabx/v6.20/mplab_platform/mplab_ipe/ipecmd.sh \' \
	'  -TPPK3 -PPIC12F675 -Fimage.hex -M -Y -OL' '```'

flashing_raw_case 'a writer behind sudo' docs/field_notes.md \
	'# Field notes' '' '```sh' \
	'sudo ipecmd -TPPK3 -PPIC12F675 -Fimage.hex -M -Y -OL' '```'

flashing_raw_case 'a writer behind a shell variable' docs/field_notes.md \
	'# Field notes' '' '```sh' \
	'"${IPECMD}" -TPPK3 -PPIC12F675 -Fimage.hex -M -Y -OL' '```'

flashing_raw_case 'the -MP program selector' docs/field_notes.md \
	'# Field notes' '' '```sh' \
	'ipecmd -TPPK3 -PPIC12F675 -Fimage.hex -MP -Y' '```'

flashing_raw_case 'a bulk erase' docs/field_notes.md \
	'# Field notes' '' '```sh' \
	'pk2cmd -PPIC12F675 -E' '```'

flashing_raw_case 'a raw write in an inline code span' docs/field_notes.md \
	'# Field notes' '' \
	'Program it with `ipecmd -TPPK3 -PPIC12F675 -Fimage.hex -M -Y` and reseat it.'

flashing_raw_case 'a raw write in an indented code block' docs/field_notes.md \
	'# Field notes' '' \
	'    ipecmd -TPPK3 -PPIC12F675 -Fimage.hex -M -Y -OL'

flashing_raw_case 'a raw write in an AsciiDoc listing block' docs/field_notes.adoc \
	'= Field notes' '' '[source,sh]' '----' \
	'ipecmd -TPPK3 -PPIC12F675 -Fimage.hex -M -Y -OL' '----'

# The same broadening must not swallow prose that NAMES the retired command in
# order to forbid it, nor the six parts that legitimately publish a one-liner.
write_flashing_fixture
{
	printf '# Field notes\n\n'
	printf 'Do not substitute a raw `pk2cmd` or `ipecmd` writer command for the\n'
	printf 'PIC12F675 helper; a bulk erase destroys the trim.\n\n'
	printf 'A `-M` flag programs the device, which is exactly what must not happen\n'
	printf 'here.\n\n'
	printf '```sh\n'
	printf 'pk2cmd -PPIC10F322 -Fbypass-pic10f322-cd4053_simple.hex -M -Y -R\n'
	printf '```\n'
} > "$flashing_root/docs/field_notes.md"
assert_flashing_accepts 'prose naming the retired form and another part'\''s one-liner'

# A current document that still says this part has no no-compiler path
# contradicts the four that publish the helper, whichever document it is.
flashing_state_case() {
	local description=$1 name=$2 sentence=$3
	write_flashing_fixture
	printf '# Notes\n\n%s\n' "$sentence" > "$flashing_root/$name"
	assert_flashing_rejects "$description" \
		"$name still publishes the superseded PIC12F675 state"
}

flashing_state_case 'the retired no-compiler-path claim' docs/field_notes.md \
	'The prebuilt file is reproducible, but there is not yet a no-compiler path that admits it to the transaction.'
flashing_state_case 'the retired direct-from-download claim' docs/field_notes.md \
	'It is the one place where a qualified direct-from-download path is not available today.'
flashing_state_case 'the retired checkout-and-toolchain claim' docs/field_notes.md \
	'Its guarded workflow requires a clean source checkout of the same release tag and the pinned XC8/DFP toolchain.'

# The three publishers are held to it too -- the reopened defect was one of them
# disagreeing with the other three.
write_flashing_fixture
printf '\n\nThere is not yet a no-compiler path for this part.\n' \
	>> "$flashing_root/release/README.md"
assert_flashing_rejects 'a publisher that contradicts the other three' \
	'release/README.md still publishes the superseded PIC12F675 state'

# Recording HOW that state was retired is not restating it: a document that
# says so in the past tense has to keep passing, or a pattern wide enough to
# catch the live claim would make the retirement undocumentable.
write_flashing_fixture
{
	printf '# Notes\n\n'
	printf 'The position was that no no-compiler path into the transaction had\n'
	printf 'been designed or gated yet. One has been, from v0.9.10.\n'
} > "$flashing_root/docs/history.md"
assert_flashing_accepts 'a past-tense record of the retired position'

# Shipped release directories are immutable artifacts of past releases and
# legitimately carry the retired raw block; branch-only working documents quote
# it in order to retire it. Both must be pruned, or the contract cannot be
# introduced at all.
write_flashing_fixture
mkdir -p "$flashing_root/release/v0.9.9"
{
	printf '```\n'
	printf 'java -jar "$IPECMD" -TPPK3 -PPIC12F675 -Fimage.hex -M -Y -OL\n'
	printf '```\n'
} > "$flashing_root/release/v0.9.9/MANIFEST.md"
for flashing_branch_doc in pre-v9.9.9-fixes.md v9.9.9-polish.md notes-on-bloat.md; do
	{
		printf '# %s\n\n' "${flashing_branch_doc%.md}"
		printf '> **Branch-only working document.** Deleted before the merge.\n\n'
		cat "$flashing_root/release/v0.9.9/MANIFEST.md"
	} > "$flashing_root/$flashing_branch_doc"
done
assert_flashing_accepts 'shipped release artifacts and branch-only working documents'

# The exemption is the declaration, not the location: the same block in an
# undeclared root-level document is a published raw writer command.
write_flashing_fixture
{
	printf '```\n'
	printf 'java -jar "$IPECMD" -TPPK3 -PPIC12F675 -Fimage.hex -M -Y -OL\n'
	printf '```\n'
} > "$flashing_root/notes.md"
assert_flashing_rejects 'an undeclared root-level document publishing a raw writer' \
	'notes.md'

# B6: the status the helper's procedure is published under. FLASHING.md
# published an ipecmd procedure while README.md and TOOLCHAIN.adoc said no
# ipecmd procedure was published at all, so a reader believing either one was
# misled about the other. Both halves are still held -- the status in every
# publisher, and the blanket denial banned everywhere.
#
# The status is a conjunction: published, AND software-tested, AND not
# hardware-qualified. It is required as one ordered pattern rather than as three
# keywords precisely so that dropping ONE part fails, which is what these cases
# check -- a block keeping two parts out of three is the original defect.
for status_doc in FLASHING.md README.md release/README.md; do
	write_flashing_fixture
	"$REAL_AWK" '{ gsub(/is published and software-tested/, "works"); print }' \
		"$ROOT/$status_doc" > "$flashing_root/$status_doc"
	assert_flashing_rejects "$status_doc without the helper status" \
		"$status_doc's pic12f675-helper-status block no longer states"
	# Rewritten through the fence rather than by a line-wise substitution: every
	# publisher wraps this sentence differently, and "...but it is not" /
	# "hardware-qualified." straddles a line break in two of the three.
	write_flashing_fixture
	reword_claim_block_at "$flashing_root" "$status_doc" pic12f675-helper-status \
		'The helper'"'"'s `ipecmd` route is published and software-tested, and it is hardware-qualified.'
	assert_flashing_rejects "$status_doc claiming the route is hardware-qualified" \
		"$status_doc's pic12f675-helper-status block no longer states"
	write_flashing_fixture
	drop_claim_block_at "$flashing_root" "$status_doc" pic12f675-helper-status
	assert_flashing_rejects "$status_doc with no pic12f675-helper-status block" \
		"$status_doc must carry exactly one well-formed pic12f675-helper-status block"
done

# ACCEPTED: the same three-part status, rewritten. This is the case that fails
# if the status is ever quietly re-pinned to a sentence.
write_flashing_fixture
reword_claim_block_at "$flashing_root" FLASHING.md pic12f675-helper-status \
	'That route is published here and has been software-tested end to end; it is still not hardware-qualified, and nothing below should be read as saying otherwise.'
assert_flashing_accepts 'a rewritten PIC12F675 helper status'

# The last spelling is the natural one for these documents -- every one of them
# writes the tool as a code span -- so a scan that blanked spans would let the
# most likely form straight through.
for denial in 'No ipecmd hardware procedure is published yet.' \
		'So no ipecmd user procedure is published.' \
		'There is no ipecmd procedure is published anywhere.' \
		'No `ipecmd` hardware procedure is published.'; do
	write_flashing_fixture
	printf '# Toolchain\n\n%s\n' "$denial" > "$flashing_root/docs/toolchain.md"
	assert_flashing_rejects "the blanket denial \"$denial\"" \
		'denies that any ipecmd procedure is published'
done

# A claim SCOPED to the Make route is true and must stay sayable, as must the
# accurate statement that the published route is not QUALIFIED. Neither is the
# retired form, and a contract that could not tell them apart would force the
# documents to say nothing at all about the Make route.
write_flashing_fixture
{
	printf '# Toolchain\n\n'
	printf 'This Make route offers no operator ipecmd procedure, and no safe\n'
	printf 'dual-programmer handoff has been validated.\n\n'
	printf 'No ipecmd hardware procedure is qualified.\n'
} > "$flashing_root/docs/toolchain.md"
assert_flashing_accepts 'a route-scoped denial and an unqualified-procedure statement'

# Argument guards: a caller mistake must not pass vacuously.
write_flashing_fixture
flashing_rc=0
release_validate_pic12f675_flashing_helper "$flashing_root" >"$output" 2>&1 \
	|| flashing_rc=$?
[ "$flashing_rc" -eq 2 ] \
	|| fail "PIC12F675 flashing contract accepted a missing version argument"
checks=$((checks + 1))
release_validate_pic12f675_flashing_helper "$flashing_root" 0.9.10 >"$output" 2>&1 \
	&& fail "PIC12F675 flashing contract accepted a version that is not vX.Y.Z"
grep -Fq 'requested version is not vX.Y.Z' "$output" \
	|| fail "an invalid version was rejected without its diagnostic: $(<"$output")"
checks=$((checks + 1))

# The live checked-in tree must satisfy the contract.
release_validate_pic12f675_flashing_helper "$ROOT" "$live_contract_version" \
	>"$output" 2>&1 \
	|| fail "the checked-in tree fails the PIC12F675 flashing contract at $live_contract_version: $(<"$output")"
checks=$((checks + 1))

# Run the real preflight against a shadow documentation root. A stale bounded
# declaration must stop the script before its first release-scratch mktemp.
write_documentation_fixture v1.2.30 21 18 six four
shadow_root="$work/stale-release-root"
mkdir -p "$shadow_root/scripts"
cp -R "$documentation_root/." "$shadow_root/"
cp "$ROOT/scripts/release-provenance.sh" \
	"$ROOT/scripts/release-soak.sh" \
	"$ROOT/scripts/release-documentation.sh" \
	"$ROOT/scripts/release-signing-policy.sh" \
	"$ROOT/scripts/flash-pic12f675.py" "$shadow_root/scripts/"
mktemp_marker="$work/release-mktemp-reached"
if TEST_RELEASE_REPO_ROOT="$shadow_root" TEST_MKTEMP_MARKER="$mktemp_marker" \
		run_preflight v1.2.3 >"$output" 2>&1; then
	fail "versioned preflight accepted stale bounded release documentation"
fi
grep -Fq 'current release documentation is not finalized for v1.2.3' "$output" \
	|| fail "stale full preflight failed without its finalization diagnostic"
[ ! -e "$mktemp_marker" ] \
	|| fail "stale release documentation reached release scratch creation"
assert_no_release_scratch
checks=$((checks + 1))

# The boundary is executable policy, not documentation: 3.7 is accepted, 3.6
# is rejected, and newer host Python has no upper cap. This pure comparison can
# be exercised even when the test host itself is the intentionally rejected 3.6.
PYTHONPATH="$ROOT/test" "$REAL_PYTHON" - <<'PY' \
	|| fail "Python minimum-version boundary regression failed"
import python_version

assert python_version.MINIMUM == (3, 7)
assert not python_version.is_supported((3, 6, 15))
assert python_version.is_supported((3, 7, 0))
assert python_version.is_supported((3, 14, 0))
PY
checks=$((checks + 1))

# The aggregate must reject an old host before any child gate starts, while the
# three gates that introduced the 3.7 API dependency must also reject it when
# invoked directly.
early_gates=$("$REAL_MAKE" --no-print-directory -s -C "$ROOT" print-TEST_GATES_EARLY) \
	|| fail "could not read the early gate inventory"
[ "${early_gates%% *}" = python-version-valid ] \
	|| fail "python-version-valid is not the first aggregate gate"
for target in test-makefile-name-contract test-variant-selector-guard \
		test-fuse-injection-contract; do
	grep -Eq "^${target}:.*python-version-valid" "$ROOT/Makefile" \
		|| fail "$target does not enforce the Python minimum when run directly"
done
checks=$((checks + 1))

# An old interpreter must be diagnosed before PyYAML or any child gate runs.
: > "$tool_log"
if TEST_PYTHON_TOO_OLD=1 run_preflight >"$output" 2>&1; then
	fail "preflight accepted Python 3.6"
fi
grep -Fq 'Python 3.7 or newer is required' "$output" \
	|| fail "old Python failed without the actionable minimum-version diagnostic"
grep -Fq 'found Python 3.6.8' "$output" \
	|| fail "old Python diagnostic omitted the detected version"
grep -Fxq 'python-minimum-check' "$tool_log" \
	|| fail "old-Python preflight did not execute the minimum-version probe"
if grep -Fxq 'yaml-import' "$tool_log"; then
	fail "old-Python preflight continued into the PyYAML child probe"
fi
assert_no_release_scratch
checks=$((checks + 1))

# --- host C compiler floor ---------------------------------------------------
# The C counterpart of the Python minimum above. GCC 9 and older report a FALSE
# narrowing on the PIC shells' OR-folded integrity checks, so every host gate
# that compiles firmware under -Werror -Wconversion fails on them over correct
# sources. The floor is PROBED, never assumed from a version string, so these
# checks drive the probe itself.
host_cc_gate="$ROOT/test/host_compiler_version.sh"
[ -x "$host_cc_gate" ] \
	|| fail "test/host_compiler_version.sh is missing or not executable"
"$host_cc_gate" >"$output" 2>&1 \
	|| fail "the compiler running this suite fails the floor it publishes: $(cat "$output")"
checks=$((checks + 1))

# The aggregate must diagnose an unusable compiler before any gate compiles,
# and the three shipping-source coverage gates -- the ones that actually break
# on an old GCC -- must do the same when invoked directly, outside `make test`.
read -r first_gate second_gate _rest <<<"$early_gates"
{ [ "$first_gate" = python-version-valid ] && [ "$second_gate" = host-compiler-valid ]; } \
	|| fail "the host-minimum gates are not the first two aggregate gates (got '$first_gate' '$second_gate')"
for target in pic10f322-coverage-check-fw pic12f675-coverage-check-fw \
		pic10f320-coverage-check-fw; do
	grep -Eq "^${target}:.*host-compiler-valid" "$ROOT/Makefile" \
		|| fail "$target does not enforce the host compiler minimum when run directly"
done
checks=$((checks + 1))

# Enforced floor and published floor cannot drift: bumping MINIMUM_GCC without
# republishing it (or the reverse) fails here rather than in a user's build.
minimum_gcc=$(sed -n 's/^MINIMUM_GCC=\([0-9][0-9]*\)$/\1/p' "$host_cc_gate")
[ -n "$minimum_gcc" ] \
	|| fail "could not read MINIMUM_GCC from test/host_compiler_version.sh"
# Matched against the document with its line wrapping collapsed: the published
# floor must survive a reflow of the paragraph that carries it.
# The property is that each document publishes the ENFORCED NUMBER beside a host
# gcc mention -- not that it uses one of two accepted sentences. This gate used
# to require `GCC <n> or newer` or `Minimum host gcc version: <n>` literally,
# which is the antipattern A2 retired everywhere else: "GCC 10+" and "at least
# GCC 10" publish the identical requirement and failed, teaching an author that
# the offence was wording rather than omission. `avr-gcc` is excluded because
# the floor is the HOST compiler's, and the number carries its own boundaries so
# a bumped floor fails rather than matching a version that merely contains it.
floor_gcc='(^|[^-[:alnum:]])(gcc|g\+\+)([^[:alnum:]]|$)'
floor_num="(^|[^0-9.])$minimum_gcc([^0-9.]|\$)"
floor_family="$floor_gcc[^0-9]{0,32}$minimum_gcc([^0-9.]|\$)|$floor_num[^0-9]{0,32}$floor_gcc"
for document in README.md TOOLCHAIN.adoc test/README.md; do
	tr '\n' ' ' < "$ROOT/$document" | tr -s '[:space:]' ' ' > "$work/floor-prose.txt"
	grep -Eqi -- "$floor_family" "$work/floor-prose.txt" \
		|| fail "$document does not publish the enforced host compiler floor (GCC $minimum_gcc)"
	checks=$((checks + 1))
done

# What the family must and must not accept, checked against the real prose so a
# fixture cannot drift away from the documents the rule guards. A bumped floor
# that nobody republished fails; a rewrite of the same floor passes; and a
# cross-compiler mention is not a host floor.
tr '\n' ' ' < "$ROOT/README.md" | tr -s '[:space:]' ' ' > "$work/floor-prose.txt"
sed -i "s/$minimum_gcc/$((minimum_gcc + 1))/g" "$work/floor-prose.txt"
if grep -Eqi -- "$floor_family" "$work/floor-prose.txt"; then
	fail "the host-floor rule accepted prose publishing a floor other than $minimum_gcc"
fi
checks=$((checks + 1))
printf 'Every lane needs a host C compiler (at least GCC %s, or Clang).\n' \
	"$minimum_gcc" > "$work/floor-prose.txt"
grep -Eqi -- "$floor_family" "$work/floor-prose.txt" \
	|| fail "the host-floor rule rejected a reworded publication of the same floor"
checks=$((checks + 1))
printf 'The cross build needs avr-gcc %s; the host compiler is unrelated.\n' \
	"$minimum_gcc" > "$work/floor-prose.txt"
if grep -Eqi -- "$floor_family" "$work/floor-prose.txt"; then
	fail "the host-floor rule read a cross-compiler mention as the host floor"
fi
checks=$((checks + 1))

# A compiler that rejects the construct is refused with an actionable
# diagnostic. The fake forwards EVERYTHING except the probe compile, so the
# version it reports is genuinely detected rather than fabricated by the fake.
fake_cc="$work/fake-old-cc"
cat > "$fake_cc" <<FAKE
#!/usr/bin/env bash
for arg in "\$@"; do
	case "\$arg" in
	*probe.c)
		echo "\$arg:13:13: error: conversion from 'int' to 'uint8_t' may change value [-Werror=conversion]" >&2
		exit 1
		;;
	esac
done
exec "$REAL_CC" "\$@"
FAKE
chmod +x "$fake_cc"
host_cc_rc=0
"$host_cc_gate" "$fake_cc" >"$output" 2>&1 || host_cc_rc=$?
[ "$host_cc_rc" -eq 1 ] \
	|| fail "an unusable host compiler was not rejected (rc=$host_cc_rc)"
grep -Fq "GCC $minimum_gcc or newer" "$output" \
	|| fail "old-compiler diagnostic omitted the required minimum"
grep -Fq "HOSTCC=gcc-$minimum_gcc" "$output" \
	|| fail "old-compiler diagnostic omitted the corrective action"
grep -Fq 'may change value' "$output" \
	|| fail "old-compiler diagnostic omitted the compiler's own explanation"
grep -Eq 'found (gcc|clang) [0-9]+\.' "$output" \
	|| fail "old-compiler diagnostic omitted the detected compiler and version"
checks=$((checks + 1))

# A compiler that is absent, and a malformed invocation, are distinguished from
# a compiler that is merely too old.
host_cc_rc=0
"$host_cc_gate" "$work/definitely-not-a-compiler" >"$output" 2>&1 || host_cc_rc=$?
[ "$host_cc_rc" -eq 1 ] \
	|| fail "a missing host compiler was not rejected (rc=$host_cc_rc)"
grep -Fq 'was not found' "$output" \
	|| fail "missing host compiler failed without its own diagnostic"
host_cc_rc=0
"$host_cc_gate" one two >"$output" 2>&1 || host_cc_rc=$?
[ "$host_cc_rc" -eq 2 ] \
	|| fail "host compiler gate did not reject a malformed invocation with rc 2"
checks=$((checks + 1))

# Independent missing capabilities are aggregated exactly as the real preflight
# aggregates its report. One run proves every diagnostic without paying for 74
# real Makefile parses per missing input.
if TEST_AVR_LIBC_FAIL=1 TEST_SIMAVR_LINK_FAIL=1 TEST_AWK_FAIL=1 \
		TEST_PIC_SOAK_CXX=missing-selected-pic10f322-cxx \
		TEST_PIC10F320_SOAK_CXX=missing-selected-pic10f320-cxx \
		TEST_YASIMAVR_IMPORT_FAIL=1 TEST_PYYAML_FAIL=1 \
		TEST_OBJDUMP=missing-selected-objdump TEST_IHEX_VALIDATOR=fake-tool \
		TEST_ANALYZE_CMD='missing-selected-analysis --checks=fake' \
		TEST_EXTRA_MAKE_VAR=PIC12F675_PYTHON=missing-selected-pic12f675-python \
		AVR_NM=missing-selected-avr-nm MUTATION_MAKE=missing-selected-make \
		run_preflight >"$output" 2>&1; then
	fail "preflight accepted an aggregated set of missing release capabilities"
fi
for diagnostic in \
	'avr-libc headers' \
	'simavr header/link capability' \
	'AWK must execute a basic program' \
	'missing-selected-pic10f322-cxx' \
	'selected by PIC_SOAK_CXX' \
	'missing-selected-pic10f320-cxx' \
	'selected by PIC10F320_SOAK_CXX' \
	'yasimavr target-module imports' \
	'PyYAML' \
	'missing-selected-objdump' \
	'nonempty executable Intel HEX validator file' \
	'missing-selected-analysis' \
	'missing-selected-pic12f675-python' \
	'selected by PIC12F675_PYTHON' \
	'missing-selected-avr-nm' \
	'missing-selected-make'; do
	grep -Fq "$diagnostic" "$output" \
		|| fail "aggregated preflight failure omitted diagnostic: $diagnostic"
done
assert_no_release_scratch
checks=$((checks + 1))

# Both independently selected C++/header lanes must compile and link the exact
# gpsim header surface consumed by the target harnesses.
if TEST_GPSIM_LINK_FAIL=1 run_preflight >"$output" 2>&1; then
	fail "preflight accepted unlinkable gpsim toolchains"
fi
grep -Fq 'PIC10F322 gpsim compile/link capability' "$output" \
	|| fail "failed PIC10F322 gpsim link probe lacked its lane-specific diagnostic"
grep -Fq 'PIC10F320 gpsim compile/link capability' "$output" \
	|| fail "failed PIC10F320 gpsim link probe lacked its lane-specific diagnostic"
assert_no_release_scratch
checks=$((checks + 1))

# Existence is insufficient for an interpreter. The old precheck skipped the
# import when -x was false, then reported that every tool was present.
chmod 640 "$toolchain/yasimavr/bin/python"
if run_preflight >"$output" 2>&1; then
	fail "preflight accepted a non-executable yasimavr interpreter"
fi
grep -Fq 'executable patched yasimavr interpreter' "$output" \
	|| fail "non-executable yasimavr failed without the executable-path diagnostic"
chmod 750 "$toolchain/yasimavr/bin/python"
assert_no_release_scratch
checks=$((checks + 1))

# An importable interpreter still does not say WHICH yasimavr this is. Version
# 0.1.6 reports 0.1.6 with or without the vendored patches, and the patches are
# what make the ATtiny202 soak mean anything -- three published images have no
# other dynamic evidence. A release that cannot name the build refuses rather
# than recording a version that does not identify it.
stamp="$toolchain/yasimavr/.yasimavr.stamp"
stamp_value=$(cat "$stamp")
mv "$stamp" "$stamp.hidden"
if run_preflight >"$output" 2>&1; then
	fail "preflight accepted a yasimavr venv with no build stamp"
fi
grep -Fq 'could not record the yasimavr provenance' "$output" \
	|| fail "a stampless yasimavr venv failed without the provenance diagnostic: $(<"$output")"
assert_no_release_scratch
checks=$((checks + 1))

# Empty is not a signature either, and neither is one that would smuggle a
# second row or a third column into the tab-separated evidence.
: > "$stamp"
if run_preflight >"$output" 2>&1; then
	fail "preflight accepted an empty yasimavr build stamp"
fi
grep -Fq 'could not record the yasimavr provenance' "$output" \
	|| fail "an empty yasimavr stamp failed without the provenance diagnostic"
checks=$((checks + 1))

printf '0.1.6\tsmuggled\n' > "$stamp"
if run_preflight >"$output" 2>&1; then
	fail "preflight accepted a yasimavr build stamp carrying a tab"
fi
grep -Fq 'could not record the yasimavr provenance' "$output" \
	|| fail "a tab-bearing yasimavr stamp failed without the provenance diagnostic"
checks=$((checks + 1))

printf '%s' "$stamp_value" > "$stamp"
rm -f "$stamp.hidden"
assert_no_release_scratch

# The ATtiny device spec alone is not a usable DFP; every mandatory build also
# consumes a REGULAR part avr/io header. A same-name directory must not pass.
rm "$toolchain/attiny-dfp/include/avr/iotn202.h"
mkdir "$toolchain/attiny-dfp/include/avr/iotn202.h"
if run_preflight >"$output" 2>&1; then
	fail "preflight accepted a directory as the ATtiny_DFP I/O header"
fi
grep -Fq 'ATtiny_DFP I/O header' "$output" \
	|| fail "non-file ATtiny I/O header failed without its specific diagnostic"
rmdir "$toolchain/attiny-dfp/include/avr/iotn202.h"
printf 'synthetic preflight fixture\n' > "$toolchain/attiny-dfp/include/avr/iotn202.h"
assert_no_release_scratch
checks=$((checks + 1))

# A regular path is still not a usable fetched pack artifact when extraction was
# truncated to zero bytes. The runtime and device library are linker inputs even
# though the Makefile's local skip probe historically checked only spec/header.
: > "$toolchain/attiny-dfp/gcc/dev/attiny202/avrxmega3/short-calls/crtattiny202.o"
: > "$toolchain/pic10f320-gpsim/stimuli.h"
if TEST_PIC10F320_DFP_INCLUDE="$work/missing-pic10f320-analysis-include" \
		run_preflight >"$output" 2>&1; then
	fail "preflight accepted truncated target toolchain inputs"
fi
grep -Fq 'ATtiny_DFP C runtime' "$output" \
	|| fail "empty ATtiny runtime failed without its specific diagnostic"
grep -Fq 'PIC10F320 analysis header' "$output" \
	|| fail "missing selected PIC10F320 analysis header lacked its diagnostic"
grep -Fq 'PIC10F320 gates; PIC10F320_SOAK_GPSIM_INC=' "$output" \
	|| fail "empty selected PIC10F320 gpsim header lacked its diagnostic"
printf 'synthetic preflight fixture\n' \
	> "$toolchain/attiny-dfp/gcc/dev/attiny202/avrxmega3/short-calls/crtattiny202.o"
printf 'synthetic preflight fixture\n' > "$toolchain/pic10f320-gpsim/stimuli.h"
assert_no_release_scratch
checks=$((checks + 1))

# A selected XC8 command may be a PATH name, exactly as the Make recipes allow.
TEST_PIC_CC=xc8-322-path run_preflight >"$output" 2>&1 \
	|| fail "preflight rejected a PATH-selected executable PIC_CC: $(<"$output")"
assert_no_release_scratch
checks=$((checks + 1))

# --------------------------------------------------------------------------
# The three image-defining compiler pins are EXACT.
#
# They were shell substring patterns, so any banner CONTAINING the pin
# satisfied them: `avr-gcc (GCC) 17.3.0` passed the 7.3.0 check and XC8
# `V3.100` passed the V3.10 check. A neighbouring version is precisely what a
# drifting host has, and every released image byte is gated on the exact
# compiler -- so the enforcement TOOLCHAIN.adoc and the release workflow header
# promise was wider than the code delivered.
#
# Each fake below differs from the compliant one ONLY in its version banner, so
# it clears every capability probe above and can fail at the pin alone. The
# selectors are exercised separately because they are separate checks against
# separately installed compilers; PIC12F675 rides PIC_CC with the PIC10F322.
pin_fake_avr="$fakebin/fake-avr-gcc-pin"
pin_fake_xc8="$toolchain/xc8-pin"

run_preflight_with_pin_fake() {
	local selector=$1 banner=$2
	case "$selector" in
		CC)
			write_avr_gcc_fake "$pin_fake_avr" "$banner"
			TEST_CC=fake-avr-gcc-pin run_preflight >"$output" 2>&1
			;;
		PIC_CC)
			write_xc8_fake "$pin_fake_xc8" "$banner"
			TEST_PIC_CC="$pin_fake_xc8" run_preflight >"$output" 2>&1
			;;
		PIC10F320_CC)
			write_xc8_fake "$pin_fake_xc8" "$banner"
			TEST_PIC10F320_CC="$pin_fake_xc8" run_preflight >"$output" 2>&1
			;;
		*) fail "unknown compiler selector in a pin case: $selector" ;;
	esac
}

assert_pin_rejects() {
	local selector=$1 banner=$2 note=$3
	if run_preflight_with_pin_fake "$selector" "$banner"; then
		fail "preflight accepted $note ($selector banner: $banner)"
	fi
	grep -Fq 'is not the pinned' "$output" \
		|| fail "$note was rejected without the version-pin diagnostic: $(<"$output")"
	grep -Fq "(via $selector)" "$output" \
		|| fail "$note: pin diagnostic did not name the selected tool and $selector: $(<"$output")"
	grep -Fq "observed banner:   $banner" "$output" \
		|| fail "$note: pin diagnostic did not quote the observed banner: $(<"$output")"
	grep -Fq 'expected version:  exactly' "$output" \
		|| fail "$note: pin diagnostic did not state the expected version: $(<"$output")"
	grep -Fq 'corrective action: install' "$output" \
		|| fail "$note: pin diagnostic did not state a corrective action: $(<"$output")"
	! grep -Fq 'preflight passed' "$output" \
		|| fail "$note printed the preflight success line after a pin rejection"
	assert_no_release_scratch
	checks=$((checks + 1))
}

assert_pin_accepts() {
	local selector=$1 banner=$2 note=$3
	run_preflight_with_pin_fake "$selector" "$banner" \
		|| fail "preflight rejected $note ($selector banner: $banner): $(<"$output")"
	grep -Fq 'preflight passed: this host can start a release.' "$output" \
		|| fail "$note did not reach the preflight success line: $(<"$output")"
	assert_no_release_scratch
	checks=$((checks + 1))
}

# Each end-to-end case costs a whole preflight, so this file proves the WIRING
# -- that all three selectors are separately pinned, that a rejection produces
# the operator-facing diagnostic, and that it happens before any scratch tree --
# while test_release_provenance.sh enumerates the banner forms directly against
# the comparison helper, where the cases are free.
#
# The first two are the exact collisions the substring patterns accepted.
assert_pin_rejects CC 'avr-gcc (GCC) 17.3.0' \
	'an avr-gcc whose version merely ends in the pin'
assert_pin_rejects PIC_CC 'Microchip MPLAB XC8 C Compiler V3.100' \
	'a PIC10F322/PIC12F675 XC8 whose version merely starts with the pin'
# The PIC10F320 compiler is a separate installation behind a separate selector,
# so its pin is proved separately: a green 322 check must not stand in for it.
assert_pin_rejects PIC10F320_CC 'Microchip MPLAB XC8 C Compiler V13.10' \
	'a PIC10F320 XC8 whose version merely ends in the pin'

# A compiler that answers --version with nothing never reaches the pin: the
# provenance probe rejects it first, and must say so in its own terms.
if run_preflight_with_pin_fake CC ''; then
	fail "preflight accepted a compiler that reports no version at all"
fi
grep -Fq 'returned no version line' "$output" \
	|| fail "a silent compiler was rejected without its provenance diagnostic: $(<"$output")"
grep -Fq 'could not record the AVR compiler provenance' "$output" \
	|| fail "a silent compiler did not fail the AVR provenance record: $(<"$output")"
assert_no_release_scratch
checks=$((checks + 1))

# Exactness is about the version TOKEN, not the whole banner: GCC's
# parenthesised packaging blob is not the compiler version and must neither be
# mistaken for it nor make the line ambiguous. This case also proves the
# generated fakes above are compliant in every respect except their banner --
# without it, a rejection could be some unrelated capability failure.
assert_pin_accepts CC 'avr-gcc (Ubuntu 7.3.0-16ubuntu3) 7.3.0' \
	'a pinned avr-gcc carrying a distributor packaging blob'

if TEST_GIT_STATUS_FAIL=1 run_preflight >"$output" 2>&1; then
	fail "preflight accepted a failed git status as a clean tree"
fi
grep -Fq 'could not inspect working-tree status' "$output" \
	|| fail "failed git status did not fail closed by name"
assert_no_release_scratch
checks=$((checks + 1))

TEST_GIT_LOCAL_TAG_FAIL=1 run_preflight "$current_release_version" >"$output" 2>&1 \
	|| fail "versioned preflight treated a failed local-tag query as a host-capability failure"
grep -Fq "could not check local tag $current_release_version (git rev-parse exited 74)." "$output" \
	|| fail "versioned preflight silently treated a local-tag query failure as absence"
assert_no_release_scratch
checks=$((checks + 1))

TEST_GIT_REMOTE_CONFIG_FAIL=1 run_preflight "$current_release_version" >"$output" 2>&1 \
	|| fail "versioned preflight treated failed origin inspection as a host-capability failure"
grep -Fq "could not inspect origin for tag $current_release_version (git remote get-url exited 73)." "$output" \
	|| fail "versioned preflight silently treated failed origin inspection as no remote"
assert_no_release_scratch
checks=$((checks + 1))

TEST_GIT_REMOTE_FAIL=1 run_preflight "$current_release_version" >"$output" 2>&1 \
	|| fail "versioned preflight treated an unavailable remote as a host-capability failure"
grep -Fq "could not check tag $current_release_version on origin (git ls-remote exited 72)." "$output" \
	|| fail "versioned preflight silently treated a remote failure as tag absence"
assert_no_release_scratch
checks=$((checks + 1))

TEST_GIT_NO_ORIGIN=1 run_preflight "$current_release_version" >"$output" 2>&1 \
	|| fail "versioned preflight rejected a repository without origin: $(<"$output")"
if grep -Fq 'could not inspect origin' "$output"; then
	fail "an absent origin was misreported as an operational failure"
fi
assert_no_release_scratch
checks=$((checks + 1))

# Existing output is publishing state. Even a regular-file conflict must warn
# without changing the host-capability verdict; the real release still rejects.
printf 'conflicting release leaf\n' > "$preflight_output"
run_preflight >"$output" 2>&1 \
	|| fail "preflight turned an existing output warning into a capability failure: $(<"$output")"
grep -Fq 'already exists; a real release would refuse to overwrite it.' "$output" \
	|| fail "existing preflight output did not produce its warning"
rm "$preflight_output"
assert_no_release_scratch
checks=$((checks + 1))

if run_preflight --dry-run >"$output" 2>&1; then
	fail "preflight accepted the contradictory --dry-run mode"
fi
grep -Fq -- '--preflight and --dry-run are mutually exclusive' "$output" \
	|| fail "preflight/dry-run conflict failed for the wrong reason"
checks=$((checks + 1))

# --express names what a release IS; --preflight and --dry-run both say it is
# not a release at all. Either combination would leave the recorded mode
# ambiguous, so both are refused before anything is built.
if run_preflight --express >"$output" 2>&1; then
	fail "preflight accepted the contradictory --express mode"
fi
grep -Fq -- '--preflight and --express are mutually exclusive' "$output" \
	|| fail "preflight/express conflict failed for the wrong reason"
checks=$((checks + 1))

# The mode-defining pair is refused first, so this reports the express/dry-run
# contradiction rather than the --preflight this helper always passes.
if run_preflight --express --dry-run >"$output" 2>&1; then
	fail "preflight accepted both --express and --dry-run"
fi
grep -Fq -- '--express and --dry-run are mutually exclusive' "$output" \
	|| fail "express/dry-run conflict failed for the wrong reason"
checks=$((checks + 1))

# Pin both consumers of an absolute venv. Step 0 above dynamically proves the
# absolute interpreter is found and imported; these assertions cover the two
# later paths that previously prepended the repository root to it.
grep -Fq 'export YASIMAVR_VENV="$(dirname "$(dirname "$YASIMAVR_PY_ABS")")"' "$RELEASE" \
	|| fail "ATtiny202 target qualification does not preserve an absolute yasimavr venv"
grep -Fq 'printf '\''  %q %q %q\n'\'' "$YASIMAVR_PY_ABS"' "$SOAK_LIB" \
	|| fail "ATtiny202 release soak wrapper does not execute the absolute yasimavr interpreter"
checks=$((checks + 1))

# The contract is that the selected command is qualified before use, not which
# helper does the qualifying: `command -v` and the path-aware
# mutation_command_is_available wrapper both satisfy it.
grep -Eq '(command -v|mutation_command_is_available) "\$PIC_SOAK_CXX"' "$MUTATION" \
	&& grep -Eq '(command -v|mutation_command_is_available) "\$PIC10F320_SOAK_CXX"' "$MUTATION" \
	&& grep -Fq '${XT_DFP:-${XT_DFP_ABS:-third_party/attiny_dfp}}' "$MUTATION" \
	&& grep -Fq '${YASIMAVR_VENV:-${XT_YASIMAVR_VENV_ABS:-third_party/yasimavr/venv}}' "$MUTATION" \
	&& grep -Fq 'PIC10F320_SOAK_GPSIM_INC="${PIC10F320_SOAK_GPSIM_INC:-$PIC_SOAK_GPSIM_INC}"' "$MUTATION" \
	|| fail "mutation qualification does not consume the selected PIC/AVR-XT tool paths"
grep -Fq 'PIC10F320_SOAK_GPSIM_INC="$PIC10F320_SOAK_GPSIM_INC"' "$RELEASE" \
	|| fail "release does not pass the selected PIC10F320 gpsim headers to test-long"
if grep -Eq '^[[:space:]]*mutation_bounded[[:space:]]+make[[:space:]]+-C' "$MUTATION"; then
	fail "a specialized mutation branch bypasses selected MUTATION_MAKE"
fi
checks=$((checks + 1))

# The Make target is intentionally versionless by default. Ask Make for the
# recipe without running it, under the already-held lock path used by recursion.
target_recipe=$(
	env -i PATH="$fakebin:$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-$HOME}" \
		_MAKE_SERIAL_LOCK_HELD="$lock_id" \
		"$REAL_MAKE" --no-print-directory -n -C "$ROOT" \
		CC=fake-tool release-preflight
)
[[ "$target_recipe" == *'./scripts/make-release.sh --preflight'* ]] \
	|| fail "make release-preflight does not route to the script's preflight mode"
checks=$((checks + 1))

# VERSION reaches the recipe through Make's exported command-line environment,
# never by textual interpolation into shell syntax.
shell_injection_marker="$work/version-shell-injection-ran"
make_injection_marker="$work/version-make-injection-ran"
if (
	unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL _MAKE_SERIAL_LOCK_HELD
	export PATH="$fakebin:$PATH"
	export REAL_MAKE REAL_PYTHON REAL_GIT REAL_AWK
	export FAKE_REPO_ROOT="$ROOT" FAKE_TOOLCHAIN="$toolchain" FAKE_BIN="$fakebin"
	export MAKE_LOG="$make_log" TOOL_LOG="$tool_log"
	env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-$HOME}" \
		"$REAL_MAKE" --no-print-directory -C "$ROOT" CC=fake-tool MAKE_COMMAND="$REAL_MAKE" \
		release-preflight VERSION="v1.2.3\$(shell touch $make_injection_marker)"
) >"$output" 2>&1; then
	fail "make release-preflight accepted a Make-function VERSION"
fi
[ ! -e "$make_injection_marker" ] \
	|| fail "make release-preflight expanded a Make function in VERSION"
grep -Fq 'must not contain dollar signs' "$output" \
	|| fail "Make-function VERSION failed for the wrong reason"
checks=$((checks + 1))

if (
	unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL _MAKE_SERIAL_LOCK_HELD
	export PATH="$fakebin:$PATH"
	env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-$HOME}" \
		"$REAL_MAKE" --no-print-directory -C "$ROOT" MAKE_COMMAND="$REAL_MAKE" \
		release-preflight VERSION="v1.2.3; touch $shell_injection_marker"
) >"$output" 2>&1; then
	fail "make release-preflight accepted a shell-metacharacter VERSION"
fi
[ ! -e "$shell_injection_marker" ] \
	|| fail "make release-preflight interpolated VERSION into shell syntax"
grep -Fq "is not vX.Y.Z" "$output" \
	|| fail "shell-metacharacter VERSION failed for the wrong reason"
checks=$((checks + 1))

release_args_shell_marker="$work/release-args-shell-injection-ran"
release_args_make_marker="$work/release-args-make-injection-ran"
if (
	unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL _MAKE_SERIAL_LOCK_HELD
	export PATH="$fakebin:$PATH"
	env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-$HOME}" \
		"$REAL_MAKE" --no-print-directory -C "$ROOT" MAKE_COMMAND="$REAL_MAKE" \
		release VERSION=v1.2.3 RELEASE_ARGS="\$(shell touch $release_args_make_marker)"
) >"$output" 2>&1; then
	fail "make release accepted a Make-function RELEASE_ARGS"
fi
[ ! -e "$release_args_make_marker" ] \
	|| fail "make release expanded a Make function in RELEASE_ARGS"
grep -Fq 'must not contain dollar signs' "$output" \
	|| fail "Make-function RELEASE_ARGS failed for the wrong reason"
checks=$((checks + 1))

if (
	unset MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKELEVEL _MAKE_SERIAL_LOCK_HELD
	export PATH="$fakebin:$PATH"
	env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-$HOME}" \
		"$REAL_MAKE" --no-print-directory -C "$ROOT" MAKE_COMMAND="$REAL_MAKE" \
		release VERSION=v1.2.3 \
		RELEASE_ARGS="--soak-duration-ms 0; touch $release_args_shell_marker"
) >"$output" 2>&1; then
	fail "make release accepted a shell-metacharacter RELEASE_ARGS"
fi
[ ! -e "$release_args_shell_marker" ] \
	|| fail "make release interpolated RELEASE_ARGS into shell syntax"
grep -Fq 'RELEASE_ARGS may contain options only' "$output" \
	|| fail "shell-metacharacter RELEASE_ARGS failed for the wrong reason"
checks=$((checks + 1))

: > "$make_log"
if (
	export PATH="$fakebin:$PATH" TEST_GIT_CLEAN=1
	export REAL_MAKE REAL_PYTHON REAL_GIT REAL_AWK
	export FAKE_REPO_ROOT="$ROOT" FAKE_TOOLCHAIN="$toolchain" FAKE_BIN="$fakebin"
	export MAKE_LOG="$make_log" TOOL_LOG="$tool_log"
	env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-$HOME}" \
		"$REAL_MAKE" --no-print-directory -C "$ROOT" CC=fake-tool \
		release VERSION=v1.2.3 RELEASE_ARGS=v9.9.9
) >"$output" 2>&1; then
	fail "RELEASE_ARGS silently overrode VERSION with a positional value"
fi
grep -Fq 'RELEASE_ARGS may contain options only' "$output" \
	|| fail "positional RELEASE_ARGS failed without its specific diagnostic"
if grep -Fq 'forbidden non-query Make invocation' "$make_log"; then
	fail "positional RELEASE_ARGS crossed the release build boundary"
fi
checks=$((checks + 1))

# Exercise the exact helper used at the production copy boundary. The cp shim
# can alter one source immediately before copying or one destination immediately
# after copying; both must fail before the caller can accept SHA256SUMS.
binding_bin="$work/binding-bin"
binding_source="$work/binding-source"
binding_stage="$work/binding-stage"
binding_marker="$work/binding-mutation.log"
binding_checksum="$work/SHA256SUMS.accepted"
mkdir -p "$binding_bin"
cat > "$binding_bin/cp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 4 ] && [ "$1" = -p ] && [ "$2" = -- ] \
	|| { printf 'unexpected release-binding cp arguments: %s\n' "$*" >&2; exit 91; }
source_image=$3
output_dir=${4%/}
if [ "${RELEASE_BINDING_MUTATION:-none}" = pre-copy ] \
		&& [ "${source_image##*/}" = "${RELEASE_BINDING_TARGET:?}" ]; then
	printf ':00000001FE\n' >> "$source_image"
	printf 'pre-copy\n' > "${RELEASE_BINDING_MARKER:?}"
fi
"${REAL_CP:?}" "$@"
if [ "${RELEASE_BINDING_MUTATION:-none}" = staged ] \
		&& [ "${source_image##*/}" = "${RELEASE_BINDING_TARGET:?}" ]; then
	printf ':00000001FD\n' >> "$output_dir/${source_image##*/}"
	printf 'staged\n' > "${RELEASE_BINDING_MARKER:?}"
fi
EOF
chmod 750 "$binding_bin/cp"

reset_binding_fixture() {
	rm -rf "$binding_source" "$binding_stage"
	mkdir -p "$binding_source" "$binding_stage/evidence"
	printf ':020000040000FA\n:020000000102FB\n:00000001FF\n' \
		> "$binding_source/bypass-attiny13a-cd4053_simple.hex"
	printf ':020000040000FA\n:020000000304F7\n:00000001FF\n' \
		> "$binding_source/bypass-attiny85-cd4053_simple.hex"
	rm -f "$binding_marker" "$binding_checksum"
}

binding_images=(
	"$binding_source/bypass-attiny13a-cd4053_simple.hex"
	"$binding_source/bypass-attiny85-cd4053_simple.hex"
)
binding_target=${binding_images[0]##*/}

reset_binding_fixture
binding_hashes=$(release_hash_classic_avr_images "${binding_images[@]}") \
	|| fail "could not hash valid classic-AVR binding fixtures"
if PATH="$binding_bin:$PATH" REAL_CP="$REAL_CP" \
		RELEASE_BINDING_MUTATION=none RELEASE_BINDING_TARGET="$binding_target" \
		RELEASE_BINDING_MARKER="$binding_marker" \
		release_stage_classic_avr_images "$binding_stage" "$binding_hashes" \
			"${binding_images[@]}"; then
	: > "$binding_checksum"
else
	fail "classic-AVR staging helper rejected byte-identical copies"
fi
if [ ! -f "$binding_checksum" ] || [ -e "$binding_marker" ]; then
	fail "valid classic-AVR staging did not reach the checksum boundary cleanly"
fi
checks=$((checks + 1))

reset_binding_fixture
binding_hashes=$(release_hash_classic_avr_images "${binding_images[@]}") \
	|| fail "could not hash pre-copy mutation fixtures"
if PATH="$binding_bin:$PATH" REAL_CP="$REAL_CP" \
		RELEASE_BINDING_MUTATION=pre-copy RELEASE_BINDING_TARGET="$binding_target" \
		RELEASE_BINDING_MARKER="$binding_marker" \
		release_stage_classic_avr_images "$binding_stage" "$binding_hashes" \
			"${binding_images[@]}"; then
	: > "$binding_checksum"
	fail "classic-AVR staging accepted a source mutation at the copy boundary"
fi
if [ ! -f "$binding_marker" ] || [ "$(<"$binding_marker")" != pre-copy ] \
		|| [ -e "$binding_checksum" ] \
		|| ! cmp -s "${binding_images[0]}" "$binding_stage/$binding_target"; then
	fail "pre-copy mutation did not fail before checksum acceptance for byte identity"
fi
checks=$((checks + 1))

reset_binding_fixture
binding_hashes=$(release_hash_classic_avr_images "${binding_images[@]}") \
	|| fail "could not hash staged-mutation fixtures"
if PATH="$binding_bin:$PATH" REAL_CP="$REAL_CP" \
		RELEASE_BINDING_MUTATION=staged RELEASE_BINDING_TARGET="$binding_target" \
		RELEASE_BINDING_MARKER="$binding_marker" \
		release_stage_classic_avr_images "$binding_stage" "$binding_hashes" \
			"${binding_images[@]}"; then
	: > "$binding_checksum"
	fail "classic-AVR staging accepted a post-copy destination mutation"
fi
if [ ! -f "$binding_marker" ] || [ "$(<"$binding_marker")" != staged ] \
		|| [ -e "$binding_checksum" ] \
		|| cmp -s "${binding_images[0]}" "$binding_stage/$binding_target"; then
	fail "staged-byte mutation did not fail before checksum acceptance for byte identity"
fi
checks=$((checks + 1))

printf 'release preflight validation: %d checks, 0 failures (%d Makefile queries)\n' \
	"$checks" "$query_count"
