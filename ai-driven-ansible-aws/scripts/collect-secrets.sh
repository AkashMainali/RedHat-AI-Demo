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

# _read_plain <prompt> <varname>  (non-secret; visible input)
_read_plain() {
  local prompt="$1" var="$2" val
  printf '%s: ' "${prompt}" > /dev/tty
  IFS= read -r val < /dev/tty
  export "${var}=${val}"
  unset val
}

collect_secrets() {
  printf '\n== Red Hat credentials (registry.redhat.io + RHSM) ==\n' > /dev/tty
  printf '   (Same credentials used for both RHSM and container registry)\n' > /dev/tty
  _read_plain  "  Red Hat username" RHSM_USERNAME
  export RH_REGISTRY_USERNAME="${RHSM_USERNAME}"
  _read_secret "  Red Hat password" RHSM_PASSWORD 1 0
  export RH_REGISTRY_PASSWORD="${RHSM_PASSWORD}"

  printf '\n== Application passwords ==\n' > /dev/tty
  printf '   lab-user: redhat (default — no prompt)\n' > /dev/tty
  printf '   AAP admin: redhat (default — no prompt)\n' > /dev/tty
  export LAB_USER_PASSWORD="redhat"
  export AAP_ADMIN_PASSWORD="redhat"

  printf '\n== Ansible Vault (for encrypting sensitive vars) ==\n' > /dev/tty
  printf '   Enter vault password (or press Enter to auto-generate):\n' > /dev/tty
  _read_secret "  Vault password" VAULT_PASSWORD 0 0
  if [[ -z "${VAULT_PASSWORD}" ]]; then
    VAULT_PASSWORD="$(openssl rand -base64 32)"
    printf '   Auto-generated vault password (save this if you need to re-run):\n   %s\n' "${VAULT_PASSWORD}" > /dev/tty
  fi
  export VAULT_PASSWORD

  printf '\n== AI services (optional — leave blank to wire up later) ==\n' > /dev/tty
  _read_secret "  Ansible Lightspeed API key" LIGHTSPEED_API_KEY 0 0
  _read_plain  "  Red Hat AI model endpoint URL" AI_MODEL_ENDPOINT
  _read_secret "  Red Hat AI model API key" AI_MODEL_API_KEY 0 0

  printf '\nSecrets are held in this process environment only — vault file will be encrypted.\n' > /dev/tty
}
