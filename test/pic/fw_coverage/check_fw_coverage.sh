#!/usr/bin/env bash

set -u

if [ "$#" -eq 0 ]; then
    echo "usage: check_fw_coverage.sh <source.gcov>..." >&2
    exit 2
fi

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
    while IFS= read -r rec; do
        lineno=$(printf '%s' "$rec" | awk -F: '{gsub(/[^0-9]/,"",$2); print $2}')
        src=$(printf '%s' "$rec" | cut -d: -f3- | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
        if [ "$base" = "bypass_mcu_pic10f322.c.gcov" ]; then
            case "$lineno:$src" in
                "164:__attribute__((noreturn)) static void hw_force_wdt_reset(void) {"|\
                "165:INTCONbits.GIE = 0;"|\
                "379:hw_force_wdt_reset();")
                    allowed=$((allowed + 1))
                    continue
                    ;;
            esac
        elif [ "$base" = "bypass_mcu_pic12f675.c.gcov" ]; then
            case "$lineno:$src" in
                "589:hw_force_wdt_reset();")
                    # The earlier main-loop range gate catches every invalid
                    # context before debounce_step() can report res.fault.
                    allowed=$((allowed + 1))
                    continue
                    ;;
            esac
        fi
        echo "  DISALLOWED $base L${lineno}: $src"
        file_bad=$((file_bad + 1))
    done < <(grep -E '^[[:space:]]*#####:' "$gcov_file")

    if [ "$base" = "bypass_mcu_pic10f322.c.gcov" ]; then
        if ! grep -Eq '^[[:space:]]*[1-9][0-9]*:[[:space:]]*355:[[:space:]]*hw_force_wdt_reset\(\);[[:space:]]*$' "$gcov_file"; then
            echo "  FAIL: live sanity-gate reset call at source line 355 is not covered"
            file_bad=$((file_bad + 1))
        fi
    elif [ "$base" = "bypass_mcu_pic12f675.c.gcov" ]; then
        if ! grep -Eq '^[[:space:]]*[1-9][0-9]*:[[:space:]]*556:[[:space:]]*if \([[:space:]]*\(ctx_\.program_state > RELEASE_DEBOUNCE_WAIT\) \|\|[[:space:]]*$' "$gcov_file"; then
            echo "  FAIL: program-state range guard at source line 556 is not covered"
            file_bad=$((file_bad + 1))
        fi
        if ! grep -Eq '^[[:space:]]*[1-9][0-9]*:[[:space:]]*557:[[:space:]]*\(ctx_\.debounce_counter > RELEASE_THRESH\) \|\|[[:space:]]*$' "$gcov_file"; then
            echo "  FAIL: debounce-counter range guard at source line 557 is not covered"
            file_bad=$((file_bad + 1))
        fi
        if ! grep -Eq '^[[:space:]]*[1-9][0-9]*:[[:space:]]*558:[[:space:]]*\(ctx_\.effect_state > ENGAGED\) \|\|[[:space:]]*$' "$gcov_file"; then
            echo "  FAIL: effect-state range guard at source line 558 is not covered"
            file_bad=$((file_bad + 1))
        fi
        if ! grep -Eq '^[[:space:]]*[1-9][0-9]*:[[:space:]]*565:[[:space:]]*hw_force_wdt_reset\(\);[[:space:]]*$' "$gcov_file"; then
            echo "  FAIL: live sanity-gate reset call at source line 565 is not covered"
            file_bad=$((file_bad + 1))
        fi
        if ! grep -Eq '^[[:space:]]*#####:[[:space:]]*589:[[:space:]]*hw_force_wdt_reset\(\);[[:space:]]*$' "$gcov_file"; then
            echo "  FAIL: defense-in-depth reset call at source line 589 did not remain structurally unreachable"
            file_bad=$((file_bad + 1))
        fi
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
