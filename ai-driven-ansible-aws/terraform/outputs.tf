output "control_public_ip" {
  description = "Public IP (EIP) of the control/services node."
  value       = aws_eip.control.public_ip
}

output "control_private_ip" {
  description = "Private IP of the control node (used by Filebeat -> Kafka)."
  value       = aws_instance.control.private_ip
}

output "target_public_ip" {
  description = "Public IP (EIP) of the RHEL target/webserver node."
  value       = aws_eip.target.public_ip
}

output "target_private_ip" {
  description = "Private IP of the target node."
  value       = aws_instance.target.private_ip
}

output "ssh_user" {
  description = "Default SSH user for Red Hat RHEL AMIs."
  value       = "ec2-user"
}

output "aap_url" {
  description = "Ansible Automation Platform UI."
  value       = "https://${aws_eip.control.public_ip}"
}

output "gitea_url" {
  description = "Gitea UI."
  value       = "https://${aws_eip.control.public_ip}:488"
}

output "mattermost_url" {
  description = "Mattermost UI."
  value       = "http://${aws_eip.control.public_ip}:8065"
}

output "webserver_url" {
  description = "The httpd webserver that fails and self-heals."
  value       = "http://${aws_eip.target.public_ip}"
}

output "kms_key_arn" {
  description = "Customer-managed CMK used to encrypt EBS volumes."
  value       = aws_kms_key.ebs.arn
}
