#!/usr/bin/env bash
set -euo pipefail

# Hardware return-stack depth gate for the PIC targets.
#
# WHAT IT BOUNDS, AND WHY IT IS NOT THE AVR GATE
# ----------------------------------------------
# test-stack-bound uses -fstack-usage to bound the AVR's DATA stack in bytes.
# The PIC14 core has no data stack at all -- XC8 allocates locals into a static,
# non-reentrant compiled-stack overlay, which is why that gate has nothing to
# measure here. All three supported PIC targets have a fixed-size HARDWARE RETURN
# STACK. This gate was introduced when PIC10F320 made that previously unobserved
# bound release-critical and now measures every PIC target's generated assembly.
#
# Depth is 8 levels. That is read from the device pack rather than written down
# here, because a hardcoded budget silently goes stale if a chip is re-pinned --
# the same failure §5.6 of the merge plan calls out for PIC10F322_FLASH_WORDS.
# All three parts declare it identically and independently:
#     <DFP>/xc8/pic/dat/ini/{10f320,10f322,12f675}.ini   STACKDEPTH=8
#     <DFP>/edc/{PIC10F320,PIC10F322,PIC12F675}.PIC      edc:hwstackdepth="8"
# Overflow on these cores is silent: the stack wraps and the return address is
# lost, so a program returns to the wrong place. These parts expose no STKPTR,
# TOSL/TOSH, STKOVF/STKUNF bit, stack-overflow reset, or CONFIG STVREN bit.
# Nothing at runtime can detect this. It has to be
# bounded statically, which is what this script does.
#
# WHY IT DOES NOT JUST READ XC8's NUMBER
# --------------------------------------
# XC8 does its own analysis and prints, per function,
#     ;; Hardware stack levels required when called: N
# It is not a safe upper bound. Measured on the shipping tq2_l2_5v_relay image, XC8
# reports 3 for _main while the emitted instruction stream contains a genuine
# 4-deep chain:
#     _main -> _init -> _hw_set_bypass_state -> _set_relay_coils_low
#           -> _hw_relay_reset_pin_set_low
# Every edge is a real `fcall` (no tail-call folding), each verified by its
# enclosing psect. XC8's own `callstack` directives agree with 4, not with 3.
# The prose annotation is therefore deliberately NOT used as the measurement;
# synthetic call chains reproduce it correctly, so this is a property of the
# real program rather than of the annotation format in general -- which is
# exactly the situation where a re-derivation earns its keep.
#
# XC8 does detect true overflow -- "(1393) possible hardware stack overflow
# detected" -- but only as a WARNING, and it still exits 0 and emits a HEX. A
# build that overflows the stack currently ships. That is the fail-open this
# gate closes.
#
# THE TWO ORACLES
# ---------------
#   1. PRIMARY -- the longest call chain in the emitted instruction stream,
#      computed here from the `fcall`/`call` edges. Hand-verifiable, and it
#      keeps working when the call graph does not fit (see 2).
#   2. CORROBORATION -- XC8 emits `callstack N` directives giving the levels
#      REMAINING at each point. `STACKDEPTH - min(non-zero)` must equal the
#      computed peak; a disagreement fails, because it means either this parser
#      or the toolchain moved. When the graph does NOT fit, XC8 zeroes every
#      directive, so an all-zero set is itself an overflow signal and is failed
#      on its own.
#
# Usage: check_stack_depth_pic.sh <generated.s> <device.ini|depth> <reserve> <label>
#
#   <device.ini|depth>  path to the XC8 device .ini (STACKDEPTH= is read from
#                       it), or a bare integer for the regression harness.
#   <reserve>           levels held back from the budget (see the Makefile).

die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[ "$#" -eq 4 ] || die "usage: check_stack_depth_pic.sh <generated.s> <device.ini|depth> <reserve> <label>"
ASM=$1; DEPTH_SRC=$2; RESERVE=$3; LABEL=$4

[ -f "$ASM" ] || die "[$LABEL] generated assembly not found: $ASM"
[ -s "$ASM" ] || die "[$LABEL] generated assembly is empty: $ASM"

# --- the device's hardware stack depth --------------------------------------
if printf '%s' "$DEPTH_SRC" | grep -qE '^[0-9]+$'; then
	STACK_DEPTH=$DEPTH_SRC
	DEPTH_FROM="explicit argument"
else
	[ -f "$DEPTH_SRC" ] || die "[$LABEL] device .ini not found: $DEPTH_SRC"
	STACK_DEPTH=$(sed -n 's/^STACKDEPTH=\([0-9][0-9]*\)[[:space:]]*$/\1/p' "$DEPTH_SRC" | head -1)
	[ -n "$STACK_DEPTH" ] \
		|| die "[$LABEL] no STACKDEPTH= in $DEPTH_SRC (device pack changed? do not guess a budget)"
	DEPTH_FROM="$DEPTH_SRC"
fi
printf '%s' "$STACK_DEPTH" | grep -qE '^[0-9]+$' && [ "$STACK_DEPTH" -gt 0 ] \
	|| die "[$LABEL] hardware stack depth must be a positive integer (got '$STACK_DEPTH')"
printf '%s' "$RESERVE" | grep -qE '^[0-9]+$' \
	|| die "[$LABEL] reserve must be a non-negative integer (got '$RESERVE')"
[ "$RESERVE" -lt "$STACK_DEPTH" ] \
	|| die "[$LABEL] reserve ($RESERVE) must be less than the stack depth ($STACK_DEPTH)"

# --- parse, walk, and decide -------------------------------------------------
# One awk pass builds the call graph from the INSTRUCTION STREAM and the entry
# points from XC8's "This function is called by:" blocks, then a recursive
# longest-path walk with cycle detection produces the peak.
report=$(
	"${AWK:-awk}" -v label="$LABEL" -v stack_depth="$STACK_DEPTH" -v reserve="$RESERVE" '
	function structural(msg) { if (bad == "") bad = msg }
	function add_edge(f, t) {
		if (index(" " calls[f] " ", " " t " ") == 0) calls[f] = calls[f] " " t
	}
	# Longest chain of pushes below n. Returns -1 once a cycle is seen.
	function depth(n,   i, m, arr, best, d) {
		if (state[n] == 1) { cyc = n; return -1 }
		if (state[n] == 2) return memo[n]
		state[n] = 1
		best = 0
		m = split(calls[n], arr, " ")
		for (i = 1; i <= m; i++) {
			d = depth(arr[i])
			if (d < 0) { cyc = n " -> " cyc; return -1 }
			if (d + 1 > best) { best = d + 1; nxt[n] = arr[i] }
		}
		state[n] = 2; memo[n] = best
		return best
	}
	function chain(n,   s) { s = n; while (nxt[n] != "") { n = nxt[n]; s = s " -> " n } return s }

	# ---- function blocks and their annotations
	$1 == ";;" && $3 == "function" && $2 ~ /^\*+$/ {
		cur = ""
		if (pending != "") structural("function " pending " has no matching psect marker")
		fn = $4
		if (fn in known) structural("duplicate function annotation for " fn)
		known[fn] = 1; pending = fn; mode = ""; next
	}
	/^;; This function calls:/            { mode = "calls";    next }
	/^;; This function is called by:/     { mode = "calledby"; next }
	/^;;/ && mode != "" {
		s = $0
		sub(/^;;[ \t]*/, "", s)
		if (s == "" || s == "Nothing") next
		if (mode == "calledby") {
			if (s ~ /^Startup code after reset/) {
				if ((fn in entry) && entry[fn] != "reset") structural("conflicting entry-point classifications for " fn)
				else entry[fn] = "reset"
			}
			else if (s ~ /^Interrupt level/) {
				if ((fn in entry) && entry[fn] != "interrupt") structural("conflicting entry-point classifications for " fn)
				else entry[fn] = "interrupt"
			}
		}
		next
	}
	!/^;;/ { mode = "" }

	# ---- the emitted instruction stream
	# A function annotation must own exactly one matching psect marker. Without
	# this check, a changed marker spelling can put real edges under an unknown,
	# unreachable caller and make the measured depth smaller.
	/;psect for function / {
		cur = ""
		n = split($0, a, "function "); pfn = a[n]; sub(/[ \t]+$/, "", pfn)
		if (!(pfn in known)) structural("function psect marker names unannotated symbol " pfn)
		else if (pending == "") structural("function psect marker for " pfn " has no preceding annotation")
		else if (pfn != pending) structural("function psect marker " pfn " does not match annotation " pending)
		else if (pfn in psect_seen) structural("duplicate function psect marker for " pfn)
		else {
			psect_seen[pfn] = 1; cur = pfn
			# Bind the psect this body lives in, so a re-selection of it can be
			# told apart from a transition out. Only an unclaimed psect binds: a
			# marker with no declaration of its own would otherwise inherit the
			# one before it. An unbound function has no psect it may be
			# re-selected into, so every psect directive ends its body -- the
			# conservative direction.
			if (open_psect != "" && !(open_psect in psect_owner)) {
				fn_psect[pfn] = open_psect; psect_owner[open_psect] = pfn
			}
		}
		open_psect = ""; pending = ""; next
	}
	# Runtime/startup psects are outside every C function. Their direct calls are
	# recorded below but are not part of the measured C call graph.
	/^[^ \t;]+:[ \t]*;psect/ { cur = ""; next }

	# Tokenize instructions after removing assembler comments. Every direct call
	# inside a function is an edge regardless of the current XC8 symbol prefix. This
	# is what makes a new naming scheme fail at the known-function check instead
	# of disappearing from the graph. Calls outside function psects are startup
	# or runtime plumbing; if such a target is one of the annotated C functions,
	# END rejects it as a misplaced edge.
	{
		code = $0; sub(/;.*/, "", code)
		sub(/^[ \t]+/, "", code); sub(/[ \t]+$/, "", code)
		if (code == "") next
		# Accept the normal separate-label form and fail closed if XC8 moves an
		# instruction onto the same line as a label.
		if (code ~ /^[^ \t]+:[ \t]*/) {
			sub(/^[^ \t]+:[ \t]*/, "", code)
			if (code == "") next
		}
		ntok = split(code, tok, /[ \t]+/); op = tolower(tok[1])
		# A psect directive ends the current function body -- UNLESS it re-selects
		# the psect that body already lives in. XC8 does exactly that once before
		# a single instruction of every function
		#     psect  text1,local,class=CODE,delta=2,merge=1,group=0
		#     global __ptext1
		#     __ptext1:  ;psect for function _init
		#     psect  text1              <-- re-selection, still inside _init
		#     _init:
		# and again to restore the psect after each inline-asm escape (`clrwdt`
		# in the PIC shell). Reading those as transitions puts the entire body of
		# every function outside any function psect and drops every call edge --
		# which is how this gate came to reject all three PIC10F322 images.
		if (op == "psect") {
			if (ntok < 2) { structural("malformed psect directive: " code); next }
			pname = tok[2]; sub(/,.*/, "", pname)
			if (cur == "" || fn_psect[cur] == "" || pname != fn_psect[cur]) cur = ""
			open_psect = pname
			next
		}
		if (op == "callstack") {
			if (ntok != 2 || tok[2] !~ /^-?[0-9]+$/) {
				structural("malformed callstack directive: " code); next
			}
			cs_seen++
			if (tok[2] + 0 != 0) { if (cs_min == "" || tok[2] + 0 < cs_min) cs_min = tok[2] + 0 }
			next
		}
		# Indirect calls cannot be resolved statically; refuse rather than under-count.
		if (op == "callw" || (op == "pcall" && ntok == 1)) { indirect++; next }
		if (op == "fcall" || op == "call" || op == "lcall" || op == "pcall") {
			if (ntok != 2) { structural("malformed direct call instruction: " code); next }
			t = tok[2]
			if (cur == "") { outside[t] = 1; next }
			add_edge(cur, t); called[t] = 1; next
		}
	}

	END {
		if (bad != "") { print "ERR " bad; exit 0 }
		nfun = 0; for (f in known) nfun++
		if (nfun == 0) { print "ERR no XC8 function annotations found (wrong file, or the annotation format changed)"; exit 0 }
		for (f in known)
			if (!(f in psect_seen)) { print "ERR function " f " has no matching psect marker"; exit 0 }
		for (t in outside)
			if (t in known) { print "ERR call to annotated function " t " occurs outside any function psect"; exit 0 }
		if (indirect > 0) { print "ERR " indirect " indirect call(s) present; the static call graph is incomplete"; exit 0 }

		# Every call target must be a function we know about.
		for (f in calls) {
			m = split(calls[f], arr, " ")
			for (i = 1; i <= m; i++)
				if (!(arr[i] in known)) { print "ERR call to unannotated symbol " arr[i] " from " f; exit 0 }
		}
		if (cs_seen == 0) { print "ERR no XC8 callstack directives found (annotation format changed? do not drop corroboration)"; exit 0 }

		# Roots derived from the instruction stream must match the roots XC8
		# declared, or one of the two views is stale.
		nroots = 0
		for (f in known) if (!(f in called)) { roots[f] = 1; nroots++ }
		for (f in roots) if (!(f in entry)) { print "ERR " f " is never called but XC8 does not list it as an entry point"; exit 0 }
		for (f in entry) if (!(f in roots)) { print "ERR " f " is an XC8 entry point but is also called from code"; exit 0 }
		if (nroots == 0) { print "ERR no entry point found (every function is called -- recursion?)"; exit 0 }

		nreset = 0
		for (f in entry) if (entry[f] == "reset") nreset++
		if (nreset != 1) { print "ERR expected exactly 1 reset entry point, found " nreset; exit 0 }

		total = 0; detail = ""
		for (f in entry) {
			d = depth(f)
			if (d < 0) { print "ERR recursion on a non-reentrant core: " cyc; exit 0 }
			# An interrupt is entered by hardware, which pushes a return
			# address; the reset vector jumps to main, which does not. An ISR
			# can arrive at the deepest point of the main tree, so trees SUM.
			if (entry[f] == "interrupt") { d = d + 1 }
			total += d
			detail = detail "    " entry[f] " tree " f ": " d " level(s)\n      " chain(f) "\n"
		}

		# XC8 zeroes every callstack directive when the graph does not fit.
		if (cs_min == "") { print "ERR XC8 zeroed every callstack directive: it could not fit the call graph (see warning 1393)"; exit 0 }
		if (cs_min != "") {
			used = stack_depth - cs_min
			if (used != total) { print "ERR computed peak " total " disagrees with XC8 callstack (" used "); parser or toolchain moved"; exit 0 }
			corro = cs_min " level(s) remaining -> " used " used (agrees)"
		}

		printf "OK %d %d %s\n", total, stack_depth - reserve - total, corro
		printf "%s", detail
	}
	' "$ASM"
)

status=$(printf '%s\n' "$report" | head -1)
detail=$(printf '%s\n' "$report" | tail -n +2)

case "$status" in
	ERR*) die "[$LABEL] ${status#ERR }" ;;
	OK*)  ;;
	*)    die "[$LABEL] stack-depth analysis produced no verdict (this is a bug in the gate, not a pass)" ;;
esac

peak=$(printf '%s' "$status" | cut -d' ' -f2)
headroom=$(printf '%s' "$status" | cut -d' ' -f3)
corro=$(printf '%s' "$status" | cut -d' ' -f4-)

printf 'PIC hardware-stack depth [%s]\n' "$LABEL"
printf '  device depth  : %s level(s)   (%s)\n' "$STACK_DEPTH" "$DEPTH_FROM"
printf '  reserve       : %s level(s)\n' "$RESERVE"
printf '  measured peak : %s level(s)\n' "$peak"
printf '  XC8 callstack : %s\n' "$corro"
printf '%s\n' "$detail"

if [ "$headroom" -lt 0 ]; then
	die "[$LABEL] peak $peak + reserve $RESERVE exceeds the $STACK_DEPTH-level hardware stack by $((-headroom))"
fi
printf 'STACK-DEPTH PASS [%s]: %s + %s reserve <= %s levels (%s spare)\n' \
	"$LABEL" "$peak" "$RESERVE" "$STACK_DEPTH" "$headroom"
