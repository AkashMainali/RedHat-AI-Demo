#!/usr/bin/env bash
# =============================================================================
# common.sh - shared plumbing for the three entrypoints.
#
#   infra_only.sh     infrastructure only
#   demo_content.sh   demo content only (fast)
#   bootstrap.sh      everything
#
# Sourced, never executed. Every function is safe to call more than once.
#
# Security model (identical across all three entrypoints):
#   * AWS auth uses your ACTIVE credential chain (SSO / named profile / STS env).
#     No AWS keys are ever prompted for, printed, or stored.
#   * Red Hat and app secrets live in the process environment only. Ansible reads
#     them via env lookups; they are never written to disk, echoed, committed, or
#     placed in Terraform state.
#   * Terraform receives only NON-secret variables (region, ingress CIDR, public
#     SSH key), so state contains no credentials.
# =============================================================================

# --- paths ------------------------------------------------------------------
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "${LIB_DIR}/.." && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"
ANSIBLE_DIR="${ROOT_DIR}/ansible"
AAP_COLLECTIONS_DIR="${ANSIBLE_DIR}/.aap-collections"

# --- logging ----------------------------------------------------------------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '\033[1;32m %s\033[0m\n' "$*"; }

# --- secret hygiene ---------------------------------------------------------
# Registered by every entrypoint so an interrupted run does not leave secrets in
# the environment of a sourcing shell.
scrub_secrets() {
  unset RHSM_ORG_ID RHSM_ACTIVATION_KEY RHSM_USERNAME RHSM_PASSWORD \
        RH_REGISTRY_USERNAME RH_REGISTRY_PASSWORD LAB_USER_PASSWORD \
        AAP_ADMIN_PASSWORD GITEA_ADMIN_PASSWORD MM_ADMIN_PASSWORD \
        LIGHTSPEED_API_KEY AI_MODEL_ENDPOINT AI_MODEL_API_KEY AI_MODEL_ID \
        AI_CODEGEN_MODEL_ID HF_TOKEN VAULT_PASSWORD 2>/dev/null || true
  # The encrypted vault files stay on the control node so re-runs work.
}
trap_scrub() { trap scrub_secrets EXIT INT TERM; }

# --- AWS --------------------------------------------------------------------
aws_authenticate() {
  local region="$1" profile="${2:-}"
  [[ -n "${profile}" ]] && export AWS_PROFILE="${profile}"
  export AWS_REGION="${region}" AWS_DEFAULT_REGION="${region}"

  log "Validating AWS credentials (region ${AWS_REGION})..."
  local caller
  if ! caller="$(aws sts get-caller-identity --output json 2>/dev/null)"; then
    die "No active AWS credentials. Run: aws sso login${AWS_PROFILE:+ --profile ${AWS_PROFILE}} (or export temporary STS creds), then re-run."
  fi
  log "Authenticated to AWS account $(printf '%s' "${caller}" | jq -r '.Account')."
}

detect_ingress_cidr() {
  # Echoes the CIDR; caller assigns it.
  local given="${1:-}"
  if [[ -n "${given}" ]]; then printf '%s' "${given}"; return; fi
  local myip
  myip="$(curl -fsS --max-time 10 https://checkip.amazonaws.com || true)"
  myip="${myip//[$'\r\n ']/}"
  [[ -n "${myip}" ]] || die "Could not detect your public IP. Pass --ingress-cidr x.x.x.x/32."
  printf '%s/32' "${myip}"
}

# --- SSH --------------------------------------------------------------------
ensure_ssh_key() {
  local path="$1"
  if [[ ! -f "${path}" ]]; then
    log "Generating SSH keypair at ${path}"
    mkdir -p "$(dirname "${path}")"
    ssh-keygen -t ed25519 -N '' -C "aiops-ansible-demo" -f "${path}" >/dev/null
  fi
  chmod 600 "${path}"
}

wait_for_ssh() {
  local host="$1" user="$2" key="$3" tries="${4:-60}"
  log "Waiting for SSH on ${host}..."
  mkdir -p "${ANSIBLE_DIR}"
  until ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile="${ANSIBLE_DIR}/.known_hosts" \
            -i "${key}" "${user}@${host}" 'true' >/dev/null 2>&1; do
    tries=$((tries - 1))
    [[ "${tries}" -gt 0 ]] || die "SSH to ${host} did not become ready."
    sleep 10
  done
}

# --- Terraform --------------------------------------------------------------
tf_export_vars() {
  local region="$1" project="$2" ingress="${3:-}" sshpub="${4:-}"
  export TF_VAR_aws_region="${region}"
  [[ -n "${AWS_PROFILE:-}" ]] && export TF_VAR_aws_profile="${AWS_PROFILE}"
  export TF_VAR_project_name="${project}"
  [[ -n "${ingress}" ]] && export TF_VAR_allowed_ingress_cidrs="[\"${ingress}\"]"
  [[ -n "${sshpub}" ]] && export TF_VAR_ssh_public_key="${sshpub}"
  return 0
}

infra_exists() {
  [[ -f "${TF_DIR}/terraform.tfstate" ]] || return 1
  terraform -chdir="${TF_DIR}" state list 2>/dev/null | grep -q 'aws_instance.control'
}

tf_apply() {
  log "terraform init"
  terraform -chdir="${TF_DIR}" init -input=false
  log "terraform apply (idempotent: no changes means no action)"
  terraform -chdir="${TF_DIR}" apply -input=false -auto-approve
}

require_infra() {
  # Used by demo_content.sh: refuse to run against nothing, with a clear pointer.
  infra_exists || die \
"No infrastructure found in ${TF_DIR}.

Build it first:
  ./scripts/infra_only.sh --profile <aws-profile>     # infrastructure only
  ./scripts/bootstrap.sh  --profile <aws-profile>     # infrastructure + full config"
}

read_tf_outputs() {
  local o
  o="$(terraform -chdir="${TF_DIR}" output -json 2>/dev/null)" \
    || die "Could not read Terraform outputs. Has the infrastructure been created?"

  CONTROL_PUBLIC_IP="$(printf '%s' "${o}" | jq -r '.control_public_ip.value // empty')"
  CONTROL_PRIVATE_IP="$(printf '%s' "${o}" | jq -r '.control_private_ip.value // empty')"
  TARGET_PUBLIC_IP="$(printf '%s' "${o}" | jq -r '.target_public_ip.value // empty')"
  TARGET_PRIVATE_IP="$(printf '%s' "${o}" | jq -r '.target_private_ip.value // empty')"
  SSH_USER="$(printf '%s' "${o}" | jq -r '.ssh_user.value // "ec2-user"')"

  [[ -n "${CONTROL_PUBLIC_IP}" && -n "${TARGET_PUBLIC_IP}" ]] \
    || die "Terraform outputs are incomplete - the infrastructure may be partially built. Run ./scripts/infra_only.sh to converge."

  export CONTROL_PUBLIC_IP CONTROL_PRIVATE_IP TARGET_PUBLIC_IP TARGET_PRIVATE_IP SSH_USER
}

# --- Ansible ----------------------------------------------------------------
render_inventory() {
  local key="$1"
  export SSH_KEY_PATH="${key}"
  envsubst '${CONTROL_PUBLIC_IP} ${CONTROL_PRIVATE_IP} ${TARGET_PUBLIC_IP} ${TARGET_PRIVATE_IP} ${SSH_USER} ${SSH_KEY_PATH}' \
    < "${ANSIBLE_DIR}/inventory.ini.tmpl" > "${ANSIBLE_DIR}/inventory.ini"
  log "Wrote ${ANSIBLE_DIR}/inventory.ini"
}

install_galaxy_collections() {
  log "Installing Ansible collections"
  ansible-galaxy collection install -r "${ANSIBLE_DIR}/requirements.yml"
}

ensure_aap_collections() {
  # ansible.controller (used to configure AAP as code) ships inside the AAP
  # containerized setup bundle, so extract it locally rather than requiring a
  # Red Hat Automation Hub token.
  local required="${1:-warn}"   # 'require' to make a missing bundle fatal

  # The bundle directory is matched CASE-INSENSITIVELY (find -iname). It is
  # tracked in git as ansible/AAP/ (uppercase); a prior version of this script
  # looked only for lowercase ansible/aap/, which happened to still match on
  # case-insensitive filesystems (macOS, Windows) but silently finds nothing
  # on most Linux filesystems, which are case-sensitive. Matching either
  # casing here removes that gap entirely.
  local aap_dir tarball
  aap_dir="$(find "${ANSIBLE_DIR}" -maxdepth 1 -iname 'aap' -type d -print -quit 2>/dev/null || true)"
  if [[ -n "${aap_dir}" ]]; then
    tarball="$(find "${aap_dir}" -maxdepth 1 -name '*.tar.gz' -print -quit 2>/dev/null || true)"
  fi

  if [[ -z "${tarball:-}" ]]; then
    if [[ "${required}" == "require" ]]; then
      die "No AAP setup bundle found (looked for ansible/AAP/*.tar.gz and ansible/aap/*.tar.gz). ansible.controller is extracted from it to configure AAP. Download it from https://developers.redhat.com/products/ansible/download and place the .tar.gz in ansible/AAP/."
    fi
    warn "No AAP tarball found under ansible/AAP/ or ansible/aap/ - AAP configuration will fail."
    return 0
  fi

  # Completeness, not just existence: checking only "does the directory exist"
  # let an interrupted or corrupt earlier extraction look like "already done"
  # forever, on every later run. MANIFEST.json only exists if the collection
  # actually extracted in full.
  local manifest="${AAP_COLLECTIONS_DIR}/ansible_collections/ansible/controller/MANIFEST.json"
  if [[ ! -f "${manifest}" ]]; then
    log "Extracting AAP config collections from $(basename "${tarball}")"
    rm -rf "${AAP_COLLECTIONS_DIR}"
    mkdir -p "${AAP_COLLECTIONS_DIR}"
    # --strip-components=2 drops the release dir and the 'collections/' level so
    # the result is a valid ANSIBLE_COLLECTIONS_PATH root. --wildcards is
    # required for GNU tar to treat the pattern as a glob; bsdtar (macOS)
    # accepts the same flag as a compatibility no-op, so this is portable.
    local tar_err
    if ! tar_err="$(tar -xzf "${tarball}" -C "${AAP_COLLECTIONS_DIR}" --strip-components=2 \
           --wildcards '*/collections/ansible_collections/*' 2>&1)"; then
      if [[ "${required}" == "require" ]]; then
        die "Could not extract collections from the AAP bundle: ${tar_err}"
      fi
      warn "Could not extract collections from the AAP bundle: ${tar_err}"
    fi
  fi
  export ANSIBLE_COLLECTIONS_PATH="${AAP_COLLECTIONS_DIR}:${HOME}/.ansible/collections:/usr/share/ansible/collections"
}

# install_all_collections - the ONE thing to run to make this machine able to
# configure AAP. Installs every collection this project needs and then
# VERIFIES each is actually resolvable, rather than trusting exit codes alone.
#
# Deliberately has no dependency on AWS, Terraform or SSH: it only touches
# this machine. Both bootstrap.sh and demo_content.sh call it immediately
# after preflight.sh, before anything is built, so a missing or broken
# collection fails in seconds - not 20-40 minutes into a build. It is also a
# standalone entrypoint: scripts/install-collections.sh.
#
# Why this must run on THIS machine and not the remote control node: AAP and
# EDA are configured entirely through REST API calls delegated to localhost -
# see the comment at the top of ansible/roles/demo_content/tasks/main.yml -
# so ansible.controller has to be resolvable wherever ansible-playbook itself
# runs, which is here.
install_all_collections() {
  log "Installing Ansible collections on this machine"

  log "  - Galaxy collections (ansible/requirements.yml)"
  ansible-galaxy collection install -r "${ANSIBLE_DIR}/requirements.yml" \
    || die "Could not install collections from requirements.yml. Check network access to galaxy.ansible.com, or install them by hand: ansible-galaxy collection install -r ansible/requirements.yml"

  log "  - ansible.controller (extracted from the AAP setup bundle)"
  ensure_aap_collections require

  log "Verifying collections are resolvable..."
  local listing required_c missing=()
  listing="$(ansible-galaxy collection list 2>/dev/null | awk 'NF==2 && $1 ~ /\./ {print $1}')"
  for required_c in ansible.controller community.general ansible.posix containers.podman; do
    if grep -qx "${required_c}" <<<"${listing}"; then
      printf '  ok    %s\n' "${required_c}"
    else
      printf '  MISS  %s\n' "${required_c}"
      missing+=("${required_c}")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing collection(s) after install: ${missing[*]}.
  ANSIBLE_COLLECTIONS_PATH=${ANSIBLE_COLLECTIONS_PATH:-<unset>}
  Re-run scripts/install-collections.sh, or check the Prerequisites section of README.md."
  fi
  ok "All required collections present."
}

# --- AI backend -------------------------------------------------------------
resolve_ai_backend() {
  if [[ -n "${AI_MODEL_ENDPOINT:-}" ]]; then
    AI_BACKEND="external"
    log "AI inference: external endpoint ${AI_MODEL_ENDPOINT}"
  else
    AI_BACKEND="${AI_BACKEND:-ollama}"
    log "AI inference: local CPU (${AI_BACKEND}) on the control node"
  fi
  export AI_BACKEND
}

# --- shared ansible-playbook invocation -------------------------------------
# Passes the non-secret infrastructure facts plus the secrets Ansible needs.
# Extra arguments are appended, which is how the entrypoints add --tags/--limit.
run_site() {
  ( cd "${ANSIBLE_DIR}" && ansible-playbook -i inventory.ini \
      -e "control_public_ip=${CONTROL_PUBLIC_IP}" \
      -e "control_private_ip=${CONTROL_PRIVATE_IP}" \
      -e "target_public_ip=${TARGET_PUBLIC_IP}" \
      -e "target_private_ip=${TARGET_PRIVATE_IP}" \
      -e "vault_password=${VAULT_PASSWORD:-}" \
      -e "rh_registry_username=${RH_REGISTRY_USERNAME:-}" \
      -e "rh_registry_password=${RH_REGISTRY_PASSWORD:-}" \
      -e "lab_user_password=${LAB_USER_PASSWORD:-redhat}" \
      -e "aap_admin_password=${AAP_ADMIN_PASSWORD:-redhat}" \
      -e "mm_admin_password=${MM_ADMIN_PASSWORD:-ansibleredhat}" \
      -e "ai_backend=${AI_BACKEND:-ollama}" \
      -e "ai_model_api_key=${AI_MODEL_API_KEY:-not-required}" \
      site.yml "$@" )
}

# --- summaries --------------------------------------------------------------
print_infra_summary() {
  cat <<EOF

$(ok "DONE")  Infrastructure is up.

  AAP UI       : $(terraform -chdir="${TF_DIR}" output -raw aap_url 2>/dev/null)
  Gitea        : $(terraform -chdir="${TF_DIR}" output -raw gitea_url 2>/dev/null)
  Mattermost   : $(terraform -chdir="${TF_DIR}" output -raw mattermost_url 2>/dev/null)
  Webserver    : $(terraform -chdir="${TF_DIR}" output -raw webserver_url 2>/dev/null)

  SSH (control): ssh -i ${SSH_KEY_PATH} ${SSH_USER}@${CONTROL_PUBLIC_IP}
  SSH (target) : ssh -i ${SSH_KEY_PATH} ${SSH_USER}@${TARGET_PUBLIC_IP}

  Nothing is configured yet. Next:
    ./scripts/bootstrap.sh${AWS_PROFILE:+ --profile ${AWS_PROFILE}}      # full configuration
  Tear down:
    ./scripts/cleanup.sh${AWS_PROFILE:+ --profile ${AWS_PROFILE}}
EOF
}

print_demo_summary() {
  cat <<EOF

$(ok "DONE")  Demo content is configured.

  AAP UI       : https://${CONTROL_PUBLIC_IP}          admin / ${AAP_ADMIN_PASSWORD:-redhat}
  Gitea        : http://${CONTROL_PUBLIC_IP}:488       lab-user / ${LAB_USER_PASSWORD:-redhat}
  Mattermost   : http://${CONTROL_PUBLIC_IP}:8065      ansibleadmin / ${MM_ADMIN_PASSWORD:-ansibleredhat}
  Webserver    : http://${TARGET_PUBLIC_IP}

  AI inference : ${AI_BACKEND:-ollama}${AI_MODEL_ENDPOINT:+ (${AI_MODEL_ENDPOINT})}
                 RCA model     : ${AI_MODEL_ID:-granite3.1-dense:2b}
                 Codegen model : ${AI_CODEGEN_MODEL_ID:-${AI_MODEL_ID:-qwen2.5-coder:3b}}

  Run the demo:
    1. AAP > Automation Execution > Templates > launch "❌ Break Apache"
    2. Watch Automation Decisions > Rulebook Activations fire
    3. Read the AI root cause analysis in Mattermost #town-square
    4. Launch "Remediation Workflow", review the AI prompt, finish
    5. Launch "🔧✅ Execute HTTPD Remediation" with limit target-node
    6. Reset with "✅ Restore Apache"

  Changed the demo content? Re-run this script - it takes minutes, not the
  20-40 the full AAP install needs.
EOF
}
