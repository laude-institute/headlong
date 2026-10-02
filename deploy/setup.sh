#!/usr/bin/env bash
set -euo pipefail

# deploy/setup.sh — provision a fresh Ubuntu VM to run headlong-web.
#
# Creates a dedicated `shellm` user, clones the repo to /opt/shellm/app,
# installs uv + bun for that user, prebuilds the viewer frontend, and
# installs + starts the systemd service (listening on 127.0.0.1:8080).
#
# Run as root (or with sudo) on Ubuntu 22.04/24.04:
#   sudo bash deploy/setup.sh
#
# Override defaults via env:
#   SHELLM_REPO=https://github.com/laude-institute/headlong.git
#   SHELLM_BRANCH=main
#   SHELLM_HOME=/opt/shellm
#
# After this script: put your (spend-capped!) API key in
# /opt/shellm/app/.env and set up the Cloudflare tunnel — see DEPLOY.md.

SHELLM_REPO="${SHELLM_REPO:-https://github.com/laude-institute/headlong.git}"
SHELLM_BRANCH="${SHELLM_BRANCH:-main}"
SHELLM_HOME="${SHELLM_HOME:-/opt/shellm}"
SHELLM_USER="shellm"
APP_DIR="$SHELLM_HOME/app"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ "$(id -u)" -eq 0 ]] || { echo "Run as root (sudo bash deploy/setup.sh)" >&2; exit 1; }

echo "==> Installing system packages"
apt-get update -qq
apt-get install -y -qq git jq curl unzip

# Real Node is required for the frontend build: without it, bun shims
# `node` with itself and react-router's build crashes on react-dom's
# bun-specific server entry (renderToPipeableStream missing).
if ! command -v node >/dev/null 2>&1; then
    echo "==> Installing Node.js 22"
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y -qq nodejs
fi

echo "==> Creating service user $SHELLM_USER (home: $SHELLM_HOME)"
if ! id "$SHELLM_USER" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "$SHELLM_HOME" --shell /bin/bash "$SHELLM_USER"
fi

echo "==> Cloning $SHELLM_REPO ($SHELLM_BRANCH) to $APP_DIR"
if [[ -d "$APP_DIR/.git" ]]; then
    sudo -u "$SHELLM_USER" git -C "$APP_DIR" fetch origin "$SHELLM_BRANCH"
    sudo -u "$SHELLM_USER" git -C "$APP_DIR" checkout "$SHELLM_BRANCH"
    sudo -u "$SHELLM_USER" git -C "$APP_DIR" pull --ff-only origin "$SHELLM_BRANCH"
else
    sudo -u "$SHELLM_USER" git clone --branch "$SHELLM_BRANCH" "$SHELLM_REPO" "$APP_DIR"
fi

echo "==> Installing uv and bun for $SHELLM_USER"
sudo -u "$SHELLM_USER" bash -c 'command -v ~/.local/bin/uv >/dev/null 2>&1 || curl -LsSf https://astral.sh/uv/install.sh | sh'
sudo -u "$SHELLM_USER" bash -c 'command -v ~/.bun/bin/bun >/dev/null 2>&1 || curl -fsSL https://bun.sh/install | bash'

echo "==> Prebuilding the viewer frontend"
sudo -u "$SHELLM_USER" bash -c "
    set -euo pipefail
    export PATH=\"\$HOME/.local/bin:\$HOME/.bun/bin:\$PATH\"
    cd '$APP_DIR/web/viewer'
    bun install --frozen-lockfile
    bun run build
    rm -rf '$APP_DIR/web/src/headlong_web/static'
    cp -R build/client '$APP_DIR/web/src/headlong_web/static'
    cd '$APP_DIR/web' && uv sync
"

echo "==> Seeding $APP_DIR/.env (add your API key here)"
if [[ ! -f "$APP_DIR/.env" ]]; then
    sudo -u "$SHELLM_USER" tee "$APP_DIR/.env" >/dev/null <<'ENV'
# Root env sourced by web-launched thinkers (and llm/shellm run from here).
# Use a DEDICATED, SPEND-CAPPED key: the agent executes arbitrary bash.
ANTHROPIC_API_KEY=
# SHELLM_MODEL=claude-opus-4-7
ENV
    chmod 600 "$APP_DIR/.env"
fi

# Identities live outside the checkout (design/runtime_isolation.md, layer
# 0): the runtime tree is the runtime, the minds' state is its own tree, and
# a deploy pull can never touch it. The real directory is bind-mounted at
# the old path inside the checkout, so every tool that says ".identities"
# sees a plain directory (a symlink there tripped the web scan and would
# trip find/tar, 2026-09-15). The mount is in fstab so it survives reboots.
# A box from before this layout has a populated real directory at the old
# path; that is left alone (migration is a deliberate stop, move, mount).
IDENTITIES_DIR="${HEADLONG_IDENTITIES_DIR:-/var/lib/headlong/identities}"
echo "==> Identities root: $IDENTITIES_DIR (mounted at $APP_DIR/.identities)"
mkdir -p "$IDENTITIES_DIR"
chown "$SHELLM_USER:$SHELLM_USER" "$IDENTITIES_DIR"
chmod 755 "$(dirname "$IDENTITIES_DIR")" "$IDENTITIES_DIR"
if [[ -L "$APP_DIR/.identities" ]]; then
    rm -f "$APP_DIR/.identities"
fi
if [[ -d "$APP_DIR/.identities" ]] && ! mountpoint -q "$APP_DIR/.identities" \
    && [[ -n "$(ls -A "$APP_DIR/.identities" 2>/dev/null)" ]]; then
    echo "    note: $APP_DIR/.identities is a populated directory (pre-layer-0 box); not mounting over it"
else
    mkdir -p "$APP_DIR/.identities"
    chown "$SHELLM_USER:$SHELLM_USER" "$APP_DIR/.identities"
    if ! grep -qs "^$IDENTITIES_DIR $APP_DIR/.identities " /etc/fstab; then
        printf '%s %s none bind 0 0\n' "$IDENTITIES_DIR" "$APP_DIR/.identities" >> /etc/fstab
    fi
    mountpoint -q "$APP_DIR/.identities" || mount --bind "$IDENTITIES_DIR" "$APP_DIR/.identities"
fi

echo "==> Installing systemd service"
sed "s|@SHELLM_HOME@|$SHELLM_HOME|g" "$SCRIPT_DIR/headlong-web.service" \
    > /etc/systemd/system/headlong-web.service
systemctl daemon-reload
systemctl enable --now headlong-web

# Per-identity thinker units: the dash starts/stops dispatchers through
# headlong-thinkers@<identity>.service (via the sudo wrapper) so they get
# their own cgroup instead of living inside headlong-web's.
echo "==> Installing per-identity thinkers unit + control wrapper"
for unit_file in headlong-thinkers@.service headlong-thinkers-alert@.service \
                 headlong-thinkers-silence@.service headlong-thinkers-silence@.timer; do
    sed "s|@SHELLM_HOME@|$SHELLM_HOME|g" "$SCRIPT_DIR/${unit_file}" \
        > "/etc/systemd/system/${unit_file}"
done
# Runtime sandbox drop-in for the thinkers template (HEADLONG_SANDBOX in
# .env, default on; see deploy/thinkers-sandbox.sh).
bash "$SCRIPT_DIR/thinkers-sandbox.sh" install "$APP_DIR" "$SHELLM_HOME" >/dev/null
install -o root -g root -m 0755 "$SCRIPT_DIR/headlong-thinkersctl" /usr/local/bin/headlong-thinkersctl
if visudo -cf "$SCRIPT_DIR/sudoers-headlong-thinkers"; then
    install -o root -g root -m 0440 "$SCRIPT_DIR/sudoers-headlong-thinkers" /etc/sudoers.d/headlong-thinkers
else
    echo "ERROR: deploy/sudoers-headlong-thinkers failed the visudo check — not installing" >&2
    exit 1
fi
systemctl daemon-reload

# Keep deployment warnings separate from any existing box login message.
mkdir -p /etc/update-motd.d
bash "$APP_DIR/deploy/check-deploy.sh" --render-motd "$APP_DIR" "$SHELLM_HOME" \
    > /etc/update-motd.d/61-headlong-deploy
chmod 0755 /etc/update-motd.d/61-headlong-deploy

# Signal auditing: kernel-level attribution for process kills (see
# deploy/audit-headlong-signals.rules — added after the 2026-08-12
# unattributed dispatcher death). ausearch -k headlong-sig names the sender.
echo "==> Installing auditd signal rules"
if ! command -v augenrules >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y auditd >/dev/null
fi
install -o root -g root -m 0640 "$SCRIPT_DIR/audit-headlong-signals.rules" \
    /etc/audit/rules.d/headlong-signals.rules
augenrules --load || echo "WARN: augenrules --load failed — audit rules apply after next reboot" >&2

# Optional component: the Slack bridge (persona bootstrap + Socket Mode
# client). Off by default — core deploys are unaffected unless the flag is
# set (the terraform-slack stack sets it in user_data).
if [[ "${SHELLM_INSTALL_SLACK_BRIDGE:-0}" == "1" ]]; then
    echo "==> Installing Slack bridge (SHELLM_INSTALL_SLACK_BRIDGE=1)"
    sudo -u "$SHELLM_USER" bash -c "
        export PATH=\"\$HOME/.local/bin:\$PATH\"
        cd '$APP_DIR/slack' && uv sync
    "
    for unit in headlong-slack-agent headlong-slack-bridge; do
        sed "s|@SHELLM_HOME@|$SHELLM_HOME|g" "$SCRIPT_DIR/$unit.service" \
            > "/etc/systemd/system/$unit.service"
    done
    systemctl daemon-reload
    systemctl enable --now headlong-slack-agent headlong-slack-bridge
fi

echo
echo "Done. headlong-web is running on 127.0.0.1:8080 (not publicly reachable)."
echo
echo "Next steps:"
echo "  1. Add your spend-capped API key to $APP_DIR/.env"
echo "     then: systemctl restart headlong-web"
echo "  2. Set up the Cloudflare tunnel + Access policy — see deploy/DEPLOY.md"
