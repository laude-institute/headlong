#!/usr/bin/env bash
set -uo pipefail

# deploy/thinkers-silence-alert.sh — "the mind has gone quiet" and "the disk
# is filling" Slack notices for headlong-thinkers@<identity>.service. Run
# every few minutes by headlong-thinkers-silence@<identity>.timer.
#
# The death and failure alerts fire when the dispatcher UNIT dies. This one
# covers the other ways a mind stops:
#
#   - the unit is up, the dispatcher ticks, and nothing happens (2026-09-14:
#     a wedged monolith step left Audel with no trajectory step for six hours
#     while every unit reported active);
#   - the disk fills, so no step, no log line and no marker can be written
#     (2026-09-17: 24 GB of temp copies of the trajectory; the silence check
#     tripped, but this script wrote its marker BEFORE posting, the write
#     failed on the full disk, `set -e` aborted it, and every later tick saw
#     the marker and stayed quiet. Fourteen hours of silence, no alert).
#
# Rules learned from that:
#   1. Post first. State on disk is written after, best effort.
#   2. Never abort. No `set -e`; every write is `|| true`.
#   3. Re-post while the condition lasts (HEADLONG_SILENCE_REPOST_SECS, one
#      hour), so one lost post cannot mute a whole outage.
#   4. Markers fall back to a tmpfs dir when the identity's run/ dir cannot
#      take a byte (HEADLONG_ALERT_STATE_FALLBACK, default /dev/shm).
#
# Silence signal: age of the root trajectory file. Every wake, idle, thought
# and message appends to it, so at rest it is touched at least every
# MONOLITH_BACKOFF_CAP seconds (300 by default). HEADLONG_SILENCE_SECS
# (default 1800) is six times that.
#
#   age >= threshold, no marker (or marker older than the repost interval)
#                               → post the alert, write run/silent_since
#   age <  threshold, marker    → post the recovery, remove the marker
#   dispatcher not running      → say nothing (the death alert owns that)
#
# Disk signal: the fullest of the app dir, the identity dir and /tmp
# (HEADLONG_DISK_ALERT_PCT, default 90). Checked before the dispatcher gate
# because a full disk matters whether or not the mind is up. Recovery posts
# when usage drops five points under the threshold.
#
# Permissions signal: the bridges read the root trajectory as another user
# in the shellm group (the Telegram bridge runs as shellm-telegram; the
# monolith sandbox keeps the mind from touching the bridges' env). The mind
# owns the file and can lock it. 2026-09-22: Harris set its trajectory
# directory to 700 and the file to 600 while scrubbing tokens; the Telegram
# outbound thread died on the next stat and every reply for 19 hours stayed
# in the log while inbound kept working. Every tick: the trajectory
# directory must be group-traversable and the file group-readable, else
# restore them (this unit runs as the owner) and post once an hour while it
# keeps happening. Checked before the dispatcher gate, like the disk.
#
# Missing Slack config degrades to a line in
# /var/tmp/headlong-thinkers-alert.log, never a unit failure.
#
# Usage: thinkers-silence-alert.sh APP_DIR IDENTITY

APP_DIR="${1:?usage: thinkers-silence-alert.sh APP_DIR IDENTITY}"
IDENT="${2:?identity name required}"

FALLBACK_LOG="${HEADLONG_ALERT_FALLBACK_LOG:-/var/tmp/headlong-thinkers-alert.log}"
ID_DIR="$APP_DIR/.identities/$IDENT"
RUN_DIR="$ID_DIR/run"
unit="headlong-thinkers@${IDENT}.service"

if [[ -r "$APP_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$APP_DIR/.env" 2>/dev/null || true
    set +a
fi
if [[ -r "$ID_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$ID_DIR/.env" 2>/dev/null || true
    set +a
fi

THRESHOLD="${HEADLONG_SILENCE_SECS:-1800}"
REPOST="${HEADLONG_SILENCE_REPOST_SECS:-3600}"
DISK_PCT="${HEADLONG_DISK_ALERT_PCT:-90}"
ALERT_CHANNEL="${HEADLONG_ALERT_CHANNEL:-${SLACK_ALERT_CHANNEL:-${SHELLM_ALERT_CHANNEL:-}}}"
# Posting token: HEADLONG_ALERT_TOKEN (seeded by deploy/split-bridge-env.sh;
# ideally a dedicated alert-only app). The bridge's own token is in
# .env.bridge, which this script cannot read inside the thinkers sandbox.
ALERT_TOKEN="${HEADLONG_ALERT_TOKEN:-${SLACK_BOT_TOKEN:-}}"

now=$(date +%s)

log_fallback() {
    printf '%s [thinkers-silence-alert] %s\n' "$(date -u +%FT%TZ)" "$1" >> "$FALLBACK_LOG" 2>/dev/null || true
}

# Never fails, never writes to disk before the network call.
post_slack() {
    local text="$1"
    if [[ -z "$ALERT_TOKEN" || -z "$ALERT_CHANNEL" ]]; then
        log_fallback "$unit: $text; Slack not configured (need HEADLONG_ALERT_TOKEN + HEADLONG_ALERT_CHANNEL in $APP_DIR/.env)"
        return 0
    fi
    local payload resp
    payload=$(jq -nc --arg ch "$ALERT_CHANNEL" --arg text "$text" \
        '{channel: $ch, text: $text}') || return 0
    resp=$(curl -sS -m 15 -X POST https://slack.com/api/chat.postMessage \
        -H "Authorization: Bearer $ALERT_TOKEN" \
        -H "Content-Type: application/json; charset=utf-8" \
        --data "$payload" 2>&1 || true)
    if ! printf '%s' "$resp" | jq -e '.ok == true' >/dev/null 2>&1; then
        log_fallback "Slack post for $unit failed: $resp"
    fi
    return 0
}

# --- marker state ----------------------------------------------------------
# Markers normally live in the identity's run/ dir. When that dir cannot
# take a byte (full disk), they go to a tmpfs dir instead, and both places
# are consulted when looking for one.
STATE_FALLBACK="${HEADLONG_ALERT_STATE_FALLBACK:-/dev/shm}/headlong-alert-$IDENT"
STATE_DIR="$RUN_DIR"
if ! { printf 'x' > "$RUN_DIR/.alert_probe" && [[ -s "$RUN_DIR/.alert_probe" ]]; } 2>/dev/null; then
    mkdir -p "$STATE_FALLBACK" 2>/dev/null || true
    STATE_DIR="$STATE_FALLBACK"
fi
rm -f "$RUN_DIR/.alert_probe" 2>/dev/null || true

mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
# find_marker NAME → path of the existing marker, or nothing
find_marker() {
    local p
    for p in "$RUN_DIR/$1" "$STATE_FALLBACK/$1"; do
        [[ -f "$p" ]] && { printf '%s' "$p"; return 0; }
    done
    return 1
}
# mark NAME VALUE: record the condition (best effort) and stamp the post time
mark() {
    local p="$STATE_DIR/$1"
    printf '%s' "$2" > "$p" 2>/dev/null || true
    touch "$p" 2>/dev/null || true
}
unmark() { rm -f "$RUN_DIR/$1" "$STATE_FALLBACK/$1" 2>/dev/null || true; }
# marker_value NAME → numeric content, or empty
marker_value() {
    local p v
    p=$(find_marker "$1") || return 0
    v=$(cat "$p" 2>/dev/null || true)
    [[ "$v" =~ ^[0-9]+$ ]] && printf '%s' "$v"
    return 0
}
# due NAME → true when no marker exists or the last post is older than REPOST
due() {
    local p
    p=$(find_marker "$1") || return 0
    (( now - $(mtime_of "$p") >= REPOST ))
}
fmt() { printf '%dh%02dm' $(( $1 / 3600 )) $(( ($1 % 3600) / 60 )); }

# --- disk ------------------------------------------------------------------
disk_check() {
    local path pct worst=0 worst_line="" line
    for path in "$APP_DIR" "$ID_DIR" "${TMPDIR:-/tmp}"; do
        [[ -d "$path" ]] || continue
        line=$(df -Pk "$path" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); printf "%s %.1fG/%.1fG %s", $1, $3/1048576, $2/1048576, $5}') || continue
        pct="${line##* }"
        [[ "$pct" =~ ^[0-9]+$ ]] || continue
        if (( pct > worst )); then worst=$pct; worst_line="$line"; fi
    done
    [[ -n "$worst_line" ]] || return 0
    if (( worst >= DISK_PCT )); then
        due disk_alert || return 0
        local tmp_size
        tmp_size=$(du -sh "${TMPDIR:-/tmp}" 2>/dev/null | cut -f1 || true)
        post_slack ":floppy_disk: *disk on ${IDENT}'s box is ${worst}% full* — ${worst_line% *} used. ${TMPDIR:-/tmp} holds ${tmp_size:-?}. At 100% the mind stops writing steps and every alert path with it (2026-09-17). Look for \`mktemp\` copies of the trajectory first: \`sudo find /tmp -maxdepth 1 -size +1G -ls\`."
        mark disk_alert "$worst"
    elif find_marker disk_alert >/dev/null && (( worst < DISK_PCT - 5 )); then
        unmark disk_alert
        post_slack ":broom: *disk on ${IDENT}'s box is back to ${worst}%* — ${worst_line% *} used."
    fi
}
disk_check

# Root trajectory: info.txt names the id; the directory is either the full
# id or <first segment>-root. Fall back to the newest *-root file.
root_id=$(sed -n 's/^root_trajectory=//p' "$ID_DIR/info.txt" 2>/dev/null | head -n 1 || true)
traj=""
for cand in "$ID_DIR/trajectories/$root_id/trajectory.jsonl" \
            "$ID_DIR/trajectories/${root_id%%-*}-root/trajectory.jsonl"; do
    [[ -n "$root_id" && -f "$cand" ]] && { traj="$cand"; break; }
done
if [[ -z "$traj" ]]; then
    traj=$(ls -t "$ID_DIR"/trajectories/*-root/trajectory.jsonl 2>/dev/null | head -n 1 || true)
fi

# --- chat index lock -------------------------------------------------------
# Trajectory activity does not prove that the derived chat indexes advance.
# Alert only: age alone cannot distinguish an abandoned lock from a slow live
# rebuild. Recovery must stop every caller before removing the lock/indexes.
chat_index_check() {
    [[ -n "$traj" && -f "$traj" ]] || return 0
    local lock stamp age
    lock="$(dirname "$traj")/messages.jsonl.lock"
    if [[ ! -d "$lock" ]]; then
        unmark chat_index_alert
        return 0
    fi
    stamp=$(mtime_of "$lock")
    [[ "$stamp" =~ ^[0-9]+$ && "$stamp" -gt 0 ]] || return 0
    age=$(( now - stamp ))
    (( age >= THRESHOLD )) || return 0
    due chat_index_alert || return 0
    post_slack ":warning: *${IDENT}'s chat index lock has been held for $(fmt "$age")*. History, pending requests, and delivery status may be stale even while the trajectory grows. Check for a live rebuild before recovery. Stop all chat callers, run \`chat index-reset --offline\` in this identity's environment, then restart the stopped services. Follow \`docs/chat-index-recovery.md\`; restarting only the thinkers does not clear an abandoned lock."
    mark chat_index_alert "$now"
}
chat_index_check

# --- permissions -----------------------------------------------------------
# mode_of PATH → octal mode (e.g. 755), or empty
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null || true; }
perm_check() {
    [[ -n "$traj" && -f "$traj" ]] || return 0
    local dir dmode fmode dg fg bad=""
    dir=$(dirname "$traj")
    dmode=$(mode_of "$dir"); fmode=$(mode_of "$traj")
    [[ "$dmode" =~ ^[0-7]+$ && "$fmode" =~ ^[0-7]+$ ]] || return 0
    dg=$(( (8#$dmode / 8) % 8 )); fg=$(( (8#$fmode / 8) % 8 ))
    (( (dg & 5) == 5 )) || bad="directory $dmode"
    (( (fg & 4) == 4 )) || bad="${bad:+$bad, }file $fmode"
    if [[ -z "$bad" ]]; then
        unmark perm_alert
        return 0
    fi
    # Repair first (the owner can), then say so. g+X on the directory, g+r
    # on the file: exactly what a group reader needs, nothing wider.
    chmod g+rX "$dir" 2>/dev/null || true
    chmod g+r "$traj" 2>/dev/null || true
    local fixed
    fixed="restored to $(mode_of "$dir")/$(mode_of "$traj")"
    due perm_alert || return 0
    post_slack ":lock: *${IDENT}'s trajectory was unreadable by its bridges* — ${bad} (${fixed}). The Telegram bridge reads the mind log as another user in the shellm group; with group access gone its outbound thread stops and every reply stays in the log while inbound keeps working (2026-09-22, Harris, 19 h). Restored by the silence check; if it keeps happening the mind is chmod-ing its own trajectory dir."
    mark perm_alert "$now"
}
perm_check

# --- silence ---------------------------------------------------------------
# Only judge a mind that is supposed to be awake. A dead or stopped
# dispatcher is the death alert's business, and a stop marker means an
# operator did it on purpose.
dpid=$(cat "$RUN_DIR/dispatcher.pid" 2>/dev/null || true)
if [[ ! "$dpid" =~ ^[0-9]+$ ]] || ! kill -0 "$dpid" 2>/dev/null; then
    exit 0
fi
[[ -f "$RUN_DIR/deliberate_stop" ]] && exit 0

[[ -n "$traj" && -f "$traj" ]] || exit 0

mtime=$(mtime_of "$traj")
[[ "$mtime" -gt 0 ]] || mtime=$now
age=$(( now - mtime ))

if (( age >= THRESHOLD )); then
    due silent_since || exit 0
    if find_marker silent_since >/dev/null; then headline="*${IDENT} is still quiet*"; else headline="*${IDENT} has gone quiet*"; fi
    last_ts=$(date -u -d "@$mtime" +%FT%TZ 2>/dev/null || date -u -r "$mtime" +%FT%TZ 2>/dev/null || echo "$mtime")
    log_tail=$(tail -n 4 "$RUN_DIR/logs/dispatcher.log" 2>/dev/null | cut -c1-200 || true)
    steps=$(cat "$RUN_DIR/step_pids" 2>/dev/null | tr '\n' ' ' || true)
    post_slack ":zzz: ${headline} — no trajectory step for $(fmt "$age") (last at ${last_ts}) while ${unit} is up. The wake loop is stuck, not dead: check for a step that never exited (\`run/step_pids\`: ${steps:-none}), a dispatcher with nothing to fire, or a full disk.
\`\`\`
${log_tail}
\`\`\`"
    mark silent_since "$mtime"
else
    find_marker silent_since >/dev/null || exit 0
    since=$(marker_value silent_since)
    unmark silent_since
    if [[ -n "$since" ]] && (( mtime > since )); then
        post_slack ":sunrise: *${IDENT} is back* — quiet for $(fmt $(( mtime - since ))), steps are landing again."
    else
        post_slack ":sunrise: *${IDENT} is back* — steps are landing again."
    fi
fi
exit 0
