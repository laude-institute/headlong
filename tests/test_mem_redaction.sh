#!/usr/bin/env bash
# Offline write-point tests. All credentials are synthetic and assembled here.
# Re-exec with an empty environment and a private HOME/store, including in CI.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
if [[ "${MEM_REDACTION_TEST_CHILD:-}" != 1 ]]; then
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/mem-redaction.XXXXXX") || exit 1
    trap 'rm -rf "$WORK"' EXIT
    mkdir -p "$WORK/home" "$WORK/tmp"
    env -i HOME="$WORK/home" TMPDIR="$WORK/tmp" PATH="$PATH" \
        SHELLM_ENV=local MEM_REDACTION_TEST_CHILD=1 WORK="$WORK" \
        "$BASH" "$0"
    exit $?
fi
export MEM_DIR="$WORK/mem"
mkdir -p "$MEM_DIR"
cd "$WORK" || exit 1
pass=0 fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
# Source the inspected CLI without its final dispatch. Function calls exercise
# argument parsing without putting even fake secrets/large text in external argv.
sed '$d' "$REPO/bin/mem" > "$WORK/mem-library"
mem() ( source "$WORK/mem-library"; main "$@"; )
body() { sed '1d' "$1" | sed '1,/^---$/d' | sed '1d'; }
repeat() { local i; for ((i=0; i<$2; i++)); do printf '%s' "$1"; done; }

# Test every case through both write paths and both input methods. Check the
# entire body and summary, not only that a redaction marker occurs somewhere.
check_text() {
    local label="$1" input="$2" expected="$3" action mode name id file actual summary rc
    for action in add edit; do
        for mode in stdin argument; do
            rm -f "$MEM_DIR"/*.md
            local args=("$action")
            if [[ "$action" == edit ]]; then
                name=$(mem add --type todo --until 2030-01-01 --schedule 09:00 --tz UTC 'original body') || { bad "$label setup"; continue; }
                id=$(sed -n 's/^id: //p' "$MEM_DIR/$name.md")
                args+=("$id")
            fi
            if [[ "$mode" == argument ]]; then
                name=$(mem "${args[@]}" "$input" </dev/null 2>"$WORK/err"); rc=$?
            else
                name=$(printf '%s' "$input" | mem "${args[@]}" 2>"$WORK/err"); rc=$?
            fi
            local files=("$MEM_DIR"/*.md)
            file="${files[0]}"
            if [[ $rc -ne 0 || ! -f "$file" || ${#files[@]} -ne 1 ]]; then
                bad "$label $action/$mode write"; continue
            fi
            actual=$(body "$file")
            # All these cases start with a nonblank line, valid on both heads.
            # Derive the expected summary the way bin/mem does: a long first
            # line is clipped to 80 and marked with the dropped count plus a
            # route (bake_summary). On a base with no bake_summary (before the
            # marker change) fall back to the plain clip the base produced.
            summary=$(
                # Source inside a subshell: the library sets its own shell
                # options, and set -e at test level would kill the suite.
                { source "$WORK/mem-library"; bake_summary "$expected"; } 2>/dev/null || true
            )
            [[ -n "$summary" ]] || summary=$(printf '%s' "$expected" | sed -n '1p' | cut -c1-80)
            if [[ "$actual" == "$expected" ]] && grep -Fx "summary: $summary" "$file" >/dev/null; then
                ok "$label $action/$mode body and summary"
            else
                bad "$label $action/$mode body and summary"
            fi
            if [[ "$action" == edit ]]; then
                if grep -Fx "id: $id" "$file" >/dev/null && grep -Fx 'until: 2030-01-01' "$file" >/dev/null &&
                   grep -Fx 'schedule: 09:00' "$file" >/dev/null && grep -Fx 'tz: UTC' "$file" >/dev/null; then
                    ok "$label edit/$mode metadata"
                else bad "$label edit/$mode metadata"; fi
            fi
            case "$label" in
                github|env-value)
                    [[ "${file##*/}" == *redacted* && "${file##*/}" != *"$input"* ]] \
                        && ok "$label $action/$mode filename" || bad "$label $action/$mode filename" ;;
            esac
        done
    done
}

check_text ordinary $'Plain text\n\nKeep café and 日本語.' $'Plain text\n\nKeep café and 日本語.'
check_text years 'Supported releases: 2024 2025 2026' 'Supported releases: 2024 2025 2026'
check_text timestamp 'Unix microseconds 1791849600123456' 'Unix microseconds 1791849600123456'
check_text credit-date 'credit 2026-09-05 12:30' 'credit 2026-09-05 12:30'
# This date example never failed originally, but must continue to survive.
check_text visa-dates 'visa 2026-10-01 to 2026-12-31' 'visa 2026-10-01 to 2026-12-31'
card="4$(repeat 1 15)"
# Use the well-known synthetic Amex number, built in pieces.
amex="378282"'246310005'
check_text cards "card $card, $card; 4111 1111 1111 1111 / 4111-1111-1111-1111 / $amex" \
    'card <redacted:card>, <redacted:card>; <redacted:card> / <redacted:card> / <redacted:card>'
check_text card-followed-by-code '4111 1111 1111 1111 123' '<redacted:card> 123'
check_text adjacent-cards '4111 1111 1111 1111 4111 1111 1111 1111' '<redacted:card> <redacted:card>'
check_text card-layouts "4$(repeat 2 12), 4$(repeat 0 17)6, 510510$(repeat 510 2)5100, 2223003122$(repeat 0 2)3222, 6011$(repeat 1 11)7, 35301113333$(repeat 0 5), 3782 822463 10005" \
    '<redacted:card>, <redacted:card>, <redacted:card>, <redacted:card>, <redacted:card>, <redacted:card>, <redacted:card>'
check_text invalid-card 'card 4111 1111 1111 1112' 'card 4111 1111 1111 1112'
check_text long-number "$(repeat 9 19)$card" "$(repeat 9 19)$card"
check_text embedded-number "ref$card and ${card}ref" "ref$card and ${card}ref"
github="ghp_$(repeat a 36)"
check_text github "$github" '<redacted:github-token>'
export LLM_API_KEY='synthetic*literal?[value]'
check_text env-value "$LLM_API_KEY" '<redacted:value>'
unset LLM_API_KEY

# Each existing credential format remains covered; no literal scanner matches.
check_text formats "github_pat_$(repeat a 24), xoxb-$(repeat a 24), sk-$(repeat a 24), hf_$(repeat a 24), AIza$(repeat A 32), AKIA$(repeat A 16)" \
    '<redacted:github-token>, <redacted:slack-token>, <redacted:api-key>, <redacted:hf-token>, <redacted:google-key>, <redacted:aws-key>'
check_text more-formats "sk_live_$(repeat a 20), rk_live_$(repeat a 20), whsec_$(repeat a 20), npm_$(repeat a 24), glpat-$(repeat a 20), dckr_pat-$(repeat a 20), SG.$(repeat a 20).$(repeat b 20), SK$(repeat a 32), key-$(repeat a 24)" \
    '<redacted:stripe-key>, <redacted:stripe-key>, <redacted:stripe-hook>, <redacted:npm-token>, <redacted:gitlab-token>, <redacted:docker-token>, <redacted:sendgrid-key>, <redacted:twilio-key>, <redacted:mailgun-key>'
check_text structured "eyJ$(repeat a 12).$(repeat b 12).$(repeat c 12), https://user:synthetic@host/path, \"auth\": \"$(repeat A 24)\"" \
    '<redacted:jwt>, https://<redacted:basic-auth>@host/path, "auth": "<redacted:docker-auth>"'
check_text yaml $'aws_secret_access_key: synthetic-value\nAWS_secret_access_key = another-value' \
    $'aws_secret_access_key: <redacted:aws-secret>\nAWS_secret_access_key = <redacted:aws-secret>'
# No claim that the original assignment rule matches a quoted JSON key.
check_text json '"aws_secret_access_key": "example"' '"aws_secret_access_key": "example"'

begin='-----BEGIN '; end='-----END '; kind='PRIVATE KEY-----'
pem="$begin$kind"$'\nU1lOVEhFVElD\n'"$end$kind"
check_text pem "before"$'\n'"$pem"$'\n'"after" $'before\n<redacted:private-key>\nafter'
check_text inline-pem "prefix $pem suffix" 'prefix <redacted:private-key> suffix'
check_text single-line-pem "prefix $begin${kind}U1lOVEhFVElD$end$kind suffix" 'prefix <redacted:private-key> suffix'
check_text two-pem "left $pem between $pem right" 'left <redacted:private-key> between <redacted:private-key> right'

reject_write() {
    local label="$1" input="$2" slug="${3:-}" action name rc
    for action in add edit; do
        rm -f "$MEM_DIR"/*.md
        local args=("$action")
        if [[ "$action" == edit ]]; then
            name=$(mem add 'original body') || { bad "$label setup"; continue; }
            cp "$MEM_DIR/$name.md" "$WORK/original"
            args+=("$name")
            [[ -n "$slug" ]] && args+=(--slug "$slug")
        fi
        printf '%s' "$input" | mem "${args[@]}" >"$WORK/out" 2>"$WORK/err"; rc=$?
        if [[ $rc -eq 0 ]]; then bad "$label $action refused"; continue; fi
        if [[ "$action" == edit ]]; then
            cmp -s "$MEM_DIR/$name.md" "$WORK/original" && ok "$label edit unchanged" || bad "$label edit unchanged"
        else
            local files=("$MEM_DIR"/*.md)
            [[ ! -e "${files[0]}" ]] && ok "$label add writes nothing" || bad "$label add writes nothing"
        fi
    done
}
reject_write incomplete "$begin$kind"$'\nU1lOVEhFVElD\nKeep this unrelated sentence.'
reject_write nested "$begin$kind $pem"
reject_write wrong-footer "$begin"'RSA PRIVATE KEY-----'$'\nU1lOVEhFVElD\n'"$end$kind"

rm -f "$MEM_DIR"/*.md
name=$(mem add 'original body')
mem edit "$name" --slug "$github" 'edited body' >"$WORK/out" 2>"$WORK/err"
files=("$MEM_DIR"/*.md)
[[ "${files[0]}" == *redacted-github-token.md ]] && ok 'explicit slug redacted' || bad 'explicit slug redacted'
cp "${files[0]}" "$WORK/original"
name="${files[0]##*/}"; name="${name%.md}"
if mem edit "$name" --slug "$begin$kind" 'must not replace body' >"$WORK/out" 2>"$WORK/err"; then
    bad 'incomplete slug refused'
else
    cmp -s "${files[0]}" "$WORK/original" && ok 'incomplete slug preserves file' || bad 'incomplete slug preserves file'
fi

# Intercept external tools: neither unredacted bodies nor credentials should be
# passed via argv. Function calls and printf below remain shell builtins.
MEM_TEST_CANARY="synthetic-sensitive-$(repeat z 24)"; export MEM_TEST_CANARY
export LLM_API_KEY="$MEM_TEST_CANARY"
mkdir -p "$WORK/tools"
for tool in sed awk tr cut head cat mkdir date od basename mv grep; do
    real=$(command -v "$tool")
    {
        printf '#!/bin/bash\n'
        printf '%s\n' 'for arg; do' \
            '  if [[ "$arg" == *"$MEM_TEST_CANARY"* || ${#arg} -gt 65536 ]]; then' \
            '    printf "unsafe external argv\\n" >> "$WORK/argv-failure"; exit 99' '  fi' 'done'
        printf 'exec %q "$@"\n' "$real"
    } > "$WORK/tools/$tool"
    chmod +x "$WORK/tools/$tool"
done
old_path="$PATH"; export PATH="$WORK/tools:$PATH"
check_text argv "$MEM_TEST_CANARY" '<redacted:value>'
# A body larger than the Linux argv-string limit must travel through stdin.
# Integration also runs the current target multiline summary/performance suite.
large="$(repeat abcdefghij 20000)"
check_text large-body "$large" "$large"
[[ ! -e "$WORK/argv-failure" ]] && ok 'no sensitive or large external argv' || bad 'unsafe external argv'
export PATH="$old_path"
unset LLM_API_KEY MEM_TEST_CANARY

# A failing redaction subprocess must never truncate an existing memory.
# Install after the original library extraction so setup remains available.
mkdir -p "$WORK/failure"
printf '#!/bin/bash\nexit 23\n' > "$WORK/failure/sed"
chmod +x "$WORK/failure/sed"
rm -f "$MEM_DIR"/*.md
name=$(mem add 'original body'); cp "$MEM_DIR/$name.md" "$WORK/original"
if printf '%s' 'replacement body' | PATH="$WORK/failure:$PATH" mem edit "$name" >"$WORK/out" 2>"$WORK/err"; then
    bad 'subprocess failure refused'
else
    cmp -s "$MEM_DIR/$name.md" "$WORK/original" && ok 'subprocess failure preserves file' || bad 'subprocess failure preserves file'
fi
if printf '%s' 'new body' | PATH="$WORK/failure:$PATH" mem add >"$WORK/out" 2>"$WORK/err"; then
    bad 'subprocess failure add refused'
else
    files=("$MEM_DIR"/*.md)
    [[ ${#files[@]} -eq 1 ]] && ok 'subprocess failure add writes nothing' || bad 'subprocess failure add wrote file'
fi
rm -f "$MEM_DIR"/*.md
name=$(printf '%s' "$github" | "$BASH" "$REPO/bin/mem" add 2>"$WORK/err")
if [[ $? -eq 0 && -f "$MEM_DIR/$name.md" ]] && [[ "$(body "$MEM_DIR/$name.md")" == '<redacted:github-token>' ]]; then
    ok 'real CLI stdin add'
    if printf '%s' 'credit 2026-09-05 12:30' | "$BASH" "$REPO/bin/mem" edit "$name" >"$WORK/out" 2>"$WORK/err"; then
        files=("$MEM_DIR"/*.md)
        [[ "$(body "${files[0]}")" == 'credit 2026-09-05 12:30' ]] && ok 'real CLI stdin edit' || bad 'real CLI stdin edit'
    else bad 'real CLI stdin edit'; fi
else bad 'real CLI stdin add'; fi
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
