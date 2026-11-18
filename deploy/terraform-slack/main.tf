# deploy/terraform-slack — dedicated instance for the Slack persona.
#
# Intentional sibling COPY of deploy/terraform (the demo stack), not a shared
# module: modularizing would force state surgery on the live demo instance,
# and a shared user_data template rendering differently would rebuild it
# (user_data_replace_on_change). If you fix something here, fix it there too.
#
# Slack-specific deltas: subdomain/env_parameter values in terraform.tfvars,
# and user_data.sh.tpl installs + restarts the headlong-slack-* units.

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # Pinned to v4: the v5 provider reshapes the tunnel/Access resource
    # schemas. If you upgrade, expect to rewrite those resources.
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.52"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    # Zips the alert Lambda (alerting.tf).
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Auth via CLOUDFLARE_API_TOKEN env var — see README for token permissions.
provider "cloudflare" {}

locals {
  # The public dash name. var.subdomain stays the AWS naming prefix (tunnel,
  # SNS, alarms, lambda, instance tag); only the hostname follows
  # dash_subdomain, so a rename is a Cloudflare-only change.
  hostname      = "${coalesce(var.dash_subdomain, var.subdomain)}.${var.domain}"
  chat_hostname = var.chat_subdomain != "" ? "${var.chat_subdomain}.${var.domain}" : ""
  # Every dash origin the web server should accept (primary + extras).
  dash_origins = join(",", [for h in concat([local.hostname], sort(keys(var.extra_dash_hosts))) : "https://${h}"])
}

# ---------------------------------------------------------------------------
# Cloudflare: tunnel, DNS, Access
# ---------------------------------------------------------------------------

resource "random_id" "tunnel_secret" {
  byte_length = 32
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "shellm" {
  account_id = var.cloudflare_account_id
  name       = "shellm-${var.subdomain}"
  secret     = random_id.tunnel_secret.b64_std
  config_src = "cloudflare"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "shellm" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.shellm.id

  config {
    ingress_rule {
      hostname = local.hostname
      service  = "http://localhost:8080"
    }
    # Phone chat PWA: same app, second hostname with its own Access app.
    dynamic "ingress_rule" {
      for_each = local.chat_hostname != "" ? [1] : []
      content {
        hostname = local.chat_hostname
        service  = "http://localhost:8080"
      }
    }
    # Extra hostnames kept alive beside the primary ones (see variables.tf).
    dynamic "ingress_rule" {
      for_each = sort(concat(keys(var.extra_dash_hosts), keys(var.extra_chat_hosts)))
      content {
        hostname = ingress_rule.value
        service  = "http://localhost:8080"
      }
    }
    # Catch-all required by Cloudflare: anything else gets a 404
    ingress_rule {
      service = "http_status:404"
    }
  }
}

resource "cloudflare_record" "shellm" {
  zone_id = var.cloudflare_zone_id
  name    = coalesce(var.dash_subdomain, var.subdomain)
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.shellm.id}.cfargotunnel.com"
  proxied = true
}

resource "cloudflare_record" "chat" {
  count   = var.chat_subdomain != "" ? 1 : 0
  zone_id = var.cloudflare_zone_id
  name    = var.chat_subdomain
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.shellm.id}.cfargotunnel.com"
  proxied = true
}

# Extra hostnames: records in their own zones, by label.
resource "cloudflare_record" "extra_dash" {
  for_each = var.extra_dash_hosts
  zone_id  = each.value.zone_id
  name     = each.value.name
  type     = "CNAME"
  content  = "${cloudflare_zero_trust_tunnel_cloudflared.shellm.id}.cfargotunnel.com"
  proxied  = true
}

resource "cloudflare_record" "extra_chat" {
  for_each = var.extra_chat_hosts
  zone_id  = each.value.zone_id
  name     = each.value.name
  type     = "CNAME"
  content  = "${cloudflare_zero_trust_tunnel_cloudflared.shellm.id}.cfargotunnel.com"
  proxied  = true
}

# Email OTP login: allow-listed users enter their email and get a 6-digit
# code — no Cloudflare account needed.
#
# DELTA from the demo stack: onetimepin providers are account-level singletons
# (creating a second one errors with access.api.error.conflict), and the demo
# stack already owns ours — so this stack looks it up instead of creating it.
# If the demo stack is ever destroyed, its IdP goes with it and this lookup
# breaks; recreate the IdP (or move ownership here) before that.
data "cloudflare_zero_trust_access_identity_provider" "otp" {
  account_id = var.cloudflare_account_id
  name       = "Email one-time PIN"
}

# Google SSO for whole-domain access (allowed_email_domains). The OAuth
# client is created manually in Google Cloud console — redirect URI
# https://<team>.cloudflareaccess.com/cdn-cgi/access/callback. Any GCP
# project works ("Internal" consent screen adds a Google-side gate;
# "External"/published does not) — either way the email/email_domain
# policy below is the gate that matters. Empty client id = no Google IdP,
# stack stays OTP-only.
resource "cloudflare_zero_trust_access_identity_provider" "google" {
  count      = var.google_oauth_client_id != "" ? 1 : 0
  account_id = var.cloudflare_account_id
  name       = "Google (${local.hostname})"
  type       = "google"

  config {
    client_id     = var.google_oauth_client_id
    client_secret = var.google_oauth_client_secret
  }
}

resource "cloudflare_zero_trust_access_application" "shellm" {
  zone_id          = var.cloudflare_zone_id
  name             = "shellm (${local.hostname})"
  domain           = local.hostname
  type             = "self_hosted"
  session_duration = var.access_session_duration

  # OTP always; Google when configured. With a single IdP, skip the
  # login-method picker entirely; with both, the picker must show.
  allowed_idps = concat(
    [data.cloudflare_zero_trust_access_identity_provider.otp.id],
    cloudflare_zero_trust_access_identity_provider.google[*].id,
  )
  auto_redirect_to_identity = var.google_oauth_client_id == ""
}

resource "cloudflare_zero_trust_access_policy" "allowlist" {
  application_id = cloudflare_zero_trust_access_application.shellm.id
  zone_id        = var.cloudflare_zone_id
  name           = "shellm email allowlist"
  precedence     = 1
  decision       = "allow"

  # One include block with both selectors. With two blocks (emails, then
  # domains) the v4 provider kept only the last one: the live policies held
  # just the domain rule, the explicit emails were re-added on every apply
  # and dropped again, and OTP login for a non-domain address never worked
  # (found 2026-09-15 via the API; the plan had shown the "diff" forever).
  include {
    email        = var.allowed_emails
    email_domain = length(var.allowed_email_domains) > 0 ? var.allowed_email_domains : null
  }
}

# The chat PWA hostname gets its own Access app (own login session and
# cookie) but the same allowlist.
resource "cloudflare_zero_trust_access_application" "chat" {
  count            = var.chat_subdomain != "" ? 1 : 0
  zone_id          = var.cloudflare_zone_id
  name             = "shellm chat (${local.chat_hostname})"
  domain           = local.chat_hostname
  type             = "self_hosted"
  session_duration = var.access_session_duration

  allowed_idps = concat(
    [data.cloudflare_zero_trust_access_identity_provider.otp.id],
    cloudflare_zero_trust_access_identity_provider.google[*].id,
  )
  auto_redirect_to_identity = var.google_oauth_client_id == ""
}

# Chrome's WebAPK minting service (Google-side) fetches the manifest and
# icons without the user's Access cookie; if Access blocks them, Android
# "Install app" silently degrades to a homescreen shortcut. These paths are
# branding bytes only — safe to expose.
resource "cloudflare_zero_trust_access_application" "chat_public_assets" {
  count   = var.chat_subdomain != "" ? 1 : 0
  zone_id = var.cloudflare_zone_id
  name    = "shellm chat public assets (${local.chat_hostname})"
  domain  = "${local.chat_hostname}/manifest.webmanifest"
  self_hosted_domains = [
    "${local.chat_hostname}/manifest.webmanifest",
    "${local.chat_hostname}/icons/",
  ]
  type             = "self_hosted"
  session_duration = var.access_session_duration
}

resource "cloudflare_zero_trust_access_policy" "chat_public_assets_bypass" {
  count          = var.chat_subdomain != "" ? 1 : 0
  application_id = cloudflare_zero_trust_access_application.chat_public_assets[0].id
  zone_id        = var.cloudflare_zone_id
  name           = "public PWA assets"
  precedence     = 1
  decision       = "bypass"

  include {
    everyone = true
  }
}

resource "cloudflare_zero_trust_access_policy" "chat_allowlist" {
  count          = var.chat_subdomain != "" ? 1 : 0
  application_id = cloudflare_zero_trust_access_application.chat[0].id
  zone_id        = var.cloudflare_zone_id
  name           = "shellm chat email allowlist"
  precedence     = 1
  decision       = "allow"

  # One include block with both selectors. With two blocks (emails, then
  # domains) the v4 provider kept only the last one: the live policies held
  # just the domain rule, the explicit emails were re-added on every apply
  # and dropped again, and OTP login for a non-domain address never worked
  # (found 2026-09-15 via the API; the plan had shown the "diff" forever).
  include {
    email        = var.allowed_emails
    email_domain = length(var.allowed_email_domains) > 0 ? var.allowed_email_domains : null
  }
}

# Access for the extra hostnames: the same shape as the primary dash and chat
# apps above, one set per hostname, same allowlist. Kept as separate
# resources (not a for_each over the primaries) so a stack with no extras
# has no state to migrate.
resource "cloudflare_zero_trust_access_application" "extra_dash" {
  for_each         = var.extra_dash_hosts
  zone_id          = each.value.zone_id
  name             = "shellm (${each.key})"
  domain           = each.key
  type             = "self_hosted"
  session_duration = var.access_session_duration

  allowed_idps = concat(
    [data.cloudflare_zero_trust_access_identity_provider.otp.id],
    cloudflare_zero_trust_access_identity_provider.google[*].id,
  )
  auto_redirect_to_identity = var.google_oauth_client_id == ""
}

resource "cloudflare_zero_trust_access_policy" "extra_dash_allowlist" {
  for_each       = var.extra_dash_hosts
  application_id = cloudflare_zero_trust_access_application.extra_dash[each.key].id
  zone_id        = each.value.zone_id
  name           = "shellm email allowlist"
  precedence     = 1
  decision       = "allow"

  # One include block with both selectors. With two blocks (emails, then
  # domains) the v4 provider kept only the last one: the live policies held
  # just the domain rule, the explicit emails were re-added on every apply
  # and dropped again, and OTP login for a non-domain address never worked
  # (found 2026-09-15 via the API; the plan had shown the "diff" forever).
  include {
    email        = var.allowed_emails
    email_domain = length(var.allowed_email_domains) > 0 ? var.allowed_email_domains : null
  }
}

resource "cloudflare_zero_trust_access_application" "extra_chat" {
  for_each         = var.extra_chat_hosts
  zone_id          = each.value.zone_id
  name             = "shellm chat (${each.key})"
  domain           = each.key
  type             = "self_hosted"
  session_duration = var.access_session_duration

  allowed_idps = concat(
    [data.cloudflare_zero_trust_access_identity_provider.otp.id],
    cloudflare_zero_trust_access_identity_provider.google[*].id,
  )
  auto_redirect_to_identity = var.google_oauth_client_id == ""
}

resource "cloudflare_zero_trust_access_application" "extra_chat_public_assets" {
  for_each = var.extra_chat_hosts
  zone_id  = each.value.zone_id
  name     = "shellm chat public assets (${each.key})"
  domain   = "${each.key}/manifest.webmanifest"
  self_hosted_domains = [
    "${each.key}/manifest.webmanifest",
    "${each.key}/icons/",
  ]
  type             = "self_hosted"
  session_duration = var.access_session_duration
}

resource "cloudflare_zero_trust_access_policy" "extra_chat_public_assets_bypass" {
  for_each       = var.extra_chat_hosts
  application_id = cloudflare_zero_trust_access_application.extra_chat_public_assets[each.key].id
  zone_id        = each.value.zone_id
  name           = "public PWA assets"
  precedence     = 1
  decision       = "bypass"

  include {
    everyone = true
  }
}

resource "cloudflare_zero_trust_access_policy" "extra_chat_allowlist" {
  for_each       = var.extra_chat_hosts
  application_id = cloudflare_zero_trust_access_application.extra_chat[each.key].id
  zone_id        = each.value.zone_id
  name           = "shellm chat email allowlist"
  precedence     = 1
  decision       = "allow"

  # One include block with both selectors. With two blocks (emails, then
  # domains) the v4 provider kept only the last one: the live policies held
  # just the domain rule, the explicit emails were re-added on every apply
  # and dropped again, and OTP login for a non-domain address never worked
  # (found 2026-09-15 via the API; the plan had shown the "diff" forever).
  include {
    email        = var.allowed_emails
    email_domain = length(var.allowed_email_domains) > 0 ? var.allowed_email_domains : null
  }
}

# ---------------------------------------------------------------------------
# AWS: one burnable VM, no inbound network path at all
# ---------------------------------------------------------------------------

data "aws_ami" "ubuntu_arm64" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd*/ubuntu-noble-24.04-arm64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Zero ingress rules — the tunnel dials out; admin access is via SSM.
resource "aws_security_group" "shellm" {
  name_prefix = "shellm-"
  description = "shellm agent box: egress only, no inbound"
  vpc_id      = data.aws_vpc.default.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "shellm" {
  name_prefix = "shellm-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.shellm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_caller_identity" "current" {}

# Read-only access to the single parameter holding the .env contents.
resource "aws_iam_role_policy" "env_parameter" {
  count = var.env_parameter != "" ? 1 : 0

  name_prefix = "shellm-env-"
  role        = aws_iam_role.shellm.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.env_parameter}"
    }]
  })
}

resource "aws_iam_instance_profile" "shellm" {
  name_prefix = "shellm-"
  role        = aws_iam_role.shellm.name
}

resource "aws_instance" "shellm" {
  ami                    = data.aws_ami.ubuntu_arm64.id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.shellm.id]
  iam_instance_profile   = aws_iam_instance_profile.shellm.name

  root_block_device {
    volume_size = var.root_volume_gb
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/user_data.sh.tpl", {
    tunnel_token    = cloudflare_zero_trust_tunnel_cloudflared.shellm.tunnel_token
    repo            = var.shellm_repo
    branch          = var.shellm_branch
    hostname        = local.hostname
    allowed_origins = local.dash_origins
    env_parameter   = var.env_parameter
    region          = var.aws_region
  })
  user_data_replace_on_change = true

  # The AMI data source tracks the newest Ubuntu image and user_data carries
  # the hostname and tunnel token, so a plain plan drifted into "must be
  # replaced" on every run and no apply was safe (2026-08-24 followup; it
  # blocked the 2026-09-15 hostname move). A rebuild is an explicit act:
  # deploy/scripts/rebuild passes -replace=aws_instance.shellm, which still
  # replaces the box and renders the current AMI and user_data into the new
  # one. Everything else applies around a running instance.
  # The root volume's headlong-backup tag is owned by aws_ec2_tag.backup
  # (backup.tf). Without the third entry this resource sees that tag as
  # drift and plans to remove it, which would stop the nightly snapshots.
  lifecycle {
    ignore_changes = [ami, user_data, root_block_device[0].tags]
  }

  tags = {
    Name = "shellm-${var.subdomain}"
  }
}
