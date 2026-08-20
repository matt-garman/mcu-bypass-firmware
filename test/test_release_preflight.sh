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

fail() {
	printf 'FAIL: %s\n' "$*" >&2
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
# now HARD FAILS at preflight on avr-gcc drift (the image-defining compiler), so
# the happy path needs a compliant version banner -- mirroring the xc8-322/320
# fakes that already report V3.10. It still carries fake-tool's avr-libc
# preprocess probe (-mmcu=attiny13a -E) so header-missing injection still works.
cat > "$fakebin/fake-avr-gcc" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
	printf 'avr-gcc (GCC) 7.3.0\n'
	printf 'Copyright (C) 2017 Free Software Foundation, Inc.\n'
fi
if [[ " $* " == *" -mmcu=attiny13a "* ]] && [[ " $* " == *" -E "* ]]; then
	[ "${TEST_AVR_LIBC_FAIL:-0}" -eq 0 ] || exit 81
fi
exit 0
EOF

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
if [ "${1:-}" = --no-fork ]; then shift; fi
[ "$#" -ge 2 ] || exit 90
shift
exec "$@"
EOF

cat > "$toolchain/xc8-322" <<'EOF'
#!/usr/bin/env bash
printf 'Microchip MPLAB XC8 C Compiler V3.10\n'
EOF
cat > "$toolchain/xc8-320" <<'EOF'
#!/usr/bin/env bash
printf 'Microchip MPLAB XC8 C Compiler V3.10\n'
EOF

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
	print-*) goal=$3 ;;
	*)
		printf 'forbidden non-query Make invocation: %s\n' "$*" >> "${MAKE_LOG:?}"
		exit 97
		;;
esac
printf '%s\n' "$goal" >> "${MAKE_LOG:?}"
exec "${REAL_MAKE:?}" --no-print-directory -s -C "${FAKE_REPO_ROOT:?}" \
	CC=fake-avr-gcc OBJCOPY=fake-tool SIZE=fake-tool HOSTCC=fake-tool \
	OBJDUMP="${TEST_OBJDUMP:-fake-tool}" READELF=fake-tool \
	IHEX_VALIDATOR="${TEST_IHEX_VALIDATOR:-${FAKE_BIN:?}/fake-tool}" AWK="${FAKE_BIN:?}/fake-awk" \
	CLANG=fake-tool CLANG_TIDY=fake-tool CPPCHECK=fake-tool CBMC=fake-tool \
	GCOV=fake-tool GPSIM=fake-tool \
	PIC_CC="${TEST_PIC_CC:-${FAKE_TOOLCHAIN:?}/xc8-322}" \
	PIC10F320_CC="${FAKE_TOOLCHAIN:?}/xc8-320" \
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
	"$goal"
EOF
chmod 750 "$fakebin/make"

[ ! -e "$preflight_output" ] \
	|| fail "reserved preflight output fixture already exists: $preflight_output"
OUTPUT_PATH_OWNED=1

run_preflight() {
	local status_before status_after output_existed_before output_existed_after rc
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
		unset VERSION RELEASE_ARGS
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
[ "$query_count" -eq 82 ] \
	|| fail "preflight made $query_count Makefile queries, expected 82"
assert_no_release_scratch
checks=$((checks + 1))

# Versionless preflight remains a host-capability probe. Supplying a production
# version additionally exercises the actual checked-in documentation contract.
run_preflight v0.9.9 >"$output" 2>&1 \
	|| fail "valid versioned preflight failed: $(<"$output")"
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

# H1: the actual release-staging path must refuse a tree that still CONTAINS or
# still REFERENCES a branch-only working document (root-level v*-polish.md). This
# gate is deliberately OUTSIDE release_validate_current_documentation -- the
# versioned preflight above legitimately validates the live polish branch, where
# the document still exists during branch work -- and runs only on the real
# release-staging path (make-release.sh, after the preflight exit). Exercised
# here as a unit against throwaway trees.
polish_root="$work/branch-only-doc"
assert_polish_gate_rejects() {
	local description=$1
	if release_reject_branch_only_documents "$polish_root" >"$output" 2>&1; then
		fail "branch-only-document gate accepted $description"
	fi
	grep -Fq 'release documentation:' "$output" \
		|| fail "$description was rejected without a diagnostic"
	checks=$((checks + 1))
}

rm -rf "$polish_root"; mkdir -p "$polish_root/docs"
# A clean tree passes.
release_reject_branch_only_documents "$polish_root" \
	|| fail "branch-only-document gate rejected a clean release tree"
checks=$((checks + 1))

# The retained docs/<ver>_post_release_polish.md must NOT be mistaken for a
# branch-only document: it is under docs/ (not root) and uses `_polish`, not
# `-polish`.
: > "$polish_root/docs/v0.9.6_post_release_polish.md"
release_reject_branch_only_documents "$polish_root" \
	|| fail "branch-only-document gate wrongly flagged the retained docs/ polish document"
checks=$((checks + 1))

# A root-level v*-polish.md present -> rejected.
: > "$polish_root/v1.2.3-polish.md"
assert_polish_gate_rejects 'a tree containing a root-level v*-polish.md'
rm -f "$polish_root/v1.2.3-polish.md"

# A durable file naming such a document -> rejected (the reference would dangle
# once the document is deleted).
printf 'See `v1.2.3-polish.md` item F1 for context.\n' > "$polish_root/docs/notes.md"
assert_polish_gate_rejects 'a durable reference to a branch-only v*-polish.md'
rm -f "$polish_root/docs/notes.md"

# ... and the tree passes again once both violations are gone.
release_reject_branch_only_documents "$polish_root" \
	|| fail "branch-only-document gate rejected a tree after the violations were removed"
checks=$((checks + 1))

# Discovery failures are policy failures, not an empty result set.
if gate_diagnostic=$(find() { return 73; }; release_reject_branch_only_documents "$polish_root" 2>&1); then
	fail "branch-only-document gate accepted a failed document scan"
fi
[[ "$gate_diagnostic" == *"could not scan for branch-only polish documents"* ]] \
	|| fail "failed branch-document scan produced the wrong diagnostic: $gate_diagnostic"
checks=$((checks + 1))
if gate_diagnostic=$(grep() { return 74; }; release_reject_branch_only_documents "$polish_root" 2>&1); then
	fail "branch-only-document gate accepted a failed reference scan"
fi
[[ "$gate_diagnostic" == *"could not scan for branch-only polish-document references"* ]] \
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

# Run the real preflight against a shadow documentation root. A stale bounded
# declaration must stop the script before its first release-scratch mktemp.
write_documentation_fixture v1.2.30 21 18 six four
shadow_root="$work/stale-release-root"
mkdir -p "$shadow_root/scripts"
cp -R "$documentation_root/." "$shadow_root/"
cp "$ROOT/scripts/release-provenance.sh" \
	"$ROOT/scripts/release-documentation.sh" \
	"$ROOT/scripts/release-signing-policy.sh" "$shadow_root/scripts/"
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

# Independent missing capabilities are aggregated exactly as the real preflight
# aggregates its report. One run proves every diagnostic without paying for 74
# real Makefile parses per missing input.
if TEST_AVR_LIBC_FAIL=1 TEST_SIMAVR_LINK_FAIL=1 TEST_AWK_FAIL=1 \
		TEST_PIC_SOAK_CXX=missing-selected-pic10f322-cxx \
		TEST_PIC10F320_SOAK_CXX=missing-selected-pic10f320-cxx \
		TEST_YASIMAVR_IMPORT_FAIL=1 TEST_PYYAML_FAIL=1 \
		TEST_OBJDUMP=missing-selected-objdump TEST_IHEX_VALIDATOR=fake-tool \
		TEST_ANALYZE_CMD='missing-selected-analysis --checks=fake' \
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

if TEST_GIT_STATUS_FAIL=1 run_preflight >"$output" 2>&1; then
	fail "preflight accepted a failed git status as a clean tree"
fi
grep -Fq 'could not inspect working-tree status' "$output" \
	|| fail "failed git status did not fail closed by name"
assert_no_release_scratch
checks=$((checks + 1))

TEST_GIT_LOCAL_TAG_FAIL=1 run_preflight v0.9.9 >"$output" 2>&1 \
	|| fail "versioned preflight treated a failed local-tag query as a host-capability failure"
grep -Fq 'could not check local tag v0.9.9 (git rev-parse exited 74).' "$output" \
	|| fail "versioned preflight silently treated a local-tag query failure as absence"
assert_no_release_scratch
checks=$((checks + 1))

TEST_GIT_REMOTE_CONFIG_FAIL=1 run_preflight v0.9.9 >"$output" 2>&1 \
	|| fail "versioned preflight treated failed origin inspection as a host-capability failure"
grep -Fq 'could not inspect origin for tag v0.9.9 (git remote get-url exited 73).' "$output" \
	|| fail "versioned preflight silently treated failed origin inspection as no remote"
assert_no_release_scratch
checks=$((checks + 1))

TEST_GIT_REMOTE_FAIL=1 run_preflight v0.9.9 >"$output" 2>&1 \
	|| fail "versioned preflight treated an unavailable remote as a host-capability failure"
grep -Fq 'could not check tag v0.9.9 on origin (git ls-remote exited 72).' "$output" \
	|| fail "versioned preflight silently treated a remote failure as tag absence"
assert_no_release_scratch
checks=$((checks + 1))

TEST_GIT_NO_ORIGIN=1 run_preflight v0.9.9 >"$output" 2>&1 \
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
if grep -Eq '^[[:space:]]*mutation_bounded[[:space:]]+make[[:space:]]+-C' "$MUTATION"; then
	fail "a specialized mutation branch bypasses selected MUTATION_MAKE"
fi
checks=$((checks + 1))

# The Make target is intentionally versionless by default. Ask Make for the
# recipe without running it, under the already-held lock path used by recursion.
target_recipe=$(
	export _MAKE_SERIAL_LOCK_HELD="$lock_id"
	PATH="$fakebin:$PATH" "$REAL_MAKE" --no-print-directory -n -C "$ROOT" \
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
