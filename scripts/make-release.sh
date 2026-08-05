#!/usr/bin/env bash
#
# make-release.sh -- build, exhaustively validate, and STAGE a prebuilt
# firmware release for this project.
#
# WHY THIS EXISTS
#   The firmware's whole value proposition is trust: an extensive test and
#   validation suite backs the SOURCE. This script extends that same confidence
#   to PREBUILT BINARIES so that someone who just wants to flash a chip does not
#   have to install a cross-toolchain or compile anything -- yet can still verify
#   the image is exactly what the (tested) source produces.
#
#   The trust model rests on two legs:
#     1. PROVENANCE -- every released image carries a MANIFEST recording the git
#        commit, the exact toolchain versions, the per-image fuse bytes / CONFIG
#        word, and the validation evidence (test-long + both ATtiny202 gates +
#        both pre-hardware and real-target PIC aggregates + 15-combination 24-h
#        soak).
#     2. REPRODUCIBILITY -- the Intel-HEX images are byte-deterministic for a
#        fixed toolchain (objcopy ihex carries only code/data bytes, no
#        timestamps/paths). SHA256SUMS pins those bytes; the tag-triggered CI
#        (.github/workflows/release.yml) rebuilds from the tag on a clean runner
#        and FAILS the release unless its fresh images reproduce these hashes.
#        That green check -- not this script -- is the public attestation that
#        "this binary IS the tagged source."
#
# WHAT IT DOES (in order)
#   0. Preconditions: clean tree, valid version, tag not already present, and
#      EVERY required tool present. Unlike the dev-time targets (which skip
#      cleanly when a tool is missing), a release FAILS LOUD on any absence -- a
#      gate must never go green on a check that silently did nothing.
#   1. Clean-build every release-supported image: AVR Classic, ATtiny202,
#      PIC10F322 and PIC10F320. The built set is then cross-checked against the
#      CANONICAL set the Makefile declares (RELEASE_IMAGES). This independent
#      check catches a forgotten build step -- an enumeration derived from the same
#      variant matrices as the build commands shrinks in lock-step with an
#      omission and agrees with itself (merge plan §10, §14.8).
#   2. Run `make test-long`, `make attiny202-test`,
#      `make attiny202-test-target`, `make pic10f322-test`,
#      `make pic10f322-test-target-variants`, `make pic10f320-test`, and
#      `make pic10f320-test-target-variants` (the full qualification gates for
#      every release-supported target).
#   3. Run ALL release soak combinations IN PARALLEL for the full
#      duration, collecting a pass/fail verdict and evidence from each. That is
#      6 AVR Classic + 3 AVR-XT + 3 PIC10F322 + 3 PIC10F320 = 15 combos.
#   4. Recheck source HEAD + cleanliness, then stage release/<VERSION>/ : the
#      .hex images, SHA256SUMS, a provenance MANIFEST, a README, the
#      soak/validation evidence, and a commit message.
#   5. STOP. Print the exact git + signing commands for the human to run. This
#      script NEVER commits, tags, signs, or pushes -- per project policy all
#      modifying git operations are done by hand.
#
# USAGE
#   scripts/make-release.sh [options] <version>
#     <version>                vX.Y.Z (semantic version, leading 'v'); required
#                              except in --preflight mode
#   options:
#     --preflight              run every release capability/precondition check,
#                              then exit before cleaning, building, or staging
#     --dry-run                rehearse the whole pipeline with a SHORT soak
#                              (does not produce a real release; output is
#                              clearly marked and no git commands are emitted)
#     --soak-duration-ms N     per-combo soak duration (default/minimum for a
#                              real release: 24 h; dry runs may use less)
#     --jobs N                 max concurrent soak combos (default: all of them)
#     --output-dir DIR         where to stage (default release/<version>)
#     -h | --help              this help
#
# This script is intentionally long-running (~24 h, dominated by the parallel
# soaks). Run it on a machine that can stay up, with all toolchains installed
# (AVR + XC8/DFP + simavr + gpsim/gpsim-dev + analyzers). See TOOLCHAIN.adoc.

set -euo pipefail

# `make release` already owns the worktree lock. Direct execution acquires the
# same lock for the complete build/validation/staging pipeline so nested Make
# calls cannot interleave with another invocation's artifacts.
REPO_HINT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
REPO_LOCK_ID=$(stat -Lc '%d:%i' "$REPO_HINT" 2>/dev/null) \
	|| { printf 'FATAL: stat is required to identify the worktree lock\n' >&2; exit 1; }
if [ "${_MAKE_SERIAL_LOCK_HELD:-}" != "$REPO_LOCK_ID" ]; then
	command -v flock >/dev/null 2>&1 \
		|| { printf 'FATAL: flock is required to serialize release artifacts\n' >&2; exit 1; }
	# --no-fork keeps this process as the release orchestrator, so HUP/INT/TERM
	# reach its worker-cleanup traps instead of stopping a parent flock process.
	exec flock --no-fork "$REPO_HINT/.make.lock" env _MAKE_SERIAL_LOCK_HELD="$REPO_LOCK_ID" \
		"$REPO_HINT/scripts/make-release.sh" "$@"
fi

# ----------------------------------------------------------------------------
# Small output helpers (stderr for status; stdout reserved for the final recipe)
# ----------------------------------------------------------------------------
_c()  { tput "$@" 2>/dev/null || true; }
BOLD=$(_c bold); RED=$(_c setaf 1); GRN=$(_c setaf 2); YEL=$(_c setaf 3); RST=$(_c sgr0)

section() { printf '\n%s========== %s ==========%s\n' "$BOLD" "$*" "$RST" >&2; }
log()     { printf '%s\n' "$*" >&2; }
ok()      { printf '%sOK%s   %s\n' "$GRN" "$RST" "$*" >&2; }
warn()    { printf '%sWARN%s %s\n' "$YEL" "$RST" "$*" >&2; }
die()     { printf '%sFATAL%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------
MAKE_VERSION=${VERSION-}
MAKE_RELEASE_ARGS=${RELEASE_ARGS-}
VERSION=""
VERSION_WAS_SUPPLIED=0
PREFLIGHT=0
DRY_RUN=0
RELEASE_MODE=production
# Canonical project URL. MANIFEST.md is used verbatim as the GitHub Release
# body, where repo-relative links do not resolve, so any link it carries must
# be absolute. Not derived from `git remote` on purpose: that would vary with
# the operator's SSH-vs-HTTPS remote and silently change published notes.
REPO_URL=https://github.com/matt-garman/mcu-bypass-firmware
MIN_RELEASE_SOAK_MS=86400000
MAX_SOAK_DURATION_MS=4294967294    # uint32_t loop bound; preserve t + 1
SOAK_DURATION_MS=$MIN_RELEASE_SOAK_MS
SOAK_LIVENESS_INTERVAL_MS=60000
JOBS=""                            # empty => all combinations
OUTPUT_DIR=""
MAKE_RELEASE_ARGS_ACTIVE=0

usage() { sed -n '2,200p' "$0" | sed -n '/^# USAGE/,/^$/p' | sed 's/^# \{0,1\}//'; }

# The Make target exports RELEASE_ARGS rather than interpolating it into shell
# syntax. Split its documented whitespace-delimited option list without eval;
# direct script invocations already provide exact argv and ignore this channel.
if [ "$#" -eq 0 ] && [ -n "$MAKE_RELEASE_ARGS" ]; then
	IFS=$' \t\n' read -r -d '' -a make_release_argv \
		< <(printf '%s\0' "$MAKE_RELEASE_ARGS")
	set -- "${make_release_argv[@]}"
	MAKE_RELEASE_ARGS_ACTIVE=1
fi

while [ $# -gt 0 ]; do
	case "$1" in
		--preflight)          PREFLIGHT=1; shift ;;
		--dry-run)            DRY_RUN=1; shift ;;
		--soak-duration-ms)   SOAK_DURATION_MS="${2:?--soak-duration-ms needs a value}"; shift 2 ;;
		--jobs)               JOBS="${2:?--jobs needs a value}"; shift 2 ;;
		--output-dir)         OUTPUT_DIR="${2:?--output-dir needs a value}"; shift 2 ;;
		-h|--help)            usage; exit 0 ;;
		-*)                   die "unknown option: $1 (try --help)" ;;
		*)                    [ "$MAKE_RELEASE_ARGS_ACTIVE" -eq 0 ] \
				|| die "RELEASE_ARGS may contain options only, not positional value: $1"
			[ -z "$VERSION" ] || die "unexpected extra argument: $1"; VERSION="$1"; VERSION_WAS_SUPPLIED=1; shift ;;
	esac
done

[ "$PREFLIGHT" -eq 0 ] || [ "$DRY_RUN" -eq 0 ] \
	|| die "--preflight and --dry-run are mutually exclusive"
if [ "$VERSION_WAS_SUPPLIED" -eq 0 ] && [ -n "$MAKE_VERSION" ]; then
	# GNU Make exports command-line variables to recipes. Reading VERSION from
	# that environment keeps arbitrary bytes out of the recipe's shell syntax;
	# semantic/ref validation below still treats it exactly like a positional arg.
	VERSION=$MAKE_VERSION
	VERSION_WAS_SUPPLIED=1
fi
if [ -z "$VERSION" ]; then
	[ "$PREFLIGHT" -eq 1 ] \
		|| die "no <version> given (e.g. v1.0.0). Try --help."
	# Capability checks need a safe prospective staging path, but not a release
	# number. A caller that wants tag/output-state warnings can still supply one.
	VERSION=v0.0.0-preflight
fi
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] \
	|| die "version '$VERSION' is not vX.Y.Z (optionally -suffix)"
git check-ref-format "refs/tags/$VERSION" >/dev/null 2>&1 \
	|| die "version '$VERSION' is not a valid Git tag name"

# The C/C++ soak loops use uint32_t millisecond counters. Validate before any
# preconditions or builds so a bad value cannot wrap to a short/empty passing
# run. Canonical decimal syntax also keeps later shell arithmetic unambiguous.
[[ "$SOAK_DURATION_MS" =~ ^[1-9][0-9]*$ ]] \
	|| die "--soak-duration-ms must be a positive base-10 integer"
if [ "${#SOAK_DURATION_MS}" -gt "${#MAX_SOAK_DURATION_MS}" ] \
		|| { [ "${#SOAK_DURATION_MS}" -eq "${#MAX_SOAK_DURATION_MS}" ] \
			&& [[ "$SOAK_DURATION_MS" > "$MAX_SOAK_DURATION_MS" ]]; }; then
	die "--soak-duration-ms must not exceed $MAX_SOAK_DURATION_MS"
fi
if [ -n "$JOBS" ] && ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
	die "--jobs must be a positive base-10 integer"
fi
if [ "$DRY_RUN" -eq 0 ] && [ "$SOAK_DURATION_MS" -lt "$MIN_RELEASE_SOAK_MS" ]; then
	die "real releases require --soak-duration-ms >= $MIN_RELEASE_SOAK_MS (24 h); use --dry-run for a short rehearsal"
fi

if [ "$DRY_RUN" -eq 1 ]; then
	RELEASE_MODE=dry-run
	# A dry run is an explicit rehearsal: shorten the soak so the whole pipeline
	# finishes quickly, and tolerate an uncommitted tree (you typically rehearse
	# BEFORE committing the release scaffolding itself).
	[ "$SOAK_DURATION_MS" = "$MIN_RELEASE_SOAK_MS" ] && SOAK_DURATION_MS=60000
fi
# A short rehearsal must still execute at least one responsiveness round-trip.
[ "$SOAK_DURATION_MS" -lt "$SOAK_LIVENESS_INTERVAL_MS" ] \
	&& SOAK_LIVENESS_INTERVAL_MS=$SOAK_DURATION_MS
[ "$DRY_RUN" -eq 1 ] \
	&& warn "DRY RUN: short ${SOAK_DURATION_MS}ms soak (liveness interval ${SOAK_LIVENESS_INTERVAL_MS}ms); output is NOT a real release."

# ----------------------------------------------------------------------------
# Locate the repo and read the Makefile's single source of truth
# ----------------------------------------------------------------------------
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
cd "$REPO_ROOT"
# Load this once at startup so an edit during the long run cannot replace the
# final provenance-check implementation used by this process.
# shellcheck source=release-provenance.sh
source "$REPO_ROOT/scripts/release-provenance.sh"
declare -F release_source_is_unchanged >/dev/null \
	|| die "release provenance checker did not define its required function"
declare -F release_tool_version_line >/dev/null \
	|| die "release provenance checker did not define its tool-version function"
declare -F release_output_path_is_safe >/dev/null \
	|| die "release provenance checker did not define its output-path function"
declare -F release_terminate_workers >/dev/null \
	|| die "release provenance checker did not define its worker-cleanup function"
declare -F release_jobs_cap >/dev/null \
	|| die "release provenance checker did not define its jobs-cap function"
# shellcheck source=release-signing-policy.sh
source "$REPO_ROOT/scripts/release-signing-policy.sh" \
	|| die "release signing policy could not be loaded"

# GNU Make expands a few parse-time shell expressions through the platform awk
# before AWK itself can be read from Makefile truth. Diagnose that bootstrap
# prerequisite explicitly instead of failing inside an opaque print-<VAR> query.
command -v awk >/dev/null 2>&1 \
	|| die "awk is required to read release configuration from the Makefile"

mkv() { make -s print-"$1"; }      # echo one Makefile variable
path_from_repo() {
	case "$1" in
		/*) printf '%s\n' "$1" ;;
		*)  printf '%s/%s\n' "$REPO_ROOT" "$1" ;;
	esac
}
tool_from_repo() {
	case "$1" in
		*/*) path_from_repo "$1" ;;
		*)   printf '%s\n' "$1" ;;
	esac
}

AWK=$(mkv AWK)
AWK=$(tool_from_repo "$AWK")

VARIANTS=$(mkv VARIANTS)           # cd4053_simple cd4053_with_mute tq2_l2_5v_relay
TINYX5=$(mkv TINYX5)               # 85 45      (the family's internal indexing)
TINYX5_PARTS=$(mkv TINYX5_PARTS)   # attiny85 attiny45  (what a request names)
FW_BASE=$(mkv FW_BASE)             # bypass
ATTINY13A_MCU=$(mkv ATTINY13A_MCU) # attiny13a

# The canonical image basename: <prefix>-<mcu>-<output stage>, where the stage
# field IS the variant name. Composed here rather than read back from the
# Makefile ON PURPOSE: the enumeration below is this script's INDEPENDENT
# opinion of what a complete release contains, and it is cross-checked against
# the Makefile's RELEASE_IMAGES a few dozen lines down. Deriving the names from
# the thing being cross-checked would make that check agree with itself.
#
# v0.9.8 briefly needed a variant->stage translation table here. It is gone
# because the vocabularies were unified rather than mapped, so the only thing
# left to restate is the delimiter layout.
# $(fw_image <build dir> <mcu tag> <variant>) -> full path, no suffix
fw_image() { printf '%s/%s-%s-%s' "$1" "$FW_BASE" "$2" "$3"; }
AVR_BUILD_DIR=$(mkv AVR_BUILD_DIR) # build_avr_classic
PIC10F322_BUILD_DIR=$(mkv PIC10F322_BUILD_DIR) # build_pic10f322
PIC10F322_TAG=$(mkv PIC10F322_TAG)             # pic10f322
PIC10F322_XTAL=$(mkv PIC10F322_XTAL)           # 2000000UL  (_XTAL_FREQ; drives __delay_ms)
# The manifest clock string is derived after preflight validates the selected
# AWK, so it cannot drift from this firmware clock source.
PIC10F322_GPSIM_PROC=$(mkv PIC10F322_GPSIM_PROC)
LFUSE=$(mkv ATTINY13A_LFUSE);     HFUSE=$(mkv ATTINY13A_HFUSE)
LFUSE_X5=$(mkv TINYX5_LFUSE); HFUSE_X5=$(mkv TINYX5_HFUSE)
PIC_CC=$(mkv PIC_CC)
PIC_DFP=$(mkv PIC_DFP)
PIC_CC=$(tool_from_repo "$PIC_CC")
PIC_DFP=$(path_from_repo "$PIC_DFP")
AVRDUDE_PART=$(mkv ATTINY13A_AVRDUDE_PART)   # t13
declare -A AVRDUDE_PART_X5
for n in $TINYX5; do AVRDUDE_PART_X5[$n]=$(mkv part_"$n"); done

# --- ATtiny202 (AVR-XT) ------------------------------------------------------
# Read through its own variables for the same reason the PIC pair below does:
# the AVR-XT shares avr-gcc with the classic parts but nothing else -- its own
# device pack, its own clock, its own fuse model (seven named AVR8X memories
# rather than lfuse/hfuse), and a simulator that is neither simavr nor gpsim.
XT_BUILD_DIR=$(mkv XT_BUILD_DIR)   # build_avr_xt
XT_TAG=$(mkv XT_TAG)               # attiny202
XT_MCU=$(mkv XT_MCU)               # attiny202
XT_DFP=$(mkv XT_DFP)               # third_party/attiny_dfp
XT_DFP=$(path_from_repo "$XT_DFP")
XT_F_CPU=$(mkv XT_F_CPU)           # 2000000UL
XT_FLASH_BYTES=$(mkv XT_FLASH_BYTES)
XT_VARIANTS=$(mkv XT_VARIANTS_SUPPORTED)     # same three names as VARIANTS
YASIMAVR_PY=$(mkv YASIMAVR_PY)     # third_party/yasimavr/venv/bin/python
YASIMAVR_PY_ABS=$(path_from_repo "$YASIMAVR_PY")
XT_AVRDUDE_PART=$(mkv XT_AVRDUDE_PART)       # t202
XT_PROGRAMMER=$(mkv XT_PROGRAMMER)           # serialupdi
# The seven AVR8X fuse bytes, in the datasheet's memory order. Unlike the classic
# parts' lfuse/hfuse pair these are individually named avrdude memories, so the
# manifest and the flashing recipe both have to enumerate them.
XT_FUSE_NAMES="wdtcfg bodcfg osccfg syscfg0 syscfg1 append bootend"
declare -A XT_FUSE
XT_FUSE[wdtcfg]=$(mkv XT_FUSE_WDTCFG)
XT_FUSE[bodcfg]=$(mkv XT_FUSE_BODCFG)
XT_FUSE[osccfg]=$(mkv XT_FUSE_OSCCFG)
XT_FUSE[syscfg0]=$(mkv XT_FUSE_SYSCFG0)
XT_FUSE[syscfg1]=$(mkv XT_FUSE_SYSCFG1)
XT_FUSE[append]=$(mkv XT_FUSE_APPEND)
XT_FUSE[bootend]=$(mkv XT_FUSE_BOOTEND)

# --- PIC10F320, the constrained release target -------------------------------
# Read through its OWN variables, never by deriving from the PIC10F322's. The
# two chips share one XC8 + DFP installation today, but the separate variable
# pairs exist precisely so one can be re-pinned (merge plan §5.6) -- and a
# release script that assumed they track would build one chip with the other's
# toolchain and say nothing.
PIC10F320_BUILD_DIR=$(mkv PIC10F320_BUILD_DIR)     # build_pic10f320
PIC10F320_TAG=$(mkv PIC10F320_TAG)                 # pic10f320
PIC10F320_VARIANTS=$(mkv PIC10F320_VARIANTS_ALL)   # same three names as VARIANTS
PIC10F320_XTAL=$(mkv PIC10F320_XTAL)
PIC10F320_FLASH_WORDS=$(mkv PIC10F320_FLASH_WORDS) # 256
PIC10F320_CC=$(mkv PIC10F320_CC)
PIC10F320_DFP=$(mkv PIC10F320_DFP)
PIC10F320_CC=$(tool_from_repo "$PIC10F320_CC")
PIC10F320_DFP=$(path_from_repo "$PIC10F320_DFP")

# --- host / AVR / analysis tools, read through their Makefile variables -------
# The preconditions below assert these, and the manifest records their versions.
# Both must name the tool the BUILD will actually run: every one of these is a
# Makefile variable (`?=` for most, so the environment wins), so a hardcoded
# `clang` here would assert one binary while `make` used another -- passing a
# release whose analysis never ran, or failing one whose toolchain is merely
# installed elsewhere. This is the reasoning the PIC pairs above already embody.
HOST_CC=$(mkv HOSTCC)
AVR_CC=$(mkv CC)
AVR_OBJCOPY=$(mkv OBJCOPY)
AVR_SIZE=$(mkv SIZE)
AVR_OBJDUMP=$(mkv OBJDUMP)
READELF=$(mkv READELF)
IHEX_VALIDATOR=$(mkv IHEX_VALIDATOR)
CLANG=$(mkv CLANG)
CPPCHECK=$(mkv CPPCHECK)
CBMC=$(mkv CBMC)
GCOV=$(mkv GCOV)
GPSIM=$(mkv GPSIM)
SIMAVR_INC=$(mkv SIMAVR_INC)
PIC_XC8_INCLUDE=$(mkv PIC_XC8_INCLUDE)
PIC10F320_XC8_INCLUDE=$(mkv PIC10F320_XC8_INCLUDE)
PIC10F322_DFP_INCLUDE=$(mkv PIC10F322_DFP_INCLUDE)
PIC10F320_DFP_INCLUDE=$(mkv PIC10F320_DFP_INCLUDE)
PIC10F322_DEVICE_INI=$(mkv PIC10F322_DEVICE_INI)
PIC10F320_DEVICE_INI=$(mkv PIC10F320_DEVICE_INI)
XT_IO_HEADER=$(mkv XT_IO_HEADER)
PIC10F320_HOST_CC=$(mkv PIC10F320_HOST_CC)
PIC_SOAK_CXX=$(mkv PIC_SOAK_CXX)
PIC10F320_SOAK_CXX=$(mkv PIC10F320_SOAK_CXX)
PIC_SOAK_GPSIM_INC=$(mkv PIC_SOAK_GPSIM_INC)
PIC10F320_SOAK_GPSIM_INC=$(mkv PIC10F320_SOAK_GPSIM_INC)
ANALYZE_CMD=$(mkv ANALYZE_CMD)

SIMAVR_INC=$(path_from_repo "$SIMAVR_INC")
PIC_XC8_INCLUDE=$(path_from_repo "$PIC_XC8_INCLUDE")
PIC10F320_XC8_INCLUDE=$(path_from_repo "$PIC10F320_XC8_INCLUDE")
PIC10F322_DFP_INCLUDE=$(path_from_repo "$PIC10F322_DFP_INCLUDE")
PIC10F320_DFP_INCLUDE=$(path_from_repo "$PIC10F320_DFP_INCLUDE")
PIC10F322_DEVICE_INI=$(path_from_repo "$PIC10F322_DEVICE_INI")
PIC10F320_DEVICE_INI=$(path_from_repo "$PIC10F320_DEVICE_INI")
XT_IO_HEADER=$(path_from_repo "$XT_IO_HEADER")
PIC_SOAK_GPSIM_INC=$(path_from_repo "$PIC_SOAK_GPSIM_INC")
PIC10F320_SOAK_GPSIM_INC=$(path_from_repo "$PIC10F320_SOAK_GPSIM_INC")
AVR_CC=$(tool_from_repo "$AVR_CC")
AVR_OBJCOPY=$(tool_from_repo "$AVR_OBJCOPY")
AVR_SIZE=$(tool_from_repo "$AVR_SIZE")
AVR_OBJDUMP=$(tool_from_repo "$AVR_OBJDUMP")
READELF=$(tool_from_repo "$READELF")
IHEX_VALIDATOR=$(tool_from_repo "$IHEX_VALIDATOR")
HOST_CC=$(tool_from_repo "$HOST_CC")
PIC10F320_HOST_CC=$(tool_from_repo "$PIC10F320_HOST_CC")
CLANG=$(tool_from_repo "$CLANG")
CPPCHECK=$(tool_from_repo "$CPPCHECK")
CBMC=$(tool_from_repo "$CBMC")
GCOV=$(tool_from_repo "$GCOV")
GPSIM=$(tool_from_repo "$GPSIM")
PIC_SOAK_CXX=$(tool_from_repo "$PIC_SOAK_CXX")
PIC10F320_SOAK_CXX=$(tool_from_repo "$PIC10F320_SOAK_CXX")
ANALYZE_TOOL=${ANALYZE_CMD%%[[:space:]]*}
AVR_NM=$(tool_from_repo "${AVR_NM:-avr-nm}")
MUTATION_MAKE=$(tool_from_repo "${MUTATION_MAKE:-make}")

# Every nested Make and child script must consume the exact paths preflight
# approved. Most Makefile selectors are ?= and therefore honor these exports;
# the three plain classic-tool assignments are also passed explicitly where the
# release invokes their build/test graphs.
export OBJDUMP="$AVR_OBJDUMP" READELF IHEX_VALIDATOR AWK HOSTCC="$HOST_CC"
export CLANG CPPCHECK CBMC GCOV GPSIM SIMAVR_INC
export ANALYZE_CMD AVR_NM MUTATION_MAKE
export PIC_CC PIC_DFP PIC_XC8_INCLUDE PIC10F322_DFP_INCLUDE PIC10F322_DEVICE_INI
export PIC10F320_CC PIC10F320_DFP PIC10F320_XC8_INCLUDE PIC10F320_DFP_INCLUDE PIC10F320_DEVICE_INI
export PIC10F320_HOST_CC PIC_SOAK_CXX PIC10F320_SOAK_CXX
export PIC_SOAK_GPSIM_INC PIC10F320_SOAK_GPSIM_INC XT_DFP
export YASIMAVR_VENV="$(dirname "$(dirname "$YASIMAVR_PY_ABS")")"

# The canonical release product set (merge plan §10). This script ENUMERATES the
# images it expects to build from the variant matrices below; RELEASE_IMAGES is
# the independent statement of what a complete release contains, and the two are
# cross-checked before anything is staged. Enumeration alone cannot catch a
# missing build step -- it would simply enumerate fewer images and agree with
# itself, which is the whole failure mode §14.8 describes.
RELEASE_IMAGES=$(mkv RELEASE_IMAGES)
[ -n "${RELEASE_IMAGES// /}" ] \
	|| die "Makefile RELEASE_IMAGES is empty; the canonical release set is unusable"
# The build directories those images come from, so the reproduction instructions
# this script GENERATES cannot list a stale set of directories.
RELEASE_IMAGE_DIRS=$(mkv RELEASE_IMAGE_DIRS)
[ -n "${RELEASE_IMAGE_DIRS// /}" ] \
	|| die "Makefile RELEASE_IMAGE_DIRS is empty"
RELEASE_SOAK_NAMES=$(mkv RELEASE_SOAK_NAMES)
[ -n "${RELEASE_SOAK_NAMES// /}" ] \
	|| die "Makefile RELEASE_SOAK_NAMES is empty"
RELEASE_EVIDENCE_FILES=$(mkv RELEASE_EVIDENCE_FILES)
[ -n "${RELEASE_EVIDENCE_FILES// /}" ] \
	|| die "Makefile RELEASE_EVIDENCE_FILES is empty"

# Scratch area for evidence + per-combo soak run dirs. Preserved on failure so a
# crashed/failed run can be inspected; folded into the release on success.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mcu-release.XXXXXX")"
EVID="$WORK/evidence"; SOAKDIR="$WORK/soak"
KEEP_WORK=0
SOAK_PIDS=()
TRACKING_WORKER=0
PENDING_SIGNAL_STATUS=0
cleanup() { [ "${KEEP_WORK:-0}" = 1 ] || rm -rf "$WORK"; }
on_exit() {
	local rc=$?
	trap - EXIT
	# Cleanup is now the only path to a safe exit. Ignore repeated signals until
	# every isolated worker group has been killed and its direct child reaped.
	trap '' HUP INT TERM
	if ! release_terminate_workers "${SOAK_PIDS[@]}"; then
		rc=1
		warn "could not terminate every release soak worker cleanly"
	fi
	SOAK_PIDS=()
	if [ "$rc" -ne 0 ] && [ "${PREFLIGHT:-0}" -eq 0 ]; then
		KEEP_WORK=1
		warn "left working dir for inspection: $WORK"
	fi
	cleanup
	exit "$rc"
}
on_signal() {
	local status=$1
	if [ "${TRACKING_WORKER:-0}" -eq 1 ]; then
		PENDING_SIGNAL_STATUS=$status
		return
	fi
	exit "$status"
}
trap on_exit EXIT
trap 'on_signal 129' HUP
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
mkdir -p "$EVID" "$SOAKDIR" \
	|| die "could not initialize release scratch directories under $WORK"

# Where to stage. A real release lands in the repo at release/<version>; a dry
# run lands in the auto-scratch WORK (kept, never littering the repo).
if [ -n "$OUTPUT_DIR" ]; then :;
elif [ "$DRY_RUN" -eq 1 ]; then OUTPUT_DIR="$WORK/release/$VERSION"; KEEP_WORK=1
else OUTPUT_DIR="release/$VERSION"
fi
release_output_path_is_safe "$REPO_ROOT" "$OUTPUT_DIR" "$RELEASE_MODE" "$VERSION"

# ============================================================================
# 0. PRECONDITIONS
# ============================================================================
section "0. preconditions"

# Clean working tree -- the provenance commit SHA must mean something. A real
# release requires it; explicitly non-publishable dry-run and capability-only
# preflight modes warn because they are intended to run before the release
# changes are committed.
GIT_DIRTY=0
if ! GIT_STATUS=$(git status --porcelain); then
	die "could not inspect working-tree status"
fi
if [ -n "$GIT_STATUS" ]; then
	GIT_DIRTY=1
	if [ "$DRY_RUN" -eq 1 ] || [ "$PREFLIGHT" -eq 1 ]; then
		warn "working tree is DIRTY; provenance SHA $(git rev-parse --short HEAD) will not capture uncommitted changes."
	else
		git status --short >&2
		die "working tree is not clean. Commit/stash everything before releasing (or --dry-run to rehearse)."
	fi
fi

# Tag availability is publishing state, not host capability. Check and warn in
# preflight when a real prospective version was supplied; with no version there
# is intentionally nothing meaningful to query.
if [ "$PREFLIGHT" -eq 1 ] && [ "$VERSION_WAS_SUPPLIED" -eq 0 ]; then
	warn "no release version supplied; tag availability was not checked."
else
	if git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null 2>&1; then
		LOCAL_TAG_STATUS=0
	else
		LOCAL_TAG_STATUS=$?
	fi
	case "$LOCAL_TAG_STATUS" in
		0)
			[ "$PREFLIGHT" -eq 1 ] && warn "tag $VERSION already exists locally." \
				|| die "tag $VERSION already exists."
			;;
		1) : ;; # no matching local ref
		*)
			[ "$PREFLIGHT" -eq 1 ] \
				&& warn "could not check local tag $VERSION (git rev-parse exited $LOCAL_TAG_STATUS)." \
				|| die "could not check local tag $VERSION (git rev-parse exited $LOCAL_TAG_STATUS)."
			;;
	esac
	if git remote get-url origin >/dev/null 2>&1; then
		ORIGIN_STATUS=0
	else
		ORIGIN_STATUS=$?
	fi
	case "$ORIGIN_STATUS" in
	0)
		if git ls-remote --exit-code --tags origin "refs/tags/$VERSION" >/dev/null 2>&1; then
			REMOTE_TAG_STATUS=0
		else
			REMOTE_TAG_STATUS=$?
		fi
		case "$REMOTE_TAG_STATUS" in
			0)
				[ "$PREFLIGHT" -eq 1 ] && warn "tag $VERSION already exists on origin." \
					|| die "tag $VERSION already exists on origin."
				;;
			2) : ;; # --exit-code: remote reachable, no matching ref
			*)
				[ "$PREFLIGHT" -eq 1 ] \
					&& warn "could not check tag $VERSION on origin (git ls-remote exited $REMOTE_TAG_STATUS)." \
					|| die "could not check tag $VERSION on origin (git ls-remote exited $REMOTE_TAG_STATUS)."
				;;
		esac
		;;
	2) : ;; # no origin configured
	*)
		[ "$PREFLIGHT" -eq 1 ] \
			&& warn "could not inspect origin for tag $VERSION (git remote get-url exited $ORIGIN_STATUS)." \
			|| die "could not inspect origin for tag $VERSION (git remote get-url exited $ORIGIN_STATUS)."
		;;
	esac
fi

# Output dir must not already exist (don't clobber a prior release).
OUTPUT_EXISTS=0
if [ -e "$OUTPUT_DIR" ]; then
	OUTPUT_EXISTS=1
	[ "$PREFLIGHT" -eq 1 ] && warn "$OUTPUT_DIR already exists; a real release would refuse to overwrite it." \
		|| die "$OUTPUT_DIR already exists; refusing to overwrite."
fi

GIT_SHA=$(git rev-parse HEAD)
GIT_SHORT=$(git rev-parse --short HEAD)

# Required tools. A release FAILS LOUD on any absence (no silent skipping).
MISSING=()
have()      { command -v "$1" >/dev/null 2>&1; }
req_cmd()   { have "$1" || MISSING+=("$1${2:+  ($2)}"); }
req_file()  { [ -f "$1" ] && [ -s "$1" ] || MISSING+=("$1${2:+  ($2)}"); }
req_exec() {
	case "$1" in
		*/*) [ -f "$1" ] && [ -s "$1" ] && [ -x "$1" ] ;;
		*)   have "$1" ;;
	esac || MISSING+=("$1${2:+  ($2)}")
}
req_exec_file() {
	[ -f "$1" ] && [ -s "$1" ] && [ -x "$1" ] \
		|| MISSING+=("$1${2:+  ($2)}")
}

req_cmd make
req_cmd flock          "apt: util-linux (whole-worktree serialization)"
req_cmd setsid         "apt: util-linux (isolated release-soak process groups)"
req_cmd "$AVR_CC"      "apt: gcc-avr"
req_cmd "$AVR_OBJCOPY" "apt: binutils-avr (HEX bytes + reproducibility)"
req_cmd "$AVR_SIZE"    "apt: binutils-avr"
req_cmd "$AVR_OBJDUMP" "apt: binutils-avr (ATtiny202 coil-pulse width oracle)"
req_cmd "$READELF"     "apt: binutils (ELF architecture validation)"
req_exec_file "$IHEX_VALIDATOR" "nonempty executable Intel HEX validator file (IHEX_VALIDATOR=)"
req_cmd "$AWK"         "awk implementation selected by AWK"
if have "$AWK" && [ "$("$AWK" 'BEGIN { print "release-awk-ok" }' 2>/dev/null)" != release-awk-ok ]; then
	MISSING+=("$AWK  (AWK must execute a basic program and produce output)")
fi
req_cmd "$HOST_CC"     "host C compiler (HOSTCC=)"
req_cmd "$PIC10F320_HOST_CC" "PIC10F320 host compiler selected by PIC10F320_HOST_CC"
req_cmd "$ANALYZE_TOOL" "analysis command selected by ANALYZE_CMD"
req_cmd "$AVR_NM"      "ATtiny202 symbol resolver selected by AVR_NM"
req_cmd "$MUTATION_MAKE" "Make executable selected by MUTATION_MAKE"
req_file "$SIMAVR_INC/sim_avr.h" "apt: libsimavr-dev (SIMAVR_INC=)"
req_file "$SIMAVR_INC/sim_elf.h" "apt: libsimavr-dev (SIMAVR_INC=)"
req_file "$SIMAVR_INC/sim_irq.h" "apt: libsimavr-dev (SIMAVR_INC=)"
req_file "$SIMAVR_INC/sim_vcd_file.h" "apt: libsimavr-dev (SIMAVR_INC=)"
req_file "$SIMAVR_INC/avr_ioport.h" "apt: libsimavr-dev (SIMAVR_INC=)"
req_cmd "$CLANG"       "apt: clang (analyze-deep)"
req_cmd "$CPPCHECK"    "apt: cppcheck (analyze + MISRA)"
req_cmd "$CBMC"        "apt: cbmc (formal proof in test-long)"
req_cmd python3        "Python 3.7 or newer; host gates and MISRA addon"
PYTHON_VERSION_OK=0
if have python3; then
	if PYTHON_VERSION_ERROR=$(python3 "$REPO_ROOT/test/python_version.py" 2>&1); then
		PYTHON_VERSION_OK=1
	else
		MISSING+=("${PYTHON_VERSION_ERROR:-python3 minimum-version probe failed}")
	fi
fi
if [ "$PYTHON_VERSION_OK" -eq 1 ] \
		&& ! python3 -c 'import yaml' >/dev/null 2>&1; then
	MISSING+=("PyYAML  (apt: python3-yaml; strict workflow syntax validation)")
fi
req_cmd gpg            "release checksum/tag signing and signature regressions"
req_cmd timeout        "coreutils (bounded mutation and simulator probes)"
req_cmd tar            "tar (PIC10F320 coverage archive regression)"
# gcov backs coverage-check / coverage-check-core, which run inside the
# `make test-long` at step 2. Absent, that gate fails AFTER the clean build.
req_cmd "$GCOV"        "ships with gcc (coverage-check in test-long)"
# sha256sum is the release's trust anchor: it hashes the validated image set and
# writes SHA256SUMS during STAGING -- i.e. on the far side of the 24-hour soak.
# Nothing before that point would notice its absence.
req_cmd sha256sum      "coreutils (SHA256SUMS; the reproducibility anchor)"
if have "$AVR_CC" && ! printf '%s\n' \
		'#include <avr/io.h>' '#include <avr/wdt.h>' '#include <avr/power.h>' \
		'#include <avr/sleep.h>' '#include <avr/interrupt.h>' \
		| "$AVR_CC" -mmcu="$ATTINY13A_MCU" -x c -E - >/dev/null 2>&1; then
	MISSING+=("avr-libc headers  (apt: avr-libc; selected CC cannot preprocess the firmware headers)")
fi
if have "$HOST_CC" && ! printf '%s\n' \
		'#include "sim_avr.h"' '#include "sim_elf.h"' '#include "sim_irq.h"' \
		'#include "sim_vcd_file.h"' '#include "avr_ioport.h"' \
		'int main(void) { return 0; }' \
		| "$HOST_CC" -std=c11 -I"$SIMAVR_INC" -x c - -o "$WORK/preflight-simavr-link" \
			-Wl,--no-as-needed -lsimavr -lelf >/dev/null 2>&1; then
	MISSING+=("simavr header/link capability  (apt: libsimavr-dev libelf-dev; SIMAVR_INC=, HOSTCC=)")
fi
# PIC toolchain (paths come from the Makefile defaults / PIC_CC, PIC_DFP).
req_exec "$PIC_CC"                                  "executable XC8 driver (PIC_CC=)"
req_file "$PIC_DFP/pic/include/proc/pic10f322.h"    "PIC10-12Fxxx DFP (PIC_DFP=)"
req_file "$PIC_XC8_INCLUDE/xc.h"                    "XC8 base header (PIC_XC8_INCLUDE=)"
req_file "$PIC10F322_DFP_INCLUDE/proc/pic10f322.h"  "PIC10F322 analysis header (PIC10F322_DFP_INCLUDE=)"
req_file "$PIC10F322_DEVICE_INI"                    "PIC10F322 device geometry (PIC10F322_DEVICE_INI=)"
# ...and the PIC10F320's, asserted through its own pair. One DFP ships both
# device headers, so this normally passes with the line above -- but a truncated
# unpack, or a deliberately re-pinned PIC10F320_DFP, is exactly the case where the
# 320 lane would otherwise skip cleanly and the release would ship 15 images
# while claiming 18.
req_exec "$PIC10F320_CC"                                "executable XC8 driver (PIC10F320_CC=)"
req_file "$PIC10F320_DFP/pic/include/proc/pic10f320.h"  "PIC10F320 device header (PIC10F320_DFP=)"
req_file "$PIC10F320_XC8_INCLUDE/xc.h"                   "XC8 base header (PIC10F320_XC8_INCLUDE=)"
req_file "$PIC10F320_DFP_INCLUDE/proc/pic10f320.h"       "PIC10F320 analysis header (PIC10F320_DFP_INCLUDE=)"
req_file "$PIC10F320_DEVICE_INI"                        "PIC10F320 device geometry (PIC10F320_DEVICE_INI=)"
req_cmd "$GPSIM"       "apt: gpsim (pic10f322-test-gpsim, pic10f320-test-gpsim)"
req_cmd "$PIC_SOAK_CXX"       "host C++ compiler selected by PIC_SOAK_CXX"
req_cmd "$PIC10F320_SOAK_CXX" "host C++ compiler selected by PIC10F320_SOAK_CXX"
# Each chip's libgpsim headers through its OWN variable, for the same reason the
# CC/DFP pairs above are: one gpsim-dev install serves both today, but the two
# variables exist so one lane can be re-pinned, and a single hardcoded path
# would assert the wrong install and let the other lane skip.
for gpsim_header in interface.h sim_context.h processor.h pic-processor.h modules.h ioports.h stimuli.h \
		gpsim_time.h breakpoints.h trigger.h registers.h; do
	req_file "$PIC_SOAK_GPSIM_INC/$gpsim_header" \
		"apt: gpsim-dev (PIC10F322 gates; PIC_SOAK_GPSIM_INC=)"
	req_file "$PIC10F320_SOAK_GPSIM_INC/$gpsim_header" \
		"apt: gpsim-dev (PIC10F320 gates; PIC10F320_SOAK_GPSIM_INC=)"
done
req_cmd pkg-config     "apt: pkg-config (PIC soak glib flags)"
if have pkg-config && pkg-config --exists glib-2.0 2>/dev/null; then
	if GLIB_CFLAGS_RAW=$(pkg-config --cflags glib-2.0 2>/dev/null); then
		read -r -a GLIB_CFLAGS <<< "$GLIB_CFLAGS_RAW"
	else
		MISSING+=("glib-2.0 compiler flags  (pkg-config --cflags glib-2.0 failed)")
		GLIB_CFLAGS=()
	fi
	for gpsim_probe in \
		"PIC10F322|$PIC_SOAK_CXX|$PIC_SOAK_GPSIM_INC" \
		"PIC10F320|$PIC10F320_SOAK_CXX|$PIC10F320_SOAK_GPSIM_INC"; do
		IFS='|' read -r gpsim_label gpsim_cxx gpsim_inc <<< "$gpsim_probe"
		if have "$gpsim_cxx" && ! printf '%s\n' \
				'#include <glib.h>' '#include "gpsim_time.h"' '#include "breakpoints.h"' \
				'#include "trigger.h"' '#include "registers.h"' \
				'#include "pic/gpsim_bootstrap.h"' 'int main() { return 0; }' \
				| "$gpsim_cxx" -std=c++17 "${GLIB_CFLAGS[@]}" \
					-isystem "$gpsim_inc" -I"$REPO_ROOT/test" -I"$REPO_ROOT/src" \
					-x c++ - -o "$WORK/preflight-gpsim-$gpsim_label" \
					-Wl,--no-as-needed -lgpsim >/dev/null 2>&1; then
			MISSING+=("$gpsim_label gpsim compile/link capability  (gpsim-dev + libglib2.0-dev)")
		fi
	done
else
	MISSING+=("glib-2.0  (apt: libglib2.0-dev, PIC soaks)")
fi
# ATtiny202 (AVR-XT). Both inputs are fetched on demand and NOT committed, and
# every attiny202-* target skips cleanly without them -- so a release that did
# not assert them here would quietly ship three unqualified images. avr-nm and
# avr-objdump are the harness's own tools: the drivers resolve ctx_ with the
# former and read coil-pulse widths back out of the image with the latter.
req_file "$XT_DFP/gcc/dev/$XT_MCU/device-specs/specs-$XT_MCU" \
	"ATtiny_DFP (scripts/fetch_attiny_dfp.sh; XT_DFP=)"
req_file "$XT_DFP/gcc/dev/$XT_MCU/avrxmega3/short-calls/crt$XT_MCU.o" \
	"ATtiny_DFP C runtime (scripts/fetch_attiny_dfp.sh; XT_DFP=)"
req_file "$XT_DFP/gcc/dev/$XT_MCU/avrxmega3/short-calls/lib$XT_MCU.a" \
	"ATtiny_DFP device library (scripts/fetch_attiny_dfp.sh; XT_DFP=)"
req_file "$XT_IO_HEADER" "ATtiny_DFP I/O header (scripts/fetch_attiny_dfp.sh; XT_DFP=)"
req_exec "$YASIMAVR_PY_ABS" "executable patched yasimavr interpreter (scripts/fetch_yasimavr.sh; YASIMAVR_VENV=)"
YASIMAVR_IMPORT='from yasimavr.device_library.descriptors import DeviceDescriptor; from yasimavr.device_library.builders._builders_arch_xt import XT_DeviceBuilder; from yasimavr.device_library.builders import dev_tiny_0series; from yasimavr.lib import core'
if [ -f "$YASIMAVR_PY_ABS" ] && [ -x "$YASIMAVR_PY_ABS" ] \
		&& ! "$YASIMAVR_PY_ABS" -c "$YASIMAVR_IMPORT" >/dev/null 2>&1; then
	MISSING+=("yasimavr target-module imports  (rebuild: scripts/fetch_yasimavr.sh)")
fi

# Staging (step 4) runs on the far side of the ~24-hour soak, so a destination
# that cannot be written there costs the whole run. OUTPUT_DIR itself must not
# exist (asserted above), so walk up to the nearest EXISTING ancestor and
# require that it be a writable directory NOW.
STAGE_ANCHOR="$OUTPUT_DIR"
if [ "$PREFLIGHT" -eq 1 ] && [ "$OUTPUT_EXISTS" -eq 1 ]; then
	# Test the capability to create a fresh leaf, not the conflicting leaf's own
	# type/mode. A real release still rejects the conflict above.
	STAGE_ANCHOR=$(dirname "$OUTPUT_DIR")
fi
while [ ! -e "$STAGE_ANCHOR" ]; do
	stage_up=$(dirname "$STAGE_ANCHOR")
	[ "$stage_up" = "$STAGE_ANCHOR" ] && break
	STAGE_ANCHOR="$stage_up"
done
if [ ! -d "$STAGE_ANCHOR" ]; then
	MISSING+=("$STAGE_ANCHOR  (staging path's nearest existing ancestor is not a directory)")
elif [ ! -w "$STAGE_ANCHOR" ] || [ ! -x "$STAGE_ANCHOR" ]; then
	MISSING+=("$STAGE_ANCHOR  (not writable/searchable; step 4 stages $OUTPUT_DIR under it)")
fi

if [ "${#MISSING[@]}" -gt 0 ]; then
	log "Release preconditions NOT met (a release fails loud here, never mid-run):"
	for m in "${MISSING[@]}"; do log "  - $m"; done
	die "resolve the above (see TOOLCHAIN.adoc) and re-run."
fi

# These values are publication metadata, but computing them exercises the
# selected AWK. Do it only after its capability probe has passed.
PIC10F322_CLK_MHZ=$("$AWK" -v h="${PIC10F322_XTAL//[!0-9]/}" 'BEGIN{printf (h%1000000?"%.1f":"%d"), h/1000000}')
XT_CLK_MHZ=$("$AWK" -v h="${XT_F_CPU//[!0-9]/}" 'BEGIN{printf (h%1000000?"%.1f":"%d"), h/1000000}')
PIC10F320_CLK_MHZ=$("$AWK" -v h="${PIC10F320_XTAL//[!0-9]/}" 'BEGIN{printf (h%1000000?"%.1f":"%d"), h/1000000}')
if [ "$PREFLIGHT" -eq 1 ]; then
	ok "all required release tools, headers, imports and staging-path capabilities are present."
else
	ok "working tree clean @ $GIT_SHORT; tag $VERSION free; all tools present."
fi

# The release is signed BY HAND at step 5 with the pinned release key -- roughly
# 24 hours after this point. An operator whose keyring lacks that secret key
# would not find out until the soak had already cost a day, so surface it now.
#
# WARN, never fail: this script signs nothing itself (all modifying git/signing
# operations are the human's), and keeping the release secret key on a separate
# or air-gapped machine is a legitimate -- arguably better -- workflow. A dry run
# emits no git commands at all, so it says nothing.
if [ "$DRY_RUN" -eq 0 ] \
		&& ! gpg --list-secret-keys "$RELEASE_SIGNING_FINGERPRINT" >/dev/null 2>&1; then
	warn "no SECRET key for the pinned release signer $RELEASE_SIGNING_FINGERPRINT in this keyring."
	warn "  Step 5 signs SHA256SUMS and the annotated tag with exactly that key."
	warn "  Fine if you sign on another machine; otherwise import it BEFORE the ~24 h soak."
fi

# ----------------------------------------------------------------------------
# Record toolchain versions (for the manifest) and warn on drift from the pins.
# ----------------------------------------------------------------------------
pkgver() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null || echo "n/a"; }

# Record the SAME binaries the preconditions asserted and the build will run --
# not their default names -- so an overridden toolchain cannot be validated here
# while the manifest attests to a different one.
TC_AVR_GCC=$(release_tool_version_line "AVR GCC (CC=$AVR_CC)" "$AVR_CC") \
	|| die "could not record the AVR compiler provenance"
TC_AVR_BU=$(release_tool_version_line "AVR objcopy (OBJCOPY=$AVR_OBJCOPY)" "$AVR_OBJCOPY") \
	|| die "could not record the AVR binutils provenance"
TC_AVR_LIBC=$(pkgver avr-libc)
TC_HOST_CC=$(release_tool_version_line "host C compiler (HOSTCC=$HOST_CC)" "$HOST_CC") \
	|| die "could not record the host compiler provenance"
TC_XC8_322=$(release_tool_version_line "PIC10F322 XC8 (PIC_CC=$PIC_CC)" "$PIC_CC") \
	|| die "could not record the PIC10F322 compiler provenance"
TC_XC8_320=$(release_tool_version_line "PIC10F320 XC8 (PIC10F320_CC=$PIC10F320_CC)" "$PIC10F320_CC") \
	|| die "could not record the PIC10F320 compiler provenance"
TC_GPSIM=$(release_tool_version_line "gpsim (GPSIM=$GPSIM)" "$GPSIM") \
	|| die "could not record the gpsim provenance"
TC_SIMAVR=$(pkgver libsimavr-dev)
TC_CPPCHECK=$(release_tool_version_line "cppcheck (CPPCHECK=$CPPCHECK)" "$CPPCHECK") \
	|| die "could not record the cppcheck provenance"
TC_CBMC=$(release_tool_version_line "CBMC (CBMC=$CBMC)" "$CBMC") \
	|| die "could not record the CBMC provenance"
TC_CLANG=$(release_tool_version_line "Clang (CLANG=$CLANG)" "$CLANG") \
	|| die "could not record the Clang provenance"
TC_PY=$(release_tool_version_line "Python" python3) \
	|| die "could not record the Python provenance"

case "$TC_AVR_GCC" in
	*7.3.0*) : ;;
	*) warn "avr-gcc is not the pinned 7.3.0 ($TC_AVR_GCC). Images may not reproduce the CI build; the release.yml repro-verify will catch a mismatch." ;;
esac
case "$TC_XC8_322" in
	*V3.10*|*v3.10*) : ;;
	*) warn "PIC10F322 XC8 is not the pinned V3.10 ($TC_XC8_322). Images may not reproduce the CI build; the release.yml repro-verify will catch a mismatch." ;;
esac
case "$TC_XC8_320" in
	*V3.10*|*v3.10*) : ;;
	*) warn "PIC10F320 XC8 is not the pinned V3.10 ($TC_XC8_320). Images may not reproduce the CI build; the release.yml repro-verify will catch a mismatch." ;;
esac

if [ "$PREFLIGHT" -eq 1 ]; then
	ok "preflight passed: this host can start a release."
	exit 0
fi

# ============================================================================
# 1. CLEAN BUILD -- every image
# ============================================================================
section "1. clean build (all variants x release-supported MCUs)"
make clean >/dev/null
make attiny13a attiny85 attiny45 >"$EVID/build-avr-classic.log" 2>&1 || { cat "$EVID/build-avr-classic.log" >&2; die "AVR build failed."; }
# ATtiny202: STRICT_TOOLS=1 so an absent ATtiny_DFP is a hard failure here rather
# than a clean skip that would leave build_avr_xt/ empty and be caught much later
# as three missing images.
make attiny202 STRICT_TOOLS=1 XT_DFP="$XT_DFP" >"$EVID/build-avr-xt.log" 2>&1 \
	|| { cat "$EVID/build-avr-xt.log" >&2; die "ATtiny202 build failed."; }
make pic10f322 PIC_CC="$PIC_CC" PIC_DFP="$PIC_DFP" >"$EVID/build-pic10f322.log" 2>&1 || { cat "$EVID/build-pic10f322.log" >&2; die "PIC build failed."; }
# pic10f320-variants builds all three and, on any failure, removes the WHOLE image
# set rather than leaving a partial matrix behind for a later step to stage.
make pic10f320-variants PIC10F320_CC="$PIC10F320_CC" PIC10F320_DFP="$PIC10F320_DFP" \
	>"$EVID/build-pic10f320.log" 2>&1 \
	|| { cat "$EVID/build-pic10f320.log" >&2; die "PIC10F320 build failed."; }

# Enumerate the expected image set and assert each exists.
IMAGES=()
AVR_IMAGES=()
AVR_ELFS=()
XT_IMAGES=()
XT_ELFS=()
PIC_IMAGES=()
PIC10F320_IMAGES=()
for v in $VARIANTS; do
	img="$(fw_image "$AVR_BUILD_DIR" "$ATTINY13A_MCU" "$v").hex"
	elf="${img%.hex}.elf"
	IMAGES+=("$img"); AVR_IMAGES+=("$img"); AVR_ELFS+=("$elf")
done
for v in $VARIANTS; do for n in $TINYX5; do
	img="$(fw_image "$AVR_BUILD_DIR" "attiny${n}" "$v").hex"
	elf="${img%.hex}.elf"
	IMAGES+=("$img"); AVR_IMAGES+=("$img"); AVR_ELFS+=("$elf")
done; done
# ATtiny202 is kept in its own arrays rather than folded into AVR_IMAGES: the
# classic lane's final step regenerates HEX from validated ELFs with
# `make attiny13a attiny85 attiny45`, which knows nothing about the AVR-XT build.
for v in $XT_VARIANTS; do
	img="$(fw_image "$XT_BUILD_DIR" "$XT_TAG" "$v").hex"
	elf="${img%.hex}.elf"
	IMAGES+=("$img"); XT_IMAGES+=("$img"); XT_ELFS+=("$elf")
done
for v in $VARIANTS; do
	img="$(fw_image "$PIC10F322_BUILD_DIR" "$PIC10F322_TAG" "$v").hex"
	IMAGES+=("$img"); PIC_IMAGES+=("$img")
done
for v in $PIC10F320_VARIANTS; do
	img="$(fw_image "$PIC10F320_BUILD_DIR" "$PIC10F320_TAG" "$v").hex"
	IMAGES+=("$img"); PIC_IMAGES+=("$img"); PIC10F320_IMAGES+=("$img")
done
for img in "${IMAGES[@]}"; do [ -f "$img" ] || die "expected image not produced: $img"; done

# Cross-check the enumeration against the canonical set BEFORE any validation
# runs, so a mismatch costs seconds rather than a 24-hour soak. This is the
# check that catches a forgotten build step: the enumeration above is derived
# from the same variant matrices as the build commands, so it would shrink in
# lock-step with an omission and never notice. RELEASE_IMAGES would not.
enumerated=$(for img in "${IMAGES[@]}"; do basename "$img"; done | LC_ALL=C sort)
canonical=$(printf '%s\n' $RELEASE_IMAGES | LC_ALL=C sort)
if [ "$enumerated" != "$canonical" ]; then
	log "release set mismatch (left: built by this script, right: Makefile RELEASE_IMAGES):"
	diff -u <(printf '%s\n' "$enumerated") <(printf '%s\n' "$canonical") >&2 || true
	die "the images this release builds do not match the canonical release product set."
fi
ok "built ${#IMAGES[@]} images; set matches the canonical RELEASE_IMAGES exactly."

# Structural Intel-HEX validation of every PIC10F320 image. The PIC10F322 lane
# gets this inside `make pic10f322`, and the 320's `make pic10f320` validates each image
# as it is produced; repeating it here covers the window between build and
# staging, and costs nothing.
for img in "${PIC10F320_IMAGES[@]}"; do
	scripts/validate-ihex.sh "$img" >/dev/null \
		|| die "PIC10F320 image failed Intel-HEX validation: $img"
done
ok "all ${#PIC10F320_IMAGES[@]} PIC10F320 images are structurally valid Intel HEX."

# Byte identity against the previous release, for a release whose claim is that
# only the filenames moved. Run HERE so a changed byte costs seconds instead of
# a 24-hour soak, then run the same check again over the final validated images
# immediately before staging. Validation rebuilds these paths, so only the
# second report is retained as evidence about what is actually released.
#
# No version appears in this call and none is needed: the script reads which two
# releases the published rename table in release/README.md is about, and says so
# and does nothing for any other version. It therefore needs no maintenance
# between releases and cannot become a false alarm the first time a release
# legitimately changes a byte.
RENAME_IDENTITY_DOC=""
verify_rename_identity() {
	local phase=$1
	if ! scripts/verify-rename-identity.sh "$VERSION" "${IMAGES[@]}" \
			>"$WORK/RENAME_IDENTITY.md" 2>"$WORK/rename-identity.err"; then
		cat "$WORK/RENAME_IDENTITY.md" >&2
		cat "$WORK/rename-identity.err" >&2
		die "$phase images are not byte-identical to the release the rename table maps from."
	fi
	if head -1 "$WORK/RENAME_IDENTITY.md" | grep -q '^rename identity: not applicable'; then
		RENAME_IDENTITY_DOC=""
		log "$(cat "$WORK/RENAME_IDENTITY.md")"
	else
		RENAME_IDENTITY_DOC="$WORK/RENAME_IDENTITY.md"
		ok "$phase: $(grep -E '^identical=' "$RENAME_IDENTITY_DOC") -- byte identity against the previous release."
	fi
}
verify_rename_identity "initial build"

hash_avr_elf_set() {
	local elf
	for elf in "$@"; do
		[ -f "$elf" ] && [ ! -L "$elf" ] && [ -s "$elf" ] \
			|| die "validated classic AVR ELF missing, empty, or not regular: $elf"
	done
	sha256sum -- "$@"
}

hash_pic_image_set() {
	local image result hash
	for image in "$@"; do
		[ -f "$image" ] && [ ! -L "$image" ] && [ -s "$image" ] \
			|| die "validated PIC image missing, empty, or not regular: $image"
		result=$(sha256sum -- "$image") || return 1
		hash=${result%% *}
		printf '%s  %s\n' "$hash" "${image##*/}"
	done
}

# The AVR-XT equivalent, over HEX *and* ELF. Both matter: the staged artifact is
# the HEX, but every yasimavr gate and the whole soak phase drive the ELF, so
# evidence is only bound to the shipped image while the pair stays in step.
# `make attiny202` rebuilds unconditionally (its recipe removes its outputs
# first), so this is also the check that the build is actually reproducible
# across the several times validation re-enters it.
hash_xt_image_set() {
	local f result hash
	for f in "$@"; do
		[ -f "$f" ] && [ ! -L "$f" ] && [ -s "$f" ] \
			|| die "validated ATtiny202 artifact missing, empty, or not regular: $f"
		result=$(sha256sum -- "$f") || return 1
		hash=${result%% *}
		printf '%s  %s\n' "$hash" "${f##*/}"
	done
}

# ============================================================================
# 2. FULL PRE-HARDWARE GATES
# ============================================================================
section "2. validation: test-long + ATtiny202 and both PIC chips' pre-hardware/target gates"
log "running make test-long (exhaustive AVR suite + mutation)..."
make test-long STRICT_TOOLS=1 MUTATION_ALLOW_SKIP=0 \
	CC="$AVR_CC" OBJCOPY="$AVR_OBJCOPY" SIZE="$AVR_SIZE" \
	OBJDUMP="$AVR_OBJDUMP" READELF="$READELF" IHEX_VALIDATOR="$IHEX_VALIDATOR" \
	AWK="$AWK" HOSTCC="$HOST_CC" PIC10F320_HOST_CC="$PIC10F320_HOST_CC" \
	CLANG="$CLANG" ANALYZE_CMD="$ANALYZE_CMD" CPPCHECK="$CPPCHECK" \
	CBMC="$CBMC" GCOV="$GCOV" GPSIM="$GPSIM" SIMAVR_INC="$SIMAVR_INC" \
	PIC_CC="$PIC_CC" PIC_DFP="$PIC_DFP" \
	PIC_XC8_INCLUDE="$PIC_XC8_INCLUDE" PIC10F322_DFP_INCLUDE="$PIC10F322_DFP_INCLUDE" \
	PIC10F322_DEVICE_INI="$PIC10F322_DEVICE_INI" \
	PIC10F320_CC="$PIC10F320_CC" PIC10F320_DFP="$PIC10F320_DFP" \
	PIC10F320_XC8_INCLUDE="$PIC10F320_XC8_INCLUDE" \
	PIC10F320_DFP_INCLUDE="$PIC10F320_DFP_INCLUDE" \
	PIC10F320_DEVICE_INI="$PIC10F320_DEVICE_INI" \
	PIC_SOAK_CXX="$PIC_SOAK_CXX" PIC10F320_SOAK_CXX="$PIC10F320_SOAK_CXX" \
	PIC_SOAK_GPSIM_INC="$PIC_SOAK_GPSIM_INC" \
	PIC10F320_SOAK_GPSIM_INC="$PIC10F320_SOAK_GPSIM_INC" \
	XT_DFP="$XT_DFP" YASIMAVR_VENV="$YASIMAVR_VENV" \
	>"$EVID/test-long.log" 2>&1 \
	|| { tail -40 "$EVID/test-long.log" >&2; die "make test-long FAILED."; }
ok "test-long passed."
validated_avr_elf_hashes=$(hash_avr_elf_set "${AVR_ELFS[@]}")

# ATtiny202 pre-hardware gates: fuses, smoke, build + 2 KB budget, cppcheck +
# MISRA, and the coil-pulse width oracle read back out of the built image.
log "running make attiny202-test (fuses + build/budget + analysis + delay oracle)..."
make attiny202-test STRICT_TOOLS=1 XT_DFP="$XT_DFP" \
	>"$EVID/attiny202-test.log" 2>&1 \
	|| { tail -40 "$EVID/attiny202-test.log" >&2; die "make attiny202-test FAILED."; }
ok "attiny202-test passed."

# Fail-closed AVR-XT target aggregate (yasimavr), the counterpart of the two PIC
# target aggregates below: per variant, functional + physical PA2/PA3 output
# trace, critical-SFR/state fault injection, and firmware/model ctx_ lock-step.
# STRICT_TOOLS=1 converts each driver's clean skip into a hard failure.
log "running make attiny202-test-target (sim + fault + lock-step on the real image)..."
make attiny202-test-target STRICT_TOOLS=1 XT_DFP="$XT_DFP" \
	YASIMAVR_VENV="$YASIMAVR_VENV" \
	>"$EVID/attiny202-test-target.log" 2>&1 \
	|| { tail -60 "$EVID/attiny202-test-target.log" >&2; die "make attiny202-test-target FAILED."; }
ok "attiny202-test-target passed."
validated_xt_image_hashes=$(hash_xt_image_set "${XT_IMAGES[@]}")
validated_xt_elf_hashes=$(hash_xt_image_set "${XT_ELFS[@]}")

log "running make pic10f322-test (PIC CONFIG word + analyze + gpsim)..."
make pic10f322-test STRICT_TOOLS=1 PIC_CC="$PIC_CC" PIC_DFP="$PIC_DFP" >"$EVID/pic10f322-test.log" 2>&1 || { tail -40 "$EVID/pic10f322-test.log" >&2; die "make pic10f322-test FAILED."; }
ok "pic10f322-test passed."

# Fail-closed PIC target aggregate (libgpsim): per variant, require target fault
# recovery, firmware/model ctx_ lock-step, and GPIO transition/pulse timing PASS
# sentinels. This target converts the standalone skip-clean libgpsim drivers into
# a release gate: any missing tool, missing ctx_ symbol, skipped subtarget, or
# partial run is a hard failure.
log "running make pic10f322-test-target-variants (fault + lock-step + target I/O on the real HEX)..."
make pic10f322-test-target-variants STRICT_TOOLS=1 PIC_CC="$PIC_CC" PIC_DFP="$PIC_DFP" \
	>"$EVID/pic10f322-test-target-variants.log" 2>&1 \
	|| { tail -60 "$EVID/pic10f322-test-target-variants.log" >&2; die "make pic10f322-test-target-variants FAILED."; }
ok "pic10f322-test-target-variants passed."

log "running make pic10f320-test (PIC10F320 host lanes + hashes + CONFIG + stack + analysis + gpsim, all variants)..."
make pic10f320-test STRICT_TOOLS=1 PIC10F320_CC="$PIC10F320_CC" PIC10F320_DFP="$PIC10F320_DFP" \
	>"$EVID/pic10f320-test.log" 2>&1 \
	|| { tail -60 "$EVID/pic10f320-test.log" >&2; die "make pic10f320-test FAILED."; }
ok "pic10f320-test passed."

log "running make pic10f320-test-target-variants (fault + lock-step + target I/O on the real HEX)..."
make pic10f320-test-target-variants STRICT_TOOLS=1 \
	PIC10F320_CC="$PIC10F320_CC" PIC10F320_DFP="$PIC10F320_DFP" \
	>"$EVID/pic10f320-test-target-variants.log" 2>&1 \
	|| { tail -60 "$EVID/pic10f320-test-target-variants.log" >&2; die "make pic10f320-test-target-variants FAILED."; }
ok "pic10f320-test-target-variants passed."
validated_pic_image_hashes=$(hash_pic_image_set "${PIC_IMAGES[@]}")

# ============================================================================
# 3. PARALLEL SOAK -- every release combo, full duration
# ============================================================================
section "3. soak (all release combos, parallel, ${SOAK_DURATION_MS} ms each)"

# Build metadata for every soak combo: a binary, the cwd to run it from, a log.
declare -a SOAK_NAMES=()
declare -A SOAK_BIN SOAK_CWD SOAK_LOG SOAK_RC

log "compiling soak binaries..."
for v in $VARIANTS; do for p in $TINYX5_PARTS; do
	# The binary path is READ from the Makefile, not composed here. Unlike the
	# image basenames above -- restated on purpose so they can be cross-checked
	# against RELEASE_IMAGES -- this path is cross-checked against nothing, and
	# a copy of it here severed silently once already: v0.9.8 renamed the
	# release's soak COMBINATIONS, updated this line to the new _attiny<n>
	# spelling, and left AVR_SOAK_BIN saying _t<n>. `make` was then asked for a
	# target that did not exist, which fails the release an hour in, at step 3.
	name="${p}_${v}"
	bin=$(make -s print-AVR_SOAK_BIN AVR_SOAK_VARIANT="$v" AVR_SOAK_CHIP="$p") \
		|| die "cannot read AVR_SOAK_BIN for $name from the Makefile"
	[ -n "$bin" ] || die "AVR_SOAK_BIN expands empty for $name"
	elf="$(fw_image "$AVR_BUILD_DIR" "$p" "$v").elf"
	make --old-file="$elf" "$bin" AVR_REBUILD_PREREQ= \
		AVR_SOAK_VARIANT="$v" AVR_SOAK_CHIP="$p" AVR_SOAK_DURATION_MS="$SOAK_DURATION_MS" \
		AVR_SOAK_LIVENESS_INTERVAL_MS="$SOAK_LIVENESS_INTERVAL_MS" \
		AVR_SOAK_COMBINATION_NAME="$name" \
		>>"$EVID/soak-build.log" 2>&1 || die "failed to build AVR soak $name"
	SOAK_NAMES+=("$name"); SOAK_BIN[$name]="$REPO_ROOT/$bin"
	SOAK_CWD[$name]="$REPO_ROOT"   # relative FW_PATH; the binary writes no files
	SOAK_LOG[$name]="$EVID/soak-$name.log"
done; done
# ATtiny202: three more combos, one per output stage, at the same full duration
# as every other release combo. The driver is a Python script rather than a
# compiled binary, so each combo gets a tiny generated wrapper -- the soak
# launcher below execs one argument-less program per combination, and threading
# per-combo argv/env through it would complicate the one piece of this phase that
# must stay obviously correct. The wrapper pins the combination name that the
# driver binds into its SOAK_RESULT record, which validate_soak_result() then
# matches exactly, so a wrapper pointing at the wrong image cannot pass.
XT_FUSE_ENV_ARGS=()
for f in $XT_FUSE_NAMES; do
	XT_FUSE_ENV_ARGS+=("ATTINY202_FUSE_$(printf '%s' "$f" | tr '[:lower:]' '[:upper:]')=${XT_FUSE[$f]}")
done
for v in $XT_VARIANTS; do
	name="attiny202_${v}"; bin="$SOAKDIR/soak_attiny202_${v}.sh"
	elf="$REPO_ROOT/$(fw_image "$XT_BUILD_DIR" "$XT_TAG" "$v").elf"
	[ -f "$elf" ] || die "ATtiny202 soak ELF missing: $elf"
	{
		printf '#!/bin/sh\n'
		printf '# generated by make-release.sh -- ATtiny202 release soak combo %s\n' "$name"
		printf 'set -e\n'
		printf 'cd %q\n' "$REPO_ROOT"
		printf 'exec env PYTHONPATH=test/avr \\\n'
		for e in "${XT_FUSE_ENV_ARGS[@]}"; do printf '  %q \\\n' "$e"; done
		printf '  ATTINY202_SOAK_DURATION_MS=%q \\\n' "$SOAK_DURATION_MS"
		printf '  ATTINY202_SOAK_LIVENESS_INTERVAL_MS=%q \\\n' "$SOAK_LIVENESS_INTERVAL_MS"
		printf '  ATTINY202_SOAK_PROGRESS_INTERVAL_MS=%q \\\n' "$SOAK_LIVENESS_INTERVAL_MS"
		printf '  ATTINY202_SOAK_COMBINATION_NAME=%q \\\n' "$name"
		printf '  %q %q %q\n' "$YASIMAVR_PY_ABS" \
			"$REPO_ROOT/test/avr/test_soak_attiny202.py" "$elf"
	} > "$bin" || die "could not write ATtiny202 soak wrapper $bin"
	chmod +x "$bin" || die "could not make $bin executable"
	printf 'generated ATtiny202 soak wrapper: %s -> %s\n' "$name" "$elf" \
		>>"$EVID/soak-build.log"
	SOAK_NAMES+=("$name"); SOAK_BIN[$name]="$bin"
	SOAK_CWD[$name]="$REPO_ROOT"   # the wrapper cd's itself; nothing is written here
	SOAK_LOG[$name]="$EVID/soak-$name.log"
done
for v in $VARIANTS; do
	name="pic10f322_${v}"; bin="$SOAKDIR/test_soak_pic10f322_${v}"
	make "$bin" PIC10F322_SOAK_BIN="$bin" PIC10F322_SOAK_VARIANT="$v" PIC10F322_SOAK_DURATION_MS="$SOAK_DURATION_MS" \
		PIC10F322_SOAK_LIVENESS_INTERVAL_MS="$SOAK_LIVENESS_INTERVAL_MS" \
		PIC10F322_SOAK_COMBINATION_NAME="$name" \
		>>"$EVID/soak-build.log" 2>&1 || die "failed to build PIC soak $name"
	rundir="$SOAKDIR/run-$name"; mkdir -p "$rundir"
	SOAK_NAMES+=("$name"); SOAK_BIN[$name]="$bin"
	SOAK_CWD[$name]="$rundir"      # absolute FW_PATH; isolates gpsim.log per combo
	SOAK_LOG[$name]="$EVID/soak-$name.log"
done
# Three more combos, one per PIC10F320 output stage -- the same full duration as
# every other release combo, not a shortened smoke. Each drives its own real HEX
# in libgpsim. PIC10F320_SOAK_VARIANT selects the image; the driver itself is the
# shared parent one (§4: the parent copy is ahead, carrying SOAK_LIVENESS_DUE).
for v in $PIC10F320_VARIANTS; do
	name="pic10f320_${v}"; bin="$SOAKDIR/test_soak_pic10f320_${v}"
	make "$bin" PIC10F320_SOAK_BIN="$bin" PIC10F320_SOAK_VARIANT="$v" \
		PIC10F320_SOAK_DURATION_MS="$SOAK_DURATION_MS" \
		PIC10F320_SOAK_LIVENESS_INTERVAL_MS="$SOAK_LIVENESS_INTERVAL_MS" \
		PIC10F320_SOAK_COMBINATION_NAME="$name" \
		>>"$EVID/soak-build.log" 2>&1 || die "failed to build PIC10F320 soak $name"
	rundir="$SOAKDIR/run-$name"; mkdir -p "$rundir"
	SOAK_NAMES+=("$name"); SOAK_BIN[$name]="$bin"
	SOAK_CWD[$name]="$rundir"      # absolute FW_PATH; isolates gpsim.log per combo
	SOAK_LOG[$name]="$EVID/soak-$name.log"
done

# Soak harness compilation must not replace the ELFs that test-long exercised.
current_avr_elf_hashes=$(hash_avr_elf_set "${AVR_ELFS[@]}")
[ "$current_avr_elf_hashes" = "$validated_avr_elf_hashes" ] \
	|| die "a classic AVR ELF changed while compiling its soak harness"
current_pic_image_hashes=$(hash_pic_image_set "${PIC_IMAGES[@]}")
[ "$current_pic_image_hashes" = "$validated_pic_image_hashes" ] \
	|| die "a PIC image changed while compiling its soak harness"
current_xt_image_hashes=$(hash_xt_image_set "${XT_IMAGES[@]}")
current_xt_elf_hashes=$(hash_xt_image_set "${XT_ELFS[@]}")
{ [ "$current_xt_image_hashes" = "$validated_xt_image_hashes" ] \
	&& [ "$current_xt_elf_hashes" = "$validated_xt_elf_hashes" ]; } \
	|| die "an ATtiny202 image or ELF changed while preparing its soak wrappers"

NCOMBOS=${#SOAK_NAMES[@]}
actual_soaks=$(printf '%s\n' "${SOAK_NAMES[@]}" | LC_ALL=C sort)
canonical_soaks=$(printf '%s\n' $RELEASE_SOAK_NAMES | LC_ALL=C sort)
if [ "$actual_soaks" != "$canonical_soaks" ]; then
	diff -u <(printf '%s\n' "$canonical_soaks") <(printf '%s\n' "$actual_soaks") >&2 || true
	die "release soak combinations do not match canonical RELEASE_SOAK_NAMES"
fi
JOBS=$(release_jobs_cap "$JOBS" "$NCOMBOS") \
	|| die "could not resolve the release soak concurrency limit"
hours=$("$AWK" -v ms="$SOAK_DURATION_MS" 'BEGIN{printf "%.1f", ms/3600000}')
ncpu=$(nproc 2>/dev/null || echo "?")
log "launching $NCOMBOS soak combos, up to $JOBS at once (~${hours} h each; this box has $ncpu logical CPUs)."
[ "$JOBS" -lt "$NCOMBOS" ] && warn "more combos ($NCOMBOS) than the --jobs cap ($JOBS): total time scales up."

START_EPOCH=$(date +%s)
declare -A SOAK_PID
for name in "${SOAK_NAMES[@]}"; do
	# Throttle to JOBS concurrent runs.
	while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do sleep 5; done
	# Defer a signal only across this launch-and-track critical section. The
	# pending status is replayed immediately after the PID/process-group ID is in
	# SOAK_PIDS, so no child can escape cleanup in the `$!` assignment gap.
	TRACKING_WORKER=1
	( cd "${SOAK_CWD[$name]}" && exec setsid "${SOAK_BIN[$name]}" ) \
		>"${SOAK_LOG[$name]}" 2>&1 &
	SOAK_PID[$name]=$!
	SOAK_PIDS+=("${SOAK_PID[$name]}")
	TRACKING_WORKER=0
	if [ "$PENDING_SIGNAL_STATUS" -ne 0 ]; then
		pending=$PENDING_SIGNAL_STATUS
		PENDING_SIGNAL_STATUS=0
		exit "$pending"
	fi
	log "  started $name (pid ${SOAK_PID[$name]})"
done

forget_soak_pid() {
	local target=$1 index
	for index in "${!SOAK_PIDS[@]}"; do
		[ "${SOAK_PIDS[$index]}" != "$target" ] || unset "SOAK_PIDS[$index]"
	done
}

# One exact terminal record is the machine contract shared by both harnesses.
# It binds the log to its combination and compile-time timing, requires the
# expected nonzero liveness-check count, and reports every failure counter.
expected_soak_checks=$((SOAK_DURATION_MS / SOAK_LIVENESS_INTERVAL_MS))
validate_soak_result() {
	local name=$1 log=$2 expected
	local -a records pass_lines
	mapfile -t records < <(grep '^SOAK_RESULT ' "$log" || true)
	[ "${#records[@]}" -eq 1 ] || return 1
	expected="SOAK_RESULT format=1 status=pass combination=$name duration_ms=$SOAK_DURATION_MS liveness_interval_ms=$SOAK_LIVENESS_INTERVAL_MS checks=$expected_soak_checks failures=0 watchdog_failures=0 liveness_failures=0"
	[ "${records[0]}" = "$expected" ] || return 1
	mapfile -t pass_lines < <(grep "^SOAK PASS: $SOAK_DURATION_MS ms " "$log" || true)
	[ "${#pass_lines[@]}" -eq 1 ] || return 1
	! grep -q '^SOAK FAIL' "$log"
}

# Wait for all and collect verdicts. Exit status and the complete machine record
# must agree; either one alone is insufficient evidence.
SOAK_FAILS=0
for name in "${SOAK_NAMES[@]}"; do
	if wait "${SOAK_PID[$name]}"; then SOAK_RC[$name]=0; else SOAK_RC[$name]=$?; fi
	forget_soak_pid "${SOAK_PID[$name]}"
	unset "SOAK_PID[$name]"
	if [ "${SOAK_RC[$name]}" -eq 0 ] \
			&& validate_soak_result "$name" "${SOAK_LOG[$name]}"; then
		ok "soak $name: PASS"
	else
		warn "soak $name: FAIL (exit ${SOAK_RC[$name]})  -- see ${SOAK_LOG[$name]}"
		SOAK_FAILS=$((SOAK_FAILS+1))
	fi
done
SOAK_PIDS=()
SOAK_WALL=$(( $(date +%s) - START_EPOCH ))

if [ "$SOAK_FAILS" -ne 0 ]; then
	die "$SOAK_FAILS soak combo(s) FAILED. No release staged. Logs in $WORK (preserved)."
fi
ok "all $NCOMBOS soak combos passed (wall-clock ${SOAK_WALL}s)."

current_avr_elf_hashes=$(hash_avr_elf_set "${AVR_ELFS[@]}")
[ "$current_avr_elf_hashes" = "$validated_avr_elf_hashes" ] \
	|| die "a classic AVR ELF changed after its final validation began"
current_pic_image_hashes=$(hash_pic_image_set "${PIC_IMAGES[@]}")
[ "$current_pic_image_hashes" = "$validated_pic_image_hashes" ] \
	|| die "a PIC image changed while its soak was running"
current_xt_image_hashes=$(hash_xt_image_set "${XT_IMAGES[@]}")
current_xt_elf_hashes=$(hash_xt_image_set "${XT_ELFS[@]}")
{ [ "$current_xt_image_hashes" = "$validated_xt_image_hashes" ] \
	&& [ "$current_xt_elf_hashes" = "$validated_xt_elf_hashes" ]; } \
	|| die "an ATtiny202 image or ELF changed while its soak was running"

# Validation and soak rebuild classic ELFs, invalidating their paired HEX files.
# Re-materialize HEX from those exact, just-tested ELFs without compiling again.
log "regenerating classic AVR HEX from the validated ELFs..."
rm -f -- "${AVR_IMAGES[@]}" \
	|| die "could not remove stale classic AVR HEX before final regeneration"
old_file_args=()
for elf in "${AVR_ELFS[@]}"; do old_file_args+=("--old-file=$elf"); done
make "${old_file_args[@]}" attiny13a attiny85 attiny45 AVR_REBUILD_PREREQ= \
	>"$EVID/final-image-build.log" 2>&1 \
	|| { tail -60 "$EVID/final-image-build.log" >&2; die "final classic HEX regeneration FAILED."; }
current_avr_elf_hashes=$(hash_avr_elf_set "${AVR_ELFS[@]}")
[ "$current_avr_elf_hashes" = "$validated_avr_elf_hashes" ] \
	|| die "a validated classic AVR ELF changed during final HEX regeneration"
for img in "${IMAGES[@]}"; do
	[ -f "$img" ] && [ ! -L "$img" ] && [ -s "$img" ] \
		|| die "validated release image missing, empty, or not regular after final regeneration: $img"
done
current_pic_image_hashes=$(hash_pic_image_set "${PIC_IMAGES[@]}")
[ "$current_pic_image_hashes" = "$validated_pic_image_hashes" ] \
	|| die "a validated PIC image changed before staging"
ok "all validated release images are present and nonempty."

# Replace the early fail-fast report with one computed from the exact final
# image paths that staging consumes. A rebuild that changed bytes after the
# early check must fail here, never leave stale evidence beside different files.
verify_rename_identity "final validated images"

# Builds and parallel soaks can run for 24 hours. The Make lock protects shared
# artifacts from other Make invocations, but intentionally cannot prevent a
# human or editor from changing source or moving HEAD. Recheck immediately
# before creating the release directory so the recorded commit still identifies
# the validated source. Dirty rehearsals retain their explicit warning policy.
if ! release_source_is_unchanged "$GIT_SHA" "$DRY_RUN"; then
	die "source provenance changed after validation. No release staged."
fi
ok "source provenance still matches $GIT_SHORT immediately before staging."
# An explicit dry-run output may live under a path controlled outside this
# worktree. Resolve it again after the long-running gates so replacing a parent
# with a symlink cannot redirect rehearsal artifacts into release/<version>.
release_output_path_is_safe "$REPO_ROOT" "$OUTPUT_DIR" "$RELEASE_MODE" "$VERSION"

# ============================================================================
# 4. STAGE THE RELEASE
# ============================================================================
section "4. stage $OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/evidence"
for img in "${IMAGES[@]}"; do cp -p "$img" "$OUTPUT_DIR/"; done

# Checksums over the images. Named EXPLICITLY, never globbed: `sha256sum ./*.hex`
# would faithfully record whatever happens to be sitting in the staging
# directory, so a stale image left by an earlier run would be checksummed,
# committed and published as part of this release. The verifier would then
# confirm it -- the producer and the verifier sharing one blind spot is the
# §14.8 hole from the writing side.
release_basenames=()
for img in "${IMAGES[@]}"; do release_basenames+=("$(basename "$img")"); done
( cd "$OUTPUT_DIR" && sha256sum -- "${release_basenames[@]}" > SHA256SUMS ) \
	|| die "could not checksum the staged release images"
STAGED_PIC_IMAGES=()
for img in "${PIC_IMAGES[@]}"; do STAGED_PIC_IMAGES+=("$OUTPUT_DIR/$(basename "$img")"); done
staged_pic_image_hashes=$(hash_pic_image_set "${STAGED_PIC_IMAGES[@]}")
[ "$staged_pic_image_hashes" = "$validated_pic_image_hashes" ] \
	|| die "a staged PIC image differs from the image exercised by the soak"
STAGED_XT_IMAGES=()
for img in "${XT_IMAGES[@]}"; do STAGED_XT_IMAGES+=("$OUTPUT_DIR/$(basename "$img")"); done
staged_xt_image_hashes=$(hash_xt_image_set "${STAGED_XT_IMAGES[@]}")
[ "$staged_xt_image_hashes" = "$validated_xt_image_hashes" ] \
	|| die "a staged ATtiny202 image differs from the image exercised by its gates and soak"

# ...and assert the staging directory holds exactly that set and nothing else,
# because publication (.github/workflows/release.yml) uploads by glob.
shopt -s nullglob dotglob
staged=()
for f in "$OUTPUT_DIR"/*.hex; do staged+=("$(basename "$f")"); done
shopt -u nullglob dotglob
staged_sorted=$(printf '%s\n' "${staged[@]}" | LC_ALL=C sort)
wanted_sorted=$(printf '%s\n' "${release_basenames[@]}" | LC_ALL=C sort)
if [ "$staged_sorted" != "$wanted_sorted" ]; then
	diff -u <(printf '%s\n' "$wanted_sorted") <(printf '%s\n' "$staged_sorted") >&2 || true
	die "$OUTPUT_DIR holds images that are not part of this release (stale output?)."
fi
ok "wrote SHA256SUMS over ${#IMAGES[@]} images; staging directory holds exactly that set."

# Retain the byte-identity proof beside the images it is about, for the one
# release it applies to. NOT under evidence/ -- that directory's contents are
# pinned exactly by RELEASE_EVIDENCE_FILES for EVERY release, and a file only
# this release produces would fail the next release's qualification verifier.
if [ -n "$RENAME_IDENTITY_DOC" ]; then
	cp -p "$RENAME_IDENTITY_DOC" "$OUTPUT_DIR/RENAME_IDENTITY.md" \
		|| die "could not retain the byte-identity proof"
	ok "retained RENAME_IDENTITY.md beside the images."
fi

# Copy evidence. The per-combo soak logs and build/pic10f322-test logs are small and
# kept in full; the exhaustive test-long log is large (100s of KB) and would
# bloat the repo on every release, so commit a concise summary instead -- the
# full log is reproduced (and archived) by the tag-triggered release CI run.
for f in "$EVID"/*.log; do
	case "$(basename "$f")" in
		test-long.log)
			{ echo "# test-long summary -- the full log is in the release CI run."; echo; \
			  grep -nE '^(===|--- |OK:|FAIL|cbmc:|MISRA|golden-model|killed|survived|mutant)' "$f" || true; \
			  echo; echo "# --- last 20 lines ---"; tail -20 "$f"; \
			} > "$OUTPUT_DIR/evidence/test-long.summary.txt" ;;
		*) cp -p "$f" "$OUTPUT_DIR/evidence/" ;;
	esac
done

# Compact machine-readable attestation. The verifier parses this as data (never
# sources it), then cross-checks it against the canonical evidence inventory,
# every terminal soak record, and the human-readable manifest.
{
	printf 'format=1\n'
	printf 'version=%s\n' "$VERSION"
	printf 'release_mode=%s\n' "$RELEASE_MODE"
	printf 'source_commit=%s\n' "$GIT_SHA"
	printf 'source_dirty=%s\n' "$GIT_DIRTY"
	printf 'soak_duration_ms=%s\n' "$SOAK_DURATION_MS"
	printf 'soak_liveness_interval_ms=%s\n' "$SOAK_LIVENESS_INTERVAL_MS"
	printf 'soak_combination_count=%s\n' "$NCOMBOS"
} > "$OUTPUT_DIR/QUALIFICATION"

# --- per-image facts for the manifest (target, clock, fuses, flashing cmd) ----
# Echoes a markdown table row for one image path.
img_row() {
	local path="$1" base; base=$(basename "$path")
	local sha; sha=$("$AWK" -v f="$base" '$2==f{print $1}' "$OUTPUT_DIR/SHA256SUMS")
	# Flash usage is read from the build ELF (the HEX does not carry section
	# sizes avr-size can total); the ELF is still present in $AVR_BUILD_DIR when
	# the manifest is generated. PIC usage stays n/a (XC8 reports words, not bytes).
	local elf="$AVR_BUILD_DIR/${base%.hex}.elf"
	local mcu clk fuses flashcmd prog amcu used="n/a"
	# Every arm below matches the MANDATORY MCU field of the canonical basename
	# (<prefix>-<mcu>-<stage>), so the arms are mutually exclusive and order
	# carries no meaning. That is a change worth noticing: this used to be an
	# ORDER-DEPENDENT chain ending in a bare `*.hex` ATtiny13a fallback, because
	# a bare `bypass_cd4053.hex` was the ATtiny13a image. Any unrecognized name
	# fell through to that arm and produced a row confidently labelling foreign
	# firmware as an ATtiny13a with AVR fuse bytes. With the MCU always present
	# the fallback becomes a hard error instead.
	case "$base" in
		${FW_BASE}-${PIC10F320_TAG}-*.hex)
			mcu="PIC10F320"; clk="${PIC10F320_CLK_MHZ} MHz (HFINTOSC)"; fuses="CONFIG word embedded in HEX"
			# XC8 reports program space in WORDS, not bytes; the figure comes from
			# this run's own build log, so it can never be a stale hand-copied number.
			used=$("$AWK" -v f="$base" '$0 ~ ("/" f " :") { for (i = 1; i <= NF; i++) if ($i == "words") { print $(i-1) " / '"$PIC10F320_FLASH_WORDS"' words"; exit } }' \
				"$EVID/build-pic10f320.log" 2>/dev/null)
			flashcmd="pk2cmd -PPIC10F320 -F$base -M -Y -R" ;;
		${FW_BASE}-${PIC10F322_TAG}-*.hex)
			mcu="PIC10F322"; clk="${PIC10F322_CLK_MHZ} MHz (HFINTOSC)"; fuses="CONFIG word embedded in HEX"
			flashcmd="pk2cmd -PPIC10F322 -F$base -M -Y -R   (or: make pic10f322-program VARIANT=<v>)" ;;
		${FW_BASE}-${XT_TAG}-*.hex)
			mcu="ATtiny202"; clk="${XT_CLK_MHZ} MHz (internal, OSCCFG 16 MHz / 8)"
			# AVR8X replaces lfuse/hfuse with seven individually named memories;
			# enumerate them rather than inventing a two-byte summary.
			fuses=""
			for f in $XT_FUSE_NAMES; do
				fuses="${fuses}${fuses:+ }$f=${XT_FUSE[$f]}"
			done
			# From this run's own build log, like the PIC10F320 arm: the figure is
			# never a stale hand-copied number, and avr-size cannot total it here
			# (binutils 2.26 reports "Device: Unknown" for avrxmega3 parts).
			used=$("$AWK" -v f="$base" '$0 ~ ("/" f " :") { for (i = 1; i <= NF; i++) if ($i == "B") { print $(i-1) " B"; exit } }' \
				"$EVID/build-avr-xt.log" 2>/dev/null)
			flashcmd="avrdude -c $XT_PROGRAMMER -P <port> -p $XT_AVRDUDE_PART"
			for f in $XT_FUSE_NAMES; do
				flashcmd="$flashcmd -U $f:w:${XT_FUSE[$f]}:m"
			done
			flashcmd="$flashcmd -U flash:w:$base:i   (or: make attiny202-program VARIANT=<v> XT_UPDI_PORT=<port>)" ;;
		${FW_BASE}-attiny85-*.hex|${FW_BASE}-attiny45-*.hex)
			case "$base" in
				${FW_BASE}-attiny85-*.hex) mcu="ATtiny85"; amcu="attiny85" ;;
				*)                         mcu="ATtiny45"; amcu="attiny45" ;;
			esac
			# From the Makefile's part_<n>, like the other four arms. The
			# literals this replaces were the only programmer names in the
			# manifest not taken from Makefile truth -- and AVRDUDE_PART_X5 was
			# built above and then read by nobody, so the whole `mkv` preamble
			# was validating a value it discarded.
			prog=${AVRDUDE_PART_X5[${amcu#attiny}]:-}
			[ -n "$prog" ] \
				|| die "no avrdude part name for $amcu: TINYX5 and this manifest arm disagree"
			clk="1.0 MHz"; fuses="lfuse=$LFUSE_X5 hfuse=$HFUSE_X5"
			used=$("$AVR_SIZE" --mcu="$amcu" -C "$elf" 2>/dev/null | "$AWK" '/^Program:/{print $2" B"; exit}')
			flashcmd="avrdude -c <prog> -p $prog -U lfuse:w:$LFUSE_X5:m -U hfuse:w:$HFUSE_X5:m -U flash:w:$base:i" ;;
		${FW_BASE}-${ATTINY13A_MCU}-*.hex)
			mcu="ATtiny13a"; clk="1.2 MHz"; fuses="lfuse=$LFUSE hfuse=$HFUSE"
			used=$("$AVR_SIZE" --mcu=attiny13a -C "$elf" 2>/dev/null | "$AWK" '/^Program:/{print $2" B"; exit}')
			flashcmd="avrdude -c <prog> -p $AVRDUDE_PART -U lfuse:w:$LFUSE:m -U hfuse:w:$HFUSE:m -U flash:w:$base:i" ;;
		*) die "release image '$base' names no MCU this manifest generator knows; refusing to describe it" ;;
	esac
	printf '| `%s` | %s | %s | %s | %s | `%s` |\n' "$base" "$mcu" "$clk" "${used:-n/a}" "$fuses" "$sha"
	printf '%s\t%s\n' "$base" "$flashcmd" >> "$WORK/flashcmds.txt"
}

# Soak evidence summary table.
soak_table() {
	local name f
	local -a lines
	for name in "${SOAK_NAMES[@]}"; do
		f="$OUTPUT_DIR/evidence/soak-$name.log"
		mapfile -t lines < <(grep "^SOAK PASS: $SOAK_DURATION_MS ms " "$f" || true)
		[ "${#lines[@]}" -eq 1 ] \
			|| die "cannot render one exact soak summary for $name"
		printf '| %s | %s |\n' "$name" "${lines[0]}"
	done
}

REL_BANNER=""
[ "$DRY_RUN" -eq 1 ] && REL_BANNER=$'> **DRY RUN -- NOT A VALIDATED RELEASE.** Soak duration was reduced; do not publish.\n'

: > "$WORK/flashcmds.txt"
{
	printf '# Firmware release %s\n\n' "$VERSION"
	[ -n "$REL_BANNER" ] && printf '%s\n' "$REL_BANNER"
	if [ "$DRY_RUN" -eq 1 ]; then
		printf 'Prebuilt firmware rehearsal images; not fully validated. Verify integrity with\n'
	else
		printf 'Prebuilt, fully-validated firmware images. Verify integrity with\n'
	fi
	printf '`sha256sum -c SHA256SUMS`; reproduce from source per "Reproducing" below.\n\n'
	printf 'Release scope: AVR Classic (ATtiny13a/45/85), ATtiny202 (AVR-XT),\n'
	printf 'PIC10F322 and PIC10F320.\n\n'

	printf '## PIC10F320 -- the constrained target\n\n'
	printf 'The PIC10F320 has 256 words of flash, half the PIC10F322. The pure/result-struct\n'
	printf 'architecture every other target compiles into its shipping image does not fit, so\n'
	printf 'its firmware inlines the debounce algorithm into `main()` by hand. It is fully\n'
	printf 'release-gated -- firmware-to-core equivalence against the same verified\n'
	printf '`src/bypass_pure.c`, real-HEX lock-step, host and target fault injection, exact\n'
	printf 'firmware line coverage, and its own %s-h soak per output stage -- but the\n' "$hours"
	printf 'inlining seam means its architecture is not identical to the other targets.\n'
	printf 'It is the constrained exception, not evidence that the reference architecture\n'
	printf 'fits 256 words.\n\n'
	if [ -f "$REPO_ROOT/docs/pic10f320_special_case.md" ]; then
		# Absolute and tag-pinned: this file is both committed at
		# release/<version>/MANIFEST.md and published verbatim as the GitHub
		# Release body, where '../../' does not resolve. The tag does not exist
		# yet at generation time -- it is created from this very run -- so the
		# link goes live when the release is pushed. (Under --dry-run no tag is
		# ever created, so the link will 404; the dry-run banner already says
		# the output is not a real release.)
		printf 'Full detail: [docs/pic10f320_special_case.md](%s/blob/%s/docs/pic10f320_special_case.md).\n\n' \
			"$REPO_URL" "$VERSION"
	fi
	printf 'Its images follow the same `%s-<mcu>-<output stage>.hex` scheme as every\n' "$FW_BASE"
	printf 'other target (`%s-%s-<output stage>.hex`); the imported `bypass_mcu_` prefix\n' "$FW_BASE" "$PIC10F320_TAG"
	printf 'it shipped with through v0.9.7 is gone as of v0.9.8.\n\n'

	printf '## Provenance\n\n'
	printf -- '- **Version / tag:** %s\n' "$VERSION"
	printf -- '- **Release mode:** %s\n' "$RELEASE_MODE"
	printf -- '- **Source commit:** `%s`\n' "$GIT_SHA"
	printf -- '- **Soak duration per combination:** %s ms\n' "$SOAK_DURATION_MS"
	printf -- '- **Soak combinations:** %s\n' "$NCOMBOS"
	[ "$GIT_DIRTY" -eq 1 ] && printf -- '- **WARNING:** built from a DIRTY tree (uncommitted changes not captured by the SHA).\n'
	printf -- '- **Built:** %s by `%s` on `%s`\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${USER:-?}" "$(uname -srm)"
	printf -- '- **Validation:** `make test-long` + `make attiny202-test` + `make attiny202-test-target` + `make pic10f322-test` + `make pic10f322-test-target-variants` + `make pic10f320-test` + `make pic10f320-test-target-variants` (real-image fault handling, firmware/model ctx_ lock-step, and physical-output checks across AVR-XT and both PIC parts) + %s-h parallel soak of every release soak combination (see evidence/).\n' "$hours"
	printf -- '- **Release set:** %d images, checked against the canonical `RELEASE_IMAGES` set declared in the Makefile -- not against whatever the build happened to produce.\n' "${#IMAGES[@]}"
	if [ -n "$RENAME_IDENTITY_DOC" ]; then
		printf -- '- **Byte identity:** every renamed image was hashed against its counterpart in the previous release, through the old-to-new table in `release/README.md`. Table and verdict: `RENAME_IDENTITY.md`.\n'
	fi
	printf '\n'

	printf '## Toolchain\n\n'
	printf -- '| tool | version |\n|---|---|\n'
	printf -- '| avr-gcc | %s |\n' "$TC_AVR_GCC"
	printf -- '| binutils-avr (objcopy) | %s |\n' "$TC_AVR_BU"
	printf -- '| avr-libc (pkg) | %s |\n' "$TC_AVR_LIBC"
	printf -- '| host cc | %s |\n' "$TC_HOST_CC"
	printf -- '| PIC10F322 XC8 (`PIC_CC=%s`) | %s |\n' "$PIC_CC" "$TC_XC8_322"
	printf -- '| PIC10F320 XC8 (`PIC10F320_CC=%s`) | %s |\n' "$PIC10F320_CC" "$TC_XC8_320"
	printf -- '| PIC10F322 DFP | %s |\n' "$PIC_DFP"
	printf -- '| PIC10F320 DFP | %s |\n' "$PIC10F320_DFP"
	printf -- '| gpsim | %s |\n' "$TC_GPSIM"
	printf -- '| libsimavr-dev (pkg) | %s |\n' "$TC_SIMAVR"
	printf -- '| cppcheck | %s |\n' "$TC_CPPCHECK"
	printf -- '| cbmc | %s |\n' "$TC_CBMC"
	printf -- '| clang | %s |\n' "$TC_CLANG"
	printf -- '| python3 | %s |\n\n' "$TC_PY"

	printf '## Images\n\n'
	printf '| image | MCU | clock | flash used | fuses / config | sha256 |\n'
	printf '|---|---|---|---|---|---|\n'
	for img in "${IMAGES[@]}"; do img_row "$OUTPUT_DIR/$(basename "$img")"; done
	printf '\n> The ATtiny13a images are not soak-tested directly (simavr cannot model\n'
	printf '> its watchdog reset); they are covered by the full test-long suite and by\n'
	printf '> the soak of the core-identical tinyx5 family. See DESIGN_DOCUMENTATION.adoc.\n\n'

	printf '## Flashing\n\n'
	printf 'AVR images require the design fuse bytes in addition to the flash write\n'
	printf '(the table above lists them per image). PIC images embed their CONFIG word.\n\n'
	printf '```\n'
	sort "$WORK/flashcmds.txt" | while IFS=$'\t' read -r f cmd; do printf '# %s\n%s\n\n' "$f" "$cmd"; done
	printf '```\n\n'

	printf '## Soak evidence\n\n'
	printf '| combo | result |\n|---|---|\n'
	soak_table
	printf '\n'

	printf '## Reproducing these images\n\n'
	printf 'Check the images this tag *builds* against the committed checksums. A\n'
	printf 'freshly built HEX lands under %s, not\n' \
		"$(printf '%s\n' $RELEASE_IMAGE_DIRS | sed 's#^#`#; s#$#/`#' | paste -sd' ' -)"
	printf 'in this release directory, so the checksum list must be run against those\n'
	printf 'fresh bytes (running it from the repo root would just re-verify the\n'
	printf 'committed copies against themselves).\n\n'
	printf '```\n'
	printf 'git checkout %s\n' "$VERSION"
	printf '# install the pinned toolchain (see TOOLCHAIN.adoc), then:\n'
	printf 'make clean && make attiny13a attiny85 attiny45 && make attiny202\n'
	printf 'make pic10f322 && make pic10f320-variants\n'
	printf 'scripts/verify-release-images.sh release/%s %s\n' "$VERSION" "$RELEASE_IMAGE_DIRS"
	printf '```\n'
	printf 'A passing verifier proves four things agree: the committed files, the checksum\n'
	printf 'entries, the freshly built files, and the canonical `RELEASE_IMAGES` set the\n'
	printf 'Makefile declares. The fourth is what makes the first three mean something --\n'
	printf 'three sets derived by globbing the same directories agree perfectly on a\n'
	printf 'release that is missing an entire MCU.\n'
	printf 'The tag-triggered CI (.github/workflows/release.yml) runs this exact check on a\n'
	printf 'clean runner and fails the release on any mismatch.\n'
} > "$OUTPUT_DIR/MANIFEST.md"
ok "wrote MANIFEST.md"

# Per-version README (concise; points at the top-level release/README.md).
{
	printf '# %s\n\n' "$VERSION"
	[ -n "$REL_BANNER" ] && printf '%s\n' "$REL_BANNER"
	printf 'Prebuilt firmware for %s. See **MANIFEST.md** for provenance, the per-image\n' "$VERSION"
	printf 'fuse bytes / flashing commands, **QUALIFICATION** for the machine-verified\n'
	printf 'release gate, and evidence/ for the retained logs. See the top-level\n'
	printf '[release/README.md](../README.md) for the trust model and verification steps.\n\n'
	if [ -n "$RENAME_IDENTITY_DOC" ]; then
		printf 'This release renamed its images. **RENAME_IDENTITY.md** is the check of the\n'
		printf 'claim that only the names moved: every image hashed against its counterpart\n'
		printf 'in the previous release.\n\n'
	fi
	printf 'Quick verify:\n```\ncd release/%s && sha256sum -c SHA256SUMS\n```\n' "$VERSION"
	printf '\nVerify the required checksum signature first:\n'
	printf '```\ngpg --verify SHA256SUMS.asc SHA256SUMS\n```\n'
} > "$OUTPUT_DIR/README.md"

if [ "$DRY_RUN" -eq 1 ]; then qualification_args=(--allow-dry-run); else qualification_args=(); fi
scripts/verify-release-qualification.sh "${qualification_args[@]}" "$OUTPUT_DIR" "$VERSION" \
	|| die "staged release qualification failed verification"
ok "release qualification metadata and evidence verified."

# Commit message for the human to use verbatim (git commit -F ...).
{
	printf 'release: firmware %s\n\n' "$VERSION"
	if [ "$DRY_RUN" -eq 1 ]; then
		printf 'Non-publishable dry-run rehearsal images for %s.\n\n' "$VERSION"
	else
		printf 'Prebuilt, fully-validated firmware images for %s.\n\n' "$VERSION"
	fi
	printf 'Built from %s with the toolchain pinned in TOOLCHAIN.adoc.\n' "$GIT_SHORT"
	printf 'Scope: AVR Classic (ATtiny13a/45/85), ATtiny202 (AVR-XT), PIC10F322 and\n'
	printf 'PIC10F320 -- %d images, checked against the canonical RELEASE_IMAGES set the\n' "${#IMAGES[@]}"
	printf 'Makefile declares rather than against whatever the build produced.\n\n'
	printf 'Validation: make test-long + make attiny202-test + make attiny202-test-target\n'
	printf '+ make pic10f322-test + make pic10f322-test-target-variants\n'
	printf '+ make pic10f320-test + make pic10f320-test-target-variants\n'
	printf '+ %s-h parallel soak of every release soak combination (evidence under\n' "$hours"
	printf 'release/%s/evidence/).\n\n' "$VERSION"
	printf 'Reproducibility is pinned by release/%s/SHA256SUMS and verified on a\n' "$VERSION"
	printf 'clean runner by .github/workflows/release.yml when the tag is pushed.\n'
} > "$OUTPUT_DIR/commit_msg.txt"

# Fold evidence in and finish.
ls -1 "$OUTPUT_DIR" >&2

# ============================================================================
# 5. HAND OFF -- print the git + signing recipe (this script runs NOTHING below)
# ============================================================================
if [ "$DRY_RUN" -eq 1 ]; then
	section "DRY RUN complete"
	warn "This was a rehearsal with a short soak. Output staged at $OUTPUT_DIR is NOT a real release."
	warn "Re-run WITHOUT --dry-run (full 24-h soak) to produce a publishable release."
	exit 0
fi

# Everything below goes to STDOUT: the exact commands for the human to run.
cat <<EOF

$BOLD========== release $VERSION staged -- next steps (run by hand) ==========$RST

Review the staging dir, then sign + commit + tag + push. The pushed tag triggers
.github/workflows/release.yml, which reproduces the image hashes on a clean
runner and publishes the GitHub Release.

The release commit must contain ONLY $OUTPUT_DIR. Tag CI requires its sole
parent to be the source commit qualified above and rejects every changed path
outside release/$VERSION/. Finalize changelog/status documentation before
starting the production run. Ensure the remote protects v* tags from update and
deletion; CI rechecks the remote target immediately before publication, but no
workflow can make two separate GitHub API operations atomic.

  # 1. review
  git status
  less $OUTPUT_DIR/MANIFEST.md

  # 2. sign the checksums (detached, ASCII-armored) -- adds SHA256SUMS.asc
  gpg --local-user $RELEASE_SIGNING_FINGERPRINT --armor --detach-sign $OUTPUT_DIR/SHA256SUMS
  # 3. commit the whole release dir (uses the generated message)
  git add $OUTPUT_DIR
  git commit -F $OUTPUT_DIR/commit_msg.txt

  # 4. create a SIGNED, annotated tag on that commit
  git tag -s -u $RELEASE_SIGNING_FINGERPRINT $VERSION -m "Firmware release $VERSION"

  # 5. push the commit and the tag
  git push
  git push origin $VERSION

EOF
ok "done. Nothing was committed, tagged, or pushed -- that is yours to do."
