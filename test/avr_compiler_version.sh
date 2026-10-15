#!/usr/bin/env bash
#
# Pinned AVR compiler contract for the test aggregates under STRICT_TOOLS=1:
# the third prerequisite gate, after test/python_version.py and
# test/host_compiler_version.sh.
#
# avr-gcc 14.3.0, Ubuntu 26.04's own gcc-avr, is an image-defining pin.
# scripts/make-release.sh refuses to start a release with any other, and every
# AVR gate is qualified against it. Before this gate nothing in `make test`
# checked it, so a host with another avr-gcc met the pin as an
# unrelated-looking error well into the suite. When the pin was 7.3.0, Ubuntu
# 26.04's avr-gcc 14 made test-static-assert-guards report the UNMUTATED
# Classic shell as uncompilable, over a -Wsign-conversion inside avr-libc's
# set_sleep_mode(); nothing in that error pointed at the compiler.
#
# Policy. The Makefile passes three facts and this script decides:
#   - lenient (STRICT_TOOLS empty): nothing is enforced; exit 0 silently.
#   - CC from the command line (or `make -e`): the operator chose the compiler,
#     e.g. for T25-cross-compiler work. It is not enforced here, and the gate
#     says so in one line. A release still refuses it.
#   - otherwise CC is the Makefile's own default and must report exactly the
#     pin, matched as a whole token by the release's own matcher.

set -euo pipefail
# A bare `var=$(... grep ...)` that matches nothing takes this suite down with
# `set -e` and NO output: the failure has no diagnostic, and any guard on the
# next line never runs. Name the line instead of exiting mute. Deliberately no
# `set -E` -- without errtrace the trap is not inherited by the command
# substitution's subshell, so a failure is reported once rather than twice.
# This only reports; `set -e` still does the exiting, so control flow is unchanged.
# The `case $-` guard is required, not defensive: bash runs an ERR trap even
# inside a deliberate `set +e` block, and several suites use one around a
# command whose non-zero status IS the expected result (`make -q` returns 1).
# Without the guard those print a spurious FAIL that lands in retained
# release evidence, because test-long.summary.txt is built by grepping ^FAIL.
trap 'err_rc=$?; case $- in *e*) printf "FAIL: %s:%d exited %d with no diagnostic (a command substitution that matched nothing?)\n" "${BASH_SOURCE[0]}" "$LINENO" "$err_rc" >&2 ;; esac' ERR

# The release pin. test/test_release_preflight.sh holds it equal to the
# require_pinned_compiler line in scripts/make-release.sh.
AVR_GCC_PIN=14.3.0

usage() {
	echo "usage: avr_compiler_version.sh CC CC_ORIGIN strict|lenient" >&2
	exit 2
}

[ "$#" -eq 3 ] || usage
CC=$1 CC_ORIGIN=$2 MODE=$3
case "$MODE" in
	strict) ;;
	lenient) exit 0 ;;
	*) usage ;;
esac
# Every value $(origin) can return. Only an explicit selection is exempt;
# a value the Makefile or the environment supplied is held to the pin.
case "$CC_ORIGIN" in
	'command line'|'environment override')
		echo "avr-compiler-valid: CC=$CC was selected explicitly ($CC_ORIGIN);" \
		     "the avr-gcc $AVR_GCC_PIN pin is not enforced here (a release still refuses any other)."
		exit 0
		;;
	default|file|override|environment|automatic|undefined) ;;
	*) usage ;;
esac

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../scripts/release-provenance.sh
. "$ROOT/scripts/release-provenance.sh"

# scripts/fetch_avr_toolchain.sh installs the historic avr-gcc 7.3.0 here: it
# rebuilds v0.9.17 and earlier, and is T25's comparison compiler. Left first on
# PATH from that work, it shadows the pin, and the diagnostic says so by name.
HISTORIC_BIN="$ROOT/third_party/avr-toolchain/usr/bin"

refuse() {
	{
		echo "FAIL: STRICT_TOOLS=1 requires the release-pinned avr-gcc $AVR_GCC_PIN as CC; $1"
		echo "      Every AVR image, and every gate that compiles one, is qualified against exactly"
		echo "      avr-gcc $AVR_GCC_PIN, and scripts/make-release.sh refuses any other. It is Ubuntu"
		echo "      26.04's own AVR toolchain (TOOLCHAIN.adoc), and nothing earlier on PATH may"
		echo "      shadow it, so that avr-size and avr-objcopy come from it as well:"
		echo "        sudo apt install gcc-avr avr-libc binutils-avr"
		case "$resolved" in
			"$HISTORIC_BIN"/*)
				echo "      The CC that won is the historic avr-gcc 7.3.0 from"
				echo "      scripts/fetch_avr_toolchain.sh, which rebuilds v0.9.17 and earlier."
				echo "      Take $HISTORIC_BIN off PATH."
				;;
		esac
		echo "      To run the suite on another compiler deliberately, select it with CC= on the"
		echo "      command line; this gate then reports it and does not enforce the pin."
	} >&2
	exit 1
}

resolved=
if ! resolved=$(command -v -- "$CC"); then
	refuse "CC=$CC was not found."
fi
banner=$( { "$CC" --version 2>/dev/null || true; } | sed -n 1p)
[ -n "$banner" ] \
	|| refuse "CC=$CC ($resolved) printed no version banner."
release_pinned_version_matches "$banner" "$AVR_GCC_PIN" \
	|| refuse "CC=$CC resolves to $resolved, which reports:
        $banner"
exit 0
