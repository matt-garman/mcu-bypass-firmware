#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
#
# fetch_attiny_dfp.sh -- vendor the minimal ATtiny_DFP device files needed to
# build the ATtiny202 (AVR-XT / avrxmega3) firmware with the STOCK, open-source
# apt toolchain (gcc-avr / binutils-avr / avr-libc from Ubuntu universe).
#
# WHY THIS EXISTS
#   The packaged binutils already has the avrxmega3 (AVR8X) linker emulation and
#   gcc-avr ships the avrxmega3 runtime libs, so the compiler/assembler/linker
#   already speak the ATtiny202's architecture. The ONLY missing pieces are the
#   per-device description files (the gcc spec, the crt/startup object, the
#   device runtime lib, and the <avr/io.h> device header). Those live in
#   Microchip's ATtiny Device Family Pack (a plain zip served as ".atpack").
#
#   This mirrors how the PIC build consumes an external, UNCOMMITTED device pack
#   (Makefile's PIC_DFP): nothing binary is committed to git; the pack is fetched
#   on demand, pinned by version + SHA-256 for reproducibility, and the Makefile
#   target skips cleanly when the vendored files are absent.
#
# WHAT IT VENDORS (exactly four files -- verified sufficient, incl. -Wconversion):
#   gcc/dev/attiny202/device-specs/specs-attiny202
#   gcc/dev/attiny202/avrxmega3/short-calls/crtattiny202.o
#   gcc/dev/attiny202/avrxmega3/short-calls/libattiny202.a
#   include/avr/iotn202.h
#
# USAGE
#   scripts/fetch_attiny_dfp.sh [DEST_DIR]
#     DEST_DIR  where to place the vendored tree (default: ./third_party/attiny_dfp).
#               Override the Makefile's XT_DFP to point at this same dir.
#   Env overrides: ATTINY_DFP_VER, ATTINY_DFP_SHA256, ATTINY_DFP_URL_BASE.
#
# The download URL is a direct, no-account, no-EULA, version-pinned static file:
#   https://packs.download.microchip.com/Microchip.ATtiny_DFP.<ver>.atpack
#
# EXIT STATUS
#   0  files present and verified (freshly fetched or already cached)
#   1  a required tool is missing, or download/verification failed

set -eu

# --- pinned pack (bump VER + SHA together; get the new SHA from a trusted run) ---
VER="${ATTINY_DFP_VER:-3.1.260}"
SHA256="${ATTINY_DFP_SHA256:-59e3b4317cfc3a07a4ee637e49df44c5bd9025d08cf071b4d0d0c83396af5aae}"
URL_BASE="${ATTINY_DFP_URL_BASE:-https://packs.download.microchip.com}"
URL="${URL_BASE}/Microchip.ATtiny_DFP.${VER}.atpack"

DEST="${1:-third_party/attiny_dfp}"

# The four files we extract (paths are relative to both the atpack root and DEST).
FILES="gcc/dev/attiny202/device-specs/specs-attiny202
gcc/dev/attiny202/avrxmega3/short-calls/crtattiny202.o
gcc/dev/attiny202/avrxmega3/short-calls/libattiny202.a
include/avr/iotn202.h"

STAMP="${DEST}/.attiny_dfp.stamp"   # records "VER SHA256" of the vendored set

log() { printf '%s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# --- idempotence: already vendored at this exact version? -----------------------
all_present() {
    [ -f "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "${VER} ${SHA256}" ] || return 1
    for f in $FILES; do [ -f "${DEST}/${f}" ] || return 1; done
    return 0
}

if all_present; then
    log "ATtiny_DFP ${VER} already vendored in ${DEST} (verified stamp); nothing to do."
    printf 'XT_DFP=%s\n' "$DEST"
    exit 0
fi

# --- tool checks ----------------------------------------------------------------
have unzip     || die "unzip not found (install 'unzip')."
have sha256sum || die "sha256sum not found (install 'coreutils')."
if   have curl; then DL="curl -fsSL --max-time 300 -o"
elif have wget; then DL="wget -q -O"
else die "need curl or wget to download the atpack."
fi

# --- download to a temp file ----------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
PACK="${TMP}/ATtiny_DFP.${VER}.atpack"

log "Downloading ATtiny_DFP ${VER}"
log "  ${URL}"
# shellcheck disable=SC2086
$DL "$PACK" "$URL" || die "download failed: ${URL}"

# --- verify integrity BEFORE trusting any bytes ---------------------------------
GOT="$(sha256sum "$PACK" | cut -d' ' -f1)"
[ "$GOT" = "$SHA256" ] || die "SHA-256 mismatch for the atpack.
  expected: ${SHA256}
  got:      ${GOT}
  (URL content changed, or VER/SHA are out of sync -- do NOT proceed.)"
log "SHA-256 OK (${SHA256})"

# --- extract exactly the four files, preserving their relative paths ------------
mkdir -p "$DEST"
# shellcheck disable=SC2086
unzip -qo "$PACK" $FILES -d "$DEST" || die "extraction failed (atpack layout changed?)."

# confirm every expected file landed
for f in $FILES; do
    [ -f "${DEST}/${f}" ] || die "expected file missing after extract: ${DEST}/${f}"
done

printf '%s %s\n' "$VER" "$SHA256" > "$STAMP"
log "Vendored ATtiny_DFP ${VER} into ${DEST}:"
for f in $FILES; do log "  ${f}"; done
log "Point the build at it with:  make attiny202 XT_DFP=${DEST}   (or set XT_DFP in your env)"
printf 'XT_DFP=%s\n' "$DEST"
