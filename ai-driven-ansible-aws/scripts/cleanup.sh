#!/usr/bin/env bash
# =============================================================================
# cleanup.sh — release Red Hat subscriptions, then destroy all AWS resources.
# Uses your active AWS credential chain (SSO / profile / STS). No secrets are
# prompted for or stored.
# =============================================================================
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"
ANSIBLE_DIR="${ROOT_DIR}/ansible"

AWS_REGION_ARG="${AWS_REGION:-us-east-1}"
AWS_PROFILE_ARG="${AWS_PROFILE:-}"
SSH_KEY_PATH="${SSH_KEY_PATH:-${HOME}/.ssh/aiops_ansible_demo}"
AUTO_APPROVE=0
SKIP_UNREGISTER=0
DELETE_KEY=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

  --profile NAME       AWS SSO/CLI profile (else default chain / AWS_PROFILE)
  --region NAME        AWS region (default: ${AWS_REGION_ARG})
  --ssh-key PATH       SSH private key path (default: ${SSH_KEY_PATH})
  --auto-approve       Do not prompt before destroying
  --skip-unregister    Do not attempt RHSM unregister first
  --delete-ssh-key     Also delete the generated SSH keypair
  -h, --help           Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)        AWS_PROFILE_ARG="$2"; shift 2 ;;
    --region)         AWS_REGION_ARG="$2"; shift 2 ;;
    --ssh-key)        SSH_KEY_PATH="$2"; shift 2 ;;
    --auto-approve)   AUTO_APPROVE=1; shift ;;
    --skip-unregister) SKIP_UNREGISTER=1; shift ;;
    --delete-ssh-key) DELETE_KEY=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

[[ -n "${AWS_PROFILE_ARG}" ]] && export AWS_PROFILE="${AWS_PROFILE_ARG}"
export AWS_REGION="${AWS_REGION_ARG}" AWS_DEFAULT_REGION="${AWS_REGION_ARG}"

aws sts get-caller-identity >/dev/null 2>&1 || \
  die "No active AWS credentials. Run: aws sso login${AWS_PROFILE:+ --profile ${AWS_PROFILE}}"

if [[ "${AUTO_APPROVE}" -eq 0 ]]; then
  read -r -p "This will DESTROY all demo resources in ${AWS_REGION}. Type 'destroy' to continue: " ans
  [[ "${ans}" == "destroy" ]] || die "Aborted."
fi

# --- 1. best-effort RHSM unregister so entitlements are freed ---------------
if [[ "${SKIP_UNREGISTER}" -eq 0 && -f "${ANSIBLE_DIR}/inventory.ini" ]]; then
  log "Unregistering nodes from Red Hat Subscription Management (best effort)"
  ( cd "${ANSIBLE_DIR}" && ansible-playbook -i inventory.ini unregister.yml ) || \
    warn "Unregister step failed or nodes already gone; continuing to destroy."
fi

# --- 2. terraform destroy ---------------------------------------------------
# Variables have no defaults, so supply non-secret placeholders that satisfy
# validation. These do not affect destruction (attributes come from state).
export TF_VAR_aws_region="${AWS_REGION}"
[[ -n "${AWS_PROFILE:-}" ]] && export TF_VAR_aws_profile="${AWS_PROFILE}"
export TF_VAR_allowed_ingress_cidrs='["127.0.0.1/32"]'
if [[ -f "${SSH_KEY_PATH}.pub" ]]; then
  TF_VAR_ssh_public_key="$(cat "${SSH_KEY_PATH}.pub")"
else
  TF_VAR_ssh_public_key="ssh-ed25519 AAAAPLACEHOLDERKEYFORDESTROYONLY"
fi
export TF_VAR_ssh_public_key

log "terraform destroy"
destroy_args=(-input=false)
[[ "${AUTO_APPROVE}" -eq 1 ]] && destroy_args+=(-auto-approve)
terraform -chdir="${TF_DIR}" destroy "${destroy_args[@]}"

# --- 3. tidy generated local files ------------------------------------------
rm -f "${ANSIBLE_DIR}/inventory.ini" "${ANSIBLE_DIR}/.known_hosts"
log "Removed generated inventory and known_hosts."

if [[ "${DELETE_KEY}" -eq 1 ]]; then
  rm -f "${SSH_KEY_PATH}" "${SSH_KEY_PATH}.pub"
  log "Deleted SSH keypair ${SSH_KEY_PATH}."
fi

printf '\033[1;32mDONE\033[0m  Teardown complete.\n'
