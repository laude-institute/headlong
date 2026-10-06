#!/usr/bin/env bash
# test_thinkers_silence_alert.sh — deploy/thinkers-silence-alert.sh
#
# Usage: tests/test_thinkers_silence_alert.sh
#
# Stubs curl on PATH to capture the Slack payload. A stale trajectory with a
# live dispatcher pid posts one "gone quiet" alert and writes the marker; a
# second tick posts nothing; a fresh trajectory posts the recovery and drops
# the marker; a dead dispatcher pid or a deliberate stop posts nothing. Then
# the 2026-09-17 lessons: the alert re-posts after the repost interval, a
# marker that cannot be written never blocks the post (full disk), and the
# disk check posts at the threshold and recovers below it.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
SCRIPT="$REPO/deploy/thinkers-silence-alert.sh"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

APP="$TMP/app"
ID="$APP/.identities/quiet"
mkdir -p "$ID/trajectories/abcd1234-root" "$ID/run/logs" "$TMP/stub"
printf 'name=quiet\ncreated=test\nroot_trajectory=abcd1234-ffff-0000-0000-000000000000\n' > "$ID/info.txt"
TRAJ="$ID/trajectories/abcd1234-root/trajectory.jsonl"
printf '{"type":"idle"}\n' > "$TRAJ"
printf 'SLACK_BOT_TOKEN=xoxb-test\nHEADLONG_ALERT_CHANNEL=C0TEST\n' > "$APP/.env"
printf 'tick\n' > "$ID/run/logs/dispatcher.log"

# curl stub: record the JSON payload, answer ok
cat > "$TMP/stub/curl" <<'STUB'
#!/usr/bin/env bash
prev=""
for a in "$@"; do [[ "$prev" == "--data" ]] && printf '%s\n' "$a" >> "$CURL_LOG"; prev="$a"; done
echo '{"ok":true}'
STUB
chmod +x "$TMP/stub/curl"
export CURL_LOG="$TMP/curl.log"

run() { PATH="$TMP/stub:$PATH" HEADLONG_SILENCE_SECS=600 HEADLONG_ALERT_FALLBACK_LOG="$TMP/fallback.log" bash "$SCRIPT" "$APP" quiet; }
posts() { if [[ -f "$CURL_LOG" ]]; then wc -l < "$CURL_LOG" | tr -d ' '; else echo 0; fi; }
age_traj() { touch -d "@$(( $(date +%s) - $1 ))" "$TRAJ" 2>/dev/null || touch -t "$(date -r $(( $(date +%s) - $1 )) +%Y%m%d%H%M.%S)" "$TRAJ"; }

# a live "dispatcher": this shell
printf '%s\n' "$$" > "$ID/run/dispatcher.pid"

# 1. stale trajectory → one alert + marker
age_traj 1200
run
if [[ "$(posts)" -eq 1 ]] && grep -q 'has gone quiet' "$CURL_LOG"; then ok "stale trajectory posts the alert"
else bad "stale trajectory posts the alert" "posts=$(posts) $(cat "$CURL_LOG" 2>/dev/null | head -c 200)"; fi
[[ -f "$ID/run/silent_since" ]] && ok "marker written" || bad "marker written"
grep -q 'C0TEST' "$CURL_LOG" && ok "posts to the alert channel" || bad "posts to the alert channel"

# 2. still stale → nothing more
run
[[ "$(posts)" -eq 1 ]] && ok "second tick is silent" || bad "second tick is silent" "posts=$(posts)"

# 3. fresh trajectory → recovery, marker gone
age_traj 10
run
if [[ "$(posts)" -eq 2 ]] && tail -n 1 "$CURL_LOG" | grep -q 'is back'; then ok "fresh trajectory posts the recovery"
else bad "fresh trajectory posts the recovery" "posts=$(posts) $(tail -n 1 "$CURL_LOG" 2>/dev/null | head -c 200)"; fi
[[ -f "$ID/run/silent_since" ]] && bad "marker removed" || ok "marker removed"

# 4. fresh and no marker → nothing
run
[[ "$(posts)" -eq 2 ]] && ok "healthy tick is silent" || bad "healthy tick is silent"

# 5. stale but dispatcher dead → nothing (death alert's job)
age_traj 1200
printf '999999\n' > "$ID/run/dispatcher.pid"
run
[[ "$(posts)" -eq 2 ]] && ok "dead dispatcher is not a silence" || bad "dead dispatcher is not a silence"

# 6. stale, live, but deliberate stop → nothing
printf '%s\n' "$$" > "$ID/run/dispatcher.pid"
touch "$ID/run/deliberate_stop"
run
[[ "$(posts)" -eq 2 ]] && ok "deliberate stop is not a silence" || bad "deliberate stop is not a silence"
rm -f "$ID/run/deliberate_stop"

# 7. no Slack config → fallback log line, no failure
rm -f "$APP/.env" "$ID/run/silent_since"
run; rc=$?
[[ "$rc" -eq 0 && -f "$TMP/fallback.log" ]] && ok "missing config degrades to the fallback log" || bad "missing config degrades to the fallback log" "rc=$rc"

# 8. still stale past the repost interval → posts again, as "still quiet"
printf 'SLACK_BOT_TOKEN=xoxb-test\nHEADLONG_ALERT_CHANNEL=C0TEST\n' > "$APP/.env"
rm -f "$ID/run/silent_since" "$TMP/fallback.log"; : > "$CURL_LOG"
age_traj 1200
run
HEADLONG_SILENCE_REPOST_SECS=0 run
if [[ "$(posts)" -eq 2 ]] && tail -n 1 "$CURL_LOG" | grep -q 'is still quiet'; then ok "re-posts after the repost interval"
else bad "re-posts after the repost interval" "posts=$(posts) $(tail -n 1 "$CURL_LOG" 2>/dev/null | head -c 200)"; fi
run
[[ "$(posts)" -eq 2 ]] && ok "inside the repost interval it is silent" || bad "inside the repost interval it is silent" "posts=$(posts)"

# 9. run/ cannot take a byte (full disk stand-in: read-only dir) → the post
#    still goes out and the marker lands in the tmpfs fallback; recovery
#    finds it there.
rm -f "$ID/run/silent_since"; : > "$CURL_LOG"
mkdir -p "$TMP/shm"
if [[ "$(id -u)" -eq 0 ]]; then
    ok "skip: root can write a read-only dir"
else
    chmod 555 "$ID/run"
    HEADLONG_ALERT_STATE_FALLBACK="$TMP/shm" run
    chmod 755 "$ID/run"
    if [[ "$(posts)" -eq 1 ]] && grep -q 'has gone quiet' "$CURL_LOG"; then ok "unwritable marker does not block the post"
    else bad "unwritable marker does not block the post" "posts=$(posts)"; fi
    [[ -f "$TMP/shm/headlong-alert-quiet/silent_since" ]] && ok "marker falls back to tmpfs" || bad "marker falls back to tmpfs"
    age_traj 10
    HEADLONG_ALERT_STATE_FALLBACK="$TMP/shm" run
    if [[ "$(posts)" -eq 2 ]] && tail -n 1 "$CURL_LOG" | grep -q 'is back'; then ok "recovery finds the fallback marker"
    else bad "recovery finds the fallback marker" "posts=$(posts)"; fi
    [[ -f "$TMP/shm/headlong-alert-quiet/silent_since" ]] && bad "fallback marker removed" || ok "fallback marker removed"
fi

# 10. disk check: a df stub reports the usage; alert at 90, recovery under 85
mkdir -p "$TMP/dfstub"
cat > "$TMP/dfstub/df" <<'STUB'
#!/usr/bin/env bash
pct=$(cat "$DF_PCT")
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/stub 39000000 %s %s %s%% /\n' $(( 390000 * pct )) $(( 390000 * (100 - pct) )) "$pct"
STUB
chmod +x "$TMP/dfstub/df"
export DF_PCT="$TMP/df_pct"
run_df() { PATH="$TMP/dfstub:$TMP/stub:$PATH" HEADLONG_SILENCE_SECS=600 HEADLONG_ALERT_FALLBACK_LOG="$TMP/fallback.log" bash "$SCRIPT" "$APP" quiet; }
age_traj 10; : > "$CURL_LOG"
printf '95' > "$DF_PCT"; run_df
if [[ "$(posts)" -eq 1 ]] && grep -q '95% full' "$CURL_LOG"; then ok "disk over the threshold posts the alert"
else bad "disk over the threshold posts the alert" "posts=$(posts) $(cat "$CURL_LOG" 2>/dev/null | head -c 200)"; fi
[[ -f "$ID/run/disk_alert" ]] && ok "disk marker written" || bad "disk marker written"
run_df
[[ "$(posts)" -eq 1 ]] && ok "disk alert does not repeat inside the interval" || bad "disk alert does not repeat inside the interval" "posts=$(posts)"
printf '88' > "$DF_PCT"; run_df
[[ "$(posts)" -eq 1 ]] && ok "88% is not yet a recovery" || bad "88% is not yet a recovery" "posts=$(posts)"
printf '60' > "$DF_PCT"; run_df
if [[ "$(posts)" -eq 2 ]] && tail -n 1 "$CURL_LOG" | grep -q 'back to 60%'; then ok "disk under the threshold posts the recovery"
else bad "disk under the threshold posts the recovery" "posts=$(posts) $(tail -n 1 "$CURL_LOG" 2>/dev/null | head -c 200)"; fi
[[ -f "$ID/run/disk_alert" ]] && bad "disk marker removed" || ok "disk marker removed"

# 11. permissions: the mind locks its trajectory (dir 700, file 600) → the
#     tick restores group access, posts once, and re-posts only after the
#     interval; a healthy tick drops the marker.
: > "$CURL_LOG"; rm -f "$ID/run/perm_alert" "$ID/run/silent_since" "$ID/run/disk_alert"
printf '60' > "$DF_PCT"; age_traj 10
TDIR=$(dirname "$TRAJ")
chmod 700 "$TDIR"; chmod 600 "$TRAJ"
run_df
dm=$(stat -c %a "$TDIR" 2>/dev/null || stat -f %Lp "$TDIR"); fm=$(stat -c %a "$TRAJ" 2>/dev/null || stat -f %Lp "$TRAJ")
if [[ "$dm" == 750 && "$fm" == 640 ]]; then ok "locked trajectory: group access restored (dir $dm, file $fm)"
else bad "locked trajectory: group access restored" "dir=$dm file=$fm"; fi
if [[ "$(posts)" -eq 1 ]] && grep -q 'unreadable by its bridges' "$CURL_LOG" && grep -q 'directory 700, file 600' "$CURL_LOG"; then ok "locked trajectory posts the alert with the old modes"
else bad "locked trajectory posts the alert with the old modes" "posts=$(posts) $(cat "$CURL_LOG" 2>/dev/null | head -c 300)"; fi
[[ -f "$ID/run/perm_alert" ]] && ok "perm marker written" || bad "perm marker written"
chmod 700 "$TDIR"; chmod 600 "$TRAJ"
run_df
dm=$(stat -c %a "$TDIR" 2>/dev/null || stat -f %Lp "$TDIR")
[[ "$dm" == 750 && "$(posts)" -eq 1 ]] && ok "locked again inside the interval: repaired, no second post" || bad "locked again inside the interval: repaired, no second post" "dir=$dm posts=$(posts)"
chmod 700 "$TDIR"
HEADLONG_SILENCE_REPOST_SECS=0 run_df
[[ "$(posts)" -eq 2 ]] && ok "locked again past the interval: posts again" || bad "locked again past the interval: posts again" "posts=$(posts)"
run_df
[[ "$(posts)" -eq 2 && ! -f "$ID/run/perm_alert" ]] && ok "healthy permissions: silent, marker dropped" || bad "healthy permissions: silent, marker dropped" "posts=$(posts)"
chmod 755 "$TDIR"; chmod 644 "$TRAJ"

# 12. a stale index lock is visible even while the trajectory stays fresh.
: > "$CURL_LOG"
LOCK="$TDIR/messages.jsonl.lock"
mkdir "$LOCK"
age_traj 10
run_df
[[ "$(posts)" -eq 0 ]] && ok "a recent index lock does not alert" || bad "recent index lock"
touch -t 202001010000 "$LOCK"
run_df
if [[ "$(posts)" -eq 1 ]] && grep -q 'chat index lock has been held' "$CURL_LOG" && grep -q 'index-reset --offline' "$CURL_LOG"; then
    ok "an old index lock alerts with offline recovery instructions despite fresh trajectory"
else bad "old index lock alert" "posts=$(posts)"; fi
[[ -d "$LOCK" ]] && ok "watchdog never removes a potentially live lock" || bad "watchdog removed lock"
run_df
[[ "$(posts)" -eq 1 ]] && ok "index alert respects repost interval" || bad "index alert repeats"
HEADLONG_SILENCE_REPOST_SECS=0 run_df
[[ "$(posts)" -eq 2 ]] && ok "index alert reposts after interval" || bad "index alert did not repost"
rmdir "$LOCK"
run_df
[[ "$(posts)" -eq 2 && ! -f "$ID/run/chat_index_alert" ]] && ok "index recovery clears the alert marker" || bad "index recovery marker"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
