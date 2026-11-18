# Where this stack's Terraform state lives. The state is shared, so any
# operator laptop can plan and apply; the S3 lock file stops two applies
# from running at once. This file is per stack and must not be a symlink:
# the key is what keeps the stacks' states apart.
#
# The bucket is private, versioned, and encrypted. It also holds each
# stack's gitignored operator files; see deploy/scripts/stack-config.
terraform {
  required_version = ">= 1.10"

  backend "s3" {
    bucket       = "laude-headlong-tfstate"
    key          = "stacks/terraform-harris/terraform.tfstate"
    region       = "ap-southeast-2"
    encrypt      = true
    use_lockfile = true
  }
}
