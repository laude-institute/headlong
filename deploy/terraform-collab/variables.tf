variable "aws_region" {
  description = "AWS region for the boxes"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "Default EC2 instance type (Graviton/arm64 assumed by the AMI filter); a box entry can override it"
  type        = string
  default     = "t4g.large"
}

variable "root_volume_gb" {
  description = "Default root EBS volume size (gp3); a box entry can override it"
  type        = number
  default     = 40
}

variable "shellm_repo" {
  description = "Default git repo to install; a box entry can point at a collaborator's fork"
  type        = string
  default     = "https://github.com/laude-institute/headlong.git"
}

variable "shellm_branch" {
  description = "Default branch to install; a box entry can override it"
  type        = string
  default     = "main"
}

variable "ssh_ingress_cidrs" {
  description = "IPv4 ranges allowed to reach port 22. Auth is key-only regardless; narrow this when a collaborator has a fixed address. [] closes IPv4 SSH."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ssh_ingress_ipv6_cidrs" {
  description = "IPv6 ranges allowed to reach port 22. [] closes IPv6 SSH."
  type        = list(string)
  default     = ["::/0"]
}

variable "env_parameter_prefix" {
  description = <<-EOT
    SSM parameter namespace for the optional per-box .env. A box named
    <name> reads /<prefix>/<name>/env at first boot if it exists (the
    instance role can read anything under the prefix). Seed one with a
    DEDICATED, SPEND-CAPPED key before apply:
      aws ssm put-parameter --name /headlong-collab/<name>/env \
          --type SecureString --overwrite --region <region> \
          --value "$(printf 'OPENROUTER_API_KEY=sk-or-...\nSHELLM_MODEL=...\n')"
    A missing parameter is a warning in the bootstrap log, not a failure:
    the collaborator can put their own key in /opt/shellm/app/.env.
  EOT
  type        = string
  default     = "/headlong-collab"

  validation {
    condition     = can(regex("^/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$", var.env_parameter_prefix))
    error_message = "env_parameter_prefix must start with / and contain no trailing slash."
  }
}

variable "boxes" {
  description = <<-EOT
    One entry per collaborator box, keyed by a short name (a-z, 0-9, -).
    The name becomes the hostname headlong-<name>, the Name tag, the SSM
    parameter path, and the default login user.
      ssh_public_keys  OpenSSH public keys allowed to log in (required)
      user             login + passwordless-sudo user (default: the name)
      instance_type    default: var.instance_type
      root_volume_gb   default: var.root_volume_gb
      repo, branch     default: var.shellm_repo / var.shellm_branch
      env_parameter    SSM parameter with the box's .env; null = the
                       conventional /<prefix>/<name>/env, "" = none
    Adding an entry creates a box; removing it destroys that box and its
    data. Editing an existing entry's keys does NOT touch the box (see the
    lifecycle block in main.tf); run `deploy/scripts/collab keys <name>`.
  EOT
  type = map(object({
    ssh_public_keys = list(string)
    user            = optional(string)
    instance_type   = optional(string)
    root_volume_gb  = optional(number)
    repo            = optional(string)
    branch          = optional(string)
    env_parameter   = optional(string)
  }))
  default = {}

  validation {
    condition     = alltrue([for name, b in var.boxes : can(regex("^[a-z][a-z0-9-]{0,30}$", name))])
    error_message = "Box names must match ^[a-z][a-z0-9-]{0,30}$ (they become hostnames and unix users)."
  }

  validation {
    condition     = alltrue([for name, b in var.boxes : b.user == null || can(regex("^[a-z_][a-z0-9_-]{0,30}$", coalesce(b.user, "x")))])
    error_message = "A box user must be a plain lowercase unix username."
  }

  validation {
    condition = alltrue([
      for name, b in var.boxes : length(b.ssh_public_keys) > 0 && alltrue([
        for k in b.ssh_public_keys : can(regex("^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp[0-9]+|sk-[a-z0-9@.-]+) [A-Za-z0-9+/=]+", k))
      ])
    ])
    error_message = "Every box needs at least one OpenSSH public key of the form '<type> <base64> [comment]'."
  }
}
