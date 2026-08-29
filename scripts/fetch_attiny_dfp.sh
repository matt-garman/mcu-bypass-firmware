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
#   Env overrides: ATTINY_DFP_VER, ATTINY_DFP_SHA256, ATTINY_DFP_URL_BASE,
#                  ATTINY_DFP_FILE_HASHES (for isolated regression fixtures).
#
# The download URL is a direct, no-account, no-EULA, version-pinned static file:
#   https://packs.download.microchip.com/Microchip.ATtiny_DFP.<ver>.atpack
#
# EXIT STATUS
#   0  files present and verified (freshly fetched or already cached)
#   1  a required tool is missing, or download/verification failed

set -eu

# --- pinned pack (bump VER + SHA together; get the new SHA from a trusted run) ---
# This file is the ONLY place the pack version is pinned. The CI caches key on
# hashFiles('scripts/fetch_attiny_dfp.sh'), so a bump here invalidates them; the
# workflows must not carry a second copy of VER in a job env (see release.yml).
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

# The extracted build inputs are independently pinned so a restored cache is
# verified byte-for-byte on every invocation rather than trusted by stamp alone.
FILE_HASHES="${ATTINY_DFP_FILE_HASHES:-7ee7a65d516d53cd97a3af687ee55904578ac79febf4c829fca30cd3dce3c10a  gcc/dev/attiny202/device-specs/specs-attiny202
33dd5603c7d70d4705f97c9a09d9950eaf2889b7bb0145d40dbaf72bd0b3a8fc  gcc/dev/attiny202/avrxmega3/short-calls/crtattiny202.o
60ced1cb81148acb11944f85b38af9ebf6ece2dbae92f352b2b7d42a158c102f  gcc/dev/attiny202/avrxmega3/short-calls/libattiny202.a
13a0b2bf106dcc82db6bc0a7179b74bdd21ec85dd55f74071d8349af1e07c153  include/avr/iotn202.h}"

STAMP="${DEST}/.attiny_dfp.stamp"   # records "VER SHA256" of the vendored set

log() { printf '%s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# --- idempotence: already vendored at this exact version and content? -----------
files_match() {
    [ -d "$DEST" ] || return 1
    [ ! -L "$DEST" ] || return 1
    symlink=$(cd "$DEST" && find . -type l -print -quit) || return 1
    [ -z "$symlink" ] || return 1
    expected_count=0
    for f in $FILES; do
        [ -f "${DEST}/${f}" ] && [ ! -L "${DEST}/${f}" ] || return 1
        expected_count=$((expected_count + 1))
    done
    observed_count=$(cd "$DEST" \
        && find . ! -type d ! -path './.attiny_dfp.stamp' -print | wc -l) \
        || return 1
    [ "$observed_count" -eq "$expected_count" ] || return 1
    (cd "$DEST" && printf '%s\n' "$FILE_HASHES" | sha256sum -c - >/dev/null 2>&1)
}

all_present() {
    [ -f "$STAMP" ] && [ ! -L "$STAMP" ] \
        && [ "$(cat "$STAMP" 2>/dev/null)" = "${VER} ${SHA256}" ] || return 1
    files_match
}

for tool in sha256sum find wc; do
    have "$tool" || die "$tool not found"
done

[ ! -L "$DEST" ] || die "DEST_DIR must not be a symlink: ${DEST}"
[ ! -L "$STAMP" ] || die "refusing to replace symlinked stamp: ${STAMP}"

if all_present; then
    log "ATtiny_DFP ${VER} already vendored in ${DEST} (verified stamp + file hashes); nothing to do."
    printf 'XT_DFP=%s\n' "$DEST"
    exit 0
fi

# --- tool checks ----------------------------------------------------------------
have unzip     || die "unzip not found (install 'unzip')."
if   have curl; then DL="curl -fsSL --max-time 300 -o"
elif have wget; then DL="wget -q -O"
else die "need curl or wget to download the atpack."
fi

# --- download to a temp file ----------------------------------------------------
STAMP_TMP=
TMP="$(mktemp -d)"
cleanup() {
    status=$?
    trap - 0 HUP INT TERM
    [ -z "$STAMP_TMP" ] || rm -f -- "$STAMP_TMP"
    rm -rf "$TMP"
    exit "$status"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM
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

# Confirm every expected file landed with the reviewed bytes before blessing the
# cache with its stamp.
files_match || die "extracted ATtiny_DFP files do not match their reviewed SHA-256 values"

[ ! -L "$STAMP" ] || die "refusing to replace symlinked stamp: ${STAMP}"
STAMP_TMP=$(mktemp "${DEST}/.attiny_dfp.stamp.tmp.XXXXXX") \
    || die "could not create a temporary stamp next to ${STAMP}"
printf '%s %s\n' "$VER" "$SHA256" > "$STAMP_TMP" \
    || die "could not write temporary stamp: ${STAMP_TMP}"
mv -T -- "$STAMP_TMP" "$STAMP" || die "could not atomically install stamp: ${STAMP}"
STAMP_TMP=
log "Vendored ATtiny_DFP ${VER} into ${DEST}:"
for f in $FILES; do log "  ${f}"; done
log "Point the build at it with:  make attiny202 XT_DFP=${DEST}   (or set XT_DFP in your env)"
printf 'XT_DFP=%s\n' "$DEST"
