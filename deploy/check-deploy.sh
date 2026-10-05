#!/usr/bin/env bash
set -uo pipefail

# check-deploy.sh — read-only checks for files installed by deploy/update.sh.
# Usage: check-deploy.sh [--warnings-only|--render-motd] APP_DIR [SHELLM_HOME] [UNIT_DIR]
# Exit 0: required files installed; 1: deployment steps pending; 2: check failed.
# This checks installed files, not the settings of a running dispatcher.

mode="${1:-}"
case "$mode" in
    --warnings-only|--render-motd) shift ;;
    -h|--help) sed -n '4,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) mode="" ;;
esac
APP_DIR="${1:?APP_DIR required}"
SHELLM_HOME="${2:-$(dirname "$APP_DIR")}"
UNIT_DIR="${3:-/etc/systemd/system}"

if [[ "$mode" == --render-motd ]]; then
    # PAM runs this hook as root. The checkout belongs to shellm, so drop
    # privileges before executing it (including its sandbox helper).
    # Paths are shell-quoted, including spaces and shell metacharacters.
    printf '#!/bin/bash\n# Headlong deployment warnings at login. Installed by deploy/update.sh.\n'
    printf 'if [[ -f %q ]]; then\n' "$APP_DIR/deploy/check-deploy.sh"
    printf '    sudo -n -u shellm -- /bin/bash %q --warnings-only %q %q %q || true\n' \
        "$APP_DIR/deploy/check-deploy.sh" "$APP_DIR" "$SHELLM_HOME" "$UNIT_DIR"
    printf 'fi\n'
    exit 0
fi

if [[ ! -d "$APP_DIR" || ! -x "$APP_DIR" || ! -d "$UNIT_DIR" || ! -r "$UNIT_DIR" || ! -x "$UNIT_DIR" ]] \
    || [[ -e "$APP_DIR/.env" && ( ! -f "$APP_DIR/.env" || ! -r "$APP_DIR/.env" ) ]]; then
    echo 'Deploy configuration: could not inspect the checkout, systemd directory or shared .env.'
    exit 2
fi

pending=0
warn() {
    if [[ "$pending" -eq 0 ]]; then echo 'Deploy configuration needs attention:'; fi
    printf '  %s\n' "$1"
    pending=$((pending + 1))
}

# Reuse the same flag parser and environment precedence as the installer.
# Neither it nor this check sources .env or prints credential values.
if ! sandbox=$(bash "$APP_DIR/deploy/thinkers-sandbox.sh" status \
    "$APP_DIR" "$SHELLM_HOME" "$UNIT_DIR" 2>/dev/null); then
    echo 'Deploy configuration: sandbox configuration could not be checked.'
    exit 2
fi
case "$sandbox" in
    'on absent') warn 'Sandbox is enabled, but its systemd configuration is missing.' ;;
    'off present') warn 'Sandbox is disabled, but its systemd configuration is still installed.' ;;
    'on present'|'off absent') ;;
    *) echo 'Deploy configuration: sandbox configuration could not be checked.'; exit 2 ;;
esac

for unit in headlong-thinkers@.service headlong-thinkers-alert@.service; do
    [[ -f "$UNIT_DIR/$unit" ]] || warn "Required systemd unit is missing: $unit."
done
[[ -f "$UNIT_DIR/headlong-thinkers-silence@.service" ]] || warn 'Silence check service is missing.'
[[ -f "$UNIT_DIR/headlong-thinkers-silence@.timer" ]] || warn 'Silence check timer is missing.'

if [[ -f "$APP_DIR/.env" ]]; then
    # Match exactly the assignments split-bridge-env.sh migrates. grep -q
    # reports only their presence; no token value is captured or displayed.
    grep -qE '^[[:space:]]*(SLACK_BOT_TOKEN|SLACK_APP_TOKEN|SLACK_CLI_XOXB|SLACK_CLI_XAPP)=' \
        "$APP_DIR/.env" 2>/dev/null
    rc=$?
    case "$rc" in
        0) warn 'Slack bridge token assignments remain in the shared .env.' ;;
        1) ;;
        *) echo 'Deploy configuration: the shared .env could not be checked.'; exit 2 ;;
    esac
fi

if [[ "$pending" -gt 0 ]]; then
    printf 'Apply the pending deployment steps: sudo bash %q\n' "$APP_DIR/deploy/update.sh"
    exit 1
fi
[[ "$mode" == --warnings-only ]] || echo 'Deploy configuration: required files are installed.'
exit 0
