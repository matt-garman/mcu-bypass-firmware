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

# --- pinned upstream release (bump VER + SHA together, from a trusted run) ------
VER="${YASIMAVR_VER:-0.1.6}"
SDIST_SHA256="${YASIMAVR_SDIST_SHA256:-3742dae364a8d65ff7d4180d00b40c0901656dafcea6e53e94db1127b7ec6285}"
GET_PIP_URL="${GET_PIP_URL:-https://bootstrap.pypa.io/get-pip.py}"

# Resolve paths relative to the repo root (this script's parent's parent), so it
# works regardless of the caller's cwd.
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"

VENV="${1:-${REPO_ROOT}/third_party/yasimavr/venv}"
PATCH_DIR="${REPO_ROOT}/third_party/yasimavr/patches"
STAMP="${VENV}/.yasimavr.stamp"   # records "VER SDIST_SHA256 PATCHSET_SHA256"

log() { printf '%s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -d "$PATCH_DIR" ] || die "patch dir not found: ${PATCH_DIR}"

# Build signature = pinned release + a hash of the exact patch set. Changing a
# patch (or the version/SHA) changes the signature and forces a rebuild.
PATCHSET_SHA256="$(cat "$PATCH_DIR"/*.patch | sha256sum | cut -d' ' -f1)"
SIG="${VER} ${SDIST_SHA256} ${PATCHSET_SHA256}"

# The venv's python (POSIX layout: bin/). Used for idempotence + build + verify.
VPY="${VENV}/bin/python"

# --- idempotence: already built at this exact signature, and still importable? --
already_built() {
    [ -f "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$SIG" ] || return 1
    [ -x "$VPY" ] || return 1
    # Confirm the build is intact AND patch 0001 took (WDT instantiates). This
    # also exercises that the compiled extension imports on this interpreter.
    "$VPY" - <<'PY' >/dev/null 2>&1 || return 1
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

# --- work in a temp dir; always clean up ----------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

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
log "Creating virtualenv at ${VENV}"
rm -rf "$VENV"
if python3 -m venv "$VENV" 2>/dev/null && "$VPY" -m pip --version >/dev/null 2>&1; then
    : # venv came with a working pip
else
    log "  ensurepip unavailable; creating --without-pip and bootstrapping get-pip"
    rm -rf "$VENV"
    python3 -m venv --without-pip "$VENV" || die "python3 -m venv failed (install 'python3-venv')."
    GETPIP="${TMP}/get-pip.py"
    # shellcheck disable=SC2086
    $DL "$GETPIP" "$GET_PIP_URL" || die "failed to download get-pip.py from ${GET_PIP_URL}"
    "$VPY" "$GETPIP" >&2 || die "get-pip.py bootstrap failed."
fi
"$VPY" -m pip --version >/dev/null 2>&1 || die "pip is not available in the venv after bootstrap."

# --- build + install the patched tree into the venv -----------------------------
# PEP 517 build pulls the sip backend from PyPI and compiles the C++/SIP modules
# (this is the slow step -- a minute or two). Keep the build quiet unless it fails.
log "Building + installing patched yasimavr ${VER} (compiling C++/SIP extensions; this may take a minute)"
if ! "$VPY" -m pip install --no-input "$SRC" >"${TMP}/pip.log" 2>&1; then
    log "--- pip build log (tail) ---"
    tail -n 40 "${TMP}/pip.log" >&2 || true
    die "pip install of the patched yasimavr failed."
fi

# --- verify the result end-to-end (import + patch 0001 took) --------------------
"$VPY" - <<'PY' >/dev/null 2>&1 || die "post-build verification failed: yasimavr did not import, or the WDT peripheral is still missing."
from yasimavr.device_library import load_device
d = load_device('attiny202')
assert d.find_peripheral('WDT') is not None
PY

printf '%s' "$SIG" > "$STAMP"
log "Patched yasimavr ${VER} built + verified in ${VENV}"
log "  patches:  $(for p in "$PATCH_DIR"/*.patch; do printf '%s ' "$(basename "$p")"; done)"
log "  run the harness with, e.g.:  make attiny202-sim"
printf 'YASIMAVR_VENV=%s\n' "$VENV"
