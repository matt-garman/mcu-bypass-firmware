# Build and validation recipes share worktree-local firmware images, host test
# binaries, coverage data, and simulator logs. Route each independent top-level
# invocation through one persistent flock, then execute the real graph serially.
# The two release goals are the exception only in mechanism: make-release.sh
# acquires this same lock itself, avoiding a recursive Make pass that could
# reinterpret untrusted VERSION/RELEASE_ARGS command-line text.
# Recipes that explicitly launch isolated recursive `$(MAKE) -jN` workloads may
# still use their reviewed internal parallelism. Recursive makes and release
# scripts inherit the held marker and must not reacquire the same lock.
_MAKE_SERIAL_WORKTREE_ID := $(shell stat -Lc '%d:%i' . 2>/dev/null)
ifeq ($(_MAKE_SERIAL_WORKTREE_ID),)
$(error ERROR: stat is required to identify the worktree serialization lock)
endif
# Matrix requests can arrive as recursive command-line variables. Preserve their
# literal words without expanding embedded GNU Make functions, expose only known
# names to rule generation, and forward safe metadata through the serialization
# submake so inner recipes can still distinguish empty/duplicate/unknown input.
override CLASSIC_VARIANTS_SUPPORTED := cd4053_simple cd4053_with_mute tq2_l2_5v_relay
override PIC10F320_VARIANTS_SUPPORTED := cd4053_simple cd4053_with_mute tq2_l2_5v_relay
_MAKE_SERIAL_VARIANT_ORIGIN := $(origin VARIANT)
ifeq ($(_MAKE_SERIAL_VARIANT_ORIGIN),undefined)
_MAKE_SERIAL_VARIANT_REQUESTED := cd4053_simple
else
_MAKE_SERIAL_VARIANT_REQUESTED := $(value VARIANT)
endif
_MAKE_SERIAL_VARIANT_SAFE := $(filter $(CLASSIC_VARIANTS_SUPPORTED),$(_MAKE_SERIAL_VARIANT_REQUESTED))
_MAKE_SERIAL_VARIANT_EMPTY_COMPUTED := $(if $(strip $(_MAKE_SERIAL_VARIANT_REQUESTED)),0,1)
_MAKE_SERIAL_VARIANT_MULTI_COMPUTED := $(if $(word 2,$(_MAKE_SERIAL_VARIANT_REQUESTED)),1,0)
_MAKE_SERIAL_VARIANT_UNKNOWN_COMPUTED := $(if $(filter-out $(CLASSIC_VARIANTS_SUPPORTED),$(_MAKE_SERIAL_VARIANT_REQUESTED)),1,0)
_MAKE_SERIAL_PIC12F675_TARGET_VARIANT_ORIGIN := $(origin PIC12F675_TARGET_VARIANT)
ifeq ($(_MAKE_SERIAL_PIC12F675_TARGET_VARIANT_ORIGIN),undefined)
_MAKE_SERIAL_PIC12F675_TARGET_VARIANT_REQUESTED := cd4053_simple
else
_MAKE_SERIAL_PIC12F675_TARGET_VARIANT_REQUESTED := $(value PIC12F675_TARGET_VARIANT)
endif
_MAKE_SERIAL_PIC12F675_TARGET_VARIANT_SAFE := $(filter $(CLASSIC_VARIANTS_SUPPORTED),$(_MAKE_SERIAL_PIC12F675_TARGET_VARIANT_REQUESTED))
_MAKE_SERIAL_PIC12F675_TARGET_VARIANT_EMPTY_COMPUTED := $(if $(strip $(_MAKE_SERIAL_PIC12F675_TARGET_VARIANT_REQUESTED)),0,1)
_MAKE_SERIAL_PIC12F675_TARGET_VARIANT_MULTI_COMPUTED := $(if $(word 2,$(_MAKE_SERIAL_PIC12F675_TARGET_VARIANT_REQUESTED)),1,0)
_MAKE_SERIAL_PIC12F675_TARGET_VARIANT_UNKNOWN_COMPUTED := $(if $(filter-out $(CLASSIC_VARIANTS_SUPPORTED),$(_MAKE_SERIAL_PIC12F675_TARGET_VARIANT_REQUESTED)),1,0)

# Preserve the release-programming tag as literal data across the serialization
# submake. A dollar cannot occur in a valid release tag; reject it before GNU
# Make could reinterpret a command-line value in the child process.
_MAKE_SERIAL_PIC12F675_RELEASE_TAG_ORIGIN := $(origin PIC12F675_RELEASE_TAG)
ifeq ($(_MAKE_SERIAL_PIC12F675_RELEASE_TAG_ORIGIN),undefined)
_MAKE_SERIAL_PIC12F675_RELEASE_TAG_REQUESTED :=
else
_MAKE_SERIAL_PIC12F675_RELEASE_TAG_REQUESTED := $(value PIC12F675_RELEASE_TAG)
endif
_MAKE_SERIAL_DOLLAR := $$
ifneq ($(filter pic12f675-release-program,$(MAKECMDGOALS)),)
ifneq ($(findstring $(_MAKE_SERIAL_DOLLAR),$(_MAKE_SERIAL_PIC12F675_RELEASE_TAG_REQUESTED)),)
$(error PIC12F675_RELEASE_TAG must not contain dollar signs)
endif
endif
ifneq ($(filter pic12f675-program,$(MAKECMDGOALS)),)
ifneq ($(filter pic12f675-release-program,$(MAKECMDGOALS)),)
$(error request only one PIC12F675 programming target per Make invocation)
endif
endif
override PIC12F675_RELEASE_TAG := $(_MAKE_SERIAL_PIC12F675_RELEASE_TAG_REQUESTED)
export PIC12F675_RELEASE_TAG

_MAKE_SERIAL_VARIANTS_ORIGIN := $(origin VARIANTS)
ifeq ($(_MAKE_SERIAL_VARIANTS_ORIGIN),undefined)
_MAKE_SERIAL_VARIANTS_REQUESTED := $(CLASSIC_VARIANTS_SUPPORTED)
else
_MAKE_SERIAL_VARIANTS_REQUESTED := $(value VARIANTS)
endif
_MAKE_SERIAL_VARIANTS_SAFE := $(filter $(CLASSIC_VARIANTS_SUPPORTED),$(_MAKE_SERIAL_VARIANTS_REQUESTED))
_MAKE_SERIAL_CLASSIC_EMPTY_COMPUTED := $(if $(strip $(_MAKE_SERIAL_VARIANTS_REQUESTED)),0,1)
_MAKE_SERIAL_CLASSIC_UNKNOWN_COMPUTED := $(if $(filter-out $(CLASSIC_VARIANTS_SUPPORTED),$(_MAKE_SERIAL_VARIANTS_REQUESTED)),1,0)
ifneq ($(words $(_MAKE_SERIAL_VARIANTS_REQUESTED)),$(words $(sort $(_MAKE_SERIAL_VARIANTS_REQUESTED))))
_MAKE_SERIAL_CLASSIC_DUPLICATE_COMPUTED := 1
else
_MAKE_SERIAL_CLASSIC_DUPLICATE_COMPUTED := 0
endif

_MAKE_SERIAL_PIC320_VARIANTS_ORIGIN := $(origin PIC10F320_VARIANTS_ALL)
ifeq ($(_MAKE_SERIAL_PIC320_VARIANTS_ORIGIN),undefined)
_MAKE_SERIAL_PIC320_VARIANTS_REQUESTED := $(PIC10F320_VARIANTS_SUPPORTED)
else
_MAKE_SERIAL_PIC320_VARIANTS_REQUESTED := $(value PIC10F320_VARIANTS_ALL)
endif
_MAKE_SERIAL_PIC320_VARIANTS_SAFE := $(filter $(PIC10F320_VARIANTS_SUPPORTED),$(_MAKE_SERIAL_PIC320_VARIANTS_REQUESTED))
_MAKE_SERIAL_PIC320_EMPTY_COMPUTED := $(if $(strip $(_MAKE_SERIAL_PIC320_VARIANTS_REQUESTED)),0,1)
_MAKE_SERIAL_PIC320_UNKNOWN_COMPUTED := $(if $(filter-out $(PIC10F320_VARIANTS_SUPPORTED),$(_MAKE_SERIAL_PIC320_VARIANTS_REQUESTED)),1,0)
ifneq ($(words $(_MAKE_SERIAL_PIC320_VARIANTS_REQUESTED)),$(words $(sort $(_MAKE_SERIAL_PIC320_VARIANTS_REQUESTED))))
_MAKE_SERIAL_PIC320_DUPLICATE_COMPUTED := 1
else
_MAKE_SERIAL_PIC320_DUPLICATE_COMPUTED := 0
endif

ifeq ($(origin _MAKE_SERIAL_VARIANT_EMPTY),environment)
override VARIANT_REQUEST_EMPTY := $(value _MAKE_SERIAL_VARIANT_EMPTY)
override VARIANT_REQUEST_MULTI := $(value _MAKE_SERIAL_VARIANT_MULTI)
override VARIANT_REQUEST_UNKNOWN := $(value _MAKE_SERIAL_VARIANT_UNKNOWN)
else
override VARIANT_REQUEST_EMPTY := $(_MAKE_SERIAL_VARIANT_EMPTY_COMPUTED)
override VARIANT_REQUEST_MULTI := $(_MAKE_SERIAL_VARIANT_MULTI_COMPUTED)
override VARIANT_REQUEST_UNKNOWN := $(_MAKE_SERIAL_VARIANT_UNKNOWN_COMPUTED)
endif
ifeq ($(origin _MAKE_SERIAL_CLASSIC_EMPTY),environment)
override CLASSIC_VARIANTS_REQUEST_EMPTY := $(value _MAKE_SERIAL_CLASSIC_EMPTY)
override CLASSIC_VARIANTS_REQUEST_DUPLICATE := $(value _MAKE_SERIAL_CLASSIC_DUPLICATE)
override CLASSIC_VARIANTS_REQUEST_UNKNOWN := $(value _MAKE_SERIAL_CLASSIC_UNKNOWN)
else
override CLASSIC_VARIANTS_REQUEST_EMPTY := $(_MAKE_SERIAL_CLASSIC_EMPTY_COMPUTED)
override CLASSIC_VARIANTS_REQUEST_DUPLICATE := $(_MAKE_SERIAL_CLASSIC_DUPLICATE_COMPUTED)
override CLASSIC_VARIANTS_REQUEST_UNKNOWN := $(_MAKE_SERIAL_CLASSIC_UNKNOWN_COMPUTED)
endif
ifeq ($(origin _MAKE_SERIAL_PIC320_EMPTY),environment)
override PIC10F320_VARIANTS_REQUEST_EMPTY := $(value _MAKE_SERIAL_PIC320_EMPTY)
override PIC10F320_VARIANTS_REQUEST_DUPLICATE := $(value _MAKE_SERIAL_PIC320_DUPLICATE)
override PIC10F320_VARIANTS_REQUEST_UNKNOWN := $(value _MAKE_SERIAL_PIC320_UNKNOWN)
else
override PIC10F320_VARIANTS_REQUEST_EMPTY := $(_MAKE_SERIAL_PIC320_EMPTY_COMPUTED)
override PIC10F320_VARIANTS_REQUEST_DUPLICATE := $(_MAKE_SERIAL_PIC320_DUPLICATE_COMPUTED)
override PIC10F320_VARIANTS_REQUEST_UNKNOWN := $(_MAKE_SERIAL_PIC320_UNKNOWN_COMPUTED)
endif
ifeq ($(origin _MAKE_SERIAL_PIC12F675_TARGET_VARIANT_EMPTY),environment)
override PIC12F675_TARGET_VARIANT_REQUEST_EMPTY := $(value _MAKE_SERIAL_PIC12F675_TARGET_VARIANT_EMPTY)
override PIC12F675_TARGET_VARIANT_REQUEST_MULTI := $(value _MAKE_SERIAL_PIC12F675_TARGET_VARIANT_MULTI)
override PIC12F675_TARGET_VARIANT_REQUEST_UNKNOWN := $(value _MAKE_SERIAL_PIC12F675_TARGET_VARIANT_UNKNOWN)
else
override PIC12F675_TARGET_VARIANT_REQUEST_EMPTY := $(_MAKE_SERIAL_PIC12F675_TARGET_VARIANT_EMPTY_COMPUTED)
override PIC12F675_TARGET_VARIANT_REQUEST_MULTI := $(_MAKE_SERIAL_PIC12F675_TARGET_VARIANT_MULTI_COMPUTED)
override PIC12F675_TARGET_VARIANT_REQUEST_UNKNOWN := $(_MAKE_SERIAL_PIC12F675_TARGET_VARIANT_UNKNOWN_COMPUTED)
endif
override VARIANT := $(if $(_MAKE_SERIAL_VARIANT_SAFE),$(_MAKE_SERIAL_VARIANT_SAFE),cd4053_simple)
override VARIANTS := $(_MAKE_SERIAL_VARIANTS_SAFE)
override PIC10F320_VARIANTS_ALL := $(_MAKE_SERIAL_PIC320_VARIANTS_SAFE)
override PIC12F675_TARGET_VARIANT := $(if $(_MAKE_SERIAL_PIC12F675_TARGET_VARIANT_SAFE),$(_MAKE_SERIAL_PIC12F675_TARGET_VARIANT_SAFE),cd4053_simple)

_make_shell_quote = '$(subst ','"'"',$(1))'
_MAKE_RELEASE_DIRECT := $(if $(filter release release-preflight,$(MAKECMDGOALS)),$(if $(word 2,$(MAKECMDGOALS)),,1))
_MAKE_SERIAL_LOCK_WAS_HELD := $(if $(filter $(_MAKE_SERIAL_WORKTREE_ID),$(_MAKE_SERIAL_LOCK_HELD)),1,0)
ifeq ($(_MAKE_RELEASE_DIRECT),1)
ifeq ($(_MAKE_SERIAL_LOCK_WAS_HELD),0)
override _MAKE_SERIAL_LOCK_HELD := $(_MAKE_SERIAL_WORKTREE_ID)
_MAKE_RELEASE_LOCK_IN_SCRIPT := 1
endif
endif
ifneq ($(findstring q,$(firstword $(MAKEFLAGS))),)
override _MAKE_SERIAL_LOCK_HELD := $(_MAKE_SERIAL_WORKTREE_ID)
endif

ifeq ($(_MAKE_SERIAL_LOCK_HELD),$(_MAKE_SERIAL_WORKTREE_ID))
ifeq ($(_MAKE_RELEASE_LOCK_IN_SCRIPT),1)
unexport _MAKE_SERIAL_LOCK_HELD
else
export _MAKE_SERIAL_LOCK_HELD
endif
unexport _MAKE_SERIAL_VARIANT_EMPTY _MAKE_SERIAL_VARIANT_MULTI \
         _MAKE_SERIAL_VARIANT_UNKNOWN \
         _MAKE_SERIAL_CLASSIC_EMPTY _MAKE_SERIAL_CLASSIC_DUPLICATE \
         _MAKE_SERIAL_CLASSIC_UNKNOWN _MAKE_SERIAL_PIC320_EMPTY \
		 _MAKE_SERIAL_PIC320_DUPLICATE _MAKE_SERIAL_PIC320_UNKNOWN \
		 _MAKE_SERIAL_PIC12F675_TARGET_VARIANT_EMPTY \
		 _MAKE_SERIAL_PIC12F675_TARGET_VARIANT_MULTI \
		 _MAKE_SERIAL_PIC12F675_TARGET_VARIANT_UNKNOWN

################################################################################
# bypass -- build / test / flash Makefile
################################################################################
#
# WHAT THIS BUILDS
#   A hardware-agnostic core (bypass_mcu_avr_classic.c) plus one interchangeable
#   output driver, selected at build time:
#     - cd4053_simple    : CD4053 analog switch, single control line (CD4053_SIMPLE)
#     - cd4053_with_mute : CD4053 with mute-before-switch (CD4053_WITH_MUTE)
#     - tq2_l2_5v_relay  : Panasonic TQ2-L2-5V latching relay, pulsed coils (TQ2_L2_5V_RELAY)
#   The two CD4053 images drive a single MCU polarity (bypass = pin low, the
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
#   AVR_BUILD_DIR=...), named bypass-<mcu>-<output stage>.elf/.hex -- e.g.
#   bypass-attiny13a-cd4053_simple.elf, bypass-attiny85-tq2_l2_5v_relay.hex.
#   See "canonical firmware image basename" below; note the stage token is the
#   driver-source spelling, not the short VARIANT token. Pick a variant for
#   single-target actions with VARIANT=<name>, e.g.
#   `make VARIANT=tq2_l2_5v_relay attiny13a-program` (ATtiny13a) or
#   `make VARIANT=tq2_l2_5v_relay attiny45-program` (ATtiny45).
#
# HOW THE TESTS ARE LAYERED (fast -> thorough)
#   1. analyze            static analysis (clang-tidy / -fanalyzer)
#   2. test-host          independent "golden model" of the debounce algorithm
#   3. test-model-check   exhaustive proof of invariants over the whole state space
#   4. test-sim-attiny13a / -attiny85   the REAL compiled firmware run inside
#                         simavr, including lock-step co-simulation (firmware RAM
#                         vs golden model, compared every 1ms tick)
#   5. test-fault-inject  corrupt MCU state, verify watchdog-reset recovery (t85)
#   6. test-mutation      inject firmware faults, verify the suite detects them
#   7. coverage-check     fail if golden-model line coverage drops below a floor
#
# Host model tests (2,3) build with ASan+UBSan (SANITIZE=) by default.
# Firmware and workload-dependent test binaries rebuild once per requested Make
# graph, so current command-line flags and toolchain bytes are always consumed.
#
# COMMON COMMANDS
#   make                 build every release-supported part's variant images
#                        (.hex) + sizes
#   make test            fast full test suite (all variants) -- use constantly
#   make test-long       exhaustive test suite (minutes) -- before release/HW
#   make attiny13a-trace emit build_avr_classic/bypass_trace.vcd (VARIANT=, GTKWave)
#   make VARIANT=tq2_l2_5v_relay attiny13a-program   set fuses + flash one variant
#                        (one ordered transaction: the image is built and
#                        validated first, so a build failure writes no fuses)
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
#   AVR_PROGRAMMER=usbasp   use a different ISP programmer
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
# ATTINY13A_MCU   : primary production MCU (ATtiny13a)
# ATTINY13A_F_CPU : 1.2 MHz (9.6 MHz internal RC / CKDIV8)
# FW_BASE         : base name for .elf / .hex (suffixed per variant)
# CC              : AVR cross-compiler
# OBJCOPY : ELF -> Intel HEX
# SIZE    : flash/RAM usage reporter
# READELF : ELF architecture inspector
# AVRDUDE : ISP flashing tool
ATTINY13A_MCU      = attiny13a
ATTINY13A_F_CPU    = 1200000UL
FW_BASE  = bypass
CC       = avr-gcc
OBJCOPY  = avr-objcopy
OBJDUMP  ?= avr-objdump
SIZE     = avr-size
READELF  ?= readelf
IHEX_VALIDATOR ?= scripts/validate-ihex.sh
# Presence check for IHEX_VALIDATOR, shared by every phony recipe that runs it
# (`pic10f322`, `attiny202`, `pic10f320-size`, `pic12f675`,
# `pic12f675-preflight`, `pic12f675-program`, and `pic12f675-release-program`). The .hex FILE rules do not need it: they
# carry $(IHEX_VALIDATOR) as a real prerequisite, so Make refuses to run them if
# it is missing. A phony recipe gets no such protection, and it must not build an
# image it then cannot validate.
#
# `command -v` alone is NOT sufficient. For a value containing a slash, dash's
# `command -v` succeeds on a file that merely EXISTS -- a non-executable
# validator therefore passed the old check and failed later with "Permission
# denied", after objcopy had already produced the unvalidated image. Require -x
# whenever the value names a path, and fall back to a PATH lookup only for a
# bare command name.
IHEX_VALIDATOR_CHECK = case "$(IHEX_VALIDATOR)" in */*) [ -x "$(IHEX_VALIDATOR)" ] ;; *) command -v "$(IHEX_VALIDATOR)" >/dev/null 2>&1 ;; esac || { echo "FAIL: Intel HEX validator not found or not executable at $(IHEX_VALIDATOR)"; exit 1; }
AVRDUDE  = avrdude
# Software gate every AVR `*-program` transaction runs BEFORE the first avrdude
# invocation. A `*-program` goal writes fuses and then flash, so the fuse write
# is the first hardware mutation, and it sets the clock, watchdog and BOD
# configuration the part will run under from that moment on. If the image the
# flash step needs turns out to be missing -- a failed compile, a rejected
# Intel HEX, a build that never ran -- or if no programmer is installed,
# discovering it after the fuse write leaves a device carrying the design's
# fuses with no matching firmware, which is the one outcome a bench session
# cannot recover from without a second programmer pass.
#
# Two things therefore stand between the request and the first `avrdude`. The
# build that produces AND validates the selected image is a real prerequisite
# of the goal, so a build failure keeps Make out of the recipe entirely; and
# these checks run as the recipe's first line, while the device is still
# untouched. Used as:
#
#   hex="<path>"; $(AVR_PROGRAM_IMAGE_CHECK); $(AVR_PROGRAMMER_CHECK); ...
#
# by the ATtiny13A, tinyx5 and ATtiny202 program recipes. `*-fuses` and
# `*-flash` keep their single-step meaning and are NOT gated: a bench operator
# asking for exactly one of them has asked for exactly one hardware action.
AVR_PROGRAM_IMAGE_CHECK = [ -f "$$hex" ] || { echo "ERROR: $$hex not found -- no image was built for VARIANT=$(VARIANT)."; echo "       select a variant with VARIANT=<$(VARIANTS)>; no fuse or flash command has run."; exit 1; }
# Same -x rule as IHEX_VALIDATOR_CHECK above, for the same reason: dash's
# `command -v` succeeds on a merely EXISTING file when the value contains a
# slash, so a non-executable AVRDUDE=<path> would pass a PATH-only check and
# fail with "Permission denied" -- after the fuse write.
AVR_PROGRAMMER_CHECK = case "$(AVRDUDE)" in */*) [ -x "$(AVRDUDE)" ] ;; *) command -v "$(AVRDUDE)" >/dev/null 2>&1 ;; esac || { echo "ERROR: programmer '$(AVRDUDE)' not found or not executable; no fuse or flash command has run."; echo "       install avrdude, or name another with AVRDUDE=<path>."; exit 1; }
AVR_ELF_ARCH ?= avr:25

# --- AVR build-artifact directory --------------------------------------------
# Every AVR firmware image (.elf/.hex) and the trace .vcd is written here to
# keep the repo root clean -- the AVR counterpart of the PIC build's
# PIC10F322_BUILD_DIR. Override on the command line, e.g. `make AVR_BUILD_DIR=out`.
AVR_BUILD_DIR ?= build_avr_classic
# Per-image path stem: $(AVR_BUILD_DIR)/$(FW_BASE). The canonical image tail
# ($(call fw_image_tail,<variant>,<mcu-tag>) -- see "canonical firmware image
# basename" below) is appended to it, giving e.g.
# build_avr_classic/bypass-attiny85-cd4053_with_mute.elf.
AVR_FW         = $(AVR_BUILD_DIR)/$(FW_BASE)

# --- Secondary targets: the tinyx5 family (ATtiny25/45/85) ------------------
# These parts are core-identical to one another: same 1.0 MHz config, same
# registers, same fuse bytes -- they differ ONLY in flash/RAM size, the -mmcu
# name, and the avrdude part. simavr models their watchdog system reset (which
# it cannot do for the ATtiny13a), so they also carry the WDT-reset and
# fault-injection coverage for the whole family. <n> is the family's INTERNAL
# vocabulary -- it indexes mmcu_<n>/part_<n> and generates the attiny<n>,
# attiny<n>-size and attiny<n>-flash goals. To add a sibling (e.g. the
# ATtiny25), append its number here and define mmcu_<n>/part_<n>.
TINYX5     = 85 45
mmcu_85    = attiny85
mmcu_45    = attiny45
part_85    = t85
part_45    = t45
TINYX5_F_CPU   = 1000000UL

# The same family as full part names. Anything a USER types names a whole part
# (attiny85), never the fragment: v0.9.8 removed the last of the `_t85`/`85`
# spellings from artifacts and goals, and a selector that still took a bare
# number would have been the only place left where a request had to know the
# family's internal indexing. Derived from TINYX5 rather than spelled out, so a
# new sibling cannot appear in one list and not the other.
TINYX5_PARTS   = $(foreach n,$(TINYX5),$(mmcu_$(n)))

# --- Output variants ---------------------------------------------------------
# The hardware-agnostic core (bypass_mcu_avr_classic.c) links against exactly one output
# driver. A variant is identified by its output-stage name; each maps to the -D
# selector macro the firmware/tests compile with and to its driver source file.
# To add a variant: add its name to the immutable supported set and define
# macro_<name>/src_<name> below. VARIANTS remains caller-selectable for
# development targets; production matrix gates compare it with the supported set.
#
# A variant name IS the output-stage name, spelled exactly as the driver source
# file and the published image field spell it. One vocabulary, used by the
# command line (`VARIANT=`), the make goals, the soak combination names and the
# image basenames alike. Before v0.9.8 there were two -- short tokens
# (`cd4053`/`mute`/`relay`) on the classic AVR and AVR-XT lanes, hyphenated ones
# (`cd4053-simple`/`cd4053-mute`/`tq2-relay`) on PIC10F320 -- naming the same
# three output stages in different words, plus a third spelling in the image
# names themselves. The cost of the longer token is real and accepted: it is
# paid once per command line, and it buys the property that a name cannot be
# correct in one lane and meaningless in another.
CORE_SRC = src/bypass_mcu_avr_classic.c src/bypass_pure.c
override CLASSIC_VARIANTS_UNKNOWN := $(if $(filter 1,$(CLASSIC_VARIANTS_REQUEST_UNKNOWN)),invalid,)

# variant name -> firmware -D selector macro
macro_cd4053_simple    = CD4053_SIMPLE
macro_cd4053_with_mute = CD4053_WITH_MUTE
macro_tq2_l2_5v_relay  = TQ2_L2_5V_RELAY

# variant name -> output driver source file
src_cd4053_simple    = src/bypass_output_cd4053_simple.c
src_cd4053_with_mute = src/bypass_output_cd4053_with_mute.c
src_tq2_l2_5v_relay  = src/bypass_output_tq2_l2_5v_relay.c

# --- canonical firmware image basename ---------------------------------------
# THE single spelling rule for every published .elf/.hex basename, on every MCU:
#
#     <prefix>-<mcu>-<output stage>
#     bypass  - attiny85 - cd4053_with_mute
#
# Three fields, hyphen-delimited; words WITHIN a field use underscores. The
# mixed delimiter is deliberate and load-bearing: stage tokens are themselves
# multi-word, so an all-hyphen name could not be split back into its fields
# without hardcoding the MCU vocabulary. With this rule the parse is trivial:
#
#     IFS=- read -r prefix mcu stage <<< "$${base%.hex}"
#
# WHAT THIS REPLACED (TODO.md "Unified naming scheme", axes 3 and 4). Three
# basename conventions used to coexist: prefix `bypass_` vs `bypass_mcu_`; stage
# tokens `cd4053`/`mute`/`relay` vs `cd4053-simple`/`cd4053-mute`/`tq2-relay`;
# and a part suffix that was `_t45`/`_t85`/`_pic10f322`/`_pic10f320` -- or
# ABSENT, because a bare `bypass_cd4053.hex` silently meant "the ATtiny13a one".
# That last case was the real hazard: nothing in the filename stopped a builder
# from flashing the 1.2 MHz ATtiny13a image onto an ATtiny85. The MCU field is
# now mandatory on every image. At the v0.9.8 migration point the 6 x 3 product
# matrix was visible in a plain directory listing; the same rule now exposes the
# 7 x 3 matrix, and no image is identified by omission.
#
# Longest resulting name is 37 characters (bypass-pic10f320-cd4053_with_mute.hex),
# one SHORTER than the 38-character worst case this scheme replaced, so the
# verbose spelling costs nothing anywhere in the toolchain.
#
# THE STAGE FIELD IS THE VARIANT NAME, unchanged -- see "Output variants" above.
# v0.9.8 first added an IMAGE_STAGE_<variant> map here to translate two internal
# vocabularies into this one published spelling, then removed it by renaming the
# vocabularies to match (axis 4). There is nothing left to translate: what you
# type after `VARIANT=`, what the make goals and soak names carry, and what the
# image field says are one string. A translation table is a place where two
# names can disagree; the way to make that unrepresentable is to not have one.

# $(call fw_image_tail,<variant>,<mcu-tag>) -> `-<mcu>-<stage>`: everything that
# follows the prefix. Split out from fw_image so a path stem that ALREADY ends in
# the prefix can append it without re-deriving the prefix -- the AVR lane's
# AVR_FW is exactly that, and it stays overridable (test-flash-budget asserts it
# has not been redirected away from where ATTINY13A_FLASH_ELFS points).
fw_image_tail = -$(strip $(2))-$(strip $(1))

# $(call fw_image,<variant>,<mcu-tag>) -> the basename, no directory, no suffix.
fw_image = $(FW_BASE)$(call fw_image_tail,$(1),$(2))

# The SHELL-side counterpart, for recipe loops that hold the variant in a shell
# variable (`for v in $$vars`, `for v in "$$@"`). Paste $(fw_image_sh) at the top
# of such a recipe, then call `fw_image_of <variant> <mcu-tag>`; it prints
# exactly what $(call fw_image) would.
#
# Yes, the body is now one interpolation. It stays a function anyway, for the
# same reason fw_image exists in make context: the delimiter layout is spelled
# ONCE per context rather than at each of the dozen-plus recipe sites that build
# an image path. That is the property this whole section is for.
fw_image_sh = fw_image_of() { echo "$(FW_BASE)-$$2-$$1"; }

# Headers shared by every firmware build; any change rebuilds all variants.
FW_HEADERS = src/bypass_config.h src/bypass_types.h src/bypass_hw_iface.h \
             src/bypass_pure.h \
             src/bypass_output_common.h src/bypass_pins_avr_classic.h \
             src/bypass_blocking_delay.h src/bypass_static_assert.h \
             src/bypass_compile_checks.h \
             src/bypass_output_cd4053_simple.h src/bypass_output_cd4053_with_mute.h \
             src/bypass_output_tq2_l2_5v_relay.h

# VARIANT selects the single-target build for the -size/-flash/-trace/-program
# actions.
# `make`/`make test` cover ALL variants; VARIANT only matters when you act on
# one specific image (e.g. flashing).
VARIANT ?= cd4053_simple

# Programmer settings.
# AVR_PROGRAMMER: "51 AVR USB ISP ASP" dongle is a USBasp clone -> usbasp.
# ATTINY13A_AVRDUDE_PART: avrdude's short name for the ATtiny13/13a.
# Override on the command line if needed, e.g.:
#   make attiny13a-flash AVR_PROGRAMMER=usbasp
AVR_PROGRAMMER   ?= usbtiny
ATTINY13A_AVRDUDE_PART   ?= t13

# Fuse bytes for this design (verified bit-by-bit; see bypass_mcu_avr_classic.c header):
#   lfuse=0x4A : SPIEN on, CKDIV8 on (1.2MHz), SUT=14CK+64ms, int 9.6MHz RC, WDTON forced on
#   hfuse=0xF9 : 4.3V brown-out detection enabled; RSTDISBL/DWEN left safe
ATTINY13A_LFUSE = 0x4a
ATTINY13A_HFUSE = 0xf9

# tinyx5 family fuse bytes (identical across ATtiny25/45/85):
#   lfuse=0x62 : CKDIV8 on (1.0MHz), CKOUT off, SUT=14CK+64ms, int 8MHz RC
#   hfuse=0xCC : 4.3V BOD, SPIEN on, RSTDISBL/DWEN safe, WDTON forced on
TINYX5_LFUSE = 0x62
TINYX5_HFUSE = 0xcc

# Common avrdude flags for the ATtiny13a (programmer + part).
ATTINY13A_AVRDUDE_FLAGS = -c $(AVR_PROGRAMMER) -p $(ATTINY13A_AVRDUDE_PART)

# --- Host test-suite compiler / simavr ---------------------------------------
# Host (PC) compiler for the test suite (NOT the AVR cross-compiler).
HOSTCC      ?= cc
GCOV        ?= gcov
AWK         ?= awk
override export PROJECT_MAKE := $(MAKE_COMMAND)
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
# This gates individual frames, not total depth; test-stack-bound remeasures
# them. The whole-program runtime high-water mark is 31-33 B across the variants,
# measured separately by test-sim-attiny13a.
# Run `make test-stack-bound` to re-measure every frame.  Any individual frame
# above this threshold signals unintended bloat (e.g. an accidental local
# array).
AVR_STACK_MAX_FRAME ?= 32
AVR_STACK_BUILD_DIR ?=
override AVR_STACK_SOURCES := src/bypass_mcu_avr_classic.c src/bypass_pure.c \
                          src/bypass_output_cd4053_simple.c \
                          src/bypass_output_cd4053_with_mute.c \
                          src/bypass_output_tq2_l2_5v_relay.c

# ATtiny13a flash-budget ceiling for test-flash-budget (percentage of 1 KB).
# Firmware is at 81.4/85.4/84.4% today for simple/mute/relay, so the 90%
# ceiling leaves 4.6 points of margin at the tightest image. Run
# `make test-flash-budget` to re-measure -- it prints the per-variant
# percentages, so this comment can be
# checked rather than trusted.  A future accidental bloat passes silently
# without this gate.
ATTINY13A_FLASH_BUDGET ?= 90
override ATTINY13A_FLASH_MCU := attiny13a
override ATTINY13A_FLASH_BYTES := 1024
override ATTINY13A_FLASH_VARIANTS := $(CLASSIC_VARIANTS_SUPPORTED)
override ATTINY13A_FLASH_UNKNOWN := $(CLASSIC_VARIANTS_UNKNOWN)
# Deliberately spelled from AVR_BUILD_DIR and NOT from AVR_FW: test-flash-budget
# cross-checks that AVR_FW still points here, and a list derived from the value
# it is checking could not catch a redirect. The basenames come from fw_image so
# the check cannot drift from what the build actually emits.
override ATTINY13A_FLASH_ELFS := $(foreach v,$(ATTINY13A_FLASH_VARIANTS),\
                          $(AVR_BUILD_DIR)/$(call fw_image,$(v),$(ATTINY13A_FLASH_MCU)).elf)
override ATTINY13A_FLASH_OLD_FILE_ARGS := $(foreach elf,$(ATTINY13A_FLASH_ELFS),--old-file=$(elf))

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
AVR_ARCH           := $(shell $(CC) -mmcu=$(ATTINY13A_MCU) -dM -E - < /dev/null | awk '/__AVR_ARCH__/ { print $$3; exit }')
# Shared clang target/flags so clang-tidy AND the clang static analyzer parse
# the firmware exactly as the AVR build sees it.
CLANG_AVR_FLAGS    ?= -target avr -mmcu=$(ATTINY13A_MCU) -DF_CPU=$(ATTINY13A_F_CPU) -D__AVR__ -D__AVR_ATtiny13A__ \
                      -D__AVR_DEVICE_NAME__=$(ATTINY13A_MCU) $(if $(AVR_ARCH),-D__AVR_ARCH__=$(AVR_ARCH)) \
                      -D__AVR_HAVE_PRR_PRTIM0 $(BYPASS_CTX_CHECK_FLAG) \
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
                      $(BYPASS_CTX_CHECK_UNREAD_SUPP_CLASSIC) \
                      -D__AVR__ -D__AVR_ATtiny13A__ -DF_CPU=$(ATTINY13A_F_CPU) \
                      $(BYPASS_CTX_CHECK_FLAG) \
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
# cppcheck 2.13.0 does not set --error-exitcode for diagnostics attributed to an
# included header. Force every diagnostic into one strict record format and let
# the repository-owned parser decide whether its normalized path is authored
# firmware. These are validation mechanisms, not caller-selectable tools.
override MISRA_OUTPUT_GATE := test/misra_output_gate.py
override MISRA_DIAGNOSTIC_TEMPLATE := --template='MCU_BYPASS_CPPCHECK|{file}|{line}|{column}|{severity}|{id}|{message}'

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
                      -D__AVR__ -D__AVR_ATtiny13A__ -DF_CPU=$(ATTINY13A_F_CPU) \
                      $(BYPASS_CTX_CHECK_FLAG)

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
# Flags common to every firmware build; the -mmcu and F_CPU differ per target and are
# prepended in CFLAGS (t13a) / CFLAGS85 (t85).
# F2 in-range context-SEU detection (docs/context_seu_detection.md) is a
# compile-time opt-in.  It is enabled on every shell that links the pure core
# and has flash headroom: PIC10F322, PIC12F675, and both AVR families (classic
# and XT, which share CFLAGS_COMMON below).  PIC10F320 is deliberately excluded
# -- it does not link the pure core and even a one-byte fold overflows its
# 256-word flash -- so this flag is NOT added to PIC10F320_CFLAGS.
BYPASS_CTX_CHECK_FLAG := -DBYPASS_CTX_CHECK
# When F2 is enabled, the two AVR ISR shells use avr-libc's ATOMIC_BLOCK
# (<util/atomic.h>).  That vendor macro trips MISRA 12.3/14.2 (waived in
# test/misra_suppressions.txt, MISRA_COMPLIANCE.md D-5) and cppcheck's native
# unreadVariable on the macro's internal SREG-save local.  The MISRA lanes waive
# via the suppressions file; the parallel non-MISRA cppcheck lanes do not read
# that file, so they carry the unreadVariable waiver inline here.  Kept beside
# the feature flag so the whole F2 analysis coupling lives in one place.
BYPASS_CTX_CHECK_UNREAD_SUPP_CLASSIC := --suppress=unreadVariable:src/bypass_mcu_avr_classic.c
BYPASS_CTX_CHECK_UNREAD_SUPP_XT      := --suppress=unreadVariable:src/bypass_mcu_avr_xt.c

CFLAGS_COMMON = -Os \
          -fshort-enums -funsigned-char \
          -ffunction-sections -fdata-sections \
          -Werror -Wall -Wextra -Wconversion -std=c11 \
          $(BYPASS_CTX_CHECK_FLAG)

# Primary (ATtiny13a). The tinyx5 family's per-chip flags are computed inline in
# the build/sim templates from mmcu_<n> + TINYX5_F_CPU + CFLAGS_COMMON.
CFLAGS    = -mmcu=$(ATTINY13A_MCU)   -DF_CPU=$(ATTINY13A_F_CPU)   $(CFLAGS_COMMON)
LDFLAGS   = -mmcu=$(ATTINY13A_MCU)   -Wl,--gc-sections
# Internal sequencing override: normal public builds force current tools/flags;
# validated consumer phases set this empty to reuse the ELF they just checked.
AVR_REBUILD_PREREQ ?= FORCE

# Always-out-of-date prerequisite used for artifacts whose effective build
# command includes command-line variables that timestamps cannot represent.
.PHONY: FORCE
FORCE:

# Never retain a target that a failed recipe created or truncated.
.DELETE_ON_ERROR:

# Targets that are commands, not files. Per-chip tinyx5 targets (attiny85,
# attiny85-size/-fuses/-flash/-program, the *45 forms, test-sim-attiny85, ...)
# are declared .PHONY by the templates that generate them.
.PHONY: all all-request-valid attiny13a attiny13a-size clean help \
        attiny13a-readfuses attiny13a-fuses attiny13a-flash attiny13a-program \
        attiny13a-trace \
        test test-fast test-long stress python-version-valid \
        test-host test-sim-attiny13a test-sim-tinyx5 \
        test-model-check test-fault-inject test-fuses test-symbolic test-cbmc test-mutation test-mutation-sandbox \
        test-attiny202-output-oracle test-attiny202-delay-oracle test-attiny202-fault-oracle \
        test-attiny202-model-ffi \
        test-pic10f320-return-stack-oracle test-pic10f320-expected-images \
        test-pic10f320-coverage-archive \
        test-attiny202-build test-avr-build-rebuild test-avr-program-order test-ci-local-routing test-workflow-syntax test-gpsim-wrappers test-fetch-yasimavr test-supply-chain test-klee-build \
        test-pic-build test-release-images test-release-preflight test-release-provenance test-release-qualification test-release-history test-build-serialization \
        test-pic12f675-flash-helper \
        test-make-lock-probe test-make-safe-parallel-probe \
        _test-make-safe-parallel-probe-run _test-make-safe-parallel-probe-a \
        _test-make-safe-parallel-probe-b _test-mutation-policy-probe \
		test-target-matrix test-target-lane-markers test-lockstep-progress \
		test-pic-target-result-records \
        test-stack-bound-pic-regression test-pic-build-rebuild \
        test-soak-timing test-strict-tools test-workload-rebuild \
        test-variant-map-contract test-fault-wdt-note-contract test-makefile-name-contract test-todo-index \
        test-resource-tables \
        test-pinout-alignment test-misra-output-contract \
        test-analyze-variant-guard test-variant-selector-guard \
        test-clean-contract test-fuse-injection-contract test-static-assert-guards \
		pic12f675-target-selector-valid \
        pic10f322-test-target pic10f322-test-target-variants pic10f322-test-io pic10f322-test-lockstep \
        test-stack-bound attiny202-test-stack-bound test-stack-bound-regression test-flash-budget \
        test-flash-budget-regression test-soak test-soak-reset-witness \
        analyze analyze-tidy analyze-cppcheck analyze-deep \
        coverage coverage-check coverage-clean

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
#   $(AVR_BUILD_DIR)/bypass-attiny13a-<stage of v>.elf / .hex
# Generated per variant <v> x tinyx5 chip <n> (1.0 MHz):
#   $(AVR_BUILD_DIR)/bypass-attiny<n>-<stage of v>.elf / .hex
# The chip field is the -mmcu name itself ($(ATTINY13A_MCU) / $(mmcu_<n>)), so the image
# cannot claim a part the compiler was not aimed at.

# Create the AVR build-output directory on demand. It is an ORDER-ONLY
# prerequisite of every image rule below (after the '|'), so the dir's mtime
# never forces a rebuild of an already-current image.
$(AVR_BUILD_DIR):
	@mkdir -p $@

# $(call VARIANT_BUILD_T13,variant)
define VARIANT_BUILD_T13
$(AVR_FW)$(call fw_image_tail,$(1),$(ATTINY13A_MCU)).elf: $$(CORE_SRC) $$(src_$(1)) $$(FW_HEADERS) Makefile $$(AVR_REBUILD_PREREQ) | $$(AVR_BUILD_DIR)
	@hex="$$(AVR_FW)$(call fw_image_tail,$(1),$(ATTINY13A_MCU)).hex"; \
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

$(AVR_FW)$(call fw_image_tail,$(1),$(ATTINY13A_MCU)).hex: $(AVR_FW)$(call fw_image_tail,$(1),$(ATTINY13A_MCU)).elf $$(IHEX_VALIDATOR)
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
$(AVR_FW)$(call fw_image_tail,$(1),$(mmcu_$(2))).elf: $$(CORE_SRC) $$(src_$(1)) $$(FW_HEADERS) Makefile $$(AVR_REBUILD_PREREQ) | $$(AVR_BUILD_DIR)
	@hex="$$(AVR_FW)$(call fw_image_tail,$(1),$(mmcu_$(2))).hex"; \
	if ! rm -f "$$@" "$$$$hex"; then echo "FAIL: could not remove stale artifact for $$@"; exit 1; fi; \
	tmp=$$$$(mktemp "$$@.tmp.XXXXXX") || exit 1; \
	if ! $$(CC) -mmcu=$$(mmcu_$(2)) -DF_CPU=$$(TINYX5_F_CPU) $$(CFLAGS_COMMON) -Wl,--gc-sections \
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

$(AVR_FW)$(call fw_image_tail,$(1),$(mmcu_$(2))).hex: $(AVR_FW)$(call fw_image_tail,$(1),$(mmcu_$(2))).elf $$(IHEX_VALIDATOR)
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
ATTINY13A_ELFS = $(foreach v,$(VARIANTS),$(AVR_FW)$(call fw_image_tail,$(v),$(ATTINY13A_MCU)).elf)
ATTINY13A_HEXES = $(foreach v,$(VARIANTS),$(AVR_FW)$(call fw_image_tail,$(v),$(ATTINY13A_MCU)).hex)
TINYX5_ELFS = $(foreach v,$(VARIANTS),$(foreach n,$(TINYX5),$(AVR_FW)$(call fw_image_tail,$(v),$(mmcu_$(n))).elf))
TINYX5_HEXES = $(foreach v,$(VARIANTS),$(foreach n,$(TINYX5),$(AVR_FW)$(call fw_image_tail,$(v),$(mmcu_$(n))).hex))
# Per-chip ELF/HEX lists (for the attiny<n>/attiny<n>-size targets).
$(foreach n,$(TINYX5),$(eval ATTINY$(n)_ELFS := $(foreach v,$(VARIANTS),$(AVR_FW)$(call fw_image_tail,$(v),$(mmcu_$(n))).elf)))
$(foreach n,$(TINYX5),$(eval ATTINY$(n)_HEXES := $(foreach v,$(VARIANTS),$(AVR_FW)$(call fw_image_tail,$(v),$(mmcu_$(n))).hex)))

# Default goal: build every release-supported part, not just the one that got
# here first. A default-integrated lane whose cross-toolchain is absent (XC8 for
# any of the three PICs, the ATtiny_DFP for the ATtiny202) prints a named skip
# and does not fail the build, so a bare `make` stays useful on an AVR-only
# machine;
# STRICT_TOOLS=1 turns each skip into an error, as release and CI require.
#
# Composed from $(TINYX5) rather than spelled out, so adding a tinyx5 chip
# reaches the default goal without a second edit here.
all: all-request-valid \
     attiny13a $(foreach n,$(TINYX5),attiny$(n)) \
     attiny202 pic10f322 pic10f320-variants pic12f675

# `all` builds the FULL output-stage matrix, because the PIC lanes require
# every supported stage -- a partial PIC image set is not something this
# project produces. Say so here, in one line, rather than letting a subset
# request travel 40 lines into the PIC lane's own matrix check and fail there.
# Subset builds are a per-part request: `make attiny13a VARIANTS=cd4053_simple`.
.PHONY: all-request-valid
all-request-valid:
	@if [ "$(if $(filter-out $(VARIANTS),$(CLASSIC_VARIANTS_SUPPORTED)),yes,no)" = yes ]; then \
		echo "FAIL: 'make all' builds every part and needs the full stage matrix;"; \
		echo "      VARIANTS=$(VARIANTS) omits $(filter-out $(VARIANTS),$(CLASSIC_VARIANTS_SUPPORTED))."; \
		echo "      For a subset, name one part: make attiny13a VARIANTS=$(VARIANTS)"; \
		exit 2; \
	fi

# Reject malformed classic-output requests before an aggregate can report a
# successful empty or filtered build. Individual recognized subsets remain valid
# development requests; release and PIC producers impose their stricter matrices.
.PHONY: classic-variant-request-valid
classic-variant-request-valid:
	@if [ "$(CLASSIC_VARIANTS_REQUEST_EMPTY)" -eq 1 ]; then \
		echo "FAIL: VARIANTS must not be empty"; exit 2; \
	fi; \
	if [ "$(CLASSIC_VARIANTS_REQUEST_UNKNOWN)" -eq 1 ]; then \
		echo "FAIL: VARIANTS contains unsupported names; supported: $(CLASSIC_VARIANTS_SUPPORTED)"; exit 2; \
	fi; \
	if [ "$(CLASSIC_VARIANTS_REQUEST_DUPLICATE)" -eq 1 ]; then \
		echo "FAIL: VARIANTS must not contain duplicate names"; exit 2; \
	fi

# ---------------------------------------------------------------------------
# SINGLE-VARIANT SELECTORS
# ---------------------------------------------------------------------------
#
# `VARIANTS` above is a LIST, guarded by classic-variant-request-valid. The
# variables below each select exactly ONE output stage (or one tinyx5 chip) for
# a lane that acts on a single image, and they had no guard at all.
#
# WHY THEY NEED ONE. An unrecognized name here does not fail -- it composes a
# path to a file nobody builds, and the lane that wanted it reports a SKIP with
# the wrong reason:
#
#     $ make pic10f322-test-soak PIC10F322_SOAK_VARIANT=relay
#     no build_pic10f322/bypass-pic10f322-relay.hex (XC8 absent?); skipping ...
#     $ echo $?
#     0
#
# XC8 is installed and the request was a typo, but the operator is told a
# toolchain is missing and the suite is told nothing at all. STRICT_TOOLS=1 (CI
# and release) turns that into a failure -- with the same wrong diagnosis. This
# is the same class the v0.9.8 analyzers had ("shrank the subject and reported
# the smaller set clean") and the same shape as the PIC10F322 soak driver that
# had been failing to compile for a release ("degraded to a skip, not a
# failure"). The classic-AVR soak lane fails on a bad selector rather than
# skipping, but composes `bypass--<stage>.elf` on the way -- the empty-MCU-field
# spelling this release exists to make unrepresentable.
#
# ONE GUARD, ALL SELECTORS, deliberately: an override naming a value no lane
# supports is inert wherever it lands, and inert overrides are precisely the
# defect class here. `make pic10f322-test-soak PIC10F320_IO_VARIANT=typo` is
# therefore an error even though the 320's I/O lane is not what was asked for.
#
# `XT_SIM_VARIANT` is NOT in this table: empty means "every supported variant"
# for that lane, so it is a list-or-empty selector, and it already validates
# itself in each of its four recipes.
#
# <selector variable>:<variable holding its supported values>
VARIANT_SELECTORS = \
	VARIANT:CLASSIC_VARIANTS_SUPPORTED \
	AVR_SOAK_VARIANT:CLASSIC_VARIANTS_SUPPORTED \
	AVR_SOAK_WITNESS_VARIANT:CLASSIC_VARIANTS_SUPPORTED \
	AVR_SOAK_CHIP:TINYX5_PARTS \
	AVR_SOAK_WITNESS_CHIP:TINYX5_PARTS \
	PIC10F322_SOAK_VARIANT:CLASSIC_VARIANTS_SUPPORTED \
	PIC10F322_FAULT_VARIANT:CLASSIC_VARIANTS_SUPPORTED \
	PIC10F322_LOCKSTEP_VARIANT:CLASSIC_VARIANTS_SUPPORTED \
	PIC10F322_IO_VARIANT:CLASSIC_VARIANTS_SUPPORTED \
	PIC10F322_TARGET_VARIANT:CLASSIC_VARIANTS_SUPPORTED \
	PIC12F675_IO_VARIANT:CLASSIC_VARIANTS_SUPPORTED \
	PIC12F675_LOCKSTEP_VARIANT:CLASSIC_VARIANTS_SUPPORTED \
	PIC12F675_FAULT_VARIANT:CLASSIC_VARIANTS_SUPPORTED \
	PIC12F675_SOAK_VARIANT:CLASSIC_VARIANTS_SUPPORTED \
	PIC12F675_TARGET_VARIANT:CLASSIC_VARIANTS_SUPPORTED \
	PIC10F320_VARIANT:PIC10F320_VARIANTS_SUPPORTED \
	PIC10F320_TARGET_VARIANT:PIC10F320_VARIANTS_SUPPORTED \
	PIC10F320_FAULT_VARIANT:PIC10F320_VARIANTS_SUPPORTED \
	PIC10F320_IO_VARIANT:PIC10F320_VARIANTS_SUPPORTED \
	PIC10F320_LOCKSTEP_VARIANT:PIC10F320_VARIANTS_SUPPORTED \
	PIC10F320_SOAK_VARIANT:PIC10F320_VARIANTS_SUPPORTED

# $(call selector_check,<selector variable>,<supported-set variable>) -> one
# shell fragment. Both names are expanded by make, so the shell never has to
# dereference a variable it cannot see.
selector_check_generic = sel="$($(1))"; \
	case "$$sel" in \
		"") echo "FAIL: $(1) is empty; expected exactly one of: $($(2))"; rc=2 ;; \
		*" "*) echo "FAIL: $(1)=\"$$sel\" names more than one value; expected exactly one of: $($(2))"; rc=2 ;; \
		*) case " $($(2)) " in \
			*" $$sel "*) : ;; \
			*) echo "FAIL: $(1)=$$sel is not supported; expected one of: $($(2))"; rc=2 ;; \
		esac ;; \
	esac;
selector_check = $(if $(filter VARIANT,$(1)),\
	$(if $(filter 1,$(VARIANT_REQUEST_EMPTY)),echo "FAIL: VARIANT is empty; expected exactly one of: $($(2))"; rc=2;,\
	$(if $(filter 1,$(VARIANT_REQUEST_MULTI)),echo "FAIL: VARIANT names more than one value; expected exactly one of: $($(2))"; rc=2;,\
	$(if $(filter 1,$(VARIANT_REQUEST_UNKNOWN)),echo "FAIL: VARIANT is not supported; expected one of: $($(2))"; rc=2;,:;))),\
	$(if $(filter PIC12F675_TARGET_VARIANT,$(1)),\
	$(if $(filter 1,$(PIC12F675_TARGET_VARIANT_REQUEST_EMPTY)),echo "FAIL: PIC12F675_TARGET_VARIANT is empty; expected exactly one of: $($(2))"; rc=2;,\
	$(if $(filter 1,$(PIC12F675_TARGET_VARIANT_REQUEST_MULTI)),echo "FAIL: PIC12F675_TARGET_VARIANT names more than one value; expected exactly one of: $($(2))"; rc=2;,\
	$(if $(filter 1,$(PIC12F675_TARGET_VARIANT_REQUEST_UNKNOWN)),echo "FAIL: PIC12F675_TARGET_VARIANT is not supported; expected one of: $($(2))"; rc=2;,:;))),\
	$(call selector_check_generic,$(1),$(2))))

# Reject every malformed single-variant request BEFORE any lane builds, skips or
# reports. Rejecting late is not equivalent: a lane that builds first and then
# discovers the typo has already spent the build, and a lane that skips first
# never discovers it at all.
.PHONY: variant-selectors-valid
variant-selectors-valid:
	@rc=0; \
	$(foreach s,$(VARIANT_SELECTORS),\
		$(call selector_check,$(word 1,$(subst :, ,$(s))),$(word 2,$(subst :, ,$(s))))) \
	exit $$rc

# The all-variant PIC12F675 wrapper overwrites this selector in each child
# invocation, so validate the caller's literal request before qualification.
# The outer serialization pass records only classification bits and replaces
# the value with a supported token; no untrusted selector text reaches a recipe.
.PHONY: pic12f675-target-selector-valid
pic12f675-target-selector-valid:
	@if [ "$(PIC12F675_TARGET_VARIANT_REQUEST_EMPTY)" -eq 1 ]; then \
		echo "FAIL: PIC12F675_TARGET_VARIANT is empty; expected exactly one of: $(CLASSIC_VARIANTS_SUPPORTED)"; exit 2; \
	fi; \
	if [ "$(PIC12F675_TARGET_VARIANT_REQUEST_MULTI)" -eq 1 ]; then \
		echo "FAIL: PIC12F675_TARGET_VARIANT names more than one value; expected exactly one of: $(CLASSIC_VARIANTS_SUPPORTED)"; exit 2; \
	fi; \
	if [ "$(PIC12F675_TARGET_VARIANT_REQUEST_UNKNOWN)" -eq 1 ]; then \
		echo "FAIL: PIC12F675_TARGET_VARIANT is not supported; expected one of: $(CLASSIC_VARIANTS_SUPPORTED)"; exit 2; \
	fi

# Build all ATtiny13a variant firmwares (.hex) + print sizes.
attiny13a: classic-variant-request-valid $(ATTINY13A_HEXES) attiny13a-size

# Report flash/RAM usage of every ATtiny13a variant build.
attiny13a-size: classic-variant-request-valid $(ATTINY13A_ELFS)
	@for e in $(ATTINY13A_ELFS); do echo "== $$e =="; $(SIZE) --mcu=$(ATTINY13A_MCU) -C $$e; done

# Per-tinyx5-chip build + size targets: attiny85/attiny85-size, attiny45/...
# $(call MCU_X5_BUILD_TARGETS,chip-number)
define MCU_X5_BUILD_TARGETS
.PHONY: attiny$(1) attiny$(1)-size
attiny$(1): classic-variant-request-valid $$(ATTINY$(1)_HEXES) attiny$(1)-size
attiny$(1)-size: classic-variant-request-valid $$(ATTINY$(1)_ELFS)
	@for e in $$(ATTINY$(1)_ELFS); do echo "== $$$$e =="; $$(SIZE) --mcu=$$(mmcu_$(1)) -C $$$$e; done
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
# `make pic10f322` builds every variant for the PIC10F322 and gates each on the
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
# into its working directory, so the build runs inside PIC10F322_BUILD_DIR to keep the
# repo root clean; `clean` just removes that directory.
# NAMING RULE for every PIC variable across all three lanes: a PIC_* name with no
# part identifies shared mechanism; a part fact is spelled PIC10F322_*,
# PIC10F320_*, or PIC12F675_*. There is exactly one XC8, one device pack, one C++
# compiler, one sampling helper, one pin lookup, and one gpsim bootstrap behind
# all three targets, so those keep the family prefix (PIC_CC, PIC_DFP,
# PIC_XC8_INCLUDE, PIC_SOAK_CXX, PIC_SOAK_GPSIM_INC, PIC_SOAK_SAMPLING_HDR,
# PIC_PIN_LOOKUP_HDR, PIC_GPSIM_BOOTSTRAP_HDR), as do the env-var names the shared
# wrapper scripts read (PIC_GPSIM_PROC, PIC_GPSIM_STC, PIC_DEVICE_NAME,
# PIC_RECIPE_PID) -- each lane passes its own part's value through them.
# PIC_SOAK_SRC is a retained legacy name for the PIC10F32x adapter source;
# PIC12F675 has a distinct adapter because its TMR0 timebase differs.
#
# Anything whose VALUE is a property of one chip must carry that chip's name.
# A mis-scoped chip variable produces no compile error and no failing test, it
# name-contract: exempt (names a removed variable to explain why it is gone)
# produces a PASSING one: PIC_FLASH_WORDS=512 silently gated the 256-word part
# against the 322's budget, which is why that class of name no longer exists.
PIC_CC    ?= /opt/microchip/xc8/v3.10/bin/xc8-cc
PIC_DFP   ?= /opt/microchip/mdfp/PIC10-12Fxxx_DFP/1.9.189/xc8
PIC10F322_CHIP  ?= 10F322
PIC10F322_TAG   ?= pic10f322
PIC10F322_XTAL  ?= 2000000UL
PIC10F322_BUILD_DIR ?= build_pic10f322
override PIC10F322_HEXES := $(foreach v,$(CLASSIC_VARIANTS_SUPPORTED),$(PIC10F322_BUILD_DIR)/$(call fw_image,$(v),$(PIC10F322_TAG)).hex)
override PIC10F322_ASSEMBLIES := $(PIC10F322_HEXES:.hex=.s)
override PIC10F322_SYMBOLS := $(PIC10F322_HEXES:.hex=.sym)
override PIC10F322_BUILD_PRODUCTS := $(PIC10F322_HEXES) $(PIC10F322_ASSEMBLIES) $(PIC10F322_SYMBOLS)
# PIC10F322 device budget: 512 words flash / 64 B RAM.
PIC10F322_FLASH_WORDS ?= 512
# gpsim simulator + processor name for the register-level functional test.
GPSIM         ?= gpsim
PIC10F322_GPSIM_PROC ?= p10f322
GPSIM_TIMEOUT_SECONDS ?= 60
export GPSIM_TIMEOUT_SECONDS

# The PIC shell + the unchanged pure core (the AVR counterpart is CORE_SRC =
# bypass_mcu_avr_classic.c + bypass_pure.c).
PIC10F322_CORE_SRC = src/bypass_mcu_pic10f322.c src/bypass_pure.c

# Headers that, if changed, should rebuild the PIC images: the AVR FW_HEADERS
# set with the PIC pin map substituted for the AVR-classic one.
PIC10F322_HEADERS = src/bypass_config.h src/bypass_types.h src/bypass_hw_iface.h \
              src/bypass_pure.h \
              src/bypass_output_common.h src/bypass_pins_pic10f322.h \
              src/bypass_blocking_delay.h src/bypass_static_assert.h \
              src/bypass_compile_checks.h \
              src/bypass_output_cd4053_simple.h src/bypass_output_cd4053_with_mute.h \
              src/bypass_output_tq2_l2_5v_relay.h

# XC8 compile flags: select the PIC10F322 + its DFP, C99 (no C11 in XC8), the
# PIC pin map, and _XTAL_FREQ for __delay_ms.
PIC10F322_CFLAGS = -mcpu=$(PIC10F322_CHIP) -mdfp=$(PIC_DFP) -std=c99 -O2 \
             -DBYPASS_MCU_PIC10F322 -D_XTAL_FREQ=$(PIC10F322_XTAL) \
             $(BYPASS_CTX_CHECK_FLAG)

# --- PIC static analysis (cppcheck + MISRA addon) ----------------------------
# The cppcheck/MISRA register-correct parse of the PIC shell needs the real XC8
# + DFP headers (the PIC analogue of avr-libc). XC8's base include dir supplies
# xc.h; the DFP supplies pic.h + the device header proc/pic10f322.h, selected by
# the chip macro -D_<CHIP> (e.g. -D_10F322). The pic8-enhanced cppcheck platform
# models the enhanced-midrange core (16-bit int).
PIC_XC8_INCLUDE  ?= /opt/microchip/xc8/v3.10/pic/include
PIC10F322_DFP_INCLUDE  ?= $(PIC_DFP)/pic/include
PIC10F322_CHIP_MACRO   ?= _$(PIC10F322_CHIP)

# Defines/includes shared by both PIC cppcheck passes: select the device header,
# pin the PIC configuration so cppcheck does not also explore the AVR branch of
# bypass_output_common.h, and add the XC8 + DFP header search paths.
PIC10F322_CPPCHECK_CPPFLAGS = -D__XC8 -D$(PIC10F322_CHIP_MACRO) -D_XTAL_FREQ=$(PIC10F322_XTAL) \
                        -DBYPASS_MCU_PIC10F322 -U__AVR__ -UBYPASS_MCU_AVR_CLASSIC \
                        $(BYPASS_CTX_CHECK_FLAG) \
                        -Isrc -I$(PIC10F322_DFP_INCLUDE) -I$(PIC10F322_DFP_INCLUDE)/proc -I$(PIC_XC8_INCLUDE)

# Plain bug-finding pass (parallel to analyze-cppcheck for the AVR build).
PIC10F322_CPPCHECK_FLAGS ?= --enable=warning,style,performance,portability \
                      --std=c11 --platform=pic8-enhanced --error-exitcode=2 \
                      --inline-suppr --max-configs=1 \
                      --suppress=missingIncludeSystem \
                      --suppress=unmatchedSuppression \
                      --suppress=unusedStructMember \
                      '--suppress=*:$(PIC_XC8_INCLUDE)/*' \
                      '--suppress=*:$(PIC10F322_DFP_INCLUDE)/*' \
                      $(PIC10F322_CPPCHECK_CPPFLAGS)

# MISRA addon pass (parallel to MISRA_CPPCHECK_FLAGS for the AVR build). Notes:
#   - System headers (XC8 base + DFP) are outside the compliance boundary, like
#     avr-libc for the AVR run -> suppressed by path.
#   - cppcheck cannot value-flow-model the volatile SFR bitfield unions from the
#     Microchip headers (e.g. PIR1bits.TMR2IF in the tick poll). The resulting
#     misra-config accommodation is file-scoped in MISRA_SUPPRESS; findings in
#     every other authored file remain visible to the output gate.
PIC10F322_MISRA_CPPCHECK_FLAGS ?= --addon=$(MISRA_ADDON) --std=c11 --platform=pic8-enhanced \
                      --enable=style --inline-suppr --max-configs=1 \
                      --suppress=missingIncludeSystem \
                      --suppress=unmatchedSuppression \
                      '--suppress=*:$(PIC_XC8_INCLUDE)/*' \
                      '--suppress=*:$(PIC10F322_DFP_INCLUDE)/*' \
                      $(PIC10F322_CPPCHECK_CPPFLAGS)

# Build every PIC variant and enforce the flash-word budget. The variant -D
# selector and driver source are chosen inline (the same case-pattern the AVR
# analyze/budget recipes use, since $(macro_<v>)/$(src_<v>) cannot expand inside
# a shell loop). Sources are passed as make-time absolute paths so the compiler
# can run with its cwd in PIC10F322_BUILD_DIR.
.PHONY: pic10f322
pic10f322: $(PIC10F322_CORE_SRC) $(PIC10F322_HEADERS) $(foreach v,$(CLASSIC_VARIANTS_SUPPORTED),$(src_$(v)))
	@if [ "$(CLASSIC_VARIANTS_REQUEST_EMPTY)" -eq 1 ]; then \
		echo "FAIL: VARIANTS must not be empty"; exit 2; \
	fi; \
	if [ "$(CLASSIC_VARIANTS_REQUEST_DUPLICATE)" -eq 1 ]; then \
		echo "FAIL: VARIANTS must not contain duplicate names"; exit 2; \
	fi; \
	if [ "$(CLASSIC_VARIANTS_REQUEST_UNKNOWN)" -eq 1 ]; then \
		echo "FAIL: VARIANTS contains unsupported names; supported: $(CLASSIC_VARIANTS_SUPPORTED)"; exit 2; \
	fi; \
	if [ "$(if $(filter-out $(VARIANTS),$(CLASSIC_VARIANTS_SUPPORTED)),yes,no)" = yes ]; then \
		echo "FAIL: VARIANTS must contain every supported name; required: $(CLASSIC_VARIANTS_SUPPORTED)"; exit 2; \
	fi
	@rm -f $(PIC10F322_BUILD_PRODUCTS)
	@if [ ! -x "$(PIC_CC)" ] && ! command -v $(PIC_CC) >/dev/null 2>&1; then \
		echo "XC8 not found at $(PIC_CC); skipping PIC build (override with PIC_CC=...)"; \
		$(SKIP); \
	fi; \
	$(IHEX_VALIDATOR_CHECK); \
	mkdir -p $(PIC10F322_BUILD_DIR); \
	pic_complete=0; \
	cleanup_pic_products() { \
		rc=$$?; \
		if [ $$rc -ne 0 ] || [ $$pic_complete -ne 1 ]; then \
			rm -f $(PIC10F322_BUILD_PRODUCTS) || rc=1; \
			[ $$rc -ne 0 ] || rc=1; \
		fi; \
		trap - 0 1 2 15; exit $$rc; \
	}; \
	trap cleanup_pic_products 0 1 2 15; \
	export PIC_RECIPE_PID=$$$$; \
	LC_ALL=C; export LC_ALL; \
	budget="$(PIC10F322_FLASH_WORDS)"; \
	case "$$budget" in \
		''|*[!0-9]*) echo "FAIL: PIC10F322_FLASH_WORDS must be a positive decimal integer"; exit 1 ;; \
	esac; \
	while [ "$${#budget}" -gt 1 ] && [ "$${budget#0}" != "$$budget" ]; do \
		budget=$${budget#0}; \
	done; \
	if [ "$$budget" = 0 ]; then \
		echo "FAIL: PIC10F322_FLASH_WORDS must be a positive decimal integer"; exit 1; \
	fi; \
	echo "=== PIC10F322 build + flash-budget ($$budget words) ==="; \
	$(fw_image_sh); \
	fail=0; \
	for v in $(CLASSIC_VARIANTS_SUPPORTED); do \
		case $$v in \
			cd4053_with_mute) m=CD4053_WITH_MUTE; drv=src/bypass_output_cd4053_with_mute.c ;; \
			tq2_l2_5v_relay)  m=TQ2_L2_5V_RELAY;  drv=src/bypass_output_tq2_l2_5v_relay.c ;; \
			*)                m=CD4053_SIMPLE;    drv=src/bypass_output_cd4053_simple.c ;; \
		esac; \
		stem=`fw_image_of "$$v" $(PIC10F322_TAG)`; name=$$stem.hex; \
		hex=$(PIC10F322_BUILD_DIR)/$$name; asm=$(PIC10F322_BUILD_DIR)/$$stem.s; sym=$(PIC10F322_BUILD_DIR)/$$stem.sym; \
		if ! rm -f "$$hex" "$$asm" "$$sym"; then \
			echo "FAIL: could not remove stale PIC10F322 products for variant $$v before compiling"; fail=1; continue; \
		fi; \
		out=`cd $(PIC10F322_BUILD_DIR) && $(PIC_CC) $(PIC10F322_CFLAGS) -D$$m \
			$(addprefix $(CURDIR)/,$(PIC10F322_CORE_SRC)) $(CURDIR)/$$drv \
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
		while [ "$${#dec}" -gt 1 ] && [ "$${dec#0}" != "$$dec" ]; do \
			dec=$${dec#0}; \
		done; \
		over_budget=0; \
		if [ "$${#dec}" -gt "$${#budget}" ]; then \
			over_budget=1; \
		elif [ "$${#dec}" -eq "$${#budget}" ]; then \
			cmp=`$(AWK) -v a="x$$dec" -v b="x$$budget" \
				'BEGIN { print (a > b ? "gt" : "le") }'`; cmp_rc=$$?; \
			if [ $$cmp_rc -ne 0 ]; then \
				echo "FAIL: $$v: could not compare program usage with flash budget"; \
				rm -f "$$hex"; fail=1; continue; \
			fi; \
			case "$$cmp" in \
				gt) over_budget=1 ;; \
				le) ;; \
				*) echo "FAIL: $$v: invalid flash-budget comparison result"; \
					rm -f "$$hex"; fail=1; continue ;; \
			esac; \
		fi; \
		pct=`$(AWK) -v u="$$dec" -v t="$$budget" \
			'BEGIN { printf "%.1f", u * 100 / t }'`; pct_rc=$$?; \
		pct_integer=$${pct%.*}; pct_fraction=$${pct#*.}; pct_valid=1; \
		[ "$$pct_integer" != "$$pct" ] || pct_valid=0; \
		case "$$pct_integer" in ''|*[!0-9]*) pct_valid=0 ;; esac; \
		case "$$pct_fraction" in [0-9]) ;; *) pct_valid=0 ;; esac; \
		if [ $$pct_rc -ne 0 ] || [ $$pct_valid -ne 1 ]; then \
			echo "FAIL: $$v: could not calculate flash usage percentage"; \
			rm -f "$$hex"; fail=1; continue; \
		fi; \
		if [ $$over_budget -eq 1 ]; then \
			echo "FAIL: $$v uses $$dec words ($${pct}%) -- exceeds $$budget"; rm -f "$$hex"; fail=1; \
		else \
			echo "OK:   $$v -> $$hex : $$dec words ($${pct}%) of $$budget"; \
		fi; \
	done; \
	[ $$fail -ne 0 ] || pic_complete=1; \
	exit $$fail

# --- PIC CONFIG-word verification --------------------------------------------
# Host-compiled check (the PIC analogue of test-fuses, but STRONGER): it parses
# the CONFIG word XC8 emitted into each built HEX from the shell's `#pragma
# config` and asserts it matches the documented design intent (the oscillator
# selection, WDTE=ON, MCLRE=OFF, BOREN=ON, ...). The PIC CONFIG word lives in
# firmware source -- no host/formal test sees it and the PIC shells have no
# simavr harness -- so a fat-fingered pragma would otherwise only bite on
# silicon. Reads the ACTUAL compiler output rather than a Makefile-injected value.
#
# One mechanism, one decode table per part. The PIC10F322 and PIC10F320 share a
# table (same address, same layout, same expected word -- only the printed label
# differs), while the PIC12F675 shares the CONFIG ADDRESS and nothing else, so it
# brings its own. Declared here, ahead of every rule that names them: a
# prerequisite list is expanded when the rule is READ, so a header variable
# defined further down expands to nothing and silently stops being a dependency.
PIC10F32X_GPSIM_REGS = test/pic/pic10f32x_gpsim_regs.sh
PIC_CONFIG_CORE_HDR  = test/pic/test_config_pic_core.h
PIC10F32X_CONFIG_HDR = test/pic/pic10f32x_config.h
PIC12F675_CONFIG_HDR = test/pic/pic12f675_config.h
#
# Depends on `pic10f322` to build the HEX, and runs against every produced variant
# (all share the same #pragma config, so each must match -- also catches
# divergence). Skips cleanly when XC8 is absent (no HEX produced).
test/pic/test_config_pic: test/pic/test_config_pic.c $(PIC_CONFIG_CORE_HDR) $(PIC10F32X_CONFIG_HDR)
	$(HOSTCC) $(HOST_CFLAGS) $(SANITIZE) -Itest -DPIC_DEVICE_NAME='"PIC$(PIC10F322_CHIP)"' $< -o $@

.PHONY: pic10f322-test-config
pic10f322-test-config: pic10f322 test/pic/test_config_pic
	@hexes=`ls $(PIC10F322_BUILD_DIR)/$(FW_BASE)-$(PIC10F322_TAG)-*.hex 2>/dev/null`; \
	if [ -z "$$hexes" ]; then \
		echo "no PIC HEX in $(PIC10F322_BUILD_DIR)/ (XC8 absent?); skipping CONFIG-word check"; \
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
.PHONY: pic10f322-analyze pic10f322-analyze-cppcheck pic10f322-analyze-misra
pic10f322-analyze: pic10f322-analyze-cppcheck pic10f322-analyze-misra
	@echo "=== PIC static analysis (cppcheck + MISRA) complete ==="

pic10f322-analyze-cppcheck: src/bypass_mcu_pic10f322.c $(PIC10F322_HEADERS)
	@if ! command -v $(CPPCHECK) >/dev/null 2>&1; then \
		echo "cppcheck not installed; skipping PIC cppcheck analysis"; $(SKIP); \
	fi; \
	if [ ! -f "$(PIC_XC8_INCLUDE)/xc.h" ] || [ ! -f "$(PIC10F322_DFP_INCLUDE)/proc/pic10f322.h" ]; then \
		echo "XC8/DFP headers not found; skipping PIC cppcheck analysis"; $(SKIP); \
	fi; \
	echo "cppcheck (PIC, pic8-enhanced): $(CPPCHECK) src/bypass_mcu_pic10f322.c"; \
	$(CPPCHECK) $(PIC10F322_CPPCHECK_FLAGS) src/bypass_mcu_pic10f322.c

pic10f322-analyze-misra: src/bypass_mcu_pic10f322.c $(PIC10F322_HEADERS) $(MISRA_ADDON) $(MISRA_RULES) $(MISRA_SUPPRESS) $(MISRA_OUTPUT_GATE)
	@if ! command -v $(CPPCHECK) >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then \
		echo "cppcheck and/or python3 not available; skipping PIC MISRA analysis"; $(SKIP); \
	fi; \
	if [ ! -f "$(PIC_XC8_INCLUDE)/xc.h" ] || [ ! -f "$(PIC10F322_DFP_INCLUDE)/proc/pic10f322.h" ]; then \
		echo "XC8/DFP headers not found; skipping PIC MISRA analysis"; $(SKIP); \
	fi; \
	echo "MISRA-C:2012 analysis -- PIC shell ($(CPPCHECK) + misra addon, pic8-enhanced)"; \
	out=`mktemp`; rc=0; \
	PYTHONWARNINGS=ignore $(CPPCHECK) $(PIC10F322_MISRA_CPPCHECK_FLAGS) \
		$(MISRA_DIAGNOSTIC_TEMPLATE) --suppressions-list=$(MISRA_SUPPRESS) \
		--error-exitcode=2 src/bypass_mcu_pic10f322.c 2>>$$out || rc=$$?; \
	if ! python3 "$(MISRA_OUTPUT_GATE)" --repo-root "$(CURDIR)" \
			--output "$$out" --tool-status "$$rc"; then \
		echo "MISRA findings NOT covered by a documented deviation:"; \
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
# analog-switch variants drive the control pins HIGH when engaged
# (cd4053_simple=0x3, cd4053_with_mute=0x7); the relay parks its coils low at
# the settled checkpoint, leaving
# only the LED bit set (el=0x1).
#
# A second scenario (test/pic/power_on_pressed.stc, via
# run_gpsim_power_on_pressed.sh) covers the startup branch the toggle scenario
# never hits: the footswitch HELD at power-on must come up BYPASS and must NOT
# engage until a genuine release + fresh press. Both run per variant. Depends on
# `pic10f322` to build the HEX; skips cleanly when gpsim or the HEX is absent.

# Preflight shared by the CLI-gpsim lanes of all three PIC targets, and shared
# deliberately: the three lanes drive the SAME two wrapper scripts and the SAME
# $(GPSIM) binary, so a guard that lives in only one of them is not a guard.
# That is not hypothetical -- it is how the PIC10F320 lane shipped from the merge
# with no tool probe at all, where `make pic10f320-test STRICT_TOOLS=1` printed
# "all PIC10F320 pre-hardware checks complete" on a host without gpsim having run
# zero of its six scenarios (the wrappers exit 0 on a missing gpsim by design, so
# nothing below the Make level could catch it). One definition, three callers.
#
# The two wrapper checks answer DIFFERENT questions and are therefore both
# unconditional-where-meaningful rather than chained: `-x` asks whether this
# checkout can run the script now, and the git-index mode asks whether CI's
# checkout will be able to. Only the second needs a repository, so it is gated on
# one -- an ungated `git ls-files` reports an empty mode outside a work tree,
# which the guard then reads as "not 100755" and fails a tree that is perfectly
# fine. That is not hypothetical either: the mutation harness copies the source
# into a bare mktemp sandbox with no .git, so this lane failed its baseline
# there, was scored as a skip, and surfaced to the user as "toolchain absent" on
# a host whose toolchain was complete. A guard that cannot tell a broken tree
# from a git-less one is worse than no guard, because it spends the reader's
# trust. Outside a work tree there is no index to disagree with, so there is
# nothing to check.
#
# $(1) is the chip label used in the skip diagnostic. Expands INSIDE the caller's
# single shell -- like $(yasimavr_skip_if_absent) above -- so $(SKIP)'s `exit 0`
# leaves the whole recipe rather than a sub-shell.
# Usage: `$(call gpsim_wrapper_preflight,PIC10F322); \` as the first recipe line.
define gpsim_wrapper_preflight
timeout_seconds="$${GPSIM_TIMEOUT_SECONDS:-60}"; \
case "$$timeout_seconds" in \
	''|*[!0-9.]*|*.*.*|.*|*.) \
		echo "FAIL: GPSIM_TIMEOUT_SECONDS must be a positive decimal number of seconds"; exit 1 ;; \
esac; \
case "$$timeout_seconds" in \
	*[1-9]*) ;; \
	*) echo "FAIL: GPSIM_TIMEOUT_SECONDS must be a positive decimal number of seconds"; exit 1 ;; \
esac; \
if ! command -v $(GPSIM) >/dev/null 2>&1; then \
	echo "gpsim not installed; skipping $(1) gpsim register-level test"; $(SKIP); \
fi; \
guard=0; \
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then in_repo=1; else in_repo=0; fi; \
for s in test/pic/run_gpsim_test.sh test/pic/run_gpsim_power_on_pressed.sh; do \
	if [ ! -x "$$s" ]; then \
		echo "ERROR: $$s lacks its local exec bit"; \
		echo "       (e.g. a clone onto NFS that didn't honor the mode)."; \
		echo "       CI is unaffected; this only blocks the local run."; \
		echo "       Fix: chmod +x $$s"; \
		guard=1; \
	fi; \
	[ $$in_repo -eq 1 ] || continue; \
	mode=`git ls-files --stage -- "$$s" | cut -d' ' -f1`; \
	if [ "$$mode" != "100755" ]; then \
		echo "ERROR: $$s is not mode 100755 in git (found '$$mode')."; \
		echo "       CI checks out git's mode, so a non-exec script fails as"; \
		echo "       '/bin/sh: ...: Permission denied'."; \
		echo "       Fix: git update-index --chmod=+x $$s   (then commit)"; \
		guard=1; \
	fi; \
done; \
[ $$guard -eq 0 ] || exit 1
endef

.PHONY: pic10f322-test-gpsim
pic10f322-test-gpsim: pic10f322 $(PIC10F32X_GPSIM_REGS)
	@$(call gpsim_wrapper_preflight,PIC10F322); \
	$(fw_image_sh); \
	fail=0; \
	for v in $(CLASSIC_VARIANTS_SUPPORTED); do \
		case $$v in \
			cd4053_with_mute) el=0x7 ;; \
			tq2_l2_5v_relay)  el=0x1 ;; \
			*)                el=0x3 ;; \
		esac; \
		hex=$(PIC10F322_BUILD_DIR)/`fw_image_of "$$v" $(PIC10F322_TAG)`.hex; \
		if [ ! -f "$$hex" ]; then \
			echo "no $$hex (XC8 absent?); skipping gpsim test for $$v"; continue; \
		fi; \
		echo "--- gpsim register-level test: variant $$v ---"; \
		GPSIM=$(GPSIM) PIC_GPSIM_PROC=$(PIC10F322_GPSIM_PROC) STRICT_TOOLS="$(STRICT_TOOLS)" \
			test/pic/run_gpsim_test.sh $$hex $$el || fail=1; \
		GPSIM=$(GPSIM) PIC_GPSIM_PROC=$(PIC10F322_GPSIM_PROC) STRICT_TOOLS="$(STRICT_TOOLS)" \
			test/pic/run_gpsim_power_on_pressed.sh $$hex || fail=1; \
	done; \
	exit $$fail

# Host-gcov gate over the real PIC shipping source set: the PIC shell, shared
# pure core, and all three output drivers. This complements the independent
# golden-model percentage gate and the real-HEX gpsim/libgpsim behavior gates.
.PHONY: pic10f322-coverage-check-fw
pic10f322-coverage-check-fw: host-compiler-valid
	@HOSTCC="$(HOSTCC)" GCOV="$(GCOV)" COVERAGE_DIR="$(abspath $(COVERAGE_DIR))" \
		test/pic/fw_coverage/run_fw_coverage.sh pic10f322

# Aggregate: every PIC pre-hardware check (build+budget, CONFIG word, static
# analysis, shipping-source coverage, gpsim functional). Standalone -- NOT part
# of `make test`, which is the AVR pre-hardware gate (XC8/gpsim may be absent in
# CI). Each external-tool sub-target skips cleanly when its tool is missing.
#
# One lane is the exception and is listed here anyway: this aggregate keeps
# running pic10f322-coverage-check-fw even though `make test` now runs it too.
# The gate needs no PIC tool, so it belongs in the default suite; standing here
# as well is what keeps `pic10f322-test` a complete statement of the part's
# pre-hardware evidence rather than a set of leftovers.
.PHONY: pic10f322-test
pic10f322-test: pic10f322-test-config pic10f322-analyze pic10f322-coverage-check-fw pic10f322-test-gpsim \
          pic10f322-test-stack-bound
	@echo "=== all PIC10F322 pre-hardware checks complete ==="

# --- PIC hardware return-stack depth (all three targets) ----------------------
# The PIC counterpart of test-stack-bound, and deliberately a different gate.
# test-stack-bound bounds the AVR's DATA stack in bytes via -fstack-usage; the
# PIC14 core has no data stack to bound (XC8 uses a static compiled-stack
# overlay), but it does have a fixed 8-level HARDWARE RETURN STACK whose
# overflow is silent -- no STKPTR, no STKOVF, no stack-overflow reset on this
# part. See test/check_stack_depth_pic.sh for the analysis and for why XC8's own
# per-function estimate is not used as the measurement.
#
# The budget is READ FROM THE DEVICE PACK, never written down here: a hardcoded
# depth is the same silent-staleness hazard as a hardcoded PIC10F322_FLASH_WORDS
# (merge plan §5.6). All three parts declare STACKDEPTH=8 independently.
#
# The reserve is held back from the budget for two reasons worth stating: an
# in-circuit debugger consumes a stack level during bench bring-up, and no
# current PIC implementation has an ISR -- if one is added it costs a level plus its own tree,
# which the gate accounts for but which should not consume the last of the
# headroom before anyone notices.
PIC10F322_DEVICE_INI     ?= $(PIC_DFP)/pic/dat/ini/$(shell printf '%s' '$(PIC10F322_CHIP)' | tr 'A-Z' 'a-z').ini
PIC10F320_DEVICE_INI  ?= $(PIC10F320_DFP)/pic/dat/ini/$(shell printf '%s' '$(PIC10F320_CHIP)' | tr 'A-Z' 'a-z').ini
PIC10F322_STACK_RESERVE    ?= 2
PIC10F320_STACK_RESERVE ?= 2
PIC_STACK_DEPTH_GATE      = ./test/check_stack_depth_pic.sh

.PHONY: pic10f322-test-stack-bound pic10f320-test-stack-bound
pic10f322-test-stack-bound: pic10f322
	@# One shell: skip only when the build produced no HEX. A current HEX without
	@# its freshly generated assembly is a failed gate, never an absent-tool skip.
	@$(fw_image_sh); \
	have_hex=0; \
	for v in $(CLASSIC_VARIANTS_SUPPORTED); do \
		hex="$(PIC10F322_BUILD_DIR)/`fw_image_of "$$v" $(PIC10F322_TAG)`.hex"; \
		if [ -e "$$hex" ] || [ -L "$$hex" ]; then have_hex=1; fi; \
	done; \
	if [ $$have_hex -eq 0 ]; then \
		echo "no PIC10F322 HEX in $(PIC10F322_BUILD_DIR)/ (XC8 absent?); skipping stack-depth gate"; \
		$(SKIP); \
	fi; \
	for v in $(CLASSIC_VARIANTS_SUPPORTED); do \
		stem="$(PIC10F322_BUILD_DIR)/`fw_image_of "$$v" $(PIC10F322_TAG)`"; \
		hex="$$stem.hex"; \
		asm="$$stem.s"; \
		if [ ! -f "$$hex" ] || [ -L "$$hex" ] || [ ! -s "$$hex" ]; then \
			echo "FAIL: current PIC10F322 image is missing, empty, or not regular: $$hex"; exit 1; \
		fi; \
		if [ ! -f "$$asm" ] || [ -L "$$asm" ] || [ ! -s "$$asm" ]; then \
			echo "FAIL: current PIC10F322 HEX exists but generated assembly is missing, empty, or not regular: $$asm"; exit 1; \
		fi; \
		$(PIC_STACK_DEPTH_GATE) "$$asm" \
			"$(PIC10F322_DEVICE_INI)" "$(PIC10F322_STACK_RESERVE)" "PIC10F322 $$v" || exit 1; \
	done; \
	echo "=== PIC10F322 hardware stack bounded for every variant ==="

pic10f320-test-stack-bound: pic10f320-variants
	@$(fw_image_sh); \
	have_hex=0; \
	for v in $(PIC10F320_VARIANTS_ALL); do \
		hex="$(PIC10F320_BUILD_DIR)/`fw_image_of "$$v" $(PIC10F320_TAG)`.hex"; \
		if [ -e "$$hex" ] || [ -L "$$hex" ]; then have_hex=1; fi; \
	done; \
	if [ $$have_hex -eq 0 ]; then \
		echo "no PIC10F320 HEX in $(PIC10F320_BUILD_DIR)/ (XC8 absent?); skipping stack-depth gate"; \
		$(SKIP); \
	fi; \
	for v in $(PIC10F320_VARIANTS_ALL); do \
		stem="$(PIC10F320_BUILD_DIR)/`fw_image_of "$$v" $(PIC10F320_TAG)`"; \
		hex="$$stem.hex"; \
		asm="$$stem.s"; \
		if [ ! -f "$$hex" ] || [ -L "$$hex" ] || [ ! -s "$$hex" ]; then \
			echo "FAIL: current PIC10F320 image is missing, empty, or not regular: $$hex"; exit 1; \
		fi; \
		if [ ! -f "$$asm" ] || [ -L "$$asm" ] || [ ! -s "$$asm" ]; then \
			echo "FAIL: current PIC10F320 HEX exists but generated assembly is missing, empty, or not regular: $$asm"; exit 1; \
		fi; \
		$(PIC_STACK_DEPTH_GATE) "$$asm" \
			"$(PIC10F320_DEVICE_INI)" "$(PIC10F320_STACK_RESERVE)" "PIC10F320 $$v" || exit 1; \
	done; \
	echo "=== PIC10F320 hardware stack bounded for every variant ==="

# Host-only proof that the gate above rejects what it must. Tool-independent by
# construction (synthetic XC8-shaped fixtures), so it rides in `make test` and
# cannot become the check that quietly stopped running.
.PHONY: test-stack-bound-pic-regression
test-stack-bound-pic-regression:
	AWK="$(AWK)" ./test/test_stack_depth_pic.sh

# --- PIC long-duration soak test (libgpsim) ----------------------------------
# The PIC analogue of `test-soak`: drive the real built HEX in gpsim -- via
# libgpsim, NOT the gpsim CLI -- for PIC10F322_SOAK_DURATION_MS of simulated time and
# assert WDT liveness + a periodic 2-press responsiveness round-trip. Failures
# are non-fatal and logged; the run continues the full duration. The driver is
# variant-agnostic (LED is RA0 on every variant). See test/pic/test_soak_pic.cc.
#
# STANDALONE -- deliberately NOT in `make test`/`pic10f322-test`: it runs for minutes
# and links libgpsim, which needs the gpsim-dev + libglib2.0-dev headers (CI may
# lack them). Skips cleanly (exit 0) when the compiler, those headers, or the
# built HEX are absent -- exactly as `pic10f322-test-gpsim` skips without gpsim. Phony
# + always recompiles so PIC10F322_SOAK_* command-line overrides are always applied.
#
# Overrides: PIC10F322_SOAK_VARIANT (any supported variant), PIC10F322_SOAK_DURATION_MS (default
# 1 h; pass 86400000 for 24 h), PIC10F322_SOAK_LIVENESS_INTERVAL_MS, PIC10F322_SOAK_PROGRESS_INTERVAL_MS.
PIC_SOAK_CXX         ?= c++
PIC_SOAK_GPSIM_INC   ?= /usr/include/gpsim
PIC10F322_SOAK_VARIANT     ?= cd4053_simple
PIC10F322_SOAK_DURATION_MS ?= 3600000
PIC10F322_SOAK_LIVENESS_INTERVAL_MS ?= 60000
PIC10F322_SOAK_PROGRESS_INTERVAL_MS ?= 3600000
PIC10F322_SOAK_COMBINATION_NAME ?= standalone
PIC_PIN_LOOKUP_HDR = test/pic/find_pin_exact.h
# Shared libgpsim bring-up consumed by ALL FOUR harnesses (io, lock-step, fault,
# soak) on all three PIC targets. It is a prerequisite of every one below: an edit
# here changes what every PIC gpsim binary does, so none may be stale for it.
PIC_GPSIM_BOOTSTRAP_HDR = test/pic/gpsim_bootstrap.h
# Shared by all three fault adapters, and named for that rather than for the
# part whose lane defined it first. TARGET_FAULT for the same reason as
# TARGET_IO below: the adapters state their guard policy through a C macro
# family that would otherwise share the stem.
PIC_TARGET_FAULT_CORE_HDR = test/pic/test_fault_pic_core.h
PIC_TARGET_RESULT_HDR = test/pic/target_result.h
# Named PIC_ rather than PIC10F322_ because the PIC12F675 io lane compiles the
# same core: it is shared mechanism, like the bring-up header above, and a
# part-named variable would have read as the 322's private copy.
#
# TARGET_IO, not IO: the core selects its output variant through a C macro
# family whose names share that shorter stem, and test/pic/test_io_pic_core.h
# carries a name-contract exemption saying so. A make variable on the same stem
# would satisfy that axis by coincidence and retire a marker that is still
# telling the truth.
PIC_TARGET_IO_CORE_HDR = test/pic/test_io_pic_core.h
# Shared by all three lock-step adapters, exactly like the two headers above,
# and named for that rather than for the part whose lane happened to define it
# first. TARGET_LOCKSTEP for the same reason as TARGET_IO: the adapters select
# their part through a C macro family that would otherwise share the stem.
PIC_TARGET_LOCKSTEP_CORE_HDR = test/pic/test_lockstep_pic_core.h
# PIC10F32x device identity (register addresses, gpsim name tokens, masks,
# expected init values) and guard policy (which locations the fault lane
# injects, and with what). The harness cores carry only mechanism, so an edit to
# either of these changes what every PIC10F32x gpsim binary asserts or corrupts
# -- they are prerequisites exactly as the cores are. Both parts' adapters
# consume them; the PIC10F320 lanes compile inline and so cannot go stale.
PIC10F32X_REGS_HDR = test/pic/pic10f32x_regs.h
PIC10F32X_FAULT_MATRIX_HDR = test/pic/pic10f32x_fault_matrix.h
# The PIC12F675 counterparts. Same split for the same reason: identity in one
# file, guard policy in the other. The io and lock-step lanes need only the
# first; the fault lane needs both.
PIC12F675_REGS_HDR = test/pic/pic12f675_regs.h
PIC12F675_FAULT_MATRIX_HDR = test/pic/pic12f675_fault_matrix.h
# The soak's mechanism, shared by all three parts exactly as the three headers
# above are. TARGET_SOAK for the same reason as TARGET_IO: the adapters state
# their timebase and their watchdog caveat through a C macro family that would
# otherwise share the stem.
PIC_TARGET_SOAK_CORE_HDR = test/pic/test_soak_pic_core.h
# The PIC10F32x soak ADAPTER -- one file for two parts, which is why this
# variable is not part-named while the PIC12F675's is. It carries the family's
# register map, tick period and watchdog caveat; both 10F32x lanes compile it.
PIC_SOAK_SRC = test/pic/test_soak_pic.cc
PIC_SOAK_SAMPLING_HDR = test/pic/soak_sampling.h
PIC_SOAK_HOLD_TIMING_HDR = test/pic/soak_hold_timing.h
PIC10F322_SOAK_DEPS = $(PIC_SOAK_SRC) $(PIC_TARGET_SOAK_CORE_HDR) \
                $(PIC10F32X_REGS_HDR) $(PIC_PIN_LOOKUP_HDR) $(PIC_GPSIM_BOOTSTRAP_HDR) \
                $(PIC_SOAK_SAMPLING_HDR) $(PIC_SOAK_HOLD_TIMING_HDR) \
		test/soak_timing_config.h
PIC10F322_SOAK_BIN = test/pic/test_soak_pic
PIC10F322_SOAK_HEX = $(PIC10F322_BUILD_DIR)/$(call fw_image,$(PIC10F322_SOAK_VARIANT),$(PIC10F322_TAG)).hex

# Worst-case blocking output actuation (ms) per variant, passed to the soak as
# -DSOAK_ACTUATION_BLOCK_MS. A relay coil pulse / CD4053 mute busy-blocks the
# POLLED PIC main loop, stealing that many 1 ms debounce ticks from a window, so
# the soak's liveness check must hold each press/release that much longer to stay
# robust (see test/pic/test_soak_pic_core.h). Mirror the driver headers'
# TQ2_L2_5V_PULSE_MS (12) and CD4053_MUTE_DELAY_MS (5); cd4053_simple is 0.
pic_soak_block_cd4053_simple    = 0
pic_soak_block_cd4053_with_mute = 5
pic_soak_block_tq2_l2_5v_relay  = 12

# Compile command for the PIC soak driver, factored into one variable so BOTH
# the run target (pic10f322-test-soak) and the build-only rule ($(PIC10F322_SOAK_BIN) below)
# share a single definition -- the PIC analogue of AVR_SOAK_COMPILE. FW_PATH
# is baked as an ABSOLUTE path ($(CURDIR)/...) so the resulting binary does not
# depend on the cwd it is launched from. That matters for the release pipeline:
# scripts/make-release.sh builds one soak binary per variant and runs them in
# parallel, each in its own working directory, so their gpsim.log files (gpsim
# always drops one in the cwd) never collide. Running from repo root (as
# pic10f322-test-soak does) is unaffected -- an absolute FW_PATH resolves either way.
PIC10F322_SOAK_COMPILE = $(PIC_SOAK_CXX) -std=c++17 -O2 $$(pkg-config --cflags glib-2.0) \
		-isystem $(PIC_SOAK_GPSIM_INC) -Itest -Isrc \
		-DFW_PATH='"$(CURDIR)/$(PIC10F322_SOAK_HEX)"' -DPROC_NAME='"$(PIC10F322_GPSIM_PROC)"' \
		-DF_CPU_HZ=$(PIC10F322_XTAL) \
		-DSOAK_DURATION_MS=$(PIC10F322_SOAK_DURATION_MS) \
		-DSOAK_LIVENESS_INTERVAL_MS=$(PIC10F322_SOAK_LIVENESS_INTERVAL_MS) \
		-DSOAK_PROGRESS_INTERVAL_MS=$(PIC10F322_SOAK_PROGRESS_INTERVAL_MS) \
		-DSOAK_COMBINATION_NAME='"$(PIC10F322_SOAK_COMBINATION_NAME)"' \
		-DSOAK_ACTUATION_BLOCK_MS=$(pic_soak_block_$(PIC10F322_SOAK_VARIANT))u \
		$(PIC_SOAK_SRC) -o $(PIC10F322_SOAK_BIN) -lgpsim

# Build-only convenience rule: compile the soak driver for the selected
# PIC10F322_SOAK_VARIANT to PIC10F322_SOAK_BIN WITHOUT running it (the PIC analogue of the
# AVR $(AVR_SOAK_BIN) build rule). Used by scripts/make-release.sh, which builds one
# binary per variant under unique PIC10F322_SOAK_BIN names and then runs them
# concurrently. The HEX it embeds is produced by `make pic10f322`, which the release
# script runs first.
# FORCE, for the reason stated at its definition: this binary's effective build
# command includes command-line variables -- PIC10F322_SOAK_{DURATION,LIVENESS_INTERVAL,
# PROGRESS_INTERVAL}_MS and PIC10F322_SOAK_VARIANT are compiled IN as -D flags -- and a
# timestamp cannot represent them. Without it,
#     make test/pic/test_soak_pic PIC10F322_SOAK_DURATION_MS=60000
#     make test/pic/test_soak_pic PIC10F322_SOAK_DURATION_MS=120000
# reports "up to date" and leaves the 60000 binary in place. Measured, not
# theorised. The AVR ELF rules have carried $(AVR_REBUILD_PREREQ) for exactly
# this since before the merge; these two rules were the omission.
#
# No override knob (the AVR's AVR_REBUILD_PREREQ exists so a validated consumer
# phase can reuse an ELF it just checked). Nothing reuses this binary: the only
# consumer, pic10f322-test-soak, deletes and recompiles it inline, which is also why
# the staleness was invisible through the normal lane.
$(PIC10F322_SOAK_BIN): $(PIC10F322_SOAK_DEPS) FORCE
	$(PIC10F322_SOAK_COMPILE)

.PHONY: pic10f322-test-soak
pic10f322-test-soak: variant-selectors-valid pic10f322
	@if ! command -v $(PIC_SOAK_CXX) >/dev/null 2>&1; then \
		echo "no C++ compiler ($(PIC_SOAK_CXX)); skipping PIC soak"; $(SKIP); \
	fi; \
	if [ ! -f "$(PIC_SOAK_GPSIM_INC)/sim_context.h" ]; then \
		echo "gpsim-dev headers not at $(PIC_SOAK_GPSIM_INC); skipping PIC soak (install gpsim-dev)"; $(SKIP); \
	fi; \
	if ! pkg-config --exists glib-2.0 2>/dev/null; then \
		echo "libglib2.0-dev not found; skipping PIC soak (install libglib2.0-dev)"; $(SKIP); \
	fi; \
	if [ ! -f "$(PIC10F322_SOAK_HEX)" ]; then \
		echo "no $(PIC10F322_SOAK_HEX) (XC8 absent?); skipping PIC soak for variant $(PIC10F322_SOAK_VARIANT)"; $(SKIP); \
	fi; \
	echo "--- PIC soak: variant=$(PIC10F322_SOAK_VARIANT) proc=$(PIC10F322_GPSIM_PROC) duration=$(PIC10F322_SOAK_DURATION_MS) ms ---"; \
	rm -f $(PIC10F322_SOAK_BIN) && \
	$(PIC10F322_SOAK_COMPILE) && \
	./$(PIC10F322_SOAK_BIN)

# --- PIC critical-SFR fault-injection test (libgpsim) ------------------------
# Corrupt each critical config SFR (OSCCON/WDTCON/PR2/T2CON) in the running HEX
# and assert the per-tick gate (hw_critical_sfrs_intact) forces a WDT reset --
# the PIC analogue of the AVR simavr inject_config_sfr tests (test/avr/test_sim.c)
# and the mirror image of pic10f322-test-soak (a reset is the expected PASS here, a
# FAILURE there). See test/pic/test_fault_pic.cc.
#
# STANDALONE -- like pic10f322-test-soak it links libgpsim (needs gpsim-dev +
# libglib2.0-dev) and is deliberately NOT in `make test`/`pic10f322-test`, whose PIC
# leg (pic10f322-test-gpsim) needs only the gpsim CLI. Skips cleanly when the compiler,
# those headers, or the built HEX are absent. PIC10F322_FAULT_VARIANT selects the HEX
# and the output-stage macro needed for variant-aware TRISA fault expectations.
# Reuses the soak's toolchain settings (PIC_SOAK_CXX, PIC_SOAK_GPSIM_INC).
PIC10F322_FAULT_VARIANT ?= cd4053_simple
PIC10F322_FAULT_SRC = test/pic/test_fault_pic.cc
PIC10F322_FAULT_BIN = test/pic/test_fault_pic
PIC10F322_FAULT_HEX = $(PIC10F322_BUILD_DIR)/$(call fw_image,$(PIC10F322_FAULT_VARIANT),$(PIC10F322_TAG)).hex
PIC10F322_FAULT_SYM = $(PIC10F322_FAULT_HEX:.hex=.sym)

# The test's ctx_ field offsets (+0/+1/+2) depend on XC8's code generator
# packing each enum to 1 byte -- which its clang FRONT END disagrees with
# (sizeof(debounce_context_t) == 5 there, so a firmware static_assert cannot
# pin the layout). The run recipe therefore asserts `_ctx_: ds 3` in the
# generated .s before running.
#
# _ctx_'s data address from the XC8 .sym, as -DCTX_ADDR=0x<addr> for the ctx_
# SRAM cases (so the test self-adjusts per variant instead of hard-coding it).
# A $(shell) in this recursive (=) variable re-runs when PIC10F322_FAULT_COMPILE is
# expanded in the recipe -- i.e. AFTER the `pic10f322` prerequisite has built the .sym.
# Empty when the .sym is absent (XC8 not installed); the run recipe below fails
# if the HEX exists but _ctx_ cannot be resolved, so the target cannot pass with
# its SRAM cases omitted.
PIC10F322_FAULT_CTX_DEF = $(shell a=$$(awk '$$1=="_ctx_"{print $$2; exit}' $(PIC10F322_FAULT_SYM) 2>/dev/null); [ -n "$$a" ] && echo -DCTX_ADDR=0x$$a)

# FW_PATH baked as an ABSOLUTE path so the binary is cwd-independent (parity with
# the soak). Phony run rule always recompiles so a PIC10F322_FAULT_VARIANT override is
# always applied; the build-only $(PIC10F322_FAULT_BIN) rule is the release-parity hook.
PIC10F322_FAULT_COMPILE = $(PIC_SOAK_CXX) -std=c++17 -O2 $$(pkg-config --cflags glib-2.0) \
		-isystem $(PIC_SOAK_GPSIM_INC) -Itest -Isrc \
		-DFW_PATH='"$(CURDIR)/$(PIC10F322_FAULT_HEX)"' -DPROC_NAME='"$(PIC10F322_GPSIM_PROC)"' \
		-DF_CPU_HZ=$(PIC10F322_XTAL) -D$(macro_$(PIC10F322_FAULT_VARIANT)) $(PIC10F322_FAULT_CTX_DEF) \
		$(BYPASS_CTX_CHECK_FLAG) \
		$(PIC10F322_FAULT_SRC) -o $(PIC10F322_FAULT_BIN) -lgpsim

$(PIC10F322_FAULT_BIN): $(PIC10F322_FAULT_SRC) $(PIC_TARGET_FAULT_CORE_HDR) $(PIC_TARGET_RESULT_HDR) $(PIC_PIN_LOOKUP_HDR) \
                  $(PIC_GPSIM_BOOTSTRAP_HDR) $(PIC10F32X_REGS_HDR) \
                  $(PIC10F32X_FAULT_MATRIX_HDR)
	$(PIC10F322_FAULT_COMPILE)

.PHONY: pic10f322-test-fault
pic10f322-test-fault: variant-selectors-valid pic10f322
	@if ! command -v $(PIC_SOAK_CXX) >/dev/null 2>&1; then \
		echo "no C++ compiler ($(PIC_SOAK_CXX)); skipping PIC fault-inject"; $(SKIP); \
	fi; \
	if [ ! -f "$(PIC_SOAK_GPSIM_INC)/sim_context.h" ]; then \
		echo "gpsim-dev headers not at $(PIC_SOAK_GPSIM_INC); skipping PIC fault-inject (install gpsim-dev)"; $(SKIP); \
	fi; \
	if ! pkg-config --exists glib-2.0 2>/dev/null; then \
		echo "libglib2.0-dev not found; skipping PIC fault-inject (install libglib2.0-dev)"; $(SKIP); \
	fi; \
	if [ ! -f "$(PIC10F322_FAULT_HEX)" ]; then \
		echo "no $(PIC10F322_FAULT_HEX) (XC8 absent?); skipping PIC fault-inject for variant $(PIC10F322_FAULT_VARIANT)"; $(SKIP); \
	fi; \
	s="$(PIC10F322_FAULT_HEX:.hex=.s)"; \
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
	ctx_addr=`awk '$$1=="_ctx_"{print $$2; exit}' "$(PIC10F322_FAULT_SYM)" 2>/dev/null`; \
	if [ -z "$$ctx_addr" ]; then \
		echo "FAIL: _ctx_ symbol not found in $(PIC10F322_FAULT_SYM); ctx_ SRAM fault cases would be omitted."; \
		exit 1; \
	fi; \
	echo "--- PIC fault-inject: variant=$(PIC10F322_FAULT_VARIANT) proc=$(PIC10F322_GPSIM_PROC) (ctx_ layout verified: 3 bytes) ---"; \
	rm -f $(PIC10F322_FAULT_BIN) && \
	$(PIC10F322_FAULT_COMPILE) && \
	./$(PIC10F322_FAULT_BIN)

# --- PIC built-HEX lock-step test (libgpsim + shared model) -------------------
# Drive the real XC8-built HEX and the shared model with the same footswitch
# stream, then compare live ctx_ SRAM after every completed main-loop iteration.
# Standalone use is skip-clean for missing tools; pic10f322-test-target below turns it
# into a fail-closed gate by requiring the LOCK-STEP PASS sentinel.
PIC10F322_LOCKSTEP_VARIANT ?= cd4053_simple
PIC10F322_LOCKSTEP_SRC = test/pic/test_lockstep_pic.cc
PIC10F322_LOCKSTEP_BIN = test/pic/test_lockstep_pic
PIC10F322_LOCKSTEP_MODEL_OBJ = $(PIC10F322_BUILD_DIR)/bypass_pure_lockstep.o
PIC10F322_LOCKSTEP_HEX = $(PIC10F322_BUILD_DIR)/$(call fw_image,$(PIC10F322_LOCKSTEP_VARIANT),$(PIC10F322_TAG)).hex
PIC10F322_LOCKSTEP_SYM = $(PIC10F322_LOCKSTEP_HEX:.hex=.sym)
PIC10F322_LOCKSTEP_CTX_DEF = $(shell a=$$(awk '$$1=="_ctx_"{print $$2; exit}' $(PIC10F322_LOCKSTEP_SYM) 2>/dev/null); [ -n "$$a" ] && echo -DCTX_ADDR=0x$$a)
PIC10F322_LOCKSTEP_COMPILE = \
		$(HOSTCC) $(HOST_CFLAGS) $(PURE_HOST_CFLAGS) -Itest -Isrc \
			-c $(PURE_HOST_SRC) -o $(PIC10F322_LOCKSTEP_MODEL_OBJ) && \
		$(PIC_SOAK_CXX) -std=c++17 -O2 $$(pkg-config --cflags glib-2.0) \
			-isystem $(PIC_SOAK_GPSIM_INC) -Itest -Isrc \
			-DFW_PATH='"$(CURDIR)/$(PIC10F322_LOCKSTEP_HEX)"' -DPROC_NAME='"$(PIC10F322_GPSIM_PROC)"' \
			-DF_CPU_HZ=$(PIC10F322_XTAL) $(PIC10F322_LOCKSTEP_CTX_DEF) \
			$(PIC10F322_LOCKSTEP_SRC) $(PIC10F322_LOCKSTEP_MODEL_OBJ) -o $(PIC10F322_LOCKSTEP_BIN) -lgpsim

$(PIC10F322_LOCKSTEP_BIN): $(PIC10F322_LOCKSTEP_SRC) $(PIC_TARGET_LOCKSTEP_CORE_HDR) $(PIC_TARGET_RESULT_HDR) \
                     $(PIC_PIN_LOOKUP_HDR) $(PIC_GPSIM_BOOTSTRAP_HDR) $(PURE_HOST_DEP)
	$(PIC10F322_LOCKSTEP_COMPILE)

.PHONY: pic10f322-test-lockstep
pic10f322-test-lockstep: variant-selectors-valid pic10f322
	@if ! command -v $(PIC_SOAK_CXX) >/dev/null 2>&1; then \
		echo "no C++ compiler ($(PIC_SOAK_CXX)); skipping PIC lock-step"; $(SKIP); \
	fi; \
	if [ ! -f "$(PIC_SOAK_GPSIM_INC)/sim_context.h" ]; then \
		echo "gpsim-dev headers not at $(PIC_SOAK_GPSIM_INC); skipping PIC lock-step (install gpsim-dev)"; $(SKIP); \
	fi; \
	if ! pkg-config --exists glib-2.0 2>/dev/null; then \
		echo "libglib2.0-dev not found; skipping PIC lock-step (install libglib2.0-dev)"; $(SKIP); \
	fi; \
	if [ ! -f "$(PIC10F322_LOCKSTEP_HEX)" ]; then \
		echo "no $(PIC10F322_LOCKSTEP_HEX) (XC8 absent?); skipping PIC lock-step for variant $(PIC10F322_LOCKSTEP_VARIANT)"; $(SKIP); \
	fi; \
	s="$(PIC10F322_LOCKSTEP_HEX:.hex=.s)"; \
	alloc=`awk 'prev=="_ctx_:"{print $$2; exit} {prev=$$1}' "$$s" 2>/dev/null`; \
	if [ "$$alloc" != "3" ]; then \
		echo "FAIL: _ctx_ allocates $${alloc:-?} bytes in $$s -- expected 3 (packed 1-byte enums)."; \
		echo "      test_lockstep_pic.cc reads ctx_+0/+1/+2; fix offsets if packing changed."; \
		exit 1; \
	fi; \
	ctx_addr=`awk '$$1=="_ctx_"{print $$2; exit}' "$(PIC10F322_LOCKSTEP_SYM)" 2>/dev/null`; \
	if [ -z "$$ctx_addr" ]; then \
		echo "FAIL: _ctx_ symbol not found in $(PIC10F322_LOCKSTEP_SYM); lock-step cannot read firmware state."; \
		exit 1; \
	fi; \
	echo "--- PIC lock-step: variant=$(PIC10F322_LOCKSTEP_VARIANT) proc=$(PIC10F322_GPSIM_PROC) (ctx_ layout verified: 3 bytes) ---"; \
	rm -f $(PIC10F322_LOCKSTEP_BIN) && \
	$(PIC10F322_LOCKSTEP_COMPILE) && \
	./$(PIC10F322_LOCKSTEP_BIN)

# --- PIC built-HEX GPIO transitions + pulse timing (libgpsim) ----------------
# Observe the real XC8 instruction stream around startup and an engage/bypass
# round trip. Asserts exact TRISA/ANSELA/LATA/PORTA behaviour, relay coil
# exclusion, and mute/relay pulse widths. Standalone use is skip-clean;
# pic10f322-test-target below requires the TARGET-IO PASS sentinel.
PIC10F322_IO_VARIANT ?= cd4053_simple
PIC10F322_IO_SRC = test/pic/test_io_pic.cc
PIC10F322_IO_BIN = test/pic/test_io_pic
PIC10F322_IO_HEX = $(PIC10F322_BUILD_DIR)/$(call fw_image,$(PIC10F322_IO_VARIANT),$(PIC10F322_TAG)).hex
PIC10F322_IO_COMPILE = $(PIC_SOAK_CXX) -std=c++17 -O2 $$(pkg-config --cflags glib-2.0) \
		-isystem $(PIC_SOAK_GPSIM_INC) -Itest -Isrc \
		-DFW_PATH='"$(CURDIR)/$(PIC10F322_IO_HEX)"' -DPROC_NAME='"$(PIC10F322_GPSIM_PROC)"' \
		-DF_CPU_HZ=$(PIC10F322_XTAL) -D$(macro_$(PIC10F322_IO_VARIANT)) \
		$(PIC10F322_IO_SRC) -o $(PIC10F322_IO_BIN) -lgpsim

$(PIC10F322_IO_BIN): $(PIC10F322_IO_SRC) $(PIC_TARGET_IO_CORE_HDR) $(PIC_TARGET_RESULT_HDR) $(PIC_PIN_LOOKUP_HDR) \
               $(PIC_GPSIM_BOOTSTRAP_HDR) $(PIC10F32X_REGS_HDR)
	$(PIC10F322_IO_COMPILE)

.PHONY: pic10f322-test-io
pic10f322-test-io: variant-selectors-valid pic10f322
	@if ! command -v $(PIC_SOAK_CXX) >/dev/null 2>&1; then \
		echo "no C++ compiler ($(PIC_SOAK_CXX)); skipping PIC target-I/O test"; $(SKIP); \
	fi; \
	if [ ! -f "$(PIC_SOAK_GPSIM_INC)/sim_context.h" ]; then \
		echo "gpsim-dev headers not at $(PIC_SOAK_GPSIM_INC); skipping PIC target-I/O test (install gpsim-dev)"; $(SKIP); \
	fi; \
	if ! pkg-config --exists glib-2.0 2>/dev/null; then \
		echo "libglib2.0-dev not found; skipping PIC target-I/O test (install libglib2.0-dev)"; $(SKIP); \
	fi; \
	if [ ! -f "$(PIC10F322_IO_HEX)" ]; then \
		echo "no $(PIC10F322_IO_HEX) (XC8 absent?); skipping PIC target-I/O for variant $(PIC10F322_IO_VARIANT)"; $(SKIP); \
	fi; \
	echo "--- PIC target I/O: variant=$(PIC10F322_IO_VARIANT) proc=$(PIC10F322_GPSIM_PROC) ---"; \
	rm -f $(PIC10F322_IO_BIN) && \
	$(PIC10F322_IO_COMPILE) && \
	./$(PIC10F322_IO_BIN)

# Fail-closed real-HEX aggregate. The individual libgpsim targets above remain
# convenient skip-clean development commands; this wrapper requires explicit PASS
# markers, so a missing compiler/header, missing ctx_ symbol, or partial run fails
# CI/release instead of masquerading as green.
PIC10F322_TARGET_VARIANT ?= cd4053_simple
override PIC10F322_TARGET_VARIANTS_SUPPORTED := $(CLASSIC_VARIANTS_SUPPORTED)
.PHONY: pic10f322-test-target pic10f322-test-target-variants
pic10f322-test-target: variant-selectors-valid
	@set -e; \
	for spec in \
		"pic10f322-test-fault PIC10F322_FAULT_VARIANT=$(PIC10F322_TARGET_VARIANT)|FAULT-INJECT PASS" \
		"pic10f322-test-lockstep PIC10F322_LOCKSTEP_VARIANT=$(PIC10F322_TARGET_VARIANT)|LOCK-STEP PASS" \
		"pic10f322-test-io PIC10F322_IO_VARIANT=$(PIC10F322_TARGET_VARIANT)|TARGET-IO PASS"; do \
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
	@echo "=== PIC target fault/lock-step/I-O PASS (variant $(PIC10F322_TARGET_VARIANT)) ==="

pic10f322-test-target-variants:
	@if [ "$(CLASSIC_VARIANTS_REQUEST_EMPTY)" -eq 1 ]; then \
		echo "FAIL: VARIANTS must not be empty" >&2; exit 2; \
	fi; \
	if [ "$(CLASSIC_VARIANTS_REQUEST_DUPLICATE)" -eq 1 ]; then \
		echo "FAIL: VARIANTS must not contain duplicate names" >&2; exit 2; \
	fi; \
	if [ "$(CLASSIC_VARIANTS_REQUEST_UNKNOWN)" -eq 1 ]; then \
		echo "FAIL: VARIANTS contains unsupported names; supported: $(PIC10F322_TARGET_VARIANTS_SUPPORTED)" >&2; exit 2; \
	fi; \
	if [ "$(if $(filter-out $(VARIANTS),$(PIC10F322_TARGET_VARIANTS_SUPPORTED)),yes,no)" = yes ]; then \
		echo "FAIL: VARIANTS must contain every supported name; required: $(PIC10F322_TARGET_VARIANTS_SUPPORTED)" >&2; exit 2; \
	fi
	@for v in $(PIC10F322_TARGET_VARIANTS_SUPPORTED); do \
		echo "===================== PIC TARGET VARIANT $$v ====================="; \
		$(MAKE) --no-print-directory PIC10F322_TARGET_VARIANT=$$v pic10f322-test-target || exit 1; \
	done
	@echo "=== PIC target fault/lock-step/I-O validated for all variants ==="

# --- PIC device programming (hardware) ---------------------------------------
# Flash ONE built PIC variant (chosen by VARIANT, default $(VARIANT)) onto a real
# PIC10F322. Unlike AVR fuses, the PIC CONFIG word is embedded IN the HEX by
# XC8's `#pragma config`, so writing the HEX programs the configuration too --
# there is no separate fuse step (and the gpsim/CONFIG-word checks already
# verified that word pre-flash).
#
# Two common Linux programmers, selected by PIC10F322_PROG:
#   pk2cmd  (PICkit 2, open-source CLI)            <- default
#   ipecmd  (PICkit 3/4/5 via MPLAB IPE; PIC10F322_PROG=ipecmd, PIC10F322_PROG_TOOL=PK3|PK4|PK5)
# The full command is PIC10F322_PROG_CMD; override it wholesale for any other tool.
# Power defaults are CONSERVATIVE: the programmer does NOT source Vdd (safe for an
# externally-powered pedal board). For a bare chip powered by the programmer, add
# the power flag: pk2cmd `-T` (and `-A<volts>`), ipecmd `-W`.
PIC10F322_PART      ?= PIC10F322
PIC10F322_PROG      ?= pk2cmd
PIC10F322_PROG_TOOL ?= PK4
PIC10F322_PROG_HEX   = $(PIC10F322_BUILD_DIR)/$(call fw_image,$(VARIANT),$(PIC10F322_TAG)).hex
ifeq ($(PIC10F322_PROG),ipecmd)
PIC10F322_PROG_CMD ?= $(PIC10F322_PROG) -TP$(PIC10F322_PROG_TOOL) -P$(PIC10F322_PART) -M -F$(PIC10F322_PROG_HEX)
else
PIC10F322_PROG_CMD ?= $(PIC10F322_PROG) -P$(PIC10F322_PART) -F$(PIC10F322_PROG_HEX) -M -Y -R
endif

# Builds all variants + the flash-budget gate first (so the image is fresh and
# proven to fit), then flashes the VARIANT-selected HEX. Unlike the pre-hardware
# checks, this is an intentional bench action: it FAILS LOUDLY (does not silently
# skip) if the HEX or the programmer is missing. Echoes the exact command before
# it touches silicon.
.PHONY: pic10f322-program
pic10f322-program: variant-selectors-valid pic10f322
	@hex="$(PIC10F322_PROG_HEX)"; \
	if [ ! -f "$$hex" ]; then \
		echo "ERROR: $$hex not found -- 'make pic10f322' produced no HEX (XC8 installed?)."; \
		echo "       select a variant with VARIANT=<$(VARIANTS)> (default $(VARIANT))."; \
		exit 1; \
	fi; \
	if ! command -v $(PIC10F322_PROG) >/dev/null 2>&1; then \
		echo "ERROR: PIC programmer '$(PIC10F322_PROG)' not found on PATH."; \
		echo "       install pk2cmd (PICkit 2), or set PIC10F322_PROG=ipecmd (PICkit 3/4/5),"; \
		echo "       or override the whole command with PIC10F322_PROG_CMD=..."; \
		exit 1; \
	fi; \
	echo "Programming PIC10F322 (variant $(VARIANT)) via $(PIC10F322_PROG):"; \
	echo "  $(PIC10F322_PROG_CMD)"; \
	$(PIC10F322_PROG_CMD)

# ============================================================================
# BUILD -- ATtiny202 (AVR-XT / avrxmega3) toolchain/device-pack smoke gate
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
# `make attiny202-smoke` is a COMPILE/LINK gate independent of the shipping
# firmware build below. It builds test/avr/attiny202_smoke.c -- which exercises
# every peripheral group the shell drives (PORTA GPIO + PINnCTRL pull-up,
# CCP-protected CLKCTRL + WDT, TCB0 tick ISR, SLPCTRL idle, RSTCTRL) -- with the
# project's exact strict CFLAGS, then asserts the emitted image is avrxmega3 and
# fits the 2 KB flash budget. It is a standalone developer target because the DFP
# may be absent; release qualification runs it through `attiny202-test` with
# STRICT_TOOLS=1. Missing vendored device files therefore skip locally and fail
# closed for release.
XT_MCU   ?= attiny202
XT_DEVLIB ?= tn202
XT_DFP   ?= third_party/attiny_dfp
XT_SPEC_DIR = $(XT_DFP)/gcc/dev/$(XT_MCU)
XT_INC      = $(XT_DFP)/include
# ATtiny202: 2 KB flash / 128 B SRAM. Budget the smoke against the full 2 KB;
# the shipping build below enforces the same limit independently. NOTE:
# avr-size --mcu=attiny202 prints "Device: Unknown" under binutils 2.26 but STILL
# reports Program:/Data: byte counts (without percentage suffixes), so the awk
# parse below accepts both unknown-device and recognized-device forms.
XT_FLASH_BYTES ?= 2048
# The device capacity is silicon, not policy, and cannot be overridden. Static
# data is held to a separately reviewed 16 B ceiling so 112 B remains available
# for the runtime stack and interrupt context.
override XT_SRAM_BYTES := 128
# Override only when deliberately reviewing a tighter or experimental policy;
# the release/default limit remains 16 B.
XT_STATIC_RAM_LIMIT ?= 16
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
# BUILD -- ATtiny202 (AVR-XT / avrxmega3) release-supported firmware
# ============================================================================
#
# The real firmware build (the smoke gate above only proves the toolchain). The
# ATtiny202 shell (src/bypass_mcu_avr_xt.c) implements the same bypass_hw_iface.h
# contract as the classic-AVR and PIC shells and links the UNCHANGED pure core
# (bypass_pure.c) + one output driver -- exactly like `attiny13a` / `pic10f322`. Like the
# PIC build it consumes a vendored DFP and gates every variant on the device's
# 2 KB flash and reviewed static-RAM budgets. Developer invocations skip cleanly
# when the DFP is absent;
# CI/release gates use STRICT_TOOLS=1 so missing prerequisites fail closed.
#
# simavr/QEMU do not model AVR8X, but yasimavr DOES: the `attiny202-sim` /
# -soak / -fault targets below run the real built image on a patched yasimavr
# (scripts/fetch_yasimavr.sh), giving the shell register-level dynamic coverage
# close to the classic simavr harness. The shell is thus validated by (1) this
# strict-flag cross-build, (2) the flash/static-RAM and frame gates, (3) cppcheck
# + MISRA static analysis (attiny202-analyze), and (4) the yasimavr harness. Real
# hardware-bench validation remains a documented gap. The pure core keeps full
# host + formal coverage via `make test`.
XT_BUILD_DIR ?= build_avr_xt
XT_TAG       ?= attiny202
XT_F_CPU     ?= 2000000UL
override XT_VARIANTS_SUPPORTED := cd4053_simple cd4053_with_mute tq2_l2_5v_relay
override XT_VARIANTS_REQUESTED := $(filter $(XT_VARIANTS_SUPPORTED),$(VARIANTS))
override XT_VARIANTS_UNKNOWN := $(CLASSIC_VARIANTS_UNKNOWN)
# The shell + the unchanged pure core (the AVR-classic counterpart is CORE_SRC).
XT_CORE_SRC = src/bypass_mcu_avr_xt.c src/bypass_pure.c
# Headers that, if changed, should rebuild the XT images: the FW_HEADERS set with
# the AVR-XT pin map substituted for the classic one.
XT_HEADERS = src/bypass_config.h src/bypass_types.h src/bypass_hw_iface.h \
             src/bypass_pure.h \
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
# expand inside a shell loop). Emits bypass-attiny202-<output stage>.elf/.hex.
.PHONY: attiny202
attiny202: | $(XT_BUILD_DIR)
	@if ! rm -f "$(XT_BUILD_DIR)"/$(FW_BASE)-$(XT_TAG)-*.elf \
			"$(XT_BUILD_DIR)"/$(FW_BASE)-$(XT_TAG)-*.hex \
			"$(XT_BUILD_DIR)"/$(FW_BASE)-$(XT_TAG)-*.elf.tmp \
			"$(XT_BUILD_DIR)"/$(FW_BASE)-$(XT_TAG)-*.hex.tmp; then \
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
	$(IHEX_VALIDATOR_CHECK); \
	echo "=== ATtiny202 (avrxmega3) build + resource budgets (flash $(XT_FLASH_BYTES) B, static RAM $(XT_STATIC_RAM_LIMIT)/$(XT_SRAM_BYTES) B) ==="; \
	if ! awk -v t="$(XT_FLASH_BYTES)" 'BEGIN {exit !(t ~ /^[0-9]+$$/ && t ~ /[1-9]/)}'; then \
		echo "FAIL: XT_FLASH_BYTES must be a positive decimal integer"; exit 2; \
	fi; \
	if ! awk -v t="$(XT_STATIC_RAM_LIMIT)" -v s="$(XT_SRAM_BYTES)" ' \
		function decimal_gt(a, b) { \
			sub(/^0+/, "", a); sub(/^0+/, "", b); \
			if (a == "") a = "0"; if (b == "") b = "0"; \
			if (length(a) != length(b)) return length(a) > length(b); \
			return ("x" a) > ("x" b); \
		} \
		BEGIN { exit !(t ~ /^[0-9]+$$/ && t ~ /[1-9]/ \
			&& s ~ /^[0-9]+$$/ && s ~ /[1-9]/ && !decimal_gt(t, s)) }'; then \
		echo "FAIL: XT_STATIC_RAM_LIMIT must be a positive decimal integer no greater than the $(XT_SRAM_BYTES) B device SRAM"; exit 2; \
	fi; \
	if [ "$(CLASSIC_VARIANTS_REQUEST_EMPTY)" -eq 1 ]; then \
		echo "FAIL: VARIANTS is empty; no ATtiny202 images requested"; exit 2; \
	fi; \
	if [ "$(words $(XT_VARIANTS_UNKNOWN))" -ne 0 ]; then \
		echo "FAIL: VARIANTS contains an unsupported ATtiny202 variant"; exit 2; \
	fi; \
	if [ "$(CLASSIC_VARIANTS_REQUEST_DUPLICATE)" -eq 1 ]; then \
		echo "FAIL: VARIANTS contains a duplicate ATtiny202 variant"; exit 2; \
	fi; \
	set -- $(XT_VARIANTS_REQUESTED); \
	$(fw_image_sh); \
	fail=0; \
	for v in "$$@"; do \
		case $$v in \
			cd4053_simple)    m=CD4053_SIMPLE;    drv=src/bypass_output_cd4053_simple.c ;; \
			cd4053_with_mute) m=CD4053_WITH_MUTE; drv=src/bypass_output_cd4053_with_mute.c ;; \
			tq2_l2_5v_relay)  m=TQ2_L2_5V_RELAY;  drv=src/bypass_output_tq2_l2_5v_relay.c ;; \
			*) echo "FAIL: unsupported ATtiny202 variant '$$v'"; fail=1; continue ;; \
		esac; \
		stem=$(XT_BUILD_DIR)/`fw_image_of "$$v" $(XT_TAG)`; \
		elf=$$stem.elf; \
		hex=$$stem.hex; \
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
		size_records=`printf '%s\n' "$$size_out" | awk ' \
			/^[[:space:]]*Program:/ { \
				program_count++; \
				if ($$0 !~ /^[[:space:]]*Program:[[:space:]]+[0-9]+[[:space:]]+bytes([[:space:]]+\([0-9]+([.][0-9]+)?%[[:space:]]+Full\))?$$/) bad = "malformed Program size record: " $$0; \
				program = $$2; \
			} \
			/^[[:space:]]*Data:/ { \
				data_count++; \
				if ($$0 !~ /^[[:space:]]*Data:[[:space:]]+[0-9]+[[:space:]]+bytes([[:space:]]+\([0-9]+([.][0-9]+)?%[[:space:]]+Full\))?$$/) bad = "malformed Data size record: " $$0; \
				data = $$2; \
			} \
			END { \
				if (bad != "") { print bad; exit 1 } \
				if (program_count != 1) { printf "expected exactly one Program size record, found %d\n", program_count; exit 1 } \
				if (data_count != 1) { printf "expected exactly one Data size record, found %d\n", data_count; exit 1 } \
				if (program !~ /^[0-9]+$$/ || program !~ /[1-9]/) { print "Program size must be a positive decimal integer"; exit 1 } \
				if (data !~ /^[0-9]+$$/ || data !~ /[1-9]/) { print "Data size must be a positive decimal integer"; exit 1 } \
				print program, data \
			}'`; \
		if [ $$? -ne 0 ]; then \
			echo "FAIL: invalid avr-size output for ATtiny202 variant $$v: $$size_records"; \
			rm -f "$$elf_tmp" "$$hex_tmp" "$$log"; fail=1; continue; \
		fi; \
		set -- $$size_records; used=$$1; data_used=$$2; \
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
		if awk -v u="$$data_used" -v t="$(XT_STATIC_RAM_LIMIT)" 'BEGIN { \
			sub(/^0+/, "", u); sub(/^0+/, "", t); \
			if (u == "") u = "0"; if (t == "") t = "0"; \
			if (length(u) > length(t)) exit 0; \
			if (length(u) < length(t)) exit 1; \
			exit !(("x" u) > ("x" t)); \
		}'; then \
			echo "FAIL: $$v static RAM uses $$data_used B -- exceeds $(XT_STATIC_RAM_LIMIT) B policy limit ($(XT_SRAM_BYTES) B device SRAM)"; \
			rm -f "$$elf_tmp" "$$hex_tmp" "$$log"; fail=1; continue; \
		fi; \
		pct=`awk -v u="$$used" -v t="$(XT_FLASH_BYTES)" 'BEGIN{printf "%.1f", u*100/t}'`; \
		if ! $(OBJCOPY) -O ihex -R .eeprom "$$elf_tmp" "$$hex_tmp"; then \
			echo "FAIL: could not generate HEX for ATtiny202 variant $$v"; \
			rm -f "$$elf_tmp" "$$hex_tmp" "$$log"; fail=1; continue; \
		fi; \
		if ! $(IHEX_VALIDATOR) "$$hex_tmp"; then \
			echo "FAIL: objcopy produced an empty or invalid HEX for ATtiny202 variant $$v"; \
			rm -f "$$elf_tmp" "$$hex_tmp" "$$log"; fail=1; continue; \
		fi; \
		if ! mv "$$elf_tmp" "$$elf" || ! mv "$$hex_tmp" "$$hex"; then \
			echo "FAIL: could not publish ATtiny202 artifacts for variant $$v"; \
			rm -f "$$elf" "$$hex" "$$elf_tmp" "$$hex_tmp" "$$log"; fail=1; continue; \
		fi; \
		rm -f "$$log"; \
		echo "OK:   $$v -> $$hex : flash $$used B ($${pct}%) of $(XT_FLASH_BYTES) B; static RAM $$data_used/$(XT_STATIC_RAM_LIMIT) B ($(XT_SRAM_BYTES) B device)"; \
	done; \
	exit $$fail

# Compile the AVR-XT shell once for each immutable production variant using the
# shipping compile flags plus -fstack-usage. This is deliberately separate from
# the classic AVR frame gate: the shell and ABI are different, and a caller's
# development VARIANTS subset must not reduce production evidence.
# Match the existing reviewed AVR per-frame policy unless explicitly tightening
# it for an investigation.
XT_STACK_MAX_FRAME ?= 32
XT_STACK_BUILD_DIR ?=
override XT_STACK_SOURCE := src/bypass_mcu_avr_xt.c

attiny202-test-stack-bound: $(XT_STACK_SOURCE)
	@if [ ! -f test/check_stack_usage.sh ] || [ -L test/check_stack_usage.sh ] \
			|| [ ! -x test/check_stack_usage.sh ]; then \
		echo "FAIL: canonical stack-usage checker is missing, symlinked, or not executable"; exit 1; \
	fi
	@stack_dir="$(XT_STACK_BUILD_DIR)"; remove_dir=0; \
	if [ -z "$$stack_dir" ]; then \
		stack_dir=$$(mktemp -d "$${TMPDIR:-$(HOME)}/mcu-xt-stack-bound.XXXXXX") \
			|| { echo "FAIL: could not create private AVR-XT stack-evidence directory"; exit 1; }; \
		remove_dir=1; \
	elif ! mkdir -p "$$stack_dir"; then \
		echo "FAIL: could not create AVR-XT stack-evidence directory $$stack_dir"; exit 1; \
	fi; \
	cleanup_xt_stack_bound() { \
		rc=$$?; \
		rm -f "$$stack_dir"/stack_*.o "$$stack_dir"/stack_*.su || rc=1; \
		if [ "$$remove_dir" -eq 1 ]; then rmdir "$$stack_dir" || rc=1; fi; \
		trap - 0; exit $$rc; \
	}; \
	trap cleanup_xt_stack_bound 0; \
	if ! rm -f "$$stack_dir"/stack_*.o "$$stack_dir"/stack_*.su; then \
		echo "FAIL: could not remove stale AVR-XT stack evidence"; exit 1; \
	fi; \
	if [ ! -f "$(XT_SPEC_FILE)" ] || [ ! -f "$(XT_IO_HEADER)" ]; then \
		echo "ATtiny_DFP device files not found under XT_DFP=$(XT_DFP); skipping ATtiny202 stack bound."; \
		echo "  Fetch them with: scripts/fetch_attiny_dfp.sh $(XT_DFP)"; \
		$(SKIP); \
	fi; \
	if ! awk -v max="$(XT_STACK_MAX_FRAME)" 'BEGIN {exit !(max ~ /^[0-9]+$$/ && max ~ /[1-9]/)}'; then \
		echo "FAIL: XT_STACK_MAX_FRAME must be a positive decimal integer"; exit 2; \
	fi; \
	echo "=== ATtiny202 -fstack-usage static bound (limit: $(XT_STACK_MAX_FRAME) B/frame) ==="; \
	expected=0; \
	for v in $(XT_VARIANTS_SUPPORTED); do \
		case $$v in \
			cd4053_simple)    m=CD4053_SIMPLE ;; \
			cd4053_with_mute) m=CD4053_WITH_MUTE ;; \
			tq2_l2_5v_relay)  m=TQ2_L2_5V_RELAY ;; \
			*) echo "FAIL: unsupported immutable ATtiny202 stack variant '$$v'"; exit 2 ;; \
		esac; \
		obj="$$stack_dir/stack_xt_$${v}.o"; su="$${obj%.o}.su"; \
		expected=$$((expected + 1)); \
		if ! $(CC) $(XT_FW_CFLAGS) -D$$m -fstack-usage -c "$(XT_STACK_SOURCE)" -o "$$obj"; then \
			echo "FAIL: compilation error during ATtiny202 -fstack-usage build: $$v"; exit 1; \
		fi; \
		if [ ! -s "$$obj" ]; then \
			echo "FAIL: compiler produced no AVR-XT stack-check object for $$v"; exit 1; \
		fi; \
		if [ ! -s "$$su" ]; then \
			echo "FAIL: compiler produced no AVR-XT stack-usage report for $$v"; exit 1; \
		fi; \
	done; \
	set -- "$$stack_dir"/stack_*.o; actual_obj=$$#; [ -e "$$1" ] || actual_obj=0; \
	if [ "$$actual_obj" -ne "$$expected" ]; then \
		echo "FAIL: expected $$expected AVR-XT stack-check objects, found $$actual_obj"; exit 1; \
	fi; \
	set -- "$$stack_dir"/stack_*.su; actual_su=$$#; [ -e "$$1" ] || actual_su=0; \
	if [ "$$actual_su" -ne "$$expected" ]; then \
		echo "FAIL: expected $$expected AVR-XT stack-usage reports, found $$actual_su"; exit 1; \
	fi; \
	if ! test/check_stack_usage.sh "$(XT_STACK_MAX_FRAME)" "$$@"; then exit 1; fi; \
	echo "OK: $$actual_su fresh AVR-XT reports; all frames <= $(XT_STACK_MAX_FRAME) B"

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
# The AVR-XT analogue of the AVR-classic simavr suite (test-sim-attiny13a / test-soak /
# fault-inject) and the PIC libgpsim track (pic10f322-test-gpsim / -soak / -fault):
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
# skips without the DFP and `pic10f322-test-soak` skips without gpsim-dev. CI builds
# the venv explicitly (a fetch step) so a skip there cannot mask a real failure.
#
# XT_SIM_VARIANT selects one supported variant; empty
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
# Soak knobs (parity with the PIC soak's PIC10F322_SOAK_*). Default 1 h
# simulated (~17 s
# wall/variant in yasimavr fast mode); pass 86400000 for 24 h.
XT_SOAK_DURATION_MS ?= 3600000
XT_SOAK_LIVENESS_INTERVAL_MS ?= 60000
XT_SOAK_PROGRESS_INTERVAL_MS ?= 600000
# Combination label bound into the driver's SOAK_RESULT record (the shared
# release contract). Empty means "derive it per variant" -- attiny202_<variant>,
# which is exactly what RELEASE_SOAK_NAMES declares. The release orchestrator
# pins it explicitly, one combination per run, as it does for all three PIC soaks.
XT_SOAK_COMBINATION_NAME ?=

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
	@selected="$(XT_SIM_VARIANT)"; \
	if [ -n "$$selected" ]; then \
		case "$$selected" in cd4053_simple|cd4053_with_mute|tq2_l2_5v_relay) ;; \
			*) echo "FAIL: XT_SIM_VARIANT must be one supported variant"; exit 2 ;; esac; \
		case " $(VARIANTS) " in *" $$selected "*) ;; \
			*) echo "FAIL: XT_SIM_VARIANT=$$selected is not in VARIANTS=$(VARIANTS)"; exit 2 ;; esac; \
	fi; \
	if [ ! -f "$(XT_SPEC_FILE)" ] || [ ! -f "$(XT_IO_HEADER)" ]; then \
		echo "ATtiny_DFP device files not found; skipping ATtiny202 simulation."; $(SKIP); \
	fi; \
	$(yasimavr_skip_if_absent); \
	$(fw_image_sh); \
	vars="$$selected"; [ -n "$$vars" ] || vars="$(VARIANTS)"; \
	fail=0; ran=0; \
	for v in $$vars; do \
		elf=$(XT_BUILD_DIR)/`fw_image_of "$$v" $(XT_TAG)`.elf; \
		if [ ! -f "$$elf" ]; then \
			echo "FAIL: expected ATtiny202 image missing: $$elf"; fail=1; continue; \
		fi; \
		echo "--- ATtiny202 sim (functional): variant=$$v ---"; \
		ran=1; \
		PYTHONPATH=test/avr ATTINY202_VARIANT=$$v $(XT_FUSE_ENV) \
		$(YASIMAVR_PY) $(XT_SIM_DRIVER) "$$elf" || fail=1; \
	done; \
	if [ "$$ran" = 0 ]; then echo "FAIL: no ATtiny202 images were simulated"; fail=1; fi; \
	exit $$fail

# Fault injection: corrupt each guarded critical SFR / state byte in the running
# image and assert the shell catches it -- the per-tick sanity gate diverts to
# the force-reset spin, or (for the tick timer itself) the watchdog resets on
# lost liveness. Mirror image of the soak: a reset is the PASS here. Same guard /
# skip / variant-selection contract as attiny202-sim.
.PHONY: attiny202-fault
attiny202-fault: test-fuses attiny202
	@selected="$(XT_SIM_VARIANT)"; \
	if [ -n "$$selected" ]; then \
		case "$$selected" in cd4053_simple|cd4053_with_mute|tq2_l2_5v_relay) ;; \
			*) echo "FAIL: XT_SIM_VARIANT must be one supported variant"; exit 2 ;; esac; \
		case " $(VARIANTS) " in *" $$selected "*) ;; \
			*) echo "FAIL: XT_SIM_VARIANT=$$selected is not in VARIANTS=$(VARIANTS)"; exit 2 ;; esac; \
	fi; \
	if [ ! -f "$(XT_SPEC_FILE)" ] || [ ! -f "$(XT_IO_HEADER)" ]; then \
		echo "ATtiny_DFP device files not found; skipping ATtiny202 fault injection."; $(SKIP); \
	fi; \
	if [ ! -f "src/bypass_mcu_avr_xt.c" ]; then \
		echo "src/bypass_mcu_avr_xt.c not found; skipping ATtiny202 fault injection."; $(SKIP); \
	fi; \
	$(yasimavr_skip_if_absent); \
	$(fw_image_sh); \
	vars="$$selected"; [ -n "$$vars" ] || vars="$(VARIANTS)"; \
	fail=0; ran=0; \
	for v in $$vars; do \
		elf=$(XT_BUILD_DIR)/`fw_image_of "$$v" $(XT_TAG)`.elf; \
		if [ ! -f "$$elf" ]; then \
			echo "FAIL: expected ATtiny202 image missing: $$elf"; fail=1; continue; \
		fi; \
		echo "--- ATtiny202 fault-injection: variant=$$v ---"; \
		ran=1; \
		PYTHONPATH=test/avr $(XT_FUSE_ENV) \
		$(YASIMAVR_PY) $(XT_FAULT_DRIVER) "$$elf" || fail=1; \
	done; \
	if [ "$$ran" = 0 ]; then echo "FAIL: no ATtiny202 images were fault-injected"; fail=1; fi; \
	exit $$fail

# Long-duration soak: run the healthy image for XT_SOAK_DURATION_MS of simulated
# time and assert liveness holds throughout -- the watchdog never resets (a GPR0
# reset-witness stays armed) and a periodic 2-press round-trip still toggles the
# LED. Mirror image of the fault test: a reset is a FAILURE. An individual
# liveness failure is non-fatal WITHIN a run -- the driver logs it and reports a
# cumulative count -- but any nonzero count still fails the run, and so does a
# run that covered no image. Standalone; same guard / skip / variant-selection
# as the others.
#
# Fail-closed like its three siblings, and for the same reason: this target is a
# release-qualification input (RELEASE_SOAK_NAMES carries attiny202_relay), so
# "soaked nothing" must never read as "soak passed". An unsupported
# XT_SIM_VARIANT, absent DFP device files, a missing image, and an empty variant
# set are each reported rather than skipped past.
.PHONY: attiny202-soak
attiny202-soak: test-fuses attiny202
	@selected="$(XT_SIM_VARIANT)"; \
	if [ -n "$$selected" ]; then \
		case "$$selected" in cd4053_simple|cd4053_with_mute|tq2_l2_5v_relay) ;; \
			*) echo "FAIL: XT_SIM_VARIANT must be one supported variant"; exit 2 ;; esac; \
		case " $(VARIANTS) " in *" $$selected "*) ;; \
			*) echo "FAIL: XT_SIM_VARIANT=$$selected is not in VARIANTS=$(VARIANTS)"; exit 2 ;; esac; \
	fi; \
	if [ ! -f "$(XT_SPEC_FILE)" ] || [ ! -f "$(XT_IO_HEADER)" ]; then \
		echo "ATtiny_DFP device files not found; skipping ATtiny202 soak."; $(SKIP); \
	fi; \
	$(yasimavr_skip_if_absent); \
	$(fw_image_sh); \
	vars="$$selected"; [ -n "$$vars" ] || vars="$(VARIANTS)"; \
	fail=0; ran=0; \
	for v in $$vars; do \
		elf=$(XT_BUILD_DIR)/`fw_image_of "$$v" $(XT_TAG)`.elf; \
		if [ ! -f "$$elf" ]; then \
			echo "FAIL: expected ATtiny202 image missing: $$elf"; fail=1; continue; \
		fi; \
		echo "--- ATtiny202 soak: variant=$$v duration=$(XT_SOAK_DURATION_MS) ms ---"; \
		ran=1; \
		combo="$(XT_SOAK_COMBINATION_NAME)"; \
		[ -n "$$combo" ] || combo="attiny202_$$v"; \
		PYTHONPATH=test/avr \
		$(XT_FUSE_ENV) \
		ATTINY202_SOAK_DURATION_MS=$(XT_SOAK_DURATION_MS) \
		ATTINY202_SOAK_LIVENESS_INTERVAL_MS=$(XT_SOAK_LIVENESS_INTERVAL_MS) \
		ATTINY202_SOAK_PROGRESS_INTERVAL_MS=$(XT_SOAK_PROGRESS_INTERVAL_MS) \
		ATTINY202_SOAK_COMBINATION_NAME="$$combo" \
		$(YASIMAVR_PY) $(XT_SOAK_DRIVER) "$$elf" || fail=1; \
	done; \
	if [ "$$ran" = 0 ]; then echo "FAIL: no ATtiny202 images were soaked"; fail=1; fi; \
	exit $$fail

# Firmware/model LOCK-STEP co-simulation -- the AVR-XT counterpart of the
# AVR-classic test_lockstep_cosim() (test/avr/test_sim.c) and the PIC
# pic10f322-test-lockstep. After every settled 1ms tick it reads the shell's `ctx_`
# out of simulated SRAM and requires all three bytes to equal the golden model's
# state after the same tick and the same input, so a shell defect surfaces as a
# mismatched byte on the tick it occurs rather than as a wrong LED later (or not
# at all). The other harness targets check observable behaviour; this one checks
# that the behaviour comes from the intended internal trajectory.
#
# The "golden model" is the SHIPPING pure core: XT_LOCKSTEP_FFI_LIB compiles
# test/avr/model_step_ffi.c against test/model_step.h and links the real
# src/bypass_pure.c into a host shared object, which the Python driver calls
# through ctypes. Nothing about the algorithm is re-implemented in Python -- the
# same discipline that makes model_step.h the single source of truth for the
# model checker, the symbolic test and the classic simavr oracle.
#
# The library is a HOST artifact (HOSTCC, never cross-compiled) and is built
# with the same PURE_HOST_CFLAGS shim test/formal/test_model_check uses, so it
# resolves the firmware's own thresholds out of src/bypass_config.h.
XT_LOCKSTEP_DRIVER  = test/avr/test_lockstep_attiny202.py
XT_LOCKSTEP_FFI_SRC = test/avr/model_step_ffi.c
XT_LOCKSTEP_FFI_LIB = $(XT_BUILD_DIR)/libbypass_model.so
# Ticks of pseudo-random stimulus per boot scenario, per variant (the driver
# runs both released-at-boot and pressed-at-boot). 5000 matches the classic
# lock-step's full-run SIM_LOCKSTEP_ITERS; the whole matrix -- 3 variants x 2
# boot scenarios x 5000 ticks -- costs about 5 s, so there is no fast-mode
# reduction to make here.
XT_LOCKSTEP_ITERS ?= 5000

$(XT_LOCKSTEP_FFI_LIB): $(XT_LOCKSTEP_FFI_SRC) test/model_step.h \
		test/bypass_config_host.h src/bypass_config.h $(PURE_HOST_DEP) \
		| $(XT_BUILD_DIR)
	$(HOSTCC) $(HOST_CFLAGS) $(PURE_HOST_CFLAGS) -Itest -Isrc -fPIC -shared \
		$(XT_LOCKSTEP_FFI_SRC) $(PURE_HOST_SRC) -o $@

.PHONY: attiny202-lockstep
attiny202-lockstep: test-fuses attiny202 $(XT_LOCKSTEP_FFI_LIB)
	@selected="$(XT_SIM_VARIANT)"; \
	if [ -n "$$selected" ]; then \
		case "$$selected" in cd4053_simple|cd4053_with_mute|tq2_l2_5v_relay) ;; \
			*) echo "FAIL: XT_SIM_VARIANT must be one supported variant"; exit 2 ;; esac; \
		case " $(VARIANTS) " in *" $$selected "*) ;; \
			*) echo "FAIL: XT_SIM_VARIANT=$$selected is not in VARIANTS=$(VARIANTS)"; exit 2 ;; esac; \
	fi; \
	if [ ! -f "$(XT_SPEC_FILE)" ] || [ ! -f "$(XT_IO_HEADER)" ]; then \
		echo "ATtiny_DFP device files not found; skipping ATtiny202 lock-step."; $(SKIP); \
	fi; \
	$(yasimavr_skip_if_absent); \
	$(fw_image_sh); \
	vars="$$selected"; [ -n "$$vars" ] || vars="$(VARIANTS)"; \
	fail=0; ran=0; \
	for v in $$vars; do \
		elf=$(XT_BUILD_DIR)/`fw_image_of "$$v" $(XT_TAG)`.elf; \
		if [ ! -f "$$elf" ]; then \
			echo "FAIL: expected ATtiny202 image missing: $$elf"; fail=1; continue; \
		fi; \
		echo "--- ATtiny202 lock-step: variant=$$v ticks=$(XT_LOCKSTEP_ITERS) ---"; \
		ran=1; \
		PYTHONPATH=test/avr ATTINY202_VARIANT=$$v $(XT_FUSE_ENV) \
		ATTINY202_LOCKSTEP_ITERS=$(XT_LOCKSTEP_ITERS) \
		BYPASS_MODEL_FFI=$(XT_LOCKSTEP_FFI_LIB) \
		$(YASIMAVR_PY) $(XT_LOCKSTEP_DRIVER) "$$elf" || fail=1; \
	done; \
	if [ "$$ran" = 0 ]; then echo "FAIL: no ATtiny202 images were co-simulated"; fail=1; fi; \
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

# One definition of each hardware action, so the single-step goals and the
# ordered transaction below cannot drift apart.
XT_PROG_HEX = $(XT_BUILD_DIR)/$(call fw_image,$(VARIANT),$(XT_TAG)).hex
XT_FUSE_WRITE = $(AVRDUDE) $(XT_AVRDUDE_FLAGS) \
		-U wdtcfg:w:$(XT_FUSE_WDTCFG):m   -U bodcfg:w:$(XT_FUSE_BODCFG):m \
		-U osccfg:w:$(XT_FUSE_OSCCFG):m   -U syscfg0:w:$(XT_FUSE_SYSCFG0):m \
		-U syscfg1:w:$(XT_FUSE_SYSCFG1):m -U append:w:$(XT_FUSE_APPEND):m \
		-U bootend:w:$(XT_FUSE_BOOTEND):m
XT_FLASH_WRITE = $(AVRDUDE) $(XT_AVRDUDE_FLAGS) -U flash:w:$(XT_PROG_HEX):i

.PHONY: attiny202-fuses attiny202-flash attiny202-program
attiny202-fuses:
	$(XT_FUSE_WRITE)

# Flash ONE variant image to hardware (select with VARIANT=<name>); builds first.
attiny202-flash: variant-selectors-valid attiny202
	$(XT_FLASH_WRITE)

# Fresh chip, as ONE ordered transaction: build and validate the selected image,
# then write the fuses, then flash it. The build is a prerequisite, not a step,
# so nothing reaches silicon if it fails; see AVR_PROGRAM_IMAGE_CHECK.
attiny202-program: variant-selectors-valid attiny202
	@hex="$(XT_PROG_HEX)"; \
	$(AVR_PROGRAM_IMAGE_CHECK); \
	$(AVR_PROGRAMMER_CHECK); \
	echo "Programming ATtiny202 (variant $(VARIANT)): fuses, then flash $$hex"
	$(XT_FUSE_WRITE)
	$(XT_FLASH_WRITE)

# --- ATtiny202 static analysis (cppcheck + MISRA addon) ----------------------
# Two analyzers over the AVR-XT shell, parallel to analyze-cppcheck/analyze-misra
# (classic) and pic10f322-analyze-* (PIC). STANDALONE (needs the vendored DFP + apt
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
                       -DBYPASS_MCU_AVR_XT -DF_CPU=$(XT_F_CPU) $(BYPASS_CTX_CHECK_FLAG) \
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
                     $(BYPASS_CTX_CHECK_UNREAD_SUPP_XT) \
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

attiny202-analyze-misra: src/bypass_mcu_avr_xt.c $(XT_HEADERS) $(MISRA_ADDON) $(MISRA_RULES) $(MISRA_SUPPRESS) $(MISRA_OUTPUT_GATE)
	@if ! command -v $(CPPCHECK) >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then \
		echo "cppcheck and/or python3 not available; skipping ATtiny202 MISRA analysis"; $(SKIP); \
	fi; \
	if [ ! -f "$(XT_IO_HEADER)" ]; then \
		echo "ATtiny_DFP device header not found (XT_DFP=$(XT_DFP)); skipping ATtiny202 MISRA analysis"; $(SKIP); \
	fi; \
	echo "MISRA-C:2012 analysis -- ATtiny202 shell ($(CPPCHECK) + misra addon, avr8)"; \
	out=`mktemp`; rc=0; \
	PYTHONWARNINGS=ignore $(CPPCHECK) $(XT_MISRA_CPPCHECK_FLAGS) \
		$(MISRA_DIAGNOSTIC_TEMPLATE) --suppressions-list=$(MISRA_SUPPRESS) \
		--error-exitcode=2 src/bypass_mcu_avr_xt.c 2>>$$out || rc=$$?; \
	if ! python3 "$(MISRA_OUTPUT_GATE)" --repo-root "$(CURDIR)" \
			--output "$$out" --tool-status "$$rc"; then \
		echo "MISRA findings NOT covered by a documented deviation:"; \
		echo ""; \
		echo "Fix it, or (if genuinely unavoidable) add a per-file entry to"; \
		echo "$(MISRA_SUPPRESS) with a matching record in MISRA_COMPLIANCE.md."; \
		rm -f $$out *.dump *.ctu-info cppcheck-addon-ctu-file-list*; \
		exit 1; \
	fi; \
	rm -f $$out *.dump *.ctu-info cppcheck-addon-ctu-file-list*; \
	echo "MISRA-C:2012 (ATtiny202 shell): clean (documented deviations waived per MISRA_COMPLIANCE.md)"

# Absolute coil-pulse WIDTH gate, read straight from the compiled image. The
# relay/mute pulses are avr-libc _delay_ms() busy loops, so their duration is a
# compile-time CPU-cycle count -- read most directly, and independently of any
# simulator, by disassembly. This gate owns that ABSOLUTE width. The yasimavr
# harness separately measures the DELIVERED width from traced pin edges, which
# runs a few percent longer because the 1 ms tick ISR preempts the busy loop
# (see test/avr/test_attiny202_delay_oracle.py and
# test_sim_attiny202.check_pulse_width); neither check replaces the other.
# This gate parses the _delay_ms loop count out of `avr-objdump -d`
# and asserts each variant's design widths (tq2_l2_5v_relay 12 ms x2,
# cd4053_with_mute 5 ms x2, cd4053_simple none) plus the relay's 4 ms datasheet
# minimum. Needs only binutils-avr
# (already required to build), so it runs in the same standalone pre-hardware
# aggregate; it skips cleanly (STRICT_TOOLS honored) when the DFP is absent.
.PHONY: attiny202-delay-oracle
attiny202-delay-oracle: attiny202
	@if [ ! -f "$(XT_SPEC_FILE)" ] || [ ! -f "$(XT_IO_HEADER)" ]; then \
		echo "ATtiny_DFP device files not found under XT_DFP=$(XT_DFP); skipping ATtiny202 delay-width oracle."; \
		$(SKIP); \
	fi; \
	command -v $(OBJDUMP) >/dev/null 2>&1 \
		|| { echo "$(OBJDUMP) not found (install binutils-avr)"; $(SKIP); }; \
	$(fw_image_sh); \
	elves=""; \
	for v in $(XT_VARIANTS_REQUESTED); do \
		elf=$(XT_BUILD_DIR)/`fw_image_of "$$v" $(XT_TAG)`.elf; \
		if [ ! -f "$$elf" ]; then \
			echo "FAIL: expected ATtiny202 image missing: $$elf"; exit 1; \
		fi; \
		elves="$$elves $$elf"; \
	done; \
	OBJDUMP=$(OBJDUMP) python3 test/avr/test_attiny202_delay_oracle.py $$elves

# Aggregate: every ATtiny202 pre-hardware check (fuses + smoke + build/budgets +
# stack + analysis + coil-pulse width oracle). It is not part of `make test` because the
# vendored DFP may be absent; each sub-target skips cleanly for developers, while
# release qualification invokes this aggregate with STRICT_TOOLS=1.
.PHONY: attiny202-test
attiny202-test: test-fuses attiny202-smoke attiny202 attiny202-test-stack-bound attiny202-analyze attiny202-delay-oracle
	@echo "=== all ATtiny202 pre-hardware checks complete ==="

# The yasimavr target-level aggregate, over EVERY variant: functional + physical
# output trace, fault injection, and ctx_-vs-model lock-step. The AVR-XT
# counterpart of the three PIC target-variant aggregates, and what
# release qualification runs (with STRICT_TOOLS=1, which turns each sub-target's
# clean skip into a hard failure -- a release must never accept "the simulator
# was missing" as evidence).
#
# Deliberately excludes the soak: the release drives that separately, one
# combination per output stage at the full release duration, alongside every
# other target's soak.
.PHONY: attiny202-test-target
attiny202-test-target:
	@if [ "$(CLASSIC_VARIANTS_REQUEST_EMPTY)" -eq 1 ]; then \
		echo "FAIL: VARIANTS must not be empty" >&2; exit 2; \
	fi; \
	if [ "$(CLASSIC_VARIANTS_REQUEST_DUPLICATE)" -eq 1 ]; then \
		echo "FAIL: VARIANTS must not contain duplicate names" >&2; exit 2; \
	fi; \
	if [ "$(CLASSIC_VARIANTS_REQUEST_UNKNOWN)" -eq 1 ]; then \
		echo "FAIL: VARIANTS contains unsupported names; supported: $(XT_VARIANTS_SUPPORTED)" >&2; exit 2; \
	fi; \
	if [ "$(if $(filter-out $(VARIANTS),$(XT_VARIANTS_SUPPORTED)),yes,no)" = yes ]; then \
		echo "FAIL: VARIANTS must contain every supported name; required: $(XT_VARIANTS_SUPPORTED)" >&2; exit 2; \
	fi
	@set -e; \
	want=$(words $(XT_VARIANTS_SUPPORTED)); \
	for spec in \
		"attiny202-sim|SIM PASS" \
		"attiny202-fault|FAULT PASS" \
		"attiny202-lockstep|LOCKSTEP PASS"; do \
		target=$${spec%%|*}; marker=$${spec#*|}; log=`mktemp`; \
		if ! $(MAKE) --no-print-directory $$target >"$$log" 2>&1; then \
			cat "$$log"; rm -f "$$log"; exit 1; \
		fi; \
		cat "$$log"; \
		got=`grep -cF "$$marker" "$$log" || true`; \
		if [ "$$got" -ne "$$want" ]; then \
			echo "FAIL: $$target did not report '$$marker' exactly $$want time(s) (got $$got; skipped or incomplete?)"; \
			rm -f "$$log"; exit 1; \
		fi; \
		if [ "$$target" = attiny202-lockstep ]; then \
			scenarios=`grep -cF "co-simulated" "$$log" || true`; expected=$$((want * 2)); \
			if [ "$$scenarios" -ne "$$expected" ]; then \
				echo "FAIL: $$target did not report 'co-simulated' exactly $$expected time(s) (got $$scenarios; boot scenario skipped?)"; \
				rm -f "$$log"; exit 1; \
			fi; \
		fi; \
		rm -f "$$log"; \
	done
	@echo "=== ATtiny202 target sim/fault/lock-step validated for all variants ==="

# ============================================================================
# CLEAN
# ============================================================================

# The classic-AVR lanes are the only ones that build test binaries NEXT TO their
# sources; every other lane writes into a build directory a single `rm -rf`
# covers. Spelled ONCE here because `clean` and `clean-tests` both remove them.
#
# WHY THAT MATTERS. Both targets used to spell the list themselves, and the
# v0.9.8 MCU-field rename moved the rules (`test_sim_<v>` and `test_sim_<v>_t<n>`
# became `test_sim_<v>_attiny13a` / `_attiny<n>`) without either copy following.
# The result was the exact silent severance this release exists to remove: every
# path both targets named had stopped existing, and all nine binaries actually
# built survived `make clean`. Nothing failed, because an `rm -f` of a file that
# is not there is a successful `rm -f`.
#
# These MUST mirror the rule heads in "SIMULATION TESTS" below character for
# character -- `test-clean-contract` checks the list against Make's own target
# inventory rather than against a second copy of the spelling, so a divergence
# in either direction is a failing gate rather than a leftover file.
AVR_SIM_BINARIES = \
	$(foreach v,$(VARIANTS),test/avr/test_trace_$(v) test/avr/test_sim_$(v)_attiny13a) \
	$(foreach v,$(VARIANTS),$(foreach n,$(TINYX5),test/avr/test_sim_$(v)_attiny$(n)))
# Over TINYX5_PARTS, not TINYX5: AVR_SOAK_BIN composes this path from
# $(AVR_SOAK_CHIP), which now holds a full part name, so the list is built from
# the same vocabulary the target is.
AVR_SOAK_BINARIES = \
	$(foreach v,$(VARIANTS),$(foreach p,$(TINYX5_PARTS),test/avr/test_soak_$(v)_$(p)))

# Retired spellings, removed so a worktree carrying pre-v0.9.8 binaries does not
# keep them forever -- the same courtesy `clean` already extends to the
# pre-`src/`-reorganization KLEE paths below. BOTH fields moved, so both are
# enumerated: the output-stage tokens (cd4053/mute/relay, plus the _tmux boards
# dropped in 0.9.4) and the MCU suffix (absent or _t<n>). This is a fixed
# historical list; it grows only when another rename adds to it, which happened
# once more on 2026-08-03: the soak binary's MCU suffix moved from _t<n> to
# _attiny<n> (it had been missed when its sibling test_sim_ binaries moved), so
# the CURRENT variant names now have a retired soak spelling too.
AVR_TEST_BINARIES_RETIRED = $(foreach v,cd4053 mute relay cd4053_tmux mute_tmux, \
	test/avr/test_sim_$(v) test/avr/test_trace_$(v) \
	$(foreach n,$(TINYX5),test/avr/test_sim_$(v)_t$(n) test/avr/test_soak_$(v)_t$(n))) \
	$(foreach v,$(VARIANTS),$(foreach n,$(TINYX5),test/avr/test_soak_$(v)_t$(n)))

# Remove all build outputs and test binaries (keeps coverage/ -- see
# coverage-clean for that).
clean:
	rm -f $(AVR_SIM_BINARIES) $(AVR_SOAK_BINARIES) $(AVR_TEST_BINARIES_RETIRED) \
		test/host/test_logic_host test/pic/test_config_pic test/pic/test_soak_pic \
		test/pic/test_config_pic12f675 test/pic/test_io_pic12f675 \
		test/pic/test_lockstep_pic12f675 test/pic/test_fault_pic12f675 \
		test/pic/test_soak_pic12f675 \
		test/pic/test_fault_pic test/pic/test_lockstep_pic test/pic/test_io_pic \
		test/formal/test_model_check test/formal/test_symbolic test/avr/test_fuses \
		test/formal/test_symbolic.bc test/formal/bypass_pure_klee.bc \
		test/formal/test_symbolic_klee.bc \
		test/stack_*.o test/stack_*.su \
		test/.toolchain.sig $(FW_BASE).plist
	rm -f *.dump *.ctu-info cppcheck-addon-ctu-file-list*
	@# KLEE output: the pinned directory, plus the default-named and pre-`src/`
	@# -reorganization forms so an existing worktree carrying either is cleaned too.
	rm -rf $(KLEE_OUT_DIR) test/formal/klee-out-* test/formal/klee-last \
		test/klee-out-* test/klee-last test/avr/__pycache__
	rm -rf $(AVR_BUILD_DIR) $(PIC10F322_BUILD_DIR) $(XT_BUILD_DIR) $(PIC12F675_BUILD_DIR)
	@# Retired build directory (pre-v0.9.8 spelling of $(PIC10F322_BUILD_DIR)),
	@# for the same reason AVR_TEST_BINARIES_RETIRED exists: without it a
	@# worktree that predates the rename keeps a stale build_pic/ through every
	@# `make clean`, and its XC8 intermediates are not covered by .gitignore's
	@# global patterns.
	rm -rf build_pic
	# PIC10F320: one directory holds every build, coverage and test artifact
	# for this target (merge plan §5.7), so a single rm covers the lot and
	# cannot reach the shared top-level coverage/ the parent lanes own.
	rm -rf $(PIC10F320_BUILD_DIR)

# ============================================================================
# FLASH / FUSES -- hardware (select the image with VARIANT=<name>)
# ============================================================================
# These act on ONE variant image, chosen by VARIANT (default cd4053_simple). The
# per-chip tinyx5 equivalents (attiny85-fuses/-flash/-program, attiny45-...) act
# on the corresponding ATtiny85/ATtiny45 build of the selected variant.

# Read-only: print the chip's currently programmed fuse bytes. Run this FIRST
# to record a chip's existing fuses before changing anything.
attiny13a-readfuses:
	$(AVRDUDE) $(ATTINY13A_AVRDUDE_FLAGS) -U lfuse:r:-:h -U hfuse:r:-:h

# One definition of each hardware action, shared by the single-step goals and
# the ordered transaction below.
ATTINY13A_PROG_HEX = $(AVR_FW)$(call fw_image_tail,$(VARIANT),$(ATTINY13A_MCU)).hex
ATTINY13A_FUSE_WRITE = $(AVRDUDE) $(ATTINY13A_AVRDUDE_FLAGS) \
		-U lfuse:w:$(ATTINY13A_LFUSE):m \
		-U hfuse:w:$(ATTINY13A_HFUSE):m
ATTINY13A_FLASH_WRITE = $(AVRDUDE) $(ATTINY13A_AVRDUDE_FLAGS) -U flash:w:$(ATTINY13A_PROG_HEX):i

# Write the design's fuse bytes. Safe: does not touch RSTDISBL/DWEN, so ISP
# access is preserved. Verify before relying on a board in the field.
attiny13a-fuses:
	$(ATTINY13A_FUSE_WRITE)

# Flash the selected variant's ATtiny13a image to the MCU.
attiny13a-flash: variant-selectors-valid $(ATTINY13A_PROG_HEX)
	$(ATTINY13A_FLASH_WRITE)

# Fresh chip, as ONE ordered transaction: build and validate every ATtiny13a
# variant image (which reports sizes and rejects an invalid HEX), then write the
# fuses, then flash the selected variant. The build is a prerequisite, not a
# step, so nothing reaches silicon if it fails; see AVR_PROGRAM_IMAGE_CHECK.
attiny13a-program: variant-selectors-valid attiny13a
	@hex="$(ATTINY13A_PROG_HEX)"; \
	$(AVR_PROGRAM_IMAGE_CHECK); \
	$(AVR_PROGRAMMER_CHECK); \
	echo "Programming ATtiny13A (variant $(VARIANT)): fuses, then flash $$hex"
	$(ATTINY13A_FUSE_WRITE)
	$(ATTINY13A_FLASH_WRITE)

# Per-tinyx5-chip fuses/flash/program targets: attiny85-fuses/-flash/-program,
# attiny45-fuses/..., ... All share the tinyx5 fuse bytes and differ only in the
# avrdude part. attiny<n>-flash/-program act on the VARIANT-selected image.
# $(call MCU_X5_FLASH_TARGETS,chip-number)
define MCU_X5_FLASH_TARGETS
.PHONY: attiny$(1)-fuses attiny$(1)-flash attiny$(1)-program
ATTINY$(1)_PROG_HEX = $(AVR_FW)$$(call fw_image_tail,$$(VARIANT),$$(mmcu_$(1))).hex
ATTINY$(1)_FUSE_WRITE = $$(AVRDUDE) -c $$(AVR_PROGRAMMER) -p $$(part_$(1)) \
		-U lfuse:w:$$(TINYX5_LFUSE):m \
		-U hfuse:w:$$(TINYX5_HFUSE):m
ATTINY$(1)_FLASH_WRITE = $$(AVRDUDE) -c $$(AVR_PROGRAMMER) -p $$(part_$(1)) -U flash:w:$$(ATTINY$(1)_PROG_HEX):i
attiny$(1)-fuses:
	$$(ATTINY$(1)_FUSE_WRITE)
attiny$(1)-flash: variant-selectors-valid $$(ATTINY$(1)_PROG_HEX)
	$$(ATTINY$(1)_FLASH_WRITE)
attiny$(1)-program: variant-selectors-valid attiny$(1)
	@hex="$$(ATTINY$(1)_PROG_HEX)"; \
	$$(AVR_PROGRAM_IMAGE_CHECK); \
	$$(AVR_PROGRAMMER_CHECK); \
	echo "Programming ATtiny$(1) (variant $$(VARIANT)): fuses, then flash $$$$hex"
	$$(ATTINY$(1)_FUSE_WRITE)
	$$(ATTINY$(1)_FLASH_WRITE)
endef
$(foreach n,$(TINYX5),$(eval $(call MCU_X5_FLASH_TARGETS,$(n))))


# ============================================================================
# TESTS
# ============================================================================

# --- Shared gate inventory ---------------------------------------------------
# `test` and `test-long` run the SAME gates in the SAME order. They differ only
# in workload sizing (HOST_DEFS / SIM_DEFS, set on test-long below) and in
# test-long additionally running test-mutation.
#
# Listing the inventory ONCE is what keeps that true. Two hand-maintained
# prerequisite lines invite a new gate landing in only one aggregate,
# and the aggregate it misses is usually test-long -- the release gate, where
# the omission surfaces as a green run rather than as a failure.
#
# The EARLY/LATE split exists only so test-mutation keeps its position between
# the PIC10F320 host lanes and the simulator lanes; run order affects when a
# failure is reported, not whether it is caught. A new gate may go in either
# half, and lands in both aggregates either way.
#
# The two PIC shipping-source coverage gates that close the EARLY half are here
# on the same grounds pic10f320-test-host-variants is, and the grounds are the
# TOOL CONTRACT, not the part: run_fw_coverage.sh needs a host C compiler, gcov
# and Bash, all of which `test` already requires, and needs neither XC8, the
# DFP, gpsim nor a built HEX (Principle 5, docs/pic10f320_merge_plan.md).
# Reaching them only through pic10f322-test / pic12f675-test -- standalone
# aggregates whose OTHER lanes do need those tools -- is what let a stale host
# fault oracle, a non-shipping compile configuration and a dead coverage anchor
# sit on a branch under a green `make test` (TODO.md history, 2026-08-20).
# Membership is asserted from Make's own prerequisite sets in
# test/test_workload_rebuild.sh, not left to inspection of these two lists.
TEST_GATES_EARLY = \
        python-version-valid host-compiler-valid analyze test-static-assert-guards \
        test-host test-model-check test-symbolic test-cbmc \
        test-fuses test-stack-bound test-stack-bound-regression \
        test-stack-bound-pic-regression test-flash-budget-regression \
        test-fault-inject pic10f320-test-host-variants \
        test-pic10f320-return-stack-oracle test-pic10f320-expected-images \
        test-pic10f320-coverage-archive \
        pic10f322-coverage-check-fw pic12f675-coverage-check-fw
TEST_GATES_LATE = \
        test-sim-attiny13a test-sim-tinyx5 test-attiny202-build \
        test-attiny202-output-oracle test-attiny202-delay-oracle \
        test-attiny202-fault-oracle test-attiny202-model-ffi \
        test-avr-build-rebuild test-avr-program-order \
        test-ci-local-routing test-workflow-syntax \
        test-gpsim-wrappers test-fetch-yasimavr test-supply-chain \
        test-klee-build test-mutation-sandbox test-pic-build \
        test-release-images test-release-preflight test-release-provenance \
        test-release-qualification test-release-history \
        test-pic12f675-flash-helper \
		test-build-serialization test-target-matrix \
		test-target-lane-markers test-pic-target-result-records \
		test-lockstep-progress test-soak-timing \
        test-variant-map-contract test-fault-wdt-note-contract test-makefile-name-contract test-todo-index \
        test-resource-tables \
        test-pinout-alignment test-misra-output-contract \
        test-analyze-variant-guard test-variant-selector-guard \
        test-clean-contract test-fuse-injection-contract \
        test-soak-reset-witness test-strict-tools test-workload-rebuild \
        test-pic-build-rebuild coverage-check coverage-check-core
TEST_GATES = $(TEST_GATES_EARLY) $(TEST_GATES_LATE)
TEST_LONG_GATES = $(TEST_GATES_EARLY) test-mutation $(TEST_GATES_LATE)

# The mandatory host gates use subprocess.run(capture_output=..., text=...),
# both added in Python 3.7. Keep this first in each aggregate so an unsupported
# host gets the actionable contract diagnostic before any Python child gate.
# host-compiler-valid follows it for the same reason, covering the C side.
python-version-valid:
	@if ! command -v python3 >/dev/null 2>&1; then \
		echo "FAIL: Python 3.7 or newer is required by the repository host gates; python3 was not found." >&2; \
		exit 1; \
	fi
	@python3 test/python_version.py

# The C counterpart of python-version-valid, and second in each aggregate for
# the same reason: every host gate that compiles firmware sources natively uses
# -Werror -Wconversion, and GCC 9 and older report a false narrowing there (see
# test/host_compiler_version.sh). Without this the host would instead meet a
# wall of -Werror output from whichever gate happened to run first.
#
# Probed, never assumed: this is NOT a parse-time $(HOSTCC) probe. One of those
# leaks a compiler-not-found error into every make invocation, including
# `make print-%` (see the STRICT_TOOLS notes), so the check lives in a recipe.
.PHONY: host-compiler-valid
host-compiler-valid:
	@HOSTCC="$(HOSTCC)" test/host_compiler_version.sh "$(HOSTCC)"

# Default `make test`: FAST workload. Runs static analysis, the host golden
# model, the exhaustive state-space model check, the symbolic single-step proof,
# the fuse-byte check, the fault-injection sim tests, both simavr firmware
# suites, and enforces a coverage floor on the model. Designed to finish in
# ~1 minute for quick edit/build/test loops and CI.
test: $(TEST_GATES)
	@echo "=== all fast pre-hardware tests passed ==="

# Explicit alias for the fast suite (same as `make test`).
test-fast: test

# FULL exhaustive workload: same targets as `test`, but the fuzz/stress tests
# are rebuilt with their large in-source default durations (FULL_*_DEFS adds no
# overrides). Workload-dependent binaries have a FORCE prerequisite, so this
# does not rely on a racy cleanup phase. Use before tagging a release/HW signoff.
test-long: HOST_DEFS = $(FULL_HOST_DEFS)
test-long: SIM_DEFS  = $(FULL_SIM_DEFS)
test-long: $(TEST_LONG_GATES)
	@echo "=== all FULL (exhaustive) pre-hardware tests passed ==="

# Friendly alias for the exhaustive suite (same as `make test-long`).
stress: test-long

# Remove ONLY the test binaries so the next test run rebuilds them with the
# currently selected workload sizing (FAST vs FULL *_DEFS).
.PHONY: clean-tests
clean-tests:
	rm -f test/host/test_logic_host test/formal/test_model_check test/formal/test_symbolic \
	      test/avr/test_fuses \
	      $(AVR_SIM_BINARIES)
	@# PIC10F320 host test artifacts. Unlike every other target's, these are
	@# written into the chip's build directory rather than next to their sources
	@# (§5.7), so the rm above cannot reach them -- and leaving them behind would
	@# mean the next run silently reuses binaries built with the previous
	@# workload sizing, which is the exact failure this target exists to prevent.
	@# The .hex images are deliberately NOT removed: they are build output, not
	@# test output, and `make clean` owns them.
	@# $(PIC10F320_SOAK_BIN) is named explicitly because it is the ONE binary here
	@# that literally has its workload sizing compiled in (-DSOAK_DURATION_MS /
	@# -DSOAK_LIVENESS_INTERVAL_MS), and the only one reachable through a Make
	@# file rule that will not rebuild on a duration change alone -- so it is the
	@# precise case the paragraph above describes. The target-lane binaries are
	@# listed alongside it for completeness; their recipes recompile
	@# unconditionally, so they are hygiene rather than a staleness hazard.
	rm -rf $(PIC10F320_COVERAGE_DIR)
	rm -f $(PIC10F320_BUILD_DIR)/test_equiv $(PIC10F320_BUILD_DIR)/test_fault \
	      $(PIC10F320_BUILD_DIR)/test_config_pic \
	      $(PIC10F320_SOAK_BIN) $(PIC10F320_FAULT_BIN) $(PIC10F320_IO_BIN) \
	      $(PIC10F320_LOCKSTEP_BIN) \
	      $(foreach v,$(PIC10F320_VARIANTS_ALL),$(PIC10F320_BUILD_DIR)/test_actuation_$(v)) \
	      $(PIC10F320_BUILD_DIR)/*.o

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

# Fake-programmer proof that every AVR *-program goal builds and validates its
# image before the first avrdude invocation, and then writes fuses before flash.
test-avr-program-order:
	./test/test_avr_program_order.sh

# Fake-gpsim proof that complete snapshots cannot hide process failure/timeout.
test-gpsim-wrappers:
	./test/test_gpsim_wrappers.sh

# Offline fake-tool proof that the yasimavr fetcher cannot replace unowned paths
# and installs only a completely built and verified sibling venv.
test-fetch-yasimavr:
	./test/test_fetch_yasimavr.sh

# Corrupted-download/cache fixtures plus workflow/action/credential pin checks.
test-supply-chain:
	./test/test_supply_chain.sh

# Isolated fake-tool proof of fail-closed PIC image generation and PIC10F320
# image/host rebuild triggering. The script enforces the canonical 36/75/156
# counts, so missing PIC10F320 rebuild wiring cannot silently reduce coverage.
test-pic-build:
	./test/test_pic_build.sh
	@# Same fake-XC8 regression against the PIC10F320 contract: its own
	@# build target, build directory, image naming and 256-word budget.
	PB_LABEL='PIC10F320' \
	PB_TARGET='pic10f320' \
	PB_CC_VAR='PIC10F320_CC' \
	PB_BUILD_DIR_VAR='PIC10F320_BUILD_DIR' \
	PB_BUILD_DIR='build_pic10f320' \
	PB_FW_BASE_VAR='FW_BASE' \
	PB_FW_BASE='bypass' \
	PB_TAG_VAR='PIC10F320_TAG' \
	PB_TAG='pic10f320' \
	PB_FLASH_VAR='PIC10F320_FLASH_WORDS' \
	PB_FLASH_WORDS='256' \
	PB_VARIANT_VAR='PIC10F320_VARIANT' \
	PB_VARIANT='cd4053_simple' \
	PB_MATRIX_TARGET='pic10f320-variants' \
	PB_MATRIX_VARIANTS_VAR='PIC10F320_VARIANTS_ALL' \
	PB_MATRIX_VARIANTS='cd4053_simple cd4053_with_mute tq2_l2_5v_relay' \
	PB_MATRIX_IMAGES='bypass-pic10f320-cd4053_simple.hex bypass-pic10f320-cd4053_with_mute.hex bypass-pic10f320-tq2_l2_5v_relay.hex' \
	PB_MATRIX_FAIL_IMAGE='bypass-pic10f320-tq2_l2_5v_relay.hex' \
	PB_MATRIX_REQUIRE_COMPLETE=1 PB_MATRIX_UNSUPPORTED='tmux4053-simple' \
	PB_STACK_TARGET='pic10f320-test-stack-bound' \
	PB_STACK_DEVICE_VAR='PIC10F320_DEVICE_INI' \
	PB_RETURN_STACK_REQUIRED=1 \
	PB_SELECTOR_ROUTING=1 PB_SIZE_TARGET='pic10f320-size' \
	PB_REBUILD_REQUIRED=1 \
		./test/test_pic_build.sh
	@# And again against the PIC12F675 contract. Same modular shape as the
	@# PIC10F322 (one target builds every variant), so the overrides differ only
	@# in the names and the budget -- which is exactly the pair a copy-adapted
	@# lane gets wrong, and exactly what a passing budget gate would hide.
	PB_LABEL='PIC12F675' \
	PB_TARGET='pic12f675' \
	PB_CC_VAR='PIC_CC' \
	PB_BUILD_DIR_VAR='PIC12F675_BUILD_DIR' \
	PB_BUILD_DIR='build_pic12f675' \
	PB_FW_BASE_VAR='FW_BASE' \
	PB_FW_BASE='bypass' \
	PB_TAG_VAR='PIC12F675_TAG' \
	PB_TAG='pic12f675' \
	PB_FLASH_VAR='PIC12F675_FLASH_WORDS' \
	PB_FLASH_WORDS='1024' \
	PB_VARIANT_VAR='VARIANTS' \
	PB_VARIANT='cd4053_simple' \
	PB_MATRIX_TARGET='pic12f675' \
	PB_MATRIX_VARIANTS_VAR='VARIANTS' \
	PB_MATRIX_VARIANTS='cd4053_simple cd4053_with_mute tq2_l2_5v_relay' \
	PB_MATRIX_IMAGES='bypass-pic12f675-cd4053_simple.hex bypass-pic12f675-cd4053_with_mute.hex bypass-pic12f675-tq2_l2_5v_relay.hex' \
	PB_MATRIX_FAIL_IMAGE='bypass-pic12f675-tq2_l2_5v_relay.hex' \
	PB_MATRIX_REQUIRE_COMPLETE=1 PB_MATRIX_UNSUPPORTED='unknown' \
	PB_STACK_TARGET='pic12f675-test-stack-bound' \
	PB_STACK_DEVICE_VAR='PIC12F675_DEVICE_INI' \
		./test/test_pic_build.sh

# Exact-set and hash checks for the tag workflow's committed/listed/fresh images.
test-release-images:
	./test/test_release_images.sh

# Fake-tool proof that release step 0 reaches its end without cleaning, building
# or staging, and validates the actual caller-selected tool paths.
test-release-preflight:
	./test/test_release_preflight.sh

# Stateful fake-programmer proof that the release-shipped PIC12F675 flashing
# helper reaches a device write only through its full guarded transaction, and
# publishes a FAIL rather than a PASS for every way a writer can destroy this
# part's factory trim.
test-pic12f675-flash-helper: python-version-valid
	./test/test_pic12f675_flash_helper.sh

# Isolated proof of final source identity and per-PIC compiler attribution.
test-release-provenance:
	./test/test_release_provenance.sh

# Host-only proof that publication requires exact clean qualification metadata,
# the canonical retained-evidence set, and one complete result per release soak.
test-release-qualification:
	./test/test_release_qualification.sh

# Scratch-Git proof that a tag publishes only an artifact commit whose sole
# parent is the exact source commit recorded by the 24-hour qualification.
test-release-history:
	./test/test_release_history.sh

# Internal probes used only by test/test_make_serialization.sh.
SERIAL_PROBE_DIR ?= $(AVR_BUILD_DIR)

# Independent top-level Make processes must never enter this critical section
# concurrently when they share one worktree.
test-make-lock-probe:
	@mkdir -p "$(SERIAL_PROBE_DIR)"; \
	active="$(SERIAL_PROBE_DIR)/.make-lock-probe-active"; \
	if ! mkdir "$$active" 2>/dev/null; then \
		echo "FAIL: concurrent Make recipes overlapped" >&2; exit 1; \
	fi; \
	cleanup_probe() { rmdir "$$active" 2>/dev/null || true; }; \
	trap cleanup_probe 0 1 2 15; \
	printf 'start %s\n' "$(PROBE_ID)" >> "$(PROBE_LOG)"; \
	sleep 0.5; \
	printf 'end %s\n' "$(PROBE_ID)" >> "$(PROBE_LOG)"

# The outer graph is serial, but explicitly reviewed recursive fan-out with
# isolated artifacts remains available. These two prerequisites must overlap.
test-make-safe-parallel-probe:
	@mkdir -p "$(SERIAL_PROBE_DIR)"; \
	cleanup_parallel() { rm -f "$(SERIAL_PROBE_DIR)/parallel-a" \
		"$(SERIAL_PROBE_DIR)/parallel-b"; }; \
	cleanup_parallel; trap cleanup_parallel 0 1 2 15; \
	$(MAKE) --no-print-directory -j2 _test-make-safe-parallel-probe-run \
		SERIAL_PROBE_DIR="$(SERIAL_PROBE_DIR)"

_test-make-safe-parallel-probe-run: \
		_test-make-safe-parallel-probe-a _test-make-safe-parallel-probe-b

_test-make-safe-parallel-probe-a:
	@mkdir -p "$(SERIAL_PROBE_DIR)"; \
	marker="$(SERIAL_PROBE_DIR)/parallel-a"; \
	other="$(SERIAL_PROBE_DIR)/parallel-b"; \
	: > "$$marker"; \
	i=0; while [ ! -e "$$other" ] && [ $$i -lt 500 ]; do \
		i=$$((i + 1)); sleep 0.01; \
	done; \
	[ -e "$$other" ] || { echo "FAIL: reviewed recursive fan-out was serialized" >&2; exit 1; }

_test-make-safe-parallel-probe-b:
	@mkdir -p "$(SERIAL_PROBE_DIR)"; \
	marker="$(SERIAL_PROBE_DIR)/parallel-b"; \
	other="$(SERIAL_PROBE_DIR)/parallel-a"; \
	: > "$$marker"; \
	i=0; while [ ! -e "$$other" ] && [ $$i -lt 500 ]; do \
		i=$$((i + 1)); sleep 0.01; \
	done; \
	[ -e "$$other" ] || { echo "FAIL: reviewed recursive fan-out was serialized" >&2; exit 1; }

test-build-serialization:
	./test/test_make_serialization.sh

# Host-only proof that ci-local skip options route strict/partial suites correctly.
test-ci-local-routing:
	./test/test_ci_local_routing.sh

# Host-only proof that every per-variant map is registered with the parse-time
# require_variant_map guard. The guard catches a registered map whose keys go
# stale; this catches a map that was never registered, which is the half that
# let pic_soak_block_* sever silently through the whole v0.9.8 rename.
# Host-only source contract for the per-part gpsim watchdog note the
# libgpsim fault harness prints into retained evidence: each adapter must
# supply its own PIC_FAULT_WDT_NOTE and the core must consume it, so the
# PIC12F675 lane no longer reports the PIC10F32x period. Reads source only.
test-fault-wdt-note-contract:
	./test/test_fault_wdt_note_contract.sh

test-variant-map-contract:
	./test/test_variant_map_contract.sh

# Host-only proof that the names other files and documents exchange with this
# Makefile are names it actually knows. All five axes of the name-contract item:
# a variable READ (print-VAR), a goal named to a READER (make <goal>), a
# variable SET (VAR=value), a variable named to a reader, and the ENVIRONMENT a
# recipe hands a child (NAME=value ./child.sh). Make is silent about four of the
# five -- an override naming nothing is legal, `print-%` matches ANY name and
# returns an empty line, an assignment to an unknown variable is simply ignored,
# and a child that stopped reading a name just uses its own default -- so a
# rename severs the link with every gate still green. The fifth is loud, but
# only for the reader who types the dead goal, which is exactly who should not
# be the one to find it.
#
# name-contract: exempt (names the retired spellings to describe the defect)
# In v0.9.8 this class cost a 43,200x soak overrun on a renamed SOAK_* override,
# three make-release reads left pointed at MCU/LFUSE_X5/HFUSE_X5, 15 dead goals
# in a live qualification document, ten stale variable surfaces, and -- the one
# that reached a result rather than a document -- a PIC10F320 lane simulating a
# PIC10F322 for a whole release, on a PIC_GPSIM_PROC= nothing read any more.
test-makefile-name-contract: python-version-valid
	@python3 test/test_makefile_name_contract.py

# TODO.md states its own index invariant -- "the stable ID in each row matches
# exactly one open section above" -- and nothing checked it, so it drifted: the
# 2026-08-10 MISRA-review commit added a section with no summary row. Same
# family as the name contract above: a document that claims a correspondence
# should have that correspondence enforced rather than reviewed.
# The checker is named as a PREREQUISITE, not just inside the recipe: the
# clean-contract oracle is `make -rRn --print-data-base`, which sees only files
# that are targets or prerequisites, so a helper mentioned in recipe text alone
# can stay untracked forever.
.PHONY: test-todo-index
test-todo-index: python-version-valid test/test_todo_index.py TODO.md
	@python3 test/test_todo_index.py

# Every current resource figure -- four utilization tables, the sentences derived
# from them, and the same numbers restated in three other documents -- is checked
# against the images that produced it. Same family as the two contracts above,
# and it drifted the same way: at the v0.9.10 candidate the AVR Classic table
# still held the pre-F1 ATtiny13a images, the ATtiny202 and PIC12F675 tables were
# several changes behind, the ATtiny45/85 rows were missing outright, and the two
# derived sentences had been computed from the stale numbers. A reader decides
# whether a change fits from exactly these figures.
#
# It needs no AVR or PIC toolchain: program size is read out of the ELF section
# headers and the Intel HEX directly (see the module docstring), so the gate
# measures whatever this tree has already built and says how many of the 21
# images that was. `make test` runs on a runner with neither XC8 nor the
# ATtiny_DFP, so demanding all 21 would fail exactly where the AVR-only evidence
# is still worth having.
.PHONY: test-resource-tables
test-resource-tables: python-version-valid test/test_resource_tables.py \
		DESIGN_DOCUMENTATION.adoc docs/context_seu_detection.md \
		docs/pic12f675_feasibility.md CHANGELOG.md
	@python3 test/test_resource_tables.py

# The package pinout diagrams are transcribed from each device pack's own pinout
# data and are what somebody wires a board from, so a whitespace defect in one is
# a documentation defect in the thing most likely to be trusted on sight. The
# PIC12F675 diagram shipped with one extra leading space on its V_DD row, putting
# that row's walls one column right of the corners and every other row; it
# rendered visibly stepped and survived review, because that is the class of
# defect a reader's eye completes for them.
# Same prerequisite discipline as the gate above -- the checker is named, not
# just invoked -- and the same vacuity discipline inside it: the scan asserts a
# floor on the number of diagrams it found, and six synthetic probes (one of them
# the real historical defect) run on every invocation, so a checker that has
# stopped recognizing anything fails instead of passing quietly.
.PHONY: test-pinout-alignment
test-pinout-alignment: python-version-valid test/test_pinout_alignment.py
	@python3 test/test_pinout_alignment.py

# Host-only proof that every static-analysis target validates its variant
# request before analyzing anything. $(FW_SOURCES) maps $(VARIANTS) through
# src_<variant> and an unrecognized name maps to NOTHING, so a mistyped or
# retired variant does not fail the analyzers -- it shrinks their subject and
# they report the smaller set clean. v0.9.8 shipped a MISRA_COMPLIANCE.md whose
# documented compliance command named the pre-rename stage vocabulary: it
# analyzed zero of the three output drivers and exited 0.
test-analyze-variant-guard:
	./test/test_analyze_variant_guard.sh

# cppcheck 2.13.0 prints included-header MISRA findings without applying
# --error-exitcode. Exercise the repository parser directly, census all five
# gating recipes, and drive each recipe with a fake zero-exit Required-rule
# diagnostic to prove an exact per-file suppression is the only clean path.
test-misra-output-contract: test/misra_output_gate.py test/test_misra_output_contract.sh
	./test/test_misra_output_contract.sh

# The single-variant counterpart of the gate above. VARIANTS is a list and has
# been guarded for releases; the variables that select ONE output stage for one
# lane (PIC10F322_SOAK_VARIANT, PIC10F320_IO_VARIANT, AVR_SOAK_VARIANT, ...)
# were not, and an unrecognized value there composes a path to a file nothing
# builds -- which the lane reports as a MISSING TOOLCHAIN and skips, exit 0.
# Checks that the guard rejects all three malformed shapes and that it is still
# attached to every rule consuming a selector, transitively: almost none name a
# selector directly, they read a HEX path composed from one three definitions
# away.
test-variant-selector-guard: python-version-valid
	./test/test_variant_selector_guard.py

# `rm -f` of a path that does not exist SUCCEEDS, so a `clean` list that has
# drifted from the rules producing the files is completely silent -- which is
# what the v0.9.8 rename left behind: both clean and clean-tests named
# `test_sim_<v>` / `test_sim_<v>_t<n>` while the rules had moved to
# `test_sim_<v>_attiny<n>`, so every path they named was gone and all nine
# binaries actually built survived. Checks both targets against Make's own
# inventory of what it can build.
test-clean-contract:
	./test/test_clean_contract.sh

# `-D<MACRO>=$(VAR)` is a name contract the four Makefile name-contract axes
# deliberately do not cover: the C macro names are the tests' own interface and
# were not renamed with the Make variables. So a macro renamed on either side
# severed in silence for as long as the C file carried a default -- and
# test/avr/test_fuses.c carried one for all eleven fuse bytes, ten of them equal
# to the current values. The real compile line minus -DT85_LFUSE printed
# "46 checks, 0 failures" and exited 0. The defaults are now `#error`s; this
# keeps them gone and follows each byte the whole way: burned == injected ==
# guarded == printed, and every printed byte equal to print-<VAR>.
test-fuse-injection-contract: python-version-valid
	./test/test_fuse_injection_contract.py

# Prove the firmware's compile-time guards actually FIRE. Every build checks
# them, but only in the sense that they stay silent -- and a guard still
# enforcing its invariant is indistinguishable from one that has been defused,
# because both are silent and both build green. This breaks one INPUT to each
# guard (a threshold, a pin ordinal, the timer constant, -fshort-enums) in a
# throwaway copy of src/ and requires the build to fail with that guard's own
# message, plus a census so a guard whose siblings share its diagnostic cannot
# be deleted unnoticed. The firmware itself is never modified.
test-static-assert-guards:
	@if ! command -v $(CC) >/dev/null 2>&1; then \
		echo "$(CC) not installed; skipping the static_assert guard checks"; $(SKIP); \
	fi; \
	./test/test_static_assert_guards.sh

# Parse the GitHub workflow files and cross-check ci.yml's job list against
# ci-local.sh. Nothing else here loads them as YAML, so an unparseable workflow
# -- which stops the entire CI matrix before a single job starts -- would
# otherwise pass every local gate.
test-workflow-syntax:
	./test/test_workflow_syntax.sh

# Fake-tool proof that KLEE receives linked harness + shipping pure-core bitcode.
test-klee-build:
	./test/test_klee_build.sh

_test-mutation-policy-probe:
	@bash -c '. ./test/mutation_policy.sh; resolve_mutation_allow_skip'

# Host-only proof of mutation sandbox completeness and fail-closed inventory,
# command, worker/result, and conservation accounting.
test-mutation-sandbox:
	MUTATION_SANDBOX_SELFTEST=1 ./test/run_mutation_tests.sh

# Host-only proof that authoritative target aggregates reject bad matrices and
# skipped/incomplete target-level lanes.
test-target-matrix:
	./test/test_target_matrix.sh
	@# Same parameterized regression, PIC10F320 contract; the next invocation
	@# adds PIC12F675, so one script covers all three PIC targets (§4 FOLD).
	TM_LABEL='PIC10F320' \
	TM_TARGET='pic10f320-test-target-variants' \
	TM_PER_VARIANT_TARGET='pic10f320-test-target' \
	TM_VARIANTS_VAR='PIC10F320_VARIANTS_ALL' \
	TM_VARIANT_ARG='PIC10F320_TARGET_VARIANT' \
	TM_SUPPORTED='cd4053_simple cd4053_with_mute tq2_l2_5v_relay' \
	TM_SUBSET='cd4053_with_mute' \
	TM_UNSUPPORTED='tmux4053-simple' \
	TM_FAULT_TARGET='pic10f320-test-fault-target' \
	TM_FAULT_VARIANT_ARG='PIC10F320_FAULT_VARIANT' \
	TM_LOCKSTEP_TARGET='pic10f320-test-lockstep' \
	TM_LOCKSTEP_VARIANT_ARG='PIC10F320_LOCKSTEP_VARIANT' \
	TM_IO_TARGET='pic10f320-test-io' \
	TM_IO_VARIANT_ARG='PIC10F320_IO_VARIANT' \
		./test/test_target_matrix.sh
	@# Same regression again, PIC12F675 contract. Its lanes take the CLASSIC
	@# variant set and its aggregate builds the whole image matrix, so this mode
	@# is the 322's with the names swapped -- which is the point: a third part
	@# reusing the script is what keeps the aggregates from drifting apart.
	TM_LABEL='PIC12F675' \
	TM_TARGET='pic12f675-test-target-variants' \
	TM_PER_VARIANT_TARGET='pic12f675-test-target' \
	TM_VARIANTS_VAR='VARIANTS' \
	TM_VARIANT_ARG='PIC12F675_TARGET_VARIANT' \
	TM_SUPPORTED='cd4053_simple cd4053_with_mute tq2_l2_5v_relay' \
	TM_SUBSET='cd4053_with_mute' \
	TM_UNSUPPORTED='tmux4053-simple' \
	TM_FAULT_TARGET='pic12f675-test-fault' \
	TM_FAULT_VARIANT_ARG='PIC12F675_FAULT_VARIANT' \
	TM_EXACT_FAULT_CHECKS='38' \
	TM_LOCKSTEP_TARGET='pic12f675-test-lockstep' \
	TM_LOCKSTEP_VARIANT_ARG='PIC12F675_LOCKSTEP_VARIANT' \
	TM_IO_TARGET='pic12f675-test-io' \
	TM_IO_VARIANT_ARG='PIC12F675_IO_VARIANT' \
		./test/test_target_matrix.sh
	@# ...and the PIC10F320 HOST aggregate, which carries the same guard and is
	@# what `make test` actually wires in -- so a bad matrix there would silently
	@# reduce the default suite's PIC10F320 coverage rather than fail it. Guarding
	@# this one also guards `pic10f320-test`, which reaches its own loop only after
	@# this target has succeeded as a prerequisite.
	TM_LABEL='PIC10F320 host' \
	TM_TARGET='pic10f320-test-host-variants' \
	TM_PER_VARIANT_TARGET='pic10f320-test-host' \
	TM_VARIANTS_VAR='PIC10F320_VARIANTS_ALL' \
	TM_VARIANT_ARG='PIC10F320_VARIANT' \
	TM_SUPPORTED='cd4053_simple cd4053_with_mute tq2_l2_5v_relay' \
	TM_SUBSET='cd4053_with_mute' \
	TM_UNSUPPORTED='tmux4053-simple' \
	TM_CHECK_SENTINELS=0 \
		./test/test_target_matrix.sh
	@# AVR-XT's three aggregate lanes each run the complete matrix themselves,
	@# so this mode checks one recursive call per lane and exact per-variant PASS
	@# counts (plus both lock-step boot scenarios) rather than a per-variant wrapper.
	TM_LABEL='ATtiny202' \
	TM_TARGET='attiny202-test-target' \
	TM_VARIANTS_VAR='VARIANTS' \
	TM_SUPPORTED='cd4053_simple cd4053_with_mute tq2_l2_5v_relay' \
	TM_SUBSET='cd4053_with_mute' \
	TM_UNSUPPORTED='unknown' \
	TM_FAULT_TARGET='attiny202-sim' \
	TM_LOCKSTEP_TARGET='attiny202-fault' \
	TM_IO_TARGET='attiny202-lockstep' \
	TM_FAULT_MARKER='SIM PASS' \
	TM_LOCKSTEP_MARKER='FAULT PASS' \
	TM_IO_MARKER='LOCKSTEP PASS' \
	TM_FAULT_MARKER_COUNT=3 \
	TM_LOCKSTEP_MARKER_COUNT=3 \
	TM_IO_MARKER_COUNT=3 \
	TM_IO_EXTRA_MARKER='co-simulated' \
	TM_IO_EXTRA_MARKER_COUNT=6 \
	TM_AGGREGATE_LANES=1 \
		./test/test_target_matrix.sh

# Host-only proof that the PIC target aggregates are fail-CLOSED, which the
# matrix regression above does NOT cover: it proves the right variants are
# invoked, not that a lane which skipped is rejected. Both properties are needed,
# because every lane exits 0 through $(SKIP) when its tool is absent -- so an
# aggregate reading only exit status reports a full green sweep having run
# nothing. pic10f320-test-target shipped in exactly that shape; see the script
# header. Three PIC targets, one script (§4 FOLD).
test-target-lane-markers:
	./test/test_target_lane_markers.sh
	@# The PIC10F320 contract. LM_REQUIRE_ARG pins the second half of that fix:
	@# its lanes' build prerequisite `pic10f320` compiles ONE image chosen by
	@# PIC10F320_VARIANT, so an aggregate that forwards only PIC10F320_TARGET_VARIANT
	@# builds one variant and then looks for another's HEX.
	LM_LABEL='PIC10F320' \
	LM_TARGET='pic10f320-test-target' \
	LM_VARIANT_ARG='PIC10F320_TARGET_VARIANT' \
	LM_VARIANT='cd4053_with_mute' \
	LM_REQUIRE_ARG='PIC10F320_VARIANT=cd4053_with_mute' \
		./test/test_target_lane_markers.sh
	@# The PIC12F675 contract. No LM_REQUIRE_ARG: its lanes share one build
	@# prerequisite (pic12f675-simcal) that derives every variant's image, so
	@# there is no second variable to thread and nothing for it to pin.
	@for variant in cd4053_simple cd4053_with_mute tq2_l2_5v_relay; do \
		LM_LABEL='PIC12F675' \
		LM_TARGET='pic12f675-test-target' \
		LM_VARIANT_ARG='PIC12F675_TARGET_VARIANT' \
		LM_VARIANT="$$variant" \
			./test/test_target_lane_markers.sh || exit; \
	done

test-pic-target-result-records:
	PIC_SOAK_CXX="$(PIC_SOAK_CXX)" ./test/test_pic_target_result_records.sh

# Compile all three real PIC lock-step and soak drivers against a fake core;
# exercise exact pin resolution and inject bounded progress stalls. A soak wedge
# must stop immediately with actual elapsed evidence rather than claim duration.
test-lockstep-progress:
	PIC_SOAK_CXX="$(PIC_SOAK_CXX)" ./test/test_lockstep_progress.sh

# Fast host-only boundary checks for every soak timing input path: the shared
# C/C++ compile-time contract, ATtiny202 environment parser, and release CLI.
test-soak-timing:
	HOSTCC="$(HOSTCC)" HOSTCXX="$(PIC_SOAK_CXX)" ./test/test_soak_timing.sh

# Host-only proof that required CBMC/cppcheck gates follow STRICT_TOOLS.
test-strict-tools:
	./test/test_strict_tools.sh

# Isolated fake-compiler proof of workload and fuse-configuration rebuilds.
test-workload-rebuild:
	./test/test_workload_rebuild.sh

# The PIC counterpart: all three chips' soak binaries compile their workload sizing in
# as -D flags, so their file rules must be unconditionally out of date. Fake
# compiler, so it needs no gpsim/glib and runs in `make test`.
test-pic-build-rebuild:
	./test/test_pic_rebuild.sh

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
# the invariant-valid domain, including unreachable-but-valid states (the
# inductive step behind the whole-program invariants). CBMC separately covers
# corrupt program-state fault handling and released-input recovery of an
# out-of-range counter.
# Default build enumerates exhaustively; if KLEE is installed, `make
# test-symbolic-klee` runs the same assertions under symbolic execution.
test-symbolic: test/formal/test_symbolic
	./test/formal/test_symbolic

# Build rule for the symbolic step checker. Links bypass_pure.c so step()
# exercises the real firmware functions (see model_step.h / PURE_HOST_SRC).
test/formal/test_symbolic: test/formal/test_symbolic.c test/model_step.h test/bypass_config_host.h src/bypass_config.h $(PURE_HOST_DEP)
	$(HOSTCC) $(HOST_CFLAGS) $(SANITIZE) $(PURE_HOST_CFLAGS) -Itest $< $(PURE_HOST_SRC) -o $@

# Optional: run the SAME single-step properties under KLEE symbolic execution
# (only if KLEE and a matching clang/llvm-link are installed). KLEE explores the
# symbolic input domain and proves the assertions with an SMT solver rather than
# by enumeration. Compile the harness and shipping pure core separately, then
# link both modules so step() cannot resolve to undefined external functions.
.PHONY: test-symbolic-klee
# Absolute paths to the brew-installed KLEE and its matching LLVM clang. Using
# absolute defaults so the target works even when `make`'s recipe shell does not
# have brew's shellenv on PATH (an interactive shell may, /bin/sh may not).
# Using llvm@16's clang (KLEE's own LLVM) to emit the bitcode avoids the
# host/module target-triple mismatch warning seen with /usr/bin/clang.
KLEE          ?= /home/linuxbrew/.linuxbrew/bin/klee
KLEE_CLANG    ?= /home/linuxbrew/.linuxbrew/opt/llvm@16/bin/clang
KLEE_LLVMLINK ?= /home/linuxbrew/.linuxbrew/opt/llvm@16/bin/llvm-link
KLEE_INC      ?= /home/linuxbrew/.linuxbrew/Cellar/klee/3.2_3/include
# The solver runs from test/, so it gets the path relative to there; every
# cleanup site gets the repo-relative one. Defined once so they cannot disagree.
KLEE_OUT_SUBDIR := formal/klee-out
KLEE_OUT_DIR    := test/$(KLEE_OUT_SUBDIR)
test-symbolic-klee:
	@# --output-dir is PINNED rather than left to KLEE's default, and that is the
	@# point of it. KLEE derives its default klee-out-N from the directory of the
	@# INPUT BITCODE, not from the working directory -- so the output landed in
	@# test/formal/ while this scrub and `make clean` both named test/, and real
	@# runs accumulated untouched. (The bug hid because test/test_klee_build.sh's
	@# fake klee wrote to its cwd, modelling the guess instead of the tool.) With
	@# the directory pinned, the path this removes is the path KLEE writes, by
	@# construction; test_klee_build.sh asserts the flag is passed so the two
	@# cannot drift apart again.
	@rm -f test/formal/test_symbolic.bc test/formal/bypass_pure_klee.bc \
		test/formal/test_symbolic_klee.bc && \
	rm -rf $(KLEE_OUT_DIR) test/formal/klee-out-* test/formal/klee-last \
		test/klee-out-* test/klee-last && \
	if command -v $(KLEE) >/dev/null 2>&1 && command -v $(KLEE_CLANG) >/dev/null 2>&1 \
			&& command -v $(KLEE_LLVMLINK) >/dev/null 2>&1; then \
		klee_cmd=`command -v $(KLEE)`; repo_root=`pwd -P`; \
		case "$$klee_cmd" in /*) ;; *) klee_cmd="$$repo_root/$$klee_cmd" ;; esac; \
		$(KLEE_CLANG) -DUSE_KLEE -I$(KLEE_INC) -I$(SIMAVR_INC) -Itest -emit-llvm -c -g -O0 \
			$(PURE_HOST_CFLAGS) test/formal/test_symbolic.c \
			-o test/formal/test_symbolic.bc && \
		$(KLEE_CLANG) -DUSE_KLEE -I$(KLEE_INC) -I$(SIMAVR_INC) -Itest -emit-llvm -c -g -O0 \
			$(PURE_HOST_CFLAGS) $(PURE_HOST_SRC) \
			-o test/formal/bypass_pure_klee.bc && \
		$(KLEE_LLVMLINK) test/formal/test_symbolic.bc test/formal/bypass_pure_klee.bc \
			-o test/formal/test_symbolic_klee.bc && \
		cd test && "$$klee_cmd" --exit-on-error \
			--output-dir=$(KLEE_OUT_SUBDIR) formal/test_symbolic_klee.bc; \
	else \
		echo "KLEE (or its matching clang/llvm-link) not installed; the exhaustive"; \
		echo "'test-symbolic' target covers the same valid domain. Install klee +"; \
		echo "a matching llvm to enable SMT-backed symbolic execution."; \
	fi

# Optional: CBMC bounded-model-checking of the REAL pure core (bypass_pure.c).
# A third, independent SAT/SMT proof of the valid-domain safety/liveness
# invariants, plus corrupt program-state handling, integrator contraction and
# released-input recovery for out-of-range counters, and automatic instrumentation
# for integer overflow, conversions, bounds, and other undefined behaviour. See
# test/formal/test_cbmc.c. The exhaustive host
# proofs remain useful when CBMC is absent, but do not replace those extra CBMC
# obligations.
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
# assertion proves the bound is real, not assumed).
CBMC_PROOFS      = prove_integrate prove_debounce_step prove_corrupt_state_faults \
                   prove_init_context prove_step_transition prove_oor_recovery_step \
                   prove_ctx_check_single_bit_detected prove_ctx_check_definition
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
		echo "targets still cover valid-domain transitions and liveness. Install cbmc"; \
		echo "to add program-state corruption, released-input counter recovery, and UB proofs."; $(SKIP); \
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

# Host-only regression for the ATtiny202 transition/pulse-presence oracle. It
# stubs the unavailable yasimavr module and exercises positive and fail-closed
# structural trace paths; full-tool CI runs the real built image.
test-attiny202-output-oracle:
	PYTHONPATH=test/avr python3 test/avr/test_attiny202_output_oracle.py

# Host-only regression for the coil-pulse WIDTH oracle's parser + width logic.
# Needs no ELF/DFP (it drives synthetic disassembly), so it guards the width
# checker in `make test` even where the real images cannot be built; the
# attiny202-delay-oracle target runs the same code against the real images.
test-attiny202-delay-oracle:
	python3 test/avr/test_attiny202_delay_oracle.py --selftest

# Host-only accounting regression for the ATtiny202 fault driver. The actual
# corruption/recovery behavior remains covered by the built-image yasimavr job.
test-attiny202-fault-oracle:
	PYTHONPATH=test/avr python3 test/avr/test_attiny202_fault_oracle.py

# Host regression for the golden-model ctypes bridge the ATtiny202 lock-step
# driver reaches the shipping debounce core through. `attiny202-lockstep` needs
# the DFP and the yasimavr venv and skips cleanly without them, so without this
# the bridge would be uncovered on a host that lacks those tools. Needs only
# HOSTCC, hence a hard gate here.
#
# Its checks are deliberately INDEPENDENT hard-coded expectations (threshold
# values re-read from src/bypass_config.h, the >= press-threshold boundary,
# saturation bounds, lock-out and round-trip behaviour) rather than another
# comparison against the model -- lock-step mutates model and firmware together,
# so only an independent oracle can break that symmetry.
test-attiny202-model-ffi: $(XT_LOCKSTEP_FFI_LIB)
	PYTHONPATH=test/avr BYPASS_MODEL_FFI=$(XT_LOCKSTEP_FFI_LIB) \
		python3 test/avr/test_model_ffi.py

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
			-DT13_LFUSE=$(ATTINY13A_LFUSE) -DT13_HFUSE=$(ATTINY13A_HFUSE) \
			-DT85_LFUSE=$(TINYX5_LFUSE) -DT85_HFUSE=$(TINYX5_HFUSE) \
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
# exceeds AVR_STACK_MAX_FRAME bytes.  Complements the runtime HWM test (test-sim-attiny13a)
# with a compile-time structural upper bound that does not depend on exercising
# the deepest call path. Override `AVR_STACK_MAX_FRAME` only with a reviewed
# ceiling; the target generates fresh `.su` reports and validates every frame.
test-stack-bound:
	@if [ ! -f test/check_stack_usage.sh ] || [ -L test/check_stack_usage.sh ] \
			|| [ ! -x test/check_stack_usage.sh ]; then \
		echo "FAIL: canonical stack-usage checker is missing, symlinked, or not executable"; exit 1; \
	fi
	@stack_dir="$(AVR_STACK_BUILD_DIR)"; remove_dir=0; \
	if [ -z "$$stack_dir" ]; then \
		stack_dir=$$(mktemp -d "$${TMPDIR:-$(HOME)}/mcu-stack-bound.XXXXXX") \
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
	if ! awk -v max="$(AVR_STACK_MAX_FRAME)" 'BEGIN {exit !(max ~ /^[0-9]+$$/ && max ~ /[1-9]/)}'; then \
		echo "FAIL: AVR_STACK_MAX_FRAME must be a positive decimal integer"; exit 2; \
	fi; \
	echo "=== -fstack-usage static bound (limit: $(AVR_STACK_MAX_FRAME) B/frame) ==="; \
	expected=0; \
	for f in $(AVR_STACK_SOURCES); do \
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
	if ! test/check_stack_usage.sh "$(AVR_STACK_MAX_FRAME)" "$$@"; then exit 1; fi; \
	echo "OK: $$actual_su fresh reports; all frames <= $(AVR_STACK_MAX_FRAME) B"

# Fake-compiler regression checks for stale, missing, and malformed .su evidence.
test-stack-bound-regression:
	./test/test_stack_bound.sh

# Flash-utilization budget assertion: run avr-size on every ATtiny13a variant
# ELF and fail if flash (Program bytes) exceeds ATTINY13A_FLASH_BUDGET% of 1024 B.
# Firmware is at 81.4/85.4/84.4% today for simple/mute/relay, inside the 90%
# default ceiling by 4.6 points at the tightest image. The target prints the
# measured per-variant percentages, so this figure can be re-checked by running
# it. A future accidental bloat would otherwise pass silently.
# Override: make test-flash-budget ATTINY13A_FLASH_BUDGET=80
test-flash-budget:
	@if [ "$(ATTINY13A_MCU)" != "$(ATTINY13A_FLASH_MCU)" ] || [ "$(FW_BASE)" != "bypass" ] \
			|| [ "$(AVR_FW)" != "$(AVR_BUILD_DIR)/bypass" ]; then \
		echo "FAIL: test-flash-budget requires ATTINY13A_MCU=attiny13a, FW_BASE=bypass, and the canonical AVR_FW"; \
		exit 2; \
	fi; \
	if [ "$(words $(strip $(VARIANTS)))" -ne 3 ] \
			|| [ "$(words $(sort $(VARIANTS)))" -ne 3 ] \
			|| [ "$(words $(ATTINY13A_FLASH_UNKNOWN))" -ne 0 ]; then \
		echo "FAIL: test-flash-budget requires the complete $(CLASSIC_VARIANTS_SUPPORTED) variant matrix"; \
		exit 2; \
	fi
	@$(MAKE) --no-print-directory _test-flash-budget-measure

.PHONY: _test-flash-budget-measure
_test-flash-budget-measure: $(ATTINY13A_FLASH_ELFS)
	./test/check_flash_budget.sh "$(SIZE)" "$(ATTINY13A_FLASH_MCU)" "$(ATTINY13A_FLASH_BYTES)" \
		"$(ATTINY13A_FLASH_BUDGET)" 3 \
		$(ATTINY13A_FLASH_ELFS)

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
#   test/avr/test_sim_<v>_attiny13a   ATtiny13a -> test-sim-<v>-attiny13a
#   test/avr/test_sim_<v>_attiny<n>   tinyx5    -> test-sim-<v>-attiny<n>
#   test/avr/test_trace_<v>           VCD waveform builder (-DTRACE, ATtiny13a)
SIM_DEPS = test/avr/test_sim.c test/model_step.h test/bypass_config_host.h \
           test/bypass_output_host.h src/bypass_config.h $(FW_HEADERS) $(PURE_HOST_DEP)

# $(call VARIANT_SIM_T13,variant)
define VARIANT_SIM_T13
test/avr/test_sim_$(1)_attiny13a: $$(SIM_DEPS) $(AVR_FW)$(call fw_image_tail,$(1),$(ATTINY13A_MCU)).elf FORCE
	$$(HOSTCC) $$(SIM_CFLAGS) $$(SIM_DEFS) $$(PURE_HOST_CFLAGS) -D$$(macro_$(1)) -Itest \
		-DFW_PATH=\"$(AVR_FW)$(call fw_image_tail,$(1),$(ATTINY13A_MCU)).elf\" \
		-DMCU_NAME=\"$(ATTINY13A_MCU)\" \
		-DF_CPU_HZ=$(ATTINY13A_F_CPU) \
		test/avr/test_sim.c $$(PURE_HOST_SRC) -o $$@ $$(SIM_LIBS)

test/avr/test_trace_$(1): $$(SIM_DEPS) $(AVR_FW)$(call fw_image_tail,$(1),$(ATTINY13A_MCU)).elf FORCE
	$$(HOSTCC) $$(SIM_CFLAGS) $$(SIM_DEFS) $$(PURE_HOST_CFLAGS) -D$$(macro_$(1)) -DTRACE -Itest \
		-DFW_PATH=\"$(AVR_FW)$(call fw_image_tail,$(1),$(ATTINY13A_MCU)).elf\" \
		-DMCU_NAME=\"$(ATTINY13A_MCU)\" \
		-DF_CPU_HZ=$(ATTINY13A_F_CPU) \
		-DTRACE_VCD_PATH=\"$(AVR_BUILD_DIR)/bypass_trace.vcd\" \
		test/avr/test_sim.c $$(PURE_HOST_SRC) -o $$@ $$(SIM_LIBS)

.PHONY: test-sim-$(1)-attiny13a
test-sim-$(1)-attiny13a: test/avr/test_sim_$(1)_attiny13a
	@echo "--- sim (ATtiny13a) variant: $(1) ---"
	./test/avr/test_sim_$(1)_attiny13a
endef
$(foreach v,$(VARIANTS),$(eval $(call VARIANT_SIM_T13,$(v))))

# $(call VARIANT_SIM_X5,variant,chip-number)
define VARIANT_SIM_X5
test/avr/test_sim_$(1)_attiny$(2): $$(SIM_DEPS) $(AVR_FW)$(call fw_image_tail,$(1),$(mmcu_$(2))).elf FORCE
	$$(HOSTCC) $$(SIM_CFLAGS) $$(SIM_DEFS) $$(PURE_HOST_CFLAGS) -D$$(macro_$(1)) -Itest \
		-DFW_PATH=\"$(AVR_FW)$(call fw_image_tail,$(1),$(mmcu_$(2))).elf\" \
		-DMCU_NAME=\"$$(mmcu_$(2))\" \
		-DF_CPU_HZ=$$(TINYX5_F_CPU) \
		-DTARGET_TINYX5 \
		test/avr/test_sim.c $$(PURE_HOST_SRC) -o $$@ $$(SIM_LIBS)

.PHONY: test-sim-$(1)-attiny$(2) test-fault-inject-$(1)-attiny$(2)
test-sim-$(1)-attiny$(2): test/avr/test_sim_$(1)_attiny$(2)
	@echo "--- sim (ATtiny$(2)) variant: $(1) ---"
	./test/avr/test_sim_$(1)_attiny$(2)
test-fault-inject-$(1)-attiny$(2): test/avr/test_sim_$(1)_attiny$(2)
	@echo "--- fault-injection (ATtiny$(2)) variant: $(1) ---"
	./test/avr/test_sim_$(1)_attiny$(2) fault-inject
endef
$(foreach v,$(VARIANTS),$(foreach n,$(TINYX5),$(eval $(call VARIANT_SIM_X5,$(v),$(n)))))

# Aggregate run targets.
# test-sim-attiny13a          : all variants on ATtiny13a
# test-sim-attiny<n> : all variants on tinyx5 chip <n> (e.g. test-sim-attiny85)
# test-sim-tinyx5: all variants on every tinyx5 chip
# test-fault-inject : all variants x every tinyx5 chip
#
# Each aggregate dispatches its (variant x MCU) fan-out through a recursive
# `$(MAKE) -jSIM_JOBS`. The individual runs are independent: every ELF compiles
# in a single command to a distinct output (no shared .o), and every simavr run
# only reads its own ELF and asserts via exit code (the VCD writer is TRACE-only,
# not built here), so nothing is shared and the runs parallelize cleanly. The
# recursive phase also preserves the original ordering guarantee -- for test-sim-attiny13a,
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

test-sim-attiny13a: test-flash-budget
	@$(MAKE) --no-print-directory -j$(SIM_JOBS) $(ATTINY13A_FLASH_OLD_FILE_ARGS) \
		_test-sim-run SIM_DEFS="$(SIM_DEFS)" AVR_REBUILD_PREREQ=
_test-sim-run: $(foreach v,$(VARIANTS),test-sim-$(v)-attiny13a)
$(foreach n,$(TINYX5),$(eval test-sim-attiny$(n): $(foreach v,$(VARIANTS),test-sim-$(v)-attiny$(n))))
test-sim-tinyx5:
	@$(MAKE) --no-print-directory -j$(SIM_JOBS) _test-sim-tinyx5-run SIM_DEFS="$(SIM_DEFS)"
_test-sim-tinyx5-run: $(foreach n,$(TINYX5),test-sim-attiny$(n))
test-fault-inject:
	@$(MAKE) --no-print-directory -j$(SIM_JOBS) _test-fault-inject-run SIM_DEFS="$(SIM_DEFS)"
_test-fault-inject-run: $(foreach v,$(VARIANTS),$(foreach n,$(TINYX5),test-fault-inject-$(v)-attiny$(n)))
.PHONY: test-sim-attiny13a _test-sim-run test-sim-tinyx5 _test-sim-tinyx5-run \
        test-fault-inject _test-fault-inject-run \
        $(foreach n,$(TINYX5),test-sim-attiny$(n))

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
# Drives random input for AVR_SOAK_DURATION_MS of simulated time (default 24 h).
# Checks WDT liveness (no unexpected resets) and device responsiveness (a
# 2-press round-trip every AVR_SOAK_LIVENESS_INTERVAL_MS).  Unlike test_sim.c,
# failures are NEVER fatal: each anomaly is logged and the run continues so
# the full duration is exercised even after an early failure.
#
# Intentionally NOT part of `make test` or `make test-long` -- run standalone
# before hardware signoff or as a pre-release gate.
#
# name-contract: exempt (SOAK_* here is the C macro family, stated below)
# Overrides (command line) -- note the AVR_ prefix. The bare SOAK_* spellings
# are the compiled-in C macros below, NOT make variables: passing one of those
# on the command line defines a variable nothing reads, and the soak silently
# runs at its 24 h default. See test/run_mutation_tests.sh's WDT-pet mutant.
#   AVR_SOAK_VARIANT=<name>             variant to test (default cd4053_simple)
#   AVR_SOAK_CHIP=attiny45              tinyx5 part ($(TINYX5_PARTS); default attiny85)
#   AVR_SOAK_DURATION_MS=3600000        simulated ms (default 86400000 = 24 h)
#   AVR_SOAK_LIVENESS_INTERVAL_MS=10000 liveness-check interval (default 60000 ms)
AVR_SOAK_VARIANT     ?= cd4053_simple
AVR_SOAK_CHIP        ?= attiny85
AVR_SOAK_DURATION_MS ?= 86400000
AVR_SOAK_COMBINATION_NAME ?= standalone
AVR_SOAK_BIN  = test/avr/test_soak_$(AVR_SOAK_VARIANT)_$(AVR_SOAK_CHIP)
AVR_SOAK_DEPS = test/avr/test_soak.c test/bypass_output_host.h test/bypass_config_host.h \
            test/soak_timing_config.h src/bypass_config.h $(FW_HEADERS)

# The C macros (-DSOAK_DURATION_MS, -DSOAK_LIVENESS_INTERVAL_MS, etc.) are baked
# into the binary at compile time. To ensure command-line overrides
# (e.g. `make test-soak AVR_SOAK_DURATION_MS=3600000`) are always picked up, the
# test-soak recipe is phony and always recompiles before running.
AVR_SOAK_LIVENESS_INTERVAL_MS  ?= 60000
AVR_SOAK_PROGRESS_INTERVAL_MS  ?= 3600000
AVR_SOAK_COMPILE = $(HOSTCC) $(SIM_CFLAGS) $(PURE_HOST_CFLAGS) \
	-D$(macro_$(AVR_SOAK_VARIANT)) \
	-Itest \
	-DFW_PATH=\"$(AVR_FW)$(call fw_image_tail,$(AVR_SOAK_VARIANT),$(AVR_SOAK_CHIP)).elf\" \
	-DMCU_NAME=\"$(AVR_SOAK_CHIP)\" \
	-DF_CPU_HZ=$(TINYX5_F_CPU) \
	-DTARGET_TINYX5 \
	-DSOAK_DURATION_MS=$(AVR_SOAK_DURATION_MS) \
	-DSOAK_LIVENESS_INTERVAL_MS=$(AVR_SOAK_LIVENESS_INTERVAL_MS) \
	-DSOAK_PROGRESS_INTERVAL_MS=$(AVR_SOAK_PROGRESS_INTERVAL_MS) \
	-DSOAK_COMBINATION_NAME='"$(AVR_SOAK_COMBINATION_NAME)"' \
	test/avr/test_soak.c -o $(AVR_SOAK_BIN) $(SIM_LIBS)

# Optional build-only convenience: build without running (Make's normal
# dependency tracking applies; won't rebuild on AVR_SOAK_DURATION_MS change alone).
$(AVR_SOAK_BIN): $(AVR_SOAK_DEPS) $(AVR_FW)$(call fw_image_tail,$(AVR_SOAK_VARIANT),$(AVR_SOAK_CHIP)).elf | variant-selectors-valid
	$(AVR_SOAK_COMPILE)

# Run target: always recompiles (phony) so every AVR_SOAK_* override is applied.
test-soak: variant-selectors-valid $(AVR_SOAK_DEPS) $(AVR_FW)$(call fw_image_tail,$(AVR_SOAK_VARIANT),$(AVR_SOAK_CHIP)).elf
	$(AVR_SOAK_COMPILE)
	@echo "--- soak test: variant=$(AVR_SOAK_VARIANT)  MCU=$(AVR_SOAK_CHIP)  duration=$(AVR_SOAK_DURATION_MS) ms ---"
	./$(AVR_SOAK_BIN)

# The soak's `watchdog_failures` counter is release evidence, so prove a real
# watchdog reset can actually reach it. This builds the SAME soak driver against
# the SAME healthy image twice -- untouched, and with the fixture that disables
# the timer interrupt mid-run -- and requires the first to pass with
# watchdog_failures=0 and the second to fail with a nonzero one. A soak that has
# merely stopped being able to observe a reset passes the first half and fails
# the second, which is precisely the drift this gate exists to catch.
#
# Short by construction: the numbers below are one WDT window plus slack, not a
# scaled-down release soak. tinyx5 only -- simavr models the WDT system reset
# for the ATtiny25/45/85 family and not for the ATtiny13a.
AVR_SOAK_WITNESS_VARIANT       ?= cd4053_simple
AVR_SOAK_WITNESS_CHIP          ?= attiny85
AVR_SOAK_WITNESS_DURATION_MS   ?= 3000
AVR_SOAK_WITNESS_LIVENESS_MS   ?= 1000
# Kill the tick with a full WDT window (nominal 250 ms, RC tolerance to ~350 ms)
# plus margin left in the run, so the reset lands inside the soak rather than
# after its last millisecond.
AVR_SOAK_WITNESS_KILL_TIMER_MS ?= 1500
test-soak-reset-witness: variant-selectors-valid $(AVR_SOAK_DEPS) \
                         $(AVR_FW)$(call fw_image_tail,$(AVR_SOAK_WITNESS_VARIANT),$(AVR_SOAK_WITNESS_CHIP)).elf
	@echo "--- soak reset witness: variant=$(AVR_SOAK_WITNESS_VARIANT)  MCU=$(AVR_SOAK_WITNESS_CHIP) ---"
	HOSTCC="$(HOSTCC)" \
	AVR_SOAK_WITNESS_CFLAGS="$(SIM_CFLAGS) $(PURE_HOST_CFLAGS)" \
	AVR_SOAK_WITNESS_LIBS="$(SIM_LIBS)" \
	AVR_SOAK_WITNESS_MACRO="$(macro_$(AVR_SOAK_WITNESS_VARIANT))" \
	AVR_SOAK_WITNESS_FW="$(AVR_FW)$(call fw_image_tail,$(AVR_SOAK_WITNESS_VARIANT),$(AVR_SOAK_WITNESS_CHIP)).elf" \
	AVR_SOAK_WITNESS_MCU="$(AVR_SOAK_WITNESS_CHIP)" \
	AVR_SOAK_WITNESS_F_CPU="$(TINYX5_F_CPU)" \
	AVR_SOAK_WITNESS_DURATION_MS="$(AVR_SOAK_WITNESS_DURATION_MS)" \
	AVR_SOAK_WITNESS_LIVENESS_MS="$(AVR_SOAK_WITNESS_LIVENESS_MS)" \
	AVR_SOAK_WITNESS_KILL_TIMER_MS="$(AVR_SOAK_WITNESS_KILL_TIMER_MS)" \
	./test/test_soak_reset_witness.sh

# Generate a GTKWave-viewable waveform of PB0/PB1/PB2/PB3 over a representative
# press/release sequence for the selected VARIANT. Writes
# $(AVR_BUILD_DIR)/bypass_trace.vcd.
attiny13a-trace: variant-selectors-valid test/avr/test_trace_$(VARIANT)
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
#
# EVERY TARGET BELOW GUARDS ITS VARIANT REQUEST, for a reason that is easy to
# miss: the subject of the analysis is $(FW_SOURCES), which maps $(VARIANTS)
# through src_<variant>, and an unrecognized name maps to NOTHING. So a bad
# VARIANTS= does not fail here -- it silently SHRINKS the analysis set and the
# analyzer honestly reports the smaller set clean. `VARIANTS="cd4053 mute
# relay"` (the pre-v0.9.8 stage vocabulary) leaves the two core files and zero
# of the three output drivers, and `make analyze-misra` exits 0.
#
# That is not hypothetical: MISRA_COMPLIANCE.md documented exactly that command
# as the compliance procedure to run after changing the firmware, so the one
# gate whose whole job is to be believed was the one analyzing nothing.
# classic-variant-request-valid rejects empty, unknown and duplicate names, the
# same guard the build targets carry. Recognized SUBSETS stay valid -- analyzing
# a single driver is a normal development request.
analyze: analyze-tidy analyze-cppcheck analyze-deep analyze-misra
	@echo "=== static analysis (clang-tidy + cppcheck + clang-analyzer + MISRA) clean ==="

# clang-tidy (or whatever ANALYZE_CMD points at). Falls back to avr-gcc
# -fanalyzer if a NEWER avr-gcc that supports it is ever installed; otherwise
# errors with guidance.
analyze-tidy: classic-variant-request-valid $(FW_SOURCES) $(FW_HEADERS)
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
analyze-cppcheck: classic-variant-request-valid $(FW_SOURCES) $(FW_HEADERS)
	@if command -v $(CPPCHECK) >/dev/null 2>&1; then \
		echo "cppcheck: $(CPPCHECK)"; \
		$(CPPCHECK) $(CPPCHECK_FLAGS) $(FW_SOURCES); \
	else \
		echo "cppcheck not installed; skipping (install cppcheck to enable)"; $(SKIP); \
	fi

# Deep path analysis via the clang static analyzer on the AVR target. Emits
# diagnostics as text and FAILS the build on any report (-Werror). This is the
# `-fanalyzer`-equivalent gate.
analyze-deep: classic-variant-request-valid $(FW_SOURCES) $(FW_HEADERS)
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
# cd4053_simple driver under the default VARIANT's macro, the mute and relay
# drivers under their own. Findings are rule-labeled via test/misra_rules.txt;
# avr-libc/avr-gcc system-header findings are excluded (compliance boundary).
#
# GATING: fails the build on any finding NOT covered by a documented deviation
# in test/misra_suppressions.txt (each justified in MISRA_COMPLIANCE.md). The
# suppression list waives those; MISRA_OUTPUT_GATE independently parses every
# remaining source/header diagnostic because cppcheck's error exit status does
# not cover included headers. Part of `analyze` -> `make test`.
.PHONY: analyze-misra
analyze-misra: variant-selectors-valid classic-variant-request-valid $(FW_SOURCES) $(FW_HEADERS) $(MISRA_ADDON) $(MISRA_RULES) $(MISRA_SUPPRESS) $(MISRA_OUTPUT_GATE)
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
			$(MISRA_DIAGNOSTIC_TEMPLATE) --suppressions-list=$(MISRA_SUPPRESS) \
			--error-exitcode=2 -D$$m $$f 2>>$$out || rc=$$?; \
	done; \
	if ! python3 "$(MISRA_OUTPUT_GATE)" --repo-root "$(CURDIR)" \
			--output "$$out" --tool-status "$$rc"; then \
		echo "MISRA findings NOT covered by a documented deviation:"; \
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
analyze-misra-report: variant-selectors-valid classic-variant-request-valid $(FW_SOURCES) $(FW_HEADERS) $(MISRA_ADDON) $(MISRA_RULES)
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
# --- the SECOND coverage gate: the real core ---------------------------------
# COVERAGE_SRC above measures test/host/test_logic_host.c -- the independent
# "golden model" ORACLE, which by design does NOT include the firmware (see that
# file's header). So the 90% floor above says nothing about src/bypass_pure.c,
# the code that actually ships on every target.
#
# This gate closes that hole. It measures the REAL core, exercised by the two
# formal drivers that link it, against its own higher floor. Promoted from the
# PIC10F320 child project during the merge: it was the only line-coverage gate
# over the shipping core that either project had, and folding the child's copy
# away would have DELETED it rather than deduplicated it (merge plan,
# Principle 8). Two subjects need two floors -- do not merge these two gates.
COVERAGE_CORE_MIN ?= 95
COVERAGE_CORE_SRC  = $(PURE_HOST_SRC)
COVERAGE_CORE_OBJ_NAME   = bypass_pure_cov.o
COVERAGE_CORE_ANNOTATION = bypass_pure.c.gcov
# Drivers that link the real core. test/host/test_logic_host is deliberately
# ABSENT: it is the oracle and links no core object, so adding it would inflate
# nothing and confuse the gate's subject.
COVERAGE_CORE_DRIVERS = test/formal/test_model_check.c test/formal/test_symbolic.c

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

# Line-coverage gate over the REAL core, src/bypass_pure.c (see
# COVERAGE_CORE_MIN above for why this is a separate gate from coverage-check).
# The core is compiled ONCE with --coverage and linked into each driver, so the
# .gcda accumulates across all of them and the percentage reflects the whole
# formal suite rather than any single run.
.PHONY: coverage-check-core
coverage-check-core:
	@mkdir -p "$(COVERAGE_DIR)" || exit 1; \
	work=`mktemp -d "$(COVERAGE_DIR)/core.XXXXXX"` || exit 1; \
	trap 'rm -rf "$$work"' EXIT HUP INT TERM; \
	$(HOSTCC) $(HOST_CFLAGS) $(HOST_DEFS) $(PURE_HOST_CFLAGS) -Itest --coverage \
		-c $(abspath $(COVERAGE_CORE_SRC)) -o "$$work/$(COVERAGE_CORE_OBJ_NAME)" || exit 1; \
	for drv in $(COVERAGE_CORE_DRIVERS); do \
		bin="$$work/`basename $$drv .c`"; \
		$(HOSTCC) $(HOST_CFLAGS) $(HOST_DEFS) $(PURE_HOST_CFLAGS) -Itest --coverage \
			$(abspath $$drv) "$$work/$(COVERAGE_CORE_OBJ_NAME)" -o "$$bin" || exit 1; \
		"$$bin" >/dev/null || { echo "FAIL: $$drv failed under coverage"; exit 1; }; \
	done; \
	if [ ! -s "$$work/bypass_pure_cov.gcda" ]; then \
		echo "FAIL: coverage run did not produce fresh profile data for the core"; exit 1; \
	fi; \
	out=`cd "$$work" && $(GCOV) -o . $(COVERAGE_CORE_OBJ_NAME) 2>&1` \
		|| { printf '%s\n' "$$out"; echo "FAIL: gcov could not generate core coverage"; exit 1; }; \
	pct=`printf '%s\n' "$$out" | awk -F'[:%]' '/Lines executed/{print $$2; exit}'`; \
	echo "verified-core line coverage (src/bypass_pure.c): $${pct:-unknown}% (floor $(COVERAGE_CORE_MIN)%)"; \
	if ! printf '%s\n' "$$pct" | grep -Eq '^[0-9]+([.][0-9]+)?$$'; then \
		echo "FAIL: gcov line coverage is missing or malformed:"; \
		printf '%s\n' "$$out"; exit 1; \
	fi; \
	if [ ! -s "$$work/$(COVERAGE_CORE_ANNOTATION)" ]; then \
		echo "FAIL: gcov reported success but produced no fresh $(COVERAGE_CORE_ANNOTATION)"; \
		printf '%s\n' "$$out"; exit 1; \
	fi; \
	if ! printf '%s\n' "$(COVERAGE_CORE_MIN)" | grep -Eq '^[0-9]+([.][0-9]+)?$$'; then \
		echo "FAIL: COVERAGE_CORE_MIN is malformed: $(COVERAGE_CORE_MIN)"; exit 1; \
	fi; \
	awk -v p="$$pct" -v m="$(COVERAGE_CORE_MIN)" 'BEGIN{exit !(p>=0 && p<=100 && m>=0 && m<=100)}' \
		|| { echo "FAIL: coverage percentage or floor is outside 0..100"; exit 1; }; \
	awk -v p="$$pct" -v m="$(COVERAGE_CORE_MIN)" 'BEGIN{exit !(p>=m)}' \
		|| { echo "FAIL: core coverage $$pct% below floor $(COVERAGE_CORE_MIN)%"; exit 1; }

# Remove coverage artifacts (the coverage/ dir and any stray gcov data files).
coverage-clean:
	rm -rf $(COVERAGE_DIR)
	find . -name '*.gcda' -o -name '*.gcno' | xargs rm -f

# ============================================================================
# PIC10F320 -- the constrained target (Phase 2 scaffolding: host lanes)
# ============================================================================
# PIC10F320 has 256 words of flash, HALF the PIC10F322's. The pure/result-struct
# architecture every other target uses does not fit, so its firmware inlines the
# debounce algorithm into main() by hand. That is the whole reason this target
# exists, and it is why its lanes are separate from the PIC10F322 ones rather
# than parameterized alongside them.
#
# NAMING: all three PIC lanes are equally-explicit siblings -- `pic10f322-*`,
# `pic10f320-*`, and `pic12f675-*` -- and a goal named `pic-*` covers shared PIC
# mechanism (test-pic-build, test-lockstep-progress,
# test-stack-bound-pic-regression). This supersedes
# merge-plan §15 D1, which kept the bare `pic-` prefix for the 322 because it
# got here first; that made `pic-` read as a qualifier rather than a part and
# put the two chips one near-name apart. Do NOT add a PIC-shaped variable here
# without a part-scoped prefix: a mis-scoped chip variable produces no compile
# error and no failing test, it produces a PASSING one (§14.7 -- e.g. the wrong
# flash budget silently gates 256 words against 512).
#
# Toolchain is deliberately SHARED with the PIC10F322 lane: both parts are built
# by the same XC8 V3.10 + PIC10-12Fxxx DFP 1.9.189 (verified equal, plan §6.14).
PIC10F320_CC          ?= $(PIC_CC)
PIC10F320_DFP         ?= $(PIC_DFP)

PIC10F320_CHIP        ?= 10F320
PIC10F320_TAG         ?= pic10f320
PIC10F320_XTAL        ?= 2000000UL
PIC10F320_FLASH_WORDS ?= 256

# PIC10F320_FW_BASE is GONE. It used to be `bypass_mcu`, a prefix inherited from the
# archived child repository whose `_mcu_` infix distinguished nothing -- every
# image in every lane is MCU firmware. This part now shares the one FW_BASE with
# every other lane and is told apart by the mandatory MCU field. See "canonical
# firmware image basename" near the top.
PIC10F320_SRC         := src/bypass_mcu_pic10f320.c
PIC10F320_BUILD_DIR   ?= build_pic10f320

# §5.7: PIC10F320 coverage lives UNDER the build directory, never in the shared
# top-level coverage/ that the parent lanes own. One ignore entry covers both,
# and every destructive recipe below can be scoped to a single root.
PIC10F320_COVERAGE_DIR := $(PIC10F320_BUILD_DIR)/coverage

# --- output variant ----------------------------------------------------------
PIC10F320_VARIANT      ?= cd4053_simple
# The authoritative supported set and sanitized request are established before
# serialization so command-line matrix text cannot execute during recursive Make.

ifeq ($(PIC10F320_VARIANT),cd4053_simple)
  PIC10F320_OUTPUT_MACRO := OUTPUT_CD4053_SIMPLE
else ifeq ($(PIC10F320_VARIANT),cd4053_with_mute)
  PIC10F320_OUTPUT_MACRO := OUTPUT_CD4053_WITH_MUTE
else ifeq ($(PIC10F320_VARIANT),tq2_l2_5v_relay)
  PIC10F320_OUTPUT_MACRO := OUTPUT_TQ2_RELAY
else
  $(error PIC10F320_VARIANT must be one of: $(PIC10F320_VARIANTS_ALL) (got '$(PIC10F320_VARIANT)'))
endif
PIC10F320_OUTPUT_DEF := -D$(PIC10F320_OUTPUT_MACRO)

PIC10F320_CFLAGS := -mcpu=$(PIC10F320_CHIP) -mdfp=$(PIC10F320_DFP) -std=c99 -O2 \
                 -D_XTAL_FREQ=$(PIC10F320_XTAL) $(PIC10F320_OUTPUT_DEF)
override PIC10F320_HEX    := $(PIC10F320_BUILD_DIR)/$(call fw_image,$(PIC10F320_VARIANT),$(PIC10F320_TAG)).hex
override PIC10F320_ASM    := $(PIC10F320_HEX:.hex=.s)
override PIC10F320_SYM    := $(PIC10F320_HEX:.hex=.sym)
override PIC10F320_BUILD_PRODUCTS := $(PIC10F320_HEX) $(PIC10F320_ASM) $(PIC10F320_SYM)

# Final-HEX hardware return-stack oracle. Expand the real-image list from the
# immutable supported set, never from a glob or the caller's PIC10F320_VARIANTS_ALL
# request, so the build and gate cannot acquire divergent hard-coded matrices.
override PIC10F320_RETURN_STACK_ORACLE := test/pic10f320/return_stack_oracle.py
override PIC10F320_RETURN_STACK_LIMIT := 8
override PIC10F320_RETURN_STACK_IMAGES := $(foreach v,$(PIC10F320_VARIANTS_SUPPORTED),$(PIC10F320_BUILD_DIR)/$(call fw_image,$(v),$(PIC10F320_TAG)).hex)

# Standing byte-identity regression. These hashes deliberately pin the exact
# XC8 V3.10 + PIC10-12Fxxx DFP 1.9.189 output. A reviewed firmware/toolchain
# change may rebaseline them, but a normal build must never rewrite the file.
override PIC10F320_EXPECTED_IMAGE_CHECKER := test/pic10f320/check_expected_images.py
override PIC10F320_EXPECTED_IMAGE_MANIFEST := test/pic10f320/expected_images.sha256
override PIC10F320_EXPECTED_IMAGE_PATHS := $(foreach v,$(PIC10F320_VARIANTS_SUPPORTED),$(PIC10F320_BUILD_DIR)/$(call fw_image,$(v),$(PIC10F320_TAG)).hex)

# --- host lanes --------------------------------------------------------------
# HOST_CFLAGS here intentionally mirrors the IMPORTED build contract (no
# -Wconversion) rather than the parent's stricter host flags: the relocated
# harnesses were written and proven green under these. Tightening them is a
# deliberate follow-up, not a side effect of relocation.
PIC10F320_HOST_CC     ?= $(HOSTCC)
PIC10F320_HOST_CFLAGS ?= -std=c11 -O2 -Wall -Wextra -Werror
PIC10F320_HOST_INC    := -Itest

# The equivalence and lock-step lanes compile and link the ONE verified core --
# src/bypass_pure.c -- never a vendored copy (Principle 2).
PIC10F320_MODEL_SRC   := src/bypass_pure.c

PIC10F320_EQUIV_DIR   := test/pic10f320/equiv
PIC10F320_ACT_DIR     := test/pic10f320/actuation
PIC10F320_FAULT_DIR   := test/pic10f320/fault

# The firmware is #included verbatim by both host harnesses, with main() renamed
# so the driver can step it. -Wno-unknown-pragmas because XC8 pragmas (CONFIG)
# are meaningless to the host compiler.
PIC10F320_FW_HOST_DEFS := -Wno-unknown-pragmas -Dmain=fw_main \
                       -D_XTAL_FREQ=$(PIC10F320_XTAL) $(PIC10F320_OUTPUT_DEF)
PIC10F320_FAULT_INC    := -I$(PIC10F320_EQUIV_DIR) -I$(PIC10F320_FAULT_DIR)

# Firmware-coverage inputs (Phase 5). Same compile contract as the fault lane
# above -- including the deliberate split where only the DRIVER is -Werror, since
# the harness translation unit #includes the shipping firmware -- but at -O0 so
# gcov's line mapping is exact, and with --coverage instrumentation.
PIC10F320_COVERAGE_FW_CFLAGS  := -std=c11 -O0 --coverage
PIC10F320_COVERAGE_DRV_CFLAGS := -std=c11 -O0 -Wall -Wextra -Werror --coverage
PIC10F320_COVERAGE_FW_BASE    := fw_fault_cov
PIC10F320_COVERAGE_FW_GATE    := $(PIC10F320_FAULT_DIR)/check_fw_coverage.sh
PIC10F320_COVERAGE_ANNOTATION := $(notdir $(PIC10F320_SRC)).gcov

.PHONY: pic10f320-test-equiv pic10f320-test-actuation pic10f320-test-fault-host \
        pic10f320-coverage-check-fw pic10f320-test-host pic10f320-test-host-variants \
        test-pic10f320-return-stack-oracle pic10f320-clean

# Dependency-free parser/control-flow regression. This is part of make test and
# test-long, so malformed-image handling and every supported/rejected flow opcode
# remain exercised even on hosts without XC8 and without any PIC HEX artifacts.
test-pic10f320-return-stack-oracle: $(PIC10F320_RETURN_STACK_ORACLE)
	@if ! command -v python3 >/dev/null 2>&1; then \
		echo "FAIL: python3 is required by the PIC10F320 return-stack oracle"; exit 1; \
	fi
	@python3 $(PIC10F320_RETURN_STACK_ORACLE) --selftest

# Tool-independent checker/manifest regression. The full image comparison lives
# in pic10f320-test-build because make test does not require XC8.
test-pic10f320-expected-images:
	@if ! command -v python3 >/dev/null 2>&1; then \
		echo "FAIL: python3 is required by the PIC10F320 expected-image checker"; exit 1; \
	fi
	@python3 $(PIC10F320_EXPECTED_IMAGE_CHECKER) --selftest
	@python3 $(PIC10F320_EXPECTED_IMAGE_CHECKER) $(PIC10F320_EXPECTED_IMAGE_MANIFEST)

test-pic10f320-coverage-archive:
	@./test/test_pic10f320_coverage_archive.sh

# Firmware<->core equivalence: the real firmware, host-compiled, stepped tick for
# tick against src/bypass_pure.c on the same stimulus.
pic10f320-test-equiv:
	@mkdir -p $(PIC10F320_BUILD_DIR)
	@$(PIC10F320_HOST_CC) -std=c11 -O2 $(PIC10F320_FW_HOST_DEFS) -I$(PIC10F320_EQUIV_DIR) \
		-c $(PIC10F320_EQUIV_DIR)/fw_harness.c -o $(PIC10F320_BUILD_DIR)/fw_harness.o
	@$(PIC10F320_HOST_CC) $(PIC10F320_HOST_CFLAGS) $(PIC10F320_HOST_INC) \
		-c $(PIC10F320_EQUIV_DIR)/test_equiv.c -o $(PIC10F320_BUILD_DIR)/test_equiv_drv.o
	@$(PIC10F320_HOST_CC) $(PIC10F320_HOST_CFLAGS) $(PIC10F320_HOST_INC) \
		-c $(PIC10F320_MODEL_SRC) -o $(PIC10F320_BUILD_DIR)/bypass_pure_equiv.o
	@$(PIC10F320_HOST_CC) $(PIC10F320_BUILD_DIR)/fw_harness.o \
		$(PIC10F320_BUILD_DIR)/test_equiv_drv.o $(PIC10F320_BUILD_DIR)/bypass_pure_equiv.o \
		-o $(PIC10F320_BUILD_DIR)/test_equiv
	@$(PIC10F320_BUILD_DIR)/test_equiv

# Settled control-pin sequence for the selected output stage (the variant-
# specific RA1/RA2 pattern the equivalence lane deliberately does not check).
pic10f320-test-actuation: variant-selectors-valid
	@mkdir -p $(PIC10F320_BUILD_DIR)
	@$(PIC10F320_HOST_CC) -std=c11 -O2 $(PIC10F320_FW_HOST_DEFS) -I$(PIC10F320_EQUIV_DIR) \
		-c $(PIC10F320_EQUIV_DIR)/fw_harness.c -o $(PIC10F320_BUILD_DIR)/fw_harness_$(PIC10F320_VARIANT).o
	@$(PIC10F320_HOST_CC) $(PIC10F320_HOST_CFLAGS) $(PIC10F320_OUTPUT_DEF) \
		-c $(PIC10F320_ACT_DIR)/test_actuation.c \
		-o $(PIC10F320_BUILD_DIR)/test_actuation_drv_$(PIC10F320_VARIANT).o
	@$(PIC10F320_HOST_CC) $(PIC10F320_BUILD_DIR)/fw_harness_$(PIC10F320_VARIANT).o \
		$(PIC10F320_BUILD_DIR)/test_actuation_drv_$(PIC10F320_VARIANT).o \
		-o $(PIC10F320_BUILD_DIR)/test_actuation_$(PIC10F320_VARIANT)
	@$(PIC10F320_BUILD_DIR)/test_actuation_$(PIC10F320_VARIANT)

# Host fault injection over the firmware's defensive layer: corrupt an SFR or the
# debounce context, assert the sanity gate forces a watchdog reset. Distinct from
# the libgpsim TARGET fault lane added in Phase 4 -- hence the -host suffix.
pic10f320-test-fault-host:
	@mkdir -p $(PIC10F320_BUILD_DIR)
	@$(PIC10F320_HOST_CC) -std=c11 -O2 $(PIC10F320_FW_HOST_DEFS) $(PIC10F320_FAULT_INC) \
		-c $(PIC10F320_FAULT_DIR)/fw_fault_harness.c \
		-o $(PIC10F320_BUILD_DIR)/fw_fault_harness.o
	@$(PIC10F320_HOST_CC) $(PIC10F320_HOST_CFLAGS) $(PIC10F320_OUTPUT_DEF) $(PIC10F320_FAULT_INC) \
		-c $(PIC10F320_FAULT_DIR)/test_fault.c -o $(PIC10F320_BUILD_DIR)/test_fault_drv.o
	@$(PIC10F320_HOST_CC) $(PIC10F320_BUILD_DIR)/fw_fault_harness.o \
		$(PIC10F320_BUILD_DIR)/test_fault_drv.o -o $(PIC10F320_BUILD_DIR)/test_fault
	@$(PIC10F320_BUILD_DIR)/test_fault

# Firmware line-coverage GATE over the REAL shipping source, src/bypass_mcu_pic10f320.c.
# The last child validation layer without an equivalent in the merged tree, and
# unlike the model gates (`coverage-check`, `coverage-check-core`, which are
# percentage floors) this asserts an EXACT property: every firmware line must be
# exercised on the host except the enumerated watchdog-reset fault path. The
# allow-list and the reasoning for each entry live in the gate script itself.
#
# It is a HOST lane -- cc + gcov only, both already inside `make test`'s existing
# tool contract -- so it joins pic10f320-test-host rather than the full-tool
# pic10f320-test aggregate.
#
# Deliberately NOT converged with the PIC10F322's pic10f322-coverage-check-fw
# (test/pic/fw_coverage/run_fw_coverage.sh), which is a different mechanism over
# a different source set (shell + shared pure core + all three output drivers).
# Merge plan §6.12 flags the two-mechanism outcome; the split is kept because the
# 320's exact-line property is only meaningful for a single fully-inlined TU,
# whereas the 322's multi-file set needs the percentage-style harness. Converging
# them would weaken one or the other, so it is recorded rather than forced.
#
# Runs per variant: the firmware's #ifdef output stages give the three variants
# 84 / 95 / 100 executable lines, so a single-variant run would leave real
# firmware logic unmeasured. pic10f320-test-host-variants sweeps all three.
pic10f320-coverage-check-fw: variant-selectors-valid host-compiler-valid
	@# Local executability is required everywhere, including source archives.
	@# Inside a worktree, also verify what CI will receive from the Git index.
	@if [ ! -x "$(PIC10F320_COVERAGE_FW_GATE)" ]; then \
		echo "ERROR: $(PIC10F320_COVERAGE_FW_GATE) lacks its local exec bit."; \
		echo "       Fix: chmod +x $(PIC10F320_COVERAGE_FW_GATE)"; \
		exit 1; \
	fi; \
	if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then \
		mode=`git ls-files --stage -- "$(PIC10F320_COVERAGE_FW_GATE)" | cut -d' ' -f1`; \
		if [ "$$mode" != "100755" ]; then \
			echo "ERROR: $(PIC10F320_COVERAGE_FW_GATE) is not mode 100755 in git (found '$$mode')."; \
			echo "       Fix: git update-index --chmod=+x $(PIC10F320_COVERAGE_FW_GATE)"; \
			exit 1; \
		fi; \
	fi
	@mkdir -p "$(PIC10F320_COVERAGE_DIR)" || exit 1; \
	work=`mktemp -d "$(PIC10F320_COVERAGE_DIR)/fw.XXXXXX"` || exit 1; \
	trap 'rm -rf "$$work"' EXIT HUP INT TERM; \
	$(PIC10F320_HOST_CC) $(PIC10F320_COVERAGE_FW_CFLAGS) $(PIC10F320_FW_HOST_DEFS) \
		$(PIC10F320_FAULT_INC) -c $(abspath $(PIC10F320_FAULT_DIR)/fw_fault_harness.c) \
		-o "$$work/$(PIC10F320_COVERAGE_FW_BASE).o" || exit 1; \
	$(PIC10F320_HOST_CC) $(PIC10F320_COVERAGE_DRV_CFLAGS) $(PIC10F320_OUTPUT_DEF) \
		$(PIC10F320_FAULT_INC) -c $(abspath $(PIC10F320_FAULT_DIR)/test_fault.c) \
		-o "$$work/test_fault_cov_drv.o" || exit 1; \
	$(PIC10F320_HOST_CC) --coverage "$$work/$(PIC10F320_COVERAGE_FW_BASE).o" \
		"$$work/test_fault_cov_drv.o" -o "$$work/test_fault_cov" || exit 1; \
	"$$work/test_fault_cov" >/dev/null \
		|| { echo "FAIL: the PIC10F320 fault harness failed under coverage instrumentation"; exit 1; }; \
	if [ ! -s "$$work/$(PIC10F320_COVERAGE_FW_BASE).gcda" ]; then \
		echo "FAIL: the coverage run produced no fresh profile data for the PIC10F320 firmware"; exit 1; \
	fi; \
	out=`cd "$$work" && $(GCOV) -o . $(PIC10F320_COVERAGE_FW_BASE).o 2>&1` \
		|| { printf '%s\n' "$$out"; echo "FAIL: gcov could not generate PIC10F320 firmware coverage"; exit 1; }; \
	if [ ! -s "$$work/$(PIC10F320_COVERAGE_ANNOTATION)" ]; then \
		echo "FAIL: gcov reported success but produced no fresh $(PIC10F320_COVERAGE_ANNOTATION)"; \
		printf '%s\n' "$$out"; exit 1; \
	fi; \
	echo "PIC10F320 firmware line coverage (fault + happy-path harness, variant $(PIC10F320_VARIANT)):"; \
	$(PIC10F320_COVERAGE_FW_GATE) "$$work/$(PIC10F320_COVERAGE_ANNOTATION)"

# Tool-independent aggregate: everything above needs only a host C compiler (plus
# gcov for the coverage gate), so this joins `test` (Principle 5). It does NOT
# build any HEX.
pic10f320-test-host: variant-selectors-valid \
                  pic10f320-test-equiv pic10f320-test-actuation pic10f320-test-fault-host \
                  pic10f320-coverage-check-fw
	@echo "=== all PIC10F320 host lanes passed (variant $(PIC10F320_VARIANT)) ==="

# ...and the all-variant sweep, which is what `test`/`test-long` actually wire in:
# every host lane above is compiled against a variant-specific firmware, so one
# variant is one third of the evidence. Uses the same Make-function matrix guard
# as pic10f320-test-target-variants -- empty, duplicated, unsupported, and incomplete
# matrices are rejected on stderr before any variant runs, so "all variants
# passed" always means the complete supported set ran (§6.5). Registered in
# test/test_target_matrix.sh, which proves the guard by feeding it each bad matrix.
pic10f320-test-host-variants:
	@if [ "$(PIC10F320_VARIANTS_REQUEST_EMPTY)" -eq 1 ]; then \
		echo "FAIL: PIC10F320_VARIANTS_ALL must not be empty" >&2; exit 2; \
	fi; \
	if [ "$(PIC10F320_VARIANTS_REQUEST_DUPLICATE)" -eq 1 ]; then \
		echo "FAIL: PIC10F320_VARIANTS_ALL must not contain duplicate names" >&2; exit 2; \
	fi; \
	if [ "$(PIC10F320_VARIANTS_REQUEST_UNKNOWN)" -eq 1 ]; then \
		echo "FAIL: PIC10F320_VARIANTS_ALL contains unsupported names; supported: $(PIC10F320_VARIANTS_SUPPORTED)" >&2; exit 2; \
	fi; \
	if [ "$(if $(filter-out $(PIC10F320_VARIANTS_ALL),$(PIC10F320_VARIANTS_SUPPORTED)),yes,no)" = yes ]; then \
		echo "FAIL: PIC10F320_VARIANTS_ALL must contain every supported name; required: $(PIC10F320_VARIANTS_SUPPORTED)" >&2; exit 2; \
	fi
	@for v in $(PIC10F320_VARIANTS_SUPPORTED); do \
		echo "===================== PIC10F320 HOST VARIANT $$v ====================="; \
		$(MAKE) --no-print-directory PIC10F320_VARIANT=$$v pic10f320-test-host || exit 1; \
	done
	@echo "=== PIC10F320 host equivalence/actuation/fault/coverage validated for all variants ==="

# --- Phase 4: hardened build, flash budget, static analysis ------------------
# XC8/DFP header locations. Shared installation with the PIC10F322 lane, but
# kept as separate variables so one chip can be re-pinned without silently
# moving the other (§5.6: anything not on the shared-tool allowlist is presumed
# chip-specific).
PIC10F320_XC8_INCLUDE ?= $(PIC_XC8_INCLUDE)
PIC10F320_DFP_INCLUDE ?= $(PIC10F320_DFP)/pic/include
PIC10F320_CHIP_MACRO  ?= _$(PIC10F320_CHIP)

PIC10F320_CPPCHECK_CPPFLAGS = -D__XC8 -D$(PIC10F320_CHIP_MACRO) \
                           -D_XTAL_FREQ=$(PIC10F320_XTAL) $(PIC10F320_OUTPUT_DEF) \
                           -I$(PIC10F320_DFP_INCLUDE) -I$(PIC10F320_DFP_INCLUDE)/proc \
                           -I$(PIC10F320_XC8_INCLUDE)

PIC10F320_CPPCHECK_FLAGS ?= --enable=warning,style,performance,portability \
                      --std=c11 --platform=pic8-enhanced --error-exitcode=2 \
                      --inline-suppr --max-configs=1 \
                      --suppress=missingIncludeSystem \
                      --suppress=unmatchedSuppression \
                      --suppress=unusedStructMember \
                      '--suppress=*:$(PIC10F320_XC8_INCLUDE)/*' \
                      '--suppress=*:$(PIC10F320_DFP_INCLUDE)/*' \
                      $(PIC10F320_CPPCHECK_CPPFLAGS)

PIC10F320_MISRA_CPPCHECK_FLAGS ?= --addon=$(MISRA_ADDON) --std=c11 \
                      --platform=pic8-enhanced \
                      --enable=style --inline-suppr --max-configs=1 \
                      --suppress=unmatchedSuppression \
                      --suppress=missingIncludeSystem \
                      '--suppress=*:$(PIC10F320_XC8_INCLUDE)/*' \
                      '--suppress=*:$(PIC10F320_DFP_INCLUDE)/*' \
                      $(PIC10F320_CPPCHECK_CPPFLAGS)

.PHONY: pic10f320 pic10f320-size pic10f320-analyze pic10f320-analyze-cppcheck \
        pic10f320-analyze-misra

# Build one variant and gate it against the 256-word budget.
#
# Every failure mode here is one the child project hardened against and proved
# with fake-XC8 regressions (merge plan §6.4, commit ec6fa48), so this is a port
# of tested logic, not a fresh attempt:
#   - the HEX, assembly, and symbol paths are removed FIRST, and removal is
#     symlink/directory safe, so stale output cannot be mistaken for fresh;
#   - an EXIT trap deletes all three products unless the recipe reached the end,
#     so a failed or interrupted build never leaves plausible-looking evidence
#     behind for a later lane to consume;
#   - XC8's exit status, a nonempty image, structural Intel HEX validity, and a
#     parseable word count are each checked separately -- XC8 can report success
#     and still not produce a usable image;
#   - the budget comparison is done by string length then lexically, never by
#     shell arithmetic, so a huge or malformed word count cannot wrap into a
#     passing value;
#   - the final HEX passes the immutable hardware return-stack oracle BEFORE the
#     completion flag is set, so any oracle/tool failure reaches the same cleanup
#     trap and removes the rejected image.
pic10f320: variant-selectors-valid $(PIC10F320_SRC)
	@for path in $(PIC10F320_BUILD_PRODUCTS); do \
		if [ -d "$$path" ] && [ ! -L "$$path" ]; then rmdir "$$path"; \
		else rm -f "$$path"; fi || exit 1; \
	done
	@# ONE shell from here down, deliberately. $(SKIP) is `exit 0` in non-strict
	@# mode, which exits only the shell running it -- so if this guard stood on its
	@# own recipe line, a missing XC8 would print "skipping" and then Make would
	@# run the NEXT line and try to compile with it anyway. That is exactly what
	@# happened until test/test_strict_tools.sh grew a PIC inventory and caught it.
	@if [ ! -x "$(PIC10F320_CC)" ] && ! command -v $(PIC10F320_CC) >/dev/null 2>&1; then \
		echo "XC8 not found at $(PIC10F320_CC) (override with PIC10F320_CC=...)"; $(SKIP); \
	fi; \
	mkdir -p $(PIC10F320_BUILD_DIR); \
	echo "=== PIC10F320 build + flash-budget ($(PIC10F320_FLASH_WORDS) words, variant $(PIC10F320_VARIANT)) ==="; \
	hex="$(PIC10F320_HEX)"; asm="$(PIC10F320_ASM)"; sym="$(PIC10F320_SYM)"; image_complete=0; \
	remove_products() { \
		for path in "$$hex" "$$asm" "$$sym"; do \
			if [ -d "$$path" ] && [ ! -L "$$path" ]; then rmdir "$$path"; else rm -f "$$path"; fi \
				|| return 1; \
		done; \
	}; \
	cleanup_image() { \
		rc=$$?; \
		if [ $$rc -ne 0 ] || [ $$image_complete -ne 1 ]; then \
			remove_products || rc=1; \
			[ $$rc -ne 0 ] || rc=1; \
		fi; \
		trap - 0 1 2 15; exit $$rc; \
	}; \
	trap cleanup_image 0 1 2 15; \
	export PIC_RECIPE_PID=$$$$; \
	LC_ALL=C; export LC_ALL; \
	if ! command -v python3 >/dev/null 2>&1; then \
		echo "FAIL: python3 is required to validate every PIC10F320 image"; exit 1; \
	fi; \
	if [ ! -f "$(PIC10F320_RETURN_STACK_ORACLE)" ] || [ -L "$(PIC10F320_RETURN_STACK_ORACLE)" ] \
	   || [ ! -s "$(PIC10F320_RETURN_STACK_ORACLE)" ]; then \
		echo "FAIL: PIC10F320 return-stack oracle is missing or invalid: $(PIC10F320_RETURN_STACK_ORACLE)"; exit 1; \
	fi; \
	budget="$(PIC10F320_FLASH_WORDS)"; \
	case "$$budget" in ''|*[!0-9]*) echo "FAIL: PIC10F320_FLASH_WORDS must be a positive decimal integer"; exit 1 ;; esac; \
	while [ "$${#budget}" -gt 1 ] && [ "$${budget#0}" != "$$budget" ]; do budget=$${budget#0}; done; \
	if [ "$$budget" = 0 ]; then echo "FAIL: PIC10F320_FLASH_WORDS must be a positive decimal integer"; exit 1; fi; \
	out=`cd $(PIC10F320_BUILD_DIR) && $(PIC10F320_CC) $(PIC10F320_CFLAGS) $(CURDIR)/$(PIC10F320_SRC) \
		-o $(notdir $(PIC10F320_HEX)) 2>&1` \
		|| { printf '%s\n' "$$out"; echo "FAIL: did not compile for PIC10F320"; exit 1; }; \
	if [ ! -s "$$hex" ]; then \
		echo "FAIL: XC8 reported success but did not produce a nonempty $$hex"; \
		printf '%s\n' "$$out"; exit 1; \
	fi; \
	if ! $(IHEX_VALIDATOR) "$$hex"; then \
		echo "FAIL: XC8 produced an invalid Intel HEX image: $$hex"; exit 1; \
	fi; \
	dec=`printf '%s\n' "$$out" | grep -E 'Program space' \
		| grep -oE '\( *[0-9]+ *\)' | head -1 | tr -d '() '`; \
	if [ -z "$$dec" ]; then \
		echo "FAIL: could not parse program-word count from XC8 output:"; \
		printf '%s\n' "$$out"; exit 1; \
	fi; \
	while [ "$${#dec}" -gt 1 ] && [ "$${dec#0}" != "$$dec" ]; do dec=$${dec#0}; done; \
	over_budget=0; \
	if [ "$${#dec}" -gt "$${#budget}" ]; then over_budget=1; \
	elif [ "$${#dec}" -eq "$${#budget}" ]; then \
		cmp=`$(AWK) -v a="x$$dec" -v b="x$$budget" \
			'BEGIN { print (a > b ? "gt" : "le") }'`; cmp_rc=$$?; \
		if [ $$cmp_rc -ne 0 ]; then \
			echo "FAIL: could not compare program usage with flash budget"; exit 1; \
		fi; \
		case "$$cmp" in \
			gt) over_budget=1 ;; \
			le) ;; \
			*) echo "FAIL: invalid flash-budget comparison result"; exit 1 ;; \
		esac; \
	fi; \
	pct=`$(AWK) -v u="$$dec" -v t="$$budget" \
		'BEGIN { printf "%.1f", u * 100 / t }'`; pct_rc=$$?; \
	pct_integer=$${pct%.*}; pct_fraction=$${pct#*.}; pct_valid=1; \
	[ "$$pct_integer" != "$$pct" ] || pct_valid=0; \
	case "$$pct_integer" in ''|*[!0-9]*) pct_valid=0 ;; esac; \
	case "$$pct_fraction" in [0-9]) ;; *) pct_valid=0 ;; esac; \
	if [ $$pct_rc -ne 0 ] || [ $$pct_valid -ne 1 ]; then \
		echo "FAIL: could not calculate flash usage percentage"; exit 1; \
	fi; \
	if [ $$over_budget -eq 1 ]; then \
		echo "FAIL: uses $$dec words ($${pct}%) -- exceeds $$budget"; exit 1; \
	fi; \
	if ! python3 "$(PIC10F320_RETURN_STACK_ORACLE)" \
			--limit "$(PIC10F320_RETURN_STACK_LIMIT)" "$$hex"; then \
		echo "FAIL: PIC10F320 return-stack analysis rejected $$hex"; exit 1; \
	fi; \
	echo "OK:   $$hex : $$dec words ($${pct}%) of $$budget; return stack validated"; \
	image_complete=1

# Build every supported variant, fail-closed on the matrix itself.
#
# The closing sentinel asserts the POSTCONDITION -- every expected image exists --
# rather than trusting the loop's exit status. The two are not the same thing
# here, because `pic10f320` skips cleanly (exit 0) when XC8 is absent, so a
# status-only check printed "all PIC10F320 variants built within budget" having
# built nothing at all. The 322's `pic10f322` cannot do that: it skips as one recipe
# and claims nothing. This is the same false-evidence shape as the one
# test/test_target_lane_markers.sh exists to prevent, one level down.
#
# `pic10f320` removes its own image before deciding whether to skip, so after the
# loop the image set is either complete (a real build) or empty (every variant
# skipped) -- a PARTIAL set means a variant produced no image while reporting
# success, which is a defect rather than an absent toolchain, and is removed and
# failed rather than skipped.
#
# The sentinel and the skip must live in the SAME shell as the loop: $(SKIP) is
# `exit 0` in non-strict mode and exits only its own shell, so a sentinel on a
# separate recipe line would print regardless -- exactly the trap the `pic10f320`
# recipe above documents.
.PHONY: pic10f320-variants
pic10f320-variants:
	@set -- $(PIC10F320_VARIANTS_SUPPORTED); \
	if [ "$(PIC10F320_VARIANTS_REQUEST_EMPTY)" -eq 1 ]; then \
		echo "FAIL: PIC10F320_VARIANTS_ALL must not be empty"; exit 1; \
	fi; \
	if [ "$(PIC10F320_VARIANTS_REQUEST_DUPLICATE)" -eq 1 ]; then \
		echo "FAIL: PIC10F320_VARIANTS_ALL must not contain duplicate names"; exit 1; \
	fi; \
	if [ "$(PIC10F320_VARIANTS_REQUEST_UNKNOWN)" -eq 1 ]; then \
		echo "FAIL: PIC10F320_VARIANTS_ALL contains unsupported names; supported: $(PIC10F320_VARIANTS_SUPPORTED)"; exit 1; \
	fi; \
	if [ "$(if $(filter-out $(PIC10F320_VARIANTS_ALL),$(PIC10F320_VARIANTS_SUPPORTED)),yes,no)" = yes ]; then \
		echo "FAIL: PIC10F320_VARIANTS_ALL must contain every supported name; required: $(PIC10F320_VARIANTS_SUPPORTED)"; exit 1; \
	fi; \
	$(fw_image_sh); \
	rc=0; \
	for v in "$$@"; do \
		$(MAKE) --no-print-directory PIC10F320_VARIANT=$$v pic10f320 || { rc=1; break; }; \
	done; \
	remove_product_set() { \
		cleanup_rc=0; \
		for v in "$$@"; do \
			stem="$(PIC10F320_BUILD_DIR)/`fw_image_of "$$v" $(PIC10F320_TAG)`"; \
			for path in "$$stem.hex" "$$stem.s" "$$stem.sym"; do \
				if [ -d "$$path" ] && [ ! -L "$$path" ]; then rmdir "$$path"; \
				else rm -f "$$path"; fi || cleanup_rc=1; \
			done; \
		done; \
		return $$cleanup_rc; \
	}; \
	if [ $$rc -ne 0 ]; then \
		echo "FAIL: a PIC10F320 variant did not build; removing the partial image set"; \
		remove_product_set "$$@" \
			|| echo "FAIL: could not completely remove the partial PIC10F320 product set"; \
		exit 1; \
	fi; \
	built=0; \
	for v in "$$@"; do \
		if [ -s "$(PIC10F320_BUILD_DIR)/`fw_image_of "$$v" $(PIC10F320_TAG)`.hex" ]; then \
			built=`expr $$built + 1`; \
		fi; \
	done; \
	if [ $$built -eq 0 ]; then \
		echo "no PIC10F320 images were produced (XC8 absent?); skipping"; $(SKIP); \
	fi; \
	if [ $$built -ne $$# ]; then \
		echo "FAIL: only $$built of $$# PIC10F320 images exist after a reported-successful build; removing the partial image set"; \
		remove_product_set "$$@" \
			|| echo "FAIL: could not completely remove the partial PIC10F320 product set"; \
		exit 1; \
	fi; \
	echo "=== all PIC10F320 variants built within budget ==="

# XC8's full memory-usage summary (program + data space) for one variant.
pic10f320-size: variant-selectors-valid $(PIC10F320_SRC)
	@# One shell, for the same reason as `pic10f320` above: $(SKIP) is `exit 0` in
	@# non-strict mode and would otherwise skip only its own recipe line.
	@mkdir -p "$(PIC10F320_BUILD_DIR)"; \
	probe_stem="$(PIC10F320_BUILD_DIR)/size_probe_$(PIC10F320_VARIANT)"; \
	probe="$$probe_stem.hex"; probe_complete=0; \
	remove_probe() { \
		for path in "$$probe_stem".*; do \
			if [ ! -e "$$path" ] && [ ! -L "$$path" ]; then continue; fi; \
			if [ -d "$$path" ] && [ ! -L "$$path" ]; then \
				rmdir "$$path" || return 1; \
			else \
				rm -f "$$path" || return 1; \
			fi; \
		done; \
	}; \
	remove_probe || exit 1; \
	if [ ! -x "$(PIC10F320_CC)" ] && ! command -v "$(PIC10F320_CC)" >/dev/null 2>&1; then \
		echo "XC8 not found at $(PIC10F320_CC) (override with PIC10F320_CC=...)"; $(SKIP); \
	fi; \
	$(IHEX_VALIDATOR_CHECK); \
	cleanup_probe() { \
		rc=$$?; \
		remove_probe || rc=1; \
		if [ $$rc -eq 0 ] && [ $$probe_complete -ne 1 ]; then rc=1; fi; \
		trap - 0 1 2 15; exit $$rc; \
	}; \
	trap cleanup_probe 0 1 2 15; \
	export PIC_RECIPE_PID=$$$$; \
	out=`cd "$(PIC10F320_BUILD_DIR)" && $(PIC10F320_CC) $(PIC10F320_CFLAGS) $(CURDIR)/$(PIC10F320_SRC) \
		-o "size_probe_$(PIC10F320_VARIANT).hex" 2>&1` \
		|| { printf '%s\n' "$$out"; echo "FAIL: size probe did not compile for PIC10F320"; exit 1; }; \
	if [ ! -s "$$probe" ]; then \
		echo "FAIL: XC8 reported success but did not produce a nonempty $$probe"; \
		printf '%s\n' "$$out"; exit 1; \
	fi; \
	if ! $(IHEX_VALIDATOR) "$$probe"; then \
		echo "FAIL: XC8 produced an invalid Intel HEX size probe: $$probe"; exit 1; \
	fi; \
	if ! printf '%s\n' "$$out" | grep -qE 'Program space'; then \
		echo "FAIL: XC8 output contained no parseable program-space summary:"; \
		printf '%s\n' "$$out"; exit 1; \
	fi; \
	summary=`printf '%s\n' "$$out" | grep -iE 'space|memory summary'`; \
	if [ -z "$$summary" ]; then echo "FAIL: XC8 memory summary was empty"; exit 1; fi; \
	printf '%s\n' "$$summary"; \
	probe_complete=1
	@# The temporary HEX and all XC8 companions are removed by the EXIT trap.
	@# Leaving any size_probe_* artifact can poison release-image set validation.

# Two analyzers over the PIC10F320 shell, parallel to the AVR analyze-cppcheck /
# analyze-misra and the PIC10F322 pic10f322-analyze-*. STANDALONE (XC8/DFP headers may
# be absent in CI; NOT part of `make test`) -- and skip-clean via $(SKIP), so
# STRICT_TOOLS=1 turns a missing toolchain into a hard failure rather than a
# silent pass. Until this lane existed the PIC10F320 shell had no static
# analysis at all.
pic10f320-analyze: pic10f320-analyze-cppcheck pic10f320-analyze-misra
	@echo "=== PIC10F320 static analysis (cppcheck + MISRA) clean ==="

pic10f320-analyze-cppcheck: $(PIC10F320_SRC)
	@if ! command -v $(CPPCHECK) >/dev/null 2>&1; then \
		echo "cppcheck not installed; skipping PIC10F320 cppcheck analysis"; $(SKIP); \
	fi; \
	if [ ! -f "$(PIC10F320_XC8_INCLUDE)/xc.h" ] || [ ! -f "$(PIC10F320_DFP_INCLUDE)/proc/pic10f320.h" ]; then \
		echo "XC8/DFP headers not found; skipping PIC10F320 cppcheck analysis"; $(SKIP); \
	fi; \
	echo "cppcheck (PIC10F320, pic8-enhanced): $(PIC10F320_SRC)"; \
	$(CPPCHECK) $(PIC10F320_CPPCHECK_FLAGS) $(PIC10F320_SRC)

pic10f320-analyze-misra: $(PIC10F320_SRC) $(MISRA_ADDON) $(MISRA_RULES) $(MISRA_SUPPRESS) $(MISRA_OUTPUT_GATE)
	@if ! command -v $(CPPCHECK) >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then \
		echo "cppcheck and/or python3 not available; skipping PIC10F320 MISRA analysis"; $(SKIP); \
	fi; \
	if [ ! -f "$(PIC10F320_XC8_INCLUDE)/xc.h" ] || [ ! -f "$(PIC10F320_DFP_INCLUDE)/proc/pic10f320.h" ]; then \
		echo "XC8/DFP headers not found; skipping PIC10F320 MISRA analysis"; $(SKIP); \
	fi; \
	echo "MISRA-C:2012 analysis -- PIC10F320 shell ($(CPPCHECK) + misra addon, pic8-enhanced)"; \
	out=`mktemp`; rc=0; \
	PYTHONWARNINGS=ignore $(CPPCHECK) $(PIC10F320_MISRA_CPPCHECK_FLAGS) \
		$(MISRA_DIAGNOSTIC_TEMPLATE) --suppressions-list=$(MISRA_SUPPRESS) \
		--error-exitcode=2 $(PIC10F320_SRC) 2>>$$out || rc=$$?; \
	if ! python3 "$(MISRA_OUTPUT_GATE)" --repo-root "$(CURDIR)" \
			--output "$$out" --tool-status "$$rc"; then \
		echo "MISRA findings NOT covered by a documented deviation:"; \
		echo ""; \
		echo "Fix it, or (if genuinely unavoidable) add a per-file entry to"; \
		echo "$(MISRA_SUPPRESS) with a matching record in MISRA_COMPLIANCE.md."; \
		rm -f $$out *.dump *.ctu-info cppcheck-addon-ctu-file-list*; \
		exit 1; \
	fi; \
	rm -f $$out *.dump *.ctu-info cppcheck-addon-ctu-file-list*; \
	echo "MISRA-C:2012 (PIC10F320 shell): clean (documented deviations waived per MISRA_COMPLIANCE.md)"

# --- Phase 4: gpsim / libgpsim target lanes ----------------------------------
# The PIC10F320 counterparts of pic10f322-test-{gpsim,fault,lockstep,io,soak}. These
# run the REAL built HEX in a simulated PIC10F320, so they are the only lanes
# that see the emitted image rather than host-compiled source.
#
# Current FOLD/PARAM/FORK dispositions (merge plan §4 plus post-merge
# reconciliation), each decided from a non-comment diff rather than assumed:
#   FOLD   power_on_pressed.stc     -- executable stimulus byte-identical
#   FOLD   run_gpsim*.sh            -- differed only in the default PROC, and
#                                      they already parameterize on
#                                      PIC_GPSIM_PROC, so the 320 just overrides
#   FOLD   test_soak_pic.cc         -- the parent copy is AHEAD (SOAK_LIVENESS_DUE)
#   PARAM  test_config_pic.c        -- one printf label; now PIC_DEVICE_NAME
#   PARAM  test_{fault,io,lockstep}_pic.cc
#                                   -- thin per-part adapters include shared cores
#                                      in test/pic/; fault policy/counts stay explicit
#   FORK   footswitch_toggle.stc    -- chip-specific gpsim command script
PIC10F320_GPSIM_PROC ?= p10f320
PIC10F320_GPSIM_DIR   = test/pic10f320/gpsim
PIC10F320_GPSIM_TOGGLE_STC := $(PIC10F320_GPSIM_DIR)/footswitch_toggle.stc

# Reuse the parent's C++ toolchain settings; these are environment, not chip.
PIC10F320_SOAK_CXX       ?= $(PIC_SOAK_CXX)
PIC10F320_SOAK_GPSIM_INC ?= $(PIC_SOAK_GPSIM_INC)

PIC10F320_TARGET_VARIANT   ?= $(PIC10F320_VARIANT)
PIC10F320_FAULT_VARIANT    ?= $(PIC10F320_TARGET_VARIANT)
PIC10F320_IO_VARIANT       ?= $(PIC10F320_TARGET_VARIANT)
PIC10F320_LOCKSTEP_VARIANT ?= $(PIC10F320_TARGET_VARIANT)
PIC10F320_SOAK_VARIANT     ?= $(PIC10F320_TARGET_VARIANT)

pic10f320_hex_of = $(PIC10F320_BUILD_DIR)/$(call fw_image,$(1),$(PIC10F320_TAG)).hex

# Per-variant facts, each with a FAILING default rather than a fall-through.
#
# The imported project held all three of these in the same ifeq/else ladder as
# the output macro, ending in $(error) -- so adding a variant could not silently
# inherit another one's expectations. Folding them into nested $(if ...) here
# lost that: an unrecognized name used to resolve to tq2_l2_5v_relay's values (its
# OUTPUT_ macro and its 0x1 settled LATA) and run a green-looking test against
# the wrong contract. The top-level PIC10F320_VARIANT ladder still rejects unknown
# names, but it is NOT the only entry point -- PIC10F320_{FAULT,IO,LOCKSTEP,
# TARGET}_VARIANT can each be set directly on the command line and never pass
# through it.
# The explicit final arm restores the imported behaviour: an unknown variant is a
# hard error at the point of use, not a wrong answer.
#
# $(strip) wraps each one because a backslash-newline inside a variable
# definition collapses to a SPACE: without it these would expand to
# " OUTPUT_TQ2_RELAY" and land in the compile line as "-D OUTPUT_TQ2_RELAY".
pic10f320_macro_of = $(strip \
	$(if $(filter cd4053_simple,$(1)),OUTPUT_CD4053_SIMPLE, \
	$(if $(filter cd4053_with_mute,$(1)),OUTPUT_CD4053_WITH_MUTE, \
	$(if $(filter tq2_l2_5v_relay,$(1)),OUTPUT_TQ2_RELAY, \
	$(error pic10f320_macro_of: no output macro for PIC10F320 variant '$(1)'; supported: $(PIC10F320_VARIANTS_SUPPORTED))))))

# The full RA0..RA2 LATA each variant drives once settled, asserted by the gpsim
# register-level test. RA0 (the LED) is bit 0 in all three. BYPASS settles to 0x0
# for every variant today, but it is answered per variant rather than assumed,
# for the same reason as above.
pic10f320_engaged_lata_of = $(strip \
	$(if $(filter cd4053_simple,$(1)),0x3, \
	$(if $(filter cd4053_with_mute,$(1)),0x7, \
	$(if $(filter tq2_l2_5v_relay,$(1)),0x1, \
	$(error pic10f320_engaged_lata_of: no settled ENGAGED LATA for PIC10F320 variant '$(1)'; supported: $(PIC10F320_VARIANTS_SUPPORTED))))))
pic10f320_bypass_lata_of = $(strip \
	$(if $(filter $(PIC10F320_VARIANTS_SUPPORTED),$(1)),0x0, \
	$(error pic10f320_bypass_lata_of: no settled BYPASS LATA for PIC10F320 variant '$(1)'; supported: $(PIC10F320_VARIANTS_SUPPORTED))))

PIC10F320_FAULT_SRC = $(PIC10F320_GPSIM_DIR)/test_fault_pic.cc
PIC10F320_FAULT_BIN = $(PIC10F320_BUILD_DIR)/test_fault_pic
PIC10F320_FAULT_HEX = $(call pic10f320_hex_of,$(PIC10F320_FAULT_VARIANT))
PIC10F320_FAULT_SYM = $(PIC10F320_FAULT_HEX:.hex=.sym)
# _ctx_'s SRAM address from the XC8 .sym, so the harness self-adjusts per variant
# instead of hard-coding it. Empty when the .sym is absent; the run recipe fails
# rather than silently dropping the ctx_ cases.
PIC10F320_FAULT_CTX_DEF = $(shell a=$$(awk '$$1=="_ctx_"{print $$2; exit}' $(PIC10F320_FAULT_SYM) 2>/dev/null); [ -n "$$a" ] && echo -DCTX_ADDR=0x$$a)
PIC10F320_FAULT_COMPILE = $(PIC10F320_SOAK_CXX) -std=c++17 -O2 $$(pkg-config --cflags glib-2.0) \
		-isystem $(PIC10F320_SOAK_GPSIM_INC) -Itest \
		-DFW_PATH='"$(CURDIR)/$(PIC10F320_FAULT_HEX)"' -DPROC_NAME='"$(PIC10F320_GPSIM_PROC)"' \
		-DF_CPU_HZ=$(PIC10F320_XTAL) -D$(call pic10f320_macro_of,$(PIC10F320_FAULT_VARIANT)) \
		$(PIC10F320_FAULT_CTX_DEF) $(PIC10F320_FAULT_SRC) -o $(PIC10F320_FAULT_BIN) -lgpsim
$(PIC10F320_FAULT_BIN): $(PIC10F320_FAULT_SRC) $(PIC_TARGET_FAULT_CORE_HDR) $(PIC_TARGET_RESULT_HDR)

PIC10F320_IO_SRC = $(PIC10F320_GPSIM_DIR)/test_io_pic.cc
PIC10F320_IO_BIN = $(PIC10F320_BUILD_DIR)/test_io_pic
PIC10F320_IO_HEX = $(call pic10f320_hex_of,$(PIC10F320_IO_VARIANT))
PIC10F320_IO_COMPILE = $(PIC10F320_SOAK_CXX) -std=c++17 -O2 $$(pkg-config --cflags glib-2.0) \
		-isystem $(PIC10F320_SOAK_GPSIM_INC) -Itest \
		-DFW_PATH='"$(CURDIR)/$(PIC10F320_IO_HEX)"' -DPROC_NAME='"$(PIC10F320_GPSIM_PROC)"' \
		-DF_CPU_HZ=$(PIC10F320_XTAL) -D$(call pic10f320_macro_of,$(PIC10F320_IO_VARIANT)) \
		$(PIC10F320_IO_SRC) -o $(PIC10F320_IO_BIN) -lgpsim
$(PIC10F320_IO_BIN): $(PIC10F320_IO_SRC) $(PIC_TARGET_IO_CORE_HDR) $(PIC_TARGET_RESULT_HDR)

PIC10F320_LOCKSTEP_SRC = $(PIC10F320_GPSIM_DIR)/test_lockstep_pic.cc
PIC10F320_LOCKSTEP_BIN = $(PIC10F320_BUILD_DIR)/test_lockstep_pic
PIC10F320_LOCKSTEP_HEX = $(call pic10f320_hex_of,$(PIC10F320_LOCKSTEP_VARIANT))
PIC10F320_LOCKSTEP_SYM = $(PIC10F320_LOCKSTEP_HEX:.hex=.sym)
# Lock-step compares the running image's ctx_ against the SHARED verified core,
# so it links src/bypass_pure.c -- never a vendored copy (Principle 2).
PIC10F320_LOCKSTEP_MODEL_OBJ = $(PIC10F320_BUILD_DIR)/bypass_pure_lockstep.o
PIC10F320_LOCKSTEP_CTX_DEF = $(shell a=$$(awk '$$1=="_ctx_"{print $$2; exit}' $(PIC10F320_LOCKSTEP_SYM) 2>/dev/null); [ -n "$$a" ] && echo -DCTX_ADDR=0x$$a)
PIC10F320_LOCKSTEP_COMPILE = \
		$(HOSTCC) $(PURE_HOST_CFLAGS) -std=c11 -O2 -Itest -c $(PURE_HOST_SRC) \
			-o $(PIC10F320_LOCKSTEP_MODEL_OBJ) && \
		$(PIC10F320_SOAK_CXX) -std=c++17 -O2 $$(pkg-config --cflags glib-2.0) \
			-isystem $(PIC10F320_SOAK_GPSIM_INC) -Itest -Isrc \
			-DFW_PATH='"$(CURDIR)/$(PIC10F320_LOCKSTEP_HEX)"' -DPROC_NAME='"$(PIC10F320_GPSIM_PROC)"' \
			-DF_CPU_HZ=$(PIC10F320_XTAL) -D$(call pic10f320_macro_of,$(PIC10F320_LOCKSTEP_VARIANT)) \
			$(PIC10F320_LOCKSTEP_CTX_DEF) \
			$(PIC10F320_LOCKSTEP_SRC) $(PIC10F320_LOCKSTEP_MODEL_OBJ) \
			-o $(PIC10F320_LOCKSTEP_BIN) -lgpsim
$(PIC10F320_LOCKSTEP_BIN): $(PIC10F320_LOCKSTEP_SRC) $(PIC_TARGET_LOCKSTEP_CORE_HDR) $(PIC_TARGET_RESULT_HDR)

.PHONY: pic10f320-test-build pic10f320-test-config pic10f320-test-gpsim pic10f320-test-fault-target \
        pic10f320-test-io pic10f320-test-lockstep pic10f320-test-target \
        pic10f320-test-target-variants _pic10f320-build-fault-target \
        _pic10f320-build-io _pic10f320-build-lockstep _pic10f320-build-soak \
        pic10f320-test-return-stack

# Rebuild and compare the complete three-image matrix with the reviewed baseline.
# Keep this separate from `pic10f320`: mutation targets must reach their intended
# behavioural oracle rather than being killed incidentally by this broad byte
# check. CI and release qualification run it through the `pic10f320-test` aggregate.
pic10f320-test-build: pic10f320-variants
	@if ! command -v python3 >/dev/null 2>&1; then \
		echo "FAIL: python3 is required by the PIC10F320 expected-image gate"; exit 1; \
	fi
	@if [ ! -f "$(PIC10F320_EXPECTED_IMAGE_CHECKER)" ] || \
	    [ -L "$(PIC10F320_EXPECTED_IMAGE_CHECKER)" ] || \
	    [ ! -s "$(PIC10F320_EXPECTED_IMAGE_CHECKER)" ]; then \
		echo "FAIL: PIC10F320 expected-image checker is missing or invalid: $(PIC10F320_EXPECTED_IMAGE_CHECKER)"; \
		exit 1; \
	fi
	@python3 $(PIC10F320_EXPECTED_IMAGE_CHECKER) --require-all \
		$(PIC10F320_EXPECTED_IMAGE_MANIFEST) $(PIC10F320_EXPECTED_IMAGE_PATHS) || { \
		echo "FAIL: PIC10F320 image bytes differ from the reviewed XC8/DFP baseline."; \
		echo "      Investigate the source, flags, compiler, and DFP; do not reflexively rebaseline."; \
		exit 1; \
	}
	@echo "=== PIC10F320 expected-image hashes match all three variants ==="

# Rebuild the complete image matrix (each pic10f320 recipe checks its own output),
# then re-run one explicit reporting pass over all three final HEX paths. Unlike
# optional simulator lanes, this gate never skips: missing Python or any named
# image is a failure. The oracle itself also rejects links, non-regular/empty
# images, HEX defects, holes, non-regular control flow, recursion, and interrupts.
pic10f320-test-return-stack: pic10f320-variants test-pic10f320-return-stack-oracle
	@if ! command -v python3 >/dev/null 2>&1; then \
		echo "FAIL: python3 is required by the PIC10F320 return-stack gate"; exit 1; \
	fi; \
	for image in $(PIC10F320_RETURN_STACK_IMAGES); do \
		if [ ! -f "$$image" ] || [ -L "$$image" ] || [ ! -s "$$image" ]; then \
			echo "FAIL: required PIC10F320 return-stack image is missing or invalid: $$image"; \
			exit 1; \
		fi; \
	done
	@python3 $(PIC10F320_RETURN_STACK_ORACLE) --limit "$(PIC10F320_RETURN_STACK_LIMIT)" \
		$(PIC10F320_RETURN_STACK_IMAGES)

# Emitted CONFIG word, from the built HEX. Uses the SHARED checker with a
# device-accurate label (§4's FOLD/PARAMETERIZE), run over every built image.
#
# The no-image guard mirrors pic10f322-test-config's. Without it this recipe passed an
# UNEXPANDED glob to the checker when XC8 was absent, which reported "cannot open
# HEX file '.../bypass-pic10f320-*.hex'" and failed -- so `make pic10f320-test`
# died on a host where `make pic10f322-test` skipped cleanly, contradicting the
# skip-clean contract stated at `pic10f320-test` below. One shell, because $(SKIP)
# exits only its own.
pic10f320-test-config: pic10f320-variants
	@mkdir -p $(PIC10F320_BUILD_DIR) || exit 1; \
	hexes=`ls $(PIC10F320_BUILD_DIR)/$(FW_BASE)-$(PIC10F320_TAG)-*.hex 2>/dev/null`; \
	if [ -z "$$hexes" ]; then \
		echo "no PIC10F320 HEX in $(PIC10F320_BUILD_DIR)/ (XC8 absent?); skipping CONFIG-word check"; \
		$(SKIP); \
	fi; \
	$(HOSTCC) $(HOST_CFLAGS) -Itest -DPIC_DEVICE_NAME='"PIC10F320"' \
		test/pic/test_config_pic.c -o $(PIC10F320_BUILD_DIR)/test_config_pic || exit 1; \
	$(PIC10F320_BUILD_DIR)/test_config_pic $$hexes

# CLI gpsim: drive the footswitch, assert PORTA/LATA transitions. Reuses the
# parent's hardened wrappers (timeout + nonzero status are never discarded) and
# the shared preflight above, so this lane and the PIC10F322's agree on when a
# missing gpsim is a skip and when it is a failure.
#
# Single image, unlike the 322's loop: `pic10f320` builds exactly ONE variant,
# selected by PIC10F320_VARIANT, and `pic10f320-test` sweeps the matrix by re-invoking
# this target per variant.
#
# GPSIM is threaded through explicitly. Without it the wrappers fall back to
# their own `${GPSIM:-gpsim}` default, so a `make ... GPSIM=<other>` override was
# silently ignored on this chip and the lane tested whatever gpsim was on PATH.
#
# PIC_GPSIM_PROC is the other half of that, and the more dangerous one to lose.
# The shared wrappers fall back to p10f322, so a severed prefix here does not
# fail the lane -- it runs this chip's HEX on the OTHER chip's device model and
# reports PASS, because the 322 is a superset. That happened once, in v0.9.8,
# when the wrapper's read was renamed and these prefixes were not.
# test/test_gpsim_wrappers.sh now records the -p argument this target actually
# reaches gpsim with, so the link is checked rather than assumed.
#
# PIC_GPSIM_STC is what makes the SHARED wrappers correct for this chip: the
# toggle cadence checkpoint differs, so without the override this lane drove the
# PIC10F320 through the PIC10F322's stimulus. The power-on-pressed stimulus is
# deliberately NOT overridden -- that file is byte-identical for both parts.
#
# STRICT_TOOLS is forwarded as well as probed. The Make-level preflight decides
# skip-vs-fail before the wrappers run; forwarding keeps the wrappers' own strict
# path consistent when they are reached, exactly as the PIC10F322 lane does.
pic10f320-test-gpsim: variant-selectors-valid pic10f320 $(PIC10F32X_GPSIM_REGS)
	@$(call gpsim_wrapper_preflight,PIC10F320); \
	if [ ! -f "$(PIC10F320_HEX)" ]; then \
		echo "no $(PIC10F320_HEX) (XC8 absent?); skipping PIC10F320 gpsim test"; $(SKIP); \
	fi; \
	fail=0; \
	echo "--- gpsim register-level test: PIC10F320 variant $(PIC10F320_VARIANT) ---"; \
	GPSIM=$(GPSIM) PIC_GPSIM_PROC=$(PIC10F320_GPSIM_PROC) \
		PIC_GPSIM_STC="$(CURDIR)/$(PIC10F320_GPSIM_TOGGLE_STC)" \
		STRICT_TOOLS="$(STRICT_TOOLS)" \
		test/pic/run_gpsim_test.sh $(PIC10F320_HEX) \
		$(call pic10f320_engaged_lata_of,$(PIC10F320_VARIANT)) \
		$(call pic10f320_bypass_lata_of,$(PIC10F320_VARIANT)) || fail=1; \
	GPSIM=$(GPSIM) PIC_GPSIM_PROC=$(PIC10F320_GPSIM_PROC) \
		STRICT_TOOLS="$(STRICT_TOOLS)" \
		test/pic/run_gpsim_power_on_pressed.sh $(PIC10F320_HEX) || fail=1; \
	exit $$fail

# Aggregate: every PIC10F320 pre-hardware check -- host equivalence, actuation,
# host fault, firmware coverage, build+budget, expected-image hashes, CONFIG word,
# final-HEX return-stack proof, static analysis and the CLI-gpsim register-level
# test. The PIC10F320 counterpart of `pic10f322-test`, and the single target the CI
# `pic` job -- which covers all three PIC targets -- invokes for this chip (merge plan
# §11, D3).
#
# It sweeps all three variants, because the per-variant lanes are per-variant for
# real reasons and not one of them is representative:
#   - pic10f320-analyze compiles ONE output stage's #ifdef branch, so analyzing only
#     the default variant leaves the mute and relay code paths -- roughly a fifth
#     of the shipping source -- with no cppcheck or MISRA coverage at all;
#   - pic10f320-test-gpsim asserts a variant-specific settled LATA pattern.
# The other four lanes already cover the matrix on their own
# (pic10f320-test-build, pic10f320-test-config and pic10f320-test-return-stack check every
# built image in one run; pic10f320-test-host-variants does its own sweep), so they
# are prerequisites rather than loop bodies.
#
# The matrix guard is NOT repeated here, and that is deliberate rather than an
# omission: pic10f320-test-host-variants is a prerequisite, it carries the guard, and
# Make will not start this recipe until it has succeeded. So an empty, duplicated,
# unsupported, or incomplete PIC10F320_VARIANTS_ALL fails before the loop below is
# reached, and the guard that protects this target is the one covered by
# test/test_target_matrix.sh (§6.5). A second copy here would be untested
# duplication, since the harness cannot drive a target whose prerequisites
# themselves do real work.
#
# STANDALONE -- deliberately NOT part of `make test`, which is the
# tool-independent gate (XC8/gpsim may be absent in CI). Optional simulator and
# analyzer sub-targets skip cleanly when their tools are missing, which is why CI
# passes STRICT_TOOLS=1. The expected-image and return-stack prerequisites always
# fail closed when XC8, Python, their contracts, or rebuilt images are absent.
PIC10F320_PER_VARIANT_LANES := pic10f320-analyze pic10f320-test-gpsim

.PHONY: pic10f320-test
# Two independent witnesses on the same 8-level stack, kept deliberately: the
# -stack-bound gate walks XC8's emitted call graph and enforces the policy
# budget (peak + reserve), the -return-stack oracle re-derives the depth from
# the shipped HEX. A disagreement between them is itself the signal.
pic10f320-test: pic10f320-test-host-variants pic10f320-test-build pic10f320-test-config \
             pic10f320-test-stack-bound pic10f320-test-return-stack
	@for v in $(PIC10F320_VARIANTS_ALL); do \
		echo "===================== PIC10F320 ANALYSIS/GPSIM VARIANT $$v ====================="; \
		$(MAKE) --no-print-directory PIC10F320_VARIANT=$$v $(PIC10F320_PER_VARIANT_LANES) || exit 1; \
	done
	@echo "=== all PIC10F320 pre-hardware checks complete ==="

# Lane selectors are distinct from PIC10F320_VARIANT. Re-enter Make with the
# selected value so all simply-expanded build paths, flags and output macros are
# recomputed together; target-specific variables are too late for those `:=`
# definitions and can produce a selected label on a default-variant image.
_pic10f320-build-fault-target: variant-selectors-valid
	@$(MAKE) --no-print-directory PIC10F320_VARIANT=$(PIC10F320_FAULT_VARIANT) pic10f320

_pic10f320-build-io: variant-selectors-valid
	@$(MAKE) --no-print-directory PIC10F320_VARIANT=$(PIC10F320_IO_VARIANT) pic10f320

_pic10f320-build-lockstep: variant-selectors-valid
	@$(MAKE) --no-print-directory PIC10F320_VARIANT=$(PIC10F320_LOCKSTEP_VARIANT) pic10f320

_pic10f320-build-soak: variant-selectors-valid
	@$(MAKE) --no-print-directory PIC10F320_VARIANT=$(PIC10F320_SOAK_VARIANT) pic10f320

pic10f320-test-fault-target: variant-selectors-valid _pic10f320-build-fault-target
	@if ! command -v $(PIC10F320_SOAK_CXX) >/dev/null 2>&1; then \
		echo "no C++ compiler ($(PIC10F320_SOAK_CXX)); skipping PIC10F320 target fault-inject"; $(SKIP); \
	fi; \
	if [ ! -f "$(PIC10F320_SOAK_GPSIM_INC)/sim_context.h" ]; then \
		echo "gpsim-dev headers not at $(PIC10F320_SOAK_GPSIM_INC); skipping (install gpsim-dev)"; $(SKIP); \
	fi; \
	if ! pkg-config --exists glib-2.0 2>/dev/null; then \
		echo "libglib2.0-dev not found; skipping PIC10F320 target fault-inject"; $(SKIP); \
	fi; \
	if [ ! -f "$(PIC10F320_FAULT_HEX)" ]; then \
		echo "no $(PIC10F320_FAULT_HEX) (XC8 absent?); skipping"; $(SKIP); \
	fi; \
	s="$(PIC10F320_FAULT_HEX:.hex=.s)"; \
	alloc=`awk 'prev=="_ctx_:"{print $$2; exit} {prev=$$1}' "$$s" 2>/dev/null`; \
	if [ "$$alloc" != "3" ]; then \
		echo "FAIL: _ctx_ allocates $${alloc:-?} bytes in $$s -- expected 3 (packed 1-byte enums)."; \
		echo "      The harness injects at ctx_+0/+1/+2; XC8's code generator has"; \
		echo "      stopped packing enums to 1 byte. Fix the offsets before running."; \
		exit 1; \
	fi; \
	if [ -z "$(PIC10F320_FAULT_CTX_DEF)" ]; then \
		echo "FAIL: could not resolve _ctx_ from $(PIC10F320_FAULT_SYM); refusing to run with the SRAM cases omitted"; exit 1; \
	fi; \
	$(PIC10F320_FAULT_COMPILE) && $(PIC10F320_FAULT_BIN)

pic10f320-test-io: variant-selectors-valid _pic10f320-build-io
	@if ! command -v $(PIC10F320_SOAK_CXX) >/dev/null 2>&1 \
	   || [ ! -f "$(PIC10F320_SOAK_GPSIM_INC)/sim_context.h" ] \
	   || ! pkg-config --exists glib-2.0 2>/dev/null; then \
		echo "C++/gpsim-dev/glib not available; skipping PIC10F320 target I/O"; $(SKIP); \
	fi; \
	if [ ! -f "$(PIC10F320_IO_HEX)" ]; then \
		echo "no $(PIC10F320_IO_HEX) (XC8 absent?); skipping"; $(SKIP); \
	fi; \
	$(PIC10F320_IO_COMPILE) && $(PIC10F320_IO_BIN)

pic10f320-test-lockstep: variant-selectors-valid _pic10f320-build-lockstep
	@if ! command -v $(PIC10F320_SOAK_CXX) >/dev/null 2>&1 \
	   || [ ! -f "$(PIC10F320_SOAK_GPSIM_INC)/sim_context.h" ] \
	   || ! pkg-config --exists glib-2.0 2>/dev/null; then \
		echo "C++/gpsim-dev/glib not available; skipping PIC10F320 lock-step"; $(SKIP); \
	fi; \
	if [ ! -f "$(PIC10F320_LOCKSTEP_HEX)" ]; then \
		echo "no $(PIC10F320_LOCKSTEP_HEX) (XC8 absent?); skipping"; $(SKIP); \
	fi; \
	if [ -z "$(PIC10F320_LOCKSTEP_CTX_DEF)" ]; then \
		echo "FAIL: could not resolve _ctx_ from $(PIC10F320_LOCKSTEP_SYM); refusing to run blind"; exit 1; \
	fi; \
	$(PIC10F320_LOCKSTEP_COMPILE) && $(PIC10F320_LOCKSTEP_BIN)

# All-variant HOST fault aggregate -- the PIC10F320 analogue of the child's
# test-fault-variants, and the kill target for most of its firmware mutants.
# Rejects an empty or duplicated matrix first, so "all variants passed" can never
# mean "no variant ran".
.PHONY: pic10f320-test-fault-variants
pic10f320-test-fault-variants:
	@set -- $(PIC10F320_VARIANTS_SUPPORTED); \
	if [ "$(PIC10F320_VARIANTS_REQUEST_EMPTY)" -eq 1 ]; then \
		echo "FAIL: PIC10F320_VARIANTS_ALL must not be empty"; exit 1; \
	fi; \
	if [ "$(PIC10F320_VARIANTS_REQUEST_DUPLICATE)" -eq 1 ]; then \
		echo "FAIL: PIC10F320_VARIANTS_ALL must not contain duplicate names"; exit 1; \
	fi; \
	if [ "$(PIC10F320_VARIANTS_REQUEST_UNKNOWN)" -eq 1 ]; then \
		echo "FAIL: PIC10F320_VARIANTS_ALL contains unsupported names; supported: $(PIC10F320_VARIANTS_SUPPORTED)"; exit 1; \
	fi; \
	if [ "$(if $(filter-out $(PIC10F320_VARIANTS_ALL),$(PIC10F320_VARIANTS_SUPPORTED)),yes,no)" = yes ]; then \
		echo "FAIL: PIC10F320_VARIANTS_ALL must contain every supported name; required: $(PIC10F320_VARIANTS_SUPPORTED)"; exit 1; \
	fi; \
	for v in "$$@"; do \
		echo "===================== FAULT VARIANT $$v ====================="; \
		$(MAKE) --no-print-directory PIC10F320_VARIANT=$$v pic10f320-test-fault-host || exit 1; \
	done
	@echo "=== all PIC10F320 host fault variants validated ==="

# Fail-closed target aggregate for ONE variant, and the emphasis on "fail-closed"
# is the whole point of the shape below.
#
# This used to be a plain prerequisite list -- `pic10f320-test-target: <the three
# lanes>` plus an unconditional success echo. That is NOT fail-closed, because
# every one of those lanes exits 0 through $(SKIP) when its tool is missing (the
# documented skip-clean contract for the individual development commands). So on
# a host with XC8 but without gpsim-dev/glib -- an ordinary development box --
# the aggregate printed "target lanes passed" for all three variants having run
# ZERO checks, while the PIC10F322 counterpart failed loudly on the same host.
#
# Requiring each lane's explicit PASS marker is what closes it: a skip, a missing
# ctx_ symbol, a partial run or a crashed simulator all fail here instead of
# masquerading as green. The shared harness cores for all three chips print the
# same markers (test/pic/test_{fault,lockstep,io}_pic_core.h emit
# "<LANE> %s: %u checks" with PASS/FAIL), so this is the PIC10F322 driver at
# `pic10f322-test-target` above, verbatim in structure, with the PIC10F320_ names.
#
# PIC10F320_VARIANT is threaded down alongside each lane's own variable because
# `pic10f320` (the build prerequisite of all three lanes) builds exactly ONE image,
# selected by PIC10F320_VARIANT -- unlike the 322's `pic10f322`, which builds the whole
# matrix. Without it, `make pic10f320-test-target PIC10F320_TARGET_VARIANT=tq2_l2_5v_relay`
# would build cd4053_simple and then fail looking for the tq2_l2_5v_relay image.
pic10f320-test-target: variant-selectors-valid
	@set -e; \
	for spec in \
		"pic10f320-test-fault-target PIC10F320_FAULT_VARIANT=$(PIC10F320_TARGET_VARIANT)|FAULT-INJECT PASS" \
		"pic10f320-test-lockstep PIC10F320_LOCKSTEP_VARIANT=$(PIC10F320_TARGET_VARIANT)|LOCK-STEP PASS" \
		"pic10f320-test-io PIC10F320_IO_VARIANT=$(PIC10F320_TARGET_VARIANT)|TARGET-IO PASS"; do \
		target=$${spec%%|*}; marker=$${spec#*|}; log=`mktemp`; \
		if ! $(MAKE) --no-print-directory PIC10F320_VARIANT=$(PIC10F320_TARGET_VARIANT) \
				$$target >$$log 2>&1; then \
			cat $$log; rm -f $$log; exit 1; \
		fi; \
		cat $$log; \
		if ! grep -q "$$marker" $$log; then \
			echo "FAIL: $$target did not report '$$marker' (skipped or incomplete?)"; \
			rm -f $$log; exit 1; \
		fi; \
		rm -f $$log; \
	done
	@echo "=== PIC10F320 target fault/lock-step/I-O PASS (variant $(PIC10F320_TARGET_VARIANT)) ==="

# ...and for ALL of them. Requires the exact supported set before running, so
# "all variants passed" cannot hide an empty or incomplete matrix (§6.5).
pic10f320-test-target-variants:
	@if [ "$(PIC10F320_VARIANTS_REQUEST_EMPTY)" -eq 1 ]; then \
		echo "FAIL: PIC10F320_VARIANTS_ALL must not be empty" >&2; exit 2; \
	fi; \
	if [ "$(PIC10F320_VARIANTS_REQUEST_DUPLICATE)" -eq 1 ]; then \
		echo "FAIL: PIC10F320_VARIANTS_ALL must not contain duplicate names" >&2; exit 2; \
	fi; \
	if [ "$(PIC10F320_VARIANTS_REQUEST_UNKNOWN)" -eq 1 ]; then \
		echo "FAIL: PIC10F320_VARIANTS_ALL contains unsupported names; supported: $(PIC10F320_VARIANTS_SUPPORTED)" >&2; exit 2; \
	fi; \
	if [ "$(if $(filter-out $(PIC10F320_VARIANTS_ALL),$(PIC10F320_VARIANTS_SUPPORTED)),yes,no)" = yes ]; then \
		echo "FAIL: PIC10F320_VARIANTS_ALL must contain every supported name; required: $(PIC10F320_VARIANTS_SUPPORTED)" >&2; exit 2; \
	fi
	@for v in $(PIC10F320_VARIANTS_SUPPORTED); do \
		echo "===================== PIC10F320 TARGET VARIANT $$v ====================="; \
		$(MAKE) --no-print-directory PIC10F320_TARGET_VARIANT=$$v PIC10F320_VARIANT=$$v \
			pic10f320-test-target || exit 1; \
	done
	@echo "=== PIC10F320 target fault/lock-step/I-O validated for all variants ==="

# --- Phase 4: long-duration soak (libgpsim) ----------------------------------
# Reuses the PARENT's soak driver and timing contract verbatim (§4: the parent
# copy is ahead -- it carries SOAK_LIVENESS_DUE() and the "liveness deadline must
# fire at equality" static assert the child lacked). Only the chip, image,
# processor and per-variant blocking-actuation duration differ.
#
# Blocking actuation per variant, in ms: a relay coil pulse or CD4053 mute
# busy-blocks the POLLED main loop and steals that many 1 ms debounce ticks, so
# the soak must hold each press/release correspondingly longer. Mirrors the
# firmware's TQ2_L2_5V_PULSE_MS (12) and CD4053_MUTE_DELAY_MS (5).
pic10f320_soak_block_cd4053_simple = 0
pic10f320_soak_block_cd4053_with_mute   = 5
pic10f320_soak_block_tq2_l2_5v_relay     = 12

PIC10F320_SOAK_DURATION_MS          ?= 3600000
PIC10F320_SOAK_LIVENESS_INTERVAL_MS ?= 60000
PIC10F320_SOAK_PROGRESS_INTERVAL_MS ?= 3600000
PIC10F320_SOAK_COMBINATION_NAME     ?= standalone
PIC10F320_SOAK_SRC  = $(PIC_SOAK_SRC)
PIC10F320_SOAK_DEPS = $(PIC10F320_SOAK_SRC) $(PIC_TARGET_SOAK_CORE_HDR) \
                   $(PIC10F32X_REGS_HDR) $(PIC_PIN_LOOKUP_HDR) \
                   $(PIC_GPSIM_BOOTSTRAP_HDR) $(PIC_SOAK_SAMPLING_HDR) \
                   $(PIC_SOAK_HOLD_TIMING_HDR) test/soak_timing_config.h
PIC10F320_SOAK_BIN  = $(PIC10F320_BUILD_DIR)/test_soak_pic
PIC10F320_SOAK_HEX  = $(call pic10f320_hex_of,$(PIC10F320_SOAK_VARIANT))

PIC10F320_SOAK_COMPILE = $(PIC10F320_SOAK_CXX) -std=c++17 -O2 $$(pkg-config --cflags glib-2.0) \
		-isystem $(PIC10F320_SOAK_GPSIM_INC) -Itest -Isrc \
		-DFW_PATH='"$(CURDIR)/$(PIC10F320_SOAK_HEX)"' -DPROC_NAME='"$(PIC10F320_GPSIM_PROC)"' \
		-DF_CPU_HZ=$(PIC10F320_XTAL) \
		-DSOAK_DURATION_MS=$(PIC10F320_SOAK_DURATION_MS) \
		-DSOAK_LIVENESS_INTERVAL_MS=$(PIC10F320_SOAK_LIVENESS_INTERVAL_MS) \
		-DSOAK_PROGRESS_INTERVAL_MS=$(PIC10F320_SOAK_PROGRESS_INTERVAL_MS) \
		-DSOAK_COMBINATION_NAME='"$(PIC10F320_SOAK_COMBINATION_NAME)"' \
		-DSOAK_ACTUATION_BLOCK_MS=$(pic10f320_soak_block_$(PIC10F320_SOAK_VARIANT))u \
		$(PIC10F320_SOAK_SRC) -o $(PIC10F320_SOAK_BIN) -lgpsim

# Build-only convenience rule, the exact analogue of the PIC10F322
# $(PIC10F322_SOAK_BIN) rule: compile the soak driver for the selected
# PIC10F320_SOAK_VARIANT to PIC10F320_SOAK_BIN WITHOUT running it.
# scripts/make-release.sh needs this -- it builds one binary per variant under
# unique PIC10F320_SOAK_BIN names and then runs all release soak combos
# concurrently, which it cannot do through the pic10f320-test-soak run target.
# FORCE -- see the PIC10F322 rule above; the same command-line-variable
# staleness was measured here first (merge plan §6.12's rebuild-determinism row).
$(PIC10F320_SOAK_BIN): $(PIC10F320_SOAK_DEPS) FORCE
	$(PIC10F320_SOAK_COMPILE)

.PHONY: pic10f320-test-soak
pic10f320-test-soak: variant-selectors-valid _pic10f320-build-soak
	@if ! command -v $(PIC10F320_SOAK_CXX) >/dev/null 2>&1 \
	   || [ ! -f "$(PIC10F320_SOAK_GPSIM_INC)/sim_context.h" ] \
	   || ! pkg-config --exists glib-2.0 2>/dev/null; then \
		echo "C++/gpsim-dev/glib not available; skipping PIC10F320 soak"; $(SKIP); \
	fi; \
	if [ ! -f "$(PIC10F320_SOAK_HEX)" ]; then \
		echo "no $(PIC10F320_SOAK_HEX) (XC8 absent?); skipping PIC10F320 soak"; $(SKIP); \
	fi; \
	echo "--- PIC10F320 soak: variant=$(PIC10F320_SOAK_VARIANT) proc=$(PIC10F320_GPSIM_PROC) duration=$(PIC10F320_SOAK_DURATION_MS) ms ---"; \
	rm -f $(PIC10F320_SOAK_BIN) && \
	$(PIC10F320_SOAK_COMPILE) && \
	./$(PIC10F320_SOAK_BIN)

# --- §6.13 byte-identity gate ------------------------------------------------
# This began as a one-shot MIGRATION gate (merge plan §15, D4). It ran twice,
# exactly as §6.13 required:
#
#   Phase 2, vs the child project's signed release/v0.9.5 images -- PASSED 3/3.
#     Proved the relocated firmware, built by the ported recipe under new
#     variable names in a different Makefile, emitted the child's exact bytes.
#   Phase 4, vs the hashes the §6.11 exact-TRISA edit rebaselined to -- PASSED
#     3/3, with the HARDENED build rule (budget gate, IHEX validation, cleanup
#     traps), proving that hardening changed no emitted bytes either.
#
# Both historical hash sets remain recorded in the merge plan and validation
# record. The post-audit standing gate moves the reviewed final set into
# test/pic10f320/expected_images.sha256, where Phase 7 cannot delete it, and
# `pic10f320-test-build` enforces it through CI/release qualification. This is the
# byte-level witness for hardware-integrity changes the differential lanes cannot
# see; rebaselining must be an explicit reviewed firmware/toolchain change.

# --- cleanup -----------------------------------------------------------------
# §5.7: scoped to PIC10F320 paths ONLY. The imported child recipe did
# `rm -rf $(COVERAGE_DIR)` on the SHARED top-level coverage/, which would have
# deleted the parent's coverage report and any concurrent gate working directory.
# Every destructive path below is under $(PIC10F320_BUILD_DIR).
pic10f320-clean:
	rm -rf $(PIC10F320_BUILD_DIR)

# ============================================================================
# BUILD -- PIC12F675 (Microchip XC8) cross-build
# ============================================================================
#
# The CLASSIC mid-range PIC. Same toolchain as the PIC10F32x lanes (one XC8, one
# device pack), a different silicon generation: no LATx, no TMR2, no OSCCON, no
# WDTCON, a second register bank, and a 1024-word flash that is twice the
# PIC10F322's. That last fact is why this part builds the MODULAR architecture
# -- the shipping pure core plus an unmodified output driver, exactly like the
# PIC10F322 and unlike the hand-inlined PIC10F320.
#
# `make pic12f675` builds every variant and gates each on the device's
# 1024-word flash and reviewed 48-byte data-space budgets. STANDALONE, like its
# PIC10F322 sibling: deliberately not part of `make test`, and it skips cleanly
# when XC8 is absent.
#
# NAMING follows the rule stated in the PIC10F322 section: a PIC_* name with no
# part in it is shared by every PIC part; anything whose VALUE is a property of
# this chip is spelled PIC12F675_*. Two values here are the ones that must never
# be inherited from a sibling, because a wrong one produces a PASSING test
# rather than a failing one: PIC12F675_FLASH_WORDS (1024, not 512), the immutable
# 64-byte data capacity, and PIC12F675_XTAL (4 MHz fixed INTOSC, not the 322's
# 2 MHz).
#
# THE UL SUFFIX ON PIC12F675_XTAL IS LOAD-BEARING. _XTAL_FREQ reaches the shell's
# static_assert(_XTAL_FREQ == 4000000UL, ...); a bare 4000000 is essentially
# signed, so the comparison mixes essential type categories and trips MISRA
# Rule 10.4 in pic12f675-analyze-misra. PIC10F322_XTAL carries the same suffix
# for the same reason.

override PIC12F675_CHIP := 12F675
PIC12F675_TAG   ?= pic12f675
PIC12F675_XTAL  ?= 4000000UL
PIC12F675_BUILD_DIR ?= build_pic12f675
override PIC12F675_HEXES := $(foreach v,$(CLASSIC_VARIANTS_SUPPORTED),$(PIC12F675_BUILD_DIR)/$(call fw_image,$(v),$(PIC12F675_TAG)).hex)
override PIC12F675_ASSEMBLIES := $(PIC12F675_HEXES:.hex=.s)
override PIC12F675_SYMBOLS := $(PIC12F675_HEXES:.hex=.sym)
override PIC12F675_BUILD_PRODUCTS := $(PIC12F675_HEXES) $(PIC12F675_ASSEMBLIES) $(PIC12F675_SYMBOLS)
# PIC12F675 device budget: 1024 words flash / 64 B RAM. TWICE the PIC10F322's
# flash, which is the measured reason the modular architecture fits here (the
# tightest variant lands at 55.9%, against the 322's 98.0%) -- see
# DESIGN_DOCUMENTATION.adoc, "Resource Utilization".
PIC12F675_FLASH_WORDS ?= 1024
# Silicon capacity is immutable. The policy limit is separately reviewable and
# inclusive, preserving 16 bytes of allocation headroom at its default setting;
# XC8's Data-space total already includes its statically overlaid automatic
# storage. The canonical transcript parser is not a tool extension point:
# command-line values cannot replace it with a weaker gate.
override PIC12F675_DATA_BYTES := 64
PIC12F675_DATA_LIMIT ?= 48
override PIC12F675_DATA_BUDGET_GATE := test/check_pic_data_budget.sh
# NB: GPSIM, GPSIM_TIMEOUT_SECONDS and PIC_XC8_INCLUDE are SHARED across every
# PIC part and are declared once in the PIC10F322 section above -- per the
# naming rule there, a PIC_* name with no part in it belongs to all of them.
# This part's gpsim processor name arrives with its gpsim lane, not here.

# The PIC shell + the unchanged pure core (the AVR counterpart is CORE_SRC =
# bypass_mcu_avr_classic.c + bypass_pure.c).
override PIC12F675_CORE_SRC := src/bypass_mcu_pic12f675.c src/bypass_pure.c

# Headers that, if changed, should rebuild the PIC images: the AVR FW_HEADERS
# set with the PIC pin map substituted for the AVR-classic one.
PIC12F675_HEADERS = src/bypass_config.h src/bypass_types.h src/bypass_hw_iface.h \
              src/bypass_pure.h \
              src/bypass_output_common.h src/bypass_pins_pic12f675.h \
              src/bypass_blocking_delay.h src/bypass_static_assert.h \
              src/bypass_compile_checks.h \
              src/bypass_output_cd4053_simple.h src/bypass_output_cd4053_with_mute.h \
              src/bypass_output_tq2_l2_5v_relay.h

# XC8 compile flags: select the PIC12F675 + its DFP, C99 (no C11 in XC8), the
# PIC pin map, and _XTAL_FREQ for __delay_ms.
override PIC12F675_CFLAGS := -mcpu=$(PIC12F675_CHIP) -mdfp=$(PIC_DFP) -std=c99 -O2 \
             -DBYPASS_MCU_PIC12F675 -D_XTAL_FREQ=$(PIC12F675_XTAL) \
             $(BYPASS_CTX_CHECK_FLAG)

# --- PIC static analysis (cppcheck + MISRA addon) ----------------------------
# The cppcheck/MISRA register-correct parse of the PIC shell needs the real XC8
# + DFP headers (the PIC analogue of avr-libc). XC8's base include dir supplies
# xc.h; the DFP supplies pic.h + the device header proc/pic12f675.h, selected by
# the chip macro -D_<CHIP> (e.g. -D_12F675). The platform is `pic8` -- the
# CLASSIC mid-range core -- NOT the `pic8-enhanced` the PIC10F32x lanes use.
# Both exist in cppcheck 2.13.0 and a bad --platform name is a hard error, so
# a clean run is itself the check that the right one was named.
PIC12F675_DFP_INCLUDE  ?= $(PIC_DFP)/pic/include
PIC12F675_CHIP_MACRO   ?= _$(PIC12F675_CHIP)

# Defines/includes shared by both PIC cppcheck passes: select the device header,
# pin the PIC configuration so cppcheck does not also explore the AVR branch of
# bypass_output_common.h, and add the XC8 + DFP header search paths.
PIC12F675_CPPCHECK_CPPFLAGS = -D__XC8 -D$(PIC12F675_CHIP_MACRO) -D_XTAL_FREQ=$(PIC12F675_XTAL) \
                        -DBYPASS_MCU_PIC12F675 -U__AVR__ -UBYPASS_MCU_AVR_CLASSIC \
                        $(BYPASS_CTX_CHECK_FLAG) \
                        -Isrc -I$(PIC12F675_DFP_INCLUDE) -I$(PIC12F675_DFP_INCLUDE)/proc -I$(PIC_XC8_INCLUDE)

# Plain bug-finding pass (parallel to analyze-cppcheck for the AVR build).
PIC12F675_CPPCHECK_FLAGS ?= --enable=warning,style,performance,portability \
                      --std=c11 --platform=pic8 --error-exitcode=2 \
                      --inline-suppr --max-configs=1 \
                      --suppress=missingIncludeSystem \
                      --suppress=unmatchedSuppression \
                      --suppress=unusedStructMember \
                      '--suppress=*:$(PIC_XC8_INCLUDE)/*' \
                      '--suppress=*:$(PIC12F675_DFP_INCLUDE)/*' \
                      $(PIC12F675_CPPCHECK_CPPFLAGS)

# MISRA addon pass (parallel to MISRA_CPPCHECK_FLAGS for the AVR build). Notes:
#   - System headers (XC8 base + DFP) are outside the compliance boundary, like
#     avr-libc for the AVR run -> suppressed by path.
#   - cppcheck cannot value-flow-model the volatile SFR bitfield unions from the
#     Microchip headers (e.g. INTCONbits.T0IF in the tick poll). The resulting
#     misra-config accommodation is file-scoped in MISRA_SUPPRESS; findings in
#     every other authored file remain visible to the output gate.
PIC12F675_MISRA_CPPCHECK_FLAGS ?= --addon=$(MISRA_ADDON) --std=c11 --platform=pic8 \
                      --enable=style --inline-suppr --max-configs=1 \
                      --suppress=missingIncludeSystem \
                      --suppress=unmatchedSuppression \
                      '--suppress=*:$(PIC_XC8_INCLUDE)/*' \
                      '--suppress=*:$(PIC12F675_DFP_INCLUDE)/*' \
                      $(PIC12F675_CPPCHECK_CPPFLAGS)

# Build every PIC variant and enforce the flash-word and data-space budgets. The variant -D
# selector and driver source are chosen inline (the same case-pattern the AVR
# analyze/budget recipes use, since $(macro_<v>)/$(src_<v>) cannot expand inside
# a shell loop). Sources are passed as make-time absolute paths so the compiler
# can run with its cwd in PIC12F675_BUILD_DIR.
.PHONY: pic12f675
pic12f675: $(PIC12F675_CORE_SRC) $(PIC12F675_HEADERS) $(foreach v,$(CLASSIC_VARIANTS_SUPPORTED),$(src_$(v)))
	@if [ "$(CLASSIC_VARIANTS_REQUEST_EMPTY)" -eq 1 ]; then \
		echo "FAIL: VARIANTS must not be empty"; exit 2; \
	fi; \
	if [ "$(CLASSIC_VARIANTS_REQUEST_DUPLICATE)" -eq 1 ]; then \
		echo "FAIL: VARIANTS must not contain duplicate names"; exit 2; \
	fi; \
	if [ "$(CLASSIC_VARIANTS_REQUEST_UNKNOWN)" -eq 1 ]; then \
		echo "FAIL: VARIANTS contains unsupported names; supported: $(CLASSIC_VARIANTS_SUPPORTED)"; exit 2; \
	fi; \
	if [ "$(if $(filter-out $(VARIANTS),$(CLASSIC_VARIANTS_SUPPORTED)),yes,no)" = yes ]; then \
		echo "FAIL: VARIANTS must contain every supported name; required: $(CLASSIC_VARIANTS_SUPPORTED)"; exit 2; \
	fi
	@rm -f "$(PIC12F675_BUILD_DIR)"/"$(FW_BASE)-$(PIC12F675_TAG)-"*.hex \
		"$(PIC12F675_BUILD_DIR)"/"$(FW_BASE)-$(PIC12F675_TAG)-"*.s \
		"$(PIC12F675_BUILD_DIR)"/"$(FW_BASE)-$(PIC12F675_TAG)-"*.sym
	@if [ ! -f "$(PIC12F675_DATA_BUDGET_GATE)" ] \
			|| [ -L "$(PIC12F675_DATA_BUDGET_GATE)" ] \
			|| [ ! -x "$(PIC12F675_DATA_BUDGET_GATE)" ]; then \
		echo "FAIL: canonical PIC12F675 data-budget gate is missing, symlinked, or not executable"; exit 1; \
	fi
	@if [ ! -x "$(PIC_CC)" ] && ! command -v $(PIC_CC) >/dev/null 2>&1; then \
		echo "XC8 not found at $(PIC_CC); skipping PIC build (override with PIC_CC=...)"; \
		$(SKIP); \
	fi; \
	$(IHEX_VALIDATOR_CHECK); \
	mkdir -p "$(PIC12F675_BUILD_DIR)"; \
	pic_complete=0; \
	cleanup_pic_products() { \
		rc=$$?; \
		if [ $$rc -ne 0 ] || [ $$pic_complete -ne 1 ]; then \
			rm -f "$(PIC12F675_BUILD_DIR)"/"$(FW_BASE)-$(PIC12F675_TAG)-"*.hex \
				"$(PIC12F675_BUILD_DIR)"/"$(FW_BASE)-$(PIC12F675_TAG)-"*.s \
				"$(PIC12F675_BUILD_DIR)"/"$(FW_BASE)-$(PIC12F675_TAG)-"*.sym || rc=1; \
			[ $$rc -ne 0 ] || rc=1; \
		fi; \
		trap - 0 1 2 15; exit $$rc; \
	}; \
	trap cleanup_pic_products 0 1 2 15; \
	export PIC_RECIPE_PID=$$$$; \
	LC_ALL=C; export LC_ALL; \
	budget="$(PIC12F675_FLASH_WORDS)"; \
	data_limit="$(PIC12F675_DATA_LIMIT)"; \
	case "$$budget" in \
		''|*[!0-9]*) echo "FAIL: PIC12F675_FLASH_WORDS must be a positive decimal integer"; exit 1 ;; \
	esac; \
	while [ "$${#budget}" -gt 1 ] && [ "$${budget#0}" != "$$budget" ]; do \
		budget=$${budget#0}; \
	done; \
	if [ "$$budget" = 0 ]; then \
		echo "FAIL: PIC12F675_FLASH_WORDS must be a positive decimal integer"; exit 1; \
	fi; \
	echo "=== PIC12F675 build + resource budgets (flash $$budget words, data $$data_limit/$(PIC12F675_DATA_BYTES) bytes) ==="; \
	$(fw_image_sh); \
	fail=0; \
	for v in $(CLASSIC_VARIANTS_SUPPORTED); do \
		case $$v in \
			cd4053_with_mute) m=CD4053_WITH_MUTE; drv=src/bypass_output_cd4053_with_mute.c ;; \
			tq2_l2_5v_relay)  m=TQ2_L2_5V_RELAY;  drv=src/bypass_output_tq2_l2_5v_relay.c ;; \
			*)                m=CD4053_SIMPLE;    drv=src/bypass_output_cd4053_simple.c ;; \
		esac; \
		stem=`fw_image_of "$$v" $(PIC12F675_TAG)`; name=$$stem.hex; \
		hex="$(PIC12F675_BUILD_DIR)/$$name"; asm="$(PIC12F675_BUILD_DIR)/$$stem.s"; sym="$(PIC12F675_BUILD_DIR)/$$stem.sym"; \
		if ! rm -f "$$hex" "$$asm" "$$sym"; then \
			echo "FAIL: could not remove stale PIC12F675 products for variant $$v before compiling"; fail=1; continue; \
		fi; \
		out=`cd "$(PIC12F675_BUILD_DIR)" && $(PIC_CC) $(PIC12F675_CFLAGS) -D$$m \
			$(addprefix $(CURDIR)/,$(PIC12F675_CORE_SRC)) $(CURDIR)/$$drv \
			-o "$$name" 2>&1` \
			|| { printf '%s\n' "$$out"; echo "FAIL: variant $$v did not compile for PIC12F675"; rm -f "$$hex"; fail=1; continue; }; \
		if [ ! -s "$$hex" ]; then \
			echo "FAIL: XC8 reported success but did not produce a nonempty $$hex"; \
			printf '%s\n' "$$out"; rm -f "$$hex"; fail=1; continue; \
		fi; \
		if ! $(IHEX_VALIDATOR) "$$hex"; then \
			echo "FAIL: XC8 produced an invalid Intel HEX image for variant $$v"; \
			rm -f "$$hex"; fail=1; continue; \
		fi; \
		data_record=`printf '%s\n' "$$out" \
			| "$(PIC12F675_DATA_BUDGET_GATE)" "$$v" "$$data_limit"`; data_rc=$$?; \
		if [ $$data_rc -ne 0 ]; then \
			echo "FAIL: $$v: invalid or over-budget PIC12F675 data-space usage"; \
			rm -f "$$hex"; fail=1; continue; \
		fi; \
		dec=`printf '%s\n' "$$out" | grep -E 'Program space' \
			| grep -oE '\( *[0-9]+ *\)' | head -1 | tr -d '() '`; \
		if [ -z "$$dec" ]; then \
			echo "FAIL: $$v: could not parse program-word count from XC8 output:"; \
			printf '%s\n' "$$out"; rm -f "$$hex"; fail=1; continue; \
		fi; \
		while [ "$${#dec}" -gt 1 ] && [ "$${dec#0}" != "$$dec" ]; do \
			dec=$${dec#0}; \
		done; \
		over_budget=0; \
		if [ "$${#dec}" -gt "$${#budget}" ]; then \
			over_budget=1; \
		elif [ "$${#dec}" -eq "$${#budget}" ]; then \
			cmp=`$(AWK) -v a="x$$dec" -v b="x$$budget" \
				'BEGIN { print (a > b ? "gt" : "le") }'`; cmp_rc=$$?; \
			if [ $$cmp_rc -ne 0 ]; then \
				echo "FAIL: $$v: could not compare program usage with flash budget"; \
				rm -f "$$hex"; fail=1; continue; \
			fi; \
			case "$$cmp" in \
				gt) over_budget=1 ;; \
				le) ;; \
				*) echo "FAIL: $$v: invalid flash-budget comparison result"; \
					rm -f "$$hex"; fail=1; continue ;; \
			esac; \
		fi; \
		pct=`$(AWK) -v u="$$dec" -v t="$$budget" \
			'BEGIN { printf "%.1f", u * 100 / t }'`; pct_rc=$$?; \
		pct_integer=$${pct%.*}; pct_fraction=$${pct#*.}; pct_valid=1; \
		[ "$$pct_integer" != "$$pct" ] || pct_valid=0; \
		case "$$pct_integer" in ''|*[!0-9]*) pct_valid=0 ;; esac; \
		case "$$pct_fraction" in [0-9]) ;; *) pct_valid=0 ;; esac; \
		if [ $$pct_rc -ne 0 ] || [ $$pct_valid -ne 1 ]; then \
			echo "FAIL: $$v: could not calculate flash usage percentage"; \
			rm -f "$$hex"; fail=1; continue; \
		fi; \
		if [ $$over_budget -eq 1 ]; then \
			echo "FAIL: $$v uses $$dec words ($${pct}%) -- exceeds $$budget"; rm -f "$$hex"; fail=1; \
		else \
			echo "OK:   $$v -> $$hex : $$dec words ($${pct}%) of $$budget"; \
			printf '%s\n' "$$data_record"; \
		fi; \
	done; \
	[ $$fail -ne 0 ] || pic_complete=1; \
	exit $$fail

.PHONY: pic12f675-analyze pic12f675-analyze-cppcheck pic12f675-analyze-misra
pic12f675-analyze: pic12f675-analyze-cppcheck pic12f675-analyze-misra
	@echo "=== PIC static analysis (cppcheck + MISRA) complete ==="

pic12f675-analyze-cppcheck: src/bypass_mcu_pic12f675.c $(PIC12F675_HEADERS)
	@if ! command -v $(CPPCHECK) >/dev/null 2>&1; then \
		echo "cppcheck not installed; skipping PIC cppcheck analysis"; $(SKIP); \
	fi; \
	if [ ! -f "$(PIC_XC8_INCLUDE)/xc.h" ] || [ ! -f "$(PIC12F675_DFP_INCLUDE)/proc/pic12f675.h" ]; then \
		echo "XC8/DFP headers not found; skipping PIC cppcheck analysis"; $(SKIP); \
	fi; \
	echo "cppcheck (PIC, pic8): $(CPPCHECK) src/bypass_mcu_pic12f675.c"; \
	$(CPPCHECK) $(PIC12F675_CPPCHECK_FLAGS) src/bypass_mcu_pic12f675.c

pic12f675-analyze-misra: src/bypass_mcu_pic12f675.c $(PIC12F675_HEADERS) $(MISRA_ADDON) $(MISRA_RULES) $(MISRA_SUPPRESS) $(MISRA_OUTPUT_GATE)
	@if ! command -v $(CPPCHECK) >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then \
		echo "cppcheck and/or python3 not available; skipping PIC MISRA analysis"; $(SKIP); \
	fi; \
	if [ ! -f "$(PIC_XC8_INCLUDE)/xc.h" ] || [ ! -f "$(PIC12F675_DFP_INCLUDE)/proc/pic12f675.h" ]; then \
		echo "XC8/DFP headers not found; skipping PIC MISRA analysis"; $(SKIP); \
	fi; \
	echo "MISRA-C:2012 analysis -- PIC shell ($(CPPCHECK) + misra addon, pic8)"; \
	out=`mktemp`; rc=0; \
	PYTHONWARNINGS=ignore $(CPPCHECK) $(PIC12F675_MISRA_CPPCHECK_FLAGS) \
		$(MISRA_DIAGNOSTIC_TEMPLATE) --suppressions-list=$(MISRA_SUPPRESS) \
		--error-exitcode=2 src/bypass_mcu_pic12f675.c 2>>$$out || rc=$$?; \
	if ! python3 "$(MISRA_OUTPUT_GATE)" --repo-root "$(CURDIR)" \
			--output "$$out" --tool-status "$$rc"; then \
		echo "MISRA findings NOT covered by a documented deviation:"; \
		echo ""; \
		echo "Fix it, or (if genuinely unavoidable) add a per-file entry to"; \
		echo "$(MISRA_SUPPRESS) with a matching record in MISRA_COMPLIANCE.md."; \
		rm -f $$out *.dump *.ctu-info cppcheck-addon-ctu-file-list*; \
		exit 1; \
	fi; \
	rm -f $$out *.dump *.ctu-info cppcheck-addon-ctu-file-list*; \
	echo "MISRA-C:2012 (PIC shell): clean (documented deviations waived per MISRA_COMPLIANCE.md)"

# Host-gcov gate over the real PIC12F675 shipping source set: the shell, shared
# pure core, and all three unmodified output drivers. Uses a classic-PIC SFR mock
# and needs no XC8, DFP or simulator installation.
.PHONY: pic12f675-coverage-check-fw
pic12f675-coverage-check-fw: host-compiler-valid
	@HOSTCC="$(HOSTCC)" GCOV="$(GCOV)" COVERAGE_DIR="$(abspath $(COVERAGE_DIR))" \
		test/pic/fw_coverage/run_fw_coverage.sh pic12f675

# --- PIC12F675 hardware return-stack bound ------------------------------------
# The classic mid-range core has the same 8-level hardware return stack as the
# PIC10F32x (STACKDEPTH=8 in 12f675.ini, corroborated by hwstackdepth="8" in
# edc/PIC12F675.PIC), and the same 2-level reserve applies for the same two
# reasons the PIC10F322 block states: an in-circuit debugger consumes a level,
# and a future ISR would cost a level plus its own tree.
PIC12F675_DEVICE_INI    ?= $(PIC_DFP)/pic/dat/ini/$(shell printf '%s' '$(PIC12F675_CHIP)' | tr 'A-Z' 'a-z').ini
PIC12F675_STACK_RESERVE ?= 2

.PHONY: pic12f675-test-stack-bound
pic12f675-test-stack-bound: pic12f675
	@# One shell: skip only when the build produced no HEX. A current HEX without
	@# its freshly generated assembly is a failed gate, never an absent-tool skip.
	@$(fw_image_sh); \
	have_hex=0; \
	for v in $(CLASSIC_VARIANTS_SUPPORTED); do \
		hex="$(PIC12F675_BUILD_DIR)/`fw_image_of "$$v" $(PIC12F675_TAG)`.hex"; \
		if [ -e "$$hex" ] || [ -L "$$hex" ]; then have_hex=1; fi; \
	done; \
	if [ $$have_hex -eq 0 ]; then \
		echo "no PIC12F675 HEX in $(PIC12F675_BUILD_DIR)/ (XC8 absent?); skipping stack-depth gate"; \
		$(SKIP); \
	fi; \
	for v in $(CLASSIC_VARIANTS_SUPPORTED); do \
		stem="$(PIC12F675_BUILD_DIR)/`fw_image_of "$$v" $(PIC12F675_TAG)`"; \
		hex="$$stem.hex"; \
		asm="$$stem.s"; \
		if [ ! -f "$$hex" ] || [ -L "$$hex" ] || [ ! -s "$$hex" ]; then \
			echo "FAIL: current PIC12F675 image is missing, empty, or not regular: $$hex"; exit 1; \
		fi; \
		if [ ! -f "$$asm" ] || [ -L "$$asm" ] || [ ! -s "$$asm" ]; then \
			echo "FAIL: current PIC12F675 HEX exists but generated assembly is missing, empty, or not regular: $$asm"; exit 1; \
		fi; \
		$(PIC_STACK_DEPTH_GATE) "$$asm" \
			"$(PIC12F675_DEVICE_INI)" "$(PIC12F675_STACK_RESERVE)" "PIC12F675 $$v" || exit 1; \
	done; \
	echo "=== PIC12F675 hardware stack bounded for every variant ==="

# --- PIC12F675 gpsim CLI functional lane ---------------------------------------
# The PIC12F675 counterpart of pic10f322-test-gpsim: drive the footswitch in
# gpsim and assert the observable register state at settled checkpoints, for
# every output variant and for both startup branches (released at power-on, and
# held at power-on).
#
# THREE THINGS DIFFER FROM THE 10F32x LANES, and all three are why this part
# needs its own stimuli rather than PIC_GPSIM_STC pointing at the shared ones:
#   1. THE IMAGE. It runs the DERIVED *_simcal.hex, never the shipping HEX -- an
#      uninjected image cannot reach main() at all on this part (see the
#      calibration block below). This is the first lane to consume them.
#   2. THE PIN. The stimulus attaches to gpio5, not ra3.
#   3. THE CYCLE COUNTS. 4 MHz FOSC gives 1000 cycles/ms against the 322's 500,
#      and the tick is 1024 cycles rather than 1 ms, so every checkpoint is
#      re-derived on tick boundaries -- not scaled from the 322's numbers.
# The part's REGISTER IDENTITY (GPIO for both port and latch, GP5 footswitch,
# GP0 LED, 0x17 output mask including parked GP4) rides in on PIC_GPSIM_REGS so the two shared
# wrappers need no per-part branch.
PIC12F675_GPSIM_PROC       ?= p12f675
PIC12F675_GPSIM_REGS       ?= test/pic/pic12f675_gpsim_regs.sh
PIC12F675_GPSIM_TOGGLE_STC ?= test/pic/pic12f675_footswitch_toggle.stc
PIC12F675_GPSIM_PON_STC    ?= test/pic/pic12f675_power_on_pressed.stc

.PHONY: pic12f675-test-gpsim
pic12f675-test-gpsim: pic12f675-simcal $(PIC12F675_GPSIM_REGS) \
                     $(PIC12F675_GPSIM_TOGGLE_STC) $(PIC12F675_GPSIM_PON_STC)
	@$(fw_image_sh); \
	$(pic12f675_simcal_matrix_sh); \
	$(call gpsim_wrapper_preflight,PIC12F675); \
	if [ $$simcal_count -eq 0 ]; then \
		echo "no PIC12F675 simulator images (XC8 absent?); skipping gpsim lane"; \
		$(SKIP); \
	fi; \
	fail=0; \
	for v in $(CLASSIC_VARIANTS_SUPPORTED); do \
		case $$v in \
			cd4053_with_mute) el=0x7 ;; \
			tq2_l2_5v_relay)  el=0x1 ;; \
			*)                el=0x3 ;; \
		esac; \
		stem=`fw_image_of "$$v" $(PIC12F675_TAG)`; \
		hex=$(PIC12F675_SIMCAL_DIR)/$${stem}_simcal.hex; \
		echo "--- gpsim register-level test: PIC12F675 variant $$v ---"; \
		GPSIM=$(GPSIM) PIC_GPSIM_PROC=$(PIC12F675_GPSIM_PROC) \
			PIC_GPSIM_REGS="$(CURDIR)/$(PIC12F675_GPSIM_REGS)" \
			PIC_GPSIM_STC="$(CURDIR)/$(PIC12F675_GPSIM_TOGGLE_STC)" \
			STRICT_TOOLS="$(STRICT_TOOLS)" \
			test/pic/run_gpsim_test.sh $$hex $$el || fail=1; \
		GPSIM=$(GPSIM) PIC_GPSIM_PROC=$(PIC12F675_GPSIM_PROC) \
			PIC_GPSIM_REGS="$(CURDIR)/$(PIC12F675_GPSIM_REGS)" \
			PIC_GPSIM_PON_STC="$(CURDIR)/$(PIC12F675_GPSIM_PON_STC)" \
			STRICT_TOOLS="$(STRICT_TOOLS)" \
			test/pic/run_gpsim_power_on_pressed.sh $$hex || fail=1; \
	done; \
	exit $$fail

# --- PIC12F675 built-HEX GPIO transitions + pulse timing (libgpsim) ------------
# The PIC12F675 counterpart of pic10f322-test-io, on the same shared core
# (test/pic/test_io_pic_core.h). Three things it does that the 322 lane cannot:
#
#   1. IT COMPARES INTENT AGAINST REALITY. The 322 reads LATA and PORTA, two
#      views of one latch, so "the port follows the latch" is nearly a tautology
#      there. This part has no output latch: the shell keeps gpio_shadow_ in
#      SRAM and writes shadow -> GPIO, so the comparison is between what the
#      firmware meant to drive and what the pins actually are. That is the check
#      docs/pic12f675_feasibility.md section 6.5 means by this lane getting MORE
#      meaningful on the part with less hardware.
#   2. IT LOCATES THE SHADOW PER BUILD. gpio_shadow_ is a file-static placed by
#      XC8, not a device address, so it is lifted from the .sym exactly as the
#      fault and lock-step lanes lift _ctx_. Empty when the .sym is absent; the
#      run recipe below FAILS if the image exists but the symbol cannot be
#      resolved, so the lane cannot pass having quietly read register 0x000.
#   3. IT RUNS THE DERIVED IMAGE. Like the gpsim CLI lane above, it consumes
#      $(PIC12F675_SIMCAL_DIR) -- an uninjected image never reaches main().
#      The .sym still comes from the SHIPPING build beside it: the injector adds
#      one calibration word and changes no symbol.
PIC12F675_IO_VARIANT ?= cd4053_simple
PIC12F675_IO_SRC = test/pic/test_io_pic12f675.cc
PIC12F675_IO_BIN = test/pic/test_io_pic12f675
PIC12F675_IO_STEM = $(call fw_image,$(PIC12F675_IO_VARIANT),$(PIC12F675_TAG))
PIC12F675_IO_HEX = $(PIC12F675_SIMCAL_DIR)/$(PIC12F675_IO_STEM)_simcal.hex
PIC12F675_IO_SYM = $(PIC12F675_BUILD_DIR)/$(PIC12F675_IO_STEM).sym
# A $(shell) in this recursive (=) variable re-runs when PIC12F675_IO_COMPILE is
# expanded in the recipe -- i.e. AFTER the `pic12f675-simcal` prerequisite has
# built the .sym.
PIC12F675_IO_SHADOW_DEF = $(shell a=$$(awk '$$1=="_gpio_shadow_"{print $$2; exit}' $(PIC12F675_IO_SYM) 2>/dev/null); [ -n "$$a" ] && echo -DPIC_SHADOW_ADDR=0x$$a)
PIC12F675_IO_COMPILE = $(PIC_SOAK_CXX) -std=c++17 -O2 $$(pkg-config --cflags glib-2.0) \
		-isystem $(PIC_SOAK_GPSIM_INC) -Itest -Isrc \
		-DFW_PATH='"$(CURDIR)/$(PIC12F675_IO_HEX)"' -DPROC_NAME='"$(PIC12F675_GPSIM_PROC)"' \
		-DPIC_TARGET_RESULT_DEVICE='"pic12f675"' \
		-DPIC_TARGET_RESULT_VARIANT='"$(PIC12F675_IO_VARIANT)"' \
		-DF_CPU_HZ=$(PIC12F675_XTAL) -D$(macro_$(PIC12F675_IO_VARIANT)) \
		$(PIC12F675_IO_SHADOW_DEF) \
		$(PIC12F675_IO_SRC) -o $(PIC12F675_IO_BIN) -lgpsim

$(PIC12F675_IO_BIN): $(PIC12F675_IO_SRC) $(PIC_TARGET_IO_CORE_HDR) $(PIC_TARGET_RESULT_HDR) $(PIC_PIN_LOOKUP_HDR) \
               $(PIC_GPSIM_BOOTSTRAP_HDR) $(PIC12F675_REGS_HDR)
	$(PIC12F675_IO_COMPILE)

.PHONY: pic12f675-test-io
pic12f675-test-io: variant-selectors-valid pic12f675-simcal
	@$(pic12f675_simcal_matrix_sh); \
	if ! command -v $(PIC_SOAK_CXX) >/dev/null 2>&1; then \
		echo "no C++ compiler ($(PIC_SOAK_CXX)); skipping PIC12F675 target-I/O test"; $(SKIP); \
	fi; \
	if [ ! -f "$(PIC_SOAK_GPSIM_INC)/sim_context.h" ]; then \
		echo "gpsim-dev headers not at $(PIC_SOAK_GPSIM_INC); skipping PIC12F675 target-I/O test (install gpsim-dev)"; $(SKIP); \
	fi; \
	if ! pkg-config --exists glib-2.0 2>/dev/null; then \
		echo "libglib2.0-dev not found; skipping PIC12F675 target-I/O test (install libglib2.0-dev)"; $(SKIP); \
	fi; \
	if [ ! -f "$(PIC12F675_IO_HEX)" ]; then \
		echo "no $(PIC12F675_IO_HEX) (XC8 absent?); skipping PIC12F675 target-I/O for variant $(PIC12F675_IO_VARIANT)"; $(SKIP); \
	fi; \
	shadow_addr=`awk '$$1=="_gpio_shadow_"{print $$2; exit}' "$(PIC12F675_IO_SYM)" 2>/dev/null`; \
	if [ -z "$$shadow_addr" ]; then \
		echo "FAIL: _gpio_shadow_ symbol not found in $(PIC12F675_IO_SYM)."; \
		echo "      This part has no output-latch SFR, so the shadow IS the latch: without"; \
		echo "      its address the harness would read register 0x000 (INDF) and the"; \
		echo "      shadow-vs-port comparison would pass while checking nothing."; \
		exit 1; \
	fi; \
	echo "--- PIC12F675 target I/O: variant=$(PIC12F675_IO_VARIANT) proc=$(PIC12F675_GPSIM_PROC) (gpio_shadow_ at 0x$$shadow_addr) ---"; \
	rm -f $(PIC12F675_IO_BIN) && \
	$(PIC12F675_IO_COMPILE) && \
	./$(PIC12F675_IO_BIN)

# --- PIC12F675 built-HEX lock-step test (libgpsim + shared model) -------------
# The PIC12F675 leg of the lock-step lane: the same shared core
# (test/pic/test_lockstep_pic_core.h) driving the real XC8-built instruction
# stream and the shared model with one footswitch stream, comparing live ctx_
# SRAM after every completed main-loop iteration. Three notes specific to this
# part:
#
#   1. IT SCANS THE WHOLE 1024-WORD PROGRAM SPACE for the main loop's CLRWDT.
#      The core scanned a hard-coded 0x200 until this part arrived; half of this
#      image sits above that line, and the loop CLRWDT is the iteration boundary
#      the entire comparison hangs on. The scan bound is now a part constant in
#      the adapter.
#   2. IT RUNS THE DERIVED IMAGE, like every simulator lane for this part, while
#      taking _ctx_ and its `ds 3` layout check from the SHIPPING build beside
#      it -- the injector adds one calibration word and changes no symbol.
#   3. NOTHING TIMING-RELATED HAD TO BE RE-DERIVED. The comparison is per
#      ITERATION, one model step per completed loop pass, so the 1.024 ms tick
#      and the 12 ms blocking coil pulse -- which the gpsim CLI checkpoints did
#      have to be re-derived for -- change nothing here.
#
# Skip-clean for missing tools when run on its own; pic12f675-test-target below
# turns that into a failure by requiring the LOCK-STEP PASS sentinel, the way
# pic10f322-test-target requires the 322's.
PIC12F675_LOCKSTEP_VARIANT ?= cd4053_simple
PIC12F675_LOCKSTEP_SRC = test/pic/test_lockstep_pic12f675.cc
PIC12F675_LOCKSTEP_BIN = test/pic/test_lockstep_pic12f675
PIC12F675_LOCKSTEP_MODEL_OBJ = $(PIC12F675_BUILD_DIR)/bypass_pure_lockstep.o
PIC12F675_LOCKSTEP_STEM = $(call fw_image,$(PIC12F675_LOCKSTEP_VARIANT),$(PIC12F675_TAG))
PIC12F675_LOCKSTEP_HEX = $(PIC12F675_SIMCAL_DIR)/$(PIC12F675_LOCKSTEP_STEM)_simcal.hex
# Both from the shipping build, NOT from the derived image beside it: the
# calibration injector rewrites one program word and emits no symbol table or
# assembly of its own.
PIC12F675_LOCKSTEP_SYM = $(PIC12F675_BUILD_DIR)/$(PIC12F675_LOCKSTEP_STEM).sym
PIC12F675_LOCKSTEP_ASM = $(PIC12F675_BUILD_DIR)/$(PIC12F675_LOCKSTEP_STEM).s
PIC12F675_LOCKSTEP_CTX_DEF = $(shell a=$$(awk '$$1=="_ctx_"{print $$2; exit}' $(PIC12F675_LOCKSTEP_SYM) 2>/dev/null); [ -n "$$a" ] && echo -DCTX_ADDR=0x$$a)
# The mkdir is not ceremony: the model object lands in the target build
# directory, which only the `pic12f675` build target creates, and this recipe is
# also reachable as a plain file target.
PIC12F675_LOCKSTEP_COMPILE = \
		mkdir -p $(PIC12F675_BUILD_DIR) && \
		$(HOSTCC) $(HOST_CFLAGS) $(PURE_HOST_CFLAGS) -Itest -Isrc \
			-c $(PURE_HOST_SRC) -o $(PIC12F675_LOCKSTEP_MODEL_OBJ) && \
		$(PIC_SOAK_CXX) -std=c++17 -O2 $$(pkg-config --cflags glib-2.0) \
			-isystem $(PIC_SOAK_GPSIM_INC) -Itest -Isrc \
			-DFW_PATH='"$(CURDIR)/$(PIC12F675_LOCKSTEP_HEX)"' -DPROC_NAME='"$(PIC12F675_GPSIM_PROC)"' \
			-DPIC_TARGET_RESULT_DEVICE='"pic12f675"' \
			-DPIC_TARGET_RESULT_VARIANT='"$(PIC12F675_LOCKSTEP_VARIANT)"' \
			-DF_CPU_HZ=$(PIC12F675_XTAL) $(PIC12F675_LOCKSTEP_CTX_DEF) \
			$(PIC12F675_LOCKSTEP_SRC) $(PIC12F675_LOCKSTEP_MODEL_OBJ) \
			-o $(PIC12F675_LOCKSTEP_BIN) -lgpsim

$(PIC12F675_LOCKSTEP_BIN): $(PIC12F675_LOCKSTEP_SRC) $(PIC_TARGET_LOCKSTEP_CORE_HDR) $(PIC_TARGET_RESULT_HDR) \
                     $(PIC_PIN_LOOKUP_HDR) $(PIC_GPSIM_BOOTSTRAP_HDR) \
                     $(PIC12F675_REGS_HDR) $(PURE_HOST_DEP)
	$(PIC12F675_LOCKSTEP_COMPILE)

.PHONY: pic12f675-test-lockstep
pic12f675-test-lockstep: variant-selectors-valid pic12f675-simcal
	@$(pic12f675_simcal_matrix_sh); \
	if ! command -v $(PIC_SOAK_CXX) >/dev/null 2>&1; then \
		echo "no C++ compiler ($(PIC_SOAK_CXX)); skipping PIC12F675 lock-step"; $(SKIP); \
	fi; \
	if [ ! -f "$(PIC_SOAK_GPSIM_INC)/sim_context.h" ]; then \
		echo "gpsim-dev headers not at $(PIC_SOAK_GPSIM_INC); skipping PIC12F675 lock-step (install gpsim-dev)"; $(SKIP); \
	fi; \
	if ! pkg-config --exists glib-2.0 2>/dev/null; then \
		echo "libglib2.0-dev not found; skipping PIC12F675 lock-step (install libglib2.0-dev)"; $(SKIP); \
	fi; \
	if [ ! -f "$(PIC12F675_LOCKSTEP_HEX)" ]; then \
		echo "no $(PIC12F675_LOCKSTEP_HEX) (XC8 absent?); skipping PIC12F675 lock-step for variant $(PIC12F675_LOCKSTEP_VARIANT)"; $(SKIP); \
	fi; \
	alloc=`awk 'prev=="_ctx_:"{print $$2; exit} {prev=$$1}' "$(PIC12F675_LOCKSTEP_ASM)" 2>/dev/null`; \
	if [ "$$alloc" != "3" ]; then \
		echo "FAIL: _ctx_ allocates $${alloc:-?} bytes in $(PIC12F675_LOCKSTEP_ASM) -- expected 3 (packed 1-byte enums)."; \
		echo "      test_lockstep_pic12f675.cc reads ctx_+0/+1/+2; fix offsets if packing changed."; \
		exit 1; \
	fi; \
	ctx_addr=`awk '$$1=="_ctx_"{print $$2; exit}' "$(PIC12F675_LOCKSTEP_SYM)" 2>/dev/null`; \
	if [ -z "$$ctx_addr" ]; then \
		echo "FAIL: _ctx_ symbol not found in $(PIC12F675_LOCKSTEP_SYM); lock-step cannot read firmware state."; \
		exit 1; \
	fi; \
	echo "--- PIC12F675 lock-step: variant=$(PIC12F675_LOCKSTEP_VARIANT) proc=$(PIC12F675_GPSIM_PROC) (ctx_ at 0x$$ctx_addr, layout verified: 3 bytes) ---"; \
	rm -f $(PIC12F675_LOCKSTEP_BIN) && \
	$(PIC12F675_LOCKSTEP_COMPILE) && \
	./$(PIC12F675_LOCKSTEP_BIN)

# --- PIC12F675 critical-SFR fault-injection test (libgpsim) --------------------
# The PIC12F675 leg of the fault lane: the same shared core
# (test/pic/test_fault_pic_core.h) corrupting a guarded location on the real
# XC8-built image and requiring the firmware to recover through exactly one
# watchdog reset. Four notes specific to this part:
#
#   1. IT NEEDS TWO ADDRESSES FROM THE BUILD, not one. Every other fault lane
#      lifts _ctx_ alone; this part has no output-latch SFR, so the latch it
#      corrupts is the shell's gpio_shadow_ in SRAM and its address is lifted
#      the same way. The adapter refuses to compile without it rather than
#      defaulting: no default can be right for a per-build address, and the
#      obvious one is actively wrong -- register 0x000 is INDF, so a write
#      through it lands wherever FSR points.
#   2. IT INJECTS INTO THE PORT REGISTER AS WELL AS THE LATCH. With the shadow
#      left correct and GPIO driven high, the only clause of the gate that can
#      explain the reset is "the port still follows the shadow" -- the check
#      this part can make and the PIC10F322 cannot.
#   3. IT SCANS THE WHOLE 1024-WORD PROGRAM SPACE for the main loop's CLRWDT,
#      the point at which every injection is parked. Half of this image sits
#      above the 0x200 the two 10F32x lanes scan.
#   4. IT RUNS THE DERIVED IMAGE, like every simulator lane for this part, while
#      taking _ctx_, gpio_shadow_ and the `ds 3` layout check from the SHIPPING
#      build beside it -- the injector adds one calibration word and changes no
#      symbol.
#
# Skip-clean for missing tools when run on its own; pic12f675-test-target below
# turns that into a failure by requiring the FAULT-INJECT PASS sentinel, the way
# pic10f322-test-target requires the 322's.
PIC12F675_FAULT_VARIANT ?= cd4053_simple
PIC12F675_FAULT_SRC = test/pic/test_fault_pic12f675.cc
PIC12F675_FAULT_BIN = test/pic/test_fault_pic12f675
PIC12F675_FAULT_STEM = $(call fw_image,$(PIC12F675_FAULT_VARIANT),$(PIC12F675_TAG))
PIC12F675_FAULT_HEX = $(PIC12F675_SIMCAL_DIR)/$(PIC12F675_FAULT_STEM)_simcal.hex
# Both from the shipping build, NOT from the derived image beside it: the
# calibration injector rewrites one program word and emits no symbol table or
# assembly of its own.
PIC12F675_FAULT_SYM = $(PIC12F675_BUILD_DIR)/$(PIC12F675_FAULT_STEM).sym
PIC12F675_FAULT_ASM = $(PIC12F675_BUILD_DIR)/$(PIC12F675_FAULT_STEM).s
# A $(shell) in these recursive (=) variables re-runs when the compile command
# below is expanded, so a rebuilt .sym is picked up without re-entering make.
# Empty when the symbol is absent; the run recipe FAILS closed on that, and the
# adapter will not compile without the shadow address.
PIC12F675_FAULT_CTX_DEF = $(shell a=$$(awk '$$1=="_ctx_"{print $$2; exit}' $(PIC12F675_FAULT_SYM) 2>/dev/null); [ -n "$$a" ] && echo -DCTX_ADDR=0x$$a)
PIC12F675_FAULT_SHADOW_DEF = $(shell a=$$(awk '$$1=="_gpio_shadow_"{print $$2; exit}' $(PIC12F675_FAULT_SYM) 2>/dev/null); [ -n "$$a" ] && echo -DPIC_SHADOW_ADDR=0x$$a)
PIC12F675_FAULT_COMPILE = $(PIC_SOAK_CXX) -std=c++17 -O2 $$(pkg-config --cflags glib-2.0) \
		-isystem $(PIC_SOAK_GPSIM_INC) -Itest -Isrc \
		-DFW_PATH='"$(CURDIR)/$(PIC12F675_FAULT_HEX)"' -DPROC_NAME='"$(PIC12F675_GPSIM_PROC)"' \
		-DPIC_TARGET_RESULT_DEVICE='"pic12f675"' \
		-DPIC_TARGET_RESULT_VARIANT='"$(PIC12F675_FAULT_VARIANT)"' \
		-DF_CPU_HZ=$(PIC12F675_XTAL) -D$(macro_$(PIC12F675_FAULT_VARIANT)) \
		$(PIC12F675_FAULT_CTX_DEF) $(PIC12F675_FAULT_SHADOW_DEF) \
		$(BYPASS_CTX_CHECK_FLAG) \
		$(PIC12F675_FAULT_SRC) -o $(PIC12F675_FAULT_BIN) -lgpsim

$(PIC12F675_FAULT_BIN): $(PIC12F675_FAULT_SRC) $(PIC_TARGET_FAULT_CORE_HDR) $(PIC_TARGET_RESULT_HDR) \
                  $(PIC_PIN_LOOKUP_HDR) $(PIC_GPSIM_BOOTSTRAP_HDR) \
                  $(PIC12F675_REGS_HDR) $(PIC12F675_FAULT_MATRIX_HDR)
	$(PIC12F675_FAULT_COMPILE)

.PHONY: pic12f675-test-fault
pic12f675-test-fault: variant-selectors-valid pic12f675-simcal
	@$(pic12f675_simcal_matrix_sh); \
	if ! command -v $(PIC_SOAK_CXX) >/dev/null 2>&1; then \
		echo "no C++ compiler ($(PIC_SOAK_CXX)); skipping PIC12F675 fault-inject"; $(SKIP); \
	fi; \
	if [ ! -f "$(PIC_SOAK_GPSIM_INC)/sim_context.h" ]; then \
		echo "gpsim-dev headers not at $(PIC_SOAK_GPSIM_INC); skipping PIC12F675 fault-inject (install gpsim-dev)"; $(SKIP); \
	fi; \
	if ! pkg-config --exists glib-2.0 2>/dev/null; then \
		echo "libglib2.0-dev not found; skipping PIC12F675 fault-inject (install libglib2.0-dev)"; $(SKIP); \
	fi; \
	if [ ! -f "$(PIC12F675_FAULT_HEX)" ]; then \
		echo "no $(PIC12F675_FAULT_HEX) (XC8 absent?); skipping PIC12F675 fault-inject for variant $(PIC12F675_FAULT_VARIANT)"; $(SKIP); \
	fi; \
	alloc=`awk 'prev=="_ctx_:"{print $$2; exit} {prev=$$1}' "$(PIC12F675_FAULT_ASM)" 2>/dev/null`; \
	if [ "$$alloc" != "3" ]; then \
		echo "FAIL: _ctx_ allocates $${alloc:-?} bytes in $(PIC12F675_FAULT_ASM) -- expected 3 (packed 1-byte enums)."; \
		echo "      test_fault_pic12f675.cc injects at the hard-coded byte offsets ctx_+0/+1/+2"; \
		echo "      (program_state / effect_state / debounce_counter); fix them if packing changed."; \
		exit 1; \
	fi; \
	ctx_addr=`awk '$$1=="_ctx_"{print $$2; exit}' "$(PIC12F675_FAULT_SYM)" 2>/dev/null`; \
	if [ -z "$$ctx_addr" ]; then \
		echo "FAIL: _ctx_ symbol not found in $(PIC12F675_FAULT_SYM); ctx_ SRAM fault cases would be omitted."; \
		exit 1; \
	fi; \
	shadow_addr=`awk '$$1=="_gpio_shadow_"{print $$2; exit}' "$(PIC12F675_FAULT_SYM)" 2>/dev/null`; \
	if [ -z "$$shadow_addr" ]; then \
		echo "FAIL: _gpio_shadow_ symbol not found in $(PIC12F675_FAULT_SYM)."; \
		echo "      This part has no output-latch SFR, so the shadow IS the latch: four"; \
		echo "      shadow-corruption injections have nothing to corrupt without its address."; \
		exit 1; \
	fi; \
	echo "--- PIC12F675 fault-inject: variant=$(PIC12F675_FAULT_VARIANT) proc=$(PIC12F675_GPSIM_PROC) (ctx_ at 0x$$ctx_addr, gpio_shadow_ at 0x$$shadow_addr, layout verified: 3 bytes) ---"; \
	rm -f $(PIC12F675_FAULT_BIN) && \
	$(PIC12F675_FAULT_COMPILE) && \
	./$(PIC12F675_FAULT_BIN)

# --- PIC12F675 long-duration soak test (libgpsim) -----------------------------
# The PIC12F675 leg of the soak lane: the shared driver
# (test/pic/test_soak_pic_core.h) running the real image for
# PIC12F675_SOAK_DURATION_MS of simulated time, asserting watchdog liveness and a
# periodic 2-press round-trip. Four notes specific to this part:
#
#   1. ITS HOLDS ARE RE-DERIVED, NOT INHERITED. This part's debounce tick is
#      1.024 ms -- four unprescaled TMR0 rollovers, because the one prescaler is
#      the watchdog's -- so a threshold counted in TICKS and a hold counted in
#      simulated MILLISECONDS stop being the same number. The timing helper
#      derives the tick from the shell's clock/subtick constants and the core
#      converts. docs/pic12f675_feasibility.md section
#      4.4.1 asked for exactly that, and specifically for NOT letting the
#      existing 10 ms slack absorb it: that slack is already paying for the
#      blocking actuation in note 4.
#   2. IT READS THE LED OUT OF SRAM. With no output-latch SFR the shell's
#      gpio_shadow_ is the latch, so the once-per-millisecond LED sample needs
#      the .sym address the io and fault lanes already lift. The adapter will not
#      compile without it, and the recipe below fails closed if the image exists
#      but the symbol cannot be resolved.
#   3. IT RUNS THE DERIVED IMAGE, like every simulator lane for this part, and
#      applies the exact-matrix gate before its optional-tool skips -- otherwise
#      a suppressed producer could let one selected image stand in for the set.
#      The .sym still comes from the SHIPPING build beside it.
#   4. BLOCKING ACTUATION IS DERIVED FROM THE SELECTED OUTPUT HEADER. A relay
#      coil pulse and mute delay are wall-clock waits, not tick counts, so they
#      do not scale with the 1.024 ms tick. Reading their 12/5 ms constants from
#      the same headers the firmware consumes avoids a second Make-side table.
#
# STANDALONE, like both 10F32x soaks and for the same reasons: it runs for
# minutes and links libgpsim, so it is deliberately not in `make test`. The
# direct binary target builds its derived inputs; the run target skips cleanly
# when the compiler, gpsim-dev / libglib2.0-dev headers or image are absent.
PIC12F675_SOAK_VARIANT     ?= cd4053_simple
PIC12F675_SOAK_DURATION_MS ?= 3600000
PIC12F675_SOAK_LIVENESS_INTERVAL_MS ?= 60000
PIC12F675_SOAK_PROGRESS_INTERVAL_MS ?= 3600000
PIC12F675_SOAK_COMBINATION_NAME ?= standalone
PIC12F675_SOAK_SRC  = test/pic/test_soak_pic12f675.cc
PIC12F675_SOAK_BIN  = test/pic/test_soak_pic12f675
PIC12F675_SOAK_STEM = $(call fw_image,$(PIC12F675_SOAK_VARIANT),$(PIC12F675_TAG))
PIC12F675_SOAK_HEX  = $(PIC12F675_SIMCAL_DIR)/$(PIC12F675_SOAK_STEM)_simcal.hex
# From the SHIPPING build, not the derived image beside it: the calibration
# injector rewrites one program word and emits no symbol table of its own.
PIC12F675_SOAK_SYM  = $(PIC12F675_BUILD_DIR)/$(PIC12F675_SOAK_STEM).sym
# This host tool derives the tick from the shell's TMR0 subtick count and FOSC,
# and the block from the selected output driver's header. It keeps the soak from
# carrying private copies of firmware timing constants.
PIC12F675_PYTHON ?= python3
override PIC12F675_SOAK_TIMING_TOOL := test/pic/pic12f675_soak_timing.py
PIC12F675_SOAK_TIMING_CMD = $(PIC12F675_PYTHON) "$(PIC12F675_SOAK_TIMING_TOOL)" \
		--root "$(CURDIR)" --variant "$(PIC12F675_SOAK_VARIANT)" \
		--fosc-hz "$(PIC12F675_XTAL)" --expected-fosc-hz 4000000UL
PIC12F675_SOAK_DEPS = $(PIC12F675_SOAK_SRC) $(PIC_TARGET_SOAK_CORE_HDR) \
                $(PIC12F675_REGS_HDR) $(PIC_PIN_LOOKUP_HDR) \
                $(PIC_GPSIM_BOOTSTRAP_HDR) $(PIC_SOAK_SAMPLING_HDR) \
                $(PIC_SOAK_HOLD_TIMING_HDR) $(PIC12F675_SOAK_TIMING_TOOL) \
		test/soak_timing_config.h
PIC12F675_SOAK_COMPILE = $(PIC_SOAK_CXX) -std=c++17 -O2 $$(pkg-config --cflags glib-2.0) \
		-isystem $(PIC_SOAK_GPSIM_INC) -Itest -Isrc \
		-DFW_PATH='"$(CURDIR)/$(PIC12F675_SOAK_HEX)"' -DPROC_NAME='"$(PIC12F675_GPSIM_PROC)"' \
		-DF_CPU_HZ=$(PIC12F675_XTAL) -DPIC_SHADOW_ADDR=0x$$shadow_addr $$timing_defs \
		-DSOAK_DURATION_MS=$(PIC12F675_SOAK_DURATION_MS) \
		-DSOAK_LIVENESS_INTERVAL_MS=$(PIC12F675_SOAK_LIVENESS_INTERVAL_MS) \
		-DSOAK_PROGRESS_INTERVAL_MS=$(PIC12F675_SOAK_PROGRESS_INTERVAL_MS) \
		-DSOAK_COMBINATION_NAME='"$(PIC12F675_SOAK_COMBINATION_NAME)"' \
		$(PIC12F675_SOAK_SRC) -o $(PIC12F675_SOAK_BIN) -lgpsim

define pic12f675_soak_inputs_sh
if [ ! -f "$(1)" ] || [ -L "$(1)" ] || [ ! -s "$(1)" ]; then \
	echo "FAIL: selected PIC12F675 simulator image is missing, empty, or not regular: $(1)"; exit 1; \
fi; \
if [ ! -f "$(2)" ] || [ -L "$(2)" ] || [ ! -s "$(2)" ]; then \
	echo "FAIL: selected PIC12F675 symbol file is missing, empty, or not regular: $(2)"; exit 1; \
fi; \
shadow_addr=`awk '$$1=="_gpio_shadow_"{print $$2; exit}' "$(2)" 2>/dev/null`; \
case "$$shadow_addr" in ''|*[!0-9A-Fa-f]*) \
	echo "FAIL: _gpio_shadow_ symbol has no hexadecimal address in $(2)"; exit 1 ;; \
esac; \
timing_defs=`$(3) --format defines` || exit 1; \
case "$$timing_defs" in \
	'-DSOAK_TICK_US='*' -DSOAK_ACTUATION_BLOCK_MS='*u) ;; \
	*) echo "FAIL: PIC12F675 soak timing tool emitted an invalid definition record: $$timing_defs"; exit 1 ;; \
esac
endef

.PHONY: _pic12f675-build-soak
_pic12f675-build-soak: variant-selectors-valid
	@$(MAKE) --no-print-directory PIC12F675_SOAK_VARIANT=$(PIC12F675_SOAK_VARIANT) \
		pic12f675-simcal

# Build-only rule, the analogue of the two 10F32x soak rules. FORCE for the
# reason stated at the PIC10F322 rule: this binary's effective build command
# includes command-line variables -- the three interval/duration values and the
# variant are compiled IN as -D flags -- and a timestamp cannot represent them,
# so without it a second `make test/pic/test_soak_pic12f675` at a different
# duration reports "up to date" and leaves the first binary in place.
$(PIC12F675_SOAK_BIN): $(PIC12F675_SOAK_DEPS) _pic12f675-build-soak FORCE | variant-selectors-valid
	@$(pic12f675_simcal_matrix_sh); \
	if [ $$simcal_count -eq 0 ]; then \
		rm -f "$(PIC12F675_SOAK_BIN)" || exit 1; \
		echo "no PIC12F675 simulator images (XC8 absent?); skipping PIC12F675 soak build"; $(SKIP); \
	fi; \
	$(call pic12f675_soak_inputs_sh,$(PIC12F675_SOAK_HEX),$(PIC12F675_SOAK_SYM),$(PIC12F675_SOAK_TIMING_CMD)); \
	$(PIC12F675_SOAK_COMPILE)

.PHONY: pic12f675-test-soak
pic12f675-test-soak: variant-selectors-valid pic12f675-simcal
	@$(pic12f675_simcal_matrix_sh); \
	if ! command -v $(PIC_SOAK_CXX) >/dev/null 2>&1; then \
		echo "no C++ compiler ($(PIC_SOAK_CXX)); skipping PIC12F675 soak"; $(SKIP); \
	fi; \
	if [ ! -f "$(PIC_SOAK_GPSIM_INC)/sim_context.h" ]; then \
		echo "gpsim-dev headers not at $(PIC_SOAK_GPSIM_INC); skipping PIC12F675 soak (install gpsim-dev)"; $(SKIP); \
	fi; \
	if ! pkg-config --exists glib-2.0 2>/dev/null; then \
		echo "libglib2.0-dev not found; skipping PIC12F675 soak (install libglib2.0-dev)"; $(SKIP); \
	fi; \
	if [ $$simcal_count -eq 0 ]; then \
		echo "no PIC12F675 simulator images (XC8 absent?); skipping PIC12F675 soak for variant $(PIC12F675_SOAK_VARIANT)"; $(SKIP); \
	fi; \
	$(call pic12f675_soak_inputs_sh,$(PIC12F675_SOAK_HEX),$(PIC12F675_SOAK_SYM),$(PIC12F675_SOAK_TIMING_CMD)); \
	echo "--- PIC12F675 soak: variant=$(PIC12F675_SOAK_VARIANT) proc=$(PIC12F675_GPSIM_PROC) duration=$(PIC12F675_SOAK_DURATION_MS) ms (gpio_shadow_ at 0x$$shadow_addr) ---"; \
	rm -f $(PIC12F675_SOAK_BIN) && \
	$(PIC12F675_SOAK_COMPILE) && \
	./$(PIC12F675_SOAK_BIN)

# --- PIC12F675 CONFIG-word verification ---------------------------------------
# Same mechanism as the PIC10F32x lane (test/pic/test_config_pic_core.h), its own
# decode table (test/pic/pic12f675_config.h). See the PIC CONFIG-word block above
# for why this check exists at all.
#
# The table is NOT the 10F32x's with the names changed. Two of this part's fields
# have no 10F32x counterpart at all -- CPD, and the BG<1:0> bandgap calibration
# bits, which the build must leave ERASED so the image does not replace factory
# trim (the CONFIG-word sibling of the OSCCAL story below). The programmer must
# preserve the device value; this build-side check cannot prove that it does. And
# FOSC widens from one bit to three, which promotes it to a design-intent check:
# seven of the eight settings hand GP4 and/or GP5 to an oscillator. Six claim
# footswitch GP5; the remaining one claims parked-output GP4. Only INTRCIO
# preserves both declared pin roles, a constraint the single-bit 10F32x FOSC
# simply cannot express.
test/pic/test_config_pic12f675: test/pic/test_config_pic12f675.c $(PIC_CONFIG_CORE_HDR) $(PIC12F675_CONFIG_HDR)
	$(HOSTCC) $(HOST_CFLAGS) $(SANITIZE) -Itest -DPIC_DEVICE_NAME='"PIC$(PIC12F675_CHIP)"' $< -o $@

.PHONY: pic12f675-test-config
pic12f675-test-config: pic12f675 test/pic/test_config_pic12f675
	@hexes=`ls $(PIC12F675_BUILD_DIR)/$(FW_BASE)-$(PIC12F675_TAG)-*.hex 2>/dev/null`; \
	if [ -z "$$hexes" ]; then \
		echo "no PIC12F675 HEX in $(PIC12F675_BUILD_DIR)/ (XC8 absent?); skipping CONFIG-word check"; \
		$(SKIP); \
	fi; \
	./test/pic/test_config_pic12f675 $$hexes

# --- PIC12F675 oscillator calibration word (simulator images) -----------------
# THE SHIPPING IMAGE CANNOT RUN IN A SIMULATOR, and that is not a defect. On this
# part the oscillator trim lives in FLASH at the last program word (0x3FF, the
# device pack's ".oscval" CalDataZone) and is written at the factory; XC8 emits a
# `CALL 0x3FF` in startup and expects a `RETLW k` waiting there. A built HEX
# deliberately leaves that word absent so a programmer can preserve the device
# value; real preservation remains hardware-unvalidated. In gpsim the program
# counter runs off the end of flash and the part watchdog-resets in a LOOP, with
# main() never reached. Every simulator lane for this part therefore runs against
# a DERIVED image carrying an injected calibration word.
#
# WHY DERIVED AND NOT PATCHED IN PLACE. The shipping HEX is what the SHA-256
# baseline and the release provenance chain cover. Injecting into it would ship an
# image carrying a fabricated calibration value; baselining the injected one would
# pin an image no lane can run. So injection produces a separate artifact, and it
# lands in its own SUBDIRECTORY rather than beside the shipping images: several
# lanes reach for their input with `$(PIC12F675_BUILD_DIR)/...-*.hex`, and a
# derived image sitting in that glob's way is exactly the sort of thing that gets
# decoded, checksummed or released by accident. `$(PIC12F675_SIMCAL_DIR)` keeps
# the two populations from ever meeting.
#
# The injected value is a fixed documented constant so the lanes are
# deterministic -- see the injector's header for what that costs. It is also what
# the shell's OSCCAL guard snapshots at init, which is precisely what makes that
# guard testable: a fault harness corrupts OSCCAL (0x090) after init and requires
# a reset, with no compile-time expected value to have to agree about. Note one trap
# it records: gpsim gives the OSCCAL *register* its 0x80 reset value whether or
# not the flash word exists, so "OSCCAL reads 0x80" does NOT distinguish a
# working image from one looping on the missing word. The distinguishing evidence
# is that the shell's init ran at all (OPTION_REG 0x0C, CMCON 0x07, TRISIO 0x28).
PIC12F675_CAL_INJECTOR ?= test/pic/inject_calibration_word.py
# Simulation tests may replace the injector above. Hardware programming may not:
# this repository-owned path is the safety gate between a fabricated simulator
# calibration word and irreversible loss of a device's factory oscillator trim.
override PIC12F675_CAL_CHECKER := test/pic/inject_calibration_word.py
PIC12F675_CAL_VALUE    ?= 0x80
# Aggregate qualification binds every image consumer to one retained matrix.
# The helper and manifest location are validation mechanisms, not caller
# extension points; relocating PIC12F675_BUILD_DIR relocates the manifest too.
override PIC12F675_MATRIX_EVIDENCE := test/pic/pic12f675_matrix_evidence.py
override PIC12F675_MATRIX_MANIFEST := $(PIC12F675_BUILD_DIR)/.pic12f675-qualified-matrix.json
override PIC12F675_MATRIX_STAGED := $(PIC12F675_MATRIX_MANIFEST).staged
override PIC12F675_MAKE_COMMAND_TRUSTED := $(if $(filter default,$(origin MAKE_COMMAND)),1,0)
# Not independently caller-overridable: simulator images must stay in this
# dedicated subdirectory so no shipping-image glob can select them. Relocating
# PIC12F675_BUILD_DIR still relocates the complete target artifact tree.
override PIC12F675_SIMCAL_DIR := $(PIC12F675_BUILD_DIR)/simcal
override PIC12F675_SIMCAL_HEXES := $(foreach v,$(CLASSIC_VARIANTS_SUPPORTED),$(PIC12F675_SIMCAL_DIR)/$(call fw_image,$(v),$(PIC12F675_TAG))_simcal.hex)
# Derived images are build products: a `pic12f675` rebuild must not leave a stale
# one behind for a lane to pick up. Appended rather than folded into the original
# definition so the whole calibration story stays in this one block.
override PIC12F675_BUILD_PRODUCTS += $(PIC12F675_SIMCAL_HEXES) \
	$(PIC12F675_MATRIX_MANIFEST) $(PIC12F675_MATRIX_STAGED)

define pic12f675_matrix_evidence_cmd
python3 "$(PIC12F675_MATRIX_EVIDENCE)" $(1) \
	--build-dir "$(PIC12F675_BUILD_DIR)" --fw-base "$(FW_BASE)" \
	--tag "$(PIC12F675_TAG)"
endef

define pic12f675_require_trusted_make_sh
if [ "$(PIC12F675_MAKE_COMMAND_TRUSTED)" -ne 1 ]; then \
	echo "FAIL: MAKE_COMMAND is internal to PIC12F675 qualification"; exit 2; \
fi
endef

# Recompute every shipping/derived image and consumed .s/.sym sidecar, then
# compare the resulting twelve-artifact record with the one captured by the
# wrapper.
define pic12f675_verify_matrix_sh
current_matrix_record=`$(call pic12f675_matrix_evidence_cmd,verify)` || { \
	rm -f "$(PIC12F675_MATRIX_MANIFEST)"; exit 1; \
}; \
if [ "$$current_matrix_record" != "$$matrix_record" ]; then \
	echo "FAIL: PIC12F675 retained matrix record changed during aggregate execution"; \
	echo "      expected: $$matrix_record"; \
	echo "      observed: $$current_matrix_record"; \
	rm -f "$(PIC12F675_MATRIX_MANIFEST)"; exit 1; \
fi
endef

define pic12f675_verify_matrix_log_sh
current_matrix_record=`$(call pic12f675_matrix_evidence_cmd,verify)` || { \
	rm -f "$(PIC12F675_MATRIX_MANIFEST)" "$$log"; exit 1; \
}; \
if [ "$$current_matrix_record" != "$$matrix_record" ]; then \
	echo "FAIL: PIC12F675 retained matrix record changed during aggregate execution"; \
	echo "      expected: $$matrix_record"; \
	echo "      observed: $$current_matrix_record"; \
	rm -f "$(PIC12F675_MATRIX_MANIFEST)" "$$log"; exit 1; \
fi
endef

define pic12f675_load_matrix_sh
matrix_record=`$(call pic12f675_matrix_evidence_cmd,verify)` || { \
	rm -f "$(PIC12F675_MATRIX_MANIFEST)"; exit 1; \
}
endef

define pic12f675_verify_staged_matrix_sh
current_matrix_record=`$(call pic12f675_matrix_evidence_cmd,verify-staged)` || { \
	rm -f "$(PIC12F675_MATRIX_STAGED)"; exit 1; \
}; \
if [ "$$current_matrix_record" != "$$matrix_record" ]; then \
	echo "FAIL: PIC12F675 staged matrix record changed during qualification"; \
	rm -f "$(PIC12F675_MATRIX_STAGED)"; exit 1; \
fi
endef

define pic12f675_verify_staged_matrix_log_sh
current_matrix_record=`$(call pic12f675_matrix_evidence_cmd,verify-staged)` || { \
	rm -f "$(PIC12F675_MATRIX_STAGED)" "$$calibration_log"; exit 1; \
}; \
if [ "$$current_matrix_record" != "$$matrix_record" ]; then \
	echo "FAIL: PIC12F675 staged matrix record changed during qualification"; \
	rm -f "$(PIC12F675_MATRIX_STAGED)" "$$calibration_log"; exit 1; \
fi
endef

# Classify the complete derived-image set in the caller's current shell. Zero
# images remains the intentional no-XC8 skip; every nonzero subset is a hard
# failure. Present members must be nonempty regular files, never symlinks, and
# the dedicated directory may not contain an unregistered *_simcal.hex. The
# producer and every simulator consumer expand this same oracle so their set
# definitions cannot drift apart.
define pic12f675_simcal_matrix_sh
simcal_count=0; \
for simcal_image in $(PIC12F675_SIMCAL_HEXES); do \
	if [ -e "$$simcal_image" ] || [ -L "$$simcal_image" ]; then \
		if [ ! -f "$$simcal_image" ] || [ -L "$$simcal_image" ] || [ ! -s "$$simcal_image" ]; then \
			echo "FAIL: PIC12F675 simulator image is empty, a symlink, or not a regular file: $$simcal_image"; \
			exit 1; \
		fi; \
		simcal_count=$$((simcal_count + 1)); \
	fi; \
done; \
if [ $$simcal_count -ne 0 ] && [ $$simcal_count -ne 3 ]; then \
	echo "FAIL: PIC12F675 simulator image matrix is partial: found $$simcal_count of 3 expected images"; \
	exit 1; \
fi; \
for simcal_image in "$(PIC12F675_SIMCAL_DIR)"/*_simcal.hex "$(PIC12F675_SIMCAL_DIR)"/.*_simcal.hex; do \
	if [ ! -e "$$simcal_image" ] && [ ! -L "$$simcal_image" ]; then continue; fi; \
	simcal_known=0; \
	for simcal_expected in $(PIC12F675_SIMCAL_HEXES); do \
		[ "$$simcal_image" != "$$simcal_expected" ] || simcal_known=1; \
	done; \
	if [ $$simcal_known -ne 1 ]; then \
		echo "FAIL: unexpected PIC12F675 simulator image outside the exact matrix: $$simcal_image"; \
		exit 1; \
	fi; \
done
endef

# Derive the simulator images. Regenerates unconditionally -- the injector is
# cheap, and "the derived image is older than the HEX it came from" is precisely
# the silent staleness this target exists to make impossible. The trap removes
# the entire expected set after any failed injection or validation, so a failed
# producer cannot publish the prefix it completed before the failure. Classify a
# zero-image tree before probing Python: without XC8 there is no injector work,
# and the normal non-strict path must remain a clean tool-independent skip.
.PHONY: pic12f675-simcal
pic12f675-simcal: pic12f675 $(PIC12F675_CAL_INJECTOR)
	@simcal_complete=0; simcal_skipped=0; \
	cleanup_simcal_products() { \
		rc=$$1; \
		if [ $$rc -ne 0 ] || [ $$simcal_complete -ne 1 ]; then \
			rm -f $(PIC12F675_SIMCAL_HEXES) || rc=1; \
		fi; \
		if [ $$rc -eq 0 ] && [ $$simcal_complete -ne 1 ] && [ $$simcal_skipped -ne 1 ]; then rc=1; fi; \
		trap - 0 1 2 15; exit $$rc; \
	}; \
	trap 'cleanup_simcal_products $$?' 0; \
	trap 'cleanup_simcal_products 129' 1; \
	trap 'cleanup_simcal_products 130' 2; \
	trap 'cleanup_simcal_products 143' 15; \
	rm -f $(PIC12F675_SIMCAL_HEXES) || exit 1; \
	$(fw_image_sh); \
	have_hex=0; \
	for v in $(CLASSIC_VARIANTS_SUPPORTED); do \
		[ ! -f "$(PIC12F675_BUILD_DIR)/`fw_image_of "$$v" $(PIC12F675_TAG)`.hex" ] || have_hex=1; \
	done; \
	if [ $$have_hex -eq 0 ]; then \
		echo "no PIC12F675 HEX in $(PIC12F675_BUILD_DIR)/ (XC8 absent?); skipping calibration injection"; \
		simcal_skipped=1; \
		$(SKIP); \
	fi; \
	if ! command -v $(PIC12F675_PYTHON) >/dev/null 2>&1; then \
		echo "FAIL: $(PIC12F675_PYTHON) is required by the PIC12F675 calibration-word injector"; exit 1; \
	fi; \
	mkdir -p $(PIC12F675_SIMCAL_DIR) || exit 1; \
	for v in $(CLASSIC_VARIANTS_SUPPORTED); do \
		stem=`fw_image_of "$$v" $(PIC12F675_TAG)`; \
		hex=$(PIC12F675_BUILD_DIR)/$$stem.hex; \
		sim=$(PIC12F675_SIMCAL_DIR)/$${stem}_simcal.hex; \
		if [ ! -f "$$hex" ] || [ -L "$$hex" ] || [ ! -s "$$hex" ]; then \
			echo "FAIL: PIC12F675 image is missing, empty, or not regular: $$hex"; exit 1; \
		fi; \
		rm -f "$$sim" || exit 1; \
		$(PIC12F675_PYTHON) $(PIC12F675_CAL_INJECTOR) --flash-words $(PIC12F675_FLASH_WORDS) \
			--value $(PIC12F675_CAL_VALUE) "$$hex" "$$sim" || exit 1; \
		$(IHEX_VALIDATOR) "$$sim" || exit 1; \
	done; \
	$(pic12f675_simcal_matrix_sh); \
	if [ $$simcal_count -ne 3 ]; then \
		echo "FAIL: PIC12F675 simulator image producer did not publish all 3 images"; exit 1; \
	fi; \
	simcal_complete=1; \
	echo "=== PIC12F675 simulator images derived in $(PIC12F675_SIMCAL_DIR)/ ==="

# The calibration contract. Six properties, in the order they would bite:
#   1. the injector's own behaviour (its --selftest, which needs no toolchain);
#   2. shipping and derived inputs are each the complete three-image matrix;
#   3. injecting leaves the SHIPPING image byte-identical, and is deterministic --
#      both established by re-running it on the real image and comparing, because
#      "the derived image contains everything the shipping one did" (property 4)
#      would still hold if the injector had quietly rewritten its own input first;
#   4. the derived image differs from the shipping one by exactly the expected
#      calibration record -- whose encoding is computed here from the policy
#      constants, independently of the injector, because a record read back from
#      the thing under test could not fail;
#   5. the injector refuses to run again on its own output, so a lane cannot
#      quietly double-inject or inject the wrong part's image;
#   6. no derived image is reachable through a shipping-image glob.
.PHONY: pic12f675-test-calibration
pic12f675-test-calibration: pic12f675-simcal $(PIC12F675_CAL_INJECTOR)
	@if ! command -v python3 >/dev/null 2>&1; then \
		echo "FAIL: python3 is required by the PIC12F675 calibration-word injector"; exit 1; \
	fi
	@python3 $(PIC12F675_CAL_INJECTOR) --selftest
	@$(fw_image_sh); \
	shipping_count=0; \
	for v in $(CLASSIC_VARIANTS_SUPPORTED); do \
		shipping=$(PIC12F675_BUILD_DIR)/`fw_image_of "$$v" $(PIC12F675_TAG)`.hex; \
		if [ -e "$$shipping" ] || [ -L "$$shipping" ]; then \
			if [ ! -f "$$shipping" ] || [ -L "$$shipping" ] || [ ! -s "$$shipping" ]; then \
				echo "FAIL: PIC12F675 shipping image is empty, a symlink, or not a regular file: $$shipping"; exit 1; \
			fi; \
			shipping_count=$$((shipping_count + 1)); \
		fi; \
	done; \
	$(pic12f675_simcal_matrix_sh); \
	if [ $$shipping_count -eq 0 ] && [ $$simcal_count -eq 0 ]; then \
		echo "no PIC12F675 HEX (XC8 absent?); skipping calibration contract"; $(SKIP); \
	fi; \
	if [ $$shipping_count -ne 3 ]; then \
		echo "FAIL: PIC12F675 shipping image matrix is partial: found $$shipping_count of 3 expected images"; exit 1; \
	fi; \
	if [ $$simcal_count -ne 3 ]; then \
		echo "FAIL: PIC12F675 calibration contract requires all 3 derived simulator images"; exit 1; \
	fi; \
	checked=0; \
	for v in $(CLASSIC_VARIANTS_SUPPORTED); do \
		stem=`fw_image_of "$$v" $(PIC12F675_TAG)`; \
		hex=$(PIC12F675_BUILD_DIR)/$$stem.hex; \
		sim=$(PIC12F675_SIMCAL_DIR)/$${stem}_simcal.hex; \
		witness=$(PIC12F675_SIMCAL_DIR)/$$stem.witness; probe=$(PIC12F675_SIMCAL_DIR)/$$stem.probe; \
		rm -f "$$witness" "$$probe"; \
		cp "$$hex" "$$witness" || exit 1; \
		if ! python3 $(PIC12F675_CAL_INJECTOR) --flash-words $(PIC12F675_FLASH_WORDS) \
			--value $(PIC12F675_CAL_VALUE) "$$hex" "$$probe" >/dev/null; then \
			rm -f "$$witness" "$$probe"; \
			echo "FAIL: $$v: the injector failed on a second run over the shipping image"; exit 1; \
		fi; \
		if ! cmp -s "$$hex" "$$witness"; then \
			rm -f "$$witness" "$$probe"; \
			echo "FAIL: $$v: injecting MODIFIED the shipping image $$hex"; exit 1; \
		fi; \
		if ! cmp -s "$$sim" "$$probe"; then \
			rm -f "$$witness" "$$probe"; \
			echo "FAIL: $$v: injection is not deterministic -- a second run differs from $$sim"; exit 1; \
		fi; \
		rm -f "$$witness" "$$probe"; \
		added=`diff "$$hex" "$$sim" | grep -c '^>' || true`; \
		removed=`diff "$$hex" "$$sim" | grep -c '^<' || true`; \
		if [ "$$added" != 1 ] || [ "$$removed" != 0 ]; then \
			echo "FAIL: $$v: derived image differs from the shipping image by $$added added / $$removed removed records, expected 1 / 0"; \
			exit 1; \
		fi; \
		record=`diff "$$hex" "$$sim" | sed -n 's/^> //p'`; \
		expected=`python3 -c 'import sys; v=int(sys.argv[1],0); w=int(sys.argv[2],0)-1; b=w*2; op=0x3400|v; d=bytes([2,(b>>8)&0xFF,b&0xFF,0,op&0xFF,(op>>8)&0xFF]); print(":"+(d+bytes([(-sum(d))&0xFF])).hex().upper())' \
			'$(PIC12F675_CAL_VALUE)' '$(PIC12F675_FLASH_WORDS)'`; \
		if [ "$$record" != "$$expected" ]; then \
			echo "FAIL: $$v: calibration record is $$record, expected $$expected"; exit 1; \
		fi; \
		if ! python3 $(PIC12F675_CAL_INJECTOR) --flash-words $(PIC12F675_FLASH_WORDS) \
			--value $(PIC12F675_CAL_VALUE) "$$sim" "$$sim.reinjected" >/dev/null 2>&1; then :; else \
			rm -f "$$sim.reinjected"; \
			echo "FAIL: $$v: the injector accepted an already-injected image"; exit 1; \
		fi; \
		rm -f "$$sim.reinjected"; \
		echo "CALIBRATION PASS [$$v]: $$record injected, shipping image unchanged"; \
		checked=$$((checked + 1)); \
	done; \
	stray=`ls $(PIC12F675_BUILD_DIR)/*_simcal.hex 2>/dev/null || true`; \
	if [ -n "$$stray" ]; then \
		echo "FAIL: derived image(s) beside the shipping images, where a"; \
		echo "      shipping-image glob would pick them up:"; \
		printf '        %s\n' $$stray; \
		exit 1; \
	fi; \
	if [ $$checked -ne 3 ]; then \
		echo "FAIL: PIC12F675 calibration contract checked $$checked variants, expected 3"; exit 1; \
	fi; \
	echo "=== PIC12F675 calibration contract holds for all 3 variants ==="

# Build and qualify exactly one retained shipping/simulator matrix before any
# aggregate consumer runs. The private second shipping build is discarded: it
# exists only to reject compiler nondeterminism. The calibration contract's
# private probes independently reject injector nondeterminism. A successful
# manifest binds all six images plus the .s/.sym sidecars consumed by stack,
# fault, lock-step and I/O; public wrappers verify it after every lane.
.PHONY: _pic12f675-qualify-matrix
_pic12f675-qualify-matrix: pic12f675-target-selector-valid pic12f675-simcal $(PIC12F675_MATRIX_EVIDENCE)
	@$(pic12f675_require_trusted_make_sh); \
	qualified=0; skipped=0; final_owned=0; witness=; calibration_log=; \
	cleanup_qualification() { \
		rc=$$?; \
		if [ -n "$$witness" ] && [ -e "$$witness" ]; then \
			chmod -R u+w "$$witness" 2>/dev/null || :; rm -rf "$$witness" || rc=1; \
		fi; \
		if [ -n "$$calibration_log" ] && [ -e "$$calibration_log" ]; then \
			rm -f "$$calibration_log" || rc=1; \
		fi; \
		if [ $$rc -ne 0 ] || [ $$qualified -ne 1 ]; then \
			if [ $$final_owned -eq 1 ]; then \
				rm -f "$(PIC12F675_MATRIX_MANIFEST)" || rc=1; \
			fi; \
			rm -f "$(PIC12F675_MATRIX_STAGED)" || rc=1; \
		fi; \
		if [ $$rc -eq 0 ] && [ $$qualified -ne 1 ] && [ $$skipped -ne 1 ]; then rc=1; fi; \
		trap - 0 1 2 15; exit $$rc; \
	}; \
	trap cleanup_qualification 0; \
	trap 'exit 129' 1; trap 'exit 130' 2; trap 'exit 143' 15; \
	rm -f "$(PIC12F675_MATRIX_MANIFEST)" "$(PIC12F675_MATRIX_STAGED)" || exit 1; \
	set -- $(PIC12F675_HEXES) $(PIC12F675_SIMCAL_HEXES); \
	present=0; for image in "$$@"; do \
		[ ! -e "$$image" ] && [ ! -L "$$image" ] || present=$$((present + 1)); \
	done; \
	if [ $$present -eq 0 ]; then \
		echo "no PIC12F675 shipping/simulator matrix (XC8 absent?); skipping aggregate qualification"; \
		skipped=1; $(SKIP); \
	fi; \
	matrix_record=`$(call pic12f675_matrix_evidence_cmd,stage)` || exit 1; \
	witness=`mktemp -d "$(PIC12F675_BUILD_DIR).qualify.XXXXXX"` || exit 1; \
	if ! $(PROJECT_MAKE) --no-print-directory PIC12F675_BUILD_DIR="$$witness" \
			pic12f675; then \
		echo "FAIL: private PIC12F675 reproducibility matrix did not build"; exit 1; \
	fi; \
	if ! python3 "$(PIC12F675_MATRIX_EVIDENCE)" compare-shipping-staged \
			--build-dir "$(PIC12F675_BUILD_DIR)" \
			--candidate-build-dir "$$witness" --fw-base "$(FW_BASE)" \
			--tag "$(PIC12F675_TAG)" >/dev/null; then \
		echo "FAIL: retained PIC12F675 shipping matrix is not compiler-reproducible"; exit 1; \
	fi; \
	$(pic12f675_verify_staged_matrix_sh); \
	calibration_log=`mktemp` || exit 1; calibration_rc=0; \
		$(PROJECT_MAKE) --no-print-directory --old-file=pic12f675-simcal \
			pic12f675-test-calibration >"$$calibration_log" 2>&1 || calibration_rc=$$?; \
	$(pic12f675_verify_staged_matrix_log_sh); \
	replay_rc=0; cat "$$calibration_log" || replay_rc=$$?; \
	rm -f "$$calibration_log" || exit 1; \
	if [ $$replay_rc -ne 0 ]; then exit $$replay_rc; fi; \
	if [ $$calibration_rc -ne 0 ]; then \
		echo "FAIL: retained PIC12F675 simulator matrix failed calibration qualification"; \
		exit $$calibration_rc; \
	fi; \
	promoted_record=`$(call pic12f675_matrix_evidence_cmd,promote)` || exit 1; \
	final_owned=1; \
	if [ "$$promoted_record" != "$$matrix_record" ]; then \
		echo "FAIL: promoted PIC12F675 matrix record changed"; exit 1; \
	fi; \
	rm -f "$(PIC12F675_MATRIX_STAGED)" || exit 1; \
	$(pic12f675_verify_matrix_sh); \
	qualified=1; \
	echo "=== PIC12F675 retained matrix qualified: $$matrix_record ==="

# --- PIC12F675 authoritative aggregates ---------------------------------------
# Two aggregates, split the way both 10F32x parts split theirs, because they
# answer different questions at different cost:
#
#   pic12f675-test         every pre-hardware check that needs no libgpsim --
#                          the CONFIG decode, static analysis, host coverage,
#                          the calibration contract, the gpsim CLI lane and the
#                          hardware return-stack bound.
#   pic12f675-test-target  the three libgpsim lanes against a real HEX, for ONE
#                          variant; -test-target-variants sweeps the matrix.
#
# The soak is in NEITHER, exactly as on both 10F32x parts: an hour of simulated
# time per variant is a long-duration command, not a pre-hardware check.
#
# The host coverage lane is ALSO a direct member of `make test`, and has to be.
# This aggregate skips as a whole when XC8 has qualified no matrix -- correct for
# every other lane, since each one reads a real HEX -- which left the one lane
# that needs no XC8 unrun on exactly the hosts where it was the only PIC evidence
# available. Listing it here as well costs a few seconds and keeps this aggregate
# the complete pre-hardware statement for the part.
#
# WHY THE CALIBRATION CONTRACT IS LISTED HERE and not left implied by the lanes.
# Every simulator lane for this part depends on pic12f675-simcal, so the derived
# images get PRODUCED whatever else runs; what no other lane checks is that
# producing them left the SHIPPING images untouched. That is the property whose
# failure would ship a HEX different from the one the simulator lanes qualified,
# and it is unique to this part -- neither 10F32x part derives anything.
.PHONY: pic12f675-test
pic12f675-test: _pic12f675-qualify-matrix
	@$(pic12f675_require_trusted_make_sh); \
	if [ ! -f "$(PIC12F675_MATRIX_MANIFEST)" ]; then \
		echo "no qualified PIC12F675 matrix (XC8 absent?); skipping pre-hardware aggregate"; \
		$(SKIP); \
	fi; \
	$(pic12f675_load_matrix_sh); \
	for spec in \
		"pic12f675-test-config|--old-file=pic12f675" \
		"pic12f675-analyze|" \
		"pic12f675-coverage-check-fw|" \
		"pic12f675-test-gpsim|--old-file=pic12f675-simcal" \
		"pic12f675-test-stack-bound|--old-file=pic12f675"; do \
		target=$${spec%%|*}; old=$${spec#*|}; log=`mktemp` || exit 1; lane_rc=0; \
		$(PROJECT_MAKE) --no-print-directory $$old $$target >"$$log" 2>&1 || lane_rc=$$?; \
		$(pic12f675_verify_matrix_log_sh); \
		replay_rc=0; cat "$$log" || replay_rc=$$?; rm -f "$$log" || exit 1; \
		if [ $$lane_rc -ne 0 ]; then exit $$lane_rc; fi; \
		if [ $$replay_rc -ne 0 ]; then exit $$replay_rc; fi; \
	done; \
	$(pic12f675_verify_matrix_sh); \
	echo "=== all PIC12F675 pre-hardware checks complete: $$matrix_record ==="

# Fail-closed real-HEX aggregate, structurally identical to pic10f322-test-target
# and for the same reason: each lane below exits 0 through $(SKIP) when XC8,
# gpsim-dev or glib is absent, which is right for a standalone development
# command and useless in a gate. So this wrapper requires one exact, terminal,
# variant-bound result record with the canonical check count and zero failures;
# a skipped, truncated, duplicated or contradictory lane fails here.
#
# No build-variant threading, unlike pic10f320-test-target: `pic12f675-simcal`
# (the prerequisite every lane shares) derives the WHOLE three-image matrix, as
# `pic10f322` builds the 322's, so forwarding the lane selector is sufficient --
# there is no second variable that could select a different variant's image.
PIC12F675_TARGET_VARIANT ?= cd4053_simple
override PIC12F675_TARGET_VARIANTS_SUPPORTED := $(CLASSIC_VARIANTS_SUPPORTED)
.PHONY: pic12f675-test-target pic12f675-test-target-variants
pic12f675-test-target: pic12f675-target-selector-valid variant-selectors-valid _pic12f675-qualify-matrix
	@$(pic12f675_require_trusted_make_sh); \
	if [ ! -f "$(PIC12F675_MATRIX_MANIFEST)" ]; then \
		echo "FAIL: PIC12F675 target aggregate requires a qualified image matrix"; exit 1; \
	fi; \
	$(pic12f675_load_matrix_sh); \
	set -e; \
	for spec in \
		"pic12f675-test-fault PIC12F675_FAULT_VARIANT=$(PIC12F675_TARGET_VARIANT)|fault|FAULT-INJECT|variant" \
		"pic12f675-test-lockstep PIC12F675_LOCKSTEP_VARIANT=$(PIC12F675_TARGET_VARIANT)|lockstep|LOCK-STEP|3005" \
		"pic12f675-test-io PIC12F675_IO_VARIANT=$(PIC12F675_TARGET_VARIANT)|io|TARGET-IO|variant"; do \
		target=$${spec%%|*}; fields=$${spec#*|}; lane=$${fields%%|*}; \
		fields=$${fields#*|}; human=$${fields%%|*}; checks=$${fields#*|}; \
		if [ "$$checks" = variant ]; then \
			case "$$lane:$(PIC12F675_TARGET_VARIANT)" in \
				fault:cd4053_simple) checks=38 ;; \
				fault:cd4053_with_mute) checks=38 ;; \
				fault:tq2_l2_5v_relay) checks=43 ;; \
				io:cd4053_simple) checks=25 ;; \
				io:cd4053_with_mute) checks=26 ;; \
				io:tq2_l2_5v_relay) checks=36 ;; \
				*) echo "FAIL: no check count for $$lane/$(PIC12F675_TARGET_VARIANT)"; exit 2 ;; \
			esac; \
		fi; \
		expected="PIC_TARGET_RESULT format=1 device=pic12f675 lane=$$lane variant=$(PIC12F675_TARGET_VARIANT) status=pass checks=$$checks failures=0"; \
		human_pass="$$human PASS: $$checks checks, 0 failures"; \
		log=`mktemp`; lane_rc=0; \
		$(PROJECT_MAKE) --no-print-directory --old-file=pic12f675-simcal \
			$$target >"$$log" 2>&1 || lane_rc=$$?; \
		$(pic12f675_verify_matrix_log_sh); \
		if [ $$lane_rc -ne 0 ]; then cat "$$log"; rm -f "$$log"; exit $$lane_rc; fi; \
		result_count=`grep -c '^PIC_TARGET_RESULT ' "$$log" || true`; \
		result=`grep '^PIC_TARGET_RESULT ' "$$log" || true`; \
		human_count=`grep -cFx "$$human_pass" "$$log" || true`; \
		terminal=`$(AWK) 'NF { line=$$0 } END { print line }' "$$log"`; \
		if [ "$$result_count" -ne 1 ] || [ "$$result" != "$$expected" ] \
				|| [ "$$human_count" -ne 1 ] \
				|| [ "$$terminal" != "$$expected" ] \
				|| grep -q "^$$human FAIL:" "$$log"; then \
			echo "FAIL: $$target did not report one exact terminal result:"; \
			echo "      expected: $$expected"; \
			echo "      observed records: $$result_count"; \
			echo "      exact human PASS summaries: $$human_count"; \
			cat "$$log"; rm -f "$$log"; exit 1; \
		fi; \
		replay_rc=0; cat "$$log" || replay_rc=$$?; rm -f "$$log" || exit 1; \
		if [ $$replay_rc -ne 0 ]; then exit $$replay_rc; fi; \
	done; \
	$(pic12f675_verify_matrix_sh); \
	echo "=== PIC12F675 target fault/lock-step/I-O PASS (variant $(PIC12F675_TARGET_VARIANT)): $$matrix_record ==="

# ...and for ALL of them. Requires the exact supported set before running, so
# "all variants passed" cannot hide an empty or incomplete matrix (§6.5).
pic12f675-test-target-variants: pic12f675-target-selector-valid variant-selectors-valid _pic12f675-qualify-matrix
	@$(pic12f675_require_trusted_make_sh); \
	if [ "$(CLASSIC_VARIANTS_REQUEST_EMPTY)" -eq 1 ]; then \
		echo "FAIL: VARIANTS must not be empty" >&2; exit 2; \
	fi; \
	if [ "$(CLASSIC_VARIANTS_REQUEST_DUPLICATE)" -eq 1 ]; then \
		echo "FAIL: VARIANTS must not contain duplicate names" >&2; exit 2; \
	fi; \
	if [ "$(CLASSIC_VARIANTS_REQUEST_UNKNOWN)" -eq 1 ]; then \
		echo "FAIL: VARIANTS contains unsupported names; supported: $(PIC12F675_TARGET_VARIANTS_SUPPORTED)" >&2; exit 2; \
	fi; \
	if [ "$(if $(filter-out $(VARIANTS),$(PIC12F675_TARGET_VARIANTS_SUPPORTED)),yes,no)" = yes ]; then \
		echo "FAIL: VARIANTS must contain every supported name; required: $(PIC12F675_TARGET_VARIANTS_SUPPORTED)" >&2; exit 2; \
	fi
	@if [ ! -f "$(PIC12F675_MATRIX_MANIFEST)" ]; then \
		echo "FAIL: PIC12F675 all-variant target aggregate requires a qualified image matrix"; exit 1; \
	fi; \
	$(pic12f675_load_matrix_sh); \
	for v in $(PIC12F675_TARGET_VARIANTS_SUPPORTED); do \
		echo "===================== PIC12F675 TARGET VARIANT $$v ====================="; \
		lane_rc=0; \
		$(PROJECT_MAKE) --no-print-directory --old-file=_pic12f675-qualify-matrix \
			PIC12F675_TARGET_VARIANT=$$v pic12f675-test-target || lane_rc=$$?; \
		$(pic12f675_verify_matrix_sh); \
		if [ $$lane_rc -ne 0 ]; then exit $$lane_rc; fi; \
	done; \
	$(pic12f675_verify_matrix_sh); \
	echo "=== PIC12F675 target fault/lock-step/I-O validated for all variants: $$matrix_record ==="

# --- PIC12F675 device programming (hardware) ----------------------------------
# Flash ONE built variant (chosen by VARIANT, default $(VARIANT)) onto a real
# PIC12F675. Same shape as pic10f322-program and for the same reasons: the
# CONFIG word rides inside the HEX -- XC8's `#pragma config` -- so there is no
# separate fuse step, and the power default is conservative (the programmer does
# NOT source Vdd, which is safe for an externally powered pedal board). The
# target intentionally does not ask the programmer to source Vdd; externally
# power the board. Programmer-powered bare-chip operation needs its own validated
# voltage interface rather than a whole-command escape hatch. PIC12F675_PROG
# names the executable;
# PIC12F675_PROG_KIND selects the validated pk2cmd/ipecmd argument dialect when
# the executable has been path-qualified or renamed. The guarded target accepts
# no image or whole-command override: both could separate checked bytes from the
# bytes the programmer consumes.
#
# THIS TARGET IS THE PIC12F675 BENCH-PROGRAMMING WORKFLOW, AND HOW ITS 1.x.y
# HARDWARE VALIDATION GETS DONE. docs/pic12f675_feasibility.md section 8 items 1
# and 2 -- whether a programmer preserves the factory bandgap trim in CONFIG and
# the oscillator calibration word in flash -- are silicon-only risks. No
# simulator lane can reach them; they close at a bench, with this command, or not
# at all. The part is release-supported in software at 0.9.x like every other
# target -- none of which carries a controlled hardware-qualification record
# either (HARDWARE_VALIDATION_LOG.md section 2; the field-use reports in its
# section 1 are a different kind of evidence and close nothing here) -- and these
# residual risks are the 1.x.y hardware pass, tracked as TODO.md
# T3-pic12f675-bench. So the target makes their bench measurement the
# transaction: a read-only baseline must
# exist, the live device must still match it immediately before the write, and a
# post-write readback/result is mandatory.
#
# ON TOOL SUPPORT (section 8 item 8). PICkit 2 has long covered this family, and
# the pinned device pack registers PIC12F675 with the same MPLAB hardware-tool
# set as the PIC10F322 this project already programs -- a byte-identical hwtool
# file list in the pack's .pdsc, and both parts named in every sdm*.xml that
# names either. That is evidence current MPLAB/IPE device support still lists
# the part (docs/pic12f675_feasibility.md section 10 reproduces the two lists). It is not a substitute for running the programmer once; neither
# pk2cmd nor ipecmd is installed on any machine this repository is tested on.
override PIC12F675_PART := PIC12F675
PIC12F675_PROG      ?= pk2cmd
PIC12F675_PROG_KIND ?= $(if $(filter ipecmd,$(notdir $(PIC12F675_PROG))),ipecmd,pk2cmd)
PIC12F675_PROG_TOOL ?= PK4
# pk2cmd's read-to-HEX path is the only readback dialect pinned here. An ipecmd
# write can still be measured, but needs a separately connected pk2cmd reader;
# guessing an untested IPE read command would turn the safety gate into theatre.
PIC12F675_READ_PROG ?= $(if $(filter pk2cmd,$(PIC12F675_PROG_KIND)),$(PIC12F675_PROG),pk2cmd)
PIC12F675_TRIM_EVIDENCE ?=
PIC12F675_BENCH_RESULT ?=
override PIC12F675_TRIM_EVIDENCE_TOOL := test/pic/pic12f675_trim_evidence.py
override PIC12F675_RELEASE_IMAGE_CHECKER := scripts/verify-release-program-image.sh
export PIC12F675_PART PIC12F675_PROG PIC12F675_PROG_KIND PIC12F675_PROG_TOOL \
       PIC12F675_READ_PROG PIC12F675_TRIM_EVIDENCE PIC12F675_BENCH_RESULT \
       PIC12F675_RELEASE_TAG

# Capture the factory values without issuing any erase/write option. The raw
# programmer version and device transcripts, target Device ID/revision, complete
# read HEX digest, word 0x3FF, CONFIG and BG<1:0> are retained in one exclusive
# evidence file. The output path is mandatory and may not already exist.
# Transient full-device reads use TMPDIR when set, otherwise XDG_RUNTIME_DIR,
# otherwise HOME. The root must already exist, be current-user-private, and may
# not be shared /tmp or /var/tmp.
.PHONY: pic12f675-preflight
pic12f675-preflight: $(PIC12F675_TRIM_EVIDENCE_TOOL)
	@if [ "$(if $(filter undefined,$(origin PIC12F675_PROG_HEX)),0,1)" -ne 0 ]; then \
		echo "ERROR: PIC12F675_PROG_HEX is not supported by the guarded hardware workflow."; \
		exit 1; \
	fi; \
	if [ "$(if $(filter undefined,$(origin PIC12F675_PROG_CMD)),0,1)" -ne 0 ]; then \
		echo "ERROR: PIC12F675_PROG_CMD is not supported by the guarded hardware workflow."; \
		exit 1; \
	fi; \
	evidence=$$PIC12F675_TRIM_EVIDENCE; \
	reader=$$PIC12F675_READ_PROG; \
	part=$$PIC12F675_PART; \
	if [ -z "$$evidence" ]; then \
		echo "ERROR: PIC12F675_TRIM_EVIDENCE is required for read-only baseline capture."; \
		exit 1; \
	fi; \
	if [ -e "$$evidence" ] || [ -L "$$evidence" ]; then \
		echo "ERROR: trim-evidence output already exists; refusing to overwrite: $$evidence"; \
		exit 1; \
	fi; \
	case "$$reader" in \
		*/*) [ -f "$$reader" ] && [ -x "$$reader" ]; reader_path=$$reader ;; \
		*) reader_path=`command -v "$$reader" 2>/dev/null` ;; \
	esac; \
	if [ -z "$$reader_path" ] || [ ! -f "$$reader_path" ] || [ ! -x "$$reader_path" ]; then \
		echo "ERROR: pk2cmd reader '$$reader' not found or not executable."; \
		echo "       Set PIC12F675_READ_PROG to a pk2cmd executable."; \
		exit 1; \
	fi; \
	if ! command -v python3 >/dev/null 2>&1; then \
		echo "ERROR: python3 is required to create trim evidence."; exit 1; \
	fi; \
	if ! command -v sha256sum >/dev/null 2>&1; then \
		echo "ERROR: sha256sum is required to bind the reader executable to its evidence."; exit 1; \
	fi; \
	$(IHEX_VALIDATOR_CHECK); \
	hash_file() { \
		hash_output=`sha256sum -- "$$1"` || return 1; \
		hash_digest=$${hash_output%% *}; \
		case "$$hash_digest" in ''|*[!0-9a-f]*) return 1 ;; esac; \
		[ $${#hash_digest} -eq 64 ] || return 1; \
		printf '%s' "$$hash_digest"; \
	}; \
	temp_root=$${TMPDIR:-$${XDG_RUNTIME_DIR:-$${HOME:-}}}; \
	if [ -z "$$temp_root" ] || [ ! -d "$$temp_root" ]; then \
		echo "ERROR: set TMPDIR, XDG_RUNTIME_DIR, or HOME to an existing private temporary root."; \
		exit 1; \
	fi; \
	temp_root=`CDPATH= cd -- "$$temp_root" && pwd -P` || exit 1; \
	while [ "$${temp_root#//}" != "$$temp_root" ]; do temp_root=/$${temp_root#//}; done; \
	case "$$temp_root" in \
		/tmp|/tmp/*|/var/tmp|/var/tmp/*) \
			echo "ERROR: refusing shared temporary root $$temp_root; select private TMPDIR."; exit 1 ;; \
		*[!A-Za-z0-9_./\ -]*) \
			echo "ERROR: private temporary root contains unsupported path characters: $$temp_root"; exit 1 ;; \
	esac; \
	temp_root_uid=`stat -Lc '%u' -- "$$temp_root"` || exit 1; \
	current_uid=`id -u` || exit 1; \
	temp_root_mode=`stat -Lc '%a' -- "$$temp_root"` || exit 1; \
	case "$$temp_root_mode" in ''|*[!0-7]*) \
		echo "ERROR: could not determine private temporary root permissions."; exit 1 ;; \
	esac; \
	if [ "$$temp_root_uid" != "$$current_uid" ] || [ $$((0$$temp_root_mode & 077)) -ne 0 ]; then \
		echo "ERROR: private temporary root must be owned by the current user with no group/other access: $$temp_root"; \
		exit 1; \
	fi; \
	ancestor=$$temp_root; \
	while [ "$$ancestor" != / ]; do \
		ancestor=$${ancestor%/*}; [ -n "$$ancestor" ] || ancestor=/; \
		ancestor_mode=`stat -Lc '%a' -- "$$ancestor"` || exit 1; \
		ancestor_uid=`stat -Lc '%u' -- "$$ancestor"` || exit 1; \
		case "$$ancestor_mode" in ''|*[!0-7]*) \
			echo "ERROR: could not determine temporary-root ancestor permissions."; exit 1 ;; \
		esac; \
		if [ "$$ancestor_uid" != 0 ] && [ "$$ancestor_uid" != "$$current_uid" ]; then \
			echo "ERROR: private temporary root has an ancestor not owned by root or the current user: $$ancestor"; exit 1; \
		fi; \
		if [ $$((0$$ancestor_mode & 022)) -ne 0 ]; then \
			echo "ERROR: private temporary root has a group/other-writable ancestor: $$ancestor"; exit 1; \
		fi; \
	done; \
	bench_dir="$$temp_root/pic12f675-preflight.$$$$"; bench_created=0; \
	setup_in_progress=1; pending_signal=0; \
	cleanup_preflight() { \
		rc=$$1; trap - 0 1 2 15; \
		if [ "$$bench_created" -eq 1 ]; then rm -rf -- "$$bench_dir" || rc=1; fi; \
		exit $$rc; \
	}; \
	handle_preflight_signal() { \
		if [ "$$setup_in_progress" -eq 1 ]; then pending_signal=$$1; return; fi; \
		cleanup_preflight $$1; \
	}; \
	trap 'cleanup_preflight $$?' 0; \
	trap 'handle_preflight_signal 129' 1; \
	trap 'handle_preflight_signal 130' 2; \
	trap 'handle_preflight_signal 143' 15; \
	if (trap '' 1 2 15; umask 077 && mkdir -- "$$bench_dir"); then bench_created=1; else \
		setup_in_progress=0; \
		if [ "$$pending_signal" -ne 0 ]; then cleanup_preflight "$$pending_signal"; fi; \
		echo "ERROR: could not exclusively create a private preflight directory."; exit 1; \
	fi; \
	setup_in_progress=0; \
	if [ "$$pending_signal" -ne 0 ]; then cleanup_preflight "$$pending_signal"; fi; \
	version_log="$$bench_dir/pk2cmd-version.log"; \
	read_log="$$bench_dir/device-read.log"; \
	read_hex="$$bench_dir/device-read.hex"; \
	reader_digest_before=`hash_file "$$reader_path"` || exit 1; \
	if ! "$$reader_path" '-?V' >"$$version_log" 2>&1; then \
		cat "$$version_log"; echo "ERROR: pk2cmd version query failed."; exit 1; \
	fi; \
	if ! "$$reader_path" "-P$$part" -I "-GF$$read_hex" -R >"$$read_log" 2>&1; then \
		cat "$$read_log"; echo "ERROR: read-only PIC12F675 baseline capture failed."; exit 1; \
	fi; \
	reader_digest_after=`hash_file "$$reader_path"` || exit 1; \
	if [ "$$reader_digest_before" != "$$reader_digest_after" ]; then \
		echo "ERROR: pk2cmd reader changed during baseline capture."; exit 1; \
	fi; \
	cat "$$version_log"; cat "$$read_log"; \
	$(IHEX_VALIDATOR) "$$read_hex" || exit 1; \
	baseline_output=`python3 "$(PIC12F675_TRIM_EVIDENCE_TOOL)" baseline \
		--reader-path "$$reader_path" --version-log "$$version_log" \
		--read-log "$$read_log" --read-hex "$$read_hex" --output "$$evidence"` || exit 1; \
	expected_baseline="PIC12F675_TRIM_BASELINE PASS evidence=$$evidence"; \
	if [ "$$baseline_output" != "$$expected_baseline" ] || \
			[ ! -f "$$evidence" ] || [ -L "$$evidence" ] || [ ! -s "$$evidence" ]; then \
		echo "ERROR: trim-evidence oracle did not emit its exact baseline record."; exit 1; \
	fi; \
	printf '%s\n' "$$baseline_output"

# Resolve a retained PENDING transaction without issuing an erase/write command.
# The reservation binds the original baseline, image, part, variant, reader and
# writer identities plus signed-release tag/source identity when applicable.
# Validate all of them before touching hardware, then perform only a pk2cmd
# version query and full-device read. The recovery oracle publishes result.json
# exclusively, including a durable FAIL when the live state differs.
.PHONY: pic12f675-finalize
pic12f675-finalize: variant-selectors-valid $(PIC12F675_TRIM_EVIDENCE_TOOL) \
                    $(PIC12F675_RELEASE_IMAGE_CHECKER)
	@if [ "$(if $(filter undefined,$(origin PIC12F675_PROG_HEX)),0,1)" -ne 0 ]; then \
		echo "ERROR: PIC12F675_PROG_HEX is not supported by read-only finalization."; exit 1; \
	fi; \
	if [ "$(if $(filter undefined,$(origin PIC12F675_PROG_CMD)),0,1)" -ne 0 ]; then \
		echo "ERROR: PIC12F675_PROG_CMD is not supported by read-only finalization."; exit 1; \
	fi; \
	evidence=$$PIC12F675_TRIM_EVIDENCE; \
	result=$$PIC12F675_BENCH_RESULT; \
	reader=$$PIC12F675_READ_PROG; \
	writer=$$PIC12F675_PROG; \
	writer_kind=$$PIC12F675_PROG_KIND; \
	part=$$PIC12F675_PART; \
	variant="$(VARIANT)"; \
	release_tag=$$PIC12F675_RELEASE_TAG; release_source_commit=; \
	if [ -z "$$evidence" ]; then \
		echo "ERROR: PIC12F675_TRIM_EVIDENCE is required for transaction finalization."; exit 1; \
	fi; \
	if [ -z "$$result" ] || [ ! -d "$$result" ] || [ -L "$$result" ]; then \
		echo "ERROR: PIC12F675_BENCH_RESULT must name a real PENDING transaction directory."; exit 1; \
	fi; \
	reservation="$$result/reservation.json"; \
	if [ ! -f "$$reservation" ] || [ -L "$$reservation" ] || [ ! -s "$$reservation" ]; then \
		echo "ERROR: pending transaction has no regular nonempty reservation.json."; exit 1; \
	fi; \
	case "$$writer_kind" in \
		pk2cmd|ipecmd) : ;; \
		*) echo "ERROR: PIC12F675_PROG_KIND must be exactly pk2cmd or ipecmd; got '$$writer_kind'."; exit 1 ;; \
	esac; \
	case "$$reader" in \
		*/*) [ -f "$$reader" ] && [ -x "$$reader" ]; reader_path=$$reader ;; \
		*) reader_path=`command -v "$$reader" 2>/dev/null` ;; \
	esac; \
	if [ -z "$$reader_path" ] || [ ! -f "$$reader_path" ] || [ ! -x "$$reader_path" ]; then \
		echo "ERROR: pk2cmd reader '$$reader' not found or not executable."; exit 1; \
	fi; \
	case "$$writer" in \
		*/*) [ -f "$$writer" ] && [ -x "$$writer" ]; writer_path=$$writer ;; \
		*) writer_path=`command -v "$$writer" 2>/dev/null` ;; \
	esac; \
	if [ -z "$$writer_path" ] || [ ! -f "$$writer_path" ] || [ ! -x "$$writer_path" ]; then \
		echo "ERROR: reserved writer '$$writer' not found or not executable."; exit 1; \
	fi; \
	if [ -n "$$release_tag" ]; then \
		release_source_commit=`git rev-parse --verify "refs/tags/$$release_tag^{commit}" 2>/dev/null` || { \
			echo "ERROR: cannot resolve selected PIC12F675 release tag: $$release_tag"; exit 1; \
		}; \
		case "$$release_source_commit" in \
			????????????????????????????????????????) : ;; \
			*) echo "ERROR: selected PIC12F675 release commit is not a full SHA-1."; exit 1 ;; \
		esac; \
	fi; \
	if ! command -v python3 >/dev/null 2>&1; then \
		echo "ERROR: python3 is required to finalize PIC12F675 evidence."; exit 1; \
	fi; \
	$(IHEX_VALIDATOR_CHECK); \
	recovery_ready=`python3 "$(PIC12F675_TRIM_EVIDENCE_TOOL)" recovery-check \
		--baseline "$$evidence" --reservation "$$reservation" \
		--part "$$part" --variant "$$variant" --reader-path "$$reader_path" \
		--writer-kind "$$writer_kind" --writer-path "$$writer_path" \
		--release-tag "$$release_tag" --release-source-commit "$$release_source_commit" \
		--output-dir "$$result"` || exit 1; \
	expected_ready="PIC12F675_TRIM_RECOVERY_READY PASS evidence-dir=$$result"; \
	if [ "$$recovery_ready" != "$$expected_ready" ]; then \
		echo "ERROR: recovery oracle did not emit its exact readiness record."; exit 1; \
	fi; \
	printf '%s\n' "$$recovery_ready"; \
	for stale_attempt in "$$result"/.recovery-*; do \
		if [ ! -e "$$stale_attempt" ] && [ ! -L "$$stale_attempt" ]; then continue; fi; \
		if [ ! -d "$$stale_attempt" ] || [ -L "$$stale_attempt" ]; then \
			echo "ERROR: invalid stale recovery-attempt path: $$stale_attempt"; exit 1; \
		fi; \
		rm -rf -- "$$stale_attempt" || exit 1; \
	done; \
	attempt=`mktemp -d "$$result/.recovery-XXXXXX"` || { \
		echo "ERROR: could not create private recovery-attempt directory."; exit 1; \
	}; \
	cleanup_recovery_attempt() { \
		rc=$$1; trap - 0 1 2 15; \
		if [ -n "$$attempt" ] && [ -d "$$attempt" ] && [ ! -L "$$attempt" ]; then \
			rm -rf -- "$$attempt" || rc=1; \
		fi; \
		exit $$rc; \
	}; \
	trap 'cleanup_recovery_attempt $$?' 0; \
	trap 'exit 129' 1; trap 'exit 130' 2; trap 'exit 143' 15; \
	if [ -n "$$release_tag" ]; then \
		release_source_check=`TMPDIR="$$attempt" "$(PIC12F675_RELEASE_IMAGE_CHECKER)" \
			source "$$release_tag"` || exit 1; \
		expected_release_source="PIC12F675_RELEASE_SOURCE_CHECK PASS tag=$$release_tag"; \
		if [ "$$release_source_check" != "$$expected_release_source" ]; then \
			echo "ERROR: release source checker did not emit its exact success record."; exit 1; \
		fi; \
		verified_source_commit=`git rev-parse --verify "refs/tags/$$release_tag^{commit}" 2>/dev/null` || exit 1; \
		if [ "$$verified_source_commit" != "$$release_source_commit" ]; then \
			echo "ERROR: selected PIC12F675 release tag changed during finalization."; exit 1; \
		fi; \
		retained_digest_line=`sha256sum -- "$$result/image.hex"` || exit 1; \
		retained_digest=$${retained_digest_line%% *}; \
		case "$$retained_digest" in \
			????????????????????????????????????????????????????????????????) : ;; \
			*) echo "ERROR: could not identify retained PIC12F675 image digest."; exit 1 ;; \
		esac; \
		release_image_check=`TMPDIR="$$attempt" "$(PIC12F675_RELEASE_IMAGE_CHECKER)" \
			image "$$release_tag" "$$variant" "$$result/image.hex"` || exit 1; \
		expected_release_image="PIC12F675_RELEASE_IMAGE_CHECK PASS tag=$$release_tag variant=$$variant image=$$result/image.hex sha256=$$retained_digest"; \
		if [ "$$release_image_check" != "$$expected_release_image" ]; then \
			echo "ERROR: release image checker did not emit its exact success record."; exit 1; \
		fi; \
		printf '%s\n%s\n' "$$release_source_check" "$$release_image_check"; \
	fi; \
	version_log="$$attempt/reader-version.log"; \
	read_log="$$attempt/device-read.log"; \
	read_hex="$$attempt/device-read.hex"; \
	version_rc=0; \
	"$$reader_path" '-?V' >"$$version_log" 2>&1 || version_rc=$$?; \
	reader_ready=`python3 "$(PIC12F675_TRIM_EVIDENCE_TOOL)" recovery-version-check \
		--baseline "$$evidence" --reservation "$$reservation" \
		--part "$$part" --variant "$$variant" --reader-path "$$reader_path" \
		--writer-kind "$$writer_kind" --writer-path "$$writer_path" \
		--release-tag "$$release_tag" --release-source-commit "$$release_source_commit" \
		--version-log "$$version_log" --version-exit "$$version_rc" \
		--output-dir "$$result"` || exit 1; \
	expected_reader="PIC12F675_TRIM_RECOVERY_READER PASS evidence-dir=$$result"; \
	if [ "$$reader_ready" != "$$expected_reader" ]; then \
		echo "ERROR: recovery oracle did not emit its exact reader record."; exit 1; \
	fi; \
	printf '%s\n' "$$reader_ready"; \
	read_rc=0; \
	"$$reader_path" "-P$$part" -I "-GF$$read_hex" -R >"$$read_log" 2>&1 || read_rc=$$?; \
	cat "$$version_log"; cat "$$read_log"; \
	if [ "$$read_rc" -eq 0 ] && ! $(IHEX_VALIDATOR) "$$read_hex"; then read_rc=125; fi; \
	recovery_rc=0; \
	recovery_output=`python3 "$(PIC12F675_TRIM_EVIDENCE_TOOL)" recovery-result \
		--baseline "$$evidence" --reservation "$$reservation" \
		--part "$$part" --variant "$$variant" --reader-path "$$reader_path" \
		--writer-kind "$$writer_kind" --writer-path "$$writer_path" \
		--release-tag "$$release_tag" --release-source-commit "$$release_source_commit" \
		--version-log "$$version_log" --version-exit "$$version_rc" \
		--read-log "$$read_log" --read-hex "$$read_hex" --read-exit "$$read_rc" \
		--program-log "$$result/program.log" --attempt-dir "$$attempt" \
		--output-dir "$$result"` || recovery_rc=$$?; \
	printf '%s\n' "$$recovery_output"; \
	expected_recovery="PIC12F675_TRIM_RECOVERY_RESULT PASS evidence=$$result/result.json"; \
	if [ "$$recovery_rc" -ne 0 ] || [ "$$recovery_output" != "$$expected_recovery" ] || \
			[ ! -f "$$result/result.json" ] || [ -L "$$result/result.json" ] || \
			[ ! -s "$$result/result.json" ]; then \
		echo "ERROR: PIC12F675 recovery finalized with FAIL evidence."; \
		echo "       Retained transaction directory: $$result"; exit 1; \
	fi; \
	echo "PIC12F675 read-only recovery PASS: $$result/result.json"

# Builds every variant + the flash-budget gate first (so the image is fresh and
# proven to fit), derives the selected image only from validated VARIANT, then
# copies it into a private read-only snapshot. Every parser consumes that
# snapshot, its SHA-256 digest is required unchanged after all checks, and the
# programmer receives that same private path through directly constructed argv.
# Like the 322's target this is a deliberate bench action: it FAILS LOUDLY rather
# than skipping when anything is missing.
#
# THE PRE-FLASH GATE THE 10F32x PARTS DO NOT NEED. Every simulator lane for this
# part runs on a DERIVED image carrying a fabricated calibration word (see the
# calibration block above). Writing one of those to a device overwrites the
# factory oscillator trim -- irreversibly, and silently, because the part still
# runs afterwards, at the wrong clock. The derived images live in their own
# subdirectory precisely so no shipping-image glob can select one, but a command
# that writes to silicon must not rest on a directory layout. This target selects
# only the freshly built VARIANT image and asks the immutable checker's inverse
# mode whether its private snapshot programs word 0x3FF. The private, immutable
# 12F675 build supplies part identity; the CALL check is defense in depth against
# a malformed or substituted result, not part provenance by itself. An exact
# image/word success record proves the check actually ran before the programmer
# becomes reachable; exit status zero alone is insufficient.
#
# The CONFIG checker is compiled unconditionally inside the private transaction
# directory and decodes the same private snapshot rather than consuming the
# ignored repository-adjacent executable or the build glob `pic12f675-test-config`
# walks. Its exact image/word record covers the BG<1:0> half of item 1 -- the build
# must leave the factory bandgap bits erased -- and proves the private checker ran.
#
# EVERY oracle capture below compares STDOUT ONLY, and compares it for exact
# equality. Do NOT fold stderr in with `2>&1`: a deprecation warning, a tracing
# line, anything a future interpreter decides to print would be prepended to a
# PASS record and turn a successful bench write into a reported failure -- after
# the device has already been programmed. The evidence tool prints its own FAIL
# reasons to stderr, which reaches the terminal live either way.
.PHONY: pic12f675-program pic12f675-release-program
pic12f675-program: variant-selectors-valid \
                  test/pic/test_config_pic12f675.c $(PIC_CONFIG_CORE_HDR) \
                  $(PIC12F675_CONFIG_HDR) $(PIC12F675_CAL_CHECKER) \
                  $(PIC12F675_TRIM_EVIDENCE_TOOL)
pic12f675-release-program: variant-selectors-valid \
                          test/pic/test_config_pic12f675.c $(PIC_CONFIG_CORE_HDR) \
                          $(PIC12F675_CONFIG_HDR) $(PIC12F675_CAL_CHECKER) \
                          $(PIC12F675_TRIM_EVIDENCE_TOOL) \
                          $(PIC12F675_RELEASE_IMAGE_CHECKER) \
                          scripts/verify-release-signature.sh \
                          scripts/verify-release-images.sh \
                          scripts/release-signing-policy.sh
pic12f675-program pic12f675-release-program: variant-selectors-valid
	@if [ "$(if $(filter undefined,$(origin PIC12F675_PROG_HEX)),0,1)" -ne 0 ]; then \
		echo "ERROR: PIC12F675_PROG_HEX is not supported; the image is derived from validated VARIANT."; \
		exit 1; \
	fi; \
	if [ "$(if $(filter undefined,$(origin PIC12F675_PROG_CMD)),0,1)" -ne 0 ]; then \
		echo "ERROR: PIC12F675_PROG_CMD is not supported; guarded argv is constructed by the target."; \
		exit 1; \
	fi; \
	program_target='$@'; \
	release_mode=0; release_tag=; release_source_commit=; \
	if [ "$$program_target" = pic12f675-release-program ]; then \
		release_mode=1; release_tag=$$PIC12F675_RELEASE_TAG; \
		if [ -z "$$release_tag" ]; then \
			echo "ERROR: PIC12F675_RELEASE_TAG is required for signed-release programming."; exit 1; \
		fi; \
	else \
		echo "WARNING: PIC12F675 development/bench programming is not bound to signed release bytes."; \
	fi; \
	variant="$(VARIANT)"; \
	prog=$$PIC12F675_PROG; \
	prog_kind=$$PIC12F675_PROG_KIND; \
	prog_tool=$$PIC12F675_PROG_TOOL; \
	reader=$$PIC12F675_READ_PROG; \
	evidence=$$PIC12F675_TRIM_EVIDENCE; \
	result=$$PIC12F675_BENCH_RESULT; \
	part=$$PIC12F675_PART; \
	if [ -z "$$evidence" ]; then \
		echo "ERROR: PIC12F675_TRIM_EVIDENCE is required; run pic12f675-preflight first."; \
		exit 1; \
	fi; \
	if [ -z "$$result" ]; then \
		echo "ERROR: PIC12F675_BENCH_RESULT is required for retained before/after evidence."; \
		exit 1; \
	fi; \
	if [ -e "$$result" ] || [ -L "$$result" ]; then \
		echo "ERROR: bench-result output already exists; refusing to overwrite: $$result"; \
		exit 1; \
	fi; \
	if [ "$$release_mode" -eq 1 ]; then \
		repo_root=`git rev-parse --show-toplevel 2>/dev/null` || { \
			echo "ERROR: signed-release programming must run inside a Git worktree."; exit 1; \
		}; \
		repo_root=`CDPATH= cd -- "$$repo_root" && pwd -P` || exit 1; \
		for retained_path in "$$evidence" "$$result"; do \
			retained_parent=`dirname -- "$$retained_path"` || exit 1; \
			retained_base=`basename -- "$$retained_path"` || exit 1; \
			retained_parent=`CDPATH= cd -- "$$retained_parent" 2>/dev/null && pwd -P` || { \
				echo "ERROR: release evidence parent directory does not exist: $$retained_path"; exit 1; \
			}; \
			retained_abs="$$retained_parent/$$retained_base"; \
			case "$$retained_abs" in \
				"$$repo_root"|"$$repo_root"/*) \
					echo "ERROR: signed-release baseline and result paths must be outside the worktree: $$retained_path"; \
					exit 1 ;; \
			esac; \
		done; \
	fi; \
	case "$$prog_kind" in \
		pk2cmd|ipecmd) : ;; \
		*) echo "ERROR: PIC12F675_PROG_KIND must be exactly pk2cmd or ipecmd; got '$$prog_kind'."; exit 1 ;; \
	esac; \
	if [ "$$prog_kind" = ipecmd ]; then \
		case "$$prog_tool" in \
			PK3|PK4|PK5) : ;; \
			*) echo "ERROR: PIC12F675_PROG_TOOL must be exactly PK3, PK4, or PK5 for ipecmd; got '$$prog_tool'."; exit 1 ;; \
		esac; \
	fi; \
	case "$$prog" in \
		*/*) [ -f "$$prog" ] && [ -x "$$prog" ]; prog_path=$$prog ;; \
		*) prog_path=`command -v "$$prog" 2>/dev/null` ;; \
	esac; \
	if [ -z "$$prog_path" ] || [ ! -f "$$prog_path" ] || [ ! -x "$$prog_path" ]; then \
		echo "ERROR: PIC programmer '$$prog' not found or not executable."; \
		echo "       Set PIC12F675_PROG to the executable path and PIC12F675_PROG_KIND"; \
		echo "       to pk2cmd or ipecmd when its basename does not identify the dialect."; \
		exit 1; \
	fi; \
	case "$$reader" in \
		*/*) [ -f "$$reader" ] && [ -x "$$reader" ]; reader_path=$$reader ;; \
		*) reader_path=`command -v "$$reader" 2>/dev/null` ;; \
	esac; \
	if [ -z "$$reader_path" ] || [ ! -f "$$reader_path" ] || [ ! -x "$$reader_path" ]; then \
		echo "ERROR: pk2cmd reader '$$reader' not found or not executable."; \
		echo "       Set PIC12F675_READ_PROG to the pk2cmd used for the baseline."; \
		exit 1; \
	fi; \
	if ! command -v python3 >/dev/null 2>&1; then \
		echo "ERROR: python3 is required to check the calibration word before flashing."; \
		echo "       Refusing to program without that check."; \
		exit 1; \
	fi; \
	if ! command -v sha256sum >/dev/null 2>&1; then \
		echo "ERROR: sha256sum is required to bind pre-flash checks to the programmed snapshot."; \
		exit 1; \
	fi; \
	$(IHEX_VALIDATOR_CHECK); \
	baseline_check=`python3 "$(PIC12F675_TRIM_EVIDENCE_TOOL)" inspect \
		--baseline "$$evidence"` || exit 1; \
	expected_baseline_check="PIC12F675_TRIM_BASELINE_VALID PASS evidence=$$evidence"; \
	if [ "$$baseline_check" != "$$expected_baseline_check" ]; then \
		echo "ERROR: trim-evidence oracle did not emit its exact validation record."; exit 1; \
	fi; \
	printf '%s\n' "$$baseline_check"; \
	hash_file() { \
		hash_output=`sha256sum -- "$$1"` || return 1; \
		hash_digest=$${hash_output%% *}; \
		case "$$hash_digest" in ''|*[!0-9a-f]*) return 1 ;; esac; \
		[ $${#hash_digest} -eq 64 ] || return 1; \
		printf '%s' "$$hash_digest"; \
	}; \
	temp_root=$${TMPDIR:-$${XDG_RUNTIME_DIR:-$${HOME:-}}}; \
	if [ -z "$$temp_root" ] || [ ! -d "$$temp_root" ]; then \
		echo "ERROR: set TMPDIR, XDG_RUNTIME_DIR, or HOME to an existing private temporary root."; \
		exit 1; \
	fi; \
	temp_root=`CDPATH= cd -- "$$temp_root" && pwd -P` || exit 1; \
	while [ "$${temp_root#//}" != "$$temp_root" ]; do temp_root=/$${temp_root#//}; done; \
	if [ "$$release_mode" -eq 1 ]; then \
		case "$$temp_root" in \
			"$$repo_root"|"$$repo_root"/*) \
				echo "ERROR: signed-release temporary storage must be outside the worktree: $$temp_root"; exit 1 ;; \
		esac; \
	fi; \
	case "$$temp_root" in \
		/tmp|/tmp/*|/var/tmp|/var/tmp/*) \
			echo "ERROR: refusing shared temporary root $$temp_root; select private TMPDIR."; exit 1 ;; \
		*[!A-Za-z0-9_./\ -]*) \
			echo "ERROR: private temporary root contains unsupported path characters: $$temp_root"; exit 1 ;; \
	esac; \
	temp_root_uid=`stat -Lc '%u' -- "$$temp_root"` || exit 1; \
	current_uid=`id -u` || exit 1; \
	temp_root_mode=`stat -Lc '%a' -- "$$temp_root"` || exit 1; \
	case "$$temp_root_mode" in ''|*[!0-7]*) \
		echo "ERROR: could not determine private temporary root permissions."; exit 1 ;; \
	esac; \
	if [ "$$temp_root_uid" != "$$current_uid" ] || [ $$((0$$temp_root_mode & 077)) -ne 0 ]; then \
		echo "ERROR: private temporary root must be owned by the current user with no group/other access: $$temp_root"; \
		exit 1; \
	fi; \
	ancestor=$$temp_root; \
	while [ "$$ancestor" != / ]; do \
		ancestor=$${ancestor%/*}; [ -n "$$ancestor" ] || ancestor=/; \
		ancestor_mode=`stat -Lc '%a' -- "$$ancestor"` || exit 1; \
		ancestor_uid=`stat -Lc '%u' -- "$$ancestor"` || exit 1; \
		case "$$ancestor_mode" in ''|*[!0-7]*) \
			echo "ERROR: could not determine temporary-root ancestor permissions."; exit 1 ;; \
		esac; \
		if [ "$$ancestor_uid" != 0 ] && [ "$$ancestor_uid" != "$$current_uid" ]; then \
			echo "ERROR: private temporary root has an ancestor not owned by root or the current user: $$ancestor"; exit 1; \
		fi; \
		if [ $$((0$$ancestor_mode & 022)) -ne 0 ]; then \
			echo "ERROR: private temporary root has a group/other-writable ancestor: $$ancestor"; exit 1; \
		fi; \
	done; \
	program_dir="$$temp_root/pic12f675-program.$$$$"; \
	bench_dir="$$temp_root/pic12f675-bench.$$$$"; \
	program_created=0; bench_created=0; \
	setup_in_progress=1; pending_signal=0; \
	cleanup_program_snapshot() { \
		rc=$$1; \
		trap - 0 1 2 15; \
		if [ "$$program_created" -eq 1 ]; then \
			chmod 700 "$$program_dir" 2>/dev/null || :; \
			rm -rf -- "$$program_dir" || rc=1; \
		fi; \
		if [ "$$bench_created" -eq 1 ]; then rm -rf -- "$$bench_dir" || rc=1; fi; \
		exit $$rc; \
	}; \
	handle_program_signal() { \
		if [ "$$setup_in_progress" -eq 1 ]; then pending_signal=$$1; return; fi; \
		cleanup_program_snapshot $$1; \
	}; \
	trap 'cleanup_program_snapshot $$?' 0; \
	trap 'handle_program_signal 129' 1; \
	trap 'handle_program_signal 130' 2; \
	trap 'handle_program_signal 143' 15; \
	if (trap '' 1 2 15; umask 077 && mkdir -- "$$program_dir"); then program_created=1; else \
		setup_in_progress=0; \
		if [ "$$pending_signal" -ne 0 ]; then cleanup_program_snapshot "$$pending_signal"; fi; \
		echo "ERROR: could not exclusively create a private programming directory."; exit 1; \
	fi; \
	if (trap '' 1 2 15; umask 077 && mkdir -- "$$bench_dir"); then bench_created=1; else \
		setup_in_progress=0; \
		if [ "$$pending_signal" -ne 0 ]; then cleanup_program_snapshot "$$pending_signal"; fi; \
		echo "ERROR: could not exclusively create a private bench-record directory."; exit 1; \
	fi; \
	setup_in_progress=0; \
	if [ "$$pending_signal" -ne 0 ]; then cleanup_program_snapshot "$$pending_signal"; fi; \
	if [ "$$release_mode" -eq 1 ]; then \
		release_source_check=`TMPDIR="$$program_dir" "$(PIC12F675_RELEASE_IMAGE_CHECKER)" \
			source "$$release_tag"` || exit 1; \
		expected_release_source="PIC12F675_RELEASE_SOURCE_CHECK PASS tag=$$release_tag"; \
		if [ "$$release_source_check" != "$$expected_release_source" ]; then \
			echo "ERROR: release source checker did not emit its exact success record."; exit 1; \
		fi; \
		printf '%s\n' "$$release_source_check"; \
	fi; \
	config_checker="$$program_dir/config checker"; \
	if ! $(HOSTCC) $(HOST_CFLAGS) -Itest \
			-DPIC_DEVICE_NAME='"PIC$(PIC12F675_CHIP)"' \
			test/pic/test_config_pic12f675.c -o "$$config_checker"; then \
		echo "ERROR: could not compile the private PIC12F675 CONFIG checker."; exit 1; \
	fi; \
	if [ ! -f "$$config_checker" ] || [ -L "$$config_checker" ] || [ ! -s "$$config_checker" ] || \
			[ ! -x "$$config_checker" ]; then \
		echo "ERROR: private PIC12F675 CONFIG checker is missing, empty, a symlink, or not executable."; \
		exit 1; \
	fi; \
	chmod 500 "$$config_checker" || exit 1; \
	program_build="$$program_dir/build"; \
	if ! $(MAKE) --no-print-directory pic12f675 \
			PIC12F675_BUILD_DIR="$$program_build" \
			FW_BASE=bypass PIC12F675_TAG=pic12f675 \
			VARIANTS='$(CLASSIC_VARIANTS_SUPPORTED)' STRICT_TOOLS=1; then \
		echo "ERROR: private PIC12F675 programming matrix did not build successfully."; \
		exit 1; \
	fi; \
	hex="$$program_build/bypass-pic12f675-$(VARIANT).hex"; \
	if [ ! -f "$$hex" ] || [ -L "$$hex" ] || [ ! -s "$$hex" ]; then \
		echo "ERROR: fresh selected image is missing, empty, a symlink, or not regular: $$hex"; \
		exit 1; \
	fi; \
	source_digest_before=`hash_file "$$hex"` || { \
		echo "ERROR: could not hash fresh selected image $$hex."; exit 1; \
	}; \
	snapshot="$$program_dir/image snapshot.hex"; \
	cp -- "$$hex" "$$snapshot" || exit 1; \
	chmod 400 "$$snapshot" || exit 1; \
	if [ ! -f "$$hex" ] || [ -L "$$hex" ] || [ ! -s "$$hex" ]; then \
		echo "ERROR: selected image changed type while its private snapshot was created: $$hex"; \
		exit 1; \
	fi; \
	source_digest_after=`hash_file "$$hex"` || exit 1; \
	if [ ! -f "$$snapshot" ] || [ -L "$$snapshot" ] || [ ! -s "$$snapshot" ]; then \
		echo "ERROR: private programming snapshot is not a nonempty regular file."; exit 1; \
	fi; \
	snapshot_digest_before=`hash_file "$$snapshot"` || exit 1; \
	if [ "$$source_digest_before" != "$$source_digest_after" ] || \
			[ "$$source_digest_before" != "$$snapshot_digest_before" ]; then \
		echo "ERROR: selected image changed while its private snapshot was created: $$hex"; \
		exit 1; \
	fi; \
	$(IHEX_VALIDATOR) "$$snapshot" || exit 1; \
	if ! calibration_check=`python3 "$(PIC12F675_CAL_CHECKER)" \
			--assert-preserves-calibration \
			--flash-words $(PIC12F675_FLASH_WORDS) "$$snapshot"`; then \
		echo "ERROR: refusing to program selected variant $$variant."; \
		echo "       An image that writes the calibration word would destroy this"; \
		echo "       device's factory oscillator trim. The derived images under"; \
		echo "       $(PIC12F675_SIMCAL_DIR)/ carry exactly such a word and are for"; \
		echo "       simulators only; program the shipping HEX from $(PIC12F675_BUILD_DIR)/."; \
		exit 1; \
	fi; \
	expected_calibration_check="PIC12F675_CALIBRATION_CHECK PASS image=$$snapshot word=0x3FF"; \
	if [ "$$calibration_check" != "$$expected_calibration_check" ]; then \
		echo "ERROR: refusing to program selected variant $$variant."; \
		echo "       The immutable calibration checker did not emit its exact success record."; \
		exit 1; \
	fi; \
	printf '%s\n' "$$calibration_check"; \
	config_checker_digest_before=`hash_file "$$config_checker"` || exit 1; \
	if ! config_check=`"$$config_checker" --programming-record "$$snapshot"`; then \
		echo "ERROR: refusing to program selected variant $$variant."; \
		echo "       The private CONFIG checker rejected the selected snapshot."; exit 1; \
	fi; \
	if [ ! -f "$$config_checker" ] || [ -L "$$config_checker" ] || [ ! -s "$$config_checker" ] || \
			[ ! -x "$$config_checker" ]; then \
		echo "ERROR: private PIC12F675 CONFIG checker changed type while running."; exit 1; \
	fi; \
	config_checker_digest_after=`hash_file "$$config_checker"` || exit 1; \
	if [ "$$config_checker_digest_before" != "$$config_checker_digest_after" ]; then \
		echo "ERROR: private PIC12F675 CONFIG checker changed while running."; exit 1; \
	fi; \
	expected_config_check="PIC_CONFIG_CHECK PASS device=PIC12F675 image=$$snapshot word=0x31CC"; \
	if [ "$$config_check" != "$$expected_config_check" ]; then \
		echo "ERROR: refusing to program selected variant $$variant."; \
		echo "       The private CONFIG checker did not emit its exact image-bound success record."; \
		exit 1; \
	fi; \
	printf '%s\n' "$$config_check"; \
	if [ "$$release_mode" -eq 1 ]; then \
		release_image_check=`TMPDIR="$$program_dir" "$(PIC12F675_RELEASE_IMAGE_CHECKER)" \
			image "$$release_tag" "$$variant" "$$snapshot"` || exit 1; \
		expected_release_image="PIC12F675_RELEASE_IMAGE_CHECK PASS tag=$$release_tag variant=$$variant image=$$snapshot sha256=$$snapshot_digest_before"; \
		if [ "$$release_image_check" != "$$expected_release_image" ]; then \
			echo "ERROR: release image checker did not emit its exact success record."; exit 1; \
		fi; \
		printf '%s\n' "$$release_image_check"; \
		release_source_commit=`git rev-parse --verify "refs/tags/$$release_tag^{commit}" 2>/dev/null` || { \
			echo "ERROR: cannot retain signed-release source commit."; exit 1; \
		}; \
		case "$$release_source_commit" in \
			????????????????????????????????????????) : ;; \
			*) echo "ERROR: signed-release source commit is not a full SHA-1."; exit 1 ;; \
		esac; \
	fi; \
	chmod 500 "$$program_dir" || exit 1; \
	if [ ! -f "$$snapshot" ] || [ -L "$$snapshot" ] || [ ! -s "$$snapshot" ]; then \
		echo "ERROR: private programming snapshot changed type during pre-flash checks."; exit 1; \
	fi; \
	snapshot_digest_after=`hash_file "$$snapshot"` || exit 1; \
	if [ "$$snapshot_digest_before" != "$$snapshot_digest_after" ]; then \
		echo "ERROR: private programming snapshot changed during pre-flash checks."; \
		exit 1; \
	fi; \
	reader_version_log="$$bench_dir/reader-version.log"; \
	prewrite_log="$$bench_dir/prewrite-read.log"; \
	prewrite_hex="$$bench_dir/prewrite-read.hex"; \
	writer_version_log="$$bench_dir/writer-version.log"; \
	reader_digest_before=`hash_file "$$reader_path"` || exit 1; \
	if ! "$$reader_path" '-?V' >"$$reader_version_log" 2>&1; then \
		cat "$$reader_version_log"; echo "ERROR: pk2cmd reader version query failed."; exit 1; \
	fi; \
	if ! "$$reader_path" "-P$$part" -I "-GF$$prewrite_hex" -R >"$$prewrite_log" 2>&1; then \
		cat "$$prewrite_log"; echo "ERROR: immediate pre-write device read failed."; exit 1; \
	fi; \
	reader_digest_after=`hash_file "$$reader_path"` || exit 1; \
	if [ "$$reader_digest_before" != "$$reader_digest_after" ]; then \
		echo "ERROR: pk2cmd reader changed during immediate pre-write capture."; exit 1; \
	fi; \
	cat "$$reader_version_log"; cat "$$prewrite_log"; \
	$(IHEX_VALIDATOR) "$$prewrite_hex" || exit 1; \
	prewrite_check=`python3 "$(PIC12F675_TRIM_EVIDENCE_TOOL)" verify \
		--baseline "$$evidence" --reader-path "$$reader_path" \
		--version-log "$$reader_version_log" --read-log "$$prewrite_log" \
		--read-hex "$$prewrite_hex"` || exit 1; \
	expected_prewrite="PIC12F675_TRIM_PREWRITE PASS evidence=$$evidence"; \
	if [ "$$prewrite_check" != "$$expected_prewrite" ]; then \
		echo "ERROR: trim-evidence oracle did not emit its exact pre-write record."; exit 1; \
	fi; \
	printf '%s\n' "$$prewrite_check"; \
	case "$$prog_kind" in \
		ipecmd) version_arg='-?' ;; \
		pk2cmd) version_arg='-?V' ;; \
	esac; \
	writer_digest_before=`hash_file "$$prog_path"` || exit 1; \
	if ! "$$prog_path" "$$version_arg" >"$$writer_version_log" 2>&1; then \
		cat "$$writer_version_log"; echo "ERROR: programmer version query failed."; exit 1; \
	fi; \
	writer_digest_after=`hash_file "$$prog_path"` || exit 1; \
	if [ "$$writer_digest_before" != "$$writer_digest_after" ]; then \
		echo "ERROR: programmer executable changed during its version query."; exit 1; \
	fi; \
	cat "$$writer_version_log"; \
	reservation_output=`python3 "$(PIC12F675_TRIM_EVIDENCE_TOOL)" reserve \
		--baseline "$$evidence" --reader-path "$$reader_path" \
		--version-log "$$reader_version_log" --read-log "$$prewrite_log" \
		--read-hex "$$prewrite_hex" --writer-kind "$$prog_kind" \
		--writer-path "$$prog_path" --writer-version-log "$$writer_version_log" \
		--image-hex "$$snapshot" --variant "$$variant" \
		--release-tag "$$release_tag" --release-source-commit "$$release_source_commit" \
		--output-dir "$$result"` || exit 1; \
	expected_reservation="PIC12F675_TRIM_RESERVATION PASS evidence-dir=$$result"; \
	if [ "$$reservation_output" != "$$expected_reservation" ] || \
			[ ! -f "$$result/reservation.json" ] || [ -L "$$result/reservation.json" ]; then \
		echo "ERROR: trim-evidence oracle did not reserve the exact result directory."; exit 1; \
	fi; \
	printf '%s\n' "$$reservation_output"; \
	writer_digest_ready=`hash_file "$$prog_path"` || exit 1; \
	if [ "$$writer_digest_before" != "$$writer_digest_ready" ]; then \
		echo "ERROR: programmer executable changed before the write."; exit 1; \
	fi; \
	program_log="$$result/program.log"; \
	postread_log="$$result/postread.log"; \
	postread_hex="$$result/postread.hex"; \
	echo "Programming PIC12F675 selected variant $$variant from the fresh build matrix."; \
	echo "  executable: $$prog_path ($$prog_kind arguments)"; \
	echo "  readback oracle: $$reader_path (pk2cmd arguments)"; \
	echo "  checked snapshot: $$snapshot"; \
	program_rc=0; \
	case "$$prog_kind" in \
		ipecmd) "$$prog_path" "-TP$$prog_tool" "-P$$part" -M "-F$$snapshot" \
			>"$$program_log" 2>&1 || program_rc=$$? ;; \
		pk2cmd) "$$prog_path" "-P$$part" "-F$$snapshot" -M -Y -R \
			>"$$program_log" 2>&1 || program_rc=$$? ;; \
	esac; \
	cat "$$program_log"; \
	postread_rc=0; \
	"$$reader_path" "-P$$part" -I "-GF$$postread_hex" -R \
		>"$$postread_log" 2>&1 || postread_rc=$$?; \
	cat "$$postread_log"; \
	if [ "$$postread_rc" -eq 0 ] && ! $(IHEX_VALIDATOR) "$$postread_hex"; then \
		postread_rc=125; \
	fi; \
	result_rc=0; \
	result_output=`python3 "$(PIC12F675_TRIM_EVIDENCE_TOOL)" result \
		--baseline "$$evidence" --reservation "$$result/reservation.json" \
		--reader-path "$$reader_path" \
		--version-log "$$reader_version_log" --read-log "$$prewrite_log" \
		--read-hex "$$prewrite_hex" --writer-kind "$$prog_kind" \
		--writer-path "$$prog_path" --writer-version-log "$$writer_version_log" \
		--program-log "$$program_log" --program-exit "$$program_rc" \
		--post-read-log "$$postread_log" --post-read-hex "$$postread_hex" \
		--post-read-exit "$$postread_rc" --output-dir "$$result"` || result_rc=$$?; \
	printf '%s\n' "$$result_output"; \
	expected_result="PIC12F675_TRIM_RESULT PASS evidence=$$result/result.json"; \
	if [ "$$result_rc" -ne 0 ] || [ "$$result_output" != "$$expected_result" ] || \
			[ ! -f "$$result/result.json" ] || [ -L "$$result/result.json" ] || \
			[ ! -s "$$result/result.json" ]; then \
		echo "ERROR: PIC12F675 programming did not produce passing before/after trim evidence."; \
		echo "       Retained transaction directory: $$result"; \
		exit 1; \
	fi; \
	echo "PIC12F675 programming and factory-trim readback PASS: $$result/result.json"

# ============================================================================
# INTROSPECTION -- expose one Makefile variable's value to scripts
# ============================================================================
# `make print-VARIANTS` echoes "$(VARIANTS)", `make print-ATTINY13A_LFUSE` echoes the fuse
# byte, `make print-PIC_CC` echoes the XC8 path, and so on. scripts/make-release.sh
# reads the release manifest's variant list, fuse bytes, device names and build
# directories through this target so they come from THIS Makefile (the single
# source of truth) rather than a hand-maintained copy that could silently drift.
print-%:
	@echo '$($*)'

# Companion oracle: does this Makefile actually KNOW a name?
#
# `print-%` is a pattern rule, so it matches anything. Ask it for a variable
# that no longer exists and it prints an empty line and exits 0 -- which is why
# a rename can sever the link between this file and the scripts, workflows and
# documents that name its variables, with every gate staying green. v0.9.8 hit
# that three times: three `mkv` calls in scripts/make-release.sh left pointing at
# removed names (the damage would have surfaced as empty fuse bytes in a
# published MANIFEST.md at the end of a 24-hour run), a mutation row passing four
# name-contract: exempt (names the retired spelling to describe the defect)
# renamed SOAK_* overrides that were silently inert, and ten stale surfaces
# naming variables to human readers.
#
# Non-emptiness is NOT the test. Several names are defined-but-empty by design
# (XT_SOAK_COMBINATION_NAME, AVR_STACK_BUILD_DIR), so asserting a value would
# produce false failures. $(origin) is the only oracle that separates "never
# defined" (undefined) from "deliberately set empty" (file).
#
# This has to live HERE, beside print-%, rather than in an outer makefile that
# includes this one: _make-serialized-invocation intercepts goals it does not
# recognize, so the invocation fails before an externally added rule is reached.
#
# `make origin-FOO` -> undefined | file | command line | environment | ...
origin-%:
	@echo '$(origin $*)'

# Bulk form, so a gate can resolve a whole harvest in ONE make invocation
# instead of one per name: `make origins NAMES="A B C"` prints "<name> <origin>"
# per line. The per-name rule above stays for interactive use.
.PHONY: origins
origins:
	@$(foreach n,$(NAMES),printf '%s %s\n' '$(n)' '$(origin $(n))';)

# ============================================================================
# RELEASE -- reproducible, fully-validated prebuilt firmware images
# ============================================================================
# Thin wrapper around scripts/make-release.sh. The script is a deliberate,
# long-running (~24 h, because of the parallel 24-h soaks) pre-tag gate that:
#   1. refuses to run unless the working tree is clean and EVERY required tool
#      is present (the inverse of the dev-time "skip cleanly" behaviour -- a
#      release must never green-light on a tool that silently did nothing);
#   2. clean-builds all AVR + PIC variant images;
#   3. runs `make test-long`, both ATtiny202 qualification aggregates, and both
#      pre-hardware and real-target aggregates for PIC10F322, PIC10F320, and
#      PIC12F675, then ALL 18 soak combos in parallel;
#   4. rechecks source HEAD + worktree cleanliness, then stages
#      release/<VERSION>/ with the .hex images, SHA256SUMS, a provenance MANIFEST
#      (toolchain versions, per-image fuse bytes / CONFIG word, flashing command,
#      soak evidence) and a README;
#   5. STOPS and prints the exact `git add` / `git commit` / `git tag -s` and
#      checksum-signing commands for you to run by hand (it never commits or tags).
# The pushed tag then triggers .github/workflows/release.yml, which rebuilds from
# the tag on a clean runner, verifies the committed image hashes reproduce
# bit-for-bit, and publishes the GitHub Release.
#
#   make release-preflight                 # capability check, no build/staging
#   make release-preflight VERSION=v1.0.0  # require final docs; warn on tag/output state
#   make release VERSION=v1.0.0
#   make release VERSION=v1.0.0 RELEASE_ARGS='--dry-run'   # skip the 24-h soak

# --- the canonical release product set ---------------------------------------
# THE authoritative answer to "what does a complete release contain?", expressed
# once, here, and consumed everywhere else through `make -s print-RELEASE_IMAGES`
# (scripts/make-release.sh, scripts/verify-release-images.sh,
# test/test_release_images.sh). Merge plan §10.
#
# WHY THIS EXISTS. Before it, three "independent" checks all derived their idea
# of the release set by GLOBBING the same kind of directory: make-release.sh
# built SHA256SUMS from `sha256sum ./*.hex`, and verify-release-images.sh listed
# `"$dir"/*.hex`. Three sets that agree prove nothing if all three are computed
# the same wrong way -- omit a whole MCU from the build and every one of them
# happily agrees on the shortened set. That is §14.8's hole, and adding a second
# PIC part is exactly the change that makes falling into it easy: forget one
# `make pic10f320-variants` and a "complete, verified, reproduced" release ships
# with no PIC10F320 firmware at all and nothing says a word.
#
# This variable is the independent fourth opinion. It is derived from the same
# Makefile truth the build rules use -- so it cannot drift from the variant
# matrices -- but it is NOT derived from anything on disk, so no build, copy or
# publish step can influence it. The verifier fails unless the committed
# directory, the SHA256SUMS entries, and the fresh build output each equal it
# EXACTLY.
#
# The classic AVR/PIC10F322 and PIC10F320 entries use their immutable supported
# sets, not the caller's VARIANTS or PIC10F320_VARIANTS_ALL request, so an abbreviated
# build override cannot shorten this independent release contract with the build.
#
# Every entry is composed by $(call fw_image,<variant>,<mcu-tag>), so all seven
# parts share ONE basename convention -- bypass-<mcu>-<output stage>.hex -- and
# this list cannot spell an image differently from the rule that builds it. The
# five divergent conventions that used to be reconciled here by hand (merge plan
# §5.3, decision D2) were retired in v0.9.8; see "canonical firmware image
# basename" near the top for what replaced them and why.
# Fail at parse time, not at publish time, if a supported variant is not fully
# declared. Every lane's supported set is checked, so a variant that exists for
# one MCU but was never given a driver mapping cannot reach a build rule; without
# this the omission surfaces as a missing release image after a 24-hour soak has
# already run.
#
# This lives HERE rather than beside the variant definitions because it is the
# first point at which all three lanes' supported sets exist -- XT_VARIANTS_
# SUPPORTED is not defined until the AVR-XT section, and an immediate-evaluation
# check placed earlier would silently pass by checking an empty list.
#
# Deliberately NOT an equality check between the three lists. They hold the same
# three names today, but a future output stage that fits the ATtiny13a and not
# the 11-free-words PIC10F320 is a legitimate divergence, and a guard forbidding
# it would be wrong. What must hold is that wherever a name appears it means the
# same stage and is completely declared.
override ALL_SUPPORTED_VARIANTS := $(sort $(CLASSIC_VARIANTS_SUPPORTED) \
                                          $(XT_VARIANTS_SUPPORTED) \
                                          $(PIC10F320_VARIANTS_SUPPORTED))

# $(call require_variant_map,<prefix>,<supported set>,<what it is>)
#
# Every per-variant map in this file goes through here. It was two hardcoded
# checks (macro_ and src_) until v0.9.8, and the two it did NOT cover are
# exactly where the stage-vocabulary rename severed: pic_soak_block_* kept its
# retired cd4053/mute/relay keys while PIC10F322_SOAK_VARIANT moved to
# cd4053_simple/cd4053_with_mute/tq2_l2_5v_relay. Every lookup expanded empty,
# so the soak compile line emitted `-DSOAK_ACTUATION_BLOCK_MS=u` and the driver
# failed to build -- which degraded the PIC10F322 WDT mutant to a SKIP and would
# have failed three of the fifteen release soak binaries. The 10F320 copy of the
# same map had been renamed correctly, so the two lanes disagreed in silence.
#
# A non-empty value is required, not merely a declared one. `0` is a legitimate
# value here and is non-empty as a string, so the numeric maps are safe; an
# empty value is always a mistake (write `0`, not nothing).
require_variant_map = $(foreach v,$(2), \
	$(if $($(1)$(v)),,$(error supported variant '$(v)' has no $(1)$(v) $(3))))

# macro_/src_ are universal: every variant in every lane needs an output-macro
# selector and a driver source. The 10F32x soak-block maps are per-lane, and are
# checked against THAT lane's supported set rather than the union -- the
# divergence note above is the reason. Requiring the 10F322 map to cover a
# variant only the ATtiny13a supports would forbid exactly the future this
# guard is written not to forbid.
$(call require_variant_map,macro_,$(ALL_SUPPORTED_VARIANTS),output-macro selector)
$(call require_variant_map,src_,$(ALL_SUPPORTED_VARIANTS),driver source)
$(call require_variant_map,pic_soak_block_,$(CLASSIC_VARIANTS_SUPPORTED),PIC10F322 soak actuation-block time)
$(call require_variant_map,pic10f320_soak_block_,$(PIC10F320_VARIANTS_SUPPORTED),PIC10F320 soak actuation-block time)

# Broken out per lane so a consumer that legitimately cares about ONE chip
# (CI's per-lane "images were actually built" asserts) can name that lane's
# basenames instead of composing them by hand from a variant list -- a hand-built
# name silently stops matching after a rename, which is exactly the failure this
# whole scheme exists to remove. RELEASE_IMAGES stays the single canonical set;
# these are its parts, not a second opinion.
ATTINY13A_RELEASE_IMAGES    := $(foreach v,$(CLASSIC_VARIANTS_SUPPORTED),$(call fw_image,$(v),$(ATTINY13A_MCU)).hex)
TINYX5_RELEASE_IMAGES := $(foreach v,$(CLASSIC_VARIANTS_SUPPORTED),$(foreach n,$(TINYX5),$(call fw_image,$(v),$(mmcu_$(n))).hex))
XT_RELEASE_IMAGES     := $(foreach v,$(XT_VARIANTS_SUPPORTED),$(call fw_image,$(v),$(XT_TAG)).hex)
PIC10F322_RELEASE_IMAGES    := $(foreach v,$(CLASSIC_VARIANTS_SUPPORTED),$(call fw_image,$(v),$(PIC10F322_TAG)).hex)
PIC10F320_RELEASE_IMAGES := $(foreach v,$(PIC10F320_VARIANTS_SUPPORTED),$(call fw_image,$(v),$(PIC10F320_TAG)).hex)
PIC12F675_RELEASE_IMAGES := $(foreach v,$(CLASSIC_VARIANTS_SUPPORTED),$(call fw_image,$(v),$(PIC12F675_TAG)).hex)

RELEASE_IMAGES := \
	$(ATTINY13A_RELEASE_IMAGES) \
	$(TINYX5_RELEASE_IMAGES) \
	$(XT_RELEASE_IMAGES) \
	$(PIC10F322_RELEASE_IMAGES) \
	$(PIC10F320_RELEASE_IMAGES) \
	$(PIC12F675_RELEASE_IMAGES)

# The build directories those images are produced into, in the order a
# reproduction run should pass them to scripts/verify-release-images.sh. Kept
# beside the set so a new target cannot add images without also declaring where
# they come from.
RELEASE_IMAGE_DIRS := $(AVR_BUILD_DIR) $(XT_BUILD_DIR) $(PIC10F322_BUILD_DIR) $(PIC10F320_BUILD_DIR) $(PIC12F675_BUILD_DIR)

# --- required release artifacts that are NOT firmware images -----------------
# A release contains exactly 21 firmware images and, since v0.9.10, one tool: the
# standalone PIC12F675 flashing helper. It is staged, checksummed, signed and
# reproduced exactly like an image, and it is deliberately NOT a member of
# RELEASE_IMAGES -- the canonical image count is a reviewed number that a support
# script must not be able to move. Every verifier therefore reads two sets: the
# exact image set, and the exact helper set.
#
# WHY IT SHIPS AT ALL. Every other part is flash-and-forget, so a released HEX
# plus the operator's programmer CLI is a complete answer. The PIC12F675 is not:
# a bulk erase destroys the per-device OSCCAL word and BG<1:0> bandgap trim that
# no image can supply, so safe field programming needs a transaction, and a
# transaction needs a program. Shipping it beside the images is what makes
# "program a downloaded release without a source checkout" true for this part
# too -- see FLASHING.md and docs/pic12f675_feasibility.md section 8.
#
# <staged basename>=<tracked source> so the reproduction leg can prove the
# staged bytes are the tracked bytes, in one place, for both.
override RELEASE_HELPER_ARTIFACTS := flash-pic12f675.py
override RELEASE_HELPER_SOURCES := scripts/flash-pic12f675.py
override RELEASE_HELPER_MAP := flash-pic12f675.py=scripts/flash-pic12f675.py

# --- nothing is staged: every part this repository builds is released ---------
# There is no longer a "built but deliberately withheld" set. The PIC12F675 was
# the one staged part, and it graduated into RELEASE_IMAGES above alongside the
# other six MCU targets. RELEASE_STAGED_IMAGES and its parse-time
# disjoint-with-RELEASE_IMAGES guard are gone with it; the pattern for staging a
# future part (name the images, pin the exclusion from both sides in
# test-release-images, keep a graduation checklist here) is recoverable from the
# git history of that graduation if it is ever needed again.
#
# WHAT "RELEASED" MEANS HERE, AND WHAT IT DOES NOT. Everything this repository
# ships is validated in software -- simulation, formal proof and static analysis
# -- and none of it has completed controlled hardware qualification. That is the
# whole 0.9.x line, uniformly: see the versioning note at the top of CHANGELOG.md.
# Builders have flashed released images and reported them working, and those
# field-use reports are recorded in HARDWARE_VALIDATION_LOG.md section 1; they are
# evidence that the firmware runs on real silicon, and they are NOT qualification,
# because they retain no image identity, procedure or measurement. Controlled
# qualification is what the 1.x.y line will add, for EVERY part, and until then
# each target carries residual silicon-only risks that no lane here can see. The
# PIC12F675's happen to be enumerated (docs/pic12f675_feasibility.md section 8,
# items 1, 2, 8 and 9: whether a programmer preserves the factory oscillator trim in flash
# word 0x3FF and the BG<1:0> bandgap bits in the CONFIG word, whether ipecmd runs
# against the part, and GP2's Schmitt-Trigger readback margin). They are the same
# CLASS as every other part's un-bench-validated behaviour, tracked for the 1.x.y
# hardware pass as TODO.md T3-pic12f675-bench, and NOT release-blockers under the
# 0.9.x convention.
#
# ONE OF THEM IS NOT purely a 1.x.y nicety, though: losing word 0x3FF or the
# BG bits yields a device that runs WRONG while still appearing to work, and that
# is a flashing-time footgun the other parts do not have. The software mitigation
# already exists (pic12f675-program rejects an image that explicitly programs
# 0x3FF, compares the live device with a baseline immediately before writing, and
# records mandatory post-write trim/readback). That detects programmer-induced
# loss only after the write, so the published procedure in release/README.md MUST
# carry the complete guarded transaction and hardware-validation boundary. Treat
# that as a gate on the release, not a nicety -- an image shipped without the
# warning can leave an untrimmed device that still appears to work.

# Canonical release-soak and retained-evidence inventories. These are explicit,
# immutable publication contracts rather than observations of whichever loops or
# files happened to exist during a run. The release orchestrator rejects any
# actual soak-name set that differs before starting the 24-hour phase, and the
# qualification verifier requires the exact evidence set afterward.
#
# One <mcu>_<output stage> per combination, in the same MCU vocabulary the image
# basenames use -- so soak-attiny85_cd4053_simple.log is visibly the evidence for
# bypass-attiny85-cd4053_simple.hex. The old avr_<stage>_t85 form put the chip
# token at both ends and spelled the same part two ways.
override RELEASE_SOAK_NAMES := \
	attiny85_cd4053_simple attiny45_cd4053_simple \
	attiny85_cd4053_with_mute attiny45_cd4053_with_mute \
	attiny85_tq2_l2_5v_relay attiny45_tq2_l2_5v_relay \
	attiny202_cd4053_simple attiny202_cd4053_with_mute attiny202_tq2_l2_5v_relay \
	pic10f322_cd4053_simple pic10f322_cd4053_with_mute pic10f322_tq2_l2_5v_relay \
	pic10f320_cd4053_simple pic10f320_cd4053_with_mute pic10f320_tq2_l2_5v_relay \
	pic12f675_cd4053_simple pic12f675_cd4053_with_mute pic12f675_tq2_l2_5v_relay

override RELEASE_FIXED_EVIDENCE_FILES := \
	build-avr-classic.log build-avr-xt.log \
	build-pic10f322.log build-pic10f320.log build-pic12f675.log \
	final-image-build.log \
	attiny202-test.log attiny202-test-target.log \
	pic10f322-test.log pic10f322-test-target-variants.log \
	pic10f320-test.log pic10f320-test-target-variants.log \
	pic12f675-qualification.log pic12f675-qualified-matrix.json \
	soak-build.log test-long.summary.txt
override RELEASE_EVIDENCE_FILES := $(RELEASE_FIXED_EVIDENCE_FILES) \
	$(addprefix soak-,$(addsuffix .log,$(RELEASE_SOAK_NAMES)))

# --- the immutable production release identity -------------------------------
# WHAT A RELEASE IS, written as literal text that no caller can move.
#
# RELEASE_IMAGES above is the canonical set, but it is COMPOSED from the same
# variables the build rules use: $(FW_BASE), the per-part MCU tags, the tinyx5
# membership. Most of those are overridable on purpose -- test/test_pic_build.sh
# builds whole synthetic matrices under FW_BASE=, PIC12F675_TAG= and
# PIC12F675_CHIP= precisely because a name and a die are things a DEVELOPMENT
# target has to be able to vary. scripts/make-release.sh enumerates the release
# from those same variables, read back through print-<VAR>.
#
# Two opinions that consume one overridden input agree with each other about the
# overridden identity. `make release FW_BASE=other` staged, cross-checked and
# published a complete, internally consistent set of images that nobody had
# reviewed, and the enumeration-vs-RELEASE_IMAGES check a few dozen lines above
# passed, because both sides had been moved the same way. An exported
# PIC12F675_TAG did the same thing without appearing on any command line at all:
# the per-part tags are `?=`, so the environment wins them.
#
# This block is the third statement, and it is DATA. Literal words, `override`
# so neither the command line nor the environment can reach them, and derived
# from nothing that a build override can move -- a pin computed from FW_BASE
# would agree with the very thing it exists to check. The redundancy between
# the field table and the part/variant lists below is deliberate for the same
# reason: they are both literals, so they cannot disagree at run time, and an
# edit that changes one and forgets the other fails one of the two comparisons.
#
# WHAT IS PINNED: the fields that decide an image's NAME (FW_BASE, the MCU tag
# fields), the DIE that name is compiled for (the -mmcu/-mcpu selectors), the
# CLOCK its timing evidence was measured at, and the part/variant/soak
# MEMBERSHIP. The die and clock fields are here because an image called
# bypass-pic10f322-cd4053_simple.hex that was built for another chip, or at
# another clock, is the same defect wearing a reviewed name -- and the classic
# AVR clock is not even disclosed by the MANIFEST, which spells "1.2 MHz" and
# "1.0 MHz" as literals rather than reading F_CPU.
#
# WHAT IS NOT PINNED, and must not be: build directories (AVR_BUILD_DIR,
# PIC10F322_BUILD_DIR, ...) and every tool path (CC, PIC_CC, GPSIM, ...). Those
# do not change what an artifact IS, a release host legitimately relocates them,
# and make-release.sh already asserts and records the tool it actually selected.
# Fuse/CONFIG bytes are likewise not pinned here: they are read from Makefile
# truth into the signed MANIFEST, so they are disclosed rather than silently
# substituted.
#
# TO CHANGE THE RELEASE IDENTITY -- add a part, retire a variant, re-clock a
# chip -- edit this block. That edit is the review: it cannot be done from a
# command line, and a release whose selected values no longer match it stops
# before it cleans, builds, soaks or stages anything.
_RELEASE_IDENTITY_EMPTY :=
_RELEASE_IDENTITY_SPACE := $(_RELEASE_IDENTITY_EMPTY) $(_RELEASE_IDENTITY_EMPTY)
_RELEASE_IDENTITY_COMMA := ,
# Join a list value into ONE word, so a multi-word field stays a single entry
# and cannot desynchronize the pinned table from the selected one.
_release_identity_join = $(subst $(_RELEASE_IDENTITY_SPACE),$(_RELEASE_IDENTITY_COMMA),$(strip $(1)))

# <make variable>=<reviewed value>, one word per field, list values
# comma-joined. RELEASE_IDENTITY_SELECTED below reads the SAME names out of the
# live Makefile; make-release.sh compares the two field by field.
override RELEASE_IDENTITY_PINNED := \
	FW_BASE=bypass \
	ATTINY13A_MCU=attiny13a \
	ATTINY13A_F_CPU=1200000UL \
	TINYX5=85,45 \
	TINYX5_PARTS=attiny85,attiny45 \
	TINYX5_F_CPU=1000000UL \
	XT_TAG=attiny202 \
	XT_MCU=attiny202 \
	XT_F_CPU=2000000UL \
	PIC10F322_TAG=pic10f322 \
	PIC10F322_CHIP=10F322 \
	PIC10F322_XTAL=2000000UL \
	PIC10F320_TAG=pic10f320 \
	PIC10F320_CHIP=10F320 \
	PIC10F320_XTAL=2000000UL \
	PIC12F675_TAG=pic12f675 \
	PIC12F675_CHIP=12F675 \
	PIC12F675_XTAL=4000000UL \
	VARIANTS=cd4053_simple,cd4053_with_mute,tq2_l2_5v_relay \
	CLASSIC_VARIANTS_SUPPORTED=cd4053_simple,cd4053_with_mute,tq2_l2_5v_relay \
	XT_VARIANTS_SUPPORTED=cd4053_simple,cd4053_with_mute,tq2_l2_5v_relay \
	PIC10F320_VARIANTS_ALL=cd4053_simple,cd4053_with_mute,tq2_l2_5v_relay \
	PIC10F320_VARIANTS_SUPPORTED=cd4053_simple,cd4053_with_mute,tq2_l2_5v_relay

override RELEASE_IDENTITY_NAMES := $(foreach f,$(RELEASE_IDENTITY_PINNED),\
	$(firstword $(subst =,$(_RELEASE_IDENTITY_SPACE),$(f))))
override RELEASE_IDENTITY_SELECTED := $(foreach n,$(RELEASE_IDENTITY_NAMES),\
	$(n)=$(call _release_identity_join,$($(n))))

# The reviewed membership, spelled out. attiny13a is absent from the soak set
# because simavr does not model its watchdog system reset; the tinyx5 siblings
# carry that coverage for the classic family (see the TINYX5 note near the top).
override RELEASE_IDENTITY_PARTS := \
	attiny13a attiny85 attiny45 attiny202 pic10f322 pic10f320 pic12f675
override RELEASE_IDENTITY_SOAK_PARTS := \
	attiny85 attiny45 attiny202 pic10f322 pic10f320 pic12f675
override RELEASE_IDENTITY_VARIANTS := \
	cd4053_simple cd4053_with_mute tq2_l2_5v_relay
override RELEASE_IDENTITY_IMAGES := $(foreach m,$(RELEASE_IDENTITY_PARTS),\
	$(foreach v,$(RELEASE_IDENTITY_VARIANTS),bypass-$(m)-$(v).hex))
override RELEASE_IDENTITY_SOAKS := $(foreach m,$(RELEASE_IDENTITY_SOAK_PARTS),\
	$(foreach v,$(RELEASE_IDENTITY_VARIANTS),$(m)_$(v)))

# Every way the live tree can differ from the pin, as one compact word list: the
# moved <name>=<value> fields, plus the bare name of a whole set that no longer
# matches. Naming the set rather than diffing it here keeps the parse-time error
# readable -- one moved FW_BASE moves all 21 image names with it, and
# make-release.sh is where the member-by-member report belongs.
override RELEASE_IDENTITY_DRIFT := $(strip \
	$(filter-out $(RELEASE_IDENTITY_PINNED),$(RELEASE_IDENTITY_SELECTED)) \
	$(if $(filter-out $(RELEASE_IDENTITY_IMAGES),$(RELEASE_IMAGES))$(filter-out $(RELEASE_IMAGES),$(RELEASE_IDENTITY_IMAGES)),RELEASE_IMAGES) \
	$(if $(filter-out $(RELEASE_IDENTITY_SOAKS),$(RELEASE_SOAK_NAMES))$(filter-out $(RELEASE_SOAK_NAMES),$(RELEASE_IDENTITY_SOAKS)),RELEASE_SOAK_NAMES))

.PHONY: release release-preflight
# Keep release arguments in the recipe environment, never in shell source. The
# script validates VERSION and safely splits the documented RELEASE_ARGS words.
# `value` captures command-line text without expanding embedded GNU Make
# functions; the override then converts each channel to a simple literal before
# export. Otherwise VERSION='$(shell ...)' would execute before script validation.
_RELEASE_VERSION_LITERAL := $(value VERSION)
_RELEASE_ARGS_LITERAL := $(value RELEASE_ARGS)
_RELEASE_DOLLAR := $$
override VERSION := $(_RELEASE_VERSION_LITERAL)
override RELEASE_ARGS := $(_RELEASE_ARGS_LITERAL)
export VERSION RELEASE_ARGS
# Recursive Make otherwise forwards the original command-line spellings through
# MAKEOVERRIDES, bypassing the literal values above. A dollar cannot occur in a
# valid release version and is not a supported RELEASE_ARGS expansion syntax, so
# reject it in the outer process before serialization can re-parse it.
ifneq ($(filter release release-preflight,$(MAKECMDGOALS)),)
ifneq ($(findstring $(_RELEASE_DOLLAR),$(_RELEASE_VERSION_LITERAL)$(_RELEASE_ARGS_LITERAL)),)
$(error VERSION and RELEASE_ARGS must not contain dollar signs)
endif
# A release goal means the reviewed production identity, and nothing else. Fail
# at PARSE time -- before the recipe runs, before the worktree lock is taken,
# before make-release.sh creates a scratch directory -- so an identity-changing
# override costs nothing and leaves nothing behind. make-release.sh repeats the
# comparison for its own account (it is also run directly, and it names the
# $(origin) of each moved variable); this is the outer half, and it is the one
# that catches `make release FW_BASE=other` without starting a release at all.
ifneq ($(RELEASE_IDENTITY_DRIFT),)
$(error refusing a release goal under an overridden production release identity: $(RELEASE_IDENTITY_DRIFT). A release always means the reviewed identity declared by RELEASE_IDENTITY_PINNED -- seven parts, 21 images, 18 soak combinations. Re-run without those overrides; build-directory and tool-path overrides stay available)
endif
endif

release-preflight:
	./scripts/make-release.sh --preflight

release:
	./scripts/make-release.sh

# ============================================================================
# HELP
# ============================================================================

# One-line summary of the most useful targets.
help:
	@echo "Variants: $(VARIANTS)  (select with VARIANT=<name>; default $(VARIANT))"
	@echo "MCUs: release-supported: ATtiny13a/45/85 + ATtiny202 + PIC10F322 + PIC10F320 + PIC12F675"
	@echo "Build:"
	@echo "  all (default)   build every release-supported part's variant images (.hex) + sizes."
	@echo "                  Missing optional PIC/ATtiny202 toolchains skip by name; STRICT_TOOLS=1 makes that fatal."
	@echo "  attiny13a       build all variant firmwares for ATtiny13a"
	@echo "  attiny85 / attiny45   build all variant firmwares for that tinyx5 chip"
	@echo "  attiny13a-size  print flash/RAM usage for every ATtiny13a variant"
	@echo "  attiny85-size / attiny45-size   the same for that tinyx5 chip"
	@echo "  pic10f322             build all variants for PIC10F322 (XC8) + 512-word budget gate"
	@echo "  pic10f322-test        all PIC10F322 pre-hardware checks (CONFIG + analysis + source coverage + gpsim)"
	@echo "  pic10f322-test-config build PIC HEX, then verify each CONFIG word vs design intent"
	@echo "  pic10f322-analyze     cppcheck + MISRA on the PIC shell (XC8/DFP headers; standalone)"
	@echo "  pic10f322-coverage-check-fw  exact host-gcov gate over PIC shell, core, and drivers"
	@echo "                        (host compiler + gcov only, so \`make test\` runs it)"
	@echo "  pic10f322-test-gpsim  drive the footswitch in gpsim, assert PORTA/LATA toggle"
	@echo "  pic10f322-test-soak   libgpsim soak: WDT liveness + responsiveness (standalone; needs"
	@echo "                        gpsim-dev+libglib2.0-dev; PIC10F322_SOAK_VARIANT, PIC10F322_SOAK_DURATION_MS)"
	@echo "  pic10f322-test-fault  libgpsim fault-inject: corrupt a critical SFR, assert the gate"
	@echo "                        forces a WDT reset (standalone; needs gpsim-dev; PIC10F322_FAULT_VARIANT)"
	@echo "  pic10f322-test-lockstep  libgpsim HEX-vs-model ctx_ lock-step (PIC10F322_LOCKSTEP_VARIANT)"
	@echo "  pic10f322-test-io     libgpsim GPIO transition + pulse timing check (PIC10F322_IO_VARIANT)"
	@echo "  pic10f322-test-target fail-closed fault + lock-step + target-I/O for one PIC variant"
	@echo "                        (PIC10F322_TARGET_VARIANT); pic10f322-test-target-variants runs all"
	@echo "  pic10f322-program     flash one PIC variant to hardware (VARIANT=, PIC10F322_PROG=pk2cmd|ipecmd)"
	@echo "PIC12F675 (classic mid-range, 1024 words; release-supported, built by all/release):"
	@echo "  Full CI-gated pre-hardware validation, plus a bench-programming workflow with trim evidence."
	@echo "  pic12f675-test        all PIC12F675 pre-hardware checks (CONFIG + analysis + source"
	@echo "                        coverage + calibration contract + gpsim + stack bound)"
	@echo "  pic12f675             build all variants; enforce 1024-word flash and $(PIC12F675_DATA_LIMIT)/$(PIC12F675_DATA_BYTES)-byte data limits"
	@echo "  pic12f675-test-config build PIC12F675 HEX, then verify each CONFIG word vs design intent"
	@echo "  pic12f675-test-gpsim  drive the footswitch in gpsim, assert GPIO on the simcal images"
	@echo "  pic12f675-test-io     libgpsim GPIO transition + pulse timing, and the modeled port"
	@echo "                        against the SRAM output shadow (PIC12F675_IO_VARIANT)"
	@echo "  pic12f675-test-lockstep  libgpsim HEX-vs-model ctx_ lock-step (PIC12F675_LOCKSTEP_VARIANT)"
	@echo "  pic12f675-test-fault  libgpsim SEU injection into the guarded SFRs, the SRAM output"
	@echo "                        shadow and the pins, expecting WDT recovery (PIC12F675_FAULT_VARIANT)"
	@echo "  pic12f675-test-soak   libgpsim soak: WDT liveness + responsiveness, on holds re-derived"
	@echo "                        for the 1.024 ms tick (standalone; needs gpsim-dev+libglib2.0-dev;"
	@echo "                        PIC12F675_SOAK_VARIANT, PIC12F675_SOAK_DURATION_MS)"
	@echo "  pic12f675-analyze     cppcheck + MISRA on the PIC12F675 shell (pic8 platform; standalone)"
	@echo "  pic12f675-coverage-check-fw  exact host-gcov gate over the shell, core, and drivers"
	@echo "                        (host compiler + gcov only, so \`make test\` runs it)"
	@echo "  pic12f675-test-stack-bound  bound the 8-level hardware return stack for every variant"
	@echo "  pic12f675-simcal      derive simulator images with the oscillator calibration word"
	@echo "  pic12f675-test-calibration  prove the calibration injection leaves the shipping HEX alone"
	@echo "  pic12f675-test-target fail-closed fault + lock-step + target-I/O for one variant"
	@echo "                        (PIC12F675_TARGET_VARIANT); pic12f675-test-target-variants runs all"
	@echo "  pic12f675-preflight   read-only factory-trim capture (PIC12F675_READ_PROG=pk2cmd,"
	@echo "                        PIC12F675_TRIM_EVIDENCE= new retained JSON path)"
	@echo "  pic12f675-program     development/bench path: flash one fresh variant and record mandatory readback"
	@echo "                        (VARIANT=, PIC12F675_PROG=, PIC12F675_PROG_KIND=pk2cmd|ipecmd,"
	@echo "                        PIC12F675_TRIM_EVIDENCE=, PIC12F675_BENCH_RESULT= new directory)"
	@echo "  pic12f675-release-program  same guarded transaction, plus clean signed-tag and signed-image binding"
	@echo "                        (PIC12F675_RELEASE_TAG=vX.Y.Z; baseline/result paths must be outside the worktree)"
	@echo "  pic12f675-finalize    read-only resolution of a retained PENDING transaction"
	@echo "                        (same VARIANT, reader/writer identities, baseline, and result directory;"
	@echo "                        a transaction reserved by pic12f675-release-program must be finalized with"
	@echo "                        the same PIC12F675_RELEASE_TAG=vX.Y.Z it reserved)"
	@echo "                        Transients use private TMPDIR=, else XDG_RUNTIME_DIR/HOME; shared roots are rejected."
	@echo "                        Checks/records preservation; real programmer behavior remains hardware-unvalidated."
	@echo "                        ipecmd routing is software-only; no safe hardware attachment/handoff is published."
	@echo "PIC10F320 (constrained 256-word target; docs/pic10f320_special_case.md):"
	@echo "  pic10f320          build one PIC10F320 variant + 256-word and HW-stack gates"
	@echo "                     (PIC10F320_VARIANT=cd4053_simple|cd4053_with_mute|tq2_l2_5v_relay)"
	@echo "  pic10f320-variants build every variant; removes the whole set if any one fails"
	@echo "  pic10f320-size     XC8 program + data memory summary for one variant"
	@echo "  pic10f320-test     ALL PIC10F320 pre-hardware checks: host lanes (all variants) +"
	@echo "                     expected hashes + CONFIG + final-HEX stack + analysis/gpsim"
	@echo "  pic10f320-test-build  rebuild all variants and enforce reviewed image hashes"
	@echo "  pic10f320-test-host  host lanes for ONE variant: firmware<->core equivalence,"
	@echo "                     actuation sequence, host fault injection, firmware coverage"
	@echo "  pic10f320-test-host-variants  the same for all three (this is what \`make test\` runs;"
	@echo "                     host compiler + gcov only, no XC8)"
	@echo "  pic10f320-coverage-check-fw  exact-line host-gcov gate over src/bypass_mcu_pic10f320.c"
	@echo "  pic10f320-test-return-stack  rebuild, then recheck/report all HEX HW stacks <= 8"
	@echo "  pic10f320-analyze  cppcheck + MISRA on the PIC10F320 shell (XC8/DFP headers; standalone)"
	@echo "  pic10f320-test-target  fail-closed fault + lock-step + target-I/O for one variant"
	@echo "                     (PIC10F320_TARGET_VARIANT); pic10f320-test-target-variants runs all"
	@echo "  pic10f320-test-soak  libgpsim soak (PIC10F320_SOAK_VARIANT, PIC10F320_SOAK_DURATION_MS)"
	@echo "  pic10f320-clean    remove build_pic10f320/ (build + coverage artifacts)"
	@echo "ATtiny202 release-supported target (AVR-XT / avrxmega3):"
	@echo "  scripts/fetch_attiny_dfp.sh [DIR]  vendor the pinned device files (default XT_DFP=$(XT_DFP))"
	@echo "  attiny202-smoke  toolchain/device-pack gate: compile/link the peripheral smoke image, assert"
	@echo "                   avrxmega3 + $(XT_FLASH_BYTES) B budget (standalone; skips if XT_DFP absent)"
	@echo "  attiny202        build all variants; enforce 2 KB flash and $(XT_STATIC_RAM_LIMIT)/$(XT_SRAM_BYTES) B static-RAM limits"
	@echo "  attiny202-analyze  cppcheck + MISRA on the AVR-XT shell (DFP+avr-libc; standalone)"
	@echo "  attiny202-delay-oracle  verify coil-pulse widths from the disassembled _delay_ms loop"
	@echo "  attiny202-test   all ATtiny202 pre-hardware checks (fuses + smoke + build + stack + analyze + delay)"
	@echo "  attiny202-test-stack-bound  shipping-flag frame bound for all immutable variants ($(XT_STACK_MAX_FRAME) B)"
	@echo "  attiny202-sim    yasimavr functional + PA2/PA3 transition/pulse test:"
	@echo "                   ordering, polarity, exclusion, presence, delivered width"
	@echo "                   (standalone; needs scripts/fetch_yasimavr.sh; XT_SIM_VARIANT=)"
	@echo "  attiny202-fault  yasimavr fault-inject: 24 guarded corruptions (32 relay),"
	@echo "                   zero skips, exact completion (standalone; XT_SIM_VARIANT=)"
	@echo "  attiny202-soak   yasimavr soak: long run, assert no WDT reset + stays responsive"
	@echo "                   (standalone; XT_SOAK_DURATION_MS=, XT_SIM_VARIANT=)"
	@echo "  attiny202-lockstep  yasimavr ctx_-vs-model lock-step every settled tick"
	@echo "                   (standalone; XT_LOCKSTEP_ITERS=, XT_SIM_VARIANT=)"
	@echo "  attiny202-test-target  sim + fault + lock-step across all variants"
	@echo "                   (release uses STRICT_TOOLS=1 so missing prerequisites fail closed)"
	@echo "  attiny202-program  set fuses + flash one variant over UPDI (VARIANT=, XT_UPDI_PORT=)"
	@echo "Test (each runs across ALL variants):"
	@echo "  test            FAST full suite -- analysis, model, Classic sim, host regressions, coverage"
	@echo "  test-long       FULL exhaustive suite (minutes); alias: stress"
	@echo "  scripts/ci-local.sh  reproduce the GitHub CI suite locally before pushing (--pr, --help)"
	@echo "  test-host       golden-model algorithm tests (host, variant-agnostic)"
	@echo "  test-model-check exhaustive state-space proof of invariants"
	@echo "  test-symbolic   exhaustive single-step property proof of step()"
	@echo "  test-symbolic-klee  same properties under KLEE (if installed)"
	@echo "  test-cbmc       CBMC SAT/SMT proof of the real bypass_pure.c (if installed)"
	@echo "  test-fuses      decode + verify design fuse bytes (t13a + tinyx5 + ATtiny202)"
	@echo "  test-attiny202-output-oracle  host regression for PA2/PA3 sequence/pulse-presence checks"
	@echo "  test-attiny202-delay-oracle  host regression for the coil-pulse width parser (--selftest)"
	@echo "  test-attiny202-fault-oracle  host regression for exact fault-run accounting"
	@echo "  test-attiny202-model-ffi  host gate for the golden-model ctypes bridge"
	@echo "  test-pic10f320-return-stack-oracle  host Intel-HEX/control-flow oracle selftest"
	@echo "  test-pic10f320-expected-images  validate the pinned PIC10F320 image-hash contract"
	@echo "  test-pic10f320-coverage-archive  coverage-gate executable checks without a Git index"
	@echo "  test-stack-bound  -fstack-usage static frame bound (limit: AVR_STACK_MAX_FRAME=$(AVR_STACK_MAX_FRAME) B)"
	@echo "  test-stack-bound-regression  fail-closed stack-evidence checks"
	@echo "  test-flash-budget  exact ATtiny13a gate (<= ATTINY13A_FLASH_BUDGET=$(ATTINY13A_FLASH_BUDGET)% of 1 KB)"
	@echo "  test-flash-budget-regression  fail-closed flash-measurement checks"
	@echo "  test-sim-attiny13a  real firmware in simavr, all variants (ATtiny13a)"
	@echo "  test-sim-attiny85 / test-sim-attiny45  all variants on that tinyx5 chip"
	@echo "  test-sim-tinyx5  all variants on every tinyx5 chip"
	@echo "  test-sim-<v>-attiny<n>  one variant on one chip, e.g."
	@echo "                  test-sim-tq2_l2_5v_relay-attiny45"
	@echo "  test-fault-inject  corrupt state, verify WDT recovery (all variants x tinyx5)"
	@echo "  test-mutation   inject firmware faults, verify the suite kills them"
	@echo "  test-mutation-sandbox  verify mutation sandbox + inventory/result accounting"
	@echo "  test-attiny202-build  fail-closed AVR-XT image-generation checks"
	@echo "  test-avr-build-rebuild  classic AVR stale/config/partial-output checks"
	@echo "  test-avr-program-order  AVR *-program: build+validate, then fuses, then flash"
	@echo "  test-gpsim-wrappers  fail-closed gpsim process-status checks"
	@echo "  test-fetch-yasimavr  safe destination/rebuild/install checks for the yasimavr venv"
	@echo "  test-supply-chain  external download, cache, dependency and action pin checks"
	@echo "  test-ci-local-routing  local-CI skip-option command routing checks"
	@echo "  test-workflow-syntax  GitHub workflow YAML + ci-local job-map checks"
	@echo "  test-klee-build  linked harness/pure-core KLEE bitcode regression"
	@echo "  test-pic-build  PIC image validation + PIC10F320 rebuild-trigger checks"
	@echo "  test-release-images  exact committed/listed/fresh release artifact checks"
	@echo "  test-release-preflight  step-0 tool/input checks run to completion without build or staging"
	@echo "  test-release-provenance  release source/compiler provenance checks"
	@echo "  test-release-qualification  exact release evidence + 18-soak publication checks"
	@echo "  test-release-history  bind release history + checksum/tag signatures"
	@echo "  test-pic12f675-flash-helper  fake-programmer proof of the shipped PIC12F675 flashing helper (included in test)"
	@echo "  test-build-serialization  worktree Make/release lock regression"
	@echo "  test-target-matrix  fail-closed PIC target-variant matrix checks"
	@echo "  test-target-lane-markers  PIC target aggregates require fail-closed lane results"
	@echo "  test-pic-target-result-records  PIC12F675 canonical machine-result producers"
	@echo "  test-stack-bound-pic-regression  PIC hardware return-stack gate regression"
	@echo "  pic10f322-test-stack-bound / pic10f320-test-stack-bound / pic12f675-test-stack-bound"
	@echo "                  8-level PIC hardware return-stack depth gates"
	@echo "  test-lockstep-progress  all three PIC exact-pin/stall-propagation checks"
	@echo "  test-soak-timing  host-only soak timing boundary checks (included in test)"
	@echo "  test-variant-map-contract  every per-variant map is guard-registered (included in test)"
	@echo "  test-fault-wdt-note-contract  each PIC fault adapter supplies its own gpsim watchdog note (included in test)"
	@echo "  test-makefile-name-contract  every make goal, variable and child-environment name a file or doc uses really exists (included in test)"
	@echo "  test-todo-index    TODO.md's priority summary matches its open sections, both ways (included in test)"
	@echo "  test-resource-tables  every documented flash/RAM figure matches the image it was measured from (included in test)"
	@echo "  test-pinout-alignment  every ASCII package-pinout diagram draws a square box (included in test)"
	@echo "  test-analyze-variant-guard  every analyze-* target rejects a bad VARIANTS= instead of analyzing less (included in test)"
	@echo "  test-misra-output-contract  authored source/header MISRA diagnostics fail every lane (included in test)"
	@echo "  test-variant-selector-guard  every lane rejects a bad single-variant selector instead of skipping (included in test)"
	@echo "  test-clean-contract  clean/clean-tests remove everything the Makefile builds (included in test)"
	@echo "  test-fuse-injection-contract  every fuse byte survives -D injection into the checker (included in test)"
	@echo "  test-static-assert-guards  the firmware's compile-time guards really fail the build when violated (included in test)"
	@echo "  test-strict-tools  required host-analysis skip/strict policy checks"
	@echo "  test-workload-rebuild  workload/fuse rebuild regression checks"
	@echo "  test-pic-build-rebuild  PIC soak binaries rebuild on a workload change"
	@echo "  test-soak       24-h soak test (standalone; AVR_SOAK_VARIANT, AVR_SOAK_CHIP,"
	@echo "                  AVR_SOAK_DURATION_MS, AVR_SOAK_LIVENESS_INTERVAL_MS,"
	@echo "                  AVR_SOAK_PROGRESS_INTERVAL_MS)"
	@echo "  attiny13a-trace  emit $(AVR_BUILD_DIR)/bypass_trace.vcd for VARIANT (GTKWave)"
	@echo "Analysis:"
	@echo "  analyze         static analysis of core + all drivers (3 analyzers)"
	@echo "  analyze-tidy / analyze-cppcheck / analyze-deep  individual analyzers"
	@echo "  analyze-misra   MISRA-C:2012 gate (cppcheck misra addon; see MISRA_COMPLIANCE.md)"
	@echo "  analyze-misra-report  full MISRA inventory incl. waived deviations (report-only)"
	@echo "  coverage        human-readable golden-model coverage report"
	@echo "  coverage-check  fail if coverage < COVERAGE_MIN ($(COVERAGE_MIN)%)"
	@echo "Hardware (act on VARIANT=$(VARIANT); <n> in {$(TINYX5)} for tinyx5):"
	@echo "  attiny13a-readfuses    print current fuse bytes (read-only)"
	@echo "  attiny13a-fuses / attiny<n>-fuses      write design fuse bytes"
	@echo "  attiny13a-flash / attiny<n>-flash      flash the selected variant"
	@echo "  attiny13a-program / attiny<n>-program  fuses + flash (fresh chip)"
	@echo "Release:"
	@echo "  release-preflight  check every release prerequisite without cleaning, building or staging"
	@echo "                     (VERSION=vX.Y.Z requires final docs; tag/output state remains warnings)"
	@echo "  release         VERSION=vX.Y.Z: build+validate every release image -- AVR Classic"
	@echo "                  + ATtiny202 + PIC10F322 + PIC10F320 + PIC12F675, the canonical"
	@echo "                  RELEASE_IMAGES set (incl. 24-h soak of all 18 combos) + stage release/<ver>/."
	@echo "                  RELEASE_ARGS='--dry-run' shortens the soak; see"
	@echo "                  scripts/make-release.sh"
	@echo "Clean:"
	@echo "  clean           remove build + test artifacts"
	@echo "  clean-tests     remove only test binaries"
	@echo "  coverage-clean  remove coverage artifacts"
	@echo "Overrides: VARIANT=, AVR_PROGRAMMER=, COVERAGE_MIN=, HOSTCC=, HOST_DEFS=, SIM_DEFS=, AVR_BUILD_DIR="
	@echo "PIC overrides: PIC_CC=, PIC10F322_PROG=pk2cmd|ipecmd, PIC10F322_PROG_TOOL=PK3|PK4|PK5, PIC10F322_PROG_CMD="
	@echo "               PIC12F675_PROG=, PIC12F675_PROG_KIND=pk2cmd|ipecmd, PIC12F675_PROG_TOOL=PK3|PK4|PK5,"
	@echo "               PIC12F675_READ_PROG=pk2cmd, PIC12F675_TRIM_EVIDENCE=, PIC12F675_BENCH_RESULT=,"
	@echo "               PIC12F675_RELEASE_TAG=vX.Y.Z (pic12f675-release-program, and pic12f675-finalize"
	@echo "               when recovering a transaction that goal reserved)"

else

_MAKE_REQUESTED_GOALS := $(if $(MAKECMDGOALS),$(MAKECMDGOALS),all)
.DEFAULT_GOAL := all
.PHONY: _make-serialized-invocation $(_MAKE_REQUESTED_GOALS)

$(_MAKE_REQUESTED_GOALS): _make-serialized-invocation
	@:

_make-serialized-invocation:
	@command -v flock >/dev/null 2>&1 \
		|| { echo "ERROR: flock is required to serialize shared build artifacts" >&2; exit 1; }
	@env \
		_MAKE_SERIAL_VARIANT_EMPTY='$(_MAKE_SERIAL_VARIANT_EMPTY_COMPUTED)' \
		_MAKE_SERIAL_VARIANT_MULTI='$(_MAKE_SERIAL_VARIANT_MULTI_COMPUTED)' \
		_MAKE_SERIAL_VARIANT_UNKNOWN='$(_MAKE_SERIAL_VARIANT_UNKNOWN_COMPUTED)' \
		_MAKE_SERIAL_CLASSIC_EMPTY='$(_MAKE_SERIAL_CLASSIC_EMPTY_COMPUTED)' \
		_MAKE_SERIAL_CLASSIC_DUPLICATE='$(_MAKE_SERIAL_CLASSIC_DUPLICATE_COMPUTED)' \
		_MAKE_SERIAL_CLASSIC_UNKNOWN='$(_MAKE_SERIAL_CLASSIC_UNKNOWN_COMPUTED)' \
		_MAKE_SERIAL_PIC320_EMPTY='$(_MAKE_SERIAL_PIC320_EMPTY_COMPUTED)' \
		_MAKE_SERIAL_PIC320_DUPLICATE='$(_MAKE_SERIAL_PIC320_DUPLICATE_COMPUTED)' \
		_MAKE_SERIAL_PIC320_UNKNOWN='$(_MAKE_SERIAL_PIC320_UNKNOWN_COMPUTED)' \
		_MAKE_SERIAL_PIC12F675_TARGET_VARIANT_EMPTY='$(_MAKE_SERIAL_PIC12F675_TARGET_VARIANT_EMPTY_COMPUTED)' \
		_MAKE_SERIAL_PIC12F675_TARGET_VARIANT_MULTI='$(_MAKE_SERIAL_PIC12F675_TARGET_VARIANT_MULTI_COMPUTED)' \
		_MAKE_SERIAL_PIC12F675_TARGET_VARIANT_UNKNOWN='$(_MAKE_SERIAL_PIC12F675_TARGET_VARIANT_UNKNOWN_COMPUTED)' \
		flock ".make.lock" $(MAKE_COMMAND) \
		--no-print-directory -j1 \
		_MAKE_SERIAL_LOCK_HELD='$(_MAKE_SERIAL_WORKTREE_ID)' \
		MAKE='$(MAKE)' \
		$(if $(filter command line,$(_MAKE_SERIAL_VARIANT_ORIGIN)),VARIANT=$(call _make_shell_quote,$(_MAKE_SERIAL_VARIANT_SAFE))) \
		$(if $(filter command line,$(_MAKE_SERIAL_VARIANTS_ORIGIN)),VARIANTS=$(call _make_shell_quote,$(_MAKE_SERIAL_VARIANTS_SAFE))) \
		$(if $(filter command line,$(_MAKE_SERIAL_PIC320_VARIANTS_ORIGIN)),PIC10F320_VARIANTS_ALL=$(call _make_shell_quote,$(_MAKE_SERIAL_PIC320_VARIANTS_SAFE))) \
		$(if $(filter command line,$(_MAKE_SERIAL_PIC12F675_RELEASE_TAG_ORIGIN)),PIC12F675_RELEASE_TAG=$(call _make_shell_quote,$(_MAKE_SERIAL_PIC12F675_RELEASE_TAG_REQUESTED))) \
		$(_MAKE_REQUESTED_GOALS)

endif


# vim: tw=0 nowrap
