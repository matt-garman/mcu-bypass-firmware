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
#        word, and the validation evidence (test-long + pic-test + PIC target
#        aggregate + 24-h soak).
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
#   1. Clean-build every AVR + PIC variant image.
#   2. Run `make test-long`, `make pic-test`, and `make pic-test-target-variants`
#      (the full pre-hardware gates).
#   3. Run ALL soak combos (every variant x MCU) IN PARALLEL for the full
#      duration, collecting a pass/fail verdict and evidence from each.
#   4. Stage release/<VERSION>/ : the .hex images, SHA256SUMS, a provenance
#      MANIFEST, a README, the soak/validation evidence, and a commit message.
#   5. STOP. Print the exact git + signing commands for the human to run. This
#      script NEVER commits, tags, signs, or pushes -- per project policy all
#      modifying git operations are done by hand.
#
# USAGE
#   scripts/make-release.sh [options] <version>
#     <version>                vX.Y.Z (semantic version, leading 'v')
#   options:
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
VERSION=""
DRY_RUN=0
ALLOW_DIRTY=0
MIN_RELEASE_SOAK_MS=86400000
MAX_SOAK_DURATION_MS=4294967294    # uint32_t loop bound; preserve t + 1
SOAK_DURATION_MS=$MIN_RELEASE_SOAK_MS
JOBS=0                             # 0 => "all combos"
OUTPUT_DIR=""

usage() { sed -n '2,200p' "$0" | sed -n '/^# USAGE/,/^$/p' | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run)            DRY_RUN=1; shift ;;
		--allow-dirty)        ALLOW_DIRTY=1; shift ;;
		--soak-duration-ms)   SOAK_DURATION_MS="${2:?--soak-duration-ms needs a value}"; shift 2 ;;
		--jobs)               JOBS="${2:?--jobs needs a value}"; shift 2 ;;
		--output-dir)         OUTPUT_DIR="${2:?--output-dir needs a value}"; shift 2 ;;
		-h|--help)            usage; exit 0 ;;
		-*)                   die "unknown option: $1 (try --help)" ;;
		*)                    [ -z "$VERSION" ] || die "unexpected extra argument: $1"; VERSION="$1"; shift ;;
	esac
done

[ -n "$VERSION" ] || die "no <version> given (e.g. v1.0.0). Try --help."
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]] \
	|| die "version '$VERSION' is not vX.Y.Z (optionally -suffix)"

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
if [ "$DRY_RUN" -eq 0 ] && [ "$SOAK_DURATION_MS" -lt "$MIN_RELEASE_SOAK_MS" ]; then
	die "real releases require --soak-duration-ms >= $MIN_RELEASE_SOAK_MS (24 h); use --dry-run for a short rehearsal"
fi

if [ "$DRY_RUN" -eq 1 ]; then
	# A dry run is an explicit rehearsal: shorten the soak so the whole pipeline
	# finishes quickly, and tolerate an uncommitted tree (you typically rehearse
	# BEFORE committing the release scaffolding itself).
	[ "$SOAK_DURATION_MS" = "$MIN_RELEASE_SOAK_MS" ] && SOAK_DURATION_MS=60000
	ALLOW_DIRTY=1
fi

# ----------------------------------------------------------------------------
# Locate the repo and read the Makefile's single source of truth
# ----------------------------------------------------------------------------
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
cd "$REPO_ROOT"

mkv() { make -s print-"$1"; }      # echo one Makefile variable

VARIANTS=$(mkv VARIANTS)           # cd4053 mute relay
TINYX5=$(mkv TINYX5)               # 85 45
FW_BASE=$(mkv FW_BASE)             # bypass
AVR_BUILD_DIR=$(mkv AVR_BUILD_DIR) # build_avr_classic
PIC_BUILD_DIR=$(mkv PIC_BUILD_DIR) # build_pic
PIC_TAG=$(mkv PIC_TAG)             # pic10f322
PIC_XTAL=$(mkv PIC_XTAL)           # 2000000UL  (_XTAL_FREQ; drives __delay_ms)
# Human clock string for the manifest, derived from PIC_XTAL so it can never
# drift from the firmware's asserted _XTAL_FREQ / OSCCON IRCF setting.
PIC_CLK_MHZ=$(awk -v h="${PIC_XTAL//[!0-9]/}" 'BEGIN{printf (h%1000000?"%.1f":"%d"), h/1000000}')
PIC_GPSIM_PROC=$(mkv PIC_GPSIM_PROC)
LFUSE=$(mkv LFUSE);     HFUSE=$(mkv HFUSE)
LFUSE_X5=$(mkv LFUSE_X5); HFUSE_X5=$(mkv HFUSE_X5)
PIC_CC=$(mkv PIC_CC)
PIC_DFP=$(mkv PIC_DFP)
AVRDUDE_PART=$(mkv AVRDUDE_PART)   # t13
declare -A AVRDUDE_PART_X5
for n in $TINYX5; do AVRDUDE_PART_X5[$n]=$(mkv part_"$n"); done

# Scratch area for evidence + per-combo soak run dirs. Preserved on failure so a
# crashed/failed run can be inspected; folded into the release on success.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mcu-release.XXXXXX")"
EVID="$WORK/evidence"; SOAKDIR="$WORK/soak"
mkdir -p "$EVID" "$SOAKDIR"
KEEP_WORK=0
cleanup() { [ "${KEEP_WORK:-0}" = 1 ] || rm -rf "$WORK"; }
trap 'rc=$?; if [ $rc -ne 0 ]; then KEEP_WORK=1; warn "left working dir for inspection: $WORK"; fi; cleanup' EXIT

# Where to stage. A real release lands in the repo at release/<version>; a dry
# run lands in the auto-scratch WORK (kept, never littering the repo).
if [ -n "$OUTPUT_DIR" ]; then :;
elif [ "$DRY_RUN" -eq 1 ]; then OUTPUT_DIR="$WORK/release/$VERSION"; KEEP_WORK=1
else OUTPUT_DIR="release/$VERSION"
fi

# ============================================================================
# 0. PRECONDITIONS
# ============================================================================
section "0. preconditions"

[ "$DRY_RUN" -eq 1 ] && warn "DRY RUN: short ${SOAK_DURATION_MS}ms soak; output is NOT a real release."

# Clean working tree -- the provenance commit SHA must mean something. A real
# release requires it; a rehearsal (--dry-run / --allow-dirty) only warns.
GIT_DIRTY=0
if [ -n "$(git status --porcelain)" ]; then
	GIT_DIRTY=1
	if [ "$ALLOW_DIRTY" -eq 1 ]; then
		warn "working tree is DIRTY; provenance SHA $(git rev-parse --short HEAD) will not capture uncommitted changes."
	else
		git status --short >&2
		die "working tree is not clean. Commit/stash everything before releasing (or --dry-run to rehearse)."
	fi
fi

# Tag must not already exist (local or, if a remote is configured, remote).
git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null 2>&1 \
	&& die "tag $VERSION already exists."
if git remote get-url origin >/dev/null 2>&1; then
	git ls-remote --exit-code --tags origin "refs/tags/$VERSION" >/dev/null 2>&1 \
		&& die "tag $VERSION already exists on origin."
fi

# Output dir must not already exist (don't clobber a prior release).
[ -e "$OUTPUT_DIR" ] && die "$OUTPUT_DIR already exists; refusing to overwrite."

GIT_SHA=$(git rev-parse HEAD)
GIT_SHORT=$(git rev-parse --short HEAD)

# Required tools. A release FAILS LOUD on any absence (no silent skipping).
MISSING=()
have()      { command -v "$1" >/dev/null 2>&1; }
req_cmd()   { have "$1" || MISSING+=("$1${2:+  ($2)}"); }
req_file()  { [ -e "$1" ] || MISSING+=("$1${2:+  ($2)}"); }

req_cmd make
req_cmd avr-gcc        "apt: gcc-avr"
req_cmd avr-objcopy    "apt: binutils-avr (HEX bytes + reproducibility)"
req_cmd avr-size       "apt: binutils-avr"
req_cmd cc             "host C compiler"
req_file /usr/include/simavr/sim_avr.h "apt: libsimavr-dev"
req_cmd clang          "apt: clang (analyze-deep)"
req_cmd clang-tidy     "apt: clang-tidy (analyze)"
req_cmd cppcheck       "apt: cppcheck (analyze + MISRA)"
req_cmd cbmc           "apt: cbmc (formal proof in test-long)"
req_cmd python3        "MISRA addon"
# PIC toolchain (paths come from the Makefile defaults / PIC_CC, PIC_DFP).
req_file "$PIC_CC"                                  "XC8 (PIC_CC=)"
req_file "$PIC_DFP/pic/include/proc/pic10f322.h"    "PIC10-12Fxxx DFP (PIC_DFP=)"
req_cmd gpsim          "apt: gpsim (pic-test-gpsim)"
req_cmd c++            "host C++ compiler (PIC soak)"
req_file /usr/include/gpsim/sim_context.h           "apt: gpsim-dev (PIC soak)"
pkg-config --exists glib-2.0 2>/dev/null || MISSING+=("glib-2.0  (apt: libglib2.0-dev, PIC soak)")

if [ "${#MISSING[@]}" -gt 0 ]; then
	log "Required tools/headers MISSING (a release needs the full toolchain):"
	for m in "${MISSING[@]}"; do log "  - $m"; done
	die "install the above (see TOOLCHAIN.adoc) and re-run."
fi
ok "working tree clean @ $GIT_SHORT; tag $VERSION free; all tools present."

# ----------------------------------------------------------------------------
# Record toolchain versions (for the manifest) and warn on drift from the pins.
# ----------------------------------------------------------------------------
v1() { "$@" 2>&1 | head -1 || true; }
pkgver() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null || echo "n/a"; }

TC_AVR_GCC=$(v1 avr-gcc --version)
TC_AVR_BU=$(v1 avr-objcopy --version)
TC_AVR_LIBC=$(pkgver avr-libc)
TC_HOST_CC=$(v1 cc --version)
TC_XC8=$(v1 "$PIC_CC" --version)
TC_GPSIM=$(v1 gpsim --version)
TC_SIMAVR=$(pkgver libsimavr-dev)
TC_CPPCHECK=$(v1 cppcheck --version)
TC_CBMC=$(v1 cbmc --version)
TC_CLANG=$(v1 clang --version)
TC_PY=$(v1 python3 --version)

case "$TC_AVR_GCC" in
	*7.3.0*) : ;;
	*) warn "avr-gcc is not the pinned 7.3.0 ($TC_AVR_GCC). Images may not reproduce the CI build; the release.yml repro-verify will catch a mismatch." ;;
esac

# ============================================================================
# 1. CLEAN BUILD -- every image
# ============================================================================
section "1. clean build (all variants x all MCUs)"
make clean >/dev/null
make all13 all85 all45 >"$EVID/build-avr.log" 2>&1 || { cat "$EVID/build-avr.log" >&2; die "AVR build failed."; }
make pic PIC_CC="$PIC_CC" PIC_DFP="$PIC_DFP" >"$EVID/build-pic.log" 2>&1 || { cat "$EVID/build-pic.log" >&2; die "PIC build failed."; }

# Enumerate the expected image set and assert each exists.
IMAGES=()
AVR_IMAGES=()
AVR_ELFS=()
for v in $VARIANTS; do
	img="$AVR_BUILD_DIR/${FW_BASE}_${v}.hex"
	elf="${img%.hex}.elf"
	IMAGES+=("$img"); AVR_IMAGES+=("$img"); AVR_ELFS+=("$elf")
done
for v in $VARIANTS; do for n in $TINYX5; do
	img="$AVR_BUILD_DIR/${FW_BASE}_${v}_t${n}.hex"
	elf="${img%.hex}.elf"
	IMAGES+=("$img"); AVR_IMAGES+=("$img"); AVR_ELFS+=("$elf")
done; done
for v in $VARIANTS; do IMAGES+=("$PIC_BUILD_DIR/${FW_BASE}_${v}_${PIC_TAG}.hex"); done
for img in "${IMAGES[@]}"; do [ -f "$img" ] || die "expected image not produced: $img"; done
ok "built ${#IMAGES[@]} images."

hash_avr_elf_set() {
	local elf
	for elf in "$@"; do
		[ -f "$elf" ] && [ ! -L "$elf" ] && [ -s "$elf" ] \
			|| die "validated classic AVR ELF missing, empty, or not regular: $elf"
	done
	sha256sum -- "$@"
}

# ============================================================================
# 2. FULL PRE-HARDWARE GATES
# ============================================================================
section "2. validation: make test-long + make pic-test + PIC target aggregate"
log "running make test-long (exhaustive AVR suite + mutation)..."
make test-long STRICT_TOOLS=1 MUTATION_ALLOW_SKIP=0 >"$EVID/test-long.log" 2>&1 || { tail -40 "$EVID/test-long.log" >&2; die "make test-long FAILED."; }
ok "test-long passed."
validated_avr_elf_hashes=$(hash_avr_elf_set "${AVR_ELFS[@]}")
log "running make pic-test (PIC CONFIG word + analyze + gpsim)..."
make pic-test STRICT_TOOLS=1 PIC_CC="$PIC_CC" PIC_DFP="$PIC_DFP" >"$EVID/pic-test.log" 2>&1 || { tail -40 "$EVID/pic-test.log" >&2; die "make pic-test FAILED."; }
ok "pic-test passed."

# Fail-closed PIC target aggregate (libgpsim): per variant, require target fault
# recovery, firmware/model ctx_ lock-step, and GPIO transition/pulse timing PASS
# sentinels. This target converts the standalone skip-clean libgpsim drivers into
# a release gate: any missing tool, missing ctx_ symbol, skipped subtarget, or
# partial run is a hard failure.
log "running make pic-test-target-variants (fault + lock-step + target I/O on the real HEX)..."
make pic-test-target-variants STRICT_TOOLS=1 PIC_CC="$PIC_CC" PIC_DFP="$PIC_DFP" \
	>"$EVID/pic-test-target-variants.log" 2>&1 \
	|| { tail -60 "$EVID/pic-test-target-variants.log" >&2; die "make pic-test-target-variants FAILED."; }
ok "pic-test-target-variants passed."

# ============================================================================
# 3. PARALLEL SOAK -- every combo, full duration
# ============================================================================
section "3. soak (all combos, parallel, ${SOAK_DURATION_MS} ms each)"

# Build metadata for every soak combo: a binary, the cwd to run it from, a log.
declare -a SOAK_NAMES=()
declare -A SOAK_BIN SOAK_CWD SOAK_LOG SOAK_RC

log "compiling soak binaries..."
for v in $VARIANTS; do for n in $TINYX5; do
	name="avr_${v}_t${n}"; bin="test/avr/test_soak_${v}_t${n}"
	elf="$AVR_BUILD_DIR/${FW_BASE}_${v}_t${n}.elf"
	make --old-file="$elf" "$bin" AVR_REBUILD_PREREQ= \
		SOAK_VARIANT="$v" SOAK_CHIP="$n" SOAK_DURATION_MS="$SOAK_DURATION_MS" \
		>>"$EVID/soak-build.log" 2>&1 || die "failed to build AVR soak $name"
	SOAK_NAMES+=("$name"); SOAK_BIN[$name]="$REPO_ROOT/$bin"
	SOAK_CWD[$name]="$REPO_ROOT"   # relative FW_PATH; the binary writes no files
	SOAK_LOG[$name]="$EVID/soak-$name.log"
done; done
for v in $VARIANTS; do
	name="pic_${v}"; bin="$SOAKDIR/test_soak_pic_${v}"
	make "$bin" PIC_SOAK_BIN="$bin" PIC_SOAK_VARIANT="$v" PIC_SOAK_DURATION_MS="$SOAK_DURATION_MS" \
		>>"$EVID/soak-build.log" 2>&1 || die "failed to build PIC soak $name"
	rundir="$SOAKDIR/run-$name"; mkdir -p "$rundir"
	SOAK_NAMES+=("$name"); SOAK_BIN[$name]="$bin"
	SOAK_CWD[$name]="$rundir"      # absolute FW_PATH; isolates gpsim.log per combo
	SOAK_LOG[$name]="$EVID/soak-$name.log"
done

# Soak harness compilation must not replace the ELFs that test-long exercised.
current_avr_elf_hashes=$(hash_avr_elf_set "${AVR_ELFS[@]}")
[ "$current_avr_elf_hashes" = "$validated_avr_elf_hashes" ] \
	|| die "a classic AVR ELF changed while compiling its soak harness"

NCOMBOS=${#SOAK_NAMES[@]}
[ "$JOBS" -gt 0 ] 2>/dev/null || JOBS=$NCOMBOS
hours=$(awk -v ms="$SOAK_DURATION_MS" 'BEGIN{printf "%.1f", ms/3600000}')
ncpu=$(nproc 2>/dev/null || echo "?")
log "launching $NCOMBOS soak combos, up to $JOBS at once (~${hours} h each; this box has $ncpu logical CPUs)."
[ "$JOBS" -lt "$NCOMBOS" ] && warn "more combos ($NCOMBOS) than the --jobs cap ($JOBS): total time scales up."

START_EPOCH=$(date +%s)
declare -A SOAK_PID
for name in "${SOAK_NAMES[@]}"; do
	# Throttle to JOBS concurrent runs.
	while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do sleep 5; done
	( cd "${SOAK_CWD[$name]}" && exec "${SOAK_BIN[$name]}" ) >"${SOAK_LOG[$name]}" 2>&1 &
	SOAK_PID[$name]=$!
	log "  started $name (pid ${SOAK_PID[$name]})"
done

# Wait for all and collect verdicts. Both soak harnesses exit non-zero on any
# recorded failure AND print a 'SOAK PASS'/'SOAK FAIL' summary line.
SOAK_FAILS=0
for name in "${SOAK_NAMES[@]}"; do
	if wait "${SOAK_PID[$name]}"; then SOAK_RC[$name]=0; else SOAK_RC[$name]=$?; fi
	if [ "${SOAK_RC[$name]}" -eq 0 ] && grep -q "SOAK PASS" "${SOAK_LOG[$name]}"; then
		ok "soak $name: PASS"
	else
		warn "soak $name: FAIL (exit ${SOAK_RC[$name]})  -- see ${SOAK_LOG[$name]}"
		SOAK_FAILS=$((SOAK_FAILS+1))
	fi
done
SOAK_WALL=$(( $(date +%s) - START_EPOCH ))

if [ "$SOAK_FAILS" -ne 0 ]; then
	die "$SOAK_FAILS soak combo(s) FAILED. No release staged. Logs in $WORK (preserved)."
fi
ok "all $NCOMBOS soak combos passed (wall-clock ${SOAK_WALL}s)."

current_avr_elf_hashes=$(hash_avr_elf_set "${AVR_ELFS[@]}")
[ "$current_avr_elf_hashes" = "$validated_avr_elf_hashes" ] \
	|| die "a classic AVR ELF changed after its final validation began"

# Validation and soak rebuild classic ELFs, invalidating their paired HEX files.
# Re-materialize HEX from those exact, just-tested ELFs without compiling again.
log "regenerating classic AVR HEX from the validated ELFs..."
rm -f -- "${AVR_IMAGES[@]}" \
	|| die "could not remove stale classic AVR HEX before final regeneration"
old_file_args=()
for elf in "${AVR_ELFS[@]}"; do old_file_args+=("--old-file=$elf"); done
make "${old_file_args[@]}" all13 all85 all45 AVR_REBUILD_PREREQ= \
	>"$EVID/final-image-build.log" 2>&1 \
	|| { tail -60 "$EVID/final-image-build.log" >&2; die "final classic HEX regeneration FAILED."; }
current_avr_elf_hashes=$(hash_avr_elf_set "${AVR_ELFS[@]}")
[ "$current_avr_elf_hashes" = "$validated_avr_elf_hashes" ] \
	|| die "a validated classic AVR ELF changed during final HEX regeneration"
for img in "${IMAGES[@]}"; do
	[ -f "$img" ] && [ ! -L "$img" ] && [ -s "$img" ] \
		|| die "validated release image missing, empty, or not regular after final regeneration: $img"
done
ok "all validated release images are present and nonempty."

# ============================================================================
# 4. STAGE THE RELEASE
# ============================================================================
section "4. stage $OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/evidence"
for img in "${IMAGES[@]}"; do cp -p "$img" "$OUTPUT_DIR/"; done

# Checksums over the images (verifiable with: sha256sum -c SHA256SUMS).
( cd "$OUTPUT_DIR" && sha256sum ./*.hex | sed 's# \./# #' > SHA256SUMS )
ok "wrote SHA256SUMS over ${#IMAGES[@]} images."

# Copy evidence. The per-combo soak logs and build/pic-test logs are small and
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

# --- per-image facts for the manifest (target, clock, fuses, flashing cmd) ----
# Echoes a markdown table row for one image path.
img_row() {
	local path="$1" base; base=$(basename "$path")
	local sha; sha=$(awk -v f="$base" '$2==f{print $1}' "$OUTPUT_DIR/SHA256SUMS")
	# Flash usage is read from the build ELF (the HEX does not carry section
	# sizes avr-size can total); the ELF is still present in $AVR_BUILD_DIR when
	# the manifest is generated. PIC usage stays n/a (XC8 reports words, not bytes).
	local elf="$AVR_BUILD_DIR/${base%.hex}.elf"
	local mcu clk fuses flashcmd prog amcu used="n/a"
	case "$base" in
		*_${PIC_TAG}.hex)
			mcu="PIC10F322"; clk="${PIC_CLK_MHZ} MHz (HFINTOSC)"; fuses="CONFIG word embedded in HEX"
			flashcmd="pk2cmd -PPIC10F322 -F$base -M -Y -R   (or: make program-pic VARIANT=<v>)" ;;
		*_t85.hex|*_t45.hex)
			case "$base" in
				*_t85.hex) mcu="ATtiny85"; amcu="attiny85"; prog="t85" ;;
				*)         mcu="ATtiny45"; amcu="attiny45"; prog="t45" ;;
			esac
			clk="1.0 MHz"; fuses="lfuse=$LFUSE_X5 hfuse=$HFUSE_X5"
			used=$(avr-size --mcu="$amcu" -C "$elf" 2>/dev/null | awk '/^Program:/{print $2" B"; exit}')
			flashcmd="avrdude -c <prog> -p $prog -U lfuse:w:$LFUSE_X5:m -U hfuse:w:$HFUSE_X5:m -U flash:w:$base:i" ;;
		*.hex)
			mcu="ATtiny13a"; clk="1.2 MHz"; fuses="lfuse=$LFUSE hfuse=$HFUSE"
			used=$(avr-size --mcu=attiny13a -C "$elf" 2>/dev/null | awk '/^Program:/{print $2" B"; exit}')
			flashcmd="avrdude -c <prog> -p $AVRDUDE_PART -U lfuse:w:$LFUSE:m -U hfuse:w:$HFUSE:m -U flash:w:$base:i" ;;
	esac
	printf '| `%s` | %s | %s | %s | %s | `%s` |\n' "$base" "$mcu" "$clk" "${used:-n/a}" "$fuses" "$sha"
	printf '%s\t%s\n' "$base" "$flashcmd" >> "$WORK/flashcmds.txt"
}

# Soak evidence summary table.
soak_table() {
	local name f
	for name in "${SOAK_NAMES[@]}"; do
		f="$OUTPUT_DIR/evidence/soak-$name.log"
		local line; line=$(grep -E "^SOAK (PASS|FAIL)" "$f" 2>/dev/null | tail -1)
		printf '| %s | %s |\n' "$name" "${line:-PASS}"
	done
}

REL_BANNER=""
[ "$DRY_RUN" -eq 1 ] && REL_BANNER=$'> **DRY RUN -- NOT A VALIDATED RELEASE.** Soak duration was reduced; do not publish.\n'

: > "$WORK/flashcmds.txt"
{
	printf '# Firmware release %s\n\n' "$VERSION"
	[ -n "$REL_BANNER" ] && printf '%s\n' "$REL_BANNER"
	printf 'Prebuilt, fully-validated firmware images. Verify integrity with\n'
	printf '`sha256sum -c SHA256SUMS`; reproduce from source per "Reproducing" below.\n\n'

	printf '## Provenance\n\n'
	printf -- '- **Version / tag:** %s\n' "$VERSION"
	printf -- '- **Source commit:** `%s`\n' "$GIT_SHA"
	[ "$GIT_DIRTY" -eq 1 ] && printf -- '- **WARNING:** built from a DIRTY tree (uncommitted changes not captured by the SHA).\n'
	printf -- '- **Built:** %s by `%s` on `%s`\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${USER:-?}" "$(uname -srm)"
	printf -- '- **Validation:** `make test-long` + `make pic-test` + `make pic-test-target-variants` (real-HEX SFR/SRAM fault recovery, firmware/model ctx_ lock-step, and GPIO transition/pulse timing) + %s-h parallel soak of every variant x MCU (see evidence/).\n\n' "$hours"

	printf '## Toolchain\n\n'
	printf -- '| tool | version |\n|---|---|\n'
	printf -- '| avr-gcc | %s |\n' "$TC_AVR_GCC"
	printf -- '| binutils-avr (objcopy) | %s |\n' "$TC_AVR_BU"
	printf -- '| avr-libc (pkg) | %s |\n' "$TC_AVR_LIBC"
	printf -- '| host cc | %s |\n' "$TC_HOST_CC"
	printf -- '| XC8 | %s |\n' "$TC_XC8"
	printf -- '| PIC DFP | %s |\n' "$PIC_DFP"
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
	printf 'freshly built HEX lands under `build_avr_classic/` and `build_pic/`, not\n'
	printf 'in this release directory, so the checksum list must be run against those\n'
	printf 'fresh bytes (running it from the repo root would just re-verify the\n'
	printf 'committed copies against themselves).\n\n'
	printf '```\n'
	printf 'git checkout %s\n' "$VERSION"
	printf '# install the pinned toolchain (see TOOLCHAIN.adoc), then:\n'
	printf 'make clean && make all13 all85 all45 && make pic\n'
	printf 'scripts/verify-release-images.sh release/%s build_avr_classic build_pic\n' "$VERSION"
	printf '```\n'
	printf 'A passing verifier proves the committed files, checksum entries, and freshly\n'
	printf 'built files are the same complete set with byte-identical contents. The\n'
	printf 'tag-triggered CI (.github/workflows/release.yml) runs this exact check on a\n'
	printf 'clean runner and fails the release on any mismatch.\n'
} > "$OUTPUT_DIR/MANIFEST.md"
ok "wrote MANIFEST.md"

# Per-version README (concise; points at the top-level release/README.md).
{
	printf '# %s\n\n' "$VERSION"
	[ -n "$REL_BANNER" ] && printf '%s\n' "$REL_BANNER"
	printf 'Prebuilt firmware for %s. See **MANIFEST.md** for provenance, the per-image\n' "$VERSION"
	printf 'fuse bytes / flashing commands, and the soak evidence. See the top-level\n'
	printf '[release/README.md](../README.md) for the trust model and verification steps.\n\n'
	printf 'Quick verify:\n```\ncd release/%s && sha256sum -c SHA256SUMS\n```\n' "$VERSION"
	printf '\nIf SHA256SUMS.asc is present, verify the signature first:\n'
	printf '```\ngpg --verify SHA256SUMS.asc SHA256SUMS\n```\n'
} > "$OUTPUT_DIR/README.md"

# Commit message for the human to use verbatim (git commit -F ...).
{
	printf 'release: firmware %s\n\n' "$VERSION"
	printf 'Prebuilt, fully-validated firmware images for %s.\n\n' "$VERSION"
	printf 'Built from %s with the toolchain pinned in TOOLCHAIN.adoc.\n' "$GIT_SHORT"
	printf 'Validation: make test-long + make pic-test + make pic-test-target-variants\n'
	printf '+ %s-h parallel soak of every variant x MCU (evidence under\n' "$hours"
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

  # 1. review
  git status
  less $OUTPUT_DIR/MANIFEST.md

  # 2. sign the checksums (detached, ASCII-armored) -- adds SHA256SUMS.asc
  gpg --armor --detach-sign $OUTPUT_DIR/SHA256SUMS
  #    (minisign alternative: minisign -Sm $OUTPUT_DIR/SHA256SUMS)

  # 3. commit the whole release dir (uses the generated message)
  git add $OUTPUT_DIR
  git commit -F $OUTPUT_DIR/commit_msg.txt

  # 4. create a SIGNED, annotated tag on that commit
  git tag -s $VERSION -m "Firmware release $VERSION"

  # 5. push the commit and the tag
  git push
  git push origin $VERSION

EOF
ok "done. Nothing was committed, tagged, or pushed -- that is yours to do."
