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

# XC8 has no published SHA-256 sidecar; this digest was reviewed from two
# independent byte-identical HTTPS downloads. The DFP digest is published by
# Microchip in both the .atpack.sha256 sidecar and x-amz-meta-sha256 metadata.
XC8_INSTALLER_SHA256=${XC8_INSTALLER_SHA256:-628803b96f468a5981d6bc1d0a5e6c7fa809e4d87e3cca961805e2a857f5846e}
PIC_DFP_SHA256=${PIC_DFP_SHA256:-add68db8b76705557a99647bde5b149d17caf259d968f5946058356275eed75b}

is_sha256 "$XC8_INSTALLER_SHA256" || die "invalid XC8_INSTALLER_SHA256"
is_sha256 "$PIC_DFP_SHA256" || die "invalid PIC_DFP_SHA256"
for tool in wget sha256sum sudo unzip; do
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
log "Installed verified XC8 ${XC8_VERSION} and PIC DFP ${DFP_VERSION}"
