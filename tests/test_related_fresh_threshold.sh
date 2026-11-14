#!/usr/bin/env bash
# Offline real mem prefilter + common.sh threshold and timestamp fallback checks.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" HEADLONG_HOME="$WORK/home" MEM_DIR="$WORK/mem"
export PATH="$REPO/bin:$PATH" TZ=UTC0
mkdir -p "$MEM_DIR" "$HOME"
source "$REPO/thinkers/_lib/common.sh"
now=$(date -u +%s)
for pair in fresh:3600 old:172800 weeks:1728000; do
    name=${pair%:*}; seconds=${pair#*:}
    created=$(date -u -d "@$((now-seconds))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null) \
        || created=$(date -u -r "$((now-seconds))" '+%Y-%m-%d %H:%M:%S')
    printf -- '---\nid: %s\ntype: fact\nsummary: amber telescope calibration\ncreated: %s\n---\n\namber telescope calibration violet reference.\n' \
        "$name" "$created" > "$MEM_DIR/$name.md"
done
pass=0; fail=0
for cutoff in default 0 1 7200 86400 2592000; do
    unset RELATED_FRESH_S
    [[ "$cutoff" == default ]] || export RELATED_FRESH_S="$cutoff"
    result=$(_related_memories 'amber telescope calibration' '' 10)
    for name in fresh old weeks; do
        expected=yes
        case "$cutoff:$name" in default:fresh|7200:fresh|86400:fresh|2592000:*) expected=no ;; esac
        found=no
        [[ "$result" == *"- $name ["* ]] && found=yes
        if [[ "$found" == "$expected" ]]; then pass=$((pass+1))
        else fail=$((fail+1)); printf 'FAIL threshold=%s memory=%s expected=%s got=%s\n' "$cutoff" "$name" "$expected" "$found"; fi
    done
done
result=$(RELATED_FRESH_S=0 _related_memories 'amber telescope calibration' 'fresh' 10)
if [[ "$result" != *'- fresh ['* && "$result" == *'- old ['* ]]; then pass=$((pass+1))
else fail=$((fail+1)); printf 'FAIL previous-wake exclusion\n'; fi
# Missing, blank and malformed creation dates use the file modification time.
# GNU date accepts an empty date as today, so it must not parse those values.
for field in missing blank invalid; do
    for pair in recent:3600 older:172800; do
        name="fallback-$field-${pair%:*}"; seconds=${pair#*:}
        modified=$(date -u -d "@$((now-seconds))" '+%Y%m%d%H%M.%S' 2>/dev/null) \
            || modified=$(date -u -r "$((now-seconds))" '+%Y%m%d%H%M.%S')
        {
            printf -- '---\nid: %s\ntype: fact\nsummary: amber telescope calibration\n' "$name"
            case "$field" in blank) printf 'created: \n' ;; invalid) printf 'created: not-a-date\n' ;; esac
            printf -- '---\n\namber telescope calibration violet reference.\n'
        } > "$MEM_DIR/$name.md"
        TZ=UTC touch -t "$modified" "$MEM_DIR/$name.md"
    done
done
for cutoff in 86400 0; do
    result=$(RELATED_FRESH_S="$cutoff" _related_memories 'amber telescope calibration' '' 10)
    for field in missing blank invalid; do
        for age in recent older; do
            name="fallback-$field-$age"; expected=yes
            [[ "$cutoff:$age" == 86400:recent ]] && expected=no
            found=no
            [[ "$result" == *"- $name ["* ]] && found=yes
            if [[ "$found" == "$expected" ]]; then pass=$((pass+1))
            else fail=$((fail+1)); printf 'FAIL fallback threshold=%s memory=%s expected=%s got=%s\n' "$cutoff" "$name" "$expected" "$found"; fi
        done
    done
done
# The previous-wake exclusion also applies with the default age filter.
result=$(RELATED_FRESH_S=86400 _related_memories 'amber telescope calibration' 'old' 10)
if [[ "$result" != *'- old ['* && "$result" == *'- weeks ['* ]]; then pass=$((pass+1))
else fail=$((fail+1)); printf 'FAIL previous-wake exclusion with age filter\n'; fi
for invalid in abc 1d -1; do
    result=$(RELATED_FRESH_S="$invalid" _related_memories 'amber telescope calibration' '' 10 2>"$WORK/warning")
    if [[ "$result" != *'- fresh ['* && "$result" == *'- old ['* ]] && grep -q 'using 86400' "$WORK/warning"; then pass=$((pass+1))
    else fail=$((fail+1)); printf 'FAIL invalid threshold=%s\n' "$invalid"; fi
done
result=$(RELATED_FRESH_S=08 _related_memories 'amber telescope calibration' '' 10)
if [[ "$result" == *'- fresh ['* ]]; then pass=$((pass+1))
else fail=$((fail+1)); printf 'FAIL decimal threshold with leading zero\n'; fi

# Match the local timestamp format written by mem, east and west of UTC.
for zone in UTC0 PST8 JST-9; do
    export TZ="$zone"
    for pair in recent:3600 older:10800; do
        name="zoned-${pair%:*}"; seconds=${pair#*:}
        created=$(date -d "@$((now-seconds))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null) \
            || created=$(date -r "$((now-seconds))" '+%Y-%m-%d %H:%M:%S')
        printf -- '---\nid: %s\ntype: fact\nsummary: amber telescope calibration\ncreated: %s\n---\n\namber telescope calibration violet reference.\n' \
            "$name" "$created" > "$MEM_DIR/$name.md"
    done
    result=$(RELATED_FRESH_S=7200 _related_memories 'amber telescope calibration' '' 20)
    if [[ "$result" != *'- zoned-recent ['* && "$result" == *'- zoned-older ['* ]]; then pass=$((pass+1))
    else fail=$((fail+1)); printf 'FAIL local timestamp zone=%s\n' "$zone"; fi
done
printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
