#!/usr/bin/env bash
# First-boot bootstrap for a collaborator box (rendered by Terraform; runs as
# root via cloud-init). Order matters: the login user exists before sshd is
# told to allow only that user, and the cheap hardening lands before the
# long Headlong install, so an SSM shell during setup already sees the
# final SSH posture. Bash dollar-brace expansions are written with a doubled dollar here because
# Terraform renders this file first.
set -euo pipefail
exec > /var/log/headlong-bootstrap.log 2>&1

echo "==> headlong collab bootstrap starting $(date -u) (box ${box_name}, user ${user})"
export DEBIAN_FRONTEND=noninteractive

# --- hostname ------------------------------------------------------------
hostnamectl set-hostname 'headlong-${box_name}' || true
grep -q 'headlong-${box_name}' /etc/hosts || echo '127.0.1.1 headlong-${box_name}' >> /etc/hosts

# --- login user: keys + passwordless sudo, no password ---------------------
if ! id '${user}' >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash '${user}'
fi
passwd -l '${user}' >/dev/null || true
install -d -m 0700 -o '${user}' -g '${user}' '/home/${user}/.ssh'
cat > '/home/${user}/.ssh/authorized_keys' <<'KEYS'
${authorized_keys}
KEYS
chown '${user}:${user}' '/home/${user}/.ssh/authorized_keys'
chmod 0600 '/home/${user}/.ssh/authorized_keys'
echo '${user} ALL=(ALL) NOPASSWD:ALL' > '/etc/sudoers.d/90-headlong-collab-${user}'
chmod 0440 '/etc/sudoers.d/90-headlong-collab-${user}'
visudo -cf '/etc/sudoers.d/90-headlong-collab-${user}'

# --- sshd: key only, one allowed login, root closed -------------------------
# sshd reads sshd_config.d/*.conf in name order ahead of the main file and
# keeps the FIRST value it sees for each option, so this 00- file wins over
# the image's 60-cloudimg-settings.conf and anything appended later.
cat > /etc/ssh/sshd_config.d/00-headlong-collab.conf <<'CONF'
# Written by terraform-collab user_data. deploy/scripts/collab check audits it.
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin no
AllowUsers ${user}
MaxAuthTries 4
LoginGraceTime 30
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 3
CONF
# Ubuntu 24.04 socket-activates sshd, so its runtime dir may not exist yet
# and `sshd -t` would fail on that alone. The service reads the new file
# when it next starts; reload it only if it is already running.
mkdir -p /run/sshd
/usr/sbin/sshd -t
systemctl try-reload-or-restart ssh
echo "==> sshd hardened; only '${user}' may log in, by key"

# --- unattended security upgrades (no automatic reboot) -------------------
apt-get update -qq
apt-get install -y -qq unattended-upgrades git curl jq
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
CONF
systemctl enable --now unattended-upgrades

# --- MOTD: what the collaborator needs to know at login --------------------
cat > /etc/update-motd.d/60-headlong <<'MOTD'
#!/bin/sh
cat <<'TXT'

Headlong collaborator box (deploy/terraform-collab). You have passwordless sudo.
  repo:     /opt/shellm/app  (owner: shellm; run git as: sudo -u shellm git -C /opt/shellm/app ...)
  dash:     from your laptop  ssh -N -L 8080:127.0.0.1:8080 ${user}@<this host>
            then open http://localhost:8080
  API key:  sudo -u shellm nano /opt/shellm/app/.env   then  sudo systemctl restart headlong-web
  update:   sudo bash /opt/shellm/app/deploy/update.sh
  status:   systemctl status headlong-web 'headlong-thinkers@*'
  docs:     /opt/shellm/app/deploy/DEPLOY.md  /opt/shellm/app/AGENTS.md
  logs:     /var/log/headlong-bootstrap.log (first boot), journalctl -u headlong-web
TXT
if [ -f /var/run/reboot-required ]; then
    echo "*** A reboot is pending (kernel or security update): sudo reboot"
fi
if ! grep -q 'bootstrap done' /var/log/headlong-bootstrap.log 2>/dev/null; then
    echo "*** First-boot setup is still running (or failed): tail -f /var/log/headlong-bootstrap.log"
fi
echo
MOTD
chmod 0755 /etc/update-motd.d/60-headlong

# --- headlong: clone for setup.sh, which does the real provisioning ---------
rm -rf /tmp/shellm-src
git clone --depth 1 --branch '${branch}' '${repo}' /tmp/shellm-src
SHELLM_REPO='${repo}' SHELLM_BRANCH='${branch}' bash /tmp/shellm-src/deploy/setup.sh

%{ if env_parameter != "" ~}
# --- .env from SSM Parameter Store (optional, survives rebuilds) -----------
# Holds the box's root .env (a dedicated, spend-capped LLM key). A missing
# parameter must not kill the bootstrap: the collaborator can add a key by
# hand (the MOTD says how), so warn and continue.
apt-get install -y -qq awscli || snap install aws-cli --classic || true
ENV_CONTENT=$(aws ssm get-parameter --name '${env_parameter}' \
    --with-decryption --region '${region}' \
    --query Parameter.Value --output text 2>/dev/null) || ENV_CONTENT=""
if [ -n "$ENV_CONTENT" ]; then
    printf '%s\n' "$ENV_CONTENT" > /opt/shellm/app/.env
    chown shellm:shellm /opt/shellm/app/.env
    chmod 600 /opt/shellm/app/.env
    unset ENV_CONTENT
    systemctl restart headlong-web
    echo "==> .env installed from SSM parameter ${env_parameter}"
else
    echo "==> WARNING: no value at SSM parameter ${env_parameter}; the collaborator adds a key to /opt/shellm/app/.env"
fi
%{ endif ~}

echo "==> headlong collab bootstrap done $(date -u)"
