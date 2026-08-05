#!/usr/bin/env bash
# =============================================================================
# demo_content.sh - configure ONLY the demo content. The fast iteration path.
#
# Runs site.yml with --tags demo_content, which:
#   * pushes ansible/roles/demo_content/files/repo/ into Gitea
#   * bootstraps the Mattermost team and incoming webhook
#   * creates the AAP credentials, inventory, projects, 10 job templates and
#     both workflows
#   * creates the EDA project, credentials and rulebook activation
#
# Minutes, not the 20-40 the AAP containerized install needs. Use this whenever
# you change the demo playbooks, rulebook, job templates or workflows.
#
# It does NOT: run Terraform, register RHSM, install AAP, or touch Kafka / Gitea /
# Mattermost / the inference endpoint as *services*. Those must already exist -
# run bootstrap.sh once first.
#
# Red Hat credentials and a vault password are deliberately not requested: this
# stage only talks to services that are already installed and authenticated.
# =============================================================================
set -euo pipefail
umask 077

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
trap_scrub

AWS_REGION_ARG="${AWS_REGION:-us-east-1}"
AWS_PROFILE_ARG="${AWS_PROFILE:-}"
SSH_KEY_PATH="${SSH_KEY_PATH:-${HOME}/.ssh/aiops_ansible_demo}"
CHECK_MODE=0
VERBOSE=""
EXTRA_ARGS=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [-- extra ansible-playbook args]

Configures only the demo content (Gitea repos + AAP/EDA objects). Fast and
idempotent. Requires infrastructure that bootstrap.sh has already configured.

  --profile NAME        AWS SSO/CLI profile (needed only to read Terraform outputs)
  --region NAME         AWS region (default: ${AWS_REGION_ARG})
  --ssh-key PATH        SSH private key (default: ${SSH_KEY_PATH})
  --check               Dry run: report what would change, change nothing
  -v, --verbose         Pass -v to ansible-playbook (repeatable: -vv, -vvv)
  -h, --help            Show this help

Examples:
  $(basename "$0") --profile my-sso-profile
  $(basename "$0") --profile my-sso-profile --check
  $(basename "$0") --profile my-sso-profile -- --start-at-task "Create the workflows"
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)   AWS_PROFILE_ARG="$2"; shift 2 ;;
    --region)    AWS_REGION_ARG="$2"; shift 2 ;;
    --ssh-key)   SSH_KEY_PATH="$2"; shift 2 ;;
    --check)     CHECK_MODE=1; shift ;;
    -v)          VERBOSE="-v"; shift ;;
    -vv)         VERBOSE="-vv"; shift ;;
    -vvv)        VERBOSE="-vvv"; shift ;;
    --verbose)   VERBOSE="-v"; shift ;;
    --)          shift; EXTRA_ARGS=("$@"); break ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

# --- 1. tooling + the AAP bundle (ansible.controller comes from it) ----------
bash "${SCRIPT_DIR}/preflight.sh"

# --- 2. AWS, only to read Terraform outputs ---------------------------------
aws_authenticate "${AWS_REGION_ARG}" "${AWS_PROFILE_ARG}"
tf_export_vars "${AWS_REGION}" "${DEMO_USERNAME:-aiops-ansible-demo}"

# --- 3. refuse to run against nothing ---------------------------------------
require_infra
read_tf_outputs
log "Targeting control node ${CONTROL_PUBLIC_IP}"

[[ -f "${SSH_KEY_PATH}" ]] || die "SSH key ${SSH_KEY_PATH} not found. Pass --ssh-key, or run bootstrap.sh which creates it."
chmod 600 "${SSH_KEY_PATH}"
export SSH_KEY_PATH

# --- 4. lightweight secret collection ---------------------------------------
# shellcheck source=collect-secrets.sh
source "${SCRIPT_DIR}/collect-secrets.sh"
collect_secrets_demo_content
resolve_ai_backend

# --- 5. inventory + collections ---------------------------------------------
render_inventory "${SSH_KEY_PATH}"
wait_for_ssh "${CONTROL_PUBLIC_IP}" "${SSH_USER}" "${SSH_KEY_PATH}" 12
ensure_aap_collections require

# --- 6. run only the demo_content stage -------------------------------------
# --limit control because every demo_content task either runs on the control node
# or is delegated to this workstation; skipping the target play saves a fact
# gather for no loss.
run_args=(--tags demo_content --limit control)
[[ "${CHECK_MODE}" -eq 1 ]] && run_args+=(--check --diff)
[[ -n "${VERBOSE}" ]] && run_args+=("${VERBOSE}")
[[ ${#EXTRA_ARGS[@]} -gt 0 ]] && run_args+=("${EXTRA_ARGS[@]}")

if [[ "${CHECK_MODE}" -eq 1 ]]; then
  warn "Check mode: several tasks create resources through REST APIs and cannot"
  warn "be simulated, so expect skips and 'undefined variable' noise. Useful for"
  warn "seeing which files would change, not as a full dry run."
fi

log "Running site.yml --tags demo_content"
run_site "${run_args[@]}"

[[ "${CHECK_MODE}" -eq 1 ]] || print_demo_summary
