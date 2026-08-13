#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PIC_INSTALL="$ROOT/scripts/install_pic_toolchain.sh"
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
		"$PIC_INSTALL"
}

run_pic_installer_without_pic12f675() {
	FAKE_OMIT_PIC12F675=1 run_pic_installer "$@"
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
