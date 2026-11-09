#!/usr/bin/env bash
# Dots in queries are literal, including file names, versions and ellipses.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export MEM_DIR="$WORK/mem"
mkdir -p "$MEM_DIR"
cd "$WORK"

printf '%s\n' 'The endpoint is api.example.com and its version is v1.2.3 ...' > "$MEM_DIR/exact.md"
printf '%s\n' 'Unrelated names apixexampleycom and v1x2x3' > "$MEM_DIR/other.md"

check_only() {
    local query="$1" result
    result=$("$REPO/bin/mem" prefilter "$query")
    if [[ "$result" != "$MEM_DIR/exact.md" ]]; then
        printf 'FAIL literal query %s: %s\n' "$query" "$result" >&2
        exit 1
    fi
    printf 'ok   literal query %s\n' "$query"
}

check_only 'api.example.com'
check_only 'v1.2.3'
check_only '...'
