# Deploying headlong-web behind Cloudflare Zero Trust

Goal: a private URL (e.g. `https://agents.example.com`) where allow-listed
people can watch, start/stop, and chat with identities. Architecture:

```
boss's browser ── Cloudflare Access (SSO / email OTP)
                        │
                  Cloudflare Tunnel (outbound-only from the VM)
                        │
                 127.0.0.1:8080  headlong-web (systemd)
                        │ spawns
                 dispatchers + thinkers (own sessions, survive restarts)
```

No inbound ports are ever opened on the VM. Auth lives entirely in
Cloudflare Access; the app itself stays auth-free.

## 0. Prerequisites

- A domain on Cloudflare and access to the Zero Trust dashboard (free tier
  covers this seat count).
- A small Ubuntu 22.04/24.04 VM (EC2 t4g.small / Lightsail / etc.).
  **Treat it as burnable** — the agent executes arbitrary bash on it. Run
  nothing else there.
- A **dedicated, spend-capped** Anthropic API key. A runaway thinker loop
  is a token furnace; the cap is your real safety net.

## 1. Provision the app

```bash
git clone https://github.com/laude-institute/headlong.git
sudo bash headlong/deploy/setup.sh          # or run from your checkout
```

The script creates a `shellm` system user, clones the repo to
`/opt/shellm/app`, installs uv + bun, prebuilds the viewer, and starts the
`headlong-web` systemd service on `127.0.0.1:8080`. Pass `SHELLM_REPO` /
`SHELLM_BRANCH` env vars to deploy a fork or feature branch.

Then add the API key:

```bash
sudo -u shellm nano /opt/shellm/app/.env    # set ANTHROPIC_API_KEY=...
sudo systemctl restart headlong-web
curl -s localhost:8080/api/health           # {"status":"ok"}
```

## 2. Cloudflare Tunnel

In the Zero Trust dashboard: **Networks → Tunnels → Create a tunnel**
(Cloudflared connector). Copy the install command it shows and run it on
the VM — it installs `cloudflared` and a systemd service in one step:

```bash
curl -L https://pkg.cloudflare.com/cloudflared-stable-linux-amd64.deb -o cloudflared.deb
sudo dpkg -i cloudflared.deb              # (arm64 build for t4g instances)
sudo cloudflared service install <TOKEN-FROM-DASHBOARD>
```

In the tunnel's **Public Hostname** tab, add:

- Subdomain/domain: `agents.example.com`
- Service: `HTTP://localhost:8080`

Visit the hostname — you should see the viewer (still unprotected; next
step fixes that, so do it immediately).

## 3. Cloudflare Access policy

**Access → Applications → Add an application → Self-hosted**:

- Application domain: `agents.example.com`
- Policy: Action **Allow**, Include → **Emails** → your email + your
  boss's email. (Or an IdP group if you have Google/Okta wired up.)
- Session duration: e.g. 1 week.

That's the whole login system. Anyone not on the list gets Cloudflare's
block page; people on it authenticate once and land in the viewer.

## 4. Lock CORS to the public hostname

Add a systemd drop-in (the main unit file is re-synced from the repo on
every deploy, so don't hand-edit it — drop-ins survive):

```bash
sudo mkdir -p /etc/systemd/system/headlong-web.service.d
sudo tee /etc/systemd/system/headlong-web.service.d/override.conf <<'EOF'
[Service]
Environment="HEADLONG_WEB_ALLOWED_ORIGINS=https://agents.example.com"
EOF
sudo systemctl daemon-reload && sudo systemctl restart headlong-web
```

(Default is `*`, which is fine on a laptop but pointless exposure on a
deployment. Comma-separate multiple origins if you need them. The
terraform deploy writes this drop-in automatically.)

## 5. Operating it

| Task | Command |
|---|---|
| Logs | `journalctl -u headlong-web -f` |
| Restart web server (agents keep running — the unit's `KillMode=process` signals only the server; stopping the service doesn't stop agents either) | `sudo systemctl restart headlong-web` |
| Stop every agent process | `sudo -u shellm /opt/shellm/app/tools/headlong-killall` |
| Update to latest code | see below; or click the navbar build stamp → "Pull latest & restart" (needs `HEADLONG_WEB_SELF_UPDATE=1` in the unit, which the shipped unit sets) |
| View-only mode | add `Environment="HEADLONG_WEB_READONLY=1"` to the override.conf drop-in (see §4) |

**Updating:**

```bash
sudo bash /opt/shellm/app/deploy/update.sh
```

This pulls the code, installs the deployment configuration, rebuilds the
frontend and restarts the web service. Running thinker dispatchers keep
running. The dashboard's "Pull latest & restart" updates the checkout and
web app; run `deploy/update.sh` to apply system configuration changes.

**Upgrading from an older updater:** if the copy of `update.sh` you start
predates its re-exec guard, it keeps running its old steps after pulling
the new copy. It can print `Healthy` while skipping newer steps. Run the
command above a second time once to apply them. Later updates re-exec the
pulled script when it changes.

`Web application is responding` refers to the HTTP health endpoint.
The separate `Deploy configuration` result checks installed thinker unit
files, the sandbox flag against the presence of its systemd configuration,
and whether Slack bridge token assignments remain in the shared `.env`.
Pending steps name the missing configuration and print the update command;
the current updater returns nonzero even if the web app responds. The
operator command `deploy/scripts/update` also checks after an old updater
finishes, using the newly pulled copy.

Check without updating using `deploy/scripts/status` from your laptop, or
on the box:

```bash
sudo bash /opt/shellm/app/deploy/check-deploy.sh /opt/shellm/app
```

The check changes nothing and never sources `.env` or displays token
values. It exits 0 for the checked installed configuration, 1 for pending
steps and 2 when it cannot inspect the configuration. After setup/update,
login also shows pending steps through `/etc/update-motd.d/61-headlong-deploy`.

A deliberately disabled sandbox (`HEADLONG_SANDBOX=0`) with no sandbox
configuration is valid. The check does not prove that a running thinker
has loaded installed settings: sandbox changes take effect after an
explicit `headlong-thinkersctl restart <identity>`. It also does not check
whether silence timers are running, or prove full credential isolation.
Bridge-file isolation depends on sandboxing; the bridge migration initially
copies the bot token into `HEADLONG_ALERT_TOKEN` until an operator replaces
it with a dedicated alert-only token (see `deploy/split-bridge-env.sh`).

**Thinker dispatchers run as per-identity systemd units.** When the dash
(or the Slack bootstrap) starts an identity's thinkers, the dispatcher runs
under `headlong-thinkers@<identity>.service` in its own cgroup, so web-server
restarts and OOM kills cannot orphan or kill a mind. The web control plane
reaches systemd through `/usr/local/bin/headlong-thinkersctl`, a root-owned
wrapper that validates the action and identity name; the sudo rule in
`/etc/sudoers.d/headlong-thinkers` permits only that wrapper. All three pieces
are installed by `setup.sh` and re-synced by `update.sh`. Useful commands:
`systemctl status headlong-thinkers@audel` (who owns which processes),
`journalctl -u headlong-thinkers@audel` (start/stop history). A dispatcher
that dies on its own leaves the unit in a visible `failed` state — the unit
deliberately does not auto-restart it.

**Kill switches, in escalating order:** Kill All button in the UI →
`headlong-killall` on the box → `systemctl stop headlong-web` → stop the VM.

**Moving identities on/off the box:** every identity page has a Config →
Export button (and the home page has Export all / Import) producing a
portable `.shellm.tgz` — secrets (`.env`) and runtime state never leave the
machine. Use it to seed the deployment from a laptop identity, or as the
pre-demo backup. Two caveats:

- Importing an identity installs its thinkers — scripts that run when the
  identity is started. Only import archives you trust.
- Cloudflare's proxy caps request bodies at 100 MB on the free plan. For
  bigger archives, copy the file and use the CLI:

  ```bash
  scp big.shellm.tgz vm:/tmp/ && ssh vm \
      'sudo -u shellm env IDENTITY_DIR=/opt/shellm/app/.identities \
       /opt/shellm/app/tools/identity import /tmp/big.shellm.tgz'
  ```

  Uploads are also capped server-side via `HEADLONG_WEB_MAX_IMPORT_MB`
  (default 512).

## Restoring an identity from a snapshot

The persona boxes (terraform-slack, terraform-harris) snapshot their root
volume every night through Data Lifecycle Manager (`backup.tf`): 14 daily
and 8 weekly snapshots in the box's region, plus encrypted copies in
`backup_copy_region` (default `ap-southeast-1`) kept 7 days and 8 weeks.
The identities live on that volume under `/var/lib/headlong/identities`.
Snapshots are crash consistent; the trajectory is append-only, so at worst
its last line is torn.

Everything below runs from a laptop with AWS SSO and changes nothing on
the live identity. Set `R=ap-southeast-2` and `STACK=shellm-slack` (or
`shellm-harris`).

1. Pick a snapshot:

   ```bash
   aws --region $R ec2 describe-snapshots --owner-ids self \
     --filters Name=tag:headlong-backup,Values=$STACK \
     --query 'sort_by(Snapshots,&StartTime)[].[SnapshotId,StartTime,Tags[?Key==`headlong-backup-schedule`]|[0].Value]' \
     --output table
   ```

   If the home region is gone or its snapshots are, list the copies with
   `--region ap-southeast-1` and bring one back with
   `aws --region $R ec2 copy-snapshot --source-region ap-southeast-1 --source-snapshot-id <snap>`.

2. Make a volume from it in the box's availability zone and attach it as a
   second disk (the box keeps running):

   ```bash
   I=$(terraform -chdir=deploy/terraform-slack output -raw instance_id)   # or read it from deploy/scripts/status
   AZ=$(aws --region $R ec2 describe-instances --instance-ids $I --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' --output text)
   V=$(aws --region $R ec2 create-volume --snapshot-id <snap> --availability-zone $AZ --volume-type gp3 \
         --tag-specifications 'ResourceType=volume,Tags=[{Key=Name,Value=restore-scratch}]' --query VolumeId --output text)
   aws --region $R ec2 wait volume-available --volume-ids $V
   aws --region $R ec2 attach-volume --volume-id $V --instance-id $I --device /dev/sdf
   ```

   The scratch volume has no `headlong-backup` tag, so DLM never snapshots it.

3. Mount it read-only on the box. `noload` skips journal replay, which a
   crash-consistent snapshot would otherwise need, and keeps the disk
   untouched:

   ```bash
   deploy/scripts/run 'lsblk -o NAME,SIZE,MOUNTPOINT; sudo mkdir -p /mnt/restore && sudo mount -o ro,noload /dev/nvme1n1p1 /mnt/restore && ls /mnt/restore/var/lib/headlong/identities'
   ```

   Check the device name in the `lsblk` output first; it is the disk with
   no mountpoint.

4. Copy out what you need, for example
   `sudo cp -a /mnt/restore/var/lib/headlong/identities/audel /opt/shellm/backups/audel-from-<snap>`.
   Putting it back into a live identity is a separate decision: stop the
   dispatcher first (`sudo headlong-thinkersctl stop audel`), because the
   trajectory must never be replaced under a running feeder: the feeder
   follows the file by name and replays a replaced file through the mind
   (the 2026-09-12 replay incident).

5. Clean up. Do this before any reboot: the clone carries the same
   filesystem label as the root disk, and a box that boots with both
   attached can pick the wrong one.

   ```bash
   deploy/scripts/run 'sudo umount /mnt/restore'
   aws --region $R ec2 detach-volume --volume-id $V && aws --region $R ec2 wait volume-available --volume-ids $V
   aws --region $R ec2 delete-volume --volume-id $V
   ```

If the whole box is gone, the same volume can be attached to any instance
in that zone, or the snapshot registered as the root of a fresh one.

## Migrating a pre-rename box (one time)

> Doing a *different* structural migration on a live box? Read
> `deploy/MIGRATIONS.md` first — it is the general playbook this section
> is one instance of.

Boxes provisioned before the headlong rename run `shellm-*` systemd units.
`deploy/update.sh` refuses to deploy onto them and points here, because the
cutover stops the identity dispatchers — a mind restart with a drain of up
to three minutes — and update.sh also runs unattended from the dash's
self-update button.

```bash
sudo -u shellm git -C /opt/shellm/app pull --ff-only   # land the code first
sudo bash /opt/shellm/app/deploy/migrate-units.sh --dry-run
sudo bash /opt/shellm/app/deploy/migrate-units.sh
```

It backs up every unit file, the drop-in directory, the sudo wrapper, the
sudoers rule, and the audit rules to `/var/backups/headlong-unit-migration`,
then swaps in the `headlong-*` units and brings the services back in the same
order a reboot would. If anything comes back wrong:

```bash
sudo bash /opt/shellm/app/deploy/migrate-units.sh --rollback
```

Rollback depends on the legacy `shellm-*` console-script aliases in the
pyproject files, so do not remove those until the migration has been stable
for a while.

What deliberately keeps the `shellm` name: the `/opt/shellm` path, the
`shellm` and `shellm-telegram` UNIX users, `~shellm/.shellm`, the
per-identity `.shellm/` subdirectory, the `/shellm-slack/env` SSM
parameter, and the `*.shellm.net` domains. Each is a physical move with its
own migration and none of them need to happen for the unit rename.

## Security notes

- The VM is the sandbox. Dedicated key with a spend cap, nothing else on
  the machine, snapshot before demos if you're nervous.
- `headlong-web` binds `127.0.0.1` and the tunnel is outbound-only, so the
  only path in is through Access. Don't "temporarily" bind `0.0.0.0`.
- Secrets: root key in `/opt/shellm/app/.env` (mode 600); per-identity
  overrides via the Config tab (stored in `<identity>/.env`). The Slack
  bridge tokens are split out to `/opt/shellm/app/.env.bridge`, which
  the mind cannot read (`deploy/split-bridge-env.sh`, run by `update.sh`).
- Every wake runs under a systemd sandbox: filesystem read-only except
  the shellm home, the identity's own directory and the temp dirs. `HEADLONG_SANDBOX=0` in the root `.env` plus `update.sh` and a
  `headlong-thinkersctl restart <identity>` turns it off
  (`deploy/thinkers-sandbox.sh`, see SECURITY.md).
- Optional: install Docker (`apt install docker.io`, add `shellm` to the
  `docker` group) so generated code runs in shellm's Docker sandbox
  instead of directly on the host.

## Quick demo alternative (no VM)

Run the tunnel from any machine you already have (dev box, spare Mac):
create the same dashboard tunnel + Access app, run
`cloudflared service install <TOKEN>` locally, point the public hostname
at `http://localhost:8080`, and start `./tools/headlong-web`. Same URL, same
login, zero infra — it just stops when your laptop sleeps.
