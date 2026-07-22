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

# _read_secret <prompt> <varname> <required:0|1> <confirm:0|1>
_read_secret() {
  local prompt="$1" var="$2" required="${3:-0}" confirm="${4:-0}" val val2
  while true; do
    printf '%s: ' "${prompt}" > /dev/tty
    IFS= read -rs val < /dev/tty
    printf '\n' > /dev/tty
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
  printf '\n== Red Hat subscription (input hidden where sensitive) ==\n' > /dev/tty
  printf '  [1] Activation key + organization ID (recommended)\n' > /dev/tty
  printf '  [2] Username + password\n' > /dev/tty
  local method
  printf 'Choose 1 or 2 [1]: ' > /dev/tty
  IFS= read -r method < /dev/tty
  if [[ "${method}" == "2" ]]; then
    _read_plain  "  RHSM username" RHSM_USERNAME
    _read_secret "  RHSM password" RHSM_PASSWORD 1 0
  else
    _read_plain  "  RHSM organization ID" RHSM_ORG_ID
    _read_secret "  RHSM activation key" RHSM_ACTIVATION_KEY 1 0
  fi

  printf '\n-- registry.redhat.io service account (needed for AAP images) --\n' > /dev/tty
  printf '   Leave blank if you set aap_install_enabled=false.\n' > /dev/tty
  _read_plain  "  Registry service-account username" RH_REGISTRY_USERNAME
  _read_secret "  Registry service-account token" RH_REGISTRY_PASSWORD 0 0

  printf '\n== Application passwords (hidden, entered twice) ==\n' > /dev/tty
  _read_secret "  lab-user password (UI + console logins)" LAB_USER_PASSWORD 1 1
  _read_secret "  AAP admin password" AAP_ADMIN_PASSWORD 1 1

  printf '\n== AI services (optional — leave blank to wire up later) ==\n' > /dev/tty
  _read_secret "  Ansible Lightspeed API key" LIGHTSPEED_API_KEY 0 0
  _read_plain  "  Red Hat AI model endpoint URL" AI_MODEL_ENDPOINT
  _read_secret "  Red Hat AI model API key" AI_MODEL_API_KEY 0 0

  printf '\nSecrets are held in this process environment only — not written to disk.\n' > /dev/tty
}
