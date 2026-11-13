#!/usr/bin/env bash
# Offline real mem prefilter + common.sh; copy into upstream tests/.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" HEADLONG_HOME="$WORK/home" MEM_DIR="$WORK/mem"
export PATH="$REPO/bin:$PATH"
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
printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
