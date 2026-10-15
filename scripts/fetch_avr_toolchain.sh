#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) Matthew Garman
#
# fetch_avr_toolchain.sh -- install the historic AVR toolchain (avr-gcc 7.3.0,
# binutils-avr 2.26, avr-libc 2.0.0) into a project-local prefix.
#
# WHY THIS EXISTS
#   avr-gcc 7.3.0 built every release up to v0.9.17, and their published images
#   are byte-defined by it. From v0.9.18 the image-defining compiler is Ubuntu
#   26.04's own avr-gcc 14.3.0 (TOOLCHAIN.adoc), which produces different
#   images, so 7.3.0 is no longer on any supported distribution's shelf. This
#   installs it to reproduce those releases, and as the comparison compiler of
#   the cross-compiler lane (`make test-cross-compiler`). The packages are the
#   ones Ubuntu 24.04 (noble) ships, and they run unchanged from a prefix: the
#   compiler locates its assembler, linker, headers and libraries relative to
#   its own path. Measured on
#   2026-10-14, a toolchain installed this way rebuilt all 21 v0.9.16 images
#   bit-for-bit.
#
#   Nothing binary is committed: the three packages are fetched on demand,
#   each pinned by SHA-256 and checked before any byte is extracted, and the
#   extracted tree is pinned by one digest that is re-verified on every
#   invocation, so a restored or tampered prefix is caught rather than trusted
#   by its stamp.
#
# USAGE
#   scripts/fetch_avr_toolchain.sh [DEST_DIR]
#     DEST_DIR  install prefix (default: ./third_party/avr-toolchain). The tools
#               land in DEST_DIR/usr/bin; to rebuild a release up to v0.9.17,
#               put that FIRST on PATH so every avr-* tool, including the ones
#               gates run by name, is the historic one:
#                 export PATH="$PWD/third_party/avr-toolchain/usr/bin:$PATH"
#               Take it off PATH for current work: under STRICT_TOOLS=1 `make
#               test` refuses it as the default compiler and names it.
#   Env overrides (for isolated regression fixtures): AVR_TOOLCHAIN_URL_BASE,
#   AVR_TOOLCHAIN_DEBS, AVR_TOOLCHAIN_TREE_SHA256, AVR_TOOLCHAIN_VERSION_LINE.
#
# The packages come from the Ubuntu archive pool, where they remain after noble
# is superseded. Their digests were taken from noble's universe Packages index,
# whose hash was in turn checked against the InRelease file signed by the Ubuntu
# Archive Automatic Signing Key (2018).
#
# EXIT STATUS
#   0  the historic toolchain is present and verified (freshly installed or cached)
#   1  a required tool is missing, or download, verification or install failed

set -eu

URL_BASE="${AVR_TOOLCHAIN_URL_BASE:-https://archive.ubuntu.com/ubuntu/pool/universe}"
# One "sha256 pool-path" pair per line. Bump these, the tree digest and the
# version line together, from a verified run.
DEBS="${AVR_TOOLCHAIN_DEBS:-ac9dae48c82b1f174434fa04de543014fbaf334c787ba16adfb7fc26eb180ce9 g/gcc-avr/gcc-avr_7.3.0+Atmel3.7.0-1_amd64.deb
a4e84a866d03d87e5d5d1d1aa2284991f665c62834014c741149d8defe63040d b/binutils-avr/binutils-avr_2.26.20160125+Atmel3.7.0-2_amd64.deb
a810bfd9103264bfb225105db1d39c379882b4f3b3fc964575bc9776d45f257f a/avr-libc/avr-libc_2.0.0+Atmel3.7.0-1_all.deb}"
TREE_SHA256="${AVR_TOOLCHAIN_TREE_SHA256:-f17a5fc9017bd397381019f4db9d52151f7808a622c7046bdb0037f8861eaec8}"
VERSION_LINE="${AVR_TOOLCHAIN_VERSION_LINE:-avr-gcc (GCC) 7.3.0}"

DEST="${1:-third_party/avr-toolchain}"
STAMP_NAME=.avr-toolchain.stamp

log() { printf '%s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# The digest of an installed tree: every regular file's content, path and
# executable bit, and every symlink's target. Full modes are deliberately left
# out, because extraction applies the caller's umask; the executable bit is
# kept, because a tree whose compiler cannot run is not the pinned toolchain.
tree_digest() {
    (
        cd "$1" || exit 1
        {
            find . -type f ! -name "$STAMP_NAME" -print0 | LC_ALL=C sort -z \
                | xargs -0 -r sha256sum
            find . -type f ! -name "$STAMP_NAME" -perm -u+x -printf 'x %p\n'
            find . -type l -printf 'l %p -> %l\n'
        } | LC_ALL=C sort | sha256sum | cut -d' ' -f1
    )
}

stamp_value() {
    printf '%s\n%s\n' "$DEBS" "$TREE_SHA256" | sha256sum | cut -d' ' -f1
}

installed() {
    [ -d "$DEST" ] && [ ! -L "$DEST" ] || return 1
    [ -f "$DEST/$STAMP_NAME" ] && [ ! -L "$DEST/$STAMP_NAME" ] || return 1
    [ "$(cat "$DEST/$STAMP_NAME" 2>/dev/null)" = "$(stamp_value)" ] || return 1
    [ "$(tree_digest "$DEST")" = "$TREE_SHA256" ]
}

for tool in sha256sum find sort xargs cut; do
    have "$tool" || die "$tool not found"
done
case "$TREE_SHA256" in
    *[!0-9a-f]*|'') die "the pinned tree digest is not a SHA-256: ${TREE_SHA256}" ;;
esac
[ "${#TREE_SHA256}" -eq 64 ] || die "the pinned tree digest is not a SHA-256: ${TREE_SHA256}"

[ -n "$DEST" ] || die "DEST_DIR must not be empty"
[ ! -L "$DEST" ] || die "DEST_DIR must not be a symlink: ${DEST}"
[ ! -e "$DEST" ] || [ -d "$DEST" ] || die "DEST_DIR exists but is not a directory: ${DEST}"
DEST_PARENT=$(dirname -- "$DEST")
[ -d "$DEST_PARENT" ] || die "DEST_DIR parent does not exist: ${DEST_PARENT}"

if installed; then
    log "historic AVR toolchain already installed in ${DEST} (verified stamp + tree digest); nothing to do."
    printf 'AVR_TOOLCHAIN_BIN=%s/usr/bin\n' "$DEST"
    exit 0
fi

# Never replace a directory this script did not create: only a stamped prefix,
# even a stale or damaged one, is ours to rebuild.
if [ -d "$DEST" ] && [ ! -f "$DEST/$STAMP_NAME" ]; then
    die "refusing to replace an existing DEST_DIR that has no ${STAMP_NAME}: ${DEST}"
fi

# --- tool checks ----------------------------------------------------------------
have dpkg-deb || die "dpkg-deb not found (this installs Debian packages; install 'dpkg')."
case "$(uname -m)" in
    x86_64) ;;
    *) die "the pinned packages are amd64; this host is $(uname -m)." ;;
esac
if   have curl; then DL="curl -fsSL --max-time 300 -o"
elif have wget; then DL="wget -q -O"
else die "need curl or wget to download the packages."
fi

# --- download and verify every package before extracting any -------------------
STAGE=
TMP="$(mktemp -d)"
cleanup() {
    status=$?
    trap - 0 HUP INT TERM
    [ -z "$STAGE" ] || rm -rf -- "$STAGE"
    rm -rf -- "$TMP"
    exit "$status"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

printf '%s\n' "$DEBS" > "$TMP/debs"
count=0
while read -r sha path; do
    [ -n "$sha" ] && [ -n "$path" ] || die "malformed package pin: '${sha} ${path}'"
    count=$((count + 1))
    deb="$TMP/$count.deb"
    log "Downloading ${URL_BASE}/${path}"
    # shellcheck disable=SC2086
    $DL "$deb" "${URL_BASE}/${path}" || die "download failed: ${URL_BASE}/${path}"
    got=$(sha256sum "$deb" | cut -d' ' -f1)
    [ "$got" = "$sha" ] || die "SHA-256 mismatch for ${path##*/}.
  expected: ${sha}
  got:      ${got}
  (the archive content changed, or the pins are out of sync -- do NOT proceed.)"
done < "$TMP/debs"
[ "$count" -gt 0 ] || die "no packages are pinned"
log "SHA-256 OK for all ${count} packages"

# --- extract into a sibling staging tree, verify it, then rename it in ---------
STAGE=$(mktemp -d "${DEST_PARENT}/.avr-toolchain.stage.XXXXXX") \
    || die "could not create a staging directory beside ${DEST}"
i=1
while [ "$i" -le "$count" ]; do
    dpkg-deb -x "$TMP/$i.deb" "$STAGE" || die "could not extract package ${i}"
    i=$((i + 1))
done
got=$(tree_digest "$STAGE")
[ "$got" = "$TREE_SHA256" ] || die "the extracted toolchain does not match its pinned tree digest.
  expected: ${TREE_SHA256}
  got:      ${got}"

# The digest proves the bytes; this proves they run from here.
version=$("$STAGE/usr/bin/avr-gcc" --version 2>/dev/null | head -n 1) \
    || die "the extracted avr-gcc does not run on this host"
[ "$version" = "$VERSION_LINE" ] \
    || die "the extracted avr-gcc reports '${version}', not '${VERSION_LINE}'"
printf 'int main(void) { for (;;) { } }\n' > "$TMP/probe.c"
"$STAGE/usr/bin/avr-gcc" -mmcu=attiny13a -Os -o "$TMP/probe.elf" "$TMP/probe.c" \
    || die "the extracted toolchain cannot compile and link for the ATtiny13A"
"$STAGE/usr/bin/avr-size" --format=avr --mcu=attiny13a "$TMP/probe.elf" | grep -q '^Program:' \
    || die "the extracted avr-size cannot report AVR memory usage (--format=avr)"

stamp_value > "$STAGE/$STAMP_NAME" || die "could not write the stamp"
if [ -d "$DEST" ]; then
    OLD="${DEST_PARENT}/.avr-toolchain.old.$$"
    mv -T -- "$DEST" "$OLD" || die "could not move the previous install aside"
    mv -T -- "$STAGE" "$DEST" || { mv -T -- "$OLD" "$DEST"; die "could not install ${DEST}"; }
    rm -rf -- "$OLD"
else
    mv -T -- "$STAGE" "$DEST" || die "could not install ${DEST}"
fi
STAGE=
log "Installed the historic AVR toolchain (${VERSION_LINE}) into ${DEST}."
log "To rebuild a release up to v0.9.17, put it first on PATH so every avr-* tool is the historic one:"
log "  export PATH=\"$(cd "$DEST" && pwd -P)/usr/bin:\$PATH\""
printf 'AVR_TOOLCHAIN_BIN=%s/usr/bin\n' "$DEST"
