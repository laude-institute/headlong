# deploy/terraform-collab — SSH-reachable boxes for outside collaborators.
#
# Each box runs its own isolated Headlong install (deploy/setup.sh, the same
# provisioning as Audel's box) and is reached over plain key-only SSH by one
# collaborator who gets passwordless sudo. Nothing of Laude's is on the box
# beyond the compute: no Slack tokens, no Cloudflare, no shared identity.
# Nick keeps SSM access through the instance role.
#
# Sibling of deploy/terraform (demo) and deploy/terraform-slack (Audel), not
# a shared module: those stacks carry live instances and a shared template
# would rebuild them. Provisioning deltas from them:
#   - `boxes` is a map, one instance + Elastic IP per entry (for_each).
#   - Port 22 is open (ssh_ingress_cidrs), everything else is closed.
#   - user_data hardens sshd (key only, one AllowUsers login, root closed),
#     creates the collaborator user, enables unattended-upgrades, then runs
#     setup.sh. No tunnel, no CORS pin: the dash stays on 127.0.0.1:8080 and
#     the collaborator port-forwards to it.
#   - ami and user_data are ignore_changes: a newer Ubuntu image or an edited
#     key list must never replace a box someone is working on. Key changes
#     go through `deploy/scripts/collab keys <box>`.

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

locals {
  # Fill in per-box defaults once so the resources below stay simple.
  boxes = {
    for name, b in var.boxes : name => {
      user            = coalesce(b.user, name)
      ssh_public_keys = b.ssh_public_keys
      instance_type   = coalesce(b.instance_type, var.instance_type)
      root_volume_gb  = coalesce(b.root_volume_gb, var.root_volume_gb)
      repo            = coalesce(b.repo, var.shellm_repo)
      branch          = coalesce(b.branch, var.shellm_branch)
      # null = the conventional per-box parameter; "" = no SSM .env at all.
      env_parameter = b.env_parameter == null ? "${var.env_parameter_prefix}/${name}/env" : b.env_parameter
    }
  }
}

# ---------------------------------------------------------------------------
# Shared: image, network, SSH security group, instance role
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

# Port 22 only. Key-only auth is enforced on the box (user_data); narrowing
# ssh_ingress_cidrs is the extra step if a collaborator has a fixed address.
resource "aws_security_group" "collab" {
  name_prefix = "headlong-collab-"
  description = "headlong collaborator boxes: SSH in, everything out"
  vpc_id      = data.aws_vpc.default.id

  dynamic "ingress" {
    for_each = length(var.ssh_ingress_cidrs) > 0 ? [1] : []
    content {
      description = "SSH"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = var.ssh_ingress_cidrs
    }
  }

  dynamic "ingress" {
    for_each = length(var.ssh_ingress_ipv6_cidrs) > 0 ? [1] : []
    content {
      description      = "SSH (IPv6)"
      from_port        = 22
      to_port          = 22
      protocol         = "tcp"
      ipv6_cidr_blocks = var.ssh_ingress_ipv6_cidrs
    }
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name = "headlong-collab"
  }
}

# SSM for Nick's side door, plus read access to the per-box .env parameters
# under env_parameter_prefix. Every box shares the role; a box can read a
# sibling's parameter, which is fine while all boxes belong to one
# collaborator group and each parameter holds only its own spend-capped key.
resource "aws_iam_role" "collab" {
  name_prefix = "headlong-collab-"
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
  role       = aws_iam_role.collab.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "env_parameters" {
  name_prefix = "headlong-collab-env-"
  role        = aws_iam_role.collab.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.env_parameter_prefix}/*"
    }]
  })
}

resource "aws_iam_instance_profile" "collab" {
  name_prefix = "headlong-collab-"
  role        = aws_iam_role.collab.name
}

# ---------------------------------------------------------------------------
# Per box: instance + stable address
# ---------------------------------------------------------------------------

resource "aws_instance" "collab" {
  for_each = local.boxes

  ami                    = data.aws_ami.ubuntu_arm64.id
  instance_type          = each.value.instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.collab.id]
  iam_instance_profile   = aws_iam_instance_profile.collab.name

  root_block_device {
    volume_size = each.value.root_volume_gb
    volume_type = "gp3"
  }

  # IMDSv2 only: a process on the box cannot grab the instance role's
  # credentials with a bare curl.
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  user_data = templatefile("${path.module}/user_data.sh.tpl", {
    box_name        = each.key
    user            = each.value.user
    authorized_keys = join("\n", each.value.ssh_public_keys)
    repo            = each.value.repo
    branch          = each.value.branch
    env_parameter   = each.value.env_parameter
    region          = var.aws_region
  })
  user_data_replace_on_change = false

  lifecycle {
    # A box with a collaborator's work on it is never replaced by a plan.
    # Remove its map entry to destroy it; edit keys with the collab script.
    ignore_changes = [ami, user_data]
  }

  tags = {
    Name         = "headlong-collab-${each.key}"
    Stack        = "terraform-collab"
    Collaborator = each.value.user
  }
}

resource "aws_eip" "collab" {
  for_each = local.boxes

  domain = "vpc"

  tags = {
    Name  = "headlong-collab-${each.key}"
    Stack = "terraform-collab"
  }
}

resource "aws_eip_association" "collab" {
  for_each = local.boxes

  instance_id   = aws_instance.collab[each.key].id
  allocation_id = aws_eip.collab[each.key].id
}
