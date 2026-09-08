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
# WHAT RUNS, AND IN WHAT ORDER
#   The inventory is NOT here. The Makefile's CI_LOCAL_SEQUENCE names the ci-*
#   goals this script invokes and the order it invokes them in; CI_LOCAL_FOLDED
#   names the ones a single local `make test-long` covers instead. Make refuses
#   to parse unless those two lists PARTITION CI_GOALS, so a gate ci.yml runs
#   cannot exist without a local counterpart -- and this script refuses to start
#   unless every sequenced goal has a handler below, and every handler is
#   sequenced. What each goal covers is documented in the Makefile, beside the
#   commands that run it; a second description here is what used to go stale.
#
#   What this script owns is only what a ci-* goal deliberately does not: WHICH
#   toolchain installation to point a goal at, WHICH independently-pinned policy
#   values to hand it, and which goals a --skip-* flag suppresses.
#
#   Three things run around that sequence:
#     PREFLIGHT   local-only, and first. Validate the workflow FILES (an
#                 unparseable ci.yml fails the whole matrix before any job
#                 starts, and no local job can show that), then assert EVERY
#                 toolchain present -- host/AVR unconditionally, then PIC and
#                 ATtiny202. CI asserts inside each job, but CI's jobs run in
#                 PARALLEL; a SERIAL local run must not hide a missing toolchain
#                 behind the jobs that happen to precede it.
#     clean       match CI's fresh checkout (suppressed by --no-clean).
#     the fold    one `make test-long` after the sequence, covering
#                 CI_LOCAL_FOLDED -- hosted `verify`, `stress`, and the `pic`
#                 job's mutation step. Running those three goals separately
#                 would re-run the shared host suite three times for no added
#                 evidence. Under --pr it is `make ci-verify` alone.
#
#   The sequence ORDER is a purely local concern with no hosted counterpart:
#   hosted jobs run in parallel, so ci.yml's order carries no meaning. Only one
#   constraint is real -- the ATtiny202 build half must precede the half that
#   needs the simulator -- and the rest is the order this script has always run
#   them in, preserved so a converted mirror is comparable to the one before it.
#
#   `stress` and the mutation step are gated OFF pull requests in CI
#   (push/schedule/dispatch only). Use --pr to mirror a PR run: the hosted
#   verify job's own goal, `make ci-verify`, instead of the combined fold.
#
#   The `release` workflow (tag-triggered reproducibility gate) is a SEPARATE
#   pipeline and is intentionally NOT reproduced here -- use scripts/make-release.sh.
#
# USAGE
#   scripts/ci-local.sh [options]
#   options:
#     --pr           mirror a pull-request run: skip exhaustive stress and the
#                    conditional mutation gate; run `make ci-verify` instead of
#                    the combined `make test-long` fold
#     --no-clean     skip the initial `make clean` (faster, but not a true
#                    clean-checkout reproduction of CI)
#     --skip-pic     skip the PIC (XC8/gpsim) job -- ALL THREE parts, 10F322,
#                    10F320 and 12F675, since they share one toolchain and one
#                    CI job; ONLY if you lack that toolchain. Push mode still
#                    runs host/AVR and ATtiny202 mutation strictly but permits
#                    unavailable PIC mutants to be reported skipped instead of
#                    failing; this no longer mirrors CI, so it warns.
#                    NOTE: it does not skip the PIC HOST lanes of any part --
#                    the PIC10F320 host sweep and the PIC10F322/PIC12F675
#                    shipping-source coverage gates need only a host compiler
#                    and gcov, and run inside `make test` / `make test-long`
#                    regardless. Skipping the PIC job drops the XC8, gpsim and
#                    libgpsim evidence, not the host oracles.
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
#   The PIC job uses the Makefile's PIC_CC / PIC_DFP defaults for the 10F322 and
#   the 12F675, and the PIC10F320 lane's PIC10F320_CC / PIC10F320_DFP default to
#   those in turn (one shared XC8 + DFP install serves all three parts). If your
#   XC8/DFP live elsewhere, export PIC_CC and/or PIC_DFP before invoking: the
#   preflight resolves each path from the environment, falling back to the
#   Makefile default, and hands the result to `make ci-pic`, which requires the
#   paths on its command line. Export PIC10F320_CC / PIC10F320_DFP as well only
#   if you deliberately want that chip on a different toolchain.

set -euo pipefail

# Independent local-CI policy pins. Make owns the production defaults; explicit
# command-line delivery keeps a mismatched edit observable and fail-closed.
readonly CI_XT_STATIC_RAM_LIMIT=16
readonly CI_XT_STACK_MAX_FRAME=32
readonly CI_PIC12F675_DATA_LIMIT=48

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
command -v git >/dev/null 2>&1 \
	|| die "git is required by release history, signatures, and source-tree checks"
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
# The ATtiny202 soak's per-variant PASS count used to live here, in a local
# xt_gate() helper, because `make attiny202-soak` returning 0 does not mean the
# matrix was covered: the target iterates the variants and a SKIPPED variant
# still leaves it at exit 0. That assertion now lives in ci-attiny202-target,
# where the hosted job reads the same copy -- a local count that could drift
# from the hosted one is exactly the class of failure this script exists to
# prevent. The expected count still comes from XT_VARIANTS_SUPPORTED, declared
# `override` in the Makefile so it cannot be shrunk from the command line.
# ----------------------------------------------------------------------------

on_exit() {
	local rc=$?
	if [ "$rc" -eq 0 ]; then
		return 0
	fi
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

# Fail loud if any PIC tool/header is missing, for ALL THREE parts. Optional simulator
# and analyzer sub-targets skip cleanly when their tools are absent; pic10f320-test's
# expected-image and stack prerequisites fail closed, but they do not replace
# this complete preflight. Paths come from the Makefile
# defaults; exported selector overrides win because they are ?= in the Makefile.
#
# The two variable pairs are checked independently rather than assuming
# PIC10F320_* still tracks PIC_*: the whole point of the separate pair is that
# the 320 can be re-pinned, and a checker that reads only PIC_* would then
# assert the wrong installation and pass while that lane skipped.
assert_pic_toolchain() {
	# Every print-<VAR> query in this file passes --no-print-directory, and -s
	# does not imply it: Make enables -w in a sub-make and propagates a literal
	# w through MAKEFLAGS, where it OVERRIDES -s. Run this script from a Make
	# recipe and each value below would arrive wrapped in "Entering/Leaving
	# directory" lines -- reporting an installed toolchain as missing, at a path
	# nobody configured.
	# The four selector paths are GLOBALS, not locals: `make ci-pic` refuses to
	# run unless its caller supplies them on the command line, and the value it
	# must be handed is exactly the one asserted here. Resolving them twice
	# would let the assertion and the gate disagree about which installation is
	# under test -- the failure this preflight exists to prevent.
	local gpsim cppcheck
	local pic_cxx gpsim_inc pic10f320_cxx pic10f320_gpsim_inc
	PIN_PIC_CC="${PIC_CC:-$(make -s --no-print-directory print-PIC_CC)}"
	PIN_PIC_DFP="${PIC_DFP:-$(make -s --no-print-directory print-PIC_DFP)}"
	PIN_PIC10F320_CC="${PIC10F320_CC:-$(make -s --no-print-directory print-PIC10F320_CC)}"
	PIN_PIC10F320_DFP="${PIC10F320_DFP:-$(make -s --no-print-directory print-PIC10F320_DFP)}"
	gpsim="${GPSIM:-$(make -s --no-print-directory print-GPSIM)}"
	cppcheck="${CPPCHECK:-$(make -s --no-print-directory print-CPPCHECK)}"
	pic_cxx="${PIC_SOAK_CXX:-$(make -s --no-print-directory print-PIC_SOAK_CXX)}"
	gpsim_inc="${PIC_SOAK_GPSIM_INC:-$(make -s --no-print-directory print-PIC_SOAK_GPSIM_INC)}"
	pic10f320_cxx="${PIC10F320_SOAK_CXX:-$(make -s --no-print-directory print-PIC10F320_SOAK_CXX)}"
	pic10f320_gpsim_inc="${PIC10F320_SOAK_GPSIM_INC:-$(make -s --no-print-directory print-PIC10F320_SOAK_GPSIM_INC)}"
	"$REPO_ROOT/scripts/assert_pic_toolchain.sh" \
		--pic-cc "$PIN_PIC_CC" --pic-dfp "$PIN_PIC_DFP" \
		--pic10f320-cc "$PIN_PIC10F320_CC" --pic10f320-dfp "$PIN_PIC10F320_DFP" \
		--gpsim "$gpsim" --cppcheck "$cppcheck" \
		--pic-cxx "$pic_cxx" --pic-gpsim-inc "$gpsim_inc" \
		--pic10f320-cxx "$pic10f320_cxx" \
		--pic10f320-gpsim-inc "$pic10f320_gpsim_inc" \
		|| die "install the missing PIC tools (see TOOLCHAIN.adoc), or --skip-pic (no longer mirrors CI)."
	ok "PIC toolchain present, all three parts (XC8 + DFP + gpsim + gpsim-dev + glib + cppcheck + c++)."
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
	xt_dfp="${XT_DFP:-$(make -s --no-print-directory print-XT_DFP)}"
	venv="${YASIMAVR_VENV:-$(make -s --no-print-directory print-YASIMAVR_VENV)}"
	objdump="${OBJDUMP:-$(make -s --no-print-directory print-OBJDUMP)}"
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
# nothing here sits behind a --skip-* flag: `make attiny13a attiny85 attiny45` and `make
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
	# --no-print-directory matters most here: the count check below turns an
	# inherited -w into "expected 8 tool names, got 10 -- print-% broken?",
	# blaming the Makefile for the caller's nesting.
	raw="$(make -s --no-print-directory print-CC print-HOSTCC print-CLANG \
		print-CLANG_TIDY print-CPPCHECK print-CBMC print-GCOV \
		print-SIMAVR_INC)" \
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
	if command -v python3 >/dev/null 2>&1; then
		python3 -c 'import yaml' >/dev/null 2>&1 \
			|| missing+=("PyYAML  (apt: python3-yaml; strict workflow syntax validation)")
	else
		missing+=("python3  (apt: python3; MISRA addon + workflow validation)")
	fi
	command -v gpg >/dev/null 2>&1 \
		|| missing+=("gpg  (apt: gnupg; release-history signature fixtures)")
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
	# Present is not the same as usable: every host gate compiles firmware with
	# -Werror -Wconversion, which GCC 9 and older fail on the PIC shells. Same
	# contract `make host-compiler-valid` enforces, run here so a full local CI
	# reproduction says so in PREFLIGHT instead of ~12 minutes into the PIC job.
	"$REPO_ROOT/test/host_compiler_version.sh" "$hostcc" \
		|| die "host C compiler too old (see TOOLCHAIN.adoc, \"Host toolchain\")."
	ok "Host/AVR toolchain present ($cc + $hostcc + simavr + $cppcheck_bin + Python/PyYAML + gpg + $cbmc + analyzer + $gcov)."
}

# ----------------------------------------------------------------------------
# One handler per goal in the Makefile's CI_LOCAL_SEQUENCE, named goal_<goal>
# with dashes as underscores. The dispatcher below runs the sequence Make
# declares and checks the correspondence in BOTH directions before running
# anything, so neither half can go quiet: a sequenced goal with no handler would
# be absent from a run that still printed "Safe to push", and a handler for a
# goal no longer sequenced is a gate nobody calls.
#
# A handler supplies exactly what a ci-* goal refuses to assume -- the toolchain
# installation and the independently pinned policy values -- and applies the
# --skip-* policy. It never re-states what the goal runs; that lives in the
# Makefile, next to the commands.
#
# Each handler takes its own goal name as $1 so a skip diagnostic can name the
# gate that did not run rather than the job it belongs to.
# ----------------------------------------------------------------------------

# Toolchain asserted in PREFLIGHT, which also resolved the four selector paths
# this goal requires. The same `make ci-pic` the hosted job runs -- one goal, so
# local and CI cannot drift into running different things under the same name;
# the Makefile owns the five-process boundary and the strictness, and this
# script owns only WHICH installation to point them at.
#
# Locally there is no independent source of truth for those paths (CI has one:
# the installer wrote them), so the pins below echo back the environment-or-
# default this script documents. That satisfies ci-pic's command-line
# requirement without pretending to cross-check it.
goal_ci_pic() {
	if [ "$SKIP_PIC" -eq 1 ]; then
		warn "--skip-pic: NOT running $1 (any of the three parts); this does not mirror CI."
		return 0
	fi
	run_step "pic job: make ci-pic" make ci-pic \
		PIC_CC="$PIN_PIC_CC" PIC_DFP="$PIN_PIC_DFP" \
		PIC10F320_CC="$PIN_PIC10F320_CC" \
		PIC10F320_DFP="$PIN_PIC10F320_DFP" \
		PIC12F675_DATA_LIMIT="$CI_PIC12F675_DATA_LIMIT"
}

# One row per part, exactly as the hosted matrix runs them -- and the parts come
# from the Makefile rather than from a list here, so a new classic AVR part is
# covered locally the moment it is declared. `make print-...` is issued between
# steps: a complete Make invocation holds the worktree lock, so a query made
# while another make is in flight would block rather than answer.
goal_ci_build_classic() {
	local parts part
	parts=$(make -s --no-print-directory print-CI_CLASSIC_PARTS) \
		|| die "could not read CI_CLASSIC_PARTS from the Makefile"
	[ -n "$parts" ] || die "CI_CLASSIC_PARTS is empty; the build matrix would cover nothing"
	for part in $parts; do
		run_step "build-matrix: make ci-build-classic ($part)" \
			make ci-build-classic CI_CLASSIC_PART="$part"
	done
}

# The DFP half. Sequenced before the target half, matching the hosted job, so a
# broken image is found before anything that needs the simulator.
goal_ci_attiny202_build() {
	if [ "$SKIP_ATTINY202" -eq 1 ]; then
		warn "--skip-attiny202: NOT running $1; this does not mirror CI."
		return 0
	fi
	run_step "attiny202 job: make ci-attiny202-build" make ci-attiny202-build \
		XT_STATIC_RAM_LIMIT="$CI_XT_STATIC_RAM_LIMIT" \
		XT_STACK_MAX_FRAME="$CI_XT_STACK_MAX_FRAME"
}

# The yasimavr half. The soak's per-variant PASS count used to be counted here
# by a local helper; it now lives in ci-attiny202-target, which is the point --
# the count is a decision about what the gate proves, and a local copy of it
# could disagree with the hosted one while both stayed green.
goal_ci_attiny202_target() {
	if [ "$SKIP_ATTINY202" -eq 1 ]; then
		warn "--skip-attiny202: NOT running $1; this does not mirror CI."
		return 0
	fi
	run_step "attiny202 job: make ci-attiny202-target" make ci-attiny202-target \
		XT_STATIC_RAM_LIMIT="$CI_XT_STATIC_RAM_LIMIT"
}

# ----------------------------------------------------------------------------
# The pipeline -- preflight, then the sequence Make declares, then the fold
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
# PLAN -- settle what this run will do before it does any of it.
#
# Both of the checks below are about the run being COHERENT, not about the
# toolchain, so they come before even the preflight: a sequence naming a goal
# with no handler, or a fold that would duplicate a sequenced goal, is a defect
# in the mirror itself, and finding it after an hour of gates helps nobody.
# ----------------------------------------------------------------------------
# Reading the sequence rather than restating it means a ci-* goal that ci.yml
# gained is either invoked by this run or explicitly folded into test-long --
# the Makefile refuses to parse if it is neither, so this query cannot even
# answer while that claim is false.
sequence=$(make -s --no-print-directory print-CI_LOCAL_SEQUENCE) \
	|| die "could not read CI_LOCAL_SEQUENCE from the Makefile"
[ -n "$sequence" ] || die "CI_LOCAL_SEQUENCE is empty; this run would mirror no CI job at all"

# Both directions, before anything runs. Checking only that each sequenced goal
# has a handler would let a handler outlive the goal it serves; checking only
# the reverse would let a newly sequenced goal be skipped in silence.
sequenced_fns=""
for goal in $sequence; do
	fn="goal_${goal//-/_}"
	declare -F "$fn" >/dev/null \
		|| die "CI_LOCAL_SEQUENCE names $goal but this script defines no $fn: the local mirror would not run a gate CI runs, while still reporting success."
	sequenced_fns="$sequenced_fns $fn"
done
while read -r fn; do
	case " $sequenced_fns " in
		*" $fn "*) ;;
		*) die "$fn is defined here but CI_LOCAL_SEQUENCE does not name its goal: a handler nothing calls runs no gate." ;;
	esac
done < <(declare -F | sed -n 's/^declare -f \(goal_[A-Za-z0-9_]*\)$/\1/p')

# The fold: the goals CI_LOCAL_FOLDED names are covered by ONE local
# invocation, not invoked one at a time. `ci-verify` is spelled out at the tail
# of this script because PR mode runs only that one, so assert it is on the
# folded side -- were it moved into CI_LOCAL_SEQUENCE it would run twice per
# run, and the second time would be the one nobody noticed.
folded=$(make -s --no-print-directory print-CI_LOCAL_FOLDED) \
	|| die "could not read CI_LOCAL_FOLDED from the Makefile"
case " $folded " in
	*" ci-verify "*) ;;
	*) die "ci-verify is not in CI_LOCAL_FOLDED ($folded); the fold below would duplicate a sequenced goal." ;;
esac

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
	run_step "preflight: assert PIC toolchain present (all three parts)" assert_pic_toolchain
fi
if [ "$SKIP_ATTINY202" -eq 0 ]; then
	run_step "preflight: assert ATtiny202 toolchain present" assert_attiny202_toolchain
fi

[ "$DO_CLEAN" -eq 1 ] && run_step "make clean (match CI fresh checkout)" make clean

# The sequence, validated before anything ran (see PLAN, above).
for goal in $sequence; do
	"goal_${goal//-/_}" "$goal"
done

if [ "$PR_MODE" -eq 1 ]; then
	run_step "verify job: make ci-verify" make ci-verify
else
	# One test-long invocation combines hosted verify, mutation-free stress, and
	# the pic job's mutation gate. Keep every unskipped substrate strict and
	# authorize only target toolchains the caller explicitly skipped.
	if [ "$SKIP_PIC" -eq 1 ] && [ "$SKIP_ATTINY202" -eq 1 ]; then
		run_step "verify + stress: make test-long (skipped-target mutations may skip)" \
			make test-long MUTATION_ALLOW_SKIP=PIC,ATtiny202 \
			XT_STATIC_RAM_LIMIT="$CI_XT_STATIC_RAM_LIMIT" \
			PIC12F675_DATA_LIMIT="$CI_PIC12F675_DATA_LIMIT"
	elif [ "$SKIP_PIC" -eq 1 ]; then
		run_step "verify + stress: make test-long (PIC mutations may skip)" \
			make test-long MUTATION_ALLOW_SKIP=PIC \
			XT_STATIC_RAM_LIMIT="$CI_XT_STATIC_RAM_LIMIT" \
			PIC12F675_DATA_LIMIT="$CI_PIC12F675_DATA_LIMIT"
	elif [ "$SKIP_ATTINY202" -eq 1 ]; then
		run_step "verify + stress: make test-long (ATtiny202 mutations may skip)" \
			make test-long MUTATION_ALLOW_SKIP=ATtiny202 \
			XT_STATIC_RAM_LIMIT="$CI_XT_STATIC_RAM_LIMIT" \
			PIC12F675_DATA_LIMIT="$CI_PIC12F675_DATA_LIMIT"
	else
		run_step "verify + stress: make test-long" \
			make test-long MUTATION_ALLOW_SKIP=0 \
			XT_STATIC_RAM_LIMIT="$CI_XT_STATIC_RAM_LIMIT" \
			PIC12F675_DATA_LIMIT="$CI_PIC12F675_DATA_LIMIT"
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
	warn "PIC job was skipped (10F322, 10F320, and 12F675) -- CI will still run all three. Push with that in mind."
fi
if [ "$SKIP_ATTINY202" -eq 1 ]; then
	warn "ATtiny202 job was skipped -- CI will still run it. Push with that in mind."
fi
if [ "$SKIP_PIC" -eq 1 ] || [ "$SKIP_ATTINY202" -eq 1 ] \
		|| [ "$DO_CLEAN" -eq 0 ]; then
	ok "Requested partial local CI run complete. This was not a full push reproduction."
else
	ok "Local CI reproduction complete. Safe to push."
fi
