# terraform-collab

Boxes for outside collaborators who have no Laude AWS access. Each box is
an isolated Headlong install with one login user who has passwordless
sudo, reached over plain key-only SSH. Nothing of Laude's is on a box
beyond the compute: no Slack tokens, no Cloudflare, no shared identity,
no path to Audel's box. Nick keeps a side door through SSM.

It is a sibling of [`../terraform`](../terraform/README.md) (demo) and
[`../terraform-slack`](../terraform-slack/README.md) (Audel), and much
smaller: AWS only, one `boxes` map, one instance and Elastic IP per
entry. Provisioning on the box is the same `deploy/setup.sh` those stacks
use, so the collaborator gets the dash on `127.0.0.1:8080`, the
`headlong-web` and `headlong-thinkers@` units, and `deploy/update.sh`.

## What the first boot does

`user_data.sh.tpl`, in order:

1. Creates the login user with the keys from `terraform.tfvars`, locks its
   password, and gives it `NOPASSWD` sudo.
2. Hardens sshd through `/etc/ssh/sshd_config.d/00-headlong-collab.conf`:
   public key auth only, password and keyboard-interactive off, root login
   off, `AllowUsers <user>` so the stock `ubuntu` account cannot log in,
   `MaxAuthTries 4`, no X11 forwarding.
3. Enables unattended security upgrades with no automatic reboot. A
   pending reboot shows in the MOTD and in `collab check`.
4. Installs a MOTD with the things the collaborator needs (paths, the dash
   port forward, how to add a key, how to update).
5. Clones the repo and runs `deploy/setup.sh`. This is the slow part,
   about five to eight minutes.
6. If the SSM parameter `/headlong-collab/<name>/env` exists, installs it
   as `/opt/shellm/app/.env` and restarts the web unit. A missing
   parameter is a warning, not a failure.

Other posture: the security group opens port 22 only, IMDSv2 is required,
and the instance role is SSM plus read access to parameters under
`/headlong-collab/`.

## Create a box

Prerequisites: terraform, the AWS CLI with a live SSO login (`aws sso
login`), and the collaborator's OpenSSH public key. No Cloudflare token.

```bash
cd deploy/terraform-collab
cp terraform.tfvars.example terraform.tfvars   # gitignored
$EDITOR terraform.tfvars                        # add a boxes entry with their key

# Optional: a spend-capped key for the box. Skip it and they bring their own.
aws ssm put-parameter --name /headlong-collab/<name>/env --type SecureString \
    --overwrite --region ap-southeast-2 \
    --value "$(printf 'OPENROUTER_API_KEY=sk-or-...\nSHELLM_MODEL=...\n')"

terraform init
terraform plan      # expect: adds only; never a destroy of an existing box
terraform apply
```

Then from the repo root:

```bash
deploy/scripts/collab status            # address, state, launch time
deploy/scripts/collab check <name>      # wait for "first boot finished"; every sshd line should be ok
deploy/scripts/collab ssh-config        # stanza to send them
```

The first `check` a few minutes after apply is the acceptance test. It
audits the effective sshd settings on the box, not the file we wrote, so
it also catches a later hand edit.

## Hand it over

Send the collaborator the `ssh-config` stanza and this note, filled in:

> Your box is `headlong-<name>`. Log in with `ssh <user>@<ip>` using the
> key you gave me; you have passwordless sudo and the box is yours to
> break. Headlong is installed at `/opt/shellm/app` and the login message
> lists the day-to-day commands. The dash is not on the internet: run
> `ssh -N -L 8080:127.0.0.1:8080 <user>@<ip>` and open
> `http://localhost:8080`. Put your own API key in `/opt/shellm/app/.env`
> (or I seeded one) and restart with `sudo systemctl restart headlong-web`.
> Please keep it to Headlong work; the box gets security updates on its
> own but you reboot it when the login message asks.

## Day 2

| Task | How |
|---|---|
| See every box | `deploy/scripts/collab status` (`--check` adds the audit) |
| Audit one box | `deploy/scripts/collab check <name>` |
| Add or rotate a key | edit `ssh_public_keys` in tfvars, `terraform apply` (no instance change), `deploy/scripts/collab keys <name>` |
| Run a command as root | `deploy/scripts/collab run <name> '<command>'` |
| Pause a box to save money | `deploy/scripts/collab stop <name>`, later `start` (the address is kept) |
| Narrow who can reach port 22 | set `ssh_ingress_cidrs` in tfvars, `terraform apply` |
| Remove a box | delete its entry from `boxes`, `terraform apply`; the disk and Elastic IP go with it |

The collaborator updates their own box with `sudo bash
/opt/shellm/app/deploy/update.sh` or the dash's "Pull latest & restart".

## Why keys do not flow through terraform after the first boot

`aws_instance` ignores changes to `ami` and `user_data`. Without that, a
newer Ubuntu image or an edited key list would replace the instance and
destroy whatever the collaborator has on it. So the key list in tfvars is
the record, `terraform apply` publishes it to the `boxes` output, and
`collab keys` copies it onto the running box over SSM. Adding a whole new
box still just works, because a new entry renders its own user_data.

## What this stack does not do

- No Cloudflare tunnel or Access. If a collaborator later needs a browser
  dash without a port forward, add the tunnel the way `terraform-slack`
  does; do not open 8080 in the security group.
- No CloudWatch alarms and no Slack alerts. These boxes are not on call.
- No backups. The identity export in the dash (Config, Export) is the way
  to save a mind before a box is removed.
