variable "aws_region" {
  description = "AWS region to deploy the demo into."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Optional named AWS CLI/SSO profile. Leave null to use the default credential chain (AWS_PROFILE / env / SSO cache)."
  type        = string
  default     = null
}

variable "project_name" {
  description = "Short name used for tagging and resource naming."
  type        = string
  default     = "aiops-ansible"
}

variable "environment" {
  description = "Environment tag."
  type        = string
  default     = "demo"
}

variable "extra_tags" {
  description = "Additional tags merged into provider default_tags."
  type        = map(string)
  default     = {}
}

variable "vpc_cidr" {
  description = "CIDR block for the demo VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet."
  type        = string
  default     = "10.20.1.0/24"
}

variable "allowed_ingress_cidrs" {
  description = "CIDRs allowed to reach SSH and the web UIs (typically your workstation's public IP /32). NEVER use 0.0.0.0/0."
  type        = list(string)

  validation {
    condition     = length(var.allowed_ingress_cidrs) > 0
    error_message = "Supply at least one CIDR (e.g. your public IP as x.x.x.x/32). The bootstrap script auto-detects this for you."
  }

  validation {
    condition     = !contains(var.allowed_ingress_cidrs, "0.0.0.0/0")
    error_message = "Refusing to open the environment to 0.0.0.0/0. Scope ingress to your workstation."
  }
}

variable "ssh_public_key" {
  description = "SSH PUBLIC key material (contents of a .pub file). Only the public key is used; the private key never leaves your machine and never enters Terraform state."
  type        = string

  validation {
    condition     = can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-)", var.ssh_public_key))
    error_message = "ssh_public_key must be an OpenSSH public key string (ssh-ed25519 / ssh-rsa / ecdsa-...)."
  }
}

variable "rhel_ami_id" {
  description = "Optional explicit RHEL 9 AMI ID. Leave null to auto-select the newest Red Hat-owned RHEL 9 x86_64 AMI."
  type        = string
  default     = null
}

variable "control_instance_type" {
  description = "Instance type for the control/services node (AAP containerized + Kafka + Gitea + Mattermost). Needs ~32 GiB for a comfortable all-in-one AAP."
  type        = string
  default     = "m6i.2xlarge" # 8 vCPU / 32 GiB
}

variable "target_instance_type" {
  description = "Instance type for the RHEL target/webserver node (httpd + Filebeat)."
  type        = string
  default     = "t3.medium" # 2 vCPU / 4 GiB
}

variable "control_root_volume_gb" {
  description = "Root volume size (GiB) for the control node. AAP images + services need headroom (>= 60)."
  type        = number
  default     = 100
}

variable "target_root_volume_gb" {
  description = "Root volume size (GiB) for the target node."
  type        = number
  default     = 30
}

variable "enable_session_manager" {
  description = "Attach the SSM core policy so you can reach instances via Session Manager without relying on open SSH."
  type        = bool
  default     = true
}
