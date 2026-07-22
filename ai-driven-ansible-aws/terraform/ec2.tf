resource "aws_key_pair" "this" {
  key_name   = "${local.name_prefix}-key"
  public_key = var.ssh_public_key
  tags       = { Name = "${local.name_prefix}-key" }
}

locals {
  # Minimal, SECRET-FREE cloud-init: ensure python3 is present for Ansible and
  # set a stable hostname. No credentials are ever placed in user_data (which
  # is retrievable from instance metadata and stored in the AWS API).
  control_user_data = <<-EOT
    #cloud-config
    hostname: ${local.name_prefix}-control
    preserve_hostname: false
    runcmd:
      - [ bash, -lc, "command -v python3 >/dev/null 2>&1 || dnf -y install python3 || true" ]
  EOT

  target_user_data = <<-EOT
    #cloud-config
    hostname: ${local.name_prefix}-target
    preserve_hostname: false
    runcmd:
      - [ bash, -lc, "command -v python3 >/dev/null 2>&1 || dnf -y install python3 || true" ]
  EOT
}

resource "aws_instance" "control" {
  ami                    = local.rhel_ami_id
  instance_type          = var.control_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.control.id]
  key_name               = aws_key_pair.this.key_name
  iam_instance_profile   = aws_iam_instance_profile.instance.name
  user_data              = local.control_user_data

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # enforce IMDSv2
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.control_root_volume_gb
    encrypted             = true
    kms_key_id            = aws_kms_key.ebs.arn
    delete_on_termination = true
  }

  tags = {
    Name = "${local.name_prefix}-control"
    Role = "control"
  }
}

resource "aws_instance" "target" {
  ami                    = local.rhel_ami_id
  instance_type          = var.target_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.target.id]
  key_name               = aws_key_pair.this.key_name
  iam_instance_profile   = aws_iam_instance_profile.instance.name
  user_data              = local.target_user_data

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.target_root_volume_gb
    encrypted             = true
    kms_key_id            = aws_kms_key.ebs.arn
    delete_on_termination = true
  }

  tags = {
    Name = "${local.name_prefix}-target"
    Role = "target"
  }
}

resource "aws_eip" "control" {
  domain     = "vpc"
  instance   = aws_instance.control.id
  tags       = { Name = "${local.name_prefix}-control-eip" }
  depends_on = [aws_internet_gateway.this]
}

resource "aws_eip" "target" {
  domain     = "vpc"
  instance   = aws_instance.target.id
  tags       = { Name = "${local.name_prefix}-target-eip" }
  depends_on = [aws_internet_gateway.this]
}
