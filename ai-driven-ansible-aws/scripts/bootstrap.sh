#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh - the complete build: infrastructure + full configuration.
#
# This is the "one command from nothing" entrypoint. It runs Terraform, then the
# whole of site.yml: RHSM registration, httpd + Filebeat on the target, Kafka /
# Gitea / Mattermost containers, the local inference endpoint, the AAP
# containerized install, and finally the demo content.
#
# Expect 30-50 minutes, dominated by the AAP install.
#
# The other two entrypoints exist so you rarely need this one twice:
#   ./scripts/infra_only.sh     infrastructure only, no secrets prompted
#   ./scripts/demo_content.sh   demo content only - minutes, for iterating
#
# Security model: see scripts/lib/common.sh.
# =============================================================================
set -euo pipefail
umask 077

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
trap_scrub

# --- defaults / flags -------------------------------------------------------
AWS_REGION_ARG="${AWS_REGION:-us-east-1}"
AWS_PROFILE_ARG="${AWS_PROFILE:-}"
SSH_KEY_PATH="${SSH_KEY_PATH:-${HOME}/.ssh/aiops_ansible_demo}"
INGRESS_CIDR="${INGRESS_CIDR:-}"
DEMO_USERNAME="${DEMO_USERNAME:-}"
SKIP_ANSIBLE=0
SKIP_TERRAFORM=0
TAGS=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

SAFE & IDEMPOTENT: re-running converges; it never creates duplicate servers.

  --profile NAME        AWS SSO/CLI profile (else default chain / AWS_PROFILE)
  --region NAME         AWS region (default: ${AWS_REGION_ARG})
  --username NAME       Prefix for all resource names (default: prompted)
  --ingress-cidr CIDR   Restrict access to this CIDR (default: your public IP /32)
  --ssh-key PATH        SSH private key to use/create (default: ${SSH_KEY_PATH})
  --skip-ansible        Provision infrastructure only (same as infra_only.sh)
  --skip-terraform      Configure only; requires existing infrastructure
  -y, --yes             Non-interactive: never prompt. Requires RHSM_USERNAME and
                        RHSM_PASSWORD exported; everything optional takes its
                        default (vault password auto-generated, local AI endpoint,
                        no Lightspeed token).
  --tags TAGS           Run only these site.yml tags. One of:
                          base          RHSM registration and base packages
                          target        httpd + Filebeat on the target node
                          services      Kafka, Gitea, Mattermost containers
                          ai            local CPU inference endpoint + models
                          aap           the AAP containerized install (20-40 min)
                          subscription  attach the AAP subscription (seconds)
                          demo_content  Gitea content + AAP/EDA configuration
                        'demo_content' implies 'ai' - see the note below.
  -h, --help            Show this help

Faster alternatives for common cases:
  ./scripts/infra_only.sh      infrastructure only
  ./scripts/demo_content.sh    demo content only (minutes, not 30-50)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)        AWS_PROFILE_ARG="$2"; shift 2 ;;
    --region)         AWS_REGION_ARG="$2"; shift 2 ;;
    --username)       DEMO_USERNAME="$2"; shift 2 ;;
    --ingress-cidr)   INGRESS_CIDR="$2"; shift 2 ;;
    --ssh-key)        SSH_KEY_PATH="$2"; shift 2 ;;
    --skip-ansible)   SKIP_ANSIBLE=1; shift ;;
    --skip-terraform) SKIP_TERRAFORM=1; shift ;;
    --infra-only)     SKIP_TERRAFORM=1; shift ;;   # kept for backwards compat
    --auto-approve)   shift ;;                     # always on; accepted silently
    -y|--yes)         export AAP_DEMO_NONINTERACTIVE=1; shift ;;
    --tags)           TAGS="$2"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

# --- 1. workstation tooling + AAP bundle -------------------------------------
bash "${SCRIPT_DIR}/preflight.sh"

# --- 2. resource naming ------------------------------------------------------
if [[ -z "${DEMO_USERNAME}" ]]; then
  if [[ "${AAP_DEMO_NONINTERACTIVE:-0}" == "1" ]]; then
    DEMO_USERNAME="aiops-ansible-demo"
  else
    printf '\n== Resource naming ==\n' >&2
    printf 'Prefix for all resource names (Enter for "aiops-ansible-demo"): ' >&2
    IFS= read -r DEMO_USERNAME
    DEMO_USERNAME="${DEMO_USERNAME:-aiops-ansible-demo}"
  fi
fi
log "Resource prefix: ${DEMO_USERNAME}"

# --- 3. AWS ------------------------------------------------------------------
aws_authenticate "${AWS_REGION_ARG}" "${AWS_PROFILE_ARG}"

INGRESS_CIDR="$(detect_ingress_cidr "${INGRESS_CIDR}")"
log "Ingress will be restricted to ${INGRESS_CIDR}."

# --- 4. SSH keypair ----------------------------------------------------------
ensure_ssh_key "${SSH_KEY_PATH}"
export SSH_KEY_PATH

# --- 5. secrets, collected up front so the long run is unattended ------------
if [[ "${SKIP_ANSIBLE}" -eq 0 ]]; then
  # shellcheck source=collect-secrets.sh
  source "${SCRIPT_DIR}/collect-secrets.sh"
  # Explicit check rather than relying on set -e: in non-interactive mode this
  # returns non-zero when a required credential is missing, and that must stop
  # the run before Terraform creates anything.
  collect_secrets || die "Secret collection failed - see above. Nothing has been created."
  log "Secrets collected in memory (the vault file is created on the control node)"
else
  warn "--skip-ansible: skipping secret collection and configuration."
fi

# --- 6. Terraform ------------------------------------------------------------
tf_export_vars "${AWS_REGION}" "${DEMO_USERNAME}" "${INGRESS_CIDR}" "$(cat "${SSH_KEY_PATH}.pub")"

if [[ "${SKIP_TERRAFORM}" -eq 1 ]]; then
  log "--skip-terraform: using existing infrastructure"
  require_infra
elif infra_exists; then
  # Terraform is idempotent, so applying again is safe and catches drift.
  log "Infrastructure already exists; applying to converge any drift"
  tf_apply
else
  tf_apply
fi

read_tf_outputs
resolve_ai_backend

if [[ "${SKIP_ANSIBLE}" -eq 1 ]]; then
  print_infra_summary
  exit 0
fi

# --- 7. inventory, SSH readiness, collections --------------------------------
render_inventory "${SSH_KEY_PATH}"
wait_for_ssh "${CONTROL_PUBLIC_IP}" "${SSH_USER}" "${SSH_KEY_PATH}"
wait_for_ssh "${TARGET_PUBLIC_IP}" "${SSH_USER}" "${SSH_KEY_PATH}"
install_galaxy_collections
ensure_aap_collections require

# --- 8. configure ------------------------------------------------------------
run_args=()
if [[ -n "${TAGS}" ]]; then
  # demo_content writes the AI model ids into AAP's credential, so the endpoint
  # serving those models must be reconciled in the same run. Selecting
  # demo_content alone would leave the credential advertising a model that was
  # never pulled, which fails later with "model 'x' not found". Same reasoning as
  # demo_content.sh, applied here so --tags behaves identically.
  if [[ ",${TAGS}," == *",demo_content,"* && ",${TAGS}," != *",ai,"* ]]; then
    TAGS="${TAGS},ai"
    log "Added the 'ai' tag: demo_content declares which models it needs, so the"
    log "inference endpoint is reconciled in the same run."
  fi
  run_args+=(--tags "${TAGS}")
  log "Running site.yml --tags ${TAGS}"
else
  log "Running site.yml (includes the AAP containerized install: 20-40+ min)"
fi
run_site "${run_args[@]+"${run_args[@]}"}"

# --- 9. summary (no secrets) -------------------------------------------------
print_demo_summary
cat <<EOF
  SSH (control): ssh -i ${SSH_KEY_PATH} ${SSH_USER}@${CONTROL_PUBLIC_IP}
  SSH (target) : ssh -i ${SSH_KEY_PATH} ${SSH_USER}@${TARGET_PUBLIC_IP}

  Iterate on the demo : ./scripts/demo_content.sh${AWS_PROFILE:+ --profile ${AWS_PROFILE}}
  Tear down           : ./scripts/cleanup.sh${AWS_PROFILE:+ --profile ${AWS_PROFILE}}
EOF
