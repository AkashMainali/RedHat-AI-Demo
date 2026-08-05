#!/usr/bin/env bash
# =============================================================================
# infra_only.sh - provision the AWS infrastructure and nothing else.
#
# Terraform only: VPC, security groups, KMS key, IAM role, both EC2 instances and
# their EIPs. No software is installed and no secrets are prompted for, because
# none are needed - Terraform receives only the region, your ingress CIDR and
# your PUBLIC ssh key.
#
# Use this when you want the boxes up before deciding how to configure them, or
# to converge infrastructure drift without touching the software stack.
#
# Follow with:
#   ./scripts/bootstrap.sh      full configuration (AAP install + demo content)
#   ./scripts/demo_content.sh   demo content only, once AAP is installed
# =============================================================================
set -euo pipefail
umask 077

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

AWS_REGION_ARG="${AWS_REGION:-us-east-1}"
AWS_PROFILE_ARG="${AWS_PROFILE:-}"
SSH_KEY_PATH="${SSH_KEY_PATH:-${HOME}/.ssh/aiops_ansible_demo}"
INGRESS_CIDR="${INGRESS_CIDR:-}"
DEMO_USERNAME="${DEMO_USERNAME:-}"
PLAN_ONLY=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Provisions ONLY the AWS infrastructure. Idempotent: re-running converges rather
than duplicating. No secrets are prompted for.

  --profile NAME        AWS SSO/CLI profile (else default chain / AWS_PROFILE)
  --region NAME         AWS region (default: ${AWS_REGION_ARG})
  --username NAME       Prefix for all resource names (default: prompted)
  --ingress-cidr CIDR   Restrict access to this CIDR (default: your public IP /32)
  --ssh-key PATH        SSH private key to use/create (default: ${SSH_KEY_PATH})
  --plan                Show the Terraform plan and exit without applying
  -h, --help            Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)      AWS_PROFILE_ARG="$2"; shift 2 ;;
    --region)       AWS_REGION_ARG="$2"; shift 2 ;;
    --username)     DEMO_USERNAME="$2"; shift 2 ;;
    --ingress-cidr) INGRESS_CIDR="$2"; shift 2 ;;
    --ssh-key)      SSH_KEY_PATH="$2"; shift 2 ;;
    --plan)         PLAN_ONLY=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

# --- 1. workstation tooling --------------------------------------------------
bash "${SCRIPT_DIR}/preflight.sh"

# --- 2. resource naming ------------------------------------------------------
if [[ -z "${DEMO_USERNAME}" ]]; then
  printf '\n== Resource naming ==\n' >&2
  printf 'Prefix for all resource names (Enter for "aiops-ansible-demo"): ' >&2
  IFS= read -r DEMO_USERNAME
  DEMO_USERNAME="${DEMO_USERNAME:-aiops-ansible-demo}"
fi
log "Resource prefix: ${DEMO_USERNAME}"

# --- 3. AWS ------------------------------------------------------------------
aws_authenticate "${AWS_REGION_ARG}" "${AWS_PROFILE_ARG}"

INGRESS_CIDR="$(detect_ingress_cidr "${INGRESS_CIDR}")"
log "Ingress will be restricted to ${INGRESS_CIDR}."

# --- 4. SSH keypair (private key never leaves this machine) ------------------
ensure_ssh_key "${SSH_KEY_PATH}"
export SSH_KEY_PATH

# --- 5. Terraform ------------------------------------------------------------
tf_export_vars "${AWS_REGION}" "${DEMO_USERNAME}" "${INGRESS_CIDR}" "$(cat "${SSH_KEY_PATH}.pub")"

if [[ "${PLAN_ONLY}" -eq 1 ]]; then
  log "terraform init"
  terraform -chdir="${TF_DIR}" init -input=false
  log "terraform plan (no changes will be applied)"
  terraform -chdir="${TF_DIR}" plan -input=false
  exit 0
fi

tf_apply
read_tf_outputs
print_infra_summary
