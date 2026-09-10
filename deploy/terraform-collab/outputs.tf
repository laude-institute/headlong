output "region" {
  description = "Region the boxes live in (read by deploy/scripts/collab)"
  value       = var.aws_region
}

output "security_group_id" {
  description = "The shared SSH security group"
  value       = aws_security_group.collab.id
}

output "boxes" {
  description = "Per-box connection details. Public keys are public; nothing here is secret."
  value = {
    for name, b in local.boxes : name => {
      instance_id         = aws_instance.collab[name].id
      public_ip           = aws_eip.collab[name].public_ip
      user                = b.user
      instance_type       = b.instance_type
      env_parameter       = b.env_parameter
      repo                = b.repo
      branch              = b.branch
      ssh_public_keys     = b.ssh_public_keys
      ssh_command         = "ssh ${b.user}@${aws_eip.collab[name].public_ip}"
      ssm_session_command = "aws ssm start-session --region ${var.aws_region} --target ${aws_instance.collab[name].id}"
    }
  }
}
