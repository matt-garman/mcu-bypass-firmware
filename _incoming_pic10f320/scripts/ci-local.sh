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
#   verify -> make test-variants + make test-target-variants
#                                  (build + static analysis [cppcheck + MISRA]
#                                   + host/formal + firmware<->model equivalence
#                                   + actuation + fault-injection + CONFIG word
#                                   + gpsim + coverage + target fault/lock-step/
#                                   I/O timing gates -- for ALL THREE
#                                   output variants: cd4053-simple,
#                                   cd4053-mute, tq2-relay)
#   stress -> make test-mutation   (mutation-kill suite; gated OFF pull
#                                   requests in CI -- push/schedule/dispatch
#                                   only, and `needs: verify`)
#
#   Use --pr to mirror a PR run: skips the stress (mutation) job, same as CI
#   does for pull_request events.
#
#   Unlike the parent mcu-bypass-firmware project, this repo targets a single
#   MCU (PIC10F320) with no separate AVR build-matrix job, and the Makefile's
#   `all` target HARD-FAILS without XC8 (it does not skip cleanly) -- so there
#   is no "--skip-pic" mode here: verify always needs the full PIC toolchain.
#
#   The `release` workflow (tag-triggered reproducibility gate) is a SEPARATE
#   pipeline and is intentionally NOT reproduced here -- use scripts/make-release.sh.
#
# USAGE
#   scripts/ci-local.sh [options]
#   options:
#     --pr           mirror a pull-request run: skip the stress (mutation) job
#     --no-clean     skip the initial `make clean` (faster, but not a true
#                    clean-checkout reproduction of CI)
#     -h | --help    this help
#
# TOOLCHAIN
#   Needs the same tools CI installs: XC8 + the PIC10-12Fxxx DFP, gpsim,
#   gpsim-dev, libglib2.0-dev, cppcheck, cbmc, gcc/g++, python3. See
#   TOOLCHAIN.adoc.
#
#   Most individual analysis/test targets SKIP CLEANLY (exit 0) when their tool
#   is absent (see TOOLCHAIN.adoc), which is fine for ad-hoc dev use but would
#   let a missing tool masquerade as a pass here -- so, like CI's "Assert
#   toolchain present" step, this script asserts the full toolchain up front
#   and fails loud rather than silently skipping gates.
#
#   Uses the Makefile's PIC_CC / PIC_DFP defaults. If your XC8/DFP live
#   elsewhere, export PIC_CC and/or PIC_DFP before invoking and make will pick
#   them up (they are `?=` defaults, so the environment wins).

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

while [ $# -gt 0 ]; do
	case "$1" in
		--pr)         PR_MODE=1; shift ;;
		--no-clean)   DO_CLEAN=0; shift ;;
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
# Assert toolchain present (mirrors CI's "Assert toolchain present" step) --
# fail loud rather than let a missing optional tool silently skip a gate.
# ----------------------------------------------------------------------------
assert_toolchain() {
	local pic_cc pic_dfp gpsim_inc dev_header missing=0
	pic_cc="$(make -s print-PIC_CC)"
	pic_dfp="$(make -s print-PIC_DFP)"
	gpsim_inc="$(make -s print-PIC_SOAK_GPSIM_INC)"
	dev_header="${pic_dfp}/pic/include/proc/pic10f320.h"

	if [ -x "$pic_cc" ] || command -v "$pic_cc" >/dev/null 2>&1; then
		:
	else
		log "missing: XC8 ($pic_cc)"; missing=1
	fi
	[ -f "$dev_header" ] || { log "missing: PIC10-12Fxxx DFP ($dev_header)"; missing=1; }
	for t in gpsim cppcheck cbmc gcc c++ python3; do
		command -v "$t" >/dev/null 2>&1 || { log "missing: $t"; missing=1; }
	done
	[ -f "$gpsim_inc/sim_context.h" ] \
		|| { log "missing: gpsim-dev headers ($gpsim_inc/sim_context.h)"; missing=1; }
	pkg-config --exists glib-2.0 2>/dev/null \
		|| { log "missing: libglib2.0-dev (glib-2.0 pkg-config entry)"; missing=1; }

	[ "$missing" -eq 0 ] || die "toolchain incomplete (see TOOLCHAIN.adoc); install the above and re-run."
}

run_step "assert toolchain present" assert_toolchain

# ----------------------------------------------------------------------------
# The pipeline -- same order CI runs the jobs
# ----------------------------------------------------------------------------
if [ "$PR_MODE" -eq 1 ]; then
	section "ci-local: PULL-REQUEST mode (skips the stress/mutation job)"
else
	section "ci-local: PUSH-TO-MAIN mode (verify + stress)"
fi

[ "$DO_CLEAN" -eq 1 ] && run_step "make clean (match CI fresh checkout)" make clean

run_step "verify job: make test-variants" make test-variants
run_step "verify job: make test-target-variants" make test-target-variants

if [ "$PR_MODE" -eq 1 ]; then
	log "skipping stress job (--pr mirrors CI, which gates it off pull_request events)"
else
	run_step "stress job: make test-mutation" make test-mutation MUTATION_ALLOW_SKIP=0
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
ok "Local CI reproduction complete. Safe to push."
