#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — provision the AWS environment and configure the AI-driven
# Ansible Automation demo.
#
# Security model:
#   * AWS auth uses your ACTIVE credential chain (AWS SSO / named profile / env
#     STS creds). No AWS keys are ever prompted for, printed, or stored.
#   * Red Hat + app secrets are prompted at runtime with hidden input, kept in
#     the process environment only, and read by Ansible via env lookups. They
#     are never written to disk, never echoed, never committed, and never put
#     into Terraform state.
#   * Terraform receives only NON-secret variables (region, ingress CIDR, and
#     your PUBLIC ssh key). State therefore contains no credentials.
# =============================================================================
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"
ANSIBLE_DIR="${ROOT_DIR}/ansible"

# --- defaults / flags -------------------------------------------------------
AWS_REGION_ARG="${AWS_REGION:-us-east-1}"
AWS_PROFILE_ARG="${AWS_PROFILE:-}"
SSH_KEY_PATH="${SSH_KEY_PATH:-${HOME}/.ssh/aiops_ansible_demo}"
INGRESS_CIDR="${INGRESS_CIDR:-}"
AUTO_APPROVE=1  # Default: yes (Terraform is idempotent, safe to auto-approve)
SKIP_ANSIBLE=0
INFRA_ONLY=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

SAFE & IDEMPOTENT: Running this script multiple times will NOT create duplicate servers.
Terraform detects existing resources and skips recreation.

  --profile NAME        AWS SSO/CLI profile to use (else default chain / AWS_PROFILE)
  --region NAME         AWS region (default: ${AWS_REGION_ARG})
  --ingress-cidr CIDR   Restrict access to this CIDR (default: auto-detected /32)
  --ssh-key PATH        SSH private key path to use/create (default: ${SSH_KEY_PATH})
  --auto-approve        Do not prompt for Terraform apply confirmation (default: yes)
  --skip-ansible        Provision infrastructure only (no secret prompts, no config)
  --infra-only          Check: infrastructure exists? Run Ansible only (skip TF)
  -h, --help            Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)      AWS_PROFILE_ARG="$2"; shift 2 ;;
    --region)       AWS_REGION_ARG="$2"; shift 2 ;;
    --ingress-cidr) INGRESS_CIDR="$2"; shift 2 ;;
    --ssh-key)      SSH_KEY_PATH="$2"; shift 2 ;;
    --auto-approve) AUTO_APPROVE=1; shift ;;
    --skip-ansible) SKIP_ANSIBLE=1; shift ;;
    --infra-only)   INFRA_ONLY=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

# --- logging ----------------------------------------------------------------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

# --- scrub secrets from the environment on any exit -------------------------
cleanup_env() {
  unset RHSM_ORG_ID RHSM_ACTIVATION_KEY RHSM_USERNAME RHSM_PASSWORD \
        RH_REGISTRY_USERNAME RH_REGISTRY_PASSWORD LAB_USER_PASSWORD \
        AAP_ADMIN_PASSWORD GITEA_ADMIN_PASSWORD MM_ADMIN_PASSWORD \
        LIGHTSPEED_API_KEY AI_MODEL_ENDPOINT AI_MODEL_API_KEY 2>/dev/null || true
}
trap cleanup_env EXIT INT TERM

# --- 1. preflight -----------------------------------------------------------
bash "${SCRIPT_DIR}/preflight.sh"

# --- 2. AWS auth (SSO / profile / STS env) — never handles static keys ------
[[ -n "${AWS_PROFILE_ARG}" ]] && export AWS_PROFILE="${AWS_PROFILE_ARG}"
export AWS_REGION="${AWS_REGION_ARG}" AWS_DEFAULT_REGION="${AWS_REGION_ARG}"

log "Validating AWS credentials (region ${AWS_REGION})..."
if ! caller_json="$(aws sts get-caller-identity --output json 2>/dev/null)"; then
  die "No active AWS credentials. Run: aws sso login${AWS_PROFILE:+ --profile ${AWS_PROFILE}} (or export temporary STS creds), then re-run."
fi
account_id="$(printf '%s' "${caller_json}" | jq -r '.Account')"
log "Authenticated to AWS account ${account_id}."

# --- 3. ingress CIDR (default: this workstation's public IP /32) ------------
if [[ -z "${INGRESS_CIDR}" ]]; then
  log "Auto-detecting your public IP for ingress restriction..."
  myip="$(curl -fsS --max-time 10 https://checkip.amazonaws.com || true)"
  myip="${myip//[$'\r\n ']/}"
  [[ -n "${myip}" ]] || die "Could not detect public IP. Pass --ingress-cidr x.x.x.x/32."
  INGRESS_CIDR="${myip}/32"
fi
log "Ingress will be restricted to ${INGRESS_CIDR}."

# --- 4. SSH keypair (private key stays local; only the public key is used) --
if [[ ! -f "${SSH_KEY_PATH}" ]]; then
  log "Generating SSH keypair at ${SSH_KEY_PATH}"
  mkdir -p "$(dirname "${SSH_KEY_PATH}")"
  ssh-keygen -t ed25519 -N '' -C "aiops-ansible-demo" -f "${SSH_KEY_PATH}" >/dev/null
fi
chmod 600 "${SSH_KEY_PATH}"
SSH_PUB="$(cat "${SSH_KEY_PATH}.pub")"

# --- 5. collect secrets at the start (hidden input; env only) ---------------
if [[ "${SKIP_ANSIBLE}" -eq 0 ]]; then
  # shellcheck source=collect-secrets.sh
  source "${SCRIPT_DIR}/collect-secrets.sh"
  collect_secrets
else
  warn "--skip-ansible set: skipping secret collection and demo configuration."
fi

# --- 6. Check if infrastructure already exists (idempotency guard) -----------
infra_exists=0
if [[ -f "${TF_DIR}/terraform.tfstate" ]]; then
  if terraform -chdir="${TF_DIR}" state list 2>/dev/null | grep -q aws_instance.control; then
    log "Infrastructure already exists (detected from terraform.tfstate)"
    infra_exists=1
  fi
fi

if [[ "${infra_exists}" -eq 1 ]] && [[ "${SKIP_ANSIBLE}" -eq 0 ]]; then
  log "IDEMPOTENCY: Skipping terraform apply (infrastructure exists). Running Ansible only."
  INFRA_ONLY=1
fi

# --- 7. Terraform (NON-secret vars only, skipped if infra exists) ------
if [[ "${INFRA_ONLY}" -eq 0 ]]; then
  export TF_VAR_aws_region="${AWS_REGION}"
  [[ -n "${AWS_PROFILE:-}" ]] && export TF_VAR_aws_profile="${AWS_PROFILE}"
  export TF_VAR_allowed_ingress_cidrs="[\"${INGRESS_CIDR}\"]"
  export TF_VAR_ssh_public_key="${SSH_PUB}"

  log "terraform init"
  terraform -chdir="${TF_DIR}" init -input=false

  log "terraform apply (IDEMPOTENT: no changes = no action; new = create)"
  apply_args=(-input=false -auto-approve)
  terraform -chdir="${TF_DIR}" apply "${apply_args[@]}"
else
  log "Skipping terraform (infrastructure already exists)"
  export TF_VAR_aws_region="${AWS_REGION}"
  [[ -n "${AWS_PROFILE:-}" ]] && export TF_VAR_aws_profile="${AWS_PROFILE}"
fi

# --- 8. read outputs --------------------------------------------------------
CONTROL_PUBLIC_IP="$(terraform -chdir="${TF_DIR}" output -raw control_public_ip)"
CONTROL_PRIVATE_IP="$(terraform -chdir="${TF_DIR}" output -raw control_private_ip)"
TARGET_PUBLIC_IP="$(terraform -chdir="${TF_DIR}" output -raw target_public_ip)"
SSH_USER="$(terraform -chdir="${TF_DIR}" output -raw ssh_user)"

if [[ "${SKIP_ANSIBLE}" -eq 1 ]]; then
  log "Infrastructure ready. Skipping configuration (--skip-ansible)."
  terraform -chdir="${TF_DIR}" output
  exit 0
fi

# --- 9. render the Ansible inventory (non-secret) ---------------------------
export CONTROL_PUBLIC_IP CONTROL_PRIVATE_IP TARGET_PUBLIC_IP SSH_USER SSH_KEY_PATH
envsubst '${CONTROL_PUBLIC_IP} ${CONTROL_PRIVATE_IP} ${TARGET_PUBLIC_IP} ${SSH_USER} ${SSH_KEY_PATH}' \
  < "${ANSIBLE_DIR}/inventory.ini.tmpl" > "${ANSIBLE_DIR}/inventory.ini"
log "Wrote ${ANSIBLE_DIR}/inventory.ini"

# --- 10. wait for SSH on both nodes ------------------------------------------
wait_for_ssh() {
  local host="$1" tries=60
  log "Waiting for SSH on ${host}..."
  mkdir -p "${ANSIBLE_DIR}"
  until ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile="${ANSIBLE_DIR}/.known_hosts" \
            -i "${SSH_KEY_PATH}" "${SSH_USER}@${host}" 'true' >/dev/null 2>&1; do
    tries=$((tries - 1))
    [[ "${tries}" -gt 0 ]] || die "SSH to ${host} did not become ready (tried 60 times, 600 sec total)."
    sleep 10
  done
}
wait_for_ssh "${CONTROL_PUBLIC_IP}"
wait_for_ssh "${TARGET_PUBLIC_IP}"

# --- 11. install required Galaxy collections --------------------------------
log "Installing Ansible collections"
ansible-galaxy collection install -r "${ANSIBLE_DIR}/requirements.yml"

# --- 12. configure everything (secrets stay in env; read via lookups) -------
log "Running site.yml (this includes the AAP containerized install and can take 20-40+ min)"
( cd "${ANSIBLE_DIR}" && ansible-playbook -i inventory.ini site.yml )

# --- 13. summary (no secrets) -----------------------------------------------
cat <<EOF

$(printf '\033[1;32mDONE\033[0m')  Environment is up.

  AAP UI       : $(terraform -chdir="${TF_DIR}" output -raw aap_url)
  Gitea        : $(terraform -chdir="${TF_DIR}" output -raw gitea_url)
  Mattermost   : $(terraform -chdir="${TF_DIR}" output -raw mattermost_url)
  Webserver    : $(terraform -chdir="${TF_DIR}" output -raw webserver_url)

  SSH (control): ssh -i ${SSH_KEY_PATH} ${SSH_USER}@${CONTROL_PUBLIC_IP}
  SSH (target) : ssh -i ${SSH_KEY_PATH} ${SSH_USER}@${TARGET_PUBLIC_IP}

  UI login     : lab-user / <the lab-user password you entered>
  Tear down    : scripts/cleanup.sh${AWS_PROFILE:+ --profile ${AWS_PROFILE}}
EOF
