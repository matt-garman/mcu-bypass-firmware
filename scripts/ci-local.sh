#!/usr/bin/env bash
#
# ci-local.sh -- run the GitHub CI suite locally before pushing.
#
# WHY THIS EXISTS
#   The hosted runners are slow; a developer box with the toolchain installed
#   reproduces the same gates in a fraction of the time. This script runs, in
#   order, exactly what .github/workflows/ci.yml runs on a push to main, so a
#   clean pass here means the CI matrix will be green.
#
# CI-JOB MAPPING (.github/workflows/ci.yml)
#   preflight     -> validate the workflow FILES (an unparseable ci.yml fails
#                    the whole matrix before any job starts, and no local job
#                    can show that), then assert EVERY toolchain present: the
#                    host/AVR tools (unconditional -- no --skip covers them),
#                    then the PIC and ATtiny202 toolchains. See PREFLIGHT below.
#                    CI asserts inside each job, but CI's jobs run in PARALLEL;
#                    a serial local run must not hide a missing toolchain behind
#                    the jobs that happen to precede it.
#   pic           -> make pic-test          (10F322: XC8 + gpsim PORTA/LATA gate)
#                    make pic-test-target-variants
#                                           (10F322: libgpsim fault recovery,
#                                            firmware/model ctx_ lock-step,
#                                            and target I/O, every variant)
#                    make pic320-test       (10F320: host equivalence/actuation/
#                                            fault/firmware-coverage + build,
#                                            budget, reviewed hashes, CONFIG,
#                                            return stack, cppcheck/MISRA and CLI
#                                            gpsim across all variants)
#                    make pic320-test-target-variants
#                                           (10F320: the same fail-closed
#                                            libgpsim aggregate)
#   build-matrix  -> make all13 all85 all45 (every variant builds for every
#                                            AVR; each prints flash/RAM)
#   attiny202     -> make attiny202-test    (fuses + smoke + build/budget +
#                                            cppcheck/MISRA + coil-pulse width
#                                            oracle; STRICT_TOOLS=1)
#                    make attiny202-sim     (yasimavr functional + output trace)
#                    make attiny202-fault   (yasimavr fault injection)
#                    make attiny202-lockstep (yasimavr ctx_-vs-model co-sim)
#                    make attiny202-soak    (yasimavr 5-min soak smoke)
#                                           (the AVR-XT lane; needs the vendored
#                                            ATtiny_DFP + the patched yasimavr
#                                            venv)
#                    Those four are COUNTED, not just run: CI asserts one PASS
#                    line per variant on each, because a per-variant skip
#                    returns 0. See xt_gate() below; a bare `make` exit status
#                    is a weaker check than the CI step it stands in for.
#   verify        -> make test              ) covered together by `make
#   stress        -> make test-long         ) test-long`, which is a strict
#                                             superset of `make test`
#                                             (adds mutation testing + the
#                                             exhaustive FULL_* input domains).
#
#   `stress` is gated OFF pull requests in CI (push/schedule/dispatch only).
#   Use --pr to mirror a PR run: `make test` instead of `make test-long`.
#
#   The `release` workflow (tag-triggered reproducibility gate) is a SEPARATE
#   pipeline and is intentionally NOT reproduced here -- use scripts/make-release.sh.
#
# USAGE
#   scripts/ci-local.sh [options]
#   options:
#     --pr           mirror a pull-request run: skip the exhaustive/mutation
#                    `stress` job and run `make test` instead of `make test-long`
#     --no-clean     skip the initial `make clean` (faster, but not a true
#                    clean-checkout reproduction of CI)
#     --skip-pic     skip the PIC (XC8/gpsim) job -- BOTH chips, 10F322 and
#                    10F320, since they share one toolchain and one CI job;
#                    ONLY if you lack that toolchain. Push mode still runs
#                    host/AVR mutation strictly but permits unavailable PIC
#                    mutants of EITHER chip to be reported skipped instead of
#                    failing; this no longer mirrors CI, so it warns.
#                    NOTE: it does not skip the PIC10F320 HOST lanes -- those
#                    need only a host compiler and run inside `make test` /
#                    `make test-long` regardless.
#     --skip-attiny202  skip the ATtiny202 (DFP/yasimavr) job -- ONLY if you lack
#                    that toolchain; this no longer mirrors CI, so it warns loudly
#     -h | --help    this help
#
# TOOLCHAIN
#   Needs the same tools CI installs: avr-gcc + avr-libc, simavr + libsimavr-dev,
#   clang-tidy, cppcheck, cbmc (the `verify`/`stress` side) and XC8 + the
#   PIC10-12Fxxx DFP + gpsim + gpsim-dev + libglib2.0-dev + a C++ compiler
#   (the `pic` side, incl. the libgpsim target aggregate). See TOOLCHAIN.adoc.
#
#   EVERY toolchain is ASSERTED present in a PREFLIGHT step, before any job runs
#   (CI's fail-loud per-job steps, hoisted, plus a host/AVR assert CI gets for
#   free by installing its tools first): the pic and attiny202 sub-targets skip
#   cleanly when a tool is absent, which must never read as a local pass, and
#   the host/AVR gates fail only at the very END of a run under STRICT_TOOLS=1.
#   Use --skip-pic / --skip-attiny202 if you genuinely lack one of those two.
#   The host/AVR set has no --skip: those lanes run on every invocation.
#
#   The PIC job uses the Makefile's PIC_CC / PIC_DFP defaults, and the PIC10F320
#   lane's PIC320_CC / PIC320_DFP default to those in turn (one shared XC8 + DFP
#   install serves both chips). If your XC8/DFP live elsewhere, export PIC_CC
#   and/or PIC_DFP before invoking and make will pick them up (they are `?=`
#   defaults, so the environment wins); export PIC320_CC / PIC320_DFP as well
#   only if you deliberately want the two chips on different toolchains.

set -euo pipefail

# ----------------------------------------------------------------------------
# Small output helpers (mirrors scripts/make-release.sh)
# ----------------------------------------------------------------------------
_c()  { tput "$@" 2>/dev/null || true; }
BOLD=$(_c bold); RED=$(_c setaf 1); GRN=$(_c setaf 2); YEL=$(_c setaf 3); RST=$(_c sgr0)

section() { printf '\n%s========== %s ==========%s\n' "$BOLD" "$*" "$RST" >&2; }
log()     { printf '%s\n' "$*" >&2; }
ok()      { printf '%sOK%s   %s\n' "$GRN" "$RST" "$*" >&2; }
warn()    { printf '%sWARN%s %s\n' "$YEL" "$RST" "$*" >&2; }
die()     { printf '%sFATAL%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

usage() { sed -n '/^# USAGE/,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------
PR_MODE=0
DO_CLEAN=1
SKIP_PIC=0
SKIP_ATTINY202=0

while [ $# -gt 0 ]; do
	case "$1" in
		--pr)             PR_MODE=1; shift ;;
		--no-clean)       DO_CLEAN=0; shift ;;
		--skip-pic)       SKIP_PIC=1; shift ;;
		--skip-attiny202) SKIP_ATTINY202=1; shift ;;
		-h|--help)    usage; exit 0 ;;
		-*)           die "unknown option: $1 (try --help)" ;;
		*)            die "unexpected argument: $1 (try --help)" ;;
	esac
done

# ----------------------------------------------------------------------------
# Run from the repo root so relative paths in the Makefile resolve
# ----------------------------------------------------------------------------
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
cd "$REPO_ROOT"

# ----------------------------------------------------------------------------
# Step runner: banner + wall-clock timing + fail-loud. `set -e` already aborts
# on the first non-zero make, so a run that reaches the summary passed every step.
# ----------------------------------------------------------------------------
STEPS=()        # "name\tseconds" for the final summary
CURRENT=""      # step in flight, named by the failure trap

run_step() {
	local name="$1"; shift
	CURRENT="$name"
	section "$name"
	log "\$ $*"
	local t0=$SECONDS
	"$@"
	local dt=$(( SECONDS - t0 ))
	ok "$name (${dt}s)"
	STEPS+=("$name	${dt}")
	CURRENT=""
}

# ----------------------------------------------------------------------------
# ATtiny202 harness gates: run the target AND count its per-variant PASS lines.
#
# WHY THIS IS NOT JUST `run_step make attiny202-<x>`
#   CI deliberately does not trust these targets' exit status. Each attiny202-*
#   harness target iterates VARIANTS, and a variant that is skipped rather than
#   run still leaves the target at exit 0 -- so `make` returning 0 does not mean
#   the matrix was covered. ci.yml therefore greps one PASS marker per variant
#   and fails the step on a short count. Without the same assertion here, a tree
#   that covers fewer variants than it claims passes locally and fails in CI,
#   which is precisely the outcome this script exists to prevent.
#
#   The expected count comes from XT_VARIANTS_SUPPORTED (declared `override` in
#   the Makefile, so it cannot be shrunk from the command line) rather than from
#   VARIANTS, which can. The fault gate keeps ci.yml's hardcoded 3 as an
#   independent cross-check on that variable: if both the Makefile's supported
#   list and this expectation were sourced the same way, a wrong list would
#   agree with itself and the gate would go green having tested less.
#
# Usage: xt_gate <marker> <count> [<marker> <count>...] -- <command...>
# ----------------------------------------------------------------------------
XT_LOG_DIR=""

xt_gate() {
	local -a specs=()
	while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
		specs+=("$1"); shift
	done
	[ "${1-}" = "--" ] || die "xt_gate: missing -- before the command"
	shift
	[ "$#" -gt 0 ] || die "xt_gate: no command given"
	[ "${#specs[@]}" -gt 0 ] && [ $(( ${#specs[@]} % 2 )) -eq 0 ] \
		|| die "xt_gate: expected <marker> <count> pairs"

	[ -n "$XT_LOG_DIR" ] \
		|| XT_LOG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ci-local-attiny202.XXXXXX")
	local logfile
	logfile=$(mktemp "$XT_LOG_DIR/gate.XXXXXX")

	# pipefail is already set; a failing make aborts here exactly as before,
	# before any count is consulted.
	"$@" 2>&1 | tee "$logfile"

	local i marker want got
	for (( i = 0; i < ${#specs[@]}; i += 2 )); do
		marker=${specs[i]}
		want=${specs[i + 1]}
		got=$(grep -c "$marker" "$logfile" || true)
		[ "$got" -eq "$want" ] \
			|| die "$CURRENT: '$marker' appeared $got time(s), expected $want (a variant was skipped or did not report)"
		ok "  '$marker' x$got (expected $want)"
	done
}

on_exit() {
	local rc=$?
	if [ "$rc" -eq 0 ]; then
		[ -z "$XT_LOG_DIR" ] || rm -rf "$XT_LOG_DIR"
		return 0
	fi
	if [ -n "$CURRENT" ]; then
		printf '\n%sFAILED%s during: %s (exit %d)\n' "$RED" "$RST" "$CURRENT" "$rc" >&2
		log "CI would be RED. Fix the above and re-run."
	fi
	# Kept on failure only: the gate output is what a short count needs read.
	[ -z "$XT_LOG_DIR" ] || log "ATtiny202 gate logs kept in: $XT_LOG_DIR"
	return 0   # preserve original exit code
}
trap on_exit EXIT

# ----------------------------------------------------------------------------
# PIC toolchain assert (the local mirror of the CI pic job's fail-loud
# "Assert PIC toolchain present" step).
# ----------------------------------------------------------------------------

# Fail loud if any PIC tool/header is missing, for BOTH chips. Optional simulator
# and analyzer sub-targets skip cleanly when their tools are absent; pic320-test's
# expected-image and stack prerequisites fail closed, but they do not replace
# this complete preflight. Paths come from the Makefile
# defaults; an exported PIC_CC / PIC_DFP / PIC320_CC / PIC320_DFP /
# PIC_SOAK_GPSIM_INC wins (they are ?= in the Makefile).
#
# The two chips are checked through their OWN variables rather than assuming
# PIC320_* still tracks PIC_*: the whole point of the separate pair (merge plan
# §5.6) is that one chip can be re-pinned, and a checker that reads only PIC_*
# would then assert the wrong installation and pass while the 320 lane skipped.
assert_pic_toolchain() {
	local pic_cc pic_dfp pic320_cc pic320_dfp gpsim_inc
	pic_cc="${PIC_CC:-$(make -s print-PIC_CC)}"
	pic_dfp="${PIC_DFP:-$(make -s print-PIC_DFP)}"
	pic320_cc="${PIC320_CC:-$(make -s print-PIC320_CC)}"
	pic320_dfp="${PIC320_DFP:-$(make -s print-PIC320_DFP)}"
	gpsim_inc="${PIC_SOAK_GPSIM_INC:-$(make -s print-PIC_SOAK_GPSIM_INC)}"
	local missing=()
	[ -x "$pic_cc" ]                                  || missing+=("XC8 (10F322) at $pic_cc  (export PIC_CC=...)")
	[ -f "$pic_dfp/pic/include/proc/pic10f322.h" ]    || missing+=("PIC10-12Fxxx DFP at $pic_dfp  (export PIC_DFP=...)")
	[ -x "$pic320_cc" ]                               || missing+=("XC8 (10F320) at $pic320_cc  (export PIC320_CC=...)")
	[ -f "$pic320_dfp/pic/include/proc/pic10f320.h" ] || missing+=("PIC10F320 device header under $pic320_dfp  (export PIC320_DFP=...)")
	command -v gpsim >/dev/null 2>&1                  || missing+=("gpsim  (apt: gpsim)")
	command -v cppcheck >/dev/null 2>&1               || missing+=("cppcheck  (apt: cppcheck)")
	command -v c++ >/dev/null 2>&1                    || missing+=("c++  (apt: g++; pic-test-target-variants)")
	[ -f "$gpsim_inc/sim_context.h" ]                 || missing+=("libgpsim headers at $gpsim_inc  (apt: gpsim-dev; pic-test-target-variants)")
	pkg-config --exists glib-2.0 2>/dev/null          || missing+=("glib-2.0  (apt: libglib2.0-dev; pic-test-target-variants)")
	if [ "${#missing[@]}" -gt 0 ]; then
		log "PIC toolchain incomplete -- the pic/pic320 targets would silently SKIP, not fail:"
		for m in "${missing[@]}"; do log "  - $m"; done
		die "install the above (see TOOLCHAIN.adoc), or --skip-pic (no longer mirrors CI)."
	fi
	ok "PIC toolchain present, both chips (XC8 + DFP + gpsim + gpsim-dev + glib + cppcheck + c++)."
}

# Fail loud if any ATtiny202 (AVR-XT) input is missing. Like the PIC targets,
# every attiny202-* target SKIPS CLEANLY without the vendored ATtiny_DFP device
# files or the patched yasimavr venv -- a missing input would otherwise read as a
# local PASS while CI still runs the real gates. The two out-of-apt inputs are
# fetched + pinned by repo scripts (scripts/fetch_attiny_dfp.sh, scripts/
# fetch_yasimavr.sh); XT_DFP / YASIMAVR_VENV honor an exported override (?= in
# the Makefile). avr-objdump (binutils-avr) backs the coil-pulse width oracle.
assert_attiny202_toolchain() {
	local xt_dfp venv objdump py
	xt_dfp="${XT_DFP:-$(make -s print-XT_DFP)}"
	venv="${YASIMAVR_VENV:-$(make -s print-YASIMAVR_VENV)}"
	objdump="${OBJDUMP:-$(make -s print-OBJDUMP)}"
	py="$venv/bin/python"
	# need_dfp / need_yasimavr: which of the two FETCH-ON-DEMAND artifacts is
	# absent, tracked separately from the flat `missing` list so the failure can
	# name the one command that provisions each (see the hint block below).
	local missing=() need_dfp=0 need_yasimavr=0
	command -v avr-gcc >/dev/null 2>&1 \
		|| missing+=("avr-gcc  (apt: gcc-avr avr-libc)")
	command -v "$objdump" >/dev/null 2>&1 \
		|| missing+=("$objdump  (apt: binutils-avr; delay-width oracle)")
	command -v cppcheck >/dev/null 2>&1 \
		|| missing+=("cppcheck  (apt: cppcheck; attiny202-analyze)")
	[ -f "$xt_dfp/gcc/dev/attiny202/device-specs/specs-attiny202" ] \
		|| { missing+=("ATtiny_DFP at $xt_dfp  (scripts/fetch_attiny_dfp.sh; export XT_DFP=...)"); need_dfp=1; }
	[ -f "$xt_dfp/include/avr/iotn202.h" ] \
		|| { missing+=("ATtiny_DFP header iotn202.h at $xt_dfp  (scripts/fetch_attiny_dfp.sh)"); need_dfp=1; }
	if [ -x "$py" ] && "$py" -c "import yasimavr" >/dev/null 2>&1; then
		"$py" - >/dev/null 2>&1 <<-'PY' \
			|| { missing+=("patched yasimavr (WDT model) in $venv  (scripts/fetch_yasimavr.sh)"); need_yasimavr=1; }
		from yasimavr.device_library import load_device
		assert load_device('attiny202').find_peripheral('WDT') is not None
		PY
	else
		missing+=("patched yasimavr venv at $venv  (scripts/fetch_yasimavr.sh; export YASIMAVR_VENV=...)")
		need_yasimavr=1
	fi
	if [ "${#missing[@]}" -gt 0 ]; then
		log "ATtiny202 toolchain incomplete -- the attiny202 targets would silently SKIP, not fail:"
		for m in "${missing[@]}"; do log "  - $m"; done
		# The DFP and the yasimavr venv are gitignored, fetch-on-demand artifacts
		# under third_party/ (only the yasimavr PATCHES are tracked), so a fresh
		# clone never has them and `make clean` never removes them. Without this
		# note the list above reads as N independent breakages -- or as a
		# regression from a recent commit -- when it is really one unprovisioned
		# checkout. Name the exact command(s) that fix it.
		if [ "$need_dfp" -eq 1 ] || [ "$need_yasimavr" -eq 1 ]; then
			log ""
			log "NOTE: those are gitignored, fetch-on-demand artifacts under third_party/."
			log "      A fresh clone never has them (and 'make clean' never removes them),"
			log "      so this is most likely an unprovisioned checkout, not a regression."
			log "      Provision it with:"
			[ "$need_dfp" -eq 1 ]      && log "        ./scripts/fetch_attiny_dfp.sh"
			[ "$need_yasimavr" -eq 1 ] && log "        ./scripts/fetch_yasimavr.sh"
			log "      Each pins its download by version + SHA-256, and is idempotent"
			log "      (a re-run is a no-op once the artifact is present)."
		fi
		die "provide the above (see TOOLCHAIN.adoc), or --skip-attiny202 (no longer mirrors CI)."
	fi
	ok "ATtiny202 toolchain present (avr-gcc + binutils-avr + cppcheck + ATtiny_DFP + patched yasimavr)."
}

# Fail loud if any HOST/AVR tool is missing. Unlike the two chip toolchains,
# nothing here sits behind a --skip-* flag: `make all13 all85 all45` and `make
# test` / `make test-long` run on EVERY invocation of this script, so every tool
# below is required by every run.
#
# Two different failure modes are collected together on purpose, because both
# land at the WORST possible moment -- test-long is the last step, so a gap here
# costs the entire PIC job, the build matrix and the ATtiny202 job first:
#   * hard prerequisites (avr-gcc, the host cc, simavr headers, a deep analyzer,
#     gcov) fail their recipe outright; and
#   * STRICT_TOOLS=1 gates (cppcheck, python3, cbmc) skip cleanly in an ordinary
#     build and fail only because this script exports STRICT_TOOLS=1.
#
# KLEE is deliberately NOT asserted. Its guard (Makefile `test-symbolic-klee`)
# prints guidance and falls through WITHOUT $(SKIP), so it passes even under
# STRICT_TOOLS=1; asserting it would invent a requirement neither CI nor the
# Makefile has.
assert_host_toolchain() {
	local cc hostcc clang tidy cppcheck_bin cbmc gcov simavr_inc raw vals=()
	# One make invocation for every value -- print-% accepts multiple targets, so
	# this costs ~30 ms instead of eight process spawns. Read each tool NAME from
	# the Makefile rather than hardcoding it: CC is a plain `=` assignment, so an
	# exported CC never reaches the build and a `${CC:-...}` probe would check a
	# binary make does not run. The `?=` tools already reflect the environment.
	#
	# Validate the query rather than reading straight into variables: a partial
	# answer would otherwise leave a tool name EMPTY, and `command -v ""` fails,
	# reporting a missing tool that is actually installed -- or, worse, aborting
	# under `set -e` with no diagnostic at all.
	raw="$(make -s print-CC print-HOSTCC print-CLANG print-CLANG_TIDY \
		print-CPPCHECK print-CBMC print-GCOV print-SIMAVR_INC)" \
		|| die "could not query tool names from the Makefile (make print-* failed)."
	mapfile -t vals <<<"$raw"
	[ "${#vals[@]}" -eq 8 ] \
		|| die "expected 8 tool names from the Makefile, got ${#vals[@]} -- print-% broken?"
	cc="${vals[0]}";          hostcc="${vals[1]}"
	clang="${vals[2]}";       tidy="${vals[3]}"
	cppcheck_bin="${vals[4]}"; cbmc="${vals[5]}"
	gcov="${vals[6]}";        simavr_inc="${vals[7]}"
	local missing=()
	command -v "$cc" >/dev/null 2>&1 \
		|| missing+=("$cc  (apt: gcc-avr avr-libc; build-matrix + every AVR lane)")
	command -v "$hostcc" >/dev/null 2>&1 \
		|| missing+=("$hostcc  (host C compiler; export HOSTCC=...)")
	[ -f "$simavr_inc/sim_avr.h" ] \
		|| missing+=("simavr headers at $simavr_inc  (apt: libsimavr-dev; export SIMAVR_INC=...)")
	command -v "$gcov" >/dev/null 2>&1 \
		|| missing+=("$gcov  (ships with gcc; coverage-check)")
	command -v "$cppcheck_bin" >/dev/null 2>&1 \
		|| missing+=("$cppcheck_bin  (apt: cppcheck; analyze-cppcheck + MISRA)")
	command -v python3 >/dev/null 2>&1 \
		|| missing+=("python3  (apt: python3; the cppcheck misra addon)")
	command -v "$cbmc" >/dev/null 2>&1 \
		|| missing+=("$cbmc  (apt: cbmc; test-cbmc)")
	# analyze-tidy and analyze-deep each accept their clang tool OR an avr-gcc new
	# enough for -fanalyzer, and hard-fail (exit 1, NOT a skip) only when neither
	# is available. Probe the shared fallback once and report a genuine dead end
	# rather than demanding clang on a box whose avr-gcc can stand in.
	if ! "$cc" -fsyntax-only -fanalyzer -xc /dev/null >/dev/null 2>&1; then
		command -v "$tidy" >/dev/null 2>&1 \
			|| missing+=("$tidy  (apt: clang-tidy; analyze-tidy -- this $cc has no -fanalyzer)")
		command -v "$clang" >/dev/null 2>&1 \
			|| missing+=("$clang  (apt: clang; analyze-deep -- this $cc has no -fanalyzer)")
	fi
	if [ "${#missing[@]}" -gt 0 ]; then
		log "Host/AVR toolchain incomplete -- these back lanes that run on EVERY invocation:"
		for m in "${missing[@]}"; do log "  - $m"; done
		die "install the above (see TOOLCHAIN.adoc). There is no --skip for these:
      the build matrix and \`make test\`/\`test-long\` run unconditionally."
	fi
	ok "Host/AVR toolchain present ($cc + $hostcc + simavr + $cppcheck_bin + python3 + $cbmc + analyzer + $gcov)."
}

# ----------------------------------------------------------------------------
# The pipeline -- same order CI runs the jobs
# ----------------------------------------------------------------------------
if [ "$PR_MODE" -eq 1 ]; then
	section "ci-local: PULL-REQUEST mode (skips the exhaustive/mutation stress job)"
else
	section "ci-local: PUSH-TO-MAIN mode (full matrix, incl. exhaustive + mutation)"
fi

# Mirror CI's "no silent skips" contract: every optional-tool gate must actually
# run here, so a missing tool is a hard failure rather than a clean skip. Every
# Makefile skip guard honors STRICT_TOOLS=1. assert_pic_toolchain (above) already
# checks the PIC side up front; this extends the same guarantee to the host/AVR
# gates (cppcheck, cbmc, python3, ...) so a local green truly means "all ran".
export STRICT_TOOLS=1

# ----------------------------------------------------------------------------
# PREFLIGHT -- assert every toolchain BEFORE any job runs.
#
# CI asserts each toolchain inside its own job, and CI runs those jobs in
# PARALLEL, so each assert fails within seconds of that job starting. A local
# run is SERIAL: an assert left in job order does not fire until every job
# before it has finished. The ATtiny202 assert sat behind the entire PIC job
# plus the AVR build matrix, so a forgotten provisioning step surfaced many
# minutes into a run that was doomed from the start -- and the ATtiny202 inputs
# are exactly the ones easiest to forget, being gitignored, fetch-on-demand
# artifacts (scripts/fetch_attiny_dfp.sh, scripts/fetch_yasimavr.sh) that a
# fresh clone never carries.
#
# Hoisting both asserts here changes no gate: the same two functions run, with
# the same strictness, and each remains individually suppressed by its own
# --skip-* flag. It only moves the whole diagnosis into the first seconds.
# ----------------------------------------------------------------------------
# The workflow files themselves are a gate input: an unparseable ci.yml stops
# the ENTIRE matrix with "Invalid workflow file" before a single job starts, and
# no amount of green local jobs predicts that. Run it first -- it costs
# milliseconds, and finding it here beats finding it after the full suite.
# STRICT_TOOLS=1 (exported below for every job) turns a missing PyYAML into a
# hard failure rather than a silent skip.
run_step "preflight: validate GitHub workflow files" \
	env STRICT_TOOLS=1 "$REPO_ROOT/test/test_workflow_syntax.sh"

run_step "preflight: assert host/AVR toolchain present" assert_host_toolchain
if [ "$SKIP_PIC" -eq 0 ]; then
	run_step "preflight: assert PIC toolchain present (both chips)" assert_pic_toolchain
fi
if [ "$SKIP_ATTINY202" -eq 0 ]; then
	run_step "preflight: assert ATtiny202 toolchain present" assert_attiny202_toolchain
fi

[ "$DO_CLEAN" -eq 1 ] && run_step "make clean (match CI fresh checkout)" make clean

if [ "$SKIP_PIC" -eq 1 ]; then
	warn "--skip-pic: NOT running the PIC job (either chip); this does not mirror CI."
else
	# Toolchain asserted in PREFLIGHT above.
	run_step "pic job: make pic-test" make pic-test
	run_step "pic job: pic-test-target-variants" make pic-test-target-variants
	run_step "pic job: make pic320-test" make pic320-test
	run_step "pic job: pic320-test-target-variants" make pic320-test-target-variants
fi

run_step "build-matrix: make all13 all85 all45" make all13 all85 all45

if [ "$SKIP_ATTINY202" -eq 1 ]; then
	warn "--skip-attiny202: NOT running the ATtiny202 job; this does not mirror CI."
else
	# Toolchain asserted in PREFLIGHT above.
	#
	# XT_N is read once, before any gate runs: a complete Make invocation holds
	# the worktree lock, so `make print-...` issued while another make is in
	# flight would block rather than answer.
	XT_N=$(make -s print-XT_VARIANTS_SUPPORTED | wc -w)
	[ "$XT_N" -gt 0 ] || die "XT_VARIANTS_SUPPORTED is empty; nothing would be gated"

	run_step "attiny202 job: make attiny202-test" make attiny202-test
	run_step "attiny202 job: make attiny202-sim" \
		xt_gate "SIM PASS" "$XT_N" -- make attiny202-sim
	# Hardcoded 3, exactly as ci.yml does: an independent cross-check on
	# XT_VARIANTS_SUPPORTED rather than a second reading of it.
	run_step "attiny202 job: make attiny202-fault" \
		xt_gate "FAULT PASS" 3 -- make attiny202-fault
	# Each variant co-simulates BOTH boot scenarios, so a scenario that bailed
	# out early cannot hide behind a green per-variant verdict.
	run_step "attiny202 job: make attiny202-lockstep" \
		xt_gate "LOCKSTEP PASS" "$XT_N" "co-simulated" "$(( XT_N * 2 ))" \
		-- make attiny202-lockstep
	# CI runs a 5-minute simulated soak smoke, with the progress interval set to
	# the full duration so the log carries one progress line per variant.
	run_step "attiny202 job: make attiny202-soak" \
		xt_gate "SOAK PASS" "$XT_N" -- \
		make attiny202-soak XT_SOAK_DURATION_MS=300000 \
			XT_SOAK_PROGRESS_INTERVAL_MS=300000
fi

if [ "$PR_MODE" -eq 1 ]; then
	run_step "verify job: make test" make test
else
	# test-long contains mutation testing. Keep every host/AVR optional gate under
	# STRICT_TOOLS=1, but honor either explicit target-toolchain skip by selecting
	# the mutation driver's explicitly partial mode; its summary still reports
	# PIC and ATtiny202 skips separately.
	if [ "$SKIP_PIC" -eq 1 ] || [ "$SKIP_ATTINY202" -eq 1 ]; then
		run_step "verify + stress: make test-long (skipped-target mutations may skip)" \
			make test-long MUTATION_ALLOW_SKIP=1
	else
		run_step "verify + stress: make test-long" \
			make test-long MUTATION_ALLOW_SKIP=0
	fi
fi

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
section "ALL STEPS PASSED"
total=0
for s in "${STEPS[@]}"; do
	name=${s%	*}; secs=${s##*	}
	printf '  %s%-44s%s %ss\n' "$GRN" "$name" "$RST" "$secs" >&2
	total=$(( total + secs ))
done
printf '  %s%-44s%s %ss\n' "$BOLD" "total" "$RST" "$total" >&2
log ""
if [ "$SKIP_PIC" -eq 1 ]; then
	warn "PIC job was skipped (10F322 AND 10F320) -- CI will still run both. Push with that in mind."
fi
if [ "$SKIP_ATTINY202" -eq 1 ]; then
	warn "ATtiny202 job was skipped -- CI will still run it. Push with that in mind."
fi
ok "Local CI reproduction complete. Safe to push."
