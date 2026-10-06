#!/usr/bin/env bash
set -euo pipefail

# deploy/update.sh — pull the deploy branch, force a frontend rebuild,
# restart the web service. Running agents are untouched (dispatchers live
# in their own sessions).
#
# From your laptop:  eval "$(terraform output -raw update_command)"
# From an SSM session:  sudo bash /opt/shellm/app/deploy/update.sh

APP_DIR="${APP_DIR:-/opt/shellm/app}"
UNIT_DST="${UNIT_DST:-/etc/systemd/system/headlong-web.service}"

echo "==> Pulling latest"
sudo -u shellm git -C "$APP_DIR" pull --ff-only

# The headlong rename moved every unit from shelly-* to headlong-*. That
# cutover restarts the identity dispatchers, so it must never happen as a
# side effect of a routine deploy — least of all from the dash's self-update
# button. Stop here and make an operator run the migration in a supervised
# window. Both prior generations trip this (a never-migrated box would still
# be on shellm-*).
legacy_units=$(ls /etc/systemd/system/{shellm,shelly}-{web,thinkers@,thinkers-alert@,slack-bridge,slack-agent,telegram-bridge}.service 2>/dev/null || true)
if [[ -n "$legacy_units" ]]; then
    echo "==> ERROR: legacy pre-headlong units are still installed:" >&2
    printf '      %s\n' $legacy_units >&2
    echo "    This build expects headlong-* units. Run the one-time migration first:" >&2
    echo "      sudo bash $APP_DIR/deploy/migrate-units.sh" >&2
    echo "    It restarts the dispatchers, so run it when you can watch it." >&2
    exit 1
fi

# Re-sync the systemd unit from the repo so unit changes deploy like code.
# Box-local customization belongs in headlong-web.service.d/override.conf
# (drop-ins survive this); hand-edits to the main unit will be overwritten.
UNIT_SRC="$APP_DIR/deploy/headlong-web.service"
SHELLM_HOME="${SHELLM_HOME:-$(dirname "$APP_DIR")}"
if [[ -f "$UNIT_SRC" ]]; then
    rendered=$(sed "s|@SHELLM_HOME@|$SHELLM_HOME|g" "$UNIT_SRC")
    if ! printf '%s\n' "$rendered" | cmp -s - "$UNIT_DST" 2>/dev/null; then
        echo "==> Unit file changed — re-installing $UNIT_DST"
        printf '%s\n' "$rendered" | sudo tee "$UNIT_DST" >/dev/null
        sudo systemctl daemon-reload
    fi
fi

# Per-identity thinkers: template unit + root wrapper + sudo rule. Synced
# like the web unit so changes deploy as code. The wrapper and sudo rule
# are what let the dash (user shellm) start dispatchers in their own
# cgroup; the sudoers file is only installed if it passes visudo's check,
# because a malformed sudoers file breaks sudo box-wide.
for unit_tpl in headlong-thinkers@ headlong-thinkers-alert@; do
    unit_src="$APP_DIR/deploy/${unit_tpl}.service"
    [[ -f "$unit_src" ]] || continue
    rendered=$(sed "s|@SHELLM_HOME@|$SHELLM_HOME|g" "$unit_src")
    if ! printf '%s\n' "$rendered" | cmp -s - "/etc/systemd/system/${unit_tpl}.service" 2>/dev/null; then
        echo "==> Unit file changed — re-installing ${unit_tpl}"
        printf '%s\n' "$rendered" | sudo tee "/etc/systemd/system/${unit_tpl}.service" >/dev/null
        sudo systemctl daemon-reload
    fi
done
# Single name only — the headlong rename ships no wrapper compat. Legacy
# copies are swept so nothing on the box can still invoke a wrapper that
# targets units which no longer exist.
if [[ -f "$APP_DIR/deploy/headlong-thinkersctl" ]] \
    && ! cmp -s "$APP_DIR/deploy/headlong-thinkersctl" /usr/local/bin/headlong-thinkersctl 2>/dev/null; then
    echo "==> Installing headlong-thinkersctl wrapper"
    sudo install -o root -g root -m 0755 "$APP_DIR/deploy/headlong-thinkersctl" /usr/local/bin/headlong-thinkersctl
fi
sudo rm -f /usr/local/bin/shelly-thinkersctl /usr/local/bin/shellm-thinkersctl
if [[ -f "$APP_DIR/deploy/sudoers-headlong-thinkers" ]] \
    && ! sudo cmp -s "$APP_DIR/deploy/sudoers-headlong-thinkers" /etc/sudoers.d/headlong-thinkers 2>/dev/null; then
    if sudo visudo -cf "$APP_DIR/deploy/sudoers-headlong-thinkers"; then
        echo "==> Installing sudoers rule for headlong-thinkersctl"
        sudo install -o root -g root -m 0440 "$APP_DIR/deploy/sudoers-headlong-thinkers" /etc/sudoers.d/headlong-thinkers
        sudo rm -f /etc/sudoers.d/shelly-thinkers /etc/sudoers.d/shellm-thinkers
    else
        echo "==> ERROR: deploy/sudoers-headlong-thinkers failed the visudo check — skipped" >&2
    fi
fi

# Signal-audit rules (kernel-level kill attribution, see
# deploy/audit-headlong-signals.rules). Existing boxes get auditd via this
# path — setup.sh only runs on fresh provisions.
if [[ -f "$APP_DIR/deploy/audit-headlong-signals.rules" ]] \
    && ! sudo cmp -s "$APP_DIR/deploy/audit-headlong-signals.rules" /etc/audit/rules.d/headlong-signals.rules 2>/dev/null; then
    if ! command -v augenrules >/dev/null 2>&1; then
        echo "==> Installing auditd"
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y auditd >/dev/null
    fi
    echo "==> Audit rules changed — re-installing headlong-signals.rules"
    sudo install -o root -g root -m 0640 "$APP_DIR/deploy/audit-headlong-signals.rules" /etc/audit/rules.d/headlong-signals.rules
    sudo rm -f /etc/audit/rules.d/shelly-signals.rules /etc/audit/rules.d/shellm-signals.rules
    sudo augenrules --load || echo "==> WARN: augenrules --load failed — rules apply after next reboot" >&2
fi

# Optional component: Slack bridge (installed on boxes provisioned with
# SHELLM_INSTALL_SLACK_BRIDGE=1). Re-sync its units + deps and restart the
# bridge; the persona bootstrap (oneshot) is left alone so the running
# dispatcher is untouched.
if [[ -f /etc/systemd/system/headlong-slack-bridge.service ]]; then
    echo "==> Updating Slack bridge"
    for unit in headlong-slack-agent headlong-slack-bridge; do
        unit_src="$APP_DIR/deploy/$unit.service"
        if [[ -f "$unit_src" ]]; then
            rendered=$(sed "s|@SHELLM_HOME@|$SHELLM_HOME|g" "$unit_src")
            if ! printf '%s\n' "$rendered" | cmp -s - "/etc/systemd/system/$unit.service" 2>/dev/null; then
                echo "==> Unit file changed — re-installing $unit"
                printf '%s\n' "$rendered" | sudo tee "/etc/systemd/system/$unit.service" >/dev/null
                sudo systemctl daemon-reload
            fi
        fi
    done
    sudo -u shellm bash -c "export PATH=\"\$HOME/.local/bin:\$PATH\"; cd '$APP_DIR/slack' && uv sync"
    sudo systemctl restart headlong-slack-bridge
fi

# Optional component: Telegram bridge. Enabled post-hoc on a live box by
# writing /etc/shellm/telegram.env (root:root 600 with TELEGRAM_BOT_TOKEN +
# TELEGRAM_ADMIN_ID) — there is no bootstrap flag because user_data must
# never change (instance replacement). See telegram/README.md.
if [[ -f /etc/shellm/telegram.env ]]; then
    echo "==> Updating Telegram bridge"
    sudo chown root:root /etc/shellm/telegram.env
    sudo chmod 600 /etc/shellm/telegram.env
    # Dedicated user: keeps the bot token and the allowlist out of the
    # agent's reach (the agent runs as shellm). Group shellm grants
    # read-only access to the identity's trajectory.
    if ! id -u shellm-telegram >/dev/null 2>&1; then
        sudo useradd --system --no-create-home --shell /usr/sbin/nologin shellm-telegram
    fi
    sudo usermod -aG shellm shellm-telegram
    sudo chmod g+rx "$SHELLM_HOME"
    sudo -u shellm bash -c "export PATH=\"\$HOME/.local/bin:\$PATH\"; cd '$APP_DIR/telegram' && uv sync"
    unit_src="$APP_DIR/deploy/headlong-telegram-bridge.service"
    rendered=$(sed "s|@SHELLM_HOME@|$SHELLM_HOME|g" "$unit_src")
    if ! printf '%s\n' "$rendered" | cmp -s - /etc/systemd/system/headlong-telegram-bridge.service 2>/dev/null; then
        echo "==> Unit file changed — re-installing headlong-telegram-bridge"
        printf '%s\n' "$rendered" | sudo tee /etc/systemd/system/headlong-telegram-bridge.service >/dev/null
        sudo systemctl daemon-reload
    fi
    sudo systemctl enable --now headlong-telegram-bridge >/dev/null 2>&1 || true
    sudo systemctl restart headlong-telegram-bridge
fi

echo "==> Forcing frontend rebuild on restart"
sudo -u shellm rm -rf "$APP_DIR/web/src/headlong_web/static"

echo "==> Restarting headlong-web (rebuild takes ~1-2 min)"
sudo systemctl restart headlong-web

for _ in $(seq 1 36); do
    if curl -fsS localhost:8080/api/health >/dev/null 2>&1; then
        echo "==> Healthy: $(curl -fsS localhost:8080/api/health)"
        echo "==> Now running: $(sudo -u shellm git -C "$APP_DIR" log -1 --oneline)"
        exit 0
    fi
    sleep 5
done

echo "==> ERROR: service not healthy after 3 minutes; check: journalctl -u headlong-web -n 50" >&2
exit 1
