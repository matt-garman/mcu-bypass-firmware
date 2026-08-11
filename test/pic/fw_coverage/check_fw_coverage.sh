#!/usr/bin/env bash
#
# Exact line-coverage gate over the PIC shipping sources.
#
# Every assertion below names a specific construct in the shell -- the main-loop
# context range gate, the live sanity-gate watchdog reset, the defense-in-depth
# res.fault reset that must stay structurally unreachable -- and each one used to
# be written as a source LINE NUMBER. That made the gate report false failures on
# edits that changed nothing it checks: a refactor that moved the PIC12F675 main
# loop thirteen lines down fired six of these at once, on a shell whose behaviour
# and executable-line count were unchanged. The message pointed at the guard; the
# defect was in the gate.
#
# Anchors are therefore LOCATED by the source text gcov already carries on every
# record, and the line number is reported as observed evidence rather than
# required as input. Location is fail-closed: an anchor matching zero lines, or
# several, is a failure -- a guarded construct cannot be deleted, renamed or
# duplicated and quietly stop being checked.
#
# One anchor text is deliberately NOT unique: `hw_force_wdt_reset();` is the live
# sanity-gate call AND the res.fault call, character for character. Those two are
# told apart by file order -- live first, res.fault second, in both shells' main
# loops -- and the gate requires exactly two of them, so a third call site fails
# here instead of silently re-pointing the ordinal. That is what lets this gate
# keep the two apart at all; test/pic10f320/fault/check_fw_coverage.sh takes the
# other route for the same pair, allow-listing both by text and leaning on its
# fault harness to catch a regression in the live one.

set -u

if [ "$#" -eq 0 ]; then
    echo "usage: check_fw_coverage.sh <source.gcov>..." >&2
    exit 2
fi

# The "<count>:<line>:" head of an EXECUTABLE gcov record. A "-" count means the
# line carries no code, so it can be neither covered nor uncovered and must never
# anchor an assertion. A trailing "*" is gcov's marker for a line that ran but
# holds unexecuted blocks; that line IS covered, so accept it here.
REC='^[[:space:]]*([0-9]+\*?|#####):[[:space:]]*[0-9]+:[[:space:]]*'

# The source line number gcov gave record $1.
rec_lineno() {
    printf '%s' "$1" | awk -F: '{gsub(/[^0-9]/,"",$2); print $2}'
}

# True when record $1 is an executable line that never ran.
rec_uncovered() {
    case "$(printf '%s' "$1" | cut -d: -f1 | tr -d '[:space:]')" in
        '#####') return 0 ;;
        *)       return 1 ;;
    esac
}

# Locate the sole executable record in annotation $1 whose source text matches
# the ERE $2, with $3 naming the construct in diagnostics. Sets FOUND_REC and
# FOUND_LINE on success.
FOUND_REC=""
FOUND_LINE=""
find_one() {
    local n
    FOUND_REC=""
    FOUND_LINE=""
    n=$(grep -cE "$REC$2" "$1")
    if [ "$n" -ne 1 ]; then
        echo "  FAIL: $3: expected exactly one matching source line in $(basename "$1"), found $n"
        return 1
    fi
    FOUND_REC=$(grep -E "$REC$2" "$1")
    FOUND_LINE=$(rec_lineno "$FOUND_REC")
    return 0
}

# find_one, plus the requirement that the located line was executed.
require_covered() {
    find_one "$1" "$2" "$3" || return 1
    if rec_uncovered "$FOUND_REC"; then
        echo "  FAIL: $3 at source line $FOUND_LINE is not covered"
        return 1
    fi
    return 0
}

# require_covered for one clause of the PIC12F675 main-loop range gate, booking
# the outcome into the enclosing file's `guards` evidence string and `file_bad`
# tally. Written out one call per clause rather than looped over a packed
# "pattern|description" list: these patterns contain the C source's own `||`,
# so any delimiter cheap enough to pack with is a delimiter that occurs in the
# data -- an earlier draft silently sliced its own diagnostics in half that way.
guard_check() {
    if require_covered "$gcov_file" "$1" "$2"; then
        guards="${guards:+$guards/}L$FOUND_LINE"
    else
        guards="${guards:+$guards/}L?"
        file_bad=$((file_bad + 1))
    fi
}

# The two hw_force_wdt_reset() CALL sites of annotation $1, in file order.
RESET_CALL_RE='hw_force_wdt_reset\(\);[[:space:]]*$'
find_reset_calls() {
    local recs n
    n=$(grep -cE "$REC$RESET_CALL_RE" "$1")
    if [ "$n" -ne 2 ]; then
        echo "  FAIL: expected exactly two hw_force_wdt_reset() call sites in $(basename "$1"), found $n"
        return 1
    fi
    recs=$(grep -E "$REC$RESET_CALL_RE" "$1")
    LIVE_RESET_REC=$(printf '%s\n' "$recs" | sed -n 1p)
    FAULT_RESET_REC=$(printf '%s\n' "$recs" | sed -n 2p)
    LIVE_RESET_LINE=$(rec_lineno "$LIVE_RESET_REC")
    FAULT_RESET_LINE=$(rec_lineno "$FAULT_RESET_REC")
    return 0
}

bad=0
for gcov_file in "$@"; do
    if [ ! -f "$gcov_file" ] || [ ! -s "$gcov_file" ]; then
        echo "FAIL: missing or empty firmware annotation: $gcov_file"
        bad=$((bad + 1))
        continue
    fi

    base=$(basename "$gcov_file")
    total=$(grep -cE '^[[:space:]]*([0-9]+|#####):[[:space:]]*[0-9]+:' "$gcov_file")
    uncovered=$(grep -cE '^[[:space:]]*#####:' "$gcov_file")
    if ! [[ "$total" =~ ^[0-9]+$ && "$uncovered" =~ ^[0-9]+$ ]] || [ "$total" -eq 0 ]; then
        echo "FAIL: no countable executable lines in $gcov_file"
        bad=$((bad + 1))
        continue
    fi

    file_bad=0
    allowed=0
    anchors=""
    LIVE_RESET_REC=""
    FAULT_RESET_REC=""
    LIVE_RESET_LINE=""
    FAULT_RESET_LINE=""
    RESET_DEF_LINE=""
    RESET_GIE_LINE=""

    # Locate this shell's anchors BEFORE walking anything, so the allow-list
    # below is keyed to the lines gcov actually reported. A failure here is not
    # a coverage violation but a broken oracle, so it stops this file outright
    # rather than cascading into a list of misattributed DISALLOWED lines.
    case "$base" in
        bypass_mcu_pic10f322.c.gcov|bypass_mcu_pic12f675.c.gcov)
            if ! find_reset_calls "$gcov_file"; then
                echo "FAIL: could not locate the watchdog-reset call sites in $base"
                bad=$((bad + 1))
                continue
            fi
            ;;
    esac
    if [ "$base" = "bypass_mcu_pic10f322.c.gcov" ]; then
        # gcov's edge-flow solver cannot credit a function with no exit, so
        # hw_force_wdt_reset()'s signature and body read as uncovered even
        # though the harness drives them. Both are allow-listed by position
        # here; the PIC12F675 harness reaches them for real, so that arm needs
        # neither entry.
        if ! find_one "$gcov_file" \
                '__attribute__\(\(noreturn\)\) static void hw_force_wdt_reset\(void\) \{[[:space:]]*$' \
                "hw_force_wdt_reset() definition"; then
            echo "FAIL: could not locate the watchdog-reset definition in $base"
            bad=$((bad + 1))
            continue
        fi
        RESET_DEF_LINE=$FOUND_LINE
        if ! find_one "$gcov_file" 'INTCONbits\.GIE = 0;[[:space:]]*$' \
                "interrupt disable inside hw_force_wdt_reset()"; then
            echo "FAIL: could not locate the watchdog-reset interrupt disable in $base"
            bad=$((bad + 1))
            continue
        fi
        RESET_GIE_LINE=$FOUND_LINE
    fi

    while IFS= read -r rec; do
        lineno=$(printf '%s' "$rec" | awk -F: '{gsub(/[^0-9]/,"",$2); print $2}')
        src=$(printf '%s' "$rec" | cut -d: -f3- | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
        if [ "$base" = "bypass_mcu_pic10f322.c.gcov" ]; then
            if [ "$lineno" = "$RESET_DEF_LINE" ] ||
               [ "$lineno" = "$RESET_GIE_LINE" ] ||
               [ "$lineno" = "$FAULT_RESET_LINE" ]; then
                allowed=$((allowed + 1))
                continue
            fi
        elif [ "$base" = "bypass_mcu_pic12f675.c.gcov" ]; then
            # The earlier main-loop range gate catches every invalid context
            # before debounce_step() can report res.fault.
            if [ "$lineno" = "$FAULT_RESET_LINE" ]; then
                allowed=$((allowed + 1))
                continue
            fi
        fi
        echo "  DISALLOWED $base L${lineno}: $src"
        file_bad=$((file_bad + 1))
    done < <(grep -E '^[[:space:]]*#####:' "$gcov_file")

    if [ "$base" = "bypass_mcu_pic10f322.c.gcov" ]; then
        if rec_uncovered "$LIVE_RESET_REC"; then
            echo "  FAIL: live sanity-gate reset call at source line $LIVE_RESET_LINE is not covered"
            file_bad=$((file_bad + 1))
        fi
        anchors="reset definition L$RESET_DEF_LINE/L$RESET_GIE_LINE"
        anchors="$anchors, live reset L$LIVE_RESET_LINE"
        anchors="$anchors, unreachable reset L$FAULT_RESET_LINE"
    elif [ "$base" = "bypass_mcu_pic12f675.c.gcov" ]; then
        guards=""
        guard_check 'if \([[:space:]]*\(ctx_\.program_state > RELEASE_DEBOUNCE_WAIT\) \|\|[[:space:]]*$' \
                    "program-state range guard"
        guard_check '\(ctx_\.debounce_counter > RELEASE_THRESH\) \|\|[[:space:]]*$' \
                    "debounce-counter range guard"
        guard_check '\(ctx_\.effect_state > ENGAGED\) \|\|[[:space:]]*$' \
                    "effect-state range guard"
        if rec_uncovered "$LIVE_RESET_REC"; then
            echo "  FAIL: live sanity-gate reset call at source line $LIVE_RESET_LINE is not covered"
            file_bad=$((file_bad + 1))
        fi
        if ! rec_uncovered "$FAULT_RESET_REC"; then
            echo "  FAIL: defense-in-depth reset call at source line $FAULT_RESET_LINE did not remain structurally unreachable"
            file_bad=$((file_bad + 1))
        fi
        anchors="range gate $guards"
        anchors="$anchors, live reset L$LIVE_RESET_LINE"
        anchors="$anchors, unreachable reset L$FAULT_RESET_LINE"
    fi

    if [ -n "$anchors" ]; then
        echo "  anchors located in $base: $anchors"
    fi

    covered=$((total - uncovered))
    echo "$base: $covered/$total executable lines, $allowed allowed, $file_bad disallowed"
    bad=$((bad + file_bad))
done

if [ "$bad" -ne 0 ]; then
    echo "FAIL: $bad PIC shipping-source coverage violation(s)"
    exit 1
fi

echo "OK: all PIC shipping-source lines are covered except the documented reset path."
