#!/usr/bin/env bash

# release-soak.sh -- the release soak combination sweep and its input key, as
# one unit that both the soak and the release read.
#
# WHY THIS IS A LIBRARY
#   Two callers need the same answer to "what does a release soak, and what
#   exactly does each combination drive?": the soak, which runs them, and the
#   release, which recomputes their key over the images it just built and
#   refuses unless a recorded soak already attests them. The lanes genuinely
#   disagree -- the classic AVR and ATtiny202 lanes drive ELFs, the PIC10F32x
#   lanes drive the shipped HEX, and the PIC12F675 lane drives a derived simcal
#   image that is never published -- so the mapping is real knowledge, not a
#   formality, and a second copy of it would rot.
#
#   That is not hypothetical here. v0.9.8 renamed the release soak
#   combinations, updated the orchestrator's spelling and left the Makefile
#   variable saying the old one; `make` was then asked for a target that did
#   not exist and the release failed an hour in. One copy is the fix.
#
# WHAT THE HOST MUST PROVIDE
#   Sourced into an orchestrator, not run. The host supplies its own output and
#   failure vocabulary (die, log, ok), its Makefile query (mkv), its image-path
#   composer (fw_image) and its evidence sealer (seal_evidence_result), plus the
#   release identity globals it has already read and validated. Every one of
#   those is checked before the first lane runs, so a host that is missing one
#   fails before it can compile anything rather than midway through.

# Fail before the first lane if the host has not supplied what the sweep reads.
# Cheap, and it turns "unbound variable, line 143" into a sentence.
release_soak_require_host() {
	local fn var missing=()
	for fn in die log ok mkv fw_image seal_evidence_result; do
		declare -F "$fn" >/dev/null || missing+=("function $fn")
	done
	for var in REPO_ROOT RELEASE_SOAK_NAMES VARIANTS TINYX5_PARTS FW_BASE \
			AVR_BUILD_DIR XT_VARIANTS XT_BUILD_DIR XT_TAG XT_FUSE_NAMES \
			YASIMAVR_PY_ABS PIC10F322_BUILD_DIR PIC10F322_TAG \
			PIC10F320_VARIANTS PIC10F320_BUILD_DIR PIC10F320_TAG \
			PIC12F675_BUILD_DIR PIC12F675_TAG PIC12F675_SIMCAL_DIR \
			PIC12F675_MATRIX_EVIDENCE PIC_CC PIC_DFP \
			PIC_SOAK_CXX PIC10F320_SOAK_CXX; do
		[ -n "${!var:-}" ] || missing+=("variable $var")
	done
	# An associative array cannot be tested through the indirection above: the
	# expansion yields element 0, which these never have. The ATtiny202 wrapper
	# writes one fuse assignment per name, so an empty map would silently soak
	# the right image under the wrong device configuration.
	for var in $XT_FUSE_NAMES; do
		[ -n "${XT_FUSE[$var]:-}" ] || missing+=("fuse XT_FUSE[$var]")
	done
	if [ "${#missing[@]}" -ne 0 ]; then
		printf 'FATAL: the soak sweep was sourced without %s\n' \
			"$(printf '%s, ' "${missing[@]}" | sed 's/, $//')" >&2
		return 1
	fi
}

# Assemble every release soak combination: compile or generate its driver,
# record the exact artifact it drives, and cross-check the assembled set against
# the canonical one the Makefile declares.
#
# usage: release_soak_assemble DURATION_MS LIVENESS_MS SOAKDIR EVID MATRIX_RECORD
#
# MATRIX_RECORD is the caller's already-qualified PIC12F675 fault-matrix record.
# That lane's soak driver rebuilds pic12f675-simcal, so every compile in it is
# re-checked against this record: the harness must compile from the exact matrix
# the caller qualified, never replace it with a later build.
#
# Sets, for the caller: SOAK_NAMES, SOAK_BIN, SOAK_IMAGE, SOAK_CWD, SOAK_LOG,
# NCOMBOS, and appends the derived simcal images to PIC12F675_SIMCAL_IMAGES.
release_soak_assemble() {
	if [ "$#" -ne 5 ]; then
		printf 'FATAL: release_soak_assemble requires a duration, liveness interval, soak dir, evidence dir and matrix record\n' >&2
		return 2
	fi
	release_soak_require_host || return 1
	local duration_ms=$1 liveness_ms=$2 soakdir=$3 evid=$4 matrix_record=$5
	local buildlog="$evid/soak-build.log"
	local v p f e name bin elf rundir current_matrix_record
	local -a xt_fuse_env_args=()
	local actual_soaks canonical_soaks

	declare -ga SOAK_NAMES=()
	declare -gA SOAK_BIN=() SOAK_CWD=() SOAK_LOG=()
	# The exact firmware artifact each combination drives. Recorded per combo as
	# the lane sets it up, because the lanes disagree: the classic AVR and
	# ATtiny202 soaks drive ELFs, the PIC10F32x soaks drive the shipped HEX, and
	# the PIC12F675 soak drives a DERIVED simcal image that is never shipped.
	# The input key below is only as honest as this map.
	declare -gA SOAK_IMAGE=()

	log "compiling soak binaries..."
	for v in $VARIANTS; do for p in $TINYX5_PARTS; do
		# The binary path is READ from the Makefile, not composed here. Unlike
		# the image basenames the caller restates on purpose so they can be
		# cross-checked against RELEASE_IMAGES, this path is cross-checked
		# against nothing, and a copy of it severed silently once already --
		# see the rename this file's header records.
		name="${p}_${v}"
		# --no-print-directory for the same reason mkv carries it: -s alone
		# loses to an inherited -w, and a banner here would name a soak binary
		# that cannot exist.
		bin=$(make -s --no-print-directory print-AVR_SOAK_BIN \
			AVR_SOAK_VARIANT="$v" AVR_SOAK_CHIP="$p") \
			|| die "cannot read AVR_SOAK_BIN for $name from the Makefile"
		[ -n "$bin" ] || die "AVR_SOAK_BIN expands empty for $name"
		elf="$(fw_image "$AVR_BUILD_DIR" "$p" "$v").elf"
		make --old-file="$elf" "$bin" AVR_REBUILD_PREREQ= \
			AVR_SOAK_VARIANT="$v" AVR_SOAK_CHIP="$p" AVR_SOAK_DURATION_MS="$duration_ms" \
			AVR_SOAK_LIVENESS_INTERVAL_MS="$liveness_ms" \
			AVR_SOAK_COMBINATION_NAME="$name" \
			>>"$buildlog" 2>&1 || die "failed to build AVR soak $name"
		SOAK_NAMES+=("$name"); SOAK_BIN[$name]="$REPO_ROOT/$bin"
		SOAK_IMAGE[$name]="$elf"
		SOAK_CWD[$name]="$REPO_ROOT"   # relative FW_PATH; the binary writes no files
		SOAK_LOG[$name]="$evid/soak-$name.log"
	done; done
	# ATtiny202: three more combos, one per output stage, at the same full
	# duration as every other release combo. The driver is a Python script
	# rather than a compiled binary, so each combo gets a tiny generated wrapper
	# -- the soak launcher execs one argument-less program per combination, and
	# threading per-combo argv/env through it would complicate the one piece of
	# this phase that must stay obviously correct. The wrapper pins the
	# combination name that the driver binds into its SOAK_RESULT record, which
	# the caller's result validation then matches exactly, so a wrapper pointing
	# at the wrong image cannot pass.
	for f in $XT_FUSE_NAMES; do
		xt_fuse_env_args+=("ATTINY202_FUSE_$(printf '%s' "$f" | tr '[:lower:]' '[:upper:]')=${XT_FUSE[$f]}")
	done
	for v in $XT_VARIANTS; do
		name="attiny202_${v}"; bin="$soakdir/soak_attiny202_${v}.sh"
		elf="$REPO_ROOT/$(fw_image "$XT_BUILD_DIR" "$XT_TAG" "$v").elf"
		[ -f "$elf" ] || die "ATtiny202 soak ELF missing: $elf"
		{
			printf '#!/bin/sh\n'
			printf '# generated by release-soak.sh -- ATtiny202 release soak combo %s\n' "$name"
			printf 'set -e\n'
			printf 'cd %q\n' "$REPO_ROOT"
			printf 'exec env PYTHONPATH=test/avr \\\n'
			for e in "${xt_fuse_env_args[@]}"; do printf '  %q \\\n' "$e"; done
			printf '  ATTINY202_SOAK_DURATION_MS=%q \\\n' "$duration_ms"
			printf '  ATTINY202_SOAK_LIVENESS_INTERVAL_MS=%q \\\n' "$liveness_ms"
			printf '  ATTINY202_SOAK_PROGRESS_INTERVAL_MS=%q \\\n' "$liveness_ms"
			printf '  ATTINY202_SOAK_COMBINATION_NAME=%q \\\n' "$name"
			printf '  %q %q %q\n' "$YASIMAVR_PY_ABS" \
				"$REPO_ROOT/test/avr/test_soak_attiny202.py" "$elf"
		} > "$bin" || die "could not write ATtiny202 soak wrapper $bin"
		chmod +x "$bin" || die "could not make $bin executable"
		printf 'generated ATtiny202 soak wrapper: %s -> %s\n' "$name" "$elf" \
			>>"$buildlog"
		SOAK_NAMES+=("$name"); SOAK_BIN[$name]="$bin"
		SOAK_IMAGE[$name]="$elf"
		SOAK_CWD[$name]="$REPO_ROOT"   # the wrapper cd's itself; nothing is written here
		SOAK_LOG[$name]="$evid/soak-$name.log"
	done
	for v in $VARIANTS; do
		name="pic10f322_${v}"; bin="$soakdir/test_soak_pic10f322_${v}"
		make "$bin" PIC10F322_SOAK_BIN="$bin" PIC10F322_SOAK_VARIANT="$v" \
			PIC10F322_SOAK_DURATION_MS="$duration_ms" \
			PIC10F322_SOAK_LIVENESS_INTERVAL_MS="$liveness_ms" \
			PIC10F322_SOAK_COMBINATION_NAME="$name" \
			>>"$buildlog" 2>&1 || die "failed to build PIC soak $name"
		rundir="$soakdir/run-$name"; mkdir -p "$rundir"
		SOAK_NAMES+=("$name"); SOAK_BIN[$name]="$bin"
		SOAK_IMAGE[$name]="$(fw_image "$PIC10F322_BUILD_DIR" "$PIC10F322_TAG" "$v").hex"
		SOAK_CWD[$name]="$rundir"      # absolute FW_PATH; isolates gpsim.log per combo
		SOAK_LOG[$name]="$evid/soak-$name.log"
	done
	# Three more combos, one per PIC10F320 output stage -- the same full duration
	# as every other release combo, not a shortened smoke. Each drives its own
	# real HEX in libgpsim. PIC10F320_SOAK_VARIANT selects the image; the driver
	# itself is the shared parent one (the parent copy is ahead, carrying
	# SOAK_LIVENESS_DUE).
	for v in $PIC10F320_VARIANTS; do
		name="pic10f320_${v}"; bin="$soakdir/test_soak_pic10f320_${v}"
		make "$bin" PIC10F320_SOAK_BIN="$bin" PIC10F320_SOAK_VARIANT="$v" \
			PIC10F320_SOAK_DURATION_MS="$duration_ms" \
			PIC10F320_SOAK_LIVENESS_INTERVAL_MS="$liveness_ms" \
			PIC10F320_SOAK_COMBINATION_NAME="$name" \
			>>"$buildlog" 2>&1 || die "failed to build PIC10F320 soak $name"
		rundir="$soakdir/run-$name"; mkdir -p "$rundir"
		SOAK_NAMES+=("$name"); SOAK_BIN[$name]="$bin"
		SOAK_IMAGE[$name]="$(fw_image "$PIC10F320_BUILD_DIR" "$PIC10F320_TAG" "$v").hex"
		SOAK_CWD[$name]="$rundir"      # absolute FW_PATH; isolates gpsim.log per combo
		SOAK_LOG[$name]="$evid/soak-$name.log"
	done
	# Three more combos, one per PIC12F675 output stage. UNIQUE to this part: the
	# soak drives a DERIVED simcal image, not the shipped HEX. The direct binary
	# target's normal prerequisite rebuilds pic12f675-simcal, so the caller marks
	# that producer old: the harness must compile from the exact matrix already
	# qualified, never replace it with a later build. Reverify all twelve
	# artifacts after every harness compile. Record each derived image so it is
	# also pinned unchanged across the soak, exactly as the ATtiny202 ELF is.
	for v in $VARIANTS; do
		name="pic12f675_${v}"; bin="$soakdir/test_soak_pic12f675_${v}"
		make --old-file=_pic12f675-build-soak "$bin" \
			PIC12F675_SOAK_BIN="$bin" PIC12F675_SOAK_VARIANT="$v" \
			PIC12F675_SOAK_DURATION_MS="$duration_ms" \
			PIC12F675_SOAK_LIVENESS_INTERVAL_MS="$liveness_ms" \
			PIC12F675_SOAK_COMBINATION_NAME="$name" \
			PIC_CC="$PIC_CC" PIC_DFP="$PIC_DFP" \
			>>"$buildlog" 2>&1 || die "failed to build PIC12F675 soak $name"
		current_matrix_record=$(python3 "$PIC12F675_MATRIX_EVIDENCE" verify \
			--build-dir "$PIC12F675_BUILD_DIR" --fw-base "$FW_BASE" \
			--tag "$PIC12F675_TAG") \
			|| die "PIC12F675 matrix changed while compiling soak $name"
		[ "$current_matrix_record" = "$matrix_record" ] \
			|| die "PIC12F675 soak $name was compiled from a different qualified matrix"
		PIC12F675_SIMCAL_IMAGES+=("$(fw_image "$PIC12F675_SIMCAL_DIR" "$PIC12F675_TAG" "$v")_simcal.hex")
		rundir="$soakdir/run-$name"; mkdir -p "$rundir"
		SOAK_NAMES+=("$name"); SOAK_BIN[$name]="$bin"
		SOAK_IMAGE[$name]="${PIC12F675_SIMCAL_IMAGES[-1]}"
		SOAK_CWD[$name]="$rundir"      # absolute FW_PATH; isolates gpsim.log per combo
		SOAK_LOG[$name]="$evid/soak-$name.log"
	done
	seal_evidence_result "$buildlog"

	NCOMBOS=${#SOAK_NAMES[@]}
	actual_soaks=$(printf '%s\n' "${SOAK_NAMES[@]}" | LC_ALL=C sort)
	canonical_soaks=$(printf '%s\n' $RELEASE_SOAK_NAMES | LC_ALL=C sort)
	if [ "$actual_soaks" != "$canonical_soaks" ]; then
		diff -u <(printf '%s\n' "$canonical_soaks") <(printf '%s\n' "$actual_soaks") >&2 || true
		die "release soak combinations do not match canonical RELEASE_SOAK_NAMES"
	fi
}

# ----------------------------------------------------------------------------
# What a soak PROVES, as a key.
# ----------------------------------------------------------------------------
# A soak is the only part of a release measured in days, and between v0.9.10 and
# v0.9.13 it re-ran three times against byte-identical images: the releases in
# between changed documentation, tests and tooling, and no image at all. Nothing
# recorded that, so every one paid the full duration to re-derive a result it
# already had.
#
# The input key is the record that makes the question answerable. It names every
# input that can change what a soak observes, and deliberately omits everything
# that cannot -- there is no version, no date and no source commit in the hashed
# payload, because a release that changes only prose must produce the SAME key.
# The commit appears on the RESULT line, outside the payload, where it says who
# produced the record without becoming part of its identity.
#
# Duration is on the result line for a different reason: it is a magnitude, not
# an input. A 24-hour soak of these inputs subsumes a 1-hour one, so a consumer
# compares it with >= rather than for equality. The liveness interval STAYS in
# the payload: it changes what the soak checks rather than how long it checks
# for, and an exact match is the conservative reading.
#
# What is IN: each combination and the exact artifact it drove (ELF, shipped HEX
# or -- for the PIC12F675 -- the derived simcal image), the soak driver sources
# each lane declares in the Makefile, the identity of every tool that EXECUTES a
# soak, and the durations.
#
# What is deliberately OUT: the image-producing compilers. XC8 and avr-gcc
# determine the images, and the images are hashed here directly, so naming the
# compilers again would add no information and would invalidate a soak whenever
# an unrelated toolchain row moved. For the same reason this does not fold in
# the toolchain evidence digest, which covers cppcheck, CBMC, clang and DFP
# paths -- none of which ever runs a soak. A key that over-invalidates is a key
# nobody can reuse.
#
# usage: release_soak_input_key DURATION_MS LIVENESS_MS PAYLOAD KEYFILE COMMIT
#
# Reads the SOAK_NAMES/SOAK_IMAGE map release_soak_assemble built. Writes the
# hashed payload to PAYLOAD and the payload-plus-result-line record to KEYFILE.
# Sets, for the caller: SOAK_INPUTS_SHA256, SOAK_KEY_COMBINATIONS,
# SOAK_KEY_DRIVERS, SOAK_KEY_HARNESSES.
release_soak_input_key() {
	if [ "$#" -ne 5 ]; then
		printf 'FATAL: release_soak_input_key requires a duration, liveness interval, payload path, key path and commit\n' >&2
		return 2
	fi
	release_soak_require_host || return 1
	declare -F release_tool_version_line >/dev/null \
		|| { printf 'FATAL: the soak input key requires the release tool-version helper\n' >&2; return 1; }
	local harness_var
	for harness_var in TC_SIMAVR TC_GPSIM TC_YASIMAVR TC_HOST_CC; do
		[ -n "${!harness_var:-}" ] \
			|| { printf 'FATAL: the soak input key was asked for before %s was identified\n' \
				"$harness_var" >&2; return 1; }
	done
	local duration_ms=$1 liveness_ms=$2 payload=$3 keyfile=$4 commit=$5
	local dep_var drivers driver name image digest
	local tc_soak_cxx tc_soak_cxx_320

	log "recording the soak input key..."
	drivers=$(
		for dep_var in AVR_SOAK_DEPS XT_SOAK_DEPS PIC10F322_SOAK_DEPS \
				PIC10F320_SOAK_DEPS PIC12F675_SOAK_DEPS; do
			mkv "$dep_var" | tr ' ' '\n'
		done | sed '/^$/d' | sort -u
	) || die "could not read the soak driver sources from the Makefile"
	[ -n "$drivers" ] \
		|| die "the Makefile declares no soak driver sources; refusing to key a soak on nothing"
	tc_soak_cxx=$(release_tool_version_line "PIC soak C++ (PIC_SOAK_CXX=$PIC_SOAK_CXX)" \
		"$PIC_SOAK_CXX") \
		|| die "could not record the PIC soak compiler provenance"
	tc_soak_cxx_320=$(release_tool_version_line \
		"PIC10F320 soak C++ (PIC10F320_SOAK_CXX=$PIC10F320_SOAK_CXX)" \
		"$PIC10F320_SOAK_CXX") \
		|| die "could not record the PIC10F320 soak compiler provenance"
	{
		printf 'SOAK_KEY format=2\n'
		printf 'liveness_interval_ms=%s\n' "$liveness_ms"
		for name in $(printf '%s\n' "${SOAK_NAMES[@]}" | sort); do
			image=${SOAK_IMAGE[$name]:-}
			[ -n "$image" ] \
				|| die "soak combination $name records no image; the key would omit what it drove"
			[ -f "$image" ] || die "soak image for $name is missing: $image"
			digest=$(sha256sum -- "$image") \
				|| die "could not hash the soak image for $name: $image"
			printf 'combination\t%s\t%s\n' "$name" "${digest%% *}"
		done
		for driver in $drivers; do
			[ -f "$driver" ] \
				|| die "declared soak driver source is missing: $driver"
			digest=$(sha256sum -- "$driver") \
				|| die "could not hash the soak driver source: $driver"
			printf 'driver\t%s\t%s\n' "$driver" "${digest%% *}"
		done
		printf 'harness\t%s\t%s\n' \
			'simavr' "$TC_SIMAVR" \
			'gpsim' "$TC_GPSIM" \
			'yasimavr' "$TC_YASIMAVR" \
			'host-cc' "$TC_HOST_CC" \
			'soak-cxx' "$tc_soak_cxx" \
			'soak-cxx-320' "$tc_soak_cxx_320"
	} > "$payload" \
		|| die "could not record the soak input key"
	if grep -q '^[[:space:]]*$' "$payload"; then
		die "the soak input key contains a blank line"
	fi
	SOAK_KEY_COMBINATIONS=$(grep -c $'^combination\t' "$payload") \
		|| die "could not count the keyed soak combinations"
	[ "$SOAK_KEY_COMBINATIONS" -eq "$NCOMBOS" ] \
		|| die "the soak input key names $SOAK_KEY_COMBINATIONS combinations, not the $NCOMBOS assembled"
	SOAK_KEY_DRIVERS=$(grep -c $'^driver\t' "$payload") \
		|| die "could not count the keyed soak driver sources"
	SOAK_KEY_HARNESSES=$(grep -c $'^harness\t' "$payload") \
		|| die "could not count the keyed soak harnesses"
	# The digest covers the payload and NOT the result line that carries it, for
	# the same reason an evidence seal excludes its own: a self-referential hash
	# cannot be recomputed by a reader.
	SOAK_INPUTS_SHA256=$(sha256sum -- "$payload") \
		|| die "could not hash the soak input key"
	SOAK_INPUTS_SHA256=${SOAK_INPUTS_SHA256%% *}
	{
		cat -- "$payload"
		printf 'SOAK_KEY_RESULT format=2 status=pass combinations=%d drivers=%d harnesses=%d duration_ms=%s inputs_sha256=%s source_commit=%s\n' \
			"$SOAK_KEY_COMBINATIONS" "$SOAK_KEY_DRIVERS" "$SOAK_KEY_HARNESSES" \
			"$duration_ms" "$SOAK_INPUTS_SHA256" "$commit"
	} > "$keyfile" \
		|| die "could not seal the soak input key"
	ok "soak input key: $SOAK_INPUTS_SHA256 ($SOAK_KEY_COMBINATIONS combinations, $SOAK_KEY_DRIVERS driver sources, $SOAK_KEY_HARNESSES harnesses)."
}

# ----------------------------------------------------------------------------
# The record: what the current images have been soaked for.
# ----------------------------------------------------------------------------
# One record, at a fixed path in the worktree, overwritten in place and
# committed. Git history is the archive, so an overwritten record is a checkout
# away rather than lost, and the tree carries one live record however many
# releases it has cut.
#
# It is not a new file format. It is the three kinds of file a release already
# writes -- the soak input key, the evidence index, and the sealed transcripts
# -- under names a reader can find. There is no signature, and that is
# deliberate: a signature establishes that a directory came from who it claims
# to, which matters for a release because a release is consumed by other people.
# This never crosses that boundary. Anyone who can rewrite it can rewrite the
# images it describes. What it needs instead is IDENTITY, which comes from a
# release recomputing the key over the images it has just built, and BODY
# INTEGRITY, which the per-transcript seals already carry.
RELEASE_SOAK_RECORD_DIR=soak
RELEASE_SOAK_RECORD_KEY=24HR_SOAK_EVIDENCE
RELEASE_SOAK_RECORD_INDEX=INDEX

# Read the record's result line. Echoes, tab separated: the inputs digest, the
# attested per-combination duration in ms, the commit whose run produced it, and
# the number of combinations it covers. Returns 1 when there is no record, or
# when what is there does not parse -- the caller decides which sentence to say.
release_soak_record_read() {
	if [ "$#" -ne 1 ]; then
		printf 'FATAL: release_soak_record_read requires a record directory\n' >&2
		return 2
	fi
	local record_dir=$1 keyfile="$1/$RELEASE_SOAK_RECORD_KEY"
	local result key duration commit combinations
	[ -f "$keyfile" ] && [ ! -L "$keyfile" ] && [ -s "$keyfile" ] || return 1
	result=$(grep '^SOAK_KEY_RESULT ' -- "$keyfile") || return 1
	[ "$(printf '%s\n' "$result" | wc -l)" -eq 1 ] || return 1
	[ "$(tail -n 1 -- "$keyfile")" = "$result" ] || return 1
	key=$(printf '%s\n' "$result" | tr ' ' '\n' | sed -n 's/^inputs_sha256=//p')
	duration=$(printf '%s\n' "$result" | tr ' ' '\n' | sed -n 's/^duration_ms=//p')
	commit=$(printf '%s\n' "$result" | tr ' ' '\n' | sed -n 's/^source_commit=//p')
	combinations=$(printf '%s\n' "$result" | tr ' ' '\n' | sed -n 's/^combinations=//p')
	[[ "$key" =~ ^[0-9a-f]{64}$ ]] || return 1
	[[ "$duration" =~ ^[1-9][0-9]*$ ]] || return 1
	[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || return 1
	[[ "$combinations" =~ ^[1-9][0-9]*$ ]] || return 1
	printf '%s\t%s\t%s\t%s\n' "$key" "$duration" "$commit" "$combinations"
}

# Does the record already attest these exact inputs, for at least this long?
# Duration compares with >= because it is a magnitude rather than an input: a
# 24-hour soak of these images subsumes a 1-hour one.
release_soak_record_attests() {
	if [ "$#" -ne 3 ]; then
		printf 'FATAL: release_soak_record_attests requires a record directory, key and duration\n' >&2
		return 2
	fi
	local record_dir=$1 key=$2 duration=$3 fields
	fields=$(release_soak_record_read "$record_dir") || return 1
	[ "$(printf '%s' "$fields" | cut -f1)" = "$key" ] || return 1
	[ "$(printf '%s' "$fields" | cut -f2)" -ge "$duration" ]
}

# Write the record for a soak that has just passed: the input key computed
# before it started, and every transcript it produced, each already sealed by
# its own payload digest.
#
# usage: release_soak_record_write RECORD_DIR KEYFILE EVID COMMIT
#
# Built beside the record and swapped in, so an interrupted write leaves either
# the previous record or none. None is the fail-closed direction: a release
# that finds no record says to soak first.
release_soak_record_write() {
	if [ "$#" -ne 4 ]; then
		printf 'FATAL: release_soak_record_write requires a record directory, key file, evidence dir and commit\n' >&2
		return 2
	fi
	local record_dir=$1 keyfile=$2 evid=$3 commit=$4
	local staging="$record_dir.staging"
	local name base role size record members=0
	local -a bases=()

	[ "${#RELEASE_EVIDENCE_ROLE[@]}" -gt 0 ] \
		|| die "the soak record cannot be written without the declared evidence role map"
	# The build transcript belongs to the record for the same reason the
	# transcripts do: after this change nothing else produces it, so a release
	# that retains it has to get it from here.
	bases=(soak-build.log)
	for name in "${SOAK_NAMES[@]}"; do bases+=("soak-$name.log"); done

	rm -rf -- "$staging" || die "could not clear the soak record staging directory"
	mkdir -p "$staging" || die "could not create the soak record staging directory"
	cp -p -- "$keyfile" "$staging/$RELEASE_SOAK_RECORD_KEY" \
		|| die "could not record the soak input key"
	for base in "${bases[@]}"; do
		[ -f "$evid/$base" ] && [ ! -L "$evid/$base" ] && [ -s "$evid/$base" ] \
			|| die "soak transcript is missing, empty, or not a regular file: $base"
		cp -p -- "$evid/$base" "$staging/$base" \
			|| die "could not record soak transcript $base"
	done
	# The same index shape a release writes, rendered from the Makefile's role
	# map rather than from the directory, so a member that went missing is a row
	# nothing can satisfy instead of a row that was never written.
	{
		printf 'EVIDENCE_INDEX format=2 source_commit=%s\n' "$commit"
		for base in $(printf '%s\n' "${bases[@]}" | sort); do
			role=${RELEASE_EVIDENCE_ROLE[$base]:-}
			[ -n "$role" ] \
				|| die "soak record member has no declared evidence role: $base"
			size=$(stat -c%s -- "$staging/$base") \
				|| die "could not size soak record member: $base"
			record=$(grep '^EVIDENCE_RESULT ' -- "$staging/$base") \
				|| die "soak record member carries no evidence result: $base"
			[ "$(printf '%s\n' "$record" | wc -l)" -eq 1 ] \
				|| die "soak record member carries more than one evidence result: $base"
			printf '%s\t%s\t%s\t%s\n' "$base" "$role" "$size" "$record"
			members=$((members + 1))
		done
		printf 'EVIDENCE_INDEX_RESULT format=2 status=pass members=%d source_commit=%s\n' \
			"$members" "$commit"
	} > "$staging/$RELEASE_SOAK_RECORD_INDEX" \
		|| die "could not write the soak record index"
	[ "$members" -eq "${#bases[@]}" ] \
		|| die "the soak record index lists $members members, not the ${#bases[@]} written"

	rm -rf -- "$record_dir" || die "could not replace the previous soak record"
	mv -- "$staging" "$record_dir" || die "could not install the soak record"
	ok "soak record written: $record_dir ($members files, ${#SOAK_NAMES[@]} combinations)."
}
