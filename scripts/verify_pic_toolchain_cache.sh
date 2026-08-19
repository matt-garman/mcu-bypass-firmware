#!/bin/sh
# Verify a RESTORED XC8 + PIC10-12Fxxx_DFP cache against the integrity manifest
# that install_pic_toolchain.sh froze at install time.
#
# CI restores /opt/microchip WITHOUT re-running the SHA-verified installer, so
# this read-only check (no network, no sudo) is what rejects a corrupted or
# incomplete restored cache before any build or test consumes it. It mirrors the
# self-verifying ATtiny_DFP cache path (scripts/fetch_attiny_dfp.sh).
#
#   Exit 0  the restored tree matches the recorded manifest exactly.
#   Exit 1  missing / mismatched / corrupt / incomplete / symlinked cache.

set -eu

log() { printf '%s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
is_sha256() {
    [ "${#1}" -eq 64 ] || return 1
    case "$1" in
        *[!0123456789abcdef]*) return 1 ;;
    esac
}

[ "$#" -eq 0 ] || die "usage: scripts/verify_pic_toolchain_cache.sh"

XC8_VERSION=${XC8_VERSION:-3.10}
DFP_VERSION=${DFP_VERSION:-1.9.189}
XC8_DIR=${XC8_DIR:-/opt/microchip/xc8/v3.10}
XC8_DFP_ROOT=${XC8_DFP_ROOT:-/opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189}
XC8_CACHE_DIR=${XC8_CACHE_DIR:-/opt/microchip}

# The same reviewed digests install_pic_toolchain.sh pins; the stamp binds the
# restored cache to this exact (compiler, DFP) pair, so a cache built from a
# different pinned toolchain is rejected rather than trusted.
XC8_INSTALLER_SHA256=${XC8_INSTALLER_SHA256:-628803b96f468a5981d6bc1d0a5e6c7fa809e4d87e3cca961805e2a857f5846e}
PIC_DFP_SHA256=${PIC_DFP_SHA256:-add68db8b76705557a99647bde5b149d17caf259d968f5946058356275eed75b}

is_sha256 "$XC8_INSTALLER_SHA256" || die "invalid XC8_INSTALLER_SHA256"
is_sha256 "$PIC_DFP_SHA256" || die "invalid PIC_DFP_SHA256"
for tool in sha256sum find sort xargs diff; do
    have "$tool" || die "$tool not found"
done

xc8_stamp="$XC8_CACHE_DIR/.xc8_toolchain.stamp"
xc8_manifest="$XC8_CACHE_DIR/.xc8_toolchain.manifest"

# --- component roots: real directories, no symlinks anywhere ------------------
for root in "$XC8_DIR" "$XC8_DFP_ROOT"; do
    [ -e "$root" ] || die "restored cache is incomplete: missing $root"
    [ ! -L "$root" ] || die "restored cache root is a symlink: $root"
    [ -d "$root" ] || die "restored cache root is not a directory: $root"
done
# Scoped to READABLE files, pruning unreadable dirs -- identical to the walk
# install_pic_toolchain.sh recorded with (see its comment: root-only installer
# bookkeeping is not a build input, and permissions survive the cache
# save/restore, so both walks see the same readable set).
syms=$(find "$XC8_DIR" "$XC8_DFP_ROOT" \
        \( -type d ! -readable -prune \) -o \( -type l -print \)) \
    || die "could not scan the restored tree for symlinks"
[ -z "$syms" ] || die "restored cache contains symlinks (rejected):
$syms"

# --- critical files present ---------------------------------------------------
xc8="$XC8_DIR/bin/xc8-cc"
[ -f "$xc8" ] && [ -x "$xc8" ] || die "restored cache missing executable $xc8"
for device in pic10f322 pic10f320 pic12f675; do
    header="$XC8_DFP_ROOT/xc8/pic/include/proc/${device}.h"
    [ -f "$header" ] || die "restored cache missing device header $header"
done

# --- stamp binds the cache to the pinned (compiler, DFP) pair -----------------
[ -f "$xc8_stamp" ] || die "restored cache missing integrity stamp $xc8_stamp"
[ ! -L "$xc8_stamp" ] || die "integrity stamp is a symlink: $xc8_stamp"
expected_stamp="$XC8_VERSION $DFP_VERSION $XC8_INSTALLER_SHA256 $PIC_DFP_SHA256"
actual_stamp=$(cat "$xc8_stamp") || die "could not read $xc8_stamp"
[ "$actual_stamp" = "$expected_stamp" ] || die "cache stamp does not match the pinned toolchain.
  expected: $expected_stamp
  got:      $actual_stamp"

# --- tree matches the recorded manifest byte-for-byte -------------------------
# Regenerate the manifest exactly as install_pic_toolchain.sh did (deterministic
# LC_ALL=C order over every regular file under both roots) and require an exact
# match. This catches a corrupted file (digest differs), a missing file
# (incomplete restore), and an extra file (unexpected input) in one comparison.
[ -f "$xc8_manifest" ] || die "restored cache missing integrity manifest $xc8_manifest"
[ ! -L "$xc8_manifest" ] || die "integrity manifest is a symlink: $xc8_manifest"

current=$(find "$XC8_DIR" "$XC8_DFP_ROOT" \
        \( -type d ! -readable -prune \) -o \( -type f -readable -print0 \) \
    | LC_ALL=C sort -z | xargs -0 -r sha256sum) \
    || die "could not recompute the restored-tree manifest"

if ! diffout=$(printf '%s\n' "$current" | diff -u "$xc8_manifest" - 2>&1); then
    log "restored XC8/DFP cache does not match its recorded manifest:"
    printf '%s\n' "$diffout" >&2
    die "corrupted, incomplete, or tampered XC8/DFP cache (rejected before build/test)"
fi

log "XC8/DFP cache verified: $XC8_DIR + $XC8_DFP_ROOT match the recorded manifest (pinned $XC8_VERSION / $DFP_VERSION)."
