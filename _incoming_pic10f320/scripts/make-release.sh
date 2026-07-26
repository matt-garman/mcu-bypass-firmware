#!/usr/bin/env bash
#
# make-release.sh -- build, exhaustively validate, and STAGE a prebuilt
# firmware release for the PIC10F320 bypass firmware.
#
# WHY THIS EXISTS
#   The firmware's whole value proposition is trust: an extensive test and
#   validation suite backs the SOURCE. This script extends that same confidence
#   to PREBUILT BINARIES so that someone who just wants to flash a chip does not
#   have to install the XC8 cross-toolchain or compile anything -- yet can still
#   verify the image is exactly what the (tested) source produces.
#
#   The trust model rests on two legs:
#     1. PROVENANCE -- every released image carries a MANIFEST recording the git
#        commit, the exact toolchain versions, the per-image flash usage / CONFIG
#        word, and the validation evidence (test-variants + mutation +
#        target fault/lock-step/I-O + soak).
#     2. REPRODUCIBILITY -- the Intel-HEX images are byte-deterministic for a
#        fixed toolchain (XC8's ihex output carries only code/config bytes, no
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
#   1. Clean-build every output-variant image (cd4053-simple, cd4053-mute,
#      tq2-relay).
#   2. Run `make test-variants` (the full per-variant gate: analyze + host/formal
#      + equivalence + actuation + fault + CONFIG word + gpsim + coverage), `make
#      test-mutation` (the mutation suite), and `make test-target-variants`
#      (silicon-level SFR/SRAM/TRISA fault recovery, firmware<->model ctx_
#      lock-step, and GPIO transition/pulse timing on the real HEX). These are
#      the full pre-hardware gates.
#   3. Run ALL soak combos (one libgpsim soak per variant) IN PARALLEL for the
#      full duration, collecting a pass/fail verdict and evidence from each.
#   4. Stage release/<VERSION>/ : the .hex images, SHA256SUMS, a provenance
#      MANIFEST, a README, and the soak/validation evidence. (The suggested git
#      commit message is written to ./commit_msg.txt at the repo root -- kept OUT
#      of the staged dir so `git add release/<VERSION>` can never publish it.)
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
#     --soak-duration-ms N     per-combo soak duration, in SIMULATED MCU ms
#                              (default 86400000 = 24 h of simulated operation)
#     --jobs N                 max concurrent soak combos (default: all of them)
#     --output-dir DIR         where to stage (default release/<version>)
#     -h | --help              this help
#
# This script is long-running, dominated by the parallel soaks. Each soak
# exercises 24 h of *simulated* MCU time -- NOT 24 h of wall-clock. gpsim
# simulates the 2 MHz core faster than real time, so the wall-clock cost is
# host-dependent and typically well under 24 h; it is still long enough that you
# should run this on a machine that can stay up, with all toolchains installed
# (XC8 + PIC10-12Fxxx DFP + gpsim/gpsim-dev + cppcheck + cbmc + a host C/C++
# compiler). See TOOLCHAIN.adoc.

set -euo pipefail

# `make release` already holds the worktree lock. Direct script execution must
# acquire the same lock for the entire build/validation/staging pipeline rather
# than releasing it between individual nested Make calls.
if [ "${_MAKE_SERIAL_LOCK_HELD:-0}" != 1 ]; then
	REPO_HINT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
	command -v flock >/dev/null 2>&1 \
		|| { printf 'FATAL: flock is required to serialize release artifacts\n' >&2; exit 1; }
	exec flock "$REPO_HINT/.make.lock" env _MAKE_SERIAL_LOCK_HELD=1 \
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
VERSION=""
DRY_RUN=0
ALLOW_DIRTY=0
MIN_RELEASE_SOAK_MS=86400000
MAX_SOAK_DURATION_MS=4294967294    # uint32_t loop bound; preserve t + 1
SOAK_DURATION_MS=$MIN_RELEASE_SOAK_MS
SOAK_LIVENESS_INTERVAL_MS=60000
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

# The C++ soak loop uses a uint32_t millisecond counter. Validate before any
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

mkv() { make -s print-"$1"; }      # echo one Makefile variable

VARIANTS=$(mkv PIC_VARIANTS_ALL)   # cd4053-simple cd4053-mute tq2-relay
FW_BASE=$(mkv FW_BASE)             # bypass_mcu
BUILD_DIR=$(mkv BUILD_DIR)         # build_pic
PIC_TAG=$(mkv PIC_TAG)             # pic10f320
PIC_CHIP=$(mkv PIC_CHIP)           # 10F320
PIC_XTAL=$(mkv PIC_XTAL)           # 2000000UL
PIC_FLASH_WORDS=$(mkv PIC_FLASH_WORDS) # 256
PIC_GPSIM_PROC=$(mkv PIC_GPSIM_PROC)   # p10f320
PIC_CC=$(mkv PIC_CC)
PIC_DFP=$(mkv PIC_DFP)
PIC_SOAK_CXX=$(mkv PIC_SOAK_CXX)         # c++
PIC_SOAK_GPSIM_INC=$(mkv PIC_SOAK_GPSIM_INC)  # /usr/include/gpsim

# Scratch area for evidence + per-combo soak run dirs. Preserved on failure so a
# crashed/failed run can be inspected; folded into the release on success.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pic10f320-release.XXXXXX")"
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

# The suggested commit message is scaffolding for the human's `git commit -F`,
# NOT a release artifact -- it must live OUTSIDE OUTPUT_DIR so the recipe's
# `git add <release dir>` cannot sweep it into the published release. A real
# release drops it at the repo root (git-ignored; the handoff recipe points
# `git commit -F` at it); a dry run keeps it in the scratch WORK so the repo
# tree is never touched.
if [ "$DRY_RUN" -eq 1 ]; then COMMIT_MSG="$WORK/commit_msg.txt"
else COMMIT_MSG="$REPO_ROOT/commit_msg.txt"
fi

# ============================================================================
# 0. PRECONDITIONS
# ============================================================================
section "0. preconditions"

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
req_cmd flock          "apt: util-linux (whole-worktree build serialization)"
# PIC toolchain (paths come from the Makefile defaults / PIC_CC, PIC_DFP).
req_file "$PIC_CC"                                  "XC8 (PIC_CC=)"
req_file "$PIC_DFP/pic/include/proc/pic10f320.h"    "PIC10-12Fxxx DFP (PIC_DFP=)"
req_cmd gpsim          "apt: gpsim (test-gpsim)"
req_cmd cppcheck       "apt: cppcheck (analyze + MISRA)"
req_cmd python3        "MISRA addon"
req_cmd cbmc           "apt: cbmc (formal proof in test-cbmc)"
req_cmd cc             "host C compiler (test-host/equiv/fault)"
req_cmd "$PIC_SOAK_CXX" "host C++ compiler (soak)"
req_file "$PIC_SOAK_GPSIM_INC/sim_context.h"        "apt: gpsim-dev (soak)"
pkg-config --exists glib-2.0 2>/dev/null || MISSING+=("glib-2.0  (apt: libglib2.0-dev, soak)")

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

TC_XC8=$(v1 "$PIC_CC" --version)
TC_GPSIM=$(v1 gpsim --version)
TC_CPPCHECK=$(v1 cppcheck --version)
TC_CBMC=$(v1 cbmc --version)
TC_HOST_CC=$(v1 cc --version)
TC_HOST_CXX=$(v1 "$PIC_SOAK_CXX" --version)
TC_PY=$(v1 python3 --version)

case "$TC_XC8" in
	*3.10*) : ;;
	*) warn "XC8 is not the pinned V3.10 ($TC_XC8). Images may not reproduce the CI build; the release.yml repro-verify will catch a mismatch." ;;
esac

# ============================================================================
# 1. CLEAN BUILD -- every image
# ============================================================================
section "1. clean build (all output variants)"
make clean >/dev/null

# Per-variant flash-word usage, parsed from `make all`'s "OK: ... N words" line,
# for the manifest. (XC8 reports program WORDS, not the bytes avr-size totals.)
declare -A WORDS
IMAGES=()
for v in $VARIANTS; do
	log "building variant $v ..."
	make all PIC_VARIANT="$v" PIC_CC="$PIC_CC" PIC_DFP="$PIC_DFP" \
		>"$EVID/build-$v.log" 2>&1 || { cat "$EVID/build-$v.log" >&2; die "build failed for $v."; }
	img="$BUILD_DIR/${FW_BASE}_${v}_${PIC_TAG}.hex"
	[ -f "$img" ] || die "expected image not produced: $img"
	IMAGES+=("$img")
	# Parse the program-word count from the build's "OK: ... N words" line. Anchor
	# on '^OK:' so we don't grab the "$(PIC_FLASH_WORDS) words" in the build header.
	used=$(grep -E '^OK:' "$EVID/build-$v.log" | grep -oE '[0-9]+ words' | head -1 | awk '{print $1}' || true)
	[ -n "$used" ] || { cat "$EVID/build-$v.log" >&2; die "could not parse flash usage for $v."; }
	WORDS[$v]="$used"
done
ok "built ${#IMAGES[@]} images."

# ============================================================================
# 2. FULL PRE-HARDWARE GATES
# ============================================================================
section "2. validation: test-variants + test-mutation + test-target-variants"
log "running make test-variants (full per-variant gate: analyze + host/formal + equiv + actuation + fault + CONFIG word + gpsim + coverage)..."
make test-variants PIC_CC="$PIC_CC" PIC_DFP="$PIC_DFP" \
	>"$EVID/test-variants.log" 2>&1 || { tail -40 "$EVID/test-variants.log" >&2; die "make test-variants FAILED."; }
ok "test-variants passed."
log "running make test-mutation (inject faults; verify the suite kills them)..."
make test-mutation MUTATION_ALLOW_SKIP=0 PIC_CC="$PIC_CC" PIC_DFP="$PIC_DFP" \
	>"$EVID/test-mutation.log" 2>&1 || { tail -40 "$EVID/test-mutation.log" >&2; die "make test-mutation FAILED."; }
ok "test-mutation passed."

# Fail-closed real-HEX aggregate for every variant: target fault recovery,
# firmware/model lock-step, and GPIO direction/output/transition/pulse timing.
# The aggregate requires each driver's explicit PASS marker, so the individual
# skip-clean guards cannot turn a missing tool or partial run into release evidence.
log "running make test-target-variants (fault + lock-step + target I/O on the real HEX)..."
make test-target-variants PIC_CC="$PIC_CC" PIC_DFP="$PIC_DFP" \
	>"$EVID/test-target-variants.log" 2>&1 \
	|| { tail -60 "$EVID/test-target-variants.log" >&2; die "make test-target-variants FAILED."; }
ok "test-target-variants passed."

# ============================================================================
# 3. PARALLEL SOAK -- every variant, full duration
# ============================================================================
section "3. soak (all variants, parallel, ${SOAK_DURATION_MS} ms each)"

# Build metadata for every soak combo: a binary, the cwd to run it from, a log.
declare -a SOAK_NAMES=()
declare -A SOAK_BIN SOAK_CWD SOAK_LOG SOAK_RC

log "compiling soak binaries..."
for v in $VARIANTS; do
	name="$v"; bin="$SOAKDIR/test_soak_${v}"
	make "$bin" PIC_VARIANT="$v" PIC_SOAK_BIN="$bin" PIC_SOAK_DURATION_MS="$SOAK_DURATION_MS" \
		PIC_SOAK_LIVENESS_INTERVAL_MS="$SOAK_LIVENESS_INTERVAL_MS" \
		>>"$EVID/soak-build.log" 2>&1 || die "failed to build soak binary for $name"
	rundir="$SOAKDIR/run-$name"; mkdir -p "$rundir"
	SOAK_NAMES+=("$name"); SOAK_BIN[$name]="$bin"
	SOAK_CWD[$name]="$rundir"      # absolute FW_PATH; isolates gpsim.log per combo
	SOAK_LOG[$name]="$EVID/soak-$name.log"
done

NCOMBOS=${#SOAK_NAMES[@]}
[ "$JOBS" -gt 0 ] 2>/dev/null || JOBS=$NCOMBOS
hours=$(awk -v ms="$SOAK_DURATION_MS" 'BEGIN{printf "%.1f", ms/3600000}')
ncpu=$(nproc 2>/dev/null || echo "?")
log "launching $NCOMBOS soak combos, up to $JOBS at once (${hours} h SIMULATED each; wall-clock is host-dependent; this box has $ncpu logical CPUs)."
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

# Wait for all and collect verdicts. The soak harness exits non-zero on any
# recorded failure AND prints a 'SOAK PASS'/'SOAK FAIL' summary line.
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

# ============================================================================
# 4. STAGE THE RELEASE
# ============================================================================
section "4. stage $OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/evidence"
for img in "${IMAGES[@]}"; do cp -p "$img" "$OUTPUT_DIR/"; done

# Checksums over the images (verifiable with: sha256sum -c SHA256SUMS).
( cd "$OUTPUT_DIR" && sha256sum ./*.hex | sed 's# \./# #' > SHA256SUMS )

# Fail closed unless the expected build list, staged HEX files, and checksum
# entries are identical filename sets. OUTPUT_DIR is new, but this assertion
# protects future staging changes from publishing an extra or unchecksummed file.
printf '%s\n' "${IMAGES[@]##*/}" | sort > "$WORK/images-expected.txt"
for img in "$OUTPUT_DIR"/*.hex; do basename "$img"; done | sort > "$WORK/images-staged.txt"
awk 'NF == 2 && $2 ~ /\.hex$/ {print $2}' "$OUTPUT_DIR/SHA256SUMS" \
	| sort > "$WORK/images-checksummed.txt"
diff -u "$WORK/images-expected.txt" "$WORK/images-staged.txt" \
	|| die "staged HEX set differs from expected variants."
diff -u "$WORK/images-expected.txt" "$WORK/images-checksummed.txt" \
	|| die "SHA256SUMS HEX set differs from expected variants."
ok "wrote SHA256SUMS over the exact ${#IMAGES[@]}-image release set."

# Copy evidence. The per-combo soak logs and build logs are small and kept in
# full; the test-variants log is large and would bloat the repo on every
# release, so commit a concise summary instead -- the full log is reproduced
# (and archived) by the tag-triggered release CI run.
for f in "$EVID"/*.log; do
	case "$(basename "$f")" in
		test-variants.log)
			{ echo "# test-variants summary -- the full log is in the release CI run."; echo; \
			  grep -nE '^(=====|OK:|FAIL|cbmc:|MISRA|coverage|VARIANT|killed|survived|mutant)' "$f" || true; \
			  echo; echo "# --- last 20 lines ---"; tail -20 "$f"; \
			} > "$OUTPUT_DIR/evidence/test-variants.summary.txt" ;;
		*) cp -p "$f" "$OUTPUT_DIR/evidence/" ;;
	esac
done

# --- per-image facts for the manifest (target, clock, flash usage, flashing) ---
# Echoes a markdown table row for one image path.
img_row() {
	local path="$1" base; base=$(basename "$path")
	local sha; sha=$(awk -v f="$base" '$2==f{print $1}' "$OUTPUT_DIR/SHA256SUMS")
	# Recover the variant from the image name (bypass_mcu_<variant>_pic10f320.hex)
	# to look up its parsed flash-word count.
	local v="${base#${FW_BASE}_}"; v="${v%_${PIC_TAG}.hex}"
	local used="${WORDS[$v]:-?}"
	printf '| `%s` | %s | %s | %s words / %s | %s | `%s` |\n' \
		"$base" "PIC10F320" "2 MHz (INTOSC)" "${used}" "$PIC_FLASH_WORDS" \
		"CONFIG word embedded in HEX" "$sha"
	printf '%s\tpk2cmd -PPIC10F320 -F%s -M -Y -R\n' "$base" "$base" >> "$WORK/flashcmds.txt"
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
	printf 'Prebuilt, fully-validated PIC10F320 firmware images. Verify integrity with\n'
	printf '`sha256sum -c SHA256SUMS`; reproduce from source per "Reproducing" below.\n\n'

	printf '## Provenance\n\n'
	printf -- '- **Version / tag:** %s\n' "$VERSION"
	printf -- '- **Source commit:** `%s`\n' "$GIT_SHA"
	[ "$GIT_DIRTY" -eq 1 ] && printf -- '- **WARNING:** built from a DIRTY tree (uncommitted changes not captured by the SHA).\n'
	printf -- '- **Built:** %s by `%s` on `%s`\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${USER:-?}" "$(uname -srm)"
	printf -- '- **Validation:** `make test-variants` + `make test-mutation` + `make test-target-variants` (real-HEX TRISA/SFR/SRAM fault recovery, firmware<->model ctx_ lock-step, and GPIO transition/pulse timing) + a %s-h *simulated-time* parallel libgpsim soak of every variant (see evidence/).\n\n' "$hours"

	printf '## Toolchain\n\n'
	printf -- '| tool | version |\n|---|---|\n'
	printf -- '| XC8 | %s |\n' "$TC_XC8"
	printf -- '| PIC DFP | %s |\n' "$PIC_DFP"
	printf -- '| gpsim | %s |\n' "$TC_GPSIM"
	printf -- '| host cc | %s |\n' "$TC_HOST_CC"
	printf -- '| host c++ | %s |\n' "$TC_HOST_CXX"
	printf -- '| cppcheck | %s |\n' "$TC_CPPCHECK"
	printf -- '| cbmc | %s |\n' "$TC_CBMC"
	printf -- '| python3 | %s |\n\n' "$TC_PY"

	printf '## Images\n\n'
	printf '| image | MCU | clock | flash used | config | sha256 |\n'
	printf '|---|---|---|---|---|---|\n'
	for img in "${IMAGES[@]}"; do img_row "$OUTPUT_DIR/$(basename "$img")"; done
	printf '\n'

	printf '## Flashing\n\n'
	printf 'The PIC10F320 CONFIG word is embedded in the HEX, so writing the HEX\n'
	printf 'configures the device -- there is no separate fuse step.\n\n'
	printf '```\n'
	sort "$WORK/flashcmds.txt" | while IFS=$'\t' read -r f cmd; do printf '# %s\n%s\n\n' "$f" "$cmd"; done
	printf '```\n\n'

	printf '## Soak evidence\n\n'
	printf '| variant | result |\n|---|---|\n'
	soak_table
	printf '\n'

	printf '## Reproducing these images\n\n'
	printf 'Check the images this tag *builds* against the committed checksums. Fresh\n'
	printf 'HEX files land under `build_pic/`, not in this release directory, so the\n'
	printf 'verifier snapshots and checks those fresh bytes and requires exact filename\n'
	printf 'set equality with the committed images and `SHA256SUMS`.\n\n'
	printf '```\n'
	printf 'git checkout %s\n' "$VERSION"
	printf '# install the pinned toolchain (see TOOLCHAIN.adoc), then:\n'
	printf 'make clean\n'
	for v in $VARIANTS; do printf 'make all PIC_VARIANT=%s\n' "$v"; done
	printf 'scripts/verify-release-images.sh release/%s build_pic\n' "$VERSION"
	printf '```\n'
	printf 'A passing verifier proves the committed files, checksum entries, and freshly\n'
	printf 'built files are the same complete set with byte-identical contents. The\n'
	printf 'tag-triggered CI runs this exact check on a clean runner.\n'
} > "$OUTPUT_DIR/MANIFEST.md"
ok "wrote MANIFEST.md"

# Per-version README (concise; points at the top-level release/README.md).
{
	printf '# %s\n\n' "$VERSION"
	[ -n "$REL_BANNER" ] && printf '%s\n' "$REL_BANNER"
	printf 'Prebuilt firmware for %s. See **MANIFEST.md** for provenance, the per-image\n' "$VERSION"
	printf 'flash usage / flashing commands, and the soak evidence. See the top-level\n'
	printf '[release/README.md](../README.md) for the trust model and verification steps.\n\n'
	printf 'Quick verify:\n```\ncd release/%s && sha256sum -c SHA256SUMS\n```\n' "$VERSION"
	printf '\nIf SHA256SUMS.asc is present, verify the signature first:\n'
	printf '```\ngpg --verify SHA256SUMS.asc SHA256SUMS\n```\n'
} > "$OUTPUT_DIR/README.md"

# Commit message for the human to use verbatim (git commit -F ...). Written
# OUTSIDE OUTPUT_DIR (see COMMIT_MSG above) so it is never committed/published.
{
	printf 'release: firmware %s\n\n' "$VERSION"
	printf 'Prebuilt, fully-validated PIC10F320 firmware images for %s.\n\n' "$VERSION"
	printf 'Built from %s with the toolchain pinned in TOOLCHAIN.adoc.\n' "$GIT_SHORT"
	printf 'Validation: make test-variants + make test-mutation + make test-target-variants\n'
	printf '(real-HEX fault recovery, firmware/model lock-step, and GPIO transition/pulse\n'
	printf 'timing) + a %s-h simulated-time parallel soak\n' "$hours"
	printf 'of every output variant (evidence under release/%s/evidence/).\n\n' "$VERSION"
	printf 'Reproducibility is pinned by release/%s/SHA256SUMS and verified on a\n' "$VERSION"
	printf 'clean runner by .github/workflows/release.yml when the tag is pushed.\n'
} > "$COMMIT_MSG"

# Fold evidence in and finish.
ls -1 "$OUTPUT_DIR" >&2

# ============================================================================
# 5. HAND OFF -- print the git + signing recipe (this script runs NOTHING below)
# ============================================================================
if [ "$DRY_RUN" -eq 1 ]; then
	section "DRY RUN complete"
	warn "This was a rehearsal with a short soak. Output staged at $OUTPUT_DIR is NOT a real release."
	warn "Re-run WITHOUT --dry-run (full 24-h simulated soak) to produce a publishable release."
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

  # 3. commit the whole release dir (uses the generated message at the repo
  #    root -- commit_msg.txt is git-ignored and is NOT part of the release)
  git add $OUTPUT_DIR
  git commit -F $COMMIT_MSG

  # 4. create a SIGNED, annotated tag on that commit
  git tag -s $VERSION -m "Firmware release $VERSION"

  # 5. push the commit and the tag
  git push
  git push origin $VERSION

EOF
ok "done. Nothing was committed, tagged, or pushed -- that is yours to do."
