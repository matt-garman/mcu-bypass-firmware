################################################################################
# bypass -- build / test / flash Makefile
################################################################################
#
# WHAT THIS BUILDS
#   A hardware-agnostic core (bypass_mcu_avr_classic.c) plus one interchangeable
#   output driver, selected at build time:
#     - cd4053      : CD4053 analog switch, single control line (CD4053_SIMPLE)
#     - mute        : CD4053 with mute-before-switch (CD4053_WITH_MUTE)
#     - relay       : Panasonic TQ2-L2-5V latching relay, pulsed coils (TQ2_L2_5V_RELAY)
#   The cd4053/mute images drive a single MCU polarity (bypass = pin low, the
#   natural/MCU-absent state) that serves BOTH the CD4053-with-MOSFET-inverter
#   board and the TMUX4053 direct-drive board: the CD4053's inverter and the
#   TMUX's swapped analog throws cancel, so one image fits both (see the CD4053
#   vs TMUX4053 wiring schemes in DESIGN_DOCUMENTATION.adoc). No separate _tmux
#   firmware is needed.
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
# Firmware and workload-dependent test binaries rebuild once per requested Make
# graph, so current command-line flags and toolchain bytes are always consumed.
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
# READELF : ELF architecture inspector
# AVRDUDE : ISP flashing tool
MCU      = attiny13a
F_CPU    = 1200000UL
FW_BASE  = bypass
CC       = avr-gcc
OBJCOPY  = avr-objcopy
SIZE     = avr-size
READELF  ?= readelf
IHEX_VALIDATOR ?= scripts/validate-ihex.sh
AVRDUDE  = avrdude
AVR_ELF_ARCH ?= avr:25

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
VARIANTS = cd4053 mute relay

# variant short name -> firmware -D selector macro
macro_cd4053      = CD4053_SIMPLE
macro_mute        = CD4053_WITH_MUTE
macro_relay       = TQ2_L2_5V_RELAY

# variant short name -> output driver source file
src_cd4053      = src/bypass_output_cd4053_simple.c
src_mute        = src/bypass_output_cd4053_with_mute.c
src_relay       = src/bypass_output_tq2_l2_5v_relay.c

# Headers shared by every firmware build; any change rebuilds all variants.
FW_HEADERS = src/bypass_config.h src/bypass_types.h src/bypass_hw_iface.h \
             src/bypass_pure.h \
             src/bypass_output_common.h src/bypass_pins_avr_classic.h \
             src/bypass_blocking_delay.h src/bypass_static_assert.h \
             src/bypass_compile_checks.h \
             src/bypass_output_cd4053_simple.h src/bypass_output_cd4053_with_mute.h \
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
GCOV        ?= gcov
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
STACK_BUILD_DIR ?=
override STACK_SOURCES := src/bypass_mcu_avr_classic.c src/bypass_pure.c \
                          src/bypass_output_cd4053_simple.c \
                          src/bypass_output_cd4053_with_mute.c \
                          src/bypass_output_tq2_l2_5v_relay.c

# ATtiny13a flash-budget ceiling for test-flash-budget (percentage of 1 KB).
# Firmware is ~46% today; a future accidental bloat passes silently without
# this gate.
FLASH_T13_BUDGET ?= 90
override FLASH_T13_MCU := attiny13a
override FLASH_T13_BYTES := 1024
override FLASH_T13_VARIANTS := cd4053 mute relay
override FLASH_T13_UNKNOWN := $(filter-out $(FLASH_T13_VARIANTS),$(VARIANTS))
override FLASH_T13_ELFS := $(AVR_BUILD_DIR)/bypass_cd4053.elf \
                          $(AVR_BUILD_DIR)/bypass_mute.elf \
                          $(AVR_BUILD_DIR)/bypass_relay.elf
override FLASH_T13_OLD_FILE_ARGS := $(foreach elf,$(FLASH_T13_ELFS),--old-file=$(elf))

# Missing-tool policy for the optional gates (PIC/XC8, gpsim, cppcheck, python3,
# the ATtiny_DFP / yasimavr venv, ...). By default a missing tool prints its
# reason and skips that gate cleanly, so host-only development stays convenient.
# With STRICT_TOOLS=1 the same condition is a HARD FAILURE instead: a green run
# can then never mean "the gate was silently skipped" -- it means every gate
# actually ran. CI and scripts/ci-local.sh install the full toolchain and set
# STRICT_TOOLS=1 so a broken/absent install fails the job rather than passing.
# Every skip guard ends its reason echo with "$(SKIP);" in place of a bare
# exit-0; $(SKIP) resolves to that clean skip, or to a failing exit-1.
STRICT_TOOLS ?=
ifeq ($(strip $(STRICT_TOOLS)),)
  SKIP := exit 0
else
  SKIP := { echo "::error::STRICT_TOOLS=1: the tool/dependency reported above is required and must not be skipped"; exit 1; }
endif

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
#
# Robust avr-libc include discovery, shared by clang-tidy, clang --analyze,
# cppcheck AND the MISRA run. `$(CC) -print-file-name=avr/io.h` returns a BARE
# NAME on this toolchain (avr-libc's headers live outside avr-gcc's own dirs),
# which used to leave this variable as the garbage relative path "avr/": that
# silently degraded analyze-cppcheck (it analyzed without the real register
# headers), while the clang passes survived only via clang's own hardcoded AVR
# search paths. So discover the directory from the preprocessor's ACTUAL search
# path first, and fall back to -print-file-name only if that yields a directory
# that really contains avr/io.h. Result: a verified real path, or empty (the
# $(if ...) guards below then omit the -I and the analyzers fail loudly on the
# missing include rather than parsing garbage).
AVR_IO_HEADER      := $(shell $(CC) -print-file-name=avr/io.h)
AVR_LIBC_INCLUDE   := $(shell echo | $(CC) -xc -E -Wp,-v - 2>&1 | grep -oE '^ /[^ ]+' | tr -d ' ' | while read d; do if [ -f "$$d/avr/io.h" ]; then realpath "$$d" 2>/dev/null || echo "$$d"; break; fi; done)
ifeq ($(AVR_LIBC_INCLUDE),)
AVR_LIBC_INCLUDE   := $(patsubst %/avr/, %, $(dir $(AVR_IO_HEADER)))
# reject a non-path result ("avr/" when -print-file-name found nothing)
ifeq ($(wildcard $(AVR_LIBC_INCLUDE)/avr/io.h),)
AVR_LIBC_INCLUDE   :=
endif
endif
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
# header directly). $(sort) de-duplicates the source set so each driver .c is
# analyzed once.
FW_SOURCES         = $(sort $(CORE_SRC) $(foreach v,$(VARIANTS),$(src_$(v))))

# cppcheck: a second, independent analyzer. Uses the AVR platform model and the
# avr-libc include path so it sees the real register definitions. Findings
# INSIDE the avr-libc / avr-gcc headers are suppressed by path -- adopted
# toolchain code is outside the compliance boundary (same treatment as the
# MISRA run below; e.g. avr-libc's util/delay.h shadows its own __ticks).
CPPCHECK           ?= cppcheck
CPPCHECK_FLAGS     ?= --enable=warning,style,performance,portability \
                      --std=c11 --platform=avr8 --error-exitcode=2 \
                      --inline-suppr \
                      --suppress=missingIncludeSystem \
                      --suppress=unmatchedSuppression \
                      --suppress=unusedStructMember \
                      -D__AVR__ -D__AVR_ATtiny13A__ -DF_CPU=$(F_CPU) \
                      $(if $(AVR_LIBC_INCLUDE),'--suppress=*:$(AVR_LIBC_INCLUDE)/*' -I$(AVR_LIBC_INCLUDE)) \
                      $(if $(AVR_GCC_INCLUDE),'--suppress=*:$(AVR_GCC_INCLUDE)/*' -I$(AVR_GCC_INCLUDE))

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

# The MISRA run shares the robust AVR_LIBC_INCLUDE discovery above (it
# originally had its own preprocessor-search-path discovery, which is now the
# shared implementation). MISRA's value rules (10.x essential type, 11.x
# pointer/integer) are meaningless without the real register headers, hence the
# verified-real-path-or-empty contract.
MISRA_AVR_INCLUDE  := $(AVR_LIBC_INCLUDE)

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
# Internal sequencing override: normal public builds force current tools/flags;
# validated consumer phases set this empty to reuse the ELF they just checked.
AVR_REBUILD_PREREQ ?= FORCE

# Always-out-of-date prerequisite used for artifacts whose effective build
# command includes command-line variables that timestamps cannot represent.
.PHONY: FORCE
FORCE:

# Never retain a target that a failed recipe created or truncated.
.DELETE_ON_ERROR:

# Targets that are commands, not files. Per-chip tinyx5 targets (all85/size85/
# fuses85/flash85/program85, *45, test-sim-t85, ...) are declared .PHONY by the
# templates that generate them.
.PHONY: all all13 clean size readfuses fuses flash program help \
        test test-fast test-long stress \
        test-host test-sim test-sim-secondary \
        test-model-check test-fault-inject test-fuses test-symbolic test-cbmc test-mutation \
        test-attiny202-build test-avr-build-rebuild test-gpsim-wrappers \
        test-pic-build test-release-images \
        test-soak-timing test-workload-rebuild \
        pic-test-target pic-test-target-variants pic-test-io pic-test-lockstep \
        test-stack-bound test-stack-bound-regression test-flash-budget \
        test-flash-budget-regression test-soak \
        analyze analyze-tidy analyze-cppcheck analyze-deep \
        trace coverage coverage-check coverage-clean

# ============================================================================
# BUILD -- firmware matrix (3 variants x {ATtiny13a, tinyx5 family})
# ============================================================================
#
# ELF/HEX rules are generated by templates so adding a variant OR a tinyx5
# sibling needs no new build rules. Each rule links bypass_mcu_avr_classic.c with the
# variant's driver source and selects the variant with its -D macro. ELF targets
# depend on FORCE so every requested graph consumes current flags/tools/headers.
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
$(AVR_FW)_$(1).elf: $$(CORE_SRC) $$(src_$(1)) $$(FW_HEADERS) Makefile $$(AVR_REBUILD_PREREQ) | $$(AVR_BUILD_DIR)
	@hex="$$(AVR_FW)_$(1).hex"; \
	if ! rm -f "$$@" "$$$$hex"; then echo "FAIL: could not remove stale artifact for $$@"; exit 1; fi; \
	tmp=$$$$(mktemp "$$@.tmp.XXXXXX") || exit 1; \
	if ! $$(CC) $$(CFLAGS) -D$$(macro_$(1)) $$(LDFLAGS) -o "$$$$tmp" $$(CORE_SRC) $$(src_$(1)); then \
		rm -f "$$$$tmp"; exit 1; \
	fi; \
	if [ ! -f "$$$$tmp" ] || [ -L "$$$$tmp" ] || [ ! -s "$$$$tmp" ]; then \
		echo "FAIL: compiler produced no regular ELF: $$@"; rm -f "$$$$tmp"; exit 1; \
	fi; \
	if ! $$(READELF) -h "$$$$tmp" 2>/dev/null \
			| grep -Eq 'Machine:[[:space:]]*Atmel AVR 8-bit microcontroller' \
		|| ! $$(READELF) -h "$$$$tmp" 2>/dev/null \
			| grep -Eq 'Flags:.*$$(AVR_ELF_ARCH)([,[:space:]]|$$$$)'; then \
		echo "FAIL: compiler produced an invalid or wrong-architecture ELF: $$@"; \
		rm -f "$$$$tmp"; exit 1; \
	fi; \
	if ! mv "$$$$tmp" "$$@"; then rm -f "$$$$tmp"; exit 1; fi

$(AVR_FW)_$(1).hex: $(AVR_FW)_$(1).elf $$(IHEX_VALIDATOR)
	@if ! rm -f "$$@"; then echo "FAIL: could not remove stale artifact for $$@"; exit 1; fi; \
	tmp=$$$$(mktemp "$$@.tmp.XXXXXX") || exit 1; \
	if ! $$(OBJCOPY) -O ihex -R .eeprom "$$<" "$$$$tmp"; then rm -f "$$$$tmp"; exit 1; fi; \
	if ! $$(IHEX_VALIDATOR) "$$$$tmp"; then \
		echo "FAIL: objcopy produced an invalid HEX: $$@"; rm -f "$$$$tmp"; exit 1; \
	fi; \
	if ! mv "$$$$tmp" "$$@"; then rm -f "$$$$tmp"; exit 1; fi
endef
$(foreach v,$(VARIANTS),$(eval $(call VARIANT_BUILD_T13,$(v))))

# $(call VARIANT_BUILD_X5,variant,chip-number) -- one tinyx5 chip
define VARIANT_BUILD_X5
$(AVR_FW)_$(1)_t$(2).elf: $$(CORE_SRC) $$(src_$(1)) $$(FW_HEADERS) Makefile $$(AVR_REBUILD_PREREQ) | $$(AVR_BUILD_DIR)
	@hex="$$(AVR_FW)_$(1)_t$(2).hex"; \
	if ! rm -f "$$@" "$$$$hex"; then echo "FAIL: could not remove stale artifact for $$@"; exit 1; fi; \
	tmp=$$$$(mktemp "$$@.tmp.XXXXXX") || exit 1; \
	if ! $$(CC) -mmcu=$$(mmcu_$(2)) -DF_CPU=$$(F_CPU_X5) $$(CFLAGS_COMMON) -Wl,--gc-sections \
		-D$$(macro_$(1)) -o "$$$$tmp" $$(CORE_SRC) $$(src_$(1)); then \
		rm -f "$$$$tmp"; exit 1; \
	fi; \
	if [ ! -f "$$$$tmp" ] || [ -L "$$$$tmp" ] || [ ! -s "$$$$tmp" ]; then \
		echo "FAIL: compiler produced no regular ELF: $$@"; rm -f "$$$$tmp"; exit 1; \
	fi; \
	if ! $$(READELF) -h "$$$$tmp" 2>/dev/null \
			| grep -Eq 'Machine:[[:space:]]*Atmel AVR 8-bit microcontroller' \
		|| ! $$(READELF) -h "$$$$tmp" 2>/dev/null \
			| grep -Eq 'Flags:.*$$(AVR_ELF_ARCH)([,[:space:]]|$$$$)'; then \
		echo "FAIL: compiler produced an invalid or wrong-architecture ELF: $$@"; \
		rm -f "$$$$tmp"; exit 1; \
	fi; \
	if ! mv "$$$$tmp" "$$@"; then rm -f "$$$$tmp"; exit 1; fi

$(AVR_FW)_$(1)_t$(2).hex: $(AVR_FW)_$(1)_t$(2).elf $$(IHEX_VALIDATOR)
	@if ! rm -f "$$@"; then echo "FAIL: could not remove stale artifact for $$@"; exit 1; fi; \
	tmp=$$$$(mktemp "$$@.tmp.XXXXXX") || exit 1; \
	if ! $$(OBJCOPY) -O ihex -R .eeprom "$$<" "$$$$tmp"; then rm -f "$$$$tmp"; exit 1; fi; \
	if ! $$(IHEX_VALIDATOR) "$$$$tmp"; then \
		echo "FAIL: objcopy produced an invalid HEX: $$@"; rm -f "$$$$tmp"; exit 1; \
	fi; \
	if ! mv "$$$$tmp" "$$@"; then rm -f "$$$$tmp"; exit 1; fi
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
# BUILD -- PIC10F322 (Microchip XC8) cross-build
# ============================================================================
#
# A SECOND toolchain (XC8 + the PIC10-12Fxxx DFP), entirely separate from the
# AVR build above. The PIC shell (bypass_mcu_pic10f322.c) implements the same
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
PIC_XTAL  ?= 2000000UL
PIC_BUILD_DIR ?= build_pic
PIC_HEXES = $(foreach v,$(VARIANTS),$(PIC_BUILD_DIR)/$(FW_BASE)_$(v)_$(PIC_TAG).hex)
# PIC10F322 device budget: 512 words flash / 64 B RAM.
PIC_FLASH_WORDS ?= 512
# gpsim simulator + processor name for the register-level functional test.
GPSIM         ?= gpsim
PIC_GPSIM_PROC ?= p10f322

# The PIC shell + the unchanged pure core (the AVR counterpart is CORE_SRC =
# bypass_mcu_avr_classic.c + bypass_pure.c).
PIC_CORE_SRC = src/bypass_mcu_pic10f322.c src/bypass_pure.c

# Headers that, if changed, should rebuild the PIC images: the AVR FW_HEADERS
# set with the PIC pin map substituted for the AVR-classic one.
PIC_HEADERS = src/bypass_config.h src/bypass_types.h src/bypass_hw_iface.h \
              src/bypass_output_common.h src/bypass_pins_pic10f322.h \
              src/bypass_blocking_delay.h src/bypass_static_assert.h \
              src/bypass_compile_checks.h \
              src/bypass_output_cd4053_simple.h src/bypass_output_cd4053_with_mute.h \
              src/bypass_output_tq2_l2_5v_relay.h

# XC8 compile flags: select the PIC10F322 + its DFP, C99 (no C11 in XC8), the
# PIC pin map, and _XTAL_FREQ for __delay_ms.
PIC_CFLAGS = -mcpu=$(PIC_CHIP) -mdfp=$(PIC_DFP) -std=c99 -O2 \
             -DBYPASS_MCU_PIC10F322 -D_XTAL_FREQ=$(PIC_XTAL)

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
                        -DBYPASS_MCU_PIC10F322 -U__AVR__ -UBYPASS_MCU_AVR_CLASSIC \
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
	@rm -f $(PIC_HEXES)
	@if [ ! -x "$(PIC_CC)" ] && ! command -v $(PIC_CC) >/dev/null 2>&1; then \
		echo "XC8 not found at $(PIC_CC); skipping PIC build (override with PIC_CC=...)"; \
		$(SKIP); \
	fi; \
	if [ ! -x "$(IHEX_VALIDATOR)" ] && ! command -v $(IHEX_VALIDATOR) >/dev/null 2>&1; then \
		echo "FAIL: Intel HEX validator not found at $(IHEX_VALIDATOR)"; exit 1; \
	fi; \
	mkdir -p $(PIC_BUILD_DIR); \
	pic_complete=0; \
	cleanup_pic_images() { \
		rc=$$?; \
		if [ $$rc -ne 0 ] || [ $$pic_complete -ne 1 ]; then \
			rm -f $(PIC_HEXES) || rc=1; \
			[ $$rc -ne 0 ] || rc=1; \
		fi; \
		trap - 0 1 2 15; exit $$rc; \
	}; \
	trap cleanup_pic_images 0 1 2 15; \
	export PIC_RECIPE_PID=$$$$; \
	if [ "$(words $(strip $(VARIANTS)))" -eq 0 ]; then \
		echo "FAIL: VARIANTS is empty; no PIC images requested"; exit 2; \
	fi; \
	echo "=== PIC10F322 build + flash-budget ($(PIC_FLASH_WORDS) words) ==="; \
	fail=0; \
	for v in $(VARIANTS); do \
		case $$v in \
			*mute)  m=CD4053_WITH_MUTE; drv=src/bypass_output_cd4053_with_mute.c ;; \
			*relay) m=TQ2_L2_5V_RELAY;  drv=src/bypass_output_tq2_l2_5v_relay.c ;; \
			*)      m=CD4053_SIMPLE;    drv=src/bypass_output_cd4053_simple.c ;; \
		esac; \
		name=$(FW_BASE)_$${v}_$(PIC_TAG).hex; \
		hex=$(PIC_BUILD_DIR)/$$name; \
		if ! rm -f "$$hex"; then \
			echo "FAIL: could not remove stale $$hex before compiling"; fail=1; continue; \
		fi; \
		out=`cd $(PIC_BUILD_DIR) && $(PIC_CC) $(PIC_CFLAGS) -D$$m \
			$(addprefix $(CURDIR)/,$(PIC_CORE_SRC)) $(CURDIR)/$$drv \
			-o $$name 2>&1` \
			|| { printf '%s\n' "$$out"; echo "FAIL: variant $$v did not compile for PIC10F322"; rm -f "$$hex"; fail=1; continue; }; \
		if [ ! -s "$$hex" ]; then \
			echo "FAIL: XC8 reported success but did not produce a nonempty $$hex"; \
			printf '%s\n' "$$out"; rm -f "$$hex"; fail=1; continue; \
		fi; \
		if ! $(IHEX_VALIDATOR) "$$hex"; then \
			echo "FAIL: XC8 produced an invalid Intel HEX image for variant $$v"; \
			rm -f "$$hex"; fail=1; continue; \
		fi; \
		dec=`printf '%s\n' "$$out" | grep -E 'Program space' \
			| grep -oE '\( *[0-9]+ *\)' | head -1 | tr -d '() '`; \
		if [ -z "$$dec" ]; then \
			echo "FAIL: $$v: could not parse program-word count from XC8 output:"; \
			printf '%s\n' "$$out"; rm -f "$$hex"; fail=1; continue; \
		fi; \
		pct=`awk -v u=$$dec -v t=$(PIC_FLASH_WORDS) 'BEGIN{printf "%.1f", u*100/t}'`; \
		if [ $$dec -gt $(PIC_FLASH_WORDS) ]; then \
			echo "FAIL: $$v uses $$dec words ($${pct}%) -- exceeds $(PIC_FLASH_WORDS)"; rm -f "$$hex"; fail=1; \
		else \
			echo "OK:   $$v -> $$hex : $$dec words ($${pct}%) of $(PIC_FLASH_WORDS)"; \
		fi; \
	done; \
	[ $$fail -ne 0 ] || pic_complete=1; \
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
		$(SKIP); \
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

pic-analyze-cppcheck: src/bypass_mcu_pic10f322.c $(PIC_HEADERS)
	@if ! command -v $(CPPCHECK) >/dev/null 2>&1; then \
		echo "cppcheck not installed; skipping PIC cppcheck analysis"; $(SKIP); \
	fi; \
	if [ ! -f "$(PIC_XC8_INCLUDE)/xc.h" ] || [ ! -f "$(PIC_DFP_INCLUDE)/proc/pic10f322.h" ]; then \
		echo "XC8/DFP headers not found; skipping PIC cppcheck analysis"; $(SKIP); \
	fi; \
	echo "cppcheck (PIC, pic8-enhanced): $(CPPCHECK) src/bypass_mcu_pic10f322.c"; \
	$(CPPCHECK) $(PIC_CPPCHECK_FLAGS) src/bypass_mcu_pic10f322.c

pic-analyze-misra: src/bypass_mcu_pic10f322.c $(PIC_HEADERS) $(MISRA_ADDON) $(MISRA_RULES) $(MISRA_SUPPRESS)
	@if ! command -v $(CPPCHECK) >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then \
		echo "cppcheck and/or python3 not available; skipping PIC MISRA analysis"; $(SKIP); \
	fi; \
	if [ ! -f "$(PIC_XC8_INCLUDE)/xc.h" ] || [ ! -f "$(PIC_DFP_INCLUDE)/proc/pic10f322.h" ]; then \
		echo "XC8/DFP headers not found; skipping PIC MISRA analysis"; $(SKIP); \
	fi; \
	echo "MISRA-C:2012 analysis -- PIC shell ($(CPPCHECK) + misra addon, pic8-enhanced)"; \
	out=`mktemp`; rc=0; \
	PYTHONWARNINGS=ignore $(CPPCHECK) $(PIC_MISRA_CPPCHECK_FLAGS) \
		--suppressions-list=$(MISRA_SUPPRESS) --error-exitcode=2 \
		src/bypass_mcu_pic10f322.c 2>>$$out || rc=1; \
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
# the expected ENGAGED full-LATA pattern is passed per variant (el): the
# analog-switch variants drive the control pins HIGH when engaged (cd4053=0x3,
# mute=0x7); the relay parks its coils low at the settled checkpoint, leaving
# only the LED bit set (el=0x1).
#
# A second scenario (test/pic/power_on_pressed.stc, via
# run_gpsim_power_on_pressed.sh) covers the startup branch the toggle scenario
# never hits: the footswitch HELD at power-on must come up BYPASS and must NOT
# engage until a genuine release + fresh press. Both run per variant. Depends on
# `pic` to build the HEX; skips cleanly when gpsim or the HEX is absent.
.PHONY: pic-test-gpsim
pic-test-gpsim: pic
	@if ! command -v $(GPSIM) >/dev/null 2>&1; then \
		echo "gpsim not installed; skipping PIC gpsim register-level test"; $(SKIP); \
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

# Host-gcov gate over the real PIC shipping source set: the PIC shell, shared
# pure core, and all three output drivers. This complements the independent
# golden-model percentage gate and the real-HEX gpsim/libgpsim behavior gates.
.PHONY: pic-coverage-check-fw
pic-coverage-check-fw:
	@HOSTCC="$(HOSTCC)" GCOV="$(GCOV)" COVERAGE_DIR="$(abspath $(COVERAGE_DIR))" \
		test/pic/fw_coverage/run_fw_coverage.sh

# Aggregate: every PIC pre-hardware check (build+budget, CONFIG word, static
# analysis, shipping-source coverage, gpsim functional). Standalone -- NOT part
# of `make test`, which is the AVR pre-hardware gate (XC8/gpsim may be absent in
# CI). Each external-tool sub-target skips cleanly when its tool is missing.
.PHONY: pic-test
pic-test: pic-test-config pic-analyze pic-coverage-check-fw pic-test-gpsim
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
# Overrides: PIC_SOAK_VARIANT (cd4053/mute/relay), PIC_SOAK_DURATION_MS (default
# 1 h; pass 86400000 for 24 h), PIC_SOAK_LIVENESS_INTERVAL_MS, PIC_SOAK_PROGRESS_INTERVAL_MS.
PIC_SOAK_CXX         ?= c++
PIC_SOAK_GPSIM_INC   ?= /usr/include/gpsim
PIC_SOAK_VARIANT     ?= cd4053
PIC_SOAK_DURATION_MS ?= 3600000
PIC_SOAK_LIVENESS_INTERVAL_MS ?= 60000
PIC_SOAK_PROGRESS_INTERVAL_MS ?= 3600000
PIC_SOAK_SRC = test/pic/test_soak_pic.cc
PIC_SOAK_DEPS = $(PIC_SOAK_SRC) test/soak_timing_config.h
PIC_SOAK_BIN = test/pic/test_soak_pic
PIC_SOAK_HEX = $(PIC_BUILD_DIR)/$(FW_BASE)_$(PIC_SOAK_VARIANT)_$(PIC_TAG).hex

# Worst-case blocking output actuation (ms) per variant, passed to the soak as
# -DSOAK_ACTUATION_BLOCK_MS. A relay coil pulse / CD4053 mute busy-blocks the
# POLLED PIC main loop, stealing that many 1 ms debounce ticks from a window, so
# the soak's liveness check must hold each press/release that much longer to stay
# robust (see test/pic/test_soak_pic.cc). Mirror the driver headers'
# TQ2_L2_5V_PULSE_MS (12) and CD4053_MUTE_DELAY_MS (5); cd4053-simple is 0.
pic_soak_block_cd4053      = 0
pic_soak_block_mute        = 5
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
$(PIC_SOAK_BIN): $(PIC_SOAK_DEPS)
	$(PIC_SOAK_COMPILE)

.PHONY: pic-test-soak
pic-test-soak: pic
	@if ! command -v $(PIC_SOAK_CXX) >/dev/null 2>&1; then \
		echo "no C++ compiler ($(PIC_SOAK_CXX)); skipping PIC soak"; $(SKIP); \
	fi; \
	if [ ! -f "$(PIC_SOAK_GPSIM_INC)/sim_context.h" ]; then \
		echo "gpsim-dev headers not at $(PIC_SOAK_GPSIM_INC); skipping PIC soak (install gpsim-dev)"; $(SKIP); \
	fi; \
	if ! pkg-config --exists glib-2.0 2>/dev/null; then \
		echo "libglib2.0-dev not found; skipping PIC soak (install libglib2.0-dev)"; $(SKIP); \
	fi; \
	if [ ! -f "$(PIC_SOAK_HEX)" ]; then \
		echo "no $(PIC_SOAK_HEX) (XC8 absent?); skipping PIC soak for variant $(PIC_SOAK_VARIANT)"; $(SKIP); \
	fi; \
	echo "--- PIC soak: variant=$(PIC_SOAK_VARIANT) proc=$(PIC_GPSIM_PROC) duration=$(PIC_SOAK_DURATION_MS) ms ---"; \
	rm -f $(PIC_SOAK_BIN) && \
	$(PIC_SOAK_COMPILE) && \
	./$(PIC_SOAK_BIN)

# --- PIC critical-SFR fault-injection test (libgpsim) ------------------------
# Corrupt each critical config SFR (OSCCON/WDTCON/PR2/T2CON) in the running HEX
# and assert the per-tick gate (hw_critical_sfrs_intact) forces a WDT reset --
# the PIC analogue of the AVR simavr inject_config_sfr tests (test/avr/test_sim.c)
# and the mirror image of pic-test-soak (a reset is the expected PASS here, a
# FAILURE there). See test/pic/test_fault_pic.cc.
#
# STANDALONE -- like pic-test-soak it links libgpsim (needs gpsim-dev +
# libglib2.0-dev) and is deliberately NOT in `make test`/`pic-test`, whose PIC
# leg (pic-test-gpsim) needs only the gpsim CLI. Skips cleanly when the compiler,
# those headers, or the built HEX are absent. PIC_FAULT_VARIANT selects the HEX
# and the output-stage macro needed for variant-aware TRISA fault expectations.
# Reuses the soak's toolchain settings (PIC_SOAK_CXX, PIC_SOAK_GPSIM_INC).
PIC_FAULT_VARIANT ?= cd4053
PIC_FAULT_SRC = test/pic/test_fault_pic.cc
PIC_FAULT_BIN = test/pic/test_fault_pic
PIC_FAULT_HEX = $(PIC_BUILD_DIR)/$(FW_BASE)_$(PIC_FAULT_VARIANT)_$(PIC_TAG).hex
PIC_FAULT_SYM = $(PIC_FAULT_HEX:.hex=.sym)

# The test's ctx_ field offsets (+0/+1/+2) depend on XC8's code generator
# packing each enum to 1 byte -- which its clang FRONT END disagrees with
# (sizeof(debounce_context_t) == 5 there, so a firmware static_assert cannot
# pin the layout). The run recipe therefore asserts `_ctx_: ds 3` in the
# generated .s before running.
#
# _ctx_'s data address from the XC8 .sym, as -DCTX_ADDR=0x<addr> for the ctx_
# SRAM cases (so the test self-adjusts per variant instead of hard-coding it).
# A $(shell) in this recursive (=) variable re-runs when PIC_FAULT_COMPILE is
# expanded in the recipe -- i.e. AFTER the `pic` prerequisite has built the .sym.
# Empty when the .sym is absent (XC8 not installed); the run recipe below fails
# if the HEX exists but _ctx_ cannot be resolved, so the target cannot pass with
# its SRAM cases omitted.
PIC_FAULT_CTX_DEF = $(shell a=$$(awk '$$1=="_ctx_"{print $$2; exit}' $(PIC_FAULT_SYM) 2>/dev/null); [ -n "$$a" ] && echo -DCTX_ADDR=0x$$a)

# FW_PATH baked as an ABSOLUTE path so the binary is cwd-independent (parity with
# the soak). Phony run rule always recompiles so a PIC_FAULT_VARIANT override is
# always applied; the build-only $(PIC_FAULT_BIN) rule is the release-parity hook.
PIC_FAULT_COMPILE = $(PIC_SOAK_CXX) -std=c++17 -O2 $$(pkg-config --cflags glib-2.0) \
		-isystem $(PIC_SOAK_GPSIM_INC) -Itest -Isrc \
		-DFW_PATH='"$(CURDIR)/$(PIC_FAULT_HEX)"' -DPROC_NAME='"$(PIC_GPSIM_PROC)"' \
		-DF_CPU_HZ=$(PIC_XTAL) -D$(macro_$(PIC_FAULT_VARIANT)) $(PIC_FAULT_CTX_DEF) \
		$(PIC_FAULT_SRC) -o $(PIC_FAULT_BIN) -lgpsim

$(PIC_FAULT_BIN): $(PIC_FAULT_SRC)
	$(PIC_FAULT_COMPILE)

.PHONY: pic-test-fault
pic-test-fault: pic
	@if ! command -v $(PIC_SOAK_CXX) >/dev/null 2>&1; then \
		echo "no C++ compiler ($(PIC_SOAK_CXX)); skipping PIC fault-inject"; $(SKIP); \
	fi; \
	if [ ! -f "$(PIC_SOAK_GPSIM_INC)/sim_context.h" ]; then \
		echo "gpsim-dev headers not at $(PIC_SOAK_GPSIM_INC); skipping PIC fault-inject (install gpsim-dev)"; $(SKIP); \
	fi; \
	if ! pkg-config --exists glib-2.0 2>/dev/null; then \
		echo "libglib2.0-dev not found; skipping PIC fault-inject (install libglib2.0-dev)"; $(SKIP); \
	fi; \
	if [ ! -f "$(PIC_FAULT_HEX)" ]; then \
		echo "no $(PIC_FAULT_HEX) (XC8 absent?); skipping PIC fault-inject for variant $(PIC_FAULT_VARIANT)"; $(SKIP); \
	fi; \
	s="$(PIC_FAULT_HEX:.hex=.s)"; \
	alloc=`awk 'prev=="_ctx_:"{print $$2; exit} {prev=$$1}' "$$s" 2>/dev/null`; \
	if [ "$$alloc" != "3" ]; then \
		echo "FAIL: _ctx_ allocates $${alloc:-?} bytes in $$s -- expected 3 (packed 1-byte enums)."; \
		echo "      test_fault_pic.cc injects at the hard-coded byte offsets ctx_+0/+1/+2"; \
		echo "      (program_state/effect_state/debounce_counter), which assume XC8's code"; \
		echo "      generator packs each enum to 1 byte. It has stopped doing so: fix the"; \
		echo "      offsets (and the RAM figures in DESIGN_DOCUMENTATION.adoc) before running."; \
		echo "      NOTE: this is checked from the generated .s because it CANNOT be a"; \
		echo "      static_assert -- XC8's clang front end sizes enums as int, so"; \
		echo "      sizeof(debounce_context_t) evaluates to 5 even while the allocation is 3."; \
		exit 1; \
	fi; \
	ctx_addr=`awk '$$1=="_ctx_"{print $$2; exit}' "$(PIC_FAULT_SYM)" 2>/dev/null`; \
	if [ -z "$$ctx_addr" ]; then \
		echo "FAIL: _ctx_ symbol not found in $(PIC_FAULT_SYM); ctx_ SRAM fault cases would be omitted."; \
		exit 1; \
	fi; \
	echo "--- PIC fault-inject: variant=$(PIC_FAULT_VARIANT) proc=$(PIC_GPSIM_PROC) (ctx_ layout verified: 3 bytes) ---"; \
	rm -f $(PIC_FAULT_BIN) && \
	$(PIC_FAULT_COMPILE) && \
	./$(PIC_FAULT_BIN)

# --- PIC built-HEX lock-step test (libgpsim + shared model) -------------------
# Drive the real XC8-built HEX and the shared model with the same footswitch
# stream, then compare live ctx_ SRAM after every completed main-loop iteration.
# Standalone use is skip-clean for missing tools; pic-test-target below turns it
# into a fail-closed gate by requiring the LOCK-STEP PASS sentinel.
PIC_LOCKSTEP_VARIANT ?= cd4053
PIC_LOCKSTEP_SRC = test/pic/test_lockstep_pic.cc
PIC_LOCKSTEP_BIN = test/pic/test_lockstep_pic
PIC_LOCKSTEP_MODEL_OBJ = $(PIC_BUILD_DIR)/bypass_pure_lockstep.o
PIC_LOCKSTEP_HEX = $(PIC_BUILD_DIR)/$(FW_BASE)_$(PIC_LOCKSTEP_VARIANT)_$(PIC_TAG).hex
PIC_LOCKSTEP_SYM = $(PIC_LOCKSTEP_HEX:.hex=.sym)
PIC_LOCKSTEP_CTX_DEF = $(shell a=$$(awk '$$1=="_ctx_"{print $$2; exit}' $(PIC_LOCKSTEP_SYM) 2>/dev/null); [ -n "$$a" ] && echo -DCTX_ADDR=0x$$a)
PIC_LOCKSTEP_COMPILE = \
		$(HOSTCC) $(HOST_CFLAGS) $(PURE_HOST_CFLAGS) -Itest -Isrc \
			-c $(PURE_HOST_SRC) -o $(PIC_LOCKSTEP_MODEL_OBJ) && \
		$(PIC_SOAK_CXX) -std=c++17 -O2 $$(pkg-config --cflags glib-2.0) \
			-isystem $(PIC_SOAK_GPSIM_INC) -Itest -Isrc \
			-DFW_PATH='"$(CURDIR)/$(PIC_LOCKSTEP_HEX)"' -DPROC_NAME='"$(PIC_GPSIM_PROC)"' \
			-DF_CPU_HZ=$(PIC_XTAL) $(PIC_LOCKSTEP_CTX_DEF) \
			$(PIC_LOCKSTEP_SRC) $(PIC_LOCKSTEP_MODEL_OBJ) -o $(PIC_LOCKSTEP_BIN) -lgpsim

$(PIC_LOCKSTEP_BIN): $(PIC_LOCKSTEP_SRC) $(PURE_HOST_DEP)
	$(PIC_LOCKSTEP_COMPILE)

.PHONY: pic-test-lockstep
pic-test-lockstep: pic
	@if ! command -v $(PIC_SOAK_CXX) >/dev/null 2>&1; then \
		echo "no C++ compiler ($(PIC_SOAK_CXX)); skipping PIC lock-step"; $(SKIP); \
	fi; \
	if [ ! -f "$(PIC_SOAK_GPSIM_INC)/sim_context.h" ]; then \
		echo "gpsim-dev headers not at $(PIC_SOAK_GPSIM_INC); skipping PIC lock-step (install gpsim-dev)"; $(SKIP); \
	fi; \
	if ! pkg-config --exists glib-2.0 2>/dev/null; then \
		echo "libglib2.0-dev not found; skipping PIC lock-step (install libglib2.0-dev)"; $(SKIP); \
	fi; \
	if [ ! -f "$(PIC_LOCKSTEP_HEX)" ]; then \
		echo "no $(PIC_LOCKSTEP_HEX) (XC8 absent?); skipping PIC lock-step for variant $(PIC_LOCKSTEP_VARIANT)"; $(SKIP); \
	fi; \
	s="$(PIC_LOCKSTEP_HEX:.hex=.s)"; \
	alloc=`awk 'prev=="_ctx_:"{print $$2; exit} {prev=$$1}' "$$s" 2>/dev/null`; \
	if [ "$$alloc" != "3" ]; then \
		echo "FAIL: _ctx_ allocates $${alloc:-?} bytes in $$s -- expected 3 (packed 1-byte enums)."; \
		echo "      test_lockstep_pic.cc reads ctx_+0/+1/+2; fix offsets if packing changed."; \
		exit 1; \
	fi; \
	ctx_addr=`awk '$$1=="_ctx_"{print $$2; exit}' "$(PIC_LOCKSTEP_SYM)" 2>/dev/null`; \
	if [ -z "$$ctx_addr" ]; then \
		echo "FAIL: _ctx_ symbol not found in $(PIC_LOCKSTEP_SYM); lock-step cannot read firmware state."; \
		exit 1; \
	fi; \
	echo "--- PIC lock-step: variant=$(PIC_LOCKSTEP_VARIANT) proc=$(PIC_GPSIM_PROC) (ctx_ layout verified: 3 bytes) ---"; \
	rm -f $(PIC_LOCKSTEP_BIN) && \
	$(PIC_LOCKSTEP_COMPILE) && \
	./$(PIC_LOCKSTEP_BIN)

# --- PIC built-HEX GPIO transitions + pulse timing (libgpsim) ----------------
# Observe the real XC8 instruction stream around startup and an engage/bypass
# round trip. Asserts exact TRISA/ANSELA/LATA/PORTA behaviour, relay coil
# exclusion, and mute/relay pulse widths. Standalone use is skip-clean;
# pic-test-target below requires the TARGET-IO PASS sentinel.
PIC_IO_VARIANT ?= cd4053
PIC_IO_SRC = test/pic/test_io_pic.cc
PIC_IO_BIN = test/pic/test_io_pic
PIC_IO_HEX = $(PIC_BUILD_DIR)/$(FW_BASE)_$(PIC_IO_VARIANT)_$(PIC_TAG).hex
PIC_IO_COMPILE = $(PIC_SOAK_CXX) -std=c++17 -O2 $$(pkg-config --cflags glib-2.0) \
		-isystem $(PIC_SOAK_GPSIM_INC) -Itest -Isrc \
		-DFW_PATH='"$(CURDIR)/$(PIC_IO_HEX)"' -DPROC_NAME='"$(PIC_GPSIM_PROC)"' \
		-DF_CPU_HZ=$(PIC_XTAL) -D$(macro_$(PIC_IO_VARIANT)) \
		$(PIC_IO_SRC) -o $(PIC_IO_BIN) -lgpsim

$(PIC_IO_BIN): $(PIC_IO_SRC)
	$(PIC_IO_COMPILE)

.PHONY: pic-test-io
pic-test-io: pic
	@if ! command -v $(PIC_SOAK_CXX) >/dev/null 2>&1; then \
		echo "no C++ compiler ($(PIC_SOAK_CXX)); skipping PIC target-I/O test"; $(SKIP); \
	fi; \
	if [ ! -f "$(PIC_SOAK_GPSIM_INC)/sim_context.h" ]; then \
		echo "gpsim-dev headers not at $(PIC_SOAK_GPSIM_INC); skipping PIC target-I/O test (install gpsim-dev)"; $(SKIP); \
	fi; \
	if ! pkg-config --exists glib-2.0 2>/dev/null; then \
		echo "libglib2.0-dev not found; skipping PIC target-I/O test (install libglib2.0-dev)"; $(SKIP); \
	fi; \
	if [ ! -f "$(PIC_IO_HEX)" ]; then \
		echo "no $(PIC_IO_HEX) (XC8 absent?); skipping PIC target-I/O for variant $(PIC_IO_VARIANT)"; $(SKIP); \
	fi; \
	echo "--- PIC target I/O: variant=$(PIC_IO_VARIANT) proc=$(PIC_GPSIM_PROC) ---"; \
	rm -f $(PIC_IO_BIN) && \
	$(PIC_IO_COMPILE) && \
	./$(PIC_IO_BIN)

# Fail-closed real-HEX aggregate. The individual libgpsim targets above remain
# convenient skip-clean development commands; this wrapper requires explicit PASS
# markers, so a missing compiler/header, missing ctx_ symbol, or partial run fails
# CI/release instead of masquerading as green.
PIC_TARGET_VARIANT ?= cd4053
.PHONY: pic-test-target pic-test-target-variants
pic-test-target:
	@set -e; \
	for spec in \
		"pic-test-fault PIC_FAULT_VARIANT=$(PIC_TARGET_VARIANT)|FAULT-INJECT PASS" \
		"pic-test-lockstep PIC_LOCKSTEP_VARIANT=$(PIC_TARGET_VARIANT)|LOCK-STEP PASS" \
		"pic-test-io PIC_IO_VARIANT=$(PIC_TARGET_VARIANT)|TARGET-IO PASS"; do \
		target=$${spec%%|*}; marker=$${spec#*|}; log=`mktemp`; \
		if ! $(MAKE) --no-print-directory $$target >$$log 2>&1; then \
			cat $$log; rm -f $$log; exit 1; \
		fi; \
		cat $$log; \
		if ! grep -q "$$marker" $$log; then \
			echo "FAIL: $$target did not report '$$marker' (skipped or incomplete?)"; \
			rm -f $$log; exit 1; \
		fi; \
		rm -f $$log; \
	done
	@echo "=== PIC target fault/lock-step/I-O PASS (variant $(PIC_TARGET_VARIANT)) ==="

pic-test-target-variants:
	@for v in $(VARIANTS); do \
		echo "===================== PIC TARGET VARIANT $$v ====================="; \
		$(MAKE) --no-print-directory PIC_TARGET_VARIANT=$$v pic-test-target || exit 1; \
	done
	@echo "=== PIC target fault/lock-step/I-O validated for all variants ==="

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
# BUILD -- ATtiny202 (AVR-XT / avrxmega3) toolchain smoke gate  [Phase 0]
# ============================================================================
#
# A THIRD toolchain path -- but, unlike the PIC's closed XC8, the compiler here
# stays 100% open-source apt packages: the stock gcc-avr / binutils-avr already
# ship the avrxmega3 (AVR8X) architecture support, so only the per-device
# DESCRIPTION files (spec, crt, device lib, <avr/io.h> header) are missing. Those
# are vendored from a pinned, SHA-verified ATtiny_DFP atpack by
# scripts/fetch_attiny_dfp.sh into XT_DFP -- an EXTERNAL, uncommitted dir
# (third_party/ is gitignored), exactly mirroring how the PIC build consumes an
# uncommitted PIC_DFP.
#
# `make attiny202-smoke` is a COMPILE/LINK gate only: there is no firmware shell
# yet (src/bypass_mcu_avr_xt.c is Increment 2). It builds test/avr/attiny202_smoke.c
# -- which exercises every peripheral group the shell will drive (PORTA GPIO +
# PINnCTRL pull-up, CCP-protected CLKCTRL + WDT, TCB0 tick ISR, SLPCTRL idle,
# RSTCTRL) -- with the project's exact strict CFLAGS, then asserts the emitted
# image is avrxmega3 and fits the 2 KB flash budget. STANDALONE (NOT part of
# `make test`, since the DFP may be absent in CI); skips cleanly when the
# vendored device files are missing. There is no instruction-level simulator for
# AVR8X (simavr/QEMU do not model it), so the eventual shell is validated by
# static analysis + real hardware; the pure core keeps full formal coverage.
XT_MCU   ?= attiny202
XT_DEVLIB ?= tn202
XT_DFP   ?= third_party/attiny_dfp
XT_SPEC_DIR = $(XT_DFP)/gcc/dev/$(XT_MCU)
XT_INC      = $(XT_DFP)/include
# ATtiny202: 2 KB flash / 128 B SRAM. Budget the smoke against the full 2 KB (the
# shell's own budget gate lands in Increment 2). NOTE: avr-size --mcu=attiny202
# prints "Device: Unknown" under binutils 2.26 but STILL reports the Program:
# byte count, so the awk parse below works (same tactic as the PIC word parse).
XT_FLASH_BYTES ?= 2048
# The vendored device files that must exist for the build (the fetch script's
# output); their absence -> skip cleanly with a fetch hint.
XT_SPEC_FILE = $(XT_SPEC_DIR)/device-specs/specs-$(XT_MCU)
XT_IO_HEADER = $(XT_INC)/avr/io$(XT_DEVLIB).h
# Strict flags: the classic-AVR CFLAGS_COMMON plus the -B/-I device-pack
# injection (the open-source analogue of the PIC's -mdfp).
XT_CFLAGS = -mmcu=$(XT_MCU) -B $(XT_SPEC_DIR) -I $(XT_INC) $(CFLAGS_COMMON)
XT_LDFLAGS = -mmcu=$(XT_MCU) -B $(XT_SPEC_DIR) -Wl,--gc-sections

XT_SMOKE_SRC = test/avr/attiny202_smoke.c
XT_SMOKE_ELF = $(AVR_BUILD_DIR)/attiny202_smoke.elf

.PHONY: attiny202-smoke
attiny202-smoke: $(XT_SMOKE_SRC) | $(AVR_BUILD_DIR)
	@if [ ! -f "$(XT_SPEC_FILE)" ] || [ ! -f "$(XT_IO_HEADER)" ]; then \
		echo "ATtiny_DFP device files not found under XT_DFP=$(XT_DFP); skipping ATtiny202 smoke build."; \
		echo "  Fetch them (open-source apt toolchain + pinned atpack):"; \
		echo "    scripts/fetch_attiny_dfp.sh $(XT_DFP)"; \
		$(SKIP); \
	fi; \
	echo "=== ATtiny202 (avrxmega3) smoke: compile + link + arch + $(XT_FLASH_BYTES) B budget ==="; \
	$(CC) $(XT_CFLAGS) $(XT_LDFLAGS) -o $(XT_SMOKE_ELF) $(XT_SMOKE_SRC) \
		|| { echo "FAIL: ATtiny202 smoke did not compile/link"; exit 1; }; \
	flags=`$(READELF) -h $(XT_SMOKE_ELF) 2>/dev/null | sed -n 's/.*Flags:[[:space:]]*//p'`; \
	case "$$flags" in \
		*avr:103*) : ;; \
		*) echo "FAIL: $(XT_SMOKE_ELF) is not avrxmega3 (ELF flags: $$flags)"; exit 1 ;; \
	esac; \
	used=`$(SIZE) --mcu=$(XT_MCU) -C $(XT_SMOKE_ELF) 2>/dev/null | awk '/^Program:/ {print $$2; exit}'`; \
	if [ -z "$$used" ]; then echo "FAIL: could not read Program size from $(XT_SMOKE_ELF)"; exit 1; fi; \
	pct=`awk -v u="$$used" -v t=$(XT_FLASH_BYTES) 'BEGIN {printf "%.1f", u*100/t}'`; \
	if [ "$$used" -gt "$(XT_FLASH_BYTES)" ]; then \
		echo "FAIL: smoke uses $$used B ($${pct}%) -- exceeds $(XT_FLASH_BYTES) B"; exit 1; \
	fi; \
	echo "OK:   avrxmega3, $(XT_SMOKE_ELF) uses $$used B ($${pct}%) of $(XT_FLASH_BYTES) B"

# ============================================================================
# BUILD -- ATtiny202 (AVR-XT / avrxmega3) development firmware  [non-release]
# ============================================================================
#
# The real firmware build (the smoke gate above only proves the toolchain). The
# ATtiny202 shell (src/bypass_mcu_avr_xt.c) implements the same bypass_hw_iface.h
# contract as the classic-AVR and PIC shells and links the UNCHANGED pure core
# (bypass_pure.c) + one output driver -- exactly like `all13` / `pic`. Like the
# PIC build it is STANDALONE (the vendored DFP may be absent in CI, and there is
# NO AVR8X simulator) and gates every variant on the device's 2 KB flash budget;
# it skips cleanly when the DFP or the shell source is absent.
#
# simavr/QEMU do not model AVR8X, but yasimavr DOES: the `attiny202-sim` /
# -soak / -fault targets below run the real built image on a patched yasimavr
# (scripts/fetch_yasimavr.sh), giving the shell register-level dynamic coverage
# close to the classic simavr harness. The shell is thus validated by (1) this
# strict-flag cross-build, (2) the flash-budget gate, (3) cppcheck + MISRA
# static analysis (attiny202-analyze), (4) the yasimavr harness, and (5) real
# hardware. The pure core keeps full host + formal coverage via `make test`.
XT_BUILD_DIR ?= build_avr_xt
XT_TAG       ?= attiny202
XT_F_CPU     ?= 2000000UL
override XT_VARIANTS_SUPPORTED := cd4053 mute relay
override XT_VARIANTS_REQUESTED := $(filter $(XT_VARIANTS_SUPPORTED),$(VARIANTS))
override XT_VARIANTS_UNKNOWN := $(filter-out $(XT_VARIANTS_SUPPORTED),$(VARIANTS))
# The shell + the unchanged pure core (the AVR-classic counterpart is CORE_SRC).
XT_CORE_SRC = src/bypass_mcu_avr_xt.c src/bypass_pure.c
# Headers that, if changed, should rebuild the XT images: the FW_HEADERS set with
# the AVR-XT pin map substituted for the classic one.
XT_HEADERS = src/bypass_config.h src/bypass_types.h src/bypass_hw_iface.h \
             src/bypass_output_common.h src/bypass_pins_avr_xt.h \
             src/bypass_blocking_delay.h src/bypass_static_assert.h \
             src/bypass_compile_checks.h \
             src/bypass_output_cd4053_simple.h src/bypass_output_cd4053_with_mute.h \
             src/bypass_output_tq2_l2_5v_relay.h
# Firmware compile flags: the smoke gate's strict XT_CFLAGS (-B/-I device-pack
# injection + CFLAGS_COMMON) plus the runtime -D selectors (F_CPU + the AVR-XT
# shell selector). XT_LDFLAGS (from the smoke section) carries the link flags.
XT_FW_CFLAGS = -DF_CPU=$(XT_F_CPU) -DBYPASS_MCU_AVR_XT $(XT_CFLAGS)

$(XT_BUILD_DIR):
	@mkdir -p $@

# Build every variant for the ATtiny202 and enforce the 2 KB flash-word budget.
# The variant -D selector + driver source are chosen inline (the same case-
# pattern the PIC/analyze recipes use, since $(macro_<v>)/$(src_<v>) cannot
# expand inside a shell loop). Emits bypass_<variant>_attiny202.elf/.hex.
.PHONY: attiny202
attiny202: | $(XT_BUILD_DIR)
	@if ! rm -f "$(XT_BUILD_DIR)"/$(FW_BASE)_*_$(XT_TAG).elf \
			"$(XT_BUILD_DIR)"/$(FW_BASE)_*_$(XT_TAG).hex \
			"$(XT_BUILD_DIR)"/$(FW_BASE)_*_$(XT_TAG).elf.tmp \
			"$(XT_BUILD_DIR)"/$(FW_BASE)_*_$(XT_TAG).hex.tmp; then \
		echo "FAIL: could not remove stale ATtiny202 artifacts"; exit 1; \
	fi
	@if [ ! -f "$(XT_SPEC_FILE)" ] || [ ! -f "$(XT_IO_HEADER)" ]; then \
		echo "ATtiny_DFP device files not found under XT_DFP=$(XT_DFP); skipping ATtiny202 build."; \
		echo "  Fetch them (open-source apt toolchain + pinned atpack):"; \
		echo "    scripts/fetch_attiny_dfp.sh $(XT_DFP)"; \
		$(SKIP); \
	fi; \
	if [ ! -f "src/bypass_mcu_avr_xt.c" ]; then \
		echo "src/bypass_mcu_avr_xt.c not present (Increment 2 shell); skipping ATtiny202 build."; \
		$(SKIP); \
	fi; \
	echo "=== ATtiny202 (avrxmega3) build + flash-budget ($(XT_FLASH_BYTES) B) ==="; \
	if ! awk -v t="$(XT_FLASH_BYTES)" 'BEGIN {exit !(t ~ /^[0-9]+$$/ && t ~ /[1-9]/)}'; then \
		echo "FAIL: XT_FLASH_BYTES must be a positive decimal integer"; exit 2; \
	fi; \
	if [ "$(words $(strip $(VARIANTS)))" -eq 0 ]; then \
		echo "FAIL: VARIANTS is empty; no ATtiny202 images requested"; exit 2; \
	fi; \
	if [ "$(words $(XT_VARIANTS_UNKNOWN))" -ne 0 ]; then \
		echo "FAIL: VARIANTS contains an unsupported ATtiny202 variant"; exit 2; \
	fi; \
	if [ "$(words $(strip $(VARIANTS)))" -ne "$(words $(sort $(VARIANTS)))" ]; then \
		echo "FAIL: VARIANTS contains a duplicate ATtiny202 variant"; exit 2; \
	fi; \
	set -- $(XT_VARIANTS_REQUESTED); \
	fail=0; \
	for v in "$$@"; do \
		case $$v in \
			cd4053) m=CD4053_SIMPLE;     drv=src/bypass_output_cd4053_simple.c ;; \
			mute)    m=CD4053_WITH_MUTE;  drv=src/bypass_output_cd4053_with_mute.c ;; \
			relay)   m=TQ2_L2_5V_RELAY;   drv=src/bypass_output_tq2_l2_5v_relay.c ;; \
			*) echo "FAIL: unsupported ATtiny202 variant '$$v'"; fail=1; continue ;; \
		esac; \
		elf=$(XT_BUILD_DIR)/$(FW_BASE)_$${v}_$(XT_TAG).elf; \
		hex=$(XT_BUILD_DIR)/$(FW_BASE)_$${v}_$(XT_TAG).hex; \
		elf_tmp=$$elf.tmp; hex_tmp=$$hex.tmp; log=$(XT_BUILD_DIR)/$$v.log; \
		if ! rm -f "$$elf" "$$hex" "$$elf_tmp" "$$hex_tmp" "$$log"; then \
			echo "FAIL: could not clean outputs for ATtiny202 variant $$v"; fail=1; continue; \
		fi; \
		if ! $(CC) $(XT_FW_CFLAGS) -D$$m $(XT_LDFLAGS) -o "$$elf_tmp" \
				$(XT_CORE_SRC) $$drv 2> "$$log"; then \
			cat "$$log"; \
			echo "FAIL: variant $$v did not compile for ATtiny202"; \
			rm -f "$$elf_tmp" "$$hex_tmp" "$$log"; fail=1; continue; \
		fi; \
		if [ ! -s "$$elf_tmp" ]; then \
			echo "FAIL: compiler produced no ELF for ATtiny202 variant $$v"; \
			rm -f "$$elf_tmp" "$$hex_tmp" "$$log"; fail=1; continue; \
		fi; \
		if ! elf_header=`$(READELF) -h "$$elf_tmp" 2>/dev/null`; then \
			echo "FAIL: could not inspect ELF for ATtiny202 variant $$v"; \
			rm -f "$$elf_tmp" "$$hex_tmp" "$$log"; fail=1; continue; \
		fi; \
		flags=`printf '%s\n' "$$elf_header" | sed -n 's/.*Flags:[[:space:]]*//p'`; \
		case "$$flags" in *avr:103*) : ;; \
			*) echo "FAIL: $$v is not avrxmega3 (ELF flags: $$flags)"; \
				rm -f "$$elf_tmp" "$$hex_tmp" "$$log"; fail=1; continue ;; \
		esac; \
		if ! size_out=`$(SIZE) --mcu=$(XT_MCU) -C "$$elf_tmp" 2>&1`; then \
			printf '%s\n' "$$size_out"; \
			echo "FAIL: could not measure Program size for ATtiny202 variant $$v"; \
			rm -f "$$elf_tmp" "$$hex_tmp" "$$log"; fail=1; continue; \
		fi; \
		used=`printf '%s\n' "$$size_out" | awk '/^Program:/ {print $$2; exit}'`; \
		case "$$used" in ''|*[!0-9]*) \
			echo "FAIL: invalid Program size for ATtiny202 variant $$v: '$$used'"; \
			rm -f "$$elf_tmp" "$$hex_tmp" "$$log"; fail=1; continue ;; \
		esac; \
		if awk -v u="$$used" -v t="$(XT_FLASH_BYTES)" 'BEGIN { \
			sub(/^0+/, "", u); sub(/^0+/, "", t); \
			if (u == "") u = "0"; if (t == "") t = "0"; \
			if (length(u) > length(t)) exit 0; \
			if (length(u) < length(t)) exit 1; \
			exit !(("x" u) > ("x" t)); \
		}'; then \
			pct=`awk -v u="$$used" -v t="$(XT_FLASH_BYTES)" 'BEGIN{printf "%.1f", u*100/t}'`; \
			echo "FAIL: $$v uses $$used B ($${pct}%) -- exceeds $(XT_FLASH_BYTES) B"; \
			rm -f "$$elf_tmp" "$$hex_tmp" "$$log"; fail=1; continue; \
		fi; \
		pct=`awk -v u="$$used" -v t="$(XT_FLASH_BYTES)" 'BEGIN{printf "%.1f", u*100/t}'`; \
		if ! $(OBJCOPY) -O ihex -R .eeprom "$$elf_tmp" "$$hex_tmp"; then \
			echo "FAIL: could not generate HEX for ATtiny202 variant $$v"; \
			rm -f "$$elf_tmp" "$$hex_tmp" "$$log"; fail=1; continue; \
		fi; \
		if [ ! -s "$$hex_tmp" ] || ! awk ' \
			function nibble(c) { return index("0123456789ABCDEF", c) - 1 } \
			function byte_at(s, p) { return nibble(substr(s, p, 1)) * 16 + nibble(substr(s, p + 1, 1)) } \
			BEGIN { valid = 1 } \
			{ sub(/\r$$/, ""); line = toupper($$0); \
			  if (eof_count || line !~ /^:[[:xdigit:]]+$$/) { valid = 0; next } \
			  record = substr(line, 2); record_len = length(record); \
			  if (record_len < 10 || record_len % 2) { valid = 0; next } \
			  byte_count = byte_at(record, 1); \
			  if (record_len != 10 + byte_count * 2) { valid = 0; next } \
			  sum = 0; for (i = 1; i <= record_len; i += 2) sum += byte_at(record, i); \
			  if (sum % 256 != 0) { valid = 0; next } \
			  address = substr(record, 3, 4); record_type = substr(record, 7, 2); \
			  if (record_type == "00") { \
			    if (byte_count == 0) { valid = 0; next } \
			    data_bytes += byte_count \
			  } else if (record_type == "01") { \
			    if (record != "00000001FF") { valid = 0; next } \
			    eof_count++ \
			  } else if (record_type == "02" || record_type == "04") { \
			    if (byte_count != 2 || address != "0000") { valid = 0; next } \
			  } else if (record_type == "03" || record_type == "05") { \
			    if (byte_count != 4 || address != "0000") { valid = 0; next } \
			  } else { \
			    valid = 0; next \
			  } \
			} \
			END { exit !(valid && NR > 0 && data_bytes > 0 && eof_count == 1) }' "$$hex_tmp"; then \
			echo "FAIL: objcopy produced an empty or invalid HEX for ATtiny202 variant $$v"; \
			rm -f "$$elf_tmp" "$$hex_tmp" "$$log"; fail=1; continue; \
		fi; \
		if ! mv "$$elf_tmp" "$$elf" || ! mv "$$hex_tmp" "$$hex"; then \
			echo "FAIL: could not publish ATtiny202 artifacts for variant $$v"; \
			rm -f "$$elf" "$$hex" "$$elf_tmp" "$$hex_tmp" "$$log"; fail=1; continue; \
		fi; \
		rm -f "$$log"; \
		echo "OK:   $$v -> $$hex : $$used B ($${pct}%) of $(XT_FLASH_BYTES) B"; \
	done; \
	exit $$fail

# --- ATtiny202 production fuses (programmer + checker + simulator) -----------
# One source of truth for every consumer. test-fuses injects these bytes into
# the host checker, attiny202-fuses writes them to silicon, and XT_FUSE_ENV
# passes them to yasimavr's factory-fuse descriptor without Python-side defaults.
XT_FUSE_WDTCFG  ?= 0x06
XT_FUSE_BODCFG  ?= 0xE5
XT_FUSE_OSCCFG  ?= 0x01
XT_FUSE_SYSCFG0 ?= 0xF6
XT_FUSE_SYSCFG1 ?= 0x07
XT_FUSE_APPEND  ?= 0x00
XT_FUSE_BOOTEND ?= 0x00

XT_FUSE_ENV = ATTINY202_FUSE_WDTCFG=$(XT_FUSE_WDTCFG) \
              ATTINY202_FUSE_BODCFG=$(XT_FUSE_BODCFG) \
              ATTINY202_FUSE_OSCCFG=$(XT_FUSE_OSCCFG) \
              ATTINY202_FUSE_SYSCFG0=$(XT_FUSE_SYSCFG0) \
              ATTINY202_FUSE_SYSCFG1=$(XT_FUSE_SYSCFG1) \
              ATTINY202_FUSE_APPEND=$(XT_FUSE_APPEND) \
              ATTINY202_FUSE_BOOTEND=$(XT_FUSE_BOOTEND)

# --- ATtiny202 yasimavr dynamic-simulation harness ---------------------------
# The AVR-XT analogue of the AVR-classic simavr suite (test-sim / test-soak /
# fault-inject) and the PIC libgpsim track (pic-test-gpsim / -soak / -fault):
# run the REAL built ATtiny202 image on a PATCHED yasimavr and exercise the
# peripheral-register layer of the shell (bypass_mcu_avr_xt.c) that the
# target-agnostic host/formal suites cannot reach -- TCB0 tick, fuse-locked WDT,
# PORTA in/out, RSTCTRL. The pure debounce core keeps its own full coverage.
#
# yasimavr is not in apt; it is built from a pinned upstream release plus two
# vendored bug-fix patches (third_party/yasimavr/patches/) into a project-local,
# gitignored venv by scripts/fetch_yasimavr.sh -- the yasimavr counterpart of
# scripts/fetch_attiny_dfp.sh. These targets are STANDALONE (NOT in `make test`)
# and SKIP CLEANLY (exit 0) when that venv is absent, exactly as `attiny202`
# skips without the DFP and `pic-test-soak` skips without gpsim-dev. CI builds
# the venv explicitly (a fetch step) so a skip there cannot mask a real failure.
#
# XT_SIM_VARIANT selects one variant (cd4053/mute/relay); empty
# (the default) runs every built variant. Each target first runs test-fuses, so
# complete but non-production overrides cannot reach a simulator that does not
# behaviorally observe every fuse. The drivers import test/avr/sim_attiny202.py,
# so the recipes put that dir on PYTHONPATH.
YASIMAVR_VENV ?= third_party/yasimavr/venv
YASIMAVR_PY    = $(YASIMAVR_VENV)/bin/python
XT_SIM_VARIANT ?=
XT_SIM_DRIVER   = test/avr/test_sim_attiny202.py
XT_FAULT_DRIVER = test/avr/test_fault_attiny202.py
XT_SOAK_DRIVER  = test/avr/test_soak_attiny202.py
# Soak knobs (parity with the PIC soak's SOAK_*). Default 1 h simulated (~17 s
# wall/variant in yasimavr fast mode); pass 86400000 for 24 h.
XT_SOAK_DURATION_MS ?= 3600000
XT_SOAK_LIVENESS_INTERVAL_MS ?= 60000
XT_SOAK_PROGRESS_INTERVAL_MS ?= 600000

# Shell guard shared by every harness target: skip cleanly (exit 0 out of the
# whole recipe via the caller) when the patched venv is missing or non-importable.
# Usage: `$(yasimavr_skip_if_absent)` as the first line of the recipe body.
define yasimavr_skip_if_absent
if [ ! -x "$(YASIMAVR_PY)" ] || ! "$(YASIMAVR_PY)" -c "import yasimavr" >/dev/null 2>&1; then \
	echo "patched yasimavr venv not found at $(YASIMAVR_VENV); skipping ATtiny202 simulation."; \
	echo "  Build it (pinned upstream release + vendored patches):"; \
	echo "    scripts/fetch_yasimavr.sh"; \
	$(SKIP); \
fi
endef

.PHONY: attiny202-sim
attiny202-sim: test-fuses attiny202
	@$(yasimavr_skip_if_absent); \
	vars="$(XT_SIM_VARIANT)"; [ -n "$$vars" ] || vars="$(VARIANTS)"; \
	fail=0; ran=0; \
	for v in $$vars; do \
		elf=$(XT_BUILD_DIR)/$(FW_BASE)_$${v}_$(XT_TAG).elf; \
		if [ ! -f "$$elf" ]; then \
			echo "no $$elf (DFP absent?); skipping ATtiny202 sim for variant $$v"; continue; \
		fi; \
		echo "--- ATtiny202 sim (functional): variant=$$v ---"; \
		ran=1; \
		PYTHONPATH=test/avr $(XT_FUSE_ENV) \
		$(YASIMAVR_PY) $(XT_SIM_DRIVER) "$$elf" || fail=1; \
	done; \
	if [ "$$ran" = 0 ]; then echo "no ATtiny202 images built; nothing to simulate."; fi; \
	exit $$fail

# Fault injection: corrupt each guarded critical SFR / state byte in the running
# image and assert the shell catches it -- the per-tick sanity gate diverts to
# the force-reset spin, or (for the tick timer itself) the watchdog resets on
# lost liveness. Mirror image of the soak: a reset is the PASS here. Same guard /
# skip / variant-selection contract as attiny202-sim.
.PHONY: attiny202-fault
attiny202-fault: test-fuses attiny202
	@$(yasimavr_skip_if_absent); \
	vars="$(XT_SIM_VARIANT)"; [ -n "$$vars" ] || vars="$(VARIANTS)"; \
	fail=0; ran=0; \
	for v in $$vars; do \
		elf=$(XT_BUILD_DIR)/$(FW_BASE)_$${v}_$(XT_TAG).elf; \
		if [ ! -f "$$elf" ]; then \
			echo "no $$elf (DFP absent?); skipping ATtiny202 fault-inject for variant $$v"; continue; \
		fi; \
		echo "--- ATtiny202 fault-injection: variant=$$v ---"; \
		ran=1; \
		PYTHONPATH=test/avr $(XT_FUSE_ENV) \
		$(YASIMAVR_PY) $(XT_FAULT_DRIVER) "$$elf" || fail=1; \
	done; \
	if [ "$$ran" = 0 ]; then echo "no ATtiny202 images built; nothing to fault-inject."; fi; \
	exit $$fail

# Long-duration soak: run the healthy image for XT_SOAK_DURATION_MS of simulated
# time and assert liveness holds throughout -- the watchdog never resets (a GPR0
# reset-witness stays armed) and a periodic 2-press round-trip still toggles the
# LED. Mirror image of the fault test: a reset is a FAILURE. Non-fatal, logged,
# cumulative. Standalone; same guard / skip / variant-selection as the others.
.PHONY: attiny202-soak
attiny202-soak: test-fuses attiny202
	@$(yasimavr_skip_if_absent); \
	vars="$(XT_SIM_VARIANT)"; [ -n "$$vars" ] || vars="$(VARIANTS)"; \
	fail=0; ran=0; \
	for v in $$vars; do \
		elf=$(XT_BUILD_DIR)/$(FW_BASE)_$${v}_$(XT_TAG).elf; \
		if [ ! -f "$$elf" ]; then \
			echo "no $$elf (DFP absent?); skipping ATtiny202 soak for variant $$v"; continue; \
		fi; \
		echo "--- ATtiny202 soak: variant=$$v duration=$(XT_SOAK_DURATION_MS) ms ---"; \
		ran=1; \
		PYTHONPATH=test/avr \
		$(XT_FUSE_ENV) \
		ATTINY202_SOAK_DURATION_MS=$(XT_SOAK_DURATION_MS) \
		ATTINY202_SOAK_LIVENESS_INTERVAL_MS=$(XT_SOAK_LIVENESS_INTERVAL_MS) \
		ATTINY202_SOAK_PROGRESS_INTERVAL_MS=$(XT_SOAK_PROGRESS_INTERVAL_MS) \
		$(YASIMAVR_PY) $(XT_SOAK_DRIVER) "$$elf" || fail=1; \
	done; \
	if [ "$$ran" = 0 ]; then echo "no ATtiny202 images built; nothing to soak."; fi; \
	exit $$fail

# --- ATtiny202 fuses + UPDI programming --------------------------------------
# Programmed over UPDI (single wire). The default uses avrdude's open-source
# serialupdi (a plain USB-serial adapter + a series resistor -- the cheapest,
# most open path, matching this project's open-toolchain preference); override
# XT_PROGRAMMER / XT_UPDI_PORT for jtag2updi, an Atmel-ICE, pymcuprog, etc.
#
# Fuse bytes are defined once above the simulator harness and decoded by
# test-fuses. avrdude exposes the AVR8X fuses as named memories.
XT_PROGRAMMER   ?= serialupdi
XT_UPDI_PORT    ?= /dev/ttyUSB0
XT_AVRDUDE_PART ?= t202
XT_AVRDUDE_FLAGS = -c $(XT_PROGRAMMER) -P $(XT_UPDI_PORT) -p $(XT_AVRDUDE_PART)

.PHONY: attiny202-fuses attiny202-flash attiny202-program
attiny202-fuses:
	$(AVRDUDE) $(XT_AVRDUDE_FLAGS) \
		-U wdtcfg:w:$(XT_FUSE_WDTCFG):m   -U bodcfg:w:$(XT_FUSE_BODCFG):m \
		-U osccfg:w:$(XT_FUSE_OSCCFG):m   -U syscfg0:w:$(XT_FUSE_SYSCFG0):m \
		-U syscfg1:w:$(XT_FUSE_SYSCFG1):m -U append:w:$(XT_FUSE_APPEND):m \
		-U bootend:w:$(XT_FUSE_BOOTEND):m

# Flash ONE variant image to hardware (select with VARIANT=<name>); builds first.
attiny202-flash: attiny202
	$(AVRDUDE) $(XT_AVRDUDE_FLAGS) \
		-U flash:w:$(XT_BUILD_DIR)/$(FW_BASE)_$(VARIANT)_$(XT_TAG).hex:i

# Fresh chip: write the fuses, then flash the selected variant.
attiny202-program: attiny202-fuses attiny202-flash

# --- ATtiny202 static analysis (cppcheck + MISRA addon) ----------------------
# Two analyzers over the AVR-XT shell, parallel to analyze-cppcheck/analyze-misra
# (classic) and pic-analyze-* (PIC). STANDALONE (needs the vendored DFP + apt
# avr-libc headers; NOT part of `make test`); each skips cleanly when cppcheck/
# python3 or the DFP device header is absent. The AVR-XT register headers resolve
# exactly as the real build sees them: <avr/io.h> reaches iotn202.h via the
# spec's __AVR_DEV_LIB_NAME__=tn202 fallback, and the device-family macros that
# -mmcu normally predefines (__AVR_XMEGA__ / __AVR_ATtiny202__ / ...) are supplied
# explicitly here -- mirroring the classic run's -D__AVR_ATtiny13A__ and the PIC
# run's -D_10F322. avr-libc / avr-gcc / DFP headers are outside the compliance
# boundary -> suppressed by path.
XT_ARCH ?= 103
XT_CPPCHECK_CPPFLAGS = -D__AVR__ -D__AVR_XMEGA__ -D__AVR_MEGA__ \
                       -D__AVR_ATtiny202__ -D__AVR_ARCH__=$(XT_ARCH) \
                       -D__AVR_DEV_LIB_NAME__=$(XT_DEVLIB) \
                       -DBYPASS_MCU_AVR_XT -DF_CPU=$(XT_F_CPU) \
                       -UBYPASS_MCU_PIC10F322 -UBYPASS_MCU_AVR_CLASSIC \
                       -Isrc $(if $(AVR_LIBC_INCLUDE),-I$(AVR_LIBC_INCLUDE)) \
                       -I$(XT_INC) $(if $(AVR_GCC_INCLUDE),-I$(AVR_GCC_INCLUDE))

# Plain bug-finding pass (parallel to analyze-cppcheck for the classic build).
XT_CPPCHECK_FLAGS ?= --enable=warning,style,performance,portability \
                     --std=c11 --platform=avr8 --error-exitcode=2 \
                     --inline-suppr --max-configs=1 \
                     --suppress=missingIncludeSystem \
                     --suppress=unmatchedSuppression \
                     --suppress=unusedStructMember \
                     $(if $(AVR_LIBC_INCLUDE),'--suppress=*:$(AVR_LIBC_INCLUDE)/*') \
                     $(if $(AVR_GCC_INCLUDE),'--suppress=*:$(AVR_GCC_INCLUDE)/*') \
                     '--suppress=*:$(XT_INC)/*' \
                     $(XT_CPPCHECK_CPPFLAGS)

# MISRA addon pass (parallel to MISRA_CPPCHECK_FLAGS for the classic build).
XT_MISRA_CPPCHECK_FLAGS ?= --addon=$(MISRA_ADDON) --std=c11 --platform=avr8 \
                     --enable=style --inline-suppr --max-configs=1 \
                     --suppress=missingIncludeSystem \
                     --suppress=unmatchedSuppression \
                     $(if $(AVR_LIBC_INCLUDE),'--suppress=*:$(AVR_LIBC_INCLUDE)/*') \
                     $(if $(AVR_GCC_INCLUDE),'--suppress=*:$(AVR_GCC_INCLUDE)/*') \
                     '--suppress=*:$(XT_INC)/*' \
                     $(XT_CPPCHECK_CPPFLAGS)

.PHONY: attiny202-analyze attiny202-analyze-cppcheck attiny202-analyze-misra
attiny202-analyze: attiny202-analyze-cppcheck attiny202-analyze-misra
	@echo "=== ATtiny202 static analysis (cppcheck + MISRA) complete ==="

attiny202-analyze-cppcheck: src/bypass_mcu_avr_xt.c $(XT_HEADERS)
	@if ! command -v $(CPPCHECK) >/dev/null 2>&1; then \
		echo "cppcheck not installed; skipping ATtiny202 cppcheck analysis"; $(SKIP); \
	fi; \
	if [ ! -f "$(XT_IO_HEADER)" ]; then \
		echo "ATtiny_DFP device header not found (XT_DFP=$(XT_DFP)); skipping ATtiny202 cppcheck analysis"; $(SKIP); \
	fi; \
	echo "cppcheck (ATtiny202, avr8/avrxmega3): $(CPPCHECK) src/bypass_mcu_avr_xt.c"; \
	$(CPPCHECK) $(XT_CPPCHECK_FLAGS) src/bypass_mcu_avr_xt.c

attiny202-analyze-misra: src/bypass_mcu_avr_xt.c $(XT_HEADERS) $(MISRA_ADDON) $(MISRA_RULES) $(MISRA_SUPPRESS)
	@if ! command -v $(CPPCHECK) >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then \
		echo "cppcheck and/or python3 not available; skipping ATtiny202 MISRA analysis"; $(SKIP); \
	fi; \
	if [ ! -f "$(XT_IO_HEADER)" ]; then \
		echo "ATtiny_DFP device header not found (XT_DFP=$(XT_DFP)); skipping ATtiny202 MISRA analysis"; $(SKIP); \
	fi; \
	echo "MISRA-C:2012 analysis -- ATtiny202 shell ($(CPPCHECK) + misra addon, avr8)"; \
	out=`mktemp`; rc=0; \
	PYTHONWARNINGS=ignore $(CPPCHECK) $(XT_MISRA_CPPCHECK_FLAGS) \
		--suppressions-list=$(MISRA_SUPPRESS) --error-exitcode=2 \
		src/bypass_mcu_avr_xt.c 2>>$$out || rc=1; \
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
	echo "MISRA-C:2012 (ATtiny202 shell): clean (documented deviations waived per MISRA_COMPLIANCE.md)"

# Aggregate: every ATtiny202 pre-hardware check (fuses + smoke + build/budget +
# analysis).
# STANDALONE -- NOT part of `make test` (no AVR8X simulator; DFP may be absent in
# CI). Each sub-target skips cleanly when its tool/DFP is missing.
.PHONY: attiny202-test
attiny202-test: test-fuses attiny202-smoke attiny202 attiny202-analyze
	@echo "=== all ATtiny202 pre-hardware checks complete ==="

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
		test/pic/test_fault_pic test/pic/test_lockstep_pic test/pic/test_io_pic \
		test/formal/test_model_check test/formal/test_symbolic test/avr/test_fuses \
		test/formal/test_symbolic.bc \
		test/stack_*.o test/stack_*.su \
		test/.toolchain.sig $(FW_BASE).plist
	rm -f *.dump *.ctu-info cppcheck-addon-ctu-file-list*
	rm -rf test/klee-out-* test/klee-last test/avr/__pycache__
	rm -rf $(AVR_BUILD_DIR) $(PIC_BUILD_DIR) $(XT_BUILD_DIR)

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
test: analyze test-host test-model-check test-symbolic test-cbmc test-fuses test-stack-bound test-stack-bound-regression test-flash-budget-regression test-fault-inject test-sim test-sim-secondary test-attiny202-build test-avr-build-rebuild test-gpsim-wrappers test-pic-build test-release-images test-soak-timing test-workload-rebuild coverage-check
	@echo "=== all fast pre-hardware tests passed ==="

# Explicit alias for the fast suite (same as `make test`).
test-fast: test

# FULL exhaustive workload: same targets as `test`, but the fuzz/stress tests
# are rebuilt with their large in-source default durations (FULL_*_DEFS adds no
# overrides). Workload-dependent binaries have a FORCE prerequisite, so this
# does not rely on a racy cleanup phase. Use before tagging a release/HW signoff.
test-long: HOST_DEFS = $(FULL_HOST_DEFS)
test-long: SIM_DEFS  = $(FULL_SIM_DEFS)
test-long: analyze test-host test-model-check test-symbolic test-cbmc test-fuses test-stack-bound test-stack-bound-regression test-flash-budget-regression test-fault-inject test-mutation test-sim test-sim-secondary test-attiny202-build test-avr-build-rebuild test-gpsim-wrappers test-pic-build test-release-images test-soak-timing test-workload-rebuild coverage-check
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

# Fake-tool regression checks for fail-closed ATtiny202 ELF/HEX generation.
test-attiny202-build:
	./test/test_attiny202_build.sh

# Isolated fake-tool proof of classic AVR dependency/configuration invalidation.
test-avr-build-rebuild:
	./test/test_avr_build_rebuild.sh

# Fake-gpsim proof that complete snapshots cannot hide process failure/timeout.
test-gpsim-wrappers:
	./test/test_gpsim_wrappers.sh

# Isolated fake-XC8 proof of fail-closed PIC image generation.
test-pic-build:
	./test/test_pic_build.sh

# Exact-set and hash checks for the tag workflow's committed/listed/fresh images.
test-release-images:
	./test/test_release_images.sh

# Fast host-only boundary checks for every soak timing input path: the shared
# C/C++ compile-time contract, ATtiny202 environment parser, and release CLI.
test-soak-timing:
	HOSTCC="$(HOSTCC)" HOSTCXX="$(PIC_SOAK_CXX)" ./test/test_soak_timing.sh

# Isolated fake-compiler proof of workload and fuse-configuration rebuilds.
test-workload-rebuild:
	./test/test_workload_rebuild.sh

# Build rule for the golden model. Constants come from bypass_config.h (via the
# host shim) so the model can never drift from the firmware thresholds.
test/host/test_logic_host: test/host/test_logic_host.c test/bypass_config_host.h src/bypass_config.h FORCE
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

# Fuse-byte verification: decode the EXACT bytes this Makefile will burn for
# ATtiny13a, tinyx5, and ATtiny202 and assert they match the documented design
# intent (clock, BOD, watchdog, reset/programming access, and flash sections).
# The Python companion also proves yasimavr consumes all seven ATtiny202 bytes
# fail-closed. The tinyx5 fuse bytes are identical across ATtiny25/45/85, so the
# checker's T85_* bytes cover the whole family.
test-fuses: test/avr/test_fuses test/avr/test_attiny202_fuses.py test/avr/attiny202_fuses.py
	./test/avr/test_fuses
	$(XT_FUSE_ENV) PYTHONPATH=test/avr python3 test/avr/test_attiny202_fuses.py

# Build rule for the fuse checker. Fuse byte values are injected from the
# Makefile variables (single source of truth) via -D. FORCE makes command-line
# overrides observable even when the source and Makefile timestamps are
# unchanged. Publish atomically so a failed or empty compiler result cannot
# leave a stale checker that validates previous fuse values.
test/avr/test_fuses: test/avr/test_fuses.c Makefile FORCE
	@if ! rm -f "$@"; then echo "FAIL: could not remove stale fuse checker"; exit 1; fi; \
	tmp=$$(mktemp "$@.tmp.XXXXXX") || exit 1; \
	trap 'rm -f "$$tmp"' 0 1 2 15; \
	if ! $(HOSTCC) $(HOST_CFLAGS) $(SANITIZE) \
			-DT13_LFUSE=$(LFUSE) -DT13_HFUSE=$(HFUSE) \
			-DT85_LFUSE=$(LFUSE_X5) -DT85_HFUSE=$(HFUSE_X5) \
			-DT202_WDTCFG=$(XT_FUSE_WDTCFG) -DT202_BODCFG=$(XT_FUSE_BODCFG) \
			-DT202_OSCCFG=$(XT_FUSE_OSCCFG) -DT202_SYSCFG0=$(XT_FUSE_SYSCFG0) \
			-DT202_SYSCFG1=$(XT_FUSE_SYSCFG1) -DT202_APPEND=$(XT_FUSE_APPEND) \
			-DT202_BOOTEND=$(XT_FUSE_BOOTEND) \
			$< -o "$$tmp"; then \
		exit 1; \
	fi; \
	if [ ! -f "$$tmp" ] || [ -L "$$tmp" ] || [ ! -s "$$tmp" ] || [ ! -x "$$tmp" ]; then \
		echo "FAIL: compiler produced no executable fuse checker"; exit 1; \
	fi; \
	if ! mv "$$tmp" "$@"; then exit 1; fi; \
	trap - 0 1 2 15

# Static stack-frame bound via -fstack-usage: compile every firmware TU with
# the flag, collect the per-function .su files, and fail if any single frame
# exceeds STACK_MAX_FRAME bytes.  Complements the runtime HWM test (test-sim)
# with a compile-time structural upper bound that does not depend on exercising
# the deepest call path.  Override: make test-stack-bound STACK_MAX_FRAME=16
test-stack-bound:
	@stack_dir="$(STACK_BUILD_DIR)"; remove_dir=0; \
	if [ -z "$$stack_dir" ]; then \
		stack_dir=$$(mktemp -d "$${TMPDIR:-/tmp}/mcu-stack-bound.XXXXXX") \
			|| { echo "FAIL: could not create private stack-evidence directory"; exit 1; }; \
		remove_dir=1; \
	elif ! mkdir -p "$$stack_dir"; then \
		echo "FAIL: could not create stack-evidence directory $$stack_dir"; exit 1; \
	fi; \
	cleanup_stack_bound() { \
		rc=$$?; \
		rm -f "$$stack_dir"/stack_*.o "$$stack_dir"/stack_*.su || rc=1; \
		if [ "$$remove_dir" -eq 1 ]; then rmdir "$$stack_dir" || rc=1; fi; \
		trap - 0; exit $$rc; \
	}; \
	trap cleanup_stack_bound 0; \
	if ! rm -f "$$stack_dir"/stack_*.o "$$stack_dir"/stack_*.su; then \
		echo "FAIL: could not remove stale stack evidence"; exit 1; \
	fi; \
	if ! awk -v max="$(STACK_MAX_FRAME)" 'BEGIN {exit !(max ~ /^[0-9]+$$/ && max ~ /[1-9]/)}'; then \
		echo "FAIL: STACK_MAX_FRAME must be a positive decimal integer"; exit 2; \
	fi; \
	echo "=== -fstack-usage static bound (limit: $(STACK_MAX_FRAME) B/frame) ==="; \
	expected=0; \
	for f in $(STACK_SOURCES); do \
		case $$f in \
			*cd4053_with_mute*) m=CD4053_WITH_MUTE ;; \
			*tq2_l2_5v_relay*)  m=TQ2_L2_5V_RELAY ;; \
			*)                  m=CD4053_SIMPLE ;; \
		esac; \
		base=$$(basename "$$f" .c); \
		obj="$$stack_dir/stack_$${base}_$${m}.o"; \
		su="$${obj%.o}.su"; \
		expected=$$((expected + 1)); \
		if ! $(CC) $(CFLAGS) -D$$m -fstack-usage -c "$$f" -o "$$obj"; then \
			echo "FAIL: compilation error during -fstack-usage build: $$f"; exit 1; \
		fi; \
		if [ ! -s "$$obj" ]; then \
			echo "FAIL: compiler produced no stack-check object for $$f"; exit 1; \
		fi; \
		if [ ! -s "$$su" ]; then \
			echo "FAIL: compiler produced no stack-usage report for $$f"; exit 1; \
		fi; \
	done; \
	set -- "$$stack_dir"/stack_*.o; \
	actual_obj=$$#; [ -e "$$1" ] || actual_obj=0; \
	if [ "$$actual_obj" -ne "$$expected" ]; then \
		echo "FAIL: expected $$expected stack-check objects, found $$actual_obj"; exit 1; \
	fi; \
	set -- "$$stack_dir"/stack_*.su; \
	actual_su=$$#; [ -e "$$1" ] || actual_su=0; \
	if [ "$$actual_su" -ne "$$expected" ]; then \
		echo "FAIL: expected $$expected stack-usage reports, found $$actual_su"; exit 1; \
	fi; \
	echo "Per-function stack frames:"; \
	if ! cat "$$@"; then echo "FAIL: could not read stack-usage reports"; exit 1; fi; \
	if ! awk -F'\t' -v max="$(STACK_MAX_FRAME)" ' \
		function decimal_gt(a, b) { \
			sub(/^0+/, "", a); sub(/^0+/, "", b); \
			if (a == "") a = "0"; if (b == "") b = "0"; \
			if (length(a) != length(b)) return length(a) > length(b); \
			return ("x" a) > ("x" b) \
		} \
		BEGIN { bad = 0; records = 0 } \
		NF != 3 || $$1 == "" || $$2 !~ /^[0-9]+$$/ || $$3 != "static" { \
			printf "invalid stack-usage record: %s\n", $$0 > "/dev/stderr"; bad = 1; next \
		} \
		{ records++; if (decimal_gt($$2, max)) { \
			printf "frame exceeds %s B: %s\n", max, $$0 > "/dev/stderr"; bad = 1 \
		} } \
		END { if (records == 0) { print "no stack-usage records" > "/dev/stderr"; bad = 1 } \
			exit bad }' "$$@"; then \
		echo "FAIL: invalid or oversized stack frame evidence"; exit 1; \
	fi; \
	echo "OK: $$actual_su fresh reports; all frames <= $(STACK_MAX_FRAME) B"

# Fake-compiler regression checks for stale, missing, and malformed .su evidence.
test-stack-bound-regression:
	./test/test_stack_bound.sh

# Flash-utilization budget assertion: run avr-size on every ATtiny13a variant
# ELF and fail if flash (Program bytes) exceeds FLASH_T13_BUDGET% of 1024 B.
# Firmware is ~46% today; a future accidental bloat would otherwise pass
# silently.  Override: make test-flash-budget FLASH_T13_BUDGET=80
test-flash-budget:
	@if [ "$(MCU)" != "$(FLASH_T13_MCU)" ] || [ "$(FW_BASE)" != "bypass" ] \
			|| [ "$(AVR_FW)" != "$(AVR_BUILD_DIR)/bypass" ]; then \
		echo "FAIL: test-flash-budget requires MCU=attiny13a, FW_BASE=bypass, and the canonical AVR_FW"; \
		exit 2; \
	fi; \
	if [ "$(words $(strip $(VARIANTS)))" -ne 3 ] \
			|| [ "$(words $(sort $(VARIANTS)))" -ne 3 ] \
			|| [ "$(words $(FLASH_T13_UNKNOWN))" -ne 0 ]; then \
		echo "FAIL: test-flash-budget requires the complete cd4053/mute/relay variant matrix"; \
		exit 2; \
	fi
	@$(MAKE) --no-print-directory _test-flash-budget-measure

.PHONY: _test-flash-budget-measure
_test-flash-budget-measure: $(FLASH_T13_ELFS)
	./test/check_flash_budget.sh "$(SIZE)" "$(FLASH_T13_MCU)" "$(FLASH_T13_BYTES)" \
		"$(FLASH_T13_BUDGET)" 3 \
		$(FLASH_T13_ELFS)

# Fake-size regression checks for missing, malformed, and partial measurements.
test-flash-budget-regression:
	./test/test_flash_budget.sh

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
test/avr/test_sim_$(1): $$(SIM_DEPS) $(AVR_FW)_$(1).elf FORCE
	$$(HOSTCC) $$(SIM_CFLAGS) $$(SIM_DEFS) $$(PURE_HOST_CFLAGS) -D$$(macro_$(1)) -Itest \
		-DFW_PATH=\"$(AVR_FW)_$(1).elf\" \
		test/avr/test_sim.c $$(PURE_HOST_SRC) -o $$@ $$(SIM_LIBS)

test/avr/test_trace_$(1): $$(SIM_DEPS) $(AVR_FW)_$(1).elf FORCE
	$$(HOSTCC) $$(SIM_CFLAGS) $$(SIM_DEFS) $$(PURE_HOST_CFLAGS) -D$$(macro_$(1)) -DTRACE -Itest \
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
test/avr/test_sim_$(1)_t$(2): $$(SIM_DEPS) $(AVR_FW)_$(1)_t$(2).elf FORCE
	$$(HOSTCC) $$(SIM_CFLAGS) $$(SIM_DEFS) $$(PURE_HOST_CFLAGS) -D$$(macro_$(1)) -Itest \
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
#
# Each aggregate dispatches its (variant x MCU) fan-out through a recursive
# `$(MAKE) -jSIM_JOBS`. The individual runs are independent: every ELF compiles
# in a single command to a distinct output (no shared .o), and every simavr run
# only reads its own ELF and asserts via exit code (the VCD writer is TRACE-only,
# not built here), so nothing is shared and the runs parallelize cleanly. The
# recursive phase also preserves the original ordering guarantee -- for test-sim,
# the validated ELF/flash-budget build finishes before any simulator target
# consumes it: test-flash-budget is a parent-graph prerequisite (so an explicitly
# requested test-flash-budget coalesces with it under -j), and the recursive
# simulator phase starts only after that validated ELF build has completed.
#
# SIM_JOBS caps how many runs execute at once; it defaults to the core count and
# is overridable (SIM_JOBS=1 forces the old serial behaviour, SIM_JOBS=4 leaves
# headroom). Wall time drops to roughly the slowest single run rather than their
# sum.
SIM_JOBS ?= $(shell nproc 2>/dev/null || echo 4)

test-sim: test-flash-budget
	@$(MAKE) --no-print-directory -j$(SIM_JOBS) $(FLASH_T13_OLD_FILE_ARGS) \
		_test-sim-run SIM_DEFS="$(SIM_DEFS)" AVR_REBUILD_PREREQ=
_test-sim-run: $(foreach v,$(VARIANTS),test-sim-$(v))
$(foreach n,$(TINYX5),$(eval test-sim-t$(n): $(foreach v,$(VARIANTS),test-sim-$(v)-t$(n))))
test-sim-secondary:
	@$(MAKE) --no-print-directory -j$(SIM_JOBS) _test-sim-secondary-run SIM_DEFS="$(SIM_DEFS)"
_test-sim-secondary-run: $(foreach n,$(TINYX5),test-sim-t$(n))
test-fault-inject:
	@$(MAKE) --no-print-directory -j$(SIM_JOBS) _test-fault-inject-run SIM_DEFS="$(SIM_DEFS)"
_test-fault-inject-run: $(foreach v,$(VARIANTS),$(foreach n,$(TINYX5),test-fault-inject-$(v)-t$(n)))
.PHONY: test-sim _test-sim-run test-sim-secondary _test-sim-secondary-run \
        test-fault-inject _test-fault-inject-run \
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
#   SOAK_VARIANT=relay        variant to test (cd4053/mute/relay; default cd4053)
#   SOAK_CHIP=45              tinyx5 chip number (85/45; default 85)
#   SOAK_DURATION_MS=3600000  simulated duration in ms (default 86400000 = 24 h)
#   SOAK_LIVENESS_INTERVAL_MS=10000   liveness-check interval (default 60000 ms)
SOAK_VARIANT     ?= cd4053
SOAK_CHIP        ?= 85
SOAK_DURATION_MS ?= 86400000
SOAK_BIN  = test/avr/test_soak_$(SOAK_VARIANT)_t$(SOAK_CHIP)
SOAK_DEPS = test/avr/test_soak.c test/bypass_output_host.h test/bypass_config_host.h \
            test/soak_timing_config.h src/bypass_config.h $(FW_HEADERS)

# The SOAK_* variables (-DSOAK_DURATION_MS, -DSOAK_LIVENESS_INTERVAL_MS, etc.)
# are baked into the binary at compile time. To ensure command-line overrides
# (e.g. `make test-soak SOAK_DURATION_MS=3600000`) are always picked up, the
# test-soak recipe is phony and always recompiles before running.
SOAK_LIVENESS_INTERVAL_MS  ?= 60000
SOAK_PROGRESS_INTERVAL_MS  ?= 3600000
SOAK_COMPILE = $(HOSTCC) $(SIM_CFLAGS) $(PURE_HOST_CFLAGS) \
	-D$(macro_$(SOAK_VARIANT)) \
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
		echo "cppcheck not installed; skipping MISRA analysis"; $(SKIP); \
	fi; \
	if ! command -v python3 >/dev/null 2>&1; then \
		echo "python3 not found (required by the cppcheck misra addon); skipping"; $(SKIP); \
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
		echo "cppcheck and/or python3 not available; skipping MISRA report"; $(SKIP); \
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
COVERAGE_SRC = test/host/test_logic_host.c
COVERAGE_REPORT_DIR = $(COVERAGE_DIR)/report
COVERAGE_OBJ_NAME = test_logic_host_cov.o
COVERAGE_BIN_NAME = test_logic_host_cov
COVERAGE_DATA_NAME = test_logic_host_cov.gcda
COVERAGE_ANNOTATION = test_logic_host.c.gcov

define RUN_GOLDEN_MODEL_COVERAGE
	rm -rf "$(1)" || exit 1; \
	mkdir -p "$(1)" || exit 1; \
	$(HOSTCC) $(HOST_CFLAGS) $(HOST_DEFS) -Itest --coverage -c $(abspath $(COVERAGE_SRC)) \
		-o "$(1)/$(COVERAGE_OBJ_NAME)" || exit 1; \
	$(HOSTCC) --coverage "$(1)/$(COVERAGE_OBJ_NAME)" \
		-o "$(1)/$(COVERAGE_BIN_NAME)" || exit 1; \
	"$(1)/$(COVERAGE_BIN_NAME)" >/dev/null || exit 1; \
	if [ ! -f "$(1)/$(COVERAGE_DATA_NAME)" ] || \
	   [ ! -s "$(1)/$(COVERAGE_DATA_NAME)" ]; then \
		echo "FAIL: coverage run did not produce fresh profile data in $(1)"; exit 1; \
	fi
endef

# Human-readable coverage report of the golden model (line + branch via gcov).
# Use this when you want to SEE coverage; use coverage-check to ENFORCE it.
coverage:
	@$(call RUN_GOLDEN_MODEL_COVERAGE,$(COVERAGE_REPORT_DIR))
	@out=`cd "$(COVERAGE_REPORT_DIR)" && $(GCOV) -b -o . $(COVERAGE_OBJ_NAME) 2>&1` \
		|| { printf '%s\n' "$$out"; echo "FAIL: gcov could not generate golden-model coverage"; exit 1; }; \
	if [ ! -f "$(COVERAGE_REPORT_DIR)/$(COVERAGE_ANNOTATION)" ] || \
	   [ ! -s "$(COVERAGE_REPORT_DIR)/$(COVERAGE_ANNOTATION)" ]; then \
		echo "FAIL: gcov reported success but did not produce $(COVERAGE_ANNOTATION)"; \
		printf '%s\n' "$$out"; exit 1; \
	fi; \
	printf '%s\n' "$$out"
	@echo "Coverage report: $(COVERAGE_REPORT_DIR)/$(COVERAGE_ANNOTATION)"
	@echo "For HTML report: lcov --capture -d $(COVERAGE_REPORT_DIR) -o $(COVERAGE_DIR)/coverage.info && genhtml $(COVERAGE_DIR)/coverage.info -o $(COVERAGE_DIR)/html"

# Coverage GATE (wired into `make test`): build the model with coverage, run it,
# and FAIL the build if golden-model line coverage drops below COVERAGE_MIN.
coverage-check:
	@mkdir -p "$(COVERAGE_DIR)" || exit 1; \
	work=`mktemp -d "$(COVERAGE_DIR)/check.XXXXXX"` || exit 1; \
	trap 'rm -rf "$$work"' EXIT HUP INT TERM; \
	$(call RUN_GOLDEN_MODEL_COVERAGE,$$work); \
	out=`cd "$$work" && $(GCOV) -o . $(COVERAGE_OBJ_NAME) 2>&1` \
		|| { printf '%s\n' "$$out"; echo "FAIL: gcov could not generate golden-model coverage"; exit 1; }; \
	pct=`printf '%s\n' "$$out" | awk -F'[:%]' '/Lines executed/{print $$2; exit}'`; \
	echo "golden-model line coverage: $${pct:-unknown}% (floor $(COVERAGE_MIN)%)"; \
	if ! printf '%s\n' "$$pct" | grep -Eq '^[0-9]+([.][0-9]+)?$$'; then \
		echo "FAIL: gcov line coverage is missing or malformed:"; \
		printf '%s\n' "$$out"; exit 1; \
	fi; \
	if [ ! -f "$$work/$(COVERAGE_ANNOTATION)" ] || \
	   [ ! -s "$$work/$(COVERAGE_ANNOTATION)" ]; then \
		echo "FAIL: gcov reported success but did not produce a fresh $(COVERAGE_ANNOTATION)"; \
		printf '%s\n' "$$out"; exit 1; \
	fi; \
	if ! printf '%s\n' "$(COVERAGE_MIN)" | grep -Eq '^[0-9]+([.][0-9]+)?$$'; then \
		echo "FAIL: COVERAGE_MIN is malformed: $(COVERAGE_MIN)"; exit 1; \
	fi; \
	awk -v p="$$pct" -v m="$(COVERAGE_MIN)" 'BEGIN{exit !(p>=0 && p<=100 && m>=0 && m<=100)}' \
		|| { echo "FAIL: coverage percentage or floor is outside 0..100"; exit 1; }; \
	awk -v p="$$pct" -v m="$(COVERAGE_MIN)" 'BEGIN{exit !(p>=m)}' \
		|| { echo "FAIL: coverage $$pct% below floor $(COVERAGE_MIN)%"; exit 1; }

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
	@echo "  pic-test        all PIC pre-hardware checks (CONFIG + analysis + source coverage + gpsim)"
	@echo "  pic-test-config build PIC HEX, then verify each CONFIG word vs design intent"
	@echo "  pic-analyze     cppcheck + MISRA on the PIC shell (XC8/DFP headers; standalone)"
	@echo "  pic-coverage-check-fw  exact host-gcov gate over PIC shell, core, and drivers"
	@echo "  pic-test-gpsim  drive the footswitch in gpsim, assert PORTA/LATA toggle"
	@echo "  pic-test-soak   libgpsim soak: WDT liveness + responsiveness (standalone; needs"
	@echo "                  gpsim-dev+libglib2.0-dev; PIC_SOAK_VARIANT, PIC_SOAK_DURATION_MS)"
	@echo "  pic-test-fault  libgpsim fault-inject: corrupt a critical SFR, assert the gate"
	@echo "                  forces a WDT reset (standalone; needs gpsim-dev; PIC_FAULT_VARIANT)"
	@echo "  pic-test-lockstep  libgpsim HEX-vs-model ctx_ lock-step (PIC_LOCKSTEP_VARIANT)"
	@echo "  pic-test-io     libgpsim GPIO transition + pulse timing check (PIC_IO_VARIANT)"
	@echo "  pic-test-target fail-closed fault + lock-step + target-I/O for one PIC variant"
	@echo "                  (PIC_TARGET_VARIANT); pic-test-target-variants runs all variants"
	@echo "  program-pic     flash one PIC variant to hardware (VARIANT=, PIC_PROG=pk2cmd|ipecmd)"
	@echo "ATtiny202 DEVELOPMENT-ONLY / NON-RELEASE (AVR-XT / avrxmega3):"
	@echo "  scripts/fetch_attiny_dfp.sh [DIR]  vendor the pinned device files (default XT_DFP=$(XT_DFP))"
	@echo "  attiny202-smoke  Phase-0 gate: compile/link test/avr/attiny202_smoke.c, assert"
	@echo "                   avrxmega3 + $(XT_FLASH_BYTES) B budget (standalone; skips if XT_DFP absent)"
	@echo "  attiny202        build all variants for ATtiny202 + 2 KB flash-budget gate"
	@echo "  attiny202-analyze  cppcheck + MISRA on the AVR-XT shell (DFP+avr-libc; standalone)"
	@echo "  attiny202-test   all ATtiny202 pre-hardware checks (fuses + smoke + build + analyze)"
	@echo "  attiny202-sim    yasimavr functional test: drive footswitch, assert LED toggles"
	@echo "                   (standalone; needs scripts/fetch_yasimavr.sh; XT_SIM_VARIANT=)"
	@echo "  attiny202-fault  yasimavr fault-inject: corrupt a guarded SFR/state, assert the"
	@echo "                   gate or WDT catches it (standalone; XT_SIM_VARIANT=)"
	@echo "  attiny202-soak   yasimavr soak: long run, assert no WDT reset + stays responsive"
	@echo "                   (standalone; XT_SOAK_DURATION_MS=, XT_SIM_VARIANT=)"
	@echo "  attiny202-program  set fuses + flash one variant over UPDI (VARIANT=, XT_UPDI_PORT=)"
	@echo "Test (each runs across ALL variants):"
	@echo "  test            FAST full suite -- analyze, model, sim (all MCUs), coverage"
	@echo "  test-long       FULL exhaustive suite (minutes); alias: stress"
	@echo "  scripts/ci-local.sh  reproduce the GitHub CI suite locally before pushing (--pr, --help)"
	@echo "  test-host       golden-model algorithm tests (host, variant-agnostic)"
	@echo "  test-model-check exhaustive state-space proof of invariants"
	@echo "  test-symbolic   exhaustive single-step property proof of step()"
	@echo "  test-symbolic-klee  same properties under KLEE (if installed)"
	@echo "  test-cbmc       CBMC SAT/SMT proof of the real bypass_pure.c (if installed)"
	@echo "  test-fuses      decode + verify design fuse bytes (t13a + tinyx5 + ATtiny202)"
	@echo "  test-stack-bound  -fstack-usage static frame bound (limit: STACK_MAX_FRAME=$(STACK_MAX_FRAME) B)"
	@echo "  test-stack-bound-regression  fail-closed stack-evidence checks"
	@echo "  test-flash-budget  exact ATtiny13a gate (<= FLASH_T13_BUDGET=$(FLASH_T13_BUDGET)% of 1 KB)"
	@echo "  test-flash-budget-regression  fail-closed flash-measurement checks"
	@echo "  test-sim        real firmware in simavr, all variants (ATtiny13a)"
	@echo "  test-sim-t85 / test-sim-t45  all variants on that tinyx5 chip"
	@echo "  test-sim-secondary  all variants on every tinyx5 chip"
	@echo "  test-sim-<v>[-t<n>]  single variant, e.g. test-sim-relay / test-sim-relay-t45"
	@echo "  test-fault-inject  corrupt state, verify WDT recovery (all variants x tinyx5)"
	@echo "  test-mutation   inject firmware faults, verify the suite kills them"
	@echo "  test-attiny202-build  fail-closed AVR-XT image-generation checks"
	@echo "  test-avr-build-rebuild  classic AVR stale/config/partial-output checks"
	@echo "  test-gpsim-wrappers  fail-closed gpsim process-status checks"
	@echo "  test-pic-build  PIC image-generation and Intel-HEX validation checks"
	@echo "  test-release-images  exact committed/listed/fresh release artifact checks"
	@echo "  test-soak-timing  host-only soak timing boundary checks (included in test)"
	@echo "  test-workload-rebuild  workload/fuse rebuild regression checks"
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
	@echo "  release         VERSION=vX.Y.Z: build+validate AVR Classic + PIC10F322 release images"
	@echo "                  (incl. 24-h soak) + stage release/<ver>/; RELEASE_ARGS='--dry-run'"
	@echo "                  skips the soak; see scripts/make-release.sh"
	@echo "Clean:"
	@echo "  clean           remove build + test artifacts"
	@echo "  clean-tests     remove only test binaries"
	@echo "  coverage-clean  remove coverage artifacts"
	@echo "Overrides: VARIANT=, PROGRAMMER=, COVERAGE_MIN=, HOSTCC=, HOST_DEFS=, SIM_DEFS=, AVR_BUILD_DIR="
	@echo "PIC overrides: PIC_CC=, PIC_PROG=pk2cmd|ipecmd, PIC_PROG_TOOL=PK3|PK4|PK5, PIC_PROG_CMD="


# vim: tw=0 nowrap
