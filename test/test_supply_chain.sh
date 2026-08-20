#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PIC_INSTALL="$ROOT/scripts/install_pic_toolchain.sh"
PIC_VERIFY="$ROOT/scripts/verify_pic_toolchain_cache.sh"
ATTINY_FETCH="$ROOT/scripts/fetch_attiny_dfp.sh"
YASIMAVR_FETCH="$ROOT/scripts/fetch_yasimavr.sh"
YASIMAVR_LOCK="$ROOT/scripts/yasimavr-build-requirements.txt"
work=$(mktemp -d "${TMPDIR:-/tmp}/test-supply-chain.XXXXXX")
trap 'rm -rf "$work"' EXIT
checks=0

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

expect_fail() {
	local label=$1 expected=$2 output
	shift 2
	if output=$("$@" 2>&1); then
		fail "$label: invalid supply-chain input was accepted"
	fi
	[[ "$output" == *"$expected"* ]] \
		|| fail "$label: failed for the wrong reason: $output"
	checks=$((checks + 1))
}

sha_of() {
	printf '%s' "$1" | sha256sum | cut -d' ' -f1
}

# Drive the shared PIC installer entirely offline. No fake sudo call may occur
# until both downloads match their separately pinned digests.
fakebin="$work/pic-fakebin"
mkdir "$fakebin"
real_chmod=$(command -v chmod) || fail "chmod is required"
cat > "$fakebin/wget" <<'EOF'
#!/bin/sh
set -eu
url=
output=
while [ "$#" -gt 0 ]; do
	case "$1" in
		-q) ;;
		-O) shift; output=$1 ;;
		https://*) url=$1 ;;
	esac
	shift
done
[ -n "$url" ] && [ -n "$output" ] || exit 2
case "$url" in
	*xc8-v*) printf '%s' "$FAKE_XC8_PAYLOAD" > "$output" ;;
	*.atpack) printf '%s' "$FAKE_DFP_PAYLOAD" > "$output" ;;
	*) exit 3 ;;
esac
EOF
cat > "$fakebin/sudo" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$FAKE_SUDO_LOG"
case "$1" in
	*/xc8-v*.run)
		shift
		prefix=
		while [ "$#" -gt 0 ]; do
			if [ "$1" = --prefix ]; then shift; prefix=$1; fi
			shift
		done
		[ -n "$prefix" ] || exit 2
		mkdir -p "$prefix/bin"
		printf '#!/bin/sh\nexit 0\n' > "$prefix/bin/xc8-cc"
		chmod +x "$prefix/bin/xc8-cc"
		;;
	mkdir)
		shift
		exec mkdir "$@"
		;;
	unzip)
		shift
		destination=
		while [ "$#" -gt 0 ]; do
			if [ "$1" = -d ]; then shift; destination=$1; fi
			shift
		done
		[ -n "$destination" ] || exit 2
		mkdir -p "$destination/xc8/pic/include/proc"
		: > "$destination/xc8/pic/include/proc/pic10f322.h"
		: > "$destination/xc8/pic/include/proc/pic10f320.h"
		[ "${FAKE_OMIT_PIC12F675:-0}" = 1 ] \
			|| : > "$destination/xc8/pic/include/proc/pic12f675.h"
		;;
	*) exit 3 ;;
esac
EOF
cat > "$fakebin/chmod" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$FAKE_CHMOD_LOG"
exec "$REAL_CHMOD" "$@"
EOF
chmod +x "$fakebin/wget" "$fakebin/sudo" "$fakebin/chmod"

trusted_xc8='reviewed XC8 fixture bytes'
trusted_dfp='reviewed DFP fixture bytes'
trusted_xc8_sha=$(sha_of "$trusted_xc8")
trusted_dfp_sha=$(sha_of "$trusted_dfp")
sudo_log="$work/sudo.log"
chmod_log="$work/chmod.log"

run_pic_installer() {
	env PATH="$fakebin:$PATH" FAKE_SUDO_LOG="$sudo_log" \
		FAKE_CHMOD_LOG="$chmod_log" REAL_CHMOD="$real_chmod" \
		FAKE_XC8_PAYLOAD="$1" FAKE_DFP_PAYLOAD="$2" \
		XC8_INSTALLER_SHA256="$trusted_xc8_sha" \
		PIC_DFP_SHA256="$trusted_dfp_sha" \
		XC8_DIR="$work/xc8" XC8_DFP_ROOT="$work/pic-dfp" \
		XC8_CACHE_DIR="$work" \
		"$PIC_INSTALL"
}

run_pic_installer_without_pic12f675() {
	FAKE_OMIT_PIC12F675=1 run_pic_installer "$@"
}

run_pic_installer_via_cache_link() {
	env PATH="$fakebin:$PATH" FAKE_SUDO_LOG="$sudo_log" \
		FAKE_CHMOD_LOG="$chmod_log" REAL_CHMOD="$real_chmod" \
		FAKE_XC8_PAYLOAD="$1" FAKE_DFP_PAYLOAD="$2" \
		XC8_INSTALLER_SHA256="$trusted_xc8_sha" \
		PIC_DFP_SHA256="$trusted_dfp_sha" \
		XC8_DIR="$work/cache-link/xc8" XC8_DFP_ROOT="$work/cache-link/pic-dfp" \
		XC8_CACHE_DIR="$work/cache-link" \
		"$PIC_INSTALL"
}

rm -f "$sudo_log" "$chmod_log"
expect_fail "corrupt XC8 download" "XC8 SHA-256 mismatch" \
	run_pic_installer 'changed XC8 bytes' "$trusted_dfp"
[ ! -e "$sudo_log" ] || fail "corrupt XC8 bytes reached sudo"
[ ! -e "$chmod_log" ] || fail "corrupt XC8 bytes reached chmod"
checks=$((checks + 1))

rm -f "$sudo_log" "$chmod_log"
expect_fail "corrupt PIC DFP download" "DFP SHA-256 mismatch" \
	run_pic_installer "$trusted_xc8" 'changed DFP bytes'
[ ! -e "$sudo_log" ] || fail "corrupt DFP bytes reached sudo"
[ ! -e "$chmod_log" ] || fail "corrupt DFP bytes reached chmod"
checks=$((checks + 1))

ln -s . "$work/cache-link"
rm -f "$sudo_log" "$chmod_log"
expect_fail "symlinked PIC install cache root" "XC8 cache root is a symlink" \
	run_pic_installer_via_cache_link "$trusted_xc8" "$trusted_dfp"
[ ! -e "$sudo_log" ] || fail "symlinked PIC install cache root reached sudo"
rm "$work/cache-link"
checks=$((checks + 1))

rm -rf "$work/xc8" "$work/pic-dfp"
rm -f "$sudo_log" "$chmod_log"
expect_fail "PIC DFP missing PIC12F675 header" \
	"DFP installation did not create $work/pic-dfp/xc8/pic/include/proc/pic12f675.h" \
	run_pic_installer_without_pic12f675 "$trusted_xc8" "$trusted_dfp"
[ -f "$work/pic-dfp/xc8/pic/include/proc/pic10f322.h" ] \
	&& [ -f "$work/pic-dfp/xc8/pic/include/proc/pic10f320.h" ] \
	&& [ ! -e "$work/pic-dfp/xc8/pic/include/proc/pic12f675.h" ] \
	|| fail "missing-PIC12F675 fixture did not isolate that header"
checks=$((checks + 1))

rm -rf "$work/xc8" "$work/pic-dfp"
rm -f "$sudo_log" "$chmod_log"
run_pic_installer "$trusted_xc8" "$trusted_dfp" >/dev/null 2>&1 \
	|| fail "verified PIC toolchain fixture did not install"
[ -x "$work/xc8/bin/xc8-cc" ] \
	&& [ -f "$work/pic-dfp/xc8/pic/include/proc/pic10f322.h" ] \
	&& [ -f "$work/pic-dfp/xc8/pic/include/proc/pic10f320.h" ] \
	&& [ -f "$work/pic-dfp/xc8/pic/include/proc/pic12f675.h" ] \
	|| fail "verified PIC toolchain install was incomplete"
[ -s "$sudo_log" ] || fail "verified PIC fixture never reached installation"
checks=$((checks + 1))

# --- restored-cache integrity verification (verify_pic_toolchain_cache.sh) ----
# install_pic_toolchain.sh froze a stamp + manifest of the just-installed tree.
# CI restores that tree WITHOUT re-running the SHA-verified installer, so a
# read-only verify must reject a corrupted, incomplete, or symlinked restore
# before any build/test consumes it.
[ -f "$work/.xc8_toolchain.stamp" ] && [ -f "$work/.xc8_toolchain.manifest" ] \
	|| fail "install did not record the XC8/DFP integrity stamp + manifest"
checks=$((checks + 1))

run_pic_verify() {
	env XC8_DIR="$work/xc8" XC8_DFP_ROOT="$work/pic-dfp" XC8_CACHE_DIR="$work" \
		XC8_INSTALLER_SHA256="$trusted_xc8_sha" PIC_DFP_SHA256="$trusted_dfp_sha" \
		"$PIC_VERIFY"
}
run_pic_verify_via_cache_link() {
	env XC8_DIR="$work/cache-link/xc8" XC8_DFP_ROOT="$work/cache-link/pic-dfp" \
		XC8_CACHE_DIR="$work/cache-link" \
		XC8_INSTALLER_SHA256="$trusted_xc8_sha" PIC_DFP_SHA256="$trusted_dfp_sha" \
		"$PIC_VERIFY"
}
reinstall_pic() {
	rm -rf "$work/xc8" "$work/pic-dfp" \
		"$work/.xc8_toolchain.stamp" "$work/.xc8_toolchain.manifest"
	run_pic_installer "$trusted_xc8" "$trusted_dfp" >/dev/null 2>&1 \
		|| fail "clean PIC reinstall failed"
}

# A clean, freshly-recorded cache verifies.
verify_out=$(run_pic_verify 2>&1) \
	|| fail "verified XC8/DFP cache was rejected: $verify_out"
[[ "$verify_out" == *"cache verified"* ]] \
	|| fail "XC8/DFP verify did not confirm the manifest match: $verify_out"
checks=$((checks + 1))

# A corrupted file (same name, different bytes) is caught by the manifest diff.
printf 'corrupted compiler bytes\n' > "$work/xc8/bin/xc8-cc"
expect_fail "corrupt XC8 cache file" "corrupted, incomplete, or tampered" run_pic_verify

# An unexpected extra file under a root is rejected (no manifest line for it).
reinstall_pic
printf 'unexpected input\n' > "$work/pic-dfp/xc8/pic/include/proc/extra.h"
expect_fail "extra XC8 cache file" "corrupted, incomplete, or tampered" run_pic_verify

# A missing critical device header is an incomplete restore.
reinstall_pic
rm -f "$work/pic-dfp/xc8/pic/include/proc/pic12f675.h"
expect_fail "incomplete XC8 cache" "missing device header" run_pic_verify

# A symlinked component root is refused outright.
reinstall_pic
mv "$work/xc8" "$work/xc8.real"
ln -s "$work/xc8.real" "$work/xc8"
expect_fail "symlinked XC8 root" "root is a symlink" run_pic_verify
rm -rf "$work/xc8" "$work/xc8.real"

# The cache boundary itself is part of the trust contract, not just its final
# component roots. Accessing an otherwise valid tree through a root symlink must
# fail before stamp or manifest validation.
reinstall_pic
ln -s . "$work/cache-link"
expect_fail "symlinked XC8 cache root" "cache root is a symlink" \
	run_pic_verify_via_cache_link
rm "$work/cache-link"

# A stamp that does not name the pinned (compiler, DFP) pair is rejected.
reinstall_pic
printf '9.99 0.0.0 %s %s\n' "$trusted_xc8_sha" "$trusted_dfp_sha" \
	> "$work/.xc8_toolchain.stamp"
expect_fail "wrong XC8 cache stamp" "does not match the pinned toolchain" run_pic_verify

# A missing manifest (incomplete restore) is rejected.
reinstall_pic
rm -f "$work/.xc8_toolchain.manifest"
expect_fail "missing XC8 manifest" "missing integrity manifest" run_pic_verify

# Leave a clean, verifiable cache behind.
reinstall_pic

grep -Fq '628803b96f468a5981d6bc1d0a5e6c7fa809e4d87e3cca961805e2a857f5846e' \
	"$PIC_INSTALL" || fail "reviewed XC8 digest is missing"
grep -Fq 'add68db8b76705557a99647bde5b149d17caf259d968f5946058356275eed75b' \
	"$PIC_INSTALL" || fail "official PIC DFP digest is missing"
checks=$((checks + 1))

# A matching ATtiny_DFP stamp is insufficient: every extracted file must still
# match its reviewed content hash before the cache is accepted.
attiny_dest="$work/attiny-dfp"
attiny_files=(
	gcc/dev/attiny202/device-specs/specs-attiny202
	gcc/dev/attiny202/avrxmega3/short-calls/crtattiny202.o
	gcc/dev/attiny202/avrxmega3/short-calls/libattiny202.a
	include/avr/iotn202.h
)
attiny_hashes=
for index in "${!attiny_files[@]}"; do
	path=${attiny_files[$index]}
	mkdir -p "$attiny_dest/$(dirname "$path")"
	printf 'fixture %s\n' "$index" > "$attiny_dest/$path"
	digest=$(sha256sum "$attiny_dest/$path" | cut -d' ' -f1)
	attiny_hashes+="$digest  $path"$'\n'
done
pack_sha=0000000000000000000000000000000000000000000000000000000000000000
printf 'fixture-version %s\n' "$pack_sha" > "$attiny_dest/.attiny_dfp.stamp"
output=$(ATTINY_DFP_VER=fixture-version ATTINY_DFP_SHA256="$pack_sha" \
	ATTINY_DFP_FILE_HASHES="$attiny_hashes" \
	"$ATTINY_FETCH" "$attiny_dest" 2>&1) \
	|| fail "valid synthetic ATtiny_DFP cache was rejected: $output"
[[ "$output" == *"verified stamp + file hashes"* ]] \
	|| fail "valid ATtiny_DFP cache did not take the verified cache path"
checks=$((checks + 1))

attiny_fakebin="$work/attiny-fakebin"
mkdir "$attiny_fakebin"
cat > "$attiny_fakebin/curl" <<'EOF'
#!/bin/sh
printf 'download attempted\n' >> "$ATTINY_DOWNLOAD_LOG"
exit 19
EOF
chmod +x "$attiny_fakebin/curl"
printf 'corrupted cache bytes\n' > "$attiny_dest/${attiny_files[0]}"
download_log="$work/attiny-download.log"
expect_fail "corrupt ATtiny_DFP cache" "download failed" \
	env PATH="$attiny_fakebin:$PATH" ATTINY_DOWNLOAD_LOG="$download_log" \
		ATTINY_DFP_VER=fixture-version ATTINY_DFP_SHA256="$pack_sha" \
		ATTINY_DFP_FILE_HASHES="$attiny_hashes" \
		"$ATTINY_FETCH" "$attiny_dest"
[ "$(<"$download_log")" = 'download attempted' ] \
	|| fail "corrupt ATtiny_DFP cache was accepted without refetching"
checks=$((checks + 1))

printf 'fixture 0\n' > "$attiny_dest/${attiny_files[0]}"
mkdir -p "$attiny_dest/include/avr"
printf 'unexpected compiler input\n' > "$attiny_dest/include/avr/io.h"
rm -f "$download_log"
expect_fail "extra ATtiny_DFP cache file" "download failed" \
	env PATH="$attiny_fakebin:$PATH" ATTINY_DOWNLOAD_LOG="$download_log" \
		ATTINY_DFP_VER=fixture-version ATTINY_DFP_SHA256="$pack_sha" \
		ATTINY_DFP_FILE_HASHES="$attiny_hashes" \
		"$ATTINY_FETCH" "$attiny_dest"
[ "$(<"$download_log")" = 'download attempted' ] \
	|| fail "extra ATtiny_DFP compiler input was accepted from cache"
checks=$((checks + 1))

rm -rf "$attiny_dest/include"
external_include="$work/external-attiny-include"
mkdir -p "$external_include/avr"
printf 'fixture 3\n' > "$external_include/avr/iotn202.h"
printf 'unexpected compiler input\n' > "$external_include/avr/io.h"
ln -s "$external_include" "$attiny_dest/include"
rm -f "$download_log"
expect_fail "symlinked ATtiny_DFP cache directory" "download failed" \
	env PATH="$attiny_fakebin:$PATH" ATTINY_DOWNLOAD_LOG="$download_log" \
		ATTINY_DFP_VER=fixture-version ATTINY_DFP_SHA256="$pack_sha" \
		ATTINY_DFP_FILE_HASHES="$attiny_hashes" \
		"$ATTINY_FETCH" "$attiny_dest"
[ "$(<"$download_log")" = 'download attempted' ] \
	|| fail "symlinked ATtiny_DFP compiler-input directory was accepted"
checks=$((checks + 1))

rm "$attiny_dest/include"
mkdir -p "$attiny_dest/include/avr"
printf 'fixture 3\n' > "$attiny_dest/include/avr/iotn202.h"
stamp_target="$work/stamp-target"
printf 'must not be overwritten\n' > "$stamp_target"
rm "$attiny_dest/.attiny_dfp.stamp"
ln -s "$stamp_target" "$attiny_dest/.attiny_dfp.stamp"
expect_fail "symlinked ATtiny_DFP stamp" "refusing to replace symlinked stamp" \
	env ATTINY_DFP_VER=fixture-version ATTINY_DFP_SHA256="$pack_sha" \
		ATTINY_DFP_FILE_HASHES="$attiny_hashes" \
		"$ATTINY_FETCH" "$attiny_dest"
[ "$(<"$stamp_target")" = 'must not be overwritten' ] \
	|| fail "symlinked ATtiny_DFP stamp target was overwritten"
checks=$((checks + 1))

attiny_success_bin="$work/attiny-success-bin"
mkdir "$attiny_success_bin"
cat > "$attiny_success_bin/curl" <<'EOF'
#!/bin/sh
set -eu
output=
while [ "$#" -gt 0 ]; do
	if [ "$1" = -o ]; then shift; output=$1; fi
	shift
done
[ -n "$output" ] || exit 2
printf '%s' "$ATTINY_PACK_PAYLOAD" > "$output"
EOF
cat > "$attiny_success_bin/unzip" <<'EOF'
#!/bin/sh
# The synthetic cache already contains the exact extracted fixture bytes.
exit 0
EOF
chmod +x "$attiny_success_bin/curl" "$attiny_success_bin/unzip"
rm "$attiny_dest/.attiny_dfp.stamp"
hardlink_target="$work/hardlink-stamp-target"
printf 'must remain old stamp bytes\n' > "$hardlink_target"
ln "$hardlink_target" "$attiny_dest/.attiny_dfp.stamp"
pack_payload='trusted synthetic atpack'
fresh_pack_sha=$(sha_of "$pack_payload")
env PATH="$attiny_success_bin:$PATH" ATTINY_PACK_PAYLOAD="$pack_payload" \
	ATTINY_DFP_VER=fresh-version ATTINY_DFP_SHA256="$fresh_pack_sha" \
	ATTINY_DFP_FILE_HASHES="$attiny_hashes" \
	"$ATTINY_FETCH" "$attiny_dest" >/dev/null 2>&1 \
	|| fail "synthetic ATtiny_DFP refetch with a hard-linked stamp failed"
[ "$(<"$hardlink_target")" = 'must remain old stamp bytes' ] \
	|| fail "atomic stamp update overwrote an external hard-link target"
[ "$(<"$attiny_dest/.attiny_dfp.stamp")" = "fresh-version $fresh_pack_sha" ] \
	|| fail "atomic stamp update did not install the new stamp"
[ ! "$hardlink_target" -ef "$attiny_dest/.attiny_dfp.stamp" ] \
	|| fail "new ATtiny_DFP stamp still shares the old hard-linked inode"
checks=$((checks + 1))

# The simulator build has one hash lock in every cache key, no get-pip bootstrap,
# and no isolated/dependency-resolving source build.
[ -s "$YASIMAVR_LOCK" ] || fail "yasimavr requirements lock is missing"
for requirement in packaging PyYAML pyvcd setuptools sip tomli wheel; do
	grep -Eiq "^${requirement}==[^[:space:]]+.*|^${requirement}==" "$YASIMAVR_LOCK" \
		|| fail "yasimavr requirements lock is missing $requirement"
done
grep -Fq -- '--require-hashes --only-binary=:all:' "$YASIMAVR_FETCH" \
	|| fail "yasimavr dependency install is not hash-enforced binary-only"
grep -Fq -- '--no-index --no-build-isolation --no-deps' "$YASIMAVR_FETCH" \
	|| fail "yasimavr source build can still resolve external dependencies"
! grep -Fq 'get-pip.py' "$YASIMAVR_FETCH" \
	|| fail "yasimavr fetcher still uses get-pip.py"
checks=$((checks + 1))

printf 'supply-chain validation: %d checks, 0 failures\n' "$checks"
