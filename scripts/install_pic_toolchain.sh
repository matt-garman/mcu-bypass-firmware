#!/bin/sh
# Install the release-pinned XC8 compiler and PIC10-12Fxxx device pack after
# verifying both downloads. The proprietary compiler runs as root only after
# its bytes and the DFP bytes match the reviewed SHA-256 values below.

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

[ "$#" -eq 0 ] || die "usage: scripts/install_pic_toolchain.sh"

XC8_VERSION=${XC8_VERSION:-3.10}
DFP_VERSION=${DFP_VERSION:-1.9.189}
XC8_DIR=${XC8_DIR:-/opt/microchip/xc8/v3.10}
XC8_DFP_ROOT=${XC8_DFP_ROOT:-/opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189}
XC8_CACHE_DIR=${XC8_CACHE_DIR:-/opt/microchip}

# Reject a pre-existing redirected cache boundary before privileged installation.
[ ! -L "$XC8_CACHE_DIR" ] || die "XC8 cache root is a symlink: $XC8_CACHE_DIR"
if [ -e "$XC8_CACHE_DIR" ]; then
    [ -d "$XC8_CACHE_DIR" ] || die "XC8 cache root is not a directory: $XC8_CACHE_DIR"
fi

# XC8 has no published SHA-256 sidecar; this digest was reviewed from two
# independent byte-identical HTTPS downloads. The DFP digest is published by
# Microchip in both the .atpack.sha256 sidecar and x-amz-meta-sha256 metadata.
XC8_INSTALLER_SHA256=${XC8_INSTALLER_SHA256:-628803b96f468a5981d6bc1d0a5e6c7fa809e4d87e3cca961805e2a857f5846e}
PIC_DFP_SHA256=${PIC_DFP_SHA256:-add68db8b76705557a99647bde5b149d17caf259d968f5946058356275eed75b}

is_sha256 "$XC8_INSTALLER_SHA256" || die "invalid XC8_INSTALLER_SHA256"
is_sha256 "$PIC_DFP_SHA256" || die "invalid PIC_DFP_SHA256"
for tool in wget sha256sum sudo unzip find sort xargs mktemp; do
    have "$tool" || die "$tool not found"
done

xc8_name="xc8-v${XC8_VERSION}-full-install-linux-x64-installer.run"
xc8_base="https://ww1.microchip.com/downloads/aemDocuments/documents"
xc8_url="${xc8_base}/DEV/ProductDocuments/SoftwareTools/${xc8_name}"
dfp_name="Microchip.PIC10-12Fxxx_DFP.${DFP_VERSION}.atpack"
dfp_url="https://packs.download.microchip.com/${dfp_name}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/install-pic-toolchain.XXXXXX") \
    || die "could not create temporary directory"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
xc8_installer="$tmp/$xc8_name"
dfp_pack="$tmp/$dfp_name"

log "Downloading XC8 ${XC8_VERSION}"
wget -q "$xc8_url" -O "$xc8_installer" || die "download failed: $xc8_url"
log "Downloading PIC10-12Fxxx_DFP ${DFP_VERSION}"
wget -q "$dfp_url" -O "$dfp_pack" || die "download failed: $dfp_url"

xc8_got=$(sha256sum "$xc8_installer" | cut -d' ' -f1)
[ "$xc8_got" = "$XC8_INSTALLER_SHA256" ] || die "XC8 SHA-256 mismatch.
  expected: $XC8_INSTALLER_SHA256
  got:      $xc8_got
  Refusing to execute the downloaded installer."
dfp_got=$(sha256sum "$dfp_pack" | cut -d' ' -f1)
[ "$dfp_got" = "$PIC_DFP_SHA256" ] || die "DFP SHA-256 mismatch.
  expected: $PIC_DFP_SHA256
  got:      $dfp_got
  Refusing to extract the downloaded pack."
log "XC8 and DFP SHA-256 verification passed"

chmod 700 "$xc8_installer"
sudo "$xc8_installer" --mode unattended --unattendedmodeui none \
    --netservername '' --LicenseType FreeMode --prefix "$XC8_DIR"
sudo mkdir -p "$XC8_DFP_ROOT"
sudo unzip -q -o "$dfp_pack" -d "$XC8_DFP_ROOT"

xc8="$XC8_DIR/bin/xc8-cc"
[ -x "$xc8" ] || die "XC8 installation did not create $xc8"
for device in pic10f322 pic10f320 pic12f675; do
    header="$XC8_DFP_ROOT/xc8/pic/include/proc/${device}.h"
    [ -f "$header" ] || die "DFP installation did not create $header"
done

# ---------------------------------------------------------------------------
# Freeze a restore-time integrity manifest for the just-installed tree.
#
# CI caches this extracted tree and a later job restores it WITHOUT re-running
# this SHA-verified installer. Record the digest-verified state now so
# verify_pic_toolchain_cache.sh can reject a corrupted or incomplete RESTORED
# cache before any build or test consumes it.
# ---------------------------------------------------------------------------
xc8_stamp="$XC8_CACHE_DIR/.xc8_toolchain.stamp"
xc8_manifest="$XC8_CACHE_DIR/.xc8_toolchain.manifest"

[ -e "$XC8_CACHE_DIR" ] || die "XC8 installation did not create $XC8_CACHE_DIR"
[ ! -L "$XC8_CACHE_DIR" ] || die "XC8 cache root became a symlink: $XC8_CACHE_DIR"
[ -d "$XC8_CACHE_DIR" ] || die "XC8 cache root is not a directory: $XC8_CACHE_DIR"
cache_real=$(CDPATH= cd -- "$XC8_CACHE_DIR" && pwd -P) \
    || die "could not resolve XC8 cache root: $XC8_CACHE_DIR"
for root in "$XC8_DIR" "$XC8_DFP_ROOT"; do
    [ ! -L "$root" ] || die "installed component root is a symlink: $root"
    root_real=$(CDPATH= cd -- "$root" && pwd -P) \
        || die "could not resolve installed component root: $root"
    case "$root_real" in
        "$cache_real"/*) ;;
        *) die "installed component escapes $XC8_CACHE_DIR: $root" ;;
    esac
done

# The walk is scoped to READABLE files and prunes unreadable directories. The
# XC8 installer leaves a few root-only bookkeeping files (Uninstall-*.dat,
# rollbackBackupDirectory) that this script -- run as the non-root CI user after
# sudo-installing -- cannot read. Those are never build inputs: the build runs as
# the same user, so every file it can actually consume IS readable and IS
# captured here. Permissions are preserved across the CI cache save/restore, so
# verify_ sees the identical readable set. A regular file that is unreadable is
# excluded (it cannot be a build input); a symlink among the readable tree is
# refused outright.
syms=$(find "$XC8_CACHE_DIR" \
        \( -type d ! -readable -prune \) -o \( -type l -print \)) \
    || die "could not scan the installed tree for symlinks"
[ -z "$syms" ] || die "refusing to record a manifest for a tree with symlinks:
$syms"

# Deterministic (LC_ALL=C) digest of every readable regular file under both
# roots. The stamp and manifest sit at XC8_CACHE_DIR level -- above both roots --
# so they never appear in this walk. verify_ regenerates this identically.
#
# The walk, the ordering and the hashing are three SEPARATELY status-checked
# stages, not one pipeline: /bin/sh reports a pipeline's status as its LAST
# stage's, so a find that dies partway through -- followed by a sort and a
# sha256sum that both succeed over what it had already emitted -- would freeze a
# silently partial manifest. That is the dangerous direction: a partial record
# is not caught at restore time if the same condition makes verify_'s walk fail
# the same way, and the two partial walks then agree. NUL delimiting is carried
# through every stage, so paths containing spaces, quotes, backslashes,
# newlines or any other non-NUL byte are inventoried unchanged.
scan="$tmp/manifest.scan"
ordered="$tmp/manifest.ordered"
manifest_body="$tmp/manifest.body"
find "$XC8_DIR" "$XC8_DFP_ROOT" \
        \( -type d ! -readable -prune \) -o \( -type f -readable -print0 \) \
    > "$scan" || die "could not scan the installed tree for manifest inputs"
LC_ALL=C sort -z < "$scan" > "$ordered" \
    || die "could not order the installed-tree manifest inputs"
xargs -0 -r sha256sum < "$ordered" > "$manifest_body" \
    || die "could not hash the installed-tree manifest inputs"
# An empty manifest matches an empty tree, so it can never be a valid record of
# an installation that just passed its critical-file checks above.
[ -s "$manifest_body" ] || die "refusing to record an empty XC8/DFP cache manifest"

write_cache_file() {  # usage: write_cache_file TARGET < CONTENT
    _dir=$(dirname "$1")
    if [ -w "$_dir" ]; then cat > "$1"; else sudo tee "$1" >/dev/null; fi
}
printf '%s %s %s %s\n' "$XC8_VERSION" "$DFP_VERSION" \
    "$XC8_INSTALLER_SHA256" "$PIC_DFP_SHA256" | write_cache_file "$xc8_stamp" \
    || die "could not record the XC8/DFP cache stamp: $xc8_stamp"
write_cache_file "$xc8_manifest" < "$manifest_body" \
    || die "could not record the XC8/DFP cache manifest: $xc8_manifest"

log "Installed verified XC8 ${XC8_VERSION} and PIC DFP ${DFP_VERSION}"
log "Recorded XC8/DFP cache integrity manifest ($xc8_manifest)"
