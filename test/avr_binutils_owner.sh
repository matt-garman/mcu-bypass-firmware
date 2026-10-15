#!/usr/bin/env bash
#
# AVR binutils contract: a default OBJCOPY or OBJDUMP must be the selected
# avr-gcc's own program. Two callers hold to it: the avr-binutils-valid gate,
# fourth in each test aggregate under STRICT_TOOLS=1, and
# scripts/make-release.sh at preflight.
#
# Both defaults are bare names (avr-objcopy, avr-objdump), so PATH picks them,
# and a directory ahead of the compiler's can supply another toolchain's. XC8's
# bin directory carries Microchip's binutils 2.26 pair: the manifests of v0.9.10
# to v0.9.16 record its avr-objcopy, beside an Ubuntu avr-gcc, as the program
# that wrote their .hex files, and its avr-objdump fed the ATtiny202 delay
# oracle. The images are qualified with the binutils the compiler assembles and
# links with, and the compiler names its own: `CC -print-prog-name=objcopy`
# (on Ubuntu /usr/lib/avr/bin/objcopy, which /usr/bin/avr-objcopy links to).
# A default is accepted only when it is that program: the same file, or the
# same bytes for a toolchain that installs the prefixed name as a copy.
#
# Policy. The caller passes the facts and this script decides:
#   - lenient (STRICT_TOOLS empty): nothing is enforced; exit 0 silently.
#   - NAME from the command line (or `make -e`): the operator chose it. It is
#     reported in one line and not enforced; a release records it.
#   - otherwise NAME must resolve to CC's own program.
#
# usage: avr_binutils_owner.sh strict|lenient CC NAME VALUE ORIGIN [NAME VALUE ORIGIN]...
#   NAME    OBJCOPY or OBJDUMP
#   VALUE   the program the Makefile selects for NAME
#   ORIGIN  $(origin NAME)
# Exit: 0 accepted, 1 refused, 2 bad invocation.

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

usage() {
	echo "usage: avr_binutils_owner.sh strict|lenient CC NAME VALUE ORIGIN [NAME VALUE ORIGIN]..." >&2
	exit 2
}

[ "$#" -ge 5 ] && [ $((($# - 2) % 3)) -eq 0 ] || usage
MODE=$1 CC=$2
shift 2
case "$MODE" in
	strict|lenient) ;;
	*) usage ;;
esac
[ -n "$CC" ] || usage
# Every triple is checked before anything is decided, so a malformed call is
# refused the same way in both modes.
args=("$@")
for ((i = 0; i < ${#args[@]}; i += 3)); do
	case "${args[i]}" in
		OBJCOPY|OBJDUMP) ;;
		*) usage ;;
	esac
	# Every value $(origin) can return.
	case "${args[i + 2]}" in
		'command line'|'environment override'|default|file|override|environment|automatic|undefined) ;;
		*) usage ;;
	esac
done
[ "$MODE" = strict ] || exit 0

banner() {
	local line
	line=$( { "$1" --version 2>/dev/null || true; } | sed -n 1p)
	printf '%s\n' "${line:-(no version banner)}"
}

# refuse REASON [DETAIL]: report the current NAME=VALUE (the loop's globals).
refuse() {
	{
		echo "FAIL: $name=$value is not $CC's own $prog; $1"
		echo "      The AVR images, their .hex files and the evidence read back out of them are"
		echo "      qualified with the binutils the compiler itself assembles and links with."
		case "$value" in
			*/*) ;;
			*)
				echo "      $name=$value is a bare name, so PATH chooses it, and an earlier PATH"
				echo "      entry can supply another toolchain's."
				;;
		esac
		[ -z "${2-}" ] || printf '%s\n' "$2"
	} >&2
	return 1
}

# check: refuse the current NAME=VALUE unless it is CC's own PROG.
check() {
	local cc_path own own_real resolved resolved_real cand detail fix
	cc_path=$(command -v -- "$CC") \
		|| { refuse "CC=$CC was not found, so its own $prog cannot be named."; return 1; }
	own=$("$CC" -print-prog-name="$prog" 2>/dev/null) || own=
	case "$own" in
		/*) ;;
		*)
			refuse "CC=$CC ($cc_path) names no $prog of its own (-print-prog-name=$prog printed '$own')."
			return 1
			;;
	esac
	[ -f "$own" ] && [ -x "$own" ] \
		|| { refuse "CC=$CC names $own as its $prog, and that is not an executable file."; return 1; }
	own_real=$(realpath -e -- "$own") \
		|| { refuse "cannot resolve CC's $prog, $own."; return 1; }
	[ -n "$value" ] \
		|| { refuse "it is empty." "      Select $name=$own_real on the command line."; return 1; }
	resolved=$(command -v -- "$value") \
		|| { refuse "it was not found." "      Install binutils-avr beside the compiler, or select $name=$own_real on the command line."; return 1; }
	if [ "$resolved" -ef "$own" ] || cmp -s -- "$resolved" "$own"; then
		return 0
	fi
	resolved_real=$(realpath -e -- "$resolved" 2>/dev/null) || resolved_real=$resolved
	detail="      $name resolves to $resolved_real:
        $(banner "$resolved")
      $CC's own $prog is $own_real (-print-prog-name=$prog):
        $(banner "$own")"
	# The usual repair is the PATH order. Name it when the compiler's own
	# directory holds this very name and it is the compiler's program.
	fix="      Select $name=$own_real on the command line."
	case "$value" in
		*/*) ;;
		*)
			cand="${cc_path%/*}/$value"
			if [ -x "$cand" ] && { [ "$cand" -ef "$own" ] || cmp -s -- "$cand" "$own"; }; then
				fix="      Put ${cc_path%/*} ahead of ${resolved%/*} on PATH, or select
      $name=$cand on the command line."
			fi
			;;
	esac
	if [ -x "${resolved%/*}/xc8-cc" ]; then
		fix="$fix
      ${resolved%/*} is XC8's: the Makefile reaches XC8 through
      PIC_CC's absolute path, so XC8 needs no PATH entry for this repository."
	fi
	refuse "the two are different programs." "$detail
$fix"
}

refused=0
for ((i = 0; i < ${#args[@]}; i += 3)); do
	name=${args[i]} value=${args[i + 1]} origin=${args[i + 2]}
	prog=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
	case "$origin" in
		'command line'|'environment override')
			echo "AVR binutils: $name=$value was selected explicitly ($origin);" \
			     "it is not held to $CC's own $prog here."
			continue
			;;
	esac
	check || refused=1
done
exit "$refused"
