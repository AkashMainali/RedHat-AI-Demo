#!/usr/bin/env bash
# =============================================================================
# attach-subscription.sh - attach an AAP subscription. Seconds, no reinstall.
#
# Talks straight to the AAP controller API:
#   POST /api/controller/v2/config/subscriptions/   list your pools
#   POST /api/controller/v2/config/attach/          attach the chosen one
#   POST /api/controller/v2/config/                 accept the EULA
#   GET  /api/controller/v2/config/                 verify it took
#
# This is the same sequence the UI subscription wizard performs, and the same one
# bootstrap.sh runs automatically after installing AAP. Use this when that did not
# run or did not find a pool - it avoids the preflight, AWS auth, SSH waits and
# collection extraction that a tagged bootstrap.sh run still performs.
#
# Your Red Hat password is read with hidden input, used for one API call, and
# never written to disk. AAP stores the resulting subscription itself.
# =============================================================================
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

cleanup() { unset RH_PASSWORD AAP_ADMIN_PASSWORD 2>/dev/null || true; }
trap cleanup EXIT INT TERM

AAP_HOST="${AAP_HOST:-}"
POOL_NAME="${AAP_SUBSCRIPTION_POOL:-}"
LIST_ONLY=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Attaches a subscription to an already-installed AAP. Idempotent: re-running with
a subscription already attached simply reports it.

  --host URL       AAP base URL (default: read from Terraform outputs)
  --pool NAME      Substring of the subscription name to attach
                   (default: \$AAP_SUBSCRIPTION_POOL, else you pick from a list)
  --list           Show the available pools and exit without attaching
  --profile NAME   AWS profile, only used to read the Terraform outputs
  --region NAME    AWS region, same
  -h, --help       Show this help

Examples:
  $(basename "$0") --list
  $(basename "$0") --pool "Partner"
  $(basename "$0") --profile my-sso-profile --pool "Partner"
  $(basename "$0") --host https://203.0.113.10 --pool "Partner"
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)    AAP_HOST="$2"; shift 2 ;;
    --pool)    POOL_NAME="$2"; shift 2 ;;
    --list)    LIST_ONLY=1; shift ;;
    # Accepted for symmetry with the other scripts, so the same invocation works.
    --profile) export AWS_PROFILE="$2"; shift 2 ;;
    --region)  export AWS_REGION="$2" AWS_DEFAULT_REGION="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

# --- where is AAP -----------------------------------------------------------
if [[ -z "${AAP_HOST}" ]]; then
  if ip="$(terraform -chdir="${TF_DIR}" output -raw control_public_ip 2>/dev/null)" && [[ -n "${ip}" ]]; then
    AAP_HOST="https://${ip}"
  else
    die "Could not read the control node IP from Terraform. Pass --host https://<ip>."
  fi
fi
API="${AAP_HOST%/}/api/controller/v2"
log "AAP: ${AAP_HOST}"

# --- credentials ------------------------------------------------------------
if [[ -z "${AAP_ADMIN_PASSWORD:-}" ]]; then
  printf 'AAP admin password (hidden) [redhat]: ' >&2
  IFS= read -rs AAP_ADMIN_PASSWORD; printf '\n' >&2
  AAP_ADMIN_PASSWORD="${AAP_ADMIN_PASSWORD:-redhat}"
fi
AAP_USER="${AAP_ADMIN_USER:-admin}"

# Already attached? Then there is nothing to do.
current="$(curl -sSk -u "${AAP_USER}:${AAP_ADMIN_PASSWORD}" "${API}/config/" 2>/dev/null || true)"
lic="$(printf '%s' "${current}" | jq -r '.license_info.license_type // "unlicensed"' 2>/dev/null || echo unlicensed)"
if [[ -z "${current}" ]]; then
  die "Could not reach ${API}/config/. Check the host, and that the AAP admin password is right."
fi
if [[ "${lic}" != "unlicensed" && "${lic}" != "UNLICENSED" && "${lic}" != "null" && "${LIST_ONLY}" -eq 0 ]]; then
  free="$(printf '%s' "${current}" | jq -r '.license_info.free_instances // 0')"
  ok "Already subscribed: ${lic}, ${free} managed-node slots free. Nothing to do."
  exit 0
fi

if [[ -z "${RHSM_USERNAME:-}" ]]; then
  printf 'Red Hat username: ' >&2
  IFS= read -r RHSM_USERNAME
fi
if [[ -z "${RH_PASSWORD:-}" ]]; then
  printf 'Red Hat password (hidden): ' >&2
  IFS= read -rs RH_PASSWORD; printf '\n' >&2
fi
[[ -n "${RHSM_USERNAME}" && -n "${RH_PASSWORD}" ]] || die "Red Hat username and password are required to list your pools."

# --- list pools -------------------------------------------------------------
log "Asking Red Hat which subscription pools this account has..."
pools_raw="$(curl -sSk -u "${AAP_USER}:${AAP_ADMIN_PASSWORD}" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg u "${RHSM_USERNAME}" --arg p "${RH_PASSWORD}" \
        '{subscriptions_username:$u, subscriptions_password:$p}')" \
  "${API}/config/subscriptions/" 2>/dev/null || true)"

# The endpoint has returned both a bare array and an object wrapping 'results'.
pools="$(printf '%s' "${pools_raw}" | jq -c 'if type=="object" and has("results") then .results else . end' 2>/dev/null || echo '[]')"
count="$(printf '%s' "${pools}" | jq 'length' 2>/dev/null || echo 0)"

if [[ "${count}" -eq 0 ]]; then
  printf '%s\n' "${pools_raw}" | head -c 600 >&2
  die "No subscription pools returned. Check the Red Hat credentials, or that the account has an AAP entitlement."
fi

printf '\nAvailable subscriptions:\n' >&2
printf '%s' "${pools}" | jq -r 'to_entries[] | "  [\(.key)] \(.value.subscription_name)  —  nodes: \(.value.instance_count)"' >&2
printf '\n' >&2

if [[ "${LIST_ONLY}" -eq 1 ]]; then
  # --list is also the diagnostic: show the raw field names, because which one
  # carries the identifier has varied between AAP releases.
  printf 'Fields present on each pool (the identifier is one of these):\n' >&2
  printf '%s' "${pools}" | jq -r '.[0] | keys | "  " + join(", ")' >&2
  exit 0
fi

# --- choose -----------------------------------------------------------------
if [[ -n "${POOL_NAME}" ]]; then
  idx="$(printf '%s' "${pools}" | jq --arg n "${POOL_NAME}" \
    'map(.subscription_name | test($n)) | index(true) // -1')"
  [[ "${idx}" != "-1" ]] || die "No subscription matches '${POOL_NAME}'. Pick from the list above with --pool, or omit it to choose interactively."
else
  printf 'Which subscription? [number]: ' >&2
  IFS= read -r idx
fi

chosen="$(printf '%s' "${pools}" | jq -c ".[${idx}]" 2>/dev/null || true)"
[[ -n "${chosen}" && "${chosen}" != "null" ]] || die "Invalid selection '${idx}'."
name="$(printf '%s' "${chosen}" | jq -r '.subscription_name')"
nodes="$(printf '%s' "${chosen}" | jq -r '.instance_count')"

# The identifier field is not consistently named across AAP versions: pool_id,
# subscription_id and id have all appeared. Sending the wrong one produces
# 400 {"error":"No subscription ID provided."} - the attach body ends up with a
# null. So detect whichever the response actually carries.
pool_id="$(printf '%s' "${chosen}" | jq -r '.pool_id // .subscription_id // .id // empty')"

if [[ -z "${pool_id}" ]]; then
  printf '\nThe selected pool has these fields:\n' >&2
  printf '%s' "${chosen}" | jq -r 'to_entries[] | "  \(.key): \(.value|tostring|.[0:60])"' >&2
  die "None of pool_id / subscription_id / id is present on this pool, so there is nothing to attach with. The field list above shows what the API returned - tell me and I will map it."
fi
log "Attaching \"${name}\" (${nodes} managed nodes)"

# --- attach + EULA ----------------------------------------------------------
# Send the id under every name the endpoint has used. Extra keys are ignored by
# the versions that only read one of them, which makes this work across releases
# without probing first.
attach_body="$(jq -n --arg p "${pool_id}" \
  '{pool_id:$p, subscription_id:$p, id:$p, eula_accepted:true}')"
attach_code="$(curl -sSk -o /tmp/.attach.out -w '%{http_code}' \
  -u "${AAP_USER}:${AAP_ADMIN_PASSWORD}" -H 'Content-Type: application/json' \
  -d "${attach_body}" "${API}/config/attach/" || echo 000)"
log "attach -> HTTP ${attach_code}"

curl -sSk -o /dev/null -u "${AAP_USER}:${AAP_ADMIN_PASSWORD}" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg p "${pool_id}" '{eula_accepted:true, pool_id:$p, subscription_id:$p}')" \
  "${API}/config/" >/dev/null 2>&1 || true

# --- verify -----------------------------------------------------------------
after="$(curl -sSk -u "${AAP_USER}:${AAP_ADMIN_PASSWORD}" "${API}/config/" 2>/dev/null || true)"
lic="$(printf '%s' "${after}" | jq -r '.license_info.license_type // "unlicensed"')"
free="$(printf '%s' "${after}" | jq -r '.license_info.free_instances // 0')"

if [[ "${lic}" == "unlicensed" || "${lic}" == "null" ]]; then
  printf '\nAttach response was:\n' >&2
  head -c 600 /tmp/.attach.out >&2 || true
  rm -f /tmp/.attach.out
  die "The subscription did not take effect (still ${lic}). Attach it in the UI instead: open ${AAP_HOST}, choose Username and Password, and pick \"${name}\"."
fi
rm -f /tmp/.attach.out

cat <<EOF

$(ok "DONE")  Subscription attached.

  Subscription : ${name}
  Type         : ${lic}
  Free nodes   : ${free}

Next:
  ./scripts/demo_content.sh${AWS_PROFILE:+ --profile ${AWS_PROFILE}}
EOF
