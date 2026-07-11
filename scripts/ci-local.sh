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
#   pic           -> assert toolchain present, then
#                    make pic-test          (XC8 + gpsim PORTA/LATA gate)
#                    make pic-test-target-variants
#                                           (libgpsim fault recovery,
#                                            firmware/model ctx_ lock-step,
#                                            and target I/O, every variant)
#   build-matrix  -> make all13 all85 all45 (every variant builds for every
#                                            AVR; each prints flash/RAM)
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
#     --skip-pic     skip the PIC (XC8/gpsim) job -- ONLY if you lack that
#                    toolchain; this no longer mirrors CI, so it warns loudly
#     -h | --help    this help
#
# TOOLCHAIN
#   Needs the same tools CI installs: avr-gcc + avr-libc, simavr + libsimavr-dev,
#   clang-tidy, cppcheck, cbmc (the `verify`/`stress` side) and XC8 + the
#   PIC10-12Fxxx DFP + gpsim + gpsim-dev + libglib2.0-dev + a C++ compiler
#   (the `pic` side, incl. the libgpsim target aggregate). See TOOLCHAIN.adoc.
#
#   The PIC toolchain is ASSERTED present before the pic job runs (mirroring
#   CI's fail-loud step): the pic sub-targets skip cleanly when a tool is
#   absent, which must never read as a local pass. Use --skip-pic if you
#   genuinely lack the toolchain.
#
#   The PIC job uses the Makefile's PIC_CC / PIC_DFP defaults. If your XC8/DFP
#   live elsewhere, export PIC_CC and/or PIC_DFP before invoking and make will
#   pick them up (they are `?=` defaults, so the environment wins).

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

while [ $# -gt 0 ]; do
	case "$1" in
		--pr)         PR_MODE=1; shift ;;
		--no-clean)   DO_CLEAN=0; shift ;;
		--skip-pic)   SKIP_PIC=1; shift ;;
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

on_exit() {
	local rc=$?
	[ "$rc" -eq 0 ] && return 0
	if [ -n "$CURRENT" ]; then
		printf '\n%sFAILED%s during: %s (exit %d)\n' "$RED" "$RST" "$CURRENT" "$rc" >&2
		log "CI would be RED. Fix the above and re-run."
	fi
	return 0   # preserve original exit code
}
trap on_exit EXIT

# ----------------------------------------------------------------------------
# PIC toolchain assert (the local mirror of the CI pic job's fail-loud
# "Assert PIC toolchain present" step).
# ----------------------------------------------------------------------------

# Fail loud if any PIC tool/header is missing. Every pic-test / libgpsim PIC
# sub-target SKIPS CLEANLY when its tool is absent -- fatal for a gate, since a
# missing toolchain would otherwise read as a local PASS while CI still runs
# the real checks. Paths come from the Makefile defaults; an exported PIC_CC /
# PIC_DFP / PIC_SOAK_GPSIM_INC wins (they are ?= in the Makefile).
assert_pic_toolchain() {
	local pic_cc pic_dfp gpsim_inc
	pic_cc="${PIC_CC:-$(make -s print-PIC_CC)}"
	pic_dfp="${PIC_DFP:-$(make -s print-PIC_DFP)}"
	gpsim_inc="${PIC_SOAK_GPSIM_INC:-$(make -s print-PIC_SOAK_GPSIM_INC)}"
	local missing=()
	[ -x "$pic_cc" ]                                  || missing+=("XC8 at $pic_cc  (export PIC_CC=...)")
	[ -f "$pic_dfp/pic/include/proc/pic10f322.h" ]    || missing+=("PIC10-12Fxxx DFP at $pic_dfp  (export PIC_DFP=...)")
	command -v gpsim >/dev/null 2>&1                  || missing+=("gpsim  (apt: gpsim)")
	command -v cppcheck >/dev/null 2>&1               || missing+=("cppcheck  (apt: cppcheck)")
	command -v c++ >/dev/null 2>&1                    || missing+=("c++  (apt: g++; pic-test-target-variants)")
	[ -f "$gpsim_inc/sim_context.h" ]                 || missing+=("libgpsim headers at $gpsim_inc  (apt: gpsim-dev; pic-test-target-variants)")
	pkg-config --exists glib-2.0 2>/dev/null          || missing+=("glib-2.0  (apt: libglib2.0-dev; pic-test-target-variants)")
	if [ "${#missing[@]}" -gt 0 ]; then
		log "PIC toolchain incomplete -- the pic targets would silently SKIP, not fail:"
		for m in "${missing[@]}"; do log "  - $m"; done
		die "install the above (see TOOLCHAIN.adoc), or --skip-pic (no longer mirrors CI)."
	fi
	ok "PIC toolchain present (XC8 + DFP + gpsim + gpsim-dev + glib + cppcheck + c++)."
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

[ "$DO_CLEAN" -eq 1 ] && run_step "make clean (match CI fresh checkout)" make clean

if [ "$SKIP_PIC" -eq 1 ]; then
	warn "--skip-pic: NOT running the PIC job; this does not mirror CI."
else
	run_step "pic job: assert PIC toolchain present" assert_pic_toolchain
	run_step "pic job: make pic-test" make pic-test
	run_step "pic job: pic-test-target-variants" make pic-test-target-variants
fi

run_step "build-matrix: make all13 all85 all45" make all13 all85 all45

if [ "$PR_MODE" -eq 1 ]; then
	run_step "verify job: make test" make test
else
	run_step "verify + stress: make test-long" make test-long
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
	warn "PIC job was skipped -- CI will still run it. Push with that in mind."
fi
ok "Local CI reproduction complete. Safe to push."
