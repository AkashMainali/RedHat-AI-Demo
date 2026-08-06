#!/usr/bin/env bash
# =============================================================================
# Sourced by bootstrap.sh. Prompts for every secret using HIDDEN input and
# EXPORTS them as environment variables for the current process only.
#
#   * Nothing is ever written to disk.
#   * Nothing is ever echoed back to the screen.
#   * Nothing is passed on a command line (Ansible reads these from the env).
#
# This file is meant to be `source`d, not executed.
# =============================================================================

# _read_secret <prompt> <varname> <required:0|1> <confirm:0|1> <default:empty>
_read_secret() {
  local prompt="$1" var="$2" required="${3:-0}" confirm="${4:-0}" default="${5:-}" val val2
  while true; do
    local prompt_text="${prompt}"
    [[ -n "${default}" ]] && prompt_text="${prompt} [default: ${default}]"
    printf '%s: ' "${prompt_text}" > /dev/tty
    IFS= read -rs val < /dev/tty
    printf '\n' > /dev/tty

    # Use default if empty input provided
    [[ -z "${val}" && -n "${default}" ]] && val="${default}"

    if [[ -z "${val}" && "${required}" -eq 1 ]]; then
      printf '  (required — please enter a value)\n' > /dev/tty
      continue
    fi
    if [[ "${confirm}" -eq 1 && -n "${val}" ]]; then
      printf 'Confirm %s: ' "${prompt}" > /dev/tty
      IFS= read -rs val2 < /dev/tty
      printf '\n' > /dev/tty
      if [[ "${val}" != "${val2}" ]]; then
        printf '  (entries did not match — try again)\n' > /dev/tty
        continue
      fi
    fi
    break
  done
  export "${var}=${val}"
  unset val val2
}

# _read_plain <prompt> <varname> [default]  (non-secret; visible input)
# An empty answer keeps the default, so a value already exported survives Enter.
_read_plain() {
  local prompt="$1" var="$2" default="${3:-}" val
  local prompt_text="${prompt}"
  [[ -n "${default}" ]] && prompt_text="${prompt} [${default}]"
  printf '%s: ' "${prompt_text}" > /dev/tty
  IFS= read -r val < /dev/tty
  [[ -z "${val}" ]] && val="${default}"
  export "${var}=${val}"
  unset val
}

# _skip_if_set <varname> - true when the variable already has a value, so a
# non-interactive run (CI, or a re-run with exports already in place) never
# blocks on an optional prompt. Never echoes the value.
#
# In non-interactive mode every OPTIONAL prompt is treated as already answered,
# so the run never blocks waiting on a terminal. Required credentials are still
# required - they are validated up front instead.
_skip_if_set() {
  local var="$1"
  [[ "${AAP_DEMO_NONINTERACTIVE:-0}" == "1" ]] && return 0
  [[ -n "${!var:-}" ]]
}

# Fails fast, before anything is built, if non-interactive mode is missing a
# credential it cannot prompt for.
_require_for_noninteractive() {
  [[ "${AAP_DEMO_NONINTERACTIVE:-0}" == "1" ]] || return 0
  local missing=()
  [[ -n "${RHSM_USERNAME:-}" ]] || missing+=(RHSM_USERNAME)
  [[ -n "${RHSM_PASSWORD:-}" ]] || missing+=(RHSM_PASSWORD)
  if [[ ${#missing[@]} -gt 0 ]]; then
    printf 'ERROR non-interactive mode needs these exported first: %s\n' "${missing[*]}" >&2
    printf '  export RHSM_USERNAME="you@example.com"\n' >&2
    printf '  read -rs RHSM_PASSWORD && export RHSM_PASSWORD\n' >&2
    return 1
  fi
  return 0
}

# --- app passwords: lab defaults, overridable from the environment -----------
_collect_app_passwords() {
  printf '\n== Application passwords ==\n' > /dev/tty
  export LAB_USER_PASSWORD="${LAB_USER_PASSWORD:-redhat}"
  export AAP_ADMIN_PASSWORD="${AAP_ADMIN_PASSWORD:-redhat}"
  export MM_ADMIN_PASSWORD="${MM_ADMIN_PASSWORD:-ansibleredhat}"
  printf '   lab-user / Gitea : %s\n' "${LAB_USER_PASSWORD}" > /dev/tty
  printf '   AAP admin        : %s\n' "${AAP_ADMIN_PASSWORD}" > /dev/tty
  printf '   Mattermost admin : %s\n' "${MM_ADMIN_PASSWORD}" > /dev/tty
  printf '   (not prompted — export LAB_USER_PASSWORD / AAP_ADMIN_PASSWORD /\n' > /dev/tty
  printf '    MM_ADMIN_PASSWORD before running to override)\n' > /dev/tty
}

# --- AI inference + Lightspeed, all optional ---------------------------------
# Shared by the full bootstrap and the demo-content-only run.
_collect_ai_secrets() {
  # --- AI inference (all OPTIONAL) -------------------------------------------
  # Every one of these can be skipped with Enter. Skipping them all deploys a
  # local CPU inference endpoint on the control node, which needs no input and
  # works out of the box - just slowly. You can also fill them in later without
  # re-running bootstrap.sh, using scripts/set-ai-endpoint.sh.
  #
  # Anything already exported is used as the default, so a non-interactive run
  # (CI, or repeated runs) never blocks on these.
  printf '\n== AI inference (optional — press Enter to skip any of these) ==\n' > /dev/tty
  printf '   Skip all three and the demo deploys a local CPU endpoint on the\n' > /dev/tty
  printf '   control node. You can point it at OpenShift AI / RHEL AI / MaaS now,\n' > /dev/tty
  printf '   or later with scripts/set-ai-endpoint.sh.\n' > /dev/tty

  if _skip_if_set AI_MODEL_ENDPOINT; then
    printf '   Using AI_MODEL_ENDPOINT from the environment: %s\n' "${AI_MODEL_ENDPOINT}" > /dev/tty
  else
    _read_plain "  Red Hat AI model endpoint URL (must end in /v1)" AI_MODEL_ENDPOINT
  fi

  if [[ -n "${AI_MODEL_ENDPOINT}" ]]; then
    if ! _skip_if_set AI_MODEL_ID; then
      printf '   Model id exactly as the endpoint reports it at /v1/models.\n' > /dev/tty
      _read_plain "  Red Hat AI model id" AI_MODEL_ID
    fi
    # Not passed as a _read_secret default: that would print it in cleartext.
    if ! _skip_if_set AI_MODEL_API_KEY; then
      _read_secret "  Red Hat AI model API key" AI_MODEL_API_KEY 0 0
    fi
    # Optional second model for playbook generation. A capable endpoint handles
    # both jobs with one model; the split exists only to work around small
    # CPU-hosted models, so the default here is "reuse the same one".
    if ! _skip_if_set AI_CODEGEN_MODEL_ID; then
      _read_plain "  Model id for code generation (Enter = same model)" \
                  AI_CODEGEN_MODEL_ID "${AI_MODEL_ID}"
    fi
  else
    printf '   -> Skipped. Using the local CPU endpoint on the control node.\n' > /dev/tty
    printf '      It serves two models: a chat model for the root cause analysis\n' > /dev/tty
    printf '      and a code model for playbook generation. Both are pulled for you.\n' > /dev/tty
  fi
  export AI_MODEL_ENDPOINT
  export AI_MODEL_ID="${AI_MODEL_ID:-}"
  export AI_CODEGEN_MODEL_ID="${AI_CODEGEN_MODEL_ID:-}"
  export AI_MODEL_API_KEY="${AI_MODEL_API_KEY:-not-required}"

  # --- Ansible Lightspeed (OPTIONAL) ----------------------------------------
  printf '\n== Ansible Lightspeed (optional — press Enter to skip) ==\n' > /dev/tty
  printf '   Skip this and remediation playbooks are generated by the model\n' > /dev/tty
  printf '   endpoint above — same demo narrative, no seat entitlement needed.\n' > /dev/tty
  if _skip_if_set LIGHTSPEED_API_KEY; then
    printf '   Using LIGHTSPEED_API_KEY from the environment.\n' > /dev/tty
  else
    _read_secret "  Ansible Lightspeed API key" LIGHTSPEED_API_KEY 0 0
  fi
  export LIGHTSPEED_API_KEY="${LIGHTSPEED_API_KEY:-}"

  if [[ -n "${LIGHTSPEED_API_KEY}" ]]; then
    # Deliberately NOT switching lightspeed_mode automatically. A token whose
    # entitlement has lapsed would break the demo at the generation step, and
    # that failure is confusing mid-demo. Verify first, then opt in.
    printf '   -> Token stored. The demo still generates playbooks with the model\n' > /dev/tty
    printf '      endpoint by default. To use the hosted Lightspeed service, first\n' > /dev/tty
    printf '      verify your entitlement (see README "Ansible Lightspeed"), then\n' > /dev/tty
    printf '      set lightspeed_mode: saas in\n' > /dev/tty
    printf '      ansible/roles/demo_content/defaults/main.yml\n' > /dev/tty
  else
    printf '   -> Skipped. Playbooks will be generated by the model endpoint.\n' > /dev/tty
  fi
}

# =============================================================================
# collect_secrets - for the FULL build (bootstrap.sh).
#
# Red Hat credentials are required here because the base and AAP stages register
# the hosts with RHSM and pull container images from registry.redhat.io.
# =============================================================================
collect_secrets() {
  _require_for_noninteractive || return 1
  printf '\n== Red Hat credentials (registry.redhat.io + RHSM) ==\n' > /dev/tty
  printf '   (Same credentials used for both RHSM and container registry)\n' > /dev/tty
  if _skip_if_set RHSM_USERNAME; then
    printf '   Using RHSM_USERNAME from the environment: %s\n' "${RHSM_USERNAME}" > /dev/tty
  else
    _read_plain "  Red Hat username" RHSM_USERNAME
  fi
  export RH_REGISTRY_USERNAME="${RHSM_USERNAME}"
  if _skip_if_set RHSM_PASSWORD; then
    printf '   Using RHSM_PASSWORD from the environment.\n' > /dev/tty
  else
    _read_secret "  Red Hat password" RHSM_PASSWORD 1 0
  fi
  export RH_REGISTRY_PASSWORD="${RHSM_PASSWORD}"

  _collect_app_passwords

  printf '\n== Ansible Vault (for encrypting sensitive vars) ==\n' > /dev/tty
  printf '   Enter vault password (or press Enter to auto-generate):\n' > /dev/tty
  if _skip_if_set VAULT_PASSWORD; then
    printf '   Using VAULT_PASSWORD from the environment.\n' > /dev/tty
  else
    _read_secret "  Vault password" VAULT_PASSWORD 0 0
  fi
  if [[ -z "${VAULT_PASSWORD:-}" ]]; then
    VAULT_PASSWORD="$(openssl rand -base64 32)"
    printf '   Auto-generated vault password (save this if you need to re-run):\n   %s\n' "${VAULT_PASSWORD}" > /dev/tty
  fi
  export VAULT_PASSWORD

  _collect_ai_secrets

  printf '\nSecrets are held in this process environment only — vault file will be encrypted.\n' > /dev/tty
}

# =============================================================================
# collect_secrets_demo_content - for the FAST path (demo_content.sh).
#
# Deliberately does NOT ask for Red Hat credentials or a vault password. The
# demo_content stage only talks to Gitea, Mattermost, AAP and EDA - all of which
# are already installed and authenticated by that point. Asking again would be
# friction for no benefit, which is the whole point of the fast path.
# =============================================================================
collect_secrets_demo_content() {
  _collect_app_passwords
  _collect_ai_secrets

  printf '\nSecrets are held in this process environment only.\n' > /dev/tty
}
