#!/usr/bin/env bash
set -euo pipefail
LC_ALL=C

usage() {
	printf 'usage: %s [--github-actions] --pic-cc CMD --pic-dfp DIR --pic10f320-cc CMD --pic10f320-dfp DIR --gpsim CMD --cppcheck CMD --pic-cxx CMD --pic-gpsim-inc DIR --pic10f320-cxx CMD --pic10f320-gpsim-inc DIR\n' "$0" >&2
	exit 2
}

github_actions=0
declare -A values=()
declare -A seen=()

while [[ $# -gt 0 ]]; do
	case $1 in
		--github-actions)
			[[ -z ${seen[$1]:-} ]] || { printf 'duplicate option: %s\n' "$1" >&2; exit 2; }
			seen[$1]=1
			github_actions=1
			shift
			;;
		--pic-cc|--pic-dfp|--pic10f320-cc|--pic10f320-dfp|--gpsim|--cppcheck|\
		--pic-cxx|--pic-gpsim-inc|--pic10f320-cxx|--pic10f320-gpsim-inc)
			option=$1
			[[ -z ${seen[$option]:-} ]] \
				|| { printf 'duplicate option: %s\n' "$option" >&2; exit 2; }
			[[ $# -ge 2 && -n $2 ]] || usage
			seen[$option]=1
			values[$option]=$2
			shift 2
			;;
		*) usage ;;
	esac
done

required=(
	--pic-cc --pic-dfp --pic10f320-cc --pic10f320-dfp --gpsim --cppcheck
	--pic-cxx --pic-gpsim-inc --pic10f320-cxx --pic10f320-gpsim-inc
)
for option in "${required[@]}"; do
	[[ -n ${seen[$option]:-} ]] || usage
done

errors=()

command_available() {
	local command_name=$1
	if [[ $command_name == */* ]]; then
		[[ -x $command_name && ! -d $command_name ]]
	else
		command -v -- "$command_name" >/dev/null 2>&1
	fi
}

require_command() {
	local label=$1 command_name=$2
	command_available "$command_name" \
		|| errors+=("$label command is missing or not executable: $command_name")
}

require_file() {
	local label=$1 path=$2
	[[ -f $path && ! -L $path && -s $path ]] \
		|| errors+=("$label is missing, empty, symlinked, or not a regular file: $path")
}

require_command "XC8 for PIC10F322/PIC12F675" "${values[--pic-cc]}"
require_file "PIC10F322 DFP header" \
	"${values[--pic-dfp]}/pic/include/proc/pic10f322.h"
require_file "PIC12F675 DFP header" \
	"${values[--pic-dfp]}/pic/include/proc/pic12f675.h"
require_command "XC8 for PIC10F320" "${values[--pic10f320-cc]}"
require_file "PIC10F320 DFP header" \
	"${values[--pic10f320-dfp]}/pic/include/proc/pic10f320.h"
require_command "gpsim" "${values[--gpsim]}"
require_command "cppcheck" "${values[--cppcheck]}"
require_command "PIC10F322/PIC12F675 C++" "${values[--pic-cxx]}"
require_file "PIC10F322/PIC12F675 libgpsim header" \
	"${values[--pic-gpsim-inc]}/sim_context.h"
require_command "PIC10F320 C++" "${values[--pic10f320-cxx]}"
require_file "PIC10F320 libgpsim header" \
	"${values[--pic10f320-gpsim-inc]}/sim_context.h"
require_command "pkg-config" pkg-config
if command_available pkg-config \
		&& ! pkg-config --exists glib-2.0 2>/dev/null; then
	errors+=("glib-2.0 development metadata is unavailable through pkg-config")
fi

if [[ ${#errors[@]} -gt 0 ]]; then
	for error in "${errors[@]}"; do
		if [[ $github_actions -eq 1 ]]; then
			printf '::error::%s\n' "$error" >&2
		else
			printf 'PIC toolchain: %s\n' "$error" >&2
		fi
	done
	exit 1
fi

printf 'PIC toolchain present: XC8/DFP, gpsim, libgpsim/GLib, cppcheck, and C++\n'
