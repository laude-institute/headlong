#!/usr/bin/env bash
# Workspace section find rc 1 arms, fix/workspace-find-rc (2026-10-05).
#
# find returns 1 when it cannot read a subtree, even with stderr
# discarded. Sourced under set -e -o pipefail that killed
# _workspace_section mid-build: a mode-000 fixture under scratch/ took
# the whole section down 3 of 3 trials on the real workdir. Arms 2 and 3
# are born red at fix/workspace-sigpipe a67dc13 and green at this
# branch's tip. They need a non-root user: root reads through mode-000,
# so under root they skip with a printed note.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/thinkers/_lib/common.sh"
PASS=0 FAIL=0
SECTION_OUT=""

run_section() {  # run_section <lib> <dir>; rc = section rc, text in SECTION_OUT
    local lib="$1" dir="$2" rc=0
    SECTION_OUT=""
    SECTION_OUT=$(bash -c 'set -euo pipefail; source "$1"; _workspace_section "$2"' \
        _ "$lib" "$dir" 2>/dev/null) || rc=$?
    return "$rc"
}

control_renders() {
    local tmp rc=0
    tmp=$(mktemp -d) || return 1
    mkdir "$tmp/proj" && printf 'x\n' > "$tmp/proj/a"
    run_section "$LIB" "$tmp" || rc=$?
    rm -rf "$tmp"
    [ "$rc" -eq 0 ] || return 1
    case "$SECTION_OUT" in *proj/*) return 0 ;; esac
    return 1
}

unreadable_subdir_survives() {
    [ "$(id -u)" -ne 0 ] || { echo "  skip: root reads mode-000"; return 0; }
    local tmp rc=0
    tmp=$(mktemp -d) || return 1
    mkdir -p "$tmp/proj/keep" "$tmp/proj/sub"
    printf 'x\n' > "$tmp/proj/keep/a"
    printf 'y\n' > "$tmp/proj/sub/b"
    chmod 000 "$tmp/proj/sub"
    run_section "$LIB" "$tmp" || rc=$?
    chmod 700 "$tmp/proj/sub"
    rm -rf "$tmp"
    [ "$rc" -eq 0 ] || return 1
    case "$SECTION_OUT" in *proj/*) return 0 ;; esac
    return 1
}

unreadable_topdir_listed() {
    [ "$(id -u)" -ne 0 ] || { echo "  skip: root reads mode-000"; return 0; }
    local tmp rc=0
    tmp=$(mktemp -d) || return 1
    mkdir "$tmp/locked" && printf 'z\n' > "$tmp/locked/c"
    chmod 000 "$tmp/locked"
    run_section "$LIB" "$tmp" || rc=$?
    chmod 700 "$tmp/locked"
    rm -rf "$tmp"
    [ "$rc" -eq 0 ] || return 1
    case "$SECTION_OUT" in *locked/*) return 0 ;; esac
    return 1
}

arm() {  # arm <name> <fn>
    local name="$1" fn="$2"
    if "$fn"; then PASS=$((PASS+1)); echo "PASS $name"
    else FAIL=$((FAIL+1)); echo "FAIL $name"; fi
}

arm "control: readable fixture renders with the directory listed" control_renders
arm "unreadable subdirectory does not kill the section" unreadable_subdir_survives
arm "unreadable top-level directory is listed, not fatal" unreadable_topdir_listed
echo "find-rc arms: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
