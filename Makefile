################################################################################
# bypass -- build / test / flash Makefile
################################################################################
#
# WHAT THIS BUILDS
#   A hardware-agnostic core (bypass_mcu_avr_classic.c) plus one interchangeable
#   output driver, selected at build time:
#     - cd4053      : CD4053 analog switch, single control line (CD4053_SIMPLE),
#                     driven via a MOSFET inverter (MCU 5V, switch supply 9-18V)
#     - cd4053_tmux : same driver source as cd4053 but direct-drive polarity for
#                     the TMUX4053 (adds -DBYPASS_X4053_DIRECT_DRIVE)
#     - mute        : CD4053 with mute-before-switch (CD4053_WITH_MUTE)
#     - mute_tmux   : same driver source as mute but TMUX4053 direct-drive polarity
#     - relay       : Panasonic TQ2-L2-5V latching relay, pulsed coils (TQ2_L2_5V_RELAY)
#   The *_tmux variants differ from their base ONLY in the analog-switch control
#   pin drive polarity (see src/bypass_output_x4053_polarity.h); they reuse the
#   same driver .c so the switching logic can never drift between the two.
#   Each variant is built for:
#     - ATtiny13a @ 1.2 MHz : the primary part (distinct core).
#     - tinyx5 family @ 1.0 MHz : ATtiny85 and ATtiny45 (and trivially the t25).
#                             These are core-identical to each other; simavr can
#                             model their watchdog system reset (which it cannot
#                             do for the ATtiny13a), so they also carry the
#                             WDT-reset / fault-injection coverage.
#
#   Variant outputs are written under build_avr_classic/ (override with
#   AVR_BUILD_DIR=...), named bypass_<variant>.elf/.hex (ATtiny13a) and
#   bypass_<variant>_t<n>.elf/.hex (tinyx5, n in {85,45}). Pick a variant for
#   single-target actions with VARIANT=<name>, e.g. `make VARIANT=relay program`
#   (ATtiny13a) or `make VARIANT=relay program45` (ATtiny45).
#
# HOW THE TESTS ARE LAYERED (fast -> thorough)
#   1. analyze            static analysis (clang-tidy / -fanalyzer)
#   2. test-host          independent "golden model" of the debounce algorithm
#   3. test-model-check   exhaustive proof of invariants over the whole state space
#   4. test-sim / -t85    the REAL compiled firmware run inside simavr, including
#                         lock-step co-simulation (firmware RAM vs golden model,
#                         compared every 1ms tick)
#   5. test-fault-inject  corrupt MCU state, verify watchdog-reset recovery (t85)
#   6. test-mutation      inject firmware faults, verify the suite detects them
#   7. coverage-check     fail if golden-model line coverage drops below a floor
#
# Host model tests (2,3) build with ASan+UBSan (SANITIZE=) by default.
# The firmware ELFs depend on a toolchain-signature stamp, so a compiler change
# forces a rebuild and re-runs the fault-injection gate (5).
#
# COMMON COMMANDS
#   make                 build all ATtiny13a variant firmwares (.hex) + sizes
#   make test            fast full test suite (all variants) -- use constantly
#   make test-long       exhaustive test suite (minutes) -- before release/HW
#   make trace           emit build_avr_classic/bypass_trace.vcd (VARIANT=, GTKWave)
#   make VARIANT=relay program   set fuses + flash one variant (fresh chip)
#   make clean           remove all build/test artifacts
#
# FAST vs FULL TESTS
#   `make test` compiles the fuzz/stress tests with reduced iteration counts
#   (FAST_*_DEFS) so it finishes quickly. `make test-long` rebuilds them with
#   the in-source defaults (FULL_*_DEFS = nothing extra) for exhaustive runs.
#   Any individual knob can also be overridden on the command line, e.g.:
#       make test SIM_DEFS='-DSIM_RANDOM_NOISE_DURATION_MS=20000u'
#
# USEFUL OVERRIDES (command line)
#   PROGRAMMER=usbasp       use a different ISP programmer
#   COVERAGE_MIN=95         raise the coverage gate
#   HOSTCC=clang            use a different host compiler for the test suite
#
# Run `make help` for a one-line summary of every target.
################################################################################


# --- Toolchain & primary (ATtiny13a) target ---------------------------------
# NOTE: keep comments on their OWN lines, never as trailing inline comments on
# variable assignments -- make folds the leading whitespace into the value
# (e.g. TARGET would gain a trailing space and "$(TARGET).elf" would break).
#
# MCU     : primary production MCU (ATtiny13a)
# F_CPU   : 1.2 MHz (9.6 MHz internal RC / CKDIV8)
# FW_BASE : base name for .elf / .hex (suffixed per variant)
# CC      : AVR cross-compiler
# OBJCOPY : ELF -> Intel HEX
# SIZE    : flash/RAM usage reporter
# AVRDUDE : ISP flashing tool
MCU      = attiny13a
F_CPU    = 1200000UL
FW_BASE  = bypass
CC       = avr-gcc
OBJCOPY  = avr-objcopy
SIZE     = avr-size
AVRDUDE  = avrdude

# --- AVR build-artifact directory --------------------------------------------
# Every AVR firmware image (.elf/.hex) and the trace .vcd is written here to
# keep the repo root clean -- the AVR counterpart of the PIC build's
# PIC_BUILD_DIR. Override on the command line, e.g. `make AVR_BUILD_DIR=out`.
AVR_BUILD_DIR ?= build_avr_classic
# Per-image path stem: $(AVR_BUILD_DIR)/$(FW_BASE). Each variant/chip suffix
# (_$(v)[.elf|.hex] for t13a, _$(v)_t<n>... for tinyx5) is appended to it.
AVR_FW         = $(AVR_BUILD_DIR)/$(FW_BASE)

# --- Secondary targets: the tinyx5 family (ATtiny25/45/85) ------------------
# These parts are core-identical to one another: same 1.0 MHz config, same
# registers, same fuse bytes -- they differ ONLY in flash/RAM size, the -mmcu
# name, and the avrdude part. simavr models their watchdog system reset (which
# it cannot do for the ATtiny13a), so they also carry the WDT-reset and
# fault-injection coverage for the whole family. Suffix <n> names the artifacts
# (bypass_<variant>_t<n>.elf, targets size<n>/flash<n>/...). To add a sibling
# (e.g. the ATtiny25), append its number here and define mmcu_<n>/part_<n>.
TINYX5     = 85 45
mmcu_85    = attiny85
mmcu_45    = attiny45
part_85    = t85
part_45    = t45
F_CPU_X5   = 1000000UL

# --- Output variants ---------------------------------------------------------
# The hardware-agnostic core (bypass_mcu_avr_classic.c) links against exactly one output
# driver. A variant is identified by a short name; each maps to the -D selector
# macro the firmware/tests compile with and to its driver source file. To add a
# variant: add its short name here and define macro_<name>/src_<name> below.
CORE_SRC = src/bypass_mcu_avr_classic.c src/bypass_pure.c
VARIANTS = cd4053 cd4053_tmux mute mute_tmux relay

# variant short name -> firmware -D selector macro
macro_cd4053      = CD4053_SIMPLE
macro_cd4053_tmux = CD4053_SIMPLE
macro_mute        = CD4053_WITH_MUTE
macro_mute_tmux   = CD4053_WITH_MUTE
macro_relay       = TQ2_L2_5V_RELAY

# variant short name -> output driver source file
src_cd4053      = src/bypass_output_cd4053_simple.c
src_cd4053_tmux = src/bypass_output_cd4053_simple.c
src_mute        = src/bypass_output_cd4053_with_mute.c
src_mute_tmux   = src/bypass_output_cd4053_with_mute.c
src_relay       = src/bypass_output_tq2_l2_5v_relay.c

# variant short name -> EXTRA firmware -D flags (beyond macro_<v>). The *_tmux
# variants build the SAME driver source as their base with the analog-switch
# control pins driven directly (TMUX4053) instead of through a MOSFET inverter
# (CD4053). Undefined for the base variants -> expands to empty. Appended at
# every site that compiles firmware or a variant-aware host test.
extra_cd4053_tmux = -DBYPASS_X4053_DIRECT_DRIVE
extra_mute_tmux   = -DBYPASS_X4053_DIRECT_DRIVE

# Headers shared by every firmware build; any change rebuilds all variants.
FW_HEADERS = src/bypass_config.h src/bypass_types.h src/bypass_hw_iface.h \
             src/bypass_output_common.h src/bypass_pins_avr_classic.h \
             src/bypass_blocking_delay.h src/bypass_static_assert.h \
             src/bypass_compile_checks.h \
             src/bypass_output_cd4053_simple.h src/bypass_output_cd4053_with_mute.h \
             src/bypass_output_x4053_polarity.h \
             src/bypass_output_tq2_l2_5v_relay.h

# VARIANT selects the single-target build for size/flash/trace/program actions.
# `make`/`make test` cover ALL variants; VARIANT only matters when you act on
# one specific image (e.g. flashing).
VARIANT ?= cd4053

# Programmer settings.
# PROGRAMMER: "51 AVR USB ISP ASP" dongle is a USBasp clone -> usbasp.
# AVRDUDE_PART: avrdude's short name for the ATtiny13/13a.
# Override on the command line if needed, e.g.:
#   make flash PROGRAMMER=usbasp
PROGRAMMER   ?= usbtiny
AVRDUDE_PART   ?= t13

# Fuse bytes for this design (verified bit-by-bit; see bypass_mcu_avr_classic.c header):
#   lfuse=0x4A : SPIEN on, CKDIV8 on (1.2MHz), SUT=14CK+64ms, int 9.6MHz RC, WDTON forced on
#   hfuse=0xF9 : 4.3V brown-out detection enabled; RSTDISBL/DWEN left safe
LFUSE = 0x4a
HFUSE = 0xf9

# tinyx5 family fuse bytes (identical across ATtiny25/45/85):
#   lfuse=0x62 : CKDIV8 on (1.0MHz), CKOUT off, SUT=14CK+64ms, int 8MHz RC
#   hfuse=0xCC : 4.3V BOD, SPIEN on, RSTDISBL/DWEN safe, WDTON forced on
LFUSE_X5 = 0x62
HFUSE_X5 = 0xcc

# Common avrdude flags for the ATtiny13a (programmer + part).
AVRDUDE_FLAGS = -c $(PROGRAMMER) -p $(AVRDUDE_PART)

# --- Host test-suite compiler / simavr ---------------------------------------
# Host (PC) compiler for the test suite (NOT the AVR cross-compiler).
HOSTCC      ?= cc
# -Wconversion catches implicit integer-narrowing/sign-change footguns in the
# debounce arithmetic. The host model and the firmware share the same integer
# semantics, so the model is a good place to enforce it too.
HOST_CFLAGS  = -std=c11 -Wall -Wextra -Werror -Wconversion
SIMAVR_INC  ?= /usr/include/simavr
# Note: simavr's own headers are not -Wconversion clean, so the sim harness
# uses -Wall -Wextra (still -Werror) without -Wconversion.
SIM_CFLAGS   = -std=c11 -Wall -Wextra -Werror -I$(SIMAVR_INC)
SIM_LIBS     = -lsimavr -lelf

# Sanitizers for the PURE-HOST model tests (test_logic_host, test_model_check,
# test_symbolic, test_fuses). UBSan catches the integer narrowing/overflow/
# signed-shift UB that the debounce arithmetic could otherwise hide; ASan
# catches any out-of-bounds/use-after-free in the harness itself.
# -fno-sanitize-recover turns any violation into a hard, nonzero-exit failure
# instead of a logged-and-continue warning. These pure-host binaries link no
# external libraries, so the sanitizers stay noise-free.
# Override on the command line to disable (e.g. a toolchain without the runtime):
#   make test SANITIZE=
SANITIZE    ?= -fsanitize=undefined,address -fno-sanitize-recover=all

# --- Resource-budget gate thresholds -----------------------------------------
# Per-function stack-frame ceiling for test-stack-bound (-fstack-usage).
# The firmware's full-path runtime HWM is ~10 B; any individual frame above
# this threshold signals unintended bloat (e.g. an accidental local array).
STACK_MAX_FRAME ?= 32

# ATtiny13a flash-budget ceiling for test-flash-budget (percentage of 1 KB).
# Firmware is ~46% today; a future accidental bloat passes silently without
# this gate.
FLASH_T13_BUDGET ?= 90

# Host-compiled copy of the firmware's PURE logic (bypass_pure.c), linked into
# every test that includes model_step.h. Since the convergence, model_step.h's
# step() delegates to the real debounce_integrate()/debounce_step() instead of a
# re-implementation, so those tests must link the firmware functions directly --
# the model can no longer drift from what ships. bypass_pure.c is AVR-targeted
# but hardware-free; force-including the config shim lets it compile natively so
# its only firmware dependency (the RELEASE_THRESH/PRESSED_THRESH thresholds in
# bypass_config.h) resolves on the host. The shim has an include guard, so
# force-including it into the test TU as well (which already pulls it in via
# model_step.h) is harmless.
PURE_HOST_SRC    = src/bypass_pure.c
PURE_HOST_DEP    = src/bypass_pure.c src/bypass_pure.h src/bypass_types.h
PURE_HOST_CFLAGS = -include test/bypass_config_host.h

# --- Test workload sizing ----------------------------------------------------
# The default `make test` runs a FAST but still-meaningful workload so it
# finishes in a few seconds (good for edit/build/test loops and CI gating).
# `make test-long` (alias: `make stress`) runs the FULL exhaustive workload.
# Every knob below can also be overridden individually on the command line.
#
# Fast (default) sizing:
FAST_HOST_DEFS = -DMODEL_FUZZ_RANDOM_DURATION_MS=100000u \
                 -DMODEL_FUZZ_POWER_ON_TRIALS=25 \
                 -DMODEL_FUZZ_ADVERSARIAL_CYCLES=25 \
                 -DMODEL_FUZZ_EXTREME_BOUNCE_PRESSES=5
FAST_SIM_DEFS  = -DSIM_RANDOM_NOISE_DURATION_MS=5000u \
                 -DSIM_SUSTAINED_NOISE_DURATION_MS=2000u \
                 -DSIM_EMI_BURSTS=40 \
                 -DSIM_EXTREME_BOUNCE_PRESSES=5 \
                 -DSIM_ADVERSARIAL_CYCLES=20 \
                 -DSIM_POWER_ON_BOOTS=10 \
                 -DSIM_PARITY_ITERS=200u \
                 -DSIM_LOCKSTEP_ITERS=1500u
# Full (exhaustive) sizing == the in-source defaults, so no extra -D needed.
FULL_HOST_DEFS =
FULL_SIM_DEFS  =

# Selected per-invocation; `test-long`/`stress` override these.
HOST_DEFS ?= $(FAST_HOST_DEFS)
SIM_DEFS  ?= $(FAST_SIM_DEFS)

# --- Static-analysis (clang-tidy) configuration ------------------------------
# clang-tidy needs to know where avr-libc's headers live and which AVR target
# defines to assume. These shell-outs discover the avr-gcc include paths and
# architecture so clang can parse the firmware as the AVR build sees it.
AVR_IO_HEADER      := $(shell $(CC) -print-file-name=avr/io.h)
AVR_LIBC_INCLUDE   := $(patsubst %/avr/, %, $(dir $(AVR_IO_HEADER)))
AVR_GCC_INCLUDE    := $(shell $(CC) -print-file-name=include)
AVR_ARCH           := $(shell $(CC) -mmcu=$(MCU) -dM -E - < /dev/null | awk '/__AVR_ARCH__/ { print $$3; exit }')
# Shared clang target/flags so clang-tidy AND the clang static analyzer parse
# the firmware exactly as the AVR build sees it.
CLANG_AVR_FLAGS    ?= -target avr -mmcu=$(MCU) -DF_CPU=$(F_CPU) -D__AVR__ -D__AVR_ATtiny13A__ \
                      -D__AVR_DEVICE_NAME__=$(MCU) $(if $(AVR_ARCH),-D__AVR_ARCH__=$(AVR_ARCH)) \
                      -D__AVR_HAVE_PRR_PRTIM0 \
                      -Wno-macro-redefined \
					  -fshort-enums \
                      $(if $(AVR_LIBC_INCLUDE),-I$(AVR_LIBC_INCLUDE)) \
                      $(if $(AVR_GCC_INCLUDE),-I$(AVR_GCC_INCLUDE))
CLANG_TIDY_FLAGS   ?= $(CLANG_AVR_FLAGS)
# clang-tidy check set: the default plus a curated set of bug-finding groups.
# misc-include-cleaner is excluded because it flags the (correct) transitive
# include of <stdint.h>/<stdint.h> macros via <avr/io.h>, which is idiomatic
# for AVR firmware and not worth churning the includes over.
CLANG_TIDY_CHECKS  ?= -*,bugprone-*,cert-*,clang-analyzer-*,misc-*,-misc-include-cleaner,readability-misleading-indentation,performance-*
# clang-tidy command (override to point at a different tidy binary).
CLANG_TIDY         ?= clang-tidy
# The clang-tidy invocation PREFIX (tool + checks). The analyze-tidy recipe
# appends each firmware source and the AVR parse flags per file. Override to use
# a different tidy binary or check set.
ANALYZE_CMD        ?= $(CLANG_TIDY) --checks='$(CLANG_TIDY_CHECKS)' --warnings-as-errors='*'

# Firmware translation units analyzed/linted by the `analyze` targets: the
# hardware-agnostic core plus every variant's output driver. Each is analyzed
# variant-agnostically (the core needs no selector; each driver includes its own
# header directly). $(sort) de-duplicates: the *_tmux variants reuse their
# base's driver .c, so the unique source set is what gets analyzed once each.
# (cppcheck's own configuration analysis covers both polarity #if branches of
# bypass_output_x4053_polarity.h.)
FW_SOURCES         = $(sort $(CORE_SRC) $(foreach v,$(VARIANTS),$(src_$(v))))

# cppcheck: a second, independent analyzer. Uses the AVR platform model and the
# avr-libc include path so it sees the real register definitions.
CPPCHECK           ?= cppcheck
CPPCHECK_FLAGS     ?= --enable=warning,style,performance,portability \
                      --std=c11 --platform=avr8 --error-exitcode=2 \
                      --inline-suppr \
                      --suppress=missingIncludeSystem \
                      --suppress=unmatchedSuppression \
                      --suppress=unusedStructMember \
                      -D__AVR__ -D__AVR_ATtiny13A__ -DF_CPU=$(F_CPU) \
                      $(if $(AVR_LIBC_INCLUDE),-I$(AVR_LIBC_INCLUDE))

# --- MISRA-C:2012 analysis (cppcheck misra addon) ----------------------------
# Same cppcheck binary, driven by its bundled misra.py addon. Three committed
# support files make the run readable and reproducible:
#   test/misra.json           - addon config; points misra.py at the rule texts
#   test/misra_rules.txt      - SHORT PARAPHRASES of each rule (cppcheck ships
#                               no rule texts -- they are copyrighted -- so
#                               without this every finding is an opaque number)
#   test/misra_suppressions.txt - documented per-file deviations (each maps to a
#                               "D-n" record in MISRA_COMPLIANCE.md)
# Notes:
#   - PYTHONWARNINGS=ignore silences a DeprecationWarning from misra.py under
#     Python 3.12+; cppcheck treats ANY addon stderr as a hard failure.
#   - avr-libc / avr-gcc system headers are outside the compliance boundary, so
#     their violations are suppressed by path (the '*:DIR/*' globs are quoted in
#     the recipe to keep the shell from expanding them).
#   - cppcheck must run from the project root so the relative addon/rule paths
#     resolve in the addon subprocess; `make` already does.
MISRA_ADDON        ?= test/misra.json
MISRA_RULES        ?= test/misra_rules.txt
MISRA_SUPPRESS     ?= test/misra_suppressions.txt

# Robust avr-libc include discovery for the MISRA run. The shared
# AVR_LIBC_INCLUDE (above) is derived from `$(CC) -print-file-name=avr/io.h`,
# which on this toolchain returns a bare name -- avr-libc's headers live outside
# avr-gcc's own dirs -- so it can resolve to a non-path. MISRA's value rules
# (10.x essential type, 11.x pointer/integer) are meaningless without the real
# register headers, so we discover the directory from the preprocessor's actual
# search path and fall back to the shared variable only if that fails.
MISRA_AVR_INCLUDE  := $(shell echo | $(CC) -xc -E -Wp,-v - 2>&1 | grep -oE '^ /[^ ]+' | tr -d ' ' | while read d; do if [ -f "$$d/avr/io.h" ]; then realpath "$$d" 2>/dev/null || echo "$$d"; break; fi; done)
ifeq ($(MISRA_AVR_INCLUDE),)
MISRA_AVR_INCLUDE  := $(AVR_LIBC_INCLUDE)
endif

# Base flags shared by the gating (analyze-misra) and report (analyze-misra-
# report) targets. The documented-deviation waiver (--suppressions-list) is
# deliberately NOT here: the gating target adds it (plus --error-exitcode) to
# fail on un-waived findings, while the report target omits it to show the full
# inventory including the waived deviations.
MISRA_CPPCHECK_FLAGS ?= --addon=$(MISRA_ADDON) --std=c11 --platform=avr8 \
                      --enable=style --inline-suppr \
                      --suppress=missingIncludeSystem \
                      --suppress=unmatchedSuppression \
                      $(if $(MISRA_AVR_INCLUDE),'--suppress=*:$(MISRA_AVR_INCLUDE)/*' -I$(MISRA_AVR_INCLUDE)) \
                      $(if $(AVR_GCC_INCLUDE),'--suppress=*:$(AVR_GCC_INCLUDE)/*' -I$(AVR_GCC_INCLUDE)) \
                      -D__AVR__ -D__AVR_ATtiny13A__ -DF_CPU=$(F_CPU)

# Clang static analyzer (deep symbolic-execution path analysis). This is the
# stand-in for `gcc -fanalyzer`: the system avr-gcc (7.3.0) predates -fanalyzer
# (which needs GCC 10+), but clang's analyzer understands -target avr and the
# real avr-libc headers, giving equivalent inter-procedural flow analysis.
CLANG              ?= clang

# --- Firmware compile/link flags ---------------------------------------------
# -Os                 optimize for size (tiny flash)
# -fshort-enums       8-bit enums (the design relies on this)
# -funsigned-char     plain char is unsigned
# -ffunction/data-sections + --gc-sections : strip unused code/data
# -Werror -Wall -Wextra -Wconversion : strict; -Wconversion catches narrowing
# Flags common to every firmware build; the MCU/F_CPU differ per target and are
# prepended in CFLAGS (t13a) / CFLAGS85 (t85).
CFLAGS_COMMON = -Os \
          -fshort-enums -funsigned-char \
          -ffunction-sections -fdata-sections \
          -Werror -Wall -Wextra -Wconversion -std=c11

# Primary (ATtiny13a). The tinyx5 family's per-chip flags are computed inline in
# the build/sim templates from mmcu_<n> + F_CPU_X5 + CFLAGS_COMMON.
CFLAGS    = -mmcu=$(MCU)   -DF_CPU=$(F_CPU)   $(CFLAGS_COMMON)
LDFLAGS   = -mmcu=$(MCU)   -Wl,--gc-sections

# --- Toolchain-change detection ----------------------------------------------
# The firmware's RAM-corruption sanity checks (main()'s guard) -- and the
# fault-injection tests that exercise them -- rely on the compiler keeping the
# checked globals coherent in RAM rather than caching them in registers. A
# compiler/optimization change could silently alter that and defeat the guard
# without any source change. To make such a change observable, we hash the
# compiler identities into a stamp file and have BOTH firmware ELFs depend on
# it. When the toolchain changes, the stamp is rewritten -> the firmware
# rebuilds -> the simavr harnesses relink -> `test-fault-inject` re-runs
# automatically. The stamp is only rewritten when the signature actually
# changes, so a normal build does not churn.
TOOLCHAIN_SIG   := $(shell { $(CC) --version; $(HOSTCC) --version; } 2>/dev/null | cksum | awk '{print $$1}')
TOOLCHAIN_STAMP := test/.toolchain.sig

$(TOOLCHAIN_STAMP): FORCE
	@mkdir -p test
	@if [ "$$(cat $@ 2>/dev/null)" != "$(TOOLCHAIN_SIG)" ]; then \
		printf '%s\n' "$(TOOLCHAIN_SIG)" > $@; \
		echo "toolchain signature changed ($(TOOLCHAIN_SIG)): firmware will rebuild and the fault-injection gate will re-run"; \
	fi

# Force-evaluated phony so the stamp recipe runs every invocation (it only
# touches the file when the signature differs).
.PHONY: FORCE
FORCE:

# Targets that are commands, not files.
# Targets that are commands, not files. Per-chip tinyx5 targets (all85/size85/
# fuses85/flash85/program85, *45, test-sim-t85, ...) are declared .PHONY by the
# templates that generate them.
.PHONY: all all13 clean size readfuses fuses flash program help \
        test test-fast test-long stress \
        test-host test-sim test-sim-secondary \
        test-model-check test-fault-inject test-fuses test-symbolic test-cbmc test-mutation \
        test-stack-bound test-flash-budget test-soak \
        analyze analyze-tidy analyze-cppcheck analyze-deep \
        trace coverage coverage-check coverage-clean

# ============================================================================
# BUILD -- firmware matrix (3 variants x {ATtiny13a, tinyx5 family})
# ============================================================================
#
# ELF/HEX rules are generated by templates so adding a variant OR a tinyx5
# sibling needs no new build rules. Each rule links bypass_mcu_avr_classic.c with the
# variant's driver source and selects the variant with its -D macro. The
# toolchain stamp is a prerequisite so a compiler change forces a rebuild (and
# thus re-runs the fault-injection gate that validates the RAM-corruption guard).
#
# Generated per variant <v> (ATtiny13a, 1.2 MHz):
#   $(AVR_BUILD_DIR)/bypass_<v>.elf / .hex
# Generated per variant <v> x tinyx5 chip <n> (1.0 MHz):
#   $(AVR_BUILD_DIR)/bypass_<v>_t<n>.elf / .hex

# Create the AVR build-output directory on demand. It is an ORDER-ONLY
# prerequisite of every image rule below (after the '|'), so the dir's mtime
# never forces a rebuild of an already-current image.
$(AVR_BUILD_DIR):
	@mkdir -p $@

# $(call VARIANT_BUILD_T13,variant)
define VARIANT_BUILD_T13
$(AVR_FW)_$(1).elf: $$(CORE_SRC) $$(src_$(1)) $$(FW_HEADERS) $$(TOOLCHAIN_STAMP) | $$(AVR_BUILD_DIR)
	$$(CC) $$(CFLAGS) -D$$(macro_$(1)) $$(extra_$(1)) $$(LDFLAGS) -o $$@ $$(CORE_SRC) $$(src_$(1))

$(AVR_FW)_$(1).hex: $(AVR_FW)_$(1).elf
	$$(OBJCOPY) -O ihex -R .eeprom $$< $$@
endef
$(foreach v,$(VARIANTS),$(eval $(call VARIANT_BUILD_T13,$(v))))

# $(call VARIANT_BUILD_X5,variant,chip-number) -- one tinyx5 chip
define VARIANT_BUILD_X5
$(AVR_FW)_$(1)_t$(2).elf: $$(CORE_SRC) $$(src_$(1)) $$(FW_HEADERS) $$(TOOLCHAIN_STAMP) | $$(AVR_BUILD_DIR)
	$$(CC) -mmcu=$$(mmcu_$(2)) -DF_CPU=$$(F_CPU_X5) $$(CFLAGS_COMMON) -Wl,--gc-sections \
		-D$$(macro_$(1)) $$(extra_$(1)) -o $$@ $$(CORE_SRC) $$(src_$(1))

$(AVR_FW)_$(1)_t$(2).hex: $(AVR_FW)_$(1)_t$(2).elf
	$$(OBJCOPY) -O ihex -R .eeprom $$< $$@
endef
$(foreach v,$(VARIANTS),$(foreach n,$(TINYX5),$(eval $(call VARIANT_BUILD_X5,$(v),$(n)))))

# Convenience lists of every variant's artifacts (t13a + each tinyx5 chip).
ALL_ELF13 = $(foreach v,$(VARIANTS),$(AVR_FW)_$(v).elf)
ALL_HEX13 = $(foreach v,$(VARIANTS),$(AVR_FW)_$(v).hex)
ALL_ELFX5 = $(foreach v,$(VARIANTS),$(foreach n,$(TINYX5),$(AVR_FW)_$(v)_t$(n).elf))
ALL_HEXX5 = $(foreach v,$(VARIANTS),$(foreach n,$(TINYX5),$(AVR_FW)_$(v)_t$(n).hex))
# Per-chip ELF/HEX lists (for the size<n>/all<n> targets).
$(foreach n,$(TINYX5),$(eval ELF_t$(n) := $(foreach v,$(VARIANTS),$(AVR_FW)_$(v)_t$(n).elf)))
$(foreach n,$(TINYX5),$(eval HEX_t$(n) := $(foreach v,$(VARIANTS),$(AVR_FW)_$(v)_t$(n).hex)))

# Default goal: build every ATtiny13a variant image and print sizes.
all: all13

# Build all ATtiny13a variant firmwares (.hex) + print sizes.
all13: $(ALL_HEX13) size

# Report flash/RAM usage of every ATtiny13a variant build.
size: $(ALL_ELF13)
	@for e in $(ALL_ELF13); do echo "== $$e =="; $(SIZE) --mcu=$(MCU) -C $$e; done

# Per-tinyx5-chip build + size targets: all85/size85, all45/size45, ...
# $(call MCU_X5_BUILD_TARGETS,chip-number)
define MCU_X5_BUILD_TARGETS
.PHONY: all$(1) size$(1)
all$(1): $$(HEX_t$(1)) size$(1)
size$(1): $$(ELF_t$(1))
	@for e in $$(ELF_t$(1)); do echo "== $$$$e =="; $$(SIZE) --mcu=$$(mmcu_$(1)) -C $$$$e; done
endef
$(foreach n,$(TINYX5),$(eval $(call MCU_X5_BUILD_TARGETS,$(n))))

# ============================================================================
# BUILD -- PIC10F32x (Microchip XC8) cross-build
# ============================================================================
#
# A SECOND toolchain (XC8 + the PIC10-12Fxxx DFP), entirely separate from the
# AVR build above. The PIC shell (bypass_mcu_pic10f32x.c) implements the same
# bypass_hw_iface.h contract for the PIC10F322 and links the UNCHANGED pure
# core (bypass_pure.c) + one output driver -- exactly like the AVR build.
#
# `make pic` builds every variant for the PIC10F322 and gates each on the
# device's 512-word flash budget (mirrors test-flash-budget for the AVR). It is
# STANDALONE -- deliberately NOT part of `make test` (that is the AVR
# pre-hardware gate, and XC8 may be absent in CI) -- and skips cleanly when XC8
# is not installed.
#
# Three PIC-specific build facts, each proven against XC8 v3.10 + DFP v1.9.189:
#   - -mdfp points at the pack's xc8/ SUBDIR, not the pack root (root -> err 2104).
#   - XC8 v3.10 has no C11, so it compiles as C99; the firmware's static_assert
#     is shimmed to the _Static_assert keyword (see bypass_config.h).
#   - _XTAL_FREQ is supplied here via -D (parallel to the AVR's -DF_CPU) so the
#     relay/mute drivers' __delay_ms() resolves it in every TU, not just the shell.
#
# XC8 scatters intermediates (startup.*, *.p1, *.d, .elf/.cmf/.hxl/.sym/.sdb)
# into its working directory, so the build runs inside PIC_BUILD_DIR to keep the
# repo root clean; `clean` just removes that directory.
PIC_CC    ?= /opt/microchip/xc8/v3.10/bin/xc8-cc
PIC_DFP   ?= /opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189/xc8
PIC_CHIP  ?= 10F322
PIC_TAG   ?= pic10f322
PIC_XTAL  ?= 16000000UL
PIC_BUILD_DIR ?= build_pic
# PIC10F322 device budget: 512 words flash / 64 B RAM.
PIC_FLASH_WORDS ?= 512
# gpsim simulator + processor name for the register-level functional test.
GPSIM         ?= gpsim
PIC_GPSIM_PROC ?= p10f322

# The PIC shell + the unchanged pure core (the AVR counterpart is CORE_SRC =
# bypass_mcu_avr_classic.c + bypass_pure.c).
PIC_CORE_SRC = src/bypass_mcu_pic10f32x.c src/bypass_pure.c

# Headers that, if changed, should rebuild the PIC images: the AVR FW_HEADERS
# set with the PIC pin map substituted for the AVR-classic one.
PIC_HEADERS = src/bypass_config.h src/bypass_types.h src/bypass_hw_iface.h \
              src/bypass_output_common.h src/bypass_pins_pic10f32x.h \
              src/bypass_blocking_delay.h src/bypass_static_assert.h \
              src/bypass_compile_checks.h \
              src/bypass_output_cd4053_simple.h src/bypass_output_cd4053_with_mute.h \
              src/bypass_output_tq2_l2_5v_relay.h

# XC8 compile flags: select the PIC10F322 + its DFP, C99 (no C11 in XC8), the
# PIC pin map, and _XTAL_FREQ for __delay_ms.
PIC_CFLAGS = -mcpu=$(PIC_CHIP) -mdfp=$(PIC_DFP) -std=c99 -O2 \
             -DBYPASS_MCU_PIC10F32X -D_XTAL_FREQ=$(PIC_XTAL)

# --- PIC static analysis (cppcheck + MISRA addon) ----------------------------
# The cppcheck/MISRA register-correct parse of the PIC shell needs the real XC8
# + DFP headers (the PIC analogue of avr-libc). XC8's base include dir supplies
# xc.h; the DFP supplies pic.h + the device header proc/pic10f322.h, selected by
# the chip macro -D_<CHIP> (e.g. -D_10F322). The pic8-enhanced cppcheck platform
# models the enhanced-midrange core (16-bit int).
PIC_XC8_INCLUDE  ?= /opt/microchip/xc8/v3.10/pic/include
PIC_DFP_INCLUDE  ?= $(PIC_DFP)/pic/include
PIC_CHIP_MACRO   ?= _$(PIC_CHIP)

# Defines/includes shared by both PIC cppcheck passes: select the device header,
# pin the PIC configuration so cppcheck does not also explore the AVR branch of
# bypass_output_common.h, and add the XC8 + DFP header search paths.
PIC_CPPCHECK_CPPFLAGS = -D__XC8 -D$(PIC_CHIP_MACRO) -D_XTAL_FREQ=$(PIC_XTAL) \
                        -DBYPASS_MCU_PIC10F32X -U__AVR__ -UBYPASS_MCU_AVR_CLASSIC \
                        -Isrc -I$(PIC_DFP_INCLUDE) -I$(PIC_DFP_INCLUDE)/proc -I$(PIC_XC8_INCLUDE)

# Plain bug-finding pass (parallel to analyze-cppcheck for the AVR build).
PIC_CPPCHECK_FLAGS ?= --enable=warning,style,performance,portability \
                      --std=c11 --platform=pic8-enhanced --error-exitcode=2 \
                      --inline-suppr --max-configs=1 \
                      --suppress=missingIncludeSystem \
                      --suppress=unmatchedSuppression \
                      --suppress=unusedStructMember \
                      '--suppress=*:$(PIC_XC8_INCLUDE)/*' \
                      '--suppress=*:$(PIC_DFP_INCLUDE)/*' \
                      $(PIC_CPPCHECK_CPPFLAGS)

# MISRA addon pass (parallel to MISRA_CPPCHECK_FLAGS for the AVR build). Notes:
#   - System headers (XC8 base + DFP) are outside the compliance boundary, like
#     avr-libc for the AVR run -> suppressed by path.
#   - --suppress=misra-config: cppcheck cannot value-flow-model the volatile SFR
#     bitfield unions from the Microchip headers (e.g. PIR1bits.TMR2IF in the
#     tick poll); that is a cppcheck modeling limitation on adopted toolchain
#     headers, NOT a code defect.
PIC_MISRA_CPPCHECK_FLAGS ?= --addon=$(MISRA_ADDON) --std=c11 --platform=pic8-enhanced \
                      --enable=style --inline-suppr --max-configs=1 \
                      --suppress=missingIncludeSystem \
                      --suppress=unmatchedSuppression \
                      --suppress=misra-config \
                      '--suppress=*:$(PIC_XC8_INCLUDE)/*' \
                      '--suppress=*:$(PIC_DFP_INCLUDE)/*' \
                      $(PIC_CPPCHECK_CPPFLAGS)

# Build every PIC variant and enforce the flash-word budget. The variant -D
# selector and driver source are chosen inline (the same case-pattern the AVR
# analyze/budget recipes use, since $(macro_<v>)/$(src_<v>) cannot expand inside
# a shell loop). Sources are passed as make-time absolute paths so the compiler
# can run with its cwd in PIC_BUILD_DIR.
.PHONY: pic
pic: $(PIC_CORE_SRC) $(PIC_HEADERS) $(foreach v,$(VARIANTS),$(src_$(v)))
	@if [ ! -x "$(PIC_CC)" ] && ! command -v $(PIC_CC) >/dev/null 2>&1; then \
		echo "XC8 not found at $(PIC_CC); skipping PIC build (override with PIC_CC=...)"; \
		exit 0; \
	fi; \
	mkdir -p $(PIC_BUILD_DIR); \
	echo "=== PIC10F322 build + flash-budget ($(PIC_FLASH_WORDS) words) ==="; \
	fail=0; \
	for v in $(VARIANTS); do \
		base=$${v%_tmux}; pol=; \
		[ "$$base" != "$$v" ] && pol=-DBYPASS_X4053_DIRECT_DRIVE; \
		case $$base in \
			*mute)  m=CD4053_WITH_MUTE; drv=src/bypass_output_cd4053_with_mute.c ;; \
			*relay) m=TQ2_L2_5V_RELAY;  drv=src/bypass_output_tq2_l2_5v_relay.c ;; \
			*)      m=CD4053_SIMPLE;    drv=src/bypass_output_cd4053_simple.c ;; \
		esac; \
		out=`cd $(PIC_BUILD_DIR) && $(PIC_CC) $(PIC_CFLAGS) -D$$m $$pol \
			$(addprefix $(CURDIR)/,$(PIC_CORE_SRC)) $(CURDIR)/$$drv \
			-o $(FW_BASE)_$${v}_$(PIC_TAG).hex 2>&1` \
			|| { printf '%s\n' "$$out"; echo "FAIL: variant $$v did not compile for PIC10F322"; fail=1; continue; }; \
		dec=`printf '%s\n' "$$out" | grep -E 'Program space' \
			| grep -oE '\( *[0-9]+ *\)' | head -1 | tr -d '() '`; \
		if [ -z "$$dec" ]; then \
			echo "WARN: $$v: could not parse program-word count from XC8 output:"; \
			printf '%s\n' "$$out"; continue; \
		fi; \
		pct=`awk -v u=$$dec -v t=$(PIC_FLASH_WORDS) 'BEGIN{printf "%.1f", u*100/t}'`; \
		if [ $$dec -gt $(PIC_FLASH_WORDS) ]; then \
			echo "FAIL: $$v uses $$dec words ($${pct}%) -- exceeds $(PIC_FLASH_WORDS)"; fail=1; \
		else \
			echo "OK:   $$v -> $(PIC_BUILD_DIR)/$(FW_BASE)_$${v}_$(PIC_TAG).hex : $$dec words ($${pct}%) of $(PIC_FLASH_WORDS)"; \
		fi; \
	done; \
	exit $$fail

# --- PIC CONFIG-word verification --------------------------------------------
# Host-compiled check (the PIC analogue of test-fuses, but STRONGER): it parses
# the CONFIG word XC8 emitted into each built HEX from the shell's `#pragma
# config` and asserts it matches the documented design intent (FOSC=INTOSC,
# WDTE=ON, MCLRE=OFF, BOREN=ON, ...). The PIC CONFIG word lives in firmware
# source -- no host/formal test sees it and the PIC shell has no simavr harness
# -- so a fat-fingered pragma would otherwise only bite on silicon. Reads the
# ACTUAL compiler output rather than a Makefile-injected value.
#
# Depends on `pic` to build the HEX, and runs against every produced variant
# (all share the same #pragma config, so each must match -- also catches
# divergence). Skips cleanly when XC8 is absent (no HEX produced).
test/pic/test_config_pic: test/pic/test_config_pic.c
	$(HOSTCC) $(HOST_CFLAGS) $(SANITIZE) $< -o $@

.PHONY: pic-test-config
pic-test-config: pic test/pic/test_config_pic
	@hexes=`ls $(PIC_BUILD_DIR)/$(FW_BASE)_*_$(PIC_TAG).hex 2>/dev/null`; \
	if [ -z "$$hexes" ]; then \
		echo "no PIC HEX in $(PIC_BUILD_DIR)/ (XC8 absent?); skipping CONFIG-word check"; \
		exit 0; \
	fi; \
	./test/pic/test_config_pic $$hexes

# --- PIC static analysis (cppcheck + MISRA) ----------------------------------
# Two analyzers over the PIC shell, parallel to the AVR analyze-cppcheck /
# analyze-misra. STANDALONE (XC8/DFP headers may be absent in CI; NOT part of
# `make test`) -- each skips cleanly when cppcheck/python3 or the XC8+DFP headers
# are missing. The DFP register headers are the PIC compliance-boundary analogue
# of avr-libc and are excluded by path.

# Guard recipe fragment: true (continue) only if the toolchain headers exist.
# (Duplicated as a shell test in each recipe below.)
.PHONY: pic-analyze pic-analyze-cppcheck pic-analyze-misra
pic-analyze: pic-analyze-cppcheck pic-analyze-misra
	@echo "=== PIC static analysis (cppcheck + MISRA) complete ==="

pic-analyze-cppcheck: src/bypass_mcu_pic10f32x.c $(PIC_HEADERS)
	@if ! command -v $(CPPCHECK) >/dev/null 2>&1; then \
		echo "cppcheck not installed; skipping PIC cppcheck analysis"; exit 0; \
	fi; \
	if [ ! -f "$(PIC_XC8_INCLUDE)/xc.h" ] || [ ! -f "$(PIC_DFP_INCLUDE)/proc/pic10f322.h" ]; then \
		echo "XC8/DFP headers not found; skipping PIC cppcheck analysis"; exit 0; \
	fi; \
	echo "cppcheck (PIC, pic8-enhanced): $(CPPCHECK) src/bypass_mcu_pic10f32x.c"; \
	$(CPPCHECK) $(PIC_CPPCHECK_FLAGS) src/bypass_mcu_pic10f32x.c

pic-analyze-misra: src/bypass_mcu_pic10f32x.c $(PIC_HEADERS) $(MISRA_ADDON) $(MISRA_RULES) $(MISRA_SUPPRESS)
	@if ! command -v $(CPPCHECK) >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then \
		echo "cppcheck and/or python3 not available; skipping PIC MISRA analysis"; exit 0; \
	fi; \
	if [ ! -f "$(PIC_XC8_INCLUDE)/xc.h" ] || [ ! -f "$(PIC_DFP_INCLUDE)/proc/pic10f322.h" ]; then \
		echo "XC8/DFP headers not found; skipping PIC MISRA analysis"; exit 0; \
	fi; \
	echo "MISRA-C:2012 analysis -- PIC shell ($(CPPCHECK) + misra addon, pic8-enhanced)"; \
	out=`mktemp`; rc=0; \
	PYTHONWARNINGS=ignore $(CPPCHECK) $(PIC_MISRA_CPPCHECK_FLAGS) \
		--suppressions-list=$(MISRA_SUPPRESS) --error-exitcode=2 \
		src/bypass_mcu_pic10f32x.c 2>>$$out || rc=1; \
	if [ $$rc -ne 0 ]; then \
		echo "MISRA findings NOT covered by a documented deviation:"; \
		grep -E "misra-c2012" $$out || true; \
		echo ""; \
		echo "Fix it, or (if genuinely unavoidable) add a per-file entry to"; \
		echo "$(MISRA_SUPPRESS) with a matching record in MISRA_COMPLIANCE.md."; \
		rm -f $$out *.dump *.ctu-info cppcheck-addon-ctu-file-list*; \
		exit 1; \
	fi; \
	rm -f $$out *.dump *.ctu-info cppcheck-addon-ctu-file-list*; \
	echo "MISRA-C:2012 (PIC shell): clean (documented deviations waived per MISRA_COMPLIANCE.md)"

# --- PIC gpsim register-level functional test --------------------------------
# Run the real built HEX inside gpsim, drive the footswitch (RA3) through two
# momentary presses, and assert the observable register state (LED on RA0 /
# LATA, footswitch on RA3 / PORTA) at four settled checkpoints: power-on BYPASS
# -> press toggles + latches ENGAGED -> second press toggles back to BYPASS.
# This is the PIC shell's analogue of the AVR simavr suite (the PIC shell has no
# simavr lock-step). Variant-agnostic stimulus (test/pic/footswitch_toggle.stc);
# the expected ENGAGED full-LATA pattern is passed per variant (el). It is
# polarity-dependent for the analog-switch variants: CD4053 drives the control
# pins HIGH when engaged (cd4053=0x3, mute=0x7), while the TMUX4053 direct-drive
# *_tmux variants drive them LOW, leaving only the LED bit set (el=0x1, same as
# the relay, whose coils are parked low at the settled checkpoint).
#
# A second scenario (test/pic/power_on_pressed.stc, via
# run_gpsim_power_on_pressed.sh) covers the startup branch the toggle scenario
# never hits: the footswitch HELD at power-on must come up BYPASS and must NOT
# engage until a genuine release + fresh press. Both run per variant. Depends on
# `pic` to build the HEX; skips cleanly when gpsim or the HEX is absent.
.PHONY: pic-test-gpsim
pic-test-gpsim: pic
	@if ! command -v $(GPSIM) >/dev/null 2>&1; then \
		echo "gpsim not installed; skipping PIC gpsim register-level test"; exit 0; \
	fi; \
	guard=0; \
	for s in test/pic/run_gpsim_test.sh test/pic/run_gpsim_power_on_pressed.sh; do \
		mode=`git ls-files --stage -- "$$s" | cut -d' ' -f1`; \
		if [ "$$mode" != "100755" ]; then \
			echo "ERROR: $$s is not mode 100755 in git (found '$$mode')."; \
			echo "       CI checks out git's mode, so a non-exec script fails as"; \
			echo "       '/bin/sh: ...: Permission denied'."; \
			echo "       Fix: git update-index --chmod=+x $$s   (then commit)"; \
			guard=1; \
		elif [ ! -x "$$s" ]; then \
			echo "ERROR: $$s is 100755 in git but lacks its local exec bit"; \
			echo "       (e.g. a clone onto NFS that didn't honor the mode)."; \
			echo "       CI is unaffected; this only blocks the local run."; \
			echo "       Fix: chmod +x $$s"; \
			guard=1; \
		fi; \
	done; \
	[ $$guard -eq 0 ] || exit 1; \
	fail=0; \
	for v in $(VARIANTS); do \
		case $$v in \
			*_tmux) el=0x1 ;; \
			*mute)  el=0x7 ;; \
			*relay) el=0x1 ;; \
			*)      el=0x3 ;; \
		esac; \
		hex=$(PIC_BUILD_DIR)/$(FW_BASE)_$${v}_$(PIC_TAG).hex; \
		if [ ! -f "$$hex" ]; then \
			echo "no $$hex (XC8 absent?); skipping gpsim test for $$v"; continue; \
		fi; \
		echo "--- gpsim register-level test: variant $$v ---"; \
		GPSIM=$(GPSIM) PIC_GPSIM_PROC=$(PIC_GPSIM_PROC) \
			test/pic/run_gpsim_test.sh $$hex $$el || fail=1; \
		GPSIM=$(GPSIM) PIC_GPSIM_PROC=$(PIC_GPSIM_PROC) \
			test/pic/run_gpsim_power_on_pressed.sh $$hex || fail=1; \
	done; \
	exit $$fail

# Aggregate: every PIC pre-hardware check (build+budget, CONFIG word, static
# analysis, gpsim functional). Standalone -- NOT part of `make test`, which is
# the AVR pre-hardware gate (XC8/gpsim may be absent in CI). Each sub-target
# skips cleanly when its tool is missing.
.PHONY: pic-test
pic-test: pic-test-config pic-analyze pic-test-gpsim
	@echo "=== all PIC10F322 pre-hardware checks complete ==="

# --- PIC long-duration soak test (libgpsim) ----------------------------------
# The PIC analogue of `test-soak`: drive the real built HEX in gpsim -- via
# libgpsim, NOT the gpsim CLI -- for PIC_SOAK_DURATION_MS of simulated time and
# assert WDT liveness + a periodic 2-press responsiveness round-trip. Failures
# are non-fatal and logged; the run continues the full duration. The driver is
# variant-agnostic (LED is RA0 on every variant). See test/pic/test_soak_pic.cc.
#
# STANDALONE -- deliberately NOT in `make test`/`pic-test`: it runs for minutes
# and links libgpsim, which needs the gpsim-dev + libglib2.0-dev headers (CI may
# lack them). Skips cleanly (exit 0) when the compiler, those headers, or the
# built HEX are absent -- exactly as `pic-test-gpsim` skips without gpsim. Phony
# + always recompiles so PIC_SOAK_* command-line overrides are always applied.
#
# Overrides: PIC_SOAK_VARIANT (cd4053[_tmux]/mute[_tmux]/relay), PIC_SOAK_DURATION_MS (default
# 1 h; pass 86400000 for 24 h), PIC_SOAK_LIVENESS_INTERVAL_MS, PIC_SOAK_PROGRESS_INTERVAL_MS.
PIC_SOAK_CXX         ?= c++
PIC_SOAK_GPSIM_INC   ?= /usr/include/gpsim
PIC_SOAK_VARIANT     ?= cd4053
PIC_SOAK_DURATION_MS ?= 3600000
PIC_SOAK_LIVENESS_INTERVAL_MS ?= 60000
PIC_SOAK_PROGRESS_INTERVAL_MS ?= 3600000
PIC_SOAK_SRC = test/pic/test_soak_pic.cc
PIC_SOAK_BIN = test/pic/test_soak_pic
PIC_SOAK_HEX = $(PIC_BUILD_DIR)/$(FW_BASE)_$(PIC_SOAK_VARIANT)_$(PIC_TAG).hex

# Worst-case blocking output actuation (ms) per variant, passed to the soak as
# -DSOAK_ACTUATION_BLOCK_MS. A relay coil pulse / CD4053 mute busy-blocks the
# POLLED PIC main loop, stealing that many 1 ms debounce ticks from a window, so
# the soak's liveness check must hold each press/release that much longer to stay
# robust (see test/pic/test_soak_pic.cc). Mirror the driver headers'
# TQ2_L2_5V_PULSE_MS (12) and CD4053_MUTE_DELAY_MS (5); cd4053-simple is 0. The
# block time is polarity-independent, so each *_tmux variant matches its base.
pic_soak_block_cd4053      = 0
pic_soak_block_cd4053_tmux = 0
pic_soak_block_mute        = 5
pic_soak_block_mute_tmux   = 5
pic_soak_block_relay       = 12

# Compile command for the PIC soak driver, factored into one variable so BOTH
# the run target (pic-test-soak) and the build-only rule ($(PIC_SOAK_BIN) below)
# share a single definition -- the PIC analogue of the AVR SOAK_COMPILE. FW_PATH
# is baked as an ABSOLUTE path ($(CURDIR)/...) so the resulting binary does not
# depend on the cwd it is launched from. That matters for the release pipeline:
# scripts/make-release.sh builds one soak binary per variant and runs them in
# parallel, each in its own working directory, so their gpsim.log files (gpsim
# always drops one in the cwd) never collide. Running from repo root (as
# pic-test-soak does) is unaffected -- an absolute FW_PATH resolves either way.
PIC_SOAK_COMPILE = $(PIC_SOAK_CXX) -std=c++17 -O2 $$(pkg-config --cflags glib-2.0) \
		-isystem $(PIC_SOAK_GPSIM_INC) -Itest -Isrc \
		-DFW_PATH='"$(CURDIR)/$(PIC_SOAK_HEX)"' -DPROC_NAME='"$(PIC_GPSIM_PROC)"' \
		-DF_CPU_HZ=$(PIC_XTAL) \
		-DSOAK_DURATION_MS=$(PIC_SOAK_DURATION_MS) \
		-DSOAK_LIVENESS_INTERVAL_MS=$(PIC_SOAK_LIVENESS_INTERVAL_MS) \
		-DSOAK_PROGRESS_INTERVAL_MS=$(PIC_SOAK_PROGRESS_INTERVAL_MS) \
		-DSOAK_ACTUATION_BLOCK_MS=$(pic_soak_block_$(PIC_SOAK_VARIANT))u \
		$(PIC_SOAK_SRC) -o $(PIC_SOAK_BIN) -lgpsim

# Build-only convenience rule: compile the soak driver for the selected
# PIC_SOAK_VARIANT to PIC_SOAK_BIN WITHOUT running it (the PIC analogue of the
# AVR $(SOAK_BIN) build rule). Used by scripts/make-release.sh, which builds one
# binary per variant under unique PIC_SOAK_BIN names and then runs them
# concurrently. The HEX it embeds is produced by `make pic`, which the release
# script runs first; like the AVR convenience rule it will not rebuild on a
# PIC_SOAK_DURATION_MS change alone, so the release script always `make clean`s
# before a fresh build.
$(PIC_SOAK_BIN): $(PIC_SOAK_SRC)
	$(PIC_SOAK_COMPILE)

.PHONY: pic-test-soak
pic-test-soak: pic
	@if ! command -v $(PIC_SOAK_CXX) >/dev/null 2>&1; then \
		echo "no C++ compiler ($(PIC_SOAK_CXX)); skipping PIC soak"; exit 0; \
	fi; \
	if [ ! -f "$(PIC_SOAK_GPSIM_INC)/sim_context.h" ]; then \
		echo "gpsim-dev headers not at $(PIC_SOAK_GPSIM_INC); skipping PIC soak (install gpsim-dev)"; exit 0; \
	fi; \
	if ! pkg-config --exists glib-2.0 2>/dev/null; then \
		echo "libglib2.0-dev not found; skipping PIC soak (install libglib2.0-dev)"; exit 0; \
	fi; \
	if [ ! -f "$(PIC_SOAK_HEX)" ]; then \
		echo "no $(PIC_SOAK_HEX) (XC8 absent?); skipping PIC soak for variant $(PIC_SOAK_VARIANT)"; exit 0; \
	fi; \
	echo "--- PIC soak: variant=$(PIC_SOAK_VARIANT) proc=$(PIC_GPSIM_PROC) duration=$(PIC_SOAK_DURATION_MS) ms ---"; \
	$(PIC_SOAK_COMPILE); \
	./$(PIC_SOAK_BIN)

# --- PIC device programming (hardware) ---------------------------------------
# Flash ONE built PIC variant (chosen by VARIANT, default $(VARIANT)) onto a real
# PIC10F322. Unlike AVR fuses, the PIC CONFIG word is embedded IN the HEX by
# XC8's `#pragma config`, so writing the HEX programs the configuration too --
# there is no separate fuse step (and the gpsim/CONFIG-word checks already
# verified that word pre-flash).
#
# Two common Linux programmers, selected by PIC_PROG:
#   pk2cmd  (PICkit 2, open-source CLI)            <- default
#   ipecmd  (PICkit 3/4/5 via MPLAB IPE; PIC_PROG=ipecmd, PIC_PROG_TOOL=PK3|PK4|PK5)
# The full command is PIC_PROG_CMD; override it wholesale for any other tool.
# Power defaults are CONSERVATIVE: the programmer does NOT source Vdd (safe for an
# externally-powered pedal board). For a bare chip powered by the programmer, add
# the power flag: pk2cmd `-T` (and `-A<volts>`), ipecmd `-W`.
PIC_PART      ?= PIC10F322
PIC_PROG      ?= pk2cmd
PIC_PROG_TOOL ?= PK4
PIC_PROG_HEX   = $(PIC_BUILD_DIR)/$(FW_BASE)_$(VARIANT)_$(PIC_TAG).hex
ifeq ($(PIC_PROG),ipecmd)
PIC_PROG_CMD ?= $(PIC_PROG) -TP$(PIC_PROG_TOOL) -P$(PIC_PART) -M -F$(PIC_PROG_HEX)
else
PIC_PROG_CMD ?= $(PIC_PROG) -P$(PIC_PART) -F$(PIC_PROG_HEX) -M -Y -R
endif

# Builds all variants + the flash-budget gate first (so the image is fresh and
# proven to fit), then flashes the VARIANT-selected HEX. Unlike the pre-hardware
# checks, this is an intentional bench action: it FAILS LOUDLY (does not silently
# skip) if the HEX or the programmer is missing. Echoes the exact command before
# it touches silicon.
.PHONY: program-pic
program-pic: pic
	@hex="$(PIC_PROG_HEX)"; \
	if [ ! -f "$$hex" ]; then \
		echo "ERROR: $$hex not found -- 'make pic' produced no HEX (XC8 installed?)."; \
		echo "       select a variant with VARIANT=<$(VARIANTS)> (default $(VARIANT))."; \
		exit 1; \
	fi; \
	if ! command -v $(PIC_PROG) >/dev/null 2>&1; then \
		echo "ERROR: PIC programmer '$(PIC_PROG)' not found on PATH."; \
		echo "       install pk2cmd (PICkit 2), or set PIC_PROG=ipecmd (PICkit 3/4/5),"; \
		echo "       or override the whole command with PIC_PROG_CMD=..."; \
		exit 1; \
	fi; \
	echo "Programming PIC10F322 (variant $(VARIANT)) via $(PIC_PROG):"; \
	echo "  $(PIC_PROG_CMD)"; \
	$(PIC_PROG_CMD)

# ============================================================================
# CLEAN
# ============================================================================

# Remove all build outputs and test binaries (keeps coverage/ -- see
# coverage-clean for that).
clean:
	rm -f $(foreach v,$(VARIANTS),test/avr/test_sim_$(v) test/avr/test_trace_$(v)) \
		$(foreach v,$(VARIANTS),$(foreach n,$(TINYX5),test/avr/test_sim_$(v)_t$(n))) \
		$(foreach v,$(VARIANTS),$(foreach n,$(TINYX5),test/avr/test_soak_$(v)_t$(n))) \
		test/host/test_logic_host test/pic/test_config_pic test/pic/test_soak_pic \
		test/formal/test_model_check test/formal/test_symbolic test/avr/test_fuses \
		test/formal/test_symbolic.bc \
		test/stack_*.o test/stack_*.su \
		$(FW_BASE).plist \
		$(TOOLCHAIN_STAMP)
	rm -f *.dump *.ctu-info cppcheck-addon-ctu-file-list*
	rm -rf test/klee-out-* test/klee-last
	rm -rf $(AVR_BUILD_DIR) $(PIC_BUILD_DIR)

# ============================================================================
# FLASH / FUSES -- hardware (select the image with VARIANT=<name>)
# ============================================================================
# These act on ONE variant image, chosen by VARIANT (default cd4053). The
# per-chip tinyx5 equivalents (fuses85/flash85/program85, fuses45/...) act on
# the corresponding ATtiny85/ATtiny45 build of the selected variant.

# Read-only: print the chip's currently programmed fuse bytes. Run this FIRST
# to record a chip's existing fuses before changing anything.
readfuses:
	$(AVRDUDE) $(AVRDUDE_FLAGS) -U lfuse:r:-:h -U hfuse:r:-:h

# Write the design's fuse bytes. Safe: does not touch RSTDISBL/DWEN, so ISP
# access is preserved. Verify before relying on a board in the field.
fuses:
	$(AVRDUDE) $(AVRDUDE_FLAGS) \
		-U lfuse:w:$(LFUSE):m \
		-U hfuse:w:$(HFUSE):m

# Flash the selected variant's ATtiny13a image to the MCU.
flash: $(AVR_FW)_$(VARIANT).hex
	$(AVRDUDE) $(AVRDUDE_FLAGS) -U flash:w:$(AVR_FW)_$(VARIANT).hex:i

# Convenience: set fuses, then flash firmware. Use for a fresh chip.
program: fuses flash

# Per-tinyx5-chip fuses/flash/program targets: fuses85/flash85/program85,
# fuses45/flash45/program45, ... All share the tinyx5 fuse bytes and differ only
# in the avrdude part. flash<n>/program<n> act on the VARIANT-selected image.
# $(call MCU_X5_FLASH_TARGETS,chip-number)
define MCU_X5_FLASH_TARGETS
.PHONY: fuses$(1) flash$(1) program$(1)
fuses$(1):
	$$(AVRDUDE) -c $$(PROGRAMMER) -p $$(part_$(1)) \
		-U lfuse:w:$$(LFUSE_X5):m \
		-U hfuse:w:$$(HFUSE_X5):m
flash$(1): $(AVR_FW)_$$(VARIANT)_t$(1).hex
	$$(AVRDUDE) -c $$(PROGRAMMER) -p $$(part_$(1)) -U flash:w:$(AVR_FW)_$$(VARIANT)_t$(1).hex:i
program$(1): fuses$(1) flash$(1)
endef
$(foreach n,$(TINYX5),$(eval $(call MCU_X5_FLASH_TARGETS,$(n))))


# ============================================================================
# TESTS
# ============================================================================

# Default `make test`: FAST workload. Runs static analysis, the host golden
# model, the exhaustive state-space model check, the symbolic single-step proof,
# the fuse-byte check, the fault-injection sim tests, both simavr firmware
# suites, and enforces a coverage floor on the model. Designed to finish in
# ~1 minute for quick edit/build/test loops and CI.
test: analyze test-host test-model-check test-symbolic test-cbmc test-fuses test-stack-bound test-flash-budget test-fault-inject test-sim test-sim-secondary coverage-check
	@echo "=== all fast pre-hardware tests passed ==="

# Explicit alias for the fast suite (same as `make test`).
test-fast: test

# FULL exhaustive workload: same targets as `test`, but the fuzz/stress tests
# are rebuilt with their large in-source default durations (FULL_*_DEFS adds no
# overrides). Use before tagging a release or signing off for hardware.
test-long: HOST_DEFS = $(FULL_HOST_DEFS)
test-long: SIM_DEFS  = $(FULL_SIM_DEFS)
test-long: clean-tests analyze test-host test-model-check test-symbolic test-cbmc test-fuses test-stack-bound test-flash-budget test-fault-inject test-mutation test-sim test-sim-secondary coverage-check
	@echo "=== all FULL (exhaustive) pre-hardware tests passed ==="

# Friendly alias for the exhaustive suite (same as `make test-long`).
stress: test-long

# Remove ONLY the test binaries so the next test run rebuilds them with the
# currently selected workload sizing (FAST vs FULL *_DEFS).
.PHONY: clean-tests
clean-tests:
	rm -f test/host/test_logic_host test/formal/test_model_check test/formal/test_symbolic \
	      test/avr/test_fuses \
	      $(foreach v,$(VARIANTS),test/avr/test_sim_$(v) test/avr/test_trace_$(v)) \
	      $(foreach v,$(VARIANTS),$(foreach n,$(TINYX5),test/avr/test_sim_$(v)_t$(n)))

# Golden-model unit tests: an INDEPENDENT host (PC) re-implementation of the
# debounce algorithm. No AVR involved -- fast logic verification that the
# algorithm itself meets the reliability goals. (test_sim* verify the REAL
# firmware matches.)
test-host: test/host/test_logic_host
	./test/host/test_logic_host

# Build rule for the golden model. Constants come from bypass_config.h (via the
# host shim) so the model can never drift from the firmware thresholds.
test/host/test_logic_host: test/host/test_logic_host.c test/bypass_config_host.h src/bypass_config.h
	$(HOSTCC) $(HOST_CFLAGS) $(SANITIZE) $(HOST_DEFS) -Itest $< -o $@

# Exhaustive small-model state-space verification: breadth-first search over the
# ENTIRE reachable state space of the debounce algorithm (~66 states), proving
# the core reliability invariants hold for ALL inputs, not just sampled ones.
test-model-check: test/formal/test_model_check
	./test/formal/test_model_check

# Build rule for the state-space checker. Links bypass_pure.c so step() exercises
# the real firmware functions (see model_step.h / PURE_HOST_SRC).
test/formal/test_model_check: test/formal/test_model_check.c test/model_step.h test/bypass_config_host.h src/bypass_config.h $(PURE_HOST_DEP)
	$(HOSTCC) $(HOST_CFLAGS) $(SANITIZE) $(PURE_HOST_CFLAGS) -Itest $< $(PURE_HOST_SRC) -o $@

# Symbolic / exhaustive single-step property check: proves the per-step
# transition invariants of step() hold for EVERY (state x input) combination in
# the full domain (the inductive step behind the whole-program invariants).
# Default build enumerates exhaustively; if KLEE is installed, `make
# test-symbolic-klee` runs the same assertions under symbolic execution.
test-symbolic: test/formal/test_symbolic
	./test/formal/test_symbolic

# Build rule for the symbolic step checker. Links bypass_pure.c so step()
# exercises the real firmware functions (see model_step.h / PURE_HOST_SRC).
test/formal/test_symbolic: test/formal/test_symbolic.c test/model_step.h test/bypass_config_host.h src/bypass_config.h $(PURE_HOST_DEP)
	$(HOSTCC) $(HOST_CFLAGS) $(SANITIZE) $(PURE_HOST_CFLAGS) -Itest $< $(PURE_HOST_SRC) -o $@

# Optional: run the SAME single-step properties under KLEE symbolic execution
# (only if KLEE is installed). KLEE explores the symbolic input domain and
# proves the assertions with an SMT solver rather than by enumeration.
.PHONY: test-symbolic-klee
# Absolute paths to the brew-installed KLEE and its matching LLVM clang. Using
# absolute defaults so the target works even when `make`'s recipe shell does not
# have brew's shellenv on PATH (an interactive shell may, /bin/sh may not).
# Using llvm@16's clang (KLEE's own LLVM) to emit the bitcode avoids the
# host/module target-triple mismatch warning seen with /usr/bin/clang.
KLEE        ?= /home/linuxbrew/.linuxbrew/bin/klee
KLEE_CLANG  ?= /home/linuxbrew/.linuxbrew/opt/llvm@16/bin/clang
KLEE_INC    := /home/linuxbrew/.linuxbrew/Cellar/klee/3.2_3/include
test-symbolic-klee:
	@if command -v $(KLEE) >/dev/null 2>&1 && command -v $(KLEE_CLANG) >/dev/null 2>&1; then \
		$(KLEE_CLANG) -DUSE_KLEE -I$(KLEE_INC) -I$(SIMAVR_INC) -Itest -emit-llvm -c -g -O0 \
			test/formal/test_symbolic.c -o test/formal/test_symbolic.bc && \
		$(KLEE) --exit-on-error test/formal/test_symbolic.bc; \
	else \
		echo "KLEE or its clang not installed; the exhaustive 'test-symbolic' target"; \
		echo "covers the same input domain. Install klee to enable SMT-backed proof."; \
	fi

# Optional: CBMC bounded-model-checking of the REAL pure core (bypass_pure.c).
# A third, independent proof engine (SAT/SMT) for the same safety + liveness
# invariants, run on the actual firmware functions rather than a re-model -- plus
# CBMC's automatic instrumentation proving the debounce path is free of integer
# overflow / out-of-range conversion / out-of-bounds undefined behaviour. See
# test/formal/test_cbmc.c. Only runs if cbmc is installed; otherwise the exhaustive
# test-model-check / test-symbolic targets already cover the same properties.
.PHONY: test-cbmc
CBMC        ?= cbmc
# bypass_pure.c includes the AVR-targeted bypass_config.h directly; supply the
# same minimal target macros the host shim provides (F_CPU + the PBx pin numbers)
# so it parses natively, exactly as PURE_HOST_CFLAGS does for the other tests.
CBMC_DEFS   = -DF_CPU=1200000UL -DPB0=0 -DPB1=1 -DPB2=2
# Turn on the full automatic-property instrumentation: any UB on the debounce
# path becomes a proof obligation, not a silent assumption.
CBMC_CHECKS = --bounds-check --pointer-check --div-by-zero-check \
              --signed-overflow-check --unsigned-overflow-check \
              --conversion-check --undefined-shift-check
# Straight-line proofs (no loops) and the two bounded-liveness proofs (loops
# fully unrolled at --unwind 50, > every harness's fixed horizon; the unwinding
# assertion proves the bound is real, not assumed). Matches TODO.md's
# `cbmc --unwind 50` on the debounce path.
CBMC_PROOFS      = prove_integrate prove_debounce_step prove_corrupt_state_faults \
                   prove_init_context prove_step_transition prove_oor_recovery_step
CBMC_PROOFS_LOOP = prove_press_liveness prove_release_liveness
# Deep-loop proof: out-of-range counter recovery unrolls the worst-case 255 -> 0
# descent, so it needs an unwind > 256 (the shorter --unwind 50 above is < the
# horizon and would fail its unwinding assertion).
CBMC_PROOFS_DEEP = prove_oor_recovery_bounded
CBMC_DEEP_UNWIND = 257
test-cbmc:
	@if command -v $(CBMC) >/dev/null 2>&1; then \
		for p in $(CBMC_PROOFS); do \
			echo "cbmc: $$p"; \
			$(CBMC) test/formal/test_cbmc.c $(PURE_HOST_SRC) -Itest $(CBMC_DEFS) \
				--function $$p $(CBMC_CHECKS) || exit 1; \
		done; \
		for p in $(CBMC_PROOFS_LOOP); do \
			echo "cbmc: $$p (--unwind 50)"; \
			$(CBMC) test/formal/test_cbmc.c $(PURE_HOST_SRC) -Itest $(CBMC_DEFS) \
				--function $$p --unwind 50 --unwinding-assertions $(CBMC_CHECKS) || exit 1; \
		done; \
		for p in $(CBMC_PROOFS_DEEP); do \
			echo "cbmc: $$p (--unwind $(CBMC_DEEP_UNWIND))"; \
			$(CBMC) test/formal/test_cbmc.c $(PURE_HOST_SRC) -Itest $(CBMC_DEFS) \
				--function $$p --unwind $(CBMC_DEEP_UNWIND) --unwinding-assertions $(CBMC_CHECKS) || exit 1; \
		done; \
		echo "=== CBMC: all debounce-core proofs SUCCESSFUL ==="; \
	else \
		echo "cbmc not installed; the exhaustive 'test-model-check' and 'test-symbolic'"; \
		echo "targets cover the same properties. Install cbmc (apt-get install cbmc) to"; \
		echo "enable SAT/SMT proof of the real bypass_pure.c source."; \
	fi

# Fuse-byte verification: decode the EXACT lfuse/hfuse bytes this Makefile will
# burn (LFUSE/HFUSE for t13a, LFUSE_X5/HFUSE_X5 for the tinyx5 family) and assert
# they match the documented design intent (clock, BOD 4.3V, ISP/RESET preserved,
# etc). Catches a wrong fuse before it reaches silicon -- invisible to every
# other test. The tinyx5 fuse bytes are identical across ATtiny25/45/85, so the
# checker's T85_* bytes cover the whole family.
test-fuses: test/avr/test_fuses
	./test/avr/test_fuses

# Build rule for the fuse checker. Fuse byte values are injected from the
# Makefile variables (single source of truth) via -D. Depends on the Makefile
# so that editing a fuse byte forces a rebuild (the values live in the recipe,
# not in a tracked source file).
test/avr/test_fuses: test/avr/test_fuses.c Makefile
	$(HOSTCC) $(HOST_CFLAGS) $(SANITIZE) \
		-DT13_LFUSE=$(LFUSE) -DT13_HFUSE=$(HFUSE) \
		-DT85_LFUSE=$(LFUSE_X5) -DT85_HFUSE=$(HFUSE_X5) \
		$< -o $@

# Static stack-frame bound via -fstack-usage: compile every firmware TU with
# the flag, collect the per-function .su files, and fail if any single frame
# exceeds STACK_MAX_FRAME bytes.  Complements the runtime HWM test (test-sim)
# with a compile-time structural upper bound that does not depend on exercising
# the deepest call path.  Override: make test-stack-bound STACK_MAX_FRAME=16
test-stack-bound:
	@echo "=== -fstack-usage static bound (limit: $(STACK_MAX_FRAME) B/frame) ==="
	@fail=0; \
	for f in $(FW_SOURCES); do \
		case $$f in \
			*cd4053_with_mute*) m=CD4053_WITH_MUTE ;; \
			*tq2_l2_5v_relay*)  m=TQ2_L2_5V_RELAY ;; \
			*)                  m=$(macro_$(VARIANT)) ;; \
		esac; \
		$(CC) $(CFLAGS) -D$$m -fstack-usage \
			-c $$f -o test/stack_$$(basename $$f .c)_$$m.o || fail=1; \
	done; \
	if [ "$$fail" -ne 0 ]; then \
		echo "FAIL: compilation error(s) during -fstack-usage build"; \
		rm -f test/stack_*.o test/stack_*.su; \
		exit 1; \
	fi; \
	echo "Per-function stack frames:"; \
	cat test/stack_*.su; \
	bad=$$(awk -F'\t' -v max=$(STACK_MAX_FRAME) '$$2+0 > max { print }' test/stack_*.su); \
	if [ -n "$$bad" ]; then \
		echo "FAIL: frame(s) exceed $(STACK_MAX_FRAME) B:"; \
		echo "$$bad"; \
		fail=1; \
	else \
		echo "OK: all frames <= $(STACK_MAX_FRAME) B"; \
	fi; \
	rm -f test/stack_*.o test/stack_*.su; \
	exit $$fail

# Flash-utilization budget assertion: run avr-size on every ATtiny13a variant
# ELF and fail if flash (Program bytes) exceeds FLASH_T13_BUDGET% of 1024 B.
# Firmware is ~46% today; a future accidental bloat would otherwise pass
# silently.  Override: make test-flash-budget FLASH_T13_BUDGET=80
test-flash-budget: $(ALL_ELF13)
	@echo "=== flash-utilization budget (ATtiny13a: $(FLASH_T13_BUDGET)% of 1024 B) ==="
	@limit=$$(( 1024 * $(FLASH_T13_BUDGET) / 100 )); \
	fail=0; \
	for elf in $(ALL_ELF13); do \
		used=$$($(SIZE) --mcu=$(MCU) -C $$elf | awk '/^Program:/ {print $$2; exit}'); \
		if [ -z "$$used" ]; then \
			echo "WARN: could not read flash size from $$elf"; continue; \
		fi; \
		pct=$$(awk -v u="$$used" 'BEGIN {printf "%.1f", u*100/1024}'); \
		if [ "$$used" -gt "$$limit" ]; then \
			echo "FAIL: $$elf uses $$used B ($${pct}%) -- exceeds $$limit B ($(FLASH_T13_BUDGET)%)"; \
			fail=1; \
		else \
			echo "OK:   $$elf uses $$used B ($${pct}%) of 1024 B"; \
		fi; \
	done; \
	exit $$fail

# simavr integration tests: run the REAL compiled firmware .elf in the
# instruction-accurate simulator, drive PB0, and assert LED + control-output
# behavior. One binary per (variant x MCU): the same harness compiled with the
# variant's -D selector (so it expects that variant's control output) and the
# MCU's parameters. tinyx5 builds add -DTARGET_TINYX5 to enable the
# WDT-reset-aware paths simavr can model for that family.
#
# Generated rules:
#   test/avr/test_sim_<v>         ATtiny13a   -> run via test-sim-<v>
#   test/avr/test_sim_<v>_t<n>    tinyx5 chip -> run via test-sim-<v>-t<n>
#   test/avr/test_trace_<v>       VCD waveform builder (-DTRACE, ATtiny13a)
SIM_DEPS = test/avr/test_sim.c test/model_step.h test/bypass_config_host.h \
           test/bypass_output_host.h src/bypass_config.h $(FW_HEADERS) $(PURE_HOST_DEP)

# $(call VARIANT_SIM_T13,variant)
define VARIANT_SIM_T13
test/avr/test_sim_$(1): $$(SIM_DEPS) $(AVR_FW)_$(1).elf
	$$(HOSTCC) $$(SIM_CFLAGS) $$(SIM_DEFS) $$(PURE_HOST_CFLAGS) -D$$(macro_$(1)) $$(extra_$(1)) -Itest \
		-DFW_PATH=\"$(AVR_FW)_$(1).elf\" \
		test/avr/test_sim.c $$(PURE_HOST_SRC) -o $$@ $$(SIM_LIBS)

test/avr/test_trace_$(1): $$(SIM_DEPS) $(AVR_FW)_$(1).elf
	$$(HOSTCC) $$(SIM_CFLAGS) $$(SIM_DEFS) $$(PURE_HOST_CFLAGS) -D$$(macro_$(1)) $$(extra_$(1)) -DTRACE -Itest \
		-DFW_PATH=\"$(AVR_FW)_$(1).elf\" \
		-DTRACE_VCD_PATH=\"$(AVR_BUILD_DIR)/bypass_trace.vcd\" \
		test/avr/test_sim.c $$(PURE_HOST_SRC) -o $$@ $$(SIM_LIBS)

.PHONY: test-sim-$(1)
test-sim-$(1): test/avr/test_sim_$(1)
	@echo "--- sim (ATtiny13a) variant: $(1) ---"
	./test/avr/test_sim_$(1)
endef
$(foreach v,$(VARIANTS),$(eval $(call VARIANT_SIM_T13,$(v))))

# $(call VARIANT_SIM_X5,variant,chip-number)
define VARIANT_SIM_X5
test/avr/test_sim_$(1)_t$(2): $$(SIM_DEPS) $(AVR_FW)_$(1)_t$(2).elf
	$$(HOSTCC) $$(SIM_CFLAGS) $$(SIM_DEFS) $$(PURE_HOST_CFLAGS) -D$$(macro_$(1)) $$(extra_$(1)) -Itest \
		-DFW_PATH=\"$(AVR_FW)_$(1)_t$(2).elf\" \
		-DMCU_NAME=\"$$(mmcu_$(2))\" \
		-DF_CPU_HZ=$$(F_CPU_X5) \
		-DTARGET_TINYX5 \
		test/avr/test_sim.c $$(PURE_HOST_SRC) -o $$@ $$(SIM_LIBS)

.PHONY: test-sim-$(1)-t$(2) test-fault-inject-$(1)-t$(2)
test-sim-$(1)-t$(2): test/avr/test_sim_$(1)_t$(2)
	@echo "--- sim (ATtiny$(2)) variant: $(1) ---"
	./test/avr/test_sim_$(1)_t$(2)
test-fault-inject-$(1)-t$(2): test/avr/test_sim_$(1)_t$(2)
	@echo "--- fault-injection (ATtiny$(2)) variant: $(1) ---"
	./test/avr/test_sim_$(1)_t$(2) fault-inject
endef
$(foreach v,$(VARIANTS),$(foreach n,$(TINYX5),$(eval $(call VARIANT_SIM_X5,$(v),$(n)))))

# Aggregate run targets.
# test-sim          : all variants on ATtiny13a
# test-sim-t<n>     : all variants on tinyx5 chip <n> (e.g. test-sim-t85)
# test-sim-secondary: all variants on every tinyx5 chip
# test-fault-inject : all variants x every tinyx5 chip
test-sim: $(foreach v,$(VARIANTS),test-sim-$(v))
$(foreach n,$(TINYX5),$(eval test-sim-t$(n): $(foreach v,$(VARIANTS),test-sim-$(v)-t$(n))))
test-sim-secondary: $(foreach n,$(TINYX5),test-sim-t$(n))
test-fault-inject: $(foreach v,$(VARIANTS),$(foreach n,$(TINYX5),test-fault-inject-$(v)-t$(n)))
.PHONY: test-sim test-sim-secondary test-fault-inject \
        $(foreach n,$(TINYX5),test-sim-t$(n))

# Mutation testing: inject deliberate faults into the PRODUCTION sources
# (bypass_mcu_avr_classic.c + the variant driver / bypass_config.h), rebuild, and confirm a
# fast test target DETECTS each one (the mutant is "killed"). A surviving mutant
# marks a gap in the suite. Operates on throwaway copies; never touches the real
# sources. Not part of `make test` (it rebuilds the firmware per mutant);
# included in `test-long` and runnable standalone.
test-mutation:
	./test/run_mutation_tests.sh

# Long-duration soak test.
#
# Drives random input for SOAK_DURATION_MS of simulated time (default 24 h).
# Checks WDT liveness (no unexpected resets) and device responsiveness (a
# 2-press round-trip every SOAK_LIVENESS_INTERVAL_MS).  Unlike test_sim.c,
# failures are NEVER fatal: each anomaly is logged and the run continues so
# the full duration is exercised even after an early failure.
#
# Intentionally NOT part of `make test` or `make test-long` -- run standalone
# before hardware signoff or as a pre-release gate.
#
# Overrides (command line):
#   SOAK_VARIANT=relay        variant to test (cd4053[_tmux]/mute[_tmux]/relay; default cd4053)
#   SOAK_CHIP=45              tinyx5 chip number (85/45; default 85)
#   SOAK_DURATION_MS=3600000  simulated duration in ms (default 86400000 = 24 h)
#   SOAK_LIVENESS_INTERVAL_MS=10000   liveness-check interval (default 60000 ms)
SOAK_VARIANT     ?= cd4053
SOAK_CHIP        ?= 85
SOAK_DURATION_MS ?= 86400000
SOAK_BIN  = test/avr/test_soak_$(SOAK_VARIANT)_t$(SOAK_CHIP)
SOAK_DEPS = test/avr/test_soak.c test/bypass_output_host.h test/bypass_config_host.h \
            src/bypass_config.h $(FW_HEADERS)

# The SOAK_* variables (-DSOAK_DURATION_MS, -DSOAK_LIVENESS_INTERVAL_MS, etc.)
# are baked into the binary at compile time. To ensure command-line overrides
# (e.g. `make test-soak SOAK_DURATION_MS=3600000`) are always picked up, the
# test-soak recipe is phony and always recompiles before running.
SOAK_LIVENESS_INTERVAL_MS  ?= 60000
SOAK_PROGRESS_INTERVAL_MS  ?= 3600000
SOAK_COMPILE = $(HOSTCC) $(SIM_CFLAGS) $(PURE_HOST_CFLAGS) \
	-D$(macro_$(SOAK_VARIANT)) $(extra_$(SOAK_VARIANT)) \
	-Itest \
	-DFW_PATH=\"$(AVR_FW)_$(SOAK_VARIANT)_t$(SOAK_CHIP).elf\" \
	-DMCU_NAME=\"$(mmcu_$(SOAK_CHIP))\" \
	-DF_CPU_HZ=$(F_CPU_X5) \
	-DTARGET_TINYX5 \
	-DSOAK_DURATION_MS=$(SOAK_DURATION_MS) \
	-DSOAK_LIVENESS_INTERVAL_MS=$(SOAK_LIVENESS_INTERVAL_MS) \
	-DSOAK_PROGRESS_INTERVAL_MS=$(SOAK_PROGRESS_INTERVAL_MS) \
	test/avr/test_soak.c -o $(SOAK_BIN) $(SIM_LIBS)

# Optional build-only convenience: build without running (Make's normal
# dependency tracking applies; won't rebuild on SOAK_DURATION_MS change alone).
$(SOAK_BIN): $(SOAK_DEPS) $(AVR_FW)_$(SOAK_VARIANT)_t$(SOAK_CHIP).elf
	$(SOAK_COMPILE)

# Run target: always recompiles (phony) so every SOAK_* override is applied.
test-soak: $(SOAK_DEPS) $(AVR_FW)_$(SOAK_VARIANT)_t$(SOAK_CHIP).elf
	$(SOAK_COMPILE)
	@echo "--- soak test: variant=$(SOAK_VARIANT)  MCU=ATtiny$(SOAK_CHIP)  duration=$(SOAK_DURATION_MS) ms ---"
	./$(SOAK_BIN)

# Generate a GTKWave-viewable waveform of PB0/PB1/PB2/PB3 over a representative
# press/release sequence for the selected VARIANT. Writes
# $(AVR_BUILD_DIR)/bypass_trace.vcd.
trace: test/avr/test_trace_$(VARIANT)
	./test/avr/test_trace_$(VARIANT)
	@echo "View with: gtkwave $(AVR_BUILD_DIR)/bypass_trace.vcd"

# ============================================================================
# STATIC ANALYSIS & COVERAGE
# ============================================================================

# Static analysis of the firmware. Runs THREE independent analyzers and gates
# the build on any finding:
#   - clang-tidy   : lint + bug-pattern checks (ANALYZE_CMD)
#   - cppcheck     : second-opinion static analyzer (analyze-cppcheck)
#   - clang --analyze : deep symbolic-execution path analysis (analyze-deep),
#                       the stand-in for `gcc -fanalyzer` since the installed
#                       avr-gcc (7.3) predates it.
#   - cppcheck misra : MISRA-C:2012 compliance gate (analyze-misra), clean
#                      except for the documented deviations in MISRA_COMPLIANCE.md
# -Wconversion is already enforced by the normal build (CFLAGS); these targets
# focus on deeper flow/lint analysis.
analyze: analyze-tidy analyze-cppcheck analyze-deep analyze-misra
	@echo "=== static analysis (clang-tidy + cppcheck + clang-analyzer + MISRA) clean ==="

# clang-tidy (or whatever ANALYZE_CMD points at). Falls back to avr-gcc
# -fanalyzer if a NEWER avr-gcc that supports it is ever installed; otherwise
# errors with guidance.
analyze-tidy: $(FW_SOURCES) $(FW_HEADERS)
	@cmd=$(word 1,$(ANALYZE_CMD)); \
	if command -v $$cmd >/dev/null 2>&1; then \
		for f in $(FW_SOURCES); do \
			echo "clang-tidy: $$cmd $$f"; \
			$(ANALYZE_CMD) $$f -- $(CLANG_TIDY_FLAGS) || exit 1; \
		done; \
	elif $(CC) -fsyntax-only -fanalyzer -xc /dev/null >/dev/null 2>&1; then \
		echo "avr-gcc -fanalyzer"; \
		for f in $(FW_SOURCES); do \
			$(CC) $(CFLAGS) -fanalyzer -c $$f -o $(FW_BASE).analyze.o || exit 1; \
		done; \
		rm -f $(FW_BASE).analyze.o; \
	else \
		echo "No clang-tidy and avr-gcc lacks -fanalyzer. Install clang-tidy or set ANALYZE_CMD=..."; \
		exit 1; \
	fi

# cppcheck second-opinion analyzer (gates via --error-exitcode=2).
analyze-cppcheck: $(FW_SOURCES) $(FW_HEADERS)
	@if command -v $(CPPCHECK) >/dev/null 2>&1; then \
		echo "cppcheck: $(CPPCHECK)"; \
		$(CPPCHECK) $(CPPCHECK_FLAGS) $(FW_SOURCES); \
	else \
		echo "cppcheck not installed; skipping (install cppcheck to enable)"; \
	fi

# Deep path analysis via the clang static analyzer on the AVR target. Emits
# diagnostics as text and FAILS the build on any report (-Werror). This is the
# `-fanalyzer`-equivalent gate.
analyze-deep: $(FW_SOURCES) $(FW_HEADERS)
	@if command -v $(CLANG) >/dev/null 2>&1; then \
		for f in $(FW_SOURCES); do \
			echo "clang --analyze (-target avr): $(CLANG) $$f"; \
			$(CLANG) --analyze -Xclang -analyzer-output=text -Werror \
				$(CLANG_AVR_FLAGS) $$f || exit 1; \
		done; \
	elif $(CC) -fsyntax-only -fanalyzer -xc /dev/null >/dev/null 2>&1; then \
		echo "clang unavailable; using avr-gcc -fanalyzer"; \
		for f in $(FW_SOURCES); do \
			$(CC) $(CFLAGS) -fanalyzer -c $$f -o $(FW_BASE).analyze.o || exit 1; \
		done; \
		rm -f $(FW_BASE).analyze.o; \
	else \
		echo "No deep analyzer available (need clang or avr-gcc>=10 with -fanalyzer)."; \
		exit 1; \
	fi

# MISRA-C:2012 compliance analysis (cppcheck misra addon). Runs over every
# firmware TU, each under a representative variant -D: the core and the
# CD4053-simple driver under the default VARIANT's macro, the mute and relay
# drivers under their own. Findings are rule-labeled via test/misra_rules.txt;
# avr-libc/avr-gcc system-header findings are excluded (compliance boundary).
#
# GATING: fails the build on any finding NOT covered by a documented deviation
# in test/misra_suppressions.txt (each justified in MISRA_COMPLIANCE.md). The
# --suppressions-list waives those; --error-exitcode=2 makes cppcheck exit
# non-zero on anything left. Part of `analyze` -> `make test`.
.PHONY: analyze-misra
analyze-misra: $(FW_SOURCES) $(FW_HEADERS) $(MISRA_ADDON) $(MISRA_RULES) $(MISRA_SUPPRESS)
	@if ! command -v $(CPPCHECK) >/dev/null 2>&1; then \
		echo "cppcheck not installed; skipping MISRA analysis"; exit 0; \
	fi; \
	if ! command -v python3 >/dev/null 2>&1; then \
		echo "python3 not found (required by the cppcheck misra addon); skipping"; exit 0; \
	fi; \
	echo "MISRA-C:2012 analysis ($(CPPCHECK) + misra addon)"; \
	rc=0; out=`mktemp`; \
	for f in $(FW_SOURCES); do \
		case $$f in \
			*cd4053_with_mute*) m=CD4053_WITH_MUTE ;; \
			*tq2_l2_5v_relay*)  m=TQ2_L2_5V_RELAY ;; \
			*)                  m=$(macro_$(VARIANT)) ;; \
		esac; \
		PYTHONWARNINGS=ignore $(CPPCHECK) $(MISRA_CPPCHECK_FLAGS) \
			--suppressions-list=$(MISRA_SUPPRESS) --error-exitcode=2 \
			-D$$m $$f 2>>$$out || rc=1; \
	done; \
	if [ $$rc -ne 0 ]; then \
		echo "MISRA findings NOT covered by a documented deviation:"; \
		grep -E "misra-c2012" $$out || true; \
		echo ""; \
		echo "Fix it, or (if genuinely unavoidable) add a per-file entry to"; \
		echo "$(MISRA_SUPPRESS) with a matching record in MISRA_COMPLIANCE.md."; \
		echo "Run 'make analyze-misra-report' to see the full inventory."; \
		rm -f $$out *.dump *.ctu-info cppcheck-addon-ctu-file-list*; \
		exit 1; \
	fi; \
	rm -f $$out *.dump *.ctu-info cppcheck-addon-ctu-file-list*; \
	echo "MISRA-C:2012: clean (documented deviations waived per MISRA_COMPLIANCE.md)"

# Report-only companion to analyze-misra: shows the FULL inventory, INCLUDING
# the waived deviations (it omits --suppressions-list). Never fails the build.
# Use it when reviewing or maintaining MISRA_COMPLIANCE.md.
.PHONY: analyze-misra-report
analyze-misra-report: $(FW_SOURCES) $(FW_HEADERS) $(MISRA_ADDON) $(MISRA_RULES)
	@if ! command -v $(CPPCHECK) >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then \
		echo "cppcheck and/or python3 not available; skipping MISRA report"; exit 0; \
	fi; \
	echo "MISRA-C:2012 full inventory (report-only, includes waived deviations)"; \
	out=`mktemp`; \
	for f in $(FW_SOURCES); do \
		case $$f in \
			*cd4053_with_mute*) m=CD4053_WITH_MUTE ;; \
			*tq2_l2_5v_relay*)  m=TQ2_L2_5V_RELAY ;; \
			*)                  m=$(macro_$(VARIANT)) ;; \
		esac; \
		echo "  --- $$f  (-D$$m) ---"; \
		PYTHONWARNINGS=ignore $(CPPCHECK) $(MISRA_CPPCHECK_FLAGS) -D$$m $$f 2>&1 \
			| grep -E "misra-c2012" | tee -a $$out || true; \
	done; \
	echo "--- summary: findings per rule ---"; \
	grep -oE "misra-c2012-[0-9.]+" $$out | sort | uniq -c | sort -rn || true; \
	echo "--- total: `grep -cE misra-c2012 $$out` (all waived per MISRA_COMPLIANCE.md unless noted) ---"; \
	rm -f $$out *.dump *.ctu-info cppcheck-addon-ctu-file-list*

# Where coverage artifacts are written.
COVERAGE_DIR = coverage
# Minimum acceptable golden-model line-coverage percentage (the gate threshold).
COVERAGE_MIN ?= 90

# Human-readable coverage report of the golden model (line + branch via gcov).
# Use this when you want to SEE coverage; use coverage-check to ENFORCE it.
coverage:
	@mkdir -p $(COVERAGE_DIR)
	$(HOSTCC) $(HOST_CFLAGS) $(HOST_DEFS) -Itest --coverage test/host/test_logic_host.c -o $(COVERAGE_DIR)/test_logic_host
	cd $(COVERAGE_DIR) && ./test_logic_host
	cd $(COVERAGE_DIR) && gcov -b test_logic_host.c 2>/dev/null || true
	@echo "Coverage report: $(COVERAGE_DIR)/test_logic_host.c.gcov"
	@echo "For HTML report: lcov --capture -d $(COVERAGE_DIR) -o $(COVERAGE_DIR)/coverage.info && genhtml $(COVERAGE_DIR)/coverage.info -o $(COVERAGE_DIR)/html"

# Coverage GATE (wired into `make test`): build the model with coverage, run it,
# and FAIL the build if golden-model line coverage drops below COVERAGE_MIN.
coverage-check:
	@mkdir -p $(COVERAGE_DIR)
	@$(HOSTCC) $(HOST_CFLAGS) $(HOST_DEFS) -Itest --coverage \
		test/host/test_logic_host.c -o $(COVERAGE_DIR)/test_logic_host_cov
	@cd $(COVERAGE_DIR) && ./test_logic_host_cov >/dev/null
	@cd $(COVERAGE_DIR) && gcov test_logic_host_cov-test_logic_host.c >/dev/null 2>&1 \
		|| gcov test_logic_host.c >/dev/null 2>&1 || true
	@pct=$$(cd $(COVERAGE_DIR) && gcov test_logic_host_cov-test_logic_host.c 2>/dev/null \
		| awk -F'[:%]' '/Lines executed/ {print $$2; exit}'); \
	if [ -z "$$pct" ]; then \
		pct=$$(cd $(COVERAGE_DIR) && gcov -o . test_logic_host_cov 2>/dev/null \
			| awk -F'[:%]' '/Lines executed/ {print $$2; exit}'); \
	fi; \
	echo "golden-model line coverage: $${pct:-unknown}% (floor $(COVERAGE_MIN)%)"; \
	if [ -z "$$pct" ]; then \
		echo "WARNING: could not determine coverage (gcov output parse failed); not gating."; \
	else \
		awk -v p="$$pct" -v m="$(COVERAGE_MIN)" 'BEGIN { exit !(p+0 >= m+0) }' \
			|| { echo "FAIL: coverage $$pct% below floor $(COVERAGE_MIN)%"; exit 1; }; \
	fi

# Remove coverage artifacts (the coverage/ dir and any stray gcov data files).
coverage-clean:
	rm -rf $(COVERAGE_DIR)
	find . -name '*.gcda' -o -name '*.gcno' | xargs rm -f

# ============================================================================
# INTROSPECTION -- expose one Makefile variable's value to scripts
# ============================================================================
# `make print-VARIANTS` echoes "$(VARIANTS)", `make print-LFUSE` echoes the fuse
# byte, `make print-PIC_CC` echoes the XC8 path, and so on. scripts/make-release.sh
# reads the release manifest's variant list, fuse bytes, device names and build
# directories through this target so they come from THIS Makefile (the single
# source of truth) rather than a hand-maintained copy that could silently drift.
print-%:
	@echo '$($*)'

# ============================================================================
# RELEASE -- reproducible, fully-validated prebuilt firmware images
# ============================================================================
# Thin wrapper around scripts/make-release.sh. The script is a deliberate,
# long-running (~24 h, because of the parallel 24-h soaks) pre-tag gate that:
#   1. refuses to run unless the working tree is clean and EVERY required tool
#      is present (the inverse of the dev-time "skip cleanly" behaviour -- a
#      release must never green-light on a tool that silently did nothing);
#   2. clean-builds all AVR + PIC variant images;
#   3. runs `make test-long` + `make pic-test` and ALL soak combos in parallel;
#   4. stages release/<VERSION>/ with the .hex images, SHA256SUMS, a provenance
#      MANIFEST (toolchain versions, per-image fuse bytes / CONFIG word, flashing
#      command, soak evidence) and a README;
#   5. STOPS and prints the exact `git add` / `git commit` / `git tag -s` and
#      checksum-signing commands for you to run by hand (it never commits or tags).
# The pushed tag then triggers .github/workflows/release.yml, which rebuilds from
# the tag on a clean runner, verifies the committed image hashes reproduce
# bit-for-bit, and publishes the GitHub Release.
#
#   make release VERSION=v1.0.0
#   make release VERSION=v1.0.0 RELEASE_ARGS='--dry-run'   # skip the 24-h soak
.PHONY: release
release:
	@if [ -z "$(VERSION)" ]; then \
		echo "usage: make release VERSION=vX.Y.Z [RELEASE_ARGS='--dry-run']"; \
		exit 2; \
	fi
	./scripts/make-release.sh $(RELEASE_ARGS) $(VERSION)

# ============================================================================
# HELP
# ============================================================================

# One-line summary of the most useful targets.
help:
	@echo "Variants: $(VARIANTS)  (select with VARIANT=<name>; default $(VARIANT))"
	@echo "MCUs: ATtiny13a (primary) + tinyx5 family t$(TINYX5)"
	@echo "Build:"
	@echo "  all (default)   build ALL ATtiny13a variant firmwares (.hex) + sizes"
	@echo "  all13           build all variant firmwares for ATtiny13a"
	@echo "  all85 / all45   build all variant firmwares for ATtiny85 / ATtiny45"
	@echo "  size            print flash/RAM usage for every ATtiny13a variant"
	@echo "  size85 / size45 print flash/RAM usage for every tinyx5 variant"
	@echo "  pic             build all variants for PIC10F322 (XC8) + 512-word budget gate"
	@echo "  pic-test        all PIC pre-hardware checks (CONFIG word + analyze + gpsim)"
	@echo "  pic-test-config build PIC HEX, then verify each CONFIG word vs design intent"
	@echo "  pic-analyze     cppcheck + MISRA on the PIC shell (XC8/DFP headers; standalone)"
	@echo "  pic-test-gpsim  drive the footswitch in gpsim, assert PORTA/LATA toggle"
	@echo "  pic-test-soak   libgpsim soak: WDT liveness + responsiveness (standalone; needs"
	@echo "                  gpsim-dev+libglib2.0-dev; PIC_SOAK_VARIANT, PIC_SOAK_DURATION_MS)"
	@echo "  program-pic     flash one PIC variant to hardware (VARIANT=, PIC_PROG=pk2cmd|ipecmd)"
	@echo "Test (each runs across ALL variants):"
	@echo "  test            FAST full suite -- analyze, model, sim (all MCUs), coverage"
	@echo "  test-long       FULL exhaustive suite (minutes); alias: stress"
	@echo "  scripts/ci-local.sh  reproduce the GitHub CI suite locally before pushing (--pr, --help)"
	@echo "  test-host       golden-model algorithm tests (host, variant-agnostic)"
	@echo "  test-model-check exhaustive state-space proof of invariants"
	@echo "  test-symbolic   exhaustive single-step property proof of step()"
	@echo "  test-symbolic-klee  same properties under KLEE (if installed)"
	@echo "  test-cbmc       CBMC SAT/SMT proof of the real bypass_pure.c (if installed)"
	@echo "  test-fuses      decode + verify the design fuse bytes (t13a + tinyx5)"
	@echo "  test-stack-bound  -fstack-usage static frame bound (limit: STACK_MAX_FRAME=$(STACK_MAX_FRAME) B)"
	@echo "  test-flash-budget flash-utilization gate: all t13a variants < FLASH_T13_BUDGET=$(FLASH_T13_BUDGET)% of 1 KB"
	@echo "  test-sim        real firmware in simavr, all variants (ATtiny13a)"
	@echo "  test-sim-t85 / test-sim-t45  all variants on that tinyx5 chip"
	@echo "  test-sim-secondary  all variants on every tinyx5 chip"
	@echo "  test-sim-<v>[-t<n>]  single variant, e.g. test-sim-relay / test-sim-relay-t45"
	@echo "  test-fault-inject  corrupt state, verify WDT recovery (all variants x tinyx5)"
	@echo "  test-mutation   inject firmware faults, verify the suite kills them"
	@echo "  test-soak       24-h soak test (standalone; SOAK_VARIANT, SOAK_CHIP, SOAK_DURATION_MS,"
	@echo "                  SOAK_LIVENESS_INTERVAL_MS, SOAK_PROGRESS_INTERVAL_MS)"
	@echo "  trace           emit $(AVR_BUILD_DIR)/bypass_trace.vcd for VARIANT (GTKWave)"
	@echo "Analysis:"
	@echo "  analyze         static analysis of core + all drivers (3 analyzers)"
	@echo "  analyze-tidy / analyze-cppcheck / analyze-deep  individual analyzers"
	@echo "  analyze-misra   MISRA-C:2012 gate (cppcheck misra addon; see MISRA_COMPLIANCE.md)"
	@echo "  analyze-misra-report  full MISRA inventory incl. waived deviations (report-only)"
	@echo "  coverage        human-readable golden-model coverage report"
	@echo "  coverage-check  fail if coverage < COVERAGE_MIN ($(COVERAGE_MIN)%)"
	@echo "Hardware (act on VARIANT=$(VARIANT); <n> in {$(TINYX5)} for tinyx5):"
	@echo "  readfuses       print current fuse bytes (read-only)"
	@echo "  fuses / fuses<n>   write design fuse bytes (t13a / tinyx5)"
	@echo "  flash / flash<n>   flash the selected variant's firmware"
	@echo "  program / program<n>  fuses + flash (fresh chip)"
	@echo "Release:"
	@echo "  release         VERSION=vX.Y.Z: build+validate (incl. 24-h soak) + stage release/<ver>/"
	@echo "                  (RELEASE_ARGS='--dry-run' skips the soak; see scripts/make-release.sh)"
	@echo "Clean:"
	@echo "  clean           remove build + test artifacts"
	@echo "  clean-tests     remove only test binaries"
	@echo "  coverage-clean  remove coverage artifacts"
	@echo "Overrides: VARIANT=, PROGRAMMER=, COVERAGE_MIN=, HOSTCC=, HOST_DEFS=, SIM_DEFS=, AVR_BUILD_DIR="
	@echo "PIC overrides: PIC_CC=, PIC_PROG=pk2cmd|ipecmd, PIC_PROG_TOOL=PK3|PK4|PK5, PIC_PROG_CMD="


# vim: tw=0 nowrap
