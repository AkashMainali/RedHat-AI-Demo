#!/usr/bin/env bash
# =============================================================================
# set-ai-endpoint.sh - point the running demo at a real AI inference endpoint.
#
# Run this once you have an OpenShift AI / RHEL AI / MaaS endpoint. It verifies
# the endpoint, then updates the AAP "Demo AI Endpoint" credential in place.
#
# It does NOT touch AAP, Gitea, Mattermost, EDA or the demo content - so it takes
# seconds, unlike re-running bootstrap.sh which would re-run the AAP installer.
#
# The token is prompted with hidden input and kept in this process environment
# only; it goes straight into AAP's encrypted credential store.
# =============================================================================
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ANSIBLE_DIR="${ROOT_DIR}/ansible"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

cleanup_env() { unset AI_MODEL_API_KEY AAP_ADMIN_PASSWORD 2>/dev/null || true; }
trap cleanup_env EXIT INT TERM

[[ -f "${ANSIBLE_DIR}/inventory.ini" ]] || die \
  "No ansible/inventory.ini. Run scripts/bootstrap.sh first to build the environment."

# --- collect ----------------------------------------------------------------
if [[ -z "${AI_MODEL_ENDPOINT:-}" ]]; then
  printf '\n== AI inference endpoint ==\n' >&2
  printf 'OpenAI-compatible base URL ending in /v1. For OpenShift AI Model Serving\n' >&2
  printf 'this is the model'"'"'s inference endpoint with /v1 appended, e.g.\n' >&2
  printf '  https://granite-my-project.apps.my-cluster.example.com/v1\n' >&2
  printf 'Endpoint URL: ' >&2
  IFS= read -r AI_MODEL_ENDPOINT
fi
[[ -n "${AI_MODEL_ENDPOINT}" ]] || die "An endpoint URL is required."

if [[ -z "${AI_MODEL_API_KEY:-}" ]]; then
  printf 'Bearer token (hidden, press Enter if the endpoint needs none): ' >&2
  IFS= read -rs AI_MODEL_API_KEY
  printf '\n' >&2
fi
AI_MODEL_API_KEY="${AI_MODEL_API_KEY:-not-required}"

# Discover the served model ids so the operator does not have to guess. This is
# the single most common source of a broken demo.
if [[ -z "${AI_MODEL_ID:-}" ]]; then
  log "Asking the endpoint which models it serves..."
  ids="$(curl -sSk --max-time 30 \
           -H "Authorization: Bearer ${AI_MODEL_API_KEY}" \
           "${AI_MODEL_ENDPOINT%/}/models" 2>/dev/null \
         | jq -r '.data[].id' 2>/dev/null || true)"

  if [[ -z "${ids}" ]]; then
    printf '  Could not list models (endpoint unreachable, bad token, or non-standard API).\n' >&2
    printf '  Enter the model id manually.\n' >&2
    printf 'Model id: ' >&2
    IFS= read -r AI_MODEL_ID
  else
    printf '\nModels available at this endpoint:\n' >&2
    printf '%s\n' "${ids}" | nl -w4 -s') ' >&2
    count="$(printf '%s\n' "${ids}" | wc -l | tr -d ' ')"
    if [[ "${count}" -eq 1 ]]; then
      AI_MODEL_ID="${ids}"
      log "Using the only model served: ${AI_MODEL_ID}"
    else
      printf 'Model id (paste one from above): ' >&2
      IFS= read -r AI_MODEL_ID
    fi
  fi
fi
[[ -n "${AI_MODEL_ID}" ]] || die "A model id is required."

# Optional second model for the playbook-generation step. A capable endpoint
# (OpenShift AI serving Granite 8B, for instance) handles both jobs with one
# model - the split only exists to work around small CPU-hosted models.
if [[ -z "${AI_CODEGEN_MODEL_ID:-}" ]]; then
  printf 'Separate model for code generation? Enter to use %s: ' "${AI_MODEL_ID}" >&2
  IFS= read -r AI_CODEGEN_MODEL_ID
  AI_CODEGEN_MODEL_ID="${AI_CODEGEN_MODEL_ID:-${AI_MODEL_ID}}"
fi

if [[ -z "${AAP_ADMIN_PASSWORD:-}" ]]; then
  printf 'AAP admin password (hidden) [redhat]: ' >&2
  IFS= read -rs AAP_ADMIN_PASSWORD
  printf '\n' >&2
  AAP_ADMIN_PASSWORD="${AAP_ADMIN_PASSWORD:-redhat}"
fi

export AI_MODEL_ENDPOINT AI_MODEL_ID AI_CODEGEN_MODEL_ID AI_MODEL_API_KEY AAP_ADMIN_PASSWORD

# --- ansible.controller comes from the AAP setup bundle ---------------------
AAP_COLLECTIONS_DIR="${ANSIBLE_DIR}/.aap-collections"
if [[ ! -d "${AAP_COLLECTIONS_DIR}/ansible_collections/ansible/controller" ]]; then
  aap_tarball="$(find "${ANSIBLE_DIR}/aap" -maxdepth 1 -name '*.tar.gz' -print -quit 2>/dev/null || true)"
  [[ -n "${aap_tarball}" ]] || die \
    "ansible.controller not found and no AAP bundle in ansible/aap/ to extract it from."
  log "Extracting ansible.controller from $(basename "${aap_tarball}")"
  mkdir -p "${AAP_COLLECTIONS_DIR}"
  tar -xzf "${aap_tarball}" -C "${AAP_COLLECTIONS_DIR}" --strip-components=2 \
    --wildcards '*/collections/ansible_collections/*' 2>/dev/null || true
fi
export ANSIBLE_COLLECTIONS_PATH="${AAP_COLLECTIONS_DIR}:${HOME}/.ansible/collections:/usr/share/ansible/collections"

# --- apply ------------------------------------------------------------------
log "Verifying the endpoint and updating the AAP credential"
( cd "${ANSIBLE_DIR}" && ansible-playbook -i inventory.ini \
    -e "aap_admin_password=${AAP_ADMIN_PASSWORD}" \
    update-ai-endpoint.yml )

cat <<EOF

$(printf '\033[1;32mDONE\033[0m')  The demo now uses your endpoint.

  Endpoint : ${AI_MODEL_ENDPOINT}
  Model    : ${AI_MODEL_ID}
  Codegen  : ${AI_CODEGEN_MODEL_ID}

Nothing else to change - every AI job template reads this credential. Re-run the
demo from "❌ Break Apache" to see it in action.
EOF
