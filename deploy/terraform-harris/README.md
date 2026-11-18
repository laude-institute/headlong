# terraform-harris

Dedicated instance for the second persona, `harris`, at
`https://harris.headlong.ai` (dash) and `https://harris-chat.headlong.ai`
(phone chat). Every `.tf` file, the user data template, the alert Lambda,
and the examples are symlinks into [`../terraform-slack`](../terraform-slack/README.md),
so the two personas run the same stack code with separate state, separate
variables, and separate credentials. Fix a bug once, in terraform-slack, and
both stacks get it on their next apply.

What differs from the Audel stack is all in the gitignored `terraform.tfvars`:

- `domain = "headlong.ai"` and `cloudflare_zone_id` for that zone.
- `subdomain = "harris"`, `chat_subdomain = "harris-chat"`.
- `env_parameter = "/shellm-harris/env"`, seeded before the first apply with
  Harris's own OpenRouter key, its own Slack bot and app tokens, and
  `SHELLM_SLACK_IDENTITY=harris`.

Harris has its own Slack app (`slack/manifest.harris.json`), its own
Telegram bot, and its own LLM key, so a runaway on one persona cannot spend
the other's budget or post as the other's bot.

State is in S3 under its own key (`backend.tf` here is a real file, not a
link). On a laptop that did not create this stack, fetch the operator
files with `SHELLM_TF_STACK=terraform-harris deploy/scripts/stack-config
pull` and run `terraform init`; see "State and operator files" in
`deploy/terraform/README.md`.

Before the first apply:

```bash
cp ../terraform-slack/.envrc .envrc && direnv allow     # same Cloudflare + AWS creds
cp terraform.tfvars.example terraform.tfvars            # then edit as above
aws ssm put-parameter --region ap-southeast-2 --name /shellm-harris/env \
    --type SecureString --value "$(cat ~/.env.harris)" --overwrite
terraform init && terraform plan                        # expect adds only, no destroys
```

The email one-time PIN identity provider is looked up, not created, so a
third stack does not hit Cloudflare's one-per-account limit. The Google
OAuth client is shared: its redirect URI is per Cloudflare team, not per
hostname.

Day-2 via the shared scripts: `SHELLM_TF_STACK=terraform-harris
deploy/scripts/status` (likewise `update` / `run` / `telegram-env` /
`env-push`). The env-push default file for this stack is `~/.env.harris`.
The Cloudflare API token must cover the headlong.ai zone as well as
shellm.net.
