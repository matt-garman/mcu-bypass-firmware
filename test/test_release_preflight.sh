#!/usr/bin/env bash
# Exercise the real release step 0 without starting a release, plus the
# source-loaded helper that binds final classic-AVR HEX bytes across staging.
# Every external selected release input is supplied by a throwaway fake
# toolchain; base host utilities and Make variable queries remain real. The
# preflight must reach the last version probe, execute no build goal, create no
# output directory, and leave tracked/nonignored worktree content unchanged on
# every tested path.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RELEASE="$ROOT/scripts/make-release.sh"
RELEASE_WORKFLOW="$ROOT/.github/workflows/release.yml"
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
# shellcheck source=scripts/release-provenance.sh
source "$ROOT/scripts/release-provenance.sh"
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
declare -F release_validate_hardware_claims >/dev/null \
	|| { printf 'FAIL: hardware evidence classifier is missing\n' >&2; exit 1; }
declare -F release_validate_pic12f675_flashing_helper >/dev/null \
	|| { printf 'FAIL: PIC12F675 flashing-helper contract is missing\n' >&2; exit 1; }
declare -F release_validate_flashing_simplicity_status >/dev/null \
	|| { printf 'FAIL: flashing-simplicity status contract is missing\n' >&2; exit 1; }
declare -F release_require_main_branch >/dev/null \
	|| { printf 'FAIL: release main-branch validator is missing\n' >&2; exit 1; }
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
		# testing the argument vector it actually passes.
		unset VERSION RELEASE_ARGS MAKEFLAGS MFLAGS GNUMAKEFLAGS MAKEOVERRIDES MAKELEVEL \
			STRICT_TOOLS MUTATION_ALLOW_SKIP XT_STATIC_RAM_LIMIT XT_STACK_MAX_FRAME \
			PIC12F675_DATA_LIMIT
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
[ "$query_count" -eq 91 ] \
	|| fail "preflight made $query_count Makefile queries, expected 91"
assert_no_release_scratch
checks=$((checks + 1))

# Versionless preflight remains a host-capability probe. Supplying a production
# version additionally exercises the actual checked-in documentation contract.
run_preflight v0.9.10 >"$output" 2>&1 \
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
	for document in release/README.md TODO.md docs/pic10f320_special_case.md \
			docs/pic10f320_validation.md; do
		cat > "$documentation_root/$document" <<EOF
<!-- current-release:start -->
$declaration
<!-- current-release:end -->
EOF
	done
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
	local document=$1 line=$2 target="$documentation_root/$document"
	awk -v line="$line" '
		$0 == "<!-- current-release:end -->" { print line }
		{ print }
	' "$target" > "$target.new" || fail "could not extend $document"
	mv "$target.new" "$target"
}

write_documentation_fixture v1.2.3 21 18 six four
declare_in_block TODO.md 'Evidence is retained under `release/v1.2.3/`.'
assert_documentation_rejected 'an undisclosed claim on the not-yet-staged release directory'

write_documentation_fixture v1.2.3 21 18 six four
declare_in_block TODO.md 'Evidence is retained under `release/v1.2.3/`.'
declare_in_block TODO.md "$transition_line"
release_validate_current_documentation "$documentation_root" v1.2.3 21 18 \
	|| fail "documentation validator rejected a disclosed pre-tag transition"
checks=$((checks + 1))

# The disclosure covers ONLY the version being released. Any other release
# directory a block names is evidence claimed to be retained now, so an abandoned
# or postponed cut cannot leave the claim standing behind the transition line.
write_documentation_fixture v1.2.3 21 18 six four
declare_in_block TODO.md 'Evidence is retained under `release/v1.2.2/`.'
declare_in_block TODO.md "$transition_line"
assert_documentation_rejected 'a bounded claim on a release directory that does not exist'

write_documentation_fixture v1.2.3 21 18 six four
mkdir -p "$documentation_root/release/v1.2.2"
declare_in_block TODO.md 'Evidence is retained under `release/v1.2.2/`.'
release_validate_current_documentation "$documentation_root" v1.2.3 21 18 \
	|| fail "documentation validator rejected a present retained-evidence directory"
checks=$((checks + 1))

# Historical prose outside the bounds stays unconstrained, as it is for every
# other field of the declaration.
write_documentation_fixture v1.2.3 21 18 six four
printf '%s\n' 'The abandoned `release/v9.9.9/` cut was never published.' \
	>> "$documentation_root/TODO.md"
release_validate_current_documentation "$documentation_root" v1.2.3 21 18 \
	|| fail "documentation validator treated prose outside the bounds as a declaration"
checks=$((checks + 1))

# release/README.md carries its block as a blockquote, so the transition line
# must be read through the same `> ` strip as the contract line.
write_documentation_fixture v1.2.3 21 18 six four
declare_in_block release/README.md '> Evidence is retained under `release/v1.2.3/`.'
declare_in_block release/README.md "> $transition_line"
release_validate_current_documentation "$documentation_root" v1.2.3 21 18 \
	|| fail "documentation validator did not read a blockquoted transition line"
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
declare_in_block TODO.md 'Evidence is retained under `release/v1.2.3/`.'
declare_in_block TODO.md "$transition_line"
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
# still REFERENCES a branch-only working document -- a root-level v*-polish.md,
# a root-level pre-v*-fixes.md, or any other root-level document outside the
# durable set. This gate is deliberately OUTSIDE
# release_validate_current_documentation -- the versioned preflight above
# legitimately validates the live polish branch, where such a document still
# exists during branch work -- and runs only on the real release-staging path
# (make-release.sh, after the preflight exit). Exercised here as a unit against
# throwaway trees.
branch_doc_root="$work/branch-only-doc"
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

# Every durable root-level document ships, and a root-level file that is not
# Markdown is not a document this gate governs at all.
for durable_doc in AGENTS.md CHANGELOG.md CLAUDE.md FLASHING.md \
	HARDWARE_VALIDATION_LOG.md MISRA_COMPLIANCE.md README.md TODO.md; do
	: > "$branch_doc_root/$durable_doc"
done
: > "$branch_doc_root/commit_msg.txt"
release_reject_branch_only_documents "$branch_doc_root" \
	|| fail "branch-only-document gate rejected the durable root-level document set"
checks=$((checks + 1))

# A root-level v*-polish.md present -> rejected.
: > "$branch_doc_root/v1.2.3-polish.md"
assert_branch_doc_gate_rejects 'a tree containing a root-level v*-polish.md' \
	'v1.2.3-polish.md'
rm -f "$branch_doc_root/v1.2.3-polish.md"

# ... and so is a pre-release fix list, whose name the polish pattern cannot
# see. That miss is the defect this case pins: one name pattern per working
# document is a blocklist, and the next document's name is never in it.
: > "$branch_doc_root/pre-v1.2.3-fixes.md"
assert_branch_doc_gate_rejects 'a tree containing a root-level pre-v*-fixes.md' \
	'pre-v1.2.3-fixes.md'
rm -f "$branch_doc_root/pre-v1.2.3-fixes.md"

# ... and so is a working document neither family anticipates, which is why the
# root document set is an allowlist rather than a pattern chase.
: > "$branch_doc_root/merge-notes.md"
assert_branch_doc_gate_rejects 'a tree containing a root-level document outside the durable set' \
	'outside the durable root-document set'
rm -f "$branch_doc_root/merge-notes.md"

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

# Against the LIVE repository the gate may fail only for the branch-only working
# document a polish branch legitimately carries -- never because a root-level
# document this project actually ships is missing from the durable set. That
# pins the allowlist to the real tree instead of letting it drift until the
# release-staging path is the first thing to notice.
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
	"$release_script" | head -1 | cut -d: -f1)
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
	"$release_script" | head -1 | cut -d: -f1)
[ -n "$qualification_call_line" ] && [ -n "$staged_call_line" ] && [ -n "$handoff_line" ] \
	|| fail "could not locate the staging, staged-documentation and hand-off steps in make-release.sh"
[ "$staged_call_line" -gt "$qualification_call_line" ] \
	|| fail "staged-documentation check must run AFTER staging is verified (check at line $staged_call_line, qualification at line $qualification_call_line)"
[ "$staged_call_line" -lt "$handoff_line" ] \
	|| fail "staged-documentation check must run BEFORE the commit/tag hand-off (check at line $staged_call_line, hand-off at line $handoff_line)"
checks=$((checks + 1))

# R3: a PUBLISHED PIC12F675 finalization command must carry the identity of the
# transaction it recovers. `make pic12f675-finalize` passes the CALLER-selected
# identity to the recovery oracle, which compares it against what the reservation
# recorded -- so a signed-release example missing PIC12F675_RELEASE_TAG rejects
# the transaction it claims to recover, and a development example carrying one
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

# Deleting the recovery instructions outright is a failure too: the two static
# documents are scanned whether or not discovery finds a command in them.
write_finalization_fixture
printf '%s\n' 'Programming is documented elsewhere.' > "$finalization_root/README.md"
assert_finalization_rejects 'a document that dropped its recovery instructions' \
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
release_validate_pic12f675_finalization "$ROOT" v0.9.10 >"$output" 2>&1 \
	|| fail "the checked-in tree fails the PIC12F675 finalization contract: $(<"$output")"
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
# Both must be pruned, or this contract cannot be introduced at all.
write_hardware_fixture
mkdir -p "$hardware_root/release/v0.9.9"
printf 'None of these designs has run on silicon.\n' \
	> "$hardware_root/release/v0.9.9/MANIFEST.md"
printf 'The old wording said it had never run on a device.\n' \
	> "$hardware_root/pre-v9.9.9-fixes.md"
printf 'The old wording said it had never run on a device.\n' \
	> "$hardware_root/v9.9.9-polish.md"
assert_hardware_accepts 'shipped release artifacts and branch-only working documents'

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

# 3. The precise claim, in the two entry-point documents. "Typically" and
#    "needs no toolchain at all" are the escape clauses this replaces.
for claim_doc in FLASHING.md README.md; do
	write_flashing_fixture
	"$REAL_AWK" '{ gsub(/PIC12F675 additionally requires Python 3/, "Some parts may require Python 3"); print }' \
		"$ROOT/$claim_doc" > "$flashing_root/$claim_doc"
	assert_flashing_rejects "$claim_doc without the exact programming claim" \
		"$claim_doc does not carry the exact downloaded-release programming claim"
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

# Recording HOW that state was retired is not restating it. The analysis in
# docs/flashing_simplicity.md does exactly this in the past tense, so a pattern
# wide enough to catch it would make the retirement undocumentable.
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
cp "$flashing_root/release/v0.9.9/MANIFEST.md" "$flashing_root/pre-v9.9.9-fixes.md"
cp "$flashing_root/release/v0.9.9/MANIFEST.md" "$flashing_root/v9.9.9-polish.md"
assert_flashing_accepts 'shipped release artifacts and branch-only working documents'

# B6: the status the helper's procedure is published under. FLASHING.md
# published an ipecmd procedure while README.md and TOOLCHAIN.adoc said no
# ipecmd procedure was published at all, so a reader believing either one was
# misled about the other. Both halves are now pinned -- the exact status
# sentence in every publisher, and the blanket denial banned everywhere.
for status_doc in FLASHING.md README.md release/README.md; do
	write_flashing_fixture
	"$REAL_AWK" '{ gsub(/route is published and software-tested/, "route works"); print }' \
		"$ROOT/$status_doc" > "$flashing_root/$status_doc"
	assert_flashing_rejects "$status_doc without the helper status sentence" \
		"$status_doc presents the PIC12F675 flashing helper without the exact published/software-tested/not-hardware-qualified status"
done

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
release_validate_pic12f675_flashing_helper "$ROOT" v1.2.3 >"$output" 2>&1 \
	|| fail "the checked-in tree fails the PIC12F675 flashing contract: $(<"$output")"
checks=$((checks + 1))

# ---------------------------------------------------------------------------
# B6: a preserved design discussion whose proposals have shipped.
#
# docs/flashing_simplicity.md is deliberately frozen in the present tense of the
# branch it was argued on, and two of its proposals were then built. It opened
# with "Nothing here is implemented" for the whole of the v0.9.10 candidate
# while its own body carried the update paragraphs recording what had been --
# including a paragraph describing an AVR fuse-before-build hazard that had been
# repaired. The banner is the line a reader stops at, so the banner and the two
# build-before-hardware statements are held to the body.
# ---------------------------------------------------------------------------
simplicity_root="$work/flashing-simplicity"
declare -F release_validate_flashing_simplicity_status >/dev/null \
	|| fail "flashing-simplicity status contract is missing"

write_simplicity_fixture() {
	rm -rf "$simplicity_root"
	mkdir -p "$simplicity_root/docs"
	cp "$ROOT/docs/flashing_simplicity.md" "$simplicity_root/docs/flashing_simplicity.md"
}

assert_simplicity_rejects() {
	local description=$1 expected=$2
	if release_validate_flashing_simplicity_status "$simplicity_root" \
			>"$output" 2>&1; then
		fail "flashing-simplicity contract accepted $description"
	fi
	grep -Fq "$expected" "$output" \
		|| fail "$description was rejected for the wrong reason: $(<"$output")"
	checks=$((checks + 1))
}

write_simplicity_fixture
release_validate_flashing_simplicity_status "$simplicity_root" >"$output" 2>&1 \
	|| fail "flashing-simplicity contract rejected the shipped document: $(<"$output")"
checks=$((checks + 1))

write_simplicity_fixture
"$REAL_AWK" '{ sub(/^\*\*Status:\*\* .*$/, "**Status:** analysis and proposal. **Nothing here is implemented.** This"); print }' \
	"$ROOT/docs/flashing_simplicity.md" > "$simplicity_root/docs/flashing_simplicity.md"
assert_simplicity_rejects 'a banner denying implementation the body records' \
	'still says nothing here is implemented'

# The version, not merely the word "implemented": a banner that says something
# shipped without saying which release leaves the reader unable to date it.
write_simplicity_fixture
"$REAL_AWK" '
	/^\*\*Status:\*\*/ { inbanner = 1 }
	inbanner && /^[[:space:]]*$/ { inbanner = 0 }
	inbanner { gsub(/v[0-9]+\.[0-9]+\.[0-9]+/, "a later release") }
	{ print }
' "$ROOT/docs/flashing_simplicity.md" > "$simplicity_root/docs/flashing_simplicity.md"
assert_simplicity_rejects 'a banner that names no shipped version' \
	'implementation updates its status banner does not name'

# The two build-before-hardware statements. Unmarked, each reads as an open
# hardware-safety defect: a failed build leaving changed AVR fuses behind.
write_simplicity_fixture
"$REAL_AWK" '
	/before either hardware side effect/ { skip = NR }
	skip && NR > skip && NR <= skip + 12 { gsub(/v[0-9]+\.[0-9]+\.[0-9]+/, "some release") }
	{ print }
' "$ROOT/docs/flashing_simplicity.md" > "$simplicity_root/docs/flashing_simplicity.md"
assert_simplicity_rejects 'an unacknowledged build-before-hardware defect' \
	'without acknowledging the release that repaired it'

write_simplicity_fixture
"$REAL_AWK" '
	/\*\*Repair build-before-hardware semantics\.\*\*/ { skip = NR }
	skip && NR >= skip && NR <= skip + 8 { gsub(/v[0-9]+\.[0-9]+\.[0-9]+/, "some release") }
	{ print }
' "$ROOT/docs/flashing_simplicity.md" > "$simplicity_root/docs/flashing_simplicity.md"
assert_simplicity_rejects 'an unacknowledged repair proposal' \
	'without acknowledging the release that did'

# The anchors themselves must exist: deleting the statement is not a way to
# satisfy a contract that the statement be qualified.
write_simplicity_fixture
"$REAL_AWK" '!/before either hardware side effect/ { print }' \
	"$ROOT/docs/flashing_simplicity.md" > "$simplicity_root/docs/flashing_simplicity.md"
assert_simplicity_rejects 'a deleted build-before-hardware statement' \
	'no longer states the build-before-hardware defect'

write_simplicity_fixture
"$REAL_AWK" '!/\*\*Repair build-before-hardware semantics\.\*\*/ { print }' \
	"$ROOT/docs/flashing_simplicity.md" > "$simplicity_root/docs/flashing_simplicity.md"
assert_simplicity_rejects 'a deleted sequencing step' \
	'no longer carries the build-before-hardware sequencing step'

write_simplicity_fixture
rm "$simplicity_root/docs/flashing_simplicity.md"
assert_simplicity_rejects 'a missing document' \
	'is not a regular nonempty file'

simplicity_rc=0
release_validate_flashing_simplicity_status >"$output" 2>&1 || simplicity_rc=$?
[ "$simplicity_rc" -eq 2 ] \
	|| fail "flashing-simplicity contract accepted a missing repository-root argument"
checks=$((checks + 1))

release_validate_flashing_simplicity_status "$ROOT" >"$output" 2>&1 \
	|| fail "the checked-in tree fails the flashing-simplicity status contract: $(<"$output")"
checks=$((checks + 1))

# Run the real preflight against a shadow documentation root. A stale bounded
# declaration must stop the script before its first release-scratch mktemp.
write_documentation_fixture v1.2.30 21 18 six four
shadow_root="$work/stale-release-root"
mkdir -p "$shadow_root/scripts"
cp -R "$documentation_root/." "$shadow_root/"
cp "$ROOT/scripts/release-provenance.sh" \
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
for document in README.md TOOLCHAIN.adoc test/README.md; do
	tr '\n' ' ' < "$ROOT/$document" | tr -s '[:space:]' ' ' > "$work/floor-prose.txt"
	grep -Fq "GCC $minimum_gcc or newer" "$work/floor-prose.txt" \
		|| grep -Fq "Minimum host gcc version: $minimum_gcc" "$work/floor-prose.txt" \
		|| fail "$document does not publish the enforced host compiler floor (GCC $minimum_gcc)"
done
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

TEST_GIT_LOCAL_TAG_FAIL=1 run_preflight v0.9.10 >"$output" 2>&1 \
	|| fail "versioned preflight treated a failed local-tag query as a host-capability failure"
grep -Fq 'could not check local tag v0.9.10 (git rev-parse exited 74).' "$output" \
	|| fail "versioned preflight silently treated a local-tag query failure as absence"
assert_no_release_scratch
checks=$((checks + 1))

TEST_GIT_REMOTE_CONFIG_FAIL=1 run_preflight v0.9.10 >"$output" 2>&1 \
	|| fail "versioned preflight treated failed origin inspection as a host-capability failure"
grep -Fq 'could not inspect origin for tag v0.9.10 (git remote get-url exited 73).' "$output" \
	|| fail "versioned preflight silently treated failed origin inspection as no remote"
assert_no_release_scratch
checks=$((checks + 1))

TEST_GIT_REMOTE_FAIL=1 run_preflight v0.9.10 >"$output" 2>&1 \
	|| fail "versioned preflight treated an unavailable remote as a host-capability failure"
grep -Fq 'could not check tag v0.9.10 on origin (git ls-remote exited 72).' "$output" \
	|| fail "versioned preflight silently treated a remote failure as tag absence"
assert_no_release_scratch
checks=$((checks + 1))

TEST_GIT_NO_ORIGIN=1 run_preflight v0.9.10 >"$output" 2>&1 \
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

# Pin both consumers of an absolute venv. Step 0 above dynamically proves the
# absolute interpreter is found and imported; these assertions cover the two
# later paths that previously prepended the repository root to it.
grep -Fq 'export YASIMAVR_VENV="$(dirname "$(dirname "$YASIMAVR_PY_ABS")")"' "$RELEASE" \
	|| fail "ATtiny202 target qualification does not preserve an absolute yasimavr venv"
grep -Fq 'printf '\''  %q %q %q\n'\'' "$YASIMAVR_PY_ABS"' "$RELEASE" \
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
[[ $(grep -cF 'XT_STATIC_RAM_LIMIT=16' "$RELEASE") -eq 4 ]] \
	|| fail "release does not pin the 16-byte AVR-XT static-RAM policy at every build/qualification consumer"
[[ $(grep -cF 'XT_STACK_MAX_FRAME=32' "$RELEASE") -eq 3 ]] \
	|| fail "release does not pin the 32-byte AVR-XT frame policy at every qualification consumer"
[[ $(grep -cF 'PIC12F675_DATA_LIMIT=48' "$RELEASE") -eq 3 ]] \
	|| fail "release does not pin the 48-byte PIC12F675 Data-space policy at every build/qualification consumer"
[[ $(grep -cF 'XT_STATIC_RAM_LIMIT=16' "$RELEASE_WORKFLOW") -eq 4 ]] \
	|| fail "tag workflow does not pin the 16-byte AVR-XT static-RAM policy at every build/qualification consumer"
[[ $(grep -cF 'XT_STACK_MAX_FRAME=32' "$RELEASE_WORKFLOW") -eq 3 ]] \
	|| fail "tag workflow does not pin the 32-byte AVR-XT frame policy at every qualification consumer"
[[ $(grep -cF 'PIC12F675_DATA_LIMIT=48' "$RELEASE_WORKFLOW") -eq 3 ]] \
	|| fail "tag workflow does not pin the 48-byte PIC12F675 Data-space policy at every build/qualification consumer"
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
