#!/usr/bin/env bash
# Exercise the actual container-side program without Docker or root.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
awk '
    /-e SHELLM_APT_PACKAGES=/ { armed=1 }
    armed && /bash -c/ { copying=1; next }
    copying && /'\'' >\/dev\/null 2>&1; then/ { exit }
    copying { print }
' "$REPO/bin/shellm" > "$WORK/body"
[[ -s "$WORK/body" ]] || { echo "FAIL: install program not found"; exit 1; }
# Only redirect the sudoers write into the fixture; all commands are mocked.
sed "s|/etc/sudoers.d/shellm|$WORK/sudoers|g" "$WORK/body" > "$WORK/safe-body"
cat > "$WORK/stubs" <<'STUBS'
apt-get() {
    printf '%s\n' "$1" >> "$TRACE"
    case "$SCENARIO:$1" in
        update:update|install:install) return 42 ;;
        missing:*) return 127 ;;
    esac
    return 0
}
getent() { return 0; }
groupadd() { return 0; }
useradd() { return 0; }
chmod() {
    echo chmod >> "$TRACE"
    [[ "$SCENARIO" != chmod ]]
}
STUBS
cat "$WORK/stubs" "$WORK/safe-body" > "$WORK/program"
pass=0 fail=0
for scenario in success update install missing chmod; do
    : > "$WORK/trace"
    rc=0
    SCENARIO="$scenario" TRACE="$WORK/trace" \
        SHELLM_UID=1000 SHELLM_GID=1000 SHELLM_APT_PACKAGES="jq curl" \
        bash "$WORK/program" >/dev/null 2>&1 || rc=$?
    expected=42
    case "$scenario" in success) expected=0 ;; missing) expected=127 ;; chmod) expected=1 ;; esac
    if [[ "$rc" == "$expected" ]]; then
        echo "ok $scenario status $rc"; pass=$((pass+1))
    else
        echo "FAIL $scenario status $rc expected $expected"; fail=$((fail+1))
    fi
    case "$scenario" in
        update|install|missing)
            if grep -q chmod "$WORK/trace"; then
                echo "FAIL $scenario continued to sudo setup"; fail=$((fail+1))
            else
                echo "ok $scenario stops before sudo setup"; pass=$((pass+1))
            fi ;;
    esac
    if [[ "$scenario" == update ]]; then
        if grep -q '^install$' "$WORK/trace"; then
            echo "FAIL update failure continued to install"; fail=$((fail+1))
        else
            echo "ok update failure stops before install"; pass=$((pass+1))
        fi
    fi
done
printf '%s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
