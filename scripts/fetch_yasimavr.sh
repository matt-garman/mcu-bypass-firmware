#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
#
# fetch_yasimavr.sh -- build a PATCHED yasimavr into a project-local virtualenv,
# for the ATtiny202 (AVR-XT / avrxmega3) dynamic-simulation harness
# (`make attiny202-sim` / -soak / -fault).
#
# WHY THIS EXISTS
#   yasimavr (github.com/clesav/yasimavr, GPL-3.0) is a scriptable AVR8X/XT
#   simulator that models the ATtiny202's TCB0 / WDT / PORT / RSTCTRL / SLPCTRL
#   -- enough to run our REAL firmware image and reach near-parity with the
#   simavr harness the AVR-Classic parts enjoy. But two upstream bugs (both
#   reported to the project; see third_party/yasimavr/patches/) stop our
#   fuse-locked-WDT firmware from running:
#     0001  the tinyAVR 0-series device builder omits the WDT peripheral, so any
#           WDT register access crashes the simulated CPU;
#     0002  ArchXT_WDT::calculate_delays() maps WINDOW=OFF to a 4-clock window
#           instead of 0, so a correctly-petted WDT resets ~every pet.
#   Bug 0002 lives in COMPILED C++, so it cannot be monkey-patched at runtime --
#   a patched *build* is required. This script produces exactly that, pinned to a
#   known-good upstream release (version + sdist SHA-256) plus our vendored
#   patches, so the environment is reproducible and identical on a developer box
#   and in GitHub CI. Nothing binary is committed; the venv it creates is a
#   generated artifact (gitignored), rebuilt on demand from the pinned inputs.
#
#   This is the yasimavr analogue of scripts/fetch_attiny_dfp.sh (which vendors
#   the ATtiny_DFP device files for the compiler).
#
# KNOWN LIMITATION (NOT patched -- worked around in the test suite)
#   yasimavr 0.1.6 is a functional/logic simulator: its AVR core charges a flat
#   ~1 cycle per instruction and does NOT model the AVR's true multi-cycle
#   instruction timing. (Single-stepping shows SBIW -> +1 cycle and a taken
#   BRNE -> +1 cycle; on silicon each is 2 cycles.) Consequences:
#     * TCB0-tick-driven timing (debounce thresholds, LED/state sequencing) is
#       ACCURATE -- the tick period is counted by the peripheral, not by summing
#       instruction cycles -- so `make attiny202-sim` validates it directly.
#     * A raw-CPU-cycle busy delay is NOT accurate: avr-libc _delay_ms() coil
#       pulses (the relay's 12 ms, the muted-x4053's 5 ms) run at ~HALF their
#       real wall-clock length here (a 4-cycle loop body executes as 2). The
#       harness therefore does NOT assert absolute pulse WIDTH; that is verified
#       from the compiled image's _delay_ms loop by
#       test/avr/test_attiny202_delay_oracle.py. See that file's header, the
#       check_pulse_present() note in test/avr/test_sim_attiny202.py, and the
#       project memory "yasimavr-flat-instruction-timing".
#   This is a fidelity limit, not a firmware defect: the built image is correct
#   for real 2 MHz silicon. It is left unpatched (accurate XT instruction timing
#   would be a large core change); the disassembly oracle covers the gap exactly.
#
# USAGE
#   scripts/fetch_yasimavr.sh [VENV_DIR]
#     VENV_DIR  where to create the venv (default: ./third_party/yasimavr/venv).
#               The Makefile's YASIMAVR_VENV defaults to the same path.
#   Env overrides: YASIMAVR_VER, YASIMAVR_SDIST_SHA256, PIP_INDEX_URL,
#                  GET_PIP_URL.
#
# PREREQUISITES (hard -- the script fails loud, it does not silently skip; the
# Makefile harness targets are the ones that skip cleanly when the venv is
# absent, exactly as `make attiny202` skips without the DFP):
#   * python3 with the venv module          (apt: python3 python3-venv)
#   * the CPython development headers        (apt: python3-dev)  -- to compile
#                                            yasimavr's C++/SIP extension modules
#   * a C++ compiler (c++ / g++)
#   * curl or wget, sha256sum, and either `patch` or `git`
#   * network access to PyPI (sdist + the sip build backend)
#
# EXIT STATUS
#   0  the patched venv is present and verified (freshly built or already cached)
#   1  a required tool is missing, or download / patch / build / verify failed

set -eu

log() { printf '%s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
normalize_physical_path() {
    normalized_path=$1
    while [ "${normalized_path#//}" != "$normalized_path" ]; do
        normalized_path=${normalized_path#/}
    done
    printf '%s\n' "$normalized_path"
}

[ "$#" -le 1 ] || die "usage: scripts/fetch_yasimavr.sh [VENV_DIR]"

# --- pinned upstream release (bump VER + SHA together, from a trusted run) ------
VER="${YASIMAVR_VER:-0.1.6}"
SDIST_SHA256="${YASIMAVR_SDIST_SHA256:-3742dae364a8d65ff7d4180d00b40c0901656dafcea6e53e94db1127b7ec6285}"
GET_PIP_URL="${GET_PIP_URL:-https://bootstrap.pypa.io/get-pip.py}"

# Resolve paths relative to the repo root (this script's parent's parent), so it
# works regardless of the caller's cwd.
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd -P)"
SCRIPT_DIR=$(normalize_physical_path "$SCRIPT_DIR")
REPO_ROOT=$(normalize_physical_path "$REPO_ROOT")

if [ "$#" -eq 1 ]; then
    [ -n "$1" ] || die "VENV_DIR must not be empty"
    VENV_REQUESTED=$1
else
    VENV_REQUESTED="${REPO_ROOT}/third_party/yasimavr/venv"
fi

# Canonicalize an existing destination itself, or the parent of a destination
# that does not exist yet. Requiring an existing parent is also what lets the
# completed venv be installed with one sibling-directory rename.
case "$VENV_REQUESTED" in
    /*) ;;
    *) VENV_REQUESTED="${PWD}/${VENV_REQUESTED}" ;;
esac
# `test -L link/` follows the trailing slash on some hosts. Remove redundant
# trailing separators before testing the caller-selected final component.
while [ "$VENV_REQUESTED" != / ] \
        && [ "${VENV_REQUESTED%/}" != "$VENV_REQUESTED" ]; do
    VENV_REQUESTED=${VENV_REQUESTED%/}
done
[ ! -L "$VENV_REQUESTED" ] || die "VENV_DIR must not be a symlink: ${VENV_REQUESTED}"
if [ -d "$VENV_REQUESTED" ]; then
    VENV="$(CDPATH= cd -- "$VENV_REQUESTED" && pwd -P)" \
        || die "cannot resolve VENV_DIR: ${VENV_REQUESTED}"
elif [ -e "$VENV_REQUESTED" ]; then
    die "VENV_DIR exists but is not a directory: ${VENV_REQUESTED}"
else
    VENV_NAME="$(basename -- "$VENV_REQUESTED")"
    VENV_PARENT_REQUESTED="$(dirname -- "$VENV_REQUESTED")"
    [ -d "$VENV_PARENT_REQUESTED" ] \
        || die "VENV_DIR parent does not exist: ${VENV_PARENT_REQUESTED}"
    VENV_PARENT="$(CDPATH= cd -- "$VENV_PARENT_REQUESTED" && pwd -P)" \
        || die "cannot resolve VENV_DIR parent: ${VENV_PARENT_REQUESTED}"
    VENV="${VENV_PARENT}/${VENV_NAME}"
fi
VENV=$(normalize_physical_path "$VENV")
[ ! -L "$VENV" ] || die "VENV_DIR must not be a symlink: ${VENV}"
[ "$VENV" != / ] || die "refusing to use the filesystem root as VENV_DIR"
[ "$VENV" != "$REPO_ROOT" ] || die "refusing to use the repository root as VENV_DIR"

VENV_PARENT="$(dirname -- "$VENV")"
VENV_NAME="$(basename -- "$VENV")"
PATCH_DIR="${REPO_ROOT}/third_party/yasimavr/patches"
VENV_STAMP="${VENV}/.yasimavr.stamp" # records "VER SDIST_SHA256 PATCHSET_SHA256"
VENV_PY="${VENV}/bin/python"

is_sha256() {
    [ "${#1}" -eq 64 ] || return 1
    case "$1" in
        *[!0123456789abcdef]*) return 1 ;;
    esac
}

# A schema-valid private stamp is the ownership marker that permits replacing a
# stale or damaged venv. Merely choosing an existing directory is never consent
# to recursively remove it.
has_yasimavr_stamp() {
    stamp_file=$1
    [ -f "$stamp_file" ] && [ ! -L "$stamp_file" ] || return 1
    stamp_value=$(cat "$stamp_file" 2>/dev/null) || return 1
    stamp_version=${stamp_value%% *}
    stamp_hashes=${stamp_value#* }
    [ -n "$stamp_version" ] && [ "$stamp_hashes" != "$stamp_value" ] || return 1
    case "$stamp_version" in
        *[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._+-]*) return 1 ;;
    esac
    stamp_sdist=${stamp_hashes%% *}
    stamp_patchset=${stamp_hashes#* }
    [ "$stamp_patchset" != "$stamp_hashes" ] || return 1
    case "$stamp_patchset" in
        *' '*) return 1 ;;
    esac
    is_sha256 "$stamp_sdist" && is_sha256 "$stamp_patchset"
}

DESTINATION_EXISTS=0
if [ -d "$VENV" ]; then
    has_yasimavr_stamp "$VENV_STAMP" \
        || die "refusing to replace existing VENV_DIR without a valid .yasimavr.stamp: ${VENV}"
    DESTINATION_EXISTS=1
elif [ -e "$VENV" ] || [ -L "$VENV" ]; then
    die "VENV_DIR exists but is not a regular directory: ${VENV}"
fi

[ -d "$PATCH_DIR" ] || die "patch dir not found: ${PATCH_DIR}"

# Build signature = pinned release + a hash of the exact patch set. Changing a
# patch (or the version/SHA) changes the signature and forces a rebuild.
PATCHSET_SHA256="$(cat "$PATCH_DIR"/*.patch | sha256sum | cut -d' ' -f1)"
SIG="${VER} ${SDIST_SHA256} ${PATCHSET_SHA256}"

# --- idempotence: already built at this exact signature, and still importable? --
already_built() {
    [ -f "$VENV_STAMP" ] && [ ! -L "$VENV_STAMP" ] \
        && [ "$(cat "$VENV_STAMP" 2>/dev/null)" = "$SIG" ] || return 1
    [ -x "$VENV_PY" ] || return 1
    # Confirm the build is intact AND patch 0001 took (WDT instantiates). This
    # also exercises that the compiled extension imports on this interpreter.
    "$VENV_PY" - <<'PY' >/dev/null 2>&1 || return 1
from yasimavr.device_library import load_device
d = load_device('attiny202')
assert d.find_peripheral('WDT') is not None, "WDT peripheral missing (patch 0001 not applied?)"
PY
    return 0
}

if already_built; then
    log "Patched yasimavr ${VER} already built in ${VENV} (verified stamp + import); nothing to do."
    printf 'YASIMAVR_VENV=%s\n' "$VENV"
    exit 0
fi

# --- tool checks ----------------------------------------------------------------
have python3   || die "python3 not found (install 'python3')."
have c++ || have g++ || die "no C++ compiler (install 'g++')."
have sha256sum || die "sha256sum not found (install 'coreutils')."
have patch || have git || die "need 'patch' or 'git' to apply the vendored patches."
if   have curl; then DL="curl -fsSL --max-time 300 -o"
elif have wget; then DL="wget -q -O"
else die "need curl or wget to download the yasimavr sdist."
fi
# CPython headers are needed to compile yasimavr's C++/SIP modules. Fail early
# with an actionable message rather than deep inside a pip build log.
python3 - <<'PY' 2>/dev/null || die "CPython development headers not found (install 'python3-dev')."
import os, sysconfig
h = os.path.join(sysconfig.get_path('include'), 'Python.h')
raise SystemExit(0 if os.path.exists(h) else 1)
PY

# --- work in private temp dirs; always clean up ---------------------------------
# BUILD_VENV is a sibling of VENV so the verified directory can be installed by
# rename. OLD_VENV is populated only during replacement and is restored if the
# final rename fails or a signal arrives between the two renames.
BUILD_VENV=
OLD_VENV=
OLD_VENV_MOVED=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/fetch-yasimavr.XXXXXX")" \
    || die "could not create download/build temporary directory"
restore_previous_venv() {
    [ -n "${OLD_VENV:-}" ] || return 1
    if mv -T -n -- "$OLD_VENV" "$VENV" \
            && [ ! -e "$OLD_VENV" ] && [ ! -L "$OLD_VENV" ]; then
        OLD_VENV_MOVED=0
        OLD_VENV=
        return 0
    fi
    return 1
}
cleanup() {
    status=$?
    trap - EXIT HUP INT TERM
    if [ -n "${OLD_VENV:-}" ] \
            && { [ -e "$OLD_VENV" ] || [ -L "$OLD_VENV" ]; }; then
        if [ "${OLD_VENV_MOVED:-0}" -eq 1 ]; then
            restore_previous_venv \
                || log "ERROR: could not restore previous VENV_DIR from ${OLD_VENV}"
        elif [ "${OLD_VENV_MOVED:-0}" -eq 0 ]; then
            rmdir -- "$OLD_VENV" 2>/dev/null \
                || log "WARNING: backup-path reservation preserved at ${OLD_VENV}"
        else
            log "WARNING: previous VENV_DIR preserved at ${OLD_VENV}"
        fi
    fi
    [ -z "${BUILD_VENV:-}" ] || rm -rf -- "$BUILD_VENV" \
        || log "WARNING: temporary build directory preserved at ${BUILD_VENV}"
    rm -rf -- "$TMP" \
        || log "WARNING: temporary download directory preserved at ${TMP}"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

BUILD_VENV="$(mktemp -d "${VENV_PARENT}/.${VENV_NAME}.build.XXXXXX")" \
    || die "could not create temporary sibling of VENV_DIR: ${VENV_PARENT}"
BUILD_PY="${BUILD_VENV}/bin/python"
BUILD_STAMP="${BUILD_VENV}/.yasimavr.stamp"

# --- download the pinned sdist and verify integrity BEFORE trusting any bytes ---
SDIST="${TMP}/yasimavr-${VER}.tar.gz"
URL="https://files.pythonhosted.org/packages/source/y/yasimavr/yasimavr-${VER}.tar.gz"
log "Downloading yasimavr ${VER} sdist"
log "  ${URL}"
# shellcheck disable=SC2086
$DL "$SDIST" "$URL" || die "download failed: ${URL}"

GOT="$(sha256sum "$SDIST" | cut -d' ' -f1)"
[ "$GOT" = "$SDIST_SHA256" ] || die "SHA-256 mismatch for the sdist.
  expected: ${SDIST_SHA256}
  got:      ${GOT}
  (PyPI content changed, or VER/SHA are out of sync -- do NOT proceed.)"
log "SHA-256 OK (${SDIST_SHA256})"

# --- extract + apply the vendored patches ---------------------------------------
tar -xzf "$SDIST" -C "$TMP" || die "failed to extract the sdist."
SRC="${TMP}/yasimavr-${VER}"
[ -d "$SRC" ] || die "unexpected sdist layout: ${SRC} missing after extract."

for p in "$PATCH_DIR"/*.patch; do
    log "Applying patch: $(basename "$p")"
    if have patch; then
        ( cd "$SRC" && patch -p1 --forward --silent < "$p" ) \
            || die "failed to apply $(basename "$p") (does it still match yasimavr ${VER}?)."
    else
        ( cd "$SRC" && git apply -p1 "$p" ) \
            || die "failed to apply $(basename "$p") with git apply."
    fi
done

# --- create the venv (portable: some distros ship python3 without a working ------
# ensurepip, e.g. Debian strips it; create --without-pip then bootstrap get-pip) -
log "Creating virtualenv for ${VENV}"
if python3 -m venv "$BUILD_VENV" 2>/dev/null && "$BUILD_PY" -m pip --version >/dev/null 2>&1; then
    : # venv came with a working pip
else
    log "  ensurepip unavailable; creating --without-pip and bootstrapping get-pip"
    rm -rf -- "$BUILD_VENV"
    mkdir -m 700 -- "$BUILD_VENV" \
        || die "could not reset temporary virtualenv directory"
    python3 -m venv --without-pip "$BUILD_VENV" || die "python3 -m venv failed (install 'python3-venv')."
    GETPIP="${TMP}/get-pip.py"
    # shellcheck disable=SC2086
    $DL "$GETPIP" "$GET_PIP_URL" || die "failed to download get-pip.py from ${GET_PIP_URL}"
    "$BUILD_PY" "$GETPIP" >&2 || die "get-pip.py bootstrap failed."
fi
"$BUILD_PY" -m pip --version >/dev/null 2>&1 || die "pip is not available in the venv after bootstrap."

# --- build + install the patched tree into the venv -----------------------------
# PEP 517 build pulls the sip backend from PyPI and compiles the C++/SIP modules
# (this is the slow step -- a minute or two). Keep the build quiet unless it fails.
log "Building + installing patched yasimavr ${VER} (compiling C++/SIP extensions; this may take a minute)"
if ! "$BUILD_PY" -m pip install --no-input "$SRC" >"${TMP}/pip.log" 2>&1; then
    log "--- pip build log (tail) ---"
    tail -n 40 "${TMP}/pip.log" >&2 || true
    die "pip install of the patched yasimavr failed."
fi

# --- verify the result end-to-end (import + patch 0001 took) --------------------
"$BUILD_PY" - <<'PY' >/dev/null 2>&1 || die "post-build verification failed: yasimavr did not import, or the WDT peripheral is still missing."
from yasimavr.device_library import load_device
d = load_device('attiny202')
assert d.find_peripheral('WDT') is not None
PY

printf '%s' "$SIG" > "$BUILD_STAMP"

# Install only the fully verified tree. For a replacement, first rename the
# owned old venv aside; cleanup restores it if the second rename cannot finish.
if [ "$DESTINATION_EXISTS" -eq 1 ]; then
    [ -d "$VENV" ] && [ ! -L "$VENV" ] && has_yasimavr_stamp "$VENV_STAMP" \
        || die "VENV_DIR changed while yasimavr was being built: ${VENV}"
    OLD_VENV="$(mktemp -d "${VENV_PARENT}/.${VENV_NAME}.old.XXXXXX")" \
        || die "could not reserve a backup path for VENV_DIR"
    rmdir -- "$OLD_VENV" || die "could not prepare the VENV_DIR backup path"
    OLD_VENV_MOVED=1
    if ! mv -T -- "$VENV" "$OLD_VENV"; then
        OLD_VENV_MOVED=0
        OLD_VENV=
        die "could not move the previous VENV_DIR aside"
    fi
    if ! has_yasimavr_stamp "$OLD_VENV/.yasimavr.stamp"; then
        restore_previous_venv || :
        die "VENV_DIR changed before it could be moved safely"
    fi
else
    [ ! -e "$VENV" ] && [ ! -L "$VENV" ] \
        || die "VENV_DIR appeared while yasimavr was being built: ${VENV}"
fi

# `-T` forbids nesting into a directory that appeared late; `-n` also refuses
# to replace an empty one. GNU mv reports success for a no-clobber refusal, so
# disappearance of the source is the authoritative rename-success witness.
if mv -T -n -- "$BUILD_VENV" "$VENV" \
        && [ ! -e "$BUILD_VENV" ] && [ ! -L "$BUILD_VENV" ]; then
    :
else
    restore_previous_venv || :
    die "could not install the verified VENV_DIR"
fi
BUILD_VENV=
if [ -n "$OLD_VENV" ]; then
    # Never recursively delete a path derived from the caller's destination.
    # Keeping the prior verified tree also provides a manual rollback point.
    log "  previous stamped venv preserved at ${OLD_VENV}"
    OLD_VENV_MOVED=0
    OLD_VENV=
fi

log "Patched yasimavr ${VER} built + verified in ${VENV}"
log "  patches:  $(for p in "$PATCH_DIR"/*.patch; do printf '%s ' "$(basename "$p")"; done)"
log "  run the harness with, e.g.:  make attiny202-sim"
printf 'YASIMAVR_VENV=%s\n' "$VENV"
