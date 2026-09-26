#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
for test in "$HERE"/test_*.sh; do bash "$test"; done
